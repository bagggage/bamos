//! # Generic OS subsystems

// Copyright (C) 2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const log = std.log.scoped(.sys);
const vfs = @import("vfs.zig");
const vm = @import("vm.zig");

pub const time = @import("sys/time.zig");

const init_paths: []const []const u8 = &.{
    "/init",
    "/bin/init",
    "/sbin/init",
    "/usr/bin/init",
    "/usr/sbin/init"
};

pub fn init() !void {
    startInit() catch |err| {
        //if (err == error.InitNotFound) @panic("Init executable not found.");
        return err;
    };
}

fn startInit() !void {
    const init_dent = try findInit();
    const buf: [*]u8 = @ptrFromInt(vm.getVirtLma(
        vm.PageAllocator.alloc(0) orelse return error.NoMemory
    ));

    const init_fd = try vfs.open(init_dent);
    _ = try init_fd.read(buf[0..vm.page_size]);

    log.info("readed:\n{s}", .{buf[0..vm.page_size]});
}

fn findInit() !*vfs.Dentry {
    const root = getInitRoot() orelse return error.NoRootFs;
    var init_dent: ?*vfs.Dentry = null;

    for (init_paths) |path| {
        const dentry = vfs.lookup(root, path) catch |err| {
            if (err == vfs.Error.NoEnt) continue;
            return err;
        };

        if (dentry.inode.type != .regular_file) continue;

        init_dent = dentry;
        break;
    }

    if (init_dent == null) return error.InitNotFound;
    return init_dent.?;
}

fn getInitRoot() ?*vfs.Dentry {
    log.warn("No root file system is configured, fallback to \""++vfs.initrd.fs_name++"\"", .{});

    return vfs.getInitRamDisk() orelse {
        log.err("The fallback root file system \""++vfs.initrd.fs_name++"\" is not accessible.",.{});
        return null;
    };
}