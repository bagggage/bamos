//! # Time subsystem

const std = @import("std");

const arch = utils.arch;
const dev = @import("../dev.zig");
const log = std.log.scoped(.@"sys.time");
const smp = @import("../smp.zig");
const utils = @import("../utils.zig");

pub const Clock = dev.classes.Clock;
pub const Timer = dev.classes.Timer;

pub const epoch_per_year = 31_556_926;
pub const epoch_per_month = 2_629_743;

pub const DateTime = extern struct {
    seconds: u8 = 0,
    minutes: u8 = 0,
    hours: u8 = 0,
    month: u8 = 1,
    day: u8 = 1,
    year: u16 = 0,

    pub fn format(
        self: DateTime,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        try writer.print("{:0>2}.{:0>2}.{:0>4}-{:0>2}:{:0>2}:{:0>2}", .{
            self.day, self.month, self.year, self.hours, self.minutes, self.seconds
        });
    }

    pub fn fromTime(time: *const Time) DateTime {
        @setRuntimeSafety(false);

        var sec = time.sec;
        var result: DateTime = undefined;

        result.year = @truncate(sec / epoch_per_year);
        result.year += std.time.epoch.epoch_year;
        sec %= epoch_per_year;

        result.month = @truncate((sec / epoch_per_month) + 1);
        sec %= epoch_per_month;

        result.day = @truncate((sec / std.time.s_per_day) + 1);
        sec %= std.time.s_per_day;

        result.hours = @truncate(sec / std.time.s_per_hour);
        sec %= std.time.s_per_hour;

        result.minutes = @truncate(sec / std.time.s_per_min);
        result.seconds = @truncate(sec % std.time.s_per_min);

        return result;
    }
};

pub const Time = extern struct {
    sec: u64 = 0,
    ns: u32 = 0,

    pub fn fromDateTime(date_time: DateTime) Time {
        var sec: u64 = @as(u64, date_time.year - std.time.epoch.epoch_year) * epoch_per_year;
        sec += @as(u64, date_time.month - 1) * epoch_per_month;
        sec += @as(u64, date_time.day - 1) * std.time.s_per_day;
        sec += @as(u64, date_time.hours) * std.time.s_per_hour;
        sec += @as(u64, date_time.minutes) * std.time.s_per_min;
        sec += date_time.seconds;

        return .{ .sec = sec, .ns = 0 };
    }

    pub fn fromTicks(ticks: usize) Time {
        var time: Time = .{};

        time.addTicks(ticks);
        return time;
    }

    pub fn normalize(self: *Time) void {
        if (self.ns < std.time.ns_per_s) return;

        self.ns -= std.time.ns_per_s;
        self.sec += 1;
    }

    pub fn addTicks(self: *Time, ticks: usize) void {
        @setRuntimeSafety(false);
        const ns: usize = ticks * (std.time.ns_per_s / sys_timer_hz);
        self.addNs(ns);
    }

    pub inline fn addNs(self: *Time, ns: usize) void {
        @setRuntimeSafety(false);
        const new_ns = ns + self.ns;

        self.sec += new_ns / std.time.ns_per_s;
        self.ns = @truncate(new_ns % std.time.ns_per_s);
    }

    pub inline fn toNs(self: *const Time) u64 {
        return (self.sec * std.time.ns_per_s) + self.ns;
    }

    pub fn fromNs(ns: u64) Time {
        return .{
            .sec = ns / std.time.ns_per_s,
            .ns = ns % std.time.ns_per_s
        };
    }

    pub fn format(
        self: Time,
        comptime fmt: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        // Print in microseconds.
        if (comptime std.mem.eql(u8, fmt, "us")) {
            try writer.print("{:>5}.{:0>6}", .{ self.sec, self.ns / std.time.ns_per_us });
            return;
        } else if (comptime std.mem.eql(u8, fmt, "s")) {
            try writer.print("{:>5}", .{ self.sec });
            return;
        } else if (comptime std.mem.eql(u8, fmt, "d")) {
            try writer.print("{}.{}", .{ self.sec, self.ns });
            return;
        }

        const date_time = DateTime.fromTime(&self);

        if (comptime std.mem.eql(u8, fmt, "dt")) {
            try writer.print("{}", .{ date_time });
        } else {
            try writer.print("{}.{:0>6}", .{ date_time, self.ns / std.time.ns_per_us });
        }
    }
};

/// System timer default frequency.
const default_hz = 500;
/// System timer maximum frequency.
const max_hz = 1000;

