//! # Process Address Space

// Copyright (C) 2025-2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const sys = @import("../sys.zig");
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

    if (new.heap == null and self.heap != null) {
        @branchHint(.unlikely);
        const new_heap = try self.heap.?.fork();
        new.heap = new_heap;
    }

    return new;
}

pub fn compare(self: *const Self, other: *const Self) bool {
    var lhs_node = self.rb_tree.first();
    var rhs_node = other.rb_tree.first();

    while (lhs_node) |l| : ({ lhs_node = l.next(); rhs_node = rhs_node.?.next(); }) {
        const r = rhs_node orelse return false;
        const l_unit = MapUnit.fromRbNode(l);
        const r_unit = MapUnit.fromRbNode(r);

        if (
            l_unit.file != r_unit.file or
            l_unit.base() != r_unit.base() or
            l_unit.flags != r_unit.flags or
            l_unit.page_capacity != r_unit.page_capacity or
            l_unit.page_offset != r_unit.page_offset
        ) return false;

        for (0..l_unit.page_capacity) |i| {
            const l_page = l_unit.region.getPage(@truncate(i));
            const r_page = r_unit.region.getPage(@truncate(i));

            if (l_page) |l_p| {
                const r_p = r_page orelse return false;
                if (l_p.dim != r_p.dim) return false;
                if (!std.mem.eql(u8, l_p.asSlice(), r_p.asSlice())) {
                    std.log.warn("vm.page content missmatch! 0x{x}: {x}, 0x{x}: {x}", .{
                        l_unit.base() + l_p.getOffset(), l_p.base,
                        r_unit.base() + r_p.getOffset(), r_p.base
                    });

                    return false;
                }
            }
        }
    }

    return true;
}

pub inline fn deinit(self: *Self) void {
    self.clear();
    self.page_table.free();
}

pub fn clear(self: *Self) void {
    self.map_lock.writeLock();
    defer self.map_lock.writeUnlock();

    if (self.heap) |h| {
        if (h.page_capacity == 0) vm.auto.free(MapUnit, h);
    }

    while (self.map_units.popFirst()) |n| {
        const map_unit = MapUnit.fromNode(n);
        map_unit.delete(self.page_table);
    }

    self.rb_tree.root = null;
    self.heap = null;
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

    defer self.validate();

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

    const brk_trunc: u16 = @truncate(new_brk & (vm.page_size - 1));
    self.brk_offset = (vm.page_size - brk_trunc) & (vm.page_size - 1);
    return new_brk;
}

pub fn heapShrink(self: *Self, bytes: usize) vm.Error!usize {
    std.debug.assert(bytes > 0);

    defer self.validate();

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

    const brk_trunc: u16 = @truncate(new_brk & (vm.page_size - 1));
    self.brk_offset = (vm.page_size - brk_trunc) & (vm.page_size - 1);
    return new_brk;
}

pub fn getHeapBreak(self: *Self) usize {
    self.map_lock.readLock();
    defer self.map_lock.readUnlock();

    const heap = self.heap.?;
    return heap.top() - self.brk_offset;
}

pub fn map(self: *Self, map_unit: *MapUnit) vfs.Error!void {
    defer self.validate();

    self.map_lock.writeLock();
    defer self.map_lock.writeUnlock();

    if (self.rb_tree.insert(&map_unit.rb_node)) |_| return error.Exists;
    errdefer self.rb_tree.remove(&map_unit.rb_node);

    try map_unit.map(self.page_table);
    self.map_units.prepend(&map_unit.node);
}

