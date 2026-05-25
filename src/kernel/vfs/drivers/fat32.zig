//! # FAT32 filesystem driver

const std = @import("std");
const cache = vfs.Drive.cache;
const lib = @import("../../lib.zig");
const log = std.log.scoped(.fat32);
const vfs = @import("../../vfs.zig");
const vm = @import("../../vm.zig");

const boot_sector_offset = 0;
const fat_magic = 0xAA55;
const root_cluster = 2;

/// Boot Sector (BPB)
const BootSector = extern struct {
    jmp_boot: [3]u8,
    oem_name: [8]u8,
    bytes_per_sector: u16,
    sectors_per_cluster: u8,
    reserved_sectors: u16,
    num_fats: u8,
    root_entries: u16,      // FAT32: 0
    total_sectors_16: u16,  // FAT32: 0
    media: u8,
    sectors_per_fat_16: u16, // FAT32: 0
    sectors_per_track: u16,
    num_heads: u16,
    hidden_sectors: u32,
    total_sectors_32: u32,

    // FAT32 extended fields
    sectors_per_fat_32: u32,
    ext_flags: u16,
    fs_ver: u16,
    root_cluster: u32,
    fs_info: u16,
    backup_boot: u16,
    reserved: [12]u8,
    drive: u8,
    reserved1: u8,
    boot_sig: u8,
    vol_id: u32,
    vol_label: [11]u8,
    fs_type: [8]u8,
    boot_code: [420]u8,
    boot_sig_55aa: u16,

    pub inline fn check(self: *const BootSector) bool {
        return self.boot_sig_55aa == fat_magic and 
               self.sectors_per_fat_16 == 0 and 
               self.root_entries == 0;
    }

    pub inline fn isFat32(self: *const BootSector) bool {
        return std.mem.eql(u8, &self.fs_type, "FAT32   ");
    }
};

const DirEntry = extern struct {
    name: [11]u8,
    attributes: u8,
    nt_reserved: u8,
    creation_time_tenth: u8,
    creation_time: u16,
    creation_date: u16,
    last_access_date: u16,
    first_cluster_high: u16,
    write_time: u16,
    write_date: u16,
    last_cluster_low: u16,
    file_size: u32,

    pub const Attributes = packed struct {
        readonly: bool,
        hidden: bool,
        system: bool,
        volume_id: bool,
        directory: bool,
        archive: bool,
        reserved: u2,
    };

    pub inline fn getAttributes(self: *const DirEntry) Attributes {
        return @bitCast(self.attributes);
    }

    pub inline fn getFirstCluster(self: *const DirEntry) u32 {
        return (@as(u32, self.first_cluster_high) << 16) | self.last_cluster_low;
    }

    pub inline fn getShortName(self: *const DirEntry) []const u8 {
        return &self.name;
    }

    pub inline fn isDirectory(self: *const DirEntry) bool {
        return self.getAttributes().directory;
    }

    pub inline fn isLongName(self: *const DirEntry) bool {
        return self.attributes == 0x0F;
    }

    pub inline fn isEmpty(self: *const DirEntry) bool {
        return self.name[0] == 0xE5 or self.name[0] == 0x00;
    }
};