/// Internal timekeeper structure.
/// Responsible for maintaining the time in an up-to-date state.
const Keeper = struct {
    time: Time = .{},
    uptime: Time = .{},

    last_count: usize = 0,
    ns_per_ticks: usize = 0,

    pub fn init(self: *Keeper) void {
        const date_time = sys_clock.getDateTime();

        self.time = Time.fromDateTime(date_time);
        self.last_count = sys_timer.getCounter();
        self.ns_per_ticks = std.time.ns_per_s / sys_timer.base_frequency;

        log.debug("count: {}, ns per tick: {}", .{self.last_count,self.ns_per_ticks});
    }

    pub fn update(self: *Keeper) void {
        const curr_count = sys_timer.getCounter();
        const delta_ns = self.deltaNs(curr_count);

        self.last_count = curr_count;
        self.time.addNs(delta_ns);
        self.uptime.addNs(delta_ns);
    }

    /// Complex inline function, don't use it everywhere.
    inline fn actualTime(self: *Keeper, src_time: Time) Time {
        if (self.time.sec == 0) return src_time;

        var time = src_time;
        const delta_ns = self.deltaNs(sys_timer.getCounter());

        time.addNs(delta_ns);
        return time;
    }

    inline fn deltaNs(self: *const Keeper, count: usize) usize {
        return ((count -% self.last_count) & sys_timer.mask) *% self.ns_per_ticks;
    }
};

/// Clock used as source of system date-time.
var sys_clock: *Clock = undefined;
/// Timer used to measure more accurate system time.
var sys_timer: *Timer = undefined;
/// Timer used as a tick interrupt source.
var sched_timer: *Timer = undefined;

var keeper: Keeper = .{};

/// System timer frequency.
var sys_timer_hz: u32 = default_hz;
var sys_up_ticks: std.atomic.Value(usize) = .init(0);
var up_ticks_lock: utils.Spinlock = .init(.unlocked);

pub fn init() !void {
    sys_clock = try chooseClock();
    sys_timer = try chooseSysTimer();
    sched_timer = try chooseSchedTimer();

    keeper.init();

    log.info("clock: {}, timer: {}", .{ sys_clock.device.name, sys_timer.device.name });
    log.info("sched timer: {}", .{sched_timer.device.name});
    log.info("{dt}", .{keeper.time});
}

pub fn initPerCpu() void {
    arch.time.initPerCpu() catch |err| {
        log.err("failed to initialize CPU timer: {s}", .{@errorName(err)});
        utils.halt();
    };
}

pub inline fn maskTimerIntr(mask: bool) void {
    // TODO: Rewrite to use `Timer` interface instead of
    // arch-dependent function.
    arch.time.maskTimerIntr(mask);
}

/// Returns current system date and time.
pub inline fn getDateTime() Clock.DateTime {
    sys_clock.getDateTime();
}

pub inline fn setDateTime(date_time: Clock.DateTime) void {
    sys_clock.setDateTime(date_time);
}

/// Returns number of system timer ticks elapsed
/// from kernel startup.
pub inline fn getTicks() usize {
    return sys_up_ticks.load(.acquire);
}

/// Returns actual system time according to clock date-time
/// with influence of system timer.
pub fn getTime() Time {
    return keeper.actualTime(keeper.time);
}

/// Returns last updated system time.
/// To get update frequency use `sys.time.getHz()`.
pub inline fn getCachedTime() Time {
    return keeper.time;
}

/// Returns actual kernel uptime.
pub fn getUpTime() Time {
    return keeper.actualTime(keeper.uptime);
}

/// Returns last updated kernel uptime.
/// To get update frequency use `sys.time.getHz()`.
pub inline fn getCachedUpTime() Time {
    return keeper.uptime;
}

/// Returns UNIX epoch:
/// number of seconds elapsed since 1970-01-01.
pub inline fn getEpoch() u64 {
    return keeper.time.sec;
}

/// Returns current timestamp relative
/// to kernel uptime in nanoseconds.
pub inline fn getTimestamp() u64 {
    return getUpTime().toNs();
}

/// Returns timestamp relative
/// to cached kernel uptime in nanoseconds.
pub inline fn getFastTimestamp() u64 {
    return getCachedUpTime().toNs();
}

pub inline fn getNsPerTick() u32 {
    return std.time.ns_per_s / sys_timer_hz;
}

pub inline fn getHz() u32 {
    return sys_timer_hz;
}

export fn timerIntrHandler(_: *Timer) void {
    const local = smp.getLocalData();
    local.enterInterrupt();

    if (local.idx == smp.boot_cpu) {
        _ = sys_up_ticks.fetchAdd(1, .monotonic);
        keeper.update();
    }

    local.scheduler.tick();
}

inline fn chooseClock() !*Clock {
    return arch.time.getClock() orelse
        return error.SuitableDeviceNotFound;
}

inline fn chooseSysTimer() !*Timer {
    return arch.time.getSysTimer() orelse
        return error.SuitableDeviceNotFound;
}

inline fn chooseSchedTimer() !*Timer {
    return arch.time.getSchedTimer() orelse
        return error.SuitableDeviceNotFound;
}
