//! # VFS Lookup cache

// Copyright (C) 2024 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const Dentry = vfs.Dentry;
const log = std.log.scoped(.@"vfs.lookup_cache");
const utils = @import("../utils.zig");
const vfs = @import("../vfs.zig");
const vm = @import("../vm.zig");

const Table = utils.HashTable(u64, Dentry.Node, opaque{
    pub fn hash(key: u64) u64 { return key; } 
    pub fn eql(a: u64, b: u64) bool { return a == b; }
});

const max_table_size = utils.mb_size * 16;
const min_table_size = utils.mb_size;

pub const Entry = Table.EntryNode;

var table: Table = .{};
var lock = utils.Spinlock.init(.unlocked);

pub fn init() !void {
    const total_mem_size = vm.PageAllocator.getTotalPages() * vm.page_size;
    const table_size = std.math.clamp(
        (total_mem_size / 100) / 2, // 0.5% of total memory
        min_table_size,
        max_table_size
    );
    const table_capacity = std.math.divCeil(usize, table_size, @sizeOf(Table.Bucket)) catch unreachable;

    try table.init(@truncate(table_capacity));

    log.info("table: capacity: {}, size: {} KB", .{table_capacity,table_size / utils.kb_size});
}

pub fn get(hash: u64) ?*Dentry {
    lock.lock();
    defer lock.unlock();

    const dentry = &(table.get(hash) orelse return null).data;

    return if (dentry.ref_count.get()) dentry else null;
}

pub fn insert(hash: u64, dentry: *Dentry) void {
    lock.lock();
    defer lock.unlock();

    table.insert(hash, dentry.getCacheEntry());
}

pub fn remove(hash: u64) ?*Dentry {
    lock.lock();
    defer lock.unlock();

    return &(table.remove(hash) orelse return null).data.value.data;
}

pub fn calcHash(parent: *const Dentry, name: []const u8) u64 {
    const ptr = @intFromPtr(parent.inode);

    var hasher = std.hash.Fnv1a_64.init();
    hasher.update(name);
    hasher.update(std.mem.asBytes(&ptr));

    return hasher.final();
}

pub inline fn cache(dentry: *const Dentry) void {
    const hash = calcHash(dentry.parent, dentry.name.str());
    insert(hash, dentry);
}

pub inline fn uncache(dentry: *const Dentry) bool {
    const hash = calcHash(dentry.parent, dentry.name.str());
    return remove(hash) == dentry;
}