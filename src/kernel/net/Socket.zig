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
    pub const SendFn = *const fn (*Self, *net.Packet, ?[]const u8, net.IoFlags) Error!usize;
    pub const ReceiveFn = *const fn (*Self, []u8, ?*[]u8, net.IoFlags) Error!usize;
    pub const BindFn = *const fn (*Self, []const u8) Error!void;
    pub const ListenFn = *const fn (*Self, u32) Error!void;
    pub const AcceptFn = *const fn (*Self, ?*[]u8) Error!*Self;
    pub const ConnectFn = *const fn (*Self, []const u8) Error!void;
    pub const DeleteFn = *const fn (*Self) void;

    send: SendFn = &badSend,
    receive: ReceiveFn = &badReceive,
    bind: BindFn = &badBind,
    listen: ListenFn = &badListen,
    accept: AcceptFn = &badAccept,
    connect: ConnectFn = &badConnect,
    delete: DeleteFn,

    fn badSend(_: *Self, _: *net.Packet, _: ?[]const u8, _: net.IoFlags) Error!usize {
        return error.BadOperation;
    }

    fn badReceive(_: *Self, _: []u8, _: ?*[]u8, _: net.IoFlags) Error!usize {
        return error.BadOperation;
    }

    fn badBind(_: *Self, _: []const u8) Error!void {
        return error.BadOperation;
    }

    fn badListen(_: *Self, _: u32) Error!void {
        return error.BadOperation;
    }

    fn badAccept(_: *Self, _: ?*[]u8) Error!*Self {
        return error.BadOperation;
    }

    fn badConnect(_: *Self, _: []const u8) Error!void {
        return error.BadOperation;
    }
};

