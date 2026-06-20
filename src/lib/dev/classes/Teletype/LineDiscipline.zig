//! # TTY Line Discipline

// Copyright (C) 2026 Konstantin Pigulevskiy (bagggage@github)

const bindings = @import("../../../bindings.zig");
const Teletype = @import("../Teletype.zig");

const Self = @This();

pub const max_discpline_num = 32;

pub const Builtin = enum(u5) {
    tty   = 0,
    slip  = 1,
    mouse = 2,
    ppp   = 3,

    irda  = 11,
    hdlc  = 13,
    hci   = 14,
    pps   = 18,

    gsm0710 = 21,
    @"null" = 27,
    throw   = 31,

    pub inline fn toInt(self: Builtin) u5 {
        return @intFromEnum(self);
    }
};

pub const Operations = struct {
    pub const SetupFn = *const fn (*Teletype) Teletype.Error!void;
    pub const ReadFn = *const fn (*Teletype, []u8) Teletype.Error!usize;
    pub const ReceiveFn = *const fn (*Teletype, []const u8) Teletype.Error!void;
    pub const WriteFn = *const fn (*Teletype, []const u8) Teletype.Error!usize;

    setup: ?SetupFn = null,
    read: ReadFn,
    receive: ReceiveFn,
    write: WriteFn,
};

name: []const u8,
num: u5,

ops: Operations,

pub inline fn choose(num: Builtin) *const Self {
    return bindings.getInstance().dev.classes.teletype.chooseLineDiscipline(num);
}

pub inline fn setup(self: *const Self, tty: *Teletype) Teletype.Error!void {
    const callback = self.ops.setup orelse return;
    try callback(tty);
} 

pub inline fn read(self: *const Self, tty: *Teletype, buffer: []u8) Teletype.Error!usize {
    return self.ops.read(tty, buffer);
}

pub inline fn receive(self: *const Self, tty: *Teletype, buffer: []const u8) Teletype.Error!void {
    return self.ops.receive(tty, buffer);
}

pub inline fn write(self: *const Self, tty: *Teletype, buffer: []const u8) Teletype.Error!usize {
    return self.ops.write(tty, buffer);
}
