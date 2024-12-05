//! # Partitions handling for block devices.

const std = @import("std");

const dev = @import("../dev.zig");
const Drive = dev.classes.Drive;
const log = std.log.scoped(.parts);
const utils = @import("../utils.zig");
const vm = @import("../vm.zig");

const PartNode = List.Node;
const Oma = vm.SafeOma(PartNode);

pub const List = utils.List(Partition);

pub const Error = Drive.Error;

pub const Partition = struct {
    lba_start: usize,
    lba_end: usize,
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
        pub const sign_value = "EFI PART";

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
            return std.mem.eql(u8, &self.signature, sign_value);
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

var parts_oma = Oma.init(32);

pub fn probe(drive: *Drive) Error!void {
    std.debug.assert(drive.parts.len == 1);

    const lba_size = drive.lba_size;
    var blk = try drive.readCached(lba_size);
    const gpt = blk.asObject(Gpt.Header, lba_size);
    
    if (gpt.checkSign() == false) return;

    log.info("GPT found: {s}; patritions: {}; entry size: {}", .{
        drive.base_name, gpt.parts_num, gpt.ent_size
    });

    const parts_num = gpt.parts_num;
    const ent_size = gpt.ent_size;

    if (parts_num == 0) return;

    // Entries
    const base_offset = gpt.array_lba * lba_size;
    var name: [36]u8 = .{ 0 } ** 36;

    for (0..parts_num) |i| {
        const ent_offset = base_offset + (i * ent_size);
        blk = try drive.readCachedNext(blk, ent_offset);

        const entry = blk.asObject(Gpt.Entry, ent_offset);

        if (std.mem.eql(u8, &entry.guid.val, &Gpt.Entry.unused_guid.val)) break;

        _ = std.unicode.utf16LeToUtf8(&name, &entry.name) catch {};
        log.info("Partition: type: {} guid: {}: \"{s}\"", .{
            entry.type_guid, entry.guid, name[0..std.mem.len(@as([*:0]u8, @ptrCast(&name)))]
        });

        const part = try new();

        part.data.lba_start = entry.start_lba;
        part.data.lba_end = entry.end_lba;

        drive.parts.append(part);
    }
}

pub fn new() Error!*PartNode {
    return parts_oma.alloc() orelse return error.NoMemory;
}

pub fn delete(part: *PartNode) void {
    parts_oma.free(part);
}