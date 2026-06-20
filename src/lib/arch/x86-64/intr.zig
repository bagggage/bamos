//! # Interrupts subsystem low-level implementation

// Copyright (C) 2024-2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const regs = @import("regs.zig");

pub const table_len = max_vectors;

pub const max_vectors = 256;
pub const reserved_vectors = 32;
pub const avail_vectors = max_vectors - reserved_vectors;

pub const irq_base_vec = reserved_vectors;

pub const Descriptor = packed struct {
    pub const Table = [table_len]Descriptor;

    offset_1: u16 = 0,
    selector: u16 = 0,
    ist: u3 = 0,
    rsrvd: u5 = 0,

    type_attr: u8 = 0,
    offset_2: u48 = 0,

    rsrvd_1: u32 = 0,
};

pub const TaskStateSegment = extern struct {
    rsrvd: u32 = 0,

    rsps: [3]u64 align(@alignOf(u32)),
    rsrvd_1: u64 align(@alignOf(u32)) = 0,

    ists: [7]u64 align(@alignOf(u32)),
    rsrvd_2: u64 align(@alignOf(u32)) = 0,

    rsrvd_3: u16 = 0,
    io_map_base: u16,

    comptime {
        std.debug.assert(@sizeOf(TaskStateSegment) == 0x68);
    }
};

pub const Stack = enum(u3) { self = 0x0, double_fault = 0x1 };

pub inline fn useIdt(idt: *Descriptor.Table) void {
    const idtr: regs.IDTR = .{
        .base = @intFromPtr(idt),
        .limit = @sizeOf(Descriptor.Table) - 1,
    };

    regs.setIdtr(idtr);
}

pub inline fn enableForCpu() void {
    asm volatile ("sti");
}

pub inline fn disableForCpu() void {
    asm volatile ("cli");
}

pub inline fn isEnabledForCpu() bool {
    @setRuntimeSafety(false);
    const flags = regs.getFlags();
    return flags.intr_enable;
}

pub inline fn iret() noreturn {
    @setRuntimeSafety(false);

    asm volatile ("iretq");
    unreachable;
}
