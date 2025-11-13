//! # Device representation

// Copyright (C) 2024-2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const Bus = @import("Bus.zig");
const dev = @import("../dev.zig");
const Driver = @import("Driver.zig");
const log = std.log.scoped(.Device);
const utils = @import("../utils.zig");
const vm = @import("../vm.zig");

const Self = @This();

pub const List = utils.List;
pub const Node = List.Node;

pub const alloc_config: vm.auto.Config = .{
    .allocator = .oma,
    .capacity = 64
};

name: dev.Name = .{},
bus: *Bus,

driver: ?*const Driver,
driver_data: utils.AnyData,

node: Node = .{},

pub fn new(name: dev.Name, bus: *Bus, driver: ?*const Driver, data: ?*anyopaque) ?*Self {
    const self = vm.auto.alloc(Self) orelse return null;
    self.* = .{
        .name = name,
        .bus = bus,
        .driver = driver,
        .driver_data = utils.AnyData.from(data),
    };

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