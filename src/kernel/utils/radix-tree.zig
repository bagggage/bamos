//! # Radix Tree

const std = @import("std");
const builtin = @import("builtin");

const atomic = std.atomic;
const utils = if (!builtin.is_test) @import("../utils.zig") else void;
const vm = if (!builtin.is_test) @import("../vm.zig") else void;

pub const Handle = struct {
    const ptr_mask = @as(usize, std.math.maxInt(usize)) << 1;
    const flag_mask = 1;

    value: usize = 0,

    pub const nul = Handle{ .value = 0 };

    pub inline fn init(val: anytype, is_leaf: bool) Handle {
        const mask = if (is_leaf) flag_mask else 0;
        return .{ .value = @intFromPtr(val) | mask };
    }

    pub inline fn isNull(self: Handle) bool {
        return self.value == 0;
    }

    pub inline fn isLeaf(self: Handle) bool {
        return (self.value & flag_mask) != 0;
    }

    pub inline fn isTable(self: Handle) bool {
        return (self.value & flag_mask) == 0 and self.value != 0;
    }

    pub inline fn ptr(self: Handle, comptime T: type) *T {
        return @ptrFromInt(self.value & ptr_mask);
    }
};

pub fn TableNode(width: comptime_int) type {
    return struct {
        const Self = @This();
        
        const vec_len = (std.simd.suggestVectorLength(Handle) orelse 0) / @bitSizeOf(Handle);
        const alignment = if (vec_len > 0) (vec_len * @sizeOf(usize)) else @alignOf(usize);

        var oma: vm.SafeOma(Self) = .init(8);

        entries: [width]Handle = .{Handle.nul} ** width,
        count: atomic.Value(usize) align(alignment) = .init(0),
        //lock: utils.RwLock = .{},

        pub fn new() !*Self {
            const table = oma.alloc() orelse return error.NoMemory;
            table.* = .{};
            return table;
        }

        pub inline fn delete(self: *Self) void {
            oma.free(self);
        }

        pub inline fn hasEntries(self: *const Self) bool {
            return self.count.load(.acquire) > 0;
        }

        pub inline fn isSingleEntry(self: *const Self) bool {
            return self.count.load(.acquire) == 1;
        }

        pub inline fn addEntry(self: *Self, idx: usize, handle: Handle) void {
            _ = self.count.fetchAdd(1, .release);
            self.entries[idx] = handle;
        }

        pub inline fn removeEntry(self: *Self, idx: usize) void {
            _ = self.count.fetchSub(1, .acquire);
            self.entries[idx] = Handle.nul;
        }

        pub fn findSingleEntry(self: *const Self) Handle {
            std.debug.assert(self.count.raw == 1);

            if (comptime vec_len > 0) {
                const Vec: type = @Vector(vec_len, usize);

                const vec_arr: *const [width / vec_len]Vec = @alignCast(@ptrCast(&self.entries));
                const zero: Vec = @splat(0);

                for (0..vec_arr.len) |i| {
                    const cmps = vec_arr[i] != zero;
                    if (std.simd.firstTrue(cmps)) |j| {
                        return self.entries[i * vec_len + j];
                    }
                }
            } else {
                for (0..width) |i| {
                    if (self.entries[i].isNull()) continue;
                    return self.entries[i];
                }
            }

            unreachable;
        }
    };
}

