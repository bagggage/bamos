//! # File Descriptor

// Copyright (C) 2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const File = @This();

const Dentry = vfs.Dentry;
const Error = vfs.Error;
const lib = @import("../lib.zig");
const Pipe = vfs.Pipe;
const sched = @import("../sched.zig");
const sys = @import("../sys.zig");
const vfs = @import("../vfs.zig");
const vm = @import("../vm.zig");

pub const Type = enum(u8) {
    file   = 0,
    pipe   = 1,
    socket = 2,
};

pub const Operations = struct {
    const default = vfs.internals.file.default;

    pub const ReadFn = *const fn(*const File, usize, []u8) Error!usize;
    pub const WriteFn = *const fn(*File, usize, []const u8) Error!usize;
    pub const MmapPrepareFn = *const fn(*const File, *sys.AddressSpace.MapUnit) Error!void;
    pub const IoctlFn = *const fn(*File, c_uint, usize) Error!void;
    pub const PollFn = *const fn(*File, *Poll.WaitEntry, Poll.WaitAction) Error!Poll;

    read: ReadFn = &default.read,
    write: WriteFn = &default.write,
    ioctl: IoctlFn = &default.ioctl,
    mmapPrepare: MmapPrepareFn = &default.mmapPrepare,
    poll: PollFn = &default.poll,
};

pub const Poll = packed struct {
    pub const WaitEntry = sched.WaitQueue.Entry;

    pub const WaitAction = enum(u8) {
        none = 0,
        enqueue = 1,
        remove = 2,
    };

    pub const Cache = struct {
        file: ?*File = null,
        entry: WaitEntry,

        fn setup(self: *Cache, task: *sched.Task) void {
            self.* = .{ .entry = .{ .task = task, .timestamp = std.math.maxInt(u64) }};
            self.entry.markAsRemovedFromQueue();
        }

        fn createPool(user: *sched.Task.Specific.User, len: u32) vm.Error!void {
            const caches = vm.gpa.allocMany(Cache, len) orelse return error.NoMemory;
            const task = user.toTask();

            for (caches) |*c| c.setup(task);

            user.poll_cache = caches.ptr;
            user.poll_cache_len = len;
        }

        pub fn deinitPool(user: *sched.Task.Specific.User) void {
            if (user.poll_cache_len == 0) {
                @branchHint(.likely);
                return;
            }

            user.poll_cache_len = 0;
            vm.gpa.free(user.poll_cache);
        }

        pub fn getPool(user: *sched.Task.Specific.User, len: u32) vm.Error![]Cache {
            const requested_size = len * @sizeOf(Cache);
            const current_size = user.poll_cache_len * @sizeOf(Cache);

            if (user.poll_cache_len == 0) {
                @branchHint(.unlikely);
                try createPool(user, len);
            } else if (user.poll_cache_len < len or current_size - requested_size >= lib.mb_size) {
                @branchHint(.unlikely);
                deinitPool(user);
                try createPool(user, len);
            }

            return user.poll_cache[0..len];
        }

        pub fn closePool(pool: []Cache) void {
            for (pool) |*c| {
                const file = c.file orelse continue;
                if (!c.entry.isRemovedFromQueue()) _ = file.poll(&c.entry, .remove) catch {};

                c.file = null;
                file.deref();
            }
        }
    };

    read_avail: bool = false,
    read_prior: bool = false,
    read_urgent: bool = false,
    may_write: bool = false,
    may_write_prior: bool = false,
    hung_up: bool = false,
    hung_up_read: bool = false,
    no_wait: bool = false,

    pub fn fromLinux(in: i16) Poll {
        const POLL = std.os.linux.POLL;
        return .{
            .read_avail = (in & POLL.IN) != 0,
            .read_prior = (in & POLL.RDBAND) != 0,
            .read_urgent = (in & POLL.PRI) != 0,
            .may_write = (in & POLL.OUT) != 0,
            .may_write_prior = (in & 0x200) != 0,
        };
    }

    pub fn toLinux(self: Poll) i16 {
        const POLL = std.os.linux.POLL;
        var result: i16 = 0;
        if (self.read_avail)      result |= POLL.IN | POLL.RDNORM;
        if (self.read_prior)      result |= POLL.IN | POLL.RDBAND;
        if (self.read_urgent)     result |= POLL.IN | POLL.PRI;
        if (self.may_write)       result |= POLL.OUT | 0x100;
        if (self.may_write_prior) result |= POLL.OUT | 0x200;
        if (self.hung_up)         result |= POLL.HUP;
        if (self.hung_up_read)    result |= POLL.HUP | 0x2000;

        return result;
    }
};

pub const alloc_config: vm.auto.Config = .{
    .allocator = .oma,
    .capacity = 128,
};

dentry: *Dentry,
ops: *const Operations = &Operations.default.ops,
data: lib.AnyData = .{},

ref_count: lib.atomic.RefCount(u32) = .init(0),
perm: vfs.Permissions = .none,
type: Type = .file,

// TODO: Make `offset` atomic/thread-safe access
offset: usize = 0,

pub inline fn get(self: *File) bool {
    return self.ref_count.get();
}

pub inline fn put(self: *File) bool {
    return self.ref_count.put();
}

pub inline fn ref(self: *File) void {
    self.ref_count.inc();
}

pub fn deref(self: *File) void {
    if (self.ref_count.put()) switch (self.type) {
        .file => self.dentry.onClose(self),
        .pipe => {
            const pipe = self.data.asPtr(Pipe).?;
            if (self.perm == .w) pipe.deref(.writer) else pipe.deref(.reader);
        },
        .socket => std.log.err("vfs.File: close not implemented for socket object", .{}),
    };
}

pub inline fn validateAccess(self: *const File, access: vfs.Permissions) Error!void {
    if (!self.perm.checkAccess(access)) return error.NoAccess;
}

pub fn read(self: *File, buf: []u8) Error!usize {
    const offset = self.offset;
    const readed = try self.ops.read(self, offset, buf);
    self.offset = offset + readed;

    return readed;
}

pub inline fn readAt(self: *File, offset: usize, buf: []u8) Error!usize {
    std.debug.assert(self.dentry.inode.type != .directory);
    return try self.ops.read(self, offset, buf);
}

pub fn readAll(self: *File, buf: []u8) Error!void {
    const offset = self.offset;
    const readed = try self.ops.read(self, offset, buf);
    if (readed != buf.len) return Error.IoFailed;

    self.offset = offset + readed;
}

pub inline fn write(self: *File, buf: []const u8) Error!usize {
    std.debug.assert(self.dentry.inode.type != .directory);
    const offset = self.offset;
    const size = try self.ops.write(self, offset, buf);
    self.offset = offset + size;

    return size;
}

pub inline fn writeAt(self: *File, offset: usize, buf: []const u8) Error!usize {
    std.debug.assert(self.dentry.inode.type != .directory);
    return try self.ops.write(self, offset, buf);
}

pub inline fn mmapPrepare(self: *File, map_unit: *sys.AddressSpace.MapUnit) Error!void {
    std.debug.assert(self.dentry.inode.type != .directory);
    return self.ops.mmapPrepare(self, map_unit);
}

pub inline fn ioctl(self: *File, cmd: c_uint, arg: usize) Error!void {
    return self.ops.ioctl(self, cmd, arg);
}

pub inline fn poll(self: *File, entry: *Poll.WaitEntry, action: Poll.WaitAction) Error!Poll {
    return self.ops.poll(self, entry, action);
}
