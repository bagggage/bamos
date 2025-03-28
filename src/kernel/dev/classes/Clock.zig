//! # Clock device high-level interface

const std = @import("std");

const dev = @import("../../dev.zig");
const log = std.log.scoped(.Clock);

const Self = @This();

const Priority = enum(u8) {
    low = 0,
    normal = 1,
    high = 2,
};

pub const DateTime = extern struct {
    seconds: u8 = 0,
    minutes: u8 = 0,
    hours: u8 = 0,
    month: u8 = 0,
    day: u8 = 0,
    year: u16 = 0,

    pub fn format(
        self: DateTime,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        try writer.print("{:0>2}.{:0>2}.{:0>4} {:0>2}:{:0>2}:{:0>2}", .{
            self.day, self.month, self.year,
            self.hours, self.minutes, self.seconds
        });
    }
};

pub const IntrCallbackFn = *const fn(clock: *Self) void;

pub const VTable = struct {
    pub const GetTimeFn = *const fn(obj: *Self) DateTime;
    pub const SetTimeFn = *const fn(obj: *Self, time: DateTime) bool;
    pub const MaskIrqFn = *const fn(obj: *Self, mask: bool) void;
    pub const ConfigIrqFn = *const fn(obj: *Self, freq_div: u8, callback: IntrCallbackFn) dev.intr.Error!void;

    getTime: GetTimeFn,
    setTime: SetTimeFn,
    maskIrq: MaskIrqFn,
    configIrq: ConfigIrqFn
};

var system_clock: ?*Self = null;

device: *const dev.Device,
vtable: *const VTable,

/// Frequency in Hz.
base_frequency: u32,
priority: Priority,

pub fn init(self: *Self, device: *const dev.Device, vt: *const VTable, base_frequency: u32, priority: Priority) void {
    self.* = .{
        .device = device,
        .vtable = vt,
        .base_frequency = base_frequency,
        .priority = priority
    };
}

pub inline fn getTime(self: *Self) DateTime {
    return self.vtable.getTime(self);
}

pub inline fn setTime(self: *Self, time: DateTime) bool {
    return self.vtable.setTime(self, time);
}

pub inline fn maskIrq(self: *Self, mask: bool) void {
    self.vtable.maskIrq(self, mask);
}

pub inline fn configIrq(self: *Self, freq_div_rank: u8, callback: IntrCallbackFn) dev.intr.Error!void {
    return self.vtable.configIrq(self, freq_div_rank, callback);
}

pub fn getFrequency(self: *const Self, freq_div_rank: u8) u32 {
    return self.base_frequency >> @truncate(freq_div_rank);
}

pub fn onObjectAdd(obj: *Self) void {
    if (system_clock) |clock| {
        const curr_priority = @intFromEnum(clock.priority);
        const obj_priority = @intFromEnum(obj.priority);

        if (curr_priority >= obj_priority) return;
    }

    system_clock = obj;

    log.info("system clock configured: {s}", .{obj.device.name});
}

pub fn onObjectRemove(obj: *Self) void {
    if (system_clock == obj) {
        system_clock = null;
        log.info("system clock dettached: {s}", .{obj.device.name});
    }
}

pub inline fn getSystemClock() ?*Self {
    return system_clock;
}
