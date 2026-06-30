// @noexport

//! # Ext2 filesystem driver

// Copyright (C) 2024-2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const cache = vfs.Drive.cache;
const lib = @import("../../lib.zig");
const log = std.log.scoped(.ext2);
const sys = @import("../../sys.zig");
const vfs = @import("../../vfs.zig");
const vm = @import("../../vm.zig");

const super_offset = 1024;
const super_magic = 0xEF53;
const root_inode = 2;
const superblock_disk_offset = super_offset;

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

const Operation = vfs.Drive.io.Operation;

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

    fn fromVfsType(kind: vfs.Inode.Type) DentryType {
        return switch (kind) {
            .regular_file => .regular_file,
            .directory => .directory,
            .char_device => .char_device,
            .block_device => .block_device,
            .fifo => .fifo,
            .socket => .socket,
            .symbolic_link => .symbolic_link,
            .unknown => .unknown,
        };
    }
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

    const PtrPath = struct {
        inner_idx: u32,
        indir_level: u2,
        ptr_stack: [2]u32 = .{ 0, 0 },
    };

    inline fn size(self: *const Inode) u64 {
        return (@as(u64, self.size_hi) << 32) | self.size_lo;
    }

    inline fn ptrPerBlockShift(super: *const vfs.Superblock) u5 {
        return super.block_shift - std.math.log2(@sizeOf(u32));
    }

    inline fn ptrsPerBlock(super: *const vfs.Superblock) u32 {
        return super.block_size / @sizeOf(u32);
    }

    fn calcPtrPath(begin_idx: u32, super: *const vfs.Superblock) PtrPath {
        const ptr_per_blk_shift = ptrPerBlockShift(super);
        var path = calcPtrStartLocation(begin_idx, ptr_per_blk_shift);
        if (path.indir_level == 0) return path;

        var shift = ptr_per_blk_shift * (path.indir_level - 1);
        var i: usize = 0;
        while (i < path.indir_level - 1) : (i += 1) {
            path.ptr_stack[i] = lib.misc.divByPowerOfTwo(u32, path.inner_idx, shift);
            path.inner_idx = lib.misc.modByPowerOfTwo(u32, path.inner_idx, shift);
            shift -= ptr_per_blk_shift;
        }

        return path;
    }

    fn calcPtrStartLocation(begin_idx: u32, ptr_per_blk_shift: u5) PtrPath {
        if (begin_idx < Inode.direct_ptrs_num) {
            return .{ .indir_level = 0, .inner_idx = begin_idx };
        }

        var idx = begin_idx - Inode.direct_ptrs_num;
        var shift = ptr_per_blk_shift;
        var level: u2 = 1;

        while (level < 3) : (level += 1) {
            const ptrs_per_level = @as(u32, 1) << shift;
            if (ptrs_per_level > idx) break;

            shift += shift;
            idx -= ptrs_per_level;
        }

        return .{ .indir_level = level, .inner_idx = idx };
    }

    /// Data block iterator
    const BlockIter = struct {
        inner_idx: u32,
        indir_level: u2,

        cursor: cache.Cursor,

        ptrs: [*]const u32 = undefined,
        ptr_stack: [2]u32 = .{ 0, 0 },
        indir_blk: u32 = 0,

        super: *const vfs.Superblock,
        inode: *const Inode,

        pub inline fn init(
            begin_idx: u32, super: *const vfs.Superblock,
            inode: *const Inode, comptime op: ?Operation,
        ) !BlockIter {
            const path = Inode.calcPtrPath(begin_idx, super);

            var self: BlockIter = .{
                .inner_idx = path.inner_idx,
                .indir_level = path.indir_level,
                .cursor = .blank(super.drive),
                .ptr_stack = path.ptr_stack,
                .super = super,
                .inode = inode,
            };
            try self.openStartLocation(op);

            return self;
        }

        pub inline fn deinit(self: *BlockIter, comptime op: ?Operation) void {
            self.cursor.close(op);
        }

        pub inline fn next(self: *BlockIter, comptime op: ?Operation) !u32 {
            if (self.indir_level == 0) return self.nextDirectPtr(op);

            return self.nextIndirPtr(op);
        }

        fn nextDirectPtr(self: *BlockIter, comptime op: ?Operation) !u32 {
            const ptr = self.inode.direct_ptrs[self.inner_idx];
            self.inner_idx +%= 1;

            if (self.inner_idx >= Inode.direct_ptrs_num) {
                @branchHint(.unlikely);
                self.indir_level = 1;
                self.inner_idx = 0;

                try self.readPtrBlock(self.inode.indir_ptrs[0], op);
            }

            return ptr;
        }

        fn nextIndirPtr(self: *BlockIter, comptime op: ?Operation) !u32 {
            // Have to process next pointers block ?
            if (self.inner_idx >= Inode.ptrsPerBlock(self.super)) {
                @branchHint(.unlikely);
                try self.nextIndirBlock(op);
            }

            const ptr = try self.getIndirectPtr(self.inner_idx,op);
            self.inner_idx +%= 1;

            return ptr;
        }

        fn nextIndirBlock(self: *BlockIter, comptime op: ?Operation) !void {
            self.inner_idx = 0;

            var carry: u1 = 1;
            var n = self.indir_level - 1;
            while (n > 0) : (n -= 1) {
                const idx = self.ptr_stack[n - 1] +% carry;

                if (idx >= Inode.ptrsPerBlock(self.super)) {
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

            try self.readPtrBlock(self.inode.indir_ptrs[self.indir_level - 1], op);

            for (0..self.indir_level - 1) |i| {
                const idx = self.ptr_stack[i];
                try self.readPtrBlock(try self.getIndirectPtr(idx, op), op);
            }
        }

        fn openStartLocation(self: *BlockIter, comptime op: ?Operation) !void {
            if (self.indir_level == 0) return;

            try self.readPtrBlock(self.inode.indir_ptrs[self.indir_level - 1], op);
            for (0..self.indir_level - 1) |i| {
                try self.readPtrBlock(try self.getIndirectPtr(self.ptr_stack[i], op), op);
            }
        }

        fn readPtrBlock(self: *BlockIter, block: u32, comptime op: ?Operation) !void {
            const offset = calcBlockOffset(self.super, block);
            try self.cursor.ensureCache(op, offset);

            self.ptrs = @ptrCast(self.cursor.asObject(u32));
            if (comptime op != .read) self.indir_blk = block;
        }

        fn getIndirectPtr(self: *BlockIter, i: usize, comptime op: ?Operation) !u32 {
            const offset = i * @sizeOf(u32);
            if (self.cursor.innerOffset() + offset >= cache.block_size) {
                @branchHint(.cold);
                try self.cursor.seekAndEnsure(op, @intCast(offset));

                // Pointers magic to make it able to take next pointers using sequential `i` index
                const ptrs_addr = @intFromPtr(self.cursor.asObject(u32));
                self.ptrs = @ptrFromInt(ptrs_addr - offset);
            }
            return self.ptrs[i];
        }

        test "Inode.calcPtrStartLocation" {
            // 128 pointers per block
            const ptr_per_blk_shift = 7;
            const expect = std.testing.expect;

            var loc = Inode.calcPtrStartLocation(0, ptr_per_blk_shift);
            try expect(loc.indir_level == 0 and loc.inner_idx == 0);

            loc = Inode.calcPtrStartLocation(10, ptr_per_blk_shift);
            try expect(loc.indir_level == 0 and loc.inner_idx == 10);

            loc = Inode.calcPtrStartLocation(127 + 12, ptr_per_blk_shift);
            try expect(loc.indir_level == 1 and loc.inner_idx == 127);

            loc = Inode.calcPtrStartLocation(128 + 12, ptr_per_blk_shift);
            try expect(loc.indir_level == 2 and loc.inner_idx == 0);

            loc = Inode.calcPtrStartLocation(1024, ptr_per_blk_shift);
            try expect(loc.indir_level == 2 and loc.inner_idx == 884);

            loc = Inode.calcPtrStartLocation(16534, ptr_per_blk_shift);
            try expect(loc.indir_level == 3 and loc.inner_idx == 10);

            loc = Inode.calcPtrStartLocation(2113676, ptr_per_blk_shift);
            try expect(loc.indir_level == 3 and loc.inner_idx == 2097152);
        }
    };

    pub fn makeCache(self: *const Inode, super: *const vfs.Superblock, idx: u32) !*vfs.Inode {
        const inode = vfs.Inode.new() orelse return error.NoMemory;
        inode.* = .{
            .index = idx,
            .type = self.type_perm.type.toVfsType(),
            .perm = self.type_perm.perm,
            .size = self.size(),
            .fs_data = .fromPtr(@constCast(super)),
            .cache_ctrl = .{ .write_back = &fileWriteBackCache },
            .create_time_sec = self.create_time,
            .access_time_sec = self.access_time,
            .modify_time_sec = self.modify_time,
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
            self.inner_offset = super.offsetModBlock(offset);
            self.block_i = @truncate(super.offsetToBlock(offset));
        }

        fn readNext(self: *Iterator, super: *const vfs.Superblock) !?*const Dentry {
            if (self.block_i < self.blocks_num) {
                const block_idx = try self.readBlockIdx(super);
                const offset = super.part_offset + super.blockToOffset(block_idx) + self.inner_offset;

                self.dent = try self.cursor.ensureAs(Dentry, .read, offset);
                if (self.dent.size == 0) return error.BadSuperblock;

                return self.dent;
            }

            return null;
        }

        fn readBlockIdx(self: *const Iterator, super: *const vfs.Superblock) !u32 {
            if (self.block_i < Inode.direct_ptrs_num) return self.inode.direct_ptrs[self.block_i];

            var ptr_iter = try Inode.BlockIter.init(self.block_i, super, self.inode, .read);
            defer ptr_iter.deinit(.read);

            return try ptr_iter.next(.read);
        }
    };

    inode: u32,
    size: u16,
    name_len: u8,
    type: u8,

    _name: u8,

    pub inline fn calcSize(name_len: usize) u16 {
        return lib.misc.alignUp(u16, headerSize() + @as(u16, @truncate(name_len)), @sizeOf(u32));
    }

    pub inline fn headerSize() u16 {
        return @offsetOf(Dentry, "_name");
    }

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
        .link = dentryLink,
        .unlink = dentryUnlink,
        .updateInode = dentryUpdateInode,
        .deinitInode = dentryDeinitInode,
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

        dentry.setup(
            "/",
            undefined,
            try inode.makeCache(super, root_inode),
            &fs.dentry_ops,
        ) catch unreachable;

        super.root = dentry;
    }

    ext_super.mount_time = @truncate(vfs.getTime().posix());
    ext_super.mount_num += 1;

    return super;
}

