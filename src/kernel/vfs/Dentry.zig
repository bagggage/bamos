//! # Directory Entry

// Copyright (C) 2024-2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const Context = vfs.Context;
const Error = vfs.Error;
const File = vfs.File;
const Inode = vfs.Inode;
const lib = @import("../lib.zig");
const log = std.log.scoped(.@"vfs.Dentry");
const lookup_cache = vfs.lookup_cache;
const Path = vfs.Path;
const Superblock = vfs.Superblock;
const vfs = @import("../vfs.zig");
const vm = @import("../vm.zig");

const Dentry = @This();

pub const List = std.SinglyLinkedList;
pub const Node = List.Node;

pub const Operations = struct {
    const default = vfs.internals.dentry_ops.debug;

    pub const LookupFn = *const fn(*const Dentry, []const u8) ?*Dentry;
    pub const MakeDirectoryFn = *const fn(*const Dentry, *Dentry) Error!void;
    pub const CreateFileFn = *const fn(*const Dentry, *Dentry) Error!void;
    pub const DeinitInodeFn = *const fn(*const Inode) void;

    pub const OpenFn = *const fn(*const Dentry, *File) Error!void;
    pub const CloseFn = *const fn(*const Dentry, *File) void;

    lookup: LookupFn = &default.lookup,
    makeDirectory: MakeDirectoryFn = &default.makeDirectory,
    createFile: CreateFileFn = &default.createFile,
    deinitInode: DeinitInodeFn = &default.deinitInode,

    open: OpenFn = &default.open,
    close: CloseFn = &default.close,
};

pub const Name = struct {
    pub const Union = union {
        const short_len = 32;

        short: [short_len:0]u8,
        long: [*]u8,
    };

    value: Union = undefined,
    len: u8 = 0,

    pub fn init(name: []const u8) !Name {
        var self: Name = .{};
        if (name.len < Union.short_len) {
            self.value = .{ .short = undefined };

            @memcpy(self.value.short[0..name.len], name);
            self.value.short[name.len] = 0;
        }
        else {
            const buffer: [*]u8 = @ptrCast(vm.malloc(name.len) orelse return error.NoMemory);
            @memcpy(buffer[0..name.len], name);

            self.value = .{ .long = buffer };
        }

        self.len = @truncate(name.len);
        return self;
    }

    pub fn move(self: *Name, other: *Name) void {
        std.debug.assert(other.len == 0);

        if (self.len >= Union.short_len) {
            other.value = .{ .long = self.value.long };
        } else {
            other.value = .{ .short = undefined };
            @memcpy(
                other.value.short[0..self.len + 1],
                self.value.short[0..self.len + 1]
            );
        }

        other.len = self.len;
    }

    pub fn deinit(self: *Name) void {
        if (self.len >= Union.short_len) vm.free(self.value.long);
    }

    pub inline fn str(self: *const Name) []const u8 {
        return if (self.len >= Union.short_len)
            self.value.long[0..self.len] else
            self.value.short[0..self.len];
    }
};

name: Name,

parent: *Dentry,
ctx: Context.Ptr,
inode: *Inode,
ops: *const Operations = &Operations.default.ops,

child: List = .{},
node: Node = .{},

cache_ent: lookup_cache.Entry = .{},

ref_count: lib.atomic.RefCount(u32) = .{},
lock: lib.sync.Spinlock = .{},

pub const alloc_config: vm.auto.Config = .{
    .allocator = .oma,
    .capacity = 512
};

pub inline fn new() ?*Dentry {
    const dentry = vm.auto.alloc(Dentry) orelse return null;
    dentry.* = .{
        .name = undefined,
        .parent = undefined,
        .ctx = undefined,
        .inode = undefined,
    };

    return dentry;
}

pub inline fn free(self: *Dentry) void {
    vm.auto.free(Dentry, self);
}

pub inline fn fromNode(node: *Node) *Dentry {
    return @fieldParentPtr("node", node);
}

pub inline fn fromCache(entry: *lookup_cache.Entry) *Dentry {
    return @fieldParentPtr("cache_ent", entry);
}

