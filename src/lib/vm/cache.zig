//! # Cache subsystem

// Copyright (C) 2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const lib = @import("../lib.zig");
const vm = @import("../vm.zig");

pub const LruList = lib.rcu.DoublyLinkedList;

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

    pub const List = std.SinglyLinkedList;
    pub const Node = List.Node;

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

    pub inline fn fromNode(node: *Node) *Block {
        return @fieldParentPtr("node", node);
    }

    pub inline fn fromLruNode(lru_node: *LruList.Node) *Block {
        return @fieldParentPtr("lru_node", lru_node);
    }

    pub inline fn free(self: *Block) void {

    }

    pub inline fn ref(self: *Block) void {
        return self.ref_count.inc();
    }

    pub inline fn deref(self: *Block) void {
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
    pub inline fn setDirtyRange(self: *Block, start: usize, end: usize) void {

    }

    /// `pos` is relative to start of the block.
    pub inline fn setDirtyAt(self: *Block, pos: usize) void {

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
    }

    pub fn getOrNull(self: *Control, index: u32) ?*Block {
    }

    pub fn getNoRef(self: *Control, index: u32) error{NoEnt}!*Block {
    }

    pub fn insert(self: *Control, block: *Block) !?*Block {
    }

    pub fn insertOrFree(self: *Control, block: *Block) !?*Block {
    }

    pub fn remove(self: *Control, block: *Block) void {
    }

    pub fn writeBack(self: *Control, block: *Block) bool {
    }

    pub fn writeBackAll(self: *Control) bool {
    }
};

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

pub inline fn createBlock(ctrl: *Control, index: usize, size: Block.Size) !*Block {
    
}

pub inline fn cleanup(pages: u32) bool {

}
