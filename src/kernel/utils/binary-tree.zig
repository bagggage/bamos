//! # Binary tree implementation

const std = @import("std");

const utils = @import("../utils.zig");

/// Provides a default comparison function for the binary tree nodes.
/// This function compares two values of type `T` and returns a `utils.CmpResult`
/// indicating the relative order of the values.
fn default_cmp_fn(comptime T: type) utils.CmpFnType(T) {
    const Anon = struct {
        pub fn cmp(lhs: *const T, rhs: *const T) utils.CmpResult {
            if (lhs.* < rhs.*) { return .less; }
            else if (lhs.* == rhs.*) { return .equals; }

            return .great;
        }
    };

    return Anon.cmp;
}

/// Binary tree data structure for managing elements of type `T`.
/// The binary tree uses a comparison function to maintain its order and provides
/// various operations for inserting, removing, and searching for elements.
///
/// - `T`: The type of data stored in the binary tree nodes.
/// - `cmp_func`: An optional comparison function for ordering the elements in the tree. 
///   If `null`, a default comparison function is used.
/// - Returns: A binary tree type.
pub fn BinaryTree(comptime T: type, comptime cmp_func: ?utils.CmpFnType(T)) type {
    const cmp_fn = cmp_func orelse default_cmp_fn(T);

    return struct {
        const Self = @This();

        /// Represents a node in the binary tree.
        /// Each node contains data of type `T` and
        /// pointers to its left and right children.
        pub const Node = struct {
            lhs: ?*Node = null,
            rhs: ?*Node = null,

            data: T,

            /// Initializes a new node with the given value.
            pub inline fn init(val: T) Node {
                return Node{ .data = val };
            }

            /// Finds the node with the minimum value in the subtree rooted at this node.
            pub inline fn findMin(self: *Node) *Node {
                var it = self;

                while (it.lhs) |lhs| { it = lhs; }

                return it;
            }

            /// Finds the node with the maximum value in the subtree rooted at this node.
            pub inline fn findMax(self: *Node) *Node {
                var it = self;

                while (it.rhs) |rhs| { it = rhs; }

                return it;
            }

            /// Same as `findMax`, but also returns the parent node poiner.
            inline fn findMaxP(self: *Node, parent_out: **Node) *Node {
                var it = self;

                while (it.rhs) |rhs| {
                    parent_out.* = it;
                    it = rhs;
                }

                return it;
            }

            /// Same as `findMin`, but also returns the parent node poiner.
            inline fn findMinP(self: *Node, parent_out: **Node) *Node {
                var it = self;

                while (it.lhs) |lhs| {
                    parent_out.* = it;
                    it = lhs;
                }

                return it;
            }

            /// Finds a child node of this node with a value equal to `val`.
            /// 
            /// - Returns: A pointer to the child node or `null` if there is
            /// no such node with the `data` equals to `val`.
            pub inline fn findChild(self: *const Node, val: *const T) ?*Node {
                if (self.lhs) |lhs| {
                    if (cmp_fn(&lhs.data, val) == .equals) return lhs;
                }
                if (self.rhs) |rhs| {
                    if (cmp_fn(&rhs.data, val) == .equals) return rhs;
                }

                return null;
            }

            /// Removes this node from the tree. The tree structure is maintained by
            /// promoting a child node to replace the removed node if necessary.
            ///
            /// - `parent`: The parent of this node, or `null` if this node is the root.
            /// - Returns: The removed node.
            pub fn remove(self: *Node, parent: ?*Node) *Node {
                var temp_parent = self;

                if (self.lhs) |lhs| {
                    const max = lhs.findMaxP(&temp_parent);

                    self.data = max.data;
                    return max.remove(temp_parent);
                }
                else if (self.rhs) |rhs| {
                    const min = rhs.findMinP(&temp_parent);

                    self.data = min.data;
                    return min.remove(temp_parent);
                }
                else {
                    if (parent) |par| {
                        if (self == par.lhs) { par.lhs = null; }
                        else { par.rhs = null; }
                    }

                    return self;
                }
            }
        };

        /// The root node of the binary tree.
        root: ?*Node = null,

        /// Inserts a new node into the binary tree, maintaining the tree's order.
        ///
        /// - `node`: A pointer to the node to insert.
        pub fn insert(self: *Self, node: *Node) void {
            if (self.root) |root| {
                var it = root;

                while (true) {
                    if (cmp_fn(&it.data, &node.data) == .less) {
                        // Right branch
                        if (it.rhs) |rhs| {
                            it = rhs;
                        }
                        else {
                            it.rhs = node;
                            break;
                        }
                    }
                    // Left branch
                    else if (it.lhs) |lhs| {
                        it = lhs;
                    }
                    else {
                        it.lhs = node;
                        break;
                    }
                }
            }
            else {
                self.root = node;
            }
        }

        /// A helper function that handles different types of inputs (`raw values` or `pointers`)
        /// and calls the appropriate method with a pointer to the value.
        inline fn anytype_call(comptime SelfPtr: type, comptime func: anytype, self: SelfPtr, val: anytype) ?*Node {
            const type_info = @typeInfo(@TypeOf(val));
            const err_str = "Only raw values or pointers to data member type allowed";

            switch (type_info) {
                .Pointer => |ptr| {
                    if (ptr.child != T) @compileError(err_str);
                    return func(self, val);
                },
                .ComptimeInt,
                .ComptimeFloat => switch (@typeInfo(T)) {
                    .Int,
                    .Float => {
                        const value = @as(T, val);
                        return func(self, &value);
                    },
                    else => @compileError(err_str)
                },
                else => {
                    if (T == @TypeOf(val)) { return func(self, &val); }
                    else { @compileError(err_str); }
                }
            }
        }

        /// Internal function to remove a node with a value equal to `val` from the tree.
        fn removeImpl(self: *Self, val: *const T) ?*Node {
            if (self.root) |root| {
                if (cmp_fn(&root.data, val) == .equals) {
                    // Remove root
                    const result = root.remove(null);
                    if (result == root) self.root = null;

                    return result;
                }

                var it: ?*Node = root;

                while (it) |node| {
                    if (node.findChild(val)) |child| {
                        return child.remove(node);
                    }
                    else if (cmp_fn(&node.data, val) == .less) {
                        it = node.rhs;
                    }
                    else {
                        it = node.lhs;
                    }
                }
            }

            return null;
        }

        /// Removes a node with a value equal to `val` from the tree.
        ///
        /// - `val`: The value of the node to remove (can be a raw value or a pointer).
        /// - Returns: The removed node, or `null` if no node with the specified value was found.
        pub inline fn remove(self: *Self, val: anytype) ?*Node {
            return anytype_call(@TypeOf(self), removeImpl, self, val);
        }

        /// Internal function to find a node with a value equal to `val` in the tree.
        fn findImpl(self: *const Self, val: *const T) ?*Node {
            var it: ?*Node = self.root;

            while (it) |node| {
                const cmp = cmp_fn(&node.data, val);

                if (cmp == .equals) { return node; }
                else if (cmp == .less) {
                    it = node.rhs;
                }
                else {
                    it = node.lhs;
                }
            }

            return null;
        }

        /// Finds a node with a value equal to `val` in the tree.
        ///
        /// - `val`: The value to search for (can be a raw value or a pointer).
        /// - Returns: A pointer to the found node, or `null` if no node with the specified value was found.
        pub inline fn find(self: *const Self, val: anytype) ?*Node {
            return anytype_call(@TypeOf(self), findImpl, self, val);
        }

        /// Finds the node with the maximum value in the entire tree.
        ///
        /// - Returns: A pointer to the node with the maximum value, or `null` if the tree is empty.
        pub inline fn findMax(self: *const Self) ?*Node {
            const root = self.root orelse return null;
            return root.findMax();
        }

        /// Finds the node with the minimum value in the entire tree.
        ///
        /// - Returns: A pointer to the node with the minimum value, or `null` if the tree is empty.
        pub inline fn findMin(self: *const Self) ?*Node {
            const root = self.root orelse return null;
            return root.findMin();
        }
    };
}

