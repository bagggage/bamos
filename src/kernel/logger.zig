//! # Logging
//! 
//! Provides logging utilities for handling various types of log messages,
//! including exceptions, informational messages, warnings, and errors.
//! Manages thread-safe text output with color formatting.

// Copyright (C) 2024 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");
const builtin = @import("builtin");

const arch = utils.arch;
const serial = @import("dev/drivers/uart.zig");
const smp = @import("smp.zig");
const terminal = video.terminal;
const utils = @import("utils.zig");
const video = @import("video.zig");

const Spinlock = utils.Spinlock;

const EarlyWriter = struct {
    const buffer_size = 1024;
    const Stream = std.io.FixedBufferStream([buffer_size]u8);

    var stream: Stream = .{
        .buffer = .{ 0 } ** buffer_size,
        .pos = 0
    };
    var buf_writer = stream.writer();

    fn setup() std.io.AnyWriter {
        return .{
            .context = undefined,
            .writeFn = write
        };
    }

    fn getPrinted() []const u8 {
        return stream.buffer[0..stream.pos];
    }

    fn write(_: *const anyopaque, bytes: []const u8) anyerror!usize {
        serial.write(bytes);
        return buf_writer.write(bytes);
    }
};

const KernelWriter = struct {
    fn setup() std.io.AnyWriter {
        const early_logs = EarlyWriter.getPrinted();

        terminal.write(early_logs);

        return .{
            .context = undefined,
            .writeFn = write
        };
    }

    fn write(_: *const anyopaque, bytes: []const u8) anyerror!usize {
        serial.write(bytes);
        terminal.write(bytes);

        return bytes.len;
    }
};

pub var writer: std.io.AnyWriter = EarlyWriter.setup();

/// Buffer used for formatting log messages before output.
var buff: [1024]u8 = undefined;
var tty_config: std.io.tty.Config = .escape_codes;

/// Spinlock to ensure that logging is thread-safe.
var lock = Spinlock.init(.unlocked);
var lock_owner: u16 = undefined;

// @export
pub fn defaultLog(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype
) void {
    lock.lock();
    defer lock.unlock();

    logFmtPrint(
        level,
        scope,
        format,
        args
    ) catch |erro| {
        tty_config.setColor(writer, .bright_red) catch {};

        writer.print("[LOGGER ERROR]: {s}", .{@errorName(erro)}) catch {
            writer.writeAll("[LOGGER PANIC]!") catch {};
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
        .info => .white,
        .debug => .bright_black,
        .warn => .bright_yellow,
        .err => .bright_red
    };

    try tty_config.setColor(writer, color);
    try writer.print("[{s}] ", .{level_str});

    if (scope != std.log.default_log_scope) {
        try writer.writeAll(@tagName(scope));
    }

    try writer.print(": "++format++"\n\r", args);
}

inline fn levelToString(comptime level: std.log.Level) []const u8 {
    return switch (level) {
        .debug  => "debug",
        .info   => "INFO",
        .warn   => "WARN",
        .err    => "ERROR"
    };
}

pub fn switchFromEarly() void {
    writer = KernelWriter.setup();
}

/// Logs an exception message.
///
/// - `vec`: The interrupt service vector associated with the exception.
/// - `error_code`: The error code associated with the exception.
///
/// This function initializes the text output system if it is not already enabled,
/// formats the exception message, and prints to screen.
pub fn excp(vec: u32, error_code: u64) void {
    const cpu_idx = smp.getIdx();

    tty_config.setColor(writer, .bright_red) catch {};

    _ = std.fmt.bufPrint(&buff, "[EXCEPTION]: #{}: error: 0x{x}: CPU: {}\n\x00", .{ vec, error_code, cpu_idx }) catch unreachable;

    if (lock.isLocked() and lock_owner == cpu_idx) {
        lock.unlock();
    }

    lock.lock();
    lock_owner = cpu_idx;

    writer.writeAll(&buff) catch |erro| {
        writer.print("[LOGGER ERROR]: {s}", .{@errorName(erro)}) catch {};
    };
}

pub inline fn excpEnd() void {
    lock.unlock();
}

/// Logs a raw formatted message with the specified color.
///
/// - `fmt`: The format string for the message.
/// - `args`: The arguments to format into the message.
/// - `color`: The color to use for the log message output.
///
/// This function initializes the text output system if it is not already enabled,
/// acquires the spinlock to ensure thread safety, formats the message, and prints it in the specified color.
pub fn rawLog(comptime fmt: []const u8, args: anytype, color: video.Color, comptime use_lock: bool) void {
    _ = color;

    var was_locked = false;

    if (use_lock) {
        const cpu_idx = smp.getIdx();
        
        if (!lock.isLocked() or lock_owner != cpu_idx) {
            lock.lock();
            lock_owner = cpu_idx;
            was_locked = true;
        }
    }
    defer if (use_lock and was_locked) lock.unlock();

    writer.print(fmt++"\n\r", args) catch |erro| {
        writer.print("[LOGGER ERROR]: {s}", .{@errorName(erro)}) catch {};
    };
}