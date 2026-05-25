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
    .num = .{ .major = 1, .minor = 7 },
    .ops = &dev_file_ops,
};

pub fn init() !void {
    dev_file.name = .init("full");
    try devfs.registerCharDev(&dev_file);
}

fn fileWrite(_: *vfs.File, _: usize, _: []const u8) vfs.Error!usize {
    return error.NoSpace;
}

fn fileRead(_: *const vfs.File, _: usize, buffer: []u8) vfs.Error!usize {
    @memset(buffer, 0);
    return buffer.len;
}
