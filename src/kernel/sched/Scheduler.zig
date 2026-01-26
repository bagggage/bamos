//! # Scheduler Interface

// Copyright (C) 2025-2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const arch = lib.arch;
const intr = @import("../dev.zig").intr;
const lib = @import("../lib.zig");
const log = std.log.scoped(.sched);
const sched = @import("../sched.zig");
const smp = @import("../smp.zig");
const sys = @import("../sys.zig");
const Task = sched.Task;
const vm = @import("../vm.zig");

const WaitQueue = sched.WaitQueue;
const Self = @This();

const Flags = packed struct {
    need_resched: bool = false,
};

const TaskQueue = struct {
    const len = sched.max_priority;

    lists: [len]Task.List = .{ Task.List{} } ** len,
    size: u32 = 0,

    last_min: u8 = 0,

    pub fn push(self: *TaskQueue, task: *Task) void {
        const priority = task.stats.getPriority();
        if (priority < self.last_min) self.last_min = priority;

        self.lists[priority].append(&task.node);
        self.size += 1;
    }

    pub fn prepend(self: *TaskQueue, task: *Task) void {
        const priority = task.stats.getPriority();
        if (priority < self.last_min) self.last_min = priority;

        self.lists[priority].prepend(&task.node);
        self.size += 1;
    }

    pub fn pop(self: *TaskQueue) ?*Task {
        for (self.lists[self.last_min..len]) |*list| {
            if (list.popFirst()) |n| {
                self.size -= 1;
                return Task.fromNode(n);
            }

            self.last_min += 1;
        }

        return null;
    }

    pub fn remove(self: *TaskQueue, task: *Task) void {
        const priority = task.stats.getPriority();
        self.lists[priority].remove(&task.node);
    }
};

task_lock: lib.sync.Spinlock = .init(.unlocked),
task_queues: [2]TaskQueue = .{ TaskQueue{} } ** 2,

pause_queue: sched.WaitQueue = .{},

active_queue: *TaskQueue = undefined,
expired_queue: *TaskQueue = undefined,

current_task: ?*Task = null,
sleep_ctx: arch.Context = undefined,

preemption: u16 = 1,
flags: Flags = .{},

pub fn preinit(self: *Self) void {
    self.active_queue = &self.task_queues[0];
    self.expired_queue = &self.task_queues[1];
}

pub fn start(self: *Self) noreturn {
    std.debug.assert(self.current_task == null and self.isOnCurrentCpu());
    std.debug.assert(intr.isEnabledForCpu() and self.preemption == 1);

    const stack = Task.createKernelStack() catch |err| {
        log.err("Failed to create sleep context: {t}", .{err});
        lib.sync.halt();
    };
    const top = stack + Task.kernel_stack_size;
    self.sleep_ctx = .init(top, undefined);

    sys.time.maskTimerIntr(false);
    self.rescheduleAtomic();

    unreachable;
}

/// Schedule task.
/// 
/// Can be called from both atomic and kernel context.
/// You have make sure that task is not already scheduled.
pub fn enqueueTask(self: *Self, task: *Task) void {
    std.debug.assert(intr.isEnabledForCpu());
    std.debug.assert(task.stats.sleep.raw == .awake);
    std.debug.assert(!task.stats.lock.isLocked());

    task.stats.updateBonus();
    task.stats.updateTimeSlice();

    if (self.tryPreempt(task)) return;

    self.task_lock.lockIntr();
    defer self.task_lock.unlockIntr();

    self.expired_queue.prepend(task);
}

pub fn dequeueTask(self: *Self,  task: *Task) void {
    std.debug.assert(task.stats.sleep.raw != .sleep);

    self.task_lock.lockIntr();
    defer self.task_lock.unlockIntr();

    self.expired_queue.remove(task);
}

/// Yield current task time.
pub fn yield(self: *Self) void {
    const task = self.current_task.?;
    std.debug.assert(task.stats.sleep.raw == .awake);

    if (!task.stats.lock.tryLockAtomic()) {
        log.err("something is wrong... p: {}, r: {}, i: {}", .{self.preemption, self.flags.need_resched, self.getCpuLocal().nested_intr});
        return;
    }
    task.stats.yieldTime();

    {
        self.task_lock.lockIntr();
        defer self.task_lock.unlockIntr();

        self.expired_queue.push(task);
        self.disablePreemption();
    }

    self.rescheduleAtomic();
}

