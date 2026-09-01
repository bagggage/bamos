//! # Directory Entry

// Copyright (C) 2024-2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

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

    pub const OpenFn = *const fn(*const Dentry, *File) Error!void;
    pub const CloseFn = *const fn(*const Dentry, *File) void;
    pub const LookupFn = *const fn(*const Dentry, []const u8) ?*Dentry;
    pub const IterateFn = *const fn (*const Dentry, *Iterator) Error!void;
    pub const LinkFn = *const fn(*Dentry, *Inode) Error!void;
    pub const UnlinkFn = *const fn(*const Dentry) Error!void;
    pub const ReadLinkFn = *const fn (*const Dentry, []u8) Error!usize;
    pub const UpdateInodeFn = *const fn (*const Inode, Inode.Update) Error!void;
    pub const DeinitInodeFn = *const fn(*const Inode) void;

    open: OpenFn = &default.open,
    close: CloseFn = &default.close,
    lookup: LookupFn = &default.lookup,
    iterate: IterateFn = &default.iterate,
    link: LinkFn = &default.link,
    unlink: UnlinkFn = &default.unlink,
    readLink: ReadLinkFn = &default.readLink,
    updateInode: UpdateInodeFn = &default.updateInode,
    deinitInode: DeinitInodeFn = &default.deinitInode,
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
            const buffer: [*]u8 = @ptrCast(vm.gpa.alloc(name.len) orelse return error.NoMemory);
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
    unlinked: bool = false,
    mount_point: bool = false,
};

/// Dentries iterator, used as an interface between the kernel
/// and file-system drivers to implement directory reading.
pub const Iterator = struct {
    pub const FillFn = *const fn(
        *Iterator, name: []const u8, inode: usize, @"type": Inode.Type
    ) bool;

    callback: FillFn,
    pos: usize = 0,

    pub fn fillNext(self: *Iterator, name: []const u8, inode: usize, @"type": Inode.Type) bool {
        return self.callback(self, name, inode, @"type");
    }
};

