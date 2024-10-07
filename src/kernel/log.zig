//! # Logging
//! 
//! Provides logging utilities for handling various types of log messages,
//! including exceptions, informational messages, warnings, and errors.
//! Manages thread-safe text output with color formatting.

const std = @import("std");
const builtin = @import("builtin");

const arch = utils.arch;
const text_output = video.text_output;
const smp = @import("smp.zig");
const utils = @import("utils.zig");
const video = @import("video.zig");

const Spinlock = utils.Spinlock;

/// Buffer used for formatting log messages before output.
var buff: [1024]u8 = undefined;
/// Spinlock to ensure that logging is thread-safe.
var lock = Spinlock.init(.unlocked);
var lock_owner: u16 = undefined;

/// Logs an exception message.
///
/// - `vec`: The interrupt service vector associated with the exception.
/// - `error_code`: The error code associated with the exception.
///
/// This function initializes the text output system if it is not already enabled,
/// formats the exception message, and prints to screen.
pub fn excp(vec: u32, error_code: u64) void {
    if (text_output.isEnabled() == false) text_output.init();

    const cpu_idx = smp.getIdx();

    _ = std.fmt.bufPrint(&buff, "[EXCEPTION]: #{}: error: 0x{x}: CPU: {}\n\x00", .{ vec, error_code, cpu_idx }) catch unreachable;

    if (lock.isLocked() and lock_owner == cpu_idx) {
        lock.unlock();
    }

    lock.lock();
    lock_owner = cpu_idx;

    text_output.setColor(video.Color.lred);
    text_output.print(&buff);
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
    if (text_output.isEnabled() == false) text_output.init();

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

    const formated = std.fmt.bufPrint(&buff, fmt ++ "\n\x00", args) catch |erro| {
        const error_name = @errorName(erro);
        const error_str = error_name[0..];

        text_output.setColor(video.Color.orange);
        text_output.print("[LOGGER]: ");
        text_output.setColor(video.Color.lred);
        text_output.print("Formating failed: ");

        text_output.print(error_str);
        text_output.print("\n");

        return;
    };

    text_output.setColor(color);
    text_output.print(formated);
}

/// Logs an debug message. Only works in `RelaseSafe` and `Debug` mode.
///
/// - `fmt`: The format string for the message.
/// - `args`: The arguments to format into the message.
pub inline fn debug(comptime fmt: []const u8, args: anytype) void {
    if (builtin.mode != .ReleaseSafe and builtin.mode != .Debug) return;

    rawLog("<DEBUG> " ++ fmt, args, video.Color.gray, true);
}

/// Logs an informational message.
///
/// - `fmt`: The format string for the message.
/// - `args`: The arguments to format into the message.
pub inline fn info(comptime fmt: []const u8, args: anytype) void {
    rawLog("[INFO]: " ++ fmt, args, video.Color.lgray, true);
}

/// Logs a warning message.
///
/// - `fmt`: The format string for the message.
/// - `args`: The arguments to format into the message.
pub inline fn warn(comptime fmt: []const u8, args: anytype) void {
    rawLog("[WARN]: " ++ fmt, args, video.Color.lyellow, true);
}

/// Logs an error message.
///
/// - `fmt`: The format string for the message.
/// - `args`: The arguments to format into the message.
pub inline fn err(comptime fmt: []const u8, args: anytype) void {
    rawLog("[ERROR]:" ++ fmt, args, video.Color.lred, true);
}

/// Logs a warning message and then halts the system.
///
/// - `fmt`: The format string for the message.
/// - `args`: The arguments to format into the message.
pub inline fn brk(comptime fmt: []const u8, args: anytype) noreturn {
    warn(fmt, args);
    utils.halt();
}
