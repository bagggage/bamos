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
const timer_div_conf = struct { divider: comptime_int, config: comptime_int } {
    .divider = 16,
    .config = 0b0011
};

var eval_lock = utils.Spinlock.init(.unlocked);
/// Scheduler timer frequency in Hz.
var timer_frequency: u32 = 0;
var timer_ns_per_tick: u32 = 0;
var timer_init_count: u32 = 0;
/// Scheduler timer interrupt interval in milliseconds.
var time_slice_granule: u8 = 0;

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
        .timer_mode = .once,
        .mask = 1,
        .vector = @truncate(intr_vec.vec)
    };

    intr.setupIsr(intr_vec, &timerIntrRoutin, .kernel, intr.intr_gate_flags);

    eval_lock.wait(.unlocked);

    lapic.set(.timer_div_conf, timer_div_conf.config);
    lapic.set(.timer_init_count, timer_init_count);
    lapic.set(.lvt_timer, @bitCast(lvt_timer));
}

fn evalTimerFrequency() !void {
    if (eval_lock.isLocked()) return;

    eval_lock.lock();
    defer eval_lock.unlock();

    if (timer_frequency != 0) return;

    time_slice_granule = 1 + std.math.log2_int(u16, smp.getNum());
    const clock = Clock.getSystemClock() orelse return error.ClockNotAvailable;

    try clock.configIrq(clock_freq_div_rank, clockIntrCallback);
    clock.maskIrq(false);

    // Wait
    const ptr: *volatile u32 = &timer_frequency; 
    while (ptr.* == 0) {}

    clock.maskIrq(true);

    timer_ns_per_tick = @truncate(@as(u64, std.time.ns_per_s) / timer_frequency);
    if (timer_ns_per_tick == 0) timer_ns_per_tick = 1;

    timer_init_count = @as(u32, time_slice_granule) * (std.time.ns_per_ms / timer_ns_per_tick) / timer_div_conf.divider;

    log.info("timer frequency: {} MHz, ns per tick: {}", .{timer_frequency / 1000_000, timer_ns_per_tick});
    log.info("time slice granule: {} ms", .{time_slice_granule});
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

    // Set divider to 1.
    lapic.set(.timer_div_conf, 0b1011);
    lapic.set(.timer_init_count, std.math.maxInt(u32));

    Static.begin_ticks = lapic.get(.timer_curr_count);
    Static.started = true;
}

fn timerIntrRoutin() callconv(.naked) noreturn {
    asm volatile("call isr.entry");
    defer asm volatile("jmp isr.exit");

    regs.saveState();
    defer regs.restoreState();

    asm volatile("call timerIntrHandler");
    defer asm volatile("call intrHandlerExit");

    lapic.set(.timer_init_count, timer_init_count);
}