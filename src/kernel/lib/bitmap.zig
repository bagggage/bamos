//! # Bitmap

// Copyright (C) 2024-2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const lib = @import("../lib.zig"); 

pub const BitmapUnbounded = struct {
    bytes: [*]u8,

    pub inline fn init(bytes: []u8, comptime is_setted: bool) BitmapUnbounded {
        @memset(bytes, if (is_setted) 0xFF else 0);
        return .{ .bytes = bytes.ptr };
    }

    pub inline fn get(self: BitmapUnbounded, bit_idx: usize) u8 {
        return self.bytes[bit_idx >> lib.byte_shift] & bitmask(bit_idx);
    }

    pub inline fn clear(self: BitmapUnbounded, bit_idx: usize) void {
        self.bytes[bit_idx >> lib.byte_shift] &= ~bitmask(bit_idx);
    }

    pub inline fn set(self: BitmapUnbounded, bit_idx: usize) void {
        self.bytes[bit_idx >> lib.byte_shift] |= bitmask(bit_idx);
    }

    pub inline fn toggle(self: BitmapUnbounded, bit_idx: usize) void {
        self.bytes[bit_idx >> lib.byte_shift] ^= bitmask(bit_idx);
    }

    pub fn find(self: BitmapUnbounded, bit_len: usize, comptime is_setted: bool) ?usize {
        @setRuntimeSafety(false);

        const byte_len = bitsToBytes(bit_len);
        const bytes_num = byte_len & (@bitSizeOf(usize) - 1);
        const words_num = (byte_len - bytes_num) / @bitSizeOf(usize);

        const words: [*]align(1) const usize = @ptrCast(self.bytes);
        if (findGranulated(usize, is_setted, words[0..words_num], bit_len)) |bit| return bit;

        const begin = byte_len & (~@as(usize, @bitSizeOf(usize) - 1));
        return findGranulated(u8, is_setted, self.bytes[begin..bytes_num], bit_len);
    }

    pub fn rfind(self: BitmapUnbounded, bit_len: usize, comptime is_setted: bool) ?usize {
        const byte_val = if (comptime is_setted) 0x00 else 0xFF;
        var byte_idx = bitsToBytes(bit_len);

        while (byte_idx > 0) {
            byte_idx -%= 1;

            const byte = self.bytes[byte_idx];
            if (byte == byte_val) continue;

            const bit_idx = (byte_idx << lib.byte_shift) + if (comptime is_setted) @ctz(byte) else @ctz(~byte);
            if (bit_idx < bit_len) return bit_idx;
        }

        return null;
    }
};

pub const Bitmap = struct {
    unbounded: BitmapUnbounded = .{ .bytes = undefined },
    bit_len: usize = 0,

    pub inline fn init(bytes: []u8, bit_len: usize, comptime is_setted: bool) Bitmap {
        std.debug.assert(bytes.len >= bitsToBytes(bit_len));
        defer {
            const mask = @as(u8, 0xFF) << @truncate(bit_len % lib.byte_size);
            bytes[bytes.len - 1] = if (comptime is_setted) ~mask else mask;
        }

        return .{
            .unbounded = .init(bytes, is_setted),
            .bit_len = bit_len
        };
    }

    pub inline fn byteLen(self: Bitmap) usize {
        return bitsToBytes(self.bit_len);
    }

    pub inline fn get(self: Bitmap, bit_idx: usize) u8 {
        std.debug.assert(bit_idx < self.bit_len);
        return self.unbounded.get(bit_idx);
    }

    pub inline fn clear(self: Bitmap, bit_idx: usize) void {
        std.debug.assert(bit_idx < self.bit_len);
        self.unbounded.clear(bit_idx);
    }

    pub inline fn set(self: Bitmap, bit_idx: usize) void {
        std.debug.assert(bit_idx < self.bit_len);
        self.unbounded.set(bit_idx);
    }

    pub inline fn toggle(self: Bitmap, bit_idx: usize) void {
        std.debug.assert(bit_idx < self.bit_len);
        self.unbounded.toggle(bit_idx);
    }

    pub inline fn find(self: Bitmap, comptime is_setted: bool) ?usize {
        return self.unbounded.find(self.bit_len, is_setted);
    }

    pub inline fn rfind(self: Bitmap, comptime is_setted: bool) ?usize {
        return self.unbounded.rfind(self.bit_len, is_setted);
    }
};

inline fn bitsToBytes(bits: usize) usize {
    return (bits + (lib.byte_size - 1)) >> lib.byte_shift;
}

inline fn bitmask(bit_idx: usize) u8 {
    const shift = bit_idx & @as(u8, lib.byte_size - 1);
    return @as(u8, 1) << @truncate(shift);
}

inline fn findGranulated(
    comptime Int: type,
    comptime is_setted: bool,
    ints: []align(1) const Int,
    bit_len: usize
) ?usize {
    const int_val = if (comptime is_setted) 0x00 else std.math.maxInt(Int);

    for (ints[0..], 0..) |int, idx| {
        if (int == int_val) continue;

        const inner_bit_idx = if (comptime is_setted) @ctz(int) else @ctz(~int);
        const bit_idx = idx * @bitSizeOf(Int) + inner_bit_idx;

        if (bit_idx < bit_len) {
            @branchHint(.likely);
            return bit_idx;
        }

        break;
    }

    return null;
}
