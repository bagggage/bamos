//! # Teletypewriter device

// Copyright (C) 2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const dev = @import("../../dev.zig");
const devfs = @import("../../vfs.zig").devfs;
const log = std.log.scoped(.Teletype);
const sched = @import("../../sched.zig");
const lib = @import("../../lib.zig");
const sys = @import("../../sys.zig");
const vfs = @import("../../vfs.zig");
const vm = @import("../../vm.zig");

const Self = @This();

pub const termios = std.os.linux.termios2;
pub const V = std.os.linux.V;

pub const LineDiscipline = @import("Teletype/LineDiscipline.zig");

pub const Error = vm.Error || error {
    BadOperation,
    IoFailed
};

pub const Operations = struct {
    pub const FlushFn = *const fn (self: *Self, buffer: []const u8) Error!void;
    pub const EnableFn = *const fn (self: *Self) Error!void;
    pub const DisableFn = *const fn (self: *Self) void;

    flush: FlushFn,
    enable: EnableFn,
    disable: DisableFn,
};

pub const Buffer = struct {
    ptr: [*]u8 = undefined,
    len: u32 = 0,
    pos: u32 = 0,

    pub fn deinit(self: *Buffer) void {
        if (self.len == 0) return;

        const rank = vm.bytesToRank(self.len);
        const phys = vm.getPhysLma(self.ptr);
        vm.PageAllocator.free(phys, rank);
    }

    pub fn ensureCapacity(self: *Buffer, pages: u32) Error!void {
        const len = pages * vm.page_size;
        if (len <= self.len) return;

        self.deinit();

        const rank = vm.pagesToRank(pages);
        const phys = vm.PageAllocator.alloc(rank) orelse return error.NoMemory;

        self.ptr = @ptrFromInt(vm.getVirtLma(phys));
        self.pos = 0;
        self.len = len;
    }

    pub fn write(self: *Buffer, buf: []const u8) usize {
        if (self.pos == self.len) return 0;

        const end_pos = @min(self.len, self.pos + buf.len);
        const len = end_pos - self.pos;

        @memcpy(self.ptr[self.pos..end_pos], buf[0..len]);
        self.pos = end_pos;
        return len;
    }

    fn writeRaw(self: *Buffer, buf: []const u8) void {
        const end_pos = self.pos + buf.len;

        @memcpy(self.ptr[self.pos..end_pos], buf);
        self.pos = end_pos;
    }

    pub fn read(self: *Buffer, buf: []u8) usize {
        if (self.pos == self.len) return 0;

        const end_pos = @min(self.len, self.pos + buf.len);
        const len = end_pos - self.pos;

        @memcpy(buf[0..len], self.ptr[self.pos..end_pos]);
        self.pos = end_pos;
        return len;
    }

    pub inline fn reset(self: *Buffer) void {
        self.pos = 0;
    }
};

pub const alloc_config: vm.auto.Config = .{
    .allocator = .oma,
};

const devfile_ops: devfs.DevFile.Operations = .{
    .open = devOpen,
    .close = devClose,

    .fops = .{
        .read = fileRead,
        .write = fileWrite,
        .ioctl = fileIoctl,
    }
};

dev_file: devfs.DevFile,

ops: *const Operations,
line_disc: *const LineDiscipline = &LineDiscipline.null_disc,

proc: ?*sys.Process = null,
config: termios = std.mem.zeroes(termios),

in_buffer: Buffer = .{},
out_buffer: Buffer = .{},

in_lock: lib.sync.Spinlock = .{},
out_lock: lib.sync.Spinlock = .{},

in_seek: u32 = 0,
in_wait: sched.WaitQueue = .{},

enabled: std.atomic.Value(bool) = .init(false),
users: lib.atomic.RefCount(u16) = .{},

data: lib.AnyData = .{},

