//! # Unix protocol family

// Copyright (C) 2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const net = @import("../net.zig");
const lib = @import("../lib.zig");
const log = std.log.scoped(.@"net.unix");
const sched = @import("../sched.zig");
const vfs = @import("../vfs.zig");
const vm = @import("../vm.zig");

const AbstractAddress = struct {
    const Table = lib.HashTable([]const u8, opaque{
        pub fn hash(key: []const u8) u64 {
            return std.hash.Wyhash.hash(0, key);
        }

        pub fn eql(entry: *const Table.Entry, key: []const u8) bool {
            const address = fromEntry(@constCast(entry));
            for (key, address.path) |l, r| if (l != r) return false;

            return true;
        }
    });

    const namespace_capacity = 2048;

    path: [*:0]u8,
    entry: Table.Entry = .{},

    inline fn fromEntry(entry: *Table.Entry) *AbstractAddress {
        return @fieldParentPtr("entry", entry);
    }
};

const Socket = struct {
    const Address = std.os.linux.sockaddr.un;

    const AddressType = enum(u8) {
        unnamed = 0,
        abstract,
        pathname,
    };

    const AnyAddress = union {
        abstract: AbstractAddress,
        dentry: *vfs.Dentry,
    };

    pub const alloc_config: vm.auto.Config = .{ .allocator = .oma };

    base: net.Socket,
    address: AnyAddress = undefined,
    address_type: AddressType = .unnamed,

    fn deinit(self: *Socket) void {
        switch (self.address_type) {
            .unnamed => {},
            .abstract => {
                path_lock.writeLock();
                defer path_lock.writeUnlock();
                
                path_table.removeEntry(&self.address.abstract.entry);
                vm.gpa.free(@ptrCast(self.address.abstract.path));
            },
            .pathname => {
                const dentry = self.address.dentry;
                dentry.unlink() catch {};
                dentry.deref();
            },
        }
    }

    inline fn fromBase(socket: *net.Socket) *Socket {
        return @fieldParentPtr("base", socket);
    }

    inline fn fromEntry(entry: *AbstractAddress.Table.Entry) *Socket {
        const any_address: *AnyAddress = @fieldParentPtr("abstract", AbstractAddress.fromEntry(entry));
        return  @fieldParentPtr("address", any_address);
    }
};

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

var path_table: AbstractAddress.Table = .{};
var path_lock: lib.sync.RwLock = .{};

pub fn init() !void {
    path_table = try .init(AbstractAddress.namespace_capacity);
    errdefer path_table.deinit();

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

    if (address[0] == '\x00') {
        const buffer = vm.gpa.allocMany(u8, address.len) orelse return error.NoMemory;
        const path = buffer[0..address.len - 1];

        @memcpy(path, address[1..]);
        buffer[address.len] = 0;

        unix.address = .{ .abstract = .{ .path = @ptrCast(path.ptr) } };
        unix.address_type = .abstract;

        path_lock.writeLock();
        defer path_lock.writeUnlock();

        if (path_table.insert(path, &unix.address.abstract.entry) != null) {
            return error.AddressInUse;
        }
    } else {
        const task = sched.getCurrentTask();

        const root, const dir,
        const gid, const uid = if (task.spec == .user) blk: {
            @branchHint(.likely);
            const process = task.spec.user.process;
            break :blk .{ process.root_dir, process.work_dir, process.gid, process.uid };
        } else .{ null, null, 0, 0 };

        const create_path = try vfs.resolveCreatePath(root, dir, address);
        defer create_path.deref();

        const dentry = try create_path.parent_dir.createFileRaw(
            create_path.base_name,
            .socket,
            .{ .gid = gid, .uid = uid },
            .fromPtr(self),
        );

        unix.address = .{ .dentry = dentry };
        unix.address_type = .pathname;
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

    const unix_peer = try findSocketByAddress(unix_address);
    defer unix_peer.base.deref();

    const recv_queue = blk: {
        unix_peer.base.mutex.lock();
        defer unix_peer.base.mutex.unlock();

        if (unix_peer.base.@"type" != self.@"type") return error.UnsupportedSocketType;
        if (unix_peer.base.flags.shutdown_read) return error.ConnectionRefused;

        break :blk &unix_peer.base.role.client.recv_queue;
    };

    const size = packet.getDataSize();
    try recv_queue.push(packet);

    return size;
}

fn socketAccept(self: *net.Socket, out_address: ?[]u8) net.Error!*net.Socket {
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
        defer target.base.deref();

        if (self.@"type" != target.base.@"type") return error.ProtocolTypeMissmatch;

        const listener = inner_blk: {
            target.base.mutex.lock();
            defer target.base.mutex.unlock();

            if (!target.base.isListener()) return error.ConnectionRefused;
            break :inner_blk &target.base.role.listener;
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

    self.role.listener = try .create(*Socket, pending_limit);
    self.flags.listener = true;
}

fn socketDelete(self: *net.Socket) void {
    const unix = Socket.fromBase(self);
    unix.deinit();

    vm.auto.free(Socket, unix);
}

fn findSocketByAddress(address: []const u8) net.Error!*Socket {
    if (address[0] == '\x00') {
        const entry = path_table.get(address[1..]) orelse return error.NoEnt;
        const socket = Socket.fromEntry(entry);

        return if (socket.base.tryRef()) socket else error.NoEnt;
    }

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

    const socket = dentry.inode.fs_data.asPtr(Socket).?;
    if (!socket.base.tryRef()) return error.NoEnt;

    const role = dentry.inode.getRole(uid, gid);
    if (!dentry.inode.checkAccess(.rw, role)) return error.NoAccess;

    return socket;
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
