//! # Heap

// Copyright (C) 2024 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const utils = @import("../utils.zig");
const vm = @import("../vm.zig");

const Self = @This();
const Range = struct {
    pub const alloc_config: vm.obj.AllocatorConfig = .{
        .allocator = .oma
    };

    const List = utils.SList;
    const Node = List.Node;

    base: usize = undefined,
    pages: u32 = undefined,

    node: Node = .{},

    inline fn top(self: *const Range) usize {
        return self.base + (self.pages * vm.page_size);
    }

    inline fn fromNode(node: *Node) *Range {
        return @fieldParentPtr("node", node);
    }
};

base: usize = undefined,
top: usize = undefined,

free_list: Range.List = .{},

pub inline fn init(base: usize) Self {
    return Self{ .base = base, .top = base };
}

pub fn reserve(self: *Self, pages: u32) usize {
    std.debug.assert(pages > 0);

    var result: usize = undefined;
    var suitable_range: ?*Range = null;

    if (self.free_list.first != null)  {
        var curr_node = self.free_list.first;

        while (curr_node) |n| : (curr_node = n.next) {
            const range = Range.fromNode(n);
            if (range.pages >= pages and
                (suitable_range == null or
                (suitable_range != null and suitable_range.?.pages < range.pages)))
            {
                suitable_range = range;
                if (range.pages == pages) break;
            }
        }

        if (suitable_range) |range| {
            result = range.base;
            self.removeRange(range, pages);
        }
    }

    if (suitable_range == null) {
        result = self.top;
        self.top += pages * vm.page_size;
    }

    return result;
}

pub fn release(self: *Self, base: usize, pages: u32) void {
    std.debug.assert(base > 0 and pages > 0);

    const range_top = base + (pages * vm.page_size);
    if (range_top == self.top) {
        self.top = base;
        return;
    }

    var curr_node = self.free_list.first;
    while (curr_node) |n| : (curr_node = n.next) {
        const range = Range.fromNode(n);
        if (range.base == range_top) {
            range.base = base;
            range.pages += pages;
            break;
        } else if (range.top() == base) {
            range.pages += pages;
            break;
        }
    }

    if (curr_node == null) {
        const range = vm.obj.new(Range) orelse unreachable;
        range.base = base;
        range.pages = pages;

        self.free_list.prepend(&range.node);
    } else {
        const target_range = Range.fromNode(curr_node.?);
        curr_node = self.free_list.first;

        const target_top = target_range.top();
        while (curr_node) |n| : (curr_node = n.next) {
            if (curr_node == &target_range.node) continue;

            const range = Range.fromNode(n);
            const curr_range_top = range.top();

            if (range.base == target_top) {
                range.base = target_range.base;
                range.pages += target_range.pages;

                self.free_list.remove(&target_range.node);
                vm.obj.free(Range, target_range);
                break;
            } else if (curr_range_top == target_range.base) {
                range.pages += target_range.pages;

                self.free_list.remove(&target_range.node);
                vm.obj.free(Range, target_range);
                break;
            }
        }
    }
}

inline fn removeRange(self: *Self, range: *Range, pages: u32) void {
    if (range.pages > pages) {
        range.base += pages * vm.page_size;
        range.pages -= pages;
    } else {
        self.free_list.remove(&range.node);
        vm.obj.free(Range, range);
    }
}
