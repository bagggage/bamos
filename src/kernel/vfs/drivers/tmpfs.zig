//! # Temporary memory-based filesystem
//! 
//! This is a simple memory-based temporary file system.
//! Its primary purpose is to serve as the root file system during the boot process.
//! It provides flexibility and allows for the temporary mounting of other file systems.
//! Ultimately, it facilitates the mounting of the main root file system, replacing the current one.
//! 
//! It can also be mounted during regular operation; however,
//! any data written to it is not preserved and remains in RAM only until it is unmounted.

// Copyright (C) 2024 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const log = std.log.scoped(.tmpfs);
const utils = @import("../../utils.zig");
const vfs = @import("../../vfs.zig");
const vm = @import("../../vm.zig");

const oma_capacity = 128;

const EntryKind = enum {
    directory,
    file
};

const File = struct {
    const PageList = utils.SList(u32);

    var oma = vm.SafeOma(File).init(oma_capacity);

    page_list: PageList = .{},

    pub inline fn new() ?*File {
        return oma.alloc();
    }

    pub inline fn free(self: *File) void {
        oma.free(self);
    }

    pub fn deinit(_: *File) void {}

    pub fn delete(self: *File) void {
        self.deinit();
        self.free();
    }
};

var fs = vfs.FileSystem.init(
    "tmpfs",
    .{ .virt = .{
        .mount = mount,
        .unmount = undefined
    }},
    .{
        .lookup = dentryLookup,
        .makeDirectory = dentryMakeDirectory,
        .createFile = dentryCreateFile,
        .deinitInode = deinitInode,

        .read = undefined,
        .write = undefined
    }
);

pub fn init() !void {
    if (vfs.registerFs(&fs) == false) return error.Busy;
}

pub fn deinit() void {
    vfs.unregisterFs(&fs);
}

fn mount() vfs.Error!vfs.Context.Virt {
    const root = try createDentry(undefined, "/", .directory);
    return .{ .root = root };
}

fn dentryLookup(parent: *const vfs.Dentry, name: []const u8) ?*vfs.Dentry {
    var node = parent.child.first;

    while (node) |n| : (node = n.next) {
        if (std.mem.eql(u8, n.data.name.str(), name)) return &n.data;
    }

    return null;
}

fn dentryMakeDirectory(_: *const vfs.Dentry, child: *vfs.Dentry) vfs.Error!void {
    const inode = try createInode(.directory);
    child.inode = inode;
}

fn dentryCreateFile(_: *const vfs.Dentry, child: *vfs.Dentry) vfs.Error!void {
    const inode = try createInode(.file);
    child.inode = inode;
}

fn createDentry(ctx: vfs.Context.Ptr, name: []const u8, comptime kind: EntryKind) !*vfs.Dentry {
    const dentry = vfs.Dentry.new() orelse return error.NoMemory;
    errdefer dentry.free();

    const inode = try createInode(kind);
    errdefer inode.free();

    try dentry.init(name, ctx, inode, &fs.data.dentry_ops);

    // Prevent auto-freeing dentry
    dentry.ref();

    return dentry;
}

fn createInode(comptime kind: EntryKind) !*vfs.Inode {
    const inode = vfs.Inode.new() orelse return error.NoMemory;
    errdefer inode.free();

    inode.* = .{
        .index = 0,
        .type = switch (kind) {
            .directory => .directory,
            .file => .regular_file
        },
        .perm = 0
    };

    if (kind == .file) {
        const file = File.new() orelse return error.NoMemory;
        inode.fs_data.set(file);
    }

    return inode;
}

fn deinitInode(inode: *const vfs.Inode) void {
    if (inode.type == .regular_file) {
        const file = inode.fs_data.as(File).?;
        file.delete();
    }
}