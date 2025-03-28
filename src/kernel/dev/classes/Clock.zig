//! # Clock device high-level interface

const std = @import("std");

const dev = @import("../../dev.zig");

const Self = @This();

pub const Time = extern struct {
    seconds: u8 = 0,
    days: u16 = 0,
    months: u8 = 0,
    years: u16 = 0
};

pub const IntrCallbackFn = *const fn(clock: *Self) void;

pub const VTable = struct {
    pub const GetTimeFn = *const fn(obj: *Self) Time;
    pub const SetTimeFn = *const fn(obj: *Self, time: Time) bool;
    pub const MaskIrqFn = *const fn(obj: *Self, mask: bool) void;
    pub const ConfigIrqFn = *const fn(obj: *Self, freq_div: u8, callback: IntrCallbackFn) dev.intr.Error!void;

    getTime: GetTimeFn,
    setTime: SetTimeFn,
    maskIrq: MaskIrqFn,
    configIrq: ConfigIrqFn
};

vtable: *const VTable,

pub fn init(self: *Self, vt: *const VTable) void {
    self.vtable = vt;
}

pub inline fn getTime(self: *Self) Time {
    return self.vtable.getTime(self);
}

pub inline fn setTime(self: *Self, time: Time) bool {
    return self.vtable.setTime(self, time);
}

pub inline fn maskIrq(self: *Self, mask: bool) void {
    self.vtable.maskIrq(self, mask);
}

pub inline fn configIrq(self: *Self, freq_div: u8, callback: IntrCallbackFn) dev.intr.Error!void {
    return self.vtable.configIrq(self, freq_div, callback);
}
