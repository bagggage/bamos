//! # Clock device high-level interface

const std = @import("std");

const dev = @import("../../dev.zig");
const lib = @import("../../lib.zig");
const log = std.log.scoped(.Clock);
const sys = @import("../../sys.zig");

const Self = @This();
const Timer = @import("Timer.zig");

pub const DateTime = sys.time.DateTime;

pub const EvaluateFrequency = struct {
    timer: *Timer,
    ref_timer: *Timer,
    lock: lib.sync.Spinlock = .{},
    freq_div_rank: u8 = 0,
    start_count: u64 = 0,
    start_ref_count: u64 = 0,

    // Result values
    frequency_hz: u32 = 0,
};

pub const Callback = struct {
    pub const Fn = ?*const fn (clock: *Self, data: lib.AnyData) void;

    func: Fn = null,
    data: lib.AnyData = .{},
};

pub const Operations = struct {
    pub const GetDateTimeFn = *const fn(obj: *Self) DateTime;
    pub const SetDateTimeFn = *const fn(obj: *Self, time: DateTime) bool;
    pub const MaskIrqFn = *const fn(obj: *Self, mask: bool) void;
    pub const ConfigIrqFn = *const fn(obj: *Self, freq_div: u8) dev.intr.Error!void;

    getDateTime: GetDateTimeFn,
    setDateTime: SetDateTimeFn,
    maskIrq: MaskIrqFn,
    configIrq: ConfigIrqFn,
};

device: *const dev.Device,
ops: *const Operations,
callback: Callback = .{},

/// Frequency in Hz.
base_frequency: u32,

pub fn init(device: *const dev.Device, ops: *const Operations, base_frequency: u32) Self {
    return .{
        .device = device,
        .ops = ops,
        .base_frequency = base_frequency,
    };
}

pub fn evaluateTimerFrequency(self: *Self, eval: *EvaluateFrequency) dev.intr.Error!void {
    var clock_div_rank: u8 = 0;
    var clock_freq = self.base_frequency;
    while (clock_freq > 64) {
        clock_div_rank += 1;
        clock_freq >>= 1;
    }

    self.maskIrq(true);
    try self.configIrq(clock_div_rank, .{
        .func = &evaluateFrequencyCallback,
        .data = .fromPtr(eval),
    });
    defer self.callback.func = null;

    eval.frequency_hz = 0;

    const max_tries = 3;
    var tries: u32 = 0;
    while (
        tries < max_tries and
        (eval.frequency_hz < 1024 or
        eval.frequency_hz == std.math.maxInt(usize))
    ) : (tries += 1) {
        eval.lock = .{};

        self.maskIrq(false);
        defer self.maskIrq(true);

        eval.lock.wait(.locked_no_intr);
        eval.lock.wait(.unlocked);
    }

    if (tries <= 1) return;
    if (tries == max_tries) {
        log.err("failed to evaluate {s} frequency", .{eval.timer.device.name.str()});
    } else {
        log.warn("{s} frequency evaluated after {} attempts", .{
            eval.timer.device.name.str(), tries
        });
    }
}

pub inline fn getDateTime(self: *Self) DateTime {
    return self.ops.getDateTime(self);
}

pub inline fn setDateTime(self: *Self, time: DateTime) bool {
    return self.ops.setDateTime(self, time);
}

pub inline fn maskIrq(self: *Self, mask: bool) void {
    self.ops.maskIrq(self, mask);
}

pub fn configIrq(self: *Self, freq_div_rank: u8, callback: Callback) dev.intr.Error!void {
    self.callback = callback;
    return self.ops.configIrq(self, freq_div_rank);
}

pub fn calcFrequency(self: *const Self, freq_div_rank: u8) u32 {
    return self.base_frequency >> @truncate(freq_div_rank);
}

fn evaluateFrequencyCallback(_: *Self, data: lib.AnyData) void {
    const intr_enable = dev.intr.saveAndDisableForCpu();
    defer dev.intr.restoreForCpu(intr_enable);

    const eval: *EvaluateFrequency = data.asPtr(EvaluateFrequency).?;
    if (eval.lock.tryLockAtomic()) {
        eval.start_ref_count = eval.ref_timer.readCounter();
        eval.start_count = eval.timer.readCounter();
    } else {
        const end_ref_count = eval.ref_timer.readCounter();
        const end_count = eval.timer.readCounter();

        const ticks = @max(eval.timer.deltaTicks(eval.start_count, end_count), 1);
        const ref_ticks = eval.ref_timer.deltaTicks(eval.start_ref_count, end_ref_count);

        const scale = 1024;
        const hz = (((ticks *| scale) / ref_ticks) * eval.ref_timer.frequency_hz) / scale;

        eval.frequency_hz = @min(hz, std.math.maxInt(u32));
        eval.lock.unlockAtomic();
    }
}
