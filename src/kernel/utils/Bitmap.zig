//! # Bitmap

// Copyright (C) 2024 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const log = @import("../log.zig");
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
    const byte_val = if (is_setted) 0x00 else 0xFF;

    for (0..self.bits.len) |byte_idx| {
        const byte = self.bits[byte_idx];

        if (byte == byte_val) continue;

        for (0..utils.byte_size) |i| {
            const is_curr_setted = (byte & bitmask(i)) != 0;
            if (is_curr_setted == is_setted) return (byte_idx * utils.byte_size) + i;
        }
    }

    return null;
}

pub fn rfind(self: *Self, comptime is_setted: bool) ?usize {
    const byte_val = if (is_setted) 0x00 else 0xFF;
    var byte_idx = self.bits.len;

    while (byte_idx > 0) {
        byte_idx -= 1;

        const byte = self.bits[byte_idx];

        if (byte == byte_val) continue;

        for (0..utils.byte_size) |i| {
            const is_curr_setted = (byte & bitmask(i)) != 0;
            if (is_curr_setted == is_setted) return (byte_idx * utils.byte_size) + i;
        }
    }

    return null;
}

inline fn bitmask(bit_idx: usize) u8 {
    return @as(u8,1) << @truncate(@mod(bit_idx, utils.byte_size));
}