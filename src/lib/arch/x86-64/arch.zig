//! # x86-64 Architecture specific implementation
//!
//! This module handles the initialization and management of the x86-64 CPU,
//! Setup of control registers, enabling specific CPU features.

// Copyright (C) 2024 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const bindings = @import("../../bindings.zig");

const boot = @import("../../boot.zig");
const gdt = @import("gdt.zig");
const lapic = @import("intr/lapic.zig");
const lib = @import("../../lib.zig");
const smp = @import("../../smp.zig");

pub const Cpu = struct {
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

    features: CpuId,

    pub fn getName(self: *const Cpu) []const u8 {
        const len = std.mem.indexOf(u8, &self.name, "  ") orelse max_name;
        return self.name[0..len];
    }

    pub fn getHwCap(self: *const Cpu) u32 {
        return self.features.d;
    }
};

const CpuId = packed struct {
    a: u32, b: u32, c: u32, d: u32,

    pub fn format(self: CpuId, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("eax: 0x{x}, ebx: 0x{x}, ecx: 0x{x}, edx: 0x{x}", .{
            self.a, self.b, self.c, self.d
        });
    }
};

pub const regs = @import("regs.zig");

pub const Context = @import("Context.zig");
pub const intr = @import("intr.zig");
pub const io = @import("io.zig");
pub const syscall = @import("syscall.zig");
pub const time = @import("time.zig");
pub const vm = @import("vm.zig");

pub const CpuLocalData = struct {
    self_ptr: usize,
    apic_id: u8,

    tss: intr.TaskStateSegment,
};

pub const cpuid_features = 1;

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
    return bindings.getInstance().arch.getCpuInfo();
}

pub inline fn setCpuLocalData(local_data: *smp.LocalData) void {
    local_data.arch_specific.self_ptr = @intFromPtr(local_data);
    local_data.arch_specific.apic_id = @truncate(cpuid(cpuid_features, undefined, undefined, undefined).b >> 24);

    regs.setGs(0);
    regs.setMsr(regs.MSR_GS_BASE, @intFromPtr(local_data));
}

pub inline fn getCpuLocalData() *smp.LocalData {
    return asm (
        std.fmt.comptimePrint("mov %gs:{},%[ret]", .{
            @offsetOf(smp.LocalData, "arch_specific") + @offsetOf(CpuLocalData, "self_ptr")
        })
        : [ret] "=r" (-> *smp.LocalData),
    );
}
