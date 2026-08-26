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
    pub const ListenFn = *const fn (*Self, u32) Error!void;
    pub const AcceptFn = *const fn (*Self, ?[]u8) Error!*Self;
    pub const ConnectFn = *const fn (*Self, []const u8) Error!void;
    pub const DeleteFn = *const fn (*Self) void;

    send: SendFn = &badSend,
    receive: ReceiveFn = &badReceive,
    bind: BindFn = &badBind,
    listen: ListenFn = &badListen,
    accept: AcceptFn = &badAccept,
    connect: ConnectFn = &badConnect,
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

    fn badListen(_: *Self, _: u32) Error!void {
        return error.BadOperation;
    }

    fn badAccept(_: *Self, _: ?[]u8) Error!*Self {
        return error.BadOperation;
    }

    fn badConnect(_: *Self, _: []const u8) Error!void {
        return error.BadOperation;
    }
};

const Listener = struct {
    pending_queue: [*]anyopaque,
    pending_limit: u32 = 0,
    pending_size: u32 = 0,
    lock: lib.sync.Spinlock = .{},
    wait_queue: sched.WaitQueue = .{},

    pub fn create(comptime T: type, limit: u32) vm.Error!Listener {
        const size = @sizeOf(T) * limit;
        const ptr = vm.gpa.alloc(size) orelse return error.NoMemory;

        return .{ .pending_queue = @ptrCast(ptr), .pending_limit = limit };
    }

    pub fn deinit(self: *Listener) void {
        self.pending_limit = 0;
        self.pending_size = 0;

        vm.gpa.free(self.pending_queue);
    }

    pub inline fn toSocket(self: *Listener) *Self {
        return @fieldParentPtr("role", self);
    }

    pub inline fn getPendingAs(self: *Listener, comptime T: type) []T {
        return @as([*]T, @ptrCast(self.pending_queue))[0..self.pending_size];
    }

    pub fn pushAtomic(self: *Listener, comptime T: type, item: T) void {
        const items: [*]T = @alignCast(@ptrCast(self.pending_queue));

        items[self.pending_size] = item;
        self.pending_size += 1;
    }

    pub fn popAtomic(self: *Listener, comptime T: type) T {
        const items: [*]T = @alignCast(@ptrCast(self.pending_queue));

        self.pending_size -= 1;
        return items[self.pending_size];
    }

    pub fn removeWeakAtomic(self: *Listener, comptime T: type, item: T) bool {
        const items: [*]T = @alignCast(@ptrCast(self.pending_queue));

        for (items[0..self.pending_size], 0..) |*entry, i| {
            if (entry.* != item) continue;

            const end_i = self.pending_size - 1;
            if (i < end_i) items[i] = items[end_i];

            self.pending_size = end_i;
            return true;
        }

        return false;
    }

    pub fn waitNotEmptyLock(self: *Listener) void {
        self.lock.lock();
        errdefer self.lock.unlock();

        const socket = self.toSocket();
        var timeout_ns = if (socket.recv_timeout_ns == 0) std.math.maxInt(u64) else socket.recv_timeout_ns;

        while (self.pending_size == 0) try self.doWaitTimeout(&timeout_ns);
    }

    pub fn waitClientPending(self: *Listener, client: *Self) Error!void {
        self.lock.lock();
        defer self.lock.unlock();

        if (!client.flags.connection_pending) return;
        if (client.flags.non_block) return error.InProgress;

        const send_timeout_ns = client.role.client.send_timeout_ns;
        var timeout_ns = if (send_timeout_ns == 0) std.math.maxInt(u64) else send_timeout_ns;

        while (client.flags.atomicLoad().connection_pending) try self.doWaitTimeout(&timeout_ns);
    }

    pub fn tryAddRequestLock(self: *Listener) bool {
        self.lock.lock();

        if (self.pending_size >= self.pending_limit) {
            @branchHint(.unlikely);
            self.lock.unlock();
            return false;
        }

        return true;
    }

    pub inline fn unlock(self: *Listener) void {
        self.lock.unlock();
    }

    pub fn notifyAtomic(self: *Listener) void {
        sched.awakeAll(&self.wait_queue);
    }

    fn doWaitTimeout(self: *Listener, timeout_ns: *u64) error{Timeout,Interrupted}!void {
        const scheduler = sched.getCurrent();
        var entry = scheduler.initWait();

        self.wait_queue.push(&entry);
        errdefer self.wait_queue.removeWeak(&entry);

        self.lock.unlock();
        defer self.lock.lock();

        try scheduler.doWaitTimeout(timeout_ns.*, true);
        timeout_ns.* -|= sys.time.getUpTimeNs() -| entry.timestamp;
    }
};

