//! # Device objects subsystem

// Copyright (C) 2024-2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const lib = @import("../lib.zig");
const vm = @import("../vm.zig");

const List = std.DoublyLinkedList;
const Node = List.Node;
const HashMap = std.AutoHashMapUnmanaged(u32, ObjectsList);

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

var hash_map: HashMap = .{};
var map_lock: lib.sync.Spinlock = .init(.unlocked);

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
    if (!addByTypeId(id, &obj.node)) return error.NoMemory;

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
    const result = removeByTypeId(id, &obj.node);
    std.debug.assert(result == true);
}

pub inline fn getObjects(comptime T: type) ?*List {
    comptime checkType(T);
    const id = comptime lib.meta.typeId(T);

    return getObjectsByTypeId(id) orelse return null;
}

pub export fn putObjects(list: *List) void {
    const objects: *ObjectsList = @fieldParentPtr("list", list);
    objects.lock.unlock();
}

pub inline fn fromNode(comptime T: type, node: *Node) *T {
    return Object(T).fromNode(node);
}

export fn removeByTypeId(id: u32, node: *Node) bool {
    const obj_list = blk: {
        map_lock.lock();
        defer map_lock.unlock();

        break :blk (hash_map.getPtr(id) orelse return false);
    };

    obj_list.lock.lock();
    defer obj_list.lock.unlock();

    if (obj_list.list.first == obj_list.list.last) {
        map_lock.lock();
        defer map_lock.unlock();
            
        return hash_map.remove(id);
    }
    else {
        obj_list.list.remove(node);
    }

    vm.gpa.free(node);
    return true;
}

export fn addByTypeId(id: u32, node: *Node) bool {
    const entry = blk: {
        map_lock.lock();
        defer map_lock.unlock();

        break :blk hash_map.getOrPutValue(vm.gpa.std_interface, id, ObjectsList{}) catch {
            return false;
        };
    };

    entry.value_ptr.lock.lock();
    defer entry.value_ptr.lock.unlock();

    entry.value_ptr.list.append(node);
    return true;
}

export fn getObjectsByTypeId(id: u32) ?*List {
    const objects = blk: {
        map_lock.lock();
        defer map_lock.unlock();

        break :blk hash_map.getPtr(id) orelse return null;
    };

    objects.lock.lock();
    return &objects.list;
}

