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
    pub const PollFn = *const fn(*File) Error!Poll;

    read: ReadFn = &default.read,
    write: WriteFn = &default.write,
    ioctl: IoctlFn = &default.ioctl,
    mmapPrepare: MmapPrepareFn = &default.mmapPrepare,
    poll: PollFn = &default.poll,
};

pub const Poll = packed struct {
    read_avail: bool = false,
    read_prior: bool = false,
    read_urgent: bool = false,
    may_write: bool = false,
    may_write_prior: bool = false,
    hung_up: bool = false,
    hung_up_read: bool = false,

    pub fn fromLinux(in: i16) Poll {
        const POLL = std.os.linux.POLL;
        return .{
            .read_avail = (in & POLL.IN) != 0,
            .read_prior = (in & POLL.RDBAND) != 0,
            .read_urgent = (in & POLL.PRI) != 0,
            .may_write = (in & POLL.OUT) != 0,
            .may_write_prior = (in & 0x200) != 0,
        };
    }

    pub fn toLinux(self: Poll) i16 {
        const POLL = std.os.linux.POLL;
        var result: i16 = 0;
        if (self.read_avail)      result |= POLL.IN | POLL.RDNORM;
        if (self.read_prior)      result |= POLL.IN | POLL.RDBAND;
        if (self.read_urgent)     result |= POLL.IN | POLL.PRI;
        if (self.may_write)       result |= POLL.OUT | 0x100;
        if (self.may_write_prior) result |= POLL.OUT | 0x200;
        if (self.hung_up)         result |= POLL.HUP;
        if (self.hung_up_read)    result |= POLL.HUP | 0x2000;

        return result;
    }
};

pub const alloc_config: vm.auto.Config = .{
    .allocator = .oma,
    .capacity = 128,
};

dentry: *Dentry,
ops: *const Operations = &Operations.default.ops,
data: lib.AnyData = .{},

ref_count: lib.atomic.RefCount(u32) = .init(0),
perm: vfs.Permissions = .none,
// TODO: Make `offset` atomic access
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

pub inline fn poll(self: *File) Error!Poll {
    return self.ops.poll(self);
}
