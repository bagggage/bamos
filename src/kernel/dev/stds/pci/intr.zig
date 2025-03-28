//! # PCI Interrupts API

// Copyright (C) 2024 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const config = @import("config.zig");
const dev = @import("../../../dev.zig");
const intr = dev.intr;
const io = dev.io;
const log = std.log.scoped(.@"pci.intr");
const utils = @import("../../../utils.zig");
const vm = @import("../../../vm.zig");

const Msi = struct {
    pub const Msi32Ref = config.ConfigSpaceGroup.Ref(config.Capability.Msi.x32);
    pub const Msi64Ref = config.ConfigSpaceGroup.Ref(config.Capability.Msi.x64);
    pub const MessageControl = config.Capability.Msi.MessageControl;

    ref: union {
        x32: Msi32Ref,
        x64: Msi64Ref
    },
    ctrl: MessageControl,

    id: u8 = 0xFF,
    is_64: bool,

    pub fn init(cfg: config.ConfigSpace, cap_offset: u16) Msi {
        const msi_x32 = cfg.internal.referenceAsOffset(config.Capability.Msi.x32, cap_offset);
        const ctrl = msi_x32.get(MessageControl, .msg_ctrl);

        return .{
            .ref = .{ .x32 = msi_x32 },
            .ctrl = ctrl,
            .is_64 = ctrl.x64_addr == 1,
        };
    }

    pub inline fn deinit(self: *Msi) void {
        if (self.id != 0xFF) intr.releaseMsi(self.id);
    }

    pub inline fn enable(self: *Msi) void {
        self.ctrl.enable = 1;
        self.ref.x32.set(.msg_ctrl, self.ctrl);
    }

    pub inline fn disable(self: *Msi) void {
        self.ctrl.enable = 0;
        self.ref.x32.set(.msg_ctrl, self.ctrl);
    }

    pub inline fn getMax(self: *Msi) u8 {
        return @as(u8, 1) << self.ctrl.multi_msg;
    }

    pub inline fn alloc(self: *Msi, num: u8) u8 {
        std.debug.assert(num > 0 and num <= self.getMax());

        const power = std.math.log2_int(u8, num);

        self.ctrl.multi_msg_enable = power;
        self.ref.x32.set(.msg_ctrl, self.ctrl);

        return @as(u8, 1) << power;
    }

    pub fn maskIdx(self: *Msi, idx: u8, comptime mask: bool) bool {
        if (self.ctrl.per_vec_mask == 0) return false;

        const bit_shift = @as(u32, 1) << @truncate(idx);
        const mask_idx = if (mask) bit_shift else (0xFFFF_FFFF ^ bit_shift);

        if (self.is_64) {
            const mask_bits = self.ref.x64.read(.mask_bits);
            const val = if (mask) mask_bits | mask_idx else mask_bits & mask_idx;
            self.ref.x64.write(.mask_bits, val);
        } else {
            const mask_bits = self.ref.x32.read(.mask_bits);
            const val = if (mask) mask_bits | mask_idx else mask_bits & mask_idx;
            self.ref.x32.write(.mask_bits, val);
        }

        return true;
    }

    pub fn setup(self: *Msi, msg: intr.Msi.Message) void {
        if (self.is_64) {
            self.ref.x64.write(.msg_addr, msg.address);
            self.ref.x64.write(.msg_data, @truncate(msg.data));
        } else {
            self.ref.x32.write(.msg_addr, @truncate(msg.address));
            self.ref.x32.write(.msg_data, @truncate(msg.data));
        }
    }
};

const MsiX = struct {
    pub const MsiXRef = config.ConfigSpaceGroup.Ref(config.Capability.MsiX);
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

    pub fn init(cfg: config.ConfigSpace, cap_offset: u16) MsiX {
        const ref = cfg.internal.referenceAsOffset(config.Capability.MsiX, cap_offset);
        const vec_offset = ref.read(.table_offset);
        const pba_offset = ref.read(.pba_offset);

        const vec_bar: u3 = @truncate(vec_offset);
        const pba_bar: u3 = @truncate(pba_offset);

        const vec_table = vm.getVirtLma(cfg.readBar(vec_bar) + (vec_offset & 0xFFFF_FFF8));
        const pba_table = vm.getVirtLma(cfg.readBar(pba_bar) + (pba_offset & 0xFFFF_FFF8));

        return .{
            .msis = undefined,
            .ref = ref,
            .ctrl = ref.get(MessageControl, .msg_ctrl),
            .vec_table = @ptrFromInt(vec_table),
            .pba_table = @ptrFromInt(pba_table)
        };
    }

    pub fn deinit(self: *MsiX) void {
        for (self.msis, 0..) |msi, i| {
            if (msi == 0xFF) continue;
            intr.releaseMsi(msi);

            self.maskIdx(@truncate(i), true);
        }

        vm.free(@ptrCast(self.msis.ptr));
    }

    pub inline fn enable(self: *MsiX) void {
        self.ctrl.enable = 1;
        self.ref.set(.msg_ctrl, self.ctrl);
    }

    pub inline fn disable(self: *MsiX) void {
        self.ctrl.enable = 0;
        self.ref.set(.msg_ctrl, self.ctrl);
    }

    pub inline fn getMax(self: *MsiX) u16 {
        return self.ctrl.table_size + 1;
    }

    pub fn alloc(self: *MsiX, num: u8) Error!void {
        std.debug.assert(num > 0 and num <= self.getMax());

        const msis= @as([*]u8, @ptrCast(vm.malloc(@sizeOf(u8) * num) orelse return error.NoMemory))[0..num];

        for (0..num) |i| { msis[i] = 0xFF; }

        self.msis = msis;
    }

    pub inline fn maskAll(self: *MsiX, comptime mask: bool) void {
        self.ctrl.func_mask = if (mask) 1 else 0;
        self.ref.set(.msg_ctrl, self.ctrl);
    }

    pub inline fn maskIdx(self: *MsiX, idx: u16, comptime mask: bool) void {
        io.writel(@intFromPtr(&self.vec_table[idx].vec_ctrl), if (mask) 1 else 0);
    }

    pub inline fn setupIdx(self: *MsiX, idx: u16, msg: intr.Msi.Message) void {
        const msg_addr_ptr = @intFromPtr(&self.vec_table[idx].msg_addr);
        const msg_data_ptr = @intFromPtr(&self.vec_table[idx].msg_data);

        io.writel(msg_addr_ptr, @truncate(msg.address));
        io.writel(msg_addr_ptr + @sizeOf(u32), @truncate(msg.address >> @bitSizeOf(u32)));

        io.writel(msg_data_ptr, msg.data);
    }
};

