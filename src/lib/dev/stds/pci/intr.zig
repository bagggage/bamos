//! # PCI Interrupts API

// Copyright (C) 2024 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const bindings = @import("../../../bindings.zig");
const config = @import("config.zig");
const dev = @import("../../../dev.zig");
const intr = dev.intr;
const io = dev.io;
const vm = @import("../../../vm.zig");

const Msi = struct {
    pub const Msi32Ref = config.ConfigSpace.Group.Ref(config.Capability.Msi.x32);
    pub const Msi64Ref = config.ConfigSpace.Group.Ref(config.Capability.Msi.x64);
    pub const MessageControl = config.Capability.Msi.MessageControl;

    ref: union {
        x32: Msi32Ref,
        x64: Msi64Ref
    },
    ctrl: MessageControl,

    id: u8 = 0xFF,
    is_64: bool,
};

const MsiX = struct {
    pub const MsiXRef = config.ConfigSpace.Group.Ref(config.Capability.MsiX);
    pub const MessageControl = config.Capability.MsiX.MessageControl;

    const VectorEntry = extern struct {
        msg_addr: usize,
        msg_data: u32,
        vec_ctrl: u32
    };

    ref: MsiXRef,
    ctrl: MessageControl,

    vec_table: [*]VectorEntry,
    pba_table: [*]u8,

    msis: []u8,
};

const IntX = struct {
    cfg: config.ConfigSpace,
    pin: u8 = 0,
};

pub const Control = struct {
    const Meta = struct {
        is_allocated: bool = false,

        is_int_x_avail: bool,
        msi_offset: u8,
        msi_x_offset: u8,

        pub inline fn isIntXAvail(self: Meta) bool {
            return self.is_int_x_avail;
        }

        pub inline fn isMsiAvail(self: Meta) bool {
            return self.msi_offset != 0;
        }

        pub inline fn isMsiXAvail(self: Meta) bool {
            return self.msi_x_offset != 0;
        }
    };

    meta: Meta,
    data: union(enum) {
        int_x: IntX,
        msi: Msi,
        msi_x: MsiX,
    },

    pub inline fn init(cfg: config.ConfigSpace) Control {
        return bindings.getInstance().dev.pci.intr.init(cfg);
    }

    pub inline fn request(self: *Control, cfg: config.ConfigSpace, min: u8, max: u8, types: Types) Error!u8 {
        return bindings.getInstance().dev.pci.intr.request(self, cfg, min, max, types);
    }

    pub inline fn release(self: *Control) void {
        bindings.getInstance().dev.pci.intr.release(self);
    }

    pub inline fn setup(
        self: *Control,
        device: *dev.Device,
        idx: u16,
        handler: intr.Handler.Fn,
        trigger_mode: intr.TriggerMode,
        cpu_idx: ?u16,
    ) intr.Error!void {
        return bindings.getInstance().dev.pci.intr.setup(self, device, idx, handler, trigger_mode, cpu_idx);
    }

    pub inline fn maskIdx(self: *Control, idx: u8, mask: bool) bool {
        return bindings.getInstance().dev.pci.intr.maskIdx(self, idx, mask);
    }
};

pub const Types = packed struct {
    int_x: bool = false,
    msi: bool = false,
    msi_x: bool = false,

    pub const all = Types{ .int_x = true, .msi = true, .msi_x = true };
    pub const msi_s = Types{ .msi = true, .msi_x = true };
};

pub const Error = error {
    TooLittleIntr,
    IntrNotAvail,
    NoMemory
};
