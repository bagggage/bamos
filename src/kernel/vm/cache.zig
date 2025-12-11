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
            return @as(u32, 1) << self.toRank();
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

    const List = lib.rcu.SinglyLinkedList;
    const Node = List.Node;

    const BitSet = std.bit_set.IntegerBitSet(16);

    ctrl: *Control,
    index: u32,

    node: Node = .{},
    lru_node: LruList.Node = .{},

    /// 1-base reference counter.
    ref_count: lib.atomic.RefCount(u16) = .init(1),
    rw_sem: lib.sync.RwSemaphore = .{},

    phys_base: u32,
    dirty_map: BitSet = .initEmpty(),
    lock_map: BitSet = .initEmpty(),

    size: Size = .{ .shift = Size.small_shift },

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
    }

    pub inline fn ref(self: *Block) void {
        return self.ref_count.inc();
    }

    pub fn deref(self: *Block) void {
        const refs = self.ref_count.value.fetchSub(1, .release) - 1;
        if (refs > 1) { @branchHint(.likely); return; }

        std.debug.assert(refs == 1);
        lru_list.prepend(&self.lru_node);
    }

    pub fn writeDown(self: *Block) void {
        self.rw_sem.writeLock();

        self.rw_sem.lock.lock();
        if (self.lock_map.mask != 0) {
            @branchHint(.unlikely);
            sched.waitUnlock(&self.rw_sem.wait_queue, &self.rw_sem.lock);
        } else {
            self.rw_sem.lock.unlock();
        }
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

    pub inline fn writeBack(self: *Block) bool {
        return self.ctrl.writeBack(self);
    }

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
};

const Table = struct {
    const EntryList = lib.rcu.SinglyLinkedList;

    entries: []EntryList = &.{},
    mod_mask: u64 = 0,

    fn init(phys: usize, len: usize) Table {
        std.debug.assert(std.math.isPowerOfTwo(len));
        const entries_ptr: [*]EntryList = @ptrFromInt(vm.getVirtLma(phys));
        @memset(entries_ptr[0..len], EntryList{});
        return .{
            .entries = entries_ptr[0..len],
            .mod_mask = len - 1
        };
    }

    fn getOrNull(self: *Table, ctrl: *Control, index: usize) ?*Block {
        const entry_idx = self.calcIdx(ctrl, index);
        const list = &self.entries[entry_idx];

        const gen = list.ctrl.readLock();
        defer list.ctrl.readUnlock(gen);

        var node = list.head.load(.acquire);
        while (node) |n| : (node = n.next) {
            const block = Block.fromNode(n);
            if (block.ctrl != ctrl or block.index != index) continue;
            if (block.tableGet()) { @branchHint(.likely); return block; }

            return null;
        }

        return null;
    }

    fn putOrGet(self: *Table, new_block: *Block) ?*Block {
        const entry_idx = self.calcIdx(new_block.ctrl, new_block.index);
        const list = &self.entries[entry_idx];

        list.ctrl.writeLock();
        defer list.ctrl.writeUnlock();

        var node = list.head.load(.acquire);
        while (node) |n| : (node = n.next) {
            const block = Block.fromNode(n);
            if (block.ctrl != new_block.ctrl or block.index != new_block.index) continue;

            block.ref();
            return block;
        }

        new_block.ref();
        list.prependRaw(&new_block.node);
        list.ctrl.update();

        return null;
    }

    fn remove(self: *Table, block: *Block) void {
        std.debug.assert(block.ref_count.count() == 0);
        const entry_idx = self.calcIdx(block.ctrl, block.index);

        const list = &self.entries[entry_idx];
        _ = list.remove(&block.node) orelse unreachable;
    }

    fn calcIdx(self: *const Table, ctrl: *Control, idx: usize) u64 {
        var hasher = std.hash.Fnv1a_64.init();
        hasher.update(std.mem.asBytes(&ctrl));
        hasher.update(std.mem.asBytes(&idx));

        return hasher.final() & self.mod_mask;
    }
};

