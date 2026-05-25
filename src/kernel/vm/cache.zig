//! # Cache subsystem

// Copyright (C) 2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const lib = @import("../lib.zig");
const log = std.log.scoped(.@"vm.cache");
const sched = @import("../sched.zig");
const vm = @import("../vm.zig");

const LruList = lib.rcu.DoublyLinkedList;

pub const Block = struct {
    pub const Size = struct {
        pub const small: Size = .{ .shift = small_shift };
        pub const small_size = 64 * lib.kb_size;
        pub const small_shift = std.math.log2_int(u32, small_size);

        pub const medium: Size = .{ .shift = medium_shift };
        pub const medium_size = 2 * lib.mb_size;
        pub const medium_shift = std.math.log2_int(u32, medium_size);

        shift: u5,

        pub inline fn toRank(self: Size) u8 {
            @setRuntimeSafety(false);
            return self.shift -% comptime std.math.log2_int(u32, vm.page_size);
        }

        pub inline fn toPages(self: Size) u32 {
            return @as(u32, 1) << @truncate(self.toRank());
        }

        pub inline fn toBytes(self: Size) u32 {
            return @as(u32, 1) << self.shift;
        }

        pub inline fn offsetToIdx(self: Size, offset: usize) usize {
            return offset >> self.shift;
        }

        pub inline fn idxToOffset(self: Size, idx: usize) usize {
            return idx << self.shift;
        }

        pub inline fn quantPages(self: Size) u32 {
            @setRuntimeSafety(false);
            return self.toPages() / max_quants;
        }

        pub inline fn quantSize(self: Size) u32 {
            @setRuntimeSafety(false);
            return self.toBytes() / max_quants;
        }

        pub inline fn quantShift(self: Size) u5 {
            return self.shift - comptime std.math.log2_int(u8, max_quants);
        }
    };

    pub const Quant = struct {
        base: u32,
        top: u32
    };

    pub const max_quants = @bitSizeOf(BitSet);

    const List = std.SinglyLinkedList;
    const Node = List.Node;

    const BitSet = std.bit_set.IntegerBitSet(16);

    ctrl: *Control,
    index: u32,

    node: Node = .{},
    lru_node: LruList.Node = .{},

    ref_count: lib.atomic.RefCount(u16) = .init(1),
    rw_sem: lib.sync.RwSemaphore = .{},

    phys_base: u32,
    dirty_map: BitSet = .initEmpty(),

    size: Size = .{ .shift = Size.small_shift },
    lock: lib.sync.Spinlock = .{},

    inline fn fromNode(node: *Node) *Block {
        return @fieldParentPtr("node", node);
    }

    inline fn fromLruNode(lru_node: *LruList.Node) *Block {
        return @fieldParentPtr("lru_node", lru_node);
    }

    fn tableGet(self: *Block) bool {
        var old = self.ref_count.count();
        while (true) {
            if (old == 0) { @branchHint(.unlikely); return false; }
            if (self.ref_count.value.cmpxchgWeak(
                old, old + 1,
                .acquire, .monotonic)
            ) |new_old| {
                old = new_old; continue;
            }

            if (old == 1) lru_list.remove(&self.lru_node);
            return true;
        }
    }

    inline fn lruGet(self: *Block) bool {
        return self.ref_count.value.cmpxchgStrong(1, 2, .release, .monotonic) == null;
    }

    inline fn lruTake(self: *Block) bool {
        return self.ref_count.value.cmpxchgStrong(2, 0, .release, .monotonic) == null;
    }

    pub inline fn free(self: *Block) void {
        const base = @as(usize, self.phys_base) * vm.page_size;
        vm.PageAllocator.free(base, self.size.toRank());

        block_oma.free(self);
    }

    pub inline fn ref(self: *Block) void {
        return self.ref_count.inc();
    }

    pub fn deref(self: *Block) void {
        self.lock.lock();
        defer self.lock.unlock();

        if (self.ref_count.put()) lru_list.prepend(&self.lru_node);
    }

    pub inline fn writeDown(self: *Block) void {
        self.rw_sem.writeLock();
    }

    pub inline fn writeUp(self: *Block) void {
        self.rw_sem.writeUnlock();
    }

    pub inline fn readDown(self: *Block) void {
        self.rw_sem.readLock();
    }

    pub inline fn readUp(self: *Block) void {
        self.rw_sem.readUnlock();
    }

    /// `start` and `end` is local offsets.
    pub fn setDirtyRange(self: *Block, start: usize, end: usize) void {
        std.debug.assert(self.rw_sem.writing);

        const quant_shift = self.size.quantShift();
        const start_quant = start >> quant_shift;
        const end_quant = (end >> quant_shift) + 1;

        self.dirty_map.setRangeValue(.{ .start = start_quant, .end = end_quant }, true);
        self.tryPutIntoDirtyList();
    }

    /// `pos` is relative to start of the block.
    pub inline fn setDirtyAt(self: *Block, pos: usize) void {
        std.debug.assert(self.rw_sem.writing);
        self.dirty_map.set(pos >> self.size.quantShift());
        self.tryPutIntoDirtyList();
    }

    //    /// `start` and `end` is local offsets.
    //    pub fn writeBackRange(self: *Block, start: usize, end: usize) bool {
    //        std.debug.assert(self.rw_sem.writing);
    //
    //        const write_back = self.ctrl.write_back orelse return true;
    //
    //        const quant_shift = self.size.quantShift();
    //        const start_quant: u32 = @truncate(start >> quant_shift);
    //        const end_quant: u32 = @truncate((end + self.size.quantSize() - 1) >> quant_shift);
    //
    //        const _start = start_quant << quant_shift;
    //        const _end = end_quant << quant_shift;
    //
    //        self.dirty_map.setRangeValue(.{ .start = start_quant, .end = end_quant }, false);
    //        self.rw_sem.writeToReadLock();
    //        defer {
    //            self.rw_sem.readUnlock();
    //            self.rw_sem.writeLock();
    //        }
    //
    //        return write_back(self, &.{ .{ .base = _start, .top = _end } }, quant_shift);
    //    }

    pub fn asSlice(self: *const Block) []u8 {
        const ptr: [*]u8 = @ptrFromInt(self.getAddress());
        return ptr[0..self.size.toBytes()];
    }

    pub fn offsetToQuant(self: *const Block, global_offset: usize) u8 {
        const inner_offset = self.innerOffset(global_offset);
        const quant_shift = self.size.quantShift();
        return @truncate(inner_offset >> quant_shift);
    }

    pub inline fn innerOffset(self: *const Block, global_offset: usize) usize {
        return global_offset & (self.size.toBytes() - 1);
    }

    pub inline fn getOffset(self: *const Block) usize {
        return idxToOffset(self.index);
    }

    pub inline fn getAddress(self: *const Block) usize {
        return vm.getVirtLma(@as(usize, self.phys_base) * vm.page_size);
    }

    inline fn tryPutIntoDirtyList(self: *Block) void {
        if (@cmpxchgStrong(
            ?*Node,
            &self.node.next,
            null,
            &self.node,
            .release,
            .monotonic,
        ) != null) return;

        self.ctrl.dirty_list.prepend(&self.node);
    }

    inline fn takeFromDirtyList(self: *Block) void {
        @atomicStore(?*Node, &self.node.next, null, .release);
    }
};