pub fn mapAnyAddress(self: *Self, map_unit: *MapUnit) vfs.Error!void {
    defer self.validate();

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
    defer self.validate();

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

pub fn unmapRange(self: *Self, base: usize, pages: u32) vm.Error!void {
    defer self.validate();

    self.map_lock.writeLock();
    defer self.map_lock.writeUnlock();

    const top = base + @as(usize, pages) * vm.page_size;
    while (self.lookupMapUnit(base, top)) |map_unit| {
        const curr_top = map_unit.top();
        if (map_unit.base() >= base) {
            if (curr_top <= top) {
                if (map_unit == self.heap) {
                    @branchHint(.unlikely);
                    self.brk_offset = 0;
                    self.removeMapping(map_unit);

                    map_unit.page_capacity = 0;
                    map_unit.unmap(self.page_table);
                } else {
                    self.deleteMapping(map_unit);
                }
            } else {
                try map_unit.shrinkBottom(
                    vm.bytesToPagesExact(top - map_unit.base()),
                    self.page_table
                );
            }
        } else if (curr_top <= top) {
            if (map_unit == self.heap) {
                @branchHint(.unlikely);
                self.brk_offset = 0;
            }
            try map_unit.shrinkTop(
                vm.bytesToPagesExact(curr_top - base),
                self.page_table
            );
        } else {
            const new_unit = try self.cutMapping(
                map_unit, base - map_unit.base(),
                pages
            );
            if (map_unit == self.heap) {
                @branchHint(.unlikely);
                self.heap = new_unit;
            }
        }
    }
}

pub fn protectRange(self: *Self, base: usize, pages: u32, flags: MapUnit.Flags) vfs.Error!void {
    defer self.validate();

    self.map_lock.writeLock();
    defer self.map_lock.writeUnlock();

    const top = base + @as(usize, pages) * vm.page_size;
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
            const prev = MapUnit.fromRbNode(base_unit.rb_node.prev() orelse return error.NoMemory);
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
        const max_top = @min(vm.max_userspace_addr + 1, top + @as(usize, self.stack_pages) * vm.page_size);
        const map_unit = self.lookupMapUnit(top, max_top) orelse return error.NoEnt;
        const target_size = vm.bytesToPagesExact(map_unit.base() - address) + map_unit.page_capacity;

        break :blk if (map_unit.flags.grow_down and target_size <= self.stack_pages) map_unit else return error.NoEnt;
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

    const trampoline = blk: {
        const map_unit = self.lookupMapUnit(
            sys.exe.start_trampoline_addr,
            sys.exe.start_trampoline_addr + vm.page_size
        ) orelse break :blk null;
        break :blk if (
            map_unit.isAnonymous() and map_unit.flags.map.exec and !map_unit.flags.map.write
        ) map_unit else null;
    };
    const stack = blk: {
        const map_unit = self.lookupMapUnit(
            sys.exe.start_stack_addr,
            sys.exe.start_args_addr
        ) orelse break :blk null;
        break :blk if (map_unit.flags.grow_down) map_unit else null;
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
        else if (map_unit == trampoline)
            try writer.writeAll("[trampoline]\n")
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

            // FIXME: Divide mapping should also reinsert pages into `middle_unit`,
            //        but currently it just unmaps the middle area, this is buggy!!!
            try self.divideMapping(map_unit, middle_unit);

            self.includeMapping(middle_unit);
            try middle_unit.map(self.page_table);
        } else {
            const top_unit = try map_unit.fork();
            errdefer top_unit.delete(self.page_table);

            top_unit.flags = flags;
            top_unit.moveBaseUp(base_pages);

            try map_unit.reinsertRegion(top_unit, base_pages, top_unit.page_capacity);
            map_unit.page_capacity -= top_unit.page_capacity;

            self.includeMapping(top_unit);
            try top_unit.map(self.page_table);
        }
    } else if (top < map_unit.top()) {
        const base_unit = try map_unit.fork();
        const base_pages = vm.bytesToPagesExact(top - map_unit.base());
        errdefer base_unit.delete(self.page_table);

        base_unit.flags = flags;
        base_unit.page_capacity = base_pages;

        try map_unit.reinsertRegion(base_unit, 0, base_pages);
        map_unit.moveBaseUp(base_pages);

        self.includeMapping(base_unit);
        try base_unit.map(self.page_table);
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
    const size = @as(usize, pages) * vm.page_size;

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
    const rb_node = self.rb_tree.lookup(.{ base, top }) orelse return null;
    return MapUnit.fromRbNode(rb_node);
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

fn divideMapping(self: *Self, map_unit: *MapUnit, div_unit: *MapUnit) !void {
    const new_base = div_unit.top();
    const new_pg_gap = vm.bytesToPagesExact(new_base - map_unit.base());
    const new_pg_size = vm.bytesToPagesExact(map_unit.top() - new_base);
    const new_pg_off = new_pg_gap + map_unit.page_offset;

    const new_unit = vm.auto.alloc(MapUnit) orelse return error.NoMemory;
    errdefer vm.auto.free(MapUnit, new_unit);

    const map_pg_size = vm.bytesToPagesExact(div_unit.base() - map_unit.base());
    try map_unit.unmapRegion(map_pg_size, div_unit.page_capacity, self.page_table);

    new_unit.* = .init(
        map_unit.file, new_base, new_pg_off,
        new_pg_size, map_unit.flags
    );

    try map_unit.reinsertRegion(new_unit, new_pg_gap, new_pg_size);
    map_unit.page_capacity = map_pg_size;

    self.includeMapping(new_unit);
}

fn cutMapping(self: *Self, map_unit: *MapUnit, offset: usize, pages: u32) !*MapUnit {
    const new_base = map_unit.base() + offset + @as(usize, pages) * vm.page_size;
    const new_top = map_unit.top();
    const new_pages = vm.bytesToPagesExact(new_top - new_base);

    const new_unit = try map_unit.fork();
    errdefer new_unit.delete(self.page_table);

    new_unit.region.base = new_base;
    new_unit.page_capacity = new_pages;

    const page_offset = vm.bytesToPagesExact(offset);
    if (new_unit.file != null) new_unit.page_offset += page_offset + pages;

    try map_unit.unmapRegion(page_offset, pages, self.page_table);
    try map_unit.reinsertRegion(new_unit, page_offset + pages, new_pages);
    map_unit.page_capacity = vm.bytesToPagesExact(offset);

    self.includeMapping(new_unit);
    return new_unit;
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
    map_unit.delete(self.page_table);
}

fn removeMapping(self: *Self, map_unit: *MapUnit) void {
    self.rb_tree.remove(&map_unit.rb_node);
    self.map_units.remove(&map_unit.node);
}

fn validate(self: *Self) void {
    if (comptime !lib.is_debug) return;

    _ = self.rb_tree.validate() catch |err| {
        std.log.err("rb invalid: {}", .{err});
        std.log.info("{f}", .{self});
    };
}
