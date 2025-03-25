//! # Scheduling and Task Management Module

// Copyright (C) 2025 Konstantin Pigulevskiy (bagggage@github)

const vm = @import("vm.zig");
const utils = @import("utils.zig");

const kernel_stack_size = 32 * utils.kb_size;

pub const scheduler = @import("sched/scheduler.zig");
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

pub fn newKernelTask(name: []const u8, handler: *const fn() noreturn) ?*AnyTask {
    const task = vm.obj.new(KernelTask) orelse return null;
    const stack_top = thread.initStack(&task.thread.stack, kernel_stack_size) orelse {
        vm.obj.free(KernelTask, task);
        return null;
    };

    task.name = name;
    task.thread.context.init(
        stack_top,
        @intFromPtr(handler),
        .kernel
    );

    return @ptrCast(task);
}