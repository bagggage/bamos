//! # VFS Internal implementations

const std = @import("std");

const bindings = @import("../bindings.zig");
const lib = @import("../lib.zig");
const sys = @import("../sys.zig");
const vfs = @import("../vfs.zig");
const vm = @import("../vm.zig");

const Dentry = vfs.Dentry;
const File = vfs.File;
const Inode = vfs.Inode;

const Error = vfs.Error;

pub const cache = opaque {
    const Block = vm.cache.Block;

    pub fn noWriteBack(_: *Block, _: []const Block.Quant, _: u5) bool {
        return true;
    }

    pub fn noWriteBackFail(_: *Block, _: []const Block.Quant, _: u5) bool {
        return false;
    }
};

pub const dentry_ops = opaque {
    pub const default = opaque {
        pub fn lookup(_: *const Dentry, _: []const u8) ?*Dentry {
            return null;
        }

        pub fn iterate(_: *const Dentry, _: *Dentry.Iterator) Error!void {
            return;
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

        pub fn iterate(dentry: *const Dentry, _: *Dentry.Iterator) Error!void {
            std.log.warn("{f}: 'iterate' is not implemented", .{dentry.path()});
            return;
        }

        pub fn makeDirectory(dentry: *const Dentry, _: *Dentry, _: vfs.CreateOptions) Error!void {
            std.log.warn("{f}: 'makeDirectory' is not implemented", .{dentry.path()});
            return error.BadOperation;
        }

        pub fn createFile(dentry: *const Dentry, _: *Dentry, _: vfs.CreateOptions) Error!void {
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
    pub const Cached = struct {
        pub const mmap = opaque {
            pub const ops: sys.AddressSpace.MapUnit.Operations = .{
                .pageFault = pageFault,
                .unmapPage = unmapPage
            };

            const MapUnit = sys.AddressSpace.MapUnit;

            pub fn pageFault(map_unit: *MapUnit, pt: *vm.PageTable, offset: usize, cause: vm.FaultCause) Error!*vm.Page {
                return bindings.getInstance().vfs.internals.cachedPageFault(map_unit, pt, offset, cause);
            }

            pub fn unmapPage(map_unit: *const MapUnit, pt: *const vm.PageTable, page: vm.Page) void {
                bindings.getInstance().vfs.internals.cachedUnmapPage(map_unit, pt, page);
            }
        };

        pub const ReadCacheBlockFn = *const fn (dentry: *const Dentry, block: *vm.cache.Block) Error!void;

        ops: File.Operations = .{
            .read = &read,
            .write = &write,
            .mmapPrepare = &mmapPrepare,
        },
        readCacheBlock: ReadCacheBlockFn,

        pub fn read(self: *const File, offset: usize, buffer: []u8) Error!usize {
            return bindings.getInstance().vfs.internals.cachedRead(self, offset, buffer);
        }

        pub fn write(self: *File, offset: usize, buffer: []const u8) Error!usize {
            return bindings.getInstance().vfs.internals.cachedWrite(self, offset, buffer);
        }

        pub fn mmapPrepare(self: *const File, map_unit: *sys.AddressSpace.MapUnit) Error!void {
            if (self.dentry.inode.type != .regular_file) return error.NotRegularFile;
            map_unit.ops = &mmap.ops;
        }

        pub inline fn fromFile(self: *const File) *const Cached {
            return @fieldParentPtr("ops", self.ops);
        }
    };

    pub const default = opaque {
        pub fn read(_: *const File, _: usize, _: []u8) Error!usize {
            return error.BadOperation;
        }

        pub fn write(_: *File, _: usize, _: []const u8) Error!usize {
            return error.BadOperation;
        }

        pub fn ioctl(_: *File, _: c_uint, _: usize) Error!void {
            return error.BadOperation;
        }

        pub fn mmapPrepare(_: *const File, _: *sys.AddressSpace.MapUnit) Error!void {
            return error.BadOperation;
        }

        pub fn poll(self: *File) Error!File.Poll {
            return switch (self.dentry.inode.type) {
                .directory,
                .symbolic_link,
                .regular_file => .{ .read_avail = true, .may_write = true },
                else => error.BadOperation
            };
        }

        pub const ops: File.Operations = .{
            .read = &read,
            .write = &write,
            .ioctl = &ioctl,
            .mmapPrepare = &mmapPrepare,
            .poll = &poll
        };
    };

    pub const debug = opaque {
        pub fn read(self: *const File, _: usize, _: []u8) Error!usize {
            std.log.warn("{}: 'read' is not implemented", .{self.dentry.path()});
            return error.BadOperation;
        }

        pub fn write(self: *File, _: usize, _: []const u8) Error!usize {
            std.log.warn("{}: 'write' is not implemented", .{self.dentry.path()});
            return error.BadOperation;
        }

        pub fn ioctl(self: *File, _: c_uint, _: usize) Error!void {
            std.log.warn("{}: 'ioctl' is not implemented", .{self.dentry.path()});
            return error.BadOperation;
        }

        pub fn mmapPrepare(self: *const File, _: *sys.AddressSpace.MapUnit) Error!void {
            std.log.warn("{}: 'mmap' is not implemented", .{self.dentry.path()});
            return error.BadOperation;
        }

        pub const ops: File.Operations = .{
            .read = &read,
            .write = &write,
            .ioctl = &ioctl,
            .mmapPrepare = &mmapPrepare,
        };
    };
};
