//! # Logger
//! 
//! Provides implementation for `defaultLog(...)` used within `std.log`.
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
    const buffer_size = 2048;
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

pub const new_line = "\r\n";
pub var writer: std.io.AnyWriter = EarlyWriter.setup();

const tty_config: std.io.tty.Config = .escape_codes;

/// Spinlock to ensure that logging is thread-safe.
var lock = Spinlock.init(.unlocked);
var lock_owner: u16 = undefined;
var double_lock = false;

pub fn switchFromEarly() void {
    writer = KernelWriter.setup();
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

// @export
pub fn defaultLog(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype
) void {
    lock.lock();
    lock_owner = smp.getIdx();
    defer lock.unlock();

    logFmtPrint(
        level,
        scope,
        format,
        args
    ) catch |erro| {
        tty_config.setColor(writer, .bright_red) catch {};

        writer.print("<LOGGER ERROR>: {s}", .{@errorName(erro)}) catch {
            writer.writeAll("<LOGGER PANIC>") catch {};
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

    try tty_config.setColor(writer, color);
    try writer.print("[{s}] ", .{level_str});

    if (scope != std.log.default_log_scope) {
        try writer.writeAll(@tagName(scope)++": ");
    }

    try writer.print(format ++ new_line, args);
}

inline fn levelToString(comptime level: std.log.Level) []const u8 {
    return switch (level) {
        .debug  => "<dbg>",
        .info   => "INFO",
        .warn   => "WARN",
        .err    => "ERROR"
    };
}