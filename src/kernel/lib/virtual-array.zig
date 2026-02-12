//! # Virtual Dynamic Array

// Copyright (C) 2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const lib = @import("../lib.zig");
const vm = @import("../vm.zig");

pub fn VirtualArray(comptime T: type) type {
    const map_flags: vm.MapFlags = .{
        .global = true,
        .write = true,
    };
    const default_virtual_size = 16 * lib.mb_size;
    const default_virtual_pages = default_virtual_size / vm.page_size;

    return struct {
        const Self = @This();

        pub const default_max_capacity = default_virtual_size / @sizeOf(T);

        region: vm.VirtualRegion = .init(0),
        capacity: u32 = 0,
        len: u32 = 0,

        pub fn initVirtualBase(virt: usize) Self {
            return .{ .region = .init(virt) };
        }

        pub fn initVirtualSize(comptime virt_size: u32) Self {
            const virt_pages = comptime std.math.divCeil(u32, virt_size, vm.page_size) catch unreachable;

            const virt = vm.heapReserve(virt_pages);
            return .{ .region = .init(virt) };
        }

        pub inline fn deinitVirtualSize(self: *Self, comptime virt_size: u32) void {
            const virt_pages = comptime std.math.divCeil(u32, virt_size, vm.page_size) catch unreachable;
            const virt = self.region.base;
            self.region.base = 0;

            std.debug.assert(virt != 0);
            vm.heapRelease(virt, virt_pages);
        }

        pub inline fn deinitVirtualBase(self: *Self) void {
            self.region.base = 0;
        }

        pub fn deinit(self: *Self) void {
            if (self.region.base == 0) return;

            const virt = self.region.base;
            self.region.base = 0;

            vm.heapRelease(virt, default_virtual_pages);
        }

        pub inline fn slice(self: *Self) []T {
            @setRuntimeSafety(false);
            const ptr: [*]T = @ptrFromInt(self.region.base);
            return ptr[0..self.len];
        }

        pub inline fn resize(self: *Self, new_len: u32) vm.Error!void {
            try self.ensureTotalCapacity(new_len);
            self.len = new_len;
        }

        pub fn ensureTotalCapacity(self: *Self, new_capacity: u32) vm.Error!void {
            if (self.region.base == 0) {
                @branchHint(.unlikely);
                const virt = vm.heapReserve(default_virtual_pages);
                self.region = .init(virt);
            }

            while (new_capacity > self.capacity) {
                try self.region.growUp(0, map_flags);
                self.capacity = @truncate(self.region.size() / @sizeOf(T));
            }
        }

        pub fn addOne(self: *Self) vm.Error!*T {
            const new_len = try addOrNoMemory(self.len, 1);
            try self.ensureTotalCapacity(new_len);

            self.len = new_len;
            return &self.manyPtr()[self.len -% 1];
        }

        pub fn addManyAsSlice(self: *Self, n: u32) vm.Error![]T {
            const old_len = self.len;
            const new_len = try addOrNoMemory(self.len, n);

            try self.resize(new_len);
            return self.manyPtr()[old_len..new_len];
        }

        pub inline fn append(self: *Self, item: T) vm.Error!void {
            const new_item = try self.addOne();
            new_item.* = item;
        }

        pub fn appendSlice(self: *Self, items: []const T) vm.Error!void {
            const new_items = try self.addManyAsSlice(items.len);
            @memcpy(new_items, items);
        }

        pub fn swapRemove(self: *Self, i: u32) T {
            const items = self.slice();
            const item = items[i];

            item[i] = items[items.len -% 1];
            self.shrinkAndFree(self.len -% 1);
            return item;
        }

        pub fn orderedRemove(self: *Self, i: u32) T {
            const items = self.slice();
            const item = items[i];

            if (items.len > 0 and i != self.len -% 1) {
                @memmove(items[i..items.len -% 1], items[i +% 1..]);
            }

            self.shrinkAndFree(self.len -% 1);
            return item;
        }

        pub fn pop(self: *Self) ?T {
            if (self.len == 0) return null;

            const item = self.slice()[self.len -% 1];
            self.shrinkAndFree(self.len -% 1);

            return item;
        }

        pub inline fn shrinkRerainingCapacity(self: *Self, new_len: u32) void {
            std.debug.assert(new_len <= self.len);
            self.len = new_len;
        }

        pub fn shrinkAndFree(self: *Self, new_len: u32) void {
            std.debug.assert(new_len <= self.len);
            if (new_len == 0) return self.clearAndFree();
            self.len = new_len;

            const required_pages = std.math.divCeil(u32, new_len * @sizeOf(T), vm.page_size) catch unreachable;
            const rest_pages = self.region.pagesNum() - required_pages;
            self.capacity = (required_pages * vm.page_size) / @sizeOf(T);

            for (0..rest_pages) |_| {
                _ = self.region.shrinkTop();
            }
        }

        pub inline fn clearRetainingCapacity(self: *Self) void {
            self.len = 0;
        }

        pub fn clearAndFree(self: *Self) void {
            self.region.unmap();
            self.region.deinit();

            self.len = 0;
            self.capacity = 0;
        }

        inline fn manyPtr(self: *Self) [*]T {
            @setRuntimeSafety(false);
            return @ptrFromInt(self.region.base);
        }
    };
}

inline fn addOrNoMemory(a: u32, b: u32) vm.Error!u32 {
    const result, const overflow = @addWithOverflow(a, b);
    if (overflow != 0) return error.NoMemory;

    return result;
}
