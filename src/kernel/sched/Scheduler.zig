//! # Scheduler Interface

// Copyright (C) 2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const smp = @import("../smp.zig");
const sched = @import("../sched.zig");
const tasks = @import("tasks.zig");
const utils = @import("../utils.zig");
const vm = @import("../vm.zig");

const Self = @This();

const Flags = packed struct {
    need_resched: bool = false,
    expire: bool = false,
    preemtion: bool = false,
};

const TaskQueue = struct {
    const len = sched.max_priority;

    lists: [len]tasks.List = .{ tasks.List{} } ** len,
    last_min: u8 = 0,

    pub fn push(self: *TaskQueue, task: *tasks.AnyTask) void {
        const priority = task.common.getPriority();
        if (priority < self.last_min) self.last_min = priority;

        self.lists[priority].prepend(task.asNode());
    }

    pub fn pop(self: *TaskQueue) ?*tasks.AnyTask {
        for (self.lists[self.last_min..len]) |*list| {
            if (list.popFirst()) |node| return &node.data;

            self.last_min += 1;
        }

        return null;
    }

    pub fn remove(self: *TaskQueue, task: *tasks.AnyTask) void {
        const priority = task.common.getPriority();
        self.lists[priority].remove(task.asNode());
    }
};

task_lock: utils.Spinlock = .init(.unlocked),
task_queues: [2]TaskQueue = .{ TaskQueue{} } ** 2,

active_queue: *TaskQueue = undefined,
expired_queue: *TaskQueue = undefined,

current_task: *tasks.AnyTask = undefined,

flags: Flags = .{},

pub fn init(self: *Self) void {
    self.active_queue = &self.task_queues[0];
    self.expired_queue = &self.task_queues[1];
}

pub fn enqueueTask(self: *Self, task: *tasks.AnyTask) void {
    std.debug.assert(task.common.state == .free);

    task.common.updateBonus();
    task.common.updateTimeSlice();

    self.task_lock.lock();
    defer self.task_lock.unlock();

    self.active_queue.push(task);
    task.common.state = .scheduled;

    self.tryPreemt(task);
}

pub fn dequeueTask(self: *Self,  task: *tasks.AnyTask) void {
    std.debug.assert(task.common.state == .scheduled);

    self.task_lock.lock();
    defer self.task_lock.unlock();

    self.active_queue.remove(task);
    task.common.state = .free;
}

pub inline fn expire(self: *Self) void {
    self.current_task.common.expireTime();
    self.expired_queue.push(self.current_task);

    self.current_task.common.state = .scheduled;
    self.flags.expire = false;
}

pub inline fn schedule(self: *Self) void {
    const temp_queue = self.active_queue;
    self.active_queue = self.expired_queue;
    self.expired_queue = temp_queue;
}

pub inline fn tryPreemt(self: *Self, task: *const tasks.AnyTask) void {
    if (
        self.flags.preemtion and
        self.current_task.common.getPriority() > task.common.getPriority()
    ) {
        self.planRescheduling();
    }
}

pub inline fn next(self: *Self) ?*tasks.AnyTask {
    return self.active_queue.pop();
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

pub inline fn enablePreemtion(self: *Self) void {
    self.flags.preemtion = true;
}

pub inline fn disablePreemtion(self: *Self) void {
    self.flags.preemtion = false;
}
