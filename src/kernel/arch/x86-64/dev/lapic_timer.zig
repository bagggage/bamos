//! # LAPIC Timer driver

// Copyright (C) 2025-2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const arch = @import("../arch.zig");
const Clock = dev.classes.Clock;
const dev = @import("../../../dev.zig");
const intr = @import("../intr.zig");
const lapic = @import("../intr/lapic.zig");
const log = std.log.scoped(.@"lapic.timer");
const rtc_cmos = @import("../dev/rtc_cmos.zig");
const smp = @import("../../../smp.zig");
const Timer = dev.classes.Timer;
const vm = @import("../../../vm.zig");

const device_name = "lapic_timer";

const ops: Timer.Operations = .{
    .readCounter = timerReadCounter,
    .setEvent = timerSetEvent,
    .setDeadline = timerSetDeadline,
};

var device: dev.Device = .init(.init(device_name), null);
var timer: *Timer = undefined;
var irq_vectors: []u16 = &.{};

pub fn init() !void {
    dev.getKernelDriver().attachDevice(&device);

    timer = try dev.obj.new(Timer);
    errdefer dev.obj.free(Timer, timer);

    timer.* = .init(&device, &ops, null, .{
        .per_cpu = true,
        .count_down = true,
        .event_source = true,
    });
    timer.mask = std.math.maxInt(u32);

    const clock = rtc_cmos.getObject();
    var eval: Clock.EvaluateFrequency = .{ .timer = timer, .ref_timer = dev.acpi.timer.getObject().? };

    lapic.set(.timer_div_conf, 0b1011);
    lapic.set(.timer_init_count, std.math.maxInt(u32));

    try clock.evaluateTimerFrequency(&eval);
    timer.initFrequency(eval.frequency_hz);

    irq_vectors = vm.gpa.allocMany(u16, smp.getNum()) orelse return error.NoMemory;
    @memset(irq_vectors, 0);

    try dev.obj.add(Timer, timer);

    log.info("frequency: {} MHz, ns per tick fp: {}", .{timer.frequency_hz / 1000_000, timer.ns_per_tick_fp});
}

pub inline fn getObject() *Timer {
    return timer;
}

fn irqHandler(_: u32) void {
    timer.event.process(timer);
}

fn timerReadCounter(_: *const Timer) usize {
    return lapic.get(.timer_curr_count);
}

fn timerSetEvent(self: *Timer, event: Timer.Event) Timer.Error!void {
    const cpu_idx = smp.getIdx();
    if (!self.event.isSet() and event.isSet()) {
        const intr_vec = dev.intr.allocVector(cpu_idx) orelse return error.NoVector;
        irq_vectors[cpu_idx] = intr_vec.vec;

        const lvt_timer: lapic.LvtTimer = .{
            .delv_status = .relaxed,
            .timer_mode = if (comptime arch.time.use_tsc_deadline_mode) .tsc_deadline else .once,
            .mask = 0,
            .vector = @truncate(intr_vec.vec)
        };

        comptime {
            const low_level_handler = dev.intr.makeLowLevelHandler(irqHandler);
            @export(low_level_handler, .{ .name = "lapicIrqHandler" });
        }

        const isr = intr.isr.makeIrqHandler("lapic", "lapicIrqHandler", null);
        intr.setupIsr(intr_vec, isr, .self, intr.intr_gate_flags);

        // Set divider to 1
        lapic.set(.timer_div_conf, 0b1011);
        // Disable interrupts until deadline is set
        lapic.set(.timer_init_count, 0);
        lapic.set(.lvt_timer, @bitCast(lvt_timer));
    } else if (self.event.isSet() and !event.isSet()) {
        var lvt_timer: lapic.LvtTimer = @bitCast(lapic.get(.lvt_timer));
        lvt_timer.mask = 1;

        lapic.set(.timer_init_count, 0);
        lapic.set(.lvt_timer, @bitCast(lvt_timer));

        dev.intr.freeVector(.{ .cpu = cpu_idx, .vec = irq_vectors[cpu_idx] });

        irq_vectors[cpu_idx] = 0;
    }
}

fn timerSetDeadline(_: *Timer, deadline_ticks: u64) void {
    lapic.set(.timer_init_count, @truncate(deadline_ticks));
}
