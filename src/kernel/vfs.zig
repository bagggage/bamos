//! # Virtual file system

// Copyright (C) 2024 Konstantin Pigulevskiy (bagggage@github)

pub const devfs = @import("vfs/devfs.zig");

const std = @import("std");

const dev = @import("dev.zig");
const utils = @import("utils.zig");
const log = std.log.scoped(.vfs);
const vm = @import("vm.zig");

const entries_oma_capacity = 512;
const super_oma_capacity = 32;

const hashFn = std.hash.Fnv1a_32.hash;

pub const parts = @import("vfs/parts.zig");
pub const Drive = dev.classes.Drive;
pub const Partition = parts.Partition;

pub const Error = error {
    InvalidArgs,
    IoFailed,
    Busy,
    NoMemory,
    NoFs,
    BadDentry,
    BadInode,
    BadSuperblock,
};

pub const FileSystem = struct {
    pub const Operations = struct {
        pub const MountT = *const fn(*Dentry, *Drive, *Partition) Error!*Superblock;
        pub const UnmountT = *const fn(*Superblock) void;

        mount: MountT,
        unmount: UnmountT
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
        dentry: *Dentry,
        drive: *Drive,
        part: *Partition
    ) Error!*Superblock {
        return self.ops.mount(dentry, drive, part);
    }
};

pub const Superblock = struct {
    drive: *Drive,
    part: *const Partition,

    part_offset: usize,

    block_size: u16,
    block_shift: u4,

    root: *Dentry = undefined,

    fs_data: utils.AnyData,

    pub var oma = vm.SafeOma(Superblock).init(super_oma_capacity);

    pub inline fn new() ?*Superblock {
        return oma.alloc();
    }

    pub inline fn delete(self: *Superblock) void {
        oma.free(self);
    }

    pub fn init(
        self: *Superblock,
        drive: ?*Drive,
        part: ?*const Partition,
        block_size: u16,
        fs_data: ?*anyopaque
    ) void {
        self.* = .{
            .drive = drive orelse undefined,
            .part = part orelse undefined,
            .part_offset = if (part) |p| drive.?.lbaToOffset(p.lba_start) else 0,
            .block_size = block_size,
            .block_shift = std.math.log2_int(u16, block_size),
            .fs_data = utils.AnyData.from(fs_data)
        };
    }

    pub inline fn blockToOffset(self: *const Superblock, block: usize) usize {
        return block << self.block_shift;
    }

    pub inline fn offsetToBlock(self: *const Superblock, offset: usize) usize {
        return offset >> self.block_shift;
    }

    pub inline fn offsetModBlock(self: *const Superblock, offset: usize) u16 {
        const mask = comptime ~@as(u16, 0);
        return offset & ~(mask << self.block_shift);
    }
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
    pub const List = utils.SList(Dentry);
    pub const Node = List.Node;

    pub const Operations = struct {
        pub const FillT = *const fn(*Dentry) void;

        fill: FillT,
    };

    pub const Name = struct {
        pub const Union = union {
            const short_len = 32;

            short: [short_len:0]u8,
            long: []u8,
        };

        value: Union = undefined,
        hash: u32 = 0,
        len: u8 = 0,

        pub fn init(self: *Name, name: []const u8) !void {    
            if (name.len < Union.short_len) {
                self.value = .{ .short = undefined };

                @memcpy(self.value.short[0..name.len], name);
                self.value.short[name.len] = 0;
            }
            else {
                const buffer: [*]u8 = @ptrCast(vm.malloc(name.len) orelse return error.NoMemory);
                @memcpy(buffer[0..name.len], name);

                self.value = .{ .long = buffer[0..name.len] };
            }

            self.hash = hashFn(name);
            self.len = @truncate(name.len);
        }

        pub fn move(self: *Name, other: *Name) void {
            std.debug.assert(other.len == 0);

            if (self.len >= Union.short_len) {
                other.value = .{ .long = self.value.long };
            } else {
                other.value = .{ .short = undefined };
                @memcpy(
                    other.value.short[0..self.len + 1],
                    self.value.short[0..self.len + 1]
                );
            }

            other.hash = self.hash;
            other.len = self.len;
        }

        pub fn deinit(self: *Name) void {
            if (self.len >= Union.short_len) vm.free(self.value.long.ptr);
        }

        pub inline fn str(self: *const Name) []const u8 {
            return if (self.len >= Union.short_len) self.value.long else self.value.short[0..self.len];
        }
    };

    name: Name,

    parent: *Dentry,
    inode: ?*Inode = null,
    ops: *Operations,

    child: List = .{},

    lock: utils.Spinlock = .{},

    pub var oma = vm.SafeOma(Node).init(entries_oma_capacity);

    pub inline fn new() ?*Dentry {
        return &(oma.alloc() orelse null).data;
    }

    pub inline fn delete(self: *Dentry) void {
        oma.free(self.getNode());
    }

    pub inline fn getNode(self: *Dentry) *Node {
        return @fieldParentPtr("data", self);
    }

    pub fn init(self: *Dentry, name: []const u8, parent: ?*Dentry, inode: ?*Inode, ops: *Operations) !void {
        try self.name.init(name);

        self.parent = parent orelse self;
        self.inode = inode;
        self.ops = ops;
        self.lock = .{};
    }

    pub fn deinit(self: *Dentry) void {
        self.deleteChilds();
        self.name.deinit();

        if (self.inode) |inode| {
            // TODO: Call fs-driver cleanup functions
            inode.delete();
        }
    }

    pub fn exchange(self: *Dentry, inode: *Inode, ops: *Dentry.Operations) void {
        self.deleteChilds();

        if (self.inode) |i| {
            // TODO: Call fs-driver cleanup functions
            i.delete();
        }

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

    fn deleteChilds(self: *Dentry) void {
        var node = self.child.first;
        while (node) |child| : (node = child.next) {
            child.data.deinit();
            child.data.delete();
        }
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

var root_dentry: Dentry = undefined;

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
    const root_inode = Inode.new() orelse return error.NoMemory;
    @memset(std.mem.asBytes(root_inode), 0);

    root_inode.links_num = 1;
    root_inode.type = .directory;

    root_dentry.name.init("/") catch unreachable;
    root_dentry.parent = &root_dentry;
    root_dentry.inode = root_inode;

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

pub fn mount(dentry: *Dentry, fs_name: []const u8, drive: ?*Drive, part_idx: u32) Error!void {
    if (dentry.inode.?.type != .directory) return error.BadDentry;

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
            .device => try fs.mount(dentry, drive.?, drive.?.getPartition(part_idx).?),
            .virtual => try fs.mount(dentry, undefined, undefined)
        };

        node.data = .{
            .dentry = dentry,
            .fs = fs,
            .super = super,
        };
    }

    if (drive) |d| {
        log.info("{s} on {s}:part:{} is mounted to \"{s}\"", .{
            fs.name, d.base_name, part_idx, dentry.name.str()
        });
    } else {
        log.info("{s} is mounted to \"{s}\"", .{fs.name, dentry.name.str()});
    }

    mount_lock.lock();
    defer mount_lock.unlock();

    mount_list.append(node);
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

pub inline fn getRoot() *Dentry {
    return &root_dentry;
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