//! # Device objects subsystem

// Copyright (C) 2024 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const vm = @import("../vm.zig");
const utils = @import("../utils.zig");

const List = utils.List(u8);
const HashMap = std.AutoHashMapUnmanaged(u32, ObjectsList);

comptime {
    std.debug.assert(@offsetOf(List.Node, "data") == (@sizeOf(usize) * 2));
}

const ObjectsList = struct {
    list: List = .{},
    lock: utils.Spinlock = .{},
};

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
var map_lock = utils.Spinlock.init(.unlocked);

fn checkType(comptime T: type) void {
    if (@typeInfo(T) != .@"struct") @compileError("Object type must be a user-defined struct; found: '"++@typeName(T)++"'");
}

/// @export
pub fn new(comptime T: type) Error!*T {
    checkType(T);

    const Node = utils.List(T).Node;
    comptime std.debug.assert(@offsetOf(Node, "data") == @offsetOf(List.Node, "data"));

    return &(vm.alloc(Node) orelse return error.NoMemory).data;
}

/// @export
pub fn free(comptime T: type, object: *T) void {
    const Node = utils.List(T).Node;
    const node: *Node = @fieldParentPtr("data", object);

    vm.free(node);
}

pub inline fn add(comptime T: type, object: *T) Error!void {
    checkType(T);
    const id = comptime utils.typeId(T);
    const node: *utils.List(T).Node = @fieldParentPtr("data", object);

    if (!addByTypeId(id, @ptrCast(node))) return error.NoMemory;
}

pub inline fn remove(object: anytype) void {
    const Ptr = @TypeOf(object);
    const T = switch (@typeInfo(Ptr)) {
        .Pointer => |ptr| ptr.child,
        else => @compileError("Expected pointer to an object; Found: '"++@typeName(Ptr)++"'")
    };

    const Node = utils.List(T).Node;
    const node: *Node = @fieldParentPtr("data", object);

    const id = comptime utils.typeId(T);
    const result = removeByTypeId(node, id);

    std.debug.assert(result == true);
}

pub inline fn getObjects(comptime T: type) ?*utils.List(T) {
    checkType(T);
    const id = comptime utils.typeId(T);

    return @alignCast(@ptrCast(getObjectsByTypeId(id) orelse return null));
}

pub export fn putObjects(list: *anyopaque) void {
    const list_raw: *List = @alignCast(@ptrCast(list));
    const objects: *ObjectsList = @fieldParentPtr("list", list_raw);

    objects.lock.unlock();
}

export fn removeByTypeId(id: u32, node: *anyopaque) bool {
    const obj_list = blk: {
        map_lock.lock();
        defer map_lock.unlock();

        break :blk (hash_map.getPtr(id) orelse return false);
    };

    obj_list.lock.lock();
    defer obj_list.lock.unlock();

    if (obj_list.list.len == 1) {
        map_lock.lock();
        defer map_lock.unlock();
            
        return hash_map.remove(id);
    }
    else {
        obj_list.list.remove(@alignCast(@ptrCast(node)));
    }

    vm.free(node);
    return true;
}

export fn addByTypeId(id: u32, node: *anyopaque) bool {
    const entry = blk: {
        map_lock.lock();
        defer map_lock.unlock();

        break :blk hash_map.getOrPutValue(vm.std_allocator, id, ObjectsList{}) catch {
            return false;
        };
    };

    entry.value_ptr.lock.lock();
    defer entry.value_ptr.lock.unlock();

    entry.value_ptr.list.append(@alignCast(@ptrCast(node)));
    return true;
}

export fn getObjectsByTypeId(id: u32) ?*anyopaque {
    const objects = blk: {
        map_lock.lock();
        defer map_lock.unlock();

        break :blk hash_map.getPtr(id) orelse return null;
    };

    objects.lock.lock();
    return &objects.list;
}