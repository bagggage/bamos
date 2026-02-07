//! # Mapping Unit

// Copyright (C) 2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const lib = @import("../lib.zig");
const log = std.log.scoped(.@"sys.MapUnit");
const vfs = @import("../vfs.zig");
const vm = @import("../vm.zig");

const Self = @This();

pub const List = std.SinglyLinkedList;
pub const Node = List.Node;

pub const Flags = packed struct {
    map: vm.MapFlags = .{},

    shared: bool = false,
    grow_down: bool = false,

    comptime { std.debug.assert(@sizeOf(Flags) == 2); }

    pub fn toPermissions(flags: Flags) vfs.Permissions {
        if (flags.map.none) return .none;

        var result: u16 = @intFromEnum(vfs.Permissions.r);
        if (flags.map.exec) result |= @intFromEnum(vfs.Permissions.x);
        if (flags.shared & flags.map.write) result |= @intFromEnum(vfs.Permissions.w);
        return @enumFromInt(result);
    }

    pub fn compatWith(flags: Flags, other: Flags) bool {
        return
            flags.shared == other.shared and
            flags.map.none == other.map.none and
            flags.map.exec == other.map.exec and
            flags.map.write == other.map.write
        ;
    }
};

pub const Operations = struct {
    pub const PageFaultFn = *const fn(*Self, pt: *vm.PageTable, offset: usize, cause: vm.FaultCause) vfs.Error!*vm.Page;
    pub const UnmapPageFn = *const fn(*const Self, pt: *const vm.PageTable, page: vm.Page) void;

    pageFault: PageFaultFn = &defaultPageFault,
    unmapPage: UnmapPageFn = &defaultUnmapPage,

    fn defaultPageFault(_: *Self, _: *vm.PageTable, _: usize, _: vm.FaultCause) vfs.Error!*vm.Page {
        return vfs.Error.SegFault;
    }

    fn defaultUnmapPage(_: *const Self, _: *const vm.PageTable, _: vm.Page) void {}
};

pub const PageHandle = struct {
    prev: ?*vm.Page.Node,
    page: *vm.Page,
};

pub const alloc_config: vm.auto.Config = .{
    .allocator = .oma,
    .capacity = 256
};

pub const max_pages = vm.Page.max_index + vm.PageAllocator.max_alloc_pages;
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
rb_node: lib.rb.Node = .{},

pub fn init(
    file: ?*vfs.File, virt: usize,
    page_offset: u32, pages: u32, flags: Flags
) Self {
    std.debug.assert(std.mem.isAligned(virt, vm.page_size));

    if (file) |f| f.ref();
    return .{
        .file = file,
        .page_offset = page_offset,
        .page_capacity = pages,
        .region = .{ .base = virt },
        .flags = flags,
    };
}

pub inline fn deinit(self: *Self, pt: *vm.PageTable) void {
    self.unmap(pt);
    if (self.file) |f| f.deref();
}

pub fn new(
    file: ?*vfs.File, virt: usize,
    page_offset: u32, pages: u32, flags: Flags
) vfs.Error!*Self {
    const map_unit = vm.auto.alloc(Self) orelse return error.NoMemory;
    errdefer map_unit.delete(undefined);

    map_unit.* = .init(file, virt, page_offset, pages, flags);
    if (file) |f| try f.mmapPrepare(map_unit);

    return map_unit;
}

pub fn fork(self: *Self) vm.Error!*Self {
    const map_unit = vm.auto.alloc(Self) orelse return error.NoMemory;
    map_unit.* = .init(self.file, self.base(), self.page_offset, self.page_capacity, self.flags);
    map_unit.ops = self.ops;

    return map_unit;
}

pub inline fn delete(self: *Self, pt: *vm.PageTable) void {
    self.deinit(pt);
    vm.auto.free(Self, self);
}

pub inline fn fromNode(node: *Node) *Self {
    return @fieldParentPtr("node", node);
}

