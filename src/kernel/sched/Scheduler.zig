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

const SleepQueue = sched.SleepQueue;
const WaitQueue = sched.WaitQueue;
const Self = @This();

const Flags = packed struct {
    need_resched: bool = false,
    want_sleep: bool = false,
    terminate: bool = false,
};

const TaskQueue = struct {
    const len = sched.max_priority;

    lists: [len]Task.List = .{Task.List{}} ** len,
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
        for (self.lists[self.last_min..self.lists.len]) |*list| {
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
task_queues: [2]TaskQueue = .{TaskQueue{}} ** 2,

active_queue: *TaskQueue = undefined,
expired_queue: *TaskQueue = undefined,

current_task: ?*Task = null,
sleep_ctx: arch.Context = undefined,

preemption: u16 = 1,
flags: Flags = .{},

sleep_queue: SleepQueue = .{},
sleep_lock: lib.sync.Spinlock = .{},

uptime_cache: u64 = 0,
event_deadline_ns: u64 = std.math.maxInt(u64),
max_event_deadline_ns: u64 = std.time.ns_per_s,
last_task_time_ns: u64 = 0,

pub fn preinit(self: *Self) void {
    self.active_queue = &self.task_queues[0];
    self.expired_queue = &self.task_queues[1];
}

pub fn start(self: *Self) noreturn {
    lib.debug.assert(
        (self.current_task == null and self.isOnCurrentCpu()) and
            (intr.isEnabledForCpu() and self.preemption == 1),
        @src(),
    );

    const stack = Task.createKernelStack() catch |err| {
        log.err("Failed to create sleep context: {t}", .{err});
        lib.sync.halt();
    };
    const top = stack + Task.kernel_stack_size;
    self.sleep_ctx = .init(top, undefined);

    self.rescheduleAtomic();
    unreachable;
}

/// Schedule task.
///
/// Can be called from both atomic and kernel context.
/// You have make sure that task is not already scheduled.
pub fn enqueueTask(self: *Self, task: *Task) void {
    lib.debug.assert(
        intr.isEnabledForCpu() and task.stats.sleep.raw == .awake and
        !task.stats.sched_lock.isLocked(),
        @src(),
    );

    updateTaskStatsAtomic(task);

    if (self.tryPreempt(task)) return;

    self.task_lock.lockIntr();
    defer self.task_lock.unlockIntr();

    self.expired_queue.prepend(task);
}

pub fn dequeueTask(self: *Self, task: *Task) void {
    lib.debug.assert(task.stats.sleep.raw != .sleep, @src());

    self.task_lock.lockIntr();
    defer self.task_lock.unlockIntr();

    self.expired_queue.remove(task);
}

/// Yield current task time.
pub fn yield(self: *Self) void {
    const task = self.current_task.?;
    lib.debug.assert(task.stats.sleep.raw == .awake, @src());

    const locked = task.stats.sched_lock.tryLockAtomic();
    lib.debug.assert(locked, @src());

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
        if (self.flags.want_sleep or !current.stats.sched_lock.tryLockAtomic()) return false;
        if (current.stats.getPriority() <= task.stats.getPriority()) {
            current.stats.sched_lock.unlockAtomic();
            return false;
        }

        // Don't release stats.lock, it's used to say that nobody can
        // scheduled this task again, because it's already scheduled

        self.active_queue.prepend(current);
        self.active_queue.prepend(task);
        self.disablePreemption();
    } else {
        intr.disableForCpu();
        defer intr.enableForCpu();

        self.active_queue.prepend(task);
        self.disablePreemption();
    }

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

    lib.debug.assert(task.stats.sleep.raw == .awake, @src());
    task.prepareForSleep();

    return .{ .task = task, .timestamp = sys.time.getUpTimeNs() };
}

pub inline fn doWait(self: *Self, comptime interruptible: bool) error{Interrupted}!void {
    const task = self.current_task.?;

    self.enterWaitCriticalSection(task) catch return;
    if (comptime interruptible) {
        try self.doInterruptibleWaitFromCriticalSection(task);
    } else {
        self.doWaitFromCriticalSection(task);
    }
}

pub fn doWaitTimeout(self: *Self, ns: u64, comptime interruptible: bool) error{Timeout, Interrupted}!void {
    lib.debug.assert(self.isOnCurrentCpu(), @src());

    // Some magic number to prevent unefficient waiting
    const min_timeout_ns = 16;
    const task = self.current_task.?;

    if (ns <= min_timeout_ns) {
        @branchHint(.unlikely);
        task.canclePrepareForSleep();
        return error.Timeout;
    }

    self.enterWaitCriticalSection(task) catch return;

    const time_ns = sys.time.getUpTimeNs();
    var entry: SleepQueue.Entry = .{
        .deadline_ns = time_ns +| ns,
        .wait_entry = .{ .task = task, .timestamp = time_ns },
    };

    self.pushSleepEntry(&entry, time_ns);
    if (comptime interruptible) {
        errdefer self.removeSleepEntryWeak(&entry);
        try self.doInterruptibleWaitFromCriticalSection(task);
    } else {
        self.doWaitFromCriticalSection(task);
    }

    if (entry.wait_entry.isRemovedFromQueue()) return error.Timeout;
    self.removeSleepEntryWeak(&entry);
}

pub fn enterWaitCriticalSection(self: *Self, task: *Task) error{ShouldAwake}!void {
    self.enterWaitCriticalSectionWeak();
    errdefer self.exitWaitCriticalSection();

    if (task.stats.sleep.load(.acquire) == .needs_wakeup) {
        @branchHint(.unlikely);

        if (task.stats.sleep.cmpxchgStrong(
            .needs_wakeup,
            .awake,
            .release,
            .monotonic,
        ) == null) {
            @branchHint(.unlikely);
            return error.ShouldAwake;
        }
    }

    lib.debug.assert(task.stats.sleep.raw != .awake, @src());
}

pub inline fn enterWaitCriticalSectionWeak(self: *Self) void {
    self.flags.want_sleep = true;
    self.disablePreemption();
}

pub inline fn exitWaitCriticalSection(self: *Self) void {
    self.enablePreemption();
    self.flags.want_sleep = false;
}

pub inline fn doWaitFromCriticalSection(self: *Self, task: *Task) void {
    self.rescheduleAtomic();
    lib.debug.assert(task.stats.sleep.raw == .awake, @src());
}

pub fn doInterruptibleWaitFromCriticalSection(self: *Self, task: *Task) error{Interrupted}!void {
    const user = &task.spec.user;

    user.sig_wait.store(true, .release);
    defer user.sig_wait.store(false, .release);

    if (user.pendingSignals().mask != 0) {
        task.canclePrepareForSleep();
        self.exitWaitCriticalSection();
        return error.Interrupted;
    }

    self.doWaitFromCriticalSection(task);

    if (user.pendingSignals().mask != 0) return error.Interrupted;
}

pub fn sleepFor(self: *Self, ns: u64) error{Interrupted}!void {
    lib.debug.assert(self.isOnCurrentCpu(), @src());

    self.enterWaitCriticalSectionWeak();

    var entry: SleepQueue.Entry = .{
        .deadline_ns = undefined,
        .wait_entry = self.initWait(),
    };

    const time_ns = entry.wait_entry.timestamp;
    entry.deadline_ns = time_ns + ns;

    self.pushSleepEntry(&entry, time_ns);
    errdefer self.removeSleepEntryWeak(&entry);

    if (entry.wait_entry.task.spec == .user) {
        try self.doInterruptibleWaitFromCriticalSection(entry.wait_entry.task);
    } else {
        self.doWaitFromCriticalSection(entry.wait_entry.task);
    }
}

pub fn timerInterrupt(self: *Self) void {
    self.event_deadline_ns = std.math.maxInt(u64);
}

pub fn timerEvent(self: *Self, time_ns: u64) void {
    lib.debug.assert(self.getCpuLocal().isInInterrupt(), @src());
    @setRuntimeSafety(false);

    self.max_event_deadline_ns = time_ns + sys.time.getMaxTimerEventDelayNs();

    const sleep_deadline_ns = self.processSleepingTasks(time_ns);
    const task_deadline_ns = self.processCurrentTask(time_ns);

    self.updateTimerEventDeadline(time_ns, @min(sleep_deadline_ns, task_deadline_ns));
}

/// Scheduler main function. Switches to next task from queue,
/// or fall into sleep if no tasks are scheduled.
///
/// **Call this function only in kernel context!**
pub inline fn reschedule(self: *Self) void {
    lib.debug.assert(self.isPreemptive(), @src());
    self.disablePreemption();
    self.rescheduleAtomic();
}

pub fn rescheduleAtomic(self: *Self) void {
    lib.debug.assert(intr.isEnabledForCpu(), @src());
    lib.debug.assert(self.preemption == 1 and self.getCpuLocal().nested_intr < 2, @src());

    self.uptime_cache = sys.time.getUpTimeNs();
    const next_task = self.nextTask() orelse blk: {
        self.schedule();

        const next_task = self.nextTask() orelse {
            self.fallIntoSleep();
            return;
        };

        if (next_task == self.current_task) {
            @branchHint(.unlikely);
            lib.debug.assert(next_task.stats.sched_lock.isLocked(), @src());

            updateTaskStatsAtomic(next_task);
            self.completeSwitch(next_task);
            return;
        }

        break :blk next_task;
    };

    if (self.current_task) |task| {
        task.context.switchTo(&next_task.context);
    } else {
        next_task.onSwitchTo();
        next_task.context.jumpInto(next_task);
    }
}

pub noinline fn postSwitch(self: *Self, new_ctx: *arch.Context) callconv(.c) void {
    if (self.current_task) |task| blk: {
        if (!task.stats.sched_lock.tryLockAtomic()) {
            @branchHint(.likely);

            if (self.flags.terminate) {
                @branchHint(.cold);

                self.flags = .{};
                self.current_task = null;

                task.delete();
                break :blk;
            }

            updateTaskStatsAtomic(task);
            break :blk;
        }

        // Disable interrupts to prevent any wakeup of current task from
        // current CPU before the sched_lock would be released.
        // This is fix deadlock issue as any awake waits until sched_lock is released.
        // Don't enable interrupts again, it's safe
        intr.disableForCpu();

        const sleep = task.stats.sleep.cmpxchgStrong(
            .falling_asleep, .sleep,
            .release, .monotonic
        ) orelse break :blk;

        switch (sleep) {
            .awake, .sleep, .falling_asleep => unreachable,
            .needs_wakeup => {
                updateTaskStatsAtomic(task);
                task.stats.sleep.store(.awake, .release);
                self.active_queue.prepend(task);
            },
        }
    }

    const new_task: ?*Task = if (new_ctx != &self.sleep_ctx) blk: {
        const task: *Task = @fieldParentPtr("context", new_ctx);
        task.onSwitchTo();
        break :blk task;
    } else null;

    self.completeSwitch(new_task);
}

pub inline fn completeSwitch(self: *Self, new_task: ?*Task) void {
    const old_task = self.current_task;
    // Why do we need this???
    //
    // This code adds a bug:
    // 1. Task was `falling_into_sleep`;
    // 2. Someone awake it (sleep state is set to `needs_wakeup`);
    // 3. Timer event preempt this task (equeue it to resume later);
    // 4. Later task is resumed, but this code drops `needs_wakeup` state!
    // 5. As a result, when the task finally calls `reschedule`
    //    the scheduler would be surprised that task is not locked,
    //    but at the same time it was in `awake` state
    //
    //if (new_task) |task| {
    //    _ = task.stats.sleep.cmpxchgStrong(
    //        .needs_wakeup, .awake,
    //        .release, .monotonic
    //    );
    //}

    // Disable interrupts to prevent race condition when setting
    // `current_task` to new value, as `timerEvent` and `tryPreempt`
    // checks `current_task` and can preempt new task too early, before
    // switch is really done.

    intr.disableForCpu();
    defer intr.enableForCpu();

    self.flags = .{};
    self.current_task = new_task;

    if (old_task) |task| {
        task.stats.sched_lock.unlockAtomic();
        task.stats.stopSystemTime(self.uptime_cache);
    }

    if (new_task) |task| {
        task.stats.startSystemTime(self.uptime_cache);
        self.updateCurrentTaskDeadline(task.stats.time_slice_ns);
    } else {
        self.updateCurrentTaskDeadline(sys.time.getMaxTimerEventDelayNs());
    }

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

fn sleepTask() callconv(.c) noreturn {
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

fn pushSleepEntry(self: *Self, entry: *SleepQueue.Entry, time_ns: u64) void {
    if (self.sleep_lock.tryLockIntr() == false) unreachable;
    defer self.sleep_lock.unlockIntr();

    self.sleep_queue.push(entry);
    self.updateTimerEventDeadline(time_ns, entry.deadline_ns);
}

fn removeSleepEntryWeak(self: *Self, entry: *SleepQueue.Entry) void {
    self.sleep_lock.lockIntr();
    defer self.sleep_lock.unlockIntr();

    self.sleep_queue.removeWeak(entry);
}

fn processSleepingTasks(self: *Self, time_ns: u64) u64 {
    if (self.sleep_lock.tryLockAtomic()) {
        @branchHint(.likely);
        defer self.sleep_lock.unlockAtomic();

        var entry = self.sleep_queue.process(time_ns);
        while (entry) |e| {
            const task = e.wait_entry.task;
            if (task.tryWakeup()) self.enqueueTask(task);

            entry = if (e.wait_entry.node.next) |n| SleepQueue.Entry.fromNode(n) else null;
            e.wait_entry.markAsRemovedFromQueue();
        }
    }

    return self.sleep_queue.getEarliestDeadline();
}

fn processCurrentTask(self: *Self, time_ns: u64) u64 {
    const task = self.current_task orelse return sched.no_deadline;
    const elapsed_time_ns = @min(time_ns - self.last_task_time_ns, std.math.maxInt(u32));

    self.last_task_time_ns = time_ns;
    task.stats.cpu_time_ns +|= elapsed_time_ns;

    if (self.flags.want_sleep or !task.stats.sched_lock.tryLockAtomic()) return sched.no_deadline;
    task.stats.time_slice_ns -|= elapsed_time_ns;

    if (task.stats.time_slice_ns == 0) {
        @branchHint(.unlikely);
        // Don't release stats.lock, it's used to say that nobody can
        // scheduled this task again, because it's already scheduled

        defer self.planRescheduling();

        self.task_lock.lockAtomic();
        defer self.task_lock.unlockAtomic();

        self.expired_queue.push(task);
        return sched.no_deadline;
    }

    task.stats.sched_lock.unlockAtomic();
    return time_ns + task.stats.time_slice_ns;
}

fn updateCurrentTaskDeadline(self: *Self, after_ns: u64) void {
    const time_ns = self.uptime_cache;
    self.last_task_time_ns = time_ns;

    const sleep_deadline_ns = self.sleep_queue.getEarliestDeadline();
    const task_deadline_ns = time_ns + after_ns;

    self.updateTimerEventDeadline(time_ns, @min(sleep_deadline_ns, task_deadline_ns));
}

fn updateTimerEventDeadline(self: *Self, time_ns: u64, deadline_ns: u64) void {
    const safe_deadline_ns = @min(self.max_event_deadline_ns, deadline_ns);
    if (safe_deadline_ns >= self.event_deadline_ns) return;

    self.event_deadline_ns = safe_deadline_ns;

    const event_source = sys.time.getEventSource();
    const ns = @max(safe_deadline_ns -| time_ns, std.time.ns_per_us / 2);
    const ticks = (ns * lib.fp_scale) / event_source.ns_per_tick_fp;

    event_source.setEventDeadline(ticks) catch unreachable;
}