/// Radix Tree structure.
///
/// - `K` key type, must be unsigned integer.
/// - `V` value type.
/// - `Hasher` opaque or struct that contains defenitions
/// of `Result: type`, `fn hash(key: K) Result`, `fn keyByValue(val: *V) K`.
/// - `width` is number of entries per one table,
/// this value must be a power of two.
pub fn RadixTree(comptime K: type, comptime V: type, comptime Hasher: type, width: comptime_int) type {
    comptime {
        const key_type = @typeInfo(K);

        if (key_type != .int or key_type.int.signedness == .signed) {
            @compileError("Key in a radix tree must be unsigned integer!");
        }

        if (width < 2 or !std.math.isPowerOfTwo(width)) {
            @compileError("Width must be a power of two and >1 !");
        }

        // This is implementation detail: because `flag` (see Handle struct)
        // is stored in lower bit in pointer to value, so make sure that
        // this bit is not used by pointer to store memory address.
        if (@alignOf(V) < 2) {
            @compileError("Value type must have alignment >1 (see `Handle` struct)!");
        }
    }

    const H: type = Hasher.Result;
    const hashKey: fn (key: K) H = Hasher.hash;
    const keyByValue: fn (val: *V) K = Hasher.keyByValue;

    const bit_shift: comptime_int = comptime std.math.log2(width);
    const bit_mask: comptime_int = comptime width - 1;

    return struct {
        const Self = @This();
        const Table = TableNode(width);

        pub const max_level = (@bitSizeOf(H) + (bit_shift - 1)) / bit_shift;

        root: ?*Table = null,

        pub fn deinit(self: *Self) void {
            if (self.root == null) {
                @branchHint(.unlikely);
                return;
            }

            defer self.root = null;

            var level: u8 = 0;
            var table = self.root.?;
            var idx: usize = 0;
            var table_stack: [max_level]struct { ptr: *Table, idx: usize } = undefined;

            while (level < max_level) {
                if (level == max_level - 1 or idx >= width) {
                    table.delete();

                    if (level == 0) break;

                    level -= 1;
                    table = table_stack[level].ptr;
                    idx = table_stack[level].idx;

                    continue;
                }

                for (idx..width) |i| {
                    const handle = table.entries[i];
                    if (handle.isTable() == false) {
                        idx += 1;
                        continue;
                    }

                    table_stack[level] = .{ .ptr = table, .idx = i + 1 };

                    level +%= 1;
                    table = handle.ptr(Table);
                    idx = 0;

                    break;
                }
            }
        }

        pub fn insert(self: *Self, key: K, value: *V) !void {
            const handle: Handle = .init(value, true);
            const hash = hashKey(key);

            var temp = std.math.rotl(H, hash, bit_shift);

            if (self.root == null) {
                @branchHint(.unlikely);

                const table = try Table.new();
                const idx = temp & bit_mask;

                table.addEntry(idx, handle);
                self.root = table;

                return;
            }

            var table = self.root.?;

            for (0..max_level) |level| {
                const idx = temp & bit_mask;
                const curr_handle = table.entries[idx];

                if (curr_handle.isNull()) {
                    table.addEntry(idx, handle);
                    return;
                } else if (curr_handle.isLeaf()) {
                    const curr_val = curr_handle.ptr(V);
                    const curr_key = keyByValue(curr_val);

                    // Replace value
                    if (curr_key == key) {
                        table.entries[idx] = handle;
                        return;
                    }

                    // Create new level
                    const new_table = try Table.new();

                    const curr_hash = hashKey(curr_key);
                    const curr_temp = std.math.rotl(H, curr_hash, bit_shift * (level + 2));
                    const curr_idx = curr_temp & bit_mask;

                    new_table.addEntry(curr_idx, curr_handle);
                    table.entries[idx] = .init(new_table, false);

                    table = new_table;
                } else {
                    table = table.entries[idx].ptr(Table);
                }

                temp = std.math.rotl(H, temp, bit_shift);
            }

            unreachable;
        }

        pub fn lookup(self: *const Self, key: K) ?*V {
            const hash = hashKey(key);
            var dummy_stack: [max_level]?*Table = undefined;

            return self.lookupThrow(key, hash, &dummy_stack);
        }

        pub fn remove(self: *Self, key: K) ?*V {
            const bits_left = comptime @bitSizeOf(H) % bit_shift;

            const hash = hashKey(key);
            var table_stack: [max_level]?*Table = .{null} ** max_level;

            const val = self.lookupThrow(
                key, hash, &table_stack
            ) orelse return null;
            var temp = if (comptime bits_left > 0) std.math.rotl(
                H, hash, bit_shift - bits_left
            ) else hash;

            for (0..max_level) |i| {
                var level = (max_level - 1) - i;

                if (table_stack[level]) |t| {
                    var table = t;
                    table.removeEntry(temp & bit_mask);

                    // Index of handle in a parent table
                    temp = std.math.rotr(H, temp, bit_shift);
                    var idx = temp & bit_mask;

                    // Cleanup tables
                    while (level > 0) : ({
                        level -= 1;
                        temp = std.math.rotr(H, temp, bit_shift);
                        idx = temp & bit_mask;
                    }) {
                        const count = table.count.load(.acquire);
                        if (count > 1) return val;

                        const parent_table = table_stack[level - 1].?;
                        if (count == 1) {
                            const single_ent = table.findSingleEntry();
                            // TODO: Rebuild subtree?
                            if (single_ent.isTable()) return val;

                            parent_table.entries[idx] = single_ent;
                        } else {
                            parent_table.removeEntry(idx);
                        }

                        table.delete();
                        table = parent_table;
                    }

                    // Handle root table
                    if (table.hasEntries()) break;

                    self.root = null;
                    table.delete();

                    break;
                }

                temp = std.math.rotr(H, temp, bit_shift);
            }

            return val;
        }

        fn lookupThrow(self: *const Self, key: K, hash: H, table_stack: *[max_level]?*Table) ?*V {
            if (self.root == null) {
                @branchHint(.unlikely);
                return null;
            }

            var temp = std.math.rotl(H, hash, bit_shift);
            var table = self.root.?;

            for (0..max_level) |level| {
                table_stack[level] = table;

                const idx = temp & bit_mask;
                const handle = table.entries[idx];

                if (handle.isNull()) {
                    break;
                } else if (handle.isLeaf()) {
                    const curr_val: *V = handle.ptr(V);
                    const curr_key: K = keyByValue(curr_val);

                    return if (curr_key == key) curr_val else null;
                }

                table = handle.ptr(Table);
                temp = std.math.rotl(H, temp, bit_shift);
            }

            return null;
        }
    };
}

