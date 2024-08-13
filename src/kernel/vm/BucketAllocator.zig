/// Bucket object memory allocator.

const std = @import("std");

const log = @import("../log.zig");
const utils = @import("../utils.zig");
const vm = @import("../vm.zig");

const Self = @This();
const Bucket = struct {
    pool_addr: usize = undefined,
    bitmap: utils.Bitmap = undefined,
    alloc_num: usize = 0,

    pub fn init(bitmap_addr: usize, capacity: usize, pool_addr: usize) Bucket {
        const bits: [*]u8 = @ptrFromInt(bitmap_addr);
        const bitmap_size = std.math.divCeil(usize, capacity, utils.byte_size) catch unreachable;

        const result = Bucket{ .pool_addr = pool_addr, .bitmap = utils.Bitmap.init(bits[0..bitmap_size], false) };

        bits[bitmap_size - 1] = @as(u8, 0xFF) << @truncate(capacity % utils.byte_size);

        return result;
    }

    pub fn calc_capacity(pages: u32, obj_size: u32) u32 {
        var capacity: u32 = ((pages * vm.page_size) - @sizeOf(BucketNode)) / obj_size;
        var bitmap_size: u32 = std.math.divCeil(u32, capacity, utils.byte_size) catch unreachable;

        while ((utils.calcAlign(u32, (capacity * obj_size) + bitmap_size, @alignOf(BucketNode)) + @sizeOf(BucketNode)) >
            (pages * vm.page_size))
        {
            capacity -= 1;
            bitmap_size = std.math.divCeil(u32, capacity, utils.byte_size) catch unreachable;
        }

        return capacity;
    }

    pub inline fn is_containing_addr(self: *@This(), addr: usize) bool {
        return (addr >= self.pool_addr and addr < @intFromPtr(self.bitmap.bits.ptr));
    }
};

const BucketNode = utils.SList(Bucket).Node;
const Order = enum { Direct, Reverse };

obj_size: u32 = undefined,
bucket_capacity: u32 = undefined,
buckets: utils.SList(Bucket) = undefined,
curr_order: Order = .Direct,

pub fn initRaw(comptime T: type, buf_addr: usize, buf_pages: u32) Self {
    var result = initSized(@sizeOf(T), buf_pages);

    const node = result.makeNode(buf_addr);
    result.buckets.prepend(node);

    return result;
}

pub fn initSized(obj_size: u32, pages_per_bucket: u32) Self {
    return Self{ .obj_size = obj_size, .bucket_capacity = Bucket.calc_capacity(pages_per_bucket, obj_size) };
}

pub inline fn init(comptime T: type) Self {
    return initSized(T, 1);
}

pub fn makeNode(self: *Self, pool_addr: usize) *BucketNode {
    const bitmap_size = std.math.divCeil(u32, self.bucket_capacity, utils.byte_size) catch unreachable;
    const bitmap_addr = pool_addr + (self.bucket_capacity * self.obj_size);
    const node_addr = utils.calcAlign(usize, bitmap_addr + bitmap_size, @alignOf(BucketNode));

    const node: *BucketNode = @ptrFromInt(node_addr);
    node.data = Bucket.init(bitmap_addr, self.bucket_capacity, pool_addr);

    return node;
}

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

pub fn free(self: *Self, obj_ptr: anytype) void {
    const obj_addr = @intFromPtr(obj_ptr);

    std.debug.assert((obj_addr % self.obj_size) ==
        ((obj_addr & (~@as(usize, 0xFFF))) % self.obj_size));

    var curr_node = self.buckets.first;

    while (curr_node) |node| : (curr_node = node.next) {
        const bucket = &node.data;

        if (!bucket.is_containing_addr(obj_addr)) continue;

        const obj_idx = (obj_addr - bucket.pool_addr) / self.obj_size;

        bucket.bitmap.clear(obj_idx);
        bucket.alloc_num -= 1;

        return;
    }

    unreachable;
}
