//! # Logging
//! Provides logging utilities for handling various types of log messages,
//! including exceptions, informational messages, warnings, and errors.
//! Manages thread-safe text output with color formatting.

const std = @import("std");

const arch = utils.arch;
const text_output = video.text_output;
const utils = @import("utils.zig");
const video = @import("video.zig");

const Spinlock = @import("Spinlock.zig");

/// Buffer used for formatting log messages before output.
var buff: [1024]u8 = undefined;
/// Spinlock to ensure that logging is thread-safe.
var lock = Spinlock.init(Spinlock.UNLOCKED);

/// Logs an exception message.
///
/// - `vec`: The interrupt service vector associated with the exception.
/// - `error_code`: The error code associated with the exception.
///
/// This function initializes the text output system if it is not already enabled,
/// formats the exception message, and prints to screen.
pub fn excp(vec: u32, error_code: u64) void {
    if (text_output.isEnabled() == false) text_output.init();

    _ = std.fmt.bufPrint(&buff, "[EXCEPTION]: #{}: error: 0x{x}\n\x00", .{ vec, error_code }) catch unreachable;

    text_output.setColor(video.Color.lred);
    text_output.print(&buff);
}

/// Logs a raw formatted message with the specified color.
///
/// - `fmt`: The format string for the message.
/// - `args`: The arguments to format into the message.
/// - `color`: The color to use for the log message output.
///
/// This function initializes the text output system if it is not already enabled,
/// acquires the spinlock to ensure thread safety, formats the message, and prints it in the specified color.
pub fn rawLog(comptime fmt: []const u8, args: anytype, color: video.Color) void {
    if (text_output.isEnabled() == false) text_output.init();

    lock.lock();
    defer lock.unlock();

    const formated = std.fmt.bufPrint(&buff, fmt ++ "\n\x00", args) catch |erro| {
        text_output.setColor(video.Color.orange);
        text_output.print("[LOGGER]: ");
        text_output.setColor(video.Color.lred);
        text_output.print("Formating failed: ");

        const error_name = @errorName(erro);
        const error_str = error_name[0..];

        text_output.print(error_str);
        text_output.print("\n");

        return;
    };

    text_output.setColor(color);
    text_output.print(formated);
}

/// Logs an informational message.
///
/// - `fmt`: The format string for the message.
/// - `args`: The arguments to format into the message.
pub inline fn info(comptime fmt: []const u8, args: anytype) void {
    rawLog("[INFO]: " ++ fmt, args, video.Color.lgray);
}

/// Logs a warning message.
///
/// - `fmt`: The format string for the message.
/// - `args`: The arguments to format into the message.
pub inline fn warn(comptime fmt: []const u8, args: anytype) void {
    rawLog("[WARN]: " ++ fmt, args, video.Color.lyellow);
}

/// Logs an error message.
///
/// - `fmt`: The format string for the message.
/// - `args`: The arguments to format into the message.
pub inline fn err(comptime fmt: []const u8, args: anytype) void {
    rawLog("[ERROR]:" ++ fmt, args, video.Color.lred);
}

/// Logs a warning message and then halts the system.
///
/// - `fmt`: The format string for the message.
/// - `args`: The arguments to format into the message.
pub inline fn brk(comptime fmt: []const u8, args: anytype) noreturn {
    warn(fmt, args);
    utils.halt();
}