const Client = struct {
    recv_queue: net.Packet.List = .{},
    send_queue: net.Packet.List = .{},
    send_timeout_ns: u64 = 0,
    peer: lib.AnyData = .{},
};

const Flags = packed struct(u8) {

    listener: bool = false,
    non_block: bool = false,
    connection_pending: bool = false,
    _: u5 = 0,

    pub inline fn atomicLoad(self: *Flags) Flags {
        return @atomicLoad(Flags, self, .acquire);
    }

    pub inline fn atomicSet(self: *Flags, mask: Flags) Flags {
        return @atomicRmw(Flags, self, .Or, mask, .release);
    }

    pub inline fn atomicClear(self: *Flags, mask: Flags) Flags {
        const int: u8 = @bitCast(mask);
        return @atomicRmw(Flags, self, .And, @bitCast(~int), .release);
    }
};

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

const socket_file_ops: File.Operations = .{};

ops: *const Operations,
role: extern union {
    listener: Listener,
    client: Client,
} = .{ .client = .{} },

recv_timeout_ns: u64 = 0,

@"type": Type,
family: net.Family,
flags: Flags = .{},

mutex: lib.sync.Mutex = .{},
ref_count: lib.atomic.RefCount(u32) = .{},

pub fn create(family: net.Family, @"type": Type) Error!*File {
    const file = vm.auto.alloc(File) orelse return error.NoMemory;
    errdefer vm.auto.free(File, file);

    const socket = try net.createSocket(family, @"type");
    socket.ref();

    file.* = .{
        .type = .socket,
        .perm = .rw,
        .dentry = &socket_dentry,
        .ops = &socket_file_ops,
        .data = .fromPtr(socket),
    };

    file.ref();
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

pub inline fn isListener(self: *Self) bool {
    return self.flags.listener;
}

pub inline fn isClient(self: *Self) bool {
    return !self.flags.listener;
}

pub inline fn isConnected(self: *Self) bool {
    return self.role.client.peer.ptr != null;
}

pub inline fn send(self: *Self, packet: *net.Packet, address: ?[]const u8, flags: net.IoFlags) Error!usize {
    if (!self.isClient()) return error.BadOperation;
    return self.ops.send(self, packet, address);
}

pub inline fn receive(self: *Self, buffer: []u8, address: ?[]const u8, flags: net.IoFlags) Error!*net.Packet {
    if (!self.isClient()) return error.BadOperation;
    return self.ops.receive(self, buffer, address);
}

pub inline fn bind(self: *Self, address: ?[]const u8) Error!void {
    return self.ops.bind(self, address);
}

pub inline fn listen(self: *Self, max_pending_connections: u32) Error!void {
    if (self.@"type" == .datagram or self.@"type" == .raw) return error.BadOperation;
    return self.ops.listen(self, max_pending_connections);
}

pub inline fn accept(self: *Self, out_address: ?[]u8) Error!*Self {
    if (!self.isListener()) return error.InvalidArgs;
    return self.ops.accept(self, out_address);
}

pub fn acceptAsFileDescriptor(self: *Self, out_address: ?[]u8) Error!*File {
    if (!self.isListener()) return error.BadOperation;

    const socket = try self.accept(out_address);
    errdefer socket.deref();

    const file = vm.auto.alloc(File) orelse return error.NoMemory;
    errdefer vm.auto.free(File, file);

    file.* = .{
        .type = .socket,
        .perm = .rw,
        .dentry = &socket_dentry,
        .ops = &socket_file_ops,
        .data = .fromPtr(socket),
    };

    file.ref();
    return file;
}

pub inline fn connect(self: *Self, address: []const u8) Error!void {
    if (self.isListener()) return error.BadOperation;
    return self.ops.connect(self, address);
}
