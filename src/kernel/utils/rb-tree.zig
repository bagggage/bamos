// SPDX-License-Identifier: MIT
// Copyright (c) 2015-2020 Zig Contributors
// This file is part of [zig](https://ziglang.org/), which is MIT licensed.
// The MIT license requires this copyright notice to be included in all copies
// and substantial portions of the software.

const std = @import("std");

const assert = std.debug.assert;
const testing = std.testing;
const Order = std.math.Order;

const Color = enum(u1) {
    Black,
    Red,
};

const Red = Color.Red;
const Black = Color.Black;

const ReplaceError = error{NotEqual};
const SortError = error{NotUnique}; // The new comparison function results in duplicates.

/// Insert this into your struct that you want to add to a red-black tree.
/// Do not use a pointer. Turn the *rb.Node results of the functions in rb
/// (after resolving optionals) to your structure using @fieldParentPtr(). Example:
///
/// const Number = struct {
///     node: rb.Node,
///     value: i32,
/// };
/// fn number(node: *rb.Node) Number {
///     return @fieldParentPtr(Number, "node", node);
/// }
pub const Node = struct {
    left: ?*Node = null,
    right: ?*Node = null,

    /// parent | color
    parent_and_color: usize = 0,

    pub fn next(constnode: *Node) ?*Node {
        var node = constnode;

        if (node.right) |right| {
            var n = right;
            while (n.left) |left| n = left;

            return n;
        }

        while (true) {
            const parent = node.getParent();
            if (parent) |p| {
                if (node != p.right) return p;
                node = p;
            } else {
                return null;
            }
        }
    }

    pub fn prev(constnode: *Node) ?*Node {
        var node = constnode;

        if (node.left) |left| {
            var n = left;
            while (n.right) |right| n = right;

            return n;
        }

        while (true) {
            const parent = node.getParent();
            if (parent) |p| {
                if (node != p.left) return p;
                node = p;
            } else {
                return null;
            }
        }
    }

    pub fn isRoot(node: *Node) bool {
        return node.getParent() == null;
    }

    fn isRed(node: *Node) bool {
        return node.getColor() == Red;
    }

    fn isBlack(node: *Node) bool {
        return node.getColor() == Black;
    }

    fn setParent(node: *Node, parent: ?*Node) void {
        node.parent_and_color = @intFromPtr(parent) | (node.parent_and_color & 1);
    }

    fn getParent(node: *Node) ?*Node {
        const mask: usize = 1;
        comptime { assert(@alignOf(*Node) >= 2); }
        const maybe_ptr = node.parent_and_color & ~mask;
        return if (maybe_ptr == 0) null else @ptrFromInt(maybe_ptr);
    }

    fn setColor(node: *Node, color: Color) void {
        const mask: usize = 1;
        node.parent_and_color = (node.parent_and_color & ~mask) | @intFromEnum(color);
    }

    fn getColor(node: *Node) Color {
        return @enumFromInt(@as(u1, @intCast(node.parent_and_color & 1)));
    }

    fn setChild(node: *Node, child: ?*Node, is_left: bool) void {
        if (is_left) {
            node.left = child;
        } else {
            node.right = child;
        }
    }

    fn getFirst(node_const: *Node) *Node {
        var node = node_const;
        while (node.left) |left| node = left;

        return node;
    }

    fn getLast(node_const: *Node) *Node {
        var node = node_const;
        while (node.right) |right| node = right;

        return node;
    }
};

