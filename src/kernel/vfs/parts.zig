//! # Partitions handling for block devices.

const std = @import("std");

const dev = @import("../dev.zig");
const devfs = vfs.devfs;
const Drive = dev.classes.Drive;
const log = std.log.scoped(.parts);
const utils = @import("../utils.zig");
const vfs = @import("../vfs.zig");
const vm = @import("../vm.zig");

pub const Error = Drive.Error;

pub const Node = List.Node;
pub const List = utils.List(Partition);

pub const Partition = struct {
    pub const alloc_config: vm.obj.AllocatorConfig = .{
        .allocator = .safe_oma,
        .capacity = 128,
        .wrapper = .listNode(Node)
    };

    lba_start: usize,
    lba_end: usize,

    dev_file: devfs.DevFile = undefined,

    pub inline fn asNode(self: *Partition) *Node {
        return @fieldParentPtr("data", self);
    }

    pub fn init(self: *Partition, lba_start: usize, lba_end: usize) !void {
        self.lba_start = lba_start;
        self.lba_end = lba_end;
    }

    pub fn registerDevice(
        self: *Partition, name: dev.Name, num: devfs.DevNum,
        fops: *const vfs.File.Operations, data: ?*anyopaque
    ) !void {
        self.dev_file = .{
            .name = name,
            .num = num,
            .fops = fops,
            .data = .from(data)
        };
        try devfs.registerBlockDev(&self.dev_file);
    }
};

pub const GuidPartitionTable = extern struct {
    pub const Guid = extern struct {
        val: [16]u8,

        pub fn format(value: *const Guid, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
            try writer.print(
                "{X:0>2}{X:0>2}{X:0>2}{X:0>2}-{X:0>2}{X:0>2}-{X:0>2}{X:0>2}-{X:0>2}{X:0>2}-{X:0>2}{X:0>2}{X:0>2}{X:0>2}{X:0>2}{X:0>2}", .{
                value.val[3],value.val[2],value.val[1],value.val[0],value.val[5],
                value.val[4],value.val[7],value.val[6],value.val[8],value.val[9],
                value.val[10],value.val[11],value.val[12],value.val[13],value.val[14],
                value.val[15]
            });
        }
    };

    /// Represents GPT header.  
    /// *little-endian*
    pub const Header = extern struct {
        pub const sign_value = "EFI PART".*;

        signature: [8]u8 = sign_value,
        revision: u32,
        size: u32 = @sizeOf(Header),
        crc32: u32,
        _rsrvd: u32 = 0,

        lba: u64,
        backup_lba: u64,

        first_usable_lba: u64,
        last_usable_lba: u64,

        guid: Guid,

        array_lba: u64,

        parts_num: u32,
        ent_size: u32,

        ents_crc32: u32,

        pub fn checkSign(self: *const Header) bool {
            return std.mem.eql(u8, &self.signature, &sign_value);
        }
    };

    pub const Entry = extern struct {
        pub const unused_guid: Guid = .{ .val = .{ 0 } ** 16 };

        type_guid: Guid,
        guid: Guid,

        start_lba: u64,
        end_lba: u64,

        attrs: u64,

        /// utf-16 (LE)
        name: [36]u16
    };
};

pub const Gpt = GuidPartitionTable;

pub fn probe(drive: *Drive) Error!void {
    std.debug.assert(drive.parts.len == 1);

    const lba_size = drive.lba_size;
    var cache_iter = try drive.readCached(lba_size);
    const gpt = cache_iter.asObject(Gpt.Header);

    if (gpt.checkSign() == false) return;

    log.info("GPT found: {}; patritions: {}; entry size: {}", .{
        drive.getName(), gpt.parts_num, gpt.ent_size
    });

    const parts_num = gpt.parts_num;
    const ent_size = gpt.ent_size;

    if (parts_num == 0) return;

    const drive_name = drive.getName().str();
    const dev_name_letter = std.ascii.isAlphabetic(drive_name[drive_name.len - 1]);

    // Entries
    const base_offset = gpt.array_lba * lba_size;
    var name: [36]u8 = .{ 0 } ** 36;

    for (0..parts_num) |i| {
        const ent_offset = base_offset + (i * ent_size);
        try drive.readCachedNext(&cache_iter, ent_offset);

        const entry = cache_iter.asObject(Gpt.Entry);

        if (std.mem.eql(u8, &entry.guid.val, &Gpt.Entry.unused_guid.val)) break;

        const dev_num = drive.dev_region.alloc() orelse return Error.DevMinorLimit;
        errdefer drive.dev_region.free(dev_num);

        var dev_name = try blk: {
            if (dev_name_letter)
                break :blk dev.Name.print("{s}{}", .{drive_name, i + 1});

            break :blk dev.Name.print("{s}p{}", .{drive_name, i + 1});
        };
        errdefer dev_name.deinit();

        _ = std.unicode.utf16LeToUtf8(&name, &entry.name) catch {};
        log.info("{s}: type: {}, guid: {}: \"{s}\"", .{
            dev_name.str(), entry.type_guid,
            entry.guid, name[0..std.mem.len(@as([*:0]u8, @ptrCast(&name)))]
        });

        const part = try new();
        errdefer delete(part);

        part.* = .{
            .lba_start = entry.start_lba,
            .lba_end = entry.end_lba
        };

        drive.parts.append(part.asNode());
        errdefer drive.parts.remove(part.asNode());

        try part.registerDevice(dev_name, dev_num, &Drive.file_operations, drive);
    }
}

pub inline fn new() Error!*Partition {
    const part = vm.obj.new(Partition) orelse return error.NoMemory;
    return part;
}

pub inline fn delete(part: *Partition) void {
    vm.obj.free(Partition, part);
}