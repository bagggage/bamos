//! # PCI Bus builtin driver

// Copyright (C) 2024-2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const bindings = @import("../../bindings.zig");
const dev = @import("../../dev.zig");
const lib = @import("../../lib.zig");
const log = std.log.scoped(.pci);
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
    data: lib.AnyData = .{},

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

    pub inline fn setupInterrupt(
        self: *Device, idx: u16,
        handler: dev.intr.Handler.Fn, trigger_mode: dev.intr.TriggerMode,
        cpu_idx: ?u16
    ) !void {
        return self.intr_ctrl.setup(
            self.device, idx,
            handler, trigger_mode, cpu_idx
        );
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

    /// Mask/unmask previously allocated interrupt line.
    /// 
    /// Returns `true` if operation succed, `false` otherwise
    /// (`msi` interrupts may not support masking specific line,
    /// masking for `int_x` is not implemented yet)
    pub inline fn maskIntr(self: *Device, idx: u8, mask: bool) bool {
        return self.intr_ctrl.maskIdx(idx, mask);
    }

    pub inline fn from(device: *const dev.Device) *Device {
        return device.driver_data.asPtr(Device) orelse unreachable;
    }
};

pub const Driver = struct {
    base: dev.Driver,
    match_id: Id,

    pub fn init(
        comptime name: []const u8,
        comptime ops: dev.Driver.Operations,
        comptime match_id: Id
    ) Driver {
        return .{
            .base = dev.Driver.init(name, ops),
            .match_id = match_id,
        };
    }

    pub inline fn from(driver: *const dev.Driver) *const Driver {
        return @fieldParentPtr("base", driver);
    }
};

pub inline fn findDevice(seg: u16, b: u8, d: u8, f: u8) ?*Device {
    return bindings.getInstance().dev.pci.findDevice(seg, b, d, f);
}
