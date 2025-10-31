//! # Block device high-level interface

// Copyright (C) 2024 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const cache = vm.cache;
const dev = @import("../../dev.zig");
const devfs = vfs.devfs;
const log = std.log.scoped(.Drive);
const sched = @import("../../sched.zig");
const smp = @import("../../smp.zig");
const utils = @import("../../utils.zig");
const vm = @import("../../vm.zig");
const vfs = @import("../../vfs.zig");

const Self = @This();

const IoQueue = utils.SList(IoRequest);
const IoOma = vm.SafeOma(IoQueue.Node);

const io_oma_capacity = 198;

pub const Error = devfs.Error || dev.Name.Error || error {
    IoFailed,
    NoMemory,
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
    wait_queue: sched.WaitQueue = .{},

    comptime {
        std.debug.assert(@sizeOf(IoRequest) == 40);
    }
};

pub const VTable = struct {
    pub const HandleIoFn = *const fn(obj: *Self, io_request: *const IoRequest) bool;

    handleIo: HandleIoFn,
};

pub const Flags = packed struct {
    is_multi_io: bool = false,
    is_partitionable: bool = false
};

pub const file_operations: vfs.File.Operations = .{
    .ioctl = undefined,
    .mmap = undefined,
    .read = filePartitionRead,
    .write = undefined
};

const Io = union {
    const SingleIo = struct {
        queue: IoQueue = .{},
        lock: utils.Spinlock = .{}
    };

    multi: [*]IoQueue,
    single: SingleIo,
};

base_part: vfs.parts.Node,

lba_size: u16,
lba_shift: u4 = undefined,

/// Drive capacity in bytes.
capacity: usize,

flags: Flags = .{},

io: Io = undefined,
io_oma: IoOma = undefined,

cache_ctrl: *cache.ControlBlock = undefined,
parts: vfs.parts.List = .{},

dev_region: *devfs.Region,

vtable: *const VTable,

fn checkIo(self: *const Self, lba_offset: usize, buffer: []const u8) void {
    std.debug.assert(self.offsetModLba(buffer.len) == 0);
    std.debug.assert(self.lbaToOffset(lba_offset) + buffer.len <= self.capacity);
}

pub fn setup(self: *Self, name: dev.Name, dev_region: *devfs.Region, multi_io: bool, partitions: bool) Error!void {
    self.cache_ctrl = try cache.newCtrl();
    errdefer cache.deleteCtrl(self.cache_ctrl);

    self.flags.is_multi_io = multi_io;

    if (multi_io) {
        const cpus_num = smp.getNum();
        const mem = vm.malloc(cpus_num * @sizeOf(IoQueue)) orelse return error.NoMemory;

        self.io = .{ .multi = @alignCast(@ptrCast(mem)) };
    } else {
        self.io = .{ .single = .{} };
    }

    errdefer if (multi_io) vm.free(self.io.multi);

    self.dev_region = dev_region;
    self.lba_shift = std.math.log2_int(u16, self.lba_size);
    self.io_oma = IoOma.init(io_oma_capacity);

    {
        const base_part = &self.base_part.data;
        base_part.* = .{
            .lba_start = 0,
            .lba_end = self.offsetToLba(self.capacity)
        };

        const dev_num = self.dev_region.alloc() orelse return Error.DevMinorLimit;
        errdefer self.dev_region.free(dev_num);

        try base_part.registerDevice(
            name,
            dev_num,
            &file_operations,
            self
        );

        self.parts = .{};
        self.parts.append(base_part.asNode());
        self.flags.is_partitionable = partitions;
    }
}

pub fn deinit(self: *Self) void {
    if (self.flags.is_multi_io) vm.free(self.io.multi);
    self.io_oma.deinit();

    cache.deleteCtrl(self.cache_ctrl);
}

pub fn onObjectAdd(self: *Self) void {
    log.info("registered: {}; lba size: {}; capacity: {} MiB", .{
        self.getName(), self.lba_size, self.capacity / utils.mb_size
    });

    if (self.flags.is_partitionable) vfs.parts.probe(self) catch |err| {
        log.err("Failed to probe partitions: {s}", .{@errorName(err)});
        self.flags.is_partitionable = false;
    };
}

