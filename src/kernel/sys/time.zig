//! # Time subsystem

// Copyright (C) 2025-2026 Konstantin Pigulevskiy (bagggage@github)

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

pub const Event = struct {
    pub const Fn = *const fn (*Timer, lib.AnyData) void;

    func: ?Fn = null,
    data: lib.AnyData = .{},

    pub inline fn isSet(self: *const Event) bool {
        return self.func != null;
    }

    pub inline fn process(self: *const Event, source: *Timer) void {
        if (self.func) |func| func(source, self.data);
    }
};

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

    pub fn toEpoch(self: *const DateTime) u64 {
        var days: u32 = self.getYearDay() -% 1;
        var year: u16 = epoch.epoch_year + 1;
        while (year < self.year) : (year += 1) {
            days +%= if (epoch.isLeapYear(year)) 366 else 365;
        }

        var result: u64 = self.seconds;
        result +%= @as(u64, days) * std.time.s_per_day;
        result +%= @as(u32, self.minutes) * std.time.s_per_min;
        result +%= @as(u32, self.hours) * std.time.s_per_hour;

        return result;
    }

    /// Returns the day number of the year.
    pub fn getYearDay(self: *const DateTime) u16 {
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
        return .{ .sec = date_time.toEpoch() };
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
        const ns: usize = ticks * (std.time.ns_per_s / sched_timer_hz);
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
            .ns = @truncate(ns % std.time.ns_per_s)
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
const default_hz = 200;
/// System timer maximum frequency.
const max_hz = 1000;

/// Internal timekeeper structure.
/// Responsible for maintaining system time in actual state.
const Keeper = struct {
    const UpTime = packed struct(u128) {
        uptime_ns: u64 = 0,
        last_count: u64 = 0,
    };

    /// Base POSIX epoch for accounting date time.
    epoch: std.atomic.Value(u64) = .init(0),
    uptime: std.atomic.Value(UpTime) = .init(.{}),

    immediates: [*]dev.intr.SoftHandler = undefined,

    fn init() !Keeper {
        const immediates = vm.gpa.allocMany(dev.intr.SoftHandler, smp.getNum()) orelse return error.NoMemory;
        for (immediates, 0..) |*imm, i| {
            const local = smp.getCpuData(@intCast(i));
            imm.* = .{ .func = &timerImmediateHandler, .ctx = local };
        }

        const date_time = sys_clock.getDateTime();
        return .{
            .epoch = .init(date_time.toEpoch()),
            .uptime = .init(.{ .last_count = timer_source.readCounter() }),
            .immediates = immediates.ptr
        };
    }

    fn update(self: *Keeper) void {
        var uptime = self.uptime.raw;
        const curr_count = timer_source.readCounter();
        const delta_ns = deltaNsAbs(curr_count, uptime.last_count);

        uptime.last_count = curr_count;
        uptime.uptime_ns +%= delta_ns;

        self.uptime.store(uptime, .release);
    }

    fn actualUpTimeNs(self: *Keeper) u64 {
        const intr_enable = dev.intr.saveAndDisableForCpu();
        defer dev.intr.restoreForCpu(intr_enable);

        const uptime = self.uptime.load(.acquire);
        const curr_count = timer_source.readCounter();

        return uptime.uptime_ns +% deltaNsAbs(curr_count, uptime.last_count);
    }

    inline fn isInitialized(self: *const Keeper) bool {
        return self.epoch.raw != 0;
    }

    inline fn deltaNsAbs(a_count: usize, b_count: usize) u64 {
        return (((a_count -% b_count) & timer_source.mask) *% timer_source.ns_per_tick_fp) / lib.fp_scale;
    }
};

var keeper: Keeper = .{};
var boot_time: Time = .{};
var max_timer_event_delay_ns: u64 = std.time.ns_per_s;

/// Clock used as source of system date-time.
var sys_clock: *Clock = undefined;
/// Timer used to measure more accurate system time.
var timer_source: *Timer = undefined;
/// Timer used as a tick interrupt source.
var event_source: *Timer = undefined;

/// Scheduler timer frequency.
var sched_timer_hz: u32 = default_hz;

pub fn init() !void {
    try arch.time.init();

    sys_clock = try arch.time.chooseClock();
    timer_source = try arch.time.chooseTimeSource();
    event_source = try arch.time.chooseEventSource();

    keeper = try .init();
    boot_time = .{
        .sec = keeper.epoch.raw,
        .ns = @truncate(keeper.uptime.raw.uptime_ns),
    };

    const max_timer_ns_value = (@as(u64, std.math.maxInt(u64)) / timer_source.ns_per_tick_fp) *| lib.fp_scale;
    const max_safe_timer_value = @min(timer_source.mask, max_timer_ns_value) / 2;
    max_timer_event_delay_ns = (max_safe_timer_value *| timer_source.ns_per_tick_fp) / lib.fp_scale;

    log.info("clock: {s}, {} Hz", .{
        sys_clock.device.name.str(),
        sys_clock.base_frequency,
    });
    log.info("time source: {s}, {}.{:0>6} MHz, ns per tick: {}.{:0>2}", .{
        timer_source.device.name.str(),
        timer_source.frequency_hz / 1000_000,
        timer_source.frequency_hz % 1000_000,
        timer_source.ns_per_tick_fp / lib.fp_scale,
        ((timer_source.ns_per_tick_fp * 100) / lib.fp_scale) % 100,
    });
    log.info("event source: {s}, {}.{:0>6} MHz, ns per tick: {}.{:0>2}", .{
        event_source.device.name.str(),
        event_source.frequency_hz / 1000_000,
        event_source.frequency_hz % 1000_000,
        event_source.ns_per_tick_fp / lib.fp_scale,
        ((event_source.ns_per_tick_fp * 100) / lib.fp_scale) % 100,
    });
    log.info("max timer event delay: {}.{:0>6} sec", .{
        max_timer_event_delay_ns / std.time.ns_per_s,
        (max_timer_event_delay_ns / std.time.ns_per_us) % std.time.us_per_s,
    });
    log.info("{f}, epoch: {}", .{
        std.fmt.alt(getCachedTime(), .formatDt),
        keeper.epoch.raw,
    });
}

pub fn initPerCpu() void {
    arch.time.initPerCpu() catch |err| {
        log.err("failed to initialize CPU timer: {s}", .{@errorName(err)});
        lib.sync.halt();
    };

    event_source.setEvent(.{ .func = timerEventHandler }) catch |err| {
        log.err("failed to initialize timer event: {s}", .{@errorName(err)});
    };
}

pub inline fn isInitialized() bool {
    return keeper.isInitialized();
}

pub inline fn getClock() *Clock {
    return sys_clock;
}

pub inline fn getTimeSource() *Timer {
    return timer_source;
}

pub inline fn getEventSource() *Timer {
    return event_source;
}

/// Returns current system date and time.
pub inline fn getDateTime() Clock.DateTime {
    sys_clock.getDateTime();
}

pub fn setDateTime(date_time: Clock.DateTime) void {
    keeper.epoch.store(date_time.toEpoch(), .release);
    sys_clock.setDateTime(date_time);
}

// TODO: Replace with timer interface
pub inline fn getMaxTimerEventDelayNs() u64 {
    return max_timer_event_delay_ns;
}

/// Returns actual system time according to clock date-time
/// with influence of system timer.
pub fn getTime() Time {
    const time_ns = (keeper.epoch.raw *% std.time.ns_per_s) +% keeper.actualUpTimeNs();
    return .fromNs(time_ns);
}

pub fn getCachedTime() Time {
    const time_ns = (keeper.epoch.raw *% std.time.ns_per_s) +% keeper.uptime.raw.uptime_ns;
    return .fromNs(time_ns);
}

pub inline fn getBootTime() Time {
    return boot_time;
}

/// Returns actual kernel uptime.
pub inline fn getUpTime() Time {
    return Time.fromNs(keeper.actualUpTimeNs());
}

pub inline fn getUpTimeNs() u64 {
    return keeper.actualUpTimeNs();
}

/// Returns last updated kernel uptime.
/// To get update frequency use `sys.time.getHz()`.
pub inline fn getCachedUpTime() Time {
    return Time.fromNs(keeper.uptime.raw.uptime_ns);
}

/// Returns UNIX epoch:
/// number of seconds elapsed since 1970-01-01.
pub inline fn getEpoch() u64 {
    return keeper.epoch.raw +% getCachedUpTime().sec;
}

/// Returns current timestamp relative
/// to kernel uptime in nanoseconds.
pub inline fn getTimestamp() u64 {
    return getUpTimeNs();
}

pub inline fn getShortTimestamp() u32 {
    return @truncate(getTimestamp());
}

/// Returns timestamp relative
/// to cached kernel uptime in nanoseconds.
pub inline fn getFastTimestamp() u64 {
    return keeper.uptime.raw.uptime_ns;
}

pub inline fn getNsPerTick() u32 {
    return std.time.ns_per_s / sched_timer_hz;
}

pub inline fn getHz() u32 {
    return sched_timer_hz;
}

fn timerEventHandler(_: *Timer, _: lib.AnyData) void {
    const local = smp.getLocalData();
    const imm = &keeper.immediates[local.idx];
    dev.intr.scheduleImmediate(imm);

    local.scheduler.timerInterrupt();
}

fn timerImmediateHandler(ctx: ?*anyopaque) void {
    const local: *smp.LocalData = @alignCast(@ptrCast(ctx.?));
    const time_ns = if (local.idx == smp.boot_cpu) blk: {
        keeper.update();
        break :blk keeper.uptime.raw.uptime_ns;
    } else keeper.actualUpTimeNs();

    local.scheduler.timerEvent(time_ns);
}
