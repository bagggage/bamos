//! # Executor

// Copyright (C) 2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

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

pub fn begin() noreturn {
    const scheduler = sched.getCurrent();
    scheduler.schedule();

    const task = scheduler.next() orelse {
        log.warn("No tasks to begin with. Halting the kernel...", .{});
        utils.halt();
    };

    scheduler.current_task = task;
    task.asUserTask().thread.context.jumpTo();
}

pub fn processRescheduling() void {
    const local = smp.getLocalData();
    const scheduler = &local.scheduler;

    scheduler.schedule();
    processNextTask(scheduler);
}

pub fn processNextTask(scheduler: *sched.Scheduler) void {
    if (scheduler.next()) |next| {
        const prev = scheduler.current_task;

        scheduler.current_task = next;
        arch.Context.switchTo(
            &prev.asUserTask().thread.context,
            &next.asUserTask().thread.context
        );
    } else {
        sleepTask();
    }
}

pub fn onIntrExit() void {
    const local = smp.getLocalData();

    if (!local.isInInterrupt() and local.scheduler.needRescheduling()) {
        processRescheduling();
    }
}

pub export fn timerIntrHandler() void {
    processNextTask(sched.getCurrent());

}

fn sleepTask() void {
    while (true) arch.halt();
}
