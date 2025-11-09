const std = @import("std");

const apic = @import("apic.zig");
const dev = @import("../../../dev.zig");
const io = dev.io;
const vm = @import("../../../vm.zig");

const Interrupt = @import("apic.zig").Interrupt;

pub const Regs = enum(u16) {
    id = 0x20,
    ver = 0x30,

    task_prior = 0x80,
    arbit_prior = 0x90,
    processor_prior = 0xa0,
    eoi = 0xb0,
    remote_read = 0xc0,
    logical_dest = 0xd0,
    dest_format = 0xe0,
    spurious_intr_vec = 0xf0,

    error_status = 0x280,
    lvt_cmci = 0x2f0,
    lvt_timer = 0x320,
    lvt_thermal_sensor = 0x330,
    lvt_performance_monitoring_counters = 0x340,
    lvt_lint0 = 0x350,
    lvt_lint1 = 0x360,
    lvt_error = 0x370,
    timer_init_count = 0x380,
    timer_curr_count = 0x390,
    timer_div_conf = 0x3e0,

    const isr_base = 0x100;
    const tmr_base = 0x180;
    const irr_base = 0x200;
    const icr_base = 0x300;
};

pub const LvtTimer = packed struct {
    vector: u8,

    rsrvd: u4 = 0,
    delv_status: Interrupt.DeliveryStatus,

    rsrvd_1: u3 = 0,
    mask: u1 = 0,

    timer_mode: enum(u2) { once = 0b00, periodic = 0b01, tsc_deadline = 0b10 },

    rsrvd_2: u13 = 0,
};

pub const timer = @import("../dev/lapic_timer.zig");

var is_initialized = false;
var base: usize = undefined;

pub fn init() !void {
    const madt = apic.getMadt();

    base = io.request("LAPIC", madt.lapic_base, 0x400, .mmio) orelse return error.MmioBusy;
    base = vm.getVirtLma(base);

    is_initialized = true;
}

pub fn initPerCpu() void {
    // Set the Spurious Interrupt Vector Register bit 8
    set(.spurious_intr_vec, get(.spurious_intr_vec) | 0x100);
    set(.task_prior, 0);
}

pub inline fn isInitialized() bool {
    return is_initialized;
}

pub inline fn get(reg: Regs) u32 {
    return read(@intFromEnum(reg));
}

pub inline fn set(reg: Regs, value: u32) void {
    write(@intFromEnum(reg), value);
}

pub inline fn read(offset: u16) u32 {
    @setRuntimeSafety(false);
    return io.readl(base + offset);
}

pub inline fn write(offset: u16, value: u32) void {
    @setRuntimeSafety(false);
    io.writel(base + offset, value);
}

pub inline fn getId() u32 {
    return get(.id) >> 24;
}
