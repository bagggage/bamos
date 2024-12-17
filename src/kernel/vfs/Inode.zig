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
size: u64, // In bytes

access_time: u32,
modify_time: u32,
create_time: u32,

gid: u16,
uid: u16,

links_num: u16,

fs_data: utils.AnyData = .{},

pub var oma = vm.SafeOma(Inode).init(oma_capacity);

pub inline fn new() ?*Inode {
    return oma.alloc();
}

pub inline fn delete(self: *Inode) void {
    oma.free(self);
}