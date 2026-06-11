//! # Temporary memory-based filesystem
//! 
//! This is a simple memory-based temporary file system.
//! Its primary purpose is to serve as the root file system during the boot process.
//! It provides flexibility and allows for the temporary mounting of other file systems.
//! Ultimately, it facilitates the mounting of the main root file system, replacing the current one.
//! 
//! It can also be mounted during regular operation; however,
//! any data written to it is not preserved and remains in RAM only until it is unmounted.

// Copyright (C) 2024-2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const log = std.log.scoped(.tmpfs);
const vfs = @import("../../vfs.zig");
const vm = @import("../../vm.zig");

const EntryKind = enum {
    directory,
    file
};

const File = struct {
    const Page = struct {
        const List = std.SinglyLinkedList;
        const Node = List.Node;

        base: u32,
        node: Node = .{},
    };

    pub const alloc_config: vm.auto.Config = .{
        .allocator = .oma,
        .capacity = 128
    };

    page_list: Page.List = .{},

    pub fn deinit(_: *File) void {}

    pub fn delete(self: *File) void {
        self.deinit();
        vm.auto.free(File, self);
    }
};

pub const DentryOps = opaque {
    pub const lookup = dentryLookup;
    pub const iterate = dentryIterate;
    pub const makeDirectory = dentryMakeDirectory;
    pub const createFile = dentryCreateFile;
};

pub const dentry_ops = &fs.dentry_ops;
pub const file_ops = vfs.internals.file.Cached {
    .readCacheBlock = &fileReadCacheBlock,
};

var fs = vfs.FileSystem.init(
    "tmpfs",
    .{ .virt = .{
        .mount = mount,
        .unmount = undefined
    }},
    .{
        .open = dentryOpen,
        .lookup = dentryLookup,
        .iterate = dentryIterate,
        .makeDirectory = dentryMakeDirectory,
        .createFile = dentryCreateFile,
        .deinitInode = deinitInode,
    },
);

pub fn init() !void {
    if (vfs.registerFs(&fs) == false) return error.Busy;
}

pub fn deinit() void {
    vfs.unregisterFs(&fs);
}

fn mount() vfs.Error!vfs.Context.Virt {
    const root = try createDirectory("/", undefined, .{
        .uid = 0,
        .gid = 0,
        .perm = @intFromEnum(vfs.Permissions.rw)
    });
    return .{ .root = root };
}

fn dentryOpen(_: *const vfs.Dentry, file: *vfs.File) vfs.Error!void {
    file.ops = &file_ops.ops;
}

fn dentryLookup(parent: *const vfs.Dentry, name: []const u8) ?*vfs.Dentry {
    var node = parent.child.first;
    while (node) |n| : (node = n.next) {
        const dentry = vfs.Dentry.fromNode(n);
        if (std.mem.eql(u8, dentry.name.str(), name)) return dentry;
    }

    return null;
}

fn dentryIterate(dentry: *const vfs.Dentry, iter: *vfs.Dentry.Iterator) vfs.Error!void {
    var node = dentry.child.first;
    for (0..iter.pos) |_| {
        if (node) |n| {
            @branchHint(.likely);
            node = n.next;
        }

        return;
    }

    while (node) |n| : ({ node = n.next; iter.pos += 1; }) {
        const child = vfs.Dentry.fromNode(n);
        if (!iter.fillNext(
            child.name.str(), child.inode.index, child.inode.type
        )) {
            @branchHint(.unlikely);
            return;
        }
    }
}

fn dentryMakeDirectory(_: *const vfs.Dentry, child: *vfs.Dentry, opts: vfs.CreateOptions) vfs.Error!void {
    const inode = try createInode(.directory, opts);
    child.assignInode(inode);
    // Prevent auto-freeing
    child.ref();
}

fn dentryCreateFile(_: *const vfs.Dentry, child: *vfs.Dentry, opts: vfs.CreateOptions) vfs.Error!void {
    const inode = try createInode(.regular_file, opts);
    child.assignInode(inode);
    // Prevent auto-freeing
    child.ref();
}

fn fileReadCacheBlock(_: *const vfs.Dentry, block: *vm.cache.Block) vfs.Error!void {
    @memset(block.asSlice(), 0);
}

pub fn createRegularFile(name: []const u8, ctx: vfs.Context.Handle, opts: vfs.CreateOptions) !*vfs.Dentry {
    const inode = try createInode(.regular_file, opts);
    errdefer inode.free();

    const dentry = try createDentry(name, inode, ctx);
    return dentry;
}

pub inline fn createDirectory(name: []const u8, ctx: vfs.Context.Handle, opts: vfs.CreateOptions) !*vfs.Dentry {
    const inode = try createInode(.directory, opts);
    errdefer inode.free();

    const dentry = try createDentry(name, inode, ctx);
    return dentry;
}

pub fn createDentry(
    name: []const u8, inode: *vfs.Inode,
    ctx: vfs.Context.Handle
) !*vfs.Dentry {
    const dentry = vfs.Dentry.new() orelse return error.NoMemory;
    errdefer dentry.free();

    try dentry.setup(name, ctx, inode, &fs.dentry_ops);
    // Prevent auto-freeing dentry
    dentry.ref();
    return dentry;
}

pub fn createInode(kind: vfs.Inode.Type, opts: vfs.CreateOptions) !*vfs.Inode {
    const inode = vfs.Inode.new() orelse return error.NoMemory;
    errdefer inode.free();

    const time = vfs.getTime().posix();
    inode.* = .{
        .index = 0,
        .type = kind,
        .cache_ctrl = .{ .write_back = &vfs.internals.cache.noWriteBack },
        .access_time = @intCast(time),
        .create_time = @intCast(time),
        .modify_time = @intCast(time),
        .gid = opts.gid,
        .uid = opts.uid,
        .perm = opts.perm
    };

    return inode;
}

fn deinitInode(inode: *const vfs.Inode) void {
    if (inode.type == .regular_file) {
        const file = inode.fs_data.asPtr(File).?;
        file.delete();
    }
}
