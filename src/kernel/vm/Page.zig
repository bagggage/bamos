//! # Physical pages region structure

// Copyright (C) 2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const vm = @import("../vm.zig");

const Self = @This();

pub const Attributes = packed struct {
    mapped: bool = false,
    writeable: bool = false,
    accessed: bool = false,
    dirty: bool = false,
};

/// Region dimension
pub const Dimension = packed struct {
    pub const max_index = std.math.maxInt(u24);

    idx: u24 = 0,
    rank: u8 = 0
};

pub const alloc_config: vm.auto.Config = .{
    .allocator = .oma,
    .capacity = 8192
};

pub const List = std.SinglyLinkedList;
pub const Node = List.Node;

base: u32,
dim: Dimension = .{},
node: Node = .{},

comptime {
    std.debug.assert(@sizeOf(Self) == 16);
    // Make sure that `base` can store any physical page index.
    std.debug.assert(vm.max_phys_pages <= std.math.maxInt(u32));
}

pub fn new(page_offset: u32, rank: u8) ?*Self {
    const page = vm.auto.alloc(Self) orelse return null;
    const phys = vm.PageAllocator.alloc(rank) orelse {
        vm.auto.free(Self, page);
        return null;
    };

    page.* = .{
        .dim = .{ .idx = @truncate(page_offset), .rank = rank },
        .base = @truncate(phys / vm.page_size)
    };
    return page;
}

pub inline fn delete(self: *Self) void {
    vm.PageAllocator.free(self.getPhysBase(), self.dim.rank);
    vm.auto.free(Self, self);
}

pub inline fn map(self: Self, pt: *vm.PageTable, base: usize, map_flags: vm.MapFlags) vm.Error!void {
    try pt.map(base + self.getOffset(), self.getPhysBase(), vm.rankToPages(self.dim.rank), map_flags);
}

pub inline fn unmap(self: *Self, pt: *vm.PageTable, base: usize) void {
    pt.unmap(base + self.getOffset(), self.pagesNum());
}

pub inline fn getOffset(self: Self) usize {
    return @as(usize, self.dim.idx) * vm.page_size;
}

pub inline fn getPhysBase(self: Self) usize {
    return @as(usize, self.base) * vm.page_size;
}

pub inline fn pagesNum(self: Self) u32 {
    return vm.rankToPages(self.dim.rank);
}

pub inline fn size(self: Self) usize {
    return vm.rankToBytes(self.dim.rank);
}

pub inline fn fromNode(node: *Node) *Self {
    return @fieldParentPtr("node", node);
}
