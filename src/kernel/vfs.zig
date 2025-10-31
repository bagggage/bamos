//! # Virtual file system

// Copyright (C) 2024-2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const api = utils.api.scoped(@This());
const dev = @import("dev.zig");
const log = std.log.scoped(.vfs);
const sys = @import("sys.zig");
const rcu = utils.rcu;
const utils = @import("utils.zig");
const vm = @import("vm.zig");

const hashFn = std.hash.Fnv1a_32.hash;

pub const devfs = @import("vfs/drivers/devfs.zig");
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

pub const Error = vm.Error || parts.Error || error {
    InvalidArgs,
    IoFailed,
    Busy,
    NoFs,
    NoEnt,
    NoAccess,
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
        root: *Dentry = bad_root,
        data: utils.AnyData = .{},

        pub inline fn getMountPoint(self: *Virt) *MountPoint {
            return @fieldParentPtr("virt", self);
        }

        pub inline fn validateRoot(self: *const Virt) bool {
            return self.root != bad_root;
        }
    };

    /// Fake dentry pointer. It's initial value of `root` field.
    /// Used to check if this field was set by a driver during mounting.
    pub const bad_root: *Dentry = @ptrFromInt(0xA0A0_0000_C0FF_0000);

    super: *Superblock,
    virt: Virt,

    pub fn getMountPoint(self: *const Context) *MountPoint {
        return switch (self.*) {
            .super => |s| s.mount_point,
            .virt => |v| v.getMountPoint()
        };
    }

    pub fn getFsRoot(self: *const Context) *Dentry {
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

    ref_count: utils.RefCount(u32) = .init(0),

    ops: Operations = undefined,
    dentry_ops: Dentry.Operations = undefined,

    node: rcu.List.Node = .{},

    pub fn init(
        comptime name: []const u8,
        ops: Operations,
        dentry_ops: Dentry.Operations
    ) FileSystem {
        comptime var buffer: [name.len]u8 = .{0} ** name.len;
        const lower = comptime std.ascii.lowerString(&buffer, name);
        const hash = comptime hashFn(lower);

        return .{
            .name = name,
            .hash = hash,
            .ops = ops,
            .dentry_ops = dentry_ops,
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

    pub inline fn fromNode(node: *rcu.List.Node) *FileSystem {
        return @fieldParentPtr("node", node);
    }

    pub inline fn ref(self: *FileSystem) void {
        self.ref_count.inc();
    }

    pub inline fn deref(self: *FileSystem) void {
        self.ref_count.dec();
    }
};

pub const Path = struct {
    dentry: *const Dentry,

    pub fn format(self: Path, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        const parent = self.dentry.parent;
        if (!std.mem.eql(u8, parent.name.str(), "/")) {
            try format(
                .{ .dentry = self.dentry.parent },&.{}, .{}, writer
            );
        }

        try writer.print("/{s}", .{self.dentry.name.str()});
    }
};

pub const MountPoint = struct {
    fs: *FileSystem,
    dentry: *Dentry,

    ctx: Context,
    node: rcu.List.Node = .{},

    pub fn init(
        self: *MountPoint, fs: *FileSystem,
        dentry: *Dentry, ctx: Context
    ) void {
        dentry.ref();
        ctx.getFsRoot().ref();

        self.* = .{
            .fs = fs,
            .dentry = dentry,
            .ctx = ctx
        };
    }

    pub inline fn deinit(self: *MountPoint) void {
        self.ctx.getFsRoot().deref();
        self.dentry.deref();
    }

    pub inline fn new() ?*MountPoint {
        return vm.alloc(MountPoint);
    }

    pub inline fn free(self: *MountPoint) void {
        vm.free(self);
    }

    pub inline fn fromNode(node: *rcu.List.Node) *MountPoint {
        return @fieldParentPtr("node", node);
    }

    pub inline fn getHiddenDentry(self: *MountPoint) *Dentry {
        return self.dentry;
    }

    pub inline fn getRootDentry(self: *MountPoint) *Dentry {
        return self.ctx.getFsRoot();
    }
};

pub const Permissions = enum(u16) {
    none = 0b000_000_000,
    x    = 0b001_001_001,
    w    = 0b010_010_010,
    r    = 0b100_100_100,
    rw   = 0b110_110_110,
    wx   = 0b011_011_011,
    rx   = 0b101_101_101,
    rwx  = 0b111_111_111,
    _,

    pub inline fn makeInt(user: Permissions, group: Permissions, others: Permissions) u16 {
        return
            @intFromEnum(user) & @intFromEnum(Role.user)   |
            @intFromEnum(group) & @intFromEnum(Role.group) |
            @intFromEnum(others) & @intFromEnum(Role.others)
        ;
    }

    pub inline fn mask(perm: Permissions, role: Role) u16 {
        return @intFromEnum(perm) & @intFromEnum(role);
    }
};

pub const Role = enum(u16) {
    others  = 0b111,
    group   = 0b111_000,
    user    = 0b111_000_000,

    group_others = 0b000_111_111,
    user_others  = 0b111_000_111,
    user_group   = 0b111_111_000,

    all = 0b111_111_111
};

export var root_dentry: *Dentry = undefined;

var mount_list: rcu.List = .{};
var fs_list: rcu.List = .{};

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

pub inline fn mount(dentry: *Dentry, fs_name: []const u8, blk_dev: ?*devfs.BlockDev) Error!*Dentry {
    return api.externFn(mountEx, .mountEx)(dentry, fs_name, blk_dev);
}

pub fn tryMount(dentry: *Dentry, blk_dev: *devfs.BlockDev) Error!*Dentry {
    const gen = fs_list.ctrl.readLock();
    defer fs_list.ctrl.readUnlock(gen);

    var curr_fs = getFirstFs();
    while (curr_fs) |fs| : (curr_fs = getNextFs(fs)) {
        if (fs.kind() == .virtual) continue;

        const fs_root = mountFs(dentry, fs, blk_dev) catch |err| {
            if (err == error.BadSuperblock) continue;

            fs.deref();
            return err;
        };

        fs.deref();
        return fs_root;
    }

    return error.BadSuperblock;
}

pub fn registerFs(fs: *FileSystem) bool {
    if (fs.node.next != null or fs.node.prev != null) return false;

    {
        fs_list.ctrl.writeLock();
        defer fs_list.ctrl.writeUnlock();

        // Check if fs with same name exists
        {
            var node = fs_list.first.raw;

            while (node) |n| : (node = n.next) {
                const other_fs = FileSystem.fromNode(n);
                if (other_fs.hash == fs.hash) return false;
            }
        }

        fs_list.appendRaw(&fs.node);
    }

    log.info("{s} was registered", .{fs.name});

    return true;
}

pub fn unregisterFs(fs: *FileSystem) void {
    comptime api.exportFn(unregisterFs);
    fs_list.remove(&fs.node);

    log.info("{s} was removed", .{fs.name});
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
            @branchHint(.unlikely);
            log.err("lookup for \"{s}\" failed: {s}", .{path, @errorName(err)});
        }
        return null;
    };
}