pub inline fn getName(self: *Self) *const dev.Name {
    return &self.base_part.data.dev_file.name;
}

pub fn nextRequest(self: *Self) ?*const IoRequest {
    if (self.flags.is_multi_io) {
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

pub fn readAsync(
    self: *Self, lba_offset: usize, buffer: []u8,
    callback: IoRequest.CallbackFn
) Error!void {
    const node = try self.makeRequest(
        .read, lba_offset,
        buffer, callback
    );
    _ = self.submitRequest(node);
}

pub fn writeAsync(
    self: *Self, lba_offset: usize,
    buffer: []const u8, callback: IoRequest.CallbackFn
) Error!void {
    const node = try self.makeRequest(
        .write, lba_offset,
        buffer, callback
    );
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
    const rq: *IoRequest = @constCast(request);
    rq.lba_num = @intFromEnum(status);

    sched.awakeAll(&rq.wait_queue);
}

fn readBlock(self: *Self, idx: u32) Error!*cache.Block {
    if (self.cache_ctrl.get(idx)) |block| return block;

    const block = self.cache_ctrl.new(idx) orelse return error.NoMemory;
    const lba_idx = idx * self.offsetToLba(cache.block_size);

    const rq_node = try self.makeRequest(
        .read, lba_idx,
        block.asSlice(), syncCallback
    );

    {   // Safe wait: put task into queue first, only then
        // submit request to device and wait.
        const scheduler = sched.getCurrent();
        var wait = scheduler.initWait();
        rq_node.data.wait_queue.push(&wait);

        if (self.submitRequest(rq_node) == false) {
            log.warn("request: {} is cached", .{idx});
        }

        scheduler.doWait();
    }

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
        node.data = .{
            .id = node.data.id, // id is set during allocation
            .operation = operation,
            .lma_buf = buffer.ptr,
            .lba_offset = lba_offset,
            .lba_num = @truncate(self.offsetToLba(buffer.len)),
            .callback = callback
        };
    }

    return node;
}

// TODO: implement deamon that would trigger enqueued requests submiting.
fn submitRequest(self: *Self, request: *IoQueue.Node) bool {
    if (self.vtable.handleIo(self, &request.data) == false) {
        if (self.flags.is_multi_io) {
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

    // FIXME: Use another lock!
    // Spinlocks shouldn't cover such heavy code.
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

fn calcPartitionRegion(self: *const Self, part: *const vfs.Partition, offset: usize, len: usize) [2]usize {
    const part_start = self.lbaToOffset(part.lba_start);
    const part_end = self.lbaToOffset(part.lba_end);

    const start = part_start + offset;
    const end = start + len;

    return .{
        std.mem.min(usize, &.{start, part_end}),
        std.mem.min(usize, &.{end, part_end})
    };
}

fn filePartitionRead(dentry: *const vfs.Dentry, offset: usize, buffer: []u8) vfs.Error!usize {
    const dev_file = devfs.DevFile.fromDentry(dentry);
    const part = vfs.Partition.fromDevFile(dev_file);
    const self = dev_file.data.as(Self).?;

    const region = self.calcPartitionRegion(part, offset, buffer.len);
    if (region[0] == region[1]) return 0;

    const blk_start = cache.offsetToBlock(region[0]);
    const blk_end = cache.offsetToBlock(region[1] - 1) + 1;

    var buf_offset: usize = 0;
    for (blk_start..blk_end) |idx| {
        const blk = try self.readBlock(@truncate(idx));
        defer blk.release();

        const buf_start = if (idx == blk_start) cache.offsetModBlock(region[0]) else 0;
        const buf_end = if (idx == blk_end - 1) cache.offsetModBlock(region[1] - 1) + 1 else cache.block_size;
        const buf_size = buf_end - buf_start;

        @memcpy(
            buffer[buf_offset..buf_offset + buf_size],
            blk.asSlice()[buf_start..buf_end]
        );

        buf_offset += buf_size;
    }

    return region[1] - region[0];
}
