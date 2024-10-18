//! PCI Bus builtin driver

const std = @import("std");

const dev = @import("../../dev.zig");
const log = @import("../../log.zig");
const utils = @import("../../utils.zig");
const regs = dev.regs;
const vm = @import("../../vm.zig");

pub const config = @import("pci/config.zig");
pub const intr = @import("pci/intr.zig");

pub const Id = struct {
    pub const any = 0xffff;

    vendor_id: u16 = any,
    device_id: u16 = any,
    class_code: ?config.ClassCode = null,
    subclass: ?config.SubclassCode = null
};

pub const Device = struct {
    device: *dev.Device,

    id: Id,
    config: config.ConfigSpace,
    intr_ctrl: intr.Control,
    data: utils.AnyData = .{},

    pub fn init(cfg: config.ConfigSpace) Device {
        return .{
            .device = undefined,
            .config = cfg,
            .id = .{
                .vendor_id = cfg.get(.vendor_id),
                .device_id = cfg.get(.device_id),
                .class_code = @enumFromInt(cfg.get(.class_code)),
                .subclass = @bitCast(cfg.get(.subclass))
            },
            .intr_ctrl = intr.Control.init(cfg)
        };
    }

    pub inline fn deinit(self: *Device) void {
        if (self.intr_ctrl.meta.is_allocated) self.intr_ctrl.release();
    }

    pub inline fn requestInterrupts(self: *Device, min: u8, max: u8, comptime types: intr.Types) !u8 {
        return self.intr_ctrl.request(self.config, min, max, types);
    }

    pub inline fn setupInterrupt(self: *Device, idx: u16, handler: dev.intr.Handler.Fn, trigger_mode: dev.intr.TriggerMode) !void {
        return self.intr_ctrl.setup(self.device, idx, handler, trigger_mode);
    }

    pub inline fn getCurrentIntrType(self: *Device) enum{int_x,msi,msi_x} {
        std.debug.assert(self.intr_ctrl.meta.is_allocated);

        return switch (self.intr_ctrl.data) {
            .int_x => .int_x,
            .msi => .msi,
            .msi_x => .msi_x
        };
    }

    pub inline fn releaseInterrupts(self: *Device) void {
        return self.intr_ctrl.release();
    }

    pub inline fn from(device: *const dev.Device) *Device {
        std.debug.assert(device.bus == bus);
        return device.driver_data.as(Device) orelse unreachable;
    }
};

pub const Driver = struct {
    match_id: Id,
};

var bus: *dev.Bus = undefined;
var dev_oma = vm.ObjectAllocator.init(Device);

pub fn init() !void {
    bus = try dev.registerBus("pci", .{
        .match = match,
        .remove = remove
    });

    try config.init();
    try enumerate();
}

fn match(driver: *const dev.Driver, device: *const dev.Device) bool {
    const pci_dev = device.driver_data.as(Device) orelse unreachable;
    const pci_driver = driver.impl_data.as(Driver) orelse unreachable;

    return (
        (pci_driver.match_id.vendor_id == Id.any or
        pci_driver.match_id.vendor_id == pci_dev.id.vendor_id)
        and
        (pci_driver.match_id.device_id == Id.any or
        pci_driver.match_id.device_id == pci_dev.id.device_id)
        and
        (pci_driver.match_id.class_code == null or
        pci_driver.match_id.class_code == pci_dev.id.class_code)
        and
        (pci_driver.match_id.subclass == null or
        @as(u8, @bitCast(pci_driver.match_id.subclass.?)) == @as(u8, @bitCast(pci_dev.id.subclass.?)))
    );
}

fn remove(device: *dev.Device) void {
    const pci_dev = device.driver_data.as(Device) orelse unreachable;

    pci_dev.deinit();
    dev_oma.free(pci_dev);
}

fn enumerate() !void {
    for (0..config.getMaxSeg()) |seg_idx|
    {
        bus_loop: for (0..config.getMaxBus(seg_idx)) |bus_idx|
        {
            dev_loop: for (0..config.max_dev) |dev_idx|
            {
                for (0..config.max_func) |func_idx|
                {
                    if (try enumDevice(
                        @truncate(seg_idx),
                        @truncate(bus_idx),
                        @truncate(dev_idx),
                        @truncate(func_idx)
                    ) == false and func_idx == 0)
                    {
                        if (dev_idx == 0)
                            { continue :bus_loop; }
                        else
                            { continue :dev_loop; }
                    }
                }
            }
        }
    }
}

fn enumDevice(seg_idx: u16, bus_idx: u8, dev_idx: u8, func_idx: u8) !bool {
    const cfg = config.ConfigSpace.init(
        seg_idx, bus_idx, dev_idx, func_idx
    );

    const vendor_id = cfg.get(.vendor_id);
    if (vendor_id == 0xffff or vendor_id == 0) return false;

    const pci_dev = dev_oma.alloc(Device) orelse return error.NoMemory;
    pci_dev.* = Device.init(cfg);

    errdefer dev_oma.free(pci_dev);

    const device = try dev.registerDevice(
        try dev.nameFmt(
            "{x:0>4}:{x:0>2}:{x:0>2}.{}",
            .{seg_idx,bus_idx,dev_idx,func_idx}
        ),
        bus, null, pci_dev
    );

    pci_dev.device = device;

    log.debug("PCI:{}: 0x{x:0>4} : 0x{x:0>4}", .{
        device.name, vendor_id, pci_dev.id.device_id
    });

    return true;
}