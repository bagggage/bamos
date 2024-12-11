// @noexport

//! # Ext2 filesystem driver

// Copyright (C) 2024 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const cache = @import("../vm.zig").cache;
const log = std.log.scoped(.ext2);
const utils = @import("../utils.zig");
const vfs = @import("../vfs.zig");

const super_offset = 1024;
const super_magic = 0xEF53;
const root_inode = 2;

// Little-endian
const Superblock = extern struct {
    const State = enum(u16) {
        clean = 1,
        has_errors = 2
    };
    const ErrorHandling = enum(u16) {
        ignore = 1,
        remount_ro = 2,
        panic = 3
    };
    const Os = enum(u32) {
        linux = 0,
        gnu_hurd = 1,
        masix = 2,
        freebsd = 3,

        other = 4
    };

    total_inodes: u32,
    total_blocks: u32,

    blocks_num: u32,

    free_blocks: u32,
    free_inodes: u32,

    sb_block: u32,

    // log2(block size) - 10
    block_shift: u32,

    // log2(frag size) - 10
    frag_shift: u32,

    blocks_per_group: u32,
    frags_per_group: u32,
    inodes_per_group: u32,

    mount_time: u32,
    write_time: u32,

    mount_num: u16,
    mount_max: u16,

    magic: u16,

    state: State,
    errors: ErrorHandling,

    minor_ver: u16,

    check_time: u32,
    check_interval: u32,

    os: Os,

    major_ver: u32,

    uid: u16,
    gid: u16,

    // Extended fields (major_ver > 1)

    first_inode: u32,

    inode_size: u16,
    sb_block_group: u16,

    optional_feat: u32,
    required_feat: u32,
    readonly_feat: u32,

    fs_id: [2]u64,

    name: [16]u8,
    mount_path: [64]u8,

    compression: u32,
    prealloc_blocks_for_file: u8,
    prealloc_blocks_for_dir: u8,
    rsrvd_gdts_num: u16,

    journal_id: [2]u64,

    journal_inode: u32,
    journal_device: u32,
    head_orphan_inode_list: u32,

    rsrvd1: [18]u8,
    bgd_size: u16,

    comptime {
        std.debug.assert(@offsetOf(Superblock, "bgd_size") == 254);
    }

    pub inline fn check(self: *const Superblock) bool {
        return (self.magic == super_magic) and (self.major_ver < 1 or self.bgd_size <= @sizeOf(BlockGroupDescriptor));
    }
};

const BlockGroupDescriptor = extern struct {
    block_bitmap: u32,
    inode_bitmap: u32,

    inode_table: u32,

    free_blocks: u16,
    free_inodes: u16,

    dirs_num: u16,

    rsrvd: u16,
    rsrvd2: [3]u32,

    comptime {
        std.debug.assert(@sizeOf(BlockGroupDescriptor) == 32);
    }
};

const DentryType = enum(u8) {
    unknown = 0,
    regular_file = 1,
    directory = 2,
    char_device = 3,
    block_device = 4,
    fifo = 5,
    socket = 6,
    symbolic_link = 7
};

const Inode = extern struct {
    const Type = enum(u4) {
        fifo = 0x1,
        char_dev = 0x2,
        directory = 0x4,
        block_dev = 0x6,
        regular_file = 0x8,
        symlink = 0xA,
        socket = 0xB,
        _
    };

    type_perm: packed struct {
        perm: u12,
        type: Type,

        comptime {
            std.debug.assert(@sizeOf(@This()) == 2);
        }
    },
    uid: u16,

    size_lo: u32,

    access_time: u32,
    create_time: u32,
    modify_time: u32,
    delete_time: u32,

    gid: u16,

    links_num: u16,
    sectors_num: u32,
    flags: u32,

    os_specific: u32,

    direct_ptrs: [12]u32,
    single_ptr: u32,
    double_ptr: u32,
    triple_ptr: u32,

    generation_num: u32,
    ext_attr_block: u32,

    size_hi: u32,

    frag_block: u32,
    os_specific2: u32,

    rsrvd: [2]u32,

    comptime {
        std.debug.assert(@sizeOf(Inode) == 128);
    }

    pub fn cache(self: *const Inode, idx: u32) !*vfs.Inode {
        const inode = vfs.Inode.new() orelse return error.NoMemory;

        inode.* = .{
            .index = idx,
            .type = switch (self.type_perm.type) {
                .fifo => .fifo,
                .char_dev => .char_device,
                .directory => .directory,
                .block_dev => .block_device,
                .regular_file => .regular_file,
                .socket => .socket,
                .symlink => .symbolic_link,
                _ => .directory
            },
            .perm = @as(u16, @bitCast(self.type_perm)) & 0x0FFF,
            .size = @as(usize, self.size_hi) << 32 | self.size_lo,

            .create_time = self.create_time,
            .access_time = self.access_time,
            .modify_time = self.modify_time,

            .gid = self.gid,
            .uid = self.uid,

            .links_num = self.links_num,

            .fs_data = utils.AnyData.from(@constCast(self)),
        };

        return inode;
    }
};