pub const Control = struct {
    pub const WriteBackFn = *const fn (block: *Block, quants: []const Block.Quant, quant_shift: u5) bool;

    write_back: ?WriteBackFn,

    pub fn writeBack(self: *Control, block: *Block) bool {
        if (self.write_back == null) return true;

        if (block.dirty_map.mask == 0) return true;
        if (block.lock_map.mask != 0) return false;

        {
            block.rw_sem.writeLock();
            defer block.rw_sem.writeUnlock();

            block.rw_sem.lock.lock();
            defer block.rw_sem.lock.unlock();

            if (block.lock_map.mask != 0) return false;
            if (block.dirty_map.mask == 0) return true;
            block.lock_map.mask = block.dirty_map.mask;
        }

        const result = self.writeBackRaw();
        const writer_waiting = blk: {
            block.rw_sem.lock.lock();
            defer block.rw_sem.lock.unlock();

            block.lock_map.mask = 0;
            break :blk block.rw_sem.writing;
        };

        if (writer_waiting) sched.awakeAll(&block.rw_sem.wait_queue);
        return result;
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
                    .base = base_idx << quant_shift,
                    .top = top_idx << quant_shift
                };

                base_idx = i;
                top_idx = i +% 1;
            }
        }

        if (top_idx != 0) quants.addOneAssumeCapacity().* = .{
            .base = base_idx << quant_shift,
            .top = top_idx << quant_shift
        };

        return self.write_back.?(block, quants.items, quant_shift);
    }
};

var block_oma: vm.ObjectAllocator = undefined;
var block_table: Table = .{};
var lru_list: LruList = .{};

pub fn init() !void {
    const assumed_pages = vm.PageAllocator.getTotalPages() - vm.PageAllocator.getAllocatedPages();
    const max_blocks = std.math.divCeil(usize, assumed_pages, comptime Block.Size.small.toPages()) catch unreachable;
    const oma_size = max_blocks * @sizeOf(Block);
    const table_size = max_blocks * @sizeOf(Table.EntryList);

    const oma_raw_pages = blk: {
        const temp = std.math.divCeil(usize, oma_size, vm.page_size) catch unreachable;
        break :blk @min(vm.PageAllocator.max_alloc_pages, temp);
    };
    const table_raw_pages = blk: {
        const temp = std.math.divCeil(usize, table_size, vm.page_size) catch unreachable;
        break :blk if (temp > vm.PageAllocator.max_alloc_pages) {
            log.warn(
                "Table size must be {} MB, but the PageAllocator is limited to {} MB",
                .{temp * vm.page_size / lib.mb_size, vm.PageAllocator.max_alloc_pages * vm.page_size / lib.mb_size}
            );
            break :blk vm.PageAllocator.max_alloc_pages;
        } else temp;
    };

    const table_rank = vm.pagesToRank(@intCast(table_raw_pages));
    const oma_rank = vm.pagesToRankExact(@intCast(oma_raw_pages));

    const table_phys = vm.PageAllocator.alloc(table_rank) orelse return error.CacheNoMemory;
    errdefer vm.PageAllocator.free(table_phys, table_rank);

    const oma_phys = vm.PageAllocator.alloc(oma_rank) orelse return error.CacheNoMemory;
    errdefer vm.PageAllocator.free(oma_phys, oma_rank);

    block_oma = try .initRaw(@sizeOf(Block), oma_phys, @intCast(vm.rankToPages(oma_rank)));

    const real_table_size = vm.rankToBytes(table_rank) / @sizeOf(Table.EntryList);
    block_table = .init(table_phys, real_table_size);
}

pub fn deinit() void {
    const table_size = block_table.entries.len * @sizeOf(Table.EntryList);
    const table_pages = std.math.divCeil(usize, table_size, vm.page_size) catch unreachable;
    const table_rank = std.math.log2_int_ceil(u32, @truncate(table_pages));
    const table_phys = vm.getPhysLma(@ptrFromInt(block_table.entries.ptr));

    vm.PageAllocator.free(table_phys, table_rank);
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

pub fn insertBlockOrFree(block: *Block) ?*Block {
    const other = block_table.putOrGet(block) orelse return null;

    block.free();
    return other;
}

pub fn getOrNull(ctrl: *Control, index: usize) ?*Block {
    return block_table.getOrNull(ctrl, index);
}

pub fn getNoRef(ctrl: *Control, index: usize) error{NoEnt}!*Block {
    const block = block_table.getOrNull(ctrl, index) orelse return error.NoEnt;
    block.ref_count.dec();

    return block;
}

pub fn cleanup(pages: u32) bool {
    var freed: u32 = 0;
    while (freed < pages) {
        const block = blk: {
            const gen = lru_list.ctrl.readLock();
            defer lru_list.ctrl.readUnlock(gen);

            const node = lru_list.last.load(.acquire) orelse return false;
            const block = Block.fromLruNode(node);

            break :blk if (block.lruGet()) block else continue;
        };

        lru_list.remove(&block.lru_node);
        if (block.writeBack()) {
            if (!block.lruTake()) continue;

            freed +%= block.size.toPages();
            removeBlock(block);
        }
    }

    return freed >= pages;
}

inline fn removeBlock(block: *Block) void {
    block_table.remove(block);
    block.free();
}
