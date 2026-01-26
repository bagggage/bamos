//! # Time subsystem

const std = @import("std");

const arch = lib.arch;
const dev = @import("../dev.zig");
const epoch = std.time.epoch;
const lib = @import("../lib.zig");
const log = std.log.scoped(.@"sys.time");
const smp = @import("../smp.zig");
const vm = @import("../vm.zig");

pub const Clock = dev.classes.Clock;
pub const Timer = dev.classes.Timer;

pub const epoch_per_year = 31_556_926;
pub const epoch_per_month = 2_629_743;

/// Represents date and time with an accuracy of seconds.
pub const DateTime = extern struct {
    /// Seconds: 0-59.
    seconds: u8 = 0,
    /// Minutes: 0-59.
    minutes: u8 = 0,
    /// Hours: 0-23.
    hours: u8 = 0,
    /// Month: 1-12.
    month: u8 = 1,
    /// Day: 1-31.
    day: u8 = 1,
    /// Year: 0-65535.
    year: u16 = 0,

    /// Format date time: DD.MM.YYYY-hh:mm:ss.
    pub fn format(self: DateTime, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{:0>2}.{:0>2}.{:0>4}-{:0>2}:{:0>2}:{:0>2}", .{
            self.day, self.month, self.year, self.hours, self.minutes, self.seconds
        });
    }

    /// Converts `Time` to `DateTime`.
    pub fn fromTime(time: Time) DateTime {
        @setRuntimeSafety(false);

        const secs: epoch.EpochSeconds = .{ .secs = time.sec };
        const day_secs = secs.getDaySeconds();
        const year_day = secs.getEpochDay().calculateYearDay();
        const month_day = year_day.calculateMonthDay();

        return .{
            .year = year_day.year,
            .month = month_day.month.numeric(),
            .day = month_day.day_index + 1,
            .hours = day_secs.getHoursIntoDay(),
            .minutes = day_secs.getMinutesIntoHour(),
            .seconds = day_secs.getSecondsIntoMinute(),
        };
    }

    /// Returns the day number of the year.
    pub fn getYearDay(self: DateTime) u16 {
        const month: epoch.Month = @enumFromInt(self.month);
        const is_leap = epoch.isLeapYear(self.year);
        const days_in_feb: u16 = if (is_leap) 29 else 28;

        const elapsed_since_year: u16 = switch (month) {
            .jan => 0,
            .feb => 31,
            .mar => 31 + days_in_feb,
            .apr => 62 + days_in_feb,
            .may => 92 + days_in_feb,
            .jun => 123 + days_in_feb,
            .jul => 153 + days_in_feb,
            .aug => 184 + days_in_feb,
            .sep => 215 + days_in_feb,
            .oct => 245 + days_in_feb,
            .nov => 276 + days_in_feb,
            .dec => 306 + days_in_feb,
        };
        
        return elapsed_since_year + self.day;
    }
};

