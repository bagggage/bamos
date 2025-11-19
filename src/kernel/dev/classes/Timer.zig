//! # Timer deivce high-level interface

const std = @import("std");

const dev = @import("../../dev.zig");
const log = std.log.scoped(.Timer);

const Self = @This();

const SupportedModes = enum(u8) {
    once = 1,
    periodic = 2,
    both = 3
};

pub const Error = error {
    BadOperation,
    BadFrequency,
    BadCounterValue,
    UnsupportedMode,
};

pub const Kind = enum(u8) {
    system_low,
    system_high,
    embedded
};

pub const Mode = enum(u8) {
    once = 1,
    periodic = 2
};

pub const VTable = struct {
    pub const GetCounterFn = *const fn(obj: *const Self) usize;
    pub const SetInitCounterFn = *const fn(obj: *Self, val: usize) Error!void;
    pub const SetFrequencyFn = *const fn(obj: *Self, freq: u32, acc: Accuracy) Error!void;
    pub const SetModeFn = *const fn(obj: *Self, mode: Mode) void;

    getCounter: GetCounterFn,
    setInitCounter: ?SetInitCounterFn = null,
    setFrequency: ?SetFrequencyFn = null,
    setMode: ?SetModeFn = null,
};

pub const Flags = packed struct {
    per_cpu: bool = false,
};

pub const Accuracy = enum(u2) {
    milliseconds = 0,
    microseconds = 1,
    nanoseconds = 2
};

device: *const dev.Device,
vtable: *const VTable,

/// Frequency in Hz.
base_frequency: u32,
/// Timer kind, used by kernel to choose system timer.
kind: Kind,
//flags: Flags, TODO: FIXME!!!
mask: u64 = std.math.maxInt(u64),

supported_modes: SupportedModes,
mode: Mode,

pub fn init(
    device: *const dev.Device,
    vt: *const VTable, base_frequency: u32,
    kind: Kind, supported_modes: SupportedModes,
    mode: Mode
) Self {
    return .{
        .vtable = vt,
        .device = device,
        .base_frequency = base_frequency,
        .kind = kind,
        .supported_modes = supported_modes,
        .mode = mode
    };
}

pub inline fn getCounter(self: *const Self) usize {
    return self.vtable.getCounter(self);
}

pub inline fn setInitCounter(self: *Self, value: usize) Error!void {
    return self.vtable.setInitCounter.?(self, value & self.mask);
}

pub inline fn setFrequency(self: *Self, frequency: u32, accuracy: Accuracy) Error!void {
    return self.vtable.setFrequency.?(self, frequency, accuracy);
}

pub fn getSupportedModes(self: *const Self) []const Mode {
    return switch (self.supported_modes) {
        .once => &.{ .once },
        .periodic => &.{ .periodic },
        .both => &.{ .once, .periodic },
    };
}

pub fn setMode(self: *Self, mode: Mode) Error!void {
    if (self.mode == mode) return;
    if (self.isModeSupported(mode) == false) return Error.UnsupportedMode;

    self.vtable.setMode.?(self, mode);
    self.mode = mode;
}

pub inline fn isModeSupported(self: *const Self, mode: Mode) bool {
    return (@intFromEnum(mode) & @intFromEnum(self.supported_modes)) != 0;
}
