//! # Mapping Unit

// Copyright (C) 2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const rb = utils.rb;
const utils = @import("../utils.zig");
const vfs = @import("../vfs.zig");
const vm = @import("../vm.zig");

const Self = @This();

pub const List = utils.SList;
pub const Node = List.Node;

pub const Flags = packed struct {
    map: vm.MapFlags = .{},

    shared: bool = false,
    grow_down: bool = false,

    comptime { std.debug.assert(@sizeOf(Flags) == 2); }
};

pub const Operations = struct {
    pub const PageFaultFn = *const fn(*Self, usize, vm.FaultCause) vfs.Error!void;

    pageFault: PageFaultFn = &defaultPageFault,

    fn defaultPageFault(self: *Self, addr: usize, cause: vm.FaultCause) vfs.Error!void {
        if (!self.isAnonymous() or
            self.flags.map.none or
            (cause == .exec and !self.flags.map.exec) or
            (cause == .write and !self.flags.map.write)
        ) return vfs.Error.SegFault;

        const page_offset: u32 = @truncate((addr - self.base()) / vm.page_size);
        try self.region.insertNewPage(page_offset, 0, self.flags.map);
    }
};

pub const Page = vm.VirtualRegion.Page;

pub const PageHandle = struct {
    prev: ?*Page.Node,
    page: *Page,
};

pub const alloc_config: vm.obj.AllocatorConfig = .{
    .allocator = .safe_oma,
    .capacity = 256
};

pub const max_pages = Page.max_index + vm.PageAllocator.max_alloc_pages;
pub const max_size = max_pages * vm.page_size;

pub const default_ops: Operations = .{};

/// File pointer, if file is mapped.
file: ?*vfs.File = null,

region: vm.VirtualRegion,
/// File inner offset in pages.
page_offset: u32,
/// Virtual size of the mapping in pages.
page_capacity: u32,

ops: *const Operations = &default_ops,
flags: Flags,

node: Node = .{},
rb_node: rb.Node = .{},

pub fn init(
    self: *Self, file: ?*vfs.File, virt: usize,
    page_offset: u32, pages: u32, map_flags: vm.MapFlags
) void {
    if (file) |f| f.ref();
    self.* = .{
        .file = file,
        .page_offset = page_offset,
        .page_capacity = pages,
        .region = .{ .base = virt },
        .flags = .{ .map = map_flags },
    };
}

pub inline fn deinit(self: *Self) void {
    if (self.file) |f| f.deref();
    self.region.deinit(self.isAnonymous());
}

pub inline fn fromNode(node: *Node) *Self {
    return @fieldParentPtr("node", node);
}

pub inline fn fromRbNode(node: *rb.Node) *Self {
    return @fieldParentPtr("rb_node", node);
}

/// Returns virtual top of the mapping.
pub inline fn top(self: *const Self) usize {
    return self.region.base + self.size();
}

/// Returns virtual base of the mapping.
pub inline fn base(self: *const Self) usize {
    return self.region.base;
}

/// Returns virtual size of the mapping.
pub inline fn size(self: *const Self) usize {
    return @as(usize, self.page_capacity) * vm.page_size;
}

pub inline fn isAnonymous(self: *const Self) bool {
    return self.file == null;
}

pub fn unmap(self: *Self, pt: *vm.PageTable) void {
    self.region.unmap(pt, self.isAnonymous());
}

pub fn unmapRegion(self: *Self, page_offset: u32, pages: u32, pt: *vm.PageTable) !void {
    const detached = try self.detachPages(page_offset, pages);
    var node = detached.first;

    if (self.isAnonymous()) {
        while (node) |n| {
            const page = Page.fromNode(n);
            page.unmap(self.base(), pt);
            vm.PageAllocator.free(page.getPhysBase(), page.dim.rank);

            node = n.next;
            vm.obj.free(Page, page);
        }
    } else {
        while (node) |n| {
            const page = Page.fromNode(n);
            page.unmap(self.base(), pt);

            node = n.next;
            vm.obj.free(Page, page);
        }
    }
}

