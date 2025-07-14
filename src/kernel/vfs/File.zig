//! # File Descriptor

// Copyright (C) 2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const File = @This();

const Dentry = vfs.Dentry;
const Error = vfs.Error;
const utils = @import("../utils.zig");
const vfs = @import("../vfs.zig");
const vm = @import("../vm.zig");

pub const Operations = struct {
    pub const ReadFn = *const fn(*const Dentry, usize, []u8) Error!usize;
    pub const WriteFn = *const fn(*Dentry, usize, []const u8) Error!usize;
    pub const MmapFn = *const fn(*const Dentry, usize, *const vm.VirtualRegion) Error!void;
    pub const IoctlFn = *const fn(*Dentry, c_uint, usize) Error!void;

    read: ReadFn,
    write: WriteFn,
    mmap: MmapFn,
    ioctl: IoctlFn = undefined,
};

pub const alloc_config: vm.obj.AllocatorConfig = .{
    .allocator = .safe_oma,
    .wrapper = .none,
    .capacity = 128,
};

dentry: *Dentry,
ops: *const Operations,
offset: usize = 0,

pub inline fn assignDentry(self: *File, dentry: *Dentry) void {
    dentry.ref();
    self.dentry = dentry;
}

pub inline fn releaseDentry(self: *File) void {
    self.dentry.deref();
}

pub inline fn close(self: *File) void {
    self.dentry.close(self);
}

pub fn read(self: *File, buf: []u8) Error!usize {
    const size = try self.ops.read(self.dentry, self.offset, buf);
    self.offset += size;

    return size;
}

pub inline fn write(self: *File, buf: []const u8) Error!usize {
    std.debug.assert(self.dentry.inode.type != .directory);
    const size = try self.ops.write(self.dentry, self.offset, buf);
    self.offset += size;

    return size;
}

pub inline fn mmap(self: *File, offset: usize, region: *const vm.VirtualRegion) Error!void {
    std.debug.assert(self.dentry.inode.type != .directory);
    return self.ops.mmap(self.dentry, offset, region);
}

pub inline fn ioctl(self: *File, cmd: c_uint, arg: usize) Error!void {
    if (true) return Error.BadOperation;
    return self.ops.ioctl(self.dentry, cmd, arg);
}