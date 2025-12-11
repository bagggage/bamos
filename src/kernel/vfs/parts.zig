//! # Partitions handling for block devices.

// Copyright (C) 2024-2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const dev = @import("../dev.zig");
const devfs = vfs.devfs;
const Drive = dev.classes.Drive;
const log = std.log.scoped(.parts);
const vfs = @import("../vfs.zig");
const vm = @import("../vm.zig");

pub const Error = Drive.Error;

pub const List = std.DoublyLinkedList;
pub const Node = List.Node;

pub const Partition = struct {
    pub const alloc_config: vm.auto.Config = .{
        .allocator = .oma,
        .capacity = 128
    };

    lba_start: usize,
    lba_end: usize,

    dev_file: devfs.DevFile = undefined,

    node: Node = .{},

    pub inline fn fromNode(node: *Node) *Partition {
        return @fieldParentPtr("node", node);
    }

    pub inline fn fromDevFile(dev_file: *devfs.DevFile) *Partition {
        return @fieldParentPtr("dev_file", dev_file);
    }

    pub fn init(lba_start: usize, lba_end: usize) Partition {
        return .{ .lba_start = lba_start, .lba_end = lba_end };
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

        pub fn format(value: *const Guid, writer: *std.Io.Writer) std.Io.Writer.Error!void {
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
    std.debug.assert(drive.parts.first == drive.parts.last);

    const lba_size = drive.lba_size;
    var cache_cursor = try drive.openCursor(.read, lba_size);
    defer cache_cursor.close(.read);

    const gpt = cache_cursor.asObject(Gpt.Header);
    if (gpt.checkSign() == false) return;

    log.info("GPT found: {f}; patritions: {}; entry size: {}", .{
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
        try cache_cursor.ensureCache(.read, ent_offset);

        const entry = cache_cursor.asObject(Gpt.Entry);
        if (std.mem.eql(u8, &entry.guid.val, &Gpt.Entry.unused_guid.val)) break;

        const dev_num = drive.dev_region.alloc() orelse return Error.DevMinorLimit;
        errdefer drive.dev_region.free(dev_num);

        var dev_name = try blk: {
            if (dev_name_letter) break :blk dev.Name.print("{s}{}", .{drive_name, i + 1});
            break :blk dev.Name.print("{s}p{}", .{drive_name, i + 1});
        };
        errdefer dev_name.deinit();

        _ = std.unicode.utf16LeToUtf8(&name, &entry.name) catch {};
        log.info("{s}: type: {f}, guid: {f}: \"{s}\"", .{
            dev_name.str(), entry.type_guid,
            entry.guid, name[0..std.mem.len(@as([*:0]u8, @ptrCast(&name)))]
        });

        const part = vm.auto.alloc(Partition) orelse return error.NoMemory;
        errdefer vm.auto.free(Partition, part);

        part.* = .{
            .lba_start = entry.start_lba,
            .lba_end = entry.end_lba
        };

        drive.parts.append(&part.node);
        errdefer drive.parts.remove(&part.node);

        try part.registerDevice(dev_name, dev_num, &Drive.file_operations, drive);
    }
}

