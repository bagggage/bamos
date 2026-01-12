//! # Bus representation

// Copyright (C) 2024-2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const Device = @import("Device.zig");
const dev = @import("../dev.zig");
const Driver = @import("Driver.zig");
const lib = @import("../lib.zig");
const log = std.log.scoped(.@"dev.bus");
const vm = @import("../vm.zig");

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

pub export fn addDevice(self: *Self, device: *Device, driver: ?*const Driver) void {
    std.debug.assert(
        device.driver == null and
        device.node.next == null and
        device.node.prev == null
    );
    device.bus = self;

    if (driver) |drv| {
        {
            // FIXME
            self.dev_lock.lock();
            defer self.dev_lock.unlock();

            self.matched_devs.append(&device.node);
        }
        self.matchLog(device, drv);
    } else {
        self.matchDevice(device);
    }
}

pub export fn removeDevice(self: *Self, device: *Device) void {
    if (device.driver) |driver| {
        driver.removeDevice(device);
        self.ops.remove(device);

        // FIXME
        self.dev_lock.lock();
        defer self.dev_lock.unlock();

        self.matched_devs.remove(&device.node);
    } else {
        self.ops.remove(device);

        // FIXME
        self.dev_lock.lock();
        defer self.dev_lock.unlock();

        self.unmatched_devs.remove(&device.node);
    }
}

pub export fn addDriver(self: *Self, driver: *Driver) void {
    {
        driver.bus = self;

        self.dri_lock.lock();
        defer self.dri_lock.unlock();

        self.drivers.prepend(&driver.node);
    }

    log.info("{s}: {s} driver was attached", .{self.name,driver.name});

    if (self.type == comptime dev.nameHash("platform")) {
        switch (driver.platformProbe()) {
            .missmatch => log.warn("{s}: device not presented or not supported", .{self.name}),
            .failed => log.err("{s}: not enough resources to initialize device", .{self.name}),
            .no_resources => log.err("{s}: probing failed", .{self.name}),
            .success => return
        }

        self.removeDriver(driver);
    } else {
        self.matchDriver(driver);
    }
}

pub export fn removeDriver(self: *Self, driver: *Driver) void {
    {
        self.dri_lock.lock();
        defer self.dri_lock.unlock();

        self.drivers.remove(&driver.node);
    }

    self.onRemoveDriver(driver);
    driver.bus = undefined;

    log.info("{s}: {s} driver was removed", .{self.name,driver.name});
}

fn matchDevice(self: *Self, device: *Device) void {
    self.dev_lock.lock();
    defer self.dev_lock.unlock();

    var node = self.drivers.first;
    while (node) |n| : (node = n.next) {
        const driver = Driver.fromNode(n);
        {   // FIXME: Use different lock mechanism.
            self.dev_lock.unlock();
            defer self.dev_lock.lock();

            if (
                self.ops.match(driver, device) == false or
                driver.probe(device) == .missmatch
            ) continue;
        }

        device.driver = driver;
        self.matched_devs.append(&device.node);

        self.matchLog(device, driver);
        return;
    }

    self.unmatched_devs.append(&device.node);
}


fn matchDriver(self: *Self, driver: *Driver) void {
    self.dev_lock.lock();
    defer self.dev_lock.unlock();

    var node = self.unmatched_devs.first;
    while (node) |n| : (node = n.next) {
        const device = Device.fromNode(n);
        if (self.ops.match(driver, device)) {
            {   // FIXME: Use different lock mechanism.
                self.dev_lock.unlock();
                defer self.dev_lock.lock();

                if (driver.probe(device) == .missmatch) continue;
            }

            device.driver = driver;

            self.unmatched_devs.remove(&device.node);
            self.matched_devs.append(&device.node);

            self.matchLog(device, driver);
        }
    }
}

inline fn matchLog(self: *const Self, device: *const Device, driver: *const Driver) void {
    log.info("{s}: '{f}' matches the {s} driver", .{self.name, device.name, driver.name});
}

fn onRemoveDriver(self: *Self, driver: *const Driver) void {
    self.dev_lock.lock();
    defer self.dev_lock.unlock();

    var node = self.matched_devs.first;
    while (node) |n| : (node = n.next) {
        const device = Device.fromNode(n);
        if (device.driver != driver) continue;

        self.matched_devs.remove(&device.node);
        defer self.matchDevice(device);

        {   // FIXME: Use different lock mechanism.
            self.dev_lock.unlock();
            defer self.dev_lock.lock();

            driver.removeDevice(device);
        }
    }
}