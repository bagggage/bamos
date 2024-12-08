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

// Copyright (C) 2024 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const utils = @import("../utils.zig");
const vm = @import("../vm.zig");

pub fn AutoContext(K: type) type {
    return opaque {
        pub fn hash(key: K) u64 {
            return std.hash.Wyhash.hash(0, std.mem.asBytes(&key));
        }

        pub fn eql(a: K, b: K) bool {
            return std.meta.eql(a, b);
        }
    };
}

/// Hash table structure.
/// 
/// - `K`: type of key.
/// - `V`: type of value.
/// - `Context`: type that contatins declarations of `hash` and `eql` functions
///   for the specified `K` type. This type is similar to `Context` parameter
///   used within `std.hash_map` standard implementation.
pub fn HashTable(K: type, V: type, Context: type) type {
    return struct {
        const Self = @This();

        pub const Entry = struct {
            value: V,
            hash: u64
        };

        pub const EntryList = utils.SList(Entry);
        pub const EntryNode = EntryList.Node;

        pub const Bucket = struct {
            list: EntryList = .{},

            fn get(self: Bucket, hash: u64) ?*EntryNode {
                var node = self.list.first;

                while (node) |n| : (node = n.next) {
                    if (n.data.hash == hash) return n;
                }

                return null;
            }
        };

        buckets: []Bucket = &.{},
        len: usize = 0,

        pub fn init(self: *Self, capacity: u32) !void {
            std.debug.assert(capacity > 0);

            const pages = std.math.divCeil(u32, capacity, vm.page_size) catch unreachable;
            const rank: u8 = std.math.log2_int_ceil(u32, pages);

            const phys = vm.PageAllocator.alloc(rank) orelse return error.NoMemory;
            const virt = vm.getVirtLma(phys);

            self.buckets.ptr = @ptrFromInt(virt);
            self.buckets.len = (pages * vm.page_size) / @sizeOf(Bucket);
            self.len = 0;

            @memset(self.buckets, Bucket{});
        }

        pub fn deinit(self: *Self) void {
            if (self.buckets.len == 0) return;

            const size: u32 = @truncate(self.buckets.len * @sizeOf(Bucket));
            const pages = std.math.divCeil(u32, size, vm.page_size) catch unreachable;
            const rank = std.math.log2_int_ceil(u32, pages);

            const virt = @intFromPtr(self.buckets.ptr);
            const phys = vm.getPhysLma(virt);

            self.buckets.len = 0;

            vm.PageAllocator.free(phys, rank);
        }

        pub fn get(self: *const Self, key: K) ?*V {
            const hash = Context.hash(key);
            const idx = hash % self.buckets.len;

            const node = self.buckets[idx].get(hash) orelse return null;

            return &node.data.value;
        }

        pub fn insert(self: *Self, key: K, entry: *EntryNode) void {
            const hash = Context.hash(key);
            const idx = hash % self.buckets.len;

            const bucket = &self.buckets[idx];

            entry.data.hash = hash;
            bucket.list.prepend(entry);

            self.len += 1;
        }

        pub fn remove(self: *Self, key: K) ?*EntryNode {
            const hash = Context.hash(key);
            const idx = hash % self.buckets.len;

            const bucket = &self.buckets[idx];
            const node = bucket.get(hash) orelse null;

            bucket.list.remove(node);
            self.len -= 1;

            return node;
        }
    };
}

pub fn AutoHashTable(K: type, V: type) type {
    return HashTable(K, V, std.hash_map.AutoContext(K));
}
