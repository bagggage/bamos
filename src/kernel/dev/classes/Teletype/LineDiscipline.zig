//! # TTY Line Discipline

// Copyright (C) 2026 Konstantin Pigulevskiy (bagggage@github)

const Teletype = @import("../Teletype.zig");

const Self = @This();

pub const Operations = struct {
    pub const SetupFn = *const fn (*Teletype) Teletype.Error!void;
    pub const ReadFn = *const fn (*Teletype, []u8) Teletype.Error!usize;
    pub const ReceiveFn = *const fn (*Teletype, []const u8) Teletype.Error!void;

    setup: ?SetupFn = null,
    read: ReadFn,
    receive: ReceiveFn,
};

pub const null_disc: Self = .{
    .name = "null",
    .ops = .{
        .read = &nullRead,
        .receive = &nullReceive
    }
};

pub const throw_disc: Self = .{
    .name = "throw",
    .ops = .{
        .read = &throwRead,
        .receive = &throwReceive
    }
};

pub const tty_disc = @import("tty_discipline.zig").self;

name: []const u8,
ops: Operations,

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

fn nullRead(_: *Teletype, _: []u8) Teletype.Error!usize {
    return 0;
}

fn nullReceive(_: *Teletype, _: []const u8) Teletype.Error!void {
    return;
}

fn throwRead(tty: *Teletype, buffer: []u8) Teletype.Error!usize {
    return tty.readInput(buffer);
}

fn throwReceive(tty: *Teletype, buffer: []const u8) Teletype.Error!void {
    _ = tty.bufferInput(buffer);
}
