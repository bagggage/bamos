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

const Self = @This();

/// Virtual base address
base: usize,

/// Physical pages list
page_list: vm.Page.List = .{},

pub fn init(virt: usize) Self {
    // Check alignment
    std.debug.assert((virt % vm.page_size) == 0);

    return .{ .base = virt };
}

pub fn deinit(self: *Self) void {
    var node = self.page_list.first;
    defer self.page_list.first = null;

    while (node) |n| {
        node = n.next;
        const page = vm.Page.fromNode(n);
        page.delete();
    }
}

pub fn growUp(self: *Self, rank: u8, map_flags: vm.MapFlags) !void {
    const pages = @as(u32, 1) << @truncate(rank);
    const pages_num = self.pagesNum();
    if (pages_num > vm.Page.Dimension.max_index) return error.MaxSize;

    const page = vm.Page.new(pages_num, rank) orelse return error.NoMemory;
    errdefer page.delete();

    const base = self.base + (pages_num * vm.page_size);
    try map(base, page, pages, map_flags);

    self.page_list.prepend(&page.node);
}

pub fn growDown(self: *Self, rank: u8, map_flags: vm.MapFlags) !void {
    const pages = @as(u32, 1) << @truncate(rank);
    const pages_num = self.pagesNum();
    if (pages_num > vm.Page.Dimension.max_index) return error.MaxSize;

    const page = vm.Page.new(pages_num, rank) orelse return error.NoMemory;
    errdefer page.delete();

    const new_base = self.base - (pages * vm.page_size);
    try map(new_base, page, pages, map_flags);

    self.page_list.prepend(&page.node);
    self.base = new_base;
}

pub fn shrinkTop(self: *Self) ?u8 {
    const page = self.detachLastPage() orelse return null;
    const rank = page.dim.rank;

    page.delete();
    return rank;
}

pub fn shrinkBottom(self: *Self) ?u8 {
    const page = self.detachLastPage() orelse return null;
    const rank = page.dim.rank;

    const new_base = self.base + (page.pagesNum() * vm.page_size);
    self.base = new_base;

    page.delete();
    return rank;
}

pub inline fn attachPage(self: *Self, page: *vm.Page) void {
    self.page_list.prepend(&page.node);
}

pub inline fn detachLastPage(self: *Self) ?*vm.Page {
    return vm.Page.fromNode(self.page_list.popFirst() orelse return null);
}

pub inline fn unmap(self: *Self) void {
    vm.getRootPt().unmap(self.base, self.pagesNum());
}

pub fn getPage(self: *const Self, idx: u32) ?*vm.Page {
    var node = self.page_list.first;
    while (node) |n| : (node = n.next) {
        const page = vm.Page.fromNode(n);
        const begin: u32 = page.dim.idx;
        const end = begin + page.pagesNum();

        if (idx >= begin and idx < end) return page;
    }

    return null;
}

pub inline fn getLastPage(self: *const Self) ?*vm.Page {
    return vm.Page.fromNode(self.page_list.first orelse return null);
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

pub inline fn size(self: *const Self) usize {
    return self.pagesNum() * vm.page_size;
}

pub fn pagesNum(self: *const Self) u32 {
    if (self.page_list.first) |n| {
        @branchHint(.likely);
        const page = vm.Page.fromNode(n);
        return page.pagesNum() + page.dim.idx;
    }

    return 0;
}

pub fn format(self: *const Self, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.print("0x{x}-0x{x}", .{self.base, self.base + self.size()});
}

fn map(base: usize, page: *vm.Page, pages: u32, map_flags: vm.MapFlags) !void {
    if (map_flags.none) return;
    try vm.getRootPt().map(base, page.getPhysBase(), pages, map_flags);
}
