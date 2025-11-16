//! # Block device high-level interface

// Copyright (C) 2024-2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const cache = vm.cache;
const dev = @import("../../dev.zig");
const devfs = vfs.devfs;
const lib = @import("../../lib.zig");
const log = std.log.scoped(.Drive);
const sched = @import("../../sched.zig");
const smp = @import("../../smp.zig");
const vm = @import("../../vm.zig");
const vfs = @import("../../vfs.zig");

const Self = @This();

pub const Error = devfs.Error || dev.Name.Error || error {
    IoFailed,
    NoMemory,
};

pub const io = opaque {
    pub const Operation = enum(u8) {
        read,
        write
    };

    pub const Status = enum(u8) {
        failed,
        success
    };

    pub const Request = struct {
        const Queue = std.SinglyLinkedList;
        const Node = Queue.Node;

        pub const CallbackFn = *const fn (*const Request, Status) void;

        id: u16,
        operation: Operation,

        lba_offset: usize,
        lba_num: u32,

        lma_buf: [*]u8,

        callback: CallbackFn,
        wait_queue: sched.WaitQueue = .{},

        node: Queue.Node = .{},

        comptime {
            std.debug.assert(@sizeOf(Request) == 48);
        }

        inline fn fromNode(node: *Node) *Request {
            return @fieldParentPtr("node", node);
        }
    };

    const Control = struct {
        const AnyQueue = union {
            const Single = struct {
                queue: Request.Queue = .{},
                lock: lib.sync.Spinlock = .{}
            };

            multi: [*]Request.Queue,
            single: Single,
        };

        const Handle = struct {
            request: *Request,
            arena: *vm.ObjectAllocator.Arena,
        };

        queue: AnyQueue,
        oma: vm.ObjectAllocator = .initCapacity(@sizeOf(Request), 192),

        fn init(multi_io: bool) !Control {
            const queue: AnyQueue = if (multi_io) blk: {
                const cpus_num = smp.getNum();
                const mem = vm.malloc(cpus_num * @sizeOf(io.Request.Queue)) orelse return error.NoMemory;

                break :blk .{ .multi = @alignCast(@ptrCast(mem)) };
            } else .{ .single = .{} };

            return .{ .queue = queue };
        }

        inline fn deinit(self: *Control, multi_io: bool) void {
            if (multi_io) vm.free(self.queue.multi);
            self.oma.deinit();
        }

        fn enqueue(self: *Control, multi_io: bool, request: *Request) void {
            if (multi_io) {
                const cpu_idx = smp.getIdx();
                self.queue.multi[cpu_idx].prepend(&request.node);
            } else {
                const single = &self.queue.single;

                single.lock.lock();
                defer single.lock.unlock();

                single.queue.prepend(&request.node);
            }
        }

        fn dequeue(self: *Control, multi_io: bool) ?*Request {
            if (multi_io) {
                const cpu_idx = smp.getIdx();

                const node = self.queue.multi[cpu_idx].popFirst() orelse return null;
                return Request.fromNode(node);
            }

            const single_io = &self.queue.single;

            single_io.lock.lock();
            defer single_io.lock.unlock();

            const node = single_io.queue.popFirst() orelse return null;
            return Request.fromNode(node);
        }

        fn allocRequest(self: *Control) ?*Request {
            var idx: u32 = 0;
            var addr: usize = 0;
            var arena: *vm.ObjectAllocator.Arena = blk: {
                var node = self.oma.arenas.first.load(.acquire);
                while (node) |n| : ({node = n.next; idx += 1;}) {
                    const arena = vm.ObjectAllocator.Arena.fromNode(n);
                    addr = arena.alloc(@sizeOf(Request), self.oma.arena_capacity) orelse continue;

                    break :blk arena;
                }

                const new = self.oma.newArena() orelse return null;
                addr = new.allocFirst(@sizeOf(Request));

                break :blk new;
            };

            const request: *Request = @ptrFromInt(addr);
            const inner_idx = (addr - arena.getBase()) / @sizeOf(Request);
            request.id = @truncate((idx * self.oma.arena_capacity) + inner_idx);

            return request;
        }

        fn freeRequest(self: *Control, handle: Handle) void {
            self.oma.freeRaw(handle.arena, @intFromPtr(handle.request));
        }

        fn getRequest(self: *Control, id: u16) Handle {
            // Hope that this function will complete much faster
            // then new arena would be allocated (in case if many I/O requests would be emited).
            //
            // Due to unlikelihood, we assume that this will never happen and we may not use lock.

            const arena_idx = id / self.oma.arena_capacity;
            const arena = blk: {
                var node = self.oma.arenas.first.load(.acquire) orelse unreachable;
                for (0..arena_idx) |_| {
                    node = node.next orelse unreachable;
                }
                break :blk vm.ObjectAllocator.Arena.fromNode(node);
            };

            const request: *Request = @ptrFromInt(arena.getBase() + (@sizeOf(io.Request) * id));
            std.debug.assert(request.id == id);

            return .{ .request = request, .arena = arena };
        }
    };
};

pub const VTable = struct {
    pub const HandleIoFn = *const fn(drive: *Self, io_request: *const io.Request) bool;

    handleIo: HandleIoFn,
};

pub const Flags = packed struct {
    multi_io: bool = false,
    partitionable: bool = false
};

