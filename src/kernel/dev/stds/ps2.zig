//! # PS/2 i8042 Controller

// Copyright (C) 2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const acpi = @import("acpi.zig");
const dev = @import("../../dev.zig");
const log = std.log.scoped(.@"ps2.i8042");
const lib = @import("../../lib.zig");
const regs = dev.regs;

pub const Error = dev.io.Error || error{IoFailed};

pub const Status = packed struct {
    out_full: bool = false,
    in_full: bool = false,
    sys_flag: bool = false,
    cmd_data: u1 = 0,
    specific0: u1 = 0,
    specific1: u1 = 0,
    timeout_error: bool = false,
    parity_error: bool = false,
};

/// Source: https://wiki.osdev.org/I8042_PS/2_Controller
pub const CtrlCommand = enum(u8) {
    read_ram = 0x20,
    write_ram = 0x60,

    off_2nd_port = 0xa7,
    on_2nd_port = 0xa8,

    test_2nd_port = 0xa9,
    test_ps2_ctrl = 0xaa,
    test_1st_port = 0xab,

    diag_dump = 0xac,

    off_1st_port = 0xad,
    on_1st_port = 0xae,

    read_in = 0xc0,
    in_03_stat_47 = 0xc1,
    in_47_stat_47 = 0xc2,

    read_out = 0xd0,
    write_out = 0xd1,
    write_1st_port = 0xd2,
    write_2nd_port = 0xd3,
    write_2nd_port_in = 0xd4,

    pulse_out_line = 0xf0,
    _,

    pub inline fn toInt(self: CtrlCommand) u8 {
        return @intFromEnum(self);
    }

    pub fn haveResponse(self: CtrlCommand) bool {
        return switch (self) {
            .read_ram, .test_2nd_port, .test_ps2_ctrl, .test_1st_port, .diag_dump, .read_in, .read_out => true,
            else => false,
        };
    }
};

pub const Response = enum(u8) {
    ack = 0xfa,
    resend = 0xfe,
    echo = 0xee,
    test_passed = 0xaa,
    _,

    pub inline fn toInt(self: Response) u8 {
        return @intFromEnum(self);
    }

    pub inline fn isValid(self: Response) bool {
        return switch (self) {
            .ack, .resend, .echo, .test_passed => true,
            else => false,
        };
    }
};

/// Source: https://isdaman.com/alsos/hardware/mouse/ps2interface.htm
const MiceCommand = enum(u8) {
    status_request = 0xe9,
    set_stream_mode = 0xea,
    read_data = 0xeb,
    reset_wrap_mode = 0xec,
    set_wrap_mode = 0xee,
    set_remote_mode = 0xf0,
    get_dev_id = 0xf2,
    set_sample_rate = 0xf3,
    enable_data_rep = 0xf4,
    disable_data_rep = 0xf5,
    set_defaults = 0xf6,

    resend = 0xfe,
    reset = 0xff,

    pub inline fn toInt(self: MiceCommand) u8 {
        return @intFromEnum(self);
    }
};

pub const Config = packed struct {
    ps2_1st_intr: bool = false,
    ps2_2nd_intr: bool = false,

    sys_flag: bool = false,
    _reserved0: u1 = 0,

    ps2_1st_clk: bool = false,
    ps2_2nd_clk: bool = false,
    ps2_1st_tsl: u1 = 0,

    _reserved1: u1 = 0
};

pub const OutputPort = packed struct {
    reset: u1 = 1,
    a20: u1 = 1,

    ps2_2nd_clk: u1 = 0,
    ps2_2nd_data: u1 = 0,

    ps2_1st_full: bool = 0,
    ps2_2nd_full: bool = 0,

    ps2_1st_clk: u1 = 0,
    ps2_1st_data: u1 = 0,
};

