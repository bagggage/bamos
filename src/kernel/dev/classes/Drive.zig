//! # Block device high-level interface

// Copyright (C) 2024-2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const dev = @import("../../dev.zig");
const devfs = vfs.devfs;
const lib = @import("../../lib.zig");
const log = std.log.scoped(.Drive);
const sched = @import("../../sched.zig");
const smp = @import("../../smp.zig");
const vm = @import("../../vm.zig");
const vfs = @import("../../vfs.zig");

const Self = @This();

pub const cache = @import("Drive/cache.zig");

pub const Error = devfs.Error || dev.Name.Error || error {
    BadLbaSize,
    IoFailed,
};

pub const io = opaque {
    pub const Operation = enum(u8) {
        read,
        write
    };

    pub const Status = enum(u8) {
        failed,
        success,
        none
    };

    pub const Request = struct {
        const Queue = std.SinglyLinkedList;
        const Node = Queue.Node;

        pub const Callback = struct {
            pub const Fn = *const fn (*const Request, Status, lib.AnyData) void;

            func: Fn,
            data: lib.AnyData = .{},

            inline fn call(self: *const Callback, request: *const Request, status: Status) void {
                self.func(request, status, self.data);
            }
        };

        id: u16,
        operation: Operation,

        lba_offset: usize,
        lba_num: u32,

        lma_buf: [*]u8,

        callback: Callback,
        wait_queue: sched.WaitQueue = .{},

        node: Queue.Node = .{},

        comptime {
            std.debug.assert(@sizeOf(Request) == 56);
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
        oma: vm.ObjectAllocator = .initCapacity(@sizeOf(Request), 512),

        fn init(multi_io: bool) !Control {
            const queue: AnyQueue = if (multi_io) blk: {
                const cpus_num = smp.getNum();
                const mem = vm.gpa.alloc(cpus_num * @sizeOf(io.Request.Queue)) orelse return error.NoMemory;

                break :blk .{ .multi = @alignCast(@ptrCast(mem)) };
            } else .{ .single = .{} };

            return .{ .queue = queue };
        }

        inline fn deinit(self: *Control, multi_io: bool) void {
            if (multi_io) vm.gpa.free(self.queue.multi);
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

pub const devfile_ops: devfs.DevFile.Operations = .{
    .fops = .{
        .read = filePartitionRead,
    }
};

base_part: vfs.parts.Partition,

lba_size: u16,
lba_shift: u4 = undefined,

/// Drive capacity in bytes.
capacity: usize,

flags: Flags = .{},

io_ctrl: io.Control = undefined,
cache_ctrl: vm.cache.Control = undefined,
parts: vfs.parts.List = .{},

dev_region: *devfs.Region,

vtable: *const VTable,

fn checkIo(self: *const Self, lba_offset: usize, buffer: []const u8) void {
    std.debug.assert(self.offsetModLba(buffer.len) == 0);
    std.debug.assert(self.lbaToOffset(lba_offset) + buffer.len <= self.capacity);
}

pub fn setup(self: *Self, name: dev.Name, dev_region: *devfs.Region, multi_io: bool, partitions: bool) Error!void {
    if (!std.math.isPowerOfTwo(self.lba_size) or self.lba_size > vm.page_size) return error.BadLbaSize;

    self.cache_ctrl = .{ .write_back = &cacheWriteBack };

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
            &devfile_ops,
            self
        );

        self.parts = .{};
        self.parts.append(&self.base_part.node);
        self.flags.partitionable = partitions;
    }
}

pub fn deinit(self: *Self) void {
    self.io_ctrl.deinit(self.flags.multi_io);
    // TODO: remove all the cache blocks
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
    const request = handle.request;

    request.callback.call(request, status);
    sched.awakeAll(&request.wait_queue);

    self.io_ctrl.freeRequest(handle);
}

pub inline fn openCursor(self: *Self, comptime op: io.Operation, offset: usize) Error!cache.Cursor {
    return .open(self, op, offset);
}

pub inline fn blankCursor(self: *Self) cache.Cursor {
    return .blank(self);
}

pub fn ioAsync(self: *Self, op: io.Operation, lba_offset: usize, buffer: []u8, callback: io.Request.Callback) Error!void {
    const request = try self.makeRequest(
        op, lba_offset,
        buffer, callback
    );
    _ = self.submitRequest(request);
}

pub fn ioSync(self: *Self, op: io.Operation, lba_offset: usize, buffer: []u8) Error!void {
    var status: io.Status = undefined;
    const request = try self.makeRequest(
        op, lba_offset, buffer,
        .{ .func = syncCallback, .data = .from(&status) }
    );

    self.submitRequestAndWait(request);
    if (status == .failed) return error.IoFailed;
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

fn syncCallback(_: *const io.Request, status: io.Status, data: lib.AnyData) void {
    const status_ptr = data.as(io.Status).?;
    status_ptr.* = status;
}

inline fn makeRequest(
    self: *Self, operation: io.Operation,
    lba_offset: usize, buffer: []u8, callback: io.Request.Callback
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

fn submitRequestAndWait(self: *Self, request: *io.Request) void {
    const scheduler = sched.getCurrent();
    var wait = scheduler.initWait();
    request.wait_queue.push(&wait);

    if (self.submitRequest(request) == false) {
        log.warn("request: {} is cached", .{request.id});
    }
    scheduler.doWait();
}

fn calcPartitionRegion(self: *const Self, part: *const vfs.Partition, offset: usize, len: usize) [2]usize {
    const part_start = self.lbaToOffset(part.lba_start);
    const part_end = self.lbaToOffset(part.lba_end);

    const start = part_start + offset;
    const end = start + len;

    return .{ @min(start, part_end), @min(end, part_end) };
}

fn cacheWriteBack(block: *vm.cache.Block, quants: []const vm.cache.Block.Quant, quant_shift: u5) bool {
    const self: *Self = @fieldParentPtr("cache_ctrl", block.ctrl);
    const offset = block.getOffset();
    const buffer = block.asSlice();

    var statuses: [vm.cache.Block.max_quants]io.Status = .{ io.Status.none } ** vm.cache.Block.max_quants;
    const num = blk: {
        for (quants, 0..) |q, i| {
            const lba_offset = self.offsetToLba(offset + q.base);
            self.ioAsync(
                .read, lba_offset, buffer[q.base..q.top],
                .{ .func = &syncCallback, .data = .from(&statuses[i]) }
            ) catch break :blk i;
        }
        break :blk quants.len;
    };

    var successed = true;
    for (&statuses, 0..num) |*s, i| {
        const status: *volatile io.Status = s;
        while (status.* == .none) sched.yield();
        if (status.* == .failed) { successed = false; continue; }

        const q_base_idx = quants[i].base >> quant_shift;
        const q_top_idx = quants[i].top >> quant_shift;

        for (q_base_idx..q_top_idx) |q_idx| block.dirty_map.unset(q_idx);
    }

    return num == quants.len and successed;
}

fn filePartitionRead(file: *const vfs.File, offset: usize, buffer: []u8) vfs.Error!usize {
    const dev_file = devfs.DevFile.fromDentry(file.dentry);
    const part = vfs.Partition.fromDevFile(dev_file);
    const self = dev_file.data.as(Self).?;

    const region = self.calcPartitionRegion(part, offset, buffer.len);
    if (region[0] == region[1]) return 0;

    var to_read = region[1] - region[0];
    var cursor = try self.openCursor(.read, region[0]);
    defer cursor.close(.read);

    while (to_read > 0) : (try cursor.next(.read)) {
        const data = cursor.asSlice();
        const size = @min(to_read, data.len);

        const pos = buffer.len -% to_read;
        @memcpy(buffer[pos..pos + size], data[0..size]);

        to_read -%= size;
    }

    return region[1] - region[0];
}
