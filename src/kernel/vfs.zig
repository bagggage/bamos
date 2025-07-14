//! # Virtual file system

// Copyright (C) 2024-2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const api = utils.api.scoped(@This());
const dev = @import("dev.zig");
const log = std.log.scoped(.vfs);
const sys = @import("sys.zig");
const utils = @import("utils.zig");
const vm = @import("vm.zig");

const hashFn = std.hash.Fnv1a_32.hash;

pub const devfs = @import("vfs/drivers//devfs.zig");
pub const initrd = @import("vfs/drivers/initrd.zig");
pub const internals = @import("vfs/internals.zig");
pub const lookup_cache = @import("vfs/lookup-cache.zig");
pub const parts = @import("vfs/parts.zig");
pub const tmpfs = @import("vfs/drivers/tmpfs.zig");

pub const Dentry = @import("vfs/Dentry.zig");
pub const Drive = dev.classes.Drive;
pub const File = @import("vfs/File.zig");
pub const Inode = @import("vfs/Inode.zig");
pub const Partition = parts.Partition;
pub const Superblock = @import("vfs/Superblock.zig");

pub const Error = parts.Error || error {
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

/// Filesystem context.
/// 
/// Contains unique FS data per each moutn point.
pub const Context = union(enum) {
    pub const Ptr = union {
        super: *Superblock,
        virt: *Context.Virt,
    };

    /// Represents virtual filesystem context.
    pub const Virt = struct {
        root: *Dentry,
        data: utils.AnyData = .{},

        pub inline fn getMountPoint(self: *Virt) *MountPoint {
            return @fieldParentPtr("virt", self);
        }
    };

    super: *Superblock,
    virt: Virt,

    pub fn getMountPoint(self: *Context) *MountPoint {
        return switch (self.*) {
            .super => |s| s.mount_point,
            .virt => |v| v.getMountPoint()
        };
    }

    pub fn getFsRoot(self: *Context) *Dentry {
        return switch (self.*) {
            .super => |s| s.root,
            .virt => |v| v.root
        };
    }
};

pub const FileSystem = struct {
    pub const DriveOperations = struct {
        pub const MountFn = *const fn(*Drive, *Partition) Error!*Superblock;
        pub const UnmountFn = *const fn(*Superblock) void;

        mount: MountFn,
        unmount: UnmountFn
    };
    pub const VirtualOperations = struct {
        pub const MountFn = *const fn() Error!Context.Virt;
        pub const UnmountFn = *const fn(*Context.Virt) void;

        mount: MountFn,
        unmount: UnmountFn,
    };

    pub const Operations = union(enum) {
        drive: DriveOperations,
        virt: VirtualOperations,
    };

    name: []const u8,
    hash: u32,

    ops: Operations = undefined,
    dentry_ops: Dentry.Operations = undefined,

    pub fn init(
        comptime name: []const u8,
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
                .ops = ops,
                .dentry_ops = dentry_ops,
            }
        };
    }

    pub inline fn mountDrive(
        self: *const FileSystem,
        drive: *Drive,
        part: *Partition
    ) Error!*Superblock {
        return self.ops.drive.mount(drive, part);
    }

    pub inline fn mountVirtual(self: *const FileSystem) Error!Context.Virt {
        return self.ops.virt.mount();
    }

    pub inline fn kind(self: *const FileSystem) enum{virtual,device} {
        return switch (self.ops) {
            .drive => .device,
            .virt => .virtual,
        };
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

    ctx: Context,
};

const MountList = utils.List(MountPoint);
const MountNode = MountList.Node;
const FsList = utils.List(FileSystem);
const FsNode = FsList.Node;

export var root_dentry: *Dentry = undefined;

var mount_list: MountList = .{};
var mount_lock = utils.Spinlock.init(.unlocked);

var fs_list: FsList = .{};
var fs_lock = utils.Spinlock.init(.unlocked);

