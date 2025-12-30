//! # Process Address Space

// Copyright (C) 2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const lib = @import("../lib.zig");
const vfs = @import("../vfs.zig");
const vm = @import("../vm.zig");

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

map_units: MapUnit.List = .{},
map_lock: lib.sync.RwSemaphore = .{},
rb_tree: RbTree = .{},

heap: ?*MapUnit = null,

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
    if (self.heap) |h| {
        if (h.page_capacity == 0) vm.auto.free(MapUnit, h);
    }

    while (self.map_units.popFirst()) |n| {
        const map_unit = MapUnit.fromNode(n);

        map_unit.deinit(self.page_table);
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

pub fn allocRegion(self: *Self, pages: u32) ?usize {
    const size = pages * vm.page_size;

    // TODO: More efficient searching for the address?
    //       The allocated address maybe allocated twise,
    //       if two threads call this simultaneously.
    self.map_lock.readLock();
    defer self.map_lock.readUnlock();

    var base_unit = self.heap orelse MapUnit.fromRbNode(self.rb_tree.first() orelse return vm.page_size);
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

pub fn heapInit(self: *Self, base: usize) vfs.Error!void {
    std.debug.assert(self.heap == null and vm.isUserVirtAddr(base));

    const heap = vm.auto.alloc(MapUnit) orelse return error.NoMemory;
    heap.* = .init(null, base, 0, 0, .{ .map = .{ .user = true, .write = true } });

    self.map_lock.writeLock();
    defer self.map_lock.writeUnlock();

    if (self.heap != null) return error.Exists;
    self.heap = heap;
}

pub fn heapGrow(self: *Self, pages: u32) ?usize {
    std.debug.assert(pages > 0);

    self.map_lock.writeLock();
    defer self.map_lock.writeUnlock();

    const heap = self.heap orelse return null;
    const top = heap.top();

    const new_top = top + (pages * vm.page_size);
    if (!vm.isUserVirtAddr(new_top)) return null;

    if (heap.page_capacity == 0) {
        heap.page_capacity += pages;
        if (self.rb_tree.insert(&heap.rb_node)) |_| {
            heap.page_capacity = 0;
            return null;
        }

        self.map_units.prepend(&heap.node);
    } else {
        if (heap.rb_node.next()) |n| {
            const next = MapUnit.fromRbNode(n);
            if (new_top > next.base()) return null;
        }

        heap.page_capacity += pages;
    }

    return top;
}

pub fn heapShrink(self: *Self, pages: u32) vm.Error!void {
    std.debug.assert(pages > 0);

    self.map_lock.writeLock();
    defer self.map_lock.writeUnlock();

    const heap = self.heap orelse return;
    if (heap.page_capacity == 0) return error.MaxSize;

    if (heap.page_capacity <= pages) {
        self.removeMapping(heap);
        heap.unmap(self.page_table);

        heap.page_capacity = 0;
    } else {
        try heap.shrinkTop(pages, self.page_table);
    }
}

pub fn mapRegion(self: *Self, region: *const vm.VirtualRegion, flags: MapUnit.Flags) vfs.Error!void {
    const map_unit = vm.auto.alloc(MapUnit) orelse return error.NoMemory;
    errdefer vm.auto.free(MapUnit, map_unit);

    map_unit.* = .init(null, region.base, 0, region.pagesNum(), flags);
    map_unit.region = region.*;

    try self.map(map_unit);
}

pub fn map(self: *Self, map_unit: *MapUnit) vfs.Error!void {
    self.map_lock.writeLock();
    defer self.map_lock.writeUnlock();

    if (self.rb_tree.insert(&map_unit.rb_node)) |_| return error.Exists;
    errdefer self.rb_tree.remove(&map_unit.rb_node);

    try map_unit.map(self.page_table);
    self.map_units.prepend(&map_unit.node);
}

pub fn mapFixed(self: *Self, map_unit: *MapUnit) vfs.Error!void {
    self.map_lock.writeLock();
    defer self.map_lock.writeUnlock();

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
    errdefer self.rb_tree.remove(&map_unit.rb_node);

    try map_unit.map(self.page_table);
    self.map_units.prepend(&map_unit.node);
}

pub fn pageFault(self: *Self, address: usize, cause: vm.FaultCause) vfs.Error!void {
    // Page aligned base address.
    const base = address - (address % vm.page_size);
    const top = base + vm.page_size;

    const map_unit = blk: {
        self.map_lock.readLock();
        defer self.map_lock.readUnlock();

        if (self.lookupMapUnit(base, top)) |map_unit| break :blk map_unit;

        // Lookup grow down unit
        const map_unit = self.lookupMapUnit(top, top + vm.page_size) orelse return error.NoEnt;
        break :blk if (map_unit.flags.grow_down) map_unit else return error.NoEnt;
    };

    self.map_lock.writeLock();
    defer self.map_lock.writeUnlock();

    try map_unit.pageFault(self.page_table, address, cause);
}

pub fn format(self: *Self, writer: *std.Io.Writer) !void {
    const stack_size = self.stack_pages * (vm.page_size / lib.kb_size);
    try writer.print("{*}: refs: {}\n\t{*}, stack size: {} KB\n", .{
        self, self.users.count(), self.page_table, stack_size
    });

    self.map_lock.readLock();
    defer self.map_lock.readUnlock();

    const stack = blk: {
        const last_unit = MapUnit.fromRbNode(self.rb_tree.last() orelse return);
        break :blk if (last_unit.flags.grow_down) last_unit else null;
    };

    var node = self.rb_tree.first();
    while (node) |n| : (node = n.next()) {
        const map_unit = MapUnit.fromRbNode(n);

        try writer.writeByte('\t');
        try map_unit.format(writer);

        if (map_unit == self.heap)
            try writer.writeAll("[heap]\n")
        else if (map_unit == stack)
            try writer.writeAll("[stack]\n")
        else
            try writer.writeByte('\n');
    }
}

pub fn calculateUsedRegion(self: *Self) [2]usize {
    self.map_lock.readLock();
    defer self.map_lock.readUnlock();

    const base = MapUnit.fromRbNode(self.rb_tree.first() orelse return .{ 0, 0 }).base();
    const last_top = MapUnit.fromRbNode(self.rb_tree.last().?).top();
    const top = if (self.heap) |h| @max(h.top(), last_top) else last_top;

    return .{ base, top };
}

fn allocRegion(self: *Self, pages: u32) vm.Error!usize {
    const size = pages * vm.page_size;

    var base_unit = blk: {
        const base = MapUnit.fromRbNode(self.rb_tree.first() orelse return vm.page_size);
        const heap = self.heap orelse break :blk base;

        break :blk if (heap.page_capacity > 0) heap else base;
    };
    var free_base = base_unit.top();

    if (free_base + size > vm.max_user_heap_addr) return error.NoMemory;

    var next_node = base_unit.rb_node.next();
    while (next_node) |n| : (next_node = n.next()) {
        const next_unit = MapUnit.fromRbNode(n);
        const free_size = next_unit.base() - free_base;

        if (free_size >= size) break;

        base_unit = next_unit;
        free_base = base_unit.top();

        if (free_base + size > vm.max_user_heap_addr) return error.NoMemory;
    }

    return free_base;
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

    old.deinit(self.page_table);
    vm.auto.free(MapUnit, old);
}

fn deleteMapping(self: *Self, map_unit: *MapUnit) void {
    self.removeMapping(map_unit);

    map_unit.deinit(self.page_table);
    vm.auto.free(MapUnit, map_unit);
}

fn removeMapping(self: *Self, map_unit: *MapUnit) void {
    self.rb_tree.remove(&map_unit.rb_node);
    self.map_units.remove(&map_unit.node);
}