pub fn resolveSymLink(sym_dent: *Dentry) Error!*Dentry {
    if (sym_dent.inode.type != .symbolic_link) {
        @branchHint(.unlikely);
        return error.BadDentry;
    }

    // TODO: Implement.
    return error.BadOperation;
}

pub fn changeRoot(new: *Dentry) void {
    // TODO: Implement
    _ = new;
}

pub fn isMountPoint(dentry: *const Dentry) bool {
    const gen = mount_list.ctrl.readLock();
    defer mount_list.ctrl.readUnlock(gen);

    var node = mount_list.first.load(.acquire);
    while (node) |n| : (node = n.next) {
        const mnt_point = MountPoint.fromNode(n);
        if (mnt_point.getRootDentry() == dentry) return true;
    }

    return false;
}

/// Returns the actual root of the entire VFS
/// and increments reference counter.
pub inline fn getRoot() *Dentry {
    root_dentry.ref();
    return root_dentry;
}

/// Returns the actual root of the entire VFS,
/// but don't increments reference counter.
pub inline fn getRootWeak() *Dentry {
    return root_dentry;
}

/// Returns root dentry of initrd filesystem if mounted,
/// `null` otherwise.
pub fn getInitRamDisk() ?*Dentry {
    return tryLookup(getRoot(), initrd.mount_dir_name);
}

/// Returns current system time that might be
/// used for files timestamps.
pub inline fn getTime() sys.time.Time {
    return sys.time.getCachedTime();
}

fn getFirstFs() ?*FileSystem {
    const node = fs_list.first.load(.acquire) orelse return null;
    const fs = FileSystem.fromNode(node);

    fs.ref();
    return fs;
}

fn getNextFs(fs: *FileSystem) ?*FileSystem {
    defer fs.deref();

    const next = FileSystem.fromNode(fs.node.next orelse return null);
    next.ref();

    return next;
}

fn getFsEx(name: []const u8) ?*FileSystem {
    const hash = hashFn(name);

    const gen = fs_list.ctrl.readLock();
    defer fs_list.ctrl.readUnlock(gen);

    var node = fs_list.first.load(.acquire);
    while (node) |n| : (node = n.next) {
        const fs = FileSystem.fromNode(n);
        if (fs.hash == hash) {
            fs.ref();
            return fs;
        }
    }

    return null;
}

