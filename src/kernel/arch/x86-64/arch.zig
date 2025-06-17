//! # x86-64 Architecture specific implementation
//!
//! This module handles the initialization and management of the x86-64 CPU,
//! Setup of control registers, enabling specific CPU features.

// Copyright (C) 2024 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const boot = @import("../../boot.zig");
const gdt = @import("gdt.zig");
const lapic = @import("intr/lapic.zig");
const regs = @import("regs.zig");
const smp = @import("../../smp.zig");
const utils = @import("../../utils.zig");

const Spinlock = utils.Spinlock;

const Cpu = struct {
    const Vendor = enum { unknown, Intel, AMD };
    const max_name = 48;

    name: [max_name:0]u8,
    vendor: Vendor,

    /// MHz
    base_frequency: u32,
    /// MHz
    max_frequency: u32,
    /// MHz
    bus_frequency: u32,

    pub fn getName(self: *const Cpu) []const u8 {
        const len = std.mem.indexOf(u8, &self.name, "  ") orelse unreachable;
        return self.name[0..len];
    }
};

const CpuId = packed struct { a: u32, b: u32, c: u32, d: u32 };

pub const Context = @import("Context.zig");
pub const intr = @import("intr.zig");
pub const io = @import("io.zig");
pub const time = @import("time.zig");
pub const vm = @import("vm.zig");

pub const CpuLocalData = struct {
    self_ptr: usize,
    apic_id: u8
};

pub const cpuid_features = 1;

var cpu: Cpu = undefined;

/// `_start` implementation
pub inline fn startImpl() void {
    asm volatile (
        \\push 0x0
        \\jmp main
    );
}

/// Ensure that only one CPU is performing the initialization at a time.
/// If the CPU is the initial one, it will proceed to initialization.
/// If not, it waits until the initialization lock is available.
pub fn preinit() void {
    initCpu();
    collectCpuInfo();

    vm.preinit();

    gdt.init();
    intr.preinit();
}

/// Initialize architecture dependent devices.
pub inline fn devInit() !void {
    const cmos = @import("dev/cmos.zig");
    const rtc_cmos = @import("dev/rtc_cmos.zig");

    try cmos.init();
    rtc_cmos.init();

    try lapic.timer.init();
}

pub inline fn cpuid(eax: u32, ebx: u32, ecx: u32, edx: u32) CpuId {
    @setRuntimeSafety(false);

    var a: u32 = eax;
    var b: u32 = ebx;
    var c: u32 = ecx;
    var d: u32 = edx;

    asm volatile (
        \\cpuid
        : [a] "={eax}" (a),
          [b] "={ebx}" (b),
          [c] "={ecx}" (c),
          [d] "={edx}" (d),
        : [id] "{eax}" (a),
          [i_b] "{ebx}" (b),
          [i_c] "{ecx}" (c),
          [i_d] "{edx}" (d),
    );

    return .{ .a = a, .b = b, .c = c, .d = d };
}

pub inline fn halt() void {
    asm volatile ("hlt");
}

pub inline fn getCpuInfo() *Cpu {
    return &cpu;
}

pub inline fn setCpuLocalData(local_data: *smp.LocalData) void {
    local_data.arch_specific.self_ptr = @intFromPtr(local_data);
    local_data.arch_specific.apic_id = @truncate(
        cpuid(cpuid_features, undefined, undefined, undefined).b >> 24
    );

    regs.setGs(0);
    regs.setMsr(regs.MSR_GS_BASE, @intFromPtr(local_data));
}

pub inline fn getCpuLocalData() *smp.LocalData {
    var local_data: *smp.LocalData = undefined;
    asm(std.fmt.comptimePrint(
        "mov %gs:{},%[ptr]",
        .{@offsetOf(smp.LocalData, "arch_specific") + @offsetOf(CpuLocalData, "self_ptr")})
        :[ptr]"=r"(local_data)
    );

    return local_data;
}

/// This function initializes the CPU's essential features and settings, such as enabling the
/// No-Execute bit, system call extensions, and AVX.
///
/// If the CPU is the initial CPU, it also performs additional
/// preinitializing the virtual memory system, the interrupt system, and etc.
pub inline fn initCpu() void {
    enableExtentions();
}

pub fn setupCpu(cpu_idx: u16) void {
    gdt.setupCpu();

    intr.setupCpu(@truncate(cpu_idx));
    intr.enableForCpu();
}

pub inline fn timestamp() usize {
    return regs.getTsc();
}

/// Enables kernel needed CPUs extentions
/// - syscall/sysret
/// - non-executable pages
inline fn enableExtentions() void {
    var efer = regs.getEfer();
    efer.noexec_enable = 1;
    efer.syscall_ext = 1;
    regs.setEfer(efer);
}

/// Enable AVX
inline fn enableAvx() void {
    asm volatile (
        \\mov %%cr4,%%rax
        \\or $0x40600,%%rax
        \\mov %%rax,%%cr4
        \\xor %%rcx,%%rcx
        \\xgetbv
        \\or $7,%%rax
        \\xsetbv
        ::: "rcx", "rax", "rdx"
    );
}

fn collectCpuInfo() void {
    cpu.vendor = getCpuVendor();

    const result = cpuid(0x16, undefined, undefined, undefined);
    cpu.base_frequency = result.a;
    cpu.max_frequency = result.b;
    cpu.bus_frequency = result.c;

    getCpuModelName(&cpu.name);
}

fn getCpuVendor() Cpu.Vendor {
    const amd_ecx = 0x444d4163; // "cAMD"
    const intel_ecx = 0x6c65746e; // "ntel"

    const cpuid0_ecx = cpuid(0, undefined, 0, undefined).c;

    return switch (cpuid0_ecx) {
        amd_ecx => .AMD,
        intel_ecx => .Intel,
        else =>.unknown,
    };
}

fn getCpuModelName(out: []u8) void {
    std.debug.assert(out.len >= Cpu.max_name);

    for (0..3) |i| {
        const result = cpuid(0x8000_0002 + @as(u32, @truncate(i)), undefined, undefined, undefined);

        const offset = i * 4 * 4;
        const buffer: []u8 = out[offset..];

        @memcpy(buffer[0..4], std.mem.asBytes(&result.a));
        @memcpy(buffer[4..8], std.mem.asBytes(&result.b));
        @memcpy(buffer[8..12], std.mem.asBytes(&result.c));
        @memcpy(buffer[12..16], std.mem.asBytes(&result.d));
    }
}
