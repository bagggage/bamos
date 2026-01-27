//! # VFS Lookup cache

// Copyright (C) 2024-2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const Dentry = vfs.Dentry;
const lib = @import("../lib.zig");
const log = std.log.scoped(.@"vfs.lookup_cache");
const vfs = @import("../vfs.zig");
const vm = @import("../vm.zig");

const Table = lib.HashTable(u64, opaque{
    pub fn hash(key: u64) u64 { return key; } 
    pub fn eql(a: u64, b: u64) bool { return a == b; }
});

const max_table_size = lib.mb_size * 16;
const min_table_size = lib.mb_size;

pub const Entry = Table.Entry;

var table: Table = .{};
var lock: lib.sync.Spinlock = .init(.unlocked);

pub fn init() !void {
    const total_mem_size = vm.PageAllocator.getTotalPages() * vm.page_size;
    const table_size = std.math.clamp(
        (total_mem_size / 100) / 2, // 0.5% of total memory
        min_table_size,
        max_table_size
    );
    const table_capacity = std.math.divCeil(usize, table_size, @sizeOf(lib.hash_table.Bucket)) catch unreachable;

    table = try .init(@truncate(table_capacity));
    log.info("table: capacity: {}, size: {} KB", .{table_capacity,table_size / lib.kb_size});
}

pub fn get(hash: u64) ?*Dentry {
    lock.lock();
    defer lock.unlock();

    const dentry = Dentry.fromCache(table.get(hash) orelse return null);
    return if (dentry.ref_count.get()) dentry else null;
}

pub fn insert(hash: u64, dentry: *Dentry) void {
    lock.lock();
    defer lock.unlock();

    table.insert(hash, &dentry.cache_ent);
}

pub fn remove(hash: u64) ?*Dentry {
    lock.lock();
    defer lock.unlock();

    return Dentry.fromCache(table.remove(hash) orelse return null);
}

pub fn calcHash(parent: *const Dentry, name: []const u8) u64 {
    const ptr = @intFromPtr(parent.inode);

    var hasher = std.hash.Fnv1a_64.init();
    hasher.update(name);
    hasher.update(std.mem.asBytes(&ptr));

    return hasher.final();
}

pub inline fn cache(dentry: *Dentry) void {
    const hash = calcHash(dentry.parent, dentry.name.str());
    insert(hash, dentry);
}

pub inline fn uncache(dentry: *const Dentry) bool {
    const hash = calcHash(dentry.parent, dentry.name.str());
    return remove(hash) == dentry;
}