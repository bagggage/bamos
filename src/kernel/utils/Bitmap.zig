//! # Bitmap

// Copyright (C) 2024 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const utils = @import("../utils.zig"); 

const Self = @This();

bits: []u8 = &.{},

pub inline fn init(bits: []u8, comptime is_setted: bool) Self {
    @memset(bits, if (is_setted) 0xFF else 0);

    return Self{
        .bits = bits
    };
}

pub inline fn get(self: *Self, bit_idx: usize) u8 {
    return self.bits[bit_idx / utils.byte_size] & bitmask(bit_idx);
}

pub inline fn clear(self: *Self, bit_idx: usize) void {
    self.bits[bit_idx / utils.byte_size] &= ~bitmask(bit_idx);
}

pub inline fn set(self: *Self, bit_idx: usize) void {
    self.bits[bit_idx / utils.byte_size] |= bitmask(bit_idx);
}

pub inline fn toggle(self: *Self, bit_idx: usize) void {
    self.bits[bit_idx / utils.byte_size] ^= bitmask(bit_idx);
}

pub fn find(self: *Self, comptime is_setted: bool) ?usize {
    @setRuntimeSafety(false);

    const bytes_num = self.bits.len & (@bitSizeOf(usize) - 1);
    const words_num = (self.bits.len - bytes_num) / @bitSizeOf(usize);

    const words: [*]align(1) const usize = @ptrCast(self.bits.ptr);
    const bytes = self.bits.ptr;

    if (findGranulated(usize, is_setted, words[0..words_num])) |bit|
        return bit;

    const begin = self.bits.len & (~@as(usize, @bitSizeOf(usize) - 1));
    return findGranulated(u8, is_setted, bytes[begin..bytes_num]);
}

pub fn rfind(self: *Self, comptime is_setted: bool) ?usize {
    const byte_val = if (is_setted) 0x00 else 0xFF;
    var byte_idx = self.bits.len;

    while (byte_idx > 0) {
        byte_idx -= 1;

        const byte = self.bits[byte_idx];
        if (byte == byte_val) continue;

        return (byte_idx * utils.byte_size) + if (comptime is_setted) @ctz(byte) else @ctz(~byte);
    }

    return null;
}

inline fn bitmask(bit_idx: usize) u8 {
    return @as(u8,1) << @truncate(@mod(bit_idx, utils.byte_size));
}

inline fn findGranulated(
    comptime Int: type,
    comptime is_setted: bool,
    ints: []align(1) const Int
) ?usize {
    const int_val = if (comptime is_setted) 0x00 else std.math.maxInt(Int);

    for (ints[0..], 0..) |int, idx| {
        if (int == int_val) continue;

        const bit_idx = if (comptime is_setted) @ctz(int) else @ctz(~int);
        return idx * @bitSizeOf(Int) + bit_idx;
    }

    return null;
}