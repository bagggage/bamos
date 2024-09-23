//! # Device module

const std = @import("std");

const log = @import("log.zig");
const utils = @import("utils.zig");
const vm = @import("vm.zig");

pub const acpi = @import("dev/stds/acpi.zig");
pub const regs = @import("dev/regs.zig");
pub const io = @import("dev/io.zig");
pub const intr = @import("dev/intr.zig");
pub const pci = @import("dev/stds/pci.zig");

pub const Bus = struct {
    pub const Operations = struct {
        pub const MatchFn = *const fn (*const Driver, *const Device) bool;
        pub const RemoveFn = *const fn (*Device) void;

        match: MatchFn,
        remove: RemoveFn
    };

    const DeviceList = utils.List(Device);
    const DeviceNode = DeviceList.Node;

    name: []const u8,
    type: u32,

    matched: DeviceList = .{},
    unmatched: DeviceList = .{},

    lock: utils.Spinlock = .{},

    ops: Operations,

    pub const nameHash = std.hash.Crc32.hash;

    pub fn init(
        comptime name: []const u8,
        ops: Operations
    ) Bus {
        comptime var lower_name: [name.len]u8 = undefined;
        _ = comptime std.ascii.lowerString(&lower_name, name);

        const temp_name: [lower_name.len]u8 = lower_name;

        return .{
            .name = &temp_name,
            .type = comptime nameHash(&lower_name),
            .ops = ops
        };
    }

    pub fn matchDriver(self: *Bus, driver: *Driver) void {
        const match_impl = self.ops.match;

        self.lock.lock();
        defer self.lock.unlock();

        var node = self.unmatched.first;

        while (node) |dev| : (node = dev.next) {
            if (match_impl(driver, &dev.data)) {
                if (driver.probe(&dev.data) == .missmatch) continue;

                dev.data.driver = driver;

                self.unmatched.remove(dev);
                self.matched.append(dev);
            }
        }
    }

    pub fn addDevice(self: *Bus, node: *DeviceNode) !void {
        const dev = &node.data;
        dev.bus = self;

        self.lock.lock();
        defer self.lock.unlock();

        if (dev.driver != null) {
            self.matched.append(node);
        }
        else {
            self.matchDevice(node);
        }
    }

    pub fn removeDevice(self: *Bus, dev: *Device) void {
        const node: *DeviceNode = @ptrFromInt(@intFromPtr(dev) - @offsetOf(DeviceNode, "data"));

        self.lock.lock();
        defer self.lock.unlock();

        if (dev.driver) |driver| {
            driver.remove(dev);
            self.ops.remove(dev);

            self.matched.remove(node);
        }
        else {
            self.ops.remove(dev);

            self.unmatched.remove(node);
        }

        DeviceReg.free(node);
    }

    pub fn onRemoveDriver(self: *Bus, driver: *const Driver) void {
        self.lock.lock();
        defer self.lock.unlock();

        const node = self.matched.first;

        while (node) |dev| : (node = dev.next) {
            if (dev.data.driver != driver) continue;

            driver.remove(&dev.data);

            self.matched.remove(dev);
            self.unmatched.append(dev);
        }
    }

    fn matchDevice(self: *Bus, dev: *DeviceNode) void {
        const match_impl = self.ops.match;

        var node = DriverReg.reg[DeviceReg.getBusIdx(self)].first;

        while (node) |driver| : (node = driver.next) {
            if (
                match_impl(&driver.data, &dev.data) == false or
                driver.data.probe(&dev.data) == .missmatch
            ) continue;

            dev.data.driver = &driver.data;
            self.matched.append(dev);

            return;
        }

        self.unmatched.append(dev);
    }
};

pub const Device = struct {
    name: []const u8,
    bus: *Bus,

    driver: ?*Driver,
    driver_data: utils.AnyData,
};

pub const Driver = struct {
    pub const Operations = struct {
        pub const ProbeResult = enum {
            missmatch,
            success
        };

        pub const ProbeFn = *const fn (*Device) ProbeResult;
        pub const RemoveFn = *const fn (*Device) void;

        probe: ProbeFn,
        remove: RemoveFn
    };

    name: []const u8,
    bus: *Bus,
    ops: Operations,

    impl_data: utils.AnyData,

    pub inline fn probe(self: *const Driver, device: *Device) Operations.ProbeResult {
        return self.ops.probe(device);
    }

    pub inline fn remove(self: *const Driver, device: *Device) void {
        return self.ops.remove(device);
    }
};