pub fn Tree(compareFn: fn (*Node, *Node, ?*Node) Order) type {
    return struct {
        pub const NodeType = Node;

        const Self = @This();

        root: ?*Node = null,

        /// Re-sorts a tree with a new compare function.
        pub fn sort(tree: *Self, comptime newCompareFn: fn (*Node, *Node, ?*Node) Order) SortError!Tree(newCompareFn) {
            var newTree: Tree(newCompareFn) = .{};
            var node: *Node = undefined;

            while (true) {
                node = tree.first() orelse break;
                tree.remove(node);

                if (newTree.insert(node) != null) return error.NotUnique;
            }

            return newTree;
        }

        /// If you have a need for a version that caches this, please file a bug.
        pub fn first(tree: *const Self) ?*Node {
            var node: *Node = tree.root orelse return null;
            while (node.left) |left| node = left;

            return node;
        }

        pub fn last(tree: *const Self) ?*Node {
            var node: *Node = tree.root orelse return null;
            while (node.right) |right| node = right;

            return node;
        }

        /// Duplicate keys are not allowed. The item with the same key already in the
        /// tree will be returned, and the item will not be inserted.
        pub fn insert(tree: *Self, node_const: *Node) ?*Node {
            var node = node_const;
            var maybe_key: ?*Node = undefined;
            var maybe_parent: ?*Node = undefined;
            var is_left: bool = undefined;

            maybe_key = doLookup(node, tree, &maybe_parent, &is_left);
            if (maybe_key) |key| return key;

            node.left = null;
            node.right = null;
            node.setColor(Red);
            node.setParent(maybe_parent);

            if (maybe_parent) |parent| {
                parent.setChild(node, is_left);
            } else {
                tree.root = node;
            }

            while (node.getParent()) |p| {
                var parent = p;

                if (parent.isBlack()) break;
                // the root is always black
                var grandpa = parent.getParent() orelse unreachable;

                if (parent == grandpa.left) {
                    const maybe_uncle = grandpa.right;

                    if (maybe_uncle) |uncle| {
                        if (uncle.isBlack()) break;

                        parent.setColor(Black);
                        uncle.setColor(Black);
                        grandpa.setColor(Red);
                        node = grandpa;
                    } else {
                        if (node == parent.right) {
                            rotateLeft(parent, tree);
                            node = parent;
                            parent = node.getParent().?; // Just rotated
                        }

                        parent.setColor(Black);
                        grandpa.setColor(Red);
                        rotateRight(grandpa, tree);
                    }
                } else {
                   const maybe_uncle = grandpa.left;

                    if (maybe_uncle) |uncle| {
                        if (uncle.isBlack()) break;

                        parent.setColor(Black);
                        uncle.setColor(Black);
                        grandpa.setColor(Red);
                        node = grandpa;
                    } else {
                        if (node == parent.left) {
                            rotateRight(parent, tree);
                            node = parent;
                            parent = node.getParent().?; // Just rotated
                        }
                        parent.setColor(Black);
                        grandpa.setColor(Red);
                        rotateLeft(grandpa, tree);
                    }
                }
            }
            // This was an insert, there is at least one node.
            tree.root.?.setColor(Black);
            return null;
        }

        /// lookup searches for the value of key, using binary search. It will
        /// return a pointer to the node if it is there, otherwise it will return null.
        /// Complexity guaranteed O(log n), where n is the number of nodes book-kept
        /// by tree.
        pub fn lookup(tree: *const Self, key: *Node) ?*Node {
            var parent: ?*Node = undefined;
            var is_left: bool = undefined;
            return doLookup(key, tree, &parent, &is_left);
        }

        /// If node is not part of tree, behavior is undefined.
        pub fn remove(tree: *Self, node_const: *Node) void {
            var node = node_const;
            // as this has the same value as node, it is unsafe to access node after newnode
            var new_node: ?*Node = node_const;
            var maybe_parent: ?*Node = node.getParent();
            var color: Color = undefined;
            var next: *Node = undefined;

            // This clause is to avoid optionals
            if (node.left == null and node.right == null) {
                if (maybe_parent) |parent| {
                    parent.setChild(null, parent.left == node);
                } else {
                    tree.root = null;
                }
                color = node.getColor();
                new_node = null;
            } else {
                if (node.left == null) {
                    next = node.right.?; // Not both null as per above
                } else if (node.right == null) {
                    next = node.left.?; // Not both null as per above
                } else {
                    next = node.right.?.getFirst(); // Just checked for null above
                }

                if (maybe_parent) |parent| {
                    parent.setChild(next, parent.left == node);
                } else {
                    tree.root = next;
                }

                if (node.left != null and node.right != null) {
                    const left = node.left.?;
                    const right = node.right.?;

                    color = next.getColor();
                    next.setColor(node.getColor());

                    next.left = left;
                    left.setParent(next);

                    if (next != right) {
                        var parent = next.getParent().?; // Was traversed via child node (right/left)
                        next.setParent(node.getParent());

                        new_node = next.right;
                        parent.left = node;

                        next.right = right;
                        right.setParent(next);
                    } else {
                        next.setParent(maybe_parent);
                        maybe_parent = next;
                        new_node = next.right;
                    }
                } else {
                    color = node.getColor();
                    new_node = next;
                }
            }

            if (new_node) |n| n.setParent(maybe_parent);

            if (color == Red) return;

            if (new_node) |n| {
                n.setColor(Black);
                return;
            }

            while (node == tree.root) {
                // If not root, there must be parent
                var parent = maybe_parent.?;
                if (node == parent.left) {
                    var sibling = parent.right.?; // Same number of black nodes.

                    if (sibling.isRed()) {
                        sibling.setColor(Black);
                        parent.setColor(Red);
                        rotateLeft(parent, tree);
                        sibling = parent.right.?; // Just rotated
                    }
                    if ((if (sibling.left) |n| n.isBlack() else true) and
                        (if (sibling.right) |n| n.isBlack() else true))
                    {
                        sibling.setColor(Red);
                        node = parent;
                        maybe_parent = parent.getParent();
                        continue;
                    }
                    if (if (sibling.right) |n| n.isBlack() else true) {
                        sibling.left.?.setColor(Black); // Same number of black nodes.
                        sibling.setColor(Red);
                        rotateRight(sibling, tree);
                        sibling = parent.right.?; // Just rotated
                    }
                    sibling.setColor(parent.getColor());
                    parent.setColor(Black);
                    sibling.right.?.setColor(Black); // Same number of black nodes.
                    rotateLeft(parent, tree);
                    new_node = tree.root;
                    break;
                } else {
                    var sibling = parent.left.?; // Same number of black nodes.

                    if (sibling.isRed()) {
                        sibling.setColor(Black);
                        parent.setColor(Red);
                        rotateRight(parent, tree);
                        sibling = parent.left.?; // Just rotated
                    }
                    if ((if (sibling.left) |n| n.isBlack() else true) and
                        (if (sibling.right) |n| n.isBlack() else true))
                    {
                        sibling.setColor(Red);
                        node = parent;
                        maybe_parent = parent.getParent();
                        continue;
                    }
                    if (if (sibling.left) |n| n.isBlack() else true) {
                        sibling.right.?.setColor(Black); // Same number of black nodes
                        sibling.setColor(Red);
                        rotateLeft(sibling, tree);
                        sibling = parent.left.?; // Just rotated
                    }
                    sibling.setColor(parent.getColor());
                    parent.setColor(Black);
                    sibling.left.?.setColor(Black); // Same number of black nodes
                    rotateRight(parent, tree);
                    new_node = tree.root;
                    break;
                }

                if (node.isRed()) break;
            }

            if (new_node) |n| n.setColor(Black);
        }

        /// This is a shortcut to avoid removing and re-inserting an item with the same key.
        pub fn replace(tree: *Self, old: *Node, new: *Node) void {
            // I assume this can get optimized out if the caller already knows.
            // if (compareFn(old, new, tree.root) != .eq) return ReplaceError.NotEqual;

            if (old.getParent()) |parent| {
                parent.setChild(new, parent.left == old);
            } else {
                tree.root = new;
            }

            if (old.left) |left| left.setParent(new);
            if (old.right) |right| right.setParent(new);

            new.* = old.*;
        }

        fn rotateLeft(node: *Node, tree: *Self) void {
            var p: *Node = node;
            var q: *Node = node.right orelse unreachable;
            var parent: *Node = undefined;

            if (!p.isRoot()) {
                parent = p.getParent().?;
                if (parent.left == p) {
                    parent.left = q;
                } else {
                    parent.right = q;
                }
                q.setParent(parent);
            } else {
                tree.root = q;
                q.setParent(null);
            }
            p.setParent(q);

            p.right = q.left;
            if (p.right) |right| right.setParent(p);

            q.left = p;
        }

        fn rotateRight(node: *Node, tree: *Self) void {
            var p: *Node = node;
            var q: *Node = node.left orelse unreachable;
            var parent: *Node = undefined;

            if (!p.isRoot()) {
                parent = p.getParent().?;
                if (parent.left == p) {
                    parent.left = q;
                } else {
                    parent.right = q;
                }
                q.setParent(parent);
            } else {
                tree.root = q;
                q.setParent(null);
            }
            p.setParent(q);

            p.left = q.right;
            if (p.left) |left| left.setParent(p);

            q.right = p;
        }

        fn doLookup(key: *Node, tree: *const Self, pparent: *?*Node, is_left: *bool) ?*Node {
            var maybe_node: ?*Node = tree.root;

            pparent.* = null;
            is_left.* = false;

            while (maybe_node) |node| {
                const res = compareFn(node, key, tree.root);
                if (res == .eq) return node;

                pparent.* = node;
                switch (res) {
                    .gt => {
                        is_left.* = true;
                        maybe_node = node.left;
                    },
                    .lt => {
                        is_left.* = false;
                        maybe_node = node.right;
                    },
                    .eq => unreachable, // handled above
                }
            }
            return null;
        }
    };
}

