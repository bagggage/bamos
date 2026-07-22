//! # x86-64 Time subsystem

// Copyright (C) 2025-2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const Clock = dev.classes.Clock;
const dev = @import("../../dev.zig");
const lapic = @import("intr/apic.zig").lapic;
const lib = @import("../../lib.zig");
const log = std.log.scoped(.@"arch.time");
const regs = @import("regs.zig");
const rtc_cmos = @import("dev/rtc_cmos.zig");
const Timer = dev.classes.Timer;
const tsc_timer = @import("dev/tsc_timer.zig");

pub const use_tsc_deadline_mode = false;

pub fn init() !void {
    if (comptime use_tsc_deadline_mode) try tsc_timer.init();
}

pub fn initPerCpu() !void {
    if (comptime use_tsc_deadline_mode) tsc_timer.initPerCpu();
}

pub inline fn chooseClock() !*Clock {
    return rtc_cmos.getObject();
}

pub inline fn chooseTimeSource() !*Timer {
    return if (comptime use_tsc_deadline_mode) tsc_timer.getObject() else dev.acpi.timer.getObject().?;
}

pub inline fn chooseEventSource() !*Timer {
    return lapic.timer.getObject();
}