const max_buses = 16;

const DriverReg = struct {
    const DriverList = utils.SList(Driver);
    pub const DriverNode = DriverList.Node;

    pub var reg: [max_buses]DriverList = .{ DriverList{} } ** max_buses;

    var lock = utils.Spinlock.init(.unlocked);
    var oma = vm.ObjectAllocator.init(DriverNode);

    pub fn register(comptime name: []const u8, bus: *Bus, ops: Driver.Operations) !*Driver {
        lock.lock();
        defer lock.unlock();

        const node = oma.alloc(DriverNode) orelse return error.NoMemory;

        node.data.name = name;
        node.data.bus = bus;
        node.data.ops = ops;

        reg[DeviceReg.getBusIdx(bus)].prepend(node);

        bus.matchDriver(&node.data);

        return &node.data;
    }

    pub fn remove(driver: *Driver) void {
        const node: *DriverNode = @ptrFromInt(@intFromPtr(driver) - @offsetOf(DriverNode, "data"));

        {
            const bus_idx = DeviceReg.getBusIdx(driver.bus);

            lock.lock();
            defer lock.unlock();

            reg[bus_idx].remove(node);
        }

        driver.bus.onRemoveDriver();

        lock.lock();
        defer lock.unlock();

        oma.free(node);
    }
};

const DeviceReg = struct {
    var buses: [max_buses]Bus = undefined;

    var lock = utils.Spinlock.init(.unlocked);
    var oma = vm.ObjectAllocator.init(Bus.DeviceNode);

    pub var reg: []Bus = buses[0..0];

    pub fn getBusIdx(bus: *const Bus) usize {
        const base = @intFromPtr(&buses);

        return (@intFromPtr(bus) - base) / @sizeOf(Bus);
    }

    pub inline fn alloc() ?*Bus.DeviceNode {
        lock.lock();
        defer lock.unlock();

        return oma.alloc(Bus.DeviceNode);
    }

    pub inline fn free(node: *Bus.DeviceNode) void {
        lock.lock();
        defer lock.unlock();

        oma.free(node);
    }

    pub fn registerBus(comptime name: []const u8, ops: Bus.Operations) !*Bus {
        lock.lock();
        defer lock.unlock();

        const len = reg.len;

        if (len == max_buses) return error.MaxBusesReached;

        reg.len += 1;
        reg[len] = Bus.init(name, ops);

        return &reg[len];
    }
};

fn platformBusRemove(_: *Device) void {}
fn platformBusMatch(_: *const Driver, _: *const Device) bool { return true; }

var platform_bus: *Bus = undefined;

pub fn init() !void {
    platform_bus = try registerBus("platform", .{
        .match = platformBusMatch,
        .remove = platformBusRemove
    });

    try acpi.init();
    try intr.init();

    try utils.arch.devInit();

    try pci.init();
}

pub inline fn registerBus(
    comptime name: []const u8,
    ops: Bus.Operations
) !*Bus {
    return DeviceReg.registerBus(name, ops);
}

pub fn registerDevice(
    bus: *Bus,
    driver: ?*Driver,
    data: ?*anyopaque
) !*Device {
    const node = DeviceReg.alloc() orelse return error.NoMemory;

    node.data.driver = driver;
    node.data.driver_data.set(data);

    try bus.addDevice(node);

    return &node.data;
}

pub inline fn registerDriver(
    comptime name: []const u8,
    bus: *const Bus,
    ops: Driver.Operations
) !*Driver {
    return DriverReg.register(name, bus, ops);
}

pub inline fn removeDevice(dev: *Device) void {
    dev.bus.removeDevice(dev);
}

pub inline fn removeDriver(driver: *Driver) void {
    DriverReg.remove(driver);
}

pub fn getBus(comptime name: []const u8) !*Bus {
    comptime var lower_name: [name.len]u8 = undefined;
    _ = comptime std.ascii.lowerString(&lower_name, name);

    const bus_type = comptime Bus.nameHash(&lower_name);

    for (DeviceReg.reg) |*bus| {
        if (bus.type == bus_type) return bus;
    }

    return error.UnsupportedBus;
}