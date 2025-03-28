//! # CMOS driver

// Copyright (C) 2025 Konstantin Pigulevskiy (bagggage@github)

const dev = @import("../../../dev.zig");

const cmos_base = 0x70;

const Ports = dev.regs.Group(
    dev.io.IoPortsMechanism("cmos io", .byte),
    cmos_base,
    null,
    &.{
        dev.regs.reg("cmos_addr", 0x0, null, .write),
        dev.regs.reg("cmos_data", 0x1, null, .rw)
    }
);
const ports: Ports = .{};

pub const IoMechanism = dev.io.Mechanism(
    u8, u8,
    read, write,
    null
);

pub fn init() !void {
    _ = try Ports.init();
}

pub fn read(addr: u8) u8 {
    ports.write(.cmos_addr, addr);
    return ports.read(.cmos_data);
}

pub fn write(addr: u8, data: u8) void {
    ports.write(.cmos_addr, addr);
    ports.write(.cmos_data, data);
}