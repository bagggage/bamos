//! # File Descriptor

// Copyright (C) 2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const File = @This();

const Dentry = vfs.Dentry;
const Error = vfs.Error;
const sys = @import("../sys.zig");
const utils = @import("../utils.zig");
const vfs = @import("../vfs.zig");
const vm = @import("../vm.zig");

pub const Operations = struct {
    pub const ReadFn = *const fn(*const Dentry, usize, []u8) Error!usize;
    pub const WriteFn = *const fn(*Dentry, usize, []const u8) Error!usize;
    pub const MmapFn = *const fn(*const Dentry, *sys.AddressSpace.MapUnit) Error!void;
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
ops: *const Operations = undefined,
ref_count: utils.RefCount(u16) = .{},
offset: usize = 0,

pub inline fn init(self: *File, dentry: *Dentry) void {
    dentry.ref();
    self.* = .{ .dentry = dentry };
}

pub inline fn deinit(self: *File) void {
    self.releaseDentry();
}

pub inline fn assignDentry(self: *File, dentry: *Dentry) void {
    dentry.ref();
    self.dentry = dentry;
}

pub inline fn get(self: *File) bool {
    return self.ref_count.get();
}

pub inline fn put(self: *File) bool {
    return self.ref_count.put();
}

pub inline fn releaseDentry(self: *File) void {
    self.dentry.deref();
}

pub inline fn close(self: *File) void {
    self.dentry.close(self);
}

pub fn read(self: *File, buf: []u8) Error!usize {
    const offset = self.offset;
    const readed = try self.ops.read(self.dentry, offset, buf);
    self.offset = offset + readed;

    return readed;
}

pub fn readAll(self: *File, buf: []u8) Error!void {
    const offset = self.offset;
    const readed = try self.ops.read(self.dentry, offset, buf);
    if (readed != buf.len) return Error.IoFailed;

    self.offset = offset + readed;
}

pub inline fn write(self: *File, buf: []const u8) Error!usize {
    std.debug.assert(self.dentry.inode.type != .directory);
    const offset = self.offset;
    const size = try self.ops.write(self.dentry, offset, buf);
    self.offset = offset + size;

    return size;
}

pub inline fn mmap(self: *File, map_unit: *sys.AddressSpace.MapUnit) Error!void {
    std.debug.assert(self.dentry.inode.type != .directory);
    return self.ops.mmap(self.dentry, map_unit);
}

pub inline fn ioctl(self: *File, cmd: c_uint, arg: usize) Error!void {
    if (true) return Error.BadOperation;
    return self.ops.ioctl(self.dentry, cmd, arg);
}