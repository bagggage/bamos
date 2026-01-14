//! # Logger
//! 
//! Provides implementation for `defaultLog(...)` used within `std.log`.
//! Manages thread-safe text output with color formatting.

// Copyright (C) 2024-2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");
const builtin = @import("builtin");

const arch = lib.arch;
const lib = @import("lib.zig");
const serial = @import("dev/drivers/uart/8250.zig");
const smp = @import("smp.zig");
const sys = @import("sys.zig");
const terminal = video.terminal;
const video = @import("video.zig");

const EarlyWriter = struct {
    const vtable: std.io.Writer.VTable = .{
        .drain = drain,
    };

    var buf_writer: std.io.Writer = .fixed(&log_buffer);

    fn setup() std.io.Writer {
        return .{ .buffer = &.{}, .vtable = &vtable };
    }

    fn getPrinted() []const u8 {
        return log_buffer[0..buf_writer.end];
    }

    fn drain(writer: *std.io.Writer, data: []const []const u8, _: usize) std.io.Writer.Error!usize {
        const slice = writer.buffer[0..writer.end];

        serial.write(slice);
        _ = buf_writer.write(slice) catch { buf_writer.end = 0; };
        writer.end = 0;

        var bytes: usize = 0;
        for (data) |d| {
            serial.write(d);
            _ = buf_writer.write(d) catch { buf_writer.end = 0; };

            bytes += d.len;
        }

        return bytes;
    }
};

const KernelWriter = struct {
    var vtable: std.io.Writer.VTable = .{
        .drain = drainBoth,
    };

    fn setup(buffer: []u8) std.io.Writer {
        const early_logs = EarlyWriter.getPrinted();

        if (terminal.isInitialized()) {
            terminal.write(early_logs);
        } else {
            vtable.drain = drainSerial;
        }

        return .{ .buffer = buffer, .vtable = &vtable};
    }

    fn drainBoth(writer: *std.io.Writer, data: []const []const u8, _: usize) std.io.Writer.Error!usize {
        defer writer.end = 0;

        var bytes: usize = 0;
        serial.write(writer.buffer[0..writer.end]);
        for (data) |d| serial.write(d);

        terminal.write(writer.buffer[0..writer.end]);
        for (data) |d| { terminal.write(d); bytes += d.len; }

        return bytes;
    }

    fn drainSerial(writer: *std.io.Writer, data: []const []const u8, _: usize) std.io.Writer.Error!usize {
        defer writer.end = 0;

        var bytes: usize = 0;
        serial.write(writer.buffer[0..writer.end]);
        for (data) |d| { serial.write(d); bytes += d.len; }

        return bytes;
    }
};

pub const new_line = "\r\n";
pub var log_writer: std.io.Writer = EarlyWriter.setup();

const tty_config: std.io.tty.Config = .escape_codes;

/// Spinlock to ensure that logging is thread-safe.
var lock: lib.sync.Spinlock = .init(.unlocked);
var lock_owner: u16 = undefined;
var double_lock = false;

var log_buffer: [arch.vm.page_size]u8 = undefined;

pub fn switchFromEarly() void {
    log_writer = KernelWriter.setup(&log_buffer);
}

pub fn capture() void {
    const cpu_idx = smp.getIdx();

    if (lock.isLocked() and lock_owner == cpu_idx) {
        double_lock = true;
        return;
    }

    lock.lock();
    lock_owner = cpu_idx;
}

pub fn release() void {
    if (double_lock) {
        double_lock = false;
        return;
    }

    lock.unlock();
}

pub inline fn flush() !void {
    try log_writer.flush();
}

// @export
pub fn defaultLog(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype
) void {
    const new_owner = smp.getIdx();
    if (lock.isLocked() and new_owner == lock_owner) {
        @branchHint(.cold);

        tty_config.setColor(&log_writer, .bright_red) catch {};
        log_writer.print("<LOGGER DEADLOCK>" ++ new_line, .{}) catch {};
        return;
    }

    lock.lock();
    lock_owner = new_owner;
    defer lock.unlock();

    logFmtPrint(
        level,
        scope,
        format,
        args
    ) catch |erro| {
        tty_config.setColor(&log_writer, .bright_red) catch {};
        log_writer.print("<LOGGER ERROR>: {s}", .{@errorName(erro)}) catch {
            log_writer.writeAll("<LOGGER PANIC>") catch {};
        };
    };
}

inline fn logFmtPrint(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype
) !void {
    const level_str = levelToString(level);
    const color: std.io.tty.Color = switch (level) {
        .info => .reset,
        .debug => .bright_black,
        .warn => .bright_yellow,
        .err => .bright_red
    };

    try tty_config.setColor(&log_writer, color);
    try log_writer.print("{f} [{s}] ", .{ std.fmt.alt(sys.time.getUpTime(), .formatUs), level_str });

    if (scope != std.log.default_log_scope) {
        try log_writer.writeAll(@tagName(scope) ++ ": ");
    }

    try log_writer.print(format ++ new_line, args);
    try log_writer.flush();
}

inline fn levelToString(comptime level: std.log.Level) []const u8 {
    return switch (level) {
        .debug  => "<dbg>",
        .info   => "INFO",
        .warn   => "WARN",
        .err    => "ERROR"
    };
}