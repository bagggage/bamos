//! # Generic OS subsystems

// Copyright (C) 2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const config = utils.config;
const devfs = vfs.devfs;
const log = std.log.scoped(.sys);
const utils = @import("utils.zig");
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
        const dentry = vfs.lookup(root, path[1..]) catch |err| {
            if (err == vfs.Error.NoEnt) continue;
            return err;
        };

        if (dentry.inode.type != .regular_file) {
            dentry.deref();
            continue;
        }

        init_dent = dentry;
        break;
    }

    if (init_dent == null) return error.InitNotFound;
    return init_dent.?;
}

fn getInitRoot() ?*vfs.Dentry {
    if (config.get("root")) |root_path| blk: {
        const dentry = findRoot(root_path) catch |err| {
            log.err(
                "Root file system at \"{s}\" not found: {s}",
                .{root_path,@errorName(err)}
            );
            break :blk;
        };
        defer dentry.deref();

        return resolveRoot(dentry) catch |err| {
            log.err(
                "Root file system at \"{s}\" cannot be resolved: {s}",
                .{root_path,@errorName(err)}
            );
            break :blk;
        };
    }

    log.warn("No root file system is configured, fallback to \""++vfs.initrd.fs_name++"\"", .{});

    return vfs.getInitRamDisk() orelse {
        log.err("The fallback root file system \""++vfs.initrd.fs_name++"\" is not accessible.",.{});
        return null;
    };
}

fn findRoot(root_path: []const u8) !*vfs.Dentry {
    const dev_path = "/dev/";

    if (std.mem.startsWith(u8, root_path, dev_path)) {
        const blk_path = root_path[dev_path.len..];
        return try vfs.lookup(devfs.getRoot(), blk_path);
    }

    return try vfs.lookup(null, root_path);
}

fn resolveRoot(dentry: *vfs.Dentry) !*vfs.Dentry {
    return switch (dentry.inode.type) {
        .directory => {
            if (vfs.isMountPoint(dentry) == false) return error.BadDentry;
            return dentry;
        },
        .block_device => blk: {
            const blk_dev = devfs.BlockDev.fromDentry(dentry);

            const mnt_dir = try vfs.getRoot().makeDirectory("rootfs");
            defer mnt_dir.deref();

            break :blk try if (config.get("rootfs")) |fs_name|
                vfs.mount(mnt_dir, fs_name, blk_dev) 
            else vfs.tryMount(mnt_dir, blk_dev);
        },
        .symbolic_link => resolveRoot(try vfs.resolveSymLink(dentry)),
        else => return error.BadDentry
    };
}
