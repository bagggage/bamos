//! # Symmetric multiprocessing

const std = @import("std");

const arch = utils.arch;
const boot = @import("boot.zig");
const log = @import("log.zig");
const utils = @import("utils.zig");
const vm = @import("vm.zig");

const Spinlock = utils.Spinlock;

pub const LocalData = struct {
    idx: u16,
    arch_specific: arch.CpuLocalData,
};

var init_lock = Spinlock.init(.unlocked);
var is_initial_cpu = true;

var cpus_data: []LocalData = undefined;

pub fn preinit() void {
    init_lock.lock();

    if (is_initial_cpu) {
        is_initial_cpu = false;

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
}

pub inline fn initAll() void {
    init_lock.unlock();
}

pub fn initCpu() void {
    const Static = struct{
        pub var curr_cpu_idx: u16 = 0;
    };

    const cpu_idx = Static.curr_cpu_idx;
    Static.curr_cpu_idx += 1;

    if (cpu_idx > 0) {
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

pub inline fn getNum() u16 {
    return @truncate(cpus_data.len);
}

pub inline fn getLocalData() *LocalData {
    return arch.getCpuLocalData();
}

pub inline fn getCpuData(cpu_idx: u16) *LocalData {
    return &cpus_data[cpu_idx];
}

pub inline fn getIdx() u16 {
    return arch.getCpuLocalData().idx;
}

fn waitForInit() noreturn {
    initCpu();

    init_lock.unlock();

    log.warn("CPU {} initialized", .{getIdx()});
    utils.halt();
}
