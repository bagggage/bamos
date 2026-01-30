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
        .lookup = dentryLookup,

        .createFile = dentryCreateFile,
        .makeDirectory = dentryMakeDirectory,
    }
);

var initrd: []const u8 = &.{};

var file_name: [max_name]u8 = .{ 0 } ** max_name;
var link_name: [max_name]u8 = .{ 0 } ** max_name;

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

    const dentry = try vfs.tmpfs.createDirectory("/", undefined);
    dentry.ops = &fs.dentry_ops;

    initrd = boot.getInitrd();

    log.debug("initrd size: 0x{x}", .{initrd.len});
    return .{ .root = dentry };
}

fn dentryOpen(_: *const vfs.Dentry, file: *vfs.File) vfs.Error!void {
    file.ops = &file_ops.ops;
}

fn dentryLookup(parent: *const vfs.Dentry, name: []const u8) ?*vfs.Dentry {
    const offset = @intFromPtr(parent.inode.fs_data.ptr);

    var reader = getStream();
    reader.seek = offset;

    var tar_iter = tar.Iterator.init(&reader, .{
        .file_name_buffer = &file_name,
        .link_name_buffer = &link_name
    });

    return tarLookup(&tar_iter, parent, name) catch |err| {
        log.err("while parsing tar: {s}", .{@errorName(err)});
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
    if (tmpfs.DentryOps.lookup(parent, name)) |child| return child;

    var i: u32 = 0;
    while (try tar_iter.next()) |file| : (i += 1) {
        var name_iter = std.mem.splitBackwardsScalar(u8, file.name, '/');
        const entry_name = name_iter.first();
        const parent_name: []const u8 = name_iter.next() orelse &.{};

        if (
            !is_parent_root and
            !std.mem.eql(u8, parent_name_str, parent_name)
        ) break;

        if (std.mem.eql(u8, entry_name, name)) {
            // Init new dentry
            const dentry = vfs.Dentry.new() orelse return error.NoMemory;
            errdefer dentry.free();

            const inode = vfs.Inode.new() orelse return error.NoMemory;
            errdefer inode.free();

            setupInode(inode, &file, i, tar_iter.reader.seek);
            try dentry.setup(entry_name, parent.ctx, inode, &fs.dentry_ops);

            return dentry;
        }
    }

    return null;
}

fn setupInode(inode: *vfs.Inode, file: *const TarFile, idx: u32, pos: usize) void {
    inode.* = .{
        .index = idx,

        .type = switch (file.kind) {
            .directory => .directory,
            .file => .regular_file,
            .sym_link => .symbolic_link
        },
        .perm = @intCast(file.mode),
        .size = file.size,
        .cache_ctrl = .{ .write_back = &vfs.internals.cache.noWriteBack },

        // Data pointer
        .fs_data = .from(pos),
    };
}

fn dentryCreateFile(parent: *const vfs.Dentry, child: *vfs.Dentry) vfs.Error!void {
    try tmpfs.DentryOps.createFile(parent, child);
    child.ops = tmpfs.dentry_ops;
}

fn dentryMakeDirectory(parent: *const vfs.Dentry, child: *vfs.Dentry) vfs.Error!void {
    try tmpfs.DentryOps.makeDirectory(parent, child);
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
