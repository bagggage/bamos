//! Epoll file descriptor

// Copyright (C) 2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");
const builtin = @import("builtin");

const Self = @This();

const Dentry = vfs.Dentry;
const Error = vfs.Error;
const File = vfs.File;
const Inode = vfs.Inode;
const lib = @import("../lib.zig");
const log = std.log.scoped(.@"vfs.epoll");
const Poll = File.Poll;
const sched = @import("../sched.zig");
const sys = @import("../sys.zig");
const vfs = @import("../vfs.zig");
const vm = @import("../vm.zig");

const epoll_fs_ctx: vfs.Context.Virt = .{};

const epoll_inode: Inode = .{
    .index = 0,
    .type = .unknown,
    .gid = 0,
    .uid = 0,
    .links_num = 0,
    .cache_ctrl = .{ .write_back = null },
};

const epoll_dentry: Dentry = .{
    .name = Dentry.Name.init("@epoll") catch unreachable,
    .inode = @constCast(&epoll_inode),
    .ctx = .{ .virt = @constCast(&epoll_fs_ctx) },
    .parent = @constCast(&epoll_dentry),
};

const Event = std.os.linux.epoll_event;

const Entry = struct {
    cache: File.Poll.Cache,
    data: usize,

    fn setup(self: *Entry, file: *File, mask: File.Poll, data: usize) void {
        // Mask is stored in lower bits of timestamp.
        // Timestamp is big enough and will *never actually
        // make a difference for sleep time calculation.
        const timestamp = (~@as(u64, 0) << @bitSizeOf(File.Poll)) | @as(u8, @bitCast(mask));
        file.ref();

        self.* = .{
            .cache = .{
                .entry = .{ .task = undefined, .timestamp = timestamp },
                .file = file,
            },
            .data = data,
        };
        self.cache.entry.markAsRemovedFromQueue();
    }

    inline fn deinit(self: *Entry) void {
        self.cache.file.?.deref();
    }

    inline fn setMask(self: *Entry, mask: File.Poll) void {
        const poll: *File.Poll = @ptrCast(&self.cache.entry.timestamp);
        poll.* = mask;
    }

    inline fn getMask(self: *const Entry) File.Poll {
        return @as(*const File.Poll, @ptrCast(&self.cache.entry.timestamp)).*;
    }

    comptime {
        // Mask is stored in lower bits of timestamp.
        std.debug.assert(builtin.cpu.arch.endian() == .little);
    }
};

pub const alloc_config: vm.auto.Config = .{ .allocator = .gpa };

entries: [*]Entry = undefined,
capacity: u32 = 0,
size: u32 = 0,
mutex: lib.sync.Mutex = .{},

pub fn new() vm.Error!*File {
    const file = vm.auto.alloc(File) orelse return error.NoMemory;
    errdefer vm.auto.free(File, file);

    const epoll = vm.auto.alloc(Self) orelse return error.NoMemory;

    epoll.* = .{};
    file.* = .{
        .type = .epoll,
        .dentry = @constCast(&epoll_dentry),
        .data = .fromPtr(epoll),
        .perm = .none,
    };

    return file;
}

pub fn delete(self: *Self) void {
    for (self.entries[0..self.size]) |*ent| ent.deinit();

    if (self.capacity > 0) {
        @branchHint(.likely);
        const rank = vm.bytesToRank(self.capacity * @sizeOf(Entry));
        vm.PageAllocator.free(vm.getPhysLma(self.entries), rank);
    }

    vm.auto.free(Self, self);
}

pub inline fn fromFile(file: *File) *Self {
    return file.data.asPtr(Self).?;
}

pub fn addEntry(self: *Self, fd: *File, mask: File.Poll, data: usize) vfs.Error!void {
    self.mutex.lock();
    defer self.mutex.unlock();

    const old_size = self.size;
    for (self.entries[0..old_size]) |*ent| if (ent.cache.file == fd) return error.Exists;

    try self.ensureCapacity(old_size + 1);

    self.entries[old_size].setup(fd, mask, data);
    self.size += 1;
}

pub fn modifyEntry(self: *Self, fd: *File, mask: File.Poll, data: usize) error{NoEnt}!void {
    self.mutex.lock();
    defer self.mutex.unlock();

    for (self.entries[0..self.size]) |*ent| {
        if (ent.cache.file != fd) continue;

        ent.setMask(mask);
        ent.data = data;

        return;
    }

    return error.NoEnt;
}

pub fn removeEntry(self: *Self, fd: *File) error{NoEnt}!void {
    const entries = self.entries[0..self.size];
    for (entries, 0..) |*ent, i| {
        if (ent.cache.file != fd) continue;

        ent.deinit();
        if (i + 1 < entries.len) entries[i] = entries[entries.len - 1];

        return;
    }

    return error.NoEnt;
}

pub fn wait(self: *Self, task: *sched.Task, events: []Event, timeout_ns: u64) error{Timeout,Interrupted}!u32 {
    self.mutex.lockKeepPreemption();
    defer self.mutex.unlockKeepPreemption();

    // Prepare
    for (self.entries[0..self.size]) |*ent| ent.cache.entry.task = task;

    // Cleanup
    defer for (self.entries[0..self.size]) |*ent| {
        if (ent.cache.entry.isRemovedFromQueue()) continue;

        const file = ent.cache.file.?;
        _ = file.poll(&ent.cache.entry, .remove) catch {};
    };

    // Polling
    const endtime_ns = sys.time.getUpTimeNs() +| timeout_ns;
    var n: u32 = 0;

    while (true) {
        task.prepareForSleep();

        for (self.entries[0..self.size]) |*ent| {
            const event = if (n < events.len) &events[n] else break;
            const file = ent.cache.file.?;

            const action: Poll.WaitAction = if (n == 0 and ent.cache.entry.isRemovedFromQueue()) .enqueue else .none;
            const result = file.poll(&ent.cache.entry, action) catch {
                n += 1;
                event.* = .{
                    .events = std.os.linux.POLL.ERR,
                    .data = .{ .ptr = ent.data },
                };

                continue;
            };

            const masked = result.mask(ent.getMask());
            if (masked.isAnySet()) continue;

            n += 1;
            event.* = .{
                .events = masked.toLinux(),
                .data = .{ .ptr = ent.data },
            };
        }

        if (n > 0) {
            task.canclePrepareForSleep();
            return n;
        }

        try sched.getCurrent().doWaitTimeout(endtime_ns -| sys.time.getUpTimeNs(), true);
    }
}

fn ensureCapacity(self: *Self, capacity: usize) vm.Error!void {
    if (self.capacity >= capacity) return;
 
    const rank = vm.bytesToRank(capacity * @sizeOf(Entry));
    const real_capacity = vm.rankToBytes(rank) / @sizeOf(Entry);

    const phys = vm.PageAllocator.alloc(rank) orelse return error.NoMemory;
    const new_entries: [*]Entry = @ptrFromInt(vm.getVirtLma(phys));

    if (self.capacity > 0) {
        @memcpy(new_entries[0..self.size], self.entries[0..self.size]);

        const old_phys = vm.getPhysLma(self.entries);
        const old_rank = vm.bytesToRank(capacity * @sizeOf(Entry));
        vm.PageAllocator.free(old_phys, old_rank);
    }

    self.entries = new_entries;
    self.capacity = @intCast(real_capacity);
}
