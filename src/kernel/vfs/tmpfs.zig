//! # Temporary memory-based filesystem
//! 
//! This is a simple memory-based temporary file system.
//! Its primary purpose is to serve as the root file system during the boot process.
//! It provides flexibility and allows for the temporary mounting of other file systems.
//! Ultimately, it facilitates the mounting of the main root file system, replacing the current one.
//! 
//! It can also be mounted during regular operation; however,
//! any data written to it is not preserved and remains in RAM only until it is unmounted.

const std = @import("std");

const log = std.log.scoped(.tmpfs);
const utils = @import("../utils.zig");
const vfs = @import("../vfs.zig");
const vm = @import("../vm.zig");

const max_name_len = 64;
const oma_capacity = 128;

const Entry = struct {
    const Kind = enum {
        directory,
        file
    };

    const List = utils.SList(Entry);
    const Node = List.Node;

    const Directory = struct {
        const Self = @This();

        childs: List = .{},

        pub fn deinit(self: *Directory) void {
            var node = self.childs.first;

            while (node) |n| : (node = n.next) {
                n.data.deinit();
                n.data.delete();
            }
        }

        pub fn lookup(self: *const Self, name: []const u8) ?*Entry {
            var node = self.childs.first;

            while (node) |n| : (node = n.next) {
                if (std.mem.eql(u8, n.data.getName(), name)) return &n.data;
            }

            return null;
        }
    };

    const File = struct {
        const PageList = utils.SList(u32);

        pub fn deinit(self: *File) void {
            _ = self;
        }
    };

    pub var oma = vm.SafeOma(Node).init(oma_capacity);

    name_buf: [max_name_len]u8 = undefined,
    name_len: u8 = 0,

    data: union(Kind) {
        directory: Directory,
        file: File,
    },

    pub inline fn deinit(self: *Entry) void {
        switch (self.data) {
            .directory => |*dir| dir.deinit(),
            .file => |*file| file.deinit()
        }
    }

    pub fn rename(self: *Entry, name: []const u8) !void {
        if (name.len > max_name_len) return error.InvalidArgs;

        @memcpy(self.name_buf[0..name.len], name);
        self.name_len = @truncate(name.len);
    }

    pub inline fn getName(self: *const Entry) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    pub inline fn getNode(self: *Entry) *Node {
        return @fieldParentPtr("data", self);
    }

    pub inline fn new() ?*Entry {
        return &(oma.alloc() orelse return null).data;
    }

    pub inline fn delete(self: *Entry) void {
        oma.free(self.getNode());
    }
};

var fs = vfs.FileSystem.init(
    "tmpfs",
    .virtual,
    .{
        .mount = mount,
        .unmount = undefined
    },
    .{
        .lookup = dentryLookup,
        .makeDirectory = dentryMakeDirectory,
        .createFile = dentryCreateFile,
    }
);

pub fn init() !void {
    if (vfs.registerFs(&fs) == false) return error.Busy;
}

pub fn deinit() void {
    vfs.unregisterFs(&fs);
}

fn mount(_: *vfs.Drive, _: *const vfs.Partition) vfs.Error!*vfs.Superblock {
    const super = vfs.Superblock.new() orelse return error.NoMemory;
    errdefer super.delete();

    const root = try createEntry("/", .directory);
    errdefer deleteEntry(root);

    const dentry = try createDentry(super, root);

    super.init(null, null, vm.page_size * 4, null);
    super.root = dentry;

    return super;
}

fn dentryLookup(parent: *const vfs.Dentry, name: []const u8) ?*vfs.Dentry {
    const inode = parent.inode;
    const directory = &inode.fs_data.as(Entry).?.data.directory;

    const child = directory.lookup(name) orelse return null;

    return createDentry(parent.super, child) catch return null;
}

fn dentryMakeDirectory(parent: *const vfs.Dentry, child: *vfs.Dentry) vfs.Error!void {
    return dentryCreateEntry(parent, child, .directory);
}

fn dentryCreateFile(parent: *const vfs.Dentry, child: *vfs.Dentry) vfs.Error!void {
    return dentryCreateEntry(parent, child, .file);
}

fn dentryCreateEntry(parent: *const vfs.Dentry, child: *vfs.Dentry, comptime kind: Entry.Kind) vfs.Error!void {
    const dir = parent.inode.fs_data.as(Entry).?;

    const entry = try createEntry(child.name.str(), kind);
    errdefer entry.delete();

    const inode = try createInode(entry);

    dir.data.directory.childs.prepend(entry.getNode());
    child.inode = inode;
}

fn createDentry(super: *vfs.Superblock, entry: *const Entry) !*vfs.Dentry {
    const dentry = vfs.Dentry.new() orelse return error.NoMemory;
    errdefer dentry.delete();

    const inode = try createInode(entry);
    errdefer inode.delete();

    try dentry.init(entry.getName(), super, inode, &fs.data.dentry_ops);

    return dentry;
}

fn createInode(entry: *const Entry) !*vfs.Inode {
    const inode = vfs.Inode.new() orelse return error.NoMemory;
    errdefer inode.delete();

    @memset(std.mem.asBytes(inode), 0);

    inode.links_num = 1;
    inode.fs_data.set(@constCast(entry));
    inode.type = switch (entry.data) {
        .directory => .directory,
        .file => .regular_file
    };

    return inode;
}

fn createEntry(name: []const u8, comptime kind: Entry.Kind) !*Entry {
    const entry: *Entry = Entry.new() orelse return error.NoMemory;
    errdefer entry.delete();

    entry.* = .{
        .data = switch (kind) {
            .directory => .{ .directory = .{} },
            .file => .{ .file = .{} }
        }
    };
    try entry.rename(name);

    return entry;
}

inline fn deleteEntry(entry: *Entry) void {
    entry.deinit();
    entry.delete();
}