pub const file_operations: vfs.File.Operations = .{
    .ioctl = undefined,
    .mmap = undefined,
    .read = filePartitionRead,
    .write = undefined
};

base_part: vfs.parts.Partition,

lba_size: u16,
lba_shift: u4 = undefined,

/// Drive capacity in bytes.
capacity: usize,

flags: Flags = .{},

io_ctrl: io.Control = undefined,
cache_ctrl: *cache.ControlBlock = undefined,
parts: vfs.parts.List = .{},

dev_region: *devfs.Region,

vtable: *const VTable,

fn checkIo(self: *const Self, lba_offset: usize, buffer: []const u8) void {
    std.debug.assert(self.offsetModLba(buffer.len) == 0);
    std.debug.assert(self.lbaToOffset(lba_offset) + buffer.len <= self.capacity);
}

pub fn setup(self: *Self, name: dev.Name, dev_region: *devfs.Region, multi_io: bool, partitions: bool) Error!void {
    self.cache_ctrl = try cache.makeCtrl();
    errdefer cache.deleteCtrl(self.cache_ctrl);

    self.io_ctrl = try .init(multi_io);
    errdefer self.io_ctrl.deinit(multi_io);

    self.flags.multi_io = multi_io;
    self.dev_region = dev_region;
    self.lba_shift = std.math.log2_int(u16, self.lba_size);

    {
        self.base_part = .{
            .lba_start = 0,
            .lba_end = self.offsetToLba(self.capacity)
        };

        const dev_num = self.dev_region.alloc() orelse return Error.DevMinorLimit;
        errdefer self.dev_region.free(dev_num);

        try self.base_part.registerDevice(
            name,
            dev_num,
            &file_operations,
            self
        );

        self.parts = .{};
        self.parts.append(&self.base_part.node);
        self.flags.partitionable = partitions;
    }
}

pub fn deinit(self: *Self) void {
    self.io_ctrl.deinit(self.flags.multi_io);
    cache.deleteCtrl(self.cache_ctrl);
}

pub fn onObjectAdd(self: *Self) void {
    log.info("registered: {f}; lba size: {}; capacity: {} MiB", .{
        self.getName(), self.lba_size, self.capacity / lib.mb_size
    });

    if (self.flags.partitionable) vfs.parts.probe(self) catch |err| {
        log.err("Failed to probe partitions: {s}", .{ @errorName(err) });
        self.flags.partitionable = false;
    };
}

pub inline fn getName(self: *Self) *const dev.Name {
    return &self.base_part.dev_file.name;
}

pub inline fn nextRequest(self: *Self) ?*const io.Request {
    return self.io_ctrl.dequeue(self.flags.multi_io);
}

pub fn completeIo(self: *Self, id: u16, status: io.Status) void {
    const handle = self.io_ctrl.getRequest(id);
    handle.request.callback(handle.request, status);

    self.io_ctrl.freeRequest(handle);
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
    callback: io.Request.CallbackFn
) Error!void {
    const request = try self.makeRequest(
        .read, lba_offset,
        buffer, callback
    );
    _ = self.submitRequest(request);
}

pub fn writeAsync(
    self: *Self, lba_offset: usize,
    buffer: []const u8, callback: io.Request.CallbackFn
) Error!void {
    const request = try self.makeRequest(
        .write, lba_offset,
        buffer, callback
    );
    _ = self.submitRequest(request);
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

    return vfs.Partition.fromNode(node);
}

fn syncCallback(request: *const io.Request, status: io.Status) void {
    const rq: *io.Request = @constCast(request);
    rq.lba_num = @intFromEnum(status);

    sched.awakeAll(&rq.wait_queue);
}

fn readBlock(self: *Self, idx: usize) Error!*cache.Block {
    if (self.cache_ctrl.get(idx)) |block| return block;

    const block = self.cache_ctrl.add(idx) orelse return error.NoMemory;
    const lba_idx = idx * self.offsetToLba(cache.block_size);

    const request = try self.makeRequest(
        .read, lba_idx,
        block.asSlice(), syncCallback
    );

    {   // Safe wait: put task into queue first, only then
        // submit request to device and wait.
        const scheduler = sched.getCurrent();
        var wait = scheduler.initWait();
        request.wait_queue.push(&wait);

        if (self.submitRequest(request) == false) {
            log.warn("request: {} is cached", .{idx});
        }

        scheduler.doWait();
    }

    const status: io.Status = @enumFromInt(request.lba_num);
    if (status == .failed) return error.IoFailed;

    return block;
}

inline fn makeRequest(
    self: *Self,
    comptime operation: io.Operation,
    lba_offset: usize, buffer: []u8,
    callback: io.Request.CallbackFn
) Error!*io.Request {
    self.checkIo(lba_offset, buffer);

    const rq = self.io_ctrl.allocRequest() orelse return error.NoMemory;
    rq.* = .{
        .id = rq.id, // id is set during allocation
        .operation = operation,
        .lma_buf = buffer.ptr,
        .lba_offset = lba_offset,
        .lba_num = @truncate(self.offsetToLba(buffer.len)),
        .callback = callback
    };

    return rq;
}

// TODO: implement deamon that would trigger enqueued requests submiting.
fn submitRequest(self: *Self, request: *io.Request) bool {
    if (self.vtable.handleIo(self, request) == false) {
        self.io_ctrl.enqueue(self.flags.multi_io, request);
        return false;
    }

    return true;
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
