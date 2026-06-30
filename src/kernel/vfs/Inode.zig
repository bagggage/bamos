//! # Inode structure

// Copyright (C) 2024-2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const lib = @import("../lib.zig");
const sys = @import("../sys.zig");
const vfs = @import("../vfs.zig");
const vm = @import("../vm.zig");

const Inode = @This();

pub const Type = enum(u8) {
    unknown = 0,
    regular_file,
    directory,
    char_device,
    block_device,
    fifo,
    socket,
    symbolic_link
};

pub const Update = union(enum) {
    time: struct {
        access: sys.time.Time,
        modify: sys.time.Time,
    },
    size: struct {
        value: u64,
    },
    perm: struct {
        value: vfs.Permissions,
        owner_gid: u16,
        owner_uid: u16,
    },
};

pub const alloc_config: vm.auto.Config = .{
    .allocator = .oma,
    .capacity = 1024
};

index: u32 = 0,
type: Type,
perm: u16 = vfs.Permissions.makeInt(.rw, .r, .r),
size: u64 = 0, // In bytes

access_time_sec: u64 = 0,
modify_time_sec: u64 = 0,
create_time_sec: u64 = 0,

access_time_ns: u32 = 0,
modify_time_ns: u32 = 0,
create_time_ns: u32 = 0,

gid: u16,
uid: u16,

links_num: u16,
ref_count: lib.atomic.RefCount(u16) = .init(0),

rw_sem: lib.sync.RwSemaphore = .{},
lock: lib.sync.Spinlock = .{},

fs_data: lib.AnyData = .{},
cache_ctrl: vm.cache.Control,

pub inline fn new() ?*Inode {
    const inode = vm.auto.alloc(Inode) orelse return null;
    inode.ref_count = .{};

    return inode;
}

pub inline fn free(self: *Inode) void {
    vm.auto.free(Inode, self);
}

pub inline fn delete(self: *Inode) void {
    self.cache_ctrl.deinit();
    self.free();
}

pub inline fn ref(self: *Inode) void {
    self.ref_count.inc();
}

pub inline fn deref(self: *Inode) bool {
    return self.ref_count.put();
}

pub inline fn accessTime(self: *const Inode) sys.time.Time {
    return .{ .sec = self.access_time_sec, .ns = self.access_time_ns };
}

pub inline fn modifyTime(self: *const Inode) sys.time.Time {
    return .{ .sec = self.modify_time_sec, .ns = self.modify_time_ns };
}

pub inline fn createTime(self: *const Inode) sys.time.Time {
    return .{ .sec = self.create_time_sec, .ns = self.create_time_ns };
}

pub inline fn isAllocated(self: *const Inode) bool {
    return self.index != 0;
}

pub inline fn isRemoved(self: *const Inode) bool {
    return self.isAllocated() and self.links_num == 0;
}

pub fn getRole(self: *const Inode, uid: u32, gid: u32) vfs.Role {
    if (uid == 0 or self.uid == uid) return .user;
    if (self.gid == gid) return .group;

    return .others;
}

pub inline fn checkAccess(self: *const Inode, perm: vfs.Permissions, role: vfs.Role) bool {
    const perm_mask = perm.mask(role);

    if (perm_mask == 0) return false;
    return (self.perm & perm_mask) == perm_mask;
}

pub inline fn anyAccess(self: *const Inode, perm: vfs.Permissions, role: vfs.Role) bool {
    const perm_mask = perm.mask(role);
    return (self.perm & perm_mask) != 0;
}
