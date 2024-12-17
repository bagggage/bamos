//! # Virtual file system

// Copyright (C) 2024 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const api = utils.api.scoped(@This());
const dev = @import("dev.zig");
const log = std.log.scoped(.vfs);
const tmpfs = @import("vfs/tmpfs.zig");
const utils = @import("utils.zig");
const vm = @import("vm.zig");

const hashFn = std.hash.Fnv1a_32.hash;

pub const devfs = @import("vfs/devfs.zig");
pub const internals = @import("vfs/internals.zig");
pub const lookup_cache = @import("vfs/lookup-cache.zig");
pub const parts = @import("vfs/parts.zig");

pub const Dentry = @import("vfs/Dentry.zig");
pub const Drive = dev.classes.Drive;
pub const Inode = @import("vfs/Inode.zig");
pub const Partition = parts.Partition;
pub const Superblock = @import("vfs/Superblock.zig");

pub const Error = error {
    InvalidArgs,
    IoFailed,
    Busy,
    NoMemory,
    NoFs,
    NoEnt,
    BadOperation,
    BadDentry,
    BadInode,
    BadSuperblock,
};

pub const FileSystem = struct {
    pub const Operations = struct {
        pub const MountFn = *const fn(*Drive, *Partition) Error!*Superblock;
        pub const UnmountFn = *const fn(*Superblock) void;

        mount: MountFn,
        unmount: UnmountFn
    };
    pub const Type = enum {
        virtual,
        device
    };

    name: []const u8,
    hash: u32,

    kind: Type,

    ops: Operations = undefined,
    dentry_ops: Dentry.Operations = undefined,

    pub fn init(
        comptime name: []const u8,
        kind: Type,
        ops: Operations,
        dentry_ops: Dentry.Operations
    ) FsNode {
        comptime var buffer: [name.len]u8 = .{0} ** name.len;
        const lower = comptime std.ascii.lowerString(&buffer, name);
        const hash = comptime hashFn(lower);

        return .{
            .data = .{
                .name = name,
                .hash = hash,
                .kind = kind,
                .ops = ops,
                .dentry_ops = dentry_ops,
            }
        };
    }

    pub inline fn mount(
        self: *const FileSystem,
        drive: *Drive,
        part: *Partition
    ) Error!*Superblock {
        return self.ops.mount(drive, part);
    }
};

pub const Path = struct {
    dentry: *const Dentry,

    pub fn format(self: Path, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        if (self.dentry.parent != root_dentry) {
            try format(.{.dentry = self.dentry.parent}, "", .{}, writer);
        }

        try writer.print("/{s}", .{self.dentry.name.str()});
    }
};

pub const MountPoint = struct {
    fs: *FileSystem,
    dentry: *Dentry,

    super: *Superblock,
};

const MountList = utils.List(MountPoint);
const MountNode = MountList.Node;
const FsList = utils.List(FileSystem);
const FsNode = FsList.Node;
const LookupTable = utils.HashTable(u64, Dentry.Node, opaque{
    pub fn hash(key: u64) u64 { return key; } 
    pub fn eql(a: u64, b: u64) bool { return a == b; }
});
const LookupEntry = LookupTable.EntryNode;

export var root_dentry: *Dentry = undefined;

var mount_list: MountList = .{};
var mount_lock = utils.Spinlock.init(.unlocked);

var fs_list: FsList = .{};
var fs_lock = utils.Spinlock.init(.unlocked);

const AutoInit = opaque {
    pub var file_systems = .{
        @import("vfs/initrd.zig"),
        @import("vfs/ext2.zig")
    };
};

pub fn init() !void {
    try lookup_cache.init();
    try initRoot();

    inline for (AutoInit.file_systems) |Fs| {
        Fs.init() catch |err| {
            log.err("failed to initialize '"++@typeName(Fs)++"' filesystem: {s}", .{@errorName(err)});  
        };
    }
}

pub fn deinit() void {
    inline for (AutoInit.file_systems) |Fs| {
        Fs.deinit();
    }

    // TODO: unmount tmpfs
    tmpfs.deinit();
}

