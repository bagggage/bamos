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

    task.asUserTask().thread.context.jumpTo();
}

pub fn processRescheduling(scheduler: *sched.Scheduler) void {
    scheduler.flags.need_resched = false;

    if (scheduler.flags.expire) {
        scheduler.expire();
        scheduler.flags.expire = false;
    }

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
    const curr_task = scheduler.current_task.asUserTask();
    scheduler.current_task = task;
    task.common.state = .running;

    curr_task.thread.context.switchTo(&task.asUserTask().thread.context);
}

pub fn sleep() void {
    //const scheduler = sched.getCurrent();
    //const node = scheduler.current_task.asNode();sleepTask();
}

pub fn onIntrExit() void {
    const local = smp.getLocalData();

    if (local.tryIfNotNestedInterrupt()) {
        defer local.nested_intr.fetchSub(1, .acquire);

        if (local.scheduler.needRescheduling()) processRescheduling();
    }
}

export fn timerIntrHandler() void {
    const scheduler = sched.getCurrent();
    scheduler.current_task.common.time_slice -= 1;

    if (scheduler.current_task.common.time_slice == 0) {
        scheduler.flags.expire = true;
        scheduler.planRescheduling();
    }
}

fn sleepTask() noreturn {
    sched.getCurrent().planRescheduling();
    intr.enableForCpu();

    while (true) arch.halt();

    unreachable;
}
