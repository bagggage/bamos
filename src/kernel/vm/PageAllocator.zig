//! # Page Allocator
//! Implements a buddy page allocator for managing physical pages of memory.
//! Provides functions for allocating and freeing pages, 
//! and accessing the status of the free/used physical memory.

// Copyright (C) 2024 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const boot = @import("../boot.zig");
const math = std.math;
const utils = @import("../utils.zig");
const vm = @import("../vm.zig");
const log = std.log.scoped(.PageAllocator);

const Spinlock = utils.Spinlock;

/// Represents a free memory area in the buddy allocator. 
/// It maintains a list of free nodes and a bitmap for tracking free pages.
const FreeArea = struct {
    pub const List_t = utils.SList(void);

    list: List_t = List_t{},
    /// Bitmap for tracking if neighbour pages (buddies) are
    /// at the same state `0` or not `1`.
    /// 
    /// There are two states: allocated and free.
    /// But for optimization purposes state not stored directly within the bitmap.
    /// Each bit represents the difference of states between two neighbour pages.
    bitmap: utils.Bitmap = undefined,

    pub fn format(value: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("Free list: ", .{});

        var curr_node = value.list.first;

        if (curr_node == null) {
            try writer.print("empty", .{});
            return;
        }

        try writer.print("{{ ", .{});

        while (curr_node) |node| : (curr_node = node.next) {
            try writer.print("0x{x}", .{entGetPhys(node)});

            if (node.next != null) try writer.print(", ", .{});
        }

        try writer.print(" }}", .{});
    }
};

const FreeNode = FreeArea.List_t.Node;

const max_areas = 14;

pub const max_rank = max_areas;
pub const max_alloc_pages = 1 << (max_rank - 1);

export var allocated_pages: u32 = 0;
export var total_pages: usize = 0;

var free_areas: [max_areas]FreeArea = .{FreeArea{}} ** max_areas;
var lock = Spinlock.init(.unlocked);

var is_initialized = false;

/// Initializes the page allocator by setting up memory pools and free areas.
/// Lookup the memory map from the `boot` module and initializes the free areas.
/// 
/// This function should be called only once.
pub fn init() vm.Error!void {
    const mem_map = boot.getMemMap();
    const max_pages = mem_map.maxPage() + 1;

    const bitmap_size = math.divCeil(u32, max_pages, utils.byte_size) catch unreachable;
    const bitmap_pages = math.divCeil(u32, bitmap_size, vm.page_size) catch unreachable;

    const mem_pool = boot.alloc(bitmap_pages) orelse return vm.Error.NoMemory;
    const virt_pool = vm.getVirtLma(mem_pool);

    log.warn("mem pool size: {} bytes ~ {} KB", .{bitmap_size, @as(usize, bitmap_pages) * (vm.page_size / utils.kb_size)});

    initAreas(virt_pool, bitmap_size);

    allocated_pages += bitmap_pages;
    allocated_pages += @truncate(
        (@intFromPtr(vm.kernel_end) - @intFromPtr(vm.kernel_start)) /
        vm.page_size
    );
    total_pages += allocated_pages;

    {
        const total_kb = total_pages * vm.page_size / utils.kb_size;
        log.warn("total mem: {} KB ({} MB)", .{ total_kb, total_kb / utils.kb_size });
    }

    is_initialized = true;
}

/// Allocates a linear block of physical memory of the specified rank (size).
/// 
/// - `rank`: Determines the number of pages as `2^rank`.
/// - Returns: The physical address of the allocated pages, or `null` if allocation fails.
pub fn alloc(rank: u32) ?usize {
    std.debug.assert(rank < max_rank);

    lock.lock();
    defer lock.unlock();

    var free_entry = free_areas[rank].list.popFirst();

    if (free_entry == null) {
        var temp_rank = rank + 1;

        while (temp_rank < max_areas) : (temp_rank += 1) {
            if (free_areas[temp_rank].list.first) |entry| {
                free_entry = entry;
                break;
            }
        }

        const entry = free_entry orelse return null;

        var temp_pages: u32 = @as(u32, 1) << @truncate((temp_rank - 1));
        var temp_base: u32 = entGetBase(entry);

        const node = free_areas[temp_rank].list.popFirst().?;
        free_areas[temp_rank - 1].list.prepend(node);

        clearPageBit(temp_base, temp_rank);
        setPageBit(temp_base, temp_rank - 1);

        temp_rank -= 1;
        temp_base += temp_pages;

        while (temp_rank > rank) {
            temp_rank -= 1;
            temp_pages >>= 1;

            const new_node = makeNode(temp_base);

            free_areas[temp_rank].list.prepend(new_node);
            setPageBit(temp_base, temp_rank);

            temp_base += temp_pages;
        }

        allocated_pages += @as(u32, 1) << @truncate(rank);
        return @as(usize, temp_base) * vm.page_size;
    }

    const entry = free_entry.?;
    togglePageBit(entGetBase(entry), rank);

    allocated_pages += @as(u32, 1) << @truncate(rank);
    return entGetPhys(entry);
}

