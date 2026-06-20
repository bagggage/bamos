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

const bindings = @import("../bindings.zig");
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
    /// - `phys_pool`: The physical memory address of the pool.
    pub fn init(phys_pool: usize) Arena {
        return .{
            .pool_base = @truncate(phys_pool / vm.page_size),
            .next_ptr = .init(vm.getVirtLma(phys_pool)),
        };
    }

    pub inline fn fromNode(node: *Node) *Arena {
        return @fieldParentPtr("node", node);
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
arena_capacity: u32,

obj_size: u16,

/// Target capacity of bucket for arena nodes allocator.
pub const default_capacity = 128;

/// Initializes an allocator for a specific object type.
/// - `T`: The type of objects to allocate.
pub fn init(comptime T: type) Self {
    if (@sizeOf(T) < @sizeOf(FreeList.Node)) {
        @compileError(std.fmt.comptimePrint("Object size must be at least {} bytes.", .{@sizeOf(FreeList.Node)}));
    }

    return initCapacity(@sizeOf(T), 128);
}

/// Initializes an allocator with a specified object size and capacity per arena.
/// - `obj_size`: The size of the objects to allocate.
/// - `capacity`: The number of the objects per arena.
pub inline fn initCapacity(obj_size: comptime_int, capacity: comptime_int) Self {
    std.debug.assert(obj_size >= @sizeOf(FreeList.Node));
    return initSized(obj_size, vm.bytesToPages(obj_size * capacity));
}

/// Initializes an allocator with a specified object size and number of pages per arena.
/// - `obj_size`: The size of the objects to allocate.
/// - `pages`: The number of pages to allocate for the arena.
pub fn initSized(obj_size: u16, pages: u16) Self {
    std.debug.assert(obj_size >= @sizeOf(FreeList.Node));

    const rank = vm.pagesToRankExact(pages);
    const real_pages = vm.rankToPages(rank);
    const real_capacity: u32 = (real_pages * vm.page_size) / obj_size;

    std.debug.assert(real_capacity > 1);
    return .{ .arena_capacity = real_capacity, .arena_rank = rank, .obj_size = obj_size };
}

/// Deinitialize allocator, free all allocated memory.
pub inline fn deinit(self: *Self) void {
    return bindings.getInstance().vm.object_alloctor.deinit(self);
}

/// Allocates memory for an object and cast it to pointer of type `T`.
/// - `T`: The type of pointer.
/// - Returns: A pointer to the allocated object, or `null` if allocation fails.
pub inline fn alloc(self: *Self, comptime T: type) ?*T {
    const ptr = bindings.getInstance().vm.object_allocator.alloc(self) orelse return null;
    return @as(*T, @alignCast(@ptrCast(ptr)));
}

/// Frees the memory of an object. Invalid object pointer causes UB.
/// - `obj_ptr`: Pointer to the object to free.
pub inline fn free(self: *Self, obj_ptr: anytype) void {
    comptime {
        const type_info = @typeInfo(@TypeOf(obj_ptr));
        switch (type_info) {
            .pointer => |ptr| if (ptr.size == .slice) @compileError("Argument type cannot be a slice"),
            else => @compileError("Argument type must be a pointer"),
        }
    }

    const addr = @intFromPtr(obj_ptr);
    return bindings.getInstance().vm.object_allocator.free(self, addr);
}
