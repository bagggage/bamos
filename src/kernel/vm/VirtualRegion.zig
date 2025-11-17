//! # Virtual memory region
//! 
//! This is growable memory region that is lineary mapped into
//! virtual memory. But may consist of different physical regions.
//! 
//! The size and base address is aligned to `vm.page_size`

// Copyright (C) 2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const lib = @import("../lib.zig");
const vm = @import("../vm.zig");

pub const Page = struct {
    pub const alloc_config: vm.auto.Config = .{
        .allocator = .oma,
        .capacity = 256
    };

    pub const List = std.SinglyLinkedList;
    pub const Node = List.Node;

    const Dim = packed struct {
        const max_index = std.math.maxInt(u24);

        idx: u24 = 0,
        rank: u8 = 0
    };

    base: u32,
    dim: Dim = .{},
    node: Node = .{},

    comptime {
        std.debug.assert(@sizeOf(Page) == 16);
        // Make sure that `base` can store any physical page index.
        std.debug.assert(vm.max_phys_pages <= std.math.maxInt(u32));
    }

    pub inline fn getOffset(self: Page) usize {
        return @as(usize, self.dim.idx) * vm.page_size;
    }

    pub inline fn getPhysBase(self: Page) usize {
        return @as(usize, self.base) * vm.page_size;
    }

    pub inline fn pagesNum(self: *const Page) u32 {
        return @as(u32, 1) << @truncate(self.dim.rank);
    }

    pub inline fn fromNode(node: *Node) *Page {
        return @fieldParentPtr("node", node);
    }

    pub inline fn unmap(self: *Page, base: usize, pt: *vm.PageTable) void {
        pt.unmap(base + self.getOffset(), self.pagesNum());
    }
};

const Self = @This();

/// Virtual base address
base: usize,

/// Physical pages list
page_list: Page.List = .{},

pub fn init(virt: usize) Self {
    // Check alignment
    std.debug.assert((virt % vm.page_size) == 0);

    return .{ .base = virt };
}

pub fn deinit(self: *Self, free_phys: bool) void {
    var node = self.page_list.first;

    while (node) |n| {
        node = n.next;
        const page = Page.fromNode(n);
        freePages(page, free_phys);
    }
}

pub fn unmap(self: *Self, page_table: *vm.PageTable, free_phys: bool) void {
    var node = self.page_list.first;

    while (node) |n| {
        const page = Page.fromNode(n);
        page.unmap(self.base, page_table);

        node = n.next;
        freePages(page, free_phys);
    }

    self.page_list.first = null;
}

pub fn growUp(self: *Self, rank: u8, map_flags: vm.MapFlags) !void {
    const pages = @as(u32, 1) << @truncate(rank);
    const pages_num = self.pagesNum();
    if (pages_num > Page.Dim.max_index) return error.MaxSize;

    const page = allocPages(rank) orelse return error.NoMemory;
    errdefer freePages(page, true);

    const base = self.base + (pages_num * vm.page_size);
    try map(base, page, pages, map_flags);

    page.dim.idx = @truncate(pages_num);
    self.page_list.prepend(&page.node);
}

pub fn growDown(self: *Self, rank: u8, map_flags: vm.MapFlags) !void {
    const pages = @as(u32, 1) << @truncate(rank);
    const pages_num = self.pagesNum();
    if (pages_num > Page.Dim.max_index) return error.MaxSize;

    const page = allocPages(rank) orelse return error.NoMemory;
    errdefer freePages(page, true);

    const new_base = self.base - (pages * vm.page_size);
    try map(new_base, page, pages, map_flags);

    page.dim.idx = @truncate(pages_num);
    self.page_list.prepend(&page.node);
    self.base = new_base;
}

pub fn insertNewPage(
    self: *Self, page_offset: u32,
    rank: u8, map_flags: vm.MapFlags
) !void {
    const page = allocPages(rank) orelse return error.NoMemory;
    errdefer freePages(page, true);

    const page_base = self.base + (page_offset * vm.page_size);
    const pages = @as(u32, 1) << @truncate(rank);

    try vm.getPageTable().map(page_base, page.getPhysBase(), pages, map_flags);

    page.dim.idx = @truncate(page_offset);
    self.page_list.prepend(&page.node);
}

pub fn shrinkTop(self: *Self) ?u8 {
    const node = self.page_list.popFirst() orelse return null;
    const page = Page.fromNode(node);
    const rank = page.dim.rank;

    freePages(page, true);
    return rank;
}

pub fn shrinkBottom(self: *Self) ?u8 {
    const node = self.page_list.popFirst() orelse return null;
    const page = Page.fromNode(node);
    const rank = page.dim.rank;

    const new_base = self.base + (page.pagesNum() * vm.page_size);
    freePages(page, true);

    self.base = new_base;
    return rank;
}

pub inline fn size(self: *const Self) usize {
    return self.pagesNum() * vm.page_size;
}

pub fn pagesNum(self: *const Self) u32 {
    if (self.page_list.first) |n| {
        @branchHint(.likely);
        const page = Page.fromNode(n);
        return page.pagesNum() + page.dim.idx;
    }

    return 0;
}

pub fn getPage(self: *const Self, idx: u32) ?*Page {
    var node = self.page_list.first;

    while (node) |n| : (node = n.next) {
        const page = Page.fromNode(n);
        const begin: u32 = page.dim.idx;
        const end = begin + page.pagesNum();

        if (begin == idx or idx < end) return page;
    }

    return null;
}

pub inline fn getLastPage(self: *const Self) ?*Page {
    return Page.fromNode(self.page_list.first orelse return null);
}

pub fn getPhys(self: *const Self, offset: usize) ?usize {
    const page_idx: u32 = @truncate(offset / vm.page_size);
    const page = self.getPage(page_idx) orelse return null;

    const page_offset = (page_idx - page.idx) * vm.page_size;
    const page_base = page.getPhysBase() + page_offset;

    return page_base + (offset % vm.page_size); 
}

pub inline fn getVirtLma(self: *const Self, offset: usize) ?usize {
    return vm.getVirtLma(self.getPhys(offset) orelse return null);
}

pub fn getTop(self: *const Self) usize {
    return self.base + self.size();
}

pub fn getTopAligned(self: *const Self, comptime alignment: u5) usize {
    return lib.misc.alignDown(usize, self.getTop() - 1, alignment);
}

pub fn format(self: *const Self, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.print("0x{x}-0x{x}", .{self.base, self.base + self.size()});
}

fn map(base: usize, page: *Page, pages: u32, map_flags: vm.MapFlags) !void {
    if (map_flags.none) return;
    try vm.getPageTable().map(base, page.getPhysBase(), pages, map_flags);
}

fn allocPages(rank: u8) ?*Page {
    const page = vm.auto.alloc(Page) orelse return null;
    const phys = vm.PageAllocator.alloc(rank) orelse {
        vm.auto.free(Page, page);
        return null;
    };

    page.* = .{
        .dim = .{ .rank = rank },
        .base = @truncate(phys / vm.page_size)
    };
    return page;
}

inline fn freePages(page: *Page, free_phys: bool) void {
    if (free_phys) {
        vm.PageAllocator.free(page.getPhysBase(), page.dim.rank);
    }

    vm.auto.free(Page, page);
}