//! # Universal memory allocator
//! 
//! The `UniversalAllocator` is a versatile and efficient memory allocator
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
//! Universal allocator is build on top of the pool of `vm.ObjectAllocator`s and `vm.PageAllocator`.
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

const lib = @import("../lib.zig");
const vm = @import("../vm.zig");

/// The maximum size for small memory allocations, defined as half of the 
/// virtual memory page size.
const max_small_size = vm.page_size / 2;
/// The minimum size for any allocation.
const min_size = 16;

/// The number of object allocators in the small object allocator pool, 
const oma_pool_len = std.math.log2(max_small_size) - std.math.log2(min_size);
/// The minimum number of objects that the object allocators can hold.
const oma_min_capacity = 16;

/// Represents a large memory block allocation.
const HugeFrame = struct {
    base: u32 = undefined,
    rank: u8 = undefined,

    pub fn cmp(lhs: *const HugeFrame, rhs: *const HugeFrame) std.math.Order {
        if (lhs.base == rhs.base) { return .eq; }
        else if (lhs.base < rhs.base) { return .lt; }

        return .gt;
    }
};

const HugeTree = lib.BinaryTree(HugeFrame, HugeFrame.cmp);
const HugeNode = HugeTree.Node;

/// A fixed-size array of object allocators (`vm.ObjectAllocator`),
/// used for managing small memory blocks.
var oma_pool: [oma_pool_len]vm.ObjectAllocator = initOmaPool();

/// An object allocator dedicated to managing nodes within the `HugeTree`.
var huge_oma: vm.ObjectAllocator = .init(HugeNode);
/// The binary tree that manages all large memory block allocations.
var huge_alloc_tree: HugeTree = .{};

/// Allocates a block of memory of the specified `size`.
/// 
/// - `size`: The size of memory to allocate. Must be great than zero.
/// Maximum size of the memory block is limited by `vm.PageAllocator.max_alloc_pages`.
/// - Returns: A pointer to the allocated memory block,
/// or `null` if the allocation fails.
pub inline fn alloc(size: usize) ?*anyopaque {
    std.debug.assert(size > 0 and size < (vm.PageAllocator.max_alloc_pages * vm.page_size));
    return if (size <= max_small_size) allocSmall(@truncate(size)) else allocHuge(@truncate(size));
}

/// Frees a previously allocated block of memory pointed to by `mem`.
/// 
/// - `mem`: A pointer to the memory block to free, or `null` (which is ignored).
pub fn free(mem: ?*anyopaque) void {
    if (mem == null) return;

    const addr: usize = @intFromPtr(mem.?);
    const phys = vm.getPhysLma(addr);

    // Try to dealloc as huge region
    if ((phys % vm.page_size) == 0) {
        const base: u32 = @truncate(phys / vm.page_size);

        if (huge_alloc_tree.remove(HugeFrame{.base = base})) |node| {
            vm.PageAllocator.free(phys, node.data.rank);
            huge_oma.free(node);

            return;
        }
    }

    // Dealloc small object
    for (oma_pool[0..]) |*oma| {
        if (oma.contains(addr)) |arena| {
            oma.freeRaw(arena, addr);
            return;
        }
    }

    // The memory region is not managed by the allocator
    // or address is damaged.
    unreachable;
}

/// Allocates a small block of memory of the specified `size` using the appropriate object 
/// allocator from the `oma_pool`.
/// 
/// - `size`: The size of the small memory block to allocate.
/// - Returns: A pointer to the allocated memory block, or `null` if the allocation fails.
fn allocSmall(size: u32) ?*anyopaque {
    const log2 = std.math.log2_int_ceil(u32, size);
    const rank = if (size > min_size) log2 - comptime std.math.log2(min_size) else 0;

    return oma_pool[rank].alloc(anyopaque);
}

/// Allocates a large block of memory of the specified `size`.
/// 
/// This involves allocating memory pages and managing the allocation
/// within the `huge_alloc_tree`.
/// 
/// - `size`: The size of the large memory block to allocate.
/// - Returns: A pointer to the allocated memory block, or `null` if the allocation fails.
fn allocHuge(size: u32) ?*anyopaque {
    const pages = std.math.divCeil(u32, size, vm.page_size) catch unreachable;

    if (pages > vm.PageAllocator.max_alloc_pages) return null;

    const rank = std.math.log2_int_ceil(u32, pages);
    const phys = vm.PageAllocator.alloc(rank) orelse return null;

    const node = huge_oma.alloc(HugeNode) orelse {
        vm.PageAllocator.free(phys, rank);
        return null;
    };
    node.* = HugeNode.init(.{
        .base = @truncate(phys / vm.page_size),
        .rank = rank
    });

    huge_alloc_tree.insert(node);

    return @as(*anyopaque, @ptrFromInt(vm.getVirtLma(phys)));
}

/// Initializes the pool of small object allocators (`oma_pool`) based on the size range 
/// from `min_size` to `max_small_size`.
/// 
/// This function is called only once in compile time.
/// 
/// - Returns: A fixed-size array of initialized `vm.ObjectAllocator` instances.
fn initOmaPool() [oma_pool_len]vm.ObjectAllocator {
    var result: [oma_pool_len]vm.ObjectAllocator = undefined;

    const min_rank = std.math.log2(min_size);
    const max_rank = std.math.log2(max_small_size);

    inline for (min_rank..max_rank) |rank| {
        const size = @as(u32, 1) << @truncate(rank);
        const i = rank - min_rank;

        const pages_num = std.math.divCeil(u32, size * oma_min_capacity, vm.page_size) catch unreachable;
        const pages = @as(u32, 1) << @truncate(std.math.log2_int_ceil(u32, pages_num));

        result[i] = .initSized(size, pages);
    }

    return result;
}
