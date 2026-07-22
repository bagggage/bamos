//! # Block device high-level interface

// Copyright (C) 2024-2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const dev = @import("../../dev.zig");
const devfs = vfs.devfs;
const lib = @import("../../lib.zig");
const log = std.log.scoped(.Drive);
const sched = @import("../../sched.zig");
const smp = @import("../../smp.zig");
const sys = @import("../../sys.zig");
const vm = @import("../../vm.zig");
const vfs = @import("../../vfs.zig");

const Self = @This();

pub const cache = @import("Drive/cache.zig");

pub const Error = devfs.Error || dev.Name.Error || error{
    BadLbaSize,
    IoFailed,
};

pub const io = opaque {
    pub const Operation = enum(u8) { read, write };

    pub const Status = enum(u8) { failed, success, none };

    pub const Queue = struct {
        const List = std.SinglyLinkedList;
        const Node = List.Node;

        const default_capacity = 256;

        list: List = .{},
        requests: [*]Request,
        wait_queue: sched.WaitQueue = .{},

        len: u32 = 0,
        lock: lib.sync.Spinlock = .{},

        fn create(capacity: u16) Error!Queue {
            // Size of Request + 1 bit for bitmap.
            const bits_per_entry = @bitSizeOf(Request) + 1;
            const bit_size = @as(u32, capacity) * bits_per_entry;

            const rank = vm.bytesToRank(bit_size / lib.byte_size);
            const pages = vm.rankToPages(rank);
            const len = @min((pages * vm.page_size * lib.byte_size) / bits_per_entry, Request.max_id);

            const phys = vm.PageAllocator.alloc(rank) orelse return error.NoMemory;

            const bitmap: [*]u8 = @ptrFromInt(vm.getVirtLma(phys) + (len * @sizeOf(Request)));
            const map_size = (len + lib.byte_size - 1) / lib.byte_size;
            @memset(bitmap[0..map_size], 0);

            return .{
                .requests = @ptrFromInt(vm.getVirtLma(phys)),
                .len = len,
            };
        }

        fn deinit(self: *Queue) void {
            if (self.len == 0) return;

            // This is not the real size, but close enough to get correct rank.
            const size = (self.len * @sizeOf(Request)) + (self.len / lib.byte_size);
            const rank = vm.bytesToRank(size);
            self.len = 0;

            const phys = vm.getPhysLma(self.requests);
            vm.PageAllocator.free(phys, rank);
        }

        inline fn getBitmap(self: *Queue) lib.BitmapUnbounded {
            const addr = @intFromPtr(self.requests) + (self.len * @sizeOf(Request));
            return .{ .bytes = @ptrFromInt(addr) };
        }

        inline fn preinitRequest(rq: *Request, idx: usize) *Request {
            rq.id = @truncate(idx);
            return rq;
        }

        fn allocAtomic(self: *Queue) *Request {
            while (true) {
                const bitmap = self.getBitmap();
                if (bitmap.find(self.len, false)) |idx| {
                    @branchHint(.likely); bitmap.set(idx);
                    return preinitRequest(&self.requests[idx], idx);
                }

                self.lock.lockIntr();
                sched.waitUnlockIntr(&self.wait_queue, &self.lock);
            }
        }

        fn alloc(self: *Queue) *Request {
            while (true) {
                self.lock.lockIntr();

                const bitmap = self.getBitmap();
                if (bitmap.find(self.len, false)) |idx| {
                    @branchHint(.likely);
                    bitmap.set(idx);
                    self.lock.unlockIntr();

                    return preinitRequest(&self.requests[idx], idx);
                }

                sched.waitUnlockIntr(&self.wait_queue, &self.lock);
            }
        }

        fn free(self: *Queue, rq: *Request) void {
            self.lock.lock();
            defer self.lock.unlock();

            self.getBitmap().clear(rq.id);
            _ = sched.awake(&self.wait_queue);
        }
    };

    pub const Request = struct {
        pub const Callback = struct {
            pub const Fn = *const fn (*const Request, Status, lib.AnyData) void;

            func: Fn,
            data: lib.AnyData = .{},

            inline fn call(self: *const Callback, request: *const Request, status: Status) void {
                self.func(request, status, self.data);
            }
        };

        pub const max_id = std.math.maxInt(u16);

        id: u16,
        cpu: u8,
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

        inline fn fromNode(node: *Queue.Node) *Request {
            return @fieldParentPtr("node", node);
        }
    };

    const Control = struct {
        const AnyQueue = union {
            multi: [*]Queue,
            single: Queue,
        };

        const Handle = struct {
            request: *Request,
            arena: *vm.ObjectAllocator.Arena,
        };

        queue: AnyQueue,

        fn init(multi_io: bool) Error!Control {
            const capacity = Queue.default_capacity;
            const queue: AnyQueue = if (multi_io) blk: {
                const cpus_num = smp.getNum();
                const queues = vm.gpa.allocMany(Queue, cpus_num) orelse return error.NoMemory;

                var i: usize = 0;
                errdefer for (0..i) |idx| queues[idx].deinit();

                for (queues) |*q| {
                    q.* = try .create(capacity);
                    i += 1;
                }

                break :blk .{ .multi = queues.ptr };
            } else .{
                .single = try .create(capacity)
            };

            return .{ .queue = queue };
        }

        fn deinit(self: *Control, multi_io: bool) void {
            if (multi_io) {
                for (self.queue.multi[0..smp.getNum()]) |*q| q.deinit();
                vm.gpa.free(self.queue.multi);
            } else {
                self.queue.single.deinit();
            }
        }

        fn enqueue(self: *Control, multi_io: bool, request: *Request) void {
            if (multi_io) {
                const cpu_idx = smp.getIdx();
                std.debug.assert(request.cpu == cpu_idx);
                self.queue.multi[cpu_idx].list.prepend(&request.node);
            } else {
                const single = &self.queue.single;

                single.lock.lock();
                defer single.lock.unlock();

                single.list.prepend(&request.node);
            }
        }

        fn dequeue(self: *Control, multi_io: bool) ?*Request {
            if (multi_io) {
                const cpu_idx = smp.getIdx();
                const node = self.queue.multi[cpu_idx].list.popFirst() orelse return null;
                return Request.fromNode(node);
            }

            const single_io = &self.queue.single;

            single_io.lock.lock();
            defer single_io.lock.unlock();

            const node = single_io.list.popFirst() orelse return null;
            return Request.fromNode(node);
        }

        fn allocRequest(self: *Control) *Request {
            const drive: *Self = @fieldParentPtr("io_ctrl", self);
            if (drive.flags.multi_io) {
                const cpu_idx = smp.getIdx();
                const rq = self.queue.multi[cpu_idx].allocAtomic();
                rq.cpu = @truncate(cpu_idx);

                return rq;
            } else {
                return self.queue.single.alloc();
            }
        }

        fn freeRequest(self: *Control, request: *Request) void {
            const drive: *Self = @fieldParentPtr("io_ctrl", self);
            if (drive.flags.multi_io) {
                const cpu_idx = smp.getIdx();
                std.debug.assert(cpu_idx == request.cpu);
                self.queue.multi[cpu_idx].free(request);
            } else {
                self.queue.single.free(request);
            }
        }

        pub fn getRequest(self: *Control, id: u16) *Request {
            const drive: *Self = @fieldParentPtr("io_ctrl", self);
            if (drive.flags.multi_io) {
                const cpu_idx = smp.getIdx();
                const rq = &self.queue.multi[cpu_idx].requests[id];

                std.debug.assert(cpu_idx == rq.cpu);
                return rq;
            } else {
                return &self.queue.single.requests[id];
            }
        }
    };
};

