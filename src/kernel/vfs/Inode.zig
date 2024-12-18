//! # Inode structure

// Copyright (C) 2024 Konstantin Pigulevskiy (bagggage@github)

const utils = @import("../utils.zig");
const vm = @import("../vm.zig");

const Inode = @This();

const oma_capacity = 512;

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

index: u32,
type: Type,
perm: u16,
size: u64 = 0, // In bytes

access_time: u32 = 0,
modify_time: u32 = 0,
create_time: u32 = 0,

gid: u16 = 0,
uid: u16 = 0,

links_num: u16 = 1,

ref_count: utils.RefCount(u32) = .{},

fs_data: utils.AnyData = .{},

pub var oma = vm.SafeOma(Inode).init(oma_capacity);

pub inline fn new() ?*Inode {
    const inode = oma.alloc() orelse return null;
    inode.ref_count = .{};

    return inode;
}

pub inline fn free(self: *Inode) void {
    oma.free(self);
}

pub inline fn ref(self: *Inode) void {
    self.ref_count.inc();
}

pub inline fn deref(self: *Inode) bool {
    return self.ref_count.put();
}