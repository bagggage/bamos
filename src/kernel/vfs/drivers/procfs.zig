//! # Process File System

const std = @import("std");

const tmpfs = vfs.tmpfs;
const sys = @import("../../sys.zig");
const vfs = @import("../../vfs.zig");
const vm = @import("../../vm.zig");

const fs: vfs.FileSystem = .init(
    "procfs",
    .{ .virt = .{
        .mount = mount,
        .unmount = unmount
    }},
    .{
    }
);

var root: *vfs.Dentry = undefined;

pub fn init() !void {
    root = try tmpfs.createDirectory(
        "/", undefined, .{ .perm = @intFromEnum(vfs.Permissions.rw) }
    );

    if (vfs.registerFs(&fs) == false) return error.RegisterFailed;
}

fn mount() vfs.Error!vfs.Context.Virt {}

fn unmount(_: *vfs.Context.Virt) void {}