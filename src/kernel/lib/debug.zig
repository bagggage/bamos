//! # Debug utilities

const std = @import("std");

const log = std.log;
const lib = @import("../lib.zig");

pub inline fn assert(ok: bool, comptime src: std.builtin.SourceLocation) void {
    if (comptime !lib.is_debug) return;

    if (!ok) {
        @branchHint(.cold);

        const location = std.fmt.comptimePrint("{s}:{}:{}", .{src.file, src.line, src.column});
        @panic(location);
    }
}
