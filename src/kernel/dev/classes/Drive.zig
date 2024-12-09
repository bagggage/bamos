//! # Block device high-level interface

// Copyright (C) 2024 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const cache = vm.cache;
const dev = @import("../../dev.zig");
const log = std.log.scoped(.Drive);
const smp = @import("../../smp.zig");
const utils = @import("../../utils.zig");
const vm = @import("../../vm.zig");
const vfs = @import("../../vfs.zig");

const Self = @This();

const IoQueue = utils.SList(IoRequest);
const IoOma = vm.SafeOma(IoQueue.Node);

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

    handleIo: HandleIoFn,
};

const Io = union {
    const SingleIo = struct {
        queue: IoQueue = .{},
        lock: utils.Spinlock = .{}
    };

    multi: [*]IoQueue,
    single: SingleIo,
};

base_name: []const u8,

lba_size: u16,
lba_shift: u4 = undefined,
capacity: usize,

is_multi_io: bool = false,
is_partitionable: bool = false,

io: Io = undefined,
io_oma: IoOma = undefined,

cache_ctrl: *cache.ControlBlock = undefined,
parts: vfs.parts.List = .{},

vtable: *const VTable,

fn checkIo(self: *const Self, lba_offset: usize, buffer: []const u8) void {
    std.debug.assert(self.offsetModLba(buffer.len) == 0);
    std.debug.assert(self.lbaToOffset(lba_offset) + buffer.len <= self.capacity);
}

pub fn init(self: *Self, name: []const u8, multi_io: bool, partitions: bool) Error!void {
    const root_part = try vfs.parts.new();
    errdefer vfs.parts.delete(root_part);

    self.cache_ctrl = try cache.newCtrl();
    errdefer cache.deleteCtrl(self.cache_ctrl);

    self.is_multi_io = multi_io;

    if (multi_io) {
        const cpus_num = smp.getNum();
        const mem = vm.malloc(cpus_num * @sizeOf(IoQueue)) orelse return error.NoMemory;

        self.io = .{ .multi = @alignCast(@ptrCast(mem)) };
    } else {
        self.io = .{ .single = .{} };
    }

    self.base_name = name;
    self.lba_shift = std.math.log2_int(u16, self.lba_size);
    self.io_oma = IoOma.init(io_oma_capacity);

    log.info("init: {s}; lba size: {}; capacity: {} MiB", .{
        self.base_name, self.lba_size, self.capacity / utils.mb_size
    });

    {
        root_part.data.lba_start = 0;
        root_part.data.lba_end = self.offsetToLba(self.capacity);

        self.parts = .{};
        self.parts.append(root_part);
        self.is_partitionable = partitions;

        if (self.is_partitionable) vfs.parts.probe(self) catch |err| {
            log.err("Failed to probe partitions: {s}", .{@errorName(err)});
            self.is_partitionable = false;
        };
    }
}

pub fn deinit(self: *Self) void {
    if (self.is_multi_io) vm.free(self.io.multi);
    self.io_oma.deinit();

    cache.deleteCtrl(self.cache_ctrl);
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

pub inline fn putCache(self: *Self, cursor: *cache.Cursor) void {
    if (cursor.blk) |blk| {
        self.cache_ctrl.put(blk);
        cursor.blk = null;
    }
}

pub inline fn getCache(self: *const Self, offset: usize) ?cache.Cursor {
    const blk = self.cache_ctrl.get(cache.offsetToBlock(offset)) orelse return null;
    return cache.Cursor.from(blk, offset);
}

pub fn readCachedNext(self: *Self, cursor: *cache.Cursor, offset: usize) Error!void {
    @setRuntimeSafety(false);

    cursor.offset = offset;
    const blk_idx = cache.offsetToBlock(offset);

    if (cursor.isValid()) {
        if (cursor.blk.?.lba_key == blk_idx) return;

        self.cache_ctrl.put(cursor.blk.?);
    }

    cursor.blk = try self.readBlock(blk_idx);
}

pub inline fn readCached(self: *Self, offset: usize) Error!cache.Cursor {
    const blk_idx = cache.offsetToBlock(offset);
    return cache.Cursor.from(try self.readBlock(blk_idx), offset);
}

pub fn readAsync(self: *Self, lba_offset: usize, buffer: []u8, callback: IoRequest.CallbackFn) Error!void {
    const node = try self.makeRequest(.read, lba_offset, buffer, callback);
    _ = self.submitRequest(node);
}

pub fn writeAsync(self: *Self, lba_offset: usize, buffer: []const u8, callback: IoRequest.CallbackFn) Error!void {
    const node = try self.makeRequest(.write, lba_offset, buffer, callback);
    _ = self.submitRequest(node);
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

pub fn getPartition(self: *const Self, part: u32) ?*vfs.Partition {
    @setRuntimeSafety(false);

    if (part >= self.parts.len) return null;

    var node = self.parts.first;

    for (0..part) |_| {
        node = node.?.next;
    }

    return &node.?.data;
}

fn syncCallback(request: *const IoRequest, status: IoRequest.Status) void {
    const rq = @constCast(request);

    rq.lba_num = @intFromEnum(status);
    rq.id = ~request.id;
}

fn readBlock(self: *Self, idx: u32) Error!*cache.Block {
    if (self.cache_ctrl.get(idx)) |block| return block;

    const block = self.cache_ctrl.new(idx) orelse return error.NoMemory;
    const lba_idx = idx * self.offsetToLba(cache.block_size);

    const rq_node = try self.makeRequest(.read, lba_idx, block.asSlice(), syncCallback);
    const wait_id = ~rq_node.data.id;
    const id_ptr: *volatile u16 = &rq_node.data.id;

    _ = self.submitRequest(rq_node);

    // Wait; FIXME: make this async!
    while (id_ptr.* != wait_id) {}

    const status: IoRequest.Status = @enumFromInt(rq_node.data.lba_num);
    if (status == .failed) return error.IoFailed;

    return block;
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
        node.data.lba_num = @truncate(self.offsetToLba(buffer.len));
        node.data.callback = callback;
    }

    return node;
}

fn submitRequest(self: *Self, request: *IoQueue.Node) bool {
    if (self.vtable.handleIo(self, &request.data) == false) {
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