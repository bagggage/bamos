//! # Init ram-disk filesystem

// Copyright (C) 2024-2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");
const tar = std.tar;

const boot = @import("../../boot.zig");
const log = std.log.scoped(.initrd);
const tmpfs = vfs.tmpfs;
const vfs = @import("../../vfs.zig");
const vm = @import("../../vm.zig");

const TarIterator = tar.Iterator;
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

const file_ops: vfs.internals.file.Cached = .{
    .readCacheBlock = fileReadCacheBlock
};

const max_name = 256;

var fs = vfs.FileSystem.init(
    "initramfs",
    .{ .virt = .{
        .mount = mount,
        .unmount = undefined
    }},
    .{
        .open = dentryOpen,
        .close = vfs.internals.dentry_ops.default.close,
        .lookup = tmpfs.DentryOps.lookup,
        .iterate = tmpfs.DentryOps.iterate,
        .deinitInode = vfs.internals.dentry_ops.default.deinitInode,

        .createFile = dentryCreateFile,
        .makeDirectory = dentryMakeDirectory,
    }
);

var initrd: []const u8 = &.{};

pub const fs_name = "initramfs";

pub fn init() !void {
    if (!vfs.registerFs(&fs)) return error.RegisterFailed;
}

pub fn deinit() void {
    vfs.unregisterFs(&fs);
}

inline fn getStream() std.Io.Reader {
    return .fixed(initrd);
}

fn mount() vfs.Error!vfs.Context.Virt {
    // Already mounted
    if (initrd.len != 0) return error.Busy;

    const dentry = try vfs.tmpfs.createDirectory(
        "/", undefined, .{ .perm = @intFromEnum(vfs.Permissions.rw) }
    );
    dentry.ops = &fs.dentry_ops;
    errdefer dentry.deref();

    initrd = boot.getInitrd();
    try populate(dentry);

    log.info("initrd size: 0x{x}", .{initrd.len});
    return .{ .root = dentry };
}

fn populate(root: *vfs.Dentry) vfs.Error!void {
    var file_name: [max_name]u8 = .{ 0 } ** max_name;
    var link_name: [max_name]u8 = .{ 0 } ** max_name;

    var reader = getStream();
    var tar_iter = tar.Iterator.init(&reader, .{
        .file_name_buffer = &file_name,
        .link_name_buffer = &link_name
    });

    const ctx: vfs.Context.Handle = .{ .ptr = .{ .root = root }, .tag = .root };

    var i: u32 = 0;
    while (tar_iter.next() catch |err| blk: {
        if (err == error.TarHeader) break :blk null;
        return;
    }) |entry| : (i += 1) {
        var name_iter = std.mem.splitBackwardsScalar(u8, entry.name, '/');
        const entry_name = name_iter.first();

        const parent = rootLookup(root, name_iter.rest()) orelse {
            log.warn("skip entry: '{s}'", .{entry.name});
            continue;
        };
        const dentry = switch (entry.kind) {
            .directory => try tmpfs.createDirectory(entry_name, ctx, .{ .uid = 0, .gid = 0, .perm = @intCast(entry.mode) }),
            .file => try tmpfs.createRegularFile(entry_name, ctx, .{ .uid = 0, .gid = 0, .perm = @intCast(entry.mode) }),
            else => continue,
        };

        dentry.ops = &fs.dentry_ops;
        dentry.inode.index = i;
        dentry.inode.size = entry.size;
        dentry.inode.fs_data = .from(tar_iter.reader.seek);

        parent.addChild(dentry);
    }
}

fn rootLookup(root: *vfs.Dentry, path: []const u8) ?*vfs.Dentry {
    var iter = std.mem.splitScalar(u8, path, '/');
    var parent = root;
    while (iter.next()) |name| {
        if (name.len == 0) break;

        const child = tmpfs.DentryOps.lookup(parent, name);
        parent = child orelse return null;
    }

    return parent;
}

fn dentryOpen(_: *const vfs.Dentry, file: *vfs.File) vfs.Error!void {
    if (file.dentry.ops == &fs.dentry_ops) {
        file.ops = &file_ops.ops;
    } else {
        file.ops = &tmpfs.file_ops.ops;
    }
}

fn dentryCreateFile(parent: *const vfs.Dentry, child: *vfs.Dentry, opts: vfs.CreateOptions) vfs.Error!void {
    try tmpfs.DentryOps.createFile(parent, child, opts);
    child.ops = tmpfs.dentry_ops;
}

fn dentryMakeDirectory(parent: *const vfs.Dentry, child: *vfs.Dentry, opts: vfs.CreateOptions) vfs.Error!void {
    try tmpfs.DentryOps.makeDirectory(parent, child, opts);
    child.ops = tmpfs.dentry_ops;
}

fn fileReadCacheBlock(dentry: *const vfs.Dentry, block: *vm.cache.Block) vfs.Error!void {
    const inode = dentry.inode;
    const data_offset = inode.fs_data.as(usize);

    const offset = block.getOffset();
    const end = @min(inode.size, offset + block.size.toBytes());
    const len = end - offset;

    @memcpy(block.asSlice()[0..len], initrd[data_offset..][offset..end]);
}
