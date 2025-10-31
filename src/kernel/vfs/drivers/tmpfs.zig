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

pub const DentryOps = opaque {
    pub const lookup = dentryLookup;
    pub const makeDirectory = dentryMakeDirectory;
    pub const createFile = dentryCreateFile;
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
    },
);

pub fn init() !void {
    if (vfs.registerFs(&fs) == false) return error.Busy;
}

pub fn deinit() void {
    vfs.unregisterFs(&fs);
}

fn mount() vfs.Error!vfs.Context.Virt {
    const root = try createDirectory("/", undefined);
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
    child.assignInode(inode);
}

fn dentryCreateFile(_: *const vfs.Dentry, child: *vfs.Dentry) vfs.Error!void {
    const inode = try createInode(.regular_file);
    child.assignInode(inode);
}

pub fn createRegularFile(name: []const u8, ctx: vfs.Context.Ptr) !*vfs.Dentry {
    const file = File.new() orelse return error.NoMemory;
    errdefer file.free();
    const inode = try createInode(.regular_file);
    errdefer inode.free();

    const dentry = try createDentry(name, inode, ctx);
    inode.fs_data.set(file);

    return dentry;
}

pub inline fn createDirectory(name: []const u8, ctx: vfs.Context.Ptr) !*vfs.Dentry {
    const inode = try createInode(.directory);
    errdefer inode.free();

    const dentry = try createDentry(name, inode, ctx);
    return dentry;
}

pub fn createDentry(
    name: []const u8, inode: *vfs.Inode,
    ctx: vfs.Context.Ptr
) !*vfs.Dentry {
    const dentry = vfs.Dentry.new() orelse return error.NoMemory;
    errdefer dentry.free();

    try dentry.setup(name, ctx, inode, &fs.dentry_ops);
    // Prevent auto-freeing dentry
    dentry.ref();
    return dentry;
}

pub fn createInode(kind: vfs.Inode.Type) !*vfs.Inode {
    const inode = vfs.Inode.new() orelse return error.NoMemory;
    errdefer inode.free();

    const time = vfs.getTime().posix();
    inode.* = .{
        .index = 0,
        .type = kind,
        .access_time = @intCast(time),
        .create_time = @intCast(time),
        .modify_time = @intCast(time)
    };

    return inode;
}

fn deinitInode(inode: *const vfs.Inode) void {
    if (inode.type == .regular_file) {
        const file = inode.fs_data.as(File).?;
        file.delete();
    }
}