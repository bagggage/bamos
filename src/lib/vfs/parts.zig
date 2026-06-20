//! # Partitions handling for block devices.

// Copyright (C) 2024-2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const bindings = @import("../bindings.zig");
const dev = @import("../dev.zig");
const devfs = vfs.devfs;
const Drive = dev.classes.Drive;
const lib = @import("../lib.zig");
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

    data: lib.AnyData,
    dev_file: devfs.DevFile = undefined,

    node: Node = .{},

    pub inline fn fromNode(node: *Node) *Partition {
        return @fieldParentPtr("node", node);
    }

    pub inline fn fromDevFile(dev_file: *devfs.DevFile) *Partition {
        return @fieldParentPtr("dev_file", dev_file);
    }

    pub inline fn init(lba_start: usize, lba_end: usize) Partition {
        return .{ .lba_start = lba_start, .lba_end = lba_end };
    }
};

pub const GuidPartitionTable = extern struct {
    pub const Guid = extern struct {
        val: [16]u8,

        pub fn format(value: *const Guid, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.print(
                "{X:0>2}{X:0>2}{X:0>2}{X:0>2}-{X:0>2}{X:0>2}-{X:0>2}{X:0>2}-{X:0>2}{X:0>2}-{X:0>2}{X:0>2}{X:0>2}{X:0>2}{X:0>2}{X:0>2}", .{
                value.val[3], value.val[2], value.val[1], value.val[0],
                value.val[5], value.val[4], value.val[7], value.val[6],
                value.val[8], value.val[9], value.val[10], value.val[11],
                value.val[12], value.val[13], value.val[14], value.val[15],
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

pub inline fn probe(drive: *Drive) Error!void {
    return bindings.getInstance().vfs.parts.probe(drive);
}