const Test = struct {
    pub const BtType = BinaryTree(u32, null);
    const Node = BtType.Node;

    pub var _50 = Node.init(50);
    pub var _60 = Node.init(60);
    pub var _40 = Node.init(40);
    pub var _30 = Node.init(30);
    pub var _45 = Node.init(45);
    pub var _65 = Node.init(65);
    pub var _70 = Node.init(70);
    pub var _80 = Node.init(80);
    pub var _67 = Node.init(67);
    pub var _68 = Node.init(68);
    pub var _69 = Node.init(69);

    pub fn tree() BtType {
        var res = BtType{};

        res.insert(&_50);
        return res;
    }
};

test "insert" {
    var tree = Test.tree();

    tree.insert(&Test._60);
    tree.insert(&Test._40);
    tree.insert(&Test._30);
    tree.insert(&Test._45);
    tree.insert(&Test._70);
    tree.insert(&Test._65);
    tree.insert(&Test._80);
    tree.insert(&Test._68);
    tree.insert(&Test._67);
    tree.insert(&Test._69);

    try std.testing.expect(tree.root == &Test._50);
    try std.testing.expect(tree.root.?.lhs == &Test._40);
    try std.testing.expect(tree.root.?.rhs == &Test._60);

    try std.testing.expect(Test._40.lhs == &Test._30);
    try std.testing.expect(Test._40.rhs == &Test._45);

    try std.testing.expect(Test._60.lhs == null);
    try std.testing.expect(Test._60.rhs == &Test._70);

    try std.testing.expect(Test._70.lhs == &Test._65);
    try std.testing.expect(Test._70.rhs == &Test._80);

    try std.testing.expect(Test._65.lhs == null);
    try std.testing.expect(Test._65.rhs == &Test._68);

    try std.testing.expect(Test._68.lhs == &Test._67);
    try std.testing.expect(Test._68.rhs == &Test._69);

    try std.testing.expect(Test._69.lhs == null);
    try std.testing.expect(Test._69.rhs == null);

    try std.testing.expect(Test._67.lhs == null);
    try std.testing.expect(Test._67.rhs == null);

    try std.testing.expect(Test._30.lhs == null);
    try std.testing.expect(Test._30.rhs == null);

    try std.testing.expect(Test._45.lhs == null);
    try std.testing.expect(Test._45.rhs == null);
}

