/// Heap.
const std = @import("std");

const utils = @import("../utils.zig");
const vm = @import("../vm.zig");

const Self = @This();
const List_t = utils.SList(Range);
const Range = struct {
    base: usize = undefined,
    pages: u32 = undefined,

    pub inline fn top(self: *const Range) usize {
        return self.base + (self.pages * vm.page_size);
    }
};

base: usize = undefined,
top: usize = undefined,

free_list: List_t = undefined,

var nodes_oma = vm.ObjectAllocator.initSized(@sizeOf(List_t.Node), 1);

pub inline fn init(base: usize) Self {
    return Self{ .base = base, .top = base };
}

pub fn reserve(self: *Self, pages: u32) usize {
    std.debug.assert(pages > 0);

    var result: usize = undefined;
    var suitable_range: ?*List_t.Node = null;

    if (self.free_list.first) {
        var curr_range = self.free_list.first;

        while (curr_range) |range| : (curr_range = range.next) {
            if (range.data.pages >= pages and
                (suitable_range == null or
                (suitable_range != null and suitable_range.?.data.pages < range.data.pages)))
            {
                suitable_range = range;

                if (range.data.pages == pages) break;
            }
        }

        if (suitable_range) |range| {
            result = range.data.base;
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

    var curr_range = self.free_list.first;

    while (curr_range) |range| : (curr_range = range.next) {
        if (range.data.base == range_top) {
            range.data.base = base;
            range.data.pages += pages;
            break;
        } else if (range.data.top() == base) {
            range.data.pages += pages;
            break;
        }
    }

    if (curr_range == null) {
        const range = nodes_oma.alloc(List_t.Node) orelse unreachable;
        range.data.base = base;
        range.data.pages = pages;

        self.free_list.prepend(range);
    } else {
        var target_node = curr_range.?;
        curr_range = self.free_list.first;

        const target_top = target_node.data.top();

        while (curr_range) |range| : (curr_range = range.next) {
            if (curr_range == target_node) continue;

            const curr_range_top = range.data.top();

            if (range.data.base == target_top) {
                range.data.base = target_node.data.base;
                range.data.pages += target_node.data.pages;

                self.free_list.remove(target_node);
                nodes_oma.free(target_node);
                break;
            } else if (curr_range_top == target_node.data.base) {
                range.data.pages += target_node.data.pages;

                self.free_list.remove(target_node);
                nodes_oma.free(target_node);
                break;
            }
        }
    }
}

inline fn removeRange(self: *Self, node: *List_t.Node, pages: u32) void {
    if (node.data.pages > pages) {
        node.data.base += pages * vm.page_size;
        node.data.pages -= pages;
    } else {
        self.free_list.remove(node);
        nodes_oma.free(node);
    }
}
