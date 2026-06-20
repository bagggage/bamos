//! # Page Allocator
//! 
//! Implements a buddy page allocator for managing physical pages of memory.
//! Provides functions for allocating and freeing pages, 
//! and accessing the status of the free/used physical memory.

// Copyright (C) 2024-2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const bindings = @import("../bindings.zig");
const lib = @import("../lib.zig");

const List = std.SinglyLinkedList;
const Node = List.Node;

/// Represents a free memory area in the buddy allocator. 
/// It maintains a list of free nodes and a bitmap for tracking free pages.
const FreeArea = struct {
    list: List = .{},
    /// Bitmap for tracking if neighbour pages (buddies) are
    /// at the same state `0` or not `1`.
    /// 
    /// There are two states: allocated and free.
    /// But for optimization purposes state not stored directly within the bitmap.
    /// Each bit represents the difference of states between two neighbour pages.
    bitmap: lib.Bitmap = .{},
};

const max_areas = 14;

pub const max_rank = max_areas;
pub const max_alloc_pages = 1 << (max_rank - 1);

extern var allocated_pages: u32;
extern var total_pages: usize;

/// Allocates a linear block of physical memory of the specified rank (size).
/// - `rank`: Determines the number of pages as `2^rank`.
/// - Returns: The physical address of the allocated pages, or `null` if allocation fails.
pub inline fn alloc(rank: u8) ?usize {
    return bindings.getInstance().vm.page_allocator.alloc(rank);
}

/// Frees a physical memory of the specified rank (size).
/// - `base`: Physical address of the first page of a linear block returned from `alloc`.
/// - `rank`: Determines the number of pages as `2^rank`,
/// must be the same as in `alloc` call.
pub inline fn free(base: usize, rank: u8) void {
    bindings.getInstance().vm.page_allocator.free(base, rank);
}

/// Returns the total number of pages managed by the allocator.
pub inline fn getTotalPages() usize {
    return total_pages;
}

/// Returns the number of pages currently allocated.
pub inline fn getAllocatedPages() u32 {
    return allocated_pages;
}
