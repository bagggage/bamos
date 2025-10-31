//! # Clock device high-level interface

const std = @import("std");

const dev = @import("../../dev.zig");
const log = std.log.scoped(.Clock);
const sys = @import("../../sys.zig");

const Self = @This();

pub const DateTime = sys.time.DateTime;

pub const Kind = enum(u8) {
    system_low,
    system_high,
    embedded,
};

pub const IntrCallbackFn = *const fn(clock: *Self) void;

pub const VTable = struct {
    pub const GetDateTimeFn = *const fn(obj: *Self) DateTime;
    pub const SetDateTimeFn = *const fn(obj: *Self, time: DateTime) bool;
    pub const MaskIrqFn = *const fn(obj: *Self, mask: bool) void;
    pub const ConfigIrqFn = *const fn(obj: *Self, freq_div: u8, callback: IntrCallbackFn) dev.intr.Error!void;

    getDateTime: GetDateTimeFn,
    setDateTime: SetDateTimeFn,
    maskIrq: MaskIrqFn,
    configIrq: ConfigIrqFn
};

device: *const dev.Device,
vtable: *const VTable,

/// Frequency in Hz.
base_frequency: u32,
/// Kind of clock, used by kernel to choose system clock.
kind: Kind,

pub fn init(device: *const dev.Device, vt: *const VTable, base_frequency: u32, kind: Kind) Self {
    return .{
        .device = device,
        .vtable = vt,
        .base_frequency = base_frequency,
        .kind = kind
    };
}

pub inline fn getDateTime(self: *Self) DateTime {
    return self.vtable.getDateTime(self);
}

pub inline fn setDateTime(self: *Self, time: DateTime) bool {
    return self.vtable.setDateTime(self, time);
}

pub inline fn maskIrq(self: *Self, mask: bool) void {
    self.vtable.maskIrq(self, mask);
}

pub inline fn configIrq(self: *Self, freq_div_rank: u8, callback: IntrCallbackFn) dev.intr.Error!void {
    return self.vtable.configIrq(self, freq_div_rank, callback);
}

pub fn calcFrequency(self: *const Self, freq_div_rank: u8) u32 {
    return self.base_frequency >> @truncate(freq_div_rank);
}
