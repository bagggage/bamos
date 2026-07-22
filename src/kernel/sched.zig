//! # Scheduling and Task Management Module

// Copyright (C) 2025-2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const dev = @import("dev.zig");
const lib = @import("lib.zig");
const log = std.log.scoped(.sched);
const smp = @import("smp.zig");
const sys = @import("sys.zig");
const vm = @import("vm.zig");

pub const min_slice_ticks = 3;
pub const max_slice_ticks = std.math.maxInt(Ticks);
/// Maximum priority (starting from 1).
pub const max_priority = 1 << @bitSizeOf(Priority);

pub const no_deadline = std.math.maxInt(u64);

/// Less is better.
pub const Priority = u5;
pub const PriorityDelta = i4;
pub const Ticks = u4;

pub const Scheduler = @import("sched/Scheduler.zig");
pub const Task = @import("sched/Task.zig");

pub const PrivilegeLevel = enum(u8) { userspace, kernel };

pub const SleepQueue = struct {
    pub const QList = std.SinglyLinkedList;
    pub const QNode = QList.Node;

    pub const max_sleep_sec = std.math.maxInt(u64) / std.time.ns_per_s;

    pub const Entry = struct {
        wait_entry: WaitQueue.Entry,
        deadline_ns: u64 = 0,

        pub inline fn fromNode(node: *QNode) *Entry {
            comptime std.debug.assert(QNode == SleepQueue.QNode);

            const wait_entry = WaitQueue.Entry.fromNode(node);
            return @fieldParentPtr("wait_entry", wait_entry);
        }
    };

    list: QList = .{},

    pub fn push(self: *SleepQueue, new_entry: *Entry) void {
        var prev: ?*QNode = null;
        var node: ?*QNode = self.list.first;

        while (node) |n| : ({
            prev = n;
            node = n.next;
        }) {
            const entry = Entry.fromNode(n);
            if (entry.deadline_ns <= new_entry.deadline_ns) {
                if (n.next != null) continue;
                n.next = &new_entry.wait_entry.node;
            } else {
                const p = prev orelse break;
                p.insertAfter(&new_entry.wait_entry.node);
            }

            return;
        }

        self.list.prepend(&new_entry.wait_entry.node);
    }

    pub fn removeWeak(self: *SleepQueue, entry: *Entry) void {
        const head = self.list.first orelse return;
        const node = &entry.wait_entry.node;

        if (self.list.first == node) {
            self.list.first = node.next;
            return;
        }

        var prev = head;
        while (prev.next) |n| : (prev = n) {
            if (node != n) {
                prev.next = node.next;
                break;
            }
        }
    }

    /// Returns the list of entries to be woken up
    pub fn process(self: *SleepQueue, time_ns: usize) ?*Entry {
        const head = self.list.first orelse return null;

        var prev: ?*QNode = null;
        var node: ?*QNode = head;
        while (node) |n| : ({
            prev = n;
            node = n.next;
        }) {
            const entry = Entry.fromNode(n);
            if (entry.deadline_ns > time_ns) {
                self.list.first = n;

                const p = prev orelse return null;
                p.next = null;

                return Entry.fromNode(head);
            }

            entry.deadline_ns = 0;
        }

        self.list.first = null;
        return Entry.fromNode(head);
    }

    pub fn getEarliestDeadline(self: *SleepQueue) u64 {
        return if (self.list.first) |n| blk: {
            const entry = Entry.fromNode(n);
            break :blk entry.deadline_ns;
        } else no_deadline;
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
            return .{ .task = task, .timestamp = timestamp };
        }

        inline fn updateSleepTime(self: *Entry) void {
            const sleep_time_ns = sys.time.getFastTimestamp() -| self.timestamp;
            self.task.stats.sleep_time_ns +|= @truncate(sleep_time_ns);
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

pub fn startup(cpu_idx: u16, taskHandler: *const fn () noreturn) !void {
    const scheduler = getScheduler(cpu_idx);
    const task = try Task.create(.{ .kernel = .{ .name = "startup" } }, @intFromPtr(taskHandler));

    scheduler.enqueueTask(task);
    initialized = true;

    if (cpu_idx == smp.getIdx()) scheduler.start();
}

pub fn rebornAsKernelTask(task: *Task, name: []const u8) void {
    std.debug.assert(task.spec == .user);

    const scheduler = getCurrent();
    if (scheduler.current_task == task) {
        scheduler.disablePreemption();
        defer scheduler.enablePreemption();

        task.spec = .{ .kernel = .{ .name = name } };
        vm.setPageTable(vm.getRootPt());
    } else {
        task.spec = .{ .kernel = .{ .name = name } };
    }
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

pub inline fn sleepFor(ns: u64) void {
    const scheduler = getCurrent();
    scheduler.sleepFor(ns);
}

pub fn terminate() noreturn {
    const scheduler = getCurrent();
    const task = scheduler.current_task.?;
    lib.debug.assert(scheduler.isPreemptive() and !scheduler.getCpuLocal().isInInterrupt(), @src());

    if (task.spec == .user) @panic("User task is trying to terminate! Stop user thread before terminiation.");
    if (!task.stats.sched_lock.tryLock()) unreachable;

    scheduler.flags.terminate = true;
    scheduler.rescheduleAtomic();

    unreachable;
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
    lock.unlock();

    scheduler.prepareToSleep();
    scheduler.reschedule();
}

pub fn pauseUnlockIntr(lock: *lib.sync.Spinlock) void {
    std.debug.assert(lock.exclusion.raw != .unlocked);

    const scheduler = getCurrent();
    std.debug.assert(scheduler.isPreemptive() and !scheduler.getCpuLocal().isInInterrupt());

    var entry = scheduler.initWait();

    scheduler.prepareToSleep();
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
    lock.unlock();

    scheduler.prepareToSleep();
    scheduler.reschedule();
}

pub fn waitUnlockIntr(queue: *WaitQueue, lock: *lib.sync.Spinlock) void {
    const scheduler = getCurrent();
    std.debug.assert(!scheduler.getCpuLocal().isInInterrupt());

    var entry = scheduler.initWait();
    queue.push(&entry);
    lock.unlockRestoreIntr();

    scheduler.prepareToSleep();
    scheduler.reschedule();
}

pub fn waitEnableIntr(queue: *WaitQueue) void {
    const scheduler = getCurrent();
    std.debug.assert(!scheduler.getCpuLocal().isInInterrupt());

    var entry = scheduler.initWait();
    queue.push(&entry);
    dev.intr.enableForCpu();

    scheduler.prepareToSleep();
    scheduler.reschedule();
}

pub fn resumeTask(task: *Task) void {
    std.debug.assert(dev.intr.isEnabledForCpu());

    // TODO: Make sure this code is correct!
    const scheduler = getCurrent();
    const entry = scheduler.pause_queue.remove(task) orelse @panic("Trying to resume non-paused task");

    if (!task.tryWakeup()) {
        log.warn("cannot resume task", .{});
        return;
    }

    const sleep_time_ns = sys.time.getFastTimestamp() - entry.timestamp;
    entry.task.stats.sleep_time_ns +|= @truncate(sleep_time_ns);

    scheduler.enqueueTask(entry.task);
}

/// Awake one task from wait queue.
/// Returns awaked task or `null` if queue is empty.
pub fn awake(queue: *WaitQueue) ?*Task {
    std.debug.assert(dev.intr.isEnabledForCpu());

    const entry = queue.pop() orelse return null;
    const scheduler = getCurrent();

    entry.updateSleepTime();

    entry.task.stats.sched_lock.wait(.unlocked);
    scheduler.enqueueTask(entry.task);

    return entry.task;
}

pub fn awakeEntry(entry: *WaitQueue.Entry) bool {
    std.debug.assert(dev.intr.isEnabledForCpu());

    if (!entry.task.tryWakeup()) return false;
    entry.updateSleepTime();

    const scheduler = getCurrent();

    entry.task.stats.sched_lock.wait(.unlocked);
    scheduler.enqueueTask(entry.task);

    return true;
}

/// Awake all tasks in wait queue.
pub fn awakeAll(queue: *WaitQueue) void {
    std.debug.assert(dev.intr.isEnabledForCpu());

    const scheduler = getCurrent();
    const timestamp = sys.time.getTimestamp();

    while (queue.pop()) |entry| {
        const sleep_time_ns = timestamp -| entry.timestamp;
        entry.task.stats.sleep_time_ns +|= @truncate(sleep_time_ns);

        entry.task.stats.sched_lock.wait(.unlocked);
        scheduler.enqueueTask(entry.task);
    }
}

fn waitRaw(scheduler: *Scheduler, queue: *WaitQueue) void {
    var entry = scheduler.initWait();

    scheduler.prepareToSleep();
    scheduler.disablePreemption();
    queue.push(&entry);

    scheduler.rescheduleAtomic();
}
