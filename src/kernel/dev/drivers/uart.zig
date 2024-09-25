//! # Serial port super-simple driver

const std = @import("std");
const builtin = @import("builtin");

const dev = @import("../../dev.zig");

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

const UartRegs = dev.regs.RegsGroup(
    "uart 8250/16450/16550",
    .io_ports, .byte,
    &.{
        // DLAB == 0
        reg("data",         0x0, .rw),
        reg("intr_enable",  0x1, .rw),

        // DLAB == 1
        reg("div_lo",       0x0, .rw),
        reg("div_hi",       0x1, .rw),

        reg("intr_id",      0x2, .ro),

        reg("fifo_ctrl",    0x2, .wo),
        reg("line_ctrl",    0x3, .rw),
        reg("modem_ctrl",   0x4, .rw),

        reg("line_status",  0x5, .ro),
        reg("modem_status", 0x6, .ro),

        reg("scratch",      0x7, .rw),
    }
);

const regs_base = switch (builtin.cpu.arch) {
    .x86_64 => 0x03f8,
    .riscv64 => 0x1000_0000,
    else => @compileError("UART registers base address is undefined for target architecture")
};

const regs = UartRegs{ .base = regs_base };

var driver: *dev.Driver = undefined;
var device: *dev.Device = undefined;

pub fn init() !void {
    const bus = try dev.getBus("platform");

    driver = try dev.registerDriver("ISA UART", bus, .{
        .probe = .{ .platform = probe },
        .remove = remove
    });
}

pub inline fn put(byte: u8) void {
    regs.write(.data, byte);
}

pub inline fn write(buffer: []const u8) void {
    for (buffer) |byte| put(byte);
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

fn probe(self: *const dev.Driver) dev.Driver.Operations.ProbeResult {
    _ = dev.io.request(
        UartRegs.name, regs_base, 2, .io_ports
    ) orelse return .missmatch;

    initPort();

    if (!testPort()) return .missmatch;

    device = self.addDevice(dev.nameOf("UART RS-232"), null) catch {
        dev.io.release(regs_base, .io_ports);
        return .missmatch;
    };

    return .success;
}

fn remove(_: *dev.Device) void {
    dev.io.release(regs_base, .io_ports);
}