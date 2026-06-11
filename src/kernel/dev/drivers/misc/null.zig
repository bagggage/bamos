//! # /dev/null - device

// Copyright (C) 2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const devfs = vfs.devfs;
const vfs = @import("../../../vfs.zig");

const dev_file_ops: devfs.DevFile.Operations = .{
    .fops = .{
        .read = &fileRead,
        .write = &fileWrite,
    }
};

var dev_file: devfs.DevFile = .{
    .name = undefined, // Compiler bug, cannot initialize name at comptime!
    .access = .{ .gid = 0, .perm = @intFromEnum(vfs.Permissions.rw) },
    .num = .{ .major = 1, .minor = 3 },
    .ops = &dev_file_ops,
};

pub fn init() !void {
    dev_file.name = .init("null");
    try devfs.registerCharDev(&dev_file);
}

fn fileWrite(_: *vfs.File, _: usize, buffer: []const u8) vfs.Error!usize {
    return buffer.len;
}

fn fileRead(_: *const vfs.File, _: usize, _: []u8) vfs.Error!usize {
    return 0;
}
