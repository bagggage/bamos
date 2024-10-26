//! # x86-64 Architecture specific implementation
//!
//! This module handles the initialization and management of the x86-64 CPU,
//! Setup of control registers, enabling specific CPU features.

const std = @import("std");

const boot = @import("../../boot.zig");
const gdt = @import("gdt.zig");
const lapic = @import("intr/lapic.zig");
const log = @import("../../log.zig");
const regs = @import("regs.zig");
const smp = @import("../../smp.zig");
const utils = @import("../../utils.zig");

const Spinlock = utils.Spinlock;

const CpuId = packed struct { a: u32, b: u32, c: u32, d: u32 };
const CpuVendor = enum { unknown, Intel, AMD };

pub const io = @import("io.zig");
pub const intr = @import("intr.zig");
pub const vm = @import("vm.zig");

pub const CpuLocalData = struct {
    self_ptr: usize,
    apic_id: u8
};

pub const cpuid_features = 1;

var cpu_vendor: CpuVendor = undefined;

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
    initCpuVendor();

    vm.preinit();

    gdt.init();
    intr.preinit();
}

/// Initialize architecture dependent devices.
pub inline fn devInit() !void {}

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

pub inline fn getCpuVendor() []const u8 {
    return @tagName(cpu_vendor);
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
    intr.enableCpu();
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
        ::: "rcx", "rax", "rdx");
}

fn initCpuVendor() void {
    const amd_ecx = 0x444d4163; // "cAMD"
    const intel_ecx = 0x6c65746e; // "ntel"

    const cpuid0_ecx = cpuid(0, undefined, 0, undefined).c;

    switch (cpuid0_ecx) {
        amd_ecx => cpu_vendor = .AMD,
        intel_ecx => cpu_vendor = .Intel,
        else => cpu_vendor = .unknown,
    }
}
