//! # Bus representation

// Copyright (C) 2024-2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const bindings = @import("../bindings.zig");
const Device = @import("Device.zig");
const dev = @import("../dev.zig");
const Driver = @import("Driver.zig");
const lib = @import("../lib.zig");

const Self = @This();

pub const Operations = struct {
    pub const MatchFn = *const fn (*const Driver, *const Device) bool;
    pub const RemoveFn = *const fn (*Device) void;

    match: MatchFn,
    remove: RemoveFn
};

pub const List = std.DoublyLinkedList;
pub const Node = List.Node;

name: []const u8,
type: u32,

node: Node = .{},

matched_devs: Device.List = .{},
unmatched_devs: Device.List = .{},
drivers: Driver.List = .{},

dri_lock: lib.sync.Spinlock = .{},
dev_lock: lib.sync.Spinlock = .{},

ops: Operations,

pub fn init(comptime name: []const u8, ops: Operations) Self {
    comptime var lower_name: [name.len]u8 = undefined;
    _ = comptime std.ascii.lowerString(&lower_name, name);

    const temp_name: [lower_name.len]u8 = lower_name;
    const hash = comptime dev.nameHash(&temp_name);

    return .{
        .name = name,
        .type = hash,
        .ops = ops
    };
}

pub inline fn fromNode(node: *Node) *Self {
    return @fieldParentPtr("node", node);
}

pub inline fn addDevice(self: *Self, device: *Device, driver: ?*const Driver) void {
    bindings.getInstance().dev.bus.addDevice(self, device, driver);
}

pub inline fn removeDevice(self: *Self, device: *Device) void {
    bindings.getInstance().dev.bus.removeDevice(self, device);
}

pub inline fn addDriver(self: *Self, driver: *Driver) void {
    bindings.getInstance().dev.bus.addDriver(self, driver);
}

pub inline fn removeDriver(self: *Self, driver: *Driver) void {
    bindings.getInstance().dev.bus.removeDriver(self, driver);
}
