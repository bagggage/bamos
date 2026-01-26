//! # Task Structure

// Copyright (C) 2025-2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");
const builtin = @import("builtin");

const arch = lib.arch;
const lib = @import("../lib.zig");
const sched = @import("../sched.zig");
const sys = @import("../sys.zig");
const vm = @import("../vm.zig");

pub const Self = @This();

pub const List = std.DoublyLinkedList;
pub const Node = List.Node;

const Priority = sched.Priority;
const PriorityDelta = sched.PriorityDelta;
const Ticks = sched.Ticks;

const max_prior_delta = std.math.maxInt(PriorityDelta) + 1;
const base_priority = sched.max_priority / 2;

/// Highest static priority value.
pub const high_static_prior = std.math.minInt(PriorityDelta);
/// Lower static priority value.
pub const low_static_prior = std.math.maxInt(PriorityDelta);

pub const kernel_stack_size = if (builtin.mode == .Debug) 8 * vm.page_size else 2 * vm.page_size;
pub const kernel_stack_rank = vm.bytesToRank(kernel_stack_size);

/// Struct contains all data used to calculate task's
/// dynamic priority, time slice and provide execution stats
/// like CPU time or sleep time.
pub const Stats = struct {
    const Sleep = enum(u8) {
        awake,
        falling_asleep,
        needs_wakeup,
        sleep,
    };

    /// Number of scheduler ticks allocated to task.
    time_slice: sched.Ticks = 0,

    static_prior: PriorityDelta = 0,
    bonus_prior: PriorityDelta = 0,

    cpu_time: u16 = 0,
    sleep_time: u16 = 0,

    sleep: std.atomic.Value(Sleep) = .init(.awake),
    lock: lib.sync.Spinlock = .{},

    comptime {
        const max_val = (std.math.maxInt(PriorityDelta) * 2) + base_priority;
        const min_val = (std.math.minInt(PriorityDelta) * 2) + base_priority;

        std.debug.assert(max_val < sched.max_priority);
        std.debug.assert(min_val >= 0);
    }

    /// Returns task priotiry in range 0-31. Less is better.
    pub inline fn getPriority(self: *const Stats) Priority {
        @setRuntimeSafety(false);
        const result: i8 = @as(i8, base_priority) +% self.static_prior +% self.bonus_prior;
        return @truncate(@as(u8, @bitCast(result)));
    }

    /// Calculate and set time slice for the task.
    pub inline fn updateTimeSlice(self: *Stats) void {
        self.time_slice = self.calcTimeSlice();
    }

    /// Update priority bonus based on task interactivity.
    pub fn updateBonus(self: *Stats) void {
        const max_inter: comptime_int = lib.fp_scale;
        const base_inter: comptime_int = (max_inter - 1) / 2;
        const max_bonus: comptime_int = (std.math.maxInt(Priority) + 1) / 2;
        const norm_mul: comptime_int = (max_inter * lib.fp_scale) / max_bonus;

        const interactivity: i32 = self.getInteractivity();
        const bonus = @divFloor(-interactivity * norm_mul, lib.fp_scale);
        self.bonus_prior = @truncate(bonus + base_inter);
    }

    pub fn yieldTime(self: *Stats) void {
        self.sleep_time +|= self.time_slice;
    }

    fn getInteractivity(self: *const Stats) u8 {
        @setRuntimeSafety(false);
        const time = @as(u32, self.cpu_time) + self.sleep_time;
        if (time == 0) return 0;

        const result = (@as(u32, self.sleep_time + 1) * lib.fp_scale) / time;
        return @truncate(result);
    }

    /// Caclulate time slice for the task and return it.
    fn calcTimeSlice(self: *const Stats) Ticks {
        const max_bonus: comptime_int = comptime calcTimeBonus(sched.max_priority);
        const norm_mult: comptime_int = ((sched.max_slice_ticks + 1) * lib.fp_scale) / max_bonus;

        const reverse_prior: u32 = @as(u32, sched.max_priority) - self.getPriority();
        const bonus: u32 = calcTimeBonus(reverse_prior);
        const norm_bonus: Ticks = @truncate((bonus * norm_mult) / lib.fp_scale);

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
    pub const UList = std.SinglyLinkedList;
    pub const UNode = UList.Node;

    process: *sys.Process,

    /// Used by `sys.Process` to put task in list.
    node: UNode = .{},

    pub inline fn fromNode(node: *UNode) *UserSpecific {
        return @fieldParentPtr("node", node);
    }

    pub inline fn toTask(self: *UserSpecific) *sched.Task {
        const spec: *Specific = @fieldParentPtr("user", self);
        return @fieldParentPtr("spec", spec);
    }
};

pub const Specific = union(enum) {
    kernel: KernelSpecific,
    user: UserSpecific,
};

stats: Stats = .{},
/// Arch-specific context used for context switching.
context: arch.Context,
node: Node = .{},

/// Specific data which is different for
/// kernel and user tasks.
spec: Specific,

pub fn create(spec: Specific, ip: usize) !*Self {
    const stack = try createKernelStack();
    const task: *Self = @ptrFromInt(stack + kernel_stack_size - @sizeOf(Self));
    const stack_top = @intFromPtr(task);

    task.* = .{
        .spec = spec,
        .context = .init(stack_top, ip),
    };

    return task;
}

pub fn delete(self: *Self) void {
    const virt = @intFromPtr(self) - (kernel_stack_size - @sizeOf(Self));
    const virt_base = virt - vm.page_size;
    const phys = vm.getRootPt().translateVirtToPhys(virt) orelse unreachable;

    vm.getRootPt().unmap(virt, vm.bytesToPages(kernel_stack_size));
    vm.heapRelease(virt_base, vm.bytesToPages(kernel_stack_size) + 1);
    vm.PageAllocator.free(phys, kernel_stack_rank);
}

pub fn createKernelStack() !usize {
    const phys = vm.PageAllocator.alloc(kernel_stack_rank) orelse return error.NoMemory;
    errdefer vm.PageAllocator.free(phys, kernel_stack_rank);

    // Reserve N+1 pages to make a gap below the stack
    // to protect a kernel from memory corruption if stack is overflow.
    const virt_pages = vm.bytesToPages(kernel_stack_size) + 1;
    const virt_base = vm.heapReserve(virt_pages);
    errdefer vm.heapRelease(virt_base, virt_pages);

    const virt = virt_base + vm.page_size;
    try vm.getRootPt().map(
        virt, phys, vm.bytesToPages(kernel_stack_size),
        .{ .global = true, .write = true }
    );

    return virt;
}

pub inline fn fromNode(node: *Node) *Self {
    return @fieldParentPtr("node", node);
}

pub inline fn getKernelStackTop(self: *const Self) usize {
    return @intFromPtr(self);
}

pub inline fn isWaiting(self: *const Self) bool {
    return self.stats.sleep.load(.acquire) == .sleep;
}

pub inline fn tryWakeup(self: *Self) bool {
    if (self.stats.sleep.cmpxchgStrong(
            .falling_asleep, .needs_wakeup,
            .release, .monotonic
    ) == null) return false;

    self.stats.sleep.store(.awake, .release);
    return true;
}

pub fn onSwitch(self: *Self) void {
    defer self.stats.lock.unlockAtomic();
    switch (self.spec) {
        .kernel => {
            const pt = vm.getRootPt();
            if (vm.getPageTable() != pt) vm.setPageTable(pt);
        },
        .user => |u| {
            const pt = u.process.addr_space.page_table;
            if (vm.getPageTable() != pt) vm.setPageTable(pt);

            arch.syscall.setupTaskAbi(self, u.process.abi);
        }
    }
}
