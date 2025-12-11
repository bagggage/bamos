//! # VFS Internal implementations

const std = @import("std");

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
    pub const Cached = struct {
        pub const mmap = opaque {
            pub const ops: sys.AddressSpace.MapUnit.Operations = .{
                .pageFault = pageFault,
                .unmapPage = unmapPage
            };

            const MapUnit = sys.AddressSpace.MapUnit;

            pub fn pageFault(map_unit: *MapUnit, pt: *vm.PageTable, offset: usize, _: vm.FaultCause) Error!void {
                const file_offset = (map_unit.page_offset * vm.page_size) + offset;
                const block = try getCacheBlockOrRead(map_unit.file.?, file_offset);
                errdefer block.deref();

                const page_offset = offset / vm.page_size;
                const page_base = block.phys_base + (block.innerOffset(file_offset) / vm.page_size);
                try map_unit.attachAndMapPage(pt, @truncate(page_offset), @truncate(page_base), 0);
            }

            pub fn unmapPage(map_unit: *const MapUnit, pt: *const vm.PageTable, page: MapUnit.Page) void {
                const inode = map_unit.file.?.dentry.inode;

                const mapped_page_offset = page.getOffset();
                const file_offset = map_unit.page_offset * vm.page_size + mapped_page_offset;
                const block = vm.cache.getNoRef(&inode.cache_ctrl, vm.cache.offsetToIdx(file_offset))
                    catch @panic("Trying to unmap cache page of non-existing cache block!");

                if (map_unit.flags.map.write) {
                    const virt = map_unit.base() + mapped_page_offset;
                    if (pt.accessPageAttributes(virt).dirty) {
                        const quant = block.offsetToQuant(file_offset);
                        block.dirty_map.set(quant);
                    }
                }

                block.deref();
            }
        };

        pub const ReadCacheBlockFn = *const fn (dentry: *const Dentry, block: *vm.cache.Block) Error!void;

        ops: File.Operations = .{
            .read = &read,
            .mmapPrepare = &mmapPrepare,
        },
        readCacheBlock: ReadCacheBlockFn,

        pub fn read(self: *const File, offset: usize, buffer: []u8) Error!usize {
            const inode = self.dentry.inode;

            if (inode.type != .regular_file) return error.BadInode;
            if (offset >= inode.size) return 0;

            var len = @min(inode.size - offset, buffer.len);
            var tmp_offset: usize = 0;
            while (len > 0) {
                const file_offset = tmp_offset + offset;
                const block = try getCacheBlockOrRead(self, file_offset);
                defer block.deref();

                const inner_offset = block.innerOffset(file_offset);
                const inner_end = @min(inner_offset + len, block.size.toBytes());
                const inner_len = inner_end - inner_offset;

                @memcpy(buffer[tmp_offset..tmp_offset + inner_len], block.asSlice()[inner_offset..inner_end]);

                tmp_offset +%= inner_len;
                len -%= inner_len;
            }

            return tmp_offset;
        }

        pub fn mmapPrepare(self: *const File, map_unit: *sys.AddressSpace.MapUnit) Error!void {
            if (self.dentry.inode.type != .regular_file) return error.BadInode;
            map_unit.ops = &mmap.ops;
        }

        fn getCacheBlockOrRead(self: *const File, offset: usize) vfs.Error!*cache.Block {
            const inode = self.dentry.inode;
            const index = vm.cache.offsetToIdx(offset);

            return vm.cache.getOrNull(&inode.cache_ctrl, index) orelse blk: {
                const new_block = try vm.cache.createBlock(&inode.cache_ctrl, index, .small);
                const cached_ops = Cached.fromFile(self);
                try cached_ops.readCacheBlock(self.dentry, new_block);

                const rest_size = self.dentry.inode.size - new_block.getOffset();
                if (rest_size < new_block.size.toBytes()) @memset(new_block.asSlice()[rest_size..], 0);

                break :blk vm.cache.insertBlockOrFree(new_block) orelse new_block;
            };
        }

        inline fn fromFile(self: *const File) *const Cached {
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

        pub const ops: File.Operations = .{
            .read = &read,
            .write = &write,
            .ioctl = &ioctl,
            .mmapPrepare = &mmapPrepare,
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