const TreeHasher = opaque {
    pub const Result = u32;

    pub inline fn hash(key: u32) u32 { return key; }

    pub inline fn keyByValue(val: *Block) u32 {
        return val.index;
    }
};

pub const Control = struct {
    pub const WriteBackFn = *const fn (block: *Block, quants: []const Block.Quant, quant_shift: u5) bool;

    const RadixTree = lib.RadixTree(u32, Block, TreeHasher, 8);

    tree: RadixTree = .{},
    rcu: lib.rcu.GenerationBlock = .{},
    dirty_list: lib.atomic.SinglyLinkedList = .{},

    write_back: ?WriteBackFn,

    pub fn deinit(self: *Control) void {
        const Helper = opaque {
            pub fn deinitTable(table: *RadixTree.Table) void {
                if (table.count.raw > 0) for (table.entries[0..]) |ent| {
                    if (ent.isNull()) continue;
                    if (ent.isTable()) {
                        deinitTable(ent.ptr(RadixTree.Table));
                    } else {
                        const block = ent.ptr(Block);

                        if (block.ref_count.count() == 0) lru_list.remove(&block.lru_node);
                        block.free();
                    }
                };

                table.free();
            }
        };

        if (self.tree.root) |table| Helper.deinitTable(table);
    }

    pub fn getOrNull(self: *Control, index: u32) ?*Block {
        const block, const users = blk: {
            const gen = self.rcu.readLock();
            defer self.rcu.readUnlock(gen);

            const block = self.tree.lookup(index) orelse return null;
            break :blk .{block, block.ref_count.value.fetchAdd(1, .release)};
        };

        if (users == 0) {
            block.lock.lock();
            defer block.lock.unlock();

            lru_list.remove(&block.lru_node);
        }

        return block;
    }

    pub fn getNoRef(self: *Control, index: u32) error{NoEnt}!*Block {
        const gen = self.rcu.readLock();
        defer self.rcu.readUnlock(gen);

        const block = self.tree.lookup(index) orelse return error.NoEnt;
        return block;
    }

    pub fn insert(self: *Control, block: *Block) !?*Block {
        self.rcu.writeLock();
        defer self.rcu.writeUnlock();

        return try self.tree.insert(block.index, block) orelse {
            self.rcu.updateSync();
            return null;
        };
    }

    pub fn insertOrFree(self: *Control, block: *Block) !?*Block {
        const other = try self.insert(block) orelse return null;

        block.free();
        return other;
    }

    pub fn remove(self: *Control, block: *Block) void {
        self.rcu.writeLock();
        defer self.rcu.writeUnlock();

        const removed = self.tree.remove(block.index);
        std.debug.assert(block == removed);

        self.rcu.updateSync();
    }

    pub fn writeBack(self: *Control, block: *Block) bool {
        if (self.write_back == null) return true;

        block.readDown();
        defer block.readUp();

        if (block.dirty_map.mask == 0) return true;

        return self.writeBackRaw(block);
    }

    pub fn writeBackAll(self: *Control) bool {
        if (self.write_back == null) return true;

        while (self.dirty_list.popFirst()) |n| {
            const block = Block.fromNode(n);
            block.takeFromDirtyList();

            if (!self.writeBack(block)) return false;
        }

        return true;
    }

    fn writeBackRaw(self: *Control, block: *Block) bool {
        const quant_shift = block.size.quantShift();

        var quants_buffer: [Block.max_quants]Block.Quant = undefined;
        var quants: std.ArrayList(Block.Quant) = .initBuffer(&quants_buffer);

        var iter = block.dirty_map.iterator(.{ .kind = .set });
        var base_idx: usize = 0;
        var top_idx: usize = 0;
        while (iter.next()) |i| {
            if (top_idx == i +% 1) {
                top_idx +%= 1;
            } else {
                if (top_idx != 0) quants.addOneAssumeCapacity().* = .{
                    .base = @intCast(base_idx << quant_shift),
                    .top = @intCast(top_idx << quant_shift)
                };

                base_idx = i;
                top_idx = i +% 1;
            }
        }

        if (top_idx != 0) quants.addOneAssumeCapacity().* = .{
            .base = @intCast(base_idx << quant_shift),
            .top = @intCast(top_idx << quant_shift)
        };

        return self.write_back.?(block, quants.items, quant_shift);
    }
};

