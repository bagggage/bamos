//! # Cache subsystem **DRAFT**

// Copyright (C) 2024 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const utils = @import("../utils.zig");
const vm = @import("../vm.zig");

pub const block_size = 16 * utils.kb_size;
pub const block_pages = block_size / vm.page_size;
pub const block_rank = std.math.log2_int(u32, block_pages);

pub const Error = error {
    NoMemory
};

pub const Block = packed struct {
    phys_base: u28 = 0,
    ref_count: u4 = 0,

    lba_key: u32 = 0,

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
        return self.ref_count != 0;
    }

    pub inline fn lock(self: *Block) void {
        self.ref_count += 1;
    }

    pub inline fn release(self: *Block) void {
        self.ref_count -= 1;
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
    pub const Node = extern struct {
        data: Block,
        next: ?*Node = null,
        prev: ?*Node = null,
    };

    const PageList = utils.SList(Page);
    const PageNode = PageList.Node;

    const Page = struct {
        base: u32,
        rank: u8 = 0,

        pub inline fn getPhysBase(self: Page) usize {
            return @as(usize, self.base) * vm.page_size;
        }
    };

    const Bucket = struct {
        head: ?*Node = null,
        tail: ?*Node = null,

        pub fn push(self: *Bucket, node: *Node) void {
            if (self.tail) |tail| {
                tail.next = node;
                self.tail = node;
            } else {
                self.head = node;
                self.tail = node;
                node.prev = null;
            }

            node.next = null;
        }

        pub fn remove(self: *Bucket, node: *Node) void {
            if (self.head == node) {
                if (self.tail == node) {
                    self.head = null;
                    self.tail = null;
                    return;
                }

                self.head = node.next;
                node.next.?.prev = null;
            } else if (self.tail == node) {
                self.tail = node.prev;
                node.prev.?.next = null;
            } else {
                node.next.?.prev = node.prev;
                node.prev.?.next = node.next;
            }
        }

        pub fn get(self: *const Bucket, key: u32) ?*Node {
            var node = self.head;

            while (node) |n| : (node = n.next) {
                if (n.data.lba_key == key) return n;
            }

            return null;
        }
    };

    const initial_capacity = 512;
    const initial_pages = std.math.divCeil(comptime_int, initial_capacity * @sizeOf(Bucket), vm.page_size) catch unreachable;
    const initial_rank = std.math.log2_int_ceil(u8, initial_pages);
    const virt_pages = (64 * utils.mb_size) / vm.page_size;

    var page_oma = vm.SafeOma(PageNode).init(128);

    pages: PageList = .{},
    buckets: []Bucket = &.{},

    pub fn init(self: *HashTable) Error!void {
        std.debug.assert(self.buckets.len == 0);

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
    }

    pub fn deinit(self: *HashTable) void {
        vm.heapRelease(@intFromPtr(self.buckets.ptr), virt_pages);

        while (self.pages.first != null) self.freePages();
    }

    pub fn add(self: *HashTable, entry: *Node) void {
        const idx = entry.data.lba_key % self.buckets.len;
        self.buckets[idx].push(entry);
    }

    pub fn remove(self: *HashTable, entry: *Node) void {
        const idx = entry.data.lba_key % self.buckets.len;
        self.buckets[idx].remove(entry);
    }

    pub fn get(self: *const HashTable, key: u32) ?*Node {
        const idx = key % self.buckets.len;
        return self.buckets[idx].get(key);
    }

    fn allocPages(self: *HashTable, rank: u8) Error!usize {
        const page_node = page_oma.alloc() orelse return error.NoMemory;
        errdefer page_oma.free(page_node);

        const phys = vm.PageAllocator.alloc(rank) orelse return error.NoMemory;
    
        page_node.data.base = @truncate(phys / vm.page_size);
        page_node.data.rank = rank;

        self.pages.prepend(page_node);

        return phys;
    }

    fn freePages(self: *HashTable) void {
        const page_node = self.pages.popFirst() orelse unreachable;

        vm.PageAllocator.free(page_node.data.getPhysBase(), page_node.data.rank);
        page_oma.free(page_node);
    }
};

