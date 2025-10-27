//! # Read-Copy-Update
//! 
//! Namespace that contains different data structures that implemented
//! with the RCU in mind.

const std = @import("std");

const sched = @import("../sched.zig");
const utils = @import("../utils.zig");
const vm = @import("../vm.zig");

const list = std.SinglyLinkedList(u8);

/// Raw implementation of the RCU based on
/// generations.
pub const GenerationBlock = struct {
    lock: utils.Spinlock = .{},

    gen_counters: [2]std.atomic.Value(u16) = .{ std.atomic.Value(u16).init(0) } ** 2,
    generation: std.atomic.Value(u8) = .init(0),

    pub fn readLock(self: *GenerationBlock) u16 {
        @setRuntimeSafety(false);

        sched.getCurrent().disablePreemption();
        const curr_gen = self.generation.load(.acquire);
        _ = self.gen_counters[curr_gen].fetchAdd(1, .acquire);

        return curr_gen;
    }

    pub fn readUnlock(self: *GenerationBlock, gen: u16) void {
        _ = self.gen_counters[gen].fetchSub(1, .release);
        sched.getCurrent().enablePreemption();
    }

    pub inline fn writeLock(self: *GenerationBlock) void {
        self.lock.lock();
    }

    pub inline fn writeUnlock(self: *GenerationBlock) void {
        self.lock.unlock();
    }

    pub inline fn update(self: *GenerationBlock) void {
        _ = self.generation.fetchXor(1, .release);
    }

    pub fn synchronize(self: *GenerationBlock) void {
        const curr_gen = self.generation.raw ^ 1;
        while (self.gen_counters[curr_gen].load(.acquire) > 0) {
            std.atomic.spinLoopHint();
        }
    }

    pub fn updateSync(self: *GenerationBlock) void {
        const curr_gen = self.generation.fetchXor(1, .release);
        while (self.gen_counters[curr_gen].load(.acquire) > 0) {
            std.atomic.spinLoopHint();
        }
    }
};

/// # RCU Single-linked list
pub const SList = struct {
    pub const Node = struct {
        next: ?*Node = null
    };

    ctrl: GenerationBlock = .{},
    head: std.atomic.Value(?*Node) = .init(null),

    pub inline fn prepend(self: *SList, node: *Node) void {
        self.ctrl.writeLock();
        defer self.ctrl.writeUnlock();

        self.prependRaw(node);
    }

    pub fn prependRaw(self: *SList, node: *Node) void {
        node.next = self.head.raw;
        self.head.store(node, .release);
        self.ctrl.update();
    }

    pub fn insertAfter(self: *SList, prev: *Node, node: *Node) void {
        self.ctrl.writeLock();
        defer self.ctrl.writeUnlock();

        node.next = prev.next;
        @atomicStore(?*Node, &prev.next, node, .release);

        self.ctrl.update();
    }

    pub fn popFirst(self: *SList) ?*Node {
        self.ctrl.writeLock();
        defer self.ctrl.writeUnlock();

        const next = (self.head.raw orelse return null).next;
        const node = self.head.swap(next, .unordered);

        self.ctrl.updateSync();
        return node;
    }

    pub fn removeAfter(self: *SList, prev: *Node) ?*Node {
        self.ctrl.writeLock();
        defer self.ctrl.writeUnlock();

        const node = prev.next orelse return null;
        @atomicStore(?*Node, &prev.next, node.next, .release);

        self.ctrl.updateSync();
        return node;
    }

    pub fn clear(self: *SList) ?*Node {
        self.ctrl.writeLock();
        defer self.ctrl.writeUnlock();

        const head = self.head.swap(null, .release);

        self.ctrl.updateSync();
        return head;
    }
};

