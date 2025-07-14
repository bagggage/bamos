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
    pub const Error = error {
        NoMemory,
        BadName
    };

    const Meta = packed struct {
        const Length = u7;

        len: Length = 0,
        is_alloc: bool = false,

        comptime { std.debug.assert(@sizeOf(Meta) == 1); }
    };

    pub const max_len = std.math.maxInt(Meta.Length);
    const local_size = @sizeOf(Name) - 1;

    ptr: [*]const u8 = undefined,
    pad_0: if (@sizeOf([*]u8) == 4) u32 else void = undefined,

    pad_1: u32 = undefined, // 4-bytes
    pad_2: u16 = undefined, // 2-bytes
    pad_3: u8 = undefined,  // 1-byte
                            // = 15 bytes

    meta: u8 = 0,           // + 1 = 16 bytes

    comptime { std.debug.assert(@sizeOf(Name) == @sizeOf(usize) * 2); }

    pub fn str(self: *const Name) []const u8 {
        const len = self.length();
        if (self.isAllocated() or len > max_len) return self.ptr[0..len];
        return self.localBuffer()[0..len];
    }

    pub fn print(comptime fmt: []const u8, args: anytype) Error!Name {
        var result: Name = undefined;

        const len: u16 = @truncate(std.fmt.count(fmt, args));
        const alloc: bool = len > local_size;

        if (len == 0 or len > max_len) return error.BadName;

        const buf: []u8 = blk: {
            if (alloc) {
                result.ptr = @ptrCast(vm.malloc(len) orelse return error.NoMemory);
                break :blk result.localBuffer()[0..len];
            } else {
                break :blk result.localBuffer()[0..len];
            }
        };

        _ = std.fmt.bufPrint(buf, fmt, args) catch return error.NoMemory;

        result.meta = @bitCast(Meta{
            .len = @truncate(len),
            .is_alloc = alloc
        });
        return result;
    }

    pub fn init(val: []const u8) Name {
        std.debug.assert(val.len > 0 and val.len < max_len);

        var result: Name = .{
            .ptr = val.ptr,
        };

        result.meta = @bitCast(Meta{
            .len = @truncate(val.len),
        });

        if (val.len <= local_size) @memcpy(
            result.localBuffer()[0..val.len],
            val
        );
        return result;
    }

    export fn devNameInit(value: [*]const u8, len: usize) Name {
        return Name.init(value[0..len]);
    }

    pub inline fn deinit(self: *Name) void {
        if (self.isAllocated()) vm.free(@constCast(self.ptr));
        self.meta = 0;
    }

    pub fn format(self: *const Name, _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("{s}", .{ self.str() });
    }

    pub inline fn length(self: *const Name) u7 {
        const meta: Meta = @bitCast(self.meta);
        return meta.len;
    }

    inline fn isAllocated(self: *const Name) bool {
        const meta: Meta = @bitCast(self.meta);
        return meta.is_alloc;
    }

    inline fn localBuffer(self: *const Name) *[local_size]u8 {
        return @ptrCast(@constCast(self));
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

fn kernelDriverProbe(_: *const Driver) Driver.Operations.ProbeResult { return .success; }

var platform_bus = Bus.init("platform",.{
    .match = platformBusMatch,
    .remove = platformBusRemove
});

var kernel_driver = Driver.init("kernel", .{
    .probe = .{ .platform = kernelDriverProbe },
    .remove = Driver.Operations.removeStub
});

pub fn preinit() !void {
    try acpi.init();
    try intr.init();

    registerBus(&platform_bus);
    platform_bus.data.addDriver(&kernel_driver);

    try acpi.postInit();
    try utils.arch.devInit();
}

pub fn init() !void {
    intr.enableForCpu();

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

pub inline fn getKernelDriver() *Driver {
    return &kernel_driver.data;
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