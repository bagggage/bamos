//! # Scheduling and Task Management Module

// Copyright (C) 2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const log = std.log.scoped(.sched);
const smp = @import("smp.zig");
const sys = @import("sys.zig");
const utils = @import("utils.zig");
const vm = @import("vm.zig");

const kernel_stack_size = 32 * utils.kb_size;

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
    const Entry = struct {
        task: *Task,
        /// Timestamp of start of wait in nanoseconds.
        timestamp: u64 = 0,
    };

    const QList = utils.SList(Entry);
    pub const QNode = QList.Node;

    list: QList = .{},

    pub inline fn push(self: *WaitQueue, node: *QNode) void {
        self.list.prepend(node);
    }

    pub inline fn pop(self: *WaitQueue) ?*Entry {
        const node = self.list.popFirst() orelse return null;
        return &node.data;
    }

    pub fn remove(self: *WaitQueue, task: *Task) ?*Entry {
        var prev: ?*QNode = null;
        var node = self.list.first;
        while (node) |n| : ({ prev = n; node = n.next; }) {
            if (n.data.task == task) {
                if (prev) |p| {
                    _ = p.removeNext();
                } else {
                    self.list.first = n.next;
                }

                return &n.data;
            }
        }

        return null;
    }

    pub inline fn initEntry(task: *Task, timestamp: u64) QNode {
        return .{
            .data = .{
                .task = task,
                .timestamp = timestamp
            }  
        };
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

    scheduler.init();
    scheduler.current_task = task;

    scheduler.enqueueTask(task);

    if (cpu_idx == smp.getIdx()) scheduler.begin();
}

pub inline fn waitStartup() noreturn {
    getCurrent().begin();
}

pub fn newKernelTask(name: []const u8, handler: *const fn() noreturn) ?*Task {
    const task = vm.obj.new(Task) orelse return null;
    const stack_top = thread.initStack(&task.kernel_stack, kernel_stack_size) orelse {
        vm.obj.free(Task, task);
        return null;
    };

    task.stats = .{};
    task.spec = .{ .kernel = .{ .name = name } };
    task.context.init(
        stack_top,
        @intFromPtr(handler),
    );

    return @ptrCast(task);
}

pub fn freeTask(task: *Task) void {
    std.debug.assert(task.stats.state == .free);

    thread.deinitStack(
        &task.kernel_stack,
        kernel_stack_size
    );
    vm.obj.free(Task, task);
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