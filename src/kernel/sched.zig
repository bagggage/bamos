//! # Scheduling and Task Management Module

// Copyright (C) 2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const lib = @import("lib.zig");
const log = std.log.scoped(.sched);
const smp = @import("smp.zig");
const sys = @import("sys.zig");
const vm = @import("vm.zig");

const kernel_stack_size = 32 * lib.kb_size;

/// Scheduler timer target frequency.
pub const hz = 1000;
pub const min_slice_ticks = 3;
pub const max_slice_ticks = std.math.maxInt(Ticks);
/// Maximum priority (starting from 1).
pub const max_priority = 1 << @bitSizeOf(Priority);

/// Less is better.
pub const Priority = u5;
pub const Ticks = u4;

pub const Scheduler = @import("sched/Scheduler.zig");
pub const thread = @import("sched/thread.zig");

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
        return Entry.fromNode(node);
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

pub inline fn init() !void {
    sys.time.initPerCpu();
}

pub inline fn getScheduler(cpu_idx: u16) *Scheduler {
    return &smp.getCpuData(cpu_idx).scheduler;
}

pub inline fn getCurrent() *Scheduler {
    return &smp.getLocalData().scheduler;
}

pub inline fn getCurrentTask() *Task {
    return getCurrent().current_task;
}

pub fn startup(cpu_idx: u16, taskHandler: *const fn() noreturn) !void {
    const scheduler = getScheduler(cpu_idx);
    const task = newKernelTask("startup", taskHandler) orelse return error.NoMemory;

    scheduler.preinit();
    scheduler.current_task = task;

    scheduler.enqueueTask(task);

    if (cpu_idx == smp.getIdx()) scheduler.begin();
}

pub inline fn waitStartup() noreturn {
    getCurrent().begin();
}

pub fn newKernelTask(name: []const u8, handler: *const fn() noreturn) ?*Task {
    const task = vm.auto.alloc(Task) orelse return null;
    task.* = Task.init(
        .{ .kernel = .{ .name = name }},
        @intFromPtr(handler), kernel_stack_size
    ) catch {
        vm.auto.free(Task, task);
        return null;
    };

    return task;
}

pub fn freeTask(task: *Task) void {
    std.debug.assert(task.stats.state == .free);

    thread.deinitStack(
        &task.kernel_stack,
        kernel_stack_size
    );
    vm.auto.free(Task, task);
}

pub inline fn enqueue(task: *Task) void {
    // TODO: CPU balancing.
    getCurrent().enqueueTask(task);
}

/// Yield current task time.
pub fn yield() void {
    const scheduler = getCurrent();

    // Don't disable preemtion because task is pushed
    // into queue under spinlock, so preemtion would be disabled.
    // After lock release, task wouldn't be in `.running` state
    // so cannot be preempted.
    scheduler.yield();
    scheduler.reschedule();
}

pub inline fn pause() void {
    const scheduler = getCurrent();
    waitEx(scheduler, &scheduler.pause_queue);
}

pub inline fn wait(queue: *WaitQueue) void {
    const scheduler = getCurrent();
    waitEx(scheduler, queue);
}

pub fn waitUnlock(queue: *WaitQueue, lock: *lib.sync.Spinlock) void {
    const scheduler = getCurrent();
    var entry = scheduler.initWait();
    queue.push(&entry);
    lock.unlock();

    scheduler.doWait();
}

pub fn resumeTask(task: *Task) void {
    const scheduler = getCurrent();
    const entry = scheduler.pause_queue.remove(task)
        orelse @panic("trying to resume non-paused task");

    const sleep_time = sys.time.getFastTimestamp() - entry.timestamp;
    entry.task.stats.sleep_time +|= @truncate(sleep_time / sys.time.getNsPerTick());

    scheduler.enqueueTask(entry.task);
}

/// Awake one task from wait queue.
/// Returns awaked task or `null` if queue is empty.
pub fn awake(queue: *WaitQueue) ?*Task {
    const scheduler = getCurrent();
    const entry = queue.pop() orelse return null;

    const sleep_time = sys.time.getFastTimestamp() - entry.timestamp;
    entry.task.stats.sleep_time +|= @truncate(sleep_time / sys.time.getNsPerTick());

    scheduler.enqueueTask(entry.task);
}

/// Awake all tasks in wait queue.
pub fn awakeAll(queue: *WaitQueue) void {
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

fn waitEx(scheduler: *Scheduler, queue: *WaitQueue) void {
    var entry = scheduler.initWait();
    queue.push(&entry);
    scheduler.doWait();
}