//! # x86-64 Executor Implementation

// Copyright (C) 2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const dev = @import("../../dev.zig");
const intr = @import("intr.zig");
const sched = @import("../../sched.zig");
const smp = @import("../../smp.zig");
const lapic = @import("intr/apic.zig").lapic;
const log = std.log.scoped(.executor);
const regs = @import("regs.zig");
const utils = @import("../../utils.zig");

const Clock = dev.classes.Clock;

const clock_freq_div_rank = 12;
const switch_period_ms = 3;
const target_switch_frequency = std.time.ms_per_s / switch_period_ms;

var eval_lock = utils.Spinlock.init(.unlocked);
var timer_frequency: u32 = 0;

pub fn init() !void {
    std.debug.assert(lapic.isInitialized());

    try initCpuTimer();
}

pub fn maskTimerIntr(mask: bool) void {
    var lvt_timer: lapic.LvtTimer = @bitCast(lapic.get(.lvt_timer));
    lvt_timer.mask = @intFromBool(mask);

    lapic.set(.lvt_timer, @bitCast(lvt_timer));
}

fn initCpuTimer() !void {
    try evalTimerFrequency();

    const cpu_idx = smp.getIdx();
    const intr_vec = dev.intr.allocVector(cpu_idx) orelse return error.NoIntrVector;

    const lvt_timer: lapic.LvtTimer = .{
        .delv_status = .relaxed,
        .timer_mode = .periodic,
        .mask = 1,
        .vector = @truncate(intr_vec.vec)
    };

    intr.setupIsr(intr_vec, &timerIntrRoutin, .kernel, intr.intr_gate_flags);

    eval_lock.wait(.unlocked);

    lapic.set(.timer_init_count, timer_frequency / target_switch_frequency);
    lapic.set(.lvt_timer, @bitCast(lvt_timer));
}

fn evalTimerFrequency() !void {
    if (eval_lock.isLocked()) return;

    eval_lock.lock();
    defer eval_lock.unlock();

    if (timer_frequency != 0) return;

    const clock = Clock.getSystemClock() orelse return error.ClockNotAvailable;

    try clock.configIrq(clock_freq_div_rank, clockIntrCallback);
    clock.maskIrq(false);

    // Wait
    const ptr: *volatile u32 = &timer_frequency; 
    while (ptr.* == 0) {}

    clock.maskIrq(true);

    log.info("timer frequency: {} MHz", .{timer_frequency / 1000_000});
}

fn clockIntrCallback(clock: *Clock) void {
    const Static = opaque {
        var started = false;
        var begin_ticks: u32 = 0;
    };

    if (Static.started) {
        const end_ticks = lapic.get(.timer_curr_count);
        const ticks = Static.begin_ticks -% end_ticks;
        timer_frequency = ticks * clock.getFrequency(clock_freq_div_rank);

        Static.started = false;
        return;
    }

    lapic.set(.timer_div_conf, 0b1011);
    lapic.set(.timer_init_count, std.math.maxInt(u32));

    Static.begin_ticks = lapic.get(.timer_curr_count);
    Static.started = true;
}

fn timerIntrRoutin() callconv(.naked) noreturn {
    regs.saveState();

    asm volatile("call timerIntrHandler");

    regs.restoreState();
    lapic.set(.eoi, 0);
    intr.iret();
}