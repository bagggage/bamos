//! # Virtual file system

// Copyright (C) 2024 Konstantin Pigulevskiy (bagggage@github)

pub const devfs = @import("vfs/devfs.zig");

const std = @import("std");

const dev = @import("dev.zig");
const utils = @import("utils.zig");
const log = std.log.scoped(.vfs);
const vm = @import("vm.zig");
const tmpfs = @import("vfs/tmpfs.zig");

const entries_oma_capacity = 512;
const super_oma_capacity = 32;

const max_lookup_table_size = utils.mb_size * 16;
const min_lookup_table_size = utils.mb_size;

const hashFn = std.hash.Fnv1a_32.hash;

pub const internals = @import("vfs/internals.zig");
pub const parts = @import("vfs/parts.zig");

pub const Drive = dev.classes.Drive;
pub const Partition = parts.Partition;

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

pub const Superblock = struct {
    drive: *Drive,
    part: *const Partition,

    part_offset: usize,

    block_size: u16,
    block_shift: u4,

    root: *Dentry = undefined,
    mount_point: *MountPoint = undefined,

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

pub const Path = struct {
    dentry: *const Dentry,

    pub fn format(self: Path, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        if (self.dentry.parent != root_dentry) {
            try format(.{.dentry = self.dentry.parent}, "", .{}, writer);
        }

        try writer.print("/{s}", .{self.dentry.name.str()});
    }
};

pub const Dentry = struct {
    pub const List = utils.SList(Dentry);
    pub const Node = List.Node;

    pub const Operations = struct {
        pub const LookupFn = *const fn(*const Dentry, []const u8) ?*Dentry;
        pub const MakeDirectoryFn = *const fn(*const Dentry, *Dentry) Error!void;
        pub const CreateFileFn = *const fn(*const Dentry, *Dentry) Error!void;

        lookup: LookupFn,
        makeDirectory: MakeDirectoryFn,
        createFile: CreateFileFn,
    };

    pub const Name = struct {
        pub const Union = union {
            const short_len = 32;

            short: [short_len:0]u8,
            long: []u8,
        };

        value: Union = undefined,
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
    super: *Superblock,
    inode: *Inode,
    ops: *Operations,

    child: List = .{},

    lock: utils.Spinlock = .{},

    pub var oma = vm.SafeOma(LookupEntry).init(entries_oma_capacity);

    pub inline fn new() ?*Dentry {
        return &(oma.alloc() orelse return null).data.value.data;
    }

    pub inline fn delete(self: *Dentry) void {
        oma.free(self.getCacheEntry());
    }

    pub inline fn getNode(self: *Dentry) *Node {
        return @fieldParentPtr("data", self);
    }

    pub inline fn getCacheEntry(self: *Dentry) *LookupEntry {
        const entry: *LookupEntry.Data = @fieldParentPtr("value", self.getNode());
        return @fieldParentPtr("data", entry);
    }

    pub fn init(self: *Dentry, name: []const u8, super: *Superblock, inode: *Inode, ops: *Operations) !void {
        try self.name.init(name);

        self.parent = self;
        self.super = super;
        self.inode = inode;
        self.ops = ops;
        self.child = .{};
        self.lock = .{};
    }

    pub fn deinit(self: *Dentry) void {
        self.deleteChilds();
        self.name.deinit();

        self.inode.delete();
    }

    pub fn exchange(self: *Dentry, super: *Superblock, inode: *Inode, ops: *Dentry.Operations) void {
        self.deleteChilds();
        self.inode.delete();

        self.super = super;
        self.inode = inode;
        self.ops = ops;
    }

    pub fn lookup(self: *Dentry, child_name: []const u8) ?*Dentry {
        std.debug.assert(self.inode.type == .directory);

        const hash = self.calcHash(child_name);
        const child = getLookupCache(hash);

        if (child == null) {
            const new_child = self.ops.lookup(self, child_name) orelse return null;

            self.addChild(new_child);

            log.debug("new dentry: {s}: inode: {}", .{new_child.name.str(), new_child.inode.index});

            insertLookupCache(hash, new_child);

            return new_child;
        }

        return child;
    }

    pub fn makeDirectory(self: *Dentry, name: []const u8) Error!*Dentry {
        const dir_dentry = try self.createLike(name);
        errdefer { dir_dentry.name.deinit(); dir_dentry.delete(); }

        try self.ops.makeDirectory(self, dir_dentry);
        self.addChild(dir_dentry);

        return dir_dentry;
    }

    pub fn createFile(self: *Dentry, name: []const u8) Error!*Dentry {
        const file_dentry = try self.createLike(name);
        errdefer { file_dentry.name.deinit(); file_dentry.delete(); }

        try self.ops.createFile(self, file_dentry);
        self.addChild(file_dentry);

        return file_dentry;
    }

    pub fn addChild(self: *Dentry, child: *Dentry) void {
        child.parent = self;
        self.child.prepend(child.getNode());
    }

    pub inline fn path(self: *const Dentry) Path {
        return Path{ .dentry = self };
    }

    inline fn cacheName(dentry: *const Dentry) void {
        const hash = dentry.parent.calcHash(dentry.name.str());
        insertLookupCache(hash, dentry);
    }

    inline fn uncacheName(dentry: *const Dentry) bool {
        const hash = dentry.parent.calcHash(dentry.name.str());
        return removeLookupCache(hash) == dentry;
    }

    fn createLike(self: *const Dentry, name: []const u8) !*Dentry {
        const dentry = Dentry.new() orelse return error.NoMemory;
        errdefer dentry.delete();

        try dentry.name.init(name);
        errdefer dentry.name.deinit();

        dentry.super = self.super;
        dentry.ops = self.ops;

        return dentry;
    }

    fn calcHash(parent: *const Dentry, name: []const u8) u64 {
        const ptr = @intFromPtr(parent.inode);

        var hasher = std.hash.Fnv1a_64.init();
        hasher.update(name);
        hasher.update(std.mem.asBytes(&ptr));

        return hasher.final();
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
const LookupTable = utils.HashTable(u64, Dentry.Node, opaque{
    pub fn hash(key: u64) u64 { return key; } 
    pub fn eql(a: u64, b: u64) bool { return a == b; }
});
const LookupEntry = LookupTable.EntryNode;

var root_dentry: *Dentry = undefined;

var lookup_table: LookupTable = .{};
var lookup_lock = utils.Spinlock.init(.unlocked);

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
    const total_mem_size = vm.PageAllocator.getTotalPages() * vm.page_size;
    const table_size = std.math.clamp(
        (total_mem_size / 100) / 2, // 0.5% of total memory
        min_lookup_table_size,
        max_lookup_table_size
    );
    const table_capacity = std.math.divCeil(usize, table_size, @sizeOf(LookupTable.Bucket)) catch unreachable;

    try lookup_table.init(@truncate(table_capacity));

    log.info("lookup table: capacity: {}, size: {} KB", .{table_capacity,table_size / utils.kb_size});

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
    const result = mountEx(
        dentry,
        fs_name.ptr, fs_name.len,
        drive, part_idx
    );

    if (result < 0) return utils.intToErr(Error, result);
}

pub export fn registerFs(fs: *FsNode) bool {
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

pub export fn unregisterFs(fs: *FsNode) void {
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
    return getFsEx(name.ptr, name.len);
}

pub fn lookup(dir: ?*Dentry, path: []const u8) !*Dentry {
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

pub inline fn getRoot() *Dentry {
    return root_dentry;
}

export fn mountEx(dentry: *Dentry, fs_name_ptr: [*]const u8, fs_name_len: usize, drive: ?*Drive, part_idx: u32) i16 {    
    mountImpl(dentry, fs_name_ptr[0..fs_name_len], drive, part_idx) catch |err| {
        return utils.errToInt(err);
    };

    return 0;
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

fn mountImpl(dentry: *Dentry, fs_name: []const u8, drive: ?*Drive, part_idx: u32) Error!void {
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

        const hash = parent.calcHash(dentry.name.str());

        _ = removeLookupCache(hash);
        insertLookupCache(hash, super.root);
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

fn initRoot() !void {
    try tmpfs.init();

    const tmp_fs = getFs("tmpfs") orelse return error.NoTmpfs;
    const super = try tmp_fs.mount(undefined, undefined);

    root_dentry = super.root;

    log.info("tmpfs was mounted as \"{s}\"", .{root_dentry.name.str()});
}

fn getLookupCache(hash: u64) ?*Dentry {
    lookup_lock.lock();
    defer lookup_lock.unlock();

    return &(lookup_table.get(hash) orelse return null).data;
}

fn insertLookupCache(hash: u64, dentry: *Dentry) void {
    lookup_lock.lock();
    defer lookup_lock.unlock();

    lookup_table.insert(hash, dentry.getCacheEntry());
}

fn removeLookupCache(hash: u64) ?*Dentry {
    lookup_lock.lock();
    defer lookup_lock.unlock();

    return &(lookup_table.remove(hash) orelse return null).data.value.data;
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