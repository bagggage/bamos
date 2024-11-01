//! # Bucket object memory allocator
//! 
//! This module implements a simple, fast memory allocator using a bucket-based approach.
//! Objects are allocated from fixed-size buckets, and each bucket manages memory for a specific object type or size.
//! 
//! This allocator is suitable for scenarios where objects of the same size are frequently allocated and freed,
//! offering low fragmentation and quick allocations.

// Copyright (C) 2024 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const log = @import("../log.zig");
const utils = @import("../utils.zig");
const vm = @import("../vm.zig");

const Self = @This();
const Bucket = struct {
    pool_addr: usize = undefined,
    bitmap: utils.Bitmap = undefined,
    alloc_num: usize = 0,

    /// Initializes a new `Bucket`.
    /// 
    /// - `bitmap_addr`: The address of the bitmap used for tracking allocations.
    /// - `capacity`: The number of objects that can be stored in this bucket.
    /// - `pool_addr`: The virtual address of the memory pool.
    pub fn init(bitmap_addr: usize, capacity: usize, pool_addr: usize) Bucket {
        const bits: [*]u8 = @ptrFromInt(bitmap_addr);
        const bitmap_size = std.math.divCeil(usize, capacity, utils.byte_size) catch unreachable;

        const result = Bucket{
            .pool_addr = pool_addr,
            .bitmap = utils.Bitmap.init(bits[0..bitmap_size], false)
        };

        bits[bitmap_size - 1] = @as(u8, 0xFF) << @truncate(capacity % utils.byte_size);

        return result;
    }

    /// Calculates the maximum capacity of a bucket based on the number of pages and object size.
    /// 
    /// - `pages`: The number of pages allocated for the bucket.
    /// - `obj_size`: The size of the objects to be stored in the bucket.
    /// - Returns: The number of objects that can be stored in the bucket.
    pub fn calcCapacity(pages: u32, obj_size: u32) u32 {
        var capacity: u32 = ((pages * vm.page_size) - @sizeOf(BucketNode)) / obj_size;
        var bitmap_size: u32 = std.math.divCeil(u32, capacity, utils.byte_size) catch unreachable;

        // Adjust the capacity to ensure the bucket fits within the allocated pages.
        while ((utils.calcAlign(
            u32, (capacity * obj_size) + bitmap_size,
            @alignOf(BucketNode)) + @sizeOf(BucketNode)) >
            (pages * vm.page_size))
        {
            capacity -= 1;
            bitmap_size = std.math.divCeil(u32, capacity, utils.byte_size) catch unreachable;
        }

        return capacity;
    }

    /// Checks if a given address falls within the memory managed by this bucket.
    /// 
    /// - `addr`: The address to check.
    /// - Returns: `true` if the address is within this bucket's pool, `false` otherwise.
    pub inline fn isContainingAddr(self: *@This(), addr: usize) bool {
        return (addr >= self.pool_addr and addr < @intFromPtr(self.bitmap.bits.ptr));
    }
};

const BucketNode = utils.SList(Bucket).Node;
const Order = enum { Direct, Reverse };

obj_size: u32 = undefined,
/// The maximum number of objects that can be stored in a bucket.
bucket_capacity: u32 = undefined,
buckets: utils.SList(Bucket) = undefined,
/// The current allocation order (direct or reverse).
curr_order: Order = .Direct,

/// Initializes an allocator with a raw memory buffer.
/// 
/// - `T`: The type of the objects to be allocated.
/// - `buf_addr`: The virtual address of the raw memory buffer.
/// - `buf_pages`: The number of pages in the raw memory buffer.
pub fn initRaw(comptime T: type, buf_addr: usize, buf_pages: u32) Self {
    var result = initSized(@sizeOf(T), buf_pages);

    const node = result.makeNode(buf_addr);
    result.buckets.prepend(node);

    return result;
}

