//! # Superblock structre

// Copyright (C) 2024 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const Dentry = vfs.Dentry;
const Drive = vfs.Drive;
const MountPoint = vfs.MountPoint;
const Partition = vfs.Partition;
const utils = @import("../utils.zig");
const vfs = @import("../vfs.zig");
const vm = @import("../vm.zig");

const Superblock = @This();

const oma_capacity = 32;

drive: *Drive,
part: *const Partition,

part_offset: usize,

block_size: u16,
block_shift: u4,

root: *Dentry = vfs.Context.bad_root,
mount_point: *MountPoint = undefined,

fs_data: utils.AnyData,

pub var oma = vm.SafeOma(Superblock).init(oma_capacity);

pub inline fn new() ?*Superblock {
    return oma.alloc();
}

pub inline fn free(self: *Superblock) void {
    oma.free(self);
}

pub fn init(
    self: *Superblock,
    drive: *Drive,
    part: *const Partition,
    block_size: u16,
    fs_data: ?*anyopaque
) void {
    self.* = .{
        .drive = drive,
        .part = part,
        .part_offset = drive.lbaToOffset(part.lba_start),
        .block_size = block_size,
        .block_shift = std.math.log2_int(u16, block_size),
        .fs_data = .from(fs_data)
    };
}

pub inline fn blockToOffset(self: *const Superblock, block: usize) usize {
    return block << self.block_shift;
}

pub inline fn offsetToBlock(self: *const Superblock, offset: usize) usize {
    return offset >> self.block_shift;
}

pub inline fn offsetModBlock(self: *const Superblock, offset: usize) u16 {
    const mask = comptime ~@as(u16, 0);
    return @as(u16, @truncate(offset)) & ~(mask << self.block_shift);
}

pub inline fn validateRoot(self: *const Superblock) bool {
    return self.root != vfs.Context.bad_root;
}
