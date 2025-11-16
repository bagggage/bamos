//! # Driver representation

// Copyright (C) 2024 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const Bus = @import("Bus.zig");
const Device = @import("Device.zig");
const dev = @import("../dev.zig");

const Self = @This();

pub const List = std.DoublyLinkedList;
pub const Node = List.Node;

pub const Operations = struct {
    pub const ProbeResult = enum {
        missmatch,
        failed,
        no_resources,
        success
    };

    pub const ProbeFn = *const fn (*Device) ProbeResult;
    pub const PlatformProbeFn = *const fn (*const Self) ProbeResult;
    pub const RemoveFn = *const fn (*Device) void;

    const Probe = union { universal: ProbeFn, platform: PlatformProbeFn };

    probe: Probe,
    remove: RemoveFn,

    pub fn removeStub(_: *Device) void {}
};

name: []const u8,
bus: *Bus = undefined,
node: Node = .{},
ops: Operations,

pub fn init(
    comptime name: []const u8,
    comptime ops: Operations
) Self {
    return .{
        .name = name,
        .ops = ops,
    };
}

/// @noexport
pub inline fn probe(self: *const Self, device: *Device) Operations.ProbeResult {
    return self.ops.probe.universal(device);
}

/// @noexport
pub inline fn platformProbe(self: *const Self) Operations.ProbeResult {
    return self.ops.probe.platform(self);
}

/// @noexport
pub inline fn removeDevice(self: *const Self, device: *Device) void {
    return self.ops.remove(device);
}

pub inline fn addDevice(self: *const Self, name: dev.Name, data: ?*anyopaque) !*Device {
    return self.bus.addDevice(name, self, data) orelse return error.NoMemory;
}

pub inline fn fromNode(node: *Node) *Self {
    return @fieldParentPtr("node", node);
}
