//! # Virtual memory region
//! 
//! This is growable memory region that is lineary mapped into
//! virtual memory. But may consist of different physical regions.
//! 
//! The size and base address is aligned to `vm.page_size`

const std = @import("std");

const utils = @import("../utils.zig");
const vm = @import("../vm.zig");

pub const Page = packed struct {
    pub const List = utils.SList(Page);
    pub const Node = List.Node;

    pub const alloc_config: vm.obj.AllocatorConfig = .{
        .allocator = .safe_oma,
        .capacity = 256,
        .wrapper = .listNode(Node)
    };

    pub const max_index = std.math.maxInt(u24);

    base: u32,
    idx: u24 = 0,
    rank: u8 = 0,

    comptime {
        std.debug.assert(@sizeOf(Page) == 8);
        // Make sure that `base` can store any physical page index.
        std.debug.assert(vm.max_phys_pages <= std.math.maxInt(u32));
    }

    pub inline fn getOffset(self: Page) usize {
        return @as(usize, self.idx) * vm.page_size;
    }

    pub inline fn getPhysBase(self: Page) usize {
        return @as(usize, self.base) * vm.page_size;
    }

    pub inline fn pagesNum(self: *const Page) u32 {
        return @as(u32, 1) << @truncate(self.rank);
    }

    pub inline fn asNode(self: *Page) *Node {
        return @fieldParentPtr("data", self);
    }

    pub inline fn unmap(self: *Page, base: usize, pt: *vm.PageTable) void {
        vm.unmap(base + self.getOffset(), self.pagesNum(), pt);
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
        freePages(n, free_phys);
    }
}

pub fn unmap(self: *Self, page_table: *vm.PageTable, free_phys: bool) void {
    var node = self.page_list.first;

    while (node) |n| {
        n.data.unmap(self.base, page_table);

        node = n.next;
        freePages(n, free_phys);
    }

    self.page_list.first = null;
}

pub fn growUp(self: *Self, rank: u8, map_flags: vm.MapFlags) !void {
    const pages = @as(u32, 1) << @truncate(rank);
    const pages_num = self.pagesNum();
    if (pages_num > Page.max_index) return error.MaxSize;

    const node = allocPages(rank) orelse return error.NoMemory;
    errdefer freePages(node, true);

    const base = self.base + (pages_num * vm.page_size);
    try map(base, node, pages, map_flags);

    node.data.idx = @truncate(pages_num);
    self.page_list.prepend(node);
}

pub fn growDown(self: *Self, rank: u8, map_flags: vm.MapFlags) !void {
    const pages = @as(u32, 1) << @truncate(rank);
    const pages_num = self.pagesNum();
    if (pages_num > Page.max_index) return error.MaxSize;

    const node = allocPages(rank) orelse return error.NoMemory;
    errdefer freePages(node, true);

    const new_base = self.base - (pages * vm.page_size);
    try map(new_base, node, pages, map_flags);

    node.data.idx = @truncate(pages_num);
    self.page_list.prepend(node);
    self.base = new_base;
}

pub fn shrinkTop(self: *Self) ?u8 {
    const node = self.page_list.popFirst() orelse return null;
    const rank = node.data.rank;

    freePages(node, true);
    return rank;
}

pub fn shrinkBottom(self: *Self) ?u8 {
    const node = self.page_list.popFirst() orelse return null;
    const rank = node.data.rank;

    const new_base = self.base + (node.data.pagesNum() * vm.page_size);
    freePages(node, true);

    self.base = new_base;
    return rank;
}

pub inline fn size(self: *const Self) usize {
    return self.pagesNum() * vm.page_size;
}

pub fn pagesNum(self: *const Self) u32 {
    if (self.page_list.first) |n| {
        @branchHint(.likely);
        return n.data.pagesNum() + n.data.idx;
    }

    return 0;
}

pub fn getPage(self: *const Self, idx: u32) ?*Page {
    var node = self.page_list.first;

    while (node) |n| : (node = n.next) {
        const begin: u32 = n.data.idx;
        const end = begin + n.data.pagesNum();

        if (begin == idx or idx < end) return &n.data;
    }

    return null;
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
    return utils.alignDown(usize, self.getTop() - 1, alignment);
}

pub fn format(
    self: *const Self,
    comptime _: []const u8,
    _: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    try writer.print("0x{x}-0x{x}", .{self.base, self.base + self.size()});
}

fn map(
    base: usize, node: *Page.Node,
    pages: u32, map_flags: vm.MapFlags
) !void {
    if (map_flags.none) return;

    try vm.mmap(
        base,
        node.data.getPhysBase(),
        pages,
        map_flags,
        vm.getPt(),
    );
}

fn allocPages(rank: u8) ?*Page.Node {
    const page = vm.obj.new(Page) orelse return null;
    const node = page.asNode();

    const phys = vm.PageAllocator.alloc(rank) orelse {
        vm.obj.free(Page, page);
        return null;
    };

    node.data = .{
        .rank = rank,
        .base = @truncate(phys / vm.page_size)
    };

    return node;
}

inline fn freePages(node: *Page.Node, free_phys: bool) void {
    if (free_phys) {
        vm.PageAllocator.free(
            node.data.getPhysBase(),
            node.data.rank
        );
    }

    vm.obj.free(Page, &node.data);
}