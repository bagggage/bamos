//! # Cache subsystem **DRAFT**

// Copyright (C) 2024-2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const utils = @import("../utils.zig");
const vm = @import("../vm.zig");

const LruList = utils.List;
const LruNode = LruList.Node;

pub const block_size = 16 * utils.kb_size;
pub const block_pages = block_size / vm.page_size;
pub const block_rank = std.math.log2_int(u32, block_pages);

pub const Error = error {
    NoMemory
};

pub const Block = struct {
    const List = utils.List;
    const Node = List.Node;

    lba_key: usize = 0,
    phys_base: u32 = 0,

    ref_count: utils.RefCount(u32) = .{},

    node: Node = .{},
    lru_node: LruNode = .{},

    pub inline fn getPhysBase(self: Block) usize {
        return @as(usize, self.phys_base) * block_size;
    }

    pub inline fn getVirtBase(self: Block) usize {
        return vm.getVirtLma(self.getPhysBase());
    }

    pub inline fn getOffset(self: Block) usize {
        return blockToOffset(self.lba_key);
    }

    pub inline fn asSlice(self: Block) []u8 {
        return @as([*]u8, @ptrFromInt(self.getVirtBase()))[0..block_size];
    }

    pub inline fn asSliceOffset(self: Block, offset: usize) []u8 {
        const inner_offset = offset % block_size;
        return @as([*]u8, @ptrFromInt(self.getVirtBase()))[inner_offset..block_size];
    }

    pub inline fn asObject(self: Block, comptime T: type, offset: usize) *T {
        const inner_offset = offset % block_size;
        return @as(*T, @ptrFromInt(self.getVirtBase() + inner_offset));
    }

    pub inline fn asArray(self: Block, comptime T: type) []T {
        const len = comptime block_size / @sizeOf(T);
        return @as([*]T, @ptrFromInt(self.getVirtBase()))[0..len];
    }

    pub inline fn asArrayOffset(self: Block, comptime T: type, offset: usize) []T {
        const inner_offset = offset % block_size;
        const len = (block_size - inner_offset) / @sizeOf(T);
        return @as([*]T, @ptrFromInt(self.getVirtBase() + inner_offset))[0..len];
    }

    pub inline fn isLocked(self: Block) bool {
        return self.ref_count.count() != 0;
    }

    pub inline fn lock(self: *Block) void {
        self.ref_count.inc();
    }

    pub inline fn release(self: *Block) void {
        self.ref_count.dec();
    }

    inline fn fromNode(node: *Node) *Block {
        return @fieldParentPtr("node", node);
    }

    inline fn fromLruNode(lru_node: *LruNode) *Block {
        return @fieldParentPtr("lru_node", lru_node);
    }
};

pub const Cursor = struct {
    blk: ?*Block = null,
    offset: usize = 0,

    pub fn blank() Cursor { return .{}; }

    pub fn from(blk: *Block, offset: usize) Cursor {
        return .{ .blk = blk, .offset = offset };
    }

    pub inline fn asObject(self: *const Cursor, T: type) *T {
        return self.blk.?.asObject(T, self.offset);
    }

    pub inline fn asSlice(self: *const Cursor) []u8 {
        return self.blk.?.asSliceOffset(self.offset);
    }

    pub inline fn asSliceAbsolute(self: *const Cursor) []u8 {
        return self.blk.?.asSlice();
    }

    pub inline fn asArray(self: *const Cursor, T: type) []T {
        return self.blk.?.asArrayOffset(T, self.offset);
    }

    pub inline fn asArrayAbsolute(self: *const Cursor, T: type) []T {
        return self.blk.?.asArray(T);
    }

    pub inline fn isValid(self: *const Cursor) bool {
        return self.blk != null;
    }
};

