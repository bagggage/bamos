//! # Device objects subsystem

// Copyright (C) 2024-2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const bindings = @import("../bindings.zig");
const lib = @import("../lib.zig");
const vm = @import("../vm.zig");

const HashMap = std.AutoHashMapUnmanaged(u32, ObjectsList);

pub const List = std.DoublyLinkedList;
pub const Node = List.Node;

// TODO: Use RCU list instead
const ObjectsList = struct {
    list: List = .{},
    lock: lib.sync.Spinlock = .{},
};

fn Object(comptime T: type) type {
    return struct {
        const Self = @This();

        node: Node = .{},
        payload: T,

        comptime {
            std.debug.assert(@offsetOf(@This(), "payload") == @sizeOf(Node));
        }

        inline fn fromPayload(payload: *T) *Self {
            return @fieldParentPtr("payload", payload);
        }

        inline fn fromNode(node: *Node) *T {
            const self: *Self = @fieldParentPtr("node", node);
            return &self.payload;
        }
    };
}

pub const Error = error {
    NoMemory
};

pub fn Inherit(comptime Base: type, comptime T: type) type {
    return struct {
        base: Base,
        derived: T,

        comptime { std.debug.assert(@offsetOf(@This(), "base") == 0); }
    };
}

fn checkType(comptime T: type) void {
    if (@typeInfo(T) != .@"struct") {
        @compileError(
            "Object type must be a user-defined struct; found: '"++@typeName(T)++"'"
        );
    }
}

/// @export
pub fn new(comptime T: type) Error!*T {
    checkType(T);
    return &(vm.gpa.create(Object(T)) orelse return error.NoMemory).payload;
}

/// @export
pub fn free(comptime T: type, object: *T) void {
    const obj = Object(T).fromPayload(object);
    vm.gpa.free(obj);
}

pub inline fn add(comptime T: type, object: *T) Error!void {
    comptime checkType(T);

    const id = comptime lib.meta.typeId(T);
    const obj = Object(T).fromPayload(object);
    const result = bindings.getInstance().dev.obj.addByTypeId(id, &obj.node);

    if (!result) return error.NoMemory;

    // Class callback
    if (comptime @hasDecl(T, "onObjectAdd")) T.onObjectAdd(object);
}

pub inline fn remove(object: anytype) void {
    const Ptr: type = @TypeOf(object);
    const T= switch (@typeInfo(Ptr)) {
        .Pointer => |ptr| ptr.child,
        else => @compileError("Expected pointer to an object; Found: '"++@typeName(Ptr)++"'")
    };

    // Class callback
    if (comptime @hasDecl(T, "onObjectRemove")) {
        T.onObjectRemove(object);
    }

    const id = comptime lib.meta.typeId(T);
    const obj = Object(T).fromPayload(object);
    const result = bindings.getInstance().dev.obj.removeByTypeId(id, &obj.node);

    std.debug.assert(result == true);
}

pub inline fn getObjects(comptime T: type) ?*List {
    comptime checkType(T);

    const id = comptime lib.meta.typeId(T);
    const list = bindings.getInstance().dev.obj.getObjectsByTypeId(id);

    return list orelse return null;
}

pub inline fn putObjects(list: *List) void {
    return bindings.getInstance().dev.obj.putObjects(list);
}

pub inline fn fromNode(comptime T: type, node: *Node) *T {
    return Object(T).fromNode(node);
}
