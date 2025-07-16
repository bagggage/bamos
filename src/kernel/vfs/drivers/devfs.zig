//! # Device virtual file system

// Copyright (C) 2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const dev = @import("../../dev.zig");
const log = std.log.scoped(.devfs);
const tmpfs = vfs.tmpfs;
const utils = @import("../../utils.zig");
const vfs = @import("../../vfs.zig");
const vm = @import("../../vm.zig");

const max_major = vm.page_size * std.mem.byte_size_in_bits;

pub const Error = error {
    NoMemory,
    DevMajorLimit,
    DevMinorLimit,
};

pub const DevNum = struct {
    major: u16,
    minor: u16,
};

pub const Region = struct {
    major: u16,
    minor_alloc: utils.NumberAlloc(u16) = .{},

    pub fn init() Error!Region {
        return .{
            .major = allocMajor() orelse return Error.DevMajorLimit,
        };
    }

    pub inline fn deinit(self: *Region) void {
        freeMajor(self.major);
    }

    pub fn alloc(self: *Region) ?DevNum {
        return .{
            .major = self.major,
            .minor = self.minor_alloc.alloc() orelse return null
        };
    }

    pub fn free(self: *Region, num: DevNum) void {
        std.debug.assert(self.major == num.major);
        self.minor_alloc.free(num.minor);
    }
};

pub const DevFile = struct {
    const List = utils.SList(void);
    const Node = List.Node;

    name: dev.Name,

    num: DevNum,

    fops: *const vfs.File.Operations,
    data: utils.AnyData = .{},

    node: Node = .{ .data = undefined },

    pub inline fn asNode(self: *DevFile) *Node {
        return &self.node;
    }

    pub inline fn fromNode(node: *Node) *DevFile {
        return @fieldParentPtr("node", node);
    }

    pub inline fn fromDentry(dentry: *const vfs.Dentry) *DevFile {
        return dentry.inode.fs_data.as(DevFile).?;
    }
};

const DevList = struct {
    list: DevFile.List,
    max_no: u16,

    lock: utils.Spinlock = .{},
};

const StubOps = vfs.internals.DentryStubOps(.devtmpfs);

const init_inode_idx = 1;

var fs = vfs.FileSystem.init(
    "devtmpfs",
    .{ .virt = .{
        .mount = mount,
        .unmount = unmount
    }},
    .{
        .lookup = tmpfs.DentryOps.lookup,
        .createFile = tmpfs.DentryOps.createFile,
        .makeDirectory = tmpfs.DentryOps.makeDirectory,

        .open = dentryOpen,
        .close = StubOps.close,
    },
);

var root: *vfs.Dentry = undefined;
var major_bitmap: utils.Bitmap = .{};
var major_lock: utils.Spinlock = .{};

var inode_idx: u32 = init_inode_idx;

pub fn init() !void {
    if (vfs.registerFs(&fs) == false) return error.RegisterFailed;

    const phys_pool = vm.PageAllocator.alloc(0) orelse return error.NoMemory;
    const vm_pool: [*]u8 = @ptrFromInt(vm.getVirtLma(phys_pool));

    major_bitmap = .init(vm_pool[0..vm.page_size], false);
    errdefer unmount(undefined);

    root = try tmpfs.createDirectory("/", undefined);
}

pub fn mount() vfs.Error!vfs.Context.Virt {
    return .{ .root = root };
}

pub fn unmount(_: *vfs.Context.Virt) void {}

pub fn allocMajor() ?u16 {
    major_lock.lock();
    defer major_lock.unlock();

    const idx = major_bitmap.find(false) orelse return null;
    major_bitmap.set(idx);

    return @truncate(idx);
}

pub fn freeMajor(major: u16) void {
    major_lock.lock();
    defer major_lock.unlock();

    major_bitmap.clear(major);
}

pub inline fn registerBlockDev(devf: *DevFile) Error!void {
    _ = try registerDevice(devf, .block_device);
}

pub inline fn registerCharDev(devf: *DevFile) Error!void {
    _ = try registerDevice(devf, .char_device);
}

pub inline fn getDevData(dentry: *const vfs.Dentry) utils.AnyData {
    return dentry.inode.fs_data.as(DevFile).?.data;
}

fn registerDevice(devf: *DevFile, kind: vfs.Inode.Type) Error!*vfs.Dentry {
    const inode = try createInode(kind);
    errdefer vfs.Inode.free(inode);

    const dentry = try tmpfs.createDentry(devf.name.str(), inode, root.ctx);
    dentry.ops = &fs.data.dentry_ops;

    inode.fs_data.set(devf);
    root.addChild(dentry);

    return dentry;
}

fn dentryOpen(dentry: *const vfs.Dentry, file: *vfs.File) vfs.Error!void {
    const devf = dentry.inode.fs_data.as(DevFile).?;
    file.ops = devf.fops;
}

fn createInode(kind: vfs.Inode.Type) Error!*vfs.Inode {
    const inode = try tmpfs.createInode(kind);
    inode.index = inode_idx;
    inode_idx += 1;

    return inode;
}
