//! # LAPIC Timer driver

// Copyright (C) 2025-2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const Clock = dev.classes.Clock;
const dev = @import("../../../dev.zig");
const intr = @import("../intr.zig");
const lapic = @import("../intr/lapic.zig");
const lib = @import("../../../lib.zig");
const log = std.log.scoped(.@"lapic.timer");
const rtc_cmos = @import("../dev/rtc_cmos.zig");
const sched = @import("../../../sched.zig");
const smp = @import("../../../smp.zig");
const Timer = dev.classes.Timer;

const device_name = "lapic_timer";
const clock_freq_div_rank = 12;

const DivisorConfig = struct {
    conf: u32,
    divisor: u32
};

const accur_config = struct {
    const milliseconds: DivisorConfig = .{ .conf = 0b1000, .divisor = 16 }; // divide by 16
    const microseconds: DivisorConfig = .{ .conf = 0b0010, .divisor =  8 }; // divide by 8
    const nanoseconds:  DivisorConfig = .{ .conf = 0b1011, .divisor =  1 }; // divide by 1

    var ns_per_tick: u32 = 0;
};

const vtable: Timer.VTable = .{
    .getCounter = getCounterCallback,
    .setFrequency = setFrequencyCallback
};

var device: dev.Device = .init(.init(device_name), null);
var timer: *Timer = undefined;

var eval_lock: lib.sync.Spinlock = .init(.unlocked);

pub fn init() !void {
    dev.getKernelDriver().attachDevice(&device);

    timer = try dev.obj.new(Timer);
    errdefer dev.obj.free(Timer, timer);

    timer.* = .init(&device, &vtable, 0, .system_high, .both, .once);

    try evalTimerFrequency();
    try dev.obj.add(Timer, timer);

    log.info("frequency: {} MHz, ns per tick: {}", .{timer.base_frequency / 1000_000, accur_config.ns_per_tick});
}

pub fn initPerCpu(isr: intr.isr.Fn) !void {
    const cpu_idx = smp.getIdx();
    const intr_vec = dev.intr.allocVector(cpu_idx) orelse return error.NoIntrVector;

    const lvt_timer: lapic.LvtTimer = .{
        .delv_status = .relaxed,
        .timer_mode = .periodic,
        .mask = 1,
        .vector = @truncate(intr_vec.vec)
    };

    intr.setupIsr(intr_vec, isr, .self, intr.intr_gate_flags);
    lapic.set(.lvt_timer, @bitCast(lvt_timer));
}

pub inline fn getObject() *Timer {
    return timer;
}

fn evalTimerFrequency() !void {
    const clock: *Clock = rtc_cmos.getObject();

    try clock.configIrq(clock_freq_div_rank, clockIntrCallback);
    clock.maskIrq(false);

    eval_lock.wait(.locked_no_intr);
    eval_lock.wait(.unlocked);

    clock.maskIrq(true);

    accur_config.ns_per_tick = @truncate(@as(u64, std.time.ns_per_s) / timer.base_frequency);
    if (accur_config.ns_per_tick == 0) accur_config.ns_per_tick = 1;
}

fn clockIntrCallback(clock: *Clock) void {
    const Static = opaque {
        var started = false;
        var begin_ticks: u32 = 0;
    };

    if (Static.started) {
        const end_ticks = lapic.get(.timer_curr_count);
        const ticks = Static.begin_ticks -% end_ticks;
        timer.base_frequency = ticks * clock.calcFrequency(clock_freq_div_rank);

        eval_lock.unlockAtomic();
        Static.started = false;

        return;
    }

    eval_lock.lockAtomic();

    // Set divider to 1.
    lapic.set(.timer_div_conf, 0b1011);
    lapic.set(.timer_init_count, std.math.maxInt(u32));

    Static.begin_ticks = lapic.get(.timer_curr_count);
    Static.started = true;
}

fn getCounterCallback(_: *const Timer) usize {
    return lapic.get(.timer_curr_count);
}

fn setFrequencyCallback(_: *Timer, freq: u32, accuracy: Timer.Accuracy) Timer.Error!void {
    const div_conf = accuracyToDivConf(accuracy);
    const init_count = (timer.base_frequency / freq) / div_conf.divisor;

    if (smp.getIdx() == smp.boot_cpu) log.debug("init count: {}", .{init_count});

    lapic.set(.timer_div_conf, div_conf.conf);
    lapic.set(.timer_init_count, init_count);
}

fn accuracyToDivConf(accuracy: Timer.Accuracy) DivisorConfig {
    return switch (accuracy) {
        .milliseconds => accur_config.milliseconds,
        .microseconds => accur_config.microseconds,
        .nanoseconds => accur_config.nanoseconds
    };
}
