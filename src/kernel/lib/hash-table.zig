//! # Hash Table structure
//! 
//! This is simple and lightweight implementation of well-known
//! hash table based on buckets.
//! 
//! It is used instead of `std.hash_map` implementations
//! because of runtime overhead that `std` implementation suffers from.
//! This problem is related to `std.mem.Allocator` interface.
//! And in most places in kernel's code, hash tables are not
//! allowed to resize, or resizing is very specific due to
//! optimization of memory reallocation.

// Copyright (C) 2024-2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const vm = @import("../vm.zig");

pub const Bucket = struct {
    pub const Entry = struct {
        pub const List = std.SinglyLinkedList;
        pub const Node = List.Node;

        hash: u64 = undefined,
        node: Node = .{},

        inline fn fromNode(node: *Node) *Entry {
            return @fieldParentPtr("node", node);
        }
    };

    list: Entry.List = .{},

    inline fn get(self: Bucket, hash: u64) ?*Entry {
        return find(self.list.first, hash);
    }

    inline fn next(_: Bucket, entry: *Entry, hash: u64) ?*Entry {
        return find(entry.node.next, hash);
    }

    fn find(node: ?*Entry.Node, hash: u64) ?*Entry {
        var curr = node;
        while (curr) |n| : (curr = n.next) {
            const entry = Entry.fromNode(n);
            if (entry.hash == hash) return entry;
        }

        return null;
    }
};

/// Hash table structure.
/// 
/// - `K`: type of key.
/// - `Context`: type that contatins declarations of `hash` and `eql` functions
///   for the specified `K` type. This type is similar to `Context` parameter
///   used within `std.hash_map` standard implementation.
pub fn HashTable(K: type, Context: type) type {
    return struct {
        const Self = @This();

        pub const Entry = Bucket.Entry;

        buckets: [*]Bucket = &.{},
        buckets_len: u32 = 0,
        len: u32 = 0,

        pub fn init(capacity: u32) !Self {
            std.debug.assert(capacity > 0);

            const rank = vm.bytesToRank(capacity);
            const phys = vm.PageAllocator.alloc(rank) orelse return error.NoMemory;

            const buckets: [*]Bucket = @ptrFromInt(vm.getVirtLma(phys));
            const len = vm.rankToBytes(rank) / @sizeOf(Bucket);

            @memset(buckets[0..len], Bucket{});

            return .{ .buckets = buckets, .buckets_len = @truncate(len) };
        }

        pub fn deinit(self: *Self) void {
            if (self.buckets_len == 0) return;

            const rank = vm.bytesToRank(self.buckets_len * @sizeOf(Bucket));
            const virt = @intFromPtr(self.buckets);
            const phys = vm.getPhysLma(virt);

            self.buckets_len = 0;
            self.len = 0;

            vm.PageAllocator.free(phys, rank);
        }

        pub fn get(self: *const Self, key: K) ?*Entry {
            const hash, const bucket = self.getHashBucket(key);
            return lookupAt(bucket, hash, key);
        }

        pub fn insert(self: *Self, key: K, entry: *Entry) ?*Entry {
            const hash, const bucket = self.getHashBucket(key);
            if (lookupAt(bucket, hash, key)) |collision| {
                @branchHint(.cold);
                return collision;
            }

            entry.hash = hash;
            bucket.list.prepend(&entry.node);
            self.len += 1;

            return null;
        }

        pub fn replace(self: *Self, entry: *Entry, new: *Entry) void {
            std.debug.assert(entry.hash == new.hash);

            const idx = entry.hash % self.buckets_len;
            const bucket = &self.buckets[idx];

            bucket.list.remove(&entry.node);
            bucket.list.prepend(&new.node);
        }

        pub fn removeByKey(self: *Self, key: K) ?*Entry {
            const hash, const bucket = self.getHashBucket(key);
            const entry = lookupAt(bucket, hash, key) orelse return null;

            bucket.list.remove(&entry.node);
            self.len -= 1;

            return entry;
        }

        pub fn removeEntry(self: *Self, entry: *Entry) void {
            const idx = entry.hash % self.buckets_len;
            const bucket = &self.buckets[idx];

            bucket.list.remove(&entry.node);
        }

        fn getHashBucket(self: *const Self, key: K) struct{u64,*Bucket} {
            const hash = Context.hash(key);
            const idx = hash % self.buckets_len;
            const bucket = &self.buckets[idx];

            return .{ hash, bucket };
        }

        fn lookupAt(bucket: *Bucket, hash: u64, key: K) ?*Entry {
            var entry = bucket.get(hash) orelse return null;
            if (Context.eql(entry, key)) {
                @branchHint(.likely);
                return entry;
            } else {
                @branchHint(.cold);
                while (bucket.next(entry, hash)) |e| : (entry = e) {
                    if (Context.eql(entry, key)) return e;
                }
                return null;
            }
        }
    };
}
