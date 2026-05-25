// @noexport

//! # Ext2 filesystem driver

// Copyright (C) 2024-2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const cache = vfs.Drive.cache;
const lib = @import("../../lib.zig");
const log = std.log.scoped(.ext2);
const vfs = @import("../../vfs.zig");
const vm = @import("../../vm.zig");

const super_offset = 1024;
const super_magic = 0xEF53;
const root_inode = 2;

// Little-endian
const Superblock = extern struct {
    const State = enum(u16) {
        clean = 1,
        has_errors = 2,
    };
    const ErrorHandling = enum(u16) {
        ignore = 1,
        remount_ro = 2,
        panic = 3,
    };
    const Os = enum(u32) {
        linux = 0,
        gnu_hurd = 1,
        masix = 2,
        freebsd = 3,
        other = 4,
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
    symbolic_link = 7,
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
        _,

        fn toVfsType(self: Type) vfs.Inode.Type {
            return switch (self) {
                .fifo => .fifo,
                .char_dev => .char_device,
                .directory => .directory,
                .block_dev => .block_device,
                .regular_file => .regular_file,
                .socket => .socket,
                .symlink => .symbolic_link,
                _ => .unknown,
            };
        }

        fn fromVfsType(vfs_type: vfs.Inode.Type) Type {
            return switch (vfs_type) {
                .fifo => .fifo,
                .char_device => .char_dev,
                .directory => .directory,
                .block_device => .block_dev,
                .regular_file => .regular_file,
                .socket => .socket,
                .symbolic_link => .symlink,
                .unknown => unreachable,
            };
        } 
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

        cursor: cache.Cursor,

        ptrs: [*]const u32 = undefined,
        ptr_stack: [2]u32 = .{ 0, 0 },

        ptr_per_blk_shift: u5,

        super: *const vfs.Superblock,
        inode: *const Inode,

        pub inline fn init(begin_idx: u32, super: *const vfs.Superblock, inode: *const Inode) !BlockIter {
            const ptr_per_blk_shift = super.block_shift - std.math.log2(@sizeOf(u32));
            const location = calcPtrStartLocation(begin_idx, ptr_per_blk_shift);

            var self: BlockIter = .{
                .inner_idx = location.inner_idx,
                .indir_level = location.indir_level,
                .ptr_per_blk_shift = ptr_per_blk_shift,
                .cursor = .blank(super.drive),
                .super = super,
                .inode = inode,
            };
            try self.decomposeStartLocation();

            return self;
        }

        pub inline fn deinit(self: *BlockIter) void {
            self.cursor.close(.read);
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

            const ptr = try self.getIndirectPtr(self.inner_idx);
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
                try self.readPtrBlock(try self.getIndirectPtr(idx));
            }
        }

        fn decomposeStartLocation(self: *BlockIter) !void {
            if (self.indir_level == 0) return;

            try self.readPtrBlock(self.inode.indir_ptrs[self.indir_level - 1]);

            // Shift to get number of ptrs that we skip by
            var shift = self.ptr_per_blk_shift * (self.indir_level - 1);
            for (0..self.indir_level - 1) |i| {
                self.ptr_stack[i] = lib.misc.divByPowerOfTwo(u32, self.inner_idx, shift);
                self.inner_idx = lib.misc.modByPowerOfTwo(u32, self.inner_idx, shift);

                shift -= self.ptr_per_blk_shift;
                try self.readPtrBlock(try self.getIndirectPtr(self.ptr_stack[i]));
            }
        }

        fn readPtrBlock(self: *BlockIter, block: u32) !void {
            const offset = calcBlockOffset(self.super, block);
            try self.cursor.ensureCache(.read, offset);
            self.ptrs = @ptrCast(self.cursor.asObject(u32));
        }

        fn getIndirectPtr(self: *BlockIter, i: usize) !u32 {
            const offset = self.cursor.innerOffset() + (i * @sizeOf(u32));
            if (offset >= cache.block_size) {
                @branchHint(.unlikely);
                try self.cursor.seekAndEnsure(.read, cache.block_size);
            }
            return self.ptrs[i];
        }

        fn calcPtrStartLocation(begin_idx: u32, ptr_per_blk_shift: u5) Location {
            if (begin_idx < Inode.direct_ptrs_num) {
                return .{ .indir_level = 0, .inner_idx = begin_idx };
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

            return .{ .indir_level = level, .inner_idx = idx };
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
            .type = self.type_perm.type.toVfsType(),
            .perm = @as(u16, @bitCast(self.type_perm)) & 0x0FFF,
            .size = @as(usize, self.size_hi) << 32 | self.size_lo,

            // TODO: Implement write-back function
            .cache_ctrl = .{ .write_back = vfs.internals.cache.noWriteBackFail },

            .create_time = self.create_time,
            .access_time = self.access_time,
            .modify_time = self.modify_time,

            .gid = self.gid,
            .uid = self.uid,

            .links_num = self.links_num,
        };

        return inode;
    }
};

