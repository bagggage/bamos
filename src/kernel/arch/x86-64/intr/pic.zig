//! # 8259A PIC Driver

const dev = @import("../../../dev.zig");
const io = dev.io;
const intr = dev.intr;

pub const Regs = enum(u1) { command = 0x0, data = 0x1 };
pub const Chip = enum(u8) { master = 0x20, slave = 0xa0 };

pub fn init() !void {
    _ = io.request("PIC Master", @intFromEnum(Chip.master), 0x2, .io_ports) orelse return error.IoBusy;
    _ = io.request("PIC Slave", @intFromEnum(Chip.slave), 0x2, .io_ports) orelse return error.IoBusy;
}

pub fn chip() intr.Chip {
    return .{ .name = "8259 PIC", .ops = undefined };
}

pub inline fn disable() void {
    write(.master, .data, 0xff);
    write(.slave, .data, 0xff);
}

pub inline fn read(pic_chip: Chip) u8 {
    return io.inb(@intFromEnum(pic_chip) + @intFromEnum(Regs.data));
}

pub inline fn write(pic_chip: Chip, reg: Regs, value: u8) void {
    io.outb(value, @intFromEnum(pic_chip) + @intFromEnum(reg));
}

fn eoi() void {
    @setRuntimeSafety(false);
    // TODO
}