const Queue = struct {
    packets: net.Packet.List = .{},
    wait_queue: sched.WaitQueue = .{},
    total_size: u32 = 0,
    max_pages: u16 = 1,
    lock: lib.sync.Spinlock = .{},

    pub inline fn maxSize(self: *const Queue) u32 {
        return @as(u32, self.max_pages) * vm.page_size;
    }

    pub fn push(self: *Queue, packet: *net.Packet) error{MessageTooBig}!void {
        const data = packet.getData();

        self.lock.lock();
        defer self.lock.unlock();

        const new_total = data.len + self.total_size;
        if (new_total > self.maxSize()) return error.MessageTooBig;

        packet.ref();
        self.total_size = @truncate(new_total);
        self.packets.append(&packet.node);

        sched.awakeAll(&self.wait_queue);
    }

    pub fn pushWait(self: *Queue, packet: *net.Packet, timeout_ns: u64) error{Timeout,Interrupted}!void {
        const data = packet.getData();

        self.lock.lock();
        defer self.lock.unlock();

        var curr_timeout_ns = timeout_ns;
        var new_total = data.len + self.total_size;
        while (new_total > self.maxSize()) {
            log.debug("wait to send", .{});
            try doWaitUpdateTimeoutKeepLock(&self.wait_queue, &self.lock, &curr_timeout_ns);
            new_total = data.len + self.total_size;
        }

        log.debug("sending packet", .{});
        self.total_size = @truncate(new_total);
        self.packets.append(&packet.node);

        sched.awakeAll(&self.wait_queue);
    }

    pub fn pop(self: *Queue) ?*net.Packet {
        self.lock.lock();
        defer self.lock.unlock();

        const packet = net.Packet.fromNode(self.packets.popFirst() orelse return null);
        self.total_size -= packet.getDataSize();
        sched.awakeAll(&self.wait_queue);

        return packet;
    }

    pub fn popWait(self: *Queue, timeout_ns: u64) error{Timeout,Interrupted}!*net.Packet {
        self.lock.lock();
        defer self.lock.unlock();

        try self.waitNotEmpty(timeout_ns);

        const packet = net.Packet.fromNode(self.packets.popFirst().?);
        self.total_size -= packet.getDataSize();
        sched.awakeAll(&self.wait_queue);

        return packet;
    }

    pub fn readDatagramWait(
        self: *Queue, buffer: []u8,
        timeout_ns: u64, flags: net.IoFlags,
    ) error{Timeout,Interrupted}!u32 {
        const real_timeout_ns = if (flags.dont_wait) 0 else timeout_ns;
        const packet, const data = blk: {
            self.lock.lock();
            defer self.lock.unlock();

            try self.waitNotEmpty(real_timeout_ns);

            const packet = net.Packet.fromNode(self.packets.first.?);
            const data = packet.getData();

            if (flags.peek) {
                packet.ref();
            } else {
                self.total_size -= @truncate(@min(data.len, buffer.len));
                self.packets.remove(&packet.node);

                sched.awakeAll(&self.wait_queue);
            }

            break :blk .{ packet, data };
        };

        const len = @min(data.len, buffer.len);
        defer packet.deref();

        @memcpy(buffer[0..len], data[0..len]);
        return if (flags.truncate) packet.size else @truncate(len);
    }

    pub fn readStreamWait(
        self: *Queue, buffer: []u8,
        timeout_ns: u64, flags: net.IoFlags,
    ) error{Timeout,Interrupted}!u32 {
        if (buffer.len == 0) return 0;

        const real_timeout_ns = if (flags.dont_wait) 0 else timeout_ns;
        const first, const last, const last_data_offset = blk: {
            self.lock.lock();
            errdefer self.lock.unlock();

            const min_to_read = if (flags.wait_all) buffer.len else 1;
            var to_read: usize = 0;
            var curr_last: ?*net.Packet.Node = null;

            outer: while (true) {
                while (self.packets.last == curr_last) {
                    log.debug("wait on receive", .{});
                    try doWaitTimeoutKeepLock(&self.wait_queue, &self.lock, real_timeout_ns);
                }

                log.debug("packets ready", .{});
                var node = if (curr_last) |n| n.next else self.packets.first;
                while (node) |n| : (node = n.next) {
                    const packet = net.Packet.fromNode(n);
                    to_read += packet.getDataSize();
                    curr_last = n;

                    log.debug("read packet: {} bytes / min: {}", .{packet.getDataSize(), min_to_read});
                    if (flags.peek) packet.ref();
                    if (buffer.len <= to_read) break :outer;
                }

                log.debug("check: to read: {} / min: {}", .{to_read, min_to_read});
                if (to_read >= min_to_read) break :outer;
            }

            log.debug("out of receive loop", .{});
            const first = net.Packet.fromNode(self.packets.first.?);
            const last = net.Packet.fromNode(curr_last.?);

            if (flags.peek) {
                @branchHint(.unlikely);
                break :blk .{ first, last, last.data };
            }

            defer {
                sched.awakeAll(&self.wait_queue);
                self.lock.unlock();
            }

            log.debug("remove packets", .{});
            const to_remove, const last_data_offset = if (to_read > buffer.len) rm: {
                // Cut data in the last packet.
                const rest_len: u32 = @truncate(to_read - buffer.len);
                const last_data_offset = last.data;
                self.total_size -= @truncate(buffer.len);
                last.data = last.tail - rest_len;
                last.ref();

                const prev = last.node.prev orelse break :blk .{ first, last, last_data_offset };
                break :rm .{ prev, last_data_offset };
            } else rm: {
                self.total_size -= @truncate(to_read);
                break :rm .{ &last.node, last.data };
            };

            // Remove packets from queue.
            if (self.packets.last == to_remove) {
                self.packets = .{};
            } else {
                to_remove.next.?.prev = null;
                self.packets.first = to_remove.next;
            }

            break :blk .{ first, last, last_data_offset };
        };

        log.debug("copy packets data, queue size: {}", .{self.total_size});
        // Copy packets that completely fits into a buffer.
        var copied: usize = 0;
        var packet = first;
        while (packet != last) {
            const data = packet.getData();
            const current = packet;
            defer current.deref();

            @memcpy(buffer[copied..copied + data.len], data);
            copied += data.len;

            packet = net.Packet.fromNode(packet.node.next.?);
        }

        if (flags.peek) self.lock.unlock();

        // Copy the last packet.
        const last_data = last.buffer[last_data_offset..last.tail];
        defer last.deref();

        if (copied + last_data.len > buffer.len) {
            const len = buffer.len - copied;
            @memcpy(buffer[copied..], last_data[0..len]);
            copied += len;
        } else {
            @memcpy(buffer[copied..copied + last_data.len], last_data);
            copied += last_data.len;
        }

        return @truncate(copied);
    }

    inline fn waitNotEmpty(self: *Queue, timeout_ns: u64) error{Timeout,Interrupted}!void {
        while (self.packets.first == null) {
            try doWaitTimeoutKeepLock(&self.wait_queue, &self.lock, timeout_ns);
        }
    }
};