/// Specific page-cache hash table
const HashTable = struct {
    const Page = struct {
        pub const alloc_config: vm.auto.Config = .{
            .allocator = .oma,
            .capacity = 128
        };

        const List = utils.SList;
        const Node = List.Node;

        base: u32,
        rank: u8 = 0,

        node: Page.Node = .{},

        pub inline fn getPhysBase(self: Page) usize {
            return @as(usize, self.base) * vm.page_size;
        }

        pub inline fn fromNode(node: *Page.Node) *Page {
            return @fieldParentPtr("node", node);
        }
    };

    const Bucket = struct {
        list: Block.List = .{},

        pub inline fn push(self: *Bucket, block: *Block) void {
            self.list.append(&block.node);
        }

        pub inline fn remove(self: *Bucket, block: *Block) void {
            self.list.remove(&block.node);
        }

        pub fn get(self: *const Bucket, key: usize) ?*Block {
            var node = self.list.first;
            while (node) |n| : (node = n.next) {
                const block = Block.fromNode(n);
                if (block.lba_key == key) return block;
            }

            return null;
        }
    };

    const initial_capacity = 512;
    const initial_pages = std.math.divCeil(comptime_int, initial_capacity * @sizeOf(Bucket), vm.page_size) catch unreachable;
    const initial_rank = std.math.log2_int_ceil(u8, initial_pages);
    const virt_pages = (64 * utils.mb_size) / vm.page_size;

    pages: Page.List = .{},
    buckets: []Bucket = &.{},

    pub fn init() Error!HashTable {
        var self: HashTable = .{};

        const phys = try self.allocPages(initial_rank);
        errdefer self.freePages();

        const virt = vm.heapReserve(virt_pages);
        vm.mmap(
            virt, phys, initial_pages,
            .{ .global = true, .write = true },
            vm.getRootPt()
        ) catch return error.NoMemory;

        self.buckets.ptr = @ptrFromInt(virt);
        self.buckets.len = (initial_pages * vm.page_size) / @sizeOf(Bucket);

        @memset(self.buckets, Bucket{});
        return self;
    }

    pub fn deinit(self: *HashTable) void {
        vm.heapRelease(@intFromPtr(self.buckets.ptr), virt_pages);

        while (self.pages.first != null) self.freePages();
    }

    pub fn add(self: *HashTable, entry: *Block) void {
        const idx = entry.lba_key % self.buckets.len;
        self.buckets[idx].push(entry);
    }

    pub fn remove(self: *HashTable, entry: *Block) void {
        const idx = entry.lba_key % self.buckets.len;
        self.buckets[idx].remove(entry);
    }

    pub fn get(self: *const HashTable, key: usize) ?*Block {
        const idx = key % self.buckets.len;
        return self.buckets[idx].get(key);
    }

    fn allocPages(self: *HashTable, rank: u8) Error!usize {
        const page = vm.auto.alloc(Page) orelse return error.NoMemory;
        errdefer vm.auto.free(Page, page);

        const phys = vm.PageAllocator.alloc(rank) orelse return error.NoMemory;
    
        page.base = @truncate(phys / vm.page_size);
        page.rank = rank;

        self.pages.prepend(&page.node);
        return phys;
    }

    fn freePages(self: *HashTable) void {
        const node = self.pages.popFirst() orelse unreachable;
        const page = Page.fromNode(node);

        vm.PageAllocator.free(page.getPhysBase(), page.rank);
        vm.auto.free(Page, page);
    }
};