const TestNumber = struct {
    node: Node,
    value: usize,
};

fn testGetNumber(node: *Node) *TestNumber {
    return @fieldParentPtr("node", node);
}

fn testCompare(l: *Node, r: *Node, _: ?*Node) Order {
    const left = testGetNumber(l);
    const right = testGetNumber(r);

    if (left.value < right.value) {
        return .lt;
    } else if (left.value == right.value) {
        return .eq;
    }

    return .gt;
}

fn testCompareReverse(l: *Node, r: *Node, _: ?*Node) Order {
    return testCompare(r, l, undefined);
}

test "rb" {
    var tree: Tree(testCompare) = .{};
    var ns: [10]TestNumber = undefined;

    ns[0].value = 42;
    ns[1].value = 41;
    ns[2].value = 40;
    ns[3].value = 39;
    ns[4].value = 38;
    ns[5].value = 39;
    ns[6].value = 3453;
    ns[7].value = 32345;
    ns[8].value = 392345;
    ns[9].value = 4;

    var dup: TestNumber = undefined;
    dup.value = 32345;

    _ = tree.insert(&ns[1].node);
    _ = tree.insert(&ns[2].node);
    _ = tree.insert(&ns[3].node);
    _ = tree.insert(&ns[4].node);
    _ = tree.insert(&ns[5].node);
    _ = tree.insert(&ns[6].node);
    _ = tree.insert(&ns[7].node);
    _ = tree.insert(&ns[8].node);
    _ = tree.insert(&ns[9].node);
    tree.remove(&ns[3].node);
    try testing.expect(tree.insert(&dup.node) == &ns[7].node);
    try tree.replace(&ns[7].node, &dup.node);

    var num: *TestNumber = undefined;
    num = testGetNumber(tree.first().?);
    while (num.node.next() != null) {
        try testing.expect(testGetNumber(num.node.next().?).value > num.value);
        num = testGetNumber(num.node.next().?);
    }
}

