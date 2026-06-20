const std = @import("std");

const bindings = @import("bindings.zig");

pub const Message = struct {
    pub const Status = enum(u8) { free = 0, processing = 1, commited = 2 };
    pub const Level = enum(u8) {
        debug = 0,
        info = 1,
        warn = 2,
        err = 3,

        pub fn fromStd(level: std.log.Level) Level {
            return switch (level) {
                .debug => .debug,
                .info => .info,
                .warn => .warn,
                .err => .err,
            };
        }

        pub fn toColor(self: Level) std.Io.tty.Color {
            return switch (self) {
                .debug => .bright_black,
                .info => .reset,
                .warn => .bright_yellow,
                .err => .bright_red,
            };
        }
    };

    const Meta = packed struct(u64) {
        idx: u32 = 0,
        len: u16 = 0,
        level: Level = .debug,
        status: Status = .free,
    };

    meta: std.atomic.Value(Meta) = .init(.{}),
    time_ns: u64 = 0,
    text: [*]const u8,
    scope: [*:0]const u8,
};

const msg_max_size = 512;

pub fn defaultLog(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype
) void {
    var buffer: [msg_max_size]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    writer.print(format, args) catch return;

    putLog(level, @tagName(scope), writer.buffered());
    notifyWaiters() catch {};
}

pub inline fn putLog(level: std.log.Level, scope: [*:0]const u8, text: []const u8) void {
    bindings.getInstance().logger.putLog(level, scope, text);
}

pub inline fn notifyWaiters() error{Timeout}!void {
    return bindings.getInstance().logger.notifyWaiters();
}

pub inline fn panic(msg: []const u8, trace: ?*std.builtin.StackTrace, ret: ?usize) noreturn {
    return bindings.getInstance().logger.panic(msg, trace, ret);
}