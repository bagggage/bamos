//! # Scheduler Interface

// Copyright (C) 2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const tasks = @import("tasks.zig");
const utils = @import("../utils.zig");
const vm = @import("../vm.zig");

const Self = @This();

const Flags = packed struct {
    need_resched: bool = false,
};

task_lock: utils.Spinlock = .init(.unlocked),

task_queue: tasks.List = .{},
exec_queue: tasks.List = .{},
wait_queue: tasks.List = .{},

current_task: *tasks.AnyTask = undefined,

flags: Flags = .{},

pub fn enqueueTask(self: *Self, task: *tasks.AnyTask) void {
    std.debug.assert(task.common.state == .free);

    task.common.state = .unscheduled;

    self.task_lock.lock();
    defer self.task_lock.unlock();

    self.task_queue.prepend(task.asNode());
}

pub fn dequeueTask(self: *Self,  task: *tasks.AnyTask) void {
    std.debug.assert(task.common.state != .free);

    const node = task.asNode();

    switch (task.common.state) {
        .unscheduled => {
            self.task_lock.lock();
            defer self.task_lock.unlock();

            self.task_queue.remove(node);
        },
        .scheduled => self.exec_queue.remove(node),
        .running => @panic("TODO: implement removing task from exec pool while running."),
        .free => unreachable,
    }

    task.common.state = .free;
}

pub fn schedule(self: *Self) void {
    std.debug.assert(self.exec_queue.first == null);

    while (self.task_queue.popFirst()) |node| {
        node.data.common.state = .scheduled;
        self.exec_queue.prepend(node);
    }
}

pub inline fn next(self: *Self) ?*tasks.AnyTask {
    const node = self.exec_queue.popFirst();

    if (node) |n| {
        n.data.common.state = .free;
        return &n.data;
    }

    return null;
}

pub inline fn planRescheduling(self: *Self) void {
    self.flags.need_resched = true;
}

pub inline fn needRescheduling(self: *const Self) bool {
    return self.flags.need_resched;
}
