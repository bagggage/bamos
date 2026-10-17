//! # Futex control block

// Copyright (C) 2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const lib = @import("../lib.zig");
const log = std.log.scoped(.@"sys.futex");
const sched = @import("../sched.zig");
const sys = @import("../sys.zig");
const vfs = @import("../vfs.zig");
const vm = @import("../vm.zig");

pub const Error = vfs.Error || error { Again, Timeout, Interrupted };

pub const Key = struct {
    /// Reserved for shared memory handling.
    ptr: ?*anyopaque = null,
    address: usize,
};

pub const Entry = struct {
    pub const alloc_config: vm.auto.Config = .{
        .allocator = .oma,
        .capacity = 256,
    };

    key: Key,
    wait_entry: sched.WaitQueue.Entry,
    table_entry: Table.Entry = .{},

    inline fn fromTableEntry(entry: *Table.Entry) *Entry {
        return @fieldParentPtr("table_entry", entry);
    }
};

const Table = lib.HashTable(*const Key, opaque {
    pub fn hash(key: *const Key) u64 {
        return std.hash.Wyhash.hash(0, std.mem.asBytes(key));
    }

    pub fn eql(entry: *const Table.Entry, key: *const Key) bool {
        const futex_entry = Entry.fromTableEntry(@constCast(entry));
        return futex_entry.key == key.*;
    }
});

var table: Table = .{};
var locks: [*]lib.sync.Spinlock = undefined;

pub fn init() vm.Error!void {
    const max_capacity_bytes = 4 * lib.mb_size;

    const total_pages = vm.PageAllocator.getTotalPages();
    const free_pages = total_pages - vm.PageAllocator.getAllocatedPages();

    // Capacity is about 0.0244% of free memory, but not higer than `max_capacity_bytes`.
    const capacity_bytes = @min(free_pages / 4096, max_capacity_bytes);

    table = try .init(capacity_bytes);
    errdefer table.deinit();

    const phys_locks = vm.PageAllocator.alloc(
        vm.bytesToRank(table.buckets_len * @sizeOf(lib.sync.Spinlock))
    ) orelse return error.NoMemory;
    locks = @ptrFromInt(vm.getVirtLma(phys_locks));

    @memset(locks[0..table.buckets_len], .{});
}

pub fn deinit() void {
    if (table.buckets_len == 0) return;

    const rank = vm.bytesToRank(table.buckets_len * @sizeOf(lib.sync.Spinlock));
    const phys_locks = vm.getPhysLma(locks);
    vm.PageAllocator.free(phys_locks, rank);

    table.deinit();
}

pub fn wait(
    proc: *sys.Process, address: usize,
    expected: u32, timeout_ns: u64,
) Error!void {
    const page, const page_offset = try proc.addr_space.getPageSafe(address, .read);
    const value_ptr: *const u32 = @ptrFromInt(@intFromPtr(page.asSlice().ptr) + page_offset);

    const scheduler = sched.getCurrent();
    var entry: Entry = .{
        .wait_entry = scheduler.initWait(),
        .key = .{ .ptr = proc.addr_space, .address = address },
    };

    const bucket = table.getHashBucket(&entry.key).@"1";
    const lock = getBucketLock(bucket);

    {
        lock.lock();
        defer lock.unlock();

        if (@atomicLoad(u32, value_ptr, .acquire) != expected) {
            @branchHint(.unlikely);
            return error.Again;
        }

        bucket.list.prepend(&entry.table_entry.node);
    }

    errdefer {
        lock.lock();
        defer lock.unlock();

        if (!entry.wait_entry.isRemovedFromQueue()) bucket.list.remove(&entry.table_entry.node);
    }

    try scheduler.doWaitTimeout(timeout_ns, true);
}

pub fn wake(proc: *sys.Process, address: usize, num: u32) u32 {
    const key: Key = .{ .ptr = proc.addr_space, .address = address };
    _, const bucket = table.getHashBucket(&key);
    const lock = getBucketLock(bucket);

    lock.lock();
    defer lock.unlock();

    var awaken: u32 = 0;
    var prev: ?*Table.Entry.Node = null;
    var node= bucket.list.first;

    while (node) |n| : ({ prev = n; node = n.next; }) {
        const table_entry: *Table.Entry = @fieldParentPtr("node", n);
        const futex_entry = Entry.fromTableEntry(table_entry);

        if (
            futex_entry.key.address != key.address or
            futex_entry.key.ptr != futex_entry.key.ptr
        ) continue;
        if (prev) |p| {
            p.next = n.next;
        } else {
            bucket.list.first = n.next;
        }

        futex_entry.wait_entry.markAsRemovedFromQueue();
        if (sched.awakeEntry(&futex_entry.wait_entry)) {
            awaken += 1;
            if (awaken >= num) break;
        }
    }

    return awaken;
} 

inline fn getBucketLock(bucket: *const lib.hash_table.Bucket) *lib.sync.Spinlock {
    return &locks[bucketIdx(bucket)];
}

inline fn bucketIdx(bucket: *const lib.hash_table.Bucket) usize {
    return (@intFromPtr(bucket) - @intFromPtr(table.buckets)) / @sizeOf(lib.hash_table.Bucket);
}
