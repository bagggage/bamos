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

pub fn processRescheduling(scheduler: *sched.Scheduler) void {
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

pub fn switchTask(scheduler: *sched.Scheduler, task: *sched.AnyTask) void {
    const local = scheduler.getCpuLocal();

    const curr_task = scheduler.current_task.asKernelTask();
    task.common.state = .running;

    if (local.isInInterrupt()) local.exitInterrupt();
    if (task.asKernelTask() == curr_task) return;

    scheduler.current_task = task;
    curr_task.thread.context.switchTo(&task.asKernelTask().thread.context);
}

pub fn sleep() void {
    //const scheduler = sched.getCurrent();
    //const node = scheduler.current_task.asNode();sleepTask();
}

pub fn onIntrExit() void {
    const local = smp.getLocalData();

    if (local.tryIfNotNestedInterrupt()) {
        if (local.scheduler.needRescheduling()) {
            processRescheduling(&local.scheduler);
        } else {
            local.exitInterrupt();
        }
    }

    local.exitInterrupt();
}

export fn timerIntrHandler() void {
    const local = smp.getLocalData();
    local.nested_intr.raw += 1;

    const scheduler = &local.scheduler;
    const curr_task = scheduler.current_task;
    
    if (curr_task.common.time_slice > 0) {
        curr_task.common.time_slice -= 1;

        if (curr_task.common.time_slice == 0) {
            scheduler.flags.expire = true;
            scheduler.planRescheduling();
        }
    } else {
        log.warn("time slice is zero but interrupt received!", .{});
    }
}

pub fn sleepTask() noreturn {
    const local = smp.getLocalData();

    if (local.isInInterrupt()) local.exitInterrupt();

    // sure that interrupts is enabled.
    intr.enableForCpu();
    while (true) arch.halt();

    unreachable;
}
