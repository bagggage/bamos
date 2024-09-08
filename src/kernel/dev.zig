//! # Device module

const std = @import("std");

const log = @import("log.zig");
const utils = @import("utils.zig");
const vm = @import("vm.zig");

pub const regs = @import("dev/regs.zig");
pub const io = @import("dev/io.zig");
pub const pci = @import("dev/stds/pci.zig");

pub const BusOps = struct {
    pub const MatchT = *const fn (*const Driver, *const Device) bool;
    pub const RemoveT = *const fn (*Device) void;

    match: MatchT,
    remove: RemoveT
};

pub const DriverOps = struct {
    pub const ProbeResult = enum {
        missmatch,
        success
    };

    pub const ProbeT = *const fn (*Device) ProbeResult;
    pub const RemoveT = *const fn (*Device) void;

    probe: ProbeT,
    remove: RemoveT
};

pub const Bus = struct {
    const List = utils.List(Device);
    const Node = List.Node;

    name: []const u8,
    type: u32,

    matched: List = .{},
    unmatched: List = .{},

    lock: utils.Spinlock = .{},

    ops: BusOps,

    pub const nameHash = std.hash.Crc32.hash;

    pub fn init(
        comptime name: []const u8,
        ops: BusOps
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

    pub fn addDevice(self: *Bus, node: *Node) !void {
        const dev = &node.data;
        dev.bus = self;

        self.lock.lock();
        defer self.lock.unlock();

        if (dev.driver) |driver| {
            if (driver.bus_type != self.type) return error.InvalidDriverOrBus;

            self.matched.append(node);
        }
        else {
            self.matchDevice(node);
        }
    }

    pub fn removeDevice(self: *Bus, dev: *Device) *Node {
        const node: *Node = @ptrFromInt(@intFromPtr(dev) - @offsetOf(Node, "data"));

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

    fn matchDevice(self: *Bus, dev: *Node) void {
        const match_impl = self.ops.match;

        var node = DriverReg.reg[DeviceReg.getBusIdx(self)].first;

        while (node) |driver| : (node = driver.next) {
            if (match_impl(&driver.data, &dev.data) == false) continue;
            if (driver.data.probe(&dev.data) == .missmatch) continue; 

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
    name: []const u8,
    bus: *Bus,
    ops: DriverOps,

    impl_data: utils.AnyData,

    pub inline fn probe(self: *const Driver, device: *Device) DriverOps.ProbeResult {
        return self.ops.probe(device);
    }

    pub inline fn remove(self: *const Driver, device: *Device) void {
        return self.ops.remove(device);
    }
};

const max_buses = 16;

const DriverReg = struct {
    const List = utils.SList(Driver);
    pub const Node = List.Node;

    pub var reg: [max_buses]List = .{ List{} } ** max_buses;

    var lock = utils.Spinlock.init(.unlocked);
    var oma = vm.ObjectAllocator.init(Node);

    pub fn register(comptime name: []const u8, bus: *Bus, ops: DriverOps) !*Driver {
        lock.lock();
        defer lock.unlock();

        const node = oma.alloc(Node) orelse return error.NoMemory;

        node.data.name = name;
        node.data.bus = bus;
        node.data.ops = ops;

        reg[DeviceReg.getBusIdx(bus)].prepend(node);

        bus.matchDriver(&node.data);

        return &node.data;
    }

    pub fn remove(driver: *Driver) void {
        const node: *Node = @ptrFromInt(@intFromPtr(driver) - @offsetOf(Node, "data"));

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
    var oma = vm.ObjectAllocator.init(Bus.Node);

    pub var reg: []Bus = buses[0..0];

    pub fn getBusIdx(bus: *const Bus) usize {
        const base = @intFromPtr(&buses);

        return (@intFromPtr(bus) - base) / @sizeOf(Bus);
    }

    pub inline fn alloc() ?*Bus.Node {
        lock.lock();
        defer lock.unlock();

        return oma.alloc(Bus.Node);
    }

    pub inline fn free(node: *Bus.Node) void {
        lock.lock();
        defer lock.unlock();

        oma.free(node);
    }

    pub fn registerBus(comptime name: []const u8, ops: BusOps) !*Bus {
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
}

pub fn registerBus(
    comptime name: []const u8,
    ops: BusOps
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
    ops: DriverOps
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