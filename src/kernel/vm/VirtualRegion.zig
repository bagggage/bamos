//! # Virtual memory region
//! 
//! This is growable memory region that is lineary mapped into
//! virtual memory. But may consist of different physical regions.
//! 
//! The size and base address is aligned to `vm.page_size`

const std = @import("std");

const utils = @import("../utils.zig");
const vm = @import("../vm.zig");

const PageList = utils.SList(Page);
const PageNode = PageList.Node;

const Page = packed struct {
    base: u32,
    idx: u24 = 0,
    rank: u8 = 0,

    pub inline fn getPhysBase(self: Page) usize {
        return @as(usize, self.base) * vm.page_size;
    }

    pub inline fn pagesNum(self: *const Page) u32 {
        return @as(u32, 1) << @truncate(self.rank);
    }

    comptime {
        std.debug.assert(@sizeOf(Page) == 8);
    }
};

const Self = @This();

var page_oma = vm.SafeOma(PageNode).init(128);

/// Virtual base address
base: usize,

/// Physical pages list
page_list: PageList = .{},

pub fn init(virt: usize) Self {
    // Check alignment
    std.debug.assert((virt % vm.page_size) == 0);

    return .{ .base = virt };
}

pub fn deinit(self: *Self) void {
    var node = self.page_list.first;

    while (node) |n| {
        node = n.next;
        freePages(n);
    }
}

pub fn growUp(self: *Self, rank: u8, map_flags: vm.MapFlags) !void {
    const node = allocPages(rank) orelse return error.NoMemory;
    errdefer freePages(node);

    const pages = @as(u24, 1) << @truncate(rank);
    const base = self.base + self.size();

    try self.map(base, node, pages, map_flags);
}

pub fn growDown(self: *Self, rank: u8, map_flags: vm.MapFlags) !void {
    const node = allocPages(rank) orelse return error.NoMemory;
    errdefer freePages(node);

    const pages = @as(u24, 1) << @truncate(rank);
    const base = self.base - (pages * vm.page_size);

    try self.map(base, node, pages, map_flags);
    self.base = base;
}

pub inline fn shrink(self: *Self) ?u8 {
    freePages(self.page_list.popFirst());
}

pub inline fn size(self: *const Self) usize {
    return self.pagesNum() * vm.page_size;
}

pub inline fn pagesNum(self: *const Self) u32 {
    return if (self.page_list.first) |n| n.data.idx else 0;
}

pub fn getPage(self: *const Self, idx: u32) ?*Page {
    var node = self.page_list.first;

    while (node) |n| : (node = n.next) {
        const begin = n.data.idx;
        const end = begin + n.data.pagesNum();

        if (begin == idx or idx < end) return &n.data;
    }

    return null;
}

pub fn getPhys(self: *const Self, offset: usize) ?usize {
    const page_idx: u32 = @truncate(offset / vm.page_size);
    const page = self.getPage(offset / vm.page_size) orelse return null;

    const page_base = page.getPhysBase() + ((page_idx - page.idx) * vm.page_size);

    return page_base + (offset % vm.page_size); 
}

pub inline fn getVirtLma(self: *const Self, offset: usize) ?usize {
    return vm.getVirtLma(self.getPhys(offset) orelse return null);
}

pub fn getTopAligned(self: *const Self, comptime alignment: u5) usize {
    const top = self.base + self.size();
    return utils.alignDown(usize, top - 1, alignment);
}

pub fn format(
    self: *const Self,
    comptime _: []const u8,
    _: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    try writer.print("0x{x}-0x{x}", .{self.base,self.base + self.size()});
}

fn map(
    self: *Self, base: usize,
    node: *PageNode, pages: u24, map_flags: vm.MapFlags
) !void {
    try vm.mmap(
        base,
        node.data.getPhysBase(),
        pages,
        map_flags,
        vm.getPt(),
    );

    node.data.idx = pages + if (self.page_list.first) |n| n.data.idx else 0;
    self.page_list.prepend(node);
}

fn allocPages(rank: u8) ?*PageNode {
    const node = page_oma.alloc() orelse return null;
    const phys = vm.PageAllocator.alloc(rank) orelse {
        page_oma.free(node);
        return null;
    };

    node.data = .{
        .rank = rank,
        .base = @truncate(phys / vm.page_size)
    };

    return node;
}

fn freePages(node: *PageNode) void {
    vm.PageAllocator.free(node.data.getPhysBase(), node.data.rank);
    page_oma.free(node);
}