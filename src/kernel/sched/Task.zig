//! # Task Structure

// Copyright (C) 2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const arch = utils.arch;
const thread = @import("thread.zig");
const sched = @import("../sched.zig");
const sys = @import("../sys.zig");
const utils = @import("../utils.zig");
const vm = @import("../vm.zig");

pub const Self = @This();

pub const List = utils.List;
pub const Node = List.Node;

pub const State = enum(u8) {
    /// Task is not in any linked list.
    free,
    /// Task is in use but not ready for execution.
    unscheduled,
    /// Task is ready for execution and stored in
    /// scheduler's linked list.
    scheduled,
    /// Task is currently running or switching.
    running,
    /// Task is stored in wait queue and waiting for awake.
    waiting,
};

const Priority = sched.Priority;
const PriorDelta: type = std.meta.Int(
    .signed,
    @bitSizeOf(Priority) - 1
);
const Ticks = sched.Ticks;

const max_prior_delta = std.math.maxInt(PriorDelta) + 1;
const base_priority = sched.max_priority / 2;

/// Highest static priority value.
pub const high_static_prior = std.math.minInt(PriorDelta);
/// Lower static priority value.
pub const low_static_prior = std.math.maxInt(PriorDelta);

/// Struct contains all data used to calculate task's
/// dynamic priority, time slice and provide execution stats
/// like CPU time or sleep time.
pub const Stats = struct {
    /// Number of scheduler ticks allocated to task.
    time_slice: sched.Ticks = 0,
    state: State = .free,

    static_prior: PriorDelta = 0,
    bonus_prior: PriorDelta = 0,

    cpu_time: u16 = 0,
    sleep_time: u16 = 0,

    comptime {
        const max_val = (std.math.maxInt(PriorDelta) * 2) + base_priority;
        const min_val = (std.math.minInt(PriorDelta) * 2) + base_priority;

        std.debug.assert(max_val < sched.max_priority);
        std.debug.assert(min_val >= 0);
    }

    /// Returns task priotiry in range 0-31. Less is better.
    pub inline fn getPriority(self: *const Stats) sched.Priority {
        @setRuntimeSafety(false);
        const result: i8 = @as(i8, base_priority) +% self.static_prior +% self.bonus_prior;
        return @truncate(@as(u8, @bitCast(result)));
    }

    /// Calculate and set time slice for the task.
    pub inline fn updateTimeSlice(self: *Stats) void {
        std.debug.assert(self.state != .running);
        self.time_slice = self.calcTimeSlice();
    }

    /// Update priority bonus based on task interactivity.
    pub fn updateBonus(self: *Stats) void {
        const max_inter: comptime_int = utils.fp_scale;
        const base_inter: comptime_int = (max_inter - 1) / 2;
        const max_bonus: comptime_int = (std.math.maxInt(Priority) + 1) / 2;
        const norm_mul: comptime_int = (max_inter * utils.fp_scale) / max_bonus;

        const interactivity: i32 = self.getInteractivity();
        const bonus = @divFloor(-interactivity * norm_mul, utils.fp_scale);
        self.bonus_prior = @truncate(bonus + base_inter);
    }

    pub fn yieldTime(self: *Stats) void {
        self.sleep_time +|= self.time_slice;
        self.updateBonus();
    }

    fn getInteractivity(self: *const Stats) u8 {
        @setRuntimeSafety(false);
        const time = @as(u32, self.cpu_time) + self.sleep_time;
        if (time == 0) return 0;

        const result = (@as(u32, self.sleep_time + 1) * utils.fp_scale) / time;
        return @truncate(result);
    }

    /// Caclulate time slice for the task and return it.
    fn calcTimeSlice(self: *const Stats) Ticks {
        const max_bonus: comptime_int = comptime calcTimeBonus(sched.max_priority);
        const norm_mult: comptime_int = ((sched.max_slice_ticks + 1) * utils.fp_scale) / max_bonus;

        const reverse_prior: u32 = @as(u32, sched.max_priority) - self.getPriority();
        const bonus: u32 = calcTimeBonus(reverse_prior);
        const norm_bonus: Ticks = @truncate((bonus * norm_mult) / utils.fp_scale);

        return if (norm_bonus < sched.min_slice_ticks)
            sched.min_slice_ticks else norm_bonus;
    }

    inline fn calcTimeBonus(reverse_prior: u32) u32 {
        return std.math.log2(reverse_prior * reverse_prior);
    }
};

/// Kernel task specific data.
pub const KernelSpecific = struct {
    name: []const u8
};

/// User task specific data.
pub const UserSpecific = struct {
    pub const UList = utils.SList;
    pub const UNode = UList.Node;

    process: *sys.Process,
    user_stack: *sys.AddressSpace.MapUnit,

    /// Used by `sys.Process` to put task in list.
    node: UNode = .{},
};

pub const Specific = union {
    kernel: KernelSpecific,
    user: UserSpecific,
};

pub const alloc_config: vm.auto.Config = .{
    .allocator = .safe_oma,
    .capacity = 128,
};

stats: Stats = .{},
/// Arch-specific context used for context switching.
context: arch.Context,
node: Node = .{},

/// Kernel stack is not appear as
/// map unit and hidden from userspace,
/// so it handles different via `vm.VirtualRegion`.
kernel_stack: vm.VirtualRegion,

/// Specific data which is different for
/// kernel and user tasks.
spec: Specific,

pub fn init(spec: Specific, ip: usize, stack_size: usize) !Self {
    const stack = thread.makeStack(stack_size) orelse return error.NoMemory;
    return .{
        .spec = spec,
        .kernel_stack = stack,
        .context = .init(stack.getTopAligned(thread.stack_alignment), ip),
    };
}

pub inline fn fromNode(node: *Node) *Self {
    return @fieldParentPtr("node", node);
}
