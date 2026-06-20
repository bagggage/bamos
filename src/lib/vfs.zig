//! # Virtual file system

// Copyright (C) 2024-2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const bindings = @import("bindings.zig");

const config = @import("config.zig");
const dev = @import("dev.zig");
const lib = @import("lib.zig");
const log = std.log.scoped(.vfs);
const sys = @import("sys.zig");
const vm = @import("vm.zig");

const hashFn = std.hash.Fnv1a_32.hash;

pub const devfs = @import("vfs/drivers/devfs.zig");
pub const internals = @import("vfs/internals.zig");
pub const parts = @import("vfs/parts.zig");

pub const Dentry = @import("vfs/Dentry.zig");
pub const Drive = dev.classes.Drive;
pub const File = @import("vfs/File.zig");
pub const Inode = @import("vfs/Inode.zig");
pub const lookup_cache = @import("vfs/lookup-cache.zig");
pub const Partition = parts.Partition;
pub const Pipe = @import("vfs/Pipe.zig");
pub const Superblock = @import("vfs/Superblock.zig");

pub const Error = vm.Error || parts.Error || error {
    BadFileDescriptor,
    BadOperation,
    BadPipe,
    BadSuperblock,
    Busy,
    Exists,
    InvalidArgs,
    IoFailed,
    NoAccess,
    NoEnt,
    NoFs,
    NoSpace,
    NoTTY,
    NotDirectory,
    NotRegularFile,
};

