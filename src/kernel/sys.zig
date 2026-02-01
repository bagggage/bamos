//! # Generic OS subsystems

// Copyright (C) 2025-2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const arch = lib.arch;
const config = @import("config.zig");
const devfs = vfs.devfs;
const lib = @import("lib.zig");
const log = std.log.scoped(.sys);
const logger = @import("logger.zig");
const sched = @import("sched.zig");
const vfs = @import("vfs.zig");
const vm = @import("vm.zig");

pub const AddressSpace = Process.AddressSpace;
pub const call = @import("sys/call.zig");
pub const exe = @import("sys/exe.zig");
pub const input = @import("sys/input.zig");
pub const limits = @import("sys/limits.zig");
pub const Process = @import("sys/Process.zig");
pub const time = @import("sys/time.zig");
pub const VirtualTerminal = @import("sys/VirtualTerminal.zig");

const init_paths: []const [:0]const u8 = &.{
    "/init",
    "/bin/init",
    "/sbin/init",
    "/usr/bin/init",
    "/usr/sbin/init"
};

const InitSource = struct {
    dentry: *vfs.Dentry,
    path: [:0]const u8,
    args: [:0]const u8
};

pub fn init() !void {
    try VirtualTerminal.init();
    try VirtualTerminal.select(0);

    logger.switchToUserspace();

    startInit() catch |err| {
        if (err == error.InitNotFound) @panic("Init executable not found.");
        return err;
    };
}

fn startInit() !void {
    const init_task = blk: {
        const root = getInitRoot() orelse return error.NoRootFs;
        defer root.deref();

        try vfs.changeRoot(root);

        const init_src = try findInit(root);
        defer init_src.dentry.deref();

        const init_proc = try Process.create(
            limits.default_stack_size,
            root, root
        );
        errdefer init_proc.delete();

        var bin: exe.Binary = try .init(init_src.dentry, init_proc);
        defer bin.deinit();

        const parsed_args = try exe.parseArgs(@constCast(init_src.args));
        defer if (parsed_args.len > 0) vm.gpa.free(@ptrCast(@constCast(parsed_args.ptr)));

        const args = if (parsed_args.len > 0) parsed_args else &.{init_src.path.ptr};
        try bin.load(args, &.{});

        log.info("start process: {f} ", .{init_proc});
        log.debug("{f}", .{init_proc.addr_space});

        arch.syscall.startProcess(init_proc, bin.data.run_ctx);
        break :blk init_proc.getMainTask().?;
    };

    sched.enqueue(init_task);
}

fn findInit(root: *vfs.Dentry) !InitSource {
    var init_dent: ?*vfs.Dentry = if (config.get("init")) |cmd| blk: {
        var it = std.mem.splitAny(u8, cmd, " \n\t");
        const path: [:0]const u8 = @ptrCast(it.first());

        const dent = vfs.lookup(root, null, path) catch |err| {
            if (err == vfs.Error.NoEnt) {
                log.warn("Init not found at specified path \"{s}\".", .{path});
                break :blk null;
            }
            return err;
        };
        return .{ .dentry = dent, .path = path, .args = cmd };
    } else null;

    const init_path = blk: {
        for (init_paths) |path| {
            const dentry = vfs.lookup(root, null, path) catch |err| {
                if (err == vfs.Error.NoEnt) continue;
                return err;
            };

            if (dentry.inode.type != .regular_file) {
                dentry.deref();
                continue;
            }

            init_dent = dentry;
            break :blk path;
        }
        return error.InitNotFound;
    };

    return .{ .dentry = init_dent.?, .path = init_path, .args = &.{} };
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
        return try vfs.lookup(null, devfs.getRoot(), blk_path);
    }

    return try vfs.lookup(null, null, root_path);
}

fn resolveRoot(dentry: *vfs.Dentry) !*vfs.Dentry {
    return switch (dentry.inode.type) {
        .directory => {
            if (vfs.isMountPoint(dentry) == false) return error.BadDentry;
            return dentry;
        },
        .block_device => blk: {
            const blk_dev = devfs.BlockDev.fromDentry(dentry);

            const mnt_dir = try vfs.getRootWeak().makeDirectory("rootfs");
            defer mnt_dir.deref();

            break :blk try if (config.get("rootfs")) |fs_name|
                vfs.mount(mnt_dir, fs_name, blk_dev) 
            else vfs.tryMount(mnt_dir, blk_dev);
        },
        .symbolic_link => resolveRoot(try vfs.resolveSymLink(dentry)),
        else => return error.BadDentry
    };
}
