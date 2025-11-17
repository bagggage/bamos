//! # Process Address Space

// Copyright (C) 2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const lib = @import("../lib.zig");
const vfs = @import("../vfs.zig");
const vm = @import("../vm.zig");

const VmList = MapUnit.List;
const VmNode = MapUnit.Node;

const RbTree = lib.rb.Tree(compareMapUnits);
const RbNode = lib.rb.Node;

const Self = @This();

pub const MapUnit = @import("MapUnit.zig");

pub const alloc_config: vm.auto.Config = .{
    .allocator = .oma,
    .capacity = 128,
};

page_table: *vm.PageTable,

users: lib.atomic.RefCount(u32) = .init(0),

map_units: VmList = .{},
map_lock: lib.sync.RwLock = .{},
rb_tree: RbTree = .{},

/// The last map unit before heap first free region starts.
heap_unit: ?*MapUnit = null,

/// Stack size in pages.
stack_pages: u16,

pub fn init(pt: *vm.PageTable, stack_pages: u16) Self {
    return .{
        .page_table = pt,
        .stack_pages = stack_pages
    };
}

pub fn create(stack_pages: u16) !*Self {
    const self = vm.auto.alloc(Self) orelse return error.NoMemory;
    errdefer vm.auto.free(Self, self);

    const pt = vm.createPageTable() orelse return error.NoMemory;
    self.* = .init(pt, stack_pages);

    return self;
}

pub fn deinit(self: *Self) void {
    while (self.map_units.popFirst()) |n| {
        const map_unit = MapUnit.fromNode(n);

        map_unit.deinit();
        vm.auto.free(MapUnit, map_unit);
    }

    self.page_table.free();
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

pub fn heapAllocRegion(self: *Self, pages: u32) ?usize {
    const size = pages * vm.page_size;

    var base_unit = self.heap_unit orelse return 0;
    var free_base = base_unit.top();

    if (free_base + size > vm.max_user_heap_addr) return null;

    var next_node = base_unit.rb_node.next();
    while (next_node) |n| : (next_node = n.next()) {
        const next_unit = MapUnit.fromRbNode(n);
        const free_size = next_unit.base() - free_base;

        if (free_size >= size) return free_base;

        base_unit = next_unit;
        free_base = base_unit.top();

        if (free_base + size > vm.max_user_heap_addr) return null;
    }

    return free_base;
}

pub fn map(self: *Self, map_unit: *MapUnit) !void {
    // Handle collisions.
    while (self.rb_tree.insert(&map_unit.rb_node)) |node| {
        const col_unit = MapUnit.fromRbNode(node);

        const map_base = map_unit.base();
        const map_top = map_unit.top();
        const col_top = col_unit.top();

        if (map_base > col_unit.base()) {
            if (map_top >= col_top) {
                // Shrink from the top.
                const pages = (col_top - map_base) / vm.page_size;
                try col_unit.shrinkTop(@truncate(pages), self.page_table);

                continue;
            }

            // Smaller than collided unit - divide.
            try self.divideMapping(col_unit, map_unit);
        } else if (map_top > col_top) {
            // Bigger then collided unit - delete.
            self.deleteMapping(col_unit);
        } else if (map_top < col_top) {
            // Shrink from the bottom.
            const pages = (map_top - col_unit.base()) / vm.page_size;
            try col_unit.shrinkBottom(@truncate(pages), self.page_table);
        } else {
            // Equals.
            self.replaceMapping(col_unit, map_unit);
            break;
        }
    }

    self.map_units.prepend(&map_unit.node);
}

pub fn pageFault(self: *Self, addr: usize, cause: vm.FaultCause) !void {
    // Page aligned base address.
    const base = addr - (addr % vm.page_size);
    const top = base + vm.page_size;

    const map_unit = blk: {
        self.map_lock.readLock();
        defer self.map_lock.readUnlock();

        break :blk self.lookupMapUnit(base, top) orelse return error.NoEnt;
    };

    try map_unit.ops.pageFault(map_unit, addr, cause);
}

pub fn format(
    self: *const Self,
    comptime _: []const u8,
    _: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    const stack_size = self.stack_pages * (vm.page_size / lib.kb_size);

    try writer.print("{*}: refs: {}\n\t{*}, stack size: {} KB\n", .{
        self, self.users.count(), self.page_table, stack_size
    });

    var node = self.rb_tree.first();
    while (node) |n| : (node = n.next()) {
        const map_unit = MapUnit.fromRbNode(n);

        try writer.writeByte('\t');
        try map_unit.format(&.{}, .{}, writer);
        try writer.writeByte('\n');
    }
}

fn lookupMapUnit(self: *Self, base: usize, top: usize) ?*MapUnit {
    var rb_node = self.rb_tree.root;

    while (rb_node) |n| {
        const map_unit = MapUnit.fromRbNode(n);
        const order = compareMapRegions(
            base, top,
            map_unit.base(), map_unit.top()
        );

        switch (order) {
            .lt => rb_node = n.left,
            .gt => rb_node = n.right,
            .eq => return map_unit
        }
    }

    return null;
}

fn compareMapUnits(left: *RbNode, right: *RbNode, _: ?*RbNode) std.math.Order {
    const lhs_mapping = MapUnit.fromRbNode(left);
    const rhs_mapping = MapUnit.fromRbNode(right);

    return compareMapRegions(
        lhs_mapping.base(), lhs_mapping.top(),
        rhs_mapping.base(), rhs_mapping.top()
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

fn divideMapping(self: *Self, map_unit: *MapUnit, div_unit: *MapUnit) !void {
    const new_base = div_unit.top();
    const new_gap: u32 = @truncate((new_base - map_unit.base()) / vm.page_size);
    const new_pg_size: u32 = @truncate((map_unit.top() - new_base) / vm.page_size);
    const new_pg_off: u32 = new_gap + map_unit.page_offset;

    const new_unit = vm.auto.alloc(MapUnit) orelse return error.NoMemory;
    errdefer vm.auto.free(MapUnit, new_unit);

    const map_pg_size = (div_unit.base() - map_unit.base()) / vm.page_size;
    try map_unit.unmapRegion(
        @truncate(map_pg_size),
        div_unit.page_capacity, self.page_table
    );

    new_unit.* = .init(
        map_unit.file, new_base, new_pg_off,
        new_pg_size, map_unit.flags
    );

    const pg_off = map_unit.page_capacity - new_pg_size;
    try map_unit.reinsertRegion(new_unit, pg_off, new_pg_size);

    self.map_units.prepend(&new_unit.node);
    _ = self.rb_tree.insert(&new_unit.rb_node);
}

fn replaceMapping(self: *Self, old: *MapUnit, new: *MapUnit) void {
    self.rb_tree.replace(&old.rb_node, &new.rb_node);

    self.map_units.remove(&old.node);
    old.unmap(self.page_table);

    vm.auto.delete(MapUnit, old);
}

fn deleteMapping(self: *Self, map_unit: *MapUnit) void {
    self.rb_tree.remove(&map_unit.rb_node);
    self.map_units.remove(&map_unit.node);
    map_unit.unmap(self.page_table);

    vm.auto.delete(MapUnit, map_unit);
}