pub const VTable = struct {
    pub const HandleIoFn = *const fn (drive: *Self, io_request: *const io.Request) bool;

    handleIo: HandleIoFn,
};

pub const Flags = packed struct {
    multi_io: bool = false,
    partitionable: bool = false,
};

pub const devfile_ops: devfs.DevFile.Operations = .{ .fops = .{
    .read = filePartitionRead,
} };

base_part: vfs.parts.Partition,

lba_size: u16,
lba_shift: u4 = undefined,

/// Drive capacity in bytes.
capacity: usize,

flags: Flags = .{},

io_ctrl: io.Control = undefined,
cache_ctrl: vm.cache.Control = undefined,
cache_worker: *sched.Task = undefined,

parts: vfs.parts.List = .{},
dev_region: *devfs.Region,

vtable: *const VTable,

fn checkIo(self: *const Self, lba_offset: usize, buffer: []const u8) void {
    std.debug.assert(self.offsetModLba(buffer.len) == 0);
    std.debug.assert(self.lbaToOffset(lba_offset) + buffer.len <= self.capacity);
}

pub fn setup(self: *Self, name: dev.Name, dev_region: *devfs.Region, multi_io: bool, partitions: bool) Error!void {
    if (!std.math.isPowerOfTwo(self.lba_size) or self.lba_size > vm.page_size) return error.BadLbaSize;

    self.cache_worker = sched.Task.createWorker("cache_worker", &cacheWorker, .fromPtr(self)) catch return error.NoMemory;
    errdefer self.cache_worker.delete();

    self.cache_ctrl = .{ .write_back = &cacheWriteBack };

    self.io_ctrl = try .init(multi_io);
    errdefer self.io_ctrl.deinit(multi_io);

    self.flags.multi_io = multi_io;
    self.dev_region = dev_region;
    self.lba_shift = std.math.log2_int(u16, self.lba_size);

    {
        self.base_part = .{ .lba_start = 0, .lba_end = self.offsetToLba(self.capacity), .data = .fromPtr(self) };

        const dev_num = self.dev_region.alloc() orelse return Error.DevMinorLimit;
        errdefer self.dev_region.free(dev_num);

        try self.base_part.registerDevice(name, dev_num, &devfile_ops);

        self.parts = .{};
        self.parts.append(&self.base_part.node);
        self.flags.partitionable = partitions;
    }
}

