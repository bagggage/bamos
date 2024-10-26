//! # Block device high-level interface

const std = @import("std");

const log = @import("../../log.zig");
const smp = @import("../../smp.zig");
const utils = @import("../../utils.zig");
const vm = @import("../../vm.zig");

const Self = @This();

const IoQueue = utils.SList(IoRequest);
const Oma = vm.SafeOma(IoQueue.Node);

const io_oma_capacity = 198;

pub const Error = error {
    IoFailed,
    NoMemory
};

pub const IoRequest = struct {
    pub const Operation = enum(u8) {
        read,
        write
    };
    pub const Status = enum(u8) {
        failed,
        success
    };

    pub const CallbackFn = *const fn (*const IoRequest, Status) void;

    id: u16,
    operation: Operation,

    lba_offset: usize,
    lba_num: u32,

    lma_buf: [*]u8,

    callback: CallbackFn,

    comptime {
        std.debug.assert(@sizeOf(IoRequest) == 32);
    }
};

pub const VTable = struct {
    pub const HandleIoFn = *const fn(obj: *Self, io_request: *const IoRequest) bool;

    handle_io: HandleIoFn,
};

const Io = union {
    const SingleIo = struct {
        queue: IoQueue = .{},
        lock: utils.Spinlock = .{}
    };

    multi: [*]IoQueue,
    single: SingleIo,
};

lba_size: u16,
capacity: usize,

io_id: u16 = 0,
is_multi_io: bool = false,

io: Io = undefined,
io_oma: Oma = undefined,

vtable: *const VTable,

fn checkIo(self: *const Self, lba_offset: usize, buffer: []const u8) void {
    std.debug.assert((buffer.len % self.lba_size) == 0);
    std.debug.assert((lba_offset * self.lba_size) + buffer.len <= self.capacity);
}

pub fn initIo(self: *Self, multi_io: bool) Error!void {
    self.is_multi_io = multi_io;

    if (multi_io) {
        const cpus_num = smp.getNum();
        const mem = vm.kmalloc(cpus_num * @sizeOf(IoQueue)) orelse return error.NoMemory;

        self.io = .{ .multi = @alignCast(@ptrCast(mem)) };
    } else {
        self.io = .{ .single = .{} };
    }

    self.io_oma = Oma.init(io_oma_capacity);
    self.io_id = 0;
}

pub fn deinit(self: *Self) void {
    if (self.is_multi_io) vm.kfree(self.io.multi);
    self.io_oma.deinit();
}

pub fn nextRequest(self: *Self) ?*const IoRequest {
    if (self.is_multi_io) {
        const cpu_idx = smp.getIdx();

        const node = self.io.multi[cpu_idx].popFirst() orelse return null;
        return &node.data;
    }

    const single_io = &self.io.single;

    single_io.lock.lock();
    defer single_io.lock.unlock();

    const node = single_io.queue.popFirst() orelse return null;
    return &node.data;
}

pub fn completeIo(self: *Self, id: u16, status: IoRequest.Status) void {
    // Hope that this function will complete much faster
    // then new arena would be allocated (in case if many I/O requests would be emited).
    //
    // Due to unlikelihood, we assume that this will never happen and we may not use lock.

    const arena_idx = id / self.io_oma.oma.arena_capacity;
    var node = self.io_oma.oma.arenas.first orelse unreachable;

    for (0..arena_idx) |_| {
        node = node.next orelse unreachable;
    }

    const request: *IoQueue.Node = @ptrFromInt(node.data.getBase() + (@sizeOf(IoQueue.Node) * id));
    const callback = request.data.callback;

    std.debug.assert(request.data.id == id);
    callback(&request.data, status);

    { // Free request node
        self.io_oma.lock.lock();
        defer self.io_oma.lock.unlock();

        self.io_oma.oma.freeRaw(node, @intFromPtr(request));
    }
}

pub fn readAsync(self: *Self, lba_offset: usize, buffer: []u8, callback: IoRequest.CallbackFn) Error!void {
    const node = try self.makeRequest(.read, lba_offset, buffer, callback);
    _ = self.submitRequest(node);
}

pub fn writeAsync(self: *Self, lba_offset: usize, buffer: []const u8, callback: IoRequest.CallbackFn) Error!void {
    const node = try self.makeRequest(.write, lba_offset, buffer, callback);
    _ = self.submitRequest(node);
}

pub fn readSync(self: *Self, lba_offset: usize, buffer: []u8) Error!void {
    const node = try self.makeRequest(.read, lba_offset, buffer, syncCallback);
    const wait_id = ~node.data.id;
    const id_ptr: *volatile u16 = &node.data.id;

    _ = self.submitRequest(node);

    // Wait
    while (id_ptr.* != wait_id) {}

    const status: IoRequest.Status = @enumFromInt(node.data.lba_num);
    if (status == .failed) return error.IoFailed;
}

pub fn writeSync(self: *Self, lba_offset: usize, buffer: []const u8) Error!void {
    const node = try self.makeRequest(.write, lba_offset, buffer, syncCallback);
    const wait_id = ~node.data.id;
    const id_ptr: *volatile u16 = &node.data.id;

    _ = self.submitRequest(node);

    // Wait
    while (id_ptr.* != wait_id) {}

    const status: IoRequest.Status = @enumFromInt(node.data.lba_num);
    if (status == .failed) return error.IoFailed;
}

fn syncCallback(request: *const IoRequest, status: IoRequest.Status) void {
    const rq = @constCast(request);

    rq.lba_num = @intFromEnum(status);
    rq.id = ~request.id;
}

inline fn makeRequest(
    self: *Self,
    comptime operation: IoRequest.Operation,
    lba_offset: usize, buffer: []u8,
    callback: IoRequest.CallbackFn
) Error!*IoQueue.Node {
    self.checkIo(lba_offset, buffer);

    const node = self.allocRequest() orelse return error.NoMemory;
    { // Init
        node.data.operation = operation;
        node.data.lma_buf = buffer.ptr;
        node.data.lba_offset = lba_offset;
        node.data.lba_num = @truncate(buffer.len / self.lba_size);
        node.data.callback = callback;
    }

    return node;
}

fn submitRequest(self: *Self, request: *IoQueue.Node) bool {
    if (self.vtable.handle_io(self, &request.data) == false) {
        if (self.is_multi_io) {
            const cpu_idx = smp.getIdx();
            self.io.multi[cpu_idx].prepend(request);
        } else {
            self.io.single.lock.lock();
            defer self.io.single.lock.unlock();

            self.io.single.queue.prepend(request);
        }

        return false;
    }

    return true;
}

fn allocRequest(self: *Self) ?*IoQueue.Node {
    const oma = &self.io_oma.oma;

    self.io_oma.lock.lock();
    defer self.io_oma.lock.unlock();

    var idx: u32 = 0;
    var node = oma.arenas.first;

    while (node) |arena| : ({node = arena.next; idx += 1;}) {
        if (arena.data.alloc_num < oma.arena_capacity) break;
    }

    if (node == null) node = oma.newArena();

    if (node) |arena| {
        const addr = arena.data.alloc(@sizeOf(IoQueue.Node));
        const request: *IoQueue.Node = @ptrFromInt(addr);

        const inner_idx = (addr - arena.data.getBase()) / @sizeOf(IoQueue.Node);
        request.data.id = @truncate((idx * oma.arena_capacity) + inner_idx);

        return request;
    }

    return null;
}