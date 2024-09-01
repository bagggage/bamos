//! # Serial port super-simple driver

const std = @import("std");
const builtin = @import("builtin");

const dev = @import("../dev.zig");

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
    "uart",
    .io_ports, .byte,
    &.{
        dev.regs.reg("data", 0),
    }
);

const regs_base = switch (builtin.cpu.arch) {
    .x86_64 => 0x03f8,
    .riscv64 => 0x1000_0000,
    else => @compileError("UART registers base address is undefined for target architecture")
};

const regs = UartRegs{.base = regs_base};

pub inline fn init() !void {
    _ = dev.io.request(
        UartRegs.name, regs_base, 2, .io_ports
    ) orelse return error.Busy;
}

pub inline fn put(byte: u8) void {
    regs.write(.data, byte);
}

pub inline fn write(buffer: []const u8) void {
    for (buffer) |byte| put(byte);
}