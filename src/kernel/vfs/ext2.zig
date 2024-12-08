// @noexport

//! # Ext2 filesystem driver

// Copyright (C) 2024 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const cache = @import("../vm.zig").cache;
const log = std.log.scoped(.ext2);
const vfs = @import("../vfs.zig");
const utils = @import("../utils.zig");

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

const Dentry = struct {
    inode: u32,
    size: u16,
    name_len: u8,
    type: u8,

    _name: u8,

    pub inline fn name(self: *Dentry) []u8 {
        return @as([*]u8, @ptrCast(&self._name))[0..self.name_len];
    }

    pub inline fn next(self: *Dentry) ?*Dentry {
        const dent: *Dentry = @ptrFromInt(@intFromPtr(self) + self.size);

        return if (dent.inode == 0) null else dent;
    }
};

var fs = vfs.FileSystem.init(
    "ext2",
    .device,
    .{
        .mount = mount,
        .unmount = undefined
    },
    .{
        .lookup = dentryLookup,
    }
);

pub fn init() !void {
    if (!vfs.registerFs(&fs)) return error.Busy;
}

pub fn deinit() void {
    vfs.unregisterFs(&fs);
}

pub fn mount(dentry: *vfs.Dentry, drive: *vfs.Drive, part: *const vfs.Partition) vfs.Error!*vfs.Superblock {
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
        var cache_iter = cache.Iterator.blank();
        defer drive.putCache(&cache_iter);

        const inode = try readInode(super, root_inode, &cache_iter);

        if (inode.type_perm.type != .directory) return error.BadInode;

        dentry.exchange(super, try inode.cache(root_inode), &fs.data.dentry_ops);
    }

    log.info("mounting on drive: {s}", .{drive.base_name});

    return super;
}

fn readBgd(super: *vfs.Superblock, group: u32, iter: *cache.Iterator) !*BlockGroupDescriptor {
    const ext_super = super.fs_data.as(Superblock).?;
    const offset = super.part_offset + ((ext_super.sb_block + 1) * super.block_size) + (group * @sizeOf(BlockGroupDescriptor));
    try super.drive.readCachedNext(iter, offset);

    return iter.asObject(BlockGroupDescriptor);
}

fn readBlock(super: *vfs.Superblock, block: u32, iter: *cache.Iterator) ![]u8 {
    const offset = super.part_offset + super.blockToOffset(block);

    try super.drive.readCachedNext(iter, offset);
    return iter.asSlice().ptr[0..super.block_size];
}

fn readInode(super: *vfs.Superblock, inode: u32, iter: *cache.Iterator) !*Inode {
    const ext_super = super.fs_data.as(Superblock).?;

    const idx = inode - 1;
    const group = idx / ext_super.inodes_per_group;
    const inner_idx = idx % ext_super.inodes_per_group;

    const bgd = try readBgd(super, group, iter);
    const offset = super.part_offset + super.blockToOffset(bgd.inode_table) + (inner_idx * ext_super.inode_size);

    try super.drive.readCachedNext(iter, offset);
    return iter.asObject(Inode);
}

fn readDirectory(super: *vfs.Superblock, inode: *Inode, iter: *cache.Iterator) !?*Dentry {
    const block_idx = inode.direct_ptrs[0];
    if (block_idx == 0) return null;

    const block = try readBlock(super, inode.direct_ptrs[0], iter);

    return @alignCast(@ptrCast(block.ptr));
}

fn dentryLookup(parent: *const vfs.Dentry, name: []const u8) ?*vfs.Dentry {
    const super = parent.super;

    var cache_iter = cache.Iterator.blank();
    defer super.drive.putCache(&cache_iter);

    const inode = readInode(super, parent.inode.index, &cache_iter) catch return null;
    const dir = blk: {
        if (readDirectory(super, inode, &cache_iter) catch return null) |first| {
            var dent: ?*Dentry = first;

            while (dent) |d| : (dent = d.next()) {
                //log.debug("dent: {s}", .{d.name()});

                if (std.mem.eql(u8, name, d.name())) break :blk d;
            }
        }

        return null;
    };

    const child_dentry = vfs.Dentry.new() orelse return null;
    child_dentry.init(dir.name(), undefined, super, undefined, &fs.data.dentry_ops) catch {
        child_dentry.delete();
        return null;
    };

    const child_inode_idx = dir.inode;
    const child_inode = readInode(super, dir.inode, &cache_iter) catch return null;

    child_dentry.inode = child_inode.cache(child_inode_idx) catch {
        child_dentry.delete();
        return null;
    };

    return child_dentry;
}
