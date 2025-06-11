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

/// Highest static priority value.
pub const high_static_prior = std.math.minInt(PriorDelta);
/// Lower static priority value.
pub const low_static_prior = std.math.maxInt(PriorDelta);

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
        const result: i8 = @as(i8, base_priority) +% self.static_prior +% self.bonus_prior;
        return @truncate(@as(u8, @bitCast(result)));
    }

    /// Apply interactivity punish and calculate new time slice.
    pub fn expireTime(self: *Common) void {
        std.debug.assert(self.time_slice == 0);

        const given_time: i8 = self.calcTimeSlice();
        const punish = @divTrunc(given_time + self.inter_delta, 2);

        self.updateInteractivity(-punish);
        self.updateTimeSlice();
    }

    pub fn yeildBonus(self: *Common) void {
        std.debug.assert(self.time_slice > 0);

        self.updateInteractivity(
            @intCast(sched.executor.getTickGranule() * self.time_slice)
        );
    }

    /// Calculate and set time slice for the task.
    pub inline fn updateTimeSlice(self: *Common) void {
        self.time_slice = self.calcTimeSlice();
    }

    /// Apply interativity bonus to the task and update
    /// priority bonus.
    pub fn updateInteractivity(self: *Common, bonus: i8) void {
        @setRuntimeSafety(false);

        const delta = bonus - self.inter_delta;
        if (delta == 0) return;

        if (delta > 0) { self.inter_delta +|= 1; }
        else { self.inter_delta -|= 1; }

        const new_inter: i32 = @as(i32, self.interactivity) +% delta;

        self.interactivity = @intCast(std.math.clamp(new_inter, 0, 255));
        self.updateBonus();
    }

    /// Update priority bonus based on task interactivity.
    pub fn updateBonus(self: *Common) void {
        const divisor = (base_interactivity + 1) / max_prior_delta;
        const delta = @divTrunc(@as(i16, base_interactivity) - self.interactivity, divisor);
        self.bonus_prior = @truncate(delta);
    }

    /// Caclulate time slice for the task and return it.
    fn calcTimeSlice(self: *const Common) Ticks {
        const percision = 16;
        const max_bonus: comptime_int = std.math.log2(sched.max_priority * 8);
        const norm_mult: comptime_int = ((sched.max_slice_ticks + 1) * percision) / max_bonus;

        const reverse_prior: u32 = @as(u32, sched.max_priority) - self.getPriority();
        const bonus: u32 = std.math.log2_int(u32, reverse_prior * 8);
        const norm_bonus: Ticks = @truncate((bonus * norm_mult) / percision);

        return if (norm_bonus < sched.min_slice_ticks)
            sched.min_slice_ticks else norm_bonus;
    }
};

pub const List = utils.List(AnyTask);
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


