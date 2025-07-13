//! # Symmetric multiprocessing

// Copyright (C) 2024 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const arch = utils.arch;
const boot = @import("boot.zig");
const log = std.log.scoped(.smp);
const sys = @import("sys.zig");
const sched = @import("sched.zig");
const utils = @import("utils.zig");
const vm = @import("vm.zig");

const Spinlock = utils.Spinlock;

/// Index of the CPU that boots the system.
pub const boot_cpu = 0;

pub const LocalData = struct {
    idx: u16 = 0,

    current_sp: usize = 0,
    kernel_sp: usize = 0,

    scheduler: sched.Scheduler = .{},

    nested_intr: std.atomic.Value(u8) = .init(0),

    arch_specific: arch.CpuLocalData = undefined,

    pub inline fn isInInterrupt(self: *const LocalData) bool {
        return self.nested_intr.raw > 0;
    }

    pub fn tryIfNotNestedInterrupt(self: *LocalData) bool {
        return self.nested_intr.cmpxchgWeak(
            0, 1,
            .acquire, .monotonic
        ) == null;
    }

    pub inline fn enterInterrupt(self: *LocalData) void {
        self.nested_intr.raw += 1;
    }

    pub inline fn exitInterrupt(self: *LocalData) void {
        self.nested_intr.raw -= 1;
    }

    /// Do atomic compare and change if is in interrupt on expected level.
    pub inline fn tryExitInterrupt(self: *LocalData, expected: u8) void {
        _ = self.nested_intr.cmpxchgWeak(
            expected, expected - 1,
            .monotonic, .monotonic
        );
    }
};

var init_lock = Spinlock.init(.unlocked);

var cpus_data: []LocalData = undefined;

pub fn preinit() void {
    const Static = opaque {
        var is_boot_cpu = true;
    };

    init_lock.lockAtomic();

    if (Static.is_boot_cpu) {
        Static.is_boot_cpu = false;

        cpus_data.len = boot.getCpusNum();
    } else {
        waitForInit();
    }
}

pub fn init() !void {
    const cpus_num = getNum();

    const pool_size = @sizeOf(LocalData) * cpus_num;
    const pool_pages = std.math.divCeil(u32, pool_size, vm.page_size) catch unreachable;

    const phys = boot.alloc(pool_pages) orelse return error.NoMemory;

    cpus_data.ptr = @ptrFromInt(vm.getVirtLma(phys));
    cpus_data.len = cpus_num;

    @memset(cpus_data, LocalData{});
}

/// @noexport
pub inline fn initAll() void {
    init_lock.unlockAtomic();
}

pub fn initCpu() void {
    const Static = struct{
        pub var curr_cpu_idx: u16 = 0;
    };

    const cpu_idx = Static.curr_cpu_idx;
    Static.curr_cpu_idx += 1;

    if (cpu_idx != boot_cpu) {
        arch.initCpu();

        vm.setPt(vm.getRootPt());

        const pt = vm.newPt() orelse {
            log.err("Not enough memory to allocate page table per each cpu", .{});
            utils.halt();
        };

        vm.setPt(pt);
    }

    const local_data = &cpus_data[cpu_idx];
    local_data.idx = cpu_idx;

    arch.setCpuLocalData(local_data);
    arch.setupCpu(cpu_idx);
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

fn waitForInit() noreturn {
    initCpu();
    init_lock.unlockAtomic();

    sched.init() catch unreachable;

    log.warn("CPU {} initialized", .{getIdx()});
    sched.waitStartup();
}
