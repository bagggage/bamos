//! # Executor

// Copyright (C) 2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.executor);

const arch = @import("../utils.zig").arch;
const sched = @import("../sched.zig");
const dev = @import("../dev.zig");
const intr = dev.intr;
const smp = @import("../smp.zig");
const utils = @import("../utils.zig");

pub fn init() !void {
    try arch.executor.init();
}

pub fn begin(scheduler: *sched.Scheduler) noreturn {
    const task = scheduler.next() orelse {
        log.warn("No tasks to begin with. Halting core...", .{});
        utils.halt();
    };

    scheduler.current_task = task;
    task.common.state = .running;

    scheduler.enablePreemtion();

    std.debug.assert(intr.isEnabledForCpu());
    if (smp.getIdx() == 0) arch.executor.maskTimerIntr(false);

    task.asUserTask().thread.context.jumpTo();
}

pub fn reschedule(scheduler: *sched.Scheduler) void {
    scheduler.flags.need_resched = false;

    if (scheduler.flags.expire) scheduler.expire();

    var task = scheduler.next();
    if (task == null) {
        scheduler.schedule();
        task = scheduler.next();

        // TODO: Check if it's correct
        if (task == null) sleepTask();
    }

    switchTask(scheduler, task.?);
}

pub fn yeild() void {
    const scheduler = sched.getCurrent();
    scheduler.disablePreemtion();

    scheduler.yeild();
    reschedule(scheduler);
}

pub fn pause() void {
    const scheduler = sched.getCurrent();
    const task = scheduler.current_task;

    scheduler.disablePreemtion();

    task.common.yeildBonus();
    task.common.state = .waiting;

    reschedule(scheduler);
}

pub fn awake(task: *sched.AnyTask) void {
    std.debug.assert(task.common.state == .waiting);

    const sleep_bonus = 16;
    const local = smp.getLocalData();

    task.common.updateInteractivity(sleep_bonus);
    local.scheduler.enqueueTask(task);
}

/// Returns number of milliseconds per one timer tick.
pub inline fn getTickGranule() u8 {
    return arch.executor.time_slice_granule;
}

pub fn onIntrExit() void {
    @setRuntimeSafety(false);

    const local = smp.getLocalData();

    if (local.tryIfNotNestedInterrupt()) {
        if (local.scheduler.needRescheduling()) {
            reschedule(&local.scheduler);
        } else {
            local.exitInterrupt();
        }
    }
}

fn switchTask(scheduler: *sched.Scheduler, task: *sched.AnyTask) void {
    const local = scheduler.getCpuLocal();

    const curr_task = scheduler.current_task.asKernelTask();
    task.common.state = .running;

    if (local.isInInterrupt()) local.exitInterrupt();
    if (task.asKernelTask() == curr_task) {
        scheduler.enablePreemtion();
        return;
    }

    scheduler.current_task = task;
    scheduler.enablePreemtion();

    curr_task.thread.context.switchTo(&task.asKernelTask().thread.context);
}

fn sleepTask() noreturn {
    const local = smp.getLocalData();
    local.scheduler.enablePreemtion();

    if (local.isInInterrupt()) local.exitInterrupt();

    // sure that interrupts is enabled.
    intr.enableForCpu();
    while (true) arch.halt();

    unreachable;
}

export fn timerIntrHandler() void {
    @setRuntimeSafety(false);

    const local = smp.getLocalData();
    local.enterInterrupt();

    const scheduler = &local.scheduler;
    const curr_task = scheduler.current_task;

    if (curr_task.common.time_slice > 0) {
        curr_task.common.time_slice -= 1;

        if (curr_task.common.time_slice == 0) {
            scheduler.flags.expire = true;
            scheduler.planRescheduling();
        }
    }
}
