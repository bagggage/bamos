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
brk_offset: u16 = 0,

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

pub fn cloneAndCopy(self: *Self) vm.Error!*Self {
    const new = vm.auto.alloc(Self) orelse return error.NoMemory;
    errdefer vm.auto.free(Self, new);

    const pt = vm.createPageTable() orelse return error.NoMemory;
    new.* = .{
        .page_table = pt,
        .stack_pages = self.stack_pages,
    };
    errdefer new.deinit();

    self.map_lock.readLock();
    defer self.map_lock.readUnlock();

    new.brk_offset = self.brk_offset;

    var node = self.map_units.first;
    while (node) |n| : (node = n.next) {
        const map_unit = MapUnit.fromNode(n);
        const new_unit = try map_unit.fork();
        errdefer new_unit.delete(new.page_table);

        if (!map_unit.flags.shared and !map_unit.flags.map.none) {
            // Allocate physical pages and copy all data
            try map_unit.copyPages(new_unit);
            try new_unit.map(new.page_table);
        }

        new.includeMapping(new_unit);
        if (map_unit == self.heap) {
            @branchHint(.unlikely);
            new.heap = new_unit;
        }
    }

    if (self.heap != null and self.heap.?.page_capacity == 0) {
        @branchHint(.unlikely);
        const heap = self.heap.?;
        const new_heap = try heap.fork();
        self.heap = new_heap;
    }

    return new;
}

