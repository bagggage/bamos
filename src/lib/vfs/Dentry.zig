//! # Directory Entry

// Copyright (C) 2024-2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const bindings = @import("../bindings.zig");
const Context = vfs.Context;
const CreateOptions = vfs.CreateOptions;
const Error = vfs.Error;
const File = vfs.File;
const FileSystem = vfs.FileSystem;
const Inode = vfs.Inode;
const lib = @import("../lib.zig");
const log = std.log.scoped(.@"vfs.Dentry");
const lookup_cache = vfs.lookup_cache;
const MountPoint = vfs.MountPoint;
const Path = vfs.Path;
const Superblock = vfs.Superblock;
const sys = @import("../sys.zig");
const vfs = @import("../vfs.zig");
const vm = @import("../vm.zig");

const Dentry = @This();

const LruList = std.DoublyLinkedList;
const LruNode = LruList.Node;

pub const List = std.SinglyLinkedList;
pub const Node = List.Node;

pub const Operations = struct {
    const default = vfs.internals.dentry_ops.debug;

    pub const LookupFn = *const fn(*const Dentry, []const u8) ?*Dentry;
    pub const IterateFn = *const fn (*const Dentry, *Iterator) Error!void;
    pub const MakeDirectoryFn = *const fn(*const Dentry, *Dentry, CreateOptions) Error!void;
    pub const CreateFileFn = *const fn(*const Dentry, *Dentry, CreateOptions) Error!void;
    pub const DeinitInodeFn = *const fn(*const Inode) void;

    pub const OpenFn = *const fn(*const Dentry, *File) Error!void;
    pub const CloseFn = *const fn(*const Dentry, *File) void;

    lookup: LookupFn = &default.lookup,
    iterate: IterateFn = &default.iterate,
    makeDirectory: MakeDirectoryFn = &default.makeDirectory,
    createFile: CreateFileFn = &default.createFile,
    deinitInode: DeinitInodeFn = &default.deinitInode,

    open: OpenFn = &default.open,
    close: CloseFn = &default.close,
};

pub const Name = struct {
    pub const Union = union {
        const short_len = 31;

        short: [short_len:0]u8,
        long: [*]u8,
    };

    value: Union = undefined,
    len: u8 = 0,

    pub inline fn init(name: []const u8) vm.Error!Name {
        return bindings.getInstance().vfs.dentry.initName(name);
    }

    pub inline fn deinit(self: *Name) void {
        if (self.len >= Union.short_len) vm.gpa.free(self.value.long);
    }

    pub inline fn str(self: *const Name) []const u8 {
        return if (self.len >= Union.short_len)
            self.value.long[0..self.len] else
            self.value.short[0..self.len];
    }
};

pub const Meta = packed struct {
    fs: Context.Tag = .none,
    dangling: bool = false,
};

/// Dentries iterator, used as an interface between the kernel
/// and file-system drivers to implement directory reading.
pub const Iterator = struct {
    pub const FillFn = *const fn(
        *Iterator, name: []const u8, inode: usize, @"type": Inode.Type
    ) bool;

    callback: FillFn,
    pos: usize = 0,

    pub inline fn fillNext(self: *Iterator, name: []const u8, inode: usize, @"type": Inode.Type) bool {
        return self.callback(self, name, inode, @"type");
    }
};

pub const alloc_config: vm.auto.Config = .{
    .allocator = .oma,
    .capacity = 1024,
};

name: Name,

parent: *Dentry,
ctx: Context.Ptr,
inode: *Inode,
ops: *const Operations = &Operations.default.ops,

child: List = .{},

node: Node = .{},
lru_node: LruNode = .{},

cache_ent: lookup_cache.Entry = .{},
meta: Meta = .{},
in_lru: std.atomic.Value(bool) = .init(false),

ref_count: lib.atomic.RefCount(u32) = .{},
lock: lib.sync.Spinlock = .{},

pub fn new() ?*Dentry {
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

pub fn getMountPoint(self: *const Dentry) *MountPoint {
    return switch (self.meta.fs) {
        .virt  => self.getVirtualCtx().getMountPoint(),
        .super => self.getSuper().mount_point,
        .root  => self.ctx.root.getMountPoint(),
        .none  => @panic("bad dentry context!"),
    };
}

pub inline fn getFileSystem(self: *const Dentry) *FileSystem {
    return self.getMountPoint().fs;
}

pub inline fn getContext(self: *const Dentry) Context.Handle {
    return .{ .ptr = self.ctx, .tag = self.meta.fs };
}

pub inline fn getSuper(self: *const Dentry) *Superblock {
    return self.ctx.super;
}

pub inline fn getVirtualCtx(self: *const Dentry) *Context.Virt {
    return self.ctx.virt;
}

pub fn setup(
    self: *Dentry, name: []const u8,
    ctx: Context.Handle, inode: *Inode, ops: *Operations
) !void {
    const dent_name: Name = try .init(name);
    inode.ref();

    self.* = .{
        .name = dent_name,
        .parent = self,
        .ctx = ctx.ptr,
        .meta = .{ .fs = ctx.tag },
        .inode = inode,
        .ops = ops
    };
}

pub inline fn deinit(self: *Dentry) void {
    bindings.getInstance().vfs.dentry.deinit(self);
}

pub inline fn delete(self: *Dentry) void {
    self.deinit();
    self.free();
}

pub inline fn lookup(self: *Dentry, child_name: []const u8) ?*Dentry {
    return bindings.getInstance().vfs.dentry.lookup(self, child_name);
}

pub inline fn iterate(self: *const Dentry, iter: *Iterator) Error!void {
    if (self.inode.type != .directory) return error.NotDirectory;
    return self.ops.iterate(self, iter);
}

pub inline fn makeDirectory(self: *Dentry, name: []const u8, opts: CreateOptions) Error!*Dentry {
    return bindings.getInstance().vfs.makeDirectory(self, name, opts);
}

pub inline fn createFile(self: *Dentry, name: []const u8, opts: CreateOptions) Error!*Dentry {
    return bindings.getInstance().vfs.createFile(self, name, opts);
}

pub inline fn open(self: *Dentry, perm: vfs.Permissions) Error!*File {
    return bindings.getInstance().vfs.dentry.open(self, perm);
}

pub inline fn onClose(self: *Dentry, file: *File) void {
    return bindings.getInstance().vfs.dentry.onClose(self, file);
}

pub inline fn addChild(self: *Dentry, child: *Dentry) void {
    bindings.getInstance().vfs.dentry.addChild(self, child);
}

pub inline fn removeChild(self: *Dentry, child: *Dentry) void {
    bindings.getInstance().vfs.dentry.removeChild(self, child);
}

/// Remove inode associated with the dentry.
/// Number of hardlinks should be 0.
pub fn remove(self: *Dentry) Error!void {
    // FIXME: Implement.

    self.lock.lock();
    defer self.lock.unlock();

    return error.BadOperation;
}

pub fn unlink(self: *Dentry) Error!void {
    // FIXME: Implement.

    self.inode.lock.lock();
    defer self.inode.lock.unlock();

    return error.BadOperation;
}

pub inline fn touch(self: *Dentry, access: sys.time.Time, modify: ?sys.time.Time) Error!void {
    return bindings.getInstance().vfs.dentry.touch(self, access, modify);
}

pub inline fn path(self: *const Dentry) Path {
    return .{ .dentry = self, .root = vfs.getRootWeak() };
}

pub inline fn relativePath(self: *const Dentry, root: *const Dentry) Path {
    return .{ .dentry = self, .root = root };
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
    return bindings.getInstance().vfs.dentry.deref(self);
}