/// Frees a physical memory of the specified rank (size).
/// 
/// - `base`: Physical address of the first page of a linear block returned from `alloc`.
/// - `rank`: Determines the number of pages as `2^rank`,
/// must be the same as in `alloc` call.
pub fn free(base: usize, rank: u32) void {
    std.debug.assert((base % vm.page_size) == 0 and rank < max_rank);

    var page_base: u32 = @truncate(base / vm.page_size);

    lock.lock();
    defer lock.unlock();

    defer allocated_pages -= @as(u32, 1) << @truncate(rank);

    if (getPageBit(page_base, rank) == 0 or rank == max_rank - 1) {
        const entry = makeNode(page_base);
        free_areas[rank].list.prepend(entry);

        setPageBit(page_base, rank);
        return;
    }

    var temp_rank = rank;

    while (getPageBit(page_base, temp_rank) != 0 and temp_rank < max_rank - 1) {
        const rank_pages = @as(u32, 1) << @truncate(temp_rank);

        var combine_base = page_base;
        var buddy_base = page_base;

        if (page_base % (rank_pages << 1) == 0) {
            buddy_base += rank_pages;
        } else {
            buddy_base -= rank_pages;
            combine_base = buddy_base;
        }

        clearPageBit(buddy_base, temp_rank);

        const list = &free_areas[temp_rank].list;
        const entry = getNode(buddy_base);

        list.remove(entry);

        page_base = combine_base;
        temp_rank += 1;
    }

    const new_node = makeNode(page_base);
    free_areas[temp_rank].list.prepend(new_node);

    setPageBit(page_base, temp_rank);
}

/// Checks if the page allocator has been initialized.
///
/// @noexport
pub inline fn isInitialized() bool {
    return is_initialized;
}

/// Returns the total number of pages managed by the allocator.
pub inline fn getTotalPages() usize {
    return total_pages;
}

/// Returns the number of pages currently allocated.
pub inline fn getAllocatedPages() u32 {
    return allocated_pages;
}

/// Initializes the free areas and bitmap based on the memory map.
/// Sets up the bitmaps and populates the free areas with initial free nodes.
fn initAreas(bitmap_base: usize, bitmap_size: u32) void {
    const mem_map = boot.getMemMap();

    var curr_bitmap_base = bitmap_base;
    var curr_bitmap_size = math.divCeil(u32, bitmap_size, 2) catch unreachable;

    // Initialize bitmaps
    for (0..max_areas) |i| {
        const bits: [*]u8 = @ptrFromInt(curr_bitmap_base);
        free_areas[i].bitmap = utils.Bitmap.init(bits[0..curr_bitmap_size], true);

        curr_bitmap_base += curr_bitmap_size;
        curr_bitmap_size = @max((curr_bitmap_size >> 1) + (curr_bitmap_size & 1), 1);
    }

    // Fill free lists
    for (mem_map.entries[0..mem_map.len]) |*entry| {
        if (entry.type != .free) continue;

        pushFreeEntry(entry);
    }
}

/// Adds a free memory entry to the appropriate free area list.
/// Splits the memory if necessary to make all pages blocks aligned to
/// it's size and updates the bitmap.
fn pushFreeEntry(entry: *const boot.MemMap.Entry) void {
    total_pages += entry.pages;

    var temp_base = entry.base;
    var temp_pages = entry.pages;

    while (temp_pages != 0) {
        var temp_rank: u32 = math.log2_int(u32, temp_pages);

        if (temp_rank >= max_rank) temp_rank = max_rank - 1;

        var rank_pages_num: u32 = @as(u32, 1) << @truncate(temp_rank);

        while ((temp_base % rank_pages_num) != 0) {
            temp_rank -= 1;
            rank_pages_num >>= 1;
        }

        const node = makeNode(temp_base);
        free_areas[temp_rank].list.prepend(node);

        temp_base += rank_pages_num;
        temp_pages -= rank_pages_num;
    }
}

/// Returns `FreeNode` related to the physical pages block located
/// by physical base.
/// 
/// - `phys_base`: Index of the first physical page in a linear block.
inline fn getNode(phys_base: u32) *FreeNode {
    return makeNode(phys_base);
}

/// Returns `FreeNode` related to the physical pages block located
/// by physical base.
/// 
/// - `phys_base`: Index of the first physical page in a linear block.
inline fn makeNode(phys_base: u32) *FreeNode {
    const phys_addr = @as(usize, phys_base) * vm.page_size;
    const node_addr = vm.getVirtLma(phys_addr);
    const node: *FreeNode = @ptrFromInt(node_addr);

    return node;
}

/// Gets the base address of a free node.
inline fn entGetBase(node: *FreeNode) u32 {
    return @truncate(entGetPhys(node) / vm.page_size);
}

/// Gets the physical address of a free node.
///
/// @export
inline fn entGetPhys(node: *FreeNode) usize {
    return vm.getPhysLma(@intFromPtr(node));
}

inline fn clearPageBit(base: u32, rank: u32) void {
    free_areas[rank].bitmap.clear(base >> @truncate(1 + rank));
}

inline fn setPageBit(base: u32, rank: u32) void {
    free_areas[rank].bitmap.set(base >> @truncate(1 + rank));
}

inline fn getPageBit(base: u32, rank: u32) u8 {
    return free_areas[rank].bitmap.get(base >> @truncate(1 + rank));
}

inline fn togglePageBit(base: u32, rank: u32) void {
    free_areas[rank].bitmap.toggle(base >> @truncate(1 + rank));
}
