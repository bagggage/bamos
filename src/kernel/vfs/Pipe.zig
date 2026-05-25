//! # Pipe

// Copyright (C) 2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const Self = @This();

const Dentry = vfs.Dentry;
const Error = vfs.Error;
const File = vfs.File;
const Inode = vfs.Inode;
const log = std.log.scoped(.@"vfs.pipe");
const lib = @import("../lib.zig");
const sched = @import("../sched.zig");
const sys = @import("../sys.zig");
const vfs = @import("../vfs.zig");
const vm = @import("../vm.zig");

const RingBuffer = lib.RingBuffer(u8);

pub const alloc_config: vm.auto.Config = .{ .allocator = .oma };

const file_ops: File.Operations = .{
    .read = &fileRead,
    .write = &fileWrite,
    .ioctl = &fileIoctl,
    .poll = &filePoll,
};

const pipe_fs_ctx: vfs.Context.Virt = .{};

const pipe_inode: Inode = .{
    .index = 0,
    .type = .unknown,
    .cache_ctrl = .{ .write_back = null },
};

const pipe_dentry: Dentry = .{
    .name = Dentry.Name.init("@pipe") catch unreachable,
    .inode = @constCast(&pipe_inode),
    .ctx = .{ .virt = @constCast(&pipe_fs_ctx) },
    .parent = @constCast(&pipe_dentry),
};

buffer: RingBuffer = .{},
ref_counter: lib.atomic.RefCount(u16) = .{},
readers: std.atomic.Value(u16) = .init(0), 
writers: std.atomic.Value(u16) = .init(0), 

mutex: lib.sync.Mutex = .{},

wait_lock: lib.sync.Spinlock = .{},
read_wait: sched.WaitQueue = .{},
write_wait: sched.WaitQueue = .{},

/// Creates new pipe and two `vfs.File` ends:
/// `[0]` - read(in), `[1]` - write(out).
pub fn create(size: u16) vm.Error![2]*File {
    const pipe = vm.auto.alloc(Self) orelse return error.NoMemory;
    errdefer pipe.delete();

    pipe.* = .{
        .ref_counter = .init(2),
        .readers = .init(1),
        .writers = .init(1),
    };
    pipe.buffer = try .create(size);

    const in = vm.auto.alloc(File) orelse return error.NoMemory;
    errdefer vm.auto.free(File, in);
    const out = vm.auto.alloc(File) orelse return error.NoMemory;
    errdefer vm.auto.free(File, out);

    in.* = .{
        .type = .pipe,
        .dentry = @constCast(&pipe_dentry),
        .ops = &file_ops,
        .perm = .r,
        .data = .fromPtr(pipe),
        .ref_count = .init(1)
    };
    out.* = .{
        .type = .pipe,
        .dentry = @constCast(&pipe_dentry),
        .ops = &file_ops,
        .perm = .w,
        .data = .fromPtr(pipe),
        .ref_count = .init(1)
    };

    return .{ in, out };
}

pub fn delete(self: *Self) void {
    self.buffer.delete();
    vm.auto.free(Self, self);
}

pub inline fn ref(self: *Self, comptime kind: enum{ reader, writer }) void {
    switch (comptime kind) {
        .reader => _ = self.readers.fetchAdd(1, .release),
        .writer => _ = self.writers.fetchAdd(1, .release),
    }

    self.ref_counter.inc();
}

pub fn deref(self: *Self, comptime kind: enum{ reader, writer }) void {
    switch (comptime kind) {
        .reader => if (self.readers.fetchSub(1, .release) == 1) {
            self.wait_lock.lock();
            defer self.wait_lock.unlock();
            sched.awakeAll(&self.write_wait);
        },
        .writer => if (self.writers.fetchSub(1, .release) == 1) {
            self.wait_lock.lock();
            defer self.wait_lock.unlock();
            sched.awakeAll(&self.read_wait);
        }
    }

    if (self.ref_counter.put()) self.delete();
}