const IntX = struct {
    cfg: config.ConfigSpace,
    pin: u8 = 0,

    pub inline fn init(cfg: config.ConfigSpace) IntX {
        return .{
            .cfg = cfg,
            .pin = cfg.get(.intr_pin)
        };
    }

    pub inline fn enable(self: *const IntX) void {
        var command_reg = self.cfg.getAs(config.Regs.Command, .command);
        command_reg.intr_disable = 0;

        self.cfg.setAs(.command, command_reg);
    }

    pub inline fn disable(self: *const IntX) void {
        var command_reg = self.cfg.getAs(config.Regs.Command, .command);
        command_reg.intr_disable = 1;

        self.cfg.setAs(.command, command_reg);
    }
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

    pub fn init(cfg: config.ConfigSpace) Control {
        var capability = cfg.getCapabilities();

        var msi_offset: u8 = 0;
        var msi_x_offset: u8 = 0;

        while (capability) |cap| : (capability = cap.next()) {
            switch (cap.header.id) {
                .msi => msi_offset = cap.offset,
                .msi_x => msi_x_offset = cap.offset,
                else => continue
            }
        }

        return .{
            .meta = .{
                .is_int_x_avail = cfg.get(.intr_pin) != 0,
                .msi_offset = msi_offset,
                .msi_x_offset = msi_x_offset
            },
            .data = undefined
        };
    }

    pub fn request(self: *Control, cfg: config.ConfigSpace, min: u8, max: u8, comptime types: Types) Error!u8 {
        std.debug.assert(min > 0 and min <= max and self.meta.is_allocated == false);

        var num: u8 = 0;

        if (types.msi_x and self.meta.isMsiXAvail()) {
            var msi_x = MsiX.init(cfg, self.meta.msi_x_offset);

            if (min > msi_x.getMax()) return Error.TooLittleIntr;

            num = std.mem.min(u8, &.{ @truncate(msi_x.getMax()), max });
            try msi_x.alloc(num);

            IntX.init(cfg).disable();
            msi_x.enable();
            msi_x.maskAll(false);

            self.data = .{ .msi_x = msi_x };
        } else if (types.msi and self.meta.isMsiAvail()) {
            var msi = Msi.init(cfg, self.meta.msi_offset);

            if (min > 1) return Error.TooLittleIntr;

            num = 1;

            IntX.init(cfg).disable();
            _ = msi.alloc(1);
            msi.enable();

            self.data = .{ .msi = msi };
        } else if (types.int_x and self.meta.isIntXAvail()) {
            if (min > 1) return Error.TooLittleIntr;

            num = 1;

            const int_x = IntX.init(cfg);
            int_x.enable();

            self.data = .{ .int_x = int_x };
        } else {
            return Error.IntrNotAvail;
        }

        self.meta.is_allocated = true;

        return num;
    }

    pub fn release(self: *Control) void {
        std.debug.assert(self.meta.is_allocated);

        switch (self.data) {
            .int_x => |*int_x| {
                _ = int_x;
                log.err("IntX not implemented yet.", .{});
                unreachable;
            },
            .msi => |*msi| {
                _ = msi.maskIdx(0, true);
                msi.disable();
                msi.deinit();
            },
            .msi_x => |*msi_x| {
                msi_x.disable();
                msi_x.deinit();
            }
        }

        self.meta.is_allocated = false;
    }

    pub fn setup(
        self: *Control, device: *dev.Device, idx: u16, handler: intr.Handler.Fn,
        trigger_mode: intr.TriggerMode, cpu_idx: ?u16
    ) intr.Error!void {
        std.debug.assert(self.meta.is_allocated);

        switch (self.data) {
            .int_x => |*int_x| {
                std.debug.assert(idx == 0);
                _ = int_x;

                return error.NoMemory;
            },
            .msi => |*msi| {
                std.debug.assert(idx == 0);

                const id = try intr.requestMsi(device, handler, trigger_mode, cpu_idx);
                msi.id = id;

                msi.setup(intr.getMsiMessage(id));
                _ = msi.maskIdx(id, false);
            },
            .msi_x => |*msi_x| {
                const id = try intr.requestMsi(device, handler, trigger_mode, cpu_idx);
                msi_x.msis[idx] = id;

                msi_x.setupIdx(idx, intr.getMsiMessage(id));
                msi_x.maskIdx(idx, false);
            }
        }
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