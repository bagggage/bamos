const std = @import("std");

const arch = utils.arch;
const text_output = video.text_output;
const utils = @import("utils.zig");
const video = @import("video.zig");

const Spinlock = @import("Spinlock.zig");

var buff: [1024]u8 = undefined;
var lock = Spinlock.init(Spinlock.UNLOCKED);

pub fn excp(vec: u32, error_code: u64) void {
    if (text_output.isEnabled() == false) text_output.init();

    _ = std.fmt.bufPrint(&buff, "[EXCEPTION]: #{}: error: 0x{x}\n\x00", .{ vec, error_code }) catch unreachable;

    text_output.setColor(video.Color.lred);
    text_output.print(&buff);
}

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

pub inline fn info(comptime fmt: []const u8, args: anytype) void {
    rawLog("[INFO]: " ++ fmt, args, video.Color.lgray);
}

pub inline fn warn(comptime fmt: []const u8, args: anytype) void {
    rawLog("[WARN]: " ++ fmt, args, video.Color.lyellow);
}

pub inline fn err(comptime fmt: []const u8, args: anytype) void {
    rawLog("[ERROR]:" ++ fmt, args, video.Color.lred);
}

pub inline fn brk(comptime fmt: []const u8, args: anytype) noreturn {
    warn(fmt, args);
    utils.halt();
}
