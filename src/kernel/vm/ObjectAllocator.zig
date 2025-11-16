//! # Object Memory Allocator
//! 
//! Provides an implementation for a lock-free memory allocator that manages objects
//! in a virtual memory system. It uses arenas to allocate and free memory for objects of 
//! a specific size. The allocator ensures that memory is efficiently reused by utilizing a 
//! free list for deallocated objects.
//! 
//! This allocator is particularly fast and not prone to fragmentation.
//! The additional memory overhead is practically nonexistent, except for allocating a few bytes per arena.
//! 
//! Best choise for allocating objects of the same size.

// Copyright (C) 2024-2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const boot = @import("../boot.zig");
const lib = @import("../lib.zig");
const vm = @import("../vm.zig");

const FreeList = lib.atomic.SinglyLinkedList;

pub const Arena = struct {
    const List = lib.atomic.SinglyLinkedList;
    const Node = List.Node;

    /// Represents a physical page number of the memory pool from which objects are allocated.
    pool_base: u32,
    /// Number of allocations made from this arena.
    alloc_num: std.atomic.Value(u16) = .init(0),

    /// Pointer to the next available memory location in the pool.
    next_ptr: std.atomic.Value(usize),

    /// Free list for managing deallocated objects.
    free_list: FreeList = .{},
    node: Node = .{},

    /// Initializes an `Arena` structure.
    /// 
    /// - `phys_pool`: The physical memory address of the pool.
    pub fn init(phys_pool: usize) Arena {
        return .{ .pool_base = @truncate(phys_pool / vm.page_size), .next_ptr = .init(vm.getVirtLma(phys_pool)) };
    }

    pub inline fn fromNode(node: *Node) *Arena {
        return @fieldParentPtr("node", node);
    }

    /// Allocates memory for an object of size `obj_size`.
    /// First try to get free entry from the `free_list`, only then uses `next_ptr`.
    /// 
    /// - `obj_size`: The size of the object to allocate.
    /// - Returns: The address of the allocated object.
    pub fn alloc(self: *Arena, obj_size: u16, capacity: u16) ?usize {
        var curr_num = self.alloc_num.raw;
        if (curr_num >= capacity or curr_num == 0) return null;

        while (self.alloc_num.cmpxchgWeak(curr_num, curr_num +% 1, .release, .monotonic)) |num| {
            curr_num = num;
            if (curr_num >= capacity or curr_num == 0) return null;
        }

        return self.allocRaw(obj_size);
    }

    pub fn allocFirst(self: *Arena, obj_size: u16) usize {
        _ = self.alloc_num.fetchAdd(1, .release);
        return self.allocRaw(obj_size);
    }

    inline fn allocRaw(self: *Arena, obj_size: u16) usize {
        if (self.free_list.popFirst()) |node| {
            return @intFromPtr(node);
        }

        return self.next_ptr.fetchAdd(obj_size, .release);
    }

    /// Frees the memory of an object.
    /// Usually puts new entry into `free_list`.
    /// But if this object was the last allocated just decrements the `next_ptr`.
    /// 
    /// - `obj_addr`: The address of the object to free.
    /// - `obj_size`: The size of the object to free.
    fn free(self: *Arena, obj_addr: usize, obj_size: u16) bool {
        const expected_ptr = obj_addr + obj_size;
        if (self.next_ptr.cmpxchgStrong(expected_ptr, obj_addr, .release, .acquire) != null) {
            const node: *FreeList.Node = @ptrFromInt(obj_addr);
            self.free_list.prepend(node);
        }

        return self.alloc_num.fetchSub(1, .release) == 1;
    }

    /// Checks if an address belongs to this `Arena`.
    /// 
    /// - `obj_addr`: The address to check.
    /// - `pool_size`: The size of the memory pool.
    /// - Returns: `true` if the address is within the arena's range, `false` otherwise.
    pub fn contains(self: *Arena, obj_addr: usize, pool_size: usize) bool {
        const begin = self.getBase();
        const end = begin + pool_size;

        return obj_addr >= begin and obj_addr < end;
    }

    /// Returns virtual base address of the arena pool.
    pub inline fn getBase(self: *const Arena) usize {
        return vm.getVirtLma(@as(usize, self.pool_base) * vm.page_size);
    }
};

