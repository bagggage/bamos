//! # Bus representation

const std = @import("std");

const Device = @import("Device.zig");
const dev = @import("../dev.zig");
const Driver = @import("Driver.zig");
const utils = @import("../utils.zig");
const vm = @import("../vm.zig");

const Self = @This();

pub const Operations = struct {
    pub const MatchFn = *const fn (*const Driver, *const Device) bool;
    pub const RemoveFn = *const fn (*Device) void;

    match: MatchFn,
    remove: RemoveFn
};

name: []const u8,
type: u32,

matched: dev.DeviceList = .{},
unmatched: dev.DeviceList = .{},
drivers: dev.DriverList = .{},

dri_lock: utils.Spinlock = .{},
dev_lock: utils.Spinlock = .{},

ops: Operations,

var device_oma = vm.SafeOma(dev.DeviceNode).init(64);

pub fn init(comptime name: []const u8, ops: Operations) dev.BusNode {
    comptime var lower_name: [name.len]u8 = undefined;
    _ = comptime std.ascii.lowerString(&lower_name, name);

    const temp_name: [lower_name.len]u8 = lower_name;
    const hash = comptime dev.nameHash(&temp_name);

    return .{
        .data = .{
            .name = name,
            .type = hash,
            .ops = ops
        }
    };
}

pub export fn addDevice(self: *Self, name: dev.Name, driver: ?*const Driver, data: ?*anyopaque) ?*Device {
    const node = device_oma.alloc() orelse return null;
    const device = &node.data;

    device.* = .{
        .name = name,
        .driver = driver,
        .driver_data = utils.AnyData.from(data),
        .bus = self,
    };

    {
        self.dev_lock.lock();
        defer self.dev_lock.unlock();

        if (driver != null) {
            self.matched.append(node);
        }
        else {
            self.matchDevice(node);
        }
    }

    return device;
}

pub export fn removeDevice(self: *Self, device: *Device) void {
    const node: *dev.DeviceNode = @ptrFromInt(@intFromPtr(device) - @offsetOf(dev.DeviceNode, "data"));

    self.dev_lock.lock();
    defer self.dev_lock.unlock();

    if (device.driver) |driver| {
        driver.removeDevice(device);
        self.ops.remove(device);

        self.matched.remove(node);
    }
    else {
        self.ops.remove(device);

        self.unmatched.remove(node);
    }

    node.data.deinit();
    device_oma.free(node);
}

pub export fn addDriver(self: *Self, driver: *dev.DriverNode) void {
    {
        self.dri_lock.lock();
        defer self.dri_lock.unlock();

        self.drivers.prepend(driver);
    }

    self.matchDriver(&driver.data);
}

pub export fn removeDriver(self: *Self, driver: *dev.DriverNode) void {
    {
        self.dri_lock.lock();
        defer self.dri_lock.unlock();

        self.drivers.remove(driver);
    }

    self.onRemoveDriver(&driver.data);
}

fn matchDevice(self: *Self, device: *dev.DeviceNode) void {
    const match_impl = self.ops.match;

    var node = self.drivers.first;

    while (node) |driver| : (node = driver.next) {
        if (
            match_impl(&driver.data, &device.data) == false or
            driver.data.probe(&device.data) == .missmatch
        ) continue;

        device.data.driver = &driver.data;
        self.matched.append(device);

        return;
    }

    self.unmatched.append(device);
}


fn matchDriver(self: *Self, driver: *Driver) void {
    const match_impl = self.ops.match;

    self.dev_lock.lock();
    defer self.dev_lock.unlock();

    var node = self.unmatched.first;

    while (node) |device| {
        node = device.next;

        if (match_impl(driver, &device.data)) {
            if (driver.probe(&device.data) == .missmatch) continue;

            device.data.driver = driver;

            self.unmatched.remove(device);
            self.matched.append(device);
        }
    }
}

fn onRemoveDriver(self: *Self, driver: *const Driver) void {
    self.dev_lock.lock();
    defer self.dev_lock.unlock();

    var node = self.matched.first;

    while (node) |device| {
        node = device.next;

        if (device.data.driver != driver) continue;

        driver.removeDevice(&device.data);

        self.matched.remove(device);
        self.unmatched.append(device);
    }
}