//! # Timer deivce high-level interface

const std = @import("std");

const dev = @import("../../dev.zig");
const lib = @import("../../lib.zig");
const log = std.log.scoped(.Timer);
const sys = @import("../../sys.zig");

const Self = @This();

pub const Event = sys.time.Event;

pub const Error = dev.io.Error || dev.intr.Error || error {
    BadOperation,
};

pub const Operations = struct {
    pub const ReadCounterFn = *const fn (*const Self) u64;
    pub const SetCounterFn = *const fn (*Self, u64) void;
    pub const SetEventFn = *const fn (*Self, Event) Error!void;
    pub const SetDeadlineFn = *const fn (*Self, u64) void;

    readCounter: ReadCounterFn,
    setCounter: ?SetCounterFn = null,

    /// Timer interrupt management and event configuration interface.
    setEvent: SetEventFn = undefined,
    setDeadline: SetDeadlineFn = undefined,
};

pub const Flags = packed struct(u8) {
    per_cpu: bool,
    count_down: bool,
    event_source: bool = false,
    time_source: bool = false,
    unstable: bool = false,
    _rsvd: u3 = 0,
};

device: *const dev.Device,
ops: *const Operations,

mask: u64 = std.math.maxInt(u64),
frequency_hz: u32,
ns_per_tick_fp: u64,

lock: lib.sync.Spinlock = .{},
event: sys.time.Event = .{},
flags: Flags,

pub fn init(
    device: *const dev.Device,
    ops: *const Operations,
    base_frequency: ?u32,
    flags: Flags,
) Self {
    const hz = if (base_frequency) |freq| freq else undefined;
    const ns_per_tick_fp = if (base_frequency) |freq| calculateNsPerTick(freq) else undefined;

    return .{
        .ops = ops,
        .device = device,
        .frequency_hz = hz,
        .ns_per_tick_fp = ns_per_tick_fp,
        .flags = flags,
    };
}

pub fn initFrequency(self: *Self, hz: u32) void {
    self.frequency_hz = hz;
    self.ns_per_tick_fp = calculateNsPerTick(hz);
}

pub inline fn readCounter(self: *const Self) u64 {
    return self.ops.readCounter(self);
}

pub inline fn setCounter(self: *Self, value: u64) error{BadOperation}!void {
    const func = self.ops.setCounter orelse return error.BadOperation;
    func(self, value & self.mask);
}

pub fn deltaTicks(self: *const Self, start: u64, end: u64) u64 {
    const raw_ticks =
        if (self.flags.count_down)
            start -% end
        else
            end -% start;

    return raw_ticks & self.mask;
}

pub inline fn deltaNs(self: *const Self, start: u64, end: u64) u64 {
    return (self.deltaTicks(start, end) * self.ns_per_tick_fp) / lib.fp_scale;
}

pub fn setEvent(self: *Self, event: Event) Error!void {
    if (!self.isEventSource()) return error.BadOperation;

    self.lock.lockSaveIntr();
    defer self.lock.unlockRestoreIntr();

    try self.ops.setEvent(self, event);
    self.event = event;
}

pub fn setEventDeadline(self: *Self, deadline_ticks: u64) error{BadOperation}!void {
    if (!self.isEventSource()) return error.BadOperation;

    if (self.flags.per_cpu) {
        @branchHint(.likely);
        self.ops.setDeadline(self, deadline_ticks);
    } else {
        self.lock.lockSaveIntr();
        defer self.lock.unlockRestoreIntr();

        self.ops.setDeadline(self, deadline_ticks);
    }
}

pub inline fn isEventSource(self: *Self) bool {
    return self.flags.event_source;
}

pub inline fn isTimeSource(self: *Self) bool {
    return self.flags.time_source;
}

inline fn calculateNsPerTick(hz: u32) u64 {
    return @as(u64, std.time.ns_per_s * lib.fp_scale) / hz;
}
