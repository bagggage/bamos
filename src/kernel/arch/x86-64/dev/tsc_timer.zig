//! Timestamp Counter timer driver

// Copyright (C) 2025-2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const Clock = dev.classes.Clock;
const dev = @import("../../../dev.zig");
const log = std.log.scoped(.@"tsc.timer");
const regs = @import("../regs.zig");
const rtc_cmos = @import("../dev/rtc_cmos.zig");
const Timer = dev.classes.Timer;

const device_name = "tsc_timer";

const ops: Timer.Operations = .{
    .readCounter = timerReadCounter,
};

var device: dev.Device = .init(.init(device_name), null);
var timer: *Timer = undefined;

pub fn init() !void {
    dev.getKernelDriver().attachDevice(&device);

    timer = try dev.obj.new(Timer);
    errdefer dev.obj.free(Timer, timer);

    timer.* = .init(&device, &ops, null, .{
        .per_cpu = true,
        .count_down = false,
        .time_source = true,
    });
    device.driver_data.setPtr(timer);

    initPerCpu();

    const clock: *Clock = rtc_cmos.getObject();
    var eval: Clock.EvaluateFrequency = .{ .timer = timer, .ref_timer = dev.acpi.timer.getObject().? };

    try clock.evaluateTimerFrequency(&eval);
    timer.initFrequency(eval.frequency_hz);

    try dev.obj.add(Timer, timer);

    log.info("frequency: {} MHz, ns per tick fp: {}", .{timer.frequency_hz / 1000_000, timer.ns_per_tick_fp});
}

pub fn initPerCpu() void {
    regs.writeMsr(regs.MSR_TSC_ADJUST, 0);
}

pub inline fn getObject() *Timer {
    return timer;
}

fn timerReadCounter(_: *const Timer) u64 {
    var hi: u32 = undefined;
    var lo: u32 = undefined;

    asm volatile ("rdtsc"
        : [hi] "={edx}" (hi),
          [lo] "={eax}" (lo),
    );

    return (@as(u64, hi) << 32) | lo;
}