fn mountEx(dentry: *Dentry, fs_name: []const u8, blk_dev: ?*devfs.BlockDev) Error!*Dentry {
    if (
        dentry.inode.type != .directory or
        (dentry == root_dentry)
    ) return error.BadDentry;

    const fs = getFs(fs_name) orelse return error.NoFs;
    defer fs.deref();

    return mountFs(dentry, fs, blk_dev);
}

fn mountFs(dentry: *Dentry, fs: *FileSystem, blk_dev: ?*devfs.BlockDev) Error!*Dentry {
    if (
        fs.kind() == .device and
        blk_dev == null
    ) {
        @branchHint(.unlikely);
        return error.InvalidArgs;
    }

    const mnt_point = MountPoint.new() orelse return error.NoMemory;
    errdefer mnt_point.free();

    const fs_root = switch (fs.kind()) {
        .device => try mountDriveFs(fs, dentry, mnt_point, blk_dev.?),
        .virtual => try mountVirtualFs(fs, dentry, mnt_point),
    };

    // Swap dentries
    {
        const parent = dentry.parent;
        parent.addChild(fs_root);

        const hash = lookup_cache.calcHash(parent, dentry.name.str());

        _ = lookup_cache.remove(hash);
        lookup_cache.insert(hash, fs_root);
    }

    if (blk_dev) |blk| {
        log.info("{s} on {} is mounted to \"{s}\"", .{
            fs.name, blk.getName(), dentry.path()
        });
    } else {
        log.info("{s} is mounted to \"{s}\"", .{fs.name, dentry.path()});
    }

    mount_list.append(&mnt_point.node);
    return fs_root;
}

fn mountDriveFs(
    fs: *FileSystem, dentry: *Dentry,
    mnt_point: *MountPoint, blk_dev: *devfs.BlockDev
) !*Dentry {
    const super = try fs.mountDrive(blk_dev.getDrive(), blk_dev.getPartition());
    if (!super.validateRoot()) {
        @branchHint(.cold);
        log.err(
            "\"{s}\" driver don't set a valid root dentry on mount!",
            .{fs.name}
        );
        return error.BadSuperblock;
    }

    mnt_point.init(fs, dentry, .{ .super = super });
    super.root.ctx = .{ .super = super };
    super.mount_point = mnt_point;

    return super.root;
}

fn mountVirtualFs(fs: *FileSystem, dentry: *Dentry, mnt_point: *MountPoint) !*Dentry {
    const virt = try fs.mountVirtual();
    if (!virt.validateRoot()) {
        @branchHint(.cold);
        log.err(
            "\"{s}\" driver don't set a valid root dentry on mount!",
            .{fs.name}
        );
        return error.BadSuperblock;
    }

    mnt_point.init(fs, dentry, .{ .virt = virt });
    virt.root.ctx = .{ .virt = &mnt_point.ctx.virt };

    return virt.root;
}

fn lookupEx(dir: ?*Dentry, path: []const u8) Error!*Dentry {
    if (path.len == 0) return error.InvalidArgs;

    log.debug("lookup for: \"{s}\"", .{path});

    const start_dent = if (path[0] == '/') root_dentry else dir orelse root_dentry;

    var ent: ?*Dentry = start_dent;
    var it = std.mem.splitScalar(
        u8,
        if (path[0] == '/') path[1..] else path[0..],
        '/'
    );

    start_dent.ref();
    defer if (ent == start_dent) start_dent.deref();

    while (it.next()) |element| {
        const dentry = ent.?;
        errdefer dentry.deref();

        if (element.len == 0) continue;
        if (element[0] == '.') {
            if (element.len == 1) continue;

            if (element.ptr[1] == '.' and element.len == 2) {
                dentry.parent.ref();
                defer dentry.deref();

                ent = dentry.parent;
                continue;
            }
        }
    
        if (dentry.inode.type != .directory) return error.BadDentry;

        ent = dentry.lookup(element);
        dentry.deref();

        if (ent == null) break;
    }

    return ent orelse error.NoEnt;
}

fn initRoot() !void {
    try tmpfs.init();

    const mnt_point = MountPoint.new() orelse return error.NoMemory;
    errdefer mnt_point.free();

    const tmp_fs = getFs("tmpfs") orelse return error.NoTmpfs;
    defer tmp_fs.deref();

    {
        const virt = try tmp_fs.mountVirtual();
        defer root_dentry = virt.root;

        mnt_point.init(tmp_fs, virt.root, .{ .virt = virt });
        mount_list.prepend(&mnt_point.node);
    }

    log.info("tmpfs was mounted as \"{s}\"", .{root_dentry.name.str()});
}