pub fn deinit(self: *Self) void {
    self.io_ctrl.deinit(self.flags.multi_io);
    self.cache_worker.delete();
    self.cache_ctrl.deinit();

    // TODO: Complete
}

pub fn onObjectAdd(self: *Self) void {
    log.info("registered: {f}; lba size: {}; capacity: {} MiB", .{
        self.getName(),
        self.lba_size,
        self.capacity / lib.mb_size,
    });

    if (self.flags.partitionable) vfs.parts.probe(self) catch |err| {
        log.err("Failed to probe partitions: {s}", .{@errorName(err)});
        self.flags.partitionable = false;
    };

    sched.enqueue(self.cache_worker);
}

pub inline fn getName(self: *Self) *const dev.Name {
    return &self.base_part.dev_file.name;
}

pub inline fn nextRequest(self: *Self) ?*const io.Request {
    return self.io_ctrl.dequeue(self.flags.multi_io);
}

pub fn completeIo(self: *Self, id: u16, status: io.Status) void {
    const request = self.io_ctrl.getRequest(id);

    request.callback.call(request, status);
    sched.awakeAll(&request.wait_queue);

    self.io_ctrl.freeRequest(request);
}

pub inline fn openCursor(self: *Self, comptime op: io.Operation, offset: usize) Error!cache.Cursor {
    return .open(self, op, offset);
}

pub inline fn blankCursor(self: *Self) cache.Cursor {
    return .blank(self);
}

pub fn ioAsync(self: *Self, op: io.Operation, lba_offset: usize, buffer: []u8, callback: io.Request.Callback) void {
    const request = self.makeRequest(op, lba_offset, buffer, callback);
    _ = self.submitRequest(request);
}

pub fn ioSync(self: *Self, op: io.Operation, lba_offset: usize, buffer: []u8) Error!void {
    var status: io.Status = undefined;
    const request = self.makeRequest(op, lba_offset, buffer, .{
        .func = syncCallback,
        .data = .fromPtr(&status),
    });

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
    const dest = data.asPtr(io.Status).?;
    @atomicStore(io.Status, dest, status, .release);
}

