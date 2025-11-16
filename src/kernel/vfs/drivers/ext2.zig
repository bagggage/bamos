// @noexport

//! # Ext2 filesystem driver

// Copyright (C) 2024-2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const cache = @import("../../vm.zig").cache;
const lib = @import("../../lib.zig");
const log = std.log.scoped(.ext2);
const vfs = @import("../../vfs.zig");

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

    /// log2(block size) - 10
    block_shift: u32,

    /// log2(frag size) - 10
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

    // Extended fields (major_ver >= 1)

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
    const direct_ptrs_num = 12;

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

    direct_ptrs: [direct_ptrs_num]u32,
    indir_ptrs: [3]u32,

    generation_num: u32,
    ext_attr_block: u32,

    size_hi: u32,

    frag_block: u32,
    os_specific2: u32,

    rsrvd: [2]u32,

    comptime {
        std.debug.assert(@sizeOf(Inode) == 128);
    }

    /// Data block iterator
    const BlockIter = struct {
        const Location = struct {
            inner_idx: u32,
            indir_level: u2,
        };

        inner_idx: u32,
        indir_level: u2,

        cursor: cache.Cursor = .blank(),

        ptrs: [*]u32 = undefined,
        ptr_stack: [2]u32 = .{ 0, 0 },

        ptr_per_blk_shift: u5,

        super: *vfs.Superblock,
        inode: *const Inode,

        pub inline fn init(begin_idx: u32, super: *vfs.Superblock, inode: *const Inode) !BlockIter {
            const ptr_per_blk_shift = super.block_shift - std.math.log2(@sizeOf(u32));
            const location = calcPtrStartLocation(
                begin_idx, ptr_per_blk_shift
            );

            var self: BlockIter = .{
                .inner_idx = location.inner_idx,
                .indir_level = location.indir_level,
                .ptr_per_blk_shift = ptr_per_blk_shift,
                .super = super,
                .inode = inode
            };
            try self.decomposeStartLocation();

            return self;
        }

        pub inline fn deinit(self: *BlockIter) void {
            self.super.drive.putCache(&self.cursor);
        }

        pub inline fn next(self: *BlockIter) !u32 {
            if (self.indir_level == 0) return self.nextDirectPtr();

            return self.nextIndirPtr();
        }

        inline fn ptrsPerBlock(self: *const BlockIter) u32 {
            return @as(u32, 1) << self.ptr_per_blk_shift;
        }

        fn nextDirectPtr(self: *BlockIter) !u32 {
            const ptr = self.inode.direct_ptrs[self.inner_idx];
            self.inner_idx +%= 1;

            if (self.inner_idx >= Inode.direct_ptrs_num) {
                @branchHint(.unlikely);
                self.indir_level = 1;
                self.inner_idx = 0;

                try self.readPtrBlock(self.inode.indir_ptrs[0]);
            }

            return ptr;
        }

        fn nextIndirPtr(self: *BlockIter) !u32 {
            // Have to process next pointers block ?
            if (self.inner_idx >= self.ptrsPerBlock()) {
                @branchHint(.unlikely);
                try self.nextIndirBlock();
            }

            const ptr = self.ptrs[self.inner_idx];
            self.inner_idx +%= 1;

            return ptr;
        }

        fn nextIndirBlock(self: *BlockIter) !void {
            self.inner_idx = 0;

            var carry: u1 = 1;
            var n = self.indir_level - 1;
            while (n > 0) : (n -= 1) {
                const idx = self.ptr_stack[n - 1] +% carry;

                if (idx >= self.ptrsPerBlock()) {
                    @branchHint(.unlikely);

                    self.ptr_stack[n - 1] = 0;
                    carry = 1;
                } else {
                    self.ptr_stack[n - 1] = idx;
                    carry = 0;
                    break;
                }
            }

            if (carry > 0) {
                @branchHint(.unlikely);
                self.indir_level += 1;
            }

            try self.readPtrBlock(self.inode.indir_ptrs[self.indir_level - 1]);

            for (0..self.indir_level - 1) |i| {
                const idx = self.ptr_stack[i];
                try self.readPtrBlock(self.ptrs[idx]);
            }
        }

        fn decomposeStartLocation(self: *BlockIter) !void {
            if (self.indir_level == 0) return;

            try self.readPtrBlock(self.inode.indir_ptrs[self.indir_level - 1]);

            // Shift to get number of ptrs that we skip buy 
            var shift = self.ptr_per_blk_shift * (self.indir_level - 1);
            for (0..self.indir_level - 1) |i| {
                self.ptr_stack[i] = lib.misc.divByPowerOfTwo(u32, self.inner_idx, shift);
                self.inner_idx = lib.misc.modByPowerOfTwo(u32, self.inner_idx, shift);

                shift -= self.ptr_per_blk_shift;
                try self.readPtrBlock(self.ptrs[self.ptr_stack[i]]);
            }
        }

        fn readPtrBlock(self: *BlockIter, block: u32) !void {
            const blk_data = try readBlock(
                self.super,
                block,
                &self.cursor
            );
            self.ptrs = @ptrCast(@alignCast(blk_data.ptr));
        }

        fn calcPtrStartLocation(begin_idx: u32, ptr_per_blk_shift: u5) Location {
            if (begin_idx < Inode.direct_ptrs_num) {
                return .{
                    .indir_level = 0,
                    .inner_idx = begin_idx
                };
            }

            var idx = begin_idx - Inode.direct_ptrs_num;
            var shift = ptr_per_blk_shift;
            var level: u2 = 1;

            while (level < 3) : (level += 1) {
                // calculate modulo
                const ptrs_per_level = @as(u32, 1) << shift;

                if (ptrs_per_level > idx) break;

                // ptrs_per_blk^2
                shift += shift;
                idx -= ptrs_per_level;
            }

            return .{
                .indir_level = level,
                .inner_idx = idx
            };
        }

        test "Inode.calcPtrStartLocation" {
            // 128 pointers per block
            const ptr_per_blk_shift = 7;
            const expect = std.testing.expect;

            var loc = calcPtrStartLocation(0, ptr_per_blk_shift);
            try expect(loc.indir_level == 0 and loc.inner_idx == 0);

            loc = calcPtrStartLocation(10, ptr_per_blk_shift);
            try expect(loc.indir_level == 0 and loc.inner_idx == 10);

            loc = calcPtrStartLocation(127 + 12, ptr_per_blk_shift);
            try expect(loc.indir_level == 1 and loc.inner_idx == 127);

            loc = calcPtrStartLocation(128 + 12, ptr_per_blk_shift);
            try expect(loc.indir_level == 2 and loc.inner_idx == 0);

            loc = calcPtrStartLocation(1024, ptr_per_blk_shift);
            try expect(loc.indir_level == 2 and loc.inner_idx == 884);

            loc = calcPtrStartLocation(16534, ptr_per_blk_shift);
            try expect(loc.indir_level == 3 and loc.inner_idx == 10);

            loc = calcPtrStartLocation(2113676, ptr_per_blk_shift);
            try expect(loc.indir_level == 3 and loc.inner_idx == 2097152);
        }
    };

    pub fn makeCache(self: *const Inode, idx: u32) !*vfs.Inode {
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

            .links_num = self.links_num
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

const file_ops: vfs.File.Operations = .{
    .read = fileRead,
};

var fs = vfs.FileSystem.init(
    "ext2",
    .{ .drive = .{
        .mount = mount,
        .unmount = undefined
    }},
    .{
        .lookup = dentryLookup,

        .open = dentryOpen,
        .close = dentryClose
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

    log.debug("ver: {}.{}", .{ext_super.major_ver, ext_super.minor_ver});
    log.debug("optional: 0x{x}, required: 0x{x}, read-only: 0x{x}", .{
        ext_super.optional_feat, ext_super.required_feat, ext_super.readonly_feat
    });

    const super = vfs.Superblock.new() orelse return error.NoMemory;
    errdefer super.free();

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
        errdefer dentry.free();

        dentry.setup("/", undefined, try inode.makeCache(root_inode), &fs.dentry_ops) catch unreachable;
        super.root = dentry;
    }

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
    const super = parent.ctx.super;

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
    const child_inode = readInode(super, ext_dent.inode, &cache_cursor) catch return null;

    const child_dentry = vfs.Dentry.new() orelse return null;
    const vfs_inode = child_inode.makeCache(ext_dent.inode) catch {
        child_dentry.free();
        return null;
    };

    child_dentry.setup(name, parent.ctx, vfs_inode, &fs.dentry_ops) catch {
        child_dentry.free();
        vfs_inode.free();
        return null;
    };

    return child_dentry;
}

fn dentryOpen(_: *const vfs.Dentry, file: *vfs.File) vfs.Error!void {
    file.ops = &file_ops;
}

fn dentryClose(_: *const vfs.Dentry, _: *vfs.File) void {}

fn fileRead(dentry: *const vfs.Dentry, offset: usize, buffer: []u8) vfs.Error!usize {
    const inode = dentry.inode;
    const super = dentry.ctx.super;

    if (offset >= inode.size) return 0;

    const end = std.mem.min(usize, &.{ offset + buffer.len, inode.size });

    const begin_blk = super.offsetToBlock(offset);
    const end_blk = super.offsetToBlock(end - 1) + 1;

    var inode_cache = cache.Cursor.blank();
    defer super.drive.putCache(&inode_cache);

    const ext_inode = try readInode(super, inode.index, &inode_cache);

    var ptr_iter: Inode.BlockIter = try .init(@truncate(begin_blk), super, ext_inode);
    defer ptr_iter.deinit();

    var blk_cache = cache.Cursor.blank();
    defer super.drive.putCache(&blk_cache);

    log.debug("blocks: {} - {}", .{begin_blk, end_blk});

    var buf_offset: usize = 0;
    for (begin_blk..end_blk) |i| {
        const blk_ptr = try ptr_iter.next();
        var data = try readBlock(super, blk_ptr, &blk_cache);

        log.debug("read block: {}", .{blk_ptr});

        const buf_start = if (i == begin_blk) super.offsetModBlock(offset) else 0;
        const buf_end = if (i == end_blk - 1) super.offsetModBlock(end - 1) + 1 else super.block_size;
        const buf_size = buf_end - buf_start;

        @memcpy(
            buffer[buf_offset..buf_offset + buf_size],
            data[buf_start..buf_end]
        );

        buf_offset += buf_size;
    }

    return buf_offset;
}