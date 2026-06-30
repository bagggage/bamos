//! # Temporary memory-based filesystem
//! 
//! This is a simple memory-based temporary file system.
//! Its primary purpose is to serve as the root file system during the boot process.
//! It provides flexibility and allows for the temporary mounting of other file systems.
//! Ultimately, it facilitates the mounting of the main root file system, replacing the current one.
//! 
//! It can also be mounted during regular operation; however,
//! any data written to it is not preserved and remains in RAM only until it is unmounted.

// Copyright (C) 2024-2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const log = std.log.scoped(.tmpfs);
const lib = @import("../../lib.zig");
const vfs = @import("../../vfs.zig");
const vm = @import("../../vm.zig");

const EntryKind = enum {
    directory,
    file
};

pub const Context = packed struct(usize) {
    pub const max_inodes = std.math.maxInt(u16);
    pub const bitmap_size = max_inodes / lib.byte_size;

    const bitmap_rank = vm.bytesToRank(bitmap_size);

    bitmap: lib.BitmapUnbounded,

    pub fn init() vm.Error!Context {
        const phys = vm.PageAllocator.alloc(bitmap_rank) orelse return error.NoMemory;
        const bytes: [*]u8 = @ptrFromInt(vm.getVirtLma(phys));

        const bitmap: lib.BitmapUnbounded = .init(bytes[0..bitmap_size], false);
        return .{ .bitmap = bitmap };
    }

    pub fn deinit(self: Context) void {
        const phys = vm.getPhysLma(self.bitmap.bytes);
        vm.PageAllocator.free(phys, bitmap_rank);
    }

    pub fn allocateInodeIndex(self: Context) ?u32 {
        const index = self.bitmap.find(max_inodes, false) orelse return null;
        self.bitmap.set(index);

        return @truncate(index + 1);
    }

    pub fn reserveInodeIndex(self: Context, index: u32) error{Busy}!void {
        if (self.bitmap.get(index) != 0) return error.Busy;
        self.bitmap.set(index);
    }

    pub inline fn freeInodeIndex(self: Context, index: u32) void {
        self.bitmap.clear(index);
    }
};

pub const DentryOps = opaque {
    pub const lookup = dentryLookup;
    pub const iterate = dentryIterate;
    pub const link = dentryLink;
    pub const unlink = dentryUnlink;
    pub const updateInode = dentryUpdateInode;
    pub const deinitInode = vfs.internals.dentry_ops.default.deinitInode;
};

pub const dentry_ops = &fs.dentry_ops;
pub const file_ops = vfs.internals.file.Cached {
    .readCacheBlock = &fileReadCacheBlock,
};

var fs = vfs.FileSystem.init(
    "tmpfs",
    .{ .virt = .{
        .mount = mount,
        .unmount = undefined
    }},
    .{
        .open = dentryOpen,
        .lookup = dentryLookup,
        .iterate = dentryIterate,
        .link = dentryLink,
        .unlink = dentryUnlink,
        .updateInode = dentryUpdateInode,
        .deinitInode = vfs.internals.dentry_ops.default.deinitInode,
    },
);

pub fn init() !void {
    if (vfs.registerFs(&fs) == false) return error.Busy;
}

pub fn deinit() void {
    vfs.unregisterFs(&fs);
}

pub fn createRoot(
    inode_idx: u32,
    ops: *vfs.Dentry.Operations,
    opts: vfs.CreateOptions,
) vm.Error!*vfs.Dentry {
    const inode = try createInode(.directory, inode_idx, opts);
    errdefer inode.free();

    return createDentry("/", inode, .{ .tag = .none, .ptr = undefined }, ops);
}

pub fn createInode(kind: vfs.Inode.Type, index: u32, opts: vfs.CreateOptions) vm.Error!*vfs.Inode {
    const inode = vfs.Inode.new() orelse return error.NoMemory;
    errdefer inode.free();

    const time = vfs.getTime();
    inode.* = .{
        .index = index,
        .type = kind,
        .cache_ctrl = .{ .write_back = &vfs.internals.cache.noWriteBack },
        .access_time_sec = time.sec,
        .create_time_sec = time.sec,
        .modify_time_sec = time.sec,
        .access_time_ns = time.ns,
        .create_time_ns = time.ns,
        .modify_time_ns = time.ns,
        .links_num = 1,
        .gid = opts.gid,
        .uid = opts.uid,
        .perm = opts.perm,
    };

    return inode;
}