/// Initializes an allocator with a specified object size and pages per bucket.
/// 
/// - `obj_size`: The size of the objects to be allocated.
/// - `pages_per_bucket`: The number of pages to allocate per bucket.
/// - Returns: An initialized bucket allocator.
pub fn initSized(obj_size: u32, pages: u32) Self {
    return Self{
        .obj_size = obj_size,
        .bucket_capacity = Bucket.calcCapacity(pages, obj_size)
    };
}

/// Initializes an allocator for a specific type.
/// 
/// - `T`: The type of the objects to be allocated.
pub inline fn init(comptime T: type) Self {
    return initSized(T, 1);
}

/// Initialize a new bucket node from a given pool address.
/// 
/// - `pool_addr`: The virtual address of the memory pool.
/// - Returns: A pointer to the new bucket node.
pub fn makeNode(self: *Self, pool_addr: usize) *BucketNode {
    const bitmap_size = std.math.divCeil(u32, self.bucket_capacity, utils.byte_size) catch unreachable;
    const bitmap_addr = pool_addr + (self.bucket_capacity * self.obj_size);
    const node_addr = utils.calcAlign(usize, bitmap_addr + bitmap_size, @alignOf(BucketNode));

    const node: *BucketNode = @ptrFromInt(node_addr);
    node.data = Bucket.init(bitmap_addr, self.bucket_capacity, pool_addr);

    return node;
}

/// Allocates a new bucket node and adds it to the allocator's list of buckets.
/// 
/// - Returns: A pointer to the new bucket node, or `null` if allocation fails.
pub fn newBucket(self: *Self) ?*BucketNode {
    const pool_size =
        (self.obj_size * self.bucket_capacity) +
        @sizeOf(BucketNode) +
        (std.math.divCeil(u32, self.bucket_capacity, utils.byte_size) catch unreachable);

    const pool_pages: u32 = @truncate(std.math.divCeil(usize, pool_size, vm.page_size) catch unreachable);
    const pool_addr = vm.PageAllocator.alloc(std.math.log2_int(u32, pool_pages)) orelse return null;

    const node = self.makeNode(pool_addr);
    self.buckets.prepend(node);

    return node;
}

/// Allocates an object.
/// 
/// - `T`: The type of the pointer to be returned.
/// - Returns: A pointer to the allocated object, or `null` if allocation fails.
pub fn alloc(self: *Self, comptime T: type) ?*T {
    var bucket: ?*BucketNode = self.buckets.first;

    while (bucket) |buck| : (bucket = buck.next) {
        if (buck.data.alloc_num >= self.bucket_capacity) continue;

        bucket = buck;
        break;
    }

    if (bucket == null) {
        bucket = self.newBucket() orelse return null;
    }

    const buck: *Bucket = &bucket.?.data;
    const obj_idx = switch (self.curr_order) {
        .Direct => buck.bitmap.find(false) orelse unreachable,
        .Reverse => buck.bitmap.rfind(false) orelse unreachable,
    };

    self.curr_order = if (self.curr_order == .Direct) Order.Reverse else Order.Direct;

    buck.bitmap.set(obj_idx);
    buck.alloc_num += 1;

    return @ptrFromInt(buck.pool_addr + (obj_idx * self.obj_size));
}

/// Frees an object and returns it to the allocator.
/// 
/// - `obj_ptr`: A pointer to the object to be freed.
pub fn free(self: *Self, obj_ptr: anytype) void {
    const obj_addr = @intFromPtr(obj_ptr);

    std.debug.assert((obj_addr % self.obj_size) ==
        ((obj_addr & (~@as(usize, 0xFFF))) % self.obj_size));

    var curr_node = self.buckets.first;

    while (curr_node) |node| : (curr_node = node.next) {
        const bucket = &node.data;

        if (!bucket.isContainingAddr(obj_addr)) continue;

        const obj_idx = (obj_addr - bucket.pool_addr) / self.obj_size;

        bucket.bitmap.clear(obj_idx);
        bucket.alloc_num -= 1;

        return;
    }

    unreachable;
}