const TestHasher = opaque {
    pub const Result = u32;

    pub fn hash(key: u32) Result {
        const result = std.hash.Fnv1a_32.hash(std.mem.asBytes(&key));
        return result;
    }

    pub fn keyByValue(val: *u32) u32 {
        return val.*;
    }
};

const TestTree = RadixTree(u32, u32, TestHasher, 2);

test "insert and lookup" {
    const expect = std.testing.expect;

    var tree: TestTree = .{};
    defer tree.deinit();

    var values = [_]u32{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };

    try expect(tree.lookup(0) == null);

    try tree.insert(5, &values[5]);
    try tree.insert(0, &values[0]);
    try tree.insert(10, &values[10]);

    try expect(tree.lookup(1) == null);
    try expect(tree.lookup(0) == &values[0]);
    try expect(tree.lookup(10) == &values[10]);
    try expect(tree.lookup(8) == null);
    try expect(tree.lookup(5) == &values[5]);
}

test "insert, remove and lookup" {
    const expect = std.testing.expect;

    var tree: TestTree = .{};
    defer tree.deinit();

    var values = [_]u32{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };

    try expect(tree.lookup(0) == null);

    try tree.insert(0, &values[0]);
    try tree.insert(2, &values[2]);
    try tree.insert(4, &values[4]);
    try tree.insert(6, &values[6]);
    try tree.insert(7, &values[7]);
    try tree.insert(10, &values[10]);

    try expect(tree.lookup(8) == null);
    try expect(tree.lookup(9) == null);

    try expect(tree.lookup(0) == &values[0]);
    try expect(tree.lookup(4) == &values[4]);
    try expect(tree.lookup(7) == &values[7]);
    try expect(tree.lookup(10) == &values[10]);

    try expect(tree.remove(2) == &values[2]);

    try expect(tree.lookup(4) == &values[4]);
    try expect(tree.lookup(0) == &values[0]);
    try expect(tree.lookup(2) == null);

    try expect(tree.remove(2) == null);

    try expect(tree.remove(0) == &values[0]);
    try expect(tree.remove(4) == &values[4]);

    try expect(tree.remove(0) == null);
    try expect(tree.remove(4) == null);

    try expect(tree.lookup(7) == &values[7]);
    try expect(tree.lookup(6) == &values[6]);

    try tree.insert(4, &values[4]);

    try expect(tree.lookup(4) == &values[4]);
    try expect(tree.lookup(6) == &values[6]);

    try expect(tree.remove(4) == &values[4]);
    try expect(tree.remove(6) == &values[6]);
    try expect(tree.remove(7) == &values[7]);
    try expect(tree.remove(10) == &values[10]);

    try expect(tree.root == null);
}