pub fn createDentry(
    name: []const u8,
    inode: *vfs.Inode,
    ctx: vfs.Context.Handle,
    ops: *vfs.Dentry.Operations,
) !*vfs.Dentry {
    const dentry = vfs.Dentry.new() orelse return error.NoMemory;
    errdefer dentry.free();

    try dentry.setup(name, ctx, inode, ops);
    // Prevent auto-freeing dentry
    dentry.ref();

    return dentry;
}

fn mount() vfs.Error!vfs.Context.Virt {
    const ctx: Context = try .init();
    errdefer ctx.deinit();

    const inode_idx = ctx.allocateInodeIndex() orelse unreachable;
    const root = try createRoot(inode_idx, dentry_ops, .{});

    return .{ .root = root, .data = .from(ctx) };
}

fn dentryOpen(_: *const vfs.Dentry, file: *vfs.File) vfs.Error!void {
    file.ops = &file_ops.ops;
}

fn dentryLookup(parent: *const vfs.Dentry, name: []const u8) ?*vfs.Dentry {
    const lock: *lib.sync.Spinlock = @constCast(&parent.lock);

    lock.lock();
    defer lock.unlock();

    var node = parent.child.first;
    while (node) |n| : (node = n.next) {
        const dentry = vfs.Dentry.fromNode(n);
        if (std.mem.eql(u8, dentry.name.str(), name)) return dentry;
    }

    return null;
}

fn dentryIterate(dentry: *const vfs.Dentry, iter: *vfs.Dentry.Iterator) vfs.Error!void {
    // Fill dot entries
    if (iter.pos == 0) {
        if (!iter.fillNext(".", dentry.inode.index, .directory)) return;
        iter.pos += 1;
    }

    if (iter.pos == 1) {
        if (!iter.fillNext("..", dentry.parent.inode.index, .directory)) return;
        iter.pos += 1;
    }

    var node = dentry.child.first;
    for (2..iter.pos) |_| {
        if (node) |n| {
            @branchHint(.likely);
            node = n.next;
        }

        return;
    }

    while (node) |n| : ({ node = n.next; iter.pos += 1; }) {
        const child = vfs.Dentry.fromNode(n);
        if (!iter.fillNext(
            child.name.str(), child.inode.index, child.inode.type
        )) {
            @branchHint(.unlikely);
            return;
        }
    }
}

fn dentryLink(dentry: *vfs.Dentry, inode: *vfs.Inode) vfs.Error!void {
    if (inode.index == 0) {
        const ctx = dentry.getVirtualCtx().data.as(Context);
        const index = ctx.allocateInodeIndex() orelse return error.NoSpace;

        inode.index = index;
    }

    // Prevent auto-freeing
    dentry.ref();
}

fn dentryUnlink(dentry: *const vfs.Dentry) vfs.Error!void {
    const mut_dentry: *vfs.Dentry = @constCast(dentry);
    const inode = dentry.inode;

    if (inode.type == .directory) {
        mut_dentry.lock.lock();
        defer mut_dentry.lock.unlock();

        if (mut_dentry.child.first != null) return error.NotEmpty;
    }

    mut_dentry.deref();
}

fn dentryUpdateInode(inode: *const vfs.Inode, update: vfs.Inode.Update) vfs.Error!void {
    switch (update) {
        .size => |s| {
            if (inode.type != .regular_file) return error.InvalidArgs;
            if (s.value <= inode.size) return;

            const avail_pages = vm.PageAllocator.getTotalPages() - vm.PageAllocator.getAllocatedPages();
            const avail_mem = avail_pages * vm.page_size;

            const increment = (s.value - inode.size);
            if (increment > (avail_mem / 2)) return error.NoSpace;
        },
        else => {},
    }
}

fn fileReadCacheBlock(_: *const vfs.Dentry, block: *vm.cache.Block) vfs.Error!void {
    @memset(block.asSlice(), 0);
}
