//! # Unix protocol family

// Copyright (C) 2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const net = @import("../net.zig");
const lib = @import("../lib.zig");
const log = std.log.scoped(.@"net.unix");
const sched = @import("../sched.zig");
const vfs = @import("../vfs.zig");
const vm = @import("../vm.zig");

const AddressTable = lib.HashTable([]const u8, opaque{
    pub fn hash(key: []const u8) u64 {
        return std.hash.Wyhash.hash(0, key);
    }

    pub fn eql(entry: *const AddressTable.Entry, key: []const u8) bool {
        const socket = Socket.fromEntry(@constCast(entry));
        if (socket.address_type == .pathname) {
            return std.mem.eql(u8, key, socket.getDentryTableKey());
        }

        for (key, socket.address.abstract) |l, r| if (l != r) return false;
        return true;
    }
});

const Socket = struct {
    const Address = std.os.linux.sockaddr.un;

    const AddressType = enum(u8) {
        unnamed = 0,
        abstract,
        pathname,
    };

    const AnyAddress = extern union {
        abstract: [*:0]u8,
        dentry: *vfs.Dentry,
    };

    pub const alloc_config: vm.auto.Config = .{ .allocator = .oma };

    base: net.Socket,
    table_entry: AddressTable.Entry = .{},
    address: AnyAddress = undefined,
    address_type: AddressType = .unnamed,

    fn deinit(self: *Socket) void {
        switch (self.address_type) {
            .unnamed => {},
            .abstract => {
                {
                    table_lock.writeLock();
                    defer table_lock.writeUnlock();

                    address_table.removeEntry(&self.table_entry);
                }

                vm.gpa.free(@ptrCast(self.address.abstract));
            },
            .pathname => {
                {
                    table_lock.writeLock();
                    defer table_lock.writeUnlock();

                    address_table.removeEntry(&self.table_entry);
                }

                const dentry = self.address.dentry;
                dentry.unlink() catch {};
                dentry.deref();
            },
        }
    }

    inline fn fromBase(socket: *net.Socket) *Socket {
        return @fieldParentPtr("base", socket);
    }

    inline fn fromEntry(entry: *AddressTable.Entry) *Socket {
        return  @fieldParentPtr("table_entry", entry);
    }

    inline fn getDentryTableKey(self: *const Socket) []const u8 {
        return std.mem.asBytes(&self.address.dentry);
    }
};

const namespace_capacity = 2048;
const max_path_length = 108;

const protocol_family: net.Family.Descriptor = .{
    .name = "unix",
    .create_socket = createSocket,
};

const socket_stream_ops: net.Socket.Operations = .{
    .send = &socketStreamSend,
    .receive = &socketStreamReceive,
    .accept = &socketAccept,
    .bind = &socketBind,
    .connect = &socketConnect,
    .listen = &socketListen,
    .delete = &socketDelete,
};

const socket_datagram_ops: net.Socket.Operations = .{
    .delete = &socketDelete,
};

const socket_sequential_ops: net.Socket.Operations = .{
    .send = &socketSequentialSend,
    .receive = &socketSequentialReceive,
    .accept = &socketAccept,
    .bind = &socketBind,
    .connect = &socketConnect,
    .listen = &socketListen,
    .delete = &socketDelete,
};

var address_table: AddressTable = .{};
var table_lock: lib.sync.RwLock = .{};

pub fn init() !void {
    address_table = try .init(namespace_capacity);
    errdefer address_table.deinit();

    try net.registerProtocolFamily(.unix, &protocol_family);
}

fn createSocket(@"type": net.Socket.Type) net.Error!*net.Socket {
    log.debug("create unix socket: {t}", .{@"type"});
    const ops = switch (@"type") {
        .stream => &socket_stream_ops,
        .datagram => &socket_datagram_ops,
        .sequential => &socket_sequential_ops,
        else => return error.UnsupportedSocketType,
    };

    const socket = vm.auto.alloc(Socket) orelse return error.NoMemory;
    socket.* = .{ .base = .{
        .@"type" = @"type",
        .family = .unix,
        .ops = ops,
    }};

    return &socket.base;
}

inline fn validateConnection(socket: *net.Socket, address: ?[]const u8) net.Error!void {
    if (!socket.isClient() or !socket.isConnected()) return error.NotConnected;
    if (address != null) return error.Connected;
}