fn fileRead(file: *const File, _: usize, buffer: []u8) Error!usize {
    const pipe = file.data.asPtr(Self).?;

    var readed: usize = 0;
    while (readed < buffer.len) {
        pipe.mutex.lock();

        const remain_len = buffer.len -% readed;
        const len = @min(remain_len, pipe.buffer.itemsToRead());
        if (len == 0) {
            pipe.tryWaitUnlock(pipe.writers.raw, &pipe.read_wait, &pipe.write_wait)
                catch if (readed > 0) { return readed; } else return error.BadPipe;
            continue;
        }

        const pos: u32 = pipe.buffer.read_pos;
        const end_pos = pos +% len;
        if (end_pos > pipe.buffer.len) {
            const to_read = pipe.buffer.len -% pos;
            const to_read_next = len -% to_read;
            const end = readed +% to_read;

            @memcpy(buffer[readed .. end], pipe.buffer.ptr[pos..pipe.buffer.len]);
            @memcpy(buffer[end .. end + to_read_next], pipe.buffer.ptr[0..to_read_next]);
        } else {
            @memcpy(buffer[readed .. readed +% len], pipe.buffer.ptr[pos..end_pos]);
        }

        const was_full = pipe.buffer.writeCapacity() == 0;
        pipe.buffer.seekRead(end_pos);

        if (was_full) {
            pipe.awakeUnlock(&pipe.write_wait);
        } else {
            pipe.mutex.unlock();
        }

        readed +%= len;
    }

    return readed;
}

fn fileWrite(file: *File, _: usize, buffer: []const u8) Error!usize {
    const pipe = file.data.asPtr(Self).?;

    var writen: usize = 0;
    while (writen < buffer.len) {
        pipe.mutex.lock();

        const remain_len = buffer.len -% writen;
        const len = @min(remain_len, pipe.buffer.writeCapacity());
        if (len == 0) {
            pipe.tryWaitUnlock(pipe.readers.raw, &pipe.write_wait, &pipe.read_wait)
                catch if (writen > 0) { return writen; } else return error.BadPipe;
            continue;
        }

        const pos: u32 = pipe.buffer.write_pos;
        const end_pos = pos +% len;
        if (end_pos > pipe.buffer.len) {
            const to_write = pipe.buffer.len -% pos;
            const to_read_next = len -% to_write;
            const end = writen +% to_write;

            @memcpy(pipe.buffer.ptr[pos..pipe.buffer.len], buffer[writen .. end]);
            @memcpy(pipe.buffer.ptr[0..to_read_next], buffer[end .. end + to_read_next]);
        } else {
            @memcpy(pipe.buffer.ptr[pos..end_pos], buffer[writen .. writen +% len]);
        }

        pipe.buffer.seekWrite(end_pos);
        pipe.awakeUnlock(&pipe.read_wait);

        writen +%= len;
    }

    return writen;
}

fn fileIoctl(file: *File, cmd: c_uint, arg: usize) vfs.Error!void {
    _ = file;
    _ = cmd;
    _ = arg;

    return error.BadOperation;
}

fn filePoll(file: *File) Error!File.Poll {
    const pipe = file.data.asPtr(Self).?;

    pipe.mutex.lock();
    defer pipe.mutex.unlock();

    return .{
        .read_avail = pipe.buffer.itemsToRead() > 0,
        .may_write = pipe.buffer.writeCapacity() > 0
    };
}

fn awakeUnlock(self: *Self, queue: *sched.WaitQueue) void {
    self.wait_lock.lock();
    defer self.wait_lock.unlock();

    self.mutex.unlock();
    sched.awakeAll(queue);
}

fn tryWaitUnlock(self: *Self, others: u16, wait_queue: *sched.WaitQueue, awake_queue: *sched.WaitQueue) Error!void {
    if (others == 0) {
        @branchHint(.cold);

        self.mutex.unlock();
        return error.BadPipe;
    }

    self.wait_lock.lock();
    self.mutex.unlock();

    sched.awakeAll(awake_queue);
    sched.waitUnlock(wait_queue,&self.wait_lock);
}
