//! # Virtual file system

pub const devfs = @import("vfs/devfs.zig");

const std = @import("std");

const dev = @import("dev.zig");
const utils = @import("utils.zig");
const log = @import("log.zig");
const vm = @import("vm.zig");

const entries_oma_capacity = 512;
const fs_oma_capacity = 32;

const hashFn = std.hash.Fnv1a_32.hash;

pub const Error = error {
    Busy,
    NoMemory
};

pub const FileSystem = struct {
    pub const Operations = struct {
        pub const MountT = *const fn(*Dentry) void;
        pub const UnmountT = *const fn(*Dentry) void;

        mount: MountT,
        unmount: UnmountT
    };

    node: FsList.Node,

    name: []const u8,
    hash: u32,

    ops: Operations = undefined,
    dentry_ops: Dentry.Operations = undefined,

    pub fn init(comptime name: []const u8, ops: Operations, dentry_ops: Dentry.Operations) FileSystem {
        comptime var buffer: [name.len]u8 = .{0} ** name.len;
        const lower = comptime std.ascii.lowerString(&buffer, name);
        const hash = comptime hashFn(lower);

        return .{
            .name = name,
            .hash = hash,
            .ops = ops,
            .dentry_ops = dentry_ops,
            .node = .{
                .data = undefined
            }
        };
    }
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
    size: usize, // In bytes

    access_time: u32,
    modify_time: u32,
    create_time: u32,

    fs_data: utils.AnyData = .{},

    pub var oma = vm.SafeOma(Inode).init(entries_oma_capacity);

    pub inline fn new() ?*Inode {
        return oma.alloc();
    }

    pub inline fn delete(self: *Inode) void {
        oma.free(self);
    }
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

    pub inline fn new() ?*Dentry {
        return oma.alloc();
    }

    pub inline fn delete(self: *Dentry) void {
        oma.free(self);
    }

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

const FsList = utils.List(*FileSystem);

var root: *Dentry = undefined;
var fs_list: FsList = .{};
var fs_list_lock = utils.Spinlock.init(.unlocked);

const AutoInit = opaque {
    pub var file_systems = .{
        @import("vfs/ext2.zig")
    };
};

pub fn init() !void {
    inline for (AutoInit.file_systems) |Fs| {
        Fs.init() catch |err| {
            log.err("Failed to initialize '"++@typeName(Fs)++"' filesystem: {s}", .{@errorName(err)});  
        };
    }
}

pub fn deinit() void {
    inline for (AutoInit.file_systems) |Fs| {
        Fs.deinit();
    }
}

pub fn registerFs(fs: *FileSystem) Error!void {
    const node = &fs.node;
    if (node.next != null or node.prev != null) return error.Busy;

    fs.node.data = fs;

    fs_list_lock.lock();
    defer fs_list_lock.unlock();

    fs_list.append(node);
}

pub fn unregisterFs(fs: *FileSystem) void {
    {
        fs_list_lock.lock();
        defer fs_list_lock.unlock();

        fs_list.remove(&fs.node);
    }

    fs.node.next = null;
    fs.node.prev = null;
}

pub inline fn lookup(path: []const u8) ?*Dentry {
    _ = path; return null;
}