fn socketBind(self: *net.Socket, address: []const u8) net.Error!void {
    log.debug("unix socket bind: '{s}'", .{address});
    if (address.len == 0 or address.len > max_path_length) return error.InvalidArgs;

    const unix = Socket.fromBase(self);

    unix.base.mutex.lock();
    defer unix.base.mutex.unlock();

    if (unix.address_type != .unnamed) return error.InvalidArgs;

    const key = if (address[0] == '\x00') key: {
        const buffer = vm.gpa.allocMany(u8, address.len) orelse return error.NoMemory;
        const path = buffer[0..address.len - 1];

        @memcpy(path, address[1..]);
        buffer[address.len] = 0;

        unix.address = .{ .abstract = @ptrCast(path.ptr) };
        unix.address_type = .abstract;

        break :key path;
    } else key: {
        const task = sched.getCurrentTask();

        const root, const dir,
        const gid, const uid = if (task.spec == .user) blk: {
            @branchHint(.likely);
            const process = task.spec.user.process;
            break :blk .{ process.root_dir, process.work_dir, process.gid, process.uid };
        } else .{ null, null, 0, 0 };

        const create_path = try vfs.resolveCreatePath(root, dir, address);
        defer create_path.deref();

        const dentry = try create_path.parent_dir.createFile(
            create_path.base_name,
            .socket,
            .{ .gid = gid, .uid = uid },
        );

        unix.address = .{ .dentry = dentry };
        unix.address_type = .pathname;

        break :key unix.getDentryTableKey();
    };

    table_lock.writeLock();
    defer table_lock.writeUnlock();

    if (address_table.insert(key, &unix.table_entry) != null) {
        return error.AddressInUse;
    }
}

fn socketStreamSend(
    self: *net.Socket, packet: *net.Packet,
    address: ?[]const u8, flags: net.IoFlags,
) net.Error!usize {
    self.mutex.lock();
    defer self.mutex.unlock();

    try validateConnection(self, address);

    const unix_peer = self.role.client.peer.asPtr(Socket).?;
    const target = &unix_peer.base.role.client;

    const size = packet.getDataSize();
    const timeout_ns = if (flags.dont_wait) 0 else self.getSendTimeoutNs();
    try target.recv_queue.pushWait(packet, timeout_ns);

    return size;
}

fn socketStreamReceive(
    self: *net.Socket, buffer: []u8,
    _: ?[]u8, flags: net.IoFlags,
) net.Error!usize {
    self.mutex.lock();
    defer self.mutex.unlock();

    try validateConnection(self, null);

    const timeout_ns = self.getReceiveTimeoutNs();
    return try self.role.client.recv_queue.readStreamWait(buffer, timeout_ns, flags);
}

fn socketSequentialSend(
    self: *net.Socket, packet: *net.Packet,
    address: ?[]const u8, _: net.IoFlags,
) net.Error!usize {
    self.mutex.lock();
    defer self.mutex.unlock();

    try validateConnection(self, address);

    const unix_peer = self.role.client.peer.asPtr(Socket).?;
    const target = &unix_peer.base.role.client;

    const size = packet.getDataSize();
    try target.recv_queue.push(packet);

    return size;
}

fn socketSequentialReceive(
    self: *net.Socket, buffer: []u8,
    _: ?[]u8, flags: net.IoFlags,
) net.Error!usize {
    self.mutex.lock();
    defer self.mutex.unlock();

    try validateConnection(self, null);

    const timeout_ns = self.getReceiveTimeoutNs();
    return try self.role.client.recv_queue.readDatagramWait(buffer, timeout_ns, flags);
}

fn socketDatagramSend(
    self: *net.Socket, packet: *net.Packet,
    address: ?[]const u8, _: net.IoFlags,
) net.Error!usize {
    self.mutex.lockKeepPreemption();
    defer self.mutex.unlockKeepPreemption();

    const unix_address = address orelse if (self.role.client.peer) {
        // FIXME: Implement datagram socket connection.
        log.err("FIXME: Implement datagram socket connection", .{});
        unreachable;
    } else return error.NotConnected;

    const peer = try findSocketByAddress(unix_address);
    defer peer.deref();

    const recv_queue = blk: {
        peer.mutex.lock();
        defer peer.mutex.unlock();

        if (peer.@"type" != self.@"type") return error.UnsupportedSocketType;
        if (peer.flags.shutdown_read) return error.ConnectionRefused;

        break :blk &peer.role.client.recv_queue;
    };

    const size = packet.getDataSize();
    try recv_queue.push(packet);

    return size;
}

fn socketAccept(self: *net.Socket, out_address: ?*[]u8) net.Error!*net.Socket {
    const listener = &self.role.listener;
    _ = out_address;

    const unix_client = blk: {
        try listener.waitNotEmptyLock();
        defer listener.unlock();

        break :blk listener.popAtomic(*Socket);
    };

    const client = &unix_client.base;
    errdefer client.deref();

    const new_socket = try createSocket(self.@"type");
    new_socket.ref();
    errdefer new_socket.deref();

    const new_unix = Socket.fromBase(new_socket);

    connectionLock(unix_client, new_unix);
    defer connectionUnlock(unix_client, new_unix);

    if (!client.flags.connection_pending) return error.ConnectionRefused;

    new_socket.role.client.peer = .fromPtr(unix_client);
    client.role.client.peer = .fromPtr(new_socket);

    client.flags.connection_pending = false;
    new_socket.ref();

    return new_socket;
}

