//! # Atomic data structures
//! 
//! Lock-free data structures that are built on atomic instructions and guarantee
//! atomic execution of declared operations.
//! The implementation may have a slight overhead compared to non-atomic ones.

// Copyright (C) 2024-2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const sched = @import("../sched.zig");

pub fn RefCount(comptime UintType: type) type {
    comptime {
        const uint_type = @typeInfo(UintType);
        if (uint_type != .int or uint_type.int.signedness != .unsigned) {
            @compileError("`UintType` must be unsigned integer, e.g. `u8`,`u16`,`u32` etc.");
        }
    }

    return struct {
        const Self = @This();

        value: std.atomic.Value(UintType) = .{ .raw = 0 },

        pub inline fn init(value: UintType) Self {
            return .{ .value = .{ .raw = value } };
        }

        pub inline fn set(self: *Self, value: UintType) void {
            self.value.store(value, .acquire);
        }

        pub inline fn get(self: *Self) bool {
            var old = self.count();
            while (true) {
                if (old == 0) return false;
                if (self.value.cmpxchgWeak(
                    old, old + 1,
                    .release, .acquire)
                ) |new_old| {
                    old = new_old; continue;
                }

                return true;
            }

            unreachable;
        }

        pub inline fn put(self: *Self) bool {
            // release ensures code before put() happens-before the
            // count is decremented as dropFn could be called by then.
            if (self.value.fetchSub(1, .release) == 1) {
                // seeing 1 in the counter means that other put()s have happened,
                // but it doesn't mean that uses before each put() are visible.
                // The load acquires the release-sequence created by previous put()s
                // in order to ensure visibility of uses before dropping.
                _ = self.value.load(.acquire);
                return true;
            }

            return false;
        }

        pub inline fn count(self: *const Self) UintType {
            return self.value.load(.acquire);
        }

        pub inline fn inc(self: *Self) void {
            _ = self.value.fetchAdd(1, .monotonic);
        }

        pub inline fn dec(self: *Self) void {
            _ = self.value.fetchSub(1, .release);
        }
    };
}

pub const SinglyLinkedList = struct {
    pub const Node = std.SinglyLinkedList.Node;

    first: std.atomic.Value(?*Node) = .init(null),

    pub fn popFirst(self: *SinglyLinkedList) ?*Node {
        while (self.first.raw) |node| {
            if (self.first.cmpxchgWeak(node, node.next, .release, .monotonic) == null) {
                return node;
            }
        }

        return null;
    }

    pub fn prepend(self: *SinglyLinkedList, node: *Node) void {
        var first = self.first.raw;
        node.next = first;

        while (self.first.cmpxchgWeak(first, node, .release, .monotonic)) |other| {
            node.next = other;
            first = other;
        }
    }

    pub fn remove(self: *SinglyLinkedList, node: *Node) void {
        sched.getCurrent().disablePreemption();
        defer sched.getCurrent().enablePreemption();

        while (true) {
            // If node is first in a list
            if (self.first.cmpxchgStrong(node, node.next, .release, .monotonic) == null) {
                return;
            }

            var prev_prev: ?*Node = null;
            var prev = self.first.load(.acquire);
            while (prev) |p| : ({ prev_prev = p; prev = @atomicLoad(?*Node, &p.next, .acquire); }) {
                if (p.next != node) continue;

                if (@cmpxchgWeak(?*Node, &p.next, node, node.next, .release, .monotonic) != null) {
                    break;
                }
                if (prev_prev) |pp| {
                    if (@atomicLoad(?*Node, &pp.next, .acquire) != p) break;
                }

                return;
            }
        }
    }
};