const Dentry = extern struct {
    const Iterator = struct {
        cursor: cache.Cursor = cache.Cursor.blank(),
        dent: *Dentry = undefined,
        inode: *const Inode,

        block_i: u16 = 0,
        blocks_num: u16,

        inner_offset: u16 = undefined,

        pub fn next(self: *Iterator, super: *vfs.Superblock) !?*Dentry {
            if (!self.cursor.isValid()) return try self.readNext(super);

            self.inner_offset += self.dent.size;
            if (self.inner_offset >= super.block_size) {
                self.block_i += 1;
                return try self.readNext(super);
            }

            self.dent = @ptrFromInt(@intFromPtr(self.dent) + self.dent.size);
            return self.dent;
        }

        pub fn deinit(self: *Iterator, super: *vfs.Superblock) void {
            super.drive.putCache(&self.cursor);
        }

        fn readNext(self: *Iterator, super: *vfs.Superblock) !?*Dentry {
            self.inner_offset = 0;

            if (self.block_i < self.blocks_num) {
                const block_idx = self.inode.direct_ptrs[self.block_i];

                log.debug("read block: {}, i:{}", .{block_idx,self.block_i});

                const buffer = try readBlock(super, block_idx, &self.cursor);
                self.dent = @alignCast(@ptrCast(buffer.ptr));

                return self.dent;
            }

            return null;
        }
    };

    inode: u32,
    size: u16,
    name_len: u8,
    type: u8,

    _name: u8,

    pub inline fn name(self: *Dentry) []u8 {
        return @as([*]u8, @ptrCast(&self._name))[0..self.name_len];
    }
};

const DentryStubOps = vfs.internals.DentryStubOps(.ext2);

var fs = vfs.FileSystem.init(
    "ext2",
    .device,
    .{
        .mount = mount,
        .unmount = undefined
    },
    .{
        .lookup = dentryLookup,
        .makeDirectory = DentryStubOps.makeDirectory,
        .createFile = DentryStubOps.createFile
    }
);

pub fn init() !void {
    if (!vfs.registerFs(&fs)) return error.Busy;
}

pub fn deinit() void {
    vfs.unregisterFs(&fs);
}

pub fn mount(drive: *vfs.Drive, part: *const vfs.Partition) vfs.Error!*vfs.Superblock {
    const part_offset = drive.lbaToOffset(part.lba_start);
    const part_super_offset = part_offset + super_offset;

    // Read superblock
    var super_cache = try drive.readCached(part_super_offset);
    errdefer drive.putCache(&super_cache);

    const ext_super = super_cache.asObject(Superblock);
    if (!ext_super.check()) return error.BadSuperblock;

    const super = vfs.Superblock.new() orelse return error.NoMemory;
    errdefer super.delete();

    // Init super
    {
        const block_size = @as(u16, 1) << @truncate(ext_super.block_shift + 10);
        super.init(drive, part, block_size, ext_super);
    }

    // Init root dentry
    {
        var cache_cursor = cache.Cursor.blank();
        defer drive.putCache(&cache_cursor);

        const inode = try readInode(super, root_inode, &cache_cursor);
        if (inode.type_perm.type != .directory) return error.BadInode;

        const dentry = vfs.Dentry.new() orelse return error.NoMemory;
        dentry.init("/", super, try inode.cache(root_inode), &fs.data.dentry_ops) catch unreachable;

        super.root = dentry;
    }

    log.info("mounting on drive: {s}", .{drive.base_name});

    return super;
}

fn readBgd(super: *vfs.Superblock, group: u32, cursor: *cache.Cursor) !*BlockGroupDescriptor {
    const ext_super = super.fs_data.as(Superblock).?;
    const offset = super.part_offset + ((ext_super.sb_block + 1) * super.block_size) + (group * @sizeOf(BlockGroupDescriptor));
    try super.drive.readCachedNext(cursor, offset);

    return cursor.asObject(BlockGroupDescriptor);
}

fn readBlock(super: *vfs.Superblock, block: u32, cursor: *cache.Cursor) ![]u8 {
    const offset = super.part_offset + super.blockToOffset(block);

    try super.drive.readCachedNext(cursor, offset);
    return cursor.asSlice().ptr[0..super.block_size];
}

fn readInode(super: *vfs.Superblock, inode: u32, cursor: *cache.Cursor) !*Inode {
    const ext_super = super.fs_data.as(Superblock).?;

    const idx = inode - 1;
    const group = idx / ext_super.inodes_per_group;
    const inner_idx = idx % ext_super.inodes_per_group;

    const bgd = try readBgd(super, group, cursor);
    const offset = super.part_offset + super.blockToOffset(bgd.inode_table) + (inner_idx * ext_super.inode_size);

    try super.drive.readCachedNext(cursor, offset);
    return cursor.asObject(Inode);
}

fn readDirectory(super: *vfs.Superblock, inode: *vfs.Inode, cursor: *cache.Cursor) !Dentry.Iterator {
    const blocks_num = inode.size >> super.block_shift;
    const ext_inode = try readInode(super, inode.index, cursor);

    return Dentry.Iterator{
        .inode = ext_inode,
        .blocks_num = @truncate(blocks_num),
    };
}

fn dentryLookup(parent: *const vfs.Dentry, name: []const u8) ?*vfs.Dentry {
    const super = parent.super;

    var cache_cursor = cache.Cursor.blank();
    defer super.drive.putCache(&cache_cursor);

    var dent_it = readDirectory(super, parent.inode, &cache_cursor) catch return null;
    defer dent_it.deinit(super);

    const ext_dent = blk: {
        while (dent_it.next(super) catch return null) |dent| {
            if (std.mem.eql(u8, name, dent.name())) break :blk dent;
        }

        return null;
    };

    // Init new vfs dentry
    const child_dentry = vfs.Dentry.new() orelse return null;
    child_dentry.init(ext_dent.name(), super, undefined, &fs.data.dentry_ops) catch {
        child_dentry.delete();
        return null;
    };

    const child_inode = readInode(super, ext_dent.inode, &cache_cursor) catch return null;
    child_dentry.inode = child_inode.cache(ext_dent.inode) catch {
        child_dentry.delete();
        return null;
    };

    return child_dentry;
}
