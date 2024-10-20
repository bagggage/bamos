//! # Device objects subsystem

const std = @import("std");

const vm = @import("../vm.zig");
const log = @import("../log.zig");
const utils = @import("../utils.zig");

const List = utils.List(u8);
const HashMap = std.AutoHashMapUnmanaged(u32, List);

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
    if (@typeInfo(T) != .Struct) @compileError("Object type must be a user-defined struct; found: '"++@typeName(T)++"'");
}

pub fn new(comptime T: type) Error!*T {
    checkType(T);

    const Node = utils.List(T).Node;
    comptime std.debug.assert(@offsetOf(Node, "data") == @offsetOf(List.Node, "data"));

    return &(vm.alloc(Node) orelse return error.NoMemory).data;
}

pub fn delete(comptime T: type, object: *T) void {
    const Node = utils.List(T).Node;
    const node: *Node = @fieldParentPtr("data", object);

    vm.free(node);
}

fn addById(id: u32, node: *List.Node) Error!void {
    map_lock.lock();
    defer map_lock.unlock();

    const entry = hash_map.getOrPutValue(vm.std_allocator, id, List{}) catch {
        return error.NoMemory;
    };

    entry.value_ptr.append(@ptrCast(node));
}

pub inline fn add(comptime T: type, object: *T) Error!void {
    checkType(T);
    const id = comptime utils.typeId(T);
    const node: *utils.List(T).Node = @fieldParentPtr("data", object);

    return addById(id, @ptrCast(node));
}

pub fn remove(object: anytype) void {
    const Ptr = @TypeOf(object);
    const T = switch (@typeInfo(Ptr)) {
        .Pointer => |ptr| ptr.child,
        else => @compileError("Expected pointer to an object; Found: '"++@typeName(Ptr)++"'")
    };

    const Node = utils.List(T).Node;
    const node: *Node = @fieldParentPtr("data", object);

    const id = comptime utils.typeId(T);

    {
        map_lock.lock();
        defer map_lock.unlock();

        const list = hash_map.getPtr(id) orelse unreachable;

        if (list.len == 1) {
            const result = hash_map.remove(id);
            std.debug.assert(result == true);
        }
        else {
            list.remove(@ptrCast(node));
        }
    }

    vm.free(node);
}

pub fn getObjects(comptime T: type) ?*utils.List(T) {
    checkType(T);

    map_lock.lock();
    defer map_lock.unlock();

    const id = comptime utils.typeId(T);

    return @ptrCast(hash_map.getPtr(id) orelse return null);
}

pub fn releaseObjects(comptime T: type, list: *utils.List(T)) void {
    const objects: *ObjectsList = @fieldParentPtr("list", list);
    objects.lock.unlock();
}