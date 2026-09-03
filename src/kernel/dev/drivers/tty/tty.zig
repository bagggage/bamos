//! # /dev/tty - device

// Copyright (C) 2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const devfs = @import("../../../vfs.zig").devfs;
const lib = @import("../../../lib.zig");
const log = std.log.scoped(.@"/dev/tty");
const sched = @import("../../../sched.zig");
const sys = @import("../../../sys.zig");
const Teletype = @import("../../classes/Teletype.zig");
const vfs = @import("../../../vfs.zig");
const VirtualTerminal = @import("VirtualTerminal.zig");
const vm = @import("../../../vm.zig");

const tty_devfile_ops: devfs.DevFile.Operations = .{
    .open = &devOpenControlTty,
};

const tty0_devfile_ops: devfs.DevFile.Operations = .{
    .open = &devOpenActiveVt
};

var tty_dev_file: devfs.DevFile = .{
    .name = undefined, // Compiler bug, cannot initialize name at comptime!
    .access = .{ .gid = 0, .perm = @intFromEnum(vfs.Permissions.rw) },
    .num = .{ .major = 5, .minor = 0 },
    .ops = &tty_devfile_ops,
};

var tty0_dev_file: devfs.DevFile = .{
    .name = undefined, // Compiler bug, cannot initialize name at comptime!
    .access = .{ .gid = 0, .perm = @intFromEnum(vfs.Permissions.rw) },
    .num = .{ .major = 4, .minor = 0 },
    .ops = &tty0_devfile_ops,
};

pub fn init() !void {
    tty_dev_file.name = .init("tty");
    tty0_dev_file.name = .init("tty0");

    try devfs.registerCharDev(&tty_dev_file);
    try devfs.registerCharDev(&tty0_dev_file);
}

fn devOpenControlTty(_: *devfs.DevFile, file: *vfs.File) vfs.Error!void {
    const task = sched.getCurrentTask();
    if (task.spec != .user) return error.NoEnt;

    const proc = task.spec.user.process;
    const group = proc.getGroup();
    defer group.deref();

    group.lock.lock();
    defer group.lock.unlock();

    const tty = group.getSessionWeak().tty orelse return error.NoEnt;
    try ttyRedirectOpen(tty, file);
}

fn devOpenActiveVt(_: *devfs.DevFile, file: *vfs.File) vfs.Error!void {
    const vt = VirtualTerminal.getActive() orelse return error.NoEnt;
    try ttyRedirectOpen(&vt.tty, file);
}

fn ttyRedirectOpen(tty: *Teletype, file: *vfs.File) vfs.Error!void {
    file.ops = &tty.dev_file.ops.fops;

    if (tty.dev_file.ops.open) |open| {
        try open(&tty.dev_file, file);
    } else {
        if (!tty.users.get()) return error.NoEnt;
        file.data.setPtr(tty);
    }
}