/// Preemt current task by provided task only if current task priority is less.
pub fn tryPreempt(self: *Self, task: *Task) bool {
    if (!self.isOnCurrentCpu()) return false;

    if (self.current_task) |current| {
        if (!current.stats.lock.tryLockAtomic()) return false;
        if (current.stats.getPriority() <= task.stats.getPriority()) {
            current.stats.lock.unlockAtomic();
            return false;
        }

        // Don't release stats.lock, it's used to say that nobody can
        // scheduled this task again, because it's already scheduled

        self.active_queue.prepend(current);
        self.active_queue.prepend(task);
    } else {
        intr.disableForCpu();
        defer intr.enableForCpu();

        self.active_queue.prepend(task);
    }

    self.disablePreemption();
    self.planRescheduling();

    // Because of immediate interrupts handlers we must check if CPU is within interrupt handler
    if (self.preemption == 1 and !self.getCpuLocal().isInInterrupt()) {
        self.rescheduleAtomic();
    } else {
        self.enablePreemptionNoResched();
    }

    return true;
}

pub inline fn planRescheduling(self: *Self) void {
    self.flags.need_resched = true;
}

pub inline fn needRescheduling(self: *const Self) bool {
    return self.flags.need_resched;
}

pub inline fn isPreemptive(self: *const Self) bool {
    return self.preemption == 0;
}

pub inline fn enablePreemptionRaw(self: *Self) void {
    self.preemption -= 1;
}

pub inline fn disablePreemption(self: *Self) void {
    self.preemption += 1;
}

pub fn enablePreemption(self: *Self) void {
    // During early boot, interrupts are disabled in kernel context,
    // so there is no guarantee that it is safe to enable them again.
    const state = intr.saveAndDisableForCpu();

    if (self.preemption == 1 and !self.getCpuLocal().isInInterrupt() and self.needRescheduling()) {
        intr.enableForCpu();
        self.rescheduleAtomic();
    } else {
        self.enablePreemptionRaw();
        intr.restoreForCpu(state);
    }
}

pub inline fn enablePreemptionNoResched(self: *Self) void {
    self.enablePreemptionRaw();
}

pub inline fn getCpuLocal(self: *Self) *smp.LocalData {
    return @fieldParentPtr("scheduler", self);
}

pub fn initWait(self: *Self) WaitQueue.Entry {
    const task = self.current_task.?;

    std.debug.assert(task.stats.sleep.raw == .awake);
    task.stats.sleep.raw = .falling_asleep;

    return WaitQueue.Entry.init(
        task,
        sys.time.getFastTimestamp()
    );
}

pub fn wait(self: *Self) void {
    const task = self.current_task.?;

    self.disablePreemption();
    if (task.stats.sleep.cmpxchgStrong(
        .needs_wakeup, .awake,
        .release, .monotonic
    ) == null) {
        @branchHint(.unlikely);
        self.enablePreemption();
        return;
    }

    self.rescheduleAtomic();
}

pub fn timerEvent(self: *Self, elapsed: sched.Ticks) void {
    std.debug.assert(self.getCpuLocal().isInInterrupt());
    @setRuntimeSafety(false);

    const task = self.current_task orelse return;
    task.stats.cpu_time +|= elapsed;

    if (self.getCpuLocal().force_immediate_intrs) {
        @branchHint(.unlikely);
        return;
    }

    if (!task.stats.lock.tryLockAtomic()) return;

    task.stats.time_slice -|= elapsed;
    if (task.stats.time_slice == 0) {
        @branchHint(.unlikely);
        // Don't release stats.lock, it's used to say that nobody can
        // scheduled this task again, because it's already scheduled

        defer self.planRescheduling();

        self.task_lock.lockAtomic();
        defer self.task_lock.unlockAtomic();

        self.expired_queue.push(task);
        return;
    }

    task.stats.lock.unlockAtomic();
}

/// Scheduler main function. Switches to next task from queue,
/// or fall into sleep if no tasks are scheduled.
/// 
/// **Call this function only in kernel context!**
pub inline fn reschedule(self: *Self) void {
    std.debug.assert(self.isPreemptive());
    self.disablePreemption();
    self.rescheduleAtomic();
}

