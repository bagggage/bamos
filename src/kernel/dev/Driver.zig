//! # Driver representation

// Copyright (C) 2024 Konstantin Pigulevskiy (bagggage@github)

const Bus = @import("Bus.zig");
const Device = @import("Device.zig");
const dev = @import("../dev.zig");
const utils = @import("../utils.zig");

const Self = @This();

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
    remove: RemoveFn
};

name: []const u8,
bus: *Bus = undefined,
ops: Operations,

pub fn init(
    comptime name: []const u8,
    comptime ops: Operations
) dev.DriverNode {
    return .{
        .data = .{
            .name = name,
            .ops = ops,
        }
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
