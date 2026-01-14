//! # Serial port super-simple driver

// Copyright (C) 2024-2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");
const builtin = @import("builtin");

const dev = @import("../../../dev.zig");
const devfs = vfs.devfs;
const log = std.log.scoped(.@"uart.8250");
const Teletype = dev.classes.Teletype;
const vfs = @import("../../../vfs.zig");

comptime {
    switch (builtin.cpu.arch) {
        .x86,
        .x86_64 => {},
        else => @compileError("uart-8250 driver is not supported on target architecture")
    }
}

const IntrEnReg = packed struct {
    avail: u1 = 0,
    thr_empty: u1 = 0,
    rlsr_change: u1 = 0,
    msr_change: u1 = 0,
    sleep_mode: u1 = 0,
    low_power: u1 = 0,
    reserved: u2 = 0,
};

const LineStatusReg = packed struct {
    data_ready: bool = false,
    overrun_error: bool = false,
    parity_error: bool = false,
    framing_error: bool = false,
    break_intr: bool = false,
    empty_thr: bool = false,
    empty_dhr: bool = false,
    fifo_error: bool = false,
};

const reg = dev.regs.reg;

const Port = struct {
    const Registers = dev.regs.Group(
        dev.io.IoPortsMechanism("uart-8250", .byte),
        null, null,
        &.{
            // DLAB == 0
            reg("data",         0x0, null, .rw),
            reg("intr_enable",  0x1, null, .rw),

            // DLAB == 1
            reg("div_lo",       0x0, null, .rw),
            reg("div_hi",       0x1, null, .rw),

            reg("intr_id",      0x2, null, .read),
            reg("fifo_ctrl",    0x2, null, .write),

            reg("line_ctrl",    0x3, null, .rw),
            reg("modem_ctrl",   0x4, null, .rw),

            reg("line_status",  0x5, null, .read),
            reg("modem_status", 0x6, null, .read),

            reg("scratch",      0x7, null, .rw),
        }
    );

    const Hardware = struct {
        base: comptime_int,
        irq: comptime_int,
    };

    // 8250 FIFO size
    const fifo_size = 16;

    device: dev.Device = undefined,
    regs: Registers = undefined,
    immediate_intr: dev.intr.SoftHandler = .{
        .func = &immediateIrqHandler,
    },

    fn setup(self: *Port, driver: *dev.Driver, hw: Hardware) !void {
        self.regs = try .initBase(hw.base);
        errdefer dev.io.release(self.regs.dyn_base, .io_ports);

        if (!self.validate()) return; // COM port is unavailable.

        self.device = .init(try dev.Name.print("{x}.uart-8250", .{hw.base}), null);

        driver.attachDevice(&self.device);
        errdefer driver.detachDevice(&self.device);

        if (hw.irq != 0) {
            try dev.intr.requestIrq(hw.irq, &self.device, &irqHandler, .edge, true);
        }
        errdefer if (hw.irq != 0) dev.intr.releaseIrq(hw.irq, &self.device);

        const tty = try dev.obj.new(Teletype);
        errdefer dev.obj.free(Teletype, tty);

        try tty.setup("ttyS", &dev_region, &tty_ops, self);

        self.device.driver_data.set(tty);
        self.immediate_intr.ctx = tty;

        try dev.obj.add(Teletype, tty);

        // debug
        self.reset();
    }

    fn reset(self: *Port) void {
        self.regs.write(.intr_enable, 0x00); // Disable all interrupts

        self.regs.write(.line_ctrl, 0x80);   // Enable DLAB (set baud rate divisor)
        self.regs.write(.div_lo, 0x01);      // Set divisor to 1 (lo byte) 115200 baud
        self.regs.write(.div_hi, 0x00);      //                  (hi byte)

        self.regs.write(.line_ctrl, 0x03);   // 8 bits, no parity, one stop bit
        self.regs.write(.fifo_ctrl, 0xC7);   // Enable FIFO, clear them, with 14-byte threshold

        self.regs.write(.modem_ctrl, 0x0B);  // IRQs enabled, RTS/DSR set
    }

    fn write(self: *Port, buffer: []const u8) void {
        writeRaw(self.regs, buffer);
    } 

    fn writeRaw(regs: Registers, buffer: []const u8) void {
        waitReadyToSend(regs);

        var i: u32 = 0;
        for (buffer) |byte| {
            if (i == fifo_size) {
                waitReadyToSend(regs);
                i = 0;
            }
            
            regs.write(.data, byte);
            i += 1;
        }
    }

    inline fn waitReadyToSend(regs: Registers) void {
        while (!regs.get(LineStatusReg, .line_status).empty_thr) {
            std.atomic.spinLoopHint();
        }
    }

    inline fn enableIrq(self: *Port) void {
        self.regs.write(.intr_enable, 0x1);
    }

    inline fn disableIrq(self: *Port) void {
        self.regs.write(.intr_enable, 0x0);
    }

    fn validate(self: *Port) bool {
        const test_byte = 0xAF;
        self.regs.write(.scratch, 0x00);
        self.regs.write(.scratch, test_byte);

        return self.regs.read(.scratch) == test_byte;
    }

    fn validateLoopback(self: *Port) bool {
        const test_byte = 0xAF;
        const ctrl_val = self.regs.read(.modem_ctrl);

        // Set in loopback mode
        self.regs.write(.modem_ctrl, 0x1E);
        defer self.regs.write(.modem_ctrl, ctrl_val);

        self.regs.write(.data, test_byte);
        return self.regs.read(.data) == test_byte;
    }

    inline fn fromDevice(device: *dev.Device) *Port {
        return @fieldParentPtr("device", device);
    }

    inline fn fromTeletype(tty: *Teletype) *Port {
        return tty.data.as(Port).?;
    }
};

