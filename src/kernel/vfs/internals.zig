//! # VFS Internal implementations

const std = @import("std");

const sys = @import("../sys.zig");
const vfs = @import("../vfs.zig");

const Dentry = vfs.Dentry;
const File = vfs.File;
const Inode = vfs.Inode;

const Error = vfs.Error;

pub const dentry_ops = opaque {
    pub const default = opaque {
        pub fn lookup(_: *const Dentry, _: []const u8) ?*Dentry {
            return null;
        }

        pub fn makeDirectory(_: *const Dentry, _: *Dentry) Error!void {
            return error.BadOperation;
        }

        pub fn createFile(_: *const Dentry, _: *Dentry) Error!void {
            return error.BadOperation;
        }

        pub fn deinitInode(_: *const Inode) void {}

        pub fn open(_: *const Dentry, _: *File) Error!void {
            return error.BadOperation;
        }

        pub fn close(_: *const Dentry, _: *File) void {}

        pub const ops: Dentry.Operations = .{
            .lookup = &lookup,
            .makeDirectory = &makeDirectory,
            .createFile = &createFile,
            .open = &open,
            .close = &close,
            .deinitInode = &deinitInode
        };
    };

    pub const debug = opaque {
        pub fn lookup(dentry: *const Dentry, _: []const u8) ?*Dentry {
            std.log.warn("{f}: 'lookup' is not implemented", .{dentry.path()});
            return null;
        }

        pub fn makeDirectory(dentry: *const Dentry, _: *Dentry) Error!void {
            std.log.warn("{f}: 'makeDirectory' is not implemented", .{dentry.path()});
            return error.BadOperation;
        }

        pub fn createFile(dentry: *const Dentry, _: *Dentry) Error!void {
            std.log.warn("{f}: 'createFile' is not implemented", .{dentry.path()});
            return error.BadOperation;
        }

        pub fn deinitInode(inode: *const Inode) void {
            std.log.warn("{*}: is not properly deinitialized ('deinitInode' is not implemented)", .{inode});
        }

        pub fn open(dentry: *const Dentry, _: *File) Error!void {
            std.log.warn("{f}: 'open' is not implemented", .{dentry.path()});
            return error.BadOperation;
        }

        pub fn close(dentry: *const Dentry, _: *File) void {
            std.log.warn("{f}: 'close' is not implemented", .{dentry.path()});
        }

        pub const ops: Dentry.Operations = .{
            .lookup = &lookup,
            .makeDirectory = &makeDirectory,
            .createFile = &createFile,
            .open = &open,
            .close = &close,
            .deinitInode = &deinitInode
        };
    };
};

pub const file = opaque {
    pub const default = opaque {
        pub fn read(_: *const Dentry, _: usize, _: []u8) Error!usize {
            return error.BadOperation;
        }

        pub fn write(_: *Dentry, _: usize, _: []const u8) Error!usize {
            return error.BadOperation;
        }

        pub fn mmap(_: *const Dentry, _: *sys.AddressSpace.MapUnit) Error!void {
            return error.BadOperation;
        }

        pub fn ioctl(_: *Dentry, _: c_uint, _: usize) Error!void {
            return error.BadOperation;
        }

        pub const ops: File.Operations = .{
            .read = &read,
            .write = &write,
            .mmap = &mmap,
            .ioctl = &ioctl
        };
    };

    pub const debug = opaque {
        pub fn read(dentry: *const Dentry, _: usize, _: []u8) Error!usize {
            std.log.warn("{}: 'read' is not implemented", .{dentry.path()});
            return error.BadOperation;
        }

        pub fn write(dentry: *Dentry, _: usize, _: []const u8) Error!usize {
            std.log.warn("{}: 'write' is not implemented", .{dentry.path()});
            return error.BadOperation;
        }

        pub fn mmap(dentry: *const Dentry, _: *sys.AddressSpace.MapUnit) Error!void {
            std.log.warn("{}: 'mmap' is not implemented", .{dentry.path()});
            return error.BadOperation;
        }

        pub fn ioctl(dentry: *Dentry, _: c_uint, _: usize) Error!void {
            std.log.warn("{}: 'ioctl' is not implemented", .{dentry.path()});
            return error.BadOperation;
        }

        pub const ops: File.Operations = .{
            .read = &read,
            .write = &write,
            .mmap = &mmap,
            .ioctl = &ioctl
        };
    };
};