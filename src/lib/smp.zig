//! # Symmetric multiprocessing

// Copyright (C) 2024-2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");
const builtin = @import("builtin");

const bindings = @import("bindings.zig");

const arch = @import("kernel.zig").arch;
const sched = @import("sched.zig");
const intr = @import("dev.zig").intr;

/// Index of the CPU that boots the system.
pub const boot_cpu = 0;
/// Max supported number of CPUs.
pub const max_cpus = 2048;

pub const LocalData = struct {
    idx: u16 = 0,

    /// Used by timer IRQ to calculate elapsed time.
    sys_timer_delta: u64 = 0,
    scheduler: sched.Scheduler = .{},

    nested_intr: u8 = 0,
    force_immediate_intrs: bool = false,
    immediate_intrs: intr.SoftHandler.List = .{},

    arch_specific: arch.CpuLocalData = undefined,

    pub inline fn isInInterrupt(self: *const LocalData) bool {
        return self.nested_intr > 0;
    }

    pub inline fn enterInterrupt(self: *LocalData) void {
        self.nested_intr += 1;
    }

    pub inline fn exitInterrupt(self: *LocalData) void {
        self.nested_intr -= 1;
    }

    /// Do atomic compare and change if is in interrupt on expected level.
    pub inline fn tryExitInterrupt(self: *LocalData, expected: u8) void {
        _ = @cmpxchgStrong(
            u8, &self.nested_intr, expected,
            expected - 1, .release, .monotonic
        );
    }
};

/// Returns the number of CPUs managed and detected by kernel.
pub inline fn getNum() u16 {
    return @truncate(bindings.getInstance().smp.cpus_data.len);
}

/// Returns local data for currect CPU.
pub inline fn getLocalData() *LocalData {
    return arch.getCpuLocalData();
}

/// Returns local data for the specific CPU.
pub inline fn getCpuData(cpu_idx: u16) *LocalData {
    return &bindings.getInstance().smp.cpus_data[cpu_idx];
}

pub inline fn getIdx() u16 {
    return arch.getCpuLocalData().idx;
}
