//! # Number allocator
//! 
//! Simple and fast, but have some
//! constraints.

const std = @import("std");

pub fn NumberAllocRanged(comptime Int: type, min: comptime_int, max: comptime_int) type {
    return struct {
        const Self = @This();

        top: Int = min,

        // Free range bottom border.
        free_low: Int = min,
        // Number of allocated nums in free range.
        range_num: Int = 0,

        pub fn alloc(self: *Self) ?Int {
            if (self.top >= max) return null;

            const result = self.top;
            self.top +%= 1;

            if (self.range_num == 0) {
                self.free_low = self.top;
            } else {
                self.range_num +%= 1;
            }

            return result;
        }

        pub fn free(self: *Self, num: Int) void {
            if (num < self.free_low) {
                self.range_num +%= (self.free_low - num) - 1;
                self.free_low = num;

                if (self.range_num == 0) self.top = self.free_low;
            } else {
                self.range_num -%= 1;

                if (self.range_num == 0) {
                    self.top = self.free_low;
                } else if (self.top -% 1 == num) {
                    self.top -%= 1;
                }
            }
        }
    };
}

pub fn NumberAllocFloor(comptime Int: type, min: comptime_int) type {
    return NumberAllocRanged(Int, min, std.math.maxInt(Int));
}

pub fn NumberAllocCeil(comptime Int: type, max: comptime_int) type {
    return NumberAllocRanged(Int, std.math.minInt(Int), max);
}

pub fn NumberAlloc(comptime Int: type) type {
    return NumberAllocRanged(Int, std.math.minInt(Int), std.math.maxInt(Int));
}

const expect = std.testing.expect;

test "random alloc/free" {
    var self: NumberAlloc(u8) = .{};
    
    try expect(self.alloc() == 0);
    try expect(self.alloc() == 1);
    try expect(self.alloc() == 2);
    try expect(self.alloc() == 3);
    try expect(self.alloc() == 4);
    try expect(self.alloc() == 5);

    self.free(1);
    self.free(3);
    self.free(2);
    self.free(0);

    try expect(self.alloc() == 6);
    self.free(6);

    try expect(self.alloc() == 6);

    self.free(6);
    self.free(5);

    try expect(self.alloc() == 5);

    self.free(4);
    self.free(5);

    try expect(self.alloc() == 0);
    try expect(self.alloc() == 1);
    try expect(self.alloc() == 2);

    self.free(1);
    self.free(2);
    self.free(0);

    try expect(self.alloc() == 0);
    try expect(self.alloc() == 1);
    try expect(self.alloc() == 2);
}

test "min max" {
    var self: NumberAllocRanged(u8, 10, 15) = .{};

    try expect(self.alloc() == 10);
    try expect(self.alloc() == 11);
    try expect(self.alloc() == 12);
    try expect(self.alloc() == 13);
    try expect(self.alloc() == 14);

    try expect(self.alloc() == null);
    try expect(self.alloc() == null);
    try expect(self.alloc() == null);

    self.free(13);
    self.free(10);

    try expect(self.alloc() == null);

    self.free(14);
    self.free(11);

    // Only 14, not 13, because allocator don't store information
    // about each free range, but only about full range that contains some free entries.
    try expect(self.alloc() == 14);

    self.free(12);
    self.free(13);

    try expect(self.alloc() == 10);
    try expect(self.alloc() == 11);
    try expect(self.alloc() == 12);
    try expect(self.alloc() == 13);
    try expect(self.alloc() == 14);
}
