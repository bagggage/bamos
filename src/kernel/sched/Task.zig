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

pub const kernel_stack_size = if (builtin.mode == .Debug) 16 * vm.page_size else 8 * vm.page_size;
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

    sys_time_ns: u64 = 0,
    user_time_ns: u64 = 0,
    time_track_ns: u64 = 0,

    static_prior: PriorityDelta = 0,
    bonus_prior: PriorityDelta = 0,

    time_slice_ns: u32 = 0,
    cpu_time_ns: u32 = 0,
    sleep_time_ns: u32 = 0,

    sleep: std.atomic.Value(Sleep) = .init(.awake),
    sched_lock: lib.sync.Spinlock = .{},

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
        self.time_slice_ns = self.calcTimeSlice();
        self.decayTimes();
    }

    /// Update priority bonus based on task interactivity.
    pub fn updateBonus(self: *Stats) void {
        const max_interactivity: comptime_int = lib.fp_scale;
        const base_interactivity: comptime_int = max_interactivity / 2;

        const bonus_range_shift = @bitSizeOf(PriorityDelta);
        const interactivity_range_shift = std.math.log2(lib.fp_scale);
        const normalize_shift = interactivity_range_shift - bonus_range_shift;

        const neg_interactivity: i32 = @as(i32, base_interactivity) - self.getInteractivity();
        const bonus = neg_interactivity >> normalize_shift;

        self.bonus_prior = @truncate(std.math.clamp(bonus, std.math.minInt(PriorityDelta), std.math.maxInt(PriorityDelta)));
    }

    pub fn yieldTime(self: *Stats) void {
        self.sleep_time_ns +|= self.time_slice_ns;
    }

    pub fn enterSystemTime(self: *Stats) void {
        @setRuntimeSafety(false);
        const time_ns = sys.time.getUpTimeNs();
        const delta_ns = time_ns -% self.time_track_ns;

        self.user_time_ns +%= delta_ns;
        self.time_track_ns = time_ns;

        const task: *Self = @fieldParentPtr("stats", self);
        task.spec.user.process.stats.user_time_ns +%= delta_ns;
    }

    pub fn exitSystemTime(self: *Stats) void {
        @setRuntimeSafety(false);
        const time_ns = sys.time.getUpTimeNs();
        const delta_ns = time_ns -% self.time_track_ns;

        self.sys_time_ns +%= delta_ns;
        self.time_track_ns = time_ns;

        const task: *Self = @fieldParentPtr("stats", self);
        task.spec.user.process.stats.sys_time_ns +%= delta_ns;
    }

    pub fn startSystemTime(self: *Stats, uptime_ns: u64) void {
        self.time_track_ns = uptime_ns;
    }

    pub fn stopSystemTime(self: *Stats, uptime_ns: u64) void {
        const delta_ns = uptime_ns -% self.time_track_ns;
        self.sys_time_ns +%= delta_ns;
        self.time_track_ns = 0;

        const task: *Self = @fieldParentPtr("stats", self);
        if (task.spec == .user) task.spec.user.process.stats.sys_time_ns +%= delta_ns;
    }

    fn decayTimes(self: *Stats) void {
        const decay_fp: comptime_int = comptime @intFromFloat(0.9 * lib.fp_scale);
        const cpu_time = (@as(usize, self.cpu_time_ns) * decay_fp) / lib.fp_scale;
        const sleep_time = (@as(usize, self.sleep_time_ns) * decay_fp) / lib.fp_scale;

        self.cpu_time_ns = @truncate(cpu_time);
        self.sleep_time_ns = @truncate(sleep_time);
    }

    fn getInteractivity(self: *const Stats) u8 {
        @setRuntimeSafety(false);
        const time = @as(usize, self.cpu_time_ns) +| self.sleep_time_ns;
        if (time == 0) return 0;

        const result = ((@as(usize, self.sleep_time_ns) +| 1) * lib.fp_scale) / time;
        return @truncate(result);
    }

    /// Caclulate time slice for the task and return it.
    fn calcTimeSlice(self: *const Stats) u32 {
        const max_interactivity_bonus = 12;
        const interactivity_per_bonus = lib.fp_scale / max_interactivity_bonus;

        const max_priority_bonus = 8;
        const priority_per_bonus = sched.max_priority / max_priority_bonus;

        const interactivity_bonus = self.getInteractivity() / interactivity_per_bonus;
        const reverse_priority: u32 = @as(u32, sched.max_priority) - self.getPriority();
        const priority_bonus = reverse_priority / priority_per_bonus;

        const ticks = priority_bonus +% interactivity_bonus +% 1;
        return sys.time.getNsPerTick() *% ticks;
    }

    inline fn calcTimeBonus(reverse_prior: u32) u32 {
        return std.math.log2(reverse_prior * reverse_prior);
    }
};

pub const Specific = union(enum) {
    /// Kernel task specific data.
    pub const Kernel = struct {
        name: []const u8
    };

    /// User task specific data.
    pub const User = struct {
        pub const UList = std.SinglyLinkedList;
        pub const UNode = UList.Node;

        process: *sys.Process,
        abi_data: lib.AnyData = .{},

        /// Used by `sys.Process` to put task in list.
        node: UNode = .{},

        pub inline fn fromNode(node: *UNode) *User {
            return @fieldParentPtr("node", node);
        }

        pub inline fn toTask(self: *User) *sched.Task {
            const spec: *Specific = @fieldParentPtr("user", self);
            return @fieldParentPtr("spec", spec);
        }
    };

    kernel: Kernel,
    user: User,
};

pub const WorkerFn = *const fn (usize) noreturn;

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

pub fn createWorker(name: []const u8, entry: WorkerFn, arg: lib.AnyData) vm.Error!*Self {
    const stack = try createKernelStack();
    const task: *Self = @ptrFromInt(stack + kernel_stack_size - @sizeOf(Self));
    const stack_top = @intFromPtr(task);

    task.* = .{
        .spec = .{ .kernel = .{ .name = name } },
        .context = .initWorker(stack_top, @intFromPtr(entry), arg.as(usize)),
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

pub inline fn prepareForSleep(self: *Self) void {
    self.stats.sleep.raw = .falling_asleep;
}

pub inline fn canclePrepareForSleep(self: *Self) void {
    self.stats.sleep.store(.awake, .release);
}

pub fn tryWakeup(self: *Self) bool {
    // Prefetch to prevent cache line drop
    if (self.stats.sleep.load(.acquire) != .sleep) {
        if (self.stats.sleep.cmpxchgStrong(
            .falling_asleep, .needs_wakeup,
            .release, .monotonic
        ) == null) return false;
    }

    if (self.stats.sleep.load(.acquire) == .sleep) {
        if (self.stats.sleep.cmpxchgStrong(
            .sleep, .awake,
            .release, .monotonic
        ) == null) {
            @branchHint(.likely);
            return true;
        }
    }

    return false;
}

pub fn onSwitchTo(self: *Self) void {
    defer self.stats.sched_lock.unlockAtomic();

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
