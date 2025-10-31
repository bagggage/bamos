//! # Real-time Clock platform driver

// Copyright (C) 2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const smp = @import("../../../smp.zig");
const Clock = dev.classes.Clock;
const cmos = @import("cmos.zig");
const dev = @import("../../../dev.zig");
const log = std.log.scoped(.rtc_cmos);

const RtcRegsLayout = extern struct {
    seconds: u8,
    seconds_alarm: u8,
 
    minutes: u8,
    minutes_alarm: u8,

    hours: u8,
    hours_alarm: u8,

    weekday: u8,
    day: u8,
    month: u8,
    year: u8,

    reg_a: u8,
    reg_b: u8,
    reg_c: u8,
    reg_d: u8,

    _pad: [36]u8,

    century: u8,

    comptime {
        std.debug.assert(@offsetOf(@This(), "century") == 0x32);
    }
};

const RtcRegs = dev.regs.Group(
    cmos.IoMechanism,
    0x0,
    null,
    dev.regs.from(RtcRegsLayout)
);

const rtc_irq = 8;
const rtc_frequency = 32768;

const device_name = "rtc_cmos";

const vtable: Clock.VTable = .{
    .getDateTime = getDateTime,
    .setDateTime = setDateTime,
    .maskIrq = maskIrq,
    .configIrq = configIrq
};

var device: *dev.Device = undefined;
var regs: RtcRegs = .{};

var clock: *Clock = undefined;

var intr_callback: ?Clock.IntrCallbackFn = null;

pub fn init() void {
    initDevice(dev.getKernelDriver()) catch |err| {
        log.err("initialization failed: {s}", .{@errorName(err)});
    };
}

pub inline fn getObject() *Clock {
    return clock;
}

fn initDevice(self: *const dev.Driver) !void {
    regs = try RtcRegs.init();

    device = try self.addDevice(dev.nameOf(device_name), null);
    errdefer dev.removeDevice(device);

    clock = try dev.obj.new(Clock);
    errdefer dev.obj.free(Clock, clock);

    try dev.intr.requestIrq(
        rtc_irq,
        device,
        irqHandler,
        .edge,
        false
    );
    errdefer dev.intr.releaseIrq(rtc_irq, device);

    // Select status register A, and disable NMI (by setting the 0x80 bit).
    // Then write to CMOS/RTC RAM.
    cmos.write(0x8A, 0x20);

    clock.* = .init(device, &vtable, rtc_frequency, .system_low);
    try dev.obj.add(Clock, clock);
}

fn irqHandler(_: *dev.Device) bool {
    if (intr_callback) |callback| callback(clock);

    _ = regs.read(.reg_c);
    return true;
}

fn getDateTime(_: *Clock) Clock.DateTime {
    var time: Clock.DateTime = .{};

    {
        dev.intr.disableForCpu();
        defer dev.intr.enableForCpu();

        while (isUsed()) std.atomic.spinLoopHint();

        time.seconds = regs.read(.seconds);
        time.minutes = regs.read(.minutes);
        time.hours = regs.read(.hours);
        time.day = regs.read(.day);
        time.month = regs.read(.month);
        time.year = regs.read(.year);
    }

    const century = regs.read(.century);
    const reg_b = regs.read(.reg_b);

    // Check for DBC format.
    if ((reg_b & 0x04) == 0) {
        time.seconds = bcd2bin(time.seconds);
        time.minutes = bcd2bin(time.minutes);
        time.hours = bcd2bin(time.hours);
        time.day = bcd2bin(time.day);
        time.month = bcd2bin(time.month);
        time.year = bcd2bin(@truncate(time.year)) + @as(u16, bcd2bin(century)) * 100;
    } else {
        time.year += @as(u16, century) * 100;
    }

    return time;
}

fn setDateTime(_: *Clock, time: Clock.DateTime) bool {
    _ = time;
    return true;
}

fn maskIrq(_: *Clock, mask: bool) void {
    dev.intr.disableForCpu();
    defer dev.intr.enableForCpu();

    const reg_b = regs.read(.reg_b);

    if (mask) {
        regs.write(.reg_b, reg_b & 0xBF);
    } else {
        regs.write(.reg_b, reg_b | 0x40);
    }
}

fn configIrq(_: *Clock, freq_div_rank: u8, callback: Clock.IntrCallbackFn) dev.intr.Error!void {
    intr_callback = callback;

    dev.intr.disableForCpu();
    defer dev.intr.enableForCpu();

    const reg_a = regs.read(.reg_a);
    regs.write(
        .reg_a,
        (reg_a & 0xF0) | (freq_div_rank + 1)
    );
}

inline fn isUsed() bool {
    return (regs.read(.reg_a) & 0x80) != 0;
}

fn bcd2bin(bcd: u8) u8 {
    @setRuntimeSafety(false);
    return ((bcd >> 4) * 10) + (bcd & 0xF);
}