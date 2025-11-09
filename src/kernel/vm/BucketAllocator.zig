//! # Bucket object memory allocator
//! 
//! This module implements a simple, fast memory allocator using a bucket-based approach.
//! Objects are allocated from fixed-size buckets, and each bucket manages memory for a specific object type or size.
//! 
//! This allocator is suitable for scenarios where objects of the same size are frequently allocated and freed,
//! offering low fragmentation and quick allocations.

// Copyright (C) 2024-2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const utils = @import("../utils.zig");
const vm = @import("../vm.zig");

const Self = @This();
const Bucket = struct {
    const List = utils.SList;
    const Node = List.Node;

    pool_addr: usize,
    bitmap: utils.Bitmap,
    alloc_num: usize = 0,
    node: Node = .{},

    /// Initializes a new `Bucket`.
    /// 
    /// - `bitmap_addr`: The address of the bitmap used for tracking allocations.
    /// - `capacity`: The number of objects that can be stored in this bucket.
    /// - `pool_addr`: The virtual address of the memory pool.
    pub fn init(bitmap_addr: usize, capacity: usize, pool_addr: usize) Bucket {
        const bits: [*]u8 = @ptrFromInt(bitmap_addr);
        const bitmap_size = std.math.divCeil(usize, capacity, utils.byte_size) catch unreachable;

        defer bits[bitmap_size - 1] = @as(u8, 0xFF) << @truncate(capacity % utils.byte_size);
        return .{
            .pool_addr = pool_addr,
            .bitmap = .init(bits[0..bitmap_size], false)
        };
    }

    pub inline fn fromNode(node: *Node) *Bucket {
        return @fieldParentPtr("node", node);
    }

    /// Calculates the maximum capacity of a bucket based on the number of pages and object size.
    /// 
    /// - `pages`: The number of pages allocated for the bucket.
    /// - `obj_size`: The size of the objects to be stored in the bucket.
    /// - Returns: The number of objects that can be stored in the bucket.
    pub fn calcCapacity(pages: u32, obj_size: u32) u32 {
        var capacity: u32 = ((pages * vm.page_size) - @sizeOf(Bucket)) / obj_size;
        var bitmap_size: u32 = std.math.divCeil(u32, capacity, utils.byte_size) catch unreachable;

        // Adjust the capacity to ensure the bucket fits within the allocated pages.
        while ((utils.alignUp(
            u32, (capacity * obj_size) + bitmap_size,
            @alignOf(Bucket)) + @sizeOf(Bucket)) >
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

const Order = enum { direct, reverse };

obj_size: u32,
/// The maximum number of objects that can be stored in a bucket.
bucket_capacity: u32 = 0,
buckets: Bucket.List = .{},
/// The current allocation order (direct or reverse).
curr_order: Order = .direct,

/// Initializes an allocator with a raw memory buffer.
/// 
/// - `T`: The type of the objects to be allocated.
/// - `buf_addr`: The virtual address of the raw memory buffer.
/// - `buf_pages`: The number of pages in the raw memory buffer.
pub fn initRaw(comptime T: type, buf_addr: usize, buf_pages: u32) Self {
    var result = initSized(@sizeOf(T), buf_pages);

    const bucket = result.makeBucket(buf_addr);
    result.buckets.prepend(&bucket.node);

    return result;
}

/// Initializes an allocator with a specified object size and pages per bucket.
/// 
/// - `obj_size`: The size of the objects to be allocated.
/// - `pages_per_bucket`: The number of pages to allocate per bucket.
/// - Returns: An initialized bucket allocator.
pub fn initSized(obj_size: u32, pages: u32) Self {
    return .{
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

/// Allocates a new bucket and adds it to the allocator's list of buckets.
/// field_ptr: *T
/// - Returns: A pointer to the new bucket, or `null` if allocation fails.
pub fn newBucket(self: *Self) ?*Bucket {
    const pool_size = (self.obj_size * self.bucket_capacity) + @sizeOf(Bucket) +
        (std.math.divCeil(u32, self.bucket_capacity, utils.byte_size) catch unreachable);

    const pool_pages: u32 = @truncate(std.math.divCeil(usize, pool_size, vm.page_size) catch unreachable);
    const pool_addr = vm.PageAllocator.alloc(std.math.log2_int(u32, pool_pages)) orelse return null;

    const bucket = self.makeBucket(pool_addr);
    self.buckets.prepend(&bucket.node);

    return bucket;
}

/// Initialize a new bucket from a given pool address.
/// 
/// - `pool_addr`: The virtual address of the memory pool.
/// - Returns: A pointer to the new bucket.
fn makeBucket(self: *Self, pool_addr: usize) *Bucket {
    const bitmap_size = std.math.divCeil(u32, self.bucket_capacity, utils.byte_size) catch unreachable;
    const bitmap_addr = pool_addr + (self.bucket_capacity * self.obj_size);
    const bucket_addr = utils.alignUp(usize, bitmap_addr + bitmap_size, @alignOf(Bucket));

    const bucket: *Bucket = @ptrFromInt(bucket_addr);
    bucket.* = .init(bitmap_addr, self.bucket_capacity, pool_addr);

    return bucket;
}

/// Allocates an object.
/// 
/// - `T`: The type of the pointer to be returned.
/// - Returns: A pointer to the allocated object, or `null` if allocation fails.
pub fn alloc(self: *Self, comptime T: type) ?*T {
    const bucket = blk: {
        var node = self.buckets.first;
        while (node) |n| : (node = n.next) {
            const bucket = Bucket.fromNode(n);
            if (bucket.alloc_num >= self.bucket_capacity) continue;

            break :blk bucket;
        }

        break :blk self.newBucket() orelse return null;
    };

    const obj_idx = switch (self.curr_order) {
        .direct => bucket.bitmap.find(false) orelse unreachable,
        .reverse => bucket.bitmap.rfind(false) orelse unreachable,
    };

    self.curr_order = if (self.curr_order == .direct) Order.reverse else Order.direct;

    bucket.bitmap.set(obj_idx);
    bucket.alloc_num += 1;

    return @ptrFromInt(bucket.pool_addr + (obj_idx * self.obj_size));
}

/// Frees an object and returns it to the allocator.
/// 
/// - `obj_ptr`: A pointer to the object to be freed.
pub fn free(self: *Self, obj_ptr: anytype) void {
    const obj_addr = @intFromPtr(obj_ptr);

    std.debug.assert(
        (obj_addr % self.obj_size) ==
        ((obj_addr & (~@as(usize, 0xFFF))) % self.obj_size)
    );

    var node = self.buckets.first;
    while (node) |n| : (node = n.next) {
        const bucket = Bucket.fromNode(n);
        if (!bucket.isContainingAddr(obj_addr)) continue;

        const obj_idx = (obj_addr - bucket.pool_addr) / self.obj_size;
        bucket.bitmap.clear(obj_idx);
        bucket.alloc_num -= 1;

        return;
    }

    unreachable;
}