/// Filesystem context.
/// 
/// Contains unique FS data per each moutn point.
pub const Context = union(enum) {
    pub const Tag = enum(u2) {
        none  = 0,
        super = 1,
        virt  = 2,
        root  = 3,
    };

    pub const Ptr = union {
        super: *Superblock,
        virt: *Context.Virt,
        root: *Dentry,
    };

    pub const Handle = struct {
        ptr: Ptr,
        tag: Tag,
    };

    /// Represents virtual filesystem context.
    pub const Virt = struct {
        root: *Dentry = bad_root,
        data: lib.AnyData = .{},

        pub inline fn getMountPoint(self: *Virt) *MountPoint {
            const ctx: *Context = @fieldParentPtr("virt", self);
            return @fieldParentPtr("ctx", ctx);
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
    const List = lib.rcu.DoublyLinkedList;
    const Node = List.Node;

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

    ref_count: lib.atomic.RefCount(u32) = .init(0),

    ops: Operations = undefined,
    dentry_ops: Dentry.Operations = undefined,

    node: Node = .{},

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

    pub inline fn fromNode(node: *Node) *FileSystem {
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
    root: *const Dentry,

    pub inline fn format(self: Path, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return bindings.getInstance().vfs.path.format(self, writer);
    }
};

pub const MountPoint = struct {
    const List = lib.rcu.DoublyLinkedList;
    const Node = List.Node;

    fs: *FileSystem,
    dentry: *Dentry,

    ctx: Context,
    node: Node = .{},

    pub fn init(fs: *FileSystem, dentry: *Dentry, ctx: Context) MountPoint {
        dentry.ref();
        ctx.getFsRoot().ref();

        return .{
            .fs = fs,
            .dentry = dentry,
            .ctx = ctx
        };
    }

    pub inline fn deinit(self: *MountPoint) void {
        self.ctx.getFsRoot().deref();
        self.dentry.deref();
    }

    // TODO: Replace with `vm.obj` framework
    pub inline fn new() ?*MountPoint {
        return vm.gpa.create(MountPoint);
    }

    pub inline fn free(self: *MountPoint) void {
        vm.gpa.free(self);
    }

    pub inline fn fromNode(node: *Node) *MountPoint {
        return @fieldParentPtr("node", node);
    }

    pub inline fn getHiddenDentry(self: *MountPoint) *Dentry {
        return self.dentry;
    }

    pub inline fn getRootDentry(self: *MountPoint) *Dentry {
        return self.ctx.getFsRoot();
    }
};

pub const CreateOptions = struct {
    perm: u16 = Permissions.makeInt(.rw, .rw, .r),
    uid: u16 = 0,
    gid: u16 = 0,
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
            (@intFromEnum(user) & @intFromEnum(Role.user))    |
            (@intFromEnum(group) & @intFromEnum(Role.group))  |
            (@intFromEnum(others) & @intFromEnum(Role.others))
        ;
    }

    pub inline fn mask(perm: Permissions, role: Role) u16 {
        return @intFromEnum(perm) & @intFromEnum(role);
    }

    pub inline fn add(perm: Permissions, rhs: Permissions) Permissions {
        return @enumFromInt(@intFromEnum(perm) | @intFromEnum(rhs));
    }

    pub inline fn remove(perm: Permissions, rhs: Permissions) Permissions {
        return @enumFromInt(@intFromEnum(perm) & ~@intFromEnum(rhs));
    }

    pub inline fn checkAccess(perm: Permissions, access: Permissions) bool {
        return (@intFromEnum(access) & @intFromEnum(perm)) == @intFromEnum(access);
    }

    pub inline fn format(perm: Permissions, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return bindings.getInstance().vfs.permission.format(perm, writer);
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

pub inline fn mount(dentry: *Dentry, fs_name: []const u8, blk_dev: ?*devfs.BlockDev) Error!*Dentry {
    return bindings.getInstance().vfs.mount(dentry, fs_name, blk_dev);
}

pub inline fn tryMount(dentry: *Dentry, blk_dev: *devfs.BlockDev) Error!*Dentry {
    return bindings.getInstance().vfs.tryMount(dentry, blk_dev);
}

pub inline fn registerFs(fs: *FileSystem) bool {
    return bindings.getInstance().vfs.registerFs(fs);
}

pub inline fn unregisterFs(fs: *FileSystem) void {
    bindings.getInstance().unregisterFs(fs);
}

pub inline fn getFs(name: []const u8) ?*FileSystem {
    return bindings.getInstance().vfs.getFs(name);
}

pub inline fn lookup(root: ?*Dentry, dir: ?*Dentry, path: []const u8) Error!*Dentry {
    return lookupRaw(root, dir, path, true);
}

pub inline fn lookupRaw(root: ?*Dentry, dir: ?*Dentry, path: []const u8, follow_links: bool) Error!*Dentry {
    return bindings.getInstance().vfs.lookupRaw(root, dir, path, follow_links);
}

/// Same as `vfs.lookup`, but returns `null` if dentry not found.
/// If any other error occurs, prints error message.
pub inline fn tryLookup(root: ?*Dentry, dir: ?*Dentry, path: []const u8) ?*Dentry {
    return bindings.getInstance().vfs.tryLookup(root, dir, path);
}

pub inline fn resolveSymLink(sym_dent: *Dentry) Error!*Dentry {
    return bindings.getInstance().vfs.resolveSymLink(sym_dent);
}

pub inline fn changeRoot(new: *Dentry) Error!void {
    return bindings.getInstance().vfs.changeRoot(new);
}

pub inline fn isFsRoot(dentry: *const Dentry) bool {
    return dentry.getMountPoint().getRootDentry() == dentry;
}

/// Returns the actual root of the entire VFS
/// and increments reference counter.
pub inline fn getRoot() *Dentry {
    const root_dentry = bindings.getInstance().vfs.getRootWeak();
    root_dentry.ref();

    return root_dentry;
}

/// Returns the actual root of the entire VFS,
/// but don't increments reference counter.
pub inline fn getRootWeak() *Dentry {
    return bindings.getInstance().vfs.getRootWeak();
}

/// Returns root dentry of initrd filesystem if mounted,
/// `null` otherwise.
pub inline fn getInitRamDisk() ?*Dentry {
    return tryLookup(getRootWeak(), null, "initrd");
}

/// Returns current system time that might be
/// used for files timestamps.
pub inline fn getTime() sys.time.Time {
    return sys.time.getCachedTime();
}