pub const ControlBlock = struct {
    const List = utils.List;

    pub const alloc_config: vm.auto.Config = .{
        .allocator = .oma,
        .capacity = 32
    };

    hash_table: HashTable = .{},
    hash_lock: utils.Spinlock = utils.Spinlock.init(.unlocked),

    lru_list: LruList = .{},
    lru_lock: utils.Spinlock = utils.Spinlock.init(.unlocked),

    block_oma: vm.ObjectAllocator = .initCapacity(@sizeOf(Block), 256),

    node: List.Node = .{},

    pub inline fn init() Error!ControlBlock {
        return .{ .hash_table = try .init() };
    }

    pub fn deinit(self: *ControlBlock) void {
        self.hash_table.deinit();
        self.block_oma.deinit();
    }

    pub fn get(self: *ControlBlock, key: usize) ?*Block {
        self.lru_lock.lock();
        self.hash_lock.lock();
        defer self.lru_lock.unlock();
        defer self.hash_lock.unlock();

        const block = self.hash_table.get(key) orelse return null;

        if (!block.isLocked()) self.untrack(block);
        block.lock();

        return block;
    }

    pub fn put(self: *ControlBlock, block: *Block) void {
        self.lru_lock.lock();
        defer self.lru_lock.unlock();

        block.release();
        if (!block.isLocked()) self.track(block);
    }

    pub fn add(self: *ControlBlock, key: usize) ?*Block {
        const block = self.makeBlock(key) orelse return null;

        {
            self.hash_lock.lock();
            defer self.hash_lock.unlock();

            self.hash_table.add(block);
        }

        block.lock();
        return block;
    }

    fn swap(self: *ControlBlock, target_num: u32) u32 {
        self.lru_lock.lock();
        defer self.lru_lock.unlock();

        const num = target_num;
        var node = self.lru_list.first;
        while (node) |n| : (node = n.next) {
            if (num >= target_num) break;
        }

        return num;
    }

    fn makeBlock(self: *ControlBlock, key: usize) ?*Block {
        const block = self.block_oma.alloc(Block) orelse return null;
        const phys = vm.PageAllocator.alloc(block_rank) orelse {
            self.block_oma.free(block);
            return null;
        };

        block.* = .{
            .phys_base = @truncate(phys / block_size),
            .lba_key = key
        };
        return block;
    }

    //fn freeBlocks(self: *ControlBlock, first: *LruNode) void {
    //    self.node_oma.lock.lock();
    //    defer self.node_oma.lock.unlock();
    //
    //    vm.PageAllocator.free(node.data.data.getPhysBase(), block_rank);
    //}

    inline fn track(self: *ControlBlock, block: *Block) void {
        self.lru_list.prepend(&block.lru_node);
        total_blocks += 1;
    }

    inline fn untrack(self: *ControlBlock, block: *Block) void {
        self.lru_list.remove(&block.lru_node);
        total_blocks -= 1;
    }

    inline fn fromNode(node: *List.Node) *ControlBlock {
        return @fieldParentPtr("node", node);
    }
};

var total_blocks: u32 = 0;

var ctrl_lock = utils.Spinlock.init(.unlocked);
var ctrl_list: ControlBlock.List = .{};

pub fn makeCtrl() Error!*ControlBlock {
    const ctrl = vm.auto.alloc(ControlBlock) orelse return error.NoMemory;
    errdefer vm.auto.free(ControlBlock, ctrl);

    ctrl.* = try .init();

    ctrl_lock.lock();
    defer ctrl_lock.unlock();

    ctrl_list.append(&ctrl.node);
    return ctrl;
}

pub fn deleteCtrl(ctrl: *ControlBlock) void {
    {
        ctrl_lock.lock();
        defer ctrl_lock.unlock();

        ctrl_list.remove(&ctrl.node);
    }

    ctrl.deinit();
    vm.auto.free(ControlBlock, ctrl);
}

pub fn swap(target_num: u32) u32 {
    var num = 0;

    {
        ctrl_lock.lock();
        defer ctrl_lock.unlock();

        const node = ctrl_list.first;
        while (node) |n| : (node = n.next) {
            const ctrl = ControlBlock.fromNode(n);
            num += ctrl.swap(target_num);

            if (num >= target_num) break;
        }
    }

    return num;
}

pub inline fn offsetToBlock(offset: usize) usize {
    return offset / block_size;
}

pub inline fn offsetModBlock(offset: usize) usize {
    return offset % block_size;
}

pub inline fn blockToOffset(block: usize) usize {
    return block * block_size;
}

/// Returns the total number of cache pages.
pub inline fn getTotalPages() u32 {
    return total_blocks * block_pages;
}