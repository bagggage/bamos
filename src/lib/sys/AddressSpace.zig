//! # Process Address Space

// Copyright (C) 2025-2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const bindings = @import("../bindings.zig");
const lib = @import("../lib.zig");
const vfs = @import("../vfs.zig");
const vm = @import("../vm.zig");

const RbTree = lib.rb.Tree(compareMapUnits, keyCompareMapUnits);
const RbNode = lib.rb.Node;

const Self = @This();

pub const MapUnit = @import("MapUnit.zig");

pub const alloc_config: vm.auto.Config = .{
    .allocator = .oma,
    .capacity = 128,
};

page_table: *vm.PageTable,

users: lib.atomic.RefCount(u32) = .init(0),

map_units: MapUnit.List = .{},
map_lock: lib.sync.RwSemaphore = .{},
rb_tree: RbTree = .{},

heap: ?*MapUnit = null,

/// Stack size in pages.
stack_pages: u16,
brk_offset: u16 = 0,

pub inline fn init(pt: *vm.PageTable, stack_pages: u16) Self {
    return bindings.getInstance().sys.address_space.init(pt, stack_pages);
}

pub inline fn create(stack_pages: u16) vm.Error!*Self {
    return bindings.getInstance().sys.address_space.create(stack_pages);
}

pub inline fn cloneAndCopy(self: *Self) vm.Error!*Self {
    return bindings.getInstance().sys.address_space.cloneAndCopy(self);
}

pub inline fn compare(self: *const Self, other: *const Self) bool {
    return bindings.getInstance().sys.address_space.compare(self, other);
}

pub inline fn deinit(self: *Self) void {
    self.clear();
    self.page_table.free();
}

pub inline fn clear(self: *Self) void {
    bindings.getInstance().sys.address_space.clear(self);
}

pub inline fn delete(self: *Self) void {
    self.deinit();
    vm.auto.free(Self, self);
}

pub inline fn ref(self: *Self) void {
    self.users.inc();
}

pub inline fn deref(self: *Self) void {
    if (self.users.put()) self.delete();
}

pub inline fn heapGrow(self: *Self, bytes: usize) vm.Error!usize {
    return bindings.getInstance().sys.address_space.heapGrow(self, bytes);
}

pub inline fn heapShrink(self: *Self, bytes: usize) vm.Error!usize {
    return bindings.getInstance().sys.address_space.heapShrink(self, bytes);
}

pub inline fn getHeapBreak(self: *Self) usize {
    return bindings.getInstance().sys.address_space.getHeapBreak(self);
}

pub inline fn map(self: *Self, map_unit: *MapUnit) vfs.Error!void {
    return bindings.getInstance().sys.address_space.map(self, map_unit);
}

pub inline fn mapAnyAddress(self: *Self, map_unit: *MapUnit) vfs.Error!void {
    return bindings.getInstance().sys.address_space.mapAnyAddress(self, map_unit);
}

pub inline fn mapOrRebase(self: *Self, map_unit: *MapUnit) vfs.Error!void {
    return bindings.getInstance().sys.address_space.mapOrRebase(self, map_unit);
}

pub inline fn mapReplace(self: *Self, map_unit: *MapUnit) vfs.Error!void {
    return bindings.getInstance().sys.address_space.mapReplace(self, map_unit);
}

pub inline fn mapRegion(self: *Self, region: *const vm.VirtualRegion, flags: MapUnit.Flags) vfs.Error!void {
    return bindings.getInstance().sys.address_space.mapRegion(self, region, flags);
}

pub inline fn unmap(self: *Self, map_unit: *MapUnit) void {
    return bindings.getInstance().sys.address_space.unmap(self, map_unit);
}

pub inline fn unmapRange(self: *Self, base: usize, pages: u32) vm.Error!void {
    return bindings.getInstance().sys.address_space.unmapRange(self, base, pages);
}

pub inline fn protectRange(self: *Self, base: usize, pages: u32, flags: MapUnit.Flags) vfs.Error!void {
    return bindings.getInstance().sys.address_space.protectRange(self, base, pages, flags);
}

pub inline fn pageFault(self: *Self, address: usize, cause: vm.FaultCause) vfs.Error!void {
    return bindings.getInstance().sys.address_space.pageFault(self, address, cause);
}

pub inline fn format(self: *Self, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    return bindings.getInstance().sys.address_space.format(self, writer);
}

pub inline fn calculateUsedRegion(self: *Self) [2]usize {
    return bindings.getInstance().sys.address_space.calculateUsedRegion(self);
}

fn compareMapUnits(left: *RbNode, right: *RbNode, _: ?*RbNode) std.math.Order {
    const lhs_mapping = MapUnit.fromRbNode(left);
    const rhs_mapping = MapUnit.fromRbNode(right);

    return compareMapRegions(
        lhs_mapping.base(), lhs_mapping.top(),
        rhs_mapping.base(), rhs_mapping.top()
    );
}

fn keyCompareMapUnits(left: *RbNode, right: anytype) std.math.Order {
    const lhs_mapping = MapUnit.fromRbNode(left);
    return compareMapRegions(
        lhs_mapping.base(), lhs_mapping.top(),
        right[0], right[1]
    );
}

inline fn compareMapRegions(
    lhs_base: usize, lhs_top: usize,
    rhs_base: usize, rhs_top: usize
) std.math.Order {
    if (lhs_base >= rhs_top) {
        return .gt;
    } else if (rhs_base >= lhs_top) {
        return .lt;
    }

    return .eq;
}