/// Represents time relative to UTC 1970-01-01,
/// with an accuracy of nanoseconds.
pub const Time = extern struct {
    /// Seconds elapsed since UTC 1970-01-01 (POSIX time).
    sec: u64 = 0,
    /// Nanoseconds elapsed since the beginning of the second.
    ns: u32 = 0,

    pub fn fromDateTime(date_time: DateTime) Time {
        var elapsed_days: u32 = 0;
        for (epoch.epoch_year..date_time.year) |year| {
            elapsed_days += epoch.getDaysInYear(@truncate(year));
        }

        const days = elapsed_days + date_time.getYearDay() - 1;
        var secs: u64 = @as(u64, days) * std.time.s_per_day;
        secs += @as(u64, date_time.hours) * std.time.s_per_hour;
        secs += @as(u64, date_time.minutes) * std.time.s_per_min;
        secs += date_time.seconds;

        return .{ .sec = secs };
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

    pub inline fn toNs(self: Time) u64 {
        return (self.sec * std.time.ns_per_s) + self.ns;
    }

    pub inline fn posix(self: Time) u64 {
        return self.sec;
    }

    pub fn fromNs(ns: u64) Time {
        return .{
            .sec = ns / std.time.ns_per_s,
            .ns = ns % std.time.ns_per_s
        };
    }

    /// Format time as `{date_time}`.
    pub fn formatDt(self: Time, writer: *std.Io.Writer) std.io.Writer.Error!void {
        const date_time = DateTime.fromTime(self);
        try writer.print("{f}", .{ date_time });
    }

    /// Format time as `{sec}.{us}`.
    pub fn formatUs(self: Time, writer: *std.Io.Writer) std.io.Writer.Error!void {
        try writer.print("{:>5}.{:0>6}", .{ self.sec, self.ns / std.time.ns_per_us });
    }

    /// Format time as `{sec}.{ns}`.
    pub fn formatNs(self: Time, writer: *std.Io.Writer) std.io.Writer.Error!void {
        try writer.print("{}.{}", .{ self.sec, self.ns });
    }

    /// Format time as `{sec}`.
    pub fn formatSec(self: Time, writer: *std.Io.Writer) std.io.Writer.Error!void {
        try writer.print("{:>5}", .{ self.sec });
    }

    /// Format time as `{date_time}.{us}` by default.
    pub fn format(self: Time, writer: *std.Io.Writer) std.io.Writer.Error!void {
        const date_time = DateTime.fromTime(self);
        try writer.print("{f}.{:0>6}", .{ date_time, self.ns / std.time.ns_per_us });
    }
};

/// System timer default frequency.
const default_hz = 500;
/// System timer maximum frequency.
const max_hz = 1000;

/// Internal timekeeper structure.
/// Responsible for maintaining system time in actual state.
const Keeper = struct {
    time: Time,
    uptime: Time = .{},

    last_count: usize,
    ns_per_ticks: usize,

    immediates: [*]dev.intr.SoftHandler,

    pub fn init() !Keeper {
        const immediates = vm.gpa.allocMany(dev.intr.SoftHandler, smp.getNum()) orelse return error.NoMemory;
        for (immediates, 0..) |*imm, i| {
            const local = smp.getCpuData(@intCast(i));
            imm.* = .{ .func = &timerImmediateHandler, .ctx = local };
        }

        const date_time = sys_clock.getDateTime();
        return .{
            .time = Time.fromDateTime(date_time),
            .last_count = sys_timer.getCounter(),
            .ns_per_ticks = std.time.ns_per_s / sys_timer.base_frequency,
            .immediates = immediates.ptr
        };
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

var keeper: Keeper = undefined;

/// System timer frequency.
var sys_timer_hz: u32 = default_hz;
var sys_up_ticks: std.atomic.Value(usize) = .init(0);
var up_ticks_lock: lib.sync.Spinlock = .init(.unlocked);

pub fn init() !void {
    sys_clock = try chooseClock();
    sys_timer = try chooseSysTimer();
    sched_timer = try chooseSchedTimer();

    keeper =  try.init();
    log.debug("count: {}, ns per tick: {}", .{keeper.last_count,keeper.ns_per_ticks});

    log.info("clock: {f}, timer: {f}", .{ sys_clock.device.name, sys_timer.device.name });
    log.info("sched timer: {f}", .{sched_timer.device.name});
    log.info("{f}, epoch: {f}", .{
        std.fmt.alt(keeper.time, .formatDt),
        std.fmt.alt(keeper.time, .formatSec)
    });
}

pub fn initPerCpu() void {
    arch.time.initPerCpu() catch |err| {
        log.err("failed to initialize CPU timer: {s}", .{@errorName(err)});
        lib.sync.halt();
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

pub fn timerInterruptHandler(local: *smp.LocalData) callconv(.c) void {
    const imm = &keeper.immediates[local.idx];
    dev.intr.scheduleImmediate(imm);
}

fn timerImmediateHandler(ctx: ?*anyopaque) void {
    const local: *smp.LocalData = @alignCast(@ptrCast(ctx.?));
    if (local.idx == smp.boot_cpu) {
        _ = sys_up_ticks.fetchAdd(1, .monotonic);
        keeper.update();
    }

    local.scheduler.timerEvent(1);
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
