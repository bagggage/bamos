//! # Device module

// Copyright (C) 2024-2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const lib = @import("lib.zig");
const log = std.log.scoped(.dev);
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
    const local_size = @sizeOf(Name) - @sizeOf(Meta);

    ptr: [*]const u8 = undefined,
    pad_0: if (@sizeOf([*]u8) == 4) u32 else void = undefined,

    pad_1: u32 = undefined, // 4-bytes
    pad_2: u16 = undefined, // 2-bytes
    pad_3: u8 = undefined,  // 1-byte
                            // = 15 bytes

    meta: u8 = 0,           // + 1 = 16 bytes

    comptime { std.debug.assert(@sizeOf(Name) == 16); }

    pub fn str(self: *const Name) []const u8 {
        const len = self.length();
        return if (self.length() > local_size or self.isAllocated())
                self.ptr[0..len]
            else
                self.localBuffer()[0..len];
    }

    pub fn print(comptime fmt: []const u8, args: anytype) Error!Name {
        var result: Name = undefined;

        const len = std.fmt.count(fmt, args);
        if (len == 0 or len > max_len) return error.BadName;

        const buf: []u8 = if (len > local_size) blk: {
            result.ptr = @ptrCast(vm.gpa.alloc(len) orelse return error.NoMemory);
            break :blk @constCast(result.ptr[0..len]);
        } else result.localBuffer()[0..len];

        _ = std.fmt.bufPrint(buf, fmt, args) catch return error.NoMemory;

        result.meta = @bitCast(Meta{
            .len = @truncate(len),
            .is_alloc = (len > local_size)
        });
        return result;
    }

    pub fn init(val: []const u8) Name {
        std.debug.assert(val.len > 0 and val.len <= max_len);
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

    pub inline fn deinit(self: *Name) void {
        if (self.isAllocated()) vm.gpa.free(@constCast(self.ptr));
        self.meta = 0;
    }

    pub fn format(self: *const Name, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll(self.str());
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

var buses: Bus.List = .{};
var buses_lock: lib.sync.Spinlock = .init(.unlocked);

/// @noexport
const AutoInit = struct {
    const modules = .{
        @import("dev/drivers/input/at-keyboard.zig"),
        @import("dev/drivers/uart/8250.zig"),
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
    platform_bus.addDriver(&kernel_driver);

    classes.Input.preinit();

    try acpi.postInit();
    try lib.arch.devInit();
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

pub export fn registerBus(bus: *Bus) void {
    buses_lock.lock();
    defer buses_lock.unlock();

    buses.prepend(&bus.node);

    log.info("{s} bus was registered", .{bus.name});
}

pub fn registerDevice(comptime bus_name: []const u8, dev: *Device, driver: ?*const Driver) !void {
    const bus = try getBus(bus_name);
    bus.addDevice(dev, driver);
}

pub inline fn removeDevice(dev: *Device) void {
    dev.bus.removeDevice(dev);
}

pub inline fn deleteDevice(dev: *Device) void {
    dev.bus.removeDevice(dev);
    dev.delete();
}

pub inline fn registerDriver(comptime bus_name: []const u8, driver: *Driver) !void {
    const bus = try getBus(bus_name);
    bus.addDriver(driver);
}

pub inline fn removeDriver(driver: *Driver) void {
    driver.bus.removeDriver(driver);
}

pub inline fn getBus(comptime name: []const u8) !*Bus {
    comptime var lower_name: [name.len]u8 = undefined;
    _ = comptime std.ascii.lowerString(&lower_name, name);

    const hash = comptime nameHash(&lower_name);

    return getBusByHash(hash) orelse error.UnsupportedBus;
}

pub inline fn getKernelDriver() *Driver {
    return &kernel_driver;
}

export fn getBusByHash(hash: u32) ?*Bus {
    buses_lock.lock();
    defer buses_lock.unlock();

    var node = buses.first;
    while(node) |n| : (node = n.next) {
        const bus = Bus.fromNode(n);
        if (bus.type == hash) return bus;
    }

    return null;
}
