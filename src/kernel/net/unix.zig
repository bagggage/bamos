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
            const address = fromEntry(entry);
            for (key, address.path) |l, r| if (l != r) return false;

            return true;
        }
    });

    const namespace_capacity = 2048;

    path: [*:0]const u8,
    entry: Table.Entry,

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

    const AnyAddress = extern union {
        abstract: AbstractAddress,
        dentry: *vfs.Dentry,
    };

    pub const alloc_config: vm.auto.Config = .{ .allocator = .oma };

    base: net.Socket,
    address: AnyAddress,
    address_type: AddressType = .unnamed,
    connection: ?*Socket = null,

    fn deinit(self: *Socket) void {
        switch (self.address_type) {
            .unnamed => {},
            .abstract => {
                path_lock.writeLock();
                defer path_lock.writeUnlock();
                
                path_table.removeEntry(&self.address.abstract.entry);
                vm.gpa.free(self.address.abstract.path);
            },
            .pathname => {
                const dentry = self.address.dentry;
                dentry.unlink() catch {};
                dentry.deref();
            },
        }
    }

    fn connectRequest(self: *Socket, sender: *Socket) void {
        if (self.base.listen )
    }

    inline fn fromBase(socket: *net.Socket) *Socket {
        return @fieldParentPtr("base", socket);
    }

    inline fn fromEntry(entry: *AbstractAddress.Table.Entry) *Socket {
        const any_address: *AnyAddress = @ptrCast(AbstractAddress.fromEntry(entry));
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
    .delete = &socketDelete,
};

const socket_datagram_ops: net.Socket.Operations = .{
    .delete = &socketDelete,
};

const socket_sequential_ops: net.Socket.Operations = .{
    .delete = &socketDelete,
};

var path_table: AbstractAddress.Table = .{};
var path_lock: lib.sync.RwLock = .{};

pub fn init() !void {
    path_table = try .init(AbstractAddress.namespace_capacity);

    try net.registerProtocolFamily(.unix, &protocol_family);
}

fn createSocket(@"type": net.Socket.Type) net.Error!*net.Socket {
    const ops = switch (@"type") {
        .stream => &socket_stream_ops,
        .datagram => &socket_datagram_ops,
        .sequential => &socket_sequential_ops,
        else => return error.UnsupportedSocketType,
    };

    const socket = vm.auto.alloc(Socket) orelse return error.NoMemory;
    socket.* = .{ .base = .{ .ops = ops } };

    return &socket.base;
}

fn socketBind(self: *net.Socket, address: []const u8) net.Error!void {
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

        unix.address.abstract.* = .{ .path = path };
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

        unix.address.dentry = dentry;
        unix.address_type = .pathname;
    }
}

fn socketStreamSend(self: *net.Socket, packet: *net.Packet, address: ?[]const u8) net.Error!usize {
    const unix = Socket.fromBase(self);

    self.mutex.lock();
    defer self.mutex.unlock();

    if (unix.connection == null) return error.NotConnected;
    if (address != null) return error.Connected;

    _ = packet;
    return 0;
}

fn socketStreamReceive(self: *net.Socket, buffer: []u8, address: ?[]const u8) net.Error!usize {
    const unix = Socket.fromBase(self);

    self.mutex.lock();
    defer self.mutex.unlock();

    if (unix.connection == null) return error.NotConnected;
    if (address != null) return error.Connected;

    _ = buffer;
    return 0;
}

fn socketSequentialSend(self: *net.Socket, packet: *net.Packet, address: ?[]const u8) net.Error!usize {
    const unix = Socket.fromBase(self);

    self.mutex.lock();
    defer self.mutex.unlock();

    if (unix.connection == null) return error.NotConnected;
    if (address != null) return error.Connected;

    _ = packet;
    return 0;
}

fn socketSequentialReceive(self: *net.Socket, buffer: []u8, address: ?[]const u8) net.Error!usize {
    const unix = Socket.fromBase(self);

    self.mutex.lock();
    defer self.mutex.unlock();

    if (unix.connection == null) return error.NotConnected;
    if (address != null) return error.Connected;

    return 0;
}

fn socketConnect(self: *net.Socket, address: []const u8) net.Error!void {
    if (address.len == 0 or address.len > max_path_length) return error.InvalidArgs;

    const unix = Socket.fromBase(self);

    self.mutex.lock();
    defer self.mutex.unlock();

    if (unix.connection != null) return error.Connected;

    const other = try findSocketByAddress(address);
    try other.connectRequest(self);
}

fn socketDelete(self: *net.Socket) void {
    const unix = Socket.fromBase(self);
    unix.deinit();

    vm.auto.free(Socket, unix);
}

fn findSocketByAddress(address: []const u8) net.Error!*Socket {
    if (address[0] == '\x00') {
        const entry = path_table.get(address[1..]) orelse return error.NoEnt;
        const socket = Socket.fromEntry(&entry);

        return if (socket.base.tryRef()) socket else error.NoEnt;
    }

    const task = sched.getCurrentTask();
    const root, const dir,
    const gid, const uid = if (task.spec == .user) blk: {
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
