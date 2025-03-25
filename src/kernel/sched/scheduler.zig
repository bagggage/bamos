//! # Scheduler Interface

// Copyright (C) 2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const smp = @import("../smp.zig");
const tasks = @import("tasks.zig");
const vm = @import("../vm.zig");

const CpuLocal = struct {
    task_queue: tasks.List = .{},
    exec_queue: tasks.List = .{},
    wait_queue: tasks.List = .{}
};

var local_pool: []CpuLocal = &.{};

pub fn init() !void {
    const pool_size = smp.getNum() * @sizeOf(CpuLocal);

    local_pool.ptr = @alignCast(@ptrCast(vm.malloc(pool_size) orelse return error.NoMemory));
    local_pool.len = smp.getNum();

    @memset(local_pool, .{});
}

pub fn enqueueTask(task: *tasks.AnyTask) void {
    std.debug.assert(task.common.state == .free);

    const local: *CpuLocal = getLocal();

    task.common.state = .unscheduled;
    local.task_queue.prepend(task.asNode());
}

pub fn dequeueTask(task: *tasks.AnyTask) void {
    std.debug.assert(task.common.state != .free);

    const local: *CpuLocal = getLocal();
    const node = task.asNode();

    switch (task.common.state) {
        .unscheduled => local.task_queue.remove(node),
        .scheduled => local.exec_queue.remove(node),
        .running => @panic("TODO: implement removing task from exec pool while running."),
        .free => unreachable,
    }

    task.common.state = .free;
}

pub fn schedule() void {
    const local: *CpuLocal = getLocal();

    std.debug.assert(local.exec_queue.first == null);

    while (local.task_queue.popFirst()) |node| {
        node.data.common.state = .scheduled;
        local.exec_queue.prepend(node);
    }
}

pub inline fn next() ?*tasks.AnyTask {
    const local: *CpuLocal = getLocal();
    const node = local.exec_queue.popFirst();

    if (node) |n| {
        n.data.common.state = .free;
        return &n.data;
    }

    return null;
}

inline fn getLocal() *CpuLocal {
    return &local_pool[smp.getIdx()];
}