const hw_ports = [_]Port.Hardware{
    .{ .base = 0x3f8, .irq = 4 },
    .{ .base = 0x2f8, .irq = 3 },
    .{ .base = 0x3e8, .irq = 4 },
    .{ .base = 0x2e8, .irq = 3 }
};

var ports = [_]Port{ .{} } ** hw_ports.len;

const tty_ops: Teletype.Operations = .{
    .flush = ttyFlush,
    .enable = ttyEnable,
    .disable = ttyDisable
};

var dev_region: devfs.Region = .{
    .major = 4
};

pub fn init() !void {
    const driver = dev.getKernelDriver();

    inline for (&ports, hw_ports) |*port, hw| {
        try port.setup(driver, hw);
    }
}

pub fn write(buffer: []const u8) void {
    const regs: Port.Registers = .{ .dyn_base = hw_ports[0].base };
    Port.writeRaw(regs, buffer);
}

fn irqHandler(device: *dev.Device) bool {
    const port = Port.fromDevice(device);

    const intr_id = port.regs.read(.intr_id);
    if ((intr_id & 1) == 1) return false;

    const cause = (intr_id & 0b1110) >> 1;
    switch (cause) {
        0b010,
        0b110 => dev.intr.scheduleImmediate(&port.immediate_intr),
        0b000 => _ = port.regs.read(.modem_status),
        0b011 => _ = port.regs.read(.line_status),
        else => {}
    }

    return true;
}

fn immediateIrqHandler(ctx: ?*anyopaque) void {
    const tty: *Teletype = @ptrCast(@alignCast(ctx.?));
    const port = Port.fromTeletype(tty);

    const max_len = 16;
    var buffer: [max_len]u8 = undefined;
    var pos: usize = 0;

    while (port.regs.read(.intr_id) & 0b1110 == 0b1100) : (pos += 1) {
        buffer[pos] = port.regs.read(.data);
    }

    tty.insertInput(buffer[0..pos]) catch {};
}

fn ttyFlush(tty: *Teletype, buffer: []const u8) Teletype.Error!void {
    const port = Port.fromTeletype(tty);
    port.write(buffer);
}

fn ttyEnable(tty: *Teletype) Teletype.Error!void {
    const port = Port.fromTeletype(tty);

    tty.in_buffer.reset();
    tty.in_seek = 0;

    try tty.setLineDiscipline(&Teletype.LineDiscipline.tty_disc);
    try tty.in_buffer.ensureCapacity(1);

    port.enableIrq();
}

fn ttyDisable(tty: *Teletype) void {
    const port = Port.fromTeletype(tty);
    port.disableIrq();

    tty.in_buffer.deinit();
}