pub fn deinit(self: *Self) void {
    if (self.heap) |h| {
        if (h.page_capacity == 0) vm.auto.free(MapUnit, h);
    }

    while (self.map_units.popFirst()) |n| {
        const map_unit = MapUnit.fromNode(n);
        map_unit.delete(self.page_table);
    }

    self.rb_tree.root = null;
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

pub fn heapInit(self: *Self, base: usize) vfs.Error!void {
    std.debug.assert(self.heap == null and vm.isUserVirtAddr(base));

    const heap = try MapUnit.new(null, base, 0, 0, .{ .map = .{ .user = true, .write = true } });
    errdefer vm.auto.free(MapUnit, heap);

    self.map_lock.writeLock();
    defer self.map_lock.writeUnlock();

    if (self.heap != null) return error.Exists;
    self.heap = heap;
}

pub fn heapGrow(self: *Self, bytes: usize) vm.Error!usize {
    std.debug.assert(bytes > 0);

    self.map_lock.writeLock();
    defer self.map_lock.writeUnlock();

    const heap = self.heap orelse return error.Uninitialized;
    const top = heap.top();
    const brk = top - self.brk_offset;
    const new_brk = brk +| bytes;

    if (new_brk <= top) {
        self.brk_offset -= @truncate(new_brk - brk);
        return new_brk;
    }

    if (!vm.isUserVirtAddr(new_brk)) return error.MaxSize;

    const pages = vm.bytesToPages(new_brk - top);
    if (heap.page_capacity == 0) {
        heap.page_capacity += pages;
        if (self.rb_tree.insert(&heap.rb_node)) |_| {
            @branchHint(.unlikely);
            heap.page_capacity = 0;
            return brk;
        }

        self.map_units.prepend(&heap.node);
    } else {
        if (heap.rb_node.next()) |n| {
            const next = MapUnit.fromRbNode(n);
            if (new_brk > next.base()) return error.MaxSize;
        }

        heap.page_capacity += pages;
    }

    self.brk_offset = @truncate(vm.page_size - (new_brk & (vm.page_size - 1)));
    return new_brk;
}

pub fn heapShrink(self: *Self, bytes: usize) vm.Error!usize {
    std.debug.assert(bytes > 0);

    self.map_lock.writeLock();
    defer self.map_lock.writeUnlock();

    const heap = self.heap orelse return error.Uninitialized;
    if (heap.page_capacity == 0) return heap.base();

    const top = heap.top();
    const brk = top - self.brk_offset;
    const new_brk = brk -| bytes;
    if (new_brk <= heap.base()) {
        self.removeMapping(heap);
        heap.unmap(self.page_table);

        self.brk_offset = 0;
        heap.page_capacity = 0;

        return heap.base();
    }

    const diff = top - new_brk;
    const pages = vm.bytesToPagesExact(diff);
    if (pages > 0) {
        try heap.shrinkTop(pages, self.page_table);
    }

    self.brk_offset = @truncate(vm.page_size - (new_brk & (vm.page_size - 1)));
    return new_brk;
}

pub fn getHeapBreak(self: *Self) usize {
    self.map_lock.readLock();
    defer self.map_lock.readUnlock();

    const heap = self.heap.?;
    return heap.top() - self.brk_offset;
}

pub fn map(self: *Self, map_unit: *MapUnit) vfs.Error!void {
    self.map_lock.writeLock();
    defer self.map_lock.writeUnlock();

    if (self.rb_tree.insert(&map_unit.rb_node)) |_| return error.Exists;
    errdefer self.rb_tree.remove(&map_unit.rb_node);

    try map_unit.map(self.page_table);
    self.map_units.prepend(&map_unit.node);
}

pub fn mapAnyAddress(self: *Self, map_unit: *MapUnit) vfs.Error!void {
    self.map_lock.writeLock();
    defer self.map_lock.writeUnlock();

    const old_base = map_unit.base();
    errdefer map_unit.region.base = old_base;

    map_unit.region.base = try self.allocRegion(map_unit.page_capacity);

    if (self.rb_tree.insert(&map_unit.rb_node) != null) unreachable;
    errdefer self.rb_tree.remove(&map_unit.rb_node);

    try map_unit.map(self.page_table);
    self.map_units.prepend(&map_unit.node);
}

pub fn mapOrRebase(self: *Self, map_unit: *MapUnit) vfs.Error!void {
    const old_base = map_unit.base();
    errdefer map_unit.region.base = old_base;

    while (true) {
        self.map(map_unit) catch |err| {
            if (err != error.Exists) return err;

            self.map_lock.readLock();
            defer self.map_lock.readUnlock();

            map_unit.region.base = try self.allocRegion(map_unit.page_capacity);
            continue;
        };
        break;
    }
}

pub fn mapReplace(self: *Self, map_unit: *MapUnit) vfs.Error!void {
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

pub fn mapRegion(self: *Self, region: *const vm.VirtualRegion, flags: MapUnit.Flags) vfs.Error!void {
    const map_unit = try MapUnit.new(null, region.base, 0, region.pagesNum(), flags);
    errdefer map_unit.delete(undefined);

    map_unit.region = region.*;
    try self.map(map_unit);
}

pub fn unmap(self: *Self, map_unit: *MapUnit) void {
    {
        self.map_lock.writeLock();
        defer self.map_lock.writeUnlock();

        self.removeMapping(map_unit);
    }

    map_unit.unmap(self.page_table);
}

pub fn protectRange(self: *Self, base: usize, pages: u32, flags: MapUnit.Flags) vfs.Error!void {
    self.map_lock.writeLock();
    defer self.map_lock.writeUnlock();

    const top = base + (pages * vm.page_size);
    const map_unit = self.lookupMapUnit(base, top) orelse return error.NoEnt;

    var curr_top = map_unit.top();
    const base_unit = if (map_unit.base() <= base) blk: {
        if (curr_top >= top) {
            try validateProtection(map_unit, flags);
            return self.protectUnit(map_unit, base, top, flags);
        }

        try validateProtection(map_unit, flags);
        break :blk map_unit;
    } else blk: {
        var base_unit = map_unit;
        while (base < base_unit.base()) {
            const prev = MapUnit.fromRbNode(map_unit.rb_node.prev() orelse return error.NoMemory);
            if (prev.top() != base_unit.base()) return error.NoMemory; // gap!

            try validateProtection(prev, flags);
            base_unit = prev;
        }
        break :blk base_unit;
    };

    var top_unit = map_unit;
    while (curr_top < top) {
        const next = MapUnit.fromRbNode(top_unit.rb_node.next() orelse return error.NoMemory);
        if (next.base() != curr_top) return error.NoMemory; // gap!

        try validateProtection(next, flags);

        curr_top = next.top();
        top_unit = next;
    }

    try self.protectUnitsRange(base_unit, top_unit, base, top, flags);
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

fn protectUnit(self: *Self, map_unit: *MapUnit, base: usize, top: usize, flags: MapUnit.Flags) vfs.Error!void {
    if (map_unit.flags.compatWith(flags)) map_unit.flags = flags;

    if (base > map_unit.base()) {
        const base_pages = vm.bytesToPagesExact(base - map_unit.base());
        if (top < map_unit.top()) {
            const middle_unit = try map_unit.fork();
            const middle_pages = vm.bytesToPagesExact(top - base);
            errdefer middle_unit.delete(self.page_table);

            if (middle_unit.file != null) middle_unit.page_offset += base_pages;
            middle_unit.flags = flags;
            middle_unit.region.base = base;
            middle_unit.page_capacity = middle_pages;

            try self.divideMapping(map_unit, middle_unit);
            self.includeMapping(middle_unit);
        } else {
            const top_unit = try map_unit.fork();
            const top_pages = vm.bytesToPagesExact(map_unit.top() - base);
            errdefer top_unit.delete(self.page_table);

            if (top_unit.file != null) top_unit.page_offset += base_pages;
            top_unit.flags = flags;
            top_unit.region.base = base;
            top_unit.page_capacity = top_pages;

            try map_unit.shrinkTop(top_pages, self.page_table);
            self.includeMapping(top_unit);
        }
    } else if (top < map_unit.top()) {
        const base_unit = try map_unit.fork();
        const base_pages = vm.bytesToPagesExact(top - map_unit.base());
        errdefer base_unit.delete(self.page_table);

        try map_unit.shrinkBottom(base_pages, self.page_table);

        base_unit.flags = flags;
        base_unit.page_capacity = base_pages;
        self.includeMapping(base_unit);
    } else {
        map_unit.flags = flags;
        try map_unit.map(self.page_table);
    }
}

fn protectUnitsRange(
    self: *Self, base_unit: *MapUnit, top_unit: *MapUnit,
    base: usize, top: usize, flags: MapUnit.Flags
) vfs.Error!void {
    std.debug.assert(base_unit != top_unit);

    var map_unit = MapUnit.fromRbNode(base_unit.rb_node.next().?);
    try self.protectUnit(base_unit, base, top, flags);

    while (map_unit != top_unit) {
        if (map_unit.flags.compatWith(flags)) {
            map_unit.flags = flags;
        } else {
            map_unit.flags = flags;
            try map_unit.map(self.page_table);
        }

        map_unit = MapUnit.fromRbNode(map_unit.rb_node.next().?);
    }

    try self.protectUnit(top_unit, base, top, flags);
}

fn validateProtection(map_unit: *MapUnit, flags: MapUnit.Flags) error{NoAccess}!void {
    if (map_unit.isAnonymous()) return;

    const file = map_unit.file.?;
    file.validateAccess(flags.toPermissions()) catch return error.NoAccess;
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

fn includeMapping(self: *Self, map_unit: *MapUnit) void {
    if (self.rb_tree.insert(&map_unit.rb_node) != null) unreachable; 
    self.map_units.prepend(&map_unit.node);
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
