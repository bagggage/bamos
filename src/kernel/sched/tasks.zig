//! # Task Structure

// Copyright (C) 2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const Process = @import("../sys/Process.zig");
const thread = @import("thread.zig");
const sched = @import("../sched.zig");
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

const Priority = sched.Priority;
const Ticks = sched.Ticks;
const PriorDelta: type = std.meta.Int(.signed, @bitSizeOf(Priority) - 1);

const max_prior_delta = std.math.maxInt(PriorDelta) + 1;
const base_priority = sched.max_priority / 2;
const base_interactivity = std.math.maxInt(u8) / 2;

pub const Common = struct {
    vtable: *const VTable = &stub_vtable,

    /// Number of scheduler ticks allocated to task.
    time_slice: sched.Ticks = 0,
    state: State = .free,

    static_prior: PriorDelta = 0,
    bonus_prior: PriorDelta = 0,

    interactivity: u8 = base_interactivity,
    inter_delta: i8 = 0,

    comptime {
        const max_val = (std.math.maxInt(PriorDelta) * 2) + base_priority;
        const min_val = (std.math.minInt(PriorDelta) * 2) + base_priority;

        std.debug.assert(max_val < sched.max_priority);
        std.debug.assert(min_val >= 0);
    }

    /// Returns task priotiry in range 0-31. Less is better.
    pub inline fn getPriority(self: *const Common) sched.Priority {
        @setRuntimeSafety(false);
        return
            @as(sched.Priority, base_priority) +%
            self.static_prior +%
            self.bonus_prior;
    }

    pub fn expireTime(self: *Common) void {
        std.debug.assert(self.time_slice == 0);

        const given_time: i32 = self.calcTimeSlice();
        const punish = (given_time + self.inter_delta) / 2;

        self.updateInteractivity(-punish);
        self.updateTimeSlice();
    }

    pub inline fn updateTimeSlice(self: *Common) void {
        self.time_slice = self.calcTimeSlice();
    }

    pub fn updateInteractivity(self: *Common, bonus: i8) void {
        const delta = bonus - self.inter_delta;
        if (delta == 0) return;

        self.inter_delta = self.inter_delta +| if (delta > 0) 1 else -1;
        self.interactivity = self.interactivity +| delta;

        self.updateBonus();
    }

    pub fn updateBonus(self: *Common) void {
        const delta =
            (@as(i16, base_interactivity) - self.interactivity) /
            ((base_interactivity + 1) / max_prior_delta);
        self.bonus_prior = @truncate(delta);
    }

    fn calcTimeSlice(self: *const Common) Ticks {
        const percision = 16;
        const max_bonus: comptime_int = std.math.log2_int(comptime_int, sched.max_priority * 8);
        const norm_mult: comptime_int = ((sched.max_slice_ticks + 1) * percision) / max_bonus;

        const reverse_prior: u32 = sched.max_priority - self.getPriority();
        const bonus: u32 = std.math.log2_int(u32, reverse_prior * 8);
        const norm_bonus = (bonus * norm_mult) / percision;

        return if (norm_bonus < sched.min_slice_ticks)
            sched.min_slice_ticks else norm_bonus;
    }
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


