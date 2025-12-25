//! # System call

// Copyright (C) 2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");
const log = std.log.scoped(.@"sys.call");

const sys = @import("../sys.zig");

pub const linux = @import("call/linux.zig");

pub const Abi = enum(u8) {
    linux_sysv,
};

pub const Handler = *const fn() callconv(.naked) noreturn;

pub fn badCallHandler(proc: *sys.Process, id: usize, name: ?[]const u8, args: anytype) void {
    log.debug("invalid syscall: {s}:{}({any}), process: {}:{f}", .{
        name orelse "unknown", id, args, proc.pid, proc.exe_file.?.dentry.path()
    });
}