fn socketConnect(self: *net.Socket, address: []const u8) net.Error!void {
    if (address.len == 0 or address.len > max_path_length) return error.InvalidArgs;

    const unix = Socket.fromBase(self);
    const listener = blk: {
        self.mutex.lockKeepPreemption();
        defer self.mutex.unlockKeepPreemption();

        if (self.isConnected()) return error.Connected;
        if (self.flags.connection_pending) return error.Already;

        const target = try findSocketByAddress(address);
        defer target.deref();

        log.debug("socket types: self - {t}, target('{s}') - {t}", .{
            self.@"type", address, target.@"type"
        });

        if (self.@"type" != target.@"type") return error.ProtocolTypeMissmatch;

        const listener = inner_blk: {
            target.mutex.lock();
            defer target.mutex.unlock();

            if (!target.isListener()) return error.ConnectionRefused;
            break :inner_blk &target.role.listener;
        };

        if (!listener.tryAddRequestLock()) return error.ConnectionRefused;

        self.flags.connection_pending = true;
        self.ref();

        listener.pushAtomic(*Socket, unix);
        listener.notifyAtomic();
        listener.unlock();

        break :blk listener;
    };

    listener.waitClientPending(self) catch |err| {
        if (err != error.InProgress) {
            self.mutex.lockKeepPreemption();
            defer self.mutex.unlockKeepPreemption();

            // Check if still not connected.
            if (self.role.client.peer.asPtr(Socket) == null) {
                // Remove from pending queue.
                @branchHint(.likely);
                self.flags.connection_pending = false;

                listener.lock.lock();
                defer listener.lock.unlock();

                if (listener.removeWeakAtomic(*Socket, unix)) self.deref();
                return err;
            }

            return;
        }

        return err;
    };

    if (!self.isConnected()) return error.ConnectionRefused;
}

fn socketListen(self: *net.Socket, pending_limit: u32) net.Error!void {
    const unix = Socket.fromBase(self);

    self.mutex.lock();
    defer self.mutex.unlock();

    if (
        self.isListener() or self.isConnected() or
        self.flags.connection_pending or unix.address_type == .unnamed
    ) return error.InvalidArgs;

    self.role = .{ .listener = try .create(*Socket, pending_limit) };
    self.flags.listener = true;
}

fn socketDelete(self: *net.Socket) void {
    const unix = Socket.fromBase(self);
    unix.deinit();

    vm.auto.free(Socket, unix);
}

fn findSocketByAddress(address: []const u8) net.Error!*net.Socket {
    var dentry_key_value: usize = undefined;
    const key = if (address[0] == '\x00') address[1..] else key: {
        const task = sched.getCurrentTask();
        const root, const dir,
        const gid, const uid = if (task.spec == .user) blk: {
            @branchHint(.likely);
            const process = task.spec.user.process;
            break :blk .{ process.root_dir, process.work_dir, process.gid, process.uid };
        } else .{ null, null, 0, 0 };

        const dentry = try vfs.lookup(root, dir, address);
        defer dentry.deref();

        if (dentry.inode.type != .socket) return error.NotSocket;

        const role = dentry.inode.getRole(uid, gid);
        if (!dentry.inode.checkAccess(.rw, role)) return error.NoAccess;

        dentry_key_value = @intFromPtr(dentry);
        break :key std.mem.asBytes(&dentry_key_value);
    };

    table_lock.readLock();
    defer table_lock.readUnlock();

    const entry = address_table.get(key) orelse return error.NoEnt;
    const socket = Socket.fromEntry(entry);

    log.debug("found socket at '{s}'", .{address});
    return if (socket.base.tryRef()) &socket.base else error.NoEnt;
}

fn connectionLock(self: *Socket, peer: *Socket) void {
    if (@intFromPtr(self) < @intFromPtr(peer)) {
        self.base.mutex.lockKeepPreemption();
        peer.base.mutex.lock();
    } else {
        peer.base.mutex.lockKeepPreemption();
        self.base.mutex.lock();
    }
}

fn connectionUnlock(self: *Socket, peer: *Socket) void {
    if (@intFromPtr(self) < @intFromPtr(peer)) {
        peer.base.mutex.unlockKeepPreemption();
        self.base.mutex.unlock();
    } else {
        self.base.mutex.unlockKeepPreemption();
        peer.base.mutex.unlock();
    }
}

fn disconnectSocket(self: *Socket) void {
    std.debug.assert(self.base.mutex.isLocked());

    // Return immediatly if not connected.
    const peer = self.base.role.client.peer.asPtr(Socket) orelse return;
    if (!peer.base.tryRef()) {
        @branchHint(.cold);
        return;
    }
    defer peer.base.deref();

    connectionLock(self, peer);
    defer connectionUnlock(self, peer);

    // Already disconnected or connection is changed.
    if (self.base.role.client.peer != peer) {
        @branchHint(.unlikely);
        return;
    }

    self.base.role.client.peer.setPtr(null);
    peer.base.role.client.peer.setPtr(null);

    self.base.deref();
    peer.base.deref();
}
