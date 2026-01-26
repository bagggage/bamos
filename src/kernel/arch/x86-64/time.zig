//! # x86-64 Executor Implementation

// Copyright (C) 2025-2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const arch = @import("arch.zig");
const Clock = dev.classes.Clock;
const dev = @import("../../dev.zig");
const lapic = @import("intr/apic.zig").lapic;
const log = std.log.scoped(.@"arch.time");
const regs = @import("regs.zig");
const rtc_cmos = @import("dev/rtc_cmos.zig");
const sched = @import("../../sched.zig");
const smp = @import("../../smp.zig");
const sys = @import("../../sys.zig");
const Timer = dev.classes.Timer;

// Nothing to do here.
pub fn init() !void {}

pub inline fn initPerCpu() !void {
    const frequency = sys.time.getHz();
    const accuracy: Timer.Accuracy = if (frequency > 1000) .microseconds else .milliseconds;

    try lapic.timer.initPerCpu(timerIntrRoutin);
    try lapic.timer.getObject().setFrequency(frequency, accuracy);
}

pub fn maskTimerIntr(mask: bool) void {
    @setRuntimeSafety(false);

    var lvt_timer: lapic.LvtTimer = @bitCast(lapic.get(.lvt_timer));
    lvt_timer.mask = @intFromBool(mask);

    lapic.set(.lvt_timer, @bitCast(lvt_timer));
}

pub inline fn getClock() ?*Clock {
    return rtc_cmos.getObject();
}

pub inline fn getSchedTimer() ?*Timer {
    return lapic.timer.getObject();
}

pub inline fn getSysTimer() ?*Timer {
    return dev.acpi.timer.getObject();
}

fn timerIntrRoutin() callconv(.naked) noreturn {
    @setRuntimeSafety(false);

    comptime @export(&dev.intr.handlerExit, .{ .name = "interruptHandlerExit" });
    comptime @export(&sys.time.timerInterruptHandler, .{ .name = "timerInterruptHandler" });

    asm volatile ("call interruptEntry" ::: regs.call_clobers);
    defer asm volatile ("jmp interruptExit");

    const local = smp.getLocalData();
    dev.intr.handlerEnter(local);

    asm volatile ("call timerInterruptHandler" :: [arg1] "{rdi}" (local) : regs.call_clobers);
    // This code is buggy (if pass arg1 as `local` variable), I have no idea why this happens
    asm volatile ("call interruptHandlerExit" :: [arg1] "{rdi}" (smp.getLocalData()) : regs.call_clobers);
}
