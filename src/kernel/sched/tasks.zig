//! # Task Structure

// Copyright (C) 2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const Process = @import("../sys/Process.zig");
const thread = @import("thread.zig");
const utils = @import("../utils.zig");
const vm = @import("../vm.zig");

const UserThread = thread.UserThread;
const KernelThread = thread.KernelThread;

const VTable = struct {
    onContinue: *const fn(self: *anyopaque) void = &stub,
    onYeild: *const fn(self: *anyopaque) void = &stub,

    fn stub(_: *anyopaque) void {}
};

const stub_vtable: VTable = .{};

const State = enum(u8) {
    free,
    unscheduled,
    scheduled,
    running,
    waiting,
};

const Common = struct {
    vtable: *const VTable = &stub_vtable,
    state: State = .free,
};

pub const List = utils.SList(AnyTask);
pub const Node = List.Node;

pub const AnyTask = struct {
    common: Common,

    pub inline fn asNode(self: *AnyTask) *Node {
        return @fieldParentPtr("data", self);
    }

    pub inline fn asUserTask(self: *AnyTask) *UserTask {
        return @ptrCast(self);
    }

    pub inline fn asKernelTask(self: *AnyTask) *KernelTask {
        return @ptrCast(self);
    } 
};

pub const UserTask = struct {
    pub const alloc_config = vm.obj.AllocatorConfig{
        .allocator = .safe_oma,
        .wrapper = .single_list_node,
        .capacity = 256
    };

    common: Common = .{},

    thread: UserThread,
    process: *Process,
};

pub const KernelTask = struct {
    pub const alloc_config = vm.obj.AllocatorConfig{
        .allocator = .safe_oma,
        .wrapper = .single_list_node,
        .capacity = 16
    };

    common: Common = .{},

    thread: KernelThread,
    name: []const u8,
};