const Self = @This();

arenas: Arena.List = .{},
/// Rank (log2 of the number of pages) of the arenas.
arena_rank: u8,
arena_capacity: u16,

obj_size: u16,

/// Target capacity of bucket for arena nodes allocator.
pub const default_capacity = 128;
/// Allocator for managing arena nodes.
var arenas_alloc: vm.BucketAllocator = undefined;
var arenas_lock: lib.sync.Spinlock = .init(.unlocked);

/// Initializes the Object Memory Allocator (OMA) system.
/// - Returns: An error if the memory could not be allocated.
pub fn initOmaSystem() vm.Error!void {
    const pool_size = default_capacity * @sizeOf(Arena);
    const pool_pages = std.math.divCeil(comptime_int, pool_size, vm.page_size) catch unreachable;

    comptime std.debug.assert(std.math.isPowerOfTwo(pool_pages));

    const mem_pool = boot.alloc(pool_pages) orelse return vm.Error.NoMemory;
    const virt_pool = vm.getVirtLma(mem_pool);

    arenas_alloc = vm.BucketAllocator.initRaw(Arena, virt_pool, pool_pages);
}

/// Initializes an allocator for a specific object type.
/// - `T`: The type of objects to allocate.
pub fn init(comptime T: type) Self {
    if (@sizeOf(T) < @sizeOf(FreeList.Node)) {
        @compileError(std.fmt.comptimePrint("Object size must be at least {} bytes.", .{@sizeOf(FreeList.Node)}));
    }

    return initCapacity(@sizeOf(T), 128);
}

/// Initializes an allocator with a specified object size and capacity per arena.
/// 
/// - `obj_size`: The size of the objects to allocate.
/// - `capacity`: The number of the objects per arena.
pub fn initCapacity(obj_size: comptime_int, capacity: comptime_int) Self {
    std.debug.assert(obj_size >= @sizeOf(FreeList.Node));

    const pages = std.math.divCeil(comptime_int, obj_size * capacity, vm.page_size) catch unreachable;
    return initSized(obj_size, pages);
}

/// Initializes an allocator with a specified object size and number of pages per arena.
/// 
/// - `obj_size`: The size of the objects to allocate.
/// - `pages`: The number of pages to allocate for the arena.
pub fn initSized(obj_size: u16, pages: u16) Self {
    std.debug.assert(obj_size >= @sizeOf(FreeList.Node));

    const rank = std.math.log2_int_ceil(u16, pages);
    const real_pages = @as(u32, 1) << rank;
    const real_capacity: u32 = (real_pages * vm.page_size) / obj_size;

    std.debug.assert(real_capacity > 1);
    return .{ .arena_capacity = @truncate(real_capacity), .arena_rank = rank, .obj_size = obj_size };
}

/// Initializes an allocator with a specified object size and physical memory pool.
/// 
/// - `obj_size`: The size of the object.
/// - `pool_phys`: The physical memory address of the pool.
/// - `pool_pages`: The number of pages in the pool.
/// - Returns: A `Self` structure or an error if the allocation fails.
pub fn initRaw(obj_size: u16, pool_phys: usize, pool_pages: u16) vm.Error!Self {
    var result = initSized(obj_size, pool_pages);

    const real_pages = @as(u32, 1) << @truncate(result.arena_rank);
    std.debug.assert(real_pages == pool_pages);

    const arena = makeArena(pool_phys) orelse return error.NoMemory;
    result.arenas.prepend(&arena.node);

    return result;
}

/// Deinitialize allocator, free all allocated memory.
pub export fn deinit(self: *Self) void {
    var node = self.arenas.first.swap(null, .release);
    while (node) |n| {
        const next = n.next;
        self.freeArena(Arena.fromNode(n));

        node = next;
    }
}

/// Allocates memory for an object and cast it to pointer of type `T`.
/// - `T`: The type of pointer.
/// - Returns: A pointer to the allocated object, or `null` if allocation fails.
pub inline fn alloc(self: *Self, comptime T: type) ?*T {
    return @as(*T, @alignCast(@ptrCast(self.allocEx() orelse return null)));
}