pub const alloc_config: vm.auto.Config = .{
    .allocator = .oma,
    .capacity = 1024
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

var lru_list: LruList = .{};
var lru_lock: lib.sync.Spinlock = .{};

pub inline fn new() ?*Dentry {
    const dentry = vm.auto.alloc(Dentry) orelse return null;
    dentry.* = .{
        .name = undefined,
        .parent = dentry,
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
) vm.Error!void {
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

pub fn deinit(self: *Dentry) void {
    std.debug.assert(self.ref_count.count() == 0);

    _ = lookup_cache.tryRemove(self);

    if (self.parent != self) {
        if (!self.meta.unlinked) {
            @branchHint(.likely);
            self.parent.removeChild(self);
        } else {
            self.parent.deref();
            self.parent = self;
        }
    }

    if (self.inode.deref()) {
        self.ops.deinitInode(self.inode);
        self.inode.delete();
    }

    self.name.deinit();
}

pub fn delete(self: *Dentry) void {
    self.deinit();
    self.free();
}

pub fn lookup(self: *Dentry, child_name: []const u8) ?*Dentry {
    std.debug.assert(self.inode.type == .directory);

    const child = lookup_cache.get(self, child_name);
    if (child == null) {
        const new_child = self.ops.lookup(self, child_name) orelse return null;
        new_child.ref();

        if (new_child.parent != self) self.addChild(new_child);
        if (lookup_cache.insert(new_child)) |collision| {
            @branchHint(.cold);

            new_child.ref_count = .{};
            new_child.deinit();

            return collision;
        }

        log.debug("{f}: cached '{s}', inode: {}", .{
            self.path(), new_child.name.str(), new_child.inode.index
        });

        return new_child;
    }

    return child;
}

pub inline fn readLink(self: *const Dentry, buffer: []u8) Error!usize {
    return self.ops.readLink(self, buffer);
}

pub inline fn iterate(self: *const Dentry, iter: *Iterator) Error!void {
    if (self.inode.type != .directory) return error.NotDirectory;
    return self.ops.iterate(self, iter);
}

pub inline fn createFile(self: *Dentry, name: []const u8, @"type": Inode.Type, opts: CreateOptions) Error!*Dentry {
    return self.createFileRaw(name, @"type", opts, .{});
}

pub fn createFileRaw(
    self: *Dentry,
    name: []const u8,
    @"type": Inode.Type,
    opts: CreateOptions,
    fs_data: lib.AnyData,
) Error!*Dentry {
    const inode = Inode.new() orelse return error.NoMemory;
    errdefer inode.delete();

    const time = vfs.getTime();
    inode.* = .{
        .type = @"type",
        .perm = opts.perm,
        .uid = opts.uid,
        .gid = opts.gid,
        .links_num = 0,
        .cache_ctrl = .{ .write_back = self.inode.cache_ctrl.write_back },
        .fs_data = fs_data,
        .access_time_sec = time.sec,
        .modify_time_sec = time.sec,
        .create_time_sec = time.sec,
        .access_time_ns = time.ns,
        .modify_time_ns = time.ns,
        .create_time_ns = time.ns,
    };

    return self.createLink(name, inode);
}

pub fn createLink(self: *Dentry, name: []const u8, inode: *Inode) Error!*Dentry {
    const dentry = try self.createLike(name);
    errdefer { dentry.name.deinit(); dentry.free(); }

    dentry.parent = self;
    dentry.inode = inode;

    {
        const time = vfs.getTime();
        const parent = self.inode;

        inode.rw_sem.writeLock();
        defer inode.rw_sem.writeUnlock();

        inode.access_time_sec = time.sec;
        inode.access_time_ns = time.ns;

        parent.rw_sem.writeLock();
        defer parent.rw_sem.writeUnlock();

        if (self.lookup(name)) |child| {
            @branchHint(.unlikely);

            child.deref();
            return error.Exists;
        }

        try self.ops.link(dentry, inode);

        inode.links_num += 1;
        inode.modify_time_sec = time.sec;
        inode.modify_time_ns = time.ns;

        parent.access_time_sec = time.sec;
        parent.access_time_ns = time.ns;
        parent.modify_time_sec = time.sec;
        parent.modify_time_ns = time.ns;
    }

    dentry.ref();
    inode.ref();
    self.addChild(dentry);

    if (lookup_cache.insert(dentry)) |collision| {
        @branchHint(.cold);
        defer collision.deref();

        // This is should be unreachable as fs driver should prevent duplications.
        log.err(
            \\{f}: failed to insert into lookup cache: '{s}' (inode: {}), 
            \\strange collision with '{s}' (inode: {})
            , .{ self.path(), name, inode.index, collision.name.str(), collision.inode.index, },
        );
    }

    return dentry;
}

pub fn unlink(self: *Dentry) Error!void {
    lib.debug.assert(self.inode.isAllocated(), @src());

    if (self.parent == self) return error.InvalidArgs;

    const was_cached = lookup_cache.tryRemove(self);
    errdefer if (was_cached) { _ = lookup_cache.tryInsert(self); };

    {
        const time = vfs.getTime();
        const inode = self.inode;

        inode.rw_sem.writeLock();
        defer inode.rw_sem.writeUnlock();

        if (inode.isRemoved()) return error.NoEnt;

        inode.access_time_sec = time.sec;
        inode.access_time_ns = time.ns;

        try self.ops.unlink(self);
        self.meta.unlinked = true;

        inode.links_num -= 1;
        inode.modify_time_sec = time.sec;
        inode.modify_time_ns = time.ns;
    }

    self.parent.removeChildAnonymously(self);
}

pub fn open(self: *Dentry, perm: vfs.Permissions) Error!*File {
    self.ref();
    errdefer self.deref();

    const file = vm.auto.alloc(File) orelse return error.NoMemory;
    errdefer vm.auto.free(File, file);

    file.* = .{
        .dentry = self,
        .perm = perm
    };

    try self.ops.open(self, file);

    file.ref();
    return file;
}

pub fn onClose(self: *Dentry, file: *File) void {
    std.debug.assert(file.dentry == self and file.ref_count.count() == 0);

    self.ops.close(self, file);
    self.deref();

    vm.auto.free(File, file);
}

pub fn addChild(self: *Dentry, child: *Dentry) void {
    self.lock.lock();
    defer self.lock.unlock();

    child.parent = self;
    self.child.prepend(&child.node);

    self.ref();
}

pub fn removeChild(self: *Dentry, child: *Dentry) void {
    {
        self.lock.lock();
        defer self.lock.unlock();

        child.parent = child;
        self.child.remove(&child.node);
    }

    self.deref();
}

pub fn removeChildAnonymously(self: *Dentry, child: *Dentry) void {
    self.lock.lock();
    defer self.lock.unlock();

    self.child.remove(&child.node);
}

pub fn changePermissions(self: *Dentry, perm: vfs.Permissions) Error!void {
    const inode = self.inode;

    inode.rw_sem.writeLock();
    defer inode.rw_sem.writeUnlock();

    try self.ops.updateInode(inode, .{
        .perm = .{
            .value = perm,
            .owner_gid = inode.gid,
            .owner_uid = inode.uid,
        },
    });

    inode.perm = @intFromEnum(perm);
}

pub fn changeOwner(self: *Dentry, uid: u16, gid: u16) Error!void {
    const inode = self.inode;

    inode.rw_sem.writeLock();
    defer inode.rw_sem.writeUnlock();

    try self.ops.updateInode(inode, .{
        .perm = .{
            .value = @enumFromInt(inode.perm),
            .owner_gid = gid,
            .owner_uid = uid,
        },
    });

    inode.uid = uid;
    inode.gid = gid;
}

pub fn touch(self: *Dentry, access: sys.time.Time, modify: ?sys.time.Time) Error!void {
    const inode = self.inode;

    inode.rw_sem.writeLock();
    defer inode.rw_sem.writeUnlock();

    try self.ops.updateInode(inode, .{
        .time = .{
            .access = access,
            .modify = if (modify) |m| m else inode.modifyTime(),
        },
    });

    inode.access_time_sec = access.sec;
    inode.access_time_ns = access.ns;
    
    if (modify) |m| {
        inode.modify_time_sec = m.sec;
        inode.modify_time_ns = m.ns;
    }
}

pub fn resize(self: *Dentry, size: u64) Error!void {
    const inode = self.inode;
    if (inode.type == .directory) return error.InvalidArgs;

    inode.rw_sem.writeLock();
    defer inode.rw_sem.writeUnlock();

    if (inode.isRemoved()) return error.NoEnt;
    try self.ops.updateInode(self.inode, .{ .size = .{ .value = size } });

    inode.size = size;
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

pub fn tryRef(self: *Dentry) bool {
    const users = self.ref_count.value.fetchAdd(1, .release);
    if (users != 0) return true;

    while (!self.in_lru.load(.acquire)) std.atomic.spinLoopHint();

    lru_lock.lock();
    defer lru_lock.unlock();

    lru_list.remove(&self.lru_node);
    self.in_lru.store(false, .release);

    return true;
}

pub fn deref(self: *Dentry) void {
    if (!self.ref_count.put()) return;
    if (self.meta.unlinked) {
        self.delete();
        return;
    }

    self.moveToLru();
}

fn moveToLru(self: *Dentry) void {
    lru_lock.lock();
    defer lru_lock.unlock();

    lru_list.prepend(&self.lru_node);
    self.in_lru.store(true, .release);
}

fn createLike(self: *const Dentry, name: []const u8) !*Dentry {
    const dentry = Dentry.new() orelse return error.NoMemory;
    errdefer dentry.free();

    dentry.name = try .init(name);
    dentry.meta = .{ .fs = self.meta.fs };
    dentry.ctx = self.ctx;
    dentry.ops = self.ops;

    return dentry;
}