test "inserting and looking up" {
    var tree: Tree(testCompare) = .{};
    var number: TestNumber = undefined;
    number.value = 1000;
    _ = tree.insert(&number.node);
    var dup: TestNumber = undefined;
    //Assert that tuples with identical value fields finds the same pointer
    dup.value = 1000;
    assert(tree.lookup(&dup.node) == &number.node);
    //Assert that tuples with identical values do not clobber when inserted.
    _ = tree.insert(&dup.node);
    assert(tree.lookup(&dup.node) == &number.node);
    assert(tree.lookup(&number.node) != &dup.node);
    assert(testGetNumber(tree.lookup(&dup.node).?).value == testGetNumber(&dup.node).value);
    //Assert that if looking for a non-existing value, return null.
    var non_existing_value: TestNumber = undefined;
    non_existing_value.value = 1234;
    assert(tree.lookup(&non_existing_value.node) == null);
}

test "multiple inserts, followed by calling first and last" {
    var tree: Tree(testCompare) = .{};
    var zeroth: TestNumber = undefined;
    zeroth.value = 0;
    var first: TestNumber = undefined;
    first.value = 1;
    var second: TestNumber = undefined;
    second.value = 2;
    var third: TestNumber = undefined;
    third.value = 3;
    _ = tree.insert(&zeroth.node);
    _ = tree.insert(&first.node);
    _ = tree.insert(&second.node);
    _ = tree.insert(&third.node);
    assert(testGetNumber(tree.first().?).value == 0);
    assert(testGetNumber(tree.last().?).value == 3);

    var lookupNode: TestNumber = undefined;
    lookupNode.value = 2;
    assert(tree.lookup(&lookupNode.node) == &second.node);

    const new_tree = tree.sort(testCompareReverse) catch unreachable;
    assert(testGetNumber(new_tree.first().?).value == 3);
    assert(testGetNumber(new_tree.last().?).value == 0);
    assert(new_tree.lookup(&lookupNode.node) == &second.node);
}