const AutoInit = opaque {
    pub var file_systems = .{
        devfs,
        @import("vfs/drivers/initrd.zig"),
        @import("vfs/drivers/ext2.zig")
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

pub fn open(dentry: *Dentry) Error!*File {
    const file = vm.obj.new(File) orelse return error.NoMemory;
    try dentry.open(file);
    return file;
}

pub inline fn close(file: *File) void {
    file.close();
    vm.obj.free(File, file);
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

/// Same as `vfs.lookup`, but returns `null` if dentry not found.
/// If any other error occurs, prints error message.
pub fn tryLookup(dir: ?*Dentry, path: []const u8) ?*Dentry {
    return lookup(dir, path) catch |err| {
        if (err != Error.NoEnt) {
            log.err("lookup for \"{s}\" failed: {s}", .{path, @errorName(err)});
        }
        return null;
    };
}

/// Returns the actual root dentry of the entire VFS.
pub inline fn getRoot() *Dentry {
    return root_dentry;
}

/// Returns root dentry of initrd filesystem if mounted,
/// `null` otherwise.
pub fn getInitRamDisk() ?*Dentry {
    return tryLookup(root_dentry, initrd.mount_dir_name);
}

/// Returns current system time that might be
/// used for files timestamps.
pub inline fn getTime() sys.time.Time {
    return sys.time.getCachedTime();
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
        fs.kind() == .device and
        (drive == null or part_idx >= drive.?.parts.len)
    ) return error.InvalidArgs;

    const node = vm.alloc(MountNode) orelse return error.NoMemory;
    errdefer vm.free(node);

    // Init mount point
    const fs_root = switch (fs.kind()) {
        .device => try mountDriveFs(fs, dentry, node, drive.?, part_idx),
        .virtual => try mountVirtualFs(fs, dentry, node),
    };

    // Swap entries
    {
        const parent = dentry.parent;
        parent.addChild(fs_root);

        const hash = lookup_cache.calcHash(parent, dentry.name.str());

        _ = lookup_cache.remove(hash);
        lookup_cache.insert(hash, fs_root);
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

fn mountDriveFs(
    fs: *FileSystem, dentry: *Dentry,
    node: *MountNode, drive: *Drive, part_idx: u32
) !*Dentry {
    const super = try fs.mountDrive(drive, drive.getPartition(part_idx).?);
    node.data = .{
        .dentry = dentry,
        .fs = fs,
        .ctx = .{ .super = super },
    };
    super.root.ctx = .{ .super = super };
    super.mount_point = &node.data;

    return super.root;
}

fn mountVirtualFs(fs: *FileSystem, dentry: *Dentry, node: *MountNode) !*Dentry {
    const virt = try fs.mountVirtual();
    node.data = .{
        .dentry = dentry,
        .fs = fs,
        .ctx = .{ .virt = virt },
    };
    virt.root.ctx = .{ .virt = &node.data.ctx.virt };

    return virt.root;
}

fn lookupEx(dir: ?*Dentry, path: []const u8) Error!*Dentry {
    if (path.len == 0) return error.InvalidArgs;

    log.debug("lookup for: \"{s}\"", .{path});

    var ent: ?*Dentry = if (path[0] == '/') root_dentry else dir orelse root_dentry;
    var it = std.mem.splitScalar(
        u8,
        if (path[0] == '/') path[1..] else path[0..],
        '/'
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

        const child = ent.?.lookup(element);
        ent.?.deref();

        ent = child;
    }

    return ent orelse error.NoEnt;
}

fn initRoot() !void {
    try tmpfs.init();

    const tmp_fs = getFs("tmpfs") orelse return error.NoTmpfs;
    const virt = try tmp_fs.mountVirtual();

    root_dentry = virt.root;
    root_dentry.ref();

    log.info("tmpfs was mounted as \"{s}\"", .{root_dentry.name.str()});
}