const Listener = struct {
    pending_queue: *anyopaque,
    pending_limit: u32 = 0,
    pending_size: u32 = 0,
    wait_queue: sched.WaitQueue = .{},
    lock: lib.sync.Spinlock = .{},

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
        const Union = comptime blk: {
            const sock: Self = undefined;
            break :blk @TypeOf(sock.role);
        };

        const @"union": *Union = @fieldParentPtr("listener", self);
        return @fieldParentPtr("role", @"union");
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

    pub fn waitNotEmptyLock(self: *Listener) error{Timeout,Interrupted}!void {
        self.lock.lock();
        errdefer self.lock.unlock();

        const socket = self.toSocket();
        var timeout_ns = if (socket.recv_timeout_ns == 0) std.math.maxInt(u64) else socket.recv_timeout_ns;

        while (self.pending_size == 0) {
            try doWaitUpdateTimeoutKeepLock(&self.wait_queue, &self.lock, &timeout_ns);
        }
    }

    pub fn waitClientPending(self: *Listener, client: *Self) Error!void {
        self.lock.lock();
        defer self.lock.unlock();

        if (!client.flags.connection_pending) return;
        if (client.flags.non_block) return error.InProgress;

        const send_timeout_ns = client.role.client.send_timeout_ns;
        var timeout_ns = if (send_timeout_ns == 0) std.math.maxInt(u64) else send_timeout_ns;

        while (client.flags.atomicLoad().connection_pending) {
            try doWaitUpdateTimeoutKeepLock(&self.wait_queue, &self.lock, &timeout_ns);
        }
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
};

const Client = struct {
    recv_queue: Queue = .{},
    send_queue: Queue = .{},
    send_timeout_ns: u64 = std.math.maxInt(u64),
    peer: lib.AnyData = .{},
};

const Flags = packed struct(u8) {

    listener: bool = false,
    non_block: bool = false,
    connection_pending: bool = false,
    shutdown_read: bool = false,
    shutdown_write: bool = false,
    _: u3 = 0,

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
role: union {
    listener: Listener,
    client: Client,
} = .{ .client = .{} },

recv_timeout_ns: u64 = std.math.maxInt(u64),

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
        .dentry = @constCast(&socket_dentry),
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

pub inline fn fromFile(file: *File) *Self {
    return file.data.asPtr(Self).?;
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

pub inline fn getSendTimeoutNs(self: *const Self) u64 {
    return if (self.flags.non_block) 0 else self.role.client.send_timeout_ns;
}

pub inline fn getReceiveTimeoutNs(self: *const Self) u64 {
    return if (self.flags.non_block) 0 else self.recv_timeout_ns;
}

pub inline fn send(self: *Self, packet: *net.Packet, address: ?[]const u8, flags: net.IoFlags) Error!usize {
    if (!self.isClient()) return error.BadOperation;
    return self.ops.send(self, packet, address, flags);
}

pub inline fn receive(self: *Self, buffer: []u8, address: ?*[]u8, flags: net.IoFlags) Error!usize {
    if (!self.isClient()) return error.BadOperation;
    return self.ops.receive(self, buffer, address, flags);
}

pub inline fn bind(self: *Self, address: []const u8) Error!void {
    return self.ops.bind(self, address);
}

pub inline fn listen(self: *Self, max_pending_connections: u32) Error!void {
    if (self.@"type" == .datagram or self.@"type" == .raw) return error.BadOperation;
    return self.ops.listen(self, max_pending_connections);
}

pub inline fn accept(self: *Self, out_address: ?*[]u8) Error!*Self {
    if (!self.isListener()) return error.InvalidArgs;
    return self.ops.accept(self, out_address);
}

pub fn acceptAsFileDescriptor(self: *Self, out_address: ?*[]u8) Error!*File {
    if (!self.isListener()) return error.BadOperation;

    const file = vm.auto.alloc(File) orelse return error.NoMemory;
    errdefer vm.auto.free(File, file);

    const socket = try self.accept(out_address);

    file.* = .{
        .type = .socket,
        .perm = .rw,
        .dentry = @constCast(&socket_dentry),
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

fn doWaitUpdateTimeoutKeepLock(
    wait_queue: *sched.WaitQueue,
    lock: *lib.sync.Spinlock,
    timeout_ns: *u64,
) error{Timeout,Interrupted}!void {
    const scheduler = sched.getCurrent();
    var entry = scheduler.initWait();

    wait_queue.push(&entry);
    errdefer wait_queue.removeWeak(&entry);

    lock.unlock();
    defer lock.lock();

    try scheduler.doWaitTimeout(timeout_ns.*, true);
    timeout_ns.* -|= sys.time.getUpTimeNs() -| entry.timestamp;
}

fn doWaitTimeoutKeepLock(
    wait_queue: *sched.WaitQueue,
    lock: *lib.sync.Spinlock,
    timeout_ns: u64,
) error{Timeout,Interrupted}!void {
    const scheduler = sched.getCurrent();
    var entry = scheduler.initWait();

    wait_queue.push(&entry);
    errdefer wait_queue.removeWeak(&entry);

    lock.unlock();
    defer lock.lock();

    try scheduler.doWaitTimeout(timeout_ns, true);
}