inline fn makeRequest(
    self: *Self,
    operation: io.Operation,
    lba_offset: usize,
    buffer: []u8,
    callback: io.Request.Callback,
) *io.Request {
    self.checkIo(lba_offset, buffer);

    const rq = self.io_ctrl.allocRequest();
    rq.* = .{
        .id = rq.id, // `id` and `cpu` are set during allocation
        .cpu = rq.cpu,
        .operation = operation,
        .lma_buf = buffer.ptr,
        .lba_offset = lba_offset,
        .lba_num = @truncate(self.offsetToLba(buffer.len)),
        .callback = callback,
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
    scheduler.wait();
}

fn calcPartitionRegion(self: *const Self, part: *const vfs.Partition, offset: usize, len: usize) [2]usize {
    const part_start = self.lbaToOffset(part.lba_start);
    const part_end = self.lbaToOffset(part.lba_end);

    const start = part_start + offset;
    const end = start + len;

    return .{ @min(start, part_end), @min(end, part_end) };
}

fn cacheWorker(arg: usize) noreturn {
    const delay_sec = 5;
    const drive: *Self = @ptrFromInt(arg);

    while (true) {
        if (!drive.cache_ctrl.writeBackAll()) {
            log.warn("{s}: cache write back failed", .{drive.getName().str()});
        }

        sched.sleepFor(delay_sec * std.time.ns_per_s);   
    }
}

fn cacheWriteBack(block: *vm.cache.Block, quants: []const vm.cache.Block.Quant, quant_shift: u5) bool {
    const self: *Self = @fieldParentPtr("cache_ctrl", block.ctrl);
    const offset = block.getOffset();
    const buffer = block.asSlice();

    var statuses: [vm.cache.Block.max_quants]io.Status = .{io.Status.none} ** vm.cache.Block.max_quants;
    for (quants, 0..) |q, i| {
        const lba_offset = self.offsetToLba(offset + q.base);
        self.ioAsync(.write, lba_offset, buffer[q.base..q.top], .{
            .func = &syncCallback,
            .data = .fromPtr(&statuses[i]),
        });

        log.debug("{s}: drop internal cache: lba 0x{x}", .{self.getName().str(), lba_offset});
    }

    var successed = true;
    for (0..quants.len) |i| {
        const timeout = std.time.ns_per_s;
        const time: usize = sys.time.getUpTimeNs();

        const status = &statuses[i];
        while (@atomicLoad(io.Status, status, .acquire) == .none) {
            if (sys.time.getUpTimeNs() -| time >= timeout) {
                @branchHint(.cold);
                const lba_offset = self.offsetToLba(offset + quants[i].base);
                log.warn("{s}: write back timeout: lba 0x{x}", .{self.getName().str(), lba_offset});

                status.* = .failed;
                break;
            }

            sched.yield();
        }

        if (status.* == .failed) {
            successed = false;
            continue;
        }

        const q_base_idx = quants[i].base >> quant_shift;
        const q_top_idx = quants[i].top >> quant_shift;

        for (q_base_idx..q_top_idx) |q_idx| block.dirty_map.unset(q_idx);
    }

    return successed;
}

fn filePartitionRead(file: *const vfs.File, offset: usize, buffer: []u8) vfs.Error!usize {
    const dev_file = devfs.DevFile.fromDentry(file.dentry);
    const part = vfs.Partition.fromDevFile(dev_file);
    const self = part.data.asPtr(Self).?;

    const region = self.calcPartitionRegion(part, offset, buffer.len);
    if (region[0] == region[1]) return 0;

    var to_read = region[1] - region[0];
    var cursor = try self.openCursor(.read, region[0]);
    defer cursor.close(.read);

    while (to_read > 0) : (try cursor.next(.read)) {
        const data = cursor.asSlice();
        const size = @min(to_read, data.len);

        const pos = buffer.len -% to_read;
        @memcpy(buffer[pos .. pos + size], data[0..size]);

        to_read -%= size;
    }

    return region[1] - region[0];
}