pub fn setup(
    self: *Self, name: []const u8, dev_region: *devfs.Region,
    ops: *const Operations, data: ?*anyopaque
) !void {
    const dev_num = dev_region.alloc() orelse return error.DevMinorLimit;
    errdefer dev_region.free(dev_num);

    self.* = .{
        .dev_file = .{
            .name = try .print("{s}{}", .{name, dev_num.minor}),
            .num = dev_num,
            .ops = &devfile_ops,
            .data = .from(self)
        },
        .ops = ops,
        .data = .from(data)
    };
    errdefer self.dev_file.name.deinit();

    try devfs.registerCharDev(&self.dev_file);
}

pub fn onObjectAdd(self: *Self) void {
    log.debug("registered: {s}", .{self.dev_file.name.str()});
}

pub fn setLineDiscipline(self: *Self, line_disc: *const LineDiscipline) Error!void {
    try line_disc.setup(self);
    self.line_disc = line_disc;
}

pub inline fn insertInput(self: *Self, buffer: []const u8) Error!void {
    try self.line_disc.receive(self, buffer);
}

pub fn bufferInput(self: *Self, input: []const u8) usize {
    if (input.len == 0) return 0;

    self.in_lock.lock();
    defer self.in_lock.unlock();

    if (self.in_buffer.len == 0) return 0;

    const buffered = self.bufferInputAtomic(input);
    if (buffered > 0) sched.awakeAll(&self.in_wait);

    return buffered;
}

pub fn bufferInputAtomic(self: *Self, input: []const u8) usize {
    std.debug.assert(std.math.isPowerOfTwo(self.in_buffer.len));
    const mask = self.in_buffer.len - 1;
    const avail = (self.in_seek -% self.in_buffer.pos -% 1) & mask;

    const len = @min(avail, input.len);
    if (len == 0) return 0;

    for (0..len) |i| {
        const idx = (self.in_buffer.pos + i) & mask;
        self.in_buffer.ptr[idx] = input[i];
    }

    self.in_buffer.pos = (self.in_buffer.pos + len) & mask;
    return len;
}

pub fn bufferInputByteAtomic(self: *Self, byte: u8) bool {
    const mask = self.in_buffer.len - 1;
    const end_pos = (self.in_seek -% 1) & mask;

    if (self.in_buffer.pos == end_pos) return false;

    self.in_buffer.ptr[self.in_buffer.pos] = byte;
    self.in_buffer.pos = (self.in_buffer.pos + 1) & mask;

    return true;
}

pub fn eraseInputAtomic(self: *Self, num: u32) void {
    if (self.inputEmpty()) return;

    const mask = self.in_buffer.len - 1;
    const avail = (self.in_buffer.pos -% self.in_seek) & mask;

    self.in_buffer.pos = (self.in_buffer.pos -% @min(num, avail)) & mask;
}

pub fn eraseInputLineAtomic(self: *Self) void {
    if (self.inputEmpty()) return;

    const mask = self.in_buffer.len - 1;
    var i = (self.in_buffer.pos -% 1) & mask;
    while (i != self.in_seek) : (i = (i -% 1) & mask) {
        if (self.in_buffer.ptr[i] == std.ascii.control_code.lf) break;
    }

    self.in_buffer.pos = i;    
}

pub fn readInput(self: *Self, buffer: []u8) usize {
    self.in_lock.lock();
    defer self.in_lock.unlock();

    if (self.inputEmpty()) return 0;
    return self.readInputAtomic(buffer);
}

pub fn readInputAtomic(self: *Self, buffer: []u8) usize {
    std.debug.assert(std.math.isPowerOfTwo(self.in_buffer.len));

    const mask = self.in_buffer.len - 1;
    const avail = (self.in_buffer.pos -% self.in_seek) & mask;
    const len = @min(avail, buffer.len);

    for (0..len) |i| {
        const idx = (self.in_seek + i) & mask;
        buffer[i] = self.in_buffer.ptr[idx];
    }

    self.in_seek = (self.in_seek + len) & mask;
    return len;
}

