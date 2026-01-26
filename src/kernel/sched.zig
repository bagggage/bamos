//! # Scheduling and Task Management Module

// Copyright (C) 2025-2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const dev = @import("dev.zig");
const lib = @import("lib.zig");
const log = std.log.scoped(.sched);
const smp = @import("smp.zig");
const sys = @import("sys.zig");
const vm = @import("vm.zig");

/// Scheduler timer target frequency.
pub const hz = 1000;
pub const min_slice_ticks = 3;
pub const max_slice_ticks = std.math.maxInt(Ticks);
/// Maximum priority (starting from 1).
pub const max_priority = 1 << @bitSizeOf(Priority);

/// Less is better.
pub const Priority = u5;
pub const PriorityDelta = i4;
pub const Ticks = u4;

pub const Scheduler = @import("sched/Scheduler.zig");
pub const Task = @import("sched/Task.zig");

pub const PrivilegeLevel = enum(u8) {
    userspace,
    kernel
};

pub const WaitQueue = struct {
    pub const QList = lib.atomic.SinglyLinkedList;
    pub const QNode = QList.Node;

    pub const Entry = struct {
        task: *Task,
        /// Timestamp of start of wait in nanoseconds.
        timestamp: u64 = 0,
        node: QNode = .{},

        pub inline fn init(task: *Task, timestamp: u64) Entry {
            return .{
                .task = task,
                .timestamp = timestamp
            };
        }

        inline fn fromNode(node: *QNode) *Entry {
            return @fieldParentPtr("node", node);
        }
    };

    list: QList = .{},

    pub inline fn push(self: *WaitQueue, entry: *Entry) void {
        self.list.prepend(&entry.node);
    }

    pub inline fn pop(self: *WaitQueue) ?*Entry {
        const node = self.list.popFirst() orelse return null;
        const entry = Entry.fromNode(node);

        if (!entry.task.tryWakeup()) return null;
        return entry;
    }

    pub fn remove(self: *WaitQueue, task: *Task) ?*Entry {
        var node = self.list.first.load(.acquire);
        const entry = blk: {
            while (node) |n| : (node = n.next) {
                const temp = Entry.fromNode(n);
                if (temp.task == task) break :blk temp;
            }
            return null;
        };

        self.list.remove(&entry.node);
        return entry;
    }
};

/// Minimal timer interrupt interval in milliseconds.
var time_granule_ms: u32 = 0;
var initialized: bool = false;

pub inline fn isInitialized() bool {
    return initialized;
}

pub inline fn getScheduler(cpu_idx: u16) *Scheduler {
    return &smp.getCpuData(cpu_idx).scheduler;
}

pub inline fn getCurrent() *Scheduler {
    return &smp.getLocalData().scheduler;
}

pub inline fn getCurrentTask() *Task {
    return getCurrent().current_task.?;
}

pub fn startup(cpu_idx: u16, taskHandler: *const fn() noreturn) !void {
    const scheduler = getScheduler(cpu_idx);
    const task = try Task.create(.{ .kernel = .{ .name = "startup" } }, @intFromPtr(taskHandler));

    scheduler.enqueueTask(task);
    initialized = true;

    if (cpu_idx == smp.getIdx()) scheduler.start();
}

pub inline fn waitStartup() noreturn {
    getCurrent().start();
}

pub inline fn enqueue(task: *Task) void {
    std.debug.assert(dev.intr.isEnabledForCpu());
    // TODO: CPU balancing.
    getCurrent().enqueueTask(task);
}

/// Yield current task time.
pub inline fn yield() void {
    const scheduler = getCurrent();
    std.debug.assert(!scheduler.getCpuLocal().isInInterrupt());

    scheduler.yield();
}

pub inline fn pause() void {
    const scheduler = getCurrent();
    std.debug.assert(scheduler.isPreemptive() and !scheduler.getCpuLocal().isInInterrupt());

    waitRaw(scheduler, &scheduler.pause_queue);
}

pub fn pauseUnlock(lock: *lib.sync.Spinlock) void {
    std.debug.assert(lock.exclusion.raw == .locked_no_intr);

    const scheduler = getCurrent();
    std.debug.assert(!scheduler.isPreemptive() and !scheduler.getCpuLocal().isInInterrupt());

    var entry = scheduler.initWait();
    scheduler.pause_queue.push(&entry);

    lock.unlockAtomic();
    scheduler.rescheduleAtomic();
}

pub fn pauseUnlockIntr(lock: *lib.sync.Spinlock) void {
    std.debug.assert(lock.exclusion.raw != .unlocked);

    const scheduler = getCurrent();
    std.debug.assert(scheduler.isPreemptive() and !scheduler.getCpuLocal().isInInterrupt());

    var entry = scheduler.initWait();

    scheduler.disablePreemption();
    scheduler.pause_queue.push(&entry);

    lock.unlockRestoreIntr();
    scheduler.rescheduleAtomic();
}

pub inline fn wait(queue: *WaitQueue) void {
    const scheduler = getCurrent();
    std.debug.assert(scheduler.isPreemptive() and !scheduler.getCpuLocal().isInInterrupt());

    waitRaw(scheduler, queue);
}

pub fn waitUnlock(queue: *WaitQueue, lock: *lib.sync.Spinlock) void {
    std.debug.assert(lock.exclusion.raw == .locked_no_intr);

    const scheduler = getCurrent();
    std.debug.assert(!scheduler.getCpuLocal().isInInterrupt());

    var entry = scheduler.initWait();
    queue.push(&entry);
    lock.unlockAtomic();

    scheduler.rescheduleAtomic();
}

pub fn resumeTask(task: *Task) void {
    std.debug.assert(dev.intr.isEnabledForCpu());

    // TODO: Make sure this code is correct!
    const scheduler = getCurrent();
    const entry = scheduler.pause_queue.remove(task)
        orelse @panic("Trying to resume non-paused task");

    if (!task.tryWakeup()) {
        log.warn("cannot resume task", .{});
        return;
    }

    const sleep_time = sys.time.getFastTimestamp() - entry.timestamp;
    entry.task.stats.sleep_time +|= @truncate(sleep_time / sys.time.getNsPerTick());

    scheduler.enqueueTask(entry.task);
}

/// Awake one task from wait queue.
/// Returns awaked task or `null` if queue is empty.
pub fn awake(queue: *WaitQueue) ?*Task {
    std.debug.assert(dev.intr.isEnabledForCpu());

    const scheduler = getCurrent();
    const entry = queue.pop() orelse return null;

    const sleep_time = sys.time.getFastTimestamp() - entry.timestamp;
    entry.task.stats.sleep_time +|= @truncate(sleep_time / sys.time.getNsPerTick());

    scheduler.enqueueTask(entry.task);
}

/// Awake all tasks in wait queue.
pub fn awakeAll(queue: *WaitQueue) void {
    std.debug.assert(dev.intr.isEnabledForCpu());

    const scheduler = getCurrent();
    const timestamp = sys.time.getFastTimestamp();
    const ns_per_tick = sys.time.getNsPerTick();

    while (queue.pop()) |entry| {
        const sleep_time = (timestamp - entry.timestamp) / ns_per_tick;
        entry.task.stats.sleep_time +|= @truncate(sleep_time);

        scheduler.enqueueTask(entry.task);
    }
}

pub inline fn getTimeGranuleMs() u32 {
    return time_granule_ms;
}

fn waitRaw(scheduler: *Scheduler, queue: *WaitQueue) void {
    var entry = scheduler.initWait();

    scheduler.disablePreemption();
    queue.push(&entry);

    scheduler.rescheduleAtomic();
}