//! # VFS Internal implementations

const std = @import("std");

const vfs = @import("../vfs.zig");

const Kind = enum {
    panic,
    stub,
};

fn DentryOps(comptime fs: @Type(.enum_literal), comptime kind: Kind) type{
    const fs_name = @tagName(fs);

    return opaque {
        fn message(comptime op_name: []const u8) []const u8 {
            return fs_name ++ " doesn't implement `" ++ op_name ++ "` operation";
        }

        pub fn lookup(_: *const vfs.Dentry, _: []const u8) ?*vfs.Dentry {
            const msg = comptime message("lookup");
            switch (kind) {
                .panic => @panic(msg),
                .stub => std.log.warn(msg, .{})
            }
            return null;
        }

        pub fn makeDirectory(_: *const vfs.Dentry, _: *vfs.Dentry) vfs.Error!void {
            const msg = comptime message("makeDirectory");
            switch (kind) {
                .panic => @panic(msg),
                .stub => std.log.warn(msg, .{})
            }
            return error.BadOperation;
        }

        pub fn createFile(_: *const vfs.Dentry, _: *vfs.Dentry) vfs.Error!void {
            const msg = comptime message("createFile");
            switch (kind) {
                .panic => @panic(msg),
                .stub => std.log.warn(msg, .{})
            }
            return error.BadOperation;
        }

        pub fn open(_: *const vfs.Dentry, _: *vfs.File) vfs.Error!void {
            const msg = comptime message("open");
            switch (kind) {
                .panic => @panic(msg),
                .stub => std.log.warn(msg, .{})
            }
            return error.BadOperation;
        }

        pub fn close(_: *const vfs.Dentry, _: *vfs.File) void {
            const msg = comptime message("open");
            if (comptime kind == .panic) @panic(msg);
        }
    };
}

pub fn DentryPanicOps(comptime fs: @Type(.enum_literal)) type {
    return DentryOps(fs, .panic);
}

pub fn DentryStubOps(comptime fs: @Type(.enum_literal)) type {
    return DentryOps(fs, .stub);
}

pub const DentryNoneOps = opaque {
    pub fn deinitInode(_: *const vfs.Inode) void {}
};