pub fn shrinkTop(self: *Self, pages: u32, pt: *vm.PageTable) !void {
    std.debug.assert(self.page_capacity > pages);

    const idx = self.page_capacity - pages;
    try self.unmapRegion(idx, pages, pt);

    self.page_capacity -= pages;
}

pub fn shrinkBottom(self: *Self, pages: u32, pt: *vm.PageTable) !void {
    std.debug.assert(self.page_capacity > pages);

    try self.unmapRegion(0, pages, pt);

    self.region.base += pages * vm.page_size;
    self.page_capacity -= pages;
}

pub inline fn reinsertRegion(self: *Self, target: *Self, page_offset: u32, pages: u32) !void {
    try self.detachPagesTo(
        page_offset, pages,
        &target.region.page_list
    );
}

pub fn format(
    self: *const Self,
    comptime _: []const u8,
    _: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    const map_flags = self.flags.map;
    const flags_str: [4]u8 = .{
        if (map_flags.none) '-' else 'r',
        if (map_flags.write) 'w' else '-',
        if (map_flags.exec) 'x' else '-',
        if (self.isAnonymous()) 'a' else 'p'
    };

    try writer.print("{x:0>8} - {x:0>8}: {s}: {x:0>8} ", .{
        self.base(), self.base() + self.size(),
        &flags_str, @as(usize, self.page_offset),
    });

    if (self.file) |f| {
        try f.dentry.path().format(&.{}, .{}, writer);
    }
}

/// Detach mapped pages from the
/// specified region and return a list of them.
inline fn detachPages(self: *Self, page_offset: u32, pages: u32) !Page.List {
    var list: Page.List = .{};
    try detachPagesTo(self, page_offset, pages, &list);

    return list;
}

/// Detach mapped pages from the
/// specified region to the list.
fn detachPagesTo(self: *Self, page_base: u32, page_len: u32, list: *Page.List) !void {
    const page_top = page_base + page_len;

    while (self.findPage(page_base, page_len)) |h| {
        const col_base = h.page.base;
        const col_len = h.page.pagesNum();
        const col_top = h.page.dim.idx + col_len;

        // Shrink or divide this physical region if needed.
        if (page_base > col_base) {
            if (page_top >= col_top) {
                // Shrink from the top.
                try shrinkPageTop(list, h.page, page_base);
            } else {
                // Smaller than collided page - divide.
                try dividePages(list, h.page, page_base, page_top);
                break;
            }
        } else if (page_top < col_top) {
            // Shrink from the bottom.
            try shrinkPageBottom(list, h.page, page_top);
        } else {
            self.detachPage(list, &h);
        }
    }
}

fn detachPage(self: *Self, list: *Page.List, handle: *const PageHandle) void {
    const node = &handle.page.node;

    // Remove page from the list.
    if (handle.prev) |p| {
        p.next = node.next;
    } else {
        self.region.page_list.first = node.next;
    }

    list.prepend(node);
}

fn findPage(self: *Self, page_base: u32, page_len: u32) ?PageHandle {
    const page_top = page_base + page_len;

    var prev: ?*Page.Node = null;
    var node: ?*Page.Node = self.region.page_list.first;

    while (node) |n| : ({prev = node; node = n.next;}) {
        const page = Page.fromNode(n);
        const n_base: u32 = page.dim.idx;
        const n_len: u32 = page.pagesNum();
        const n_top: u32 = n_base + n_len;

        if (page_base < n_top and n_base < page_top) {
            return .{ .prev = prev, .page = page };
        }
    }

    return null;
}

fn shrinkPageTop(list: *Page.List, page: *Page, new_top_idx: u32) !void {
    const page_len = page.pagesNum();
    const page_top_idx = page_len + page.dim.idx;
    const detach_len = page_top_idx - new_top_idx;
    const page_new_len = page_len - detach_len;
    const detach_base = page.base + page_new_len;

    const page_dump = page.*;
    const list_end = list.first;

    // Free new pages on error.
    var dummy_list: Page.List = .{ .first = &page.node };

    try buildPage( // Detached pages
        list, detach_base,
        new_top_idx, detach_len, false
    );

    errdefer freePageList(list, list_end);
    errdefer page.* = page_dump;

    try buildPage( // Rebuilded pages
        &dummy_list, page.base,
        page.dim.idx, page_len, true
    );
}

