//! Socket file descriptor

// Copyright (C) 2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const Dentry = vfs.Dentry;
const Error = net.Error;
const File = vfs.File;
const Inode = vfs.Inode;
const lib = @import("../lib.zig");
const linux = std.os.linux;
const log = std.log.scoped(.@"net.Socket");
const net = @import("../net.zig");
const sched = @import("../sched.zig");
const sys = @import("../sys.zig");
const vfs = @import("../vfs.zig");
const vm = @import("../vm.zig");

const Self = @This();

const socket_fs_ctx: vfs.Context.Virt = .{};

const socket_inode: Inode = .{
    .index = 0,
    .type = .socket,
    .gid = 0,
    .uid = 0,
    .links_num = 0,
    .cache_ctrl = .{ .write_back = null },
};

const socket_dentry: Dentry = .{
    .name = Dentry.Name.init("@socket") catch unreachable,
    .inode = @constCast(&socket_inode),
    .ctx = .{ .virt = @constCast(&socket_fs_ctx) },
    .parent = @constCast(&socket_dentry),
};

pub const Type = enum(u8) {
    stream = linux.SOCK.STREAM,
    datagram = linux.SOCK.DGRAM,
    sequential = linux.SOCK.SEQPACKET,
    raw = linux.SOCK.RAW,
};

pub const Operations = struct {
    pub const SendFn = *const fn (*Self, *net.Packet, ?[]const u8) Error!usize;
    pub const ReceiveFn = *const fn (*Self, usize, ?[]const u8) Error!*net.Packet;
    pub const BindFn = *const fn (*Self, []const u8) Error!void;
    pub const DeleteFn = *const fn (*Self) void;

    send: SendFn = &badSend,
    receive: ReceiveFn = &badReceive,
    bind: BindFn = &badBind,
    delete: DeleteFn,

    fn badSend(_: *Self, _: *net.Packet, _: ?[]const u8) Error!usize {
        return error.BadOperation;
    }

    fn badReceive(_: *Self, _: usize, _: ?[]const u8) Error!*net.Packet {
        return error.BadOperation;
    }

    fn badBind(_: *Self, _: []const u8) Error!void {
        return error.BadOperation;
    }
};

recv_queue: net.Packet.List = .{},
send_queue: net.Packet.List = .{},
ops: *const Operations,

recv_timeout_ns: u64 = 0,
send_timeout_ns: u64 = 0,
listen_limit: u32 = 0,

mutex: lib.sync.Mutex = .{},
ref_count: lib.atomic.RefCount(u32) = .{},

pub fn create(family: net.Family, @"type": Type) Error!*File {
    const file = vm.auto.alloc(File) orelse return error.NoMemory;
    errdefer vm.auto.free(File, file);

    const socket = try net.createSocket(family, @"type");
    socket.ref();

    file.* = .{
        .type = .socket,
        .dentry = &socket_dentry,
        .data = .fromPtr(socket),
        .perm = .rw,
    };

    return file;
}

pub inline fn ref(self: *Self) void {
    self.ref_count.inc();
}

pub inline fn tryRef(self: *Self) bool {
    return self.ref_count.get();
}

pub fn deref(self: *Self) void {
    if (self.ref_count.put()) {
        @branchHint(.unlikely);
        self.ops.delete(self); 
    }
}

pub inline fn send(self: *Self, packet: *net.Packet, address: ?*const net.Address) Error!usize {
    return self.ops.send(self, packet, address);
}

pub inline fn receive(self: *Self, buffer: []u8, address: ?*const net.Address) Error!*net.Packet {
    return self.ops.receive(self, buffer, address);
}

pub inline fn bind(self: *Self, address: *const net.Address, size: u32) Error!void {
    return self.ops.bind(self, address, size);
}
