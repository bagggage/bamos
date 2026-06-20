//! # Time subsystem

const std = @import("std");

const arch = lib.arch;
const bindings = @import("../bindings.zig");
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

pub const sched_timer_hz = 500;

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
    pub inline fn format(self: DateTime, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return bindings.getInstance().sys.time.date_time.format(self, writer);
    }

    /// Converts `Time` to `DateTime`.
    pub inline fn fromTime(time: Time) DateTime {
        return bindings.getInstance().sys.date_time.fromTime(time);
    }

    /// Returns the day number of the year.
    pub inline fn getYearDay(self: DateTime) u16 {
        return bindings.getInstance().sys.date_time.getYearDay(self);
    }
};

/// Represents time relative to UTC 1970-01-01,
/// with an accuracy of nanoseconds.
pub const Time = extern struct {
    /// Seconds elapsed since UTC 1970-01-01 (POSIX time).
    sec: u64 = 0,
    /// Nanoseconds elapsed since the beginning of the second.
    ns: u32 = 0,

    pub inline fn fromDateTime(date_time: DateTime) Time {
        return bindings.getInstance().sys.time.time.fromDateTime(date_time);
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
    pub inline fn formatDt(self: Time, writer: *std.Io.Writer) std.io.Writer.Error!void {
        return bindings.getInstance().sys.time.time.formatDt(self, writer);
    }

    /// Format time as `{sec}.{us}`.
    pub inline fn formatUs(self: Time, writer: *std.Io.Writer) std.io.Writer.Error!void {
        return bindings.getInstance().sys.time.time.formatUs(self, writer);
    }

    /// Format time as `{sec}.{ns}`.
    pub inline fn formatNs(self: Time, writer: *std.Io.Writer) std.io.Writer.Error!void {
        return bindings.getInstance().sys.time.time.formatNs(self, writer);
    }

    /// Format time as `{sec}`.
    pub inline fn formatSec(self: Time, writer: *std.Io.Writer) std.io.Writer.Error!void {
        return bindings.getInstance().sys.time.time.formatSec(self, writer);
    }

    /// Format time as `{date_time}.{us}` by default.
    pub inline fn format(self: Time, writer: *std.Io.Writer) std.io.Writer.Error!void {
        return bindings.getInstance().sys.time.time.format(self, writer);
    }
};

/// Returns current system date and time.
pub inline fn getDateTime() DateTime {
    return bindings.getInstance().sys.time.getDateTime();
}

pub inline fn setDateTime(date_time: DateTime) void {
    bindings.getInstance().sys.time.setDateTime(date_time);
}

/// Returns number of system timer ticks elapsed
/// from kernel startup.
pub inline fn getTicks() usize {
    return bindings.getInstance().sys.time.getTicks();
}

/// Returns actual system time according to clock date-time
/// with influence of system timer.
pub inline fn getTime() Time {
    return bindings.getInstance().sys.time.getTime();
}

/// Returns last updated system time.
/// To get update frequency use `sys.time.getHz()`.
pub inline fn getCachedTime() Time {
    return bindings.getInstance().sys.time.getCachedTime();
}

pub inline fn getBootTime() Time {
    return bindings.getInstance().sys.time.getBootTime();
}

/// Returns actual kernel uptime.
pub fn getUpTime() Time {
    return bindings.getInstance().sys.time.getUpTime();
}

/// Returns last updated kernel uptime.
/// To get update frequency use `sys.time.getHz()`.
pub inline fn getCachedUpTime() Time {
    return bindings.getInstance().sys.time.getCachedUpTime();
}

/// Returns UNIX epoch:
/// number of seconds elapsed since 1970-01-01.
pub inline fn getEpoch() u64 {
    return bindings.getInstance().sys.time.getEpoch();
}

/// Returns current timestamp relative
/// to kernel uptime in nanoseconds.
pub inline fn getTimestamp() u64 {
    return getUpTime().toNs();
}

pub inline fn getShortTimestamp() u32 {
    return @truncate(getUpTime().toNs());
}

/// Returns timestamp relative
/// to cached kernel uptime in nanoseconds.
pub inline fn getFastTimestamp() u64 {
    return getCachedUpTime().toNs();
}

pub inline fn getNsPerTick() u32 {
    return std.time.ns_per_s / sched_timer_hz;
}

pub inline fn getHz() u32 {
    return sched_timer_hz;
}
