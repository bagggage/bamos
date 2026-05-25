//! # Kernel Console device

// Copyright (C) 2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const dev = @import("../dev.zig");
const devfs = vfs.devfs;
const log = std.log.scoped(.Console);
const logger = @import("../logger.zig");
const Teletype = dev.classes.Teletype;
const vfs = @import("../vfs.zig");
const VirtualTerminal = @import("VirtualTerminal.zig");

const Self = @This();

const dev_ops: devfs.DevFile.Operations = .{
    .open = &devOpen,
    .close = &devClose,
    .fops = .{
        .read = &fileRead,
        .write = &fileWrite,
        .ioctl = &fileIoctl,
        .poll = &filePoll,
    }
};

var instance: Self = .{};

dev_file: devfs.DevFile = undefined,
active_tty: ?*Teletype = null,

pub fn init() !void {
    // Compiler bug: this initialization cannot be done in
    // compile time, compilation just fails without errors.
    instance.dev_file = .{
        .name = .init("console"),
        .num = .{ .major = 5, .minor = 1 },
        .access = .{ .gid = 0, .perm = vfs.Permissions.makeInt(.rw, .none, .none) },
        .ops = &dev_ops
    };

    try devfs.registerCharDev(&instance.dev_file);

    const tty = VirtualTerminal.select(0) catch |err| blk: {
        if (err != error.Uninitialized) log.err("failed to enable VT: {t}", .{err});

        const ttys = dev.obj.getObjects(Teletype) orelse return;
        defer dev.obj.putObjects(ttys);

        var node = ttys.first;
        while (node) |n| : (node = n.next) {
            const tty = dev.obj.fromNode(Teletype, n);
            const name = tty.dev_file.name.str();
            if (std.mem.startsWith(u8, name, "ttyUSB") or
                std.mem.startsWith(u8, name, "ttyS")
            ) break :blk tty;
        }

        log.warn("no suitable device found", .{});
        return;
    };

    log.info("active device: {s}", .{tty.dev_file.name.str()});
    instance.active_tty = tty;
}

fn devOpen(_: *devfs.DevFile, file: *vfs.File) vfs.Error!void {
    if (instance.active_tty) |tty| {
        @branchHint(.likely);
        if (tty.dev_file.ops.open) |open| return open(&tty.dev_file, file);
    }
}

fn devClose(_: *devfs.DevFile, file: *vfs.File) void {
    if (instance.active_tty) |tty| {
        @branchHint(.likely);
        if (tty.dev_file.ops.close) |close| return close(&tty.dev_file, file);
    }
}

fn fileWrite(file: *vfs.File, offset: usize, buffer: []const u8) vfs.Error!usize {
    if (instance.active_tty) |tty| {
        @branchHint(.likely);
        return tty.dev_file.ops.fops.write(file, offset, buffer);
    }

    logger.capture();
    defer logger.release();

    return logger.log_writer.write(buffer) catch return error.IoFailed;
}

fn fileRead(file: *const vfs.File, offset: usize, buffer: []u8) vfs.Error!usize {
    if (instance.active_tty) |tty| {
        @branchHint(.likely);
        return tty.dev_file.ops.fops.read(file, offset, buffer);
    }

    return 0;
}

fn fileIoctl(file: *vfs.File, cmd: c_uint, arg: usize) vfs.Error!void {
    if (instance.active_tty) |tty| {
        @branchHint(.likely);
        return tty.dev_file.ops.fops.ioctl(file, cmd, arg);
    }

    return error.BadOperation;
}

fn filePoll(file: *vfs.File) vfs.Error!vfs.File.Poll {
    if (instance.active_tty) |tty| {
        @branchHint(.likely);
        return tty.dev_file.ops.fops.poll(file);
    }

    return .{};
}