pub inline fn getSuper(self: *Dentry) *Superblock {
    return self.ctx.super;
}

pub inline fn getVirtualCtx(self: *Dentry) *Context.Virt {
    return self.ctx.virt;
}

pub fn setup(
    self: *Dentry, name: []const u8,
    ctx: Context.Ptr, inode: *Inode, ops: *Operations
) !void {
    const dent_name: Name = try .init(name);
    inode.ref();

    self.* = .{
        .name = dent_name,
        .parent = self,
        .ctx = ctx,
        .inode = inode,
        .ops = ops
    };
}

pub fn deinit(self: *Dentry) void {
    std.debug.assert(self.ref_count.count() == 0);

    _ = lookup_cache.uncache(self);

    if (self.parent != self) self.parent.removeChild(self);

    if (self.inode.deref()) {
        self.ops.deinitInode(self.inode);
        self.inode.free();
    }

    self.name.deinit();
}

pub fn delete(self: *Dentry) void {
    self.deinit();
    self.free();
}

pub fn lookup(self: *Dentry, child_name: []const u8) ?*Dentry {
    std.debug.assert(self.inode.type == .directory);

    const hash = lookup_cache.calcHash(self, child_name);
    const child = lookup_cache.get(hash);

    if (child == null) {
        const new_child = self.ops.lookup(self, child_name) orelse return null;
        new_child.ref();

        if (new_child.parent != self) self.addChild(new_child);

        log.debug("new: {s}: inode: {}", .{new_child.name.str(), new_child.inode.index});

        lookup_cache.insert(hash, new_child);
        return new_child;
    }

    return child;
}

pub fn makeDirectory(self: *Dentry, name: []const u8) Error!*Dentry {
    const dir_dentry = try self.createLike(name);
    errdefer { dir_dentry.name.deinit(); dir_dentry.free(); }

    try self.ops.makeDirectory(self, dir_dentry);
    self.addChild(dir_dentry);
    dir_dentry.ref();

    return dir_dentry;
}

pub fn createFile(self: *Dentry, name: []const u8) Error!*Dentry {
    const file_dentry = try self.createLike(name);
    errdefer { file_dentry.name.deinit(); file_dentry.free(); }

    try self.ops.createFile(self, file_dentry);
    self.addChild(file_dentry);
    file_dentry.ref();

    return file_dentry;
}

pub fn open(self: *Dentry, perm: vfs.Permissions) Error!*File {
    self.ref();
    errdefer self.deref();

    const file = vm.auto.alloc(File) orelse return error.NoMemory;
    file.* = .{
        .dentry = self,
        .perm = perm
    };

    try self.ops.open(self, file);
    return file;
}

pub fn onClose(self: *Dentry, file: *File) void {
    std.debug.assert(file.dentry == self and file.ref_count.count() == 0);

    self.ops.close(self, file);
    self.deref();
    vm.auto.free(File, file);
}

pub fn addChild(self: *Dentry, child: *Dentry) void {
    self.ref();

    child.parent = self;
    self.child.prepend(&child.node);
}

pub fn removeChild(self: *Dentry, child: *Dentry) void {
    child.parent = child;

    if (self.ref_count.put()) {
        self.delete();
    } else {
        self.child.remove(&child.node);
    }
}

pub inline fn path(self: *const Dentry) Path {
    return .{ .dentry = self };
}

pub inline fn assignInode(self: *Dentry, inode: *Inode) void {
    inode.ref();
    self.inode = inode;
}

pub inline fn releaseInode(self: *Dentry) void {
    self.inode.deref();
}

pub inline fn ref(self: *Dentry) void {
    self.ref_count.inc();
}

pub inline fn deref(self: *Dentry) void {
    if (self.ref_count.put()) self.delete();
}

fn createLike(self: *const Dentry, name: []const u8) !*Dentry {
    const dentry = Dentry.new() orelse return error.NoMemory;
    errdefer dentry.free();

    dentry.name = try .init(name);
    dentry.ctx = self.ctx;
    dentry.ops = self.ops;

    return dentry;
}