var block_oma: vm.ObjectAllocator = .initCapacity(@sizeOf(Block), 128);
var lru_list: LruList = .{};

pub fn init() !void {
    const assumed_pages = vm.PageAllocator.getTotalPages() - vm.PageAllocator.getAllocatedPages();
    const max_blocks = std.math.divCeil(usize, assumed_pages, comptime Block.Size.small.toPages()) catch unreachable;
    const oma_size = max_blocks * @sizeOf(Block);

    const oma_raw_pages = @min(vm.PageAllocator.max_alloc_pages, vm.bytesToPages(oma_size));
    const oma_rank = vm.pagesToRankExact(oma_raw_pages);

    const oma_phys = vm.PageAllocator.alloc(oma_rank) orelse return error.CacheNoMemory;
    errdefer vm.PageAllocator.free(oma_phys, oma_rank);

    block_oma = try .initRaw(@sizeOf(Block), oma_phys, @intCast(vm.rankToPages(oma_rank)));
}

pub fn deinit() void {
    block_oma.deinit();
}

pub inline fn idxToPages(idx: usize) usize {
    return idx * comptime Block.Size.small.toPages();
}

pub inline fn pagesToIdx(pages: usize) usize {
    return pages / comptime Block.Size.small.toPages();
}

pub inline fn idxToOffset(idx: usize) usize {
    return idx * comptime Block.Size.small.toBytes();
}

pub inline fn offsetToIdx(offset: usize) usize {
    return offset / comptime Block.Size.small.toBytes();
}

pub fn createBlock(ctrl: *Control, index: usize, size: Block.Size) !*Block {
    const block = block_oma.alloc(Block) orelse return error.NoMemory;
    errdefer block_oma.free(block);

    const phys = vm.PageAllocator.alloc(size.toRank()) orelse return error.NoMemory;
    block.* = .{
        .ctrl = ctrl,
        .index = @intCast(index),
        .phys_base = @intCast(phys / vm.page_size)
    };

    return block;
}

//pub fn insertBlockOrFree(block: *Block) ?*Block {
//    const other = block_table.putOrGet(block) orelse return null;
//
//    block.free();
//    return other;
//}
//
//pub fn getOrNull(ctrl: *Control, index: usize) ?*Block {
//    return block_table.getOrNull(ctrl, index);
//}
//
//pub fn getNoRef(ctrl: *Control, index: usize) error{NoEnt}!*Block {
//    const block = block_table.getOrNull(ctrl, index) orelse return error.NoEnt;
//    block.ref_count.dec();
//
//    return block;
//}

pub fn cleanup(pages: u32) bool {
    _ = pages;
    return false;

    //    var freed: u32 = 0;
    //    while (freed < pages) {
    //        const block = blk: {
    //            const gen = lru_list.ctrl.readLock();
    //            defer lru_list.ctrl.readUnlock(gen);
    //
    //            const node = lru_list.last.load(.acquire) orelse return false;
    //            const block = Block.fromLruNode(node);
    //
    //            break :blk if (block.lruGet()) block else continue;
    //        };
    //
    //        lru_list.remove(&block.lru_node);
    //        if (block.writeBack()) {
    //            if (!block.lruTake()) continue;
    //
    //            freed +%= block.size.toPages();
    //            removeBlock(block);
    //        }
    //    }
    //
    //    return freed >= pages;
}

//inline fn removeBlock(block: *Block) void {
//    block_table.remove(block);
//    block.free();
//}
