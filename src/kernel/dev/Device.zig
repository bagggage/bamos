//! # Device representation

// Copyright (C) 2024-2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const Bus = @import("Bus.zig");
const dev = @import("../dev.zig");
const Driver = @import("Driver.zig");
const log = std.log.scoped(.Device);
const utils = @import("../utils.zig");

const Self = @This();

name: dev.Name = .{},
bus: *Bus,

driver: ?*const Driver,
driver_data: utils.AnyData,

pub inline fn deinit(self: *Self) void {
    self.name.deinit();
}