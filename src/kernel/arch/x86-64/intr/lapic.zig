const std = @import("std");

const apic = @import("apic.zig");
const dev = @import("../../../dev.zig");
const io = dev.io;
const regs = @import("../regs.zig");
const vm = @import("../../../vm.zig");

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

const APIC_ENABLED = 0x800;

var is_initialized = false;
var base: usize = undefined;

pub fn init() !void {
    const madt = apic.getMadt();

    base = io.request("LAPIC", madt.lapic_base, 0x400, .mmio) orelse return error.MmioBusy;
    base = vm.getVirtLma(base);

    // Set enabled APIC in MSR
    regs.setMsr(regs.MSR_APIC_BASE, regs.getMsr(regs.MSR_APIC_BASE) | APIC_ENABLED);

    // Set the Spurious Interrupt Vector Register bit 8
    set(.spurious_intr_vec, get(.spurious_intr_vec) | 0x100);

    is_initialized = true;
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
    return io.readl(@ptrFromInt(base + offset));
}

pub inline fn write(offset: u16, value: u32) void {
    @setRuntimeSafety(false);
    io.writel(@ptrFromInt(base + offset), value);
}

pub inline fn getId() u32 {
    return get(.id) >> 24;
}