pub fn rescheduleAtomic(self: *Self) void {
    std.debug.assert(intr.isEnabledForCpu());
    std.debug.assert(self.preemption == 1 and self.getCpuLocal().nested_intr < 2);

    const next_task = self.nextTask() orelse blk: {
        self.schedule();

        const next_task = self.nextTask() orelse {
            self.fallIntoSleep();
            return;
        };
        if (next_task == self.current_task) {
            @branchHint(.unlikely);
            std.debug.assert(next_task.stats.lock.isLocked());

            updateTaskStatsAtomic(next_task);
            self.completeSwitch(next_task);
            return;
        }
        break :blk next_task;
    };

    if (self.current_task) |task| {
        task.context.switchTo(&next_task.context);
    } else {
        next_task.onSwitch();
        next_task.context.jumpInto(next_task);
    }
}

pub noinline fn postSwitch(self: *Self, new_ctx: *arch.Context) callconv(.c) void {
    if (self.current_task) |task| blk: {
        if (!task.stats.lock.tryLockAtomic()) {
            @branchHint(.likely);
            updateTaskStatsAtomic(task);
            break :blk;
        }

        const sleep = task.stats.sleep.cmpxchgStrong(
            .falling_asleep, .sleep,
            .release, .monotonic
        ) orelse break :blk;

        switch (sleep) {
            .awake,
            .sleep,
            .falling_asleep => unreachable,
            .needs_wakeup => {
                updateTaskStatsAtomic(task);
                task.stats.sleep.store(.awake, .release);
                self.active_queue.prepend(task);
            },
        }
    }

    const new_task: ?*Task = if (new_ctx != &self.sleep_ctx) blk: {
        const task: *Task = @fieldParentPtr("context", new_ctx);
        task.onSwitch();
        break :blk task;
    } else null;

    self.completeSwitch(new_task);
}

pub inline fn completeSwitch(self: *Self, new_task: ?*Task) void {
    const old_task = self.current_task;
    if (new_task) |task| {
        _ = task.stats.sleep.cmpxchgStrong(
            .needs_wakeup, .awake,
            .release, .monotonic
        );
    }

    // Disable interrupts to prevent race condition when setting
    // `current_task` to new value, as `timerEvent` and `tryPreempt`
    // checks `current_task` and can preempt new task too early, before
    // switch is really done.

    intr.disableForCpu();
    defer intr.enableForCpu();

    self.flags.need_resched = false;
    self.current_task = new_task;

    if (old_task) |task| task.stats.lock.unlockAtomic();

    self.enablePreemptionRaw();
    self.getCpuLocal().tryExitInterrupt(1);
}

inline fn schedule(self: *Self) void {
    self.task_lock.lockIntr();
    defer self.task_lock.unlockIntr();

    const temp_queue = self.expired_queue;
    self.expired_queue = self.active_queue;
    self.active_queue = temp_queue;
}

fn fallIntoSleep(self: *Self) void {
    const pt = vm.getRootPt();
    if (vm.getPageTable() != pt) vm.setPageTable(pt);

    self.sleep_ctx.setInstrPtr(@intFromPtr(&sleepTask));

    if (self.current_task) |task| {
        task.context.switchTo(&self.sleep_ctx);
    } else {
        self.sleep_ctx.jumpInto(null);
    }
}

pub fn sleepTask() callconv(.c) noreturn {
    const self = sched.getCurrent();

    // After switch is done, flag `need_resched` was forcibly cleared,
    // even if some tasks are here, so don't halt CPU, do check before

    while (true) {
        if (self.active_queue.size > 0 or self.expired_queue.size > 0) self.reschedule();
        lib.arch.halt();
    }
}

inline fn nextTask(self: *Self) ?*Task {
    intr.disableForCpu();
    defer intr.enableForCpu();

    return self.active_queue.pop();
}

inline fn isOnCurrentCpu(self: *Self) bool {
    return self.getCpuLocal() == smp.getLocalData();
}

inline fn updateTaskStatsAtomic(task: *Task) void {
    task.stats.updateBonus();
    task.stats.updateTimeSlice();
}
