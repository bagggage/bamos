//! # Device module

// Copyright (C) 2024-2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const log = std.log.scoped(.dev);
const utils = @import("utils.zig");
const vm = @import("vm.zig");

pub const acpi = @import("dev/stds/acpi.zig");
pub const Bus = @import("dev/Bus.zig");
pub const classes = @import("dev/classes.zig");
pub const Device = @import("dev/Device.zig");
pub const Driver = @import("dev/Driver.zig");
pub const obj = @import("dev/obj.zig");
pub const regs = @import("dev/regs.zig");
pub const io = @import("dev/io.zig");
pub const intr = @import("dev/intr.zig");
pub const pci = @import("dev/stds/pci.zig");

// For internal use
pub const BusList = utils.List(Bus);
pub const BusNode = BusList.Node;

pub const DeviceList = utils.List(Device);
pub const DeviceNode = DeviceList.Node;

pub const DriverList = utils.List(Driver);
pub const DriverNode = DriverList.Node;

pub const Name = extern struct {
    ptr: [*]const u8 = undefined,
    len: u16 = 0,

    allocated: bool = false,

    comptime { std.debug.assert(@sizeOf(Name) == @sizeOf(usize) * 2); }

    pub inline fn str(self: *const Name) []const u8 {
        return self.ptr[0..self.len];
    }

    pub fn print(comptime fmt: []const u8, args: anytype) !Name {
        const len: u16 = @truncate(std.fmt.count(fmt, args));
        const buffer: [*]u8 = @ptrCast(vm.malloc(len) orelse return error.NoMemory);

        _ = try std.fmt.bufPrint(buffer[0..len], fmt, args);

        return .{
            .ptr = buffer,
            .len = len,
            .allocated = true
        };
    }

    pub inline fn init(val: []const u8) Name {
        return .{
            .ptr = val.ptr,
            .len = @truncate(val.len)
        };
    }

    pub inline fn deinit(self: *Name) void {
        if (self.allocated) vm.free(@constCast(self.ptr));

        self.len = 0;
    }

    pub fn format(self: *const Name, _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("{s}", .{ self.str() });
    }
};

pub const nameHash = std.hash.Fnv1a_32.hash;
pub const nameFmt = Name.print;
pub const nameOf = Name.init;

var buses = BusList{};
var buses_lock = utils.Spinlock.init(.unlocked);

/// @noexport
const AutoInit = struct {
    const modules = .{
        @import("dev/drivers/uart.zig"),
        pci,
        @import("dev/drivers/blk/nvme.zig")
    };
};

fn platformBusRemove(_: *Device) void {}
fn platformBusMatch(_: *const Driver, _: *const Device) bool { return true; }

var platform_bus = Bus.init("platform",.{
    .match = platformBusMatch,
    .remove = platformBusRemove
});

pub fn preinit() !void {
    try acpi.init();
    try intr.init();

    registerBus(&platform_bus);

    try utils.arch.devInit();
}

pub fn init() !void {
    inline for (AutoInit.modules) |Module| {
        if (Module.init()) {
            log.info(@typeName(Module)++": initialized", .{});
        } else |err| {
            log.warn(@typeName(Module)++": was not initialized: {s}", .{@errorName(err)});
        }
    }
}

pub export fn registerBus(bus: *BusNode) void {
    buses_lock.lock();
    defer buses_lock.unlock();

    buses.prepend(bus);

    log.info("{s} bus was registered", .{bus.data.name});
}

pub inline fn registerDevice(
    comptime bus_name: []const u8,
    name: Name,
    driver: ?*const Driver,
    data: ?*anyopaque
) !*Device {
    const bus = try getBus(bus_name);
    return bus.addDevice(name, driver, data) orelse return error.NoMemory;
}

pub inline fn removeDevice(dev: *Device) void {
    dev.bus.removeDevice(dev);
}

pub inline fn registerDriver(comptime bus_name: []const u8, driver: *DriverNode) !void {
    const bus = try getBus(bus_name);
    bus.addDriver(driver);
}

pub inline fn removeDriver(driver: *DriverNode) void {
    driver.data.bus.removeDriver(driver);
}

pub inline fn getBus(comptime name: []const u8) !*Bus {
    comptime var lower_name: [name.len]u8 = undefined;
    _ = comptime std.ascii.lowerString(&lower_name, name);

    const hash = comptime nameHash(&lower_name);

    return getBusByHash(hash) orelse error.UnsupportedBus;
}

export fn getBusByHash(hash: u32) ?*Bus {
    buses_lock.lock();
    defer buses_lock.unlock();

    var node = buses.first;

    while(node) |bus| : (node = bus.next) {
        if (bus.data.type == hash) return &bus.data;
    }

    return null;
}