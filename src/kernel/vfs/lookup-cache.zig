//! # VFS Lookup cache

// Copyright (C) 2024-2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const Dentry = vfs.Dentry;
const lib = @import("../lib.zig");
const log = std.log.scoped(.@"vfs.lookup_cache");
const MountPoint = vfs.MountPoint;
const vfs = @import("../vfs.zig");
const vm = @import("../vm.zig");

const Key = struct {
    parent: *const Dentry,
    name: []const u8,
};

const Table = lib.HashTable(Key, opaque{
    pub fn hash(key: Key) u64 {
        const ptr = @intFromPtr(key.parent.inode);
        var hasher = std.hash.Fnv1a_64.init();

        hasher.update(key.name);
        hasher.update(std.mem.asBytes(&ptr));

        return hasher.final();
    }

    pub fn eql(entry: *Entry, key: Key) bool {
        const dentry = Dentry.fromCache(entry);
        if (key.name.ptr == mount_point_name) {
            @branchHint(.unlikely);
            const mnt_point = dentry.getMountPoint();
            return dentry == mnt_point.getRootDentry() and key.parent == mnt_point.getHiddenDentry();
        }

        return dentry.parent == key.parent and std.mem.eql(u8, dentry.name.str(), key.name);
    }
});

const max_table_size = lib.mb_size * 16;
const min_table_size = lib.mb_size;
const mount_point_name = "/";

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
    const table_capacity = std.math.divCeil(
        usize,
        table_size,
        @sizeOf(lib.hash_table.Bucket),
    ) catch unreachable;

    table = try .init(@truncate(table_capacity));
    log.info("table: capacity: {}, size: {} KB", .{table_capacity,table_size / lib.kb_size});
}

pub fn get(parent: *const Dentry, name: []const u8) ?*Dentry {
    lock.lock();
    defer lock.unlock();

    const entry = table.get(.{
        .parent = parent,
        .name = name,
    }) orelse return null;

    var dentry = Dentry.fromCache(entry);
    if (dentry.meta.mount_point) {
        @branchHint(.unlikely);
        dentry = Dentry.fromCache(table.get(.{
            .parent = dentry,
            .name = mount_point_name,
        }) orelse return null);
    }

    return if (dentry.tryRef()) dentry else null;
}

pub fn getMountPoint(hidden: *const Dentry) ?*MountPoint {
    lock.lock();
    defer lock.unlock();

    const fs_root = Dentry.fromCache(table.get(.{
        .parent = hidden,
        .name = mount_point_name,
    }) orelse return null);

    return fs_root.getMountPoint();
}

pub fn insert(dentry: *Dentry) ?*Dentry {
    while (true) {
        lock.lock();
        defer lock.unlock();

        if (table.insert(
            .{
                .parent = dentry.parent,
                .name = dentry.name.str(),
            },
            &dentry.cache_ent,
        )) |collision| {
            @branchHint(.cold);

            const other = Dentry.fromCache(collision);
            if (other.tryRef()) return other; 
        }

        break;
    }

    return null;
}

pub fn tryInsert(dentry: *Dentry) bool {
    lock.lock();
    defer lock.unlock();

    if (table.insert(
        .{
            .parent = dentry.parent,
            .name = dentry.name.str(),
        },
        &dentry.cache_ent,
    ) == null) return true;

    return false;
}

pub fn insertMountPoint(mnt_point: *vfs.MountPoint) error{Exists}!void {
    const hidden = mnt_point.getHiddenDentry();
    const fs_root = mnt_point.getRootDentry();

    hidden.meta.mount_point = true;

    if (table.insert(
        .{
            .parent = hidden,
            .name = mount_point_name,
        },
        &fs_root.cache_ent,
    ) != null) return error.Exists;
}

pub fn remove(dentry: *Dentry) void {
    lock.lock();
    defer lock.unlock();

    table.removeEntry(&dentry.cache_ent);
}

pub fn tryRemove(dentry: *Dentry) bool {
    lock.lock();
    defer lock.unlock();

    if (table.removeByKey(.{
        .name = dentry.name.str(),
        .parent = dentry.parent,
    }) == null) return false;

    return true;
}

pub fn removeMountPoint(mount: *vfs.MountPoint) void {
    lock.lock();
    defer lock.unlock();

    table.removeEntry(&mount.getRootDentry().cache_ent);
    mount.getHiddenDentry().meta.mount_point = false;
}
