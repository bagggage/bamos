//! # Atomic data structures
//! 
//! Lock-free data structures that are built on atomic instructions and guarantee
//! atomic execution of declared operations.
//! The implementation may have a slight overhead compared to non-atomic ones.

const std = @import("std");

const sched = @import("../sched.zig");
const utils = @import("../utils.zig");

pub const SList = SinglyLinkedList;

pub const SinglyLinkedList = struct {
    pub const Node = std.SinglyLinkedList.Node;

    first: std.atomic.Value(?*Node) = .init(null),

    pub fn popFirst(self: *SinglyLinkedList) ?*Node {
        sched.getCurrent().disablePreemption();
        defer sched.getCurrent().enablePreemptionNoResched();

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