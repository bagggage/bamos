//! # Device representation

// Copyright (C) 2024-2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const Bus = @import("Bus.zig");
const dev = @import("../dev.zig");
const Driver = @import("Driver.zig");
const lib = @import("../lib.zig");
const log = std.log.scoped(.Device);
const vm = @import("../vm.zig");

const Self = @This();

pub const List = std.DoublyLinkedList;
pub const Node = List.Node;

pub const alloc_config: vm.auto.Config = .{
    .allocator = .oma,
    .capacity = 64
};

name: dev.Name = .{},
bus: *Bus,

driver: ?*const Driver = null,
driver_data: lib.AnyData = .{},

node: Node = .{},

pub fn init(name: dev.Name, data: ?*anyopaque) Self {
    return .{
        .name = name,
        .bus = undefined,
        .driver_data = .from(data),
    };
}

pub inline fn new(name: dev.Name, data: ?*anyopaque) ?*Self {
    const self = vm.auto.alloc(Self) orelse return null;
    self.* = init(name, data);

    return self;
}

pub fn delete(self: *Self) void {
    self.deinit();
    vm.auto.free(Self, self);
}

pub inline fn deinit(self: *Self) void {
    self.name.deinit();
}

pub inline fn fromNode(node: *Node) *Self {
    return @fieldParentPtr("node", node);
}