pub fn readAllWaitInput(self: *Self, buffer: []u8) Error!void {
    self.in_lock.lock();
    defer self.in_lock.unlock();

    var readed: usize = 0;
    while (readed < buffer.len) {
        while (self.inputEmpty()) {
            sched.waitUnlock(&self.in_wait, &self.in_lock);
            self.in_lock.lock();
        }

        readed += self.readInputAtomic(buffer[readed..]);
    }
}

pub fn waitForInput(self: *Self) void {
    self.in_lock.lock();
    defer self.in_lock.unlock();

    while (self.inputEmpty()) {
        sched.waitUnlock(&self.in_wait, &self.in_lock);
        self.in_lock.lock();
    }
}

pub fn writeOutput(self: *Self, buffer: []const u8) Error!usize {
    var writen: usize = 0;
    while (true) {
        if (self.out_buffer.len == 0) {
            try self.flushRaw(buffer);
            return buffer.len;
        }

        const tmp = self.bufferOutput(buffer[writen..]);
        writen += tmp;

        if (writen >= buffer.len) break;
        try self.flush();
    }

    return writen;
}

pub fn bufferOutput(self: *Self, output: []const u8) usize {
    if (output.len == 0) return 0;

    self.out_lock.lock();
    defer self.out_lock.unlock();

    return self.out_buffer.write(output);
}

pub fn flush(self: *Self) Error!void {
    self.out_lock.lock();
    defer self.out_lock.unlock();

    try self.flushRaw(self.out_buffer.ptr[0..self.out_buffer.len]);
    self.out_buffer.pos = 0;
}

pub inline fn flushRaw(self: *Self, buffer: []const u8) Error!void {
    try self.ops.flush(self, buffer);
}

pub inline fn inputEmpty(self: *const Self) bool {
    return self.in_seek == self.in_buffer.pos;
}

pub inline fn notifyInputReceived(self: *Self) void {
    if (self.inputEmpty()) return;
    sched.awakeAll(&self.in_wait);
}

pub fn controlSignal(self: *Self, sig: sys.Process.Signal) void {
    const proc = self.proc orelse return;
    proc.sendSignal(sig);
}

fn devOpen(dev_file: *devfs.DevFile, _: *vfs.File) vfs.Error!void {
    const tty = dev_file.data.as(Self).?;   
    if (tty.users.value.fetchAdd(1, .release) == 0) {
        try tty.ops.enable(tty);
        tty.enabled.store(true, .release);
    } else {
        if (tty.enabled.load(.acquire)) return;

        tty.users.dec();
        return error.Uninitialized;
    }
}

fn devClose(dev_file: *devfs.DevFile, _: *vfs.File) void {
    const tty = dev_file.data.as(Self).?;
    if (tty.users.put()) {
        tty.setLineDiscipline(&LineDiscipline.null_disc) catch {};
        tty.ops.disable(tty);
        tty.enabled.store(false, .release);
    }
}

fn fileRead(file: *const vfs.File, _: usize, buffer: []u8) vfs.Error!usize {
    const dev_file = devfs.DevFile.fromDentry(file.dentry);
    const tty = dev_file.data.as(Self).?;

    return tty.line_disc.read(tty, buffer);
}

fn fileWrite(file: *vfs.File, _: usize, buffer: []const u8) vfs.Error!usize {
    const dev_file = devfs.DevFile.fromDentry(file.dentry);
    const tty = dev_file.data.as(Self).?;

    return tty.writeOutput(buffer);
}

fn fileIoctl(file: *vfs.File, op: c_uint, value: usize) vfs.Error!void {
    const dev_file = devfs.DevFile.fromDentry(file.dentry);
    const tty = dev_file.data.as(Self).?;

    _ = tty;
    _ = op;
    _ = value;

    return error.BadOperation;
}