inline fn calcBlockOffset(super: *const vfs.Superblock, block: u32) usize {
    return super.part_offset + super.blockToOffset(block);
}

fn calcBgdOffset(super: *const vfs.Superblock, group: u32) usize {
    const ext_super = super.fs_data.asPtr(Superblock).?;
    return super.part_offset + ((ext_super.sb_block + 1) * super.block_size) + (group * @sizeOf(BlockGroupDescriptor));
}

fn readInode(
    super: *const vfs.Superblock,
    inode: u32,
    comptime op: Operation,
    cursor: *cache.Cursor,
) !*Inode {
    const ext_super = super.fs_data.asPtr(Superblock).?;

    const idx = inode - 1;
    const group = idx / ext_super.inodes_per_group;
    const inner_idx = idx % ext_super.inodes_per_group;

    const bgd_offset = calcBgdOffset(super, group);
    const bgd = try cursor.ensureAs(BlockGroupDescriptor, op, bgd_offset);

    const offset = super.part_offset + super.blockToOffset(bgd.inode_table) + (inner_idx * ext_super.inode_size);
    return try cursor.ensureAs(Inode, op, offset);
}

fn readDirectory(
    super: *const vfs.Superblock,
    inode: *vfs.Inode,
    cursor: *cache.Cursor,
) !Dentry.Iterator {
    const ext_inode = try readInode(super, inode.index, .read, cursor);
    const blocks_num = super.offsetToBlock(ext_inode.size());

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

    var iter = readDirectory(super, parent.inode, &cache_cursor) catch return null;
    defer iter.deinit();

    const ext_dent = blk: {
        while (iter.next(super) catch return null) |dent| {
            if (dent.inode == 0) continue;

            if (std.mem.eql(u8, name, dent.name())) break :blk dent;
        }

        return null;
    };

    // Init new vfs dentry
    const child_inode = readInode(super, ext_dent.inode, .read, &cache_cursor) catch return null;
    if (child_inode.links_num == 0) {
        @branchHint(.cold);
        return null;
    }

    const child_dentry = vfs.Dentry.new() orelse return null;
    const vfs_inode = child_inode.makeCache(super, ext_dent.inode) catch {
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

    var ext_iter = readDirectory(super, dentry.inode, &cache_cursor) catch return error.IoFailed;
    defer ext_iter.deinit();

    ext_iter.seek(super, iter.pos);
    while (ext_iter.next(super) catch return error.IoFailed) |dent| {
        iter.pos = super.blockToOffset(ext_iter.block_i) + ext_iter.inner_offset;
        if (dent.inode < 1) {
            @branchHint(.cold);
            continue;
        }

        const @"type": Inode.Type = @enumFromInt(dent.type);
        if (!iter.fillNext(dent.name(), dent.inode, @"type".toVfsType())) {
            @branchHint(.unlikely);
            return;
        }
    }

    iter.pos = super.blockToOffset(ext_iter.block_i) + ext_iter.inner_offset;
}

fn dentryLink(dentry: *vfs.Dentry, inode: *vfs.Inode) vfs.Error!void {
    lib.debug.assert(dentry.parent != dentry, @src());

    const parent = dentry.parent;
    const super = parent.ctx.super;

    var cursor = super.drive.blankCursor();
    defer cursor.close(.write);

    const time: u32 = @truncate(inode.access_time_sec);
    const inode_idx = if (inode.index == 0) blk: {
        lib.debug.assert(inode.links_num == 0, @src());

        const inode_idx = try allocInode(
            super, parent.inode.index,
            inode.type == .directory, &cursor,
        );
        const opts: vfs.CreateOptions = .{
            .perm = inode.perm,
            .uid = inode.uid,
            .gid = inode.gid,
        };

        if (inode.type == .directory) {
            try makeDirectory(parent, inode_idx, opts, time, &cursor);
        } else {
            try writeInode(
                super, inode_idx, inode.type,
                opts, time, 0,
                0, 1, &cursor,
            );
        }

        break :blk inode_idx;
    } else inode.index;

    errdefer if (inode.index == 0) {
        if (inode.type == .directory) clearDirectory(parent, inode_idx, time, &cursor) catch {};
        freeInode(super, inode_idx, inode.type == .directory, &cursor) catch {};
    };

    try addDentryToDirectory(
        super,
        parent.inode.index,
        dentry.name.str(),
        inode_idx,
        inode.type,
        time,
        &cursor,
    );

    if (!inode.isAllocated() and inode.type == .directory) {
        inode.links_num += 1;
        inode.size = super.block_size;
    }

    inode.index = inode_idx;
    inode.fs_data.setPtr(super);
}

fn dentryUnlink(dentry: *const vfs.Dentry) vfs.Error!void {
    lib.debug.assert(dentry.parent != dentry, @src());

    const super = dentry.ctx.super;
    const parent = dentry.parent;
    const inode = dentry.inode;

    if (inode.type == .directory) {
        log.debug("dir: links: {}, size: {}", .{inode.links_num, inode.size});
        if (inode.links_num > 2 or inode.size > super.block_size) return error.NotEmpty;

        var cursor = super.drive.blankCursor();
        defer cursor.close(.read);

        var iter = try readDirectory(super, inode, &cursor);
        defer iter.deinit();

        var i: u32 = 0;
        while (try iter.next(super)) |dent| {
            log.debug("dent: {} / {s}", .{dent.inode, dent.name()});

            if (dent.inode == 0) continue;
            i += 1;

            if (i > 2) return error.NotEmpty;
        }
    }

    const dent_offset = blk: {
        var cursor = super.drive.blankCursor();
        defer cursor.close(.read);

        var iter = try readDirectory(super, parent.inode, &cursor);
        defer iter.deinit();

        while (try iter.next(super)) |dent| {
            if (dent.inode != inode.index) continue;

            break :blk iter.cursor.offset;
        }

        unreachable;
    };

    var cursor = super.drive.blankCursor();
    defer cursor.close(.write);

    const dent = try cursor.ensureAs(Dentry, .write, dent_offset);
    dent.inode = 0;
    cursor.setDirty(@sizeOf(Dentry));

    const time: u32 = @truncate(inode.access_time_sec);
    errdefer internalError(super, "unlink failed: cannot update inode links num");

    const dir_inode = try readInode(super, parent.inode.index, .write, &cursor);
    dir_inode.links_num -= if (inode.type == .directory) 1 else 0;
    dir_inode.modify_time = time;
    dir_inode.access_time = time;
    cursor.setDirty(@sizeOf(Inode));

    const ext_inode = try readInode(super, inode.index, .write, &cursor);
    ext_inode.links_num -= 1;
    ext_inode.access_time = time;
    ext_inode.modify_time = time;
    cursor.setDirty(@sizeOf(Inode));

    if (inode.type == .directory) {
        parent.inode.links_num -= 1;
        inode.links_num = 1;
    }
}

fn dentryUpdateInode(inode: *const vfs.Inode, update: vfs.Inode.Update) vfs.Error!void {
    const super = inode.fs_data.asPtr(vfs.Superblock).?;

    var cursor = super.drive.blankCursor();
    defer cursor.close(.write);

    const ext_inode = try readInode(super, inode.index, .write, &cursor);
    switch (update) {
        .time => |t| {
            ext_inode.access_time = @truncate(t.access.posix());
            ext_inode.modify_time = @truncate(t.modify.posix());
        },
        .size => |s| {
            const ext_super = super.fs_data.asPtr(Superblock).?;
            if (s.value >= super.blockToOffset(ext_super.free_blocks)) return error.NoSpace;

            ext_inode.size_lo = @truncate(s.value);
            ext_inode.size_hi = @truncate(s.value >> 32);
        },
        .perm => |p| {
            ext_inode.type_perm.perm = @truncate(@intFromEnum(p.value));
            ext_inode.uid = p.owner_uid;
            ext_inode.gid = p.owner_gid;
        },
    }

    cursor.setDirty(@sizeOf(Inode));
}

fn dentryDeinitInode(inode: *const vfs.Inode) void {
    if (!inode.isRemoved()) return;

    log.debug("inode {}: is removed", .{inode.index});

    const super = inode.fs_data.asPtr(vfs.Superblock).?;
    var cursor = super.drive.blankCursor();
    defer cursor.close(.write);

    const ext_inode = readInode(super, inode.index, .write, &cursor) catch |err| {
        log.err("inode {}: failed to complete deleting: {t}", .{inode.index, err});
        return;
    };

    const dump_inode = ext_inode.*;
    ext_inode.delete_time = @truncate(inode.modify_time_sec);
    ext_inode.size_lo = 0;
    ext_inode.size_hi = 0;
    ext_inode.sectors_num = 0;
    ext_inode.links_num = 0;

    // Is it needed? Maybe it's better to leave
    // pointers to be able to restore deleted data?
    for (&ext_inode.direct_ptrs) |*dir_ptr| dir_ptr.* = 0;
    for (&ext_inode.indir_ptrs) |*indir_ptr| indir_ptr.* = 0;

    cursor.setDirty(@sizeOf(Inode));

    var iter = Inode.BlockIter.init(0, super, &dump_inode, null) catch |err| {
        log.err("inode {}: failed to complete deleting: block iterator: {t}", .{inode.index, err});
        return;
    };
    defer iter.deinit(null);

    const blocks_num = super.offsetToBlock(dump_inode.size() + (super.block_size - 1));
    const ptrs_per_block = Inode.ptrsPerBlock(super);
    if (blocks_num == 0) return;

    var freed: u32 = 0;
    for (0..blocks_num) |i| {
        const block_idx = iter.next(null) catch |err| {
            log.err("inode {}: failed to complete deleting: read block: {t}", .{inode.index, err});
            return;
        };

        freeBlockPartially(super, block_idx, &cursor) catch |err| {
            log.err("inode {}: failed to free block {} ({} from {}): {t}", .{
                inode.index, block_idx, i + 1, blocks_num, err,
            });
            break;
        };
        freed += 1;

        // Free indirect pointer block if needed
        if (
            iter.indir_level > 0 and
            (iter.inner_idx == ptrs_per_block - 1 or i == blocks_num - 1)
        ) {
            log.debug("inode {}: free indirect pointer block {}", .{inode.index, iter.indir_blk});

            freeBlockPartially(super, iter.indir_blk, &cursor) catch |err| {
                log.err("inode {}: failed to free block {} ({} from {}): {t}", .{
                    inode.index, block_idx, i + 1, blocks_num, err,
                });
                break;
            };
            freed += 1;
        }
    }

    const super_offset_abs = super.part_offset + superblock_disk_offset;
    cursor.ensureCache(.write, super_offset_abs) catch |err| {
        log.err("inode {}: failed to change free blocks number in superblock: {t}", .{
            inode.index, err,
        });
        return;
    };

    cursor.asObject(Superblock).free_blocks += freed;
    cursor.setDirty(@sizeOf(Superblock));

    freeInode(super, inode.index, inode.type == .directory, &cursor) catch |err| {
        log.err("inode {}: failed to free inode: {t}", .{inode.index, err});
    };
}

fn makeDirectory(
    parent: *const vfs.Dentry,
    inode_idx: u32,
    opts: vfs.CreateOptions,
    time: u32,
    cursor: *cache.Cursor,
) vfs.Error!void {
    const super = parent.ctx.super;

    const block_idx = try allocBlock(super, inode_idx, cursor);
    errdefer freeBlock(super, block_idx, cursor) catch {};

    try writeInode(
        super, inode_idx, .directory, 
        opts, time, super.block_size,
        sectorsPerBlock(super), 2, cursor,
    );

    const inode = cursor.asObject(Inode);
    inode.direct_ptrs[0] = block_idx;

    try makeDirectoryEntries(
        super, inode_idx,
        parent.inode.index, block_idx,
        time, cursor,
    );

    parent.inode.links_num += 1;
}

fn clearDirectory(parent: *const vfs.Dentry, inode_idx: u32, time: u32, cursor: *cache.Cursor) vfs.Error!void {
    const super = parent.ctx.super;

    const ext_inode = try readInode(super, inode_idx, .write, cursor);
    if (ext_inode.size() != super.block_size) {
        log.warn("inode {}: clearing non empty directory?", .{inode_idx});
        return error.InvalidArgs;
    } else if (ext_inode.direct_ptrs[0] == 0) {
        log.warn("inode {}: clearing non allocated directory?", .{inode_idx});
        return error.InvalidArgs;
    }

    try freeBlock(parent.ctx.super, ext_inode.direct_ptrs[0], cursor);

    ext_inode.links_num -= 1;
    ext_inode.direct_ptrs[0] = 0;
    cursor.setDirty(@sizeOf(Inode));

    const parent_inode = try readInode(super, parent.inode.index, .write, cursor);
    parent_inode.links_num -= 1;
    parent_inode.modify_time = time;
    parent_inode.access_time = time;
    cursor.setDirty(@sizeOf(Inode));

    parent.inode.links_num -= 1;
}

fn allocInode(super: *const vfs.Superblock, parent_inode_idx: u32, is_dir: bool, cursor: *cache.Cursor) vfs.Error!u32 {
    const preferred_group = inodeGroup(super, parent_inode_idx);
    const inode_idx = try allocInodeFromGroups(super, preferred_group, cursor);

    if (is_dir) {
        const bgd_offset = calcBgdOffset(super, inodeGroup(super, inode_idx));
        const bgd = try cursor.ensureAs(BlockGroupDescriptor, .write, bgd_offset);
        bgd.dirs_num += 1;

        cursor.setDirty(@sizeOf(BlockGroupDescriptor));
    }

    return inode_idx;
}

fn allocBlock(super: *const vfs.Superblock, owner_inode_idx: u32, cursor: *cache.Cursor) vfs.Error!u32 {
    return allocBlockFromGroups(super, inodeGroup(super, owner_inode_idx), cursor);
}

fn allocInodeFromGroups(super: *const vfs.Superblock, preferred_group: u32, cursor: *cache.Cursor) vfs.Error!u32 {
    const groups_num = blockGroupCount(super);
    if (groups_num == 0) return error.NoSpace;

    const ext_super = super.fs_data.asPtr(Superblock).?;
    var attempts: u32 = 0;
    while (attempts < groups_num) : (attempts += 1) {
        const group = (preferred_group + attempts) % groups_num;
        const bgd_offset = calcBgdOffset(super, group);
        const bgd = try cursor.ensureAs(BlockGroupDescriptor, .write, bgd_offset);
        if (bgd.free_inodes == 0) continue;

        bgd.free_inodes -= 1;
        errdefer bgd.free_inodes += 1;

        cursor.setDirty(@sizeOf(BlockGroupDescriptor));

        const local_idx = try bitmapAlloc(
            super,
            bgd.inode_bitmap,
            ext_super.inodes_per_group,
            calcInodesInGroup(ext_super, group),
            cursor,
        );
        const idx = group * ext_super.inodes_per_group + local_idx + 1;

        const super_offset_abs = super.part_offset + superblock_disk_offset;
        try cursor.ensureCache(.write, super_offset_abs);

        cursor.asObject(Superblock).free_inodes -%= 1;
        cursor.setDirty(@sizeOf(Superblock));

        return idx;
    }

    return error.NoSpace;
}

fn allocBlockFromGroups(super: *const vfs.Superblock, preferred_group: u32, cursor: *cache.Cursor) vfs.Error!u32 {
    const groups_num = blockGroupCount(super);
    if (groups_num == 0) return error.NoSpace;

    const ext_super = super.fs_data.asPtr(Superblock).?;
    var attempts: u32 = 0;
    while (attempts < groups_num) : (attempts += 1) {
        const group = (preferred_group + attempts) % groups_num;
        const bgd_offset = calcBgdOffset(super, group);
        const bgd = try cursor.ensureAs(BlockGroupDescriptor, .write, bgd_offset);
        if (bgd.free_blocks == 0) continue;

        bgd.free_blocks -= 1;
        errdefer bgd.free_blocks += 1;

        cursor.setDirty(@sizeOf(BlockGroupDescriptor));

        const local_idx = try bitmapAlloc(
            super,
            bgd.block_bitmap,
            ext_super.blocks_per_group,
            calcBlocksInGroup(ext_super, group),
            cursor,
        );
        const idx = group * ext_super.blocks_per_group + local_idx;

        const super_offset_abs = super.part_offset + superblock_disk_offset;
        try cursor.ensureCache(.write, super_offset_abs);

        cursor.asObject(Superblock).free_blocks -%= 1;
        cursor.setDirty(@sizeOf(Superblock));

        return idx;
    }

    return error.NoSpace;
}

fn bitmapAlloc(
    super: *const vfs.Superblock,
    bitmap_block: u32,
    entries_per_group: u32,
    group_entries: u32,
    cursor: *cache.Cursor,
) vfs.Error!u32 {
    const bitmap_offset = calcBlockOffset(super, bitmap_block);
    try cursor.ensureCache(.write, bitmap_offset);

    const bitmap: []usize = @ptrCast(@alignCast(cursor.asSlice()[0..super.block_size]));
    const group_limit = @min(entries_per_group, group_entries);
    const masks_len = (group_limit + @bitSizeOf(usize) - 1) / @bitSizeOf(usize);

    for (0..masks_len) |i| {
        const mask = bitmap[i];
        if (~mask == 0) continue;

        const bit = @ctz(~mask);
        const idx = i * @bitSizeOf(usize) + bit;
        if (idx >= group_limit) break;

        bitmap[i] |= @as(usize, 1) << @truncate(bit);
        cursor.setDirtyAt(i * @bitSizeOf(usize));

        return @truncate(idx);
    }

    return error.NoSpace;
}

fn writeInode(
    super: *const vfs.Superblock,
    idx: u32,
    kind: vfs.Inode.Type,
    opts: vfs.CreateOptions,
    time: u32,
    size: u64,
    sectors_num: u32,
    links_num: u16,
    cursor: *cache.Cursor,
) vfs.Error!void {
    const ext_super = super.fs_data.asPtr(Superblock).?;

    const group_idx = (idx - 1) / ext_super.inodes_per_group;
    const inner_idx = (idx - 1) % ext_super.inodes_per_group;

    const bgd_offset = calcBgdOffset(super, group_idx);
    const bgd = try cursor.ensureAs(BlockGroupDescriptor, .write, bgd_offset);

    const offset = super.part_offset + super.blockToOffset(bgd.inode_table) +
        (inner_idx * ext_super.inode_size);

    const ext_inode = try cursor.ensureAs(Inode, .write, offset);
    ext_inode.type_perm = .{
        .perm = @truncate(opts.perm),
        .type = .fromVfsType(kind),
    };
    ext_inode.uid = opts.uid;
    ext_inode.gid = opts.gid;
    ext_inode.size_lo = @truncate(size);
    ext_inode.size_hi = @truncate(size >> 32);
    ext_inode.access_time = time;
    ext_inode.create_time = time;
    ext_inode.modify_time = time;
    ext_inode.delete_time = 0;
    ext_inode.links_num = links_num;
    ext_inode.sectors_num = sectors_num;
    ext_inode.flags = 0;
    ext_inode.os_specific = 0;
    ext_inode.direct_ptrs = .{0} ** 12;
    ext_inode.indir_ptrs = .{0} ** 3;
    ext_inode.generation_num = 0;
    ext_inode.ext_attr_block = 0;
    ext_inode.frag_block = 0;
    ext_inode.os_specific2 = 0;
    ext_inode.rsrvd = .{0} ** 2;

    cursor.setDirty(@sizeOf(Inode));
}

fn addDentryToDirectory(
    super: *const vfs.Superblock,
    dir_inode_idx: u32,
    name: []const u8,
    child_inode_idx: u32,
    child_type: vfs.Inode.Type,
    time: u32,
    cursor: *cache.Cursor,
) vfs.Error!void {
    const ext_dir = (try readInode(super, dir_inode_idx, .write, cursor)).*;
    const blocks_num = super.offsetToBlock(ext_dir.size());
    const record_size = Dentry.calcSize(@min(name.len, 255));
    const ext_type = DentryType.fromVfsType(child_type);

    if (blocks_num == 0) return error.IoFailed;

    for (0..blocks_num) |logical_block| {
        const block_idx = try getInodeDataBlock(
            super,
            &ext_dir,
            @intCast(logical_block),
            .write,
            cursor,
        );
        const block_offset = calcBlockOffset(super, block_idx);
        const block = try cursor.ensureAsSlice(.write, block_offset);

        var offset: usize = 0;
        while (offset < super.block_size) {
            const dent = bytesAsDentry(block.ptr + offset);
            if (dent.size == 0) return error.BadSuperblock;

            if (dent.inode == 0 and dent.size >= record_size) {
                writeDentry(dent, child_inode_idx, ext_type, name, dent.size);
                cursor.setDirty(offset + dent.size);

                try touchDirectory(super, dir_inode_idx, time, cursor);
                return;
            }

            const split_size = Dentry.calcSize(dent.name_len);
            if (dent.size >= split_size + record_size) {
                const new_offset = offset + split_size;
                const remaining = dent.size - split_size;
                dent.size = split_size;

                const new_dent = bytesAsDentry(block.ptr + new_offset);
                writeDentry(new_dent, child_inode_idx, ext_type, name, remaining);
                cursor.setDirty(new_offset + remaining);

                try touchDirectory(super, dir_inode_idx, time, cursor);
                return;
            }

            offset += dent.size;
        }

        std.debug.assert(offset == super.block_size);
    }

    const new_block_idx = try allocBlock(super, dir_inode_idx, cursor);
    errdefer freeBlock(super, new_block_idx, cursor) catch {};

    try appendDirectoryBlock(super, dir_inode_idx, new_block_idx, time, cursor);

    const new_block_offset = calcBlockOffset(super, new_block_idx);
    const block = try cursor.ensureAsSlice(.write, new_block_offset);
    @memset(block[0..super.block_size], 0);

    writeDentry(
        bytesAsDentry(block.ptr),
        child_inode_idx,
        ext_type,
        name,
        super.block_size,
    );

    cursor.setDirty(super.block_size);
}

fn makeDirectoryEntries(
    super: *const vfs.Superblock,
    dir_inode_idx: u32,
    parent_inode_idx: u32,
    block_idx: u32,
    time: u32,
    cursor: *cache.Cursor,
) vfs.Error!void {
    const block_offset = calcBlockOffset(super, block_idx);
    const block = try cursor.ensureAsSlice(.write, block_offset);
    @memset(block[0..super.block_size], 0);

    const dot_size = comptime Dentry.calcSize(1);
    writeDentry(
        bytesAsDentry(block.ptr),
        dir_inode_idx,
        .directory,
        ".",
        dot_size
    );
    writeDentry(
        bytesAsDentry(block.ptr + dot_size),
        parent_inode_idx,
        .directory,
        "..",
        super.block_size - dot_size,
    );

    cursor.setDirty(super.block_size);

    const parent_inode = try readInode(super, parent_inode_idx, .write, cursor);
    parent_inode.links_num += 1;
    parent_inode.modify_time = time;
    parent_inode.access_time = time;

    cursor.setDirty(@sizeOf(Inode));
}

fn writeDentry(dent: *Dentry, inode_idx: u32, dent_type: DentryType, name: []const u8, size: u16) void {
    const name_len = @min(name.len, 255);
    dent.inode = inode_idx;
    dent.size = size;
    dent.name_len = @truncate(name_len);
    dent.type = @intFromEnum(dent_type);

    const dst = @as([*]u8, @ptrCast(&dent._name));
    @memcpy(dst[0..name_len], name[0..name_len]);

    const payload_len = size - Dentry.headerSize();
    if (payload_len > name_len) @memset(dst[name_len..payload_len], 0);
}

fn bytesAsDentry(ptr: [*]u8) *Dentry {
    return @ptrCast(@alignCast(ptr));
}

fn appendDirectoryBlock(
    super: *const vfs.Superblock,
    dir_inode_idx: u32,
    block_idx: u32,
    time: u32,
    cursor: *cache.Cursor,
) vfs.Error!void {
    const ext_dir = try readInode(super, dir_inode_idx, .write, cursor);
    const size = ext_dir.size();
    const logical_block = super.offsetToBlock(size);

    const extra_sectors = try setInodeDataBlock(
        super,
        dir_inode_idx,
        @truncate(logical_block),
        block_idx,
        cursor,
    );

    const inode = try readInode(super, dir_inode_idx, .write, cursor);
    const new_size = size + super.block_size;
    inode.size_lo = @truncate(new_size);
    inode.size_hi = @truncate(new_size >> 32);
    inode.sectors_num += sectorsPerBlock(super) + extra_sectors;
    inode.modify_time = time;
    inode.access_time = time;

    cursor.setDirty(@sizeOf(Inode));
}

fn touchDirectory(
    super: *const vfs.Superblock,
    dir_inode_idx: u32,
    time: u32,
    cursor: *cache.Cursor,
) vfs.Error!void {
    const dir_inode = try readInode(super, dir_inode_idx, .write, cursor);
    dir_inode.modify_time = time;
    dir_inode.access_time = time;

    cursor.setDirty(@sizeOf(Inode));
}

fn internalError(super: *const vfs.Superblock, msg: []const u8) void {
    if (super.drive.openCursor(.write, super.part_offset + superblock_disk_offset)) |c| {
        var cursor = c;

        // Force filesystem check/repair
        const ext_super = cursor.asObject(Superblock);
        ext_super.check_time = 0;

        cursor.setDirty(@sizeOf(Superblock));
        cursor.close(.write);
    } else |_| {
        log.err("{s}: failed to force superblock repair", .{super.part.dev_file.name.str()});
    }

    const ext_super = super.fs_data.asPtr(Superblock).?;
    if (ext_super.errors == .panic) @panic(msg);

    log.err("{s}: {s}", .{super.part.dev_file.name.str(), msg});
} 

fn inodeGroup(super: *const vfs.Superblock, inode_idx: u32) u32 {
    const ext_super = super.fs_data.asPtr(Superblock).?;
    return (inode_idx - 1) / ext_super.inodes_per_group;
}

fn blockGroupCount(super: *const vfs.Superblock) u32 {
    const ext_super = super.fs_data.asPtr(Superblock).?;
    return (ext_super.total_blocks + ext_super.blocks_per_group - 1) >> std.math.log2_int(u32, ext_super.blocks_per_group);
}

fn sectorsPerBlock(super: *const vfs.Superblock) u32 {
    return super.block_size / 512;
}

fn setInodeDataBlock(
    super: *const vfs.Superblock,
    inode_idx: u32,
    logical_idx: u32,
    block_idx: u32,
    cursor: *cache.Cursor,
) vfs.Error!u32 {
    const path = Inode.calcPtrPath(logical_idx, super);
    var ext_inode = try readInode(super, inode_idx, .write, cursor);

    if (path.indir_level == 0) {
        ext_inode.direct_ptrs[path.inner_idx] = block_idx;
        cursor.setDirty(@sizeOf(Inode));

        return 0;
    }

    var extra_sectors: u32 = 0;
    var current_block = ext_inode.indir_ptrs[path.indir_level - 1];
    if (current_block == 0) {
        current_block = try allocBlock(super, inode_idx, cursor);
        try zeroBlock(super, current_block, cursor);

        ext_inode = try readInode(super, inode_idx, .write, cursor);
        ext_inode.indir_ptrs[path.indir_level - 1] = current_block;
        cursor.setDirty(@sizeOf(Inode));

        extra_sectors += sectorsPerBlock(super);
    }

    for (0..path.indir_level - 1) |depth| {
        const entry_idx = path.ptr_stack[depth];
        const next_block = try readPointer(super, current_block, entry_idx, .write, cursor);
        if (next_block == 0) {
            const allocated_block = try allocBlock(super, inode_idx, cursor);
            try zeroBlock(super, allocated_block, cursor);
            extra_sectors += sectorsPerBlock(super);

            try writePointer(super, current_block, entry_idx, allocated_block, cursor);
            current_block = allocated_block;
        } else {
            current_block = next_block;
        }
    }

    try writePointer(super, current_block, path.inner_idx, block_idx, cursor);
    return extra_sectors;
}

fn zeroBlock(super: *const vfs.Superblock, block_idx: u32, cursor: *cache.Cursor) vfs.Error!void {
    const block_offset = calcBlockOffset(super, block_idx);
    const block = try cursor.ensureAsSlice(.write, block_offset);
    @memset(block[0..super.block_size], 0);

    cursor.setDirty(super.block_size);
}

fn freeInode(
    super: *const vfs.Superblock,
    inode_idx: u32,
    is_dir: bool,
    cursor: *cache.Cursor,
) vfs.Error!void {
    const ext_super = super.fs_data.asPtr(Superblock).?;
    const group = inodeGroup(super, inode_idx);
    const inner_idx = (inode_idx -% 1) % ext_super.inodes_per_group;

    const bgd_offset = calcBgdOffset(super, group);
    const bgd = try cursor.ensureAs(BlockGroupDescriptor, .write, bgd_offset);
    try bitmapFree(super, bgd.inode_bitmap, inner_idx, cursor);

    try cursor.ensureCache(.write, bgd_offset);
    bgd.free_inodes += 1;

    cursor.setDirty(@sizeOf(BlockGroupDescriptor));

    const super_offset_abs = super.part_offset + superblock_disk_offset;
    const super_ext = try cursor.ensureAs(Superblock, .write, super_offset_abs);

    super_ext.free_inodes +%= 1;
    cursor.setDirty(@sizeOf(Superblock));

    if (is_dir) {
        const dir_bgd_offset = calcBgdOffset(super, group);
        const dir_bgd = try cursor.ensureAs(BlockGroupDescriptor, .write, dir_bgd_offset);

        dir_bgd.dirs_num -%= 1;
        cursor.setDirty(@sizeOf(BlockGroupDescriptor));
    }
}

fn freeBlockPartially(super: *const vfs.Superblock, block_idx: u32, cursor: *cache.Cursor) vfs.Error!void {
    const ext_super = super.fs_data.asPtr(Superblock).?;
    const group = block_idx / ext_super.blocks_per_group;
    const inner_idx = block_idx % ext_super.blocks_per_group;

    const bgd_offset = calcBgdOffset(super, group);
    const bgd = try cursor.ensureAs(BlockGroupDescriptor, .write, bgd_offset);
    try bitmapFree(super, bgd.block_bitmap, inner_idx, cursor);
    try cursor.ensureCache(.write, bgd_offset);

    bgd.free_blocks += 1;
    cursor.setDirty(@sizeOf(BlockGroupDescriptor));
}

fn freeBlock(super: *const vfs.Superblock, block_idx: u32, cursor: *cache.Cursor) vfs.Error!void {
    try freeBlockPartially(super, block_idx, cursor);

    const super_offset_abs = super.part_offset + superblock_disk_offset;
    try cursor.ensureCache(.write, super_offset_abs);

    cursor.asObject(Superblock).free_blocks +%= 1;
    cursor.setDirty(@sizeOf(Superblock));
}

fn getInodeDataBlock(
    super: *const vfs.Superblock,
    inode: *const Inode,
    logical_idx: u32,
    comptime op: Operation,
    cursor: *cache.Cursor,
) vfs.Error!u32 {
    const path = Inode.calcPtrPath(logical_idx, super);
    if (path.indir_level == 0) return inode.direct_ptrs[path.inner_idx];

    var current_block = inode.indir_ptrs[path.indir_level - 1];
    if (current_block == 0) return error.IoFailed;

    for (0..path.indir_level - 1) |depth| {
        current_block = try readPointer(super, current_block, path.ptr_stack[depth], op, cursor);
        if (current_block == 0) return error.IoFailed;
    }

    const block_idx = try readPointer(super, current_block, path.inner_idx, op, cursor);
    if (block_idx == 0) return error.IoFailed;

    return block_idx;
}

inline fn readPointer(
    super: *const vfs.Superblock,
    block_idx: u32,
    entry_idx: u32,
    comptime op: Operation,
    cursor: *cache.Cursor,
) vfs.Error!u32 {
    const offset = calcBlockOffset(super, block_idx) + (entry_idx * @sizeOf(u32));
    return (try cursor.ensureAs(u32, op, offset)).*;
}

fn writePointer(
    super: *const vfs.Superblock,
    block_idx: u32,
    entry_idx: u32,
    value: u32,
    cursor: *cache.Cursor,
) vfs.Error!void {
    const offset = calcBlockOffset(super, block_idx) + (entry_idx * @sizeOf(u32));
    (try cursor.ensureAs(u32, .write, offset)).* = value;

    cursor.setDirty(@sizeOf(u32));
}

fn bitmapFree(
    super: *const vfs.Superblock,
    bitmap_block: u32,
    inner_idx: u32,
    cursor: *cache.Cursor,
) vfs.Error!void {
    const bitmap_offset = calcBlockOffset(super, bitmap_block);
    const byte_idx: usize = inner_idx / lib.byte_size;
    const bit_idx: u3 = @intCast(inner_idx % lib.byte_size);
    const mask = @as(u8, 1) << bit_idx;

    const bitmap = try cursor.ensureAs(u8, .write, bitmap_offset + byte_idx);
    if ((bitmap.* & mask) == 0) return error.BadSuperblock;

    bitmap.* &= ~mask;
    cursor.setDirty(1);
}

fn calcInodesInGroup(ext_super: *const Superblock, group: u32) u32 {
    const base = group * ext_super.inodes_per_group;
    return @min(ext_super.inodes_per_group, ext_super.total_inodes - @min(base, ext_super.total_inodes));
}

fn calcBlocksInGroup(ext_super: *const Superblock, group: u32) u32 {
    const base = group * ext_super.blocks_per_group;
    return @min(ext_super.blocks_per_group, ext_super.total_blocks - @min(base, ext_super.total_blocks));
}

fn dentryOpen(_: *const vfs.Dentry, file: *vfs.File) vfs.Error!void {
    file.ops = &file_cached_ops.ops;
}

fn dentryClose(dentry: *const vfs.Dentry, file: *vfs.File) void {
    if (
        !file.perm.checkAccess(.w) or
        dentry.inode.type != .regular_file or
        dentry.inode.size == 0
    ) return;

    if (!dentry.inode.cache_ctrl.writeBackAll()) log.warn("write back failed!", .{});
}

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
    var ptr_iter: Inode.BlockIter = try .init(@truncate(start_blk_i), super, ext_inode, .read);
    defer ptr_iter.deinit(.read);

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
            i_blk = try ptr_iter.next(.read);
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

fn fileWriteBackCache(block: *vm.cache.Block, quants: []const vm.cache.Block.Quant, _: u5) bool {
    const inode: *vfs.Inode = @fieldParentPtr("cache_ctrl", block.ctrl);
    const super = inode.fs_data.asPtr(vfs.Superblock) orelse return false;
    const block_offset = block.getOffset();

    log.debug("inode {}: write back block {}", .{inode.index, block.index});

    var cursor = super.drive.blankCursor();
    defer cursor.close(.write);

    const ext_inode = readInode(super, inode.index, .write, &cursor) catch return false;
    const inode_offset = cursor.offset;

    for (quants) |quant| {
        var begin = block_offset + quant.base;
        const end = block_offset + quant.top;

        while (begin < end) {
            const file_block_idx: u32 = @intCast(begin >> super.block_shift);
            const inner_offset = super.offsetModBlock(begin);
            const chunk_len = @min(end - begin, super.block_size - inner_offset);

            var data_block_idx = getInodeDataBlock(
                super, ext_inode, file_block_idx,
                .write, &cursor
            ) catch 0;

            if (data_block_idx == 0) {
                data_block_idx = allocBlock(super, inode.index, &cursor) catch return false;
                const extra_sectors = setInodeDataBlock(
                    super, inode.index,
                    file_block_idx, data_block_idx,
                    &cursor,
                ) catch return false;

                cursor.ensureCache(.write, inode_offset) catch return false;
                ext_inode.sectors_num += sectorsPerBlock(super) + extra_sectors;
            } else {
                cursor.ensureCache(.write, inode_offset) catch return false;
            }

            const disk_offset = calcBlockOffset(super, data_block_idx) + inner_offset;
            const lba_offset = super.drive.offsetToLba(disk_offset);
            const cache_begin = begin - block_offset;
            const cache_end = cache_begin + chunk_len;

            super.drive.ioSync(.write, lba_offset, block.asSlice()[cache_begin..cache_end]) catch return false;
            begin += chunk_len;
        }
    }

    cursor.ensureCache(.write, inode_offset) catch return false;

    inode.rw_sem.writeLock();
    defer inode.rw_sem.writeUnlock();

    if (inode.size != ext_inode.size()) {
        log.debug("inode {}: size is changed: {} -> {}", .{
            inode.index, ext_inode.size(), inode.size
        });

        ext_inode.size_lo = @truncate(inode.size);
        ext_inode.size_hi = @truncate(inode.size >> 32);
    }

    const time = vfs.getTime();
    const posix_time = time.posix();

    ext_inode.access_time = @truncate(posix_time);
    ext_inode.modify_time = @truncate(posix_time);
    inode.access_time_sec = time.sec;
    inode.modify_time_sec = time.sec;
    inode.access_time_ns = time.ns;
    inode.modify_time_ns = time.ns;

    if (ext_inode.links_num < 1) {
        @branchHint(.cold);
        log.warn("inode {}: syncing, but there are no hard links", .{inode.index});
    }

    cursor.setDirty(@sizeOf(Inode));
    return true;
}
