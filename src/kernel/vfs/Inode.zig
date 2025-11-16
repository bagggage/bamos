//! # Inode structure

// Copyright (C) 2024 Konstantin Pigulevskiy (bagggage@github)

const lib = @import("../lib.zig");
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

pub const alloc_config: vm.auto.Config = .{
    .allocator = .oma,
    .capacity = 512
};

index: u32,
type: Type,
perm: u16 = vfs.Permissions.makeInt(.rw, .r, .r),
size: u64 = 0, // In bytes

access_time: u32 = 0,
modify_time: u32 = 0,
create_time: u32 = 0,

gid: u16 = 0,
uid: u16 = 0,

links_num: u16 = 1,

ref_count: lib.atomic.RefCount(u32) = .init(0),

fs_data: lib.AnyData = .{},

pub inline fn new() ?*Inode {
    const inode = vm.auto.alloc(Inode) orelse return null;
    inode.ref_count = .{};

    return inode;
}

pub inline fn free(self: *Inode) void {
    vm.auto.free(Inode, self);
}

pub inline fn ref(self: *Inode) void {
    self.ref_count.inc();
}

pub inline fn deref(self: *Inode) bool {
    return self.ref_count.put();
}

pub fn getRole(self: *const Inode, uid: u32, gid: u32) vfs.Role {
    if (uid == 0 or self.uid == uid) return .user;
    if (self.gid == gid) return .group;

    return .others;
}

pub inline fn checkAccess(self: *const Inode, perm: vfs.Permissions, role: vfs.Role) bool {
    const perm_mask = perm.mask(role);
    return (self.perm & perm_mask) == perm_mask;
}

pub inline fn anyAccess(self: *const Inode, perm: vfs.Permissions, role: vfs.Role) bool {
    const perm_mask = perm.mask(role);
    return (self.perm & perm_mask) != 0;
}