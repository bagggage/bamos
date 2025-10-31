//! # Scheduler Interface

// Copyright (C) 2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const arch = utils.arch;
const sched = @import("../sched.zig");
const smp = @import("../smp.zig");
const sys = @import("../sys.zig");
const Task = sched.Task;
const log = std.log.scoped(.sched);
const intr = @import("../dev.zig").intr;
const utils = @import("../utils.zig");
const vm = @import("../vm.zig");

const WaitQueue = sched.WaitQueue;
const Self = @This();

const Flags = packed struct {
    need_resched: bool = false,
    need_preempt: bool = false,
    sleep: bool = false,
};

const TaskQueue = struct {
    const len = sched.max_priority;

    lists: [len]Task.List = .{ Task.List{} } ** len,
    last_min: u8 = 0,
    size: u8 = 0,

    pub fn push(self: *TaskQueue, task: *Task) void {
        task.stats.state = .scheduled;

        const priority = task.stats.getPriority();
        if (priority < self.last_min) self.last_min = priority;

        self.lists[priority].append(task.asNode());
        self.size +%= 1;
    }

    pub fn pop(self: *TaskQueue) ?*Task {
        for (self.lists[self.last_min..len]) |*list| {
            if (list.popFirst()) |node| {
                self.size -%= 1;
                return &node.data;
            }

            self.last_min += 1;
        }

        return null;
    }

    pub fn remove(self: *TaskQueue, task: *Task) void {
        const priority = task.stats.getPriority();
        self.lists[priority].remove(task.asNode());
    }
};

task_lock: utils.Spinlock = .init(.unlocked),
task_queues: [2]TaskQueue = .{ TaskQueue{} } ** 2,

pause_queue: sched.WaitQueue = .{},

active_queue: *TaskQueue = undefined,
expired_queue: *TaskQueue = undefined,

current_task: *Task = undefined,

preemption: u16 = 1,
flags: Flags = .{},

pub fn preinit(self: *Self) void {
    self.active_queue = &self.task_queues[0];
    self.expired_queue = &self.task_queues[1];
}

pub fn begin(self: *Self) noreturn {
    self.schedule();

    const task = self.next() orelse {
        log.warn("No tasks to begin with. Halting core...", .{});
        utils.halt();
    };

    self.current_task = task;
    task.stats.state = .running;

    self.enablePreemptionRaw();

    std.debug.assert(intr.isEnabledForCpu());
    sys.time.maskTimerIntr(false);

    task.context.jumpTo();
}

/// Schedule task.
/// 
/// Can be called from both atomic and kernel context.
/// You have make sure that task is not already scheduled.
pub fn enqueueTask(self: *Self, task: *Task) void {
    std.debug.assert(task.stats.state == .free or task.stats.state == .waiting);

    task.stats.updateBonus();
    task.stats.updateTimeSlice();

    defer if (self.flags.sleep) {
        @branchHint(.unlikely);

        self.flags.sleep = false;
        self.planRescheduling();
    } else {
        self.tryPreempt(task);
    };

    self.task_lock.lock();
    defer self.task_lock.unlock();

    self.expired_queue.push(task);
}

pub fn dequeueTask(self: *Self,  task: *Task) void {
    std.debug.assert(task.stats.state == .scheduled);

    defer task.stats.state = .free;

    self.task_lock.lock();
    defer self.task_lock.unlock();

    self.expired_queue.remove(task);
}

/// Yield current task time.
pub fn yield(self: *Self) void {
    // Make sure operations order is correct.
    // 1. yieldTime() - increase sleep time and update priority.
    // 2. push() - changes task state, so tick() cannot change time slice.
    // 3. updated time slice.

    self.current_task.stats.yieldTime();
    defer self.current_task.stats.updateTimeSlice();

    self.task_lock.lockIntr();
    defer self.task_lock.unlockIntr();

    self.expired_queue.push(self.current_task);
}

/// Preemt current task by provided task only in case:
/// current task priority is less and preemtion is enabled.
pub fn tryPreempt(self: *Self, task: *const Task) void {
    if (
        self.current_task.stats.state == .running and
        self.current_task.stats.getPriority() > task.stats.getPriority()
    ) self.preempt();
}

pub inline fn preempt(self: *Self) void {
    self.current_task.stats.state = .unscheduled;

    if (self.isPreemptive()) {
        self.reschedule();
        return;
    }

    self.delayPreemption();
}

pub inline fn delayPreemption(self: *Self) void {
    self.flags.need_preempt = true;
}