/// Filesystem specific context
const Context = struct {
    boot_sector: BootSector,
    fat_start: usize,
    data_start: usize,
    sectors_per_fat: u32,
    bytes_per_cluster: u32,
    root_dir_sectors: u32,

    pub fn init(boot: BootSector, part_offset: usize) Context {
        const fat_start = part_offset + (boot.reserved_sectors * boot.bytes_per_sector);
        const data_start = fat_start + (boot.num_fats * boot.sectors_per_fat_32 * boot.bytes_per_sector);
        const bytes_per_cluster = boot.bytes_per_sector * boot.sectors_per_cluster;
        
        return .{
            .boot_sector = boot,
            .fat_start = fat_start,
            .data_start = data_start,
            .sectors_per_fat = boot.sectors_per_fat_32,
            .bytes_per_cluster = bytes_per_cluster,
            .root_dir_sectors = 0, // FAT32 doesn't have fixed root directory
        };
    }

    pub fn clusterToOffset(self: *const Context, cluster: u32) usize {
        return self.data_start + ((cluster - 2) * self.bytes_per_cluster);
    }

    pub fn getNextCluster(self: *const Context, cursor: *cache.Cursor, cluster: u32) !u32 {
        const fat_offset = (cluster * 4) / self.boot_sector.bytes_per_sector;
        const fat_sector = self.fat_start + (fat_offset * self.boot_sector.bytes_per_sector);
        
        try cursor.ensureCache(.read, fat_sector);
        const fat_entry = cursor.asObject(u32);

        return fat_entry.* & 0x0FFFFFFF; // Mask to 28 bits
    }

    pub fn isEndOfChain(cluster: u32) bool {
        return cluster >= 0x0FFFFFF8;
    }

    pub fn isBadCluster(cluster: u32) bool {
        return cluster == 0x0FFFFFF7;
    }
};

// File operations
const file_cached_ops: vfs.internals.file.Cached = .{
    .readCacheBlock = fileReadCacheBlock
};

// Filesystem registration
var fs = vfs.FileSystem.init(
    "fat32",
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
    const boot_offset = part_offset + boot_sector_offset;

    // Read boot sector
    var boot_cursor = try drive.openCursor(.read, boot_offset);
    errdefer boot_cursor.close(.read);

    const boot = boot_cursor.asObject(BootSector);
    if (!boot.check() or !boot.isFat32()) return error.BadSuperblock;

    log.debug("OEM: {s}, cluster size: {} bytes", .{
        &boot.oem_name, boot.bytes_per_sector * boot.sectors_per_cluster
    });

    // Validate cluster size
    if (boot.bytes_per_sector < drive.lba_size) return error.BadSuperblock;

    // Initialize superblock
    const super = vfs.Superblock.new() orelse return error.NoMemory;
    errdefer super.free();

    const fat32_ctx = vm.auto.alloc(Context) orelse return error.NoMemory;
    fat32_ctx.* = Context.init(boot.*, part_offset);

    super.init(drive, part, boot.bytes_per_sector, fat32_ctx);

    // Initialize root dentry
    {
        var cache_cursor = drive.blankCursor();
        defer cache_cursor.close(.read);

        const root_dentry = vfs.Dentry.new() orelse return error.NoMemory;
        errdefer root_dentry.free();

        const root_inode = vfs.Inode.new() orelse return error.NoMemory;
        errdefer root_inode.free();

        root_inode.* = .{
            .index = boot.root_cluster,
            .type = .directory,
            .perm = 0o755,
            .size = 0,
            .cache_ctrl = .{ .write_back = vfs.internals.cache.noWriteBackFail },
            .create_time = 0,
            .access_time = 0,
            .modify_time = 0,
            .uid = 0,
            .gid = 0,
            .links_num = 2,
            .fs_data = .{}
        };

        root_dentry.setup("/", undefined, root_inode, &fs.dentry_ops) catch unreachable;
        super.root = root_dentry;
    }

    return super;
}

fn readDirEntry(super: *const vfs.Superblock, cluster: u32, offset: usize, cursor: *cache.Cursor) !?DirEntry {
    const fat32_ctx = super.fs_data.asPtr(Context).?;
    const cluster_offset = fat32_ctx.clusterToOffset(cluster) + offset;

    try cursor.ensureCache(.read, cluster_offset);
    const entry = cursor.asObject(DirEntry);

    if (entry.isEmpty()) return null;
    if (entry.isLongName()) {
        // Skip long filename entries for now
        return readDirEntry(super, cluster, offset + @sizeOf(DirEntry), cursor);
    }

    return entry.*;
}