fn shrinkPageBottom(list: *Page.List, page: *Page, new_idx: u32) !void {
    const detach_len = new_idx - page.dim.idx;
    const page_new_base = page.base + detach_len;
    const page_new_len = page.pagesNum() - detach_len;

    const page_dump = page.*;
    const list_end = list.first;

    var dummy_list: Page.List = .{ .first = &page.node };
    try buildPage( // Detached pages.
        list, page.base,
        page.dim.idx, detach_len, false
    );

    errdefer freePageList(list, list_end);
    errdefer page.* = page_dump;

    try buildPage( // Rebuilded pages.
        &dummy_list, page_new_base,
        new_idx, page_new_len, true
    );
}

fn dividePages(list: *Page.List, page: *Page, div_idx: u32, div_top_idx: u32) !void {
    const page_new_len = div_idx - page.dim.idx;
    const div_len = div_top_idx - div_idx;
    const div_base = page.base + page_new_len;
    const page_next_len = page.pagesNum() - page_new_len - div_len;
    const page_next_base = page.base + page_new_len + div_len;

    const page_dump = page.*;
    const dummy_end = page.node.next;
    var dummy_list: Page.List = .{ .first = &page.node };

    errdefer page.* = page_dump;

    try buildPage( // Build left part of the page.
        &dummy_list, page.base,
        page.dim.idx, page_new_len, true
    );
    errdefer {
        var clean_list: Page.List = .{ .first = page.node.next };
        freePageList(&clean_list, dummy_end);
    }

    try buildPage( // Build right part of the page.
        &dummy_list, page_next_base,
        div_top_idx, page_next_len, false
    );

    try buildPage( // Build detached part.
        list, div_base,
        div_idx, div_len, false
    );
}

fn buildPage(
    list: *Page.List, phys_base: u32,
    idx: u32, len: u32, comptime reuse_first: bool
) !void {
    var temp_base = phys_base;
    var temp_idx = idx;
    var temp_len = len;

    const insert_after = reuse_first or (list.first != null);
    const list_end = if (insert_after) list.first.?.next else list.first;

    errdefer if (insert_after) {
        var dummy_list: Page.List = .{ .first = list.first.?.next };
        defer list.first.?.next = list_end;

        freePageList(&dummy_list, list_end);
    } else {
        freePageList(list, list_end);
    };

    while (temp_len > 0) {
        const new_page =
            if (reuse_first and temp_base == phys_base)
                Page.fromNode(list.first.?)
            else
                (vm.obj.new(Page) orelse return error.NoMemory);

        var temp_rank: u8 = std.math.log2_int(u32, temp_len);
        var rank_pages_num: u32 = @as(u32, 1) << @truncate(temp_rank);

        while (utils.modByPowerOfTwo(u32, rank_pages_num, @truncate(temp_rank)) != 0) {
            temp_rank -= 1;
            rank_pages_num >>= 1;
        }

        new_page.* = .{
            .base = temp_base,
            .dim = .{
                .idx = @truncate(temp_idx),
                .rank = temp_rank
            },
        };

        // Insert new page node after current page.
        if ((comptime !reuse_first) or temp_base != phys_base) {
            const new_node = &new_page.node;

            if (insert_after)
                list.first.?.insertAfter(new_node)
            else
                list.prepend(new_node);
        }

        temp_base += rank_pages_num;
        temp_idx += rank_pages_num;
        temp_len -= rank_pages_num;
    }
}

fn freePageList(list: *Page.List, end: ?*Page.Node) void {
    while (list.first) |n| {
        if (n == end) break;

        list.first = n.next;
        vm.obj.free(Page, Page.fromNode(n));
    }
}