pub const device = opaque {
    /// Common PS/2 device commands
    pub const Command = enum(u8) {
        echo = 0xee,
        identify = 0xf2,
        enable_data_send = 0xf4,
        disable_data_send = 0xf5,
        set_defaults = 0xf6,
        resend = 0xfe,
        reset = 0xff,

        _,

        pub inline fn toInt(self: Command) u8 {
            return @intFromEnum(self);
        }
    };

    /// Source: https://wiki.osdev.org/I8042_PS/2_Controller#Detecting_PS.2F2_Device_Types
    pub const Id = enum(u8) {
        at_keyboard,
        mouse_ps2,

        mouse_scroll_whell,
        mouse_5_buttons,

        mf2_keyboard,
        short_keyboard,

        ncd_n97_keyboard,
        @"122_key_keyboard",

        japanese_G_keyboard,
        japanese_P_keyboard,
        japanese_A_keyboard,

        ncd_sun_keyboard,

        unknown,
    };
};

const io_timeout = 16384;

var io: regs.Group(
    dev.io.IoPortsMechanism("PS/2 i8042", .byte),
    0x60, null,
    &.{
        regs.reg("data", 0x0, null, .rw),
        regs.reg("status", 0x4, null, .read),
        regs.reg("command", 0x4, null, .write)
    }
) = undefined;

var second_port: bool = false;
var available: bool = false;

pub fn init() !void {
    if (acpi.getFadt().iapc_boot_arch & 0x2 == 0) return;

    io = try .init();
    reset() catch |err| {
        log.warn("reset failed: {t}", .{err});
        return;
    };
    available = true;

    log.info("ports: {}", .{getPortsNum()});
}

pub inline fn isAvailable() bool {
    return available;
}

pub inline fn getPortsNum() u2 {
    return if (second_port) 2 else 1;
}

pub fn identifyDevice(port: u1) Error!device.Id {
    try sendPortCmdAck(port, device.Command.disable_data_send.toInt());
    try sendPortCmdAck(port, device.Command.identify.toInt());

    return try readDeviceId();
}

pub fn resetDevice(port: u1) Error!device.Id {
    try sendPortCmdAck(port, device.Command.reset.toInt());
    return try readDeviceId();
}

pub fn sendCtrlCmd(cmd: CtrlCommand) Error!?u8 {
    try waitForStatusClear(.{ .in_full = true });
    io.write(.command, cmd.toInt());

    if (!cmd.haveResponse()) return null;
    return try readData();
}

pub fn sendCtrlLongCmd(cmd: CtrlCommand, byte: u8) Error!?u8 {
    io.write(.command, cmd.toInt());
    try writeData(byte);

    if (!cmd.haveResponse()) return null;
    return try readData();
}

pub inline fn readStatus() Status {
    return @bitCast(io.read(.status));
}

pub inline fn readCtrlConfig() Error!Config {
    return @bitCast((try sendCtrlCmd(.read_ram)).?);
}

pub inline fn writeCtrlConfig(cfg: Config) Error!void {
    _ = try sendCtrlLongCmd(.write_ram, @bitCast(cfg));
}

pub inline fn sendPortCmdAck(port: u1, cmd: u8) Error!void {
    const response = try sendPortCmd(port, cmd);
    if (response != .ack) {
        log.debug("command fail: 0x{x}", .{@intFromEnum(response)});
        return error.IoFailed;
    }
}

pub fn sendPortCmd(port: u1, cmd: u8) Error!Response {
    const max_retries = 6;
    for (0..max_retries) |_| {
        const response = try switch (port) {
            0 => send1stPort(cmd),
            1 => send2ndPort(cmd),
        };
        if (response != .resend) return response;
    }

    return error.IoFailed;
}

pub inline fn send1stPort(cmd: u8) Error!Response {
    try writeData(cmd);
    return @enumFromInt(try readData());
}

pub inline fn send2ndPort(cmd: u8) Error!Response {
    _ = try sendCtrlLongCmd(.write_2nd_port_in, cmd);
    return @enumFromInt(try readData());
}

