//! # General Purpose Allocator
//! 
//! The `gpa` is a versatile memory allocator
//! that supports random size allocations.
//! 
//! It is designed to work within the constraints of a virtual memory system
//! and provides a unified interface for handling different sizes of memory allocations.
//! 
//! Maximum allocation size is limited by `vm.PageAllocator.max_alloc_pages`, to get
//! max size in bytes just multiply it by `vm.page_size`. Minimum allocation size is 1 byte,
//! but the real minimal size of the memory region to be allocated is defined as `min_size`.
//! 
//! This allocator have some overhead compare to `vm.ObjectAllocator` or `vm.PageAllocator`.
//! It is **better** to avoid using of the general purpose allocator if possible.
//! However, in cases where the block size is not always known in advance, or in cases of rare allocations,
//! such as 1-20 objects of small size (less than 256 bytes or so), this allocator can be very useful.
//! It can also be effective for automatically tracking larger allocations, such as for buffers larger than 1 KB.
//! But, if you are using 1-3 buffers that you can handle manually, then it is better to use the page allocator.
//!
//! ## Implementation details:
//!
//! Gpa is build on top of the pool of `vm.ObjectAllocator`s and `vm.PageAllocator`.
//! 
//! There are two strategy:
//! - For small objects/memory blocks (with the size less or equal `max_small_size`).
//! - For larger memory regions (anything larger than `max_small_size`).
//!
//! Small allocations is managed by the pool of `vm.ObjectAllocator`s, where each allocator is determined
//! for the specific object size. The number of allocators is defined in `oma_pool_len`. The object sizes
//! specified for allocators in the pool are guaranteed to be power of two. This also means that
//! calling `alloc` with a size that is not power of two results in fragmentation,since the provided size
//! will be rounded up to the nearest power of two.
//! 
//! Large allocations is implemented via `vm.PageAllocator`, a virtual DMA zone is used for the fast
//! convertion from physical to virtual address and back. A binary tree is used to manage allocations
//! and store the number of allocated pages for future deallocation.

// Copyright (C) 2024 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const bindings = @import("../bindings.zig");

const vm = @import("../vm.zig");

pub const max_alloc_size = vm.PageAllocator.max_alloc_pages * vm.page_size;

/// High-level general purpose allocator interface.
/// Implements `std.mem.Allocator` interface for use with Zig Standard Library `std`.
pub inline fn getStdAllocator() std.mem.Allocator {
    return bindings.getInstance().vm.gpa.getStdAllocator();
}

pub inline fn create(comptime T: type) ?*T {
    return @ptrCast(@alignCast(alloc(@sizeOf(T))));
}

pub inline fn allocMany(comptime T: type, n: usize) ?[]T {
    const size = @sizeOf(T) * n;
    const ptr: [*]T = @ptrCast(@alignCast(alloc(size) orelse return null));
    return ptr[0..n];
}

/// Allocates a block of memory of the specified `size`.
/// - `size`: The size of memory to allocate. Must be great than zero.
/// Maximum size of the memory block is limited by `vm.PageAllocator.max_alloc_pages`.
/// - Returns: A pointer to the allocated memory block,
/// or `null` if the allocation fails.
pub inline fn alloc(size: usize) ?*anyopaque {
    return bindings.getInstance().vm.gpa.alloc(size);
}

/// Frees a previously allocated block of memory pointed to by `mem`.
/// - `mem`: A pointer to the memory block to free, or `null` (which is ignored).
pub inline fn free(mem: ?*anyopaque) void {
    bindings.getInstance().vm.gpa.free(mem);
}