const Dentry = extern struct {
    const Iterator = struct {
        cursor: cache.Cursor,
        dent: *const Dentry = undefined,
        inode: *const Inode,

        block_i: u16 = 0,
        blocks_num: u16,

        inner_offset: u16 = 0,

        pub fn next(self: *Iterator, super: *const vfs.Superblock) !?*const Dentry {
            if (self.cursor.isBlank()) return try self.readNext(super);

            self.inner_offset += self.dent.size;
            if (self.inner_offset >= super.block_size) {
                self.block_i += 1;
                self.inner_offset = 0;
                return try self.readNext(super);
            }

            try self.cursor.seekAndEnsure(.read, self.dent.size);
            self.dent = self.cursor.asObject(Dentry);
            return self.dent;
        }

        pub fn deinit(self: *Iterator) void {
            self.cursor.close(.read);
        }

        fn seek(self: *Iterator, super: *const vfs.Superblock, offset: usize) void {
            std.debug.assert(self.cursor.isBlank());

            self.inner_offset = super.offsetModBlock(offset);
            self.block_i = @truncate(super.offsetToBlock(offset));
        }

        fn readNext(self: *Iterator, super: *const vfs.Superblock) !?*const Dentry {
            if (self.block_i < self.blocks_num) {
                const block_idx = self.inode.direct_ptrs[self.block_i];
                const offset = super.part_offset + super.blockToOffset(block_idx) + self.inner_offset;

                try self.cursor.ensureCache(.read, offset);
                self.dent = self.cursor.asObject(Dentry);
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

    pub inline fn name(self: *const Dentry) []const u8 {
        return @as([*]const u8, @ptrCast(&self._name))[0..self.name_len];
    }
};

const file_cached_ops: vfs.internals.file.Cached = .{
    .readCacheBlock = fileReadCacheBlock,
};

var fs = vfs.FileSystem.init(
    "ext2",
    .{
        .drive = .{
            .mount = mount,
            .unmount = undefined,
        },
    },
    .{
        .lookup = dentryLookup,
        .iterate = dentryIterate,
        .createFile = dentryCreateFile,
        .makeDirectory = dentryMakeDirectory,
        .open = dentryOpen,
        .close = dentryClose,
    },
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
    var super_cache = try drive.openCursor(.read, part_super_offset);
    defer super_cache.close(.read);

    const ext_super = super_cache.asObject(Superblock);
    const block_size = @as(u16, 1) << @truncate(ext_super.block_shift + 10);
    if (!ext_super.check()) return error.BadSuperblock;

    log.debug(
        "ver: {}.{}",
        .{ ext_super.major_ver, ext_super.minor_ver },
    );
    log.debug(
        "block size: {}, optional: 0x{x}, required: 0x{x}, read-only: 0x{x}",
        .{ block_size, ext_super.optional_feat, ext_super.required_feat, ext_super.readonly_feat },
    );

    // Currently not supported
    if (block_size < drive.lba_size) return error.BadSuperblock;

    // Init super
    const super = vfs.Superblock.new() orelse return error.NoMemory;
    errdefer super.free();

    super.init(drive, part, block_size, ext_super);

    // Init root dentry
    {
        var cache_cursor = drive.blankCursor();
        defer cache_cursor.close(.read);

        const inode = try readInode(super, root_inode, .read, &cache_cursor);
        if (inode.type_perm.type != .directory) return error.NotDirectory;

        const dentry = vfs.Dentry.new() orelse return error.NoMemory;
        errdefer dentry.free();

        dentry.setup("/", undefined, try inode.makeCache(root_inode), &fs.dentry_ops) catch unreachable;
        super.root = dentry;
    }

    return super;
}

inline fn calcBlockOffset(super: *const vfs.Superblock, block: u32) usize {
    return super.part_offset + super.blockToOffset(block);
}

fn calcBgdOffset(super: *const vfs.Superblock, group: u32) usize {
    const ext_super = super.fs_data.asPtr(Superblock).?;
    return super.part_offset + ((ext_super.sb_block + 1) * super.block_size) + (group * @sizeOf(BlockGroupDescriptor));
}

fn readBgd(super: *const vfs.Superblock, group: u32, cursor: *cache.Cursor) !*BlockGroupDescriptor {
    try cursor.ensureCache(.read, calcBgdOffset(super, group));
    return cursor.asObject(BlockGroupDescriptor);
}

fn readInode(
    super: *const vfs.Superblock,
    inode: u32,
    comptime op: vfs.Drive.io.Operation,
    cursor: *cache.Cursor,
) !*const Inode {
    const ext_super = super.fs_data.asPtr(Superblock).?;

    const idx = inode - 1;
    const group = idx / ext_super.inodes_per_group;
    const inner_idx = idx % ext_super.inodes_per_group;

    const bgd_offset = calcBgdOffset(super, group);

    try cursor.ensureCache(op, bgd_offset);
    const bgd = cursor.asObject(BlockGroupDescriptor);

    const offset = super.part_offset + super.blockToOffset(bgd.inode_table) + (inner_idx * ext_super.inode_size);
    try cursor.ensureCache(op, offset);

    return cursor.asObject(Inode);
}

fn readDirectory(super: *const vfs.Superblock, inode: *vfs.Inode, cursor: *cache.Cursor) !Dentry.Iterator {
    const blocks_num = inode.size >> super.block_shift;
    const ext_inode = try readInode(super, inode.index, .read, cursor);

    return .{
        .inode = ext_inode,
        .cursor = .blank(super.drive),
        .blocks_num = @truncate(blocks_num),
    };
}

fn dentryLookup(parent: *const vfs.Dentry, name: []const u8) ?*vfs.Dentry {
    const super = parent.ctx.super;

    var cache_cursor = super.drive.blankCursor();
    defer cache_cursor.close(.read);

    var dent_it = readDirectory(super, parent.inode, &cache_cursor) catch return null;
    defer dent_it.deinit();

    const ext_dent = blk: {
        while (dent_it.next(super) catch return null) |dent| {
            if (std.mem.eql(u8, name, dent.name())) break :blk dent;
        }

        return null;
    };

    // Init new vfs dentry
    const child_inode = readInode(super, ext_dent.inode, .read, &cache_cursor) catch return null;

    const child_dentry = vfs.Dentry.new() orelse return null;
    const vfs_inode = child_inode.makeCache(ext_dent.inode) catch {
        child_dentry.free();
        return null;
    };

    child_dentry.setup(name, parent.getContext(), vfs_inode, &fs.dentry_ops) catch {
        child_dentry.free();
        vfs_inode.free();
        return null;
    };

    return child_dentry;
}

fn dentryIterate(dentry: *const vfs.Dentry, iter: *vfs.Dentry.Iterator) vfs.Error!void {
    const super = dentry.ctx.super;

    var cache_cursor = super.drive.blankCursor();
    defer cache_cursor.close(.read);

    var dent_it = readDirectory(super, dentry.inode, &cache_cursor) catch return error.IoFailed;
    defer dent_it.deinit();

    dent_it.seek(super, iter.pos);
    while (dent_it.next(super) catch return error.IoFailed) |dent| {
        iter.pos = super.blockToOffset(dent_it.block_i) + dent_it.inner_offset;

        const @"type": Inode.Type = @enumFromInt(dent.type);
        if (!iter.fillNext(dent.name(), dent.inode, @"type".toVfsType())) {
            @branchHint(.unlikely);
            return;
        }
    }

    iter.pos = super.blockToOffset(dent_it.block_i) + dent_it.inner_offset;
}

fn dentryMakeDirectory(parent: *const vfs.Dentry, child: *vfs.Dentry, opts: vfs.CreateOptions) vfs.Error!void {
    const super = parent.ctx.super;

    var cursor = super.drive.blankCursor();
    defer cursor.close(.write);

    const inode_idx = try allocInode(super, &cursor);
    const time: u32 = @intCast(vfs.getTime().posix());

    try writeInode(super, inode_idx, .directory, opts, time, &cursor);
    try addDentryToDirectory(
        super,
        parent.inode.index,
        child.name.str(),
        inode_idx,
        .directory,
        &cursor,
    );
    try makeDirectoryEntries(
        super,
        inode_idx,
        parent.inode.index,
        &cursor,
    );

    var vfs_inode = try makeInode(super, inode_idx, .directory, opts, time);
    errdefer vfs_inode.free();

    child.assignInode(vfs_inode);
    child.ref();
}

fn dentryCreateFile(parent: *const vfs.Dentry, child: *vfs.Dentry, opts: vfs.CreateOptions) vfs.Error!void {
    const super = parent.ctx.super;

    var cursor = super.drive.blankCursor();
    defer cursor.close(.write);

    const inode_idx = try allocInode(super, &cursor);
    const time: u32 = @intCast(vfs.getTime().posix());

    try writeInode(super, inode_idx, .regular_file, opts, time, &cursor);
    try addDentryToDirectory(
        super,
        parent.inode.index,
        child.name.str(),
        inode_idx,
        .regular_file,
        &cursor,
    );

    var vfs_inode = try makeInode(super, inode_idx, .regular_file, opts, time);
    errdefer vfs_inode.free();

    child.assignInode(vfs_inode);
    child.ref();
}

fn allocInode(super: *const vfs.Superblock, cursor: *cache.Cursor) vfs.Error!u32 {
    const group_idx: u32 = 0;
    const bgd_offset = calcBgdOffset(super, group_idx);

    try cursor.ensureCache(.write, bgd_offset);
    const bgd = cursor.asObject(BlockGroupDescriptor);

    if (bgd.free_inodes == 0) return error.NoEnt;
    bgd.free_inodes -= 1;

    cursor.setDirty(@sizeOf(BlockGroupDescriptor));
    return bitmapAlloc(super, bgd.inode_bitmap, cursor);
}

fn allocBlock(super: *const vfs.Superblock, cursor: *cache.Cursor) vfs.Error!u32 {
    const group_idx: u32 = 0;
    const bgd_offset = calcBgdOffset(super, group_idx);

    try cursor.ensureCache(.write, bgd_offset);
    const bgd = cursor.asObject(BlockGroupDescriptor);

    if (bgd.free_blocks == 0) return error.NoEnt;
    bgd.free_blocks -= 1;

    cursor.setDirty(@sizeOf(BlockGroupDescriptor));
    return bitmapAlloc(super, bgd.block_bitmap, cursor);
}

fn bitmapAlloc(super: *const vfs.Superblock, bitmap_block: u32, cursor: *cache.Cursor) vfs.Error!u32 {
    const bitmap_offset = calcBlockOffset(super, bitmap_block);
    try cursor.ensureCache(.write, bitmap_offset);

    const masks: [*]usize = @ptrCast(cursor.asObject(usize));
    const ext_super = super.fs_data.asPtr(Superblock).?;
    const blocks_per_group = ext_super.blocks_per_group;

    for (0..blocks_per_group) |i| {
        const bits = masks[i];
        if (bits == std.math.maxInt(usize)) continue;

        const bit = @ctz(~bits);
        const idx: u32 = @truncate(i * @bitSizeOf(usize) + bit);
        masks[i] |= @as(usize, 1) << @truncate(bit);

        try cursor.writeBack(super.block_size);
        return idx;
    }

    return error.NoSpace;
}

fn makeInode(_: *const vfs.Superblock, idx: u32, kind: vfs.Inode.Type, opts: vfs.CreateOptions, time: u32) vfs.Error!*vfs.Inode {
    const inode = vfs.Inode.new() orelse return error.NoMemory;
    errdefer inode.free();

    inode.* = .{
        .index = idx,
        .type = kind,
        .perm = opts.perm,
        .size = 0,
        .cache_ctrl = .{ .write_back = vfs.internals.cache.noWriteBackFail },
        .access_time = time,
        .create_time = time,
        .modify_time = time,
        .gid = opts.gid,
        .uid = opts.uid,
        .links_num = 1,
    };

    return inode;
}

fn writeInode(
    super: *const vfs.Superblock,
    idx: u32,
    kind: vfs.Inode.Type,
    opts: vfs.CreateOptions,
    time: u32,
    cursor: *cache.Cursor,
) vfs.Error!void {
    const ext_super = super.fs_data.asPtr(Superblock).?;

    const group_idx = (idx - 1) / ext_super.inodes_per_group;
    const inner_idx = (idx - 1) % ext_super.inodes_per_group;

    const bgd_offset = calcBgdOffset(super, group_idx);
    try cursor.ensureCache(.write, bgd_offset);

    const bgd = cursor.asObject(BlockGroupDescriptor);
    const offset = super.part_offset + super.blockToOffset(bgd.inode_table) +
        (inner_idx * ext_super.inode_size);

    try cursor.ensureCache(.write, offset);

    var ext_inode = cursor.asObject(Inode);
    ext_inode.type_perm = .{ .perm = @as(u12, @truncate(opts.perm)), .type = .fromVfsType(kind) };
    ext_inode.uid = opts.uid;
    ext_inode.size_lo = 0;
    ext_inode.size_hi = 0;
    ext_inode.access_time = time;
    ext_inode.create_time = time;
    ext_inode.modify_time = time;
    ext_inode.delete_time = 0;
    ext_inode.gid = opts.gid;
    ext_inode.links_num = 1;
    ext_inode.sectors_num = 0;
    ext_inode.flags = 0;
    ext_inode.os_specific = 0;
    ext_inode.direct_ptrs = .{0} ** 12;
    ext_inode.indir_ptrs = .{0} ** 3;
    ext_inode.generation_num = 0;
    ext_inode.ext_attr_block = 0;
    ext_inode.frag_block = 0;
    ext_inode.os_specific2 = 0;
    ext_inode.rsrvd = .{0} ** 2;

    log.info("write inode", .{});

    errdefer cursor.setDirty(@sizeOf(Inode));
    try cursor.writeBack(@sizeOf(Inode));

    log.info("inode writen", .{});
}

fn addDentryToDirectory(
    super: *const vfs.Superblock,
    dir_inode_idx: u32,
    name: []const u8,
    child_inode_idx: u32,
    child_type: vfs.Inode.Type,
    cursor: *cache.Cursor,
) vfs.Error!void {
    const ext_dir = try readInode(super, dir_inode_idx, .write, cursor);

    const dir_size: u32 = ext_dir.size_lo;
    const entry_size: u16 = @truncate(@sizeOf(Dentry) + name.len);
    const aligned_size = lib.misc.alignUp(u16, entry_size, @sizeOf(u32));
    if (ext_dir.direct_ptrs[0] == 0) return error.IoFailed;

    const block_idx = ext_dir.direct_ptrs[0];
    const block_offset = calcBlockOffset(super, block_idx);
    try cursor.ensureCache(.write, block_offset);

    const ext_child_type: u8 = switch (child_type) {
        .directory => 2,
        .regular_file => 1,
        else => 1,
    };

    const block = cursor.asSlice();
    const entry_offset: [*]u8 = @ptrCast(block.ptr + dir_size);
    @memset(entry_offset[0..aligned_size], 0);

    const name_len = @min(name.len, 255);
    @memcpy(entry_offset[4..(4 + name_len)], name[0..name_len]);

    const child_idx_bytes: [4]u8 = @bitCast(child_inode_idx);
    const aligned_size_bytes: [2]u8 = @bitCast(aligned_size);
    entry_offset[0..4].* = child_idx_bytes;
    entry_offset[4..6].* = aligned_size_bytes;
    entry_offset[6] = @truncate(name_len);
    entry_offset[7] = ext_child_type;

    try cursor.writeBack(super.block_size);
    cursor.unlock(.write);

    const ext_super = super.fs_data.asPtr(Superblock).?;
    const group = (dir_inode_idx - 1) / ext_super.inodes_per_group;
    const bdg_offset = calcBgdOffset(super, group);

    try cursor.fetchCache(.read, bdg_offset);
    const bgd = cursor.asObject(BlockGroupDescriptor);
    const inode_offset =
        super.part_offset + super.blockToOffset(bgd.inode_table) +
        ((dir_inode_idx - 1) % ext_super.inodes_per_group * ext_super.inode_size);

    cursor.unlock(.read);
    try cursor.fetchCache(.write, inode_offset);
    const dir_inode = cursor.asObject(Inode);
    dir_inode.size_lo = dir_size + aligned_size;
    dir_inode.modify_time = @intCast(vfs.getTime().posix());
    dir_inode.links_num += 1;

    try cursor.writeBack(@sizeOf(Inode));
}

fn makeDirectoryEntries(
    super: *const vfs.Superblock,
    dir_inode_idx: u32,
    parent_inode_idx: u32,
    cursor: *cache.Cursor,
) vfs.Error!void {
    const ext_dir = try readInode(super, dir_inode_idx, .write, cursor);

    if (ext_dir.direct_ptrs[0] == 0) return error.IoFailed;

    const block_idx = ext_dir.direct_ptrs[0];
    const block_offset = calcBlockOffset(super, block_idx);
    try cursor.ensureCache(.write, block_offset);

    const block = cursor.asSlice();

    @memset(block[0..super.block_size], 0);

    const inode_idx_bytes: [4]u8 = @bitCast(dir_inode_idx);
    const dent_len: u16 = @sizeOf(Dentry);
    const dent_len_bytes: [2]u8 = @bitCast(dent_len);
    block[0..4].* = inode_idx_bytes;
    block[4..6].* = dent_len_bytes;
    block[6] = 1;
    block[7] = 2;
    block[8] = '.';

    const parent_inode_idx_bytes: [4]u8 = @bitCast(parent_inode_idx);
    const dotdot_offset = @sizeOf(Dentry);
    block[dotdot_offset..(dotdot_offset + 4)].* = parent_inode_idx_bytes;
    block[(dotdot_offset + 4)..(dotdot_offset + 6)].* = dent_len_bytes;
    block[dotdot_offset + 6] = 2;
    block[dotdot_offset + 7] = 2;
    block[dotdot_offset + 8] = '.';
    block[dotdot_offset + 9] = '.';

    try cursor.writeBack(super.block_size);
}

fn dentryOpen(_: *const vfs.Dentry, file: *vfs.File) vfs.Error!void {
    file.ops = &file_cached_ops.ops;
}

fn dentryClose(_: *const vfs.Dentry, _: *vfs.File) void {}

fn fileReadCacheBlock(dentry: *const vfs.Dentry, block: *vm.cache.Block) vfs.Error!void {
    const inode = dentry.inode;
    const super = dentry.ctx.super;

    const offset = block.getOffset();
    const len = @min(inode.size - offset, block.size.toBytes());

    const start_blk_i = super.offsetToBlock(offset);
    const len_blk = super.offsetToBlock(len + super.block_size - 1);

    var inode_cache = super.drive.blankCursor();
    defer inode_cache.close(.read);

    const ext_inode = try readInode(super, inode.index, .read, &inode_cache);
    var ptr_iter: Inode.BlockIter = try .init(@truncate(start_blk_i), super, ext_inode);
    defer ptr_iter.deinit();

    var buffer = block.asSlice()[0..len];
    var base_blk: u32 = 0;
    var top_blk: u32 = 0;
    var n: usize = 0;

    while (buffer.len > 0) {
        var i_blk: u32 = undefined;
        defer {
            base_blk = i_blk;
            top_blk = i_blk + 1;
        }

        while (n < len_blk) : (n += 1) {
            i_blk = try ptr_iter.next();
            if (top_blk == 0) {
                base_blk = i_blk;
                top_blk = i_blk + 1;
            } else if (i_blk == top_blk) {
                top_blk += 1;
            } else {
                n += 1;
                break;
            }
        }

        const blk_offset = super.part_offset + super.blockToOffset(base_blk);
        const lba_offset = super.drive.offsetToLba(blk_offset);
        const region_size = super.blockToOffset(top_blk -% base_blk);
        try super.drive.ioSync(.read, lba_offset, buffer.ptr[0..region_size]);

        if (region_size >= buffer.len) break;
        buffer = buffer[region_size..];
    }
}