test "find" {
    const tree = Test.tree();

    try std.testing.expect(tree.find(0) == null);
    try std.testing.expect(tree.find(10000) == null);
    try std.testing.expect(tree.find(1) == null);
    try std.testing.expect(tree.find(61) == null);

    try std.testing.expect(tree.find(50) == &Test._50);
    try std.testing.expect(tree.find(80) == &Test._80);
    try std.testing.expect(tree.find(60) == &Test._60);
    try std.testing.expect(tree.find(65) == &Test._65);
    try std.testing.expect(tree.find(70) == &Test._70);
    try std.testing.expect(tree.find(40) == &Test._40);
    try std.testing.expect(tree.find(30) == &Test._30);
}

test "find max" {
    const tree = Test.tree();

    try std.testing.expect(tree.findMax() == &Test._80);
}

test "find min" {
    const tree = Test.tree();

    try std.testing.expect(tree.findMin() == &Test._30);
}

test "remove" {
    var tree = Test.tree();

    try std.testing.expect(tree.root == &Test._50);
    try std.testing.expect(tree.remove(50) != null);
    try std.testing.expect(tree.root.?.data == 45);

    try std.testing.expect(tree.remove(50) == null);
    try std.testing.expect(tree.remove(0) == null);

    try std.testing.expect(tree.remove(60) != null);
    try std.testing.expect(tree.remove(60) == null);
}