/// Frees the memory of an object. Invalid object pointer causes UB.
/// - `obj_ptr`: Pointer to the object to free.
pub inline fn free(self: *Self, obj_ptr: anytype) void {
    comptime {
        const type_info = @typeInfo(@TypeOf(obj_ptr));
        switch (type_info) {
            .pointer => |ptr| if (ptr.size != .one) @compileError("Argument type must be a pointer to one object"),
            else => @compileError("Argument type must be a pointer to one object"),
        }
    }

    self.freeEx(@intFromPtr(obj_ptr));
}

/// Frees object in arena.
/// This function provides implementation-dependent API to free objects
/// and should be used instead of `Arena.free` in pair with `contains`.
/// 
/// - `arena`: Arena node that belongs to the allocator instance.
/// - `obj_addr`: Address of the object, managed by the arena, to free.
pub inline fn freeRaw(self: *Self, arena: *Arena, obj_addr: usize) void {
    if (arena.free(obj_addr, self.obj_size)) {
        self.deleteArena(arena);
    }
}

/// Find allocator's arena that manage the address.
/// - `addr`: The address of the object.
/// - Returns: A pointer to the arena if the address is managed by the allocator, `null` otherwise.
pub inline fn contains(self: *const Self, addr: usize) ?*Arena {
    var node = self.arenas.first.load(.acquire);
    const arena_size = self.getArenaSize();

    while (node) |n| : (node = n.next) {
        const arena = Arena.fromNode(n);
        if (arena.contains(addr, arena_size)) {
            return arena;
        }
    }

    return null;
}

/// Returns the arena size in bytes for the current allocator.
inline fn getArenaSize(self: *const Self) u32 {
    return (@as(u32, 1) << @truncate(self.arena_rank)) * vm.page_size;
}

export fn allocEx(self: *Self) ?*anyopaque {
    var node = self.arenas.first.load(.acquire);
    while (node) |n| : (node = n.next) {
        const arena = Arena.fromNode(n);
        const obj_addr= arena.alloc(self.obj_size, self.arena_capacity) orelse continue;

        return @ptrFromInt(obj_addr);
    }

    const arena = self.newArena() orelse return null;
    return @ptrFromInt(arena.allocFirst(self.obj_size));
}

export fn freeEx(self: *Self, obj_addr: usize) void {
    const arena = self.contains(obj_addr) orelse unreachable;
    self.freeRaw(arena, obj_addr);
}

/// Creates a new arena and initializes it with a given physical memory pool.
/// - `pool_phys`: The physical memory address of the pool.
/// - Returns: A pointer to the newly created `ArenaNode`, or `null` if allocation fails.
fn makeArena(phys_pool: usize) ?*Arena {
    const arena = blk: {
        arenas_lock.lock();
        defer arenas_lock.unlock();

        break :blk arenas_alloc.alloc(Arena) orelse return null;
    };

    arena.* = .init(phys_pool);
    return arena;
}

/// Allocates and initializes a new arena for the allocator.
/// - Returns: A pointer to the newly created `ArenaNode`, or `null` if allocation fails.
pub fn newArena(self: *Self) ?*Arena {
    const phys = vm.PageAllocator.alloc(self.arena_rank) orelse return null;
    const arena = makeArena(phys) orelse {
        vm.PageAllocator.free(phys, self.arena_rank);
        return null;
    };

    self.arenas.prepend(&arena.node);
    return arena;
}

/// Deletes an arena and frees its memory.
/// - `arena`: Pointer to the `ArenaNode` to delete.
inline fn deleteArena(self: *Self, arena: *Arena) void {
    self.arenas.remove(&arena.node);
    self.freeArena(arena);
}

/// Free arena memory.
/// - `arena`: Pointer to the `ArenaNode` to free.
inline fn freeArena(self: *Self, arena: *Arena) void {
    vm.PageAllocator.free(@as(usize, arena.pool_base) * vm.page_size, self.arena_rank);
    arenas_alloc.free(arena);
}

