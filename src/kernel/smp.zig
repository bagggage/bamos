//! # Symmetric multiprocessing

// Copyright (C) 2024-2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");
const builtin = @import("builtin");

const arch = lib.arch;
const boot = @import("boot.zig");
const lib = @import("lib.zig");
const log = std.log.scoped(.smp);
const sys = @import("sys.zig");
const sched = @import("sched.zig");
const intr = @import("dev.zig").intr;
const vm = @import("vm.zig");

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

var is_boot_cpu: bool = true;

var init_lock: lib.sync.Spinlock = .init(.unlocked);
var init_cpu_idx: u16 = 0;

var cpus_data: []LocalData = undefined;

/// Returns `true` on kernel boot CPU, `false` otherwise.
pub inline fn bootCpu() bool {
    init_lock.lockAtomic();

    if (!is_boot_cpu) {
        initCpu();
        init_lock.unlockAtomic();

        return false;
    }

    arch.initCpu();
    boot.init() catch lib.sync.halt();

    const cpus_num = boot.getCpusNum();
    cpus_data.len = cpus_num;

    if (cpus_num > max_cpus) @panic("The number of CPUs is bigger then maximum supported number!");
    return true;
}

pub fn init() void {
    const cpus_num = getNum();

    const pool_size = @sizeOf(LocalData) * cpus_num;
    const pool_pages = std.math.divCeil(u32, pool_size, vm.page_size) catch unreachable;

    const phys = boot.alloc(pool_pages) orelse @panic("No memory for CPU local storage");

    cpus_data.ptr = @ptrFromInt(vm.getVirtLma(phys));
    cpus_data.len = cpus_num;

    for (cpus_data) |*data| {
        data.* = .{};
        data.scheduler.preinit();
    }

    initCpuLocal();
    is_boot_cpu = false;
}

pub inline fn initAll() void {
    init_lock.unlockAtomic();
}

pub inline fn isEarlyBoot() bool {
    return is_boot_cpu;
}

/// Returns the number of CPUs managed and detected by kernel.
pub inline fn getNum() u16 {
    return @truncate(cpus_data.len);
}

/// Returns local data for currect CPU.
pub inline fn getLocalData() *LocalData {
    return arch.getCpuLocalData();
}

/// Returns local data for the specific CPU.
/// 
/// - `cpu_idx`
///
/// @noexport
pub inline fn getCpuData(cpu_idx: u16) *LocalData {
    return &cpus_data[cpu_idx];
}

pub inline fn getIdx() u16 {
    return arch.getCpuLocalData().idx;
}

fn initCpu() void {
    arch.initCpu();
    vm.setPageTable(vm.getRootPt());

    const pt = vm.createPageTable() orelse {
        log.err("Not enough memory to allocate page table per each cpu", .{});
        lib.sync.halt();
    };

    vm.setPageTable(pt);

    initCpuLocal();
}

fn initCpuLocal() void {
    const cpu_idx = init_cpu_idx;
    init_cpu_idx += 1;

    const local_data = &cpus_data[cpu_idx];
    local_data.idx = cpu_idx;

    arch.setCpuLocalData(local_data);
    arch.setupCpu(cpu_idx);
}
