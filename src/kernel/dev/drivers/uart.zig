// @noexport

//! # Serial port super-simple driver

const std = @import("std");
const builtin = @import("builtin");

const dev = @import("../../dev.zig");
const log = std.log.scoped(.uart);

const reg = dev.regs.reg;

const IntrEnReg = packed struct {
    avail: u1 = 0,
    thr_empty: u1 = 0,
    rlsr_change: u1 = 0,
    msr_change: u1 = 0,
    sleep_mode: u1 = 0,
    low_power: u1 = 0,
    reserved: u2 = 0,
};

const UartRegs = dev.regs.Group(
    dev.io.IoPortsMechanism("uart 8250/16450/16550", .byte),
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

const regs_base = switch (builtin.cpu.arch) {
    .x86_64 => 0x03f8,
    .riscv64 => 0x1000_0000,
    else => @compileError("UART registers base address is undefined for target architecture")
};

const regs = UartRegs{ .dyn_base = regs_base };

var device: *dev.Device = undefined;

pub inline fn init() !void {
    try initDevice(dev.getKernelDriver());
}

pub fn write(bytes: []const u8) void {
    for (bytes) |byte| {
        regs.write(.data, byte);
    }
}

fn initPort() void {
    regs.write(.intr_enable, 0x00); // Disable all interrupts

    regs.write(.line_ctrl, 0x80);   // Enable DLAB (set baud rate divisor)
    regs.write(.div_lo, 0x03);      // Set divisor to 3 (lo byte) 38400 baud
    regs.write(.div_hi, 0x00);      //                  (hi byte)

    regs.write(.line_ctrl, 0x03);   // 8 bits, no parity, one stop bit
    regs.write(.fifo_ctrl, 0xC7);   // Enable FIFO, clear them, with 14-byte threshold

    regs.write(.modem_ctrl, 0x0B);  // IRQs enabled, RTS/DSR set
}

fn testPort() bool {
    const test_byte = 0xAF;
    const ctrl_val = regs.read(.modem_ctrl);

    // Set in loopback mode
    regs.write(.modem_ctrl, 0x1E);
    defer regs.write(.modem_ctrl, ctrl_val);

    regs.write(.data, test_byte);

    return regs.read(.data) == test_byte;
}

fn initDevice(self: *const dev.Driver) !void {
    _ = try UartRegs.initBase(regs_base);
    errdefer dev.io.release(regs_base, .io_ports);

    initPort();
    if (!testPort()) return; // COM port is unavailable.

    device = try self.addDevice(dev.nameOf("UART RS-232"), null);
}
