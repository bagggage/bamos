//! # Scheduling and Task Management Module

// Copyright (C) 2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const smp = @import("smp.zig");
const log = std.log.scoped(.sched);
const vm = @import("vm.zig");
const utils = @import("utils.zig");

const kernel_stack_size = 32 * utils.kb_size;

pub const Scheduler = @import("sched/Scheduler.zig");
pub const executor = @import("sched/executor.zig");
pub const tasks = @import("sched/tasks.zig");
pub const thread = @import("sched/thread.zig");

pub const AnyTask = tasks.AnyTask;
pub const KernelTask = tasks.KernelTask;
pub const UserTask = tasks.UserTask;

pub const PrivilegeLevel = enum(u8) {
    userspace,
    kernel
};

pub inline fn getScheduler(cpu_idx: u16) *Scheduler {
    return &smp.getCpuData(cpu_idx).scheduler;
}

pub inline fn getCurrent() *Scheduler {
    return &smp.getLocalData().scheduler;
}

pub fn startup(cpu_idx: u16, taskHandler: *const fn() noreturn) !void {
    const scheduler = getScheduler(cpu_idx);
    const task = newKernelTask("Startup", taskHandler) orelse return error.NoMemory;

    scheduler.enqueueTask(task);

    if (cpu_idx == smp.getIdx()) executor.begin();
}

pub fn waitStartup() noreturn {
    executor.begin();
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
        .kernel
    );

    return @ptrCast(task);
}