/// Scheduler main function. Switches to next task from queue,
/// or fall into sleep if no tasks are scheduled.
/// 
/// **Call this function only in kernel context!**
pub fn reschedule(self: *Self) void {
    std.debug.assert(intr.isEnabledForCpu() and self.current_task.stats.state != .running);

    self.flags.need_resched = false;

    const is_expire = self.current_task.stats.time_slice == 0;
    const is_preempted = !is_expire and self.current_task.stats.state == .unscheduled;

    if (is_expire) self.onTimeExpired();

    var task = self.next();
    if (task == null) {
        intr.disableForCpu();

        self.schedule();
        task = self.active_queue.pop();

        if (task == null) {
            self.sleepTask();
            return;
        }

        intr.enableForCpu();
    }

    if (is_preempted) self.onPreempt();

    self.switchTask(task.?);
}

inline fn schedule(self: *Self) void {
    self.task_lock.lockAtomic();
    defer self.task_lock.unlockAtomic();

    const temp_queue = self.expired_queue;
    self.expired_queue = self.active_queue;
    self.active_queue = temp_queue;
}

pub inline fn planRescheduling(self: *Self) void {
    self.flags.need_resched = true;
}

pub inline fn needRescheduling(self: *const Self) bool {
    return self.flags.need_resched;
}

pub inline fn getCpuLocal(self: *Self) *smp.LocalData {
    return @fieldParentPtr("scheduler", self);
}

pub fn enablePreemption(self: *Self) void {
    if (self.preemption == 1 and self.flags.need_preempt) {
        self.flags.need_preempt = false;

        self.enablePreemptionRaw();
        self.reschedule();
    } else {
        self.enablePreemptionRaw();
    }
}

pub fn enablePreemptionNoResched(self: *Self) void {
    if (self.preemption == 1 and self.flags.need_preempt) {
        self.flags.need_preempt = false;

        self.enablePreemptionRaw();
        self.planRescheduling();
    } else {
        self.enablePreemptionRaw();
    }
}

inline fn enablePreemptionRaw(self: *Self) void {
    _ = @atomicRmw(u16, &self.preemption, .Sub, 1, .release);
}

pub inline fn disablePreemption(self: *Self) void {
    _ = @atomicRmw(u16, &self.preemption, .Add, 1, .release);
}

pub inline fn isPreemptive(self: *const Self) bool {
    return self.preemption == 0;
}

pub fn tick(self: *Self) void {
    @setRuntimeSafety(false);
    const curr_task = self.current_task;

    if (
        curr_task.stats.state == .running and
        curr_task.stats.time_slice > 0
    ) {
        curr_task.stats.time_slice -= 1;
        curr_task.stats.cpu_time += 1;

        if (curr_task.stats.time_slice == 0) {
            self.current_task.stats.state = .unscheduled;
            self.delayPreemption();
        }
    }
}

pub fn initWait(self: *Self) WaitQueue.QNode {
    const task = self.current_task;
    task.stats.state = .waiting;

    return WaitQueue.initEntry(
        task,
        sys.time.getFastTimestamp()
    );
}

pub inline fn doWait(self: *Self) void {
    self.reschedule();
}

inline fn next(self: *Self) ?*Task {
    intr.disableForCpu();
    defer intr.enableForCpu();

    return self.active_queue.pop();
}

/// Handles the case when the current task's time has expired.
inline fn onTimeExpired(self: *Self) void {
    self.current_task.stats.updateBonus();
    defer self.current_task.stats.updateTimeSlice();

    self.task_lock.lockIntr();
    defer self.task_lock.unlockIntr();

    self.expired_queue.push(self.current_task);
}

inline fn onPreempt(self: *Self) void {
    self.active_queue.push(self.current_task);
}

export fn sleepTask(self: *Self) void {
    std.debug.assert(intr.isEnabledForCpu() == false);

    const local = self.getCpuLocal();
    const task = self.current_task;

    local.tryExitInterrupt(1);

    self.flags.sleep = true;
    intr.enableForCpu();

    // Waiting for awake.
    while (task.stats.state != .running) {
        arch.halt();
    }
}

fn switchTask(self: *Self, task: *sched.Task) void {
    const local = self.getCpuLocal();
    const curr_task = self.current_task;

    if (task == curr_task) {
        // Don't waste time on switch.
        self.switchEnd(local);
        return;
    }

    self.current_task = task;
    curr_task.context.switchTo(&task.context);
}

inline fn switchEnd(self: *Self, local: *smp.LocalData) void {
    // Handle special case when `reschedule` called from `dev.intr.onIntrExit`.
    local.tryExitInterrupt(1);
    self.current_task.stats.state = .running;
}

/// Used from arch-specific implementation to complete swtiching.
export fn switchEndEx() void {
    const self = sched.getCurrent();
    const local = self.getCpuLocal();

    self.switchEnd(local);
}