pub inline fn fromRbNode(node: *lib.rb.Node) *Self {
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

pub fn map(self: *Self, pt: *vm.PageTable) !void {
    if (self.flags.map.none) return;

    var node = self.region.page_list.first;
    errdefer {
        var tmp = self.region.page_list.first;
        while (tmp) |n| : (tmp = n.next) {
            if (tmp == node) break;

            const page = vm.Page.fromNode(n);
            page.unmap(pt, self.region.base);
        }
    }

    while (node) |n| : (node = n.next) {
        const page = vm.Page.fromNode(n);
        try page.map(pt, self.region.base, self.flags.map);
    }
}

pub inline fn unmap(self: *Self, pt: *vm.PageTable) void {
    self.unmapPages(self.region.page_list, pt);
    self.region.page_list.first = null;
}

pub fn unmapRegion(self: *Self, page_offset: u32, pages: u32, pt: *vm.PageTable) !void {
    const detached = try self.detachPages(page_offset, pages);
    self.unmapPages(detached, pt);
}

pub fn shrinkTop(self: *Self, pages: u32, pt: *vm.PageTable) !void {
    std.debug.assert(self.page_capacity >= pages);

    const idx = self.page_capacity - pages;
    try self.unmapRegion(idx, pages, pt);

    self.page_capacity -= pages;
}

pub fn shrinkBottom(self: *Self, pages: u32, pt: *vm.PageTable) !void {
    std.debug.assert(self.page_capacity > pages);

    try self.unmapRegion(0, pages, pt);

    self.region.base += pages * vm.page_size;
    self.page_capacity -= pages;

    if (self.file != null) self.page_offset += pages; 
}

pub fn attachAndMapPage(self: *Self, pt: *vm.PageTable, page: vm.Page, map_flags: vm.MapFlags) !*vm.Page {
    const new_page = vm.auto.alloc(vm.Page) orelse return error.NoMemory;
    new_page.* = page;
    errdefer vm.auto.free(vm.Page, new_page);

    try page.map(pt, self.base(), map_flags);
    self.region.attachPage(new_page);

    return new_page;
}

pub fn detachLastPage(self: *Self) ?vm.Page {
    const page = self.region.detachLastPage() orelse return null;
    const tmp = page.*;

    vm.auto.free(vm.Page, page);
    return tmp;
}

pub fn remapPage(self: *Self, pt: *vm.PageTable, page: vm.Page, map_flags: vm.MapFlags) !*vm.Page {
    const target_page = self.region.getPage(page.dim.idx) orelse return error.NoEnt;
    target_page.* = page;

    try page.map(pt, self.base(), map_flags);
    return target_page;
}

pub inline fn reinsertRegion(self: *Self, target: *Self, page_offset: u32, pages: u32) !void {
    try self.detachPagesTo(
        page_offset, pages,
        &target.region.page_list
    );
}

pub fn getPageSafe(self: *Self, pt: *vm.PageTable, idx: u32, cause: vm.FaultCause) vfs.Error!*vm.Page {
    return self.region.getPage(idx) orelse blk: {
        break :blk try self.fillWithNewPage(pt, idx, cause);
    };
}

pub fn copyPages(self: *Self, target: *Self) !void {
    var node = self.region.page_list.first;
    while (node) |n| : (node = n.next) {
        const page = vm.Page.fromNode(n);
        log.debug("copy: 0x{x}: {} KiB", .{self.base() + page.getOffset(), page.pagesNum() * 4});

        const new_page = vm.Page.new(page.dim.idx, page.dim.rank) orelse return error.NoMemory;

        @memcpy(new_page.asSlice(), page.asSlice());
        target.region.page_list.prepend(&new_page.node);
    }
}

pub fn pageFault(self: *Self, pt: *vm.PageTable, address: usize, cause: vm.FaultCause) vfs.Error!void {
    if (self.flags.map.none or
        (cause == .exec and !self.flags.map.exec) or
        (cause == .write and !self.flags.map.write)
    ) return error.SegFault;

    if (self.flags.grow_down and address < self.base()) {
        @branchHint(.unlikely);
        std.debug.assert(address >= self.base() - vm.page_size);
        return try self.growDownFault(pt, cause);
    }

    const offset = address - self.base();
    const page_offset: u32 = vm.bytesToPagesExact(offset);

    _ = try self.fillWithNewPage(pt, page_offset, cause);
}

pub fn format(self: *const Self, writer: *std.Io.Writer) !void {
    const map_flags = self.flags.map;
    const flags_str: [4]u8 = .{
        if (map_flags.none) '-' else 'r',
        if (map_flags.write) 'w' else '-',
        if (map_flags.exec) 'x' else '-',
        if (self.isAnonymous()) 'a' else 'p'
    };

    try writer.print("{x:0>8} - {x:0>8}: {s}: {x:0>8} ", .{
        self.base(), self.base() + self.size(),
        &flags_str, @as(usize, self.page_offset) * vm.page_size,
    });

    if (self.file) |f| try f.dentry.path().format(writer);
}

fn fillWithNewPage(self: *Self, pt: *vm.PageTable, idx: u32, cause: vm.FaultCause) vfs.Error!*vm.Page {
    const offset = @as(usize, idx) * vm.page_size;
    if (!self.isAnonymous()) return try self.ops.pageFault(self, pt, offset, cause);

    // Anonymous page
    const page = vm.Page.new(idx, 0) orelse return error.NoMemory;
    errdefer page.delete();

    try page.map(pt, self.base(), self.flags.map);
    self.region.attachPage(page);

    page.fillZeroes();
    return page;
}

fn unmapPages(self: *Self, list: vm.Page.List, pt: *vm.PageTable) void {
    var node = list.first;
    if (self.isAnonymous()) {
        while (node) |n| {
            const page = vm.Page.fromNode(n);
            page.unmap(pt, self.base());
            vm.PageAllocator.free(page.getPhysBase(), page.dim.rank);

            node = n.next;
            vm.auto.free(vm.Page, page);
        }
    } else {
        while (node) |n| {
            const page = vm.Page.fromNode(n);
            self.ops.unmapPage(self, pt, page.*);
            page.unmap(pt, self.base());

            node = n.next;
            vm.auto.free(vm.Page, page);
        }
    }
}

/// Detach mapped pages from the
/// specified region and return a list of them.
inline fn detachPages(self: *Self, page_offset: u32, pages: u32) !vm.Page.List {
    var list: vm.Page.List = .{};
    try detachPagesTo(self, page_offset, pages, &list);

    return list;
}

/// Detach mapped pages from the
/// specified region to the list.
fn detachPagesTo(self: *Self, page_base: u32, page_len: u32, list: *vm.Page.List) !void {
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

fn detachPage(self: *Self, list: *vm.Page.List, handle: *const PageHandle) void {
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

    var prev: ?*vm.Page.Node = null;
    var node: ?*vm.Page.Node = self.region.page_list.first;

    while (node) |n| : ({prev = node; node = n.next;}) {
        const page = vm.Page.fromNode(n);
        const n_base: u32 = page.dim.idx;
        const n_len: u32 = page.pagesNum();
        const n_top: u32 = n_base + n_len;

        if (page_base < n_top and n_base < page_top) {
            return .{ .prev = prev, .page = page };
        }
    }

    return null;
}

fn growDownFault(self: *Self, pt: *vm.PageTable, cause: vm.FaultCause) !void {
    std.debug.assert(self.flags.grow_down);

    var node = self.region.page_list.first;

    if (self.isAnonymous()) {
        const page = vm.Page.new(0, 0) orelse return error.NoMemory;
        errdefer page.delete();

        try page.map(pt, self.base() - vm.page_size, self.flags.map);
        self.region.attachPage(page);

        self.page_capacity += 1;
        self.region.base -= vm.page_size;

        page.fillZeroes();
    } else {
        @branchHint(.unlikely);
        if (self.page_offset == 0) return error.SegFault;

        self.page_offset -= 1;
        self.page_capacity += 1;
        self.region.base -= vm.page_size;
        errdefer {
            self.page_offset += 1;
            self.page_capacity -= 1;
            self.region.base += vm.page_size;
        }

        _ = try self.ops.pageFault(self, pt, 0, cause);
    }

    while (node) |n| : (node = n.next) {
        const page = vm.Page.fromNode(n);
        page.dim.idx += 1;
    }
}

fn shrinkPageTop(list: *vm.Page.List, page: *vm.Page, new_top_idx: u32) !void {
    const page_len = page.pagesNum();
    const page_top_idx = page_len + page.dim.idx;
    const detach_len = page_top_idx - new_top_idx;
    const page_new_len = page_len - detach_len;
    const detach_base = page.base + page_new_len;

    const page_dump = page.*;
    const list_end = list.first;

    // Free new pages on error.
    var dummy_list: vm.Page.List = .{ .first = &page.node };

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

fn shrinkPageBottom(list: *vm.Page.List, page: *vm.Page, new_idx: u32) !void {
    const detach_len = new_idx - page.dim.idx;
    const page_new_base = page.base + detach_len;
    const page_new_len = page.pagesNum() - detach_len;

    const page_dump = page.*;
    const list_end = list.first;

    var dummy_list: vm.Page.List = .{ .first = &page.node };
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

fn dividePages(list: *vm.Page.List, page: *vm.Page, div_idx: u32, div_top_idx: u32) !void {
    const page_new_len = div_idx - page.dim.idx;
    const div_len = div_top_idx - div_idx;
    const div_base = page.base + page_new_len;
    const page_next_len = page.pagesNum() - page_new_len - div_len;
    const page_next_base = page.base + page_new_len + div_len;

    const page_dump = page.*;
    const dummy_end = page.node.next;
    var dummy_list: vm.Page.List = .{ .first = &page.node };

    errdefer page.* = page_dump;

    try buildPage( // Build left part of the page.
        &dummy_list, page.base,
        page.dim.idx, page_new_len, true
    );
    errdefer {
        var clean_list: vm.Page.List = .{ .first = page.node.next };
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
    list: *vm.Page.List, phys_base: u32,
    idx: u32, len: u32, comptime reuse_first: bool
) !void {
    var temp_base = phys_base;
    var temp_idx = idx;
    var temp_len = len;

    const insert_after = reuse_first or (list.first != null);
    const list_end = if (insert_after) list.first.?.next else list.first;

    errdefer if (insert_after) {
        var dummy_list: vm.Page.List = .{ .first = list.first.?.next };
        defer list.first.?.next = list_end;

        freePageList(&dummy_list, list_end);
    } else {
        freePageList(list, list_end);
    };

    while (temp_len > 0) {
        const new_page =
            if (reuse_first and temp_base == phys_base)
                vm.Page.fromNode(list.first.?)
            else
                (vm.auto.alloc(vm.Page) orelse return error.NoMemory);

        var temp_rank: u8 = std.math.log2_int(u32, temp_len);
        var rank_pages_num: u32 = @as(u32, 1) << @truncate(temp_rank);

        while (lib.misc.modByPowerOfTwo(u32, rank_pages_num, @truncate(temp_rank)) != 0) {
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

fn freePageList(list: *vm.Page.List, end: ?*vm.Page.Node) void {
    while (list.first) |n| {
        if (n == end) break;

        list.first = n.next;
        vm.auto.free(vm.Page, vm.Page.fromNode(n));
    }
}