pub inline fn readDataRaw() u8 {
    return io.read(.data);
}

pub inline fn readData() Error!u8 {
    try waitForStatus(.{ .out_full = true });
    return io.read(.data);
}

pub inline fn writeData(byte: u8) Error!void {
    try waitForStatusClear(.{ .in_full = true });
    io.write(.data, byte);
}

pub inline fn getIrqPin(port: u1) u8 {
    return switch (port) {
        0 => 1,
        1 => 12,
    };
}

pub fn enableIrq(port: u1) !void {
    var config = try readCtrlConfig();
    switch (port) {
        0 => config.ps2_1st_intr = true,
        1 => config.ps2_2nd_intr = true,
    }
    try writeCtrlConfig(config);
}

pub fn disableIrq(port: u1) !void {
    var config = try readCtrlConfig();
    switch (port) {
        0 => config.ps2_1st_intr = false,
        1 => config.ps2_2nd_intr = false,
    }
    try writeCtrlConfig(config);
}

fn reset() !void {
    _ = try sendCtrlCmd(.off_1st_port);
    _ = try sendCtrlCmd(.off_2nd_port);

    // flush output buffer
    dev.io.delay(io_timeout);
    _ = io.read(.data);

    // configure
    var config = try readCtrlConfig();
    config.ps2_1st_intr = false;
    config.ps2_2nd_intr = false;
    config.ps2_1st_tsl = 0;
    try writeCtrlConfig(config);

    if (try sendCtrlCmd(.test_ps2_ctrl) != 0x55) return error.SelfTestFailed;

    // check if 2nd port is exists
    _ = try sendCtrlCmd(.on_2nd_port);
    second_port = !(try readCtrlConfig()).ps2_2nd_clk;

    _ = try sendCtrlCmd(.off_2nd_port);

    // test and enable ports
    var result = (try sendCtrlCmd(.test_1st_port)).?;
    if (result != 0x00) return error.PortTestFailed;

    _ = try sendCtrlCmd(.on_1st_port);

    if (second_port) {
        result = (try sendCtrlCmd(.test_2nd_port)).?;
        if (result != 0x00) {
            log.warn("2nd port test failed: 0x{x}", .{result});
            second_port = false;
            return;
        }
        _ = try sendCtrlCmd(.on_2nd_port);
    }
}

fn readDeviceId() Error!device.Id {
    const byte1 = readData() catch return .at_keyboard;
    const byte2 = readData() catch return switch (byte1) {
        0x00 => .mouse_ps2,
        0x03 => .mouse_scroll_whell,
        0x04 => .mouse_5_buttons,
        else => .unknown,
    };

    switch (byte1) {
        0xAB => {},
        0xAC => return if (byte2 == 0xA1) .ncd_sun_keyboard else .unknown,
        else => return .unknown,
    }

    // 0xAB, 0x?
    return switch (byte2) {
        // On some laptops 0x41 is returned even if
        // translation is disabled.
        0x41, 0x83, 0x8C => .mf2_keyboard,
        0x84 => .short_keyboard,
        0x85 => .ncd_n97_keyboard,
        0x86 => .@"122_key_keyboard",
        0x90 => .japanese_G_keyboard,
        0x91 => .japanese_P_keyboard,
        0x92 => .japanese_A_keyboard,
        else => .unknown,
    };
}

fn waitForStatus(comptime mask: Status) Error!void {
    try dev.io.waitFor(opaque {
        inline fn check(_: lib.AnyData) bool {
            const mask_int: u8 = comptime @bitCast(mask);
            return io.read(.status) & mask_int == mask_int;
        }
    }.check, .{}, io_timeout);
}

fn waitForStatusClear(comptime mask: Status) Error!void {
    try dev.io.waitFor(opaque {
        inline fn check(_: lib.AnyData) bool {
            const mask_int: u8 = comptime @bitCast(mask);
            return io.read(.status) & mask_int == 0;
        }
    }.check, .{}, io_timeout);
}
