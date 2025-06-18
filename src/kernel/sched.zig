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
pub const tasks = @import("sched/tasks.zig");
pub const thread = @import("sched/thread.zig");

pub const AnyTask = tasks.AnyTask;
pub const KernelTask = tasks.KernelTask;
pub const UserTask = tasks.UserTask;
pub const WaitQueue = tasks.WaitQueue;

pub const PrivilegeLevel = enum(u8) {
    userspace,
    kernel
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

pub fn startup(cpu_idx: u16, taskHandler: *const fn() noreturn) !void {
    const scheduler = getScheduler(cpu_idx);
    const task = newKernelTask("Startup", taskHandler) orelse return error.NoMemory;

    scheduler.init();
    scheduler.enqueueTask(task);

    if (cpu_idx == smp.getIdx()) scheduler.begin();
}

pub inline fn waitStartup() noreturn {
    getCurrent().begin();
}

pub fn newKernelTask(name: []const u8, handler: *const fn() noreturn) ?*AnyTask {
    const task = vm.obj.new(KernelTask) orelse return null;
    const stack_top = thread.initStack(&task.thread.stack, kernel_stack_size) orelse {
        vm.obj.free(KernelTask, task);
        return null;
    };

    task.common = .{};
    task.name = name;
    task.thread.context.init(
        stack_top,
        @intFromPtr(handler),
    );

    return @ptrCast(task);
}

pub fn freeTask(task: *AnyTask) void {
    std.debug.assert(task.common.state == .free);

    thread.deinitStack(
        &task.asKernelTask().thread.stack,
        kernel_stack_size
    );
    vm.obj.free(KernelTask, task.asKernelTask());
}

pub inline fn enqueue(task: *AnyTask) void {
    // TODO: CPU balancing.
    getCurrent().enqueueTask(task);
}

pub fn yeild() void {
    const scheduler = getCurrent();
    scheduler.disablePreemtion();

    scheduler.yeild();
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

pub fn resumeTask(task: *AnyTask) void {
    const scheduler = getCurrent();
    const entry = scheduler.pause_queue.remove(task)
        orelse @panic("trying to resume non-paused task");

    const sleep_time = sys.time.getFastTimestamp() - entry.timestamp;
    entry.task.common.sleep_time +|= @truncate(sleep_time / sys.time.getNsPerTick());

    scheduler.enqueueTask(entry.task);
}

/// Awake one task from wait queue.
/// Returns awaked task or `null` if queue is empty.
pub fn awake(queue: *WaitQueue) ?*AnyTask {
    const scheduler = getCurrent();
    const entry = queue.pop() orelse return null;

    const sleep_time = sys.time.getFastTimestamp() - entry.timestamp;
    entry.task.common.sleep_time +|= @truncate(sleep_time / sys.time.getNsPerTick());

    scheduler.enqueueTask(entry.task);
}

/// Awake all tasks in wait queue.
pub fn awakeAll(queue: *WaitQueue) void {
    const scheduler = getCurrent();
    const timestamp = sys.time.getFastTimestamp();
    const ns_per_tick = sys.time.getNsPerTick();

    while (queue.pop()) |entry| {
        const sleep_time = (timestamp - entry.timestamp) / ns_per_tick;
        entry.task.common.sleep_time +|= @truncate(sleep_time);

        scheduler.enqueueTask(entry.task);
    }
}

pub inline fn getTimeGranuleMs() u32 {
    return time_granule_ms;
}

fn waitEx(scheduler: *Scheduler, queue: *WaitQueue) void {
    scheduler.disablePreemtion();

    const task = scheduler.current_task;
    task.common.state = .waiting;

    var entry = WaitQueue.initEntry(
        task,
        sys.time.getFastTimestamp()
    );
    queue.push(&entry);
    scheduler.reschedule();
}