/// # RCU Double-linked list
pub const List = struct {
    pub const Node = struct {
        next: ?*Node = null,
        prev: ?*Node = null
    };

    ctrl: GenerationBlock = .{},
    first: std.atomic.Value(?*Node) = .init(null),
    last: std.atomic.Value(?*Node) = .init(null),

    pub fn append(self: *List, node: *Node) void {
        self.ctrl.writeLock();
        defer self.ctrl.writeUnlock();

        self.appendRaw(node);
    }

    pub fn appendRaw(self: *List, node: *Node) void {
        const last = self.last.raw;
        node.prev = last;
        node.next = null;

        if (last) |l| {
            // last.next = node;
            @atomicStore(?*Node, &l.next, node, .release);
            self.last.store(node, .release);
        } else {
            self.first.store(node, .release);
            self.last.store(node, .release);
        }

        self.ctrl.update();
    }

    pub fn prepend(self: *List, node: *Node) void {
        self.ctrl.writeLock();
        defer self.ctrl.writeUnlock();

        self.prependRaw(node);
    }

    pub fn prependRaw(self: *List, node: *Node) void {
        const first = self.first.raw;
        node.next = first;
        node.prev = null;

        if (first) |f| {
            // first.prev = node;
            @atomicStore(?*Node, &f.prev, node, .release);
            self.first.store(node, .release);
        } else {
            self.first.store(node, .release);
            self.last.store(node, .release);
        }

        self.ctrl.update();
    }

    pub fn insertAfter(self: *List, prev: *Node, node: *Node) void {
        self.ctrl.writeLock();
        defer self.ctrl.writeUnlock();

        const next = prev.next;
        node.next = next;
        node.prev = prev;
        if (next) |n| {
            // prev.next = node;
            // next.prev = node;
            @atomicStore(?*Node, &prev.next, node, .release);
            @atomicStore(?*Node, &n.prev, node, .release);
        } else {
            // prev.next = node;
            @atomicStore(?*Node, &prev.next, node, .release);
            self.last.store(node,.release);
        }

        self.ctrl.update();
    }

    pub fn insertBefore(self: *List, next: *Node, node: *Node) void {
                self.ctrl.writeLock();
        defer self.ctrl.writeUnlock();

        const prev = next.prev;
        node.next = next;
        node.prev = prev;
        if (prev) |p| {
            // prev.next = node;
            // next.prev = node;
            @atomicStore(?*Node, &p.next, node, .release);
            @atomicStore(?*Node, &next.prev, node, .release);
        } else {
            self.first.store(node,.release);
            // next.prev = node;
            @atomicStore(?*Node, &next.prev, node, .release);
        }

        self.ctrl.update();
    }

    pub fn popFirst(self: *List) ?*Node {
        @setRuntimeSafety(false);

        self.ctrl.writeLock();
        defer self.ctrl.writeUnlock();

        const next = (self.first.raw orelse return null).next;
        const node = if (next) |n| blk: {
            const node = self.first.swap(next, .release);
            // next.prev = null;
            @atomicStore(?*Node, &n.prev, null, .release);
            break :blk node;
        } else blk: {
            const node = self.first.swap(null, .release);
            self.last.store(null, .release);
            break :blk node;
        };

        self.ctrl.updateSync();
        return node;
    }

    pub fn popLast(self: *List) ?*Node {
        @setRuntimeSafety(false);

        self.ctrl.writeLock();
        defer self.ctrl.writeUnlock();

        const prev = (self.last.raw orelse return null).prev;
        const node = if (prev) |p| blk: {
            const node = self.last.swap(prev, .release);
            // prev.next = null;
            @atomicStore(?*Node, &p.next, null, .release);
            break :blk node;
        } else blk: {
            self.first.store(null, .release);
            break :blk self.last.swap(null, .release);
        };

        self.ctrl.updateSync();
        return node;
    }

    pub fn remove(self: *List, node: *Node) void {
        self.ctrl.writeLock();
        defer self.ctrl.writeUnlock();
        defer {
            self.ctrl.updateSync();
            node.* = .{};
        }

        if (self.first.raw == node) {
            if (self.last.raw == node) {
                self.first.store(null, .release);
                self.last.store(null, .release);
                return;
            }

            const next = node.next.?;
            self.first.store(next, .release);
            @atomicStore(?*Node, &next.prev, null, .release);
        } else if (self.last.raw == node) {
            const prev = node.prev.?;
            @atomicStore(?*Node, &prev.next, null, .release);
            self.last.store(prev, .release);
        } else {
            const next = node.next.?;
            const prev = node.prev.?;
            @atomicStore(?*Node, &prev.next, next, .release);
            @atomicStore(?*Node, &next.prev, prev, .release);
        }
    }

    pub fn clear(self: *List) ?*Node {
        self.ctrl.writeLock();
        defer self.ctrl.writeUnlock();

        const head = self.first.swap(null, .release);
        self.last.store(null, .release);

        self.ctrl.updateSync();
        return head;
    }
};