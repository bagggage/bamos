//! # Object Memory Allocator
//! 
//! Provides an implementation for a memory allocator that manages objects
//! in a virtual memory system. It uses arenas to allocate and free memory for objects of 
//! a specific size. The allocator ensures that memory is efficiently reused by utilizing a 
//! free list for deallocated objects.
//! 
//! This allocator is particularly fast and not prone to fragmentation.
//! The additional memory overhead is practically nonexistent, except for allocating a few bytes per arena.
//! 
//! Best choise for allocating objects of the same size.

// Copyright (C) 2024 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const boot = @import("../boot.zig");
const utils = @import("../utils.zig");
const vm = @import("../vm.zig");

const FreeList_t = utils.SList(void);
const FreeNode = FreeList_t.Node;
const ArenaList_t = utils.SList(Arena);
const ArenaNode = ArenaList_t.Node;

const Arena = struct {
    /// Represents a physical page number of the memory pool from which objects are allocated.
    pool_base: u32 = undefined,
    /// Number of allocations made from this arena.
    alloc_num: u32 = 0,

    /// Pointer to the next available memory location in the pool.
    next_ptr: usize = undefined,

    /// Free list for managing deallocated objects.
    free_list: FreeList_t = FreeList_t{},

    /// Initializes an `Arena` structure.
    /// 
    /// - `phys_pool`: The physical memory address of the pool.
    pub fn init(phys_pool: usize) Arena {
        return Arena{ .pool_base = @truncate(phys_pool / vm.page_size), .next_ptr = vm.getVirtLma(phys_pool) };
    }

    /// Allocates memory for an object of size `obj_size`.
    /// First try to get free entry from the `free_list`, only then uses `next_ptr`.
    /// 
    /// - `obj_size`: The size of the object to allocate.
    /// - Returns: The address of the allocated object.
    pub fn alloc(self: *Arena, obj_size: usize) usize {
        defer self.alloc_num += 1;

        if (self.free_list.first != null) {
            const node = self.free_list.popFirst().?;
            return @intFromPtr(node);
        }

        const result = self.next_ptr;
        self.next_ptr += obj_size;

        return result;
    }

    /// Frees the memory of an object.
    /// Usually puts new entry into `free_list`.
    /// But if this object was the last allocated just decrements the `next_ptr`.
    /// 
    /// This function should not be used externally, see `freeRaw` instead.
    /// 
    /// - `obj_addr`: The address of the object to free.
    /// - `obj_size`: The size of the object to free.
    pub fn free(self: *Arena, obj_addr: usize, obj_size: usize) void {
        defer self.alloc_num -= 1;

        if (self.next_ptr == obj_addr + obj_size) {
            self.next_ptr -= obj_size;
        } else {
            const node: *FreeNode = @ptrFromInt(obj_addr);
            self.free_list.prepend(node);
        }
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

arenas: ArenaList_t = ArenaList_t{},
arena_capacity: u32 = undefined,

/// Rank (log2 of the number of pages) of the arenas.
arena_rank: u32 = undefined,
obj_size: usize = undefined,

/// Target capacity of bucket for arena nodes allocator.
const arenas_tar_capacity = 256;
/// Allocator for managing arena nodes.
var arenas_alloc: vm.BucketAllocator = undefined;
var arenas_lock = utils.Spinlock.init(.unlocked);

/// Initializes the Object Memory Allocator (OMA) system.
/// 
/// - Returns: An error if the memory could not be allocated.
pub fn initOmaSystem() vm.Error!void {
    const pool_size = arenas_tar_capacity * @sizeOf(ArenaNode);
    const pool_pages = std.math.divCeil(comptime_int, pool_size, vm.page_size) catch unreachable;

    comptime std.debug.assert(std.math.isPowerOfTwo(pool_pages));

    const mem_pool = boot.alloc(pool_pages) orelse return vm.Error.NoMemory;
    const virt_pool = vm.getVirtLma(mem_pool);

    arenas_alloc = vm.BucketAllocator.initRaw(ArenaNode, virt_pool, pool_pages);
}

/// Initializes an allocator for a specific object type.
/// 
/// - `T`: The type of objects to allocate.
pub fn init(comptime T: type) Self {
    if (@sizeOf(T) < @sizeOf(FreeNode)) {
        @compileError(std.fmt.comptimePrint("Object size must be at least {} bytes.", .{@sizeOf(FreeNode)}));
    }

    return initCapacity(@sizeOf(T), 128);
}

/// Initializes an allocator with a specified object size and capacity per arena.
/// 
/// - `obj_size`: The size of the objects to allocate.
/// - `capacity`: The number of the objects per arena.
pub fn initCapacity(comptime obj_size: usize, comptime capacity: usize) Self {
    std.debug.assert(obj_size >= @sizeOf(FreeNode));

    const pages = std.math.divCeil(comptime_int, obj_size * capacity, vm.page_size) catch unreachable;

    return initSized(obj_size, pages);
}

/// Initializes an allocator with a specified object size and number of pages per arena.
/// 
/// - `obj_size`: The size of the objects to allocate.
/// - `pages`: The number of pages to allocate for the arena.
///
/// @export
pub fn initSized(obj_size: usize, pages: u32) Self {
    std.debug.assert(obj_size >= @sizeOf(FreeNode));

    const rank: u32 = std.math.log2_int_ceil(u32, @truncate(pages));
    const real_pages = @as(u32, 1) << @truncate(rank);
    const real_capacity: u32 = (real_pages * vm.page_size) / @as(u32, @truncate(obj_size));

    std.debug.assert(real_capacity > 1);

    return Self{ .arena_capacity = real_capacity, .arena_rank = rank, .obj_size = obj_size };
}

/// Initializes an allocator with a specified object size and physical memory pool.
/// 
/// - `obj_size`: The size of the object.
/// - `pool_phys`: The physical memory address of the pool.
/// - `pool_pages`: The number of pages in the pool.
/// - Returns: A `Self` structure or an error if the allocation fails.
pub fn initRaw(obj_size: usize, pool_phys: usize, pool_pages: u32) vm.Error!Self {
    var result = initSized(obj_size, pool_pages);

    const real_pages = @as(u32, 1) << @truncate(result.arena_rank);
    std.debug.assert(real_pages == pool_pages);

    const node = makeArena(pool_phys) orelse return error.NoMemory;
    result.arenas.prepend(node);

    return result;
}

/// Deinitialize allocator, free all allocated memory.
pub export fn deinit(self: *Self) void {
    var node = self.arenas.first;

    while (node) |arena| {
        const next = arena.next;
        self.freeArena(arena);

        node = next;
    }

    self.arenas.first = null;
}

/// Allocates memory for an object and cast it to pointer of type `T`.
/// 
/// - `T`: The type of pointer.
/// - Returns: A pointer to the allocated object, or `null` if allocation fails.
pub inline fn alloc(self: *Self, comptime T: type) ?*T {
    return @as(*T, @alignCast(@ptrCast(self.allocEx() orelse return null)));
}

/// Frees the memory of an object.
/// Invalid object pointer causes UB.
/// 
/// - `obj_ptr`: Pointer to the object to free.
pub inline fn free(self: *Self, obj_ptr: anytype) void {
    comptime {
        const type_info = @typeInfo(@TypeOf(obj_ptr));
        switch (type_info) {
            .pointer => |ptr| if (ptr.size != .One) @compileError("Argument type must be a pointer to one object"),
            else => @compileError("Argument type must be a pointer to one object"),
        }
    }

    self.freeEx(@intFromPtr(obj_ptr));
}

/// Frees object in arena without additional checks.
/// This function provides implementation-dependent API to free objects
/// and should be used instead of `Arena.free` in pair with `contains`.
/// 
/// - `arena`: Arena node that belongs to the allocator instance.
/// - `obj_addr`: Address of the object, managed by the arena, to free.
///
/// @noexport
pub inline fn freeRaw(self: *Self, arena: *ArenaNode, obj_addr: usize) void {
    arena.data.free(obj_addr, self.obj_size);

    if (arena.data.alloc_num == 0) self.deleteArena(arena);
}

/// Find allocator's arena that manage the address.
/// 
/// - `addr`: The address of the object.
/// - Returns: A pointer to the arena if the address is managed by the allocator, `null` otherwise.
///
/// @noexport
pub inline fn contains(self: *const Self, addr: usize) ?*ArenaNode {
    var node = self.arenas.first;
    const arena_size = self.getArenaSize();

    while (node) |arena| : (node = arena.next) {
        if (arena.data.contains(addr, arena_size)) {
            return arena;
        }
    }

    return null;
}

/// Returns the arena size in bytes for the current allocator.
inline fn getArenaSize(self: *const Self) usize {
    return (@as(u32, 1) << @truncate(self.arena_rank)) * vm.page_size;
}

export fn allocEx(self: *Self) ?*anyopaque {
    var node = self.arenas.first;

    while (node) |arena| : (node = arena.next) {
        if (arena.data.alloc_num < self.arena_capacity) break;
    }

    var arena: *ArenaNode = undefined;

    if (node) |ptr| {
        arena = ptr;
    } else {
        arena = self.newArena() orelse return null;
    }

    return @ptrFromInt(arena.data.alloc(self.obj_size));
}

export fn freeEx(self: *Self, obj_addr: usize) void {
    const arena = self.contains(obj_addr) orelse unreachable;
    self.freeRaw(arena, obj_addr);
}

/// Creates a new arena and initializes it with a given physical memory pool.
/// 
/// - `pool_phys`: The physical memory address of the pool.
/// - Returns: A pointer to the newly created `ArenaNode`, or `null` if allocation fails.
fn makeArena(phys_pool: usize) ?*ArenaNode {
    const node = blk: {
        arenas_lock.lock();
        defer arenas_lock.unlock();

        break :blk arenas_alloc.alloc(ArenaNode) orelse return null;
    };

    node.data = Arena.init(phys_pool);
    return node;
}

/// Allocates and initializes a new arena for the allocator.
/// 
/// - Returns: A pointer to the newly created `ArenaNode`, or `null` if allocation fails.
pub fn newArena(self: *Self) ?*ArenaNode {
    const phys = vm.PageAllocator.alloc(self.arena_rank) orelse return null;
    const node = makeArena(phys) orelse {
        vm.PageAllocator.free(phys, self.arena_rank);
        return null;
    };

    self.arenas.prepend(node);
    return node;
}

/// Deletes an arena and frees its memory.
/// 
/// - `arena`: Pointer to the `ArenaNode` to delete.
fn deleteArena(self: *Self, arena: *ArenaNode) void {
    self.arenas.remove(arena);
    self.freeArena(arena);
}

/// Free arena memory.
/// 
/// - `arena`: Pointer to the `ArenaNode` to free.
inline fn freeArena(self: *Self, arena: *ArenaNode) void {
    vm.PageAllocator.free(@as(usize, arena.data.pool_base) * vm.page_size, self.arena_rank);
    arenas_alloc.free(arena);
}
