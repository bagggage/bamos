//! # File Descriptor

// Copyright (C) 2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const File = @This();

const Dentry = vfs.Dentry;
const Error = vfs.Error;
const lib = @import("../lib.zig");
const sys = @import("../sys.zig");
const vfs = @import("../vfs.zig");
const vm = @import("../vm.zig");

pub const Operations = struct {
    const default = vfs.internals.file.default;

    pub const ReadFn = *const fn(*const File, usize, []u8) Error!usize;
    pub const WriteFn = *const fn(*File, usize, []const u8) Error!usize;
    pub const MmapPrepareFn = *const fn(*const File, *sys.AddressSpace.MapUnit) Error!void;
    pub const IoctlFn = *const fn(*File, c_uint, usize) Error!void;

    read: ReadFn = &default.read,
    write: WriteFn = &default.write,
    ioctl: IoctlFn = &default.ioctl,
    mmapPrepare: MmapPrepareFn = &default.mmapPrepare,
};

pub const alloc_config: vm.auto.Config = .{
    .allocator = .oma,
    .capacity = 128,
};

dentry: *Dentry,
ops: *const Operations = &Operations.default.ops,
ref_count: lib.atomic.RefCount(u32) = .init(0),
perm: vfs.Permissions = .none,
offset: usize = 0,

pub inline fn get(self: *File) bool {
    return self.ref_count.get();
}

pub inline fn put(self: *File) bool {
    return self.ref_count.put();
}

pub inline fn ref(self: *File) void {
    self.ref_count.inc();
}

pub inline fn deref(self: *File) void {
    if (self.ref_count.put()) self.dentry.onClose(self);
}

pub inline fn validateAccess(self: *const File, access: vfs.Permissions) Error!void {
    if (!self.perm.checkAccess(access)) return error.NoAccess;
}

pub fn read(self: *File, buf: []u8) Error!usize {
    const offset = self.offset;
    const readed = try self.ops.read(self, offset, buf);
    self.offset = offset + readed;

    return readed;
}

pub inline fn readAt(self: *File, offset: usize, buf: []u8) Error!usize {
    std.debug.assert(self.dentry.inode.type != .directory);
    return try self.ops.read(self, offset, buf);
}

pub fn readAll(self: *File, buf: []u8) Error!void {
    const offset = self.offset;
    const readed = try self.ops.read(self, offset, buf);
    if (readed != buf.len) return Error.IoFailed;

    self.offset = offset + readed;
}

pub inline fn write(self: *File, buf: []const u8) Error!usize {
    std.debug.assert(self.dentry.inode.type != .directory);
    const offset = self.offset;
    const size = try self.ops.write(self, offset, buf);
    self.offset = offset + size;

    return size;
}

pub inline fn writeAt(self: *File, offset: usize, buf: []const u8) Error!usize {
    std.debug.assert(self.dentry.inode.type != .directory);
    return try self.ops.write(self, offset, buf);
}

pub inline fn mmapPrepare(self: *File, map_unit: *sys.AddressSpace.MapUnit) Error!void {
    std.debug.assert(self.dentry.inode.type != .directory);
    return self.ops.mmapPrepare(self, map_unit);
}

pub inline fn ioctl(self: *File, cmd: c_uint, arg: usize) Error!void {
    return self.ops.ioctl(self, cmd, arg);
}