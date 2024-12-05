//! # Virtual file system

// Copyright (C) 2024 Konstantin Pigulevskiy (bagggage@github)

pub const devfs = @import("vfs/devfs.zig");

const std = @import("std");

const dev = @import("dev.zig");
const utils = @import("utils.zig");
const log = std.log.scoped(.vfs);
const vm = @import("vm.zig");

const entries_oma_capacity = 512;
const fs_oma_capacity = 32;

const hashFn = std.hash.Fnv1a_32.hash;

pub const parts = @import("vfs/parts.zig");
pub const Drive = dev.classes.Drive;
pub const Partition = parts.Partition;

pub const Error = error {
    Busy,
    NoMemory,
    NoFs,
    BadDentry,
    BadInode,
    BadSuperblock,
};

pub const FileSystem = struct {
    pub const Operations = struct {
        pub const MountT = *const fn(*Dentry) void;
        pub const UnmountT = *const fn(*Dentry) void;

        mount: MountT,
        unmount: UnmountT
    };

    name: []const u8,
    hash: u32,

    ops: Operations = undefined,
    dentry_ops: Dentry.Operations = undefined,

    pub fn init(comptime name: []const u8, ops: Operations, dentry_ops: Dentry.Operations) FsNode {
        comptime var buffer: [name.len]u8 = .{0} ** name.len;
        const lower = comptime std.ascii.lowerString(&buffer, name);
        const hash = comptime hashFn(lower);

        return .{
            .data = .{
                .name = name,
                .hash = hash,
                .ops = ops,
                .dentry_ops = dentry_ops,
            }
        };
    }
};

pub const Superblock = struct {
    drive: ?*Drive,
    offset: usize,

    block_size: u32,

    fs_data: utils.AnyData,
};

pub const Inode = struct {
    pub const Type = enum(u8) {
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
    perm: u16,
    size: u64, // In bytes

    access_time: u32,
    modify_time: u32,
    create_time: u32,

    gid: u16,
    uid: u16,

    links_num: u16,

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

pub const MountPoint = struct {
    fs: *FileSystem,
    dentry: *Dentry,

    super: Superblock,
};

const MountList = utils.List(MountPoint);
const FsList = utils.List(FileSystem);
const FsNode = FsList.Node;

var root: *Dentry = undefined;

var mount_list: MountList = .{};
var mount_lock = utils.Spinlock.init(.unlocked);

var fs_list: FsList = .{};
var fs_lock = utils.Spinlock.init(.unlocked);

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

pub fn mount(dentry: *Dentry, fs_name: []const u8, drive: ?*Drive) Error!void {
    if (dentry.inode.?.type != .directory) return error.BadDentry;

    const fs = getFs(fs_name) orelse return error.NoFs;

    try fs.ops.mount(dentry, drive);
}

pub export fn registerFs(fs: *FsNode) bool {
    if (fs.next != null or fs.prev != null) return false;

    fs_lock.lock();
    defer fs_lock.unlock();

    // Check if fs with same name exists
    {
        var fs_node = fs_list.first;

        while (fs_node) |other_fs| : (fs_node = other_fs.next) {
            if (other_fs.data.hash == fs.data.hash) return false;
        }
    }

    fs_list.append(fs);
    return true;
}

pub export fn unregisterFs(fs: *FsNode) void {
    {
        fs_lock.lock();
        defer fs_lock.unlock();

        fs_list.remove(fs);
    }

    fs.next = null;
    fs.prev = null;
}

pub inline fn getFs(name: []const u8) ?*FileSystem {
    return getFsEx(name.ptr, name.len);
}

pub inline fn lookup(path: []const u8) ?*Dentry {
    _ = path; return null;
}

export fn getFsEx(name_ptr: [*]const u8, name_len: usize) ?*FileSystem {
    const name = name_ptr[0..name_len];
    const hash = hashFn(name);

    fs_lock.lock();
    defer fs_lock.unlock();

    var node = fs_list.first;

    while (node) |fs| : (node = fs.next) {
        if (fs.data.hash == hash) return &fs.data;
    }

    return null;
}

fn getSymName(comptime Member: type, comptime ref: anytype) ?[]const u8 {
    const RefT = @TypeOf(ref);

    for (std.meta.declarations(Member)) |decl| {
        const decl_ref = @field(Member, decl.name);

        if (@TypeOf(decl_ref) != RefT) continue;
        if (ref == decl_ref) return decl.name;
    }

    return null;
}

fn exportFn(comptime Member: type, comptime ref: anytype) void {
    const name = getSymName(Member, ref) orelse unreachable;
    const api_name = @typeName(Member)++"."++name;

    //@compileLog(api_name);
    @export(ref, .{ .name = api_name });
}