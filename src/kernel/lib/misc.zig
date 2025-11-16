// Copyright (C) 2024-2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

pub inline fn alignUp(comptime T: type, value: T, alignment: T) T {
    return ((value + (alignment - 1)) & ~(alignment - 1));
}

pub inline fn alignDown(comptime T: type, value: T, alignment: T) T {
    return value & ~(alignment - 1);
}

pub inline fn divByPowerOfTwo(comptime T: type, value: T, pow_of_2: std.math.Log2Int(T)) T {
    return value >> pow_of_2;
}

pub inline fn modByPowerOfTwo(comptime T: type, value: T, pow_of_2: std.math.Log2Int(T)) T {
    const mask = ~@as(T, 0) << pow_of_2;
    return value & (~mask);
}
