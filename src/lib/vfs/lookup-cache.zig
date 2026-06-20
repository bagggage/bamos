//! # VFS Lookup cache

// Copyright (C) 2024-2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const bindings = @import("../bindings.zig");
const Dentry = vfs.Dentry;
const lib = @import("../lib.zig");
const vfs = @import("../vfs.zig");

const Table = lib.HashTable(u64, opaque{
    pub fn hash(key: u64) u64 { return key; } 
    pub fn eql(a: u64, b: u64) bool { return a == b; }
});

pub const Entry = Table.Entry;

pub inline fn get(hash: u64) ?*Dentry {
    return bindings.getInstance().vfs.lookup_cache.get(hash);
}

pub inline fn insert(hash: u64, dentry: *Dentry) void {
    bindings.getInstance().vfs.lookup_cache.insert(hash, dentry);
}

pub inline fn remove(hash: u64) ?*Dentry {
    return bindings.getInstance().vfs.lookup_cache.remove(hash);
}

pub inline fn calcHash(parent: *const Dentry, name: []const u8) u64 {
    return bindings.getInstance().vfs.lookup_cache.calcHash(parent, name);
}

pub inline fn cache(dentry: *Dentry) void {
    const hash = calcHash(dentry.parent, dentry.name.str());
    insert(hash, dentry);
}

pub inline fn uncache(dentry: *const Dentry) bool {
    const hash = calcHash(dentry.parent, dentry.name.str());
    return remove(hash) == dentry;
}
