//! # /dev/tty - device

// Copyright (C) 2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const devfs = @import("../../../vfs.zig").devfs;
const log = std.log.scoped(.@"dev/tty");
const lib = @import("../../../lib.zig");
const sched = @import("../../../sched.zig");
const sys = @import("../../../sys.zig");
const vfs = @import("../../../vfs.zig");
const vm = @import("../../../vm.zig");

const devfile_ops: devfs.DevFile.Operations = .{
    .open = &devOpen,
};

var dev_file: devfs.DevFile = .{
    .name = undefined, // Compiler bug, cannot initialize name at comptime!
    .access = .{ .gid = 0, .perm = @intFromEnum(vfs.Permissions.rw) },
    .num = .{ .major = 5, .minor = 0 },
    .ops = &devfile_ops,
};

pub fn init() !void {
    dev_file.name = .init("tty");
    try devfs.registerCharDev(&dev_file);
}

fn devOpen(_: *devfs.DevFile, file: *vfs.File) vfs.Error!void {
    const task = sched.getCurrentTask();
    if (task.spec != .user) return error.NoEnt;

    const proc = task.spec.user.process;
    const group = proc.getGroup();
    defer group.deref();

    group.lock.lock();
    defer group.lock.unlock();

    const tty = group.getSessionWeak().tty orelse return error.NoEnt;
    if (!tty.users.get()) return error.NoEnt;

    file.data.setPtr(tty);
    file.ops = &tty.dev_file.ops.fops;
}
