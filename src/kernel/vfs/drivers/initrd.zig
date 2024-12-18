//! # Init ram-disk filesystem

// Copyright (C) 2024 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");
const tar = std.tar;

const boot = @import("../../boot.zig");
const log = std.log.scoped(.initrd);
const utils = @import("../../utils.zig");
const vfs = @import("../../vfs.zig");

const TarIterator = tar.Iterator(std.io.StreamSource.Reader);
const TarFile = TarIterator.File;
const TarHeader = tar.output.Header;

const DentryStubOps = vfs.internals.DentryStubOps(.ext2);

const max_name = 256;

var fs = vfs.FileSystem.init(
    "initramfs",
    .virtual,
    .{
        .mount = mount,
        .unmount = undefined
    },
    .{
        .lookup = dentryLookup,
        .makeDirectory = DentryStubOps.makeDirectory,
        .createFile = DentryStubOps.createFile
    }
);

var initrd: []const u8 = &.{};

var file_name: [max_name]u8 = .{ 0 } ** max_name;
var link_name: [max_name]u8 = .{ 0 } ** max_name;

pub fn init() !void {
    if (!vfs.registerFs(&fs)) return error.RegisterFailed;

    const mount_dir = vfs.getRoot().makeDirectory("initrd") catch |err| {
        log.err("failed to create mount point: {}", .{err});
        return error.MountFailed;
    };

    vfs.mount(mount_dir, "initramfs", null, undefined) catch |err| {
        log.err("while mounting: {}", .{err});
        return error.MountFailed;
    };
}

pub fn deinit() void {
    vfs.unregisterFs(&fs);
}

inline fn getStream() std.io.StreamSource {
    return .{
        .const_buffer = std.io.FixedBufferStream([]const u8) {
            .buffer = initrd,
            .pos = 0
        }
    };
}

fn mount(_: *vfs.Drive, _: *vfs.Partition) vfs.Error!*vfs.Superblock {
    // Already mounted
    if (initrd.len != 0) return error.Busy;

    const super = vfs.Superblock.new() orelse return error.NoMemory;
    errdefer super.free();

    const inode = vfs.Inode.new() orelse return error.NoMemory;
    errdefer inode.free();

    const dentry = vfs.Dentry.new() orelse return error.NoMemory;

    super.init(null, null, 512, null);
    super.root = dentry;

    inode.* = .{
        .index = 0,
        .type = .directory,
        .perm = 0
    };

    dentry.init("/", super, inode, &fs.data.dentry_ops) catch unreachable;

    initrd = boot.getInitrd();

    return super;
}

fn dentryLookup(parent: *const vfs.Dentry, name: []const u8) ?*vfs.Dentry {
    const offset = parent.inode.index;

    var stream = getStream();
    stream.seekTo(offset) catch unreachable;

    var tar_iter = tar.iterator(stream.reader(), .{
        .file_name_buffer = &file_name,
        .link_name_buffer = &link_name
    });

    return tarLookup(&tar_iter, parent, name) catch |err| {
        handleErr(err);
        return null;
    };
}

fn tarLookup(tar_iter: *TarIterator, parent: *const vfs.Dentry, name: []const u8) !?*vfs.Dentry {
    // Skip parent file itself
    const is_parent_root = parent == parent.super.root;

    if (!is_parent_root) {
        if (try tar_iter.next() == null) return null;
    }

    const parent_name_str = parent.name.str();

    while (try tar_iter.next()) |file| {
        var name_iter = std.mem.splitBackwards(u8, file.name, "/");
        const entry_name = name_iter.first();
        const parent_name: []const u8 = name_iter.next() orelse &.{};

        if (
            !is_parent_root and
            !std.mem.eql(u8, parent_name_str, parent_name)
        ) break;

        log.debug("name: \"{s}\"; parent: \"{s}\"", .{entry_name, parent_name});

        if (std.mem.eql(u8, entry_name, name)) {
            // Init new dentry
            const dentry = vfs.Dentry.new() orelse return error.NoMemory;
            errdefer dentry.free();

            const inode = vfs.Inode.new() orelse return error.NoMemory;
            errdefer inode.free();

            initInode(inode, &file, tar_iter.reader.context.getPos() catch unreachable);

            try dentry.init(entry_name, parent.super, inode, &fs.data.dentry_ops);

            return dentry;
        }
    }

    return null;
}

fn handleErr(err: anyerror) void {
    log.err("while parsing tar: {s}", .{@errorName(err)});
}

fn initInode(inode: *vfs.Inode, file: *const TarFile, pos: usize) void {
    inode.* = .{
        // Offset in tar
        .index = @truncate(pos - @sizeOf(tar.output.Header)),

        .type = switch (file.kind) {
            .directory => .directory,
            .file => .regular_file,
            .sym_link => .symbolic_link
        },
        .perm = 0,
        .size = file.size,

        // Data pointer
        .fs_data = utils.AnyData.from(@constCast(&initrd.ptr[pos]))
    };
}