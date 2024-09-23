//! # Virtual file system

pub const devfs = @import("vfs/devfs.zig");

const std = @import("std");

const dev = @import("dev.zig");
const utils = @import("utils.zig");
const vm = @import("vm.zig");

const entries_oma_capacity = 512;
const fs_oma_capacity = 32;

const hashFn = std.hash.Crc32.hash;

pub const FileSystem = struct {
    pub const Operations = struct {
        pub const MountT = *const fn(*Dentry) void;
        pub const UnmountT = *const fn(*Dentry) void;

        mount: MountT,
        unmount: UnmountT
    };

    name: []const u8,
    hash: u32,

    device: ?*dev.Device = null,

    ops: Operations = undefined,
    dentry_ops: Dentry.Operations = undefined,

    pub var oma = vm.SafeOma(FsList.Node).init(fs_oma_capacity);
};

pub const Inode = struct {
    pub const Type = enum(u4) {
        unknown = 0,
        regular_file,
        directory,
        char_device,
        block_device,
        fifo,
        socket,
        symbolic_link
    };

    index: u32,
    type: Type,
    size: usize,

    fs_data: utils.AnyData = .{},

    pub var oma = vm.SafeOma(Inode).init(entries_oma_capacity);
};

pub const Dentry = struct {
    pub const Operations = struct {
        pub const FillT = *const fn(*Dentry) void;

        fill: FillT,
    };

    pub const Name = struct {
        pub const Union = union {
            short: [32:0]u8,
            long: []u8,
        };

        value: Union,
        hash: u32
    };

    name: Name,

    parent: *Dentry,
    inode: ?*Inode = null,
    ops: *Operations,

    child: utils.SList(Dentry) = .{},

    lock: utils.Spinlock = .{},

    pub var oma = vm.SafeOma(Dentry).init(entries_oma_capacity);

    pub fn init(self: *Dentry, name: []const u8, parent: ?*Dentry, inode: ?*Inode, ops: *Operations) void {
        self.name.hash = hashFn(name);
        self.name.value = blk: {
            if (name.len <= @sizeOf(@TypeOf(self.name.value))) {
                var value: Name.Union = .{ .short = undefined };
                @memcpy(value.short[0..], name);

                break :blk value;
            }
            else {
                break :blk .{ .long = @constCast(name) };
            }
        };

        self.parent = parent orelse self;
        self.inode = inode;
        self.ops = ops;
    }

    pub fn lookup(path: []const u8) ?*Dentry {
        _ = path; return null;
    }

    pub inline fn fill(self: *Dentry) void {
        std.debug.assert(self.inode.type == .directory);
        std.debug.assert(self.childs.len == 0);

        self.ops.fill(self);
    }
};

const FsList = utils.List(FileSystem);

var root: *Dentry = undefined;
var fs_list: FsList = .{};
var fs_lock = utils.Spinlock.init(.unlocked);

pub fn registerFs(
    comptime name: []const u8,
    device: ?*dev.Device,
) !*FileSystem {
    const node = FileSystem.oma.alloc() orelse return error.NoMemory;
    const fs = &node.data;

    fs.name = name;
    fs.device = device;

    fs_lock.lock();
    defer fs_lock.unlock();

    fs_list.append(node);

    return fs;
}

pub inline fn lookup(path: []const u8) ?*Dentry {
    _ = path; return null;
}