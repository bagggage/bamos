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

/// A struct that is exactly 512 bytes and matches tar file format. This is
/// intended to be used for outputting tar files; for parsing there is
/// `std.tar.Header`.
const TarHeader = extern struct {
    // This struct was originally copied from
    // https://github.com/mattnite/tar/blob/main/src/main.zig which is MIT
    // licensed.
    //
    // The name, linkname, magic, uname, and gname are null-terminated character
    // strings. All other fields are zero-filled octal numbers in ASCII. Each
    // numeric field of width w contains w minus 1 digits, and a null.
    // Reference: https://www.gnu.org/software/tar/manual/html_node/Standard.html
    // POSIX header:                                  byte offset
    name: [100]u8 = [_]u8{0} ** 100, //                         0
    mode: [7:0]u8 = default_mode.file, //                     100
    uid: [7:0]u8 = [_:0]u8{0} ** 7, // unused                 108
    gid: [7:0]u8 = [_:0]u8{0} ** 7, // unused                 116
    size: [11:0]u8 = [_:0]u8{'0'} ** 11, //                   124
    mtime: [11:0]u8 = [_:0]u8{'0'} ** 11, //                  136
    checksum: [7:0]u8 = [_:0]u8{' '} ** 7, //                 148
    typeflag: FileType = .regular, //                         156
    linkname: [100]u8 = [_]u8{0} ** 100, //                   157
    magic: [6]u8 = [_]u8{ 'u', 's', 't', 'a', 'r', 0 }, //    257
    version: [2]u8 = [_]u8{ '0', '0' }, //                    263
    uname: [32]u8 = [_]u8{0} ** 32, // unused                 265
    gname: [32]u8 = [_]u8{0} ** 32, // unused                 297
    devmajor: [7:0]u8 = [_:0]u8{0} ** 7, // unused            329
    devminor: [7:0]u8 = [_:0]u8{0} ** 7, // unused            337
    prefix: [155]u8 = [_]u8{0} ** 155, //                     345
    pad: [12]u8 = [_]u8{0} ** 12, // unused                   500

    pub const FileType = enum(u8) {
        regular = '0',
        symbolic_link = '2',
        directory = '5',
        gnu_long_name = 'L',
        gnu_long_link = 'K',
    };

    const default_mode = struct {
        const file = [_:0]u8{ '0', '0', '0', '0', '6', '6', '4' }; // 0o664
        const dir = [_:0]u8{ '0', '0', '0', '0', '7', '7', '5' }; // 0o775
        const sym_link = [_:0]u8{ '0', '0', '0', '0', '7', '7', '7' }; // 0o777
        const other = [_:0]u8{ '0', '0', '0', '0', '0', '0', '0' }; // 0o000
    };

    pub fn init(typeflag: FileType) TarHeader {
        return .{
            .typeflag = typeflag,
            .mode = switch (typeflag) {
                .directory => default_mode.dir,
                .symbolic_link => default_mode.sym_link,
                .regular => default_mode.file,
                else => default_mode.other,
            },
        };
    }
};

const max_name = 256;

var fs = vfs.FileSystem.init(
    "initramfs",
    .{ .virt = .{
        .mount = mount,
        .unmount = undefined
    }},
    .{
        .lookup = dentryLookup,
    }
);

var initrd: []const u8 = &.{};

var file_name: [max_name]u8 = .{ 0 } ** max_name;
var link_name: [max_name]u8 = .{ 0 } ** max_name;

pub const fs_name = "initramfs";
pub const mount_dir_name: []const u8 = "initrd";

pub fn init() !void {
    if (!vfs.registerFs(&fs)) return error.RegisterFailed;

    const mount_dir = vfs.getRootWeak().makeDirectory(mount_dir_name) catch |err| {
        log.err("failed to create mount point: {}", .{err});
        return error.MountFailed;
    };
    defer mount_dir.deref();

    _ = vfs.mount(mount_dir, fs_name, null) catch |err| {
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

fn mount() vfs.Error!vfs.Context.Virt {
    // Already mounted
    if (initrd.len != 0) return error.Busy;

    const inode = vfs.Inode.new() orelse return error.NoMemory;
    errdefer inode.free();

    const dentry = vfs.Dentry.new() orelse return error.NoMemory;
    inode.* = .{
        .index = 0,
        .type = .directory,
    };

    dentry.init("/", undefined, inode, &fs.data.dentry_ops) catch unreachable;
    initrd = boot.getInitrd();

    return .{ .root = dentry };
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
    const is_parent_root = parent == parent.ctx.virt.root;

    if (!is_parent_root) {
        if (try tar_iter.next() == null) return null;
    }

    const parent_name_str = parent.name.str();

    while (try tar_iter.next()) |file| {
        var name_iter = std.mem.splitBackwardsScalar(u8, file.name, '/');
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
            try dentry.init(entry_name, parent.ctx, inode, &fs.data.dentry_ops);

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
        .index = @truncate(pos - @sizeOf(TarHeader)),

        .type = switch (file.kind) {
            .directory => .directory,
            .file => .regular_file,
            .sym_link => .symbolic_link
        },
        .size = file.size,

        // Data pointer
        .fs_data = utils.AnyData.from(@constCast(&initrd.ptr[pos]))
    };
}