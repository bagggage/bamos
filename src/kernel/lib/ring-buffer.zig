//! # Ring Buffer

// Copyright (C) 2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const lib = @import("../lib.zig");
const vm = @import("../vm.zig");

pub fn RingBuffer(comptime T: type) type {
    return struct {
        const Self = @This();
        const max_capacity = std.math.maxInt(u16);

        ptr: [*]T = undefined,
        len: u16 = 0,

        read_pos: u16 = 0,
        write_pos: u16 = 0,

        lock: lib.sync.Spinlock = .{},

        pub fn create(capacity: u16) vm.Error!Self {
            const raw_size = @as(u32, capacity) * @sizeOf(T);
            const target_size = std.math.ceilPowerOfTwo(u32, raw_size) catch std.math.floorPowerOfTwo(u32, raw_size);
            var len: u16 = undefined;

            const buffer = try if (target_size >= vm.page_size)
                allocPages(target_size, &len)
            else
                allocGpa(target_size, &len);

            return .{ .ptr = buffer, .len = len };
        }

        pub fn delete(self: *Self) void {
            const size = @as(u32, self.len) * @sizeOf(T);
            defer self.len = 0;

            if (size >= vm.page_size) {
                const phys = vm.getPhysLma(self.ptr);
                const rank = vm.bytesToRank(size);
                vm.PageAllocator.free(phys, rank);
            } else {
                vm.gpa.free(self.ptr);
            }
        }

        pub fn pushOverflow(self: *Self, value: T) void {
            const tmp_pos = self.write_pos;
            self.write_pos = self.nextPos(self.write_pos);

            if (self.write_pos == self.read_pos) {
                self.read_pos = self.nextPos(self.read_pos);
            }

            self.ptr[tmp_pos] = value;
        }

        pub fn push(self: *Self, value: T) vm.Error!void {
            if (self.write_pos == self.lastWritePos()) {
                @branchHint(.unlikely);
                return error.MaxSize;
            }

            const tmp_pos = self.write_pos;
            self.write_pos = self.nextPos(self.write_pos);
            self.ptr[tmp_pos] = value;
        }

        pub fn pop(self: *Self) ?T {
            if (self.read_pos == self.write_pos) return null;

            const tmp_pos = self.read_pos;
            self.read_pos = self.nextPos(self.read_pos);
            return self.ptr[tmp_pos];
        }

        fn allocPages(size: u32, len: *u16) vm.Error![*]T {
            const rank = vm.bytesToRank(size);
            const phys = vm.PageAllocator.alloc(rank) orelse return error.NoMemory;

            const virt = vm.getVirtLma(phys);
            const real_len = vm.rankToBytes(rank) / @sizeOf(T);
            len.* = std.math.floorPowerOfTwo(u16, @intCast(real_len));

            return @ptrFromInt(virt);
        }

        fn allocGpa(size: u32, len: *u16) vm.Error![*]T {
            const real_len = size / @sizeOf(T);
            const ptr = vm.gpa.allocMany(T, real_len) orelse return error.NoMemory;

            len.* = std.math.floorPowerOfTwo(u16, @intCast(real_len));
            return ptr.ptr;
        }

        inline fn lastWritePos(self: *const Self) u16 {
            return (self.read_pos -% 1) & (self.len -% 1);
        }

        inline fn nextPos(self: *const Self, pos: u16) u16 {
            return (pos +% 1) & (self.len -% 1);
        }
    };
}
