//! # Read-Copy-Update
//! 
//! Namespace that contains different data structures that implemented
//! with the RCU in mind.

const std = @import("std");

const lib = @import("../lib.zig");
const sched = @import("../sched.zig");
const vm = @import("../vm.zig");

/// Raw implementation of the RCU based on
/// generations.
pub const GenerationBlock = struct {
    lock: lib.sync.Spinlock = .{},

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

/// # RCU Singly-linked list
pub const SinglyLinkedList = struct {
    pub const Node = struct {
        next: ?*Node = null
    };

    ctrl: GenerationBlock = .{},
    head: std.atomic.Value(?*Node) = .init(null),

    pub inline fn prepend(self: *SinglyLinkedList, node: *Node) void {
        self.ctrl.writeLock();
        defer self.ctrl.writeUnlock();

        self.prependRaw(node);
    }

    pub fn prependRaw(self: *SinglyLinkedList, node: *Node) void {
        node.next = self.head.raw;
        self.head.store(node, .release);
        self.ctrl.update();
    }

    pub fn insertAfter(self: *SinglyLinkedList, prev: *Node, node: *Node) void {
        self.ctrl.writeLock();
        defer self.ctrl.writeUnlock();

        node.next = prev.next;
        @atomicStore(?*Node, &prev.next, node, .release);

        self.ctrl.update();
    }

    pub fn popFirst(self: *SinglyLinkedList) ?*Node {
        self.ctrl.writeLock();
        defer self.ctrl.writeUnlock();

        const next = (self.head.raw orelse return null).next;
        const node = self.head.swap(next, .unordered);

        self.ctrl.updateSync();
        return node;
    }

    pub fn remove(self: *SinglyLinkedList, node: *Node) ?*Node {
        self.ctrl.writeLock();
        defer self.ctrl.writeUnlock();

        var prev: ?*Node = null;
        var temp = self.head.load(.acquire);
        while (temp) |n| : ({ prev = temp; temp = n.next; }) {
            if (n != node) continue;

            if (prev) |p| {
                @atomicStore(?*Node, &p.next, n.next, .release);
            } else {
                self.head.store(null, .release);
            }

            self.ctrl.updateSync();
            return n;
        }

        return null;
    }

    pub fn removeAfter(self: *SinglyLinkedList, prev: *Node) ?*Node {
        self.ctrl.writeLock();
        defer self.ctrl.writeUnlock();

        const node = prev.next orelse return null;
        @atomicStore(?*Node, &prev.next, node.next, .release);

        self.ctrl.updateSync();
        return node;
    }

    pub fn clear(self: *SinglyLinkedList) ?*Node {
        self.ctrl.writeLock();
        defer self.ctrl.writeUnlock();

        const head = self.head.swap(null, .release);

        self.ctrl.updateSync();
        return head;
    }
};

/// # RCU Doubly-linked list
pub const DoublyLinkedList = struct {
    pub const Node = struct {
        next: ?*Node = null,
        prev: ?*Node = null,

        pub inline fn asLinkedListNode(self: *Node) *std.DoublyLinkedList.Node {
            comptime {
                const StdNode = std.DoublyLinkedList.Node;
                std.debug.assert(@offsetOf(Node, "next") == @offsetOf(StdNode, "next"));
                std.debug.assert(@offsetOf(Node, "prev") == @offsetOf(StdNode, "prev"));
            }
            return @ptrCast(self);
        }
    };

    ctrl: GenerationBlock = .{},
    first: std.atomic.Value(?*Node) = .init(null),
    last: std.atomic.Value(?*Node) = .init(null),

    pub fn append(self: *DoublyLinkedList, node: *Node) void {
        self.ctrl.writeLock();
        defer self.ctrl.writeUnlock();

        self.appendRaw(node);
    }

    pub fn appendRaw(self: *DoublyLinkedList, node: *Node) void {
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

    pub fn prepend(self: *DoublyLinkedList, node: *Node) void {
        self.ctrl.writeLock();
        defer self.ctrl.writeUnlock();

        self.prependRaw(node);
    }

    pub fn prependRaw(self: *DoublyLinkedList, node: *Node) void {
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

    pub fn insertAfter(self: *DoublyLinkedList, prev: *Node, node: *Node) void {
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

    pub fn insertBefore(self: *DoublyLinkedList, next: *Node, node: *Node) void {
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

    pub fn popFirst(self: *DoublyLinkedList) ?*Node {
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

    pub fn popLast(self: *DoublyLinkedList) ?*Node {
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

    pub fn remove(self: *DoublyLinkedList, node: *Node) void {
        self.ctrl.writeLock();
        defer self.ctrl.writeUnlock();

        self.removeRaw(node);
    }

    pub fn removeRaw(self: *DoublyLinkedList, node: *Node) void {
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

    pub fn clear(self: *DoublyLinkedList) ?*Node {
        self.ctrl.writeLock();
        defer self.ctrl.writeUnlock();

        const head = self.first.swap(null, .release);
        self.last.store(null, .release);

        self.ctrl.updateSync();
        return head;
    }
};
