//! # Scheduling and Task Management Module

// Copyright (C) 2025-2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const bindings = @import("bindings.zig");
const lib = @import("lib.zig");
const smp = @import("smp.zig");

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

pub const SleepQueue = struct {
    pub const QList = std.SinglyLinkedList;
    pub const QNode = QList.Node;

    pub const max_sleep_sec = std.math.maxInt(u64) / std.time.ns_per_s;

    pub const Entry = struct {
        wait_entry: WaitQueue.Entry,
        /// Number of nanosecond that task wants to sleep
        /// relative to a previouse task in the queue
        delta_ns: u64 = 0,

        pub inline fn fromNode(node: *QNode) *Entry {
            comptime std.debug.assert(QNode == SleepQueue.QNode);

            const wait_entry = WaitQueue.Entry.fromNode(node);
            return @fieldParentPtr("wait_entry", wait_entry);
        }
    };

    list: QList = .{},

    pub inline fn push(self: *SleepQueue, new_entry: *Entry) void {
        bindings.getInstance().sched.sleep_queue.push(self, new_entry);
    }

    pub inline fn removeWeak(self: *SleepQueue, entry: *Entry) void {
        bindings.getInstance().sched.sleep_queue.removeWeak(self, entry);
    }

    /// Returns the list of entries to be woken up
    pub inline fn process(self: *SleepQueue, elapsed_ns: usize) ?*Entry {
        return bindings.getInstance().sched.sleep_queue.process(self, elapsed_ns);
    }
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

        pub inline fn fromNode(node: *QNode) *Entry {
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
};

pub inline fn isInitialized() bool {
    return bindings.getInstance().sched.isInitialized();
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

pub inline fn rebornAsKernelTask(task: *Task, name: []const u8) void {
    bindings.getInstance().sched.rebornAsKernelTask(task, name);
}

pub inline fn enqueue(task: *Task) void {
    bindings.getInstance().sched.enqueue(task);
}

/// Yield current task time.
pub inline fn yield() void {
    const scheduler = getCurrent();
    std.debug.assert(!scheduler.getCpuLocal().isInInterrupt());

    scheduler.yield();
}

pub inline fn sleepFor(ns: u64) void {
    const scheduler = getCurrent();
    scheduler.sleepFor(ns);
}

pub inline fn terminate() noreturn {
    bindings.getInstance().sched.terminate();
}

pub inline fn pause() void {
    bindings.getInstance().sched.pause();
}

pub inline fn pauseUnlock(lock: *lib.sync.Spinlock) void {
    bindings.getInstance().sched.pauseUnlock(lock);
}

pub fn pauseUnlockIntr(lock: *lib.sync.Spinlock) void {
    bindings.getInstance().sched.pauseUnlockIntr(lock);
}

pub inline fn wait(queue: *WaitQueue) void {
    bindings.getInstance().sched.wait(queue);
}

pub inline fn waitUnlock(queue: *WaitQueue, lock: *lib.sync.Spinlock) void {
    bindings.getInstance().sched.waitUnlock(queue, lock);
}

pub inline fn waitUnlockIntr(queue: *WaitQueue, lock: *lib.sync.Spinlock) void {
    bindings.getInstance().sched.waitUnlockIntr(queue, lock);
}

pub inline fn waitEnableIntr(queue: *WaitQueue) void {
    bindings.getInstance().sched.waitEnableIntr(queue);
}

pub inline fn resumeTask(task: *Task) void {
    bindings.getInstance().sched.resumeTask(task);
}

/// Awake one task from wait queue.
/// Returns awaked task or `null` if queue is empty.
pub inline fn awake(queue: *WaitQueue) ?*Task {
    return bindings.getInstance().sched.awake(queue);
}

pub inline fn awakeEntry(entry: *WaitQueue.Entry) bool {
    return bindings.getInstance().sched.awakeEntry(entry);
}

/// Awake all tasks in wait queue.
pub inline fn awakeAll(queue: *WaitQueue) void {
    return bindings.getInstance().sched.awakeAll(queue);
}

pub inline fn getTimeGranuleMs() u32 {
    return bindings.getInstance().sched.getTimeGranuleMs();
}