fn findInDirectory(super: *const vfs.Superblock, dir_cluster: u32, name: []const u8, cursor: *cache.Cursor) !?u32 {
    const fat32_ctx = super.fs_data.asPtr(Context).?;
    var current_cluster = dir_cluster;
    var offset: usize = 0;

    while (true) {
        const entry = readDirEntry(super, current_cluster, offset, cursor) catch |err| switch (err) {
            error.IoFailed => return null,
            else => return err,
        } orelse {
            offset += @sizeOf(DirEntry);
            if (offset >= fat32_ctx.bytes_per_cluster) {
                // Move to next cluster
                const next_cluster = try fat32_ctx.getNextCluster(cursor, current_cluster);
                if (fat32_ctx.isEndOfChain(next_cluster)) break;
                if (fat32_ctx.isBadCluster(next_cluster)) return error.BadInode;
                
                current_cluster = next_cluster;
                offset = 0;
            }
            continue;
        };

        const entry_name = entry.getShortName();
        const formatted_name = try formatFat32Name(entry_name);
        defer vm.auto.free(u8, formatted_name.ptr);

        if (std.mem.eql(u8, formatted_name, name)) {
            return entry.getFirstCluster();
        }

        offset += @sizeOf(DirEntry);
    }

    return null;
}

fn formatFat32Name(name: []const u8) ![]const u8 {
    // Remove spaces and convert to lowercase
    var result = vm.auto.alloc(u8, name.len) orelse return error.NoMemory;
    var result_len: usize = 0;

    for (name) |byte| {
        if (byte == ' ') continue;
        result[result_len] = std.ascii.toLower(byte);
        result_len += 1;
    }

    return result[0..result_len];
}

fn dentryLookup(parent: *const vfs.Dentry, name: []const u8) ?*vfs.Dentry {
    const super = parent.ctx.super;

    var cache_cursor = super.drive.blankCursor();
    defer cache_cursor.close(.read);

    const cluster = findInDirectory(super, parent.inode.index, name, &cache_cursor) catch |err| {
        log.err("Failed to find directory entry: {s}", .{@errorName(err)});
        return null;
    } orelse return null;

    // Read the directory entry to get file info
    const entry = readDirEntry(super, parent.inode.index, 0, &cache_cursor) catch return null;

    const child_dentry = vfs.Dentry.new() orelse return null;
    errdefer child_dentry.free();

    const child_inode = vfs.Inode.new() orelse return null;
    errdefer child_inode.free();

    child_inode.* = .{
        .index = cluster,
        .type = if (entry.?.isDirectory()) .directory else .regular_file,
        .perm = 0o644,
        .size = entry.?.file_size,
        .cache_ctrl = .{ .write_back = vfs.internals.cache.noWriteBackFail },
        .create_time = 0,
        .access_time = 0,
        .modify_time = 0,
        .uid = 0,
        .gid = 0,
        .links_num = 1,
        .fs_data = .{}
    };

    child_dentry.setup(name, parent, child_inode, &fs.dentry_ops) catch unreachable;
    return child_dentry;
}

fn dentryOpen(_: *const vfs.Dentry, file: *vfs.File) vfs.Error!void {
    file.ops = &file_cached_ops.ops;
}

fn dentryClose(_: *const vfs.Dentry, _: *vfs.File) void {}

fn fileReadCacheBlock(dentry: *const vfs.Dentry, block: *vm.cache.Block) vfs.Error!void {
    const inode = dentry.inode;
    const super = dentry.ctx.super;
    const fat32_ctx = super.fs_data.asPtr(Context).?;

    const offset = block.getOffset();
    const len = @min(inode.size - offset, block.size.toBytes());

    const cluster_offset = offset / fat32_ctx.bytes_per_cluster;
    const cluster = inode.index + @as(u32, @truncate(cluster_offset));

    const cluster_file_offset = fat32_ctx.clusterToOffset(cluster) + (offset % fat32_ctx.bytes_per_cluster);

    var cache_cursor = super.drive.blankCursor();
    defer cache_cursor.close(.read);

    try cache_cursor.ensureCache(.read, cluster_file_offset);
    const buffer = block.asSlice()[0..len];
    try cache_cursor.read(buffer);
}
