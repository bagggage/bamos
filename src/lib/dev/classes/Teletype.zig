//! # Teletypewriter device

// Copyright (C) 2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const bindings = @import("../../bindings.zig");
const devfs = @import("../../vfs.zig").devfs;
const sched = @import("../../sched.zig");
const lib = @import("../../lib.zig");
const linux = std.os.linux;
const sys = @import("../../sys.zig");
const vfs = @import("../../vfs.zig");
const vm = @import("../../vm.zig");

const Self = @This();

pub const termios = linux.termios2;
pub const T = linux.T;
pub const V = linux.V;

pub const WinSize = extern struct {
    rows: u16,
    cols: u16
};

pub const LineDiscipline = @import("Teletype/LineDiscipline.zig");

pub const Error = vm.Error || error {
    BadOperation,
    IoFailed
};

pub const Operations = struct {
    pub const FlushFn = *const fn (self: *Self, buffer: []const u8) Error!void;
    pub const EnableFn = *const fn (self: *Self) Error!void;
    pub const DisableFn = *const fn (self: *Self) void;
    pub const ConfigFn = *const fn (self: *Self, old: *const termios) Error!void;
    pub const ControlFn = *const fn (self: *Self, cmd: u32, arg: lib.AnyData) vfs.Error!void;

    flush: FlushFn,
    enable: EnableFn,
    disable: DisableFn,
    config: ?ConfigFn = null,
    control: ?ControlFn = null,
};

pub const Buffer = struct {
    ptr: [*]u8 = undefined,
    len: u32 = 0,
    pos: u32 = 0,
};

pub const alloc_config: vm.auto.Config = .{
    .allocator = .oma,
};

dev_file: devfs.DevFile,

ops: *const Operations,
line_disc: *const LineDiscipline = undefined,

sid: ?*sys.Process.Id = null,
foreground_group: ?*sys.Process.Id = null,

config: termios = std.mem.zeroes(termios),
conf_lock: lib.sync.Spinlock = .{},

in_buffer: Buffer = .{},
out_buffer: Buffer = .{},

in_lock: lib.sync.Spinlock = .{},
out_lock: lib.sync.Spinlock = .{},

in_seek: u32 = 0,
in_wait: sched.WaitQueue = .{},

users: lib.atomic.RefCount(u16) = .{},
data: lib.AnyData = .{},

pub inline fn setup(
    self: *Self,
    name: []const u8,
    dev_region: *devfs.Region,
    access: devfs.DevFile.Access,
    ops: *const Operations,
    data: ?*anyopaque,
) devfs.Error!void {
    return bindings.getInstance().dev.classes.teletype.setup(self, name, dev_region, access, ops, data);
}

pub inline fn fromDevFile(dev_file: *devfs.DevFile) *Self {
    return @fieldParentPtr("dev_file", dev_file);
}

pub inline fn fromFile(file: *const vfs.File) *Self {
    return file.data.asPtr(Self).?;
}

pub inline fn onObjectAdd(self: *Self) void {
    bindings.getInstance().dev.classes.teletype.onObjectAdd(self);
}

pub inline fn setLineDiscipline(self: *Self, line_disc: *const LineDiscipline) Error!void {
    try line_disc.setup(self);
    self.line_disc = line_disc;
}

pub inline fn insertInput(self: *Self, buffer: []const u8) Error!void {
    try self.line_disc.receive(self, buffer);
}

pub inline fn bufferInput(self: *Self, input: []const u8) usize {
    return bindings.getInstance().dev.classes.teletype.bufferInput(self, input);
}

pub inline fn bufferInputAtomic(self: *Self, input: []const u8) usize {
    return bindings.getInstance().dev.classes.teletype.bufferInputAtomic(self, input);
}

pub inline fn bufferInputByteAtomic(self: *Self, byte: u8) bool {
    return bindings.getInstance().dev.classes.teletype.bufferInputByteAtomic(self, byte);
}

pub inline fn eraseInputAtomic(self: *Self, num: u32) bool {
    return bindings.getInstance().dev.classes.teletype.eraseInputAtomic(self, num);
}

pub inline fn eraseInputLineAtomic(self: *Self) void {
    bindings.getInstance().dev.classes.teletype.eraseInputLineAtomic(self);
}

pub inline fn readInput(self: *Self, buffer: []u8) usize {
    return bindings.getInstance().dev.classes.teletype.readInput(self, buffer);
}

pub inline fn readInputAtomic(self: *Self, buffer: []u8) usize {
    return bindings.getInstance().dev.classes.teletype.readInputAtomic(self, buffer);
}

pub inline fn readAllWaitInput(self: *Self, buffer: []u8) Error!void {
    return bindings.getInstance().dev.classes.teletype.readAllWaitInput(self, buffer);
}

pub inline fn waitForInput(self: *Self) void {
    bindings.getInstance().dev.classes.teletype.waitForInput(self);
}

pub inline fn writeOutput(self: *Self, buffer: []const u8) Error!usize {
    return bindings.getInstance().dev.classes.teletype.writeOutput(self, buffer);
}

pub inline fn writeOutputAtomic(self: *Self, buffer: []const u8) Error!usize {
    return bindings.getInstance().dev.classes.teletype.writeOutputAtomic(self, buffer);
}

pub inline fn writeOutputByteAtomic(self: *Self, byte: u8) Error!void {
    return bindings.getInstance().dev.classes.teletype.writeOutputByteAtomic(self, byte);
}

pub inline fn bufferOutput(self: *Self, output: []const u8) usize {
    return bindings.getInstance().dev.classes.teletype.bufferOutput(self, output);
}

pub inline fn discardOutput(self: *Self) void {
    bindings.getInstance().dev.classes.teletype.discardOutput(self);
}

pub inline fn discardInput(self: *Self) void {
    bindings.getInstance().dev.classes.teletype.discardInput(self);
}

pub fn flush(self: *Self) Error!void {
    self.out_lock.lock();
    defer self.out_lock.unlock();

    try self.flushAtomic();
}

pub inline fn flushAtomic(self: *Self) Error!void {
    try self.flushRaw(self.out_buffer.ptr[0..self.out_buffer.pos]);
    self.out_buffer.pos = 0;
}

pub inline fn flushRaw(self: *Self, buffer: []const u8) Error!void {
    try self.ops.flush(self, buffer);
}

pub inline fn inputEmpty(self: *const Self) bool {
    return self.in_seek == self.in_buffer.pos;
}

pub inline fn outputFull(self: *const Self) bool {
    return self.out_buffer.pos >= (self.out_buffer.len -| 1);
}

pub inline fn notifyInputReceived(self: *Self) void {
    if (self.inputEmpty()) return;
    sched.awakeAll(&self.in_wait);
}

pub inline fn attachSession(self: *Self, sid: *sys.Process.Id) vfs.Error!void {
    self.conf_lock.lock();
    defer self.conf_lock.unlock();

    try self.attachSessionAtomic(sid);
}

pub inline fn attachSessionAtomic(self: *Self, sid: *sys.Process.Id) vfs.Error!void {
    return bindings.getInstance().dev.classes.teletype.attachSessionAtomic(self, sid);
}

pub inline fn detachSession(self: *Self) void {
    bindings.getInstance().dev.classes.teletype.detachSession(self);
}

pub inline fn controlSignal(self: *Self, sig: sys.Process.Signal) void {
    bindings.getInstance().dev.classes.teletype.controlSignal(self, sig);
}
