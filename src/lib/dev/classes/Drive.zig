//! # Block device high-level interface

// Copyright (C) 2024-2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const bindings = @import("../../bindings.zig");
const dev = @import("../../dev.zig");
const devfs = vfs.devfs;
const lib = @import("../../lib.zig");
const sched = @import("../../sched.zig");
const vm = @import("../../vm.zig");
const vfs = @import("../../vfs.zig");

const Self = @This();

pub const cache = @import("Drive/cache.zig");

pub const Error = devfs.Error || dev.Name.Error || error{
    BadLbaSize,
    IoFailed,
};

pub const io = opaque {
    pub const Operation = enum(u8) { read, write };

    pub const Status = enum(u8) { failed, success, none };

    pub const Queue = struct {
        pub const default_capacity = 256;

        pub const List = std.SinglyLinkedList;
        pub const Node = List.Node;

        list: List = .{},
        requests: [*]Request,
        wait_queue: sched.WaitQueue = .{},

        len: u32 = 0,
        lock: lib.sync.Spinlock = .{},
    };

    pub const Request = struct {
        pub const Callback = struct {
            pub const Fn = *const fn (*const Request, Status, lib.AnyData) void;

            func: Fn,
            data: lib.AnyData = .{},

            pub inline fn call(self: *const Callback, request: *const Request, status: Status) void {
                self.func(request, status, self.data);
            }
        };

        pub const max_id = std.math.maxInt(u16);

        id: u16,
        cpu: u8,
        operation: Operation,

        lba_offset: usize,
        lba_num: u32,

        lma_buf: [*]u8,

        callback: Callback,
        wait_queue: sched.WaitQueue = .{},

        node: Queue.Node = .{},

        comptime {
            std.debug.assert(@sizeOf(Request) == 56);
        }

        pub inline fn fromNode(node: *Queue.Node) *Request {
            return @fieldParentPtr("node", node);
        }
    };

    pub const Control = struct {
        pub const AnyQueue = union {
            multi: [*]Queue,
            single: Queue,
        };

        pub const Handle = struct {
            request: *Request,
            arena: *vm.ObjectAllocator.Arena,
        };

        queue: AnyQueue,

        pub inline fn getRequest(self: *Control, id: u16) *Request {
            return bindings.getInstance().dev.classes.drive.getIoRequest(self, id);
        }
    };
};

pub const Operations = struct {
    pub const HandleIoFn = *const fn (drive: *Self, io_request: *const io.Request) bool;

    handleIo: HandleIoFn,
};

pub const Flags = packed struct {
    multi_io: bool = false,
    partitionable: bool = false,
};

base_part: vfs.parts.Partition,

lba_size: u16,
lba_shift: u4 = undefined,

/// Drive capacity in bytes.
capacity: usize,

flags: Flags = .{},

io_ctrl: io.Control = undefined,
cache_ctrl: vm.cache.Control = undefined,
cache_worker: *sched.Task = undefined,

parts: vfs.parts.List = .{},
dev_region: *devfs.Region,

vtable: *const Operations,

pub inline fn setup(self: *Self, name: dev.Name, dev_region: *devfs.Region, multi_io: bool, partitions: bool) Error!void {
    return bindings.getInstance().dev.classes.drive.setup(self, name, dev_region, multi_io, partitions);
}

pub inline fn deinit(self: *Self) void {
    bindings.getInstance().dev.classes.drive.deinit(self);
}

pub inline fn onObjectAdd(self: *Self) void {
    bindings.getInstance().dev.classes.drive.onObjectAdd(self);
}

pub inline fn getName(self: *Self) *const dev.Name {
    return &self.base_part.dev_file.name;
}

pub inline fn completeIo(self: *Self, id: u16, status: io.Status) void {
    bindings.getInstance().dev.classes.drive.completeIo(self, id, status);
}

pub inline fn openCursor(self: *Self, comptime op: io.Operation, offset: usize) Error!cache.Cursor {
    return .open(self, op, offset);
}

pub inline fn blankCursor(self: *Self) cache.Cursor {
    return .blank(self);
}

pub inline fn ioAsync(self: *Self, op: io.Operation, lba_offset: usize, buffer: []u8, callback: io.Request.Callback) void {
    bindings.getInstance().dev.classes.drive.ioAsync(self, op, lba_offset, buffer, callback);
}

pub inline fn ioSync(self: *Self, op: io.Operation, lba_offset: usize, buffer: []u8) Error!void {
    bindings.getInstance().dev.classes.drive.ioSync(self, op, lba_offset, buffer);
}

pub inline fn getPartition(self: *const Self, part: u32) ?*vfs.Partition {
    return bindings.getInstance().dev.classes.drive.getPartition(self, part);
}

pub inline fn lbaToOffset(self: *const Self, lba_offset: usize) usize {
    return lba_offset << self.lba_shift;
}

pub inline fn offsetToLba(self: *const Self, offset: usize) usize {
    return offset >> self.lba_shift;
}

pub inline fn offsetModLba(self: *const Self, offset: usize) u16 {
    const mask = comptime ~@as(u16, 0);
    return ~(mask << self.lba_shift) & @as(u16, @truncate(offset));
}
