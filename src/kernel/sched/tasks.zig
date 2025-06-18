//! # Task Structure

// Copyright (C) 2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const Process = @import("../sys/Process.zig");
const thread = @import("thread.zig");
const sched = @import("../sched.zig");
const sys = @import("../sys.zig");
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

    cpu_time: u16 = 0,
    sleep_time: u16 = 0,

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

    /// Calculate and set time slice for the task.
    pub inline fn updateTimeSlice(self: *Common) void {
        self.time_slice = self.calcTimeSlice();
    }

    /// Update priority bonus based on task interactivity.
    pub fn updateBonus(self: *Common) void {
        const max_inter: comptime_int = utils.fp_scale;
        const base_inter: comptime_int = (max_inter - 1) / 2;
        const max_bonus: comptime_int = (std.math.maxInt(Priority) + 1) / 2;
        const norm_mul: comptime_int = (max_inter * utils.fp_scale) / max_bonus;

        const interactivity: i32 = self.getInteractivity();
        const bonus = @divFloor(-interactivity * norm_mul, utils.fp_scale);
        self.bonus_prior = @truncate(bonus + base_inter);
    }

    pub fn yeildTime(self: *Common) void {
        self.sleep_time +|= self.time_slice;

        self.updateBonus();
        self.updateTimeSlice();
    }

    fn getInteractivity(self: *const Common) u8 {
        @setRuntimeSafety(false);
        const time = @as(u32, self.cpu_time) + self.sleep_time;
        if (time == 0) return 0;

        const result = (@as(u32, self.sleep_time + 1) * utils.fp_scale) / time;
        return @truncate(result);
    }

    /// Caclulate time slice for the task and return it.
    fn calcTimeSlice(self: *const Common) Ticks {
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

pub const List = utils.List(AnyTask);
pub const Node = List.Node;

pub const WaitQueue = struct {
    const Entry = struct {
        task: *AnyTask,
        /// Timestamp of start of wait in nanoseconds.
        timestamp: u64 = 0,
    };

    const QList = utils.SList(Entry);
    const QNode = QList.Node;

    list: QList = .{},

    pub inline fn push(self: *WaitQueue, node: *QNode) void {
        self.list.prepend(node);
    }

    pub inline fn pop(self: *WaitQueue) ?*Entry {
        const node = self.list.popFirst() orelse return null;
        return &node.data;
    }

    pub fn remove(self: *WaitQueue, task: *AnyTask) ?*Entry {
        var prev: ?*QNode = null;
        var node = self.list.first;
        while (node) |n| : ({ prev = n; node = n.next; }) {
            if (n.data.task == task) {
                if (prev) |p| {
                    _ = p.removeNext();
                } else {
                    self.list.first = n.next;
                }

                return &n.data;
            }
        }

        return null;
    }

    pub inline fn initEntry(task: *AnyTask, timestamp: u64) QNode {
        return .{
            .data = .{
                .task = task,
                .timestamp = timestamp
            }  
        };
    }
};

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