pub const ControlBlock = struct {
    const LruList = utils.List(HashTable.Node);
    const LruNode = LruList.Node;
    const NodeOma = vm.SafeOma(LruNode);

    hash_table: HashTable = .{},
    hash_lock: utils.Spinlock = utils.Spinlock.init(.unlocked),

    lru_list: LruList = .{},
    lru_lock: utils.Spinlock = utils.Spinlock.init(.unlocked),

    node_oma: NodeOma = NodeOma.init(256),

    pub inline fn init(self: *ControlBlock) Error!void {
        self.* = .{};
        try self.hash_table.init();
    }

    pub fn deinit(self: *ControlBlock) void {
        self.hash_table.deinit();
        self.node_oma.deinit();
    }

    pub fn get(self: *ControlBlock, key: u32) ?*Block {
        self.lru_lock.lock();
        self.hash_lock.lock();
        defer self.lru_lock.unlock();
        defer self.hash_lock.unlock();

        const node = self.hash_table.get(key) orelse return null;

        if (!node.data.isLocked()) self.untrack(&node.data);
        node.data.lock();

        return &node.data;
    }

    pub fn put(self: *ControlBlock, block: *Block) void {
        self.lru_lock.lock();
        defer self.lru_lock.unlock();

        block.release();
        if (!block.isLocked()) self.track(block);
    }

    pub fn new(self: *ControlBlock, key: u32) ?*Block {
        const block = self.allocBlock() orelse return null;
        block.data.data.lba_key = key;

        {
            self.hash_lock.lock();
            defer self.hash_lock.unlock();

            self.hash_table.add(&block.data);
        }

        block.data.data.lock();
        return &block.data.data;
    }

    fn swap(self: *ControlBlock, target_num: u32) u32 {
        self.lru_lock.lock();
        defer self.lru_lock.unlock();

        const num = target_num;
        var node = self.lru_list.first;

        while (node) |lru| : (node = lru.node) {

            if (num >= target_num) break;
        }

        return num;
    }

    fn allocBlock(self: *ControlBlock) ?*LruNode {
        const node = self.node_oma.alloc() orelse return null;
        const entry = &node.data;

        const phys = vm.PageAllocator.alloc(block_rank) orelse {
            self.node_oma.free(node);
            return null;
        };

        entry.data.phys_base = @truncate(phys / block_size);
        entry.data.ref_count = 0;

        return node;
    }

    //fn freeBlocks(self: *ControlBlock, first: *LruNode) void {
    //    self.node_oma.lock.lock();
    //    defer self.node_oma.lock.unlock();
//
    //    vm.PageAllocator.free(node.data.data.getPhysBase(), block_rank);
    //}

    inline fn track(self: *ControlBlock, block: *Block) void {
        const node = getLruNode(block);
        self.lru_list.prepend(node);
        total_blocks += 1;
    }

    inline fn untrack(self: *ControlBlock, block: *Block) void {
        const node = getLruNode(block);
        self.lru_list.remove(node);
        total_blocks -= 1;
    }

    inline fn getLruNode(block: *Block) *LruNode {
        const hash_node: *HashTable.Node = @alignCast(@fieldParentPtr("data", block));
        const lru_node: *LruNode = @fieldParentPtr("data", hash_node);

        return lru_node;
    }
};

const CtrlList = utils.List(ControlBlock);
const CtrlNode = CtrlList.Node;
const CtrlOma = vm.SafeOma(CtrlNode);

var total_blocks: u32 = 0;

var ctrl_lock = utils.Spinlock.init(.unlocked);
var ctrl_list: CtrlList = .{};
var ctrl_oma = CtrlOma.init(32);

pub fn newCtrl() Error!*ControlBlock {
    const node = ctrl_oma.alloc() orelse return error.NoMemory;
    errdefer ctrl_oma.free(node);

    try node.data.init();

    ctrl_lock.lock();
    defer ctrl_lock.unlock();

    ctrl_list.append(node);

    return &node.data;
}

pub fn deleteCtrl(ctrl: *ControlBlock) void {
    const node: *CtrlNode = @fieldParentPtr("data", ctrl);

    {
        ctrl_lock.lock();
        defer ctrl_lock.unlock();

        ctrl_list.remove(node);
    }

    node.data.deinit();
    ctrl_oma.free(node);
}

pub fn swap(target_num: u32) u32 {
    var num = 0;

    {
        ctrl_lock.lock();
        defer ctrl_lock.unlock();

        const node = ctrl_list.first;

        while (node) |ctrl| : (node = ctrl.next) {
            num += ctrl.data.swap(target_num);

            if (num >= target_num) break;
        }
    }

    return num;
}

pub inline fn offsetToBlock(offset: usize) u32 {
    return @truncate(offset / block_size);
}

pub inline fn offsetModBlock(offset: usize) u32 {
    return @truncate(offset % block_size);
}

pub inline fn blockToOffset(block: u32) usize {
    return @as(usize, block) * block_size;
}

/// Returns the total number of cache pages.
pub inline fn getTotalPages() u32 {
    return total_blocks * block_pages;
}