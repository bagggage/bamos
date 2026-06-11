// SPDX-License-Identifier: MIT
// Copyright (c) 2015-2020 Zig Contributors
// This file is part of [zig](https://ziglang.org/), which is MIT licensed.
// The MIT license requires this copyright notice to be included in all copies
// and substantial portions of the software.

// Copyright (c) 2025-2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const assert = std.debug.assert;
const testing = std.testing;
const Order = std.math.Order;

const Color = enum(u1) {
    black,
    red,
};

const ReplaceError = error{NotEqual};
const SortError = error{NotUnique}; // The new comparison function results in duplicates.
const ValidateError = error{
    RootIsRed,
    ParentPointerMismatch,
    MissingParentPointer,
    NodeNotInParentChild,
    RedNodeHasRedChild,
    BSTPropertyViolation,
    BlackHeightViolation,
};

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

    pub fn isRed(node: *Node) bool {
        return node.getColor() == .red;
    }

    pub fn isBlack(node: *Node) bool {
        return node.getColor() == .black;
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

pub const CompareFn = fn (lhs: *Node, rhs: *Node, parent: ?*Node) Order;
pub const KeyCompareFn = fn (lhs: *Node, rhs_key: anytype) Order;

pub fn Tree(compareFn: CompareFn, keyCompareFn: KeyCompareFn) type {
    return struct {
        pub const NodeType = Node;

        const Self = @This();

        root: ?*Node = null,

        /// Re-sorts a tree with a new compare function.
        pub fn sort(
            tree: *Self,
            comptime newCompareFn: CompareFn,
            comptime newKeyCompareFn: KeyCompareFn,
        ) SortError!Tree(newCompareFn, newKeyCompareFn) {
            var new_tree: Tree(newCompareFn, newKeyCompareFn) = .{};
            var node: *Node = undefined;

            while (true) {
                node = tree.first() orelse break;
                tree.remove(node);

                if (new_tree.insert(node) != null) return error.NotUnique;
            }

            return new_tree;
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
            node.setColor(.red);
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
                var grandpa = parent.getParent().?;
                if (parent == grandpa.left) {
                    const uncle = grandpa.right;
                    if (uncle != null and uncle.?.getColor() == .red) {
                        parent.setColor(.black);
                        uncle.?.setColor(.black);
                        grandpa.setColor(.red);

                        node = grandpa;
                    } else {
                        if (node == parent.right) {
                            rotateLeft(parent, tree);
                            node = parent;
                            parent = node.getParent().?; // Just rotated
                        }

                        parent.setColor(.black);
                        grandpa.setColor(.red);
                        rotateRight(grandpa, tree);
                    }
                } else {
                    const uncle = grandpa.left;
                    if (uncle != null and uncle.?.getColor() == .red) {
                        parent.setColor(.black);
                        uncle.?.setColor(.black);
                        grandpa.setColor(.red);

                        node = grandpa;
                    } else {
                        if (node == parent.left) {
                            rotateRight(parent, tree);
                            node = parent;
                            parent = node.getParent().?; // Just rotated
                        }

                        parent.setColor(.black);
                        grandpa.setColor(.red);
                        rotateLeft(grandpa, tree);
                    }
                }
            }

            // This was an insert, there is at least one node.
            tree.root.?.setColor(.black);
            return null;
        }

        /// lookup searches for the value of key, using binary search. It will
        /// return a pointer to the node if it is there, otherwise it will return null.
        /// Complexity guaranteed O(log n), where n is the number of nodes book-kept
        /// by tree.
        pub inline fn lookup(tree: *const Self, key: anytype) ?*Node {
            var maybe_node: ?*Node = tree.root;
            while (maybe_node) |node| {
                const res = keyCompareFn(node, key);
                switch (res) {
                    .gt => maybe_node = node.left,
                    .lt => maybe_node = node.right,
                    .eq => return node,
                }
            }

            return null;
        }

        /// This is a shortcut to avoid removing and re-inserting an item with the same key.
        pub fn replace(tree: *Self, old: *Node, new: *Node) void {
            // I assume this can get optimized out if the caller already knows.
            //if (compareFn(old, new, tree.root) != .eq) return ReplaceError.NotEqual;

            if (old.getParent()) |parent| {
                parent.setChild(new, parent.left == old);
            } else {
                tree.root = new;
            }

            if (old.left) |left| left.setParent(new);
            if (old.right) |right| right.setParent(new);

            new.* = old.*;
        }

        pub fn validate(tree: *const Self) ValidateError!usize {
            if (tree.root) |root| {
                if (root.isRed()) return error.RootIsRed;
                return try validateNode(root, null, tree);
            }
            return 0;
        }

        pub fn remove(tree: *Self, node: *Node) void {
            var to_remove = node;
            var replacement = to_remove;
            var replacement_color = replacement.getColor();
            var child: ?*Node = null;
            var child_parent: ?*Node = null;

            // If node has two children, swap with successor
            if (to_remove.left != null and to_remove.right != null) {
                // next returns the successor; it must exist since right is not null
                replacement = to_remove.next().?;
                replacement_color = replacement.getColor();
                // successor may have a right child, but never a left child
                child = replacement.right;
                child_parent = replacement.getParent();

                const y_parent = replacement.getParent().?;
                if (y_parent == to_remove) {
                    child_parent = replacement;
                } else {
                    // transplant y.right to y's current position
                    if (child) |xr| xr.setParent(y_parent);

                    y_parent.setChild(child, y_parent.left == replacement);
                    replacement.right = to_remove.right;

                    if (replacement.right) |yr| yr.setParent(replacement);
                }
                // transplant y to to_remove's position
                tree.replaceParentsChild(to_remove, replacement);
                replacement.left = to_remove.left;

                if (replacement.left) |yl| yl.setParent(replacement);
                replacement.setColor(to_remove.getColor());
            } else {
                // y == node; node with < 2 children
                child = if (to_remove.left != null) to_remove.left else to_remove.right;
                child_parent = to_remove.getParent();

                if (child) |xx| xx.setParent(child_parent);
                tree.replaceParentsChild(to_remove, child);
            }

            // Fixup if necessary
            if (replacement_color == .black) {
                var current = child;
                while ((current == null or current.?.isBlack()) and child_parent != null) {
                    const current_parent = child_parent.?;
                    if (current_parent.left == current) {
                        var sibling = current_parent.right;
                        if (sibling != null and sibling.?.isRed()) {
                            sibling.?.setColor(.black);
                            current_parent.setColor(.red);
                            rotateLeft(current_parent, tree);

                            sibling = current_parent.right;
                        }

                        if (
                            (sibling == null or (sibling.?.left == null or sibling.?.left.?.isBlack())) and
                            (sibling == null or (sibling.?.right == null or sibling.?.right.?.isBlack()))
                        ) {
                            if (sibling) |ww| ww.setColor(.red);

                            current = current_parent;
                            child_parent = current_parent.getParent();
                        } else {
                            if (sibling != null and (sibling.?.right == null or sibling.?.right.?.isBlack())) {
                                const sib = sibling.?;
                                if (sib.left) |sl| sl.setColor(.black);

                                sib.setColor(.red);
                                rotateRight(sib, tree);
                                sibling = current_parent.right;
                            }

                            if (sibling) |sib| {
                                sib.setColor(current_parent.getColor());
                                if (sib.right) |sr| sr.setColor(.black);
                            }

                            current_parent.setColor(.black);
                            rotateLeft(current_parent, tree);

                            current = tree.root;
                            break;
                        }
                    } else {
                        var sibling = current_parent.left;
                        if (sibling != null and sibling.?.isRed()) {
                            sibling.?.setColor(.black);
                            current_parent.setColor(.red);

                            rotateRight(current_parent, tree);
                            sibling = current_parent.left;
                        }

                        if (
                            (sibling == null or (sibling.?.right == null or sibling.?.right.?.isBlack())) and
                            (sibling == null or (sibling.?.left == null or sibling.?.left.?.isBlack()))
                        ) {
                            if (sibling) |sib| sib.setColor(.red);

                            current = current_parent;
                            child_parent = current_parent.getParent();
                        } else {
                            if (sibling != null and (sibling.?.left == null or sibling.?.left.?.isBlack())) {
                                const sib = sibling.?;
                                if (sib.right) |sr| sr.setColor(.black);

                                sib.setColor(.red);
                                rotateLeft(sib, tree);
                                sibling = current_parent.left;
                            }

                            if (sibling) |sib| {
                                sib.setColor(current_parent.getColor());
                                if (sib.left) |sl| sl.setColor(.black);
                            }

                            current_parent.setColor(.black);
                            rotateRight(current_parent, tree);

                            current = tree.root;
                            break;
                        }
                    }
                }

                if (current) |c| c.setColor(.black);
            }
        }

        fn rotateLeft(node: *Node, tree: *Self) void {
            const right_child = node.right.?;

            node.right = right_child.left;
            if (node.right) |right| right.setParent(node);

            tree.replaceParentsChild(node, right_child);

            right_child.left = node;
            node.setParent(right_child);
        }

        fn rotateRight(node: *Node, tree: *Self) void {
            const left_child: *Node = node.left.?;

            node.left = left_child.right;
            if (node.left) |left| left.setParent(node);

            tree.replaceParentsChild(node, left_child);
            
            left_child.right = node;
            node.setParent(left_child);
        }

        fn replaceParentsChild(tree: *Self, old: *Node, new: ?*Node) void {
            if (!old.isRoot()) {
                const parent = old.getParent().?;
                if (parent.left == old) {
                    parent.left = new;
                } else {
                    parent.right = new;
                }
                if (new) |n| n.setParent(parent);
            } else {
                tree.root = new;
                if(new) |n| n.setParent(null);
            }
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

        fn validateNode(node: *Node, parent: ?*Node, tree: *const Self) ValidateError!usize {
            // Verify parent-child relationship consistency
            if (node.getParent()) |node_parent| {
                if (node_parent != parent) return error.ParentPointerMismatch;
            } else {
                if (parent != null) return error.MissingParentPointer;
            }

            // Verify that node's parent correctly references this node as a child
            if (parent) |p| {
                if (p.left != node and p.right != node) return error.NodeNotInParentChild;
            }

            // Root must be black
            if (parent == null and node.isRed()) return error.RootIsRed;

            // Check red-red violation (red node cannot have red children)
            if (node.isRed()) {
                if (node.left) |left| {
                    if (left.isRed()) return error.RedNodeHasRedChild;
                }
                if (node.right) |right| {
                    if (right.isRed()) return error.RedNodeHasRedChild;
                }
            }

            // Validate binary search tree property (direct children only)
            if (node.left) |left| {
                const cmp = compareFn(left, node, tree.root);
                if (cmp != .lt) return error.BSTPropertyViolation;
            }

            if (node.right) |right| {
                const cmp = compareFn(node, right, tree.root);
                if (cmp != .lt) return error.BSTPropertyViolation;
            }

            // Recursively validate subtrees and collect black heights
            var left_black_height: usize = 0;
            var right_black_height: usize = 0;

            if (node.left) |left| {
                left_black_height = try validateNode(left, node, tree);
            } else {
                left_black_height = 1; // Null children count as black
            }

            if (node.right) |right| {
                right_black_height = try validateNode(right, node, tree);
            } else {
                right_black_height = 1; // Null children count as black
            }

            // Check black height consistency
            if (left_black_height != right_black_height) return error.BlackHeightViolation;

            // Return black height for parent validation
            const current_black_height = if (node.isBlack()) 
                left_black_height + 1 
            else 
                left_black_height;

            return current_black_height;
        }
    };
}

const TestNumber = struct {
    node: Node = .{},
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

fn testKeyCompare(l: *Node, key: anytype) Order {
    const left = testGetNumber(l);

    if (left.value < key) {
        return .lt;
    } else if (left.value == key) {
        return .eq;
    }

    return .gt;
}

fn testCompareReverse(l: *Node, r: *Node, _: ?*Node) Order {
    return testCompare(r, l, undefined);
}

fn testKeyCompareReverse(l: *Node, key: anytype) Order {
    return switch (testKeyCompare(l, key)) {
        .lt => .gt,
        .gt => .lt,
        .eq => .eq
    };
}

test "rb" {
    var tree: Tree(testCompare, testKeyCompare) = .{};
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
    _ = try tree.validate();

    tree.remove(&ns[3].node);
    _ = try tree.validate();

    try testing.expect(tree.insert(&dup.node) == &ns[7].node);

    tree.replace(&ns[7].node, &dup.node);
    _ = try tree.validate();

    var num: *TestNumber = undefined;
    num = testGetNumber(tree.first().?);
    while (num.node.next() != null) {
        try testing.expect(testGetNumber(num.node.next().?).value > num.value);
        num = testGetNumber(num.node.next().?);
    }
}

test "inserting and looking up" {
    var tree: Tree(testCompare, testKeyCompare) = .{};
    var number: TestNumber = undefined;
    number.value = 1000;
    _ = tree.insert(&number.node);
    var dup: TestNumber = undefined;
    //Assert that tuples with identical value fields finds the same pointer
    dup.value = 1000;
    assert(tree.lookup(dup.value) == &number.node);
    //Assert that tuples with identical values do not clobber when inserted.
    _ = tree.insert(&dup.node);
    _ = try tree.validate();

    assert(tree.lookup(dup.value) == &number.node);
    assert(tree.lookup(number.value) != &dup.node);
    assert(testGetNumber(tree.lookup(dup.value).?).value == testGetNumber(&dup.node).value);
    //Assert that if looking for a non-existing value, return null.
    assert(tree.lookup(1234) == null);
}

test "multiple inserts, followed by calling first and last" {
    var tree: Tree(testCompare, testKeyCompare) = .{};
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
    _ = try tree.validate();

    assert(testGetNumber(tree.first().?).value == 0);
    assert(testGetNumber(tree.last().?).value == 3);

    assert(tree.lookup(2) == &second.node);

    const new_tree = tree.sort(testCompareReverse, testKeyCompareReverse) catch unreachable;
    _ = try new_tree.validate();

    assert(testGetNumber(new_tree.first().?).value == 3);
    assert(testGetNumber(new_tree.last().?).value == 0);
    assert(new_tree.lookup(2) == &second.node);
}

test "custom 1" {
    var tree: Tree(testCompare, testKeyCompare) = .{};
    var _400: TestNumber = .{ .value = 0x400 };
    var _401: TestNumber = .{ .value = 0x401 };
    var _4a7: TestNumber = .{ .value = 0x4a7 };
    var _501: TestNumber = .{ .value = 0x501 };
    var _50d: TestNumber = .{ .value = 0x50d };
    var _7ff: TestNumber = .{ .value = 0x7ff };
    var _51a: TestNumber = .{ .value = 0x51a };
    var _519: TestNumber = .{ .value = 0x519 };

    _ = tree.insert(&_400.node);
    _ = tree.insert(&_401.node);
    _ = tree.insert(&_4a7.node);
    _ = tree.insert(&_501.node);
    _ = tree.insert(&_50d.node);
    _ = tree.insert(&_7ff.node);
    _ = tree.insert(&_51a.node);

    _ = try tree.validate();
    _ = tree.insert(&_519.node);

    _ = try tree.validate();
}

test "custom 2" {
    var tree: Tree(testCompare, testKeyCompare) = .{};
    var _400: TestNumber = .{ .value = 0x400 };
    var _401: TestNumber = .{ .value = 0x401 };
    var _4a7: TestNumber = .{ .value = 0x4a7 };
    var _501: TestNumber = .{ .value = 0x501 };
    var _50d: TestNumber = .{ .value = 0x50d };
    var _519: TestNumber = .{ .value = 0x519 };
    var _51a: TestNumber = .{ .value = 0x51a };
    var _51b: TestNumber = .{ .value = 0x51b };
    var _51c: TestNumber = .{ .value = 0x51c };
    var _523: TestNumber = .{ .value = 0x523 };
    var _527: TestNumber = .{ .value = 0x527 };
    var _528: TestNumber = .{ .value = 0x528 };
    var _529: TestNumber = .{ .value = 0x529 };
    var _52a: TestNumber = .{ .value = 0x52a };
    var _52b: TestNumber = .{ .value = 0x52b };
    var _52c: TestNumber = .{ .value = 0x52c };
    var _52d: TestNumber = .{ .value = 0x52d };
    var _52e: TestNumber = .{ .value = 0x52e };
    var _530: TestNumber = .{ .value = 0x530 };
    var _534: TestNumber = .{ .value = 0x534 };
    var _538: TestNumber = .{ .value = 0x538 };
    var _53c: TestNumber = .{ .value = 0x53c };
    var _542: TestNumber = .{ .value = 0x542 };
    var _548: TestNumber = .{ .value = 0x548 };
    var _54e: TestNumber = .{ .value = 0x54e };
    var _554: TestNumber = .{ .value = 0x554 };
    var _55c: TestNumber = .{ .value = 0x55c };
    var _55d: TestNumber = .{ .value = 0x55d };
    var _55e: TestNumber = .{ .value = 0x55e };
    var _7fc: TestNumber = .{ .value = 0x7fc };

    _ = tree.insert(&_400.node);
    _ = tree.insert(&_401.node);
    _ = tree.insert(&_4a7.node);
    _ = tree.insert(&_501.node);
    _ = tree.insert(&_50d.node);
    _ = tree.insert(&_519.node);
    _ = tree.insert(&_51a.node);
    _ = tree.insert(&_51b.node);
    _ = tree.insert(&_51c.node);
    _ = tree.insert(&_523.node);
    _ = tree.insert(&_527.node);
    _ = tree.insert(&_528.node);
    _ = tree.insert(&_529.node);
    _ = tree.insert(&_52a.node);
    _ = tree.insert(&_52b.node);
    _ = tree.insert(&_52c.node);
    _ = tree.insert(&_52d.node);
    _ = tree.insert(&_52e.node);
    _ = tree.insert(&_530.node);
    _ = tree.insert(&_534.node);
    _ = tree.insert(&_538.node);
    _ = tree.insert(&_53c.node);
    _ = tree.insert(&_542.node);
    _ = tree.insert(&_548.node);
    _ = tree.insert(&_54e.node);
    _ = tree.insert(&_554.node);
    _ = tree.insert(&_55c.node);
    _ = tree.insert(&_55d.node);
    _ = tree.insert(&_55e.node);
    _ = tree.insert(&_7fc.node);

    _ = try tree.validate();

    tree.remove(&_55c.node);
    _ = try tree.validate();
}
