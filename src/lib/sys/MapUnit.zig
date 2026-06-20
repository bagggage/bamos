//! # Mapping Unit

// Copyright (C) 2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const bindings = @import("../bindings.zig");
const lib = @import("../lib.zig");
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

pub inline fn new(
    file: ?*vfs.File, virt: usize,
    page_offset: u32, pages: u32, flags: Flags
) vfs.Error!*Self {
    return bindings.getInstance().sys.map_unit.new(
        file,
        virt,
        page_offset,
        pages,
        flags,
    );
}

pub inline fn fork(self: *Self) vm.Error!*Self {
    return bindings.getInstance().sys.map_unit.fork(self);
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

pub inline fn map(self: *Self, pt: *vm.PageTable) vm.Error!void {
    return bindings.getInstance().sys.map_unit.map(self, pt);
}

pub inline fn unmap(self: *Self, pt: *vm.PageTable) void {
    bindings.getInstance().sys.map_unit.unmap(self, pt);
}

pub inline fn unmapRegion(self: *Self, page_offset: u32, pages: u32, pt: *vm.PageTable) vm.Error!void {
    return bindings.getInstance().sys.map_unit.unmapRegion(self, page_offset, pages, pt);
}

pub inline fn shrinkTop(self: *Self, pages: u32, pt: *vm.PageTable) vm.Error!void {
    return bindings.getInstance().sys.map_unit.shrinkTop(self, pages, pt);
}

pub inline fn shrinkBottom(self: *Self, pages: u32, pt: *vm.PageTable) vm.Error!void {
    return bindings.getInstance().sys.map_unit.shrinkBottom(self, pages, pt);
}

pub inline fn moveBaseUp(self: *Self, pages: u32) void {
    bindings.getInstance().sys.map_unit.moveBaseUp(self, pages);
}

pub inline fn moveBaseDown(self: *Self, pages: u32) void {
    bindings.getInstance().sys.map_unit.moveBaseDown(self, pages);
}

pub inline fn attachPage(self: *Self, page: vm.Page) vm.Error!*vm.Page {
    return bindings.getInstance().sys.map_unit.attachPage(self, page);
}

pub inline fn attachAndMapPage(self: *Self, pt: *vm.PageTable, page: vm.Page, map_flags: vm.MapFlags) vm.Error!*vm.Page {
    return bindings.getInstance().sys.map_unit.attachAndMapPage(self, pt, page, map_flags);
}

pub inline fn detachLastPage(self: *Self) ?vm.Page {
    return bindings.getInstance().sys.map_unit.detachLastPage(self);
}

pub inline fn remapPage(self: *Self, pt: *vm.PageTable, page: vm.Page, map_flags: vm.MapFlags) vm.Error!*vm.Page {
    return bindings.getInstance().sys.map_unit.remapPage(self, pt, page, map_flags);
}

pub inline fn reinsertRegion(self: *Self, target: *Self, page_offset: u32, pages: u32) vm.Error!void {
    return bindings.getInstance().sys.map_unit.reinsertRegion(self, target, page_offset, pages);
}

pub inline fn getPageSafe(self: *Self, pt: *vm.PageTable, idx: u32, cause: vm.FaultCause) vfs.Error!*vm.Page {
    return bindings.getInstance().sys.map_unit.getPageSafe(self, pt, idx, cause);
}

pub inline fn copyPages(self: *Self, target: *Self) vm.Error!void {
    return bindings.getInstance().sys.map_unit.copyPages(self, target);
}

pub inline fn pageFault(self: *Self, pt: *vm.PageTable, address: usize, cause: vm.FaultCause) vfs.Error!void {
    return bindings.getInstance().sys.map_unit.pageFault(self, pt, address, cause);
}