pub inline fn mount(dentry: *Dentry, fs_name: []const u8, drive: ?*Drive, part_idx: u32) Error!void {
    return api.externFn(mountEx, .mountEx)(dentry, fs_name, drive, part_idx);
}

pub fn registerFs(fs: *FsNode) bool {
    if (fs.next != null or fs.prev != null) return false;

    {
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
    }

    log.info("{s} was registered", .{fs.data.name});

    return true;
}

pub fn unregisterFs(fs: *FsNode) void {
    comptime api.exportFn(unregisterFs);

    {
        fs_lock.lock();
        defer fs_lock.unlock();

        fs_list.remove(fs);
    }

    fs.next = null;
    fs.prev = null;

    log.info("{s} was removed", .{fs.data.name});
}

pub inline fn getFs(name: []const u8) ?*FileSystem {
    return api.externFn(getFsEx, .getFsEx)(name);
}

pub inline fn lookup(dir: ?*Dentry, path: []const u8) Error!*Dentry {
    return api.externFn(lookupEx, .lookupEx)(dir, path);
}

pub inline fn getRoot() *Dentry {
    return root_dentry;
}

fn getFsEx(name: []const u8) ?*FileSystem {
    const hash = hashFn(name);

    fs_lock.lock();
    defer fs_lock.unlock();

    var node = fs_list.first;

    while (node) |fs| : (node = fs.next) {
        if (fs.data.hash == hash) return &fs.data;
    }

    return null;
}

fn mountEx(dentry: *Dentry, fs_name: []const u8, drive: ?*Drive, part_idx: u32) Error!void {
    if (
        dentry.inode.type != .directory or
        (dentry == root_dentry)
    ) return error.BadDentry;

    const fs = getFs(fs_name) orelse return error.NoFs;

    if (
        fs.kind == .device and
        (drive == null or part_idx >= drive.?.parts.len)
    ) return error.InvalidArgs;

    const node = vm.alloc(MountNode) orelse return error.NoMemory;
    errdefer vm.free(node);

    // Init mount point
    {
        const super = switch (fs.kind) {
            .device => try fs.mount(drive.?, drive.?.getPartition(part_idx).?),
            .virtual => try fs.mount(undefined, undefined)
        };

        node.data = .{
            .dentry = dentry,
            .fs = fs,
            .super = super,
        };
        super.mount_point = &node.data;

        // Swap entries
        const parent = dentry.parent;
        super.root.parent = parent;

        const hash = lookup_cache.calcHash(parent, dentry.name.str());

        _ = lookup_cache.remove(hash);
        lookup_cache.insert(hash, super.root);
    }

    if (drive) |d| {
        log.info("{s} on {s}:part:{} is mounted to \"{s}\"", .{
            fs.name, d.base_name, part_idx, dentry.path()
        });
    } else {
        log.info("{s} is mounted to \"{s}\"", .{fs.name, dentry.path()});
    }

    mount_lock.lock();
    defer mount_lock.unlock();

    mount_list.append(node);
}

fn lookupEx(dir: ?*Dentry, path: []const u8) Error!*Dentry {
    if (path.len == 0) return error.InvalidArgs;

    log.debug("lookup for: \"{s}\"", .{path});

    var ent: ?*Dentry = if (path[0] == '/') root_dentry else dir orelse root_dentry;
    var it = std.mem.split(
        u8,
        if (path[0] == '/') path[1..] else path[0..],
        "/"
    );

    while (it.next()) |element| {
        if (element.len == 0 or ent == null) break;
        if (ent.?.inode.type != .directory) return error.BadDentry;

        if (element[0] == '.') {
            if (element.len == 1) {
                continue;
            } else if (element.ptr[1] == '.' and element.len == 2) {
                ent = ent.?.parent;
                continue;
            }
        }

        ent = ent.?.lookup(element);
    }

    return ent orelse error.NoEnt;
}

fn initRoot() !void {
    try tmpfs.init();

    const tmp_fs = getFs("tmpfs") orelse return error.NoTmpfs;
    const super = try tmp_fs.mount(undefined, undefined);

    root_dentry = super.root;

    log.info("tmpfs was mounted as \"{s}\"", .{root_dentry.name.str()});
}