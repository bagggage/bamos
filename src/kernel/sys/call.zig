//! # System call

// Copyright (C) 2025-2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const arch = lib.arch;
const log = std.log.scoped(.@"sys.call");
const lib = @import("../lib.zig");
const sched = @import("../sched.zig");
const sys = @import("../sys.zig");
const vm = @import("../vm.zig");

pub const linux = @import("call/linux.zig");

pub const Abi = enum(u8) {
    linux_sysv,
};

pub const Handler = *const fn() callconv(.naked) noreturn;

pub fn startThread(abi: Abi, task: *sched.Task, run_ctx: sys.exe.RunContext) !void {
    const abi_data = switch (abi) {
        .linux_sysv => blk: {
            const data = vm.auto.alloc(linux.AbiData) orelse return error.NoMemory;
            data.* = .{};
            break :blk data;
        },
    };

    task.spec.user.abi_data.setPtr(abi_data);
    arch.syscall.startThread(abi, task, run_ctx);
}

pub fn badCallHandler(proc: *sys.Process, id: usize, name: ?[]const u8, args: anytype) void {
    log.debug("invalid syscall: {s}:{}({any}), process: {}:{f}", .{
        name orelse "unknown", id, args, proc.pid, proc.exe_file.?.dentry.path()
    });
}
