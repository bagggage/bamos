//! # Teletypewriter device

// Copyright (C) 2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const dev = @import("../../dev.zig");
const devfs = @import("../../vfs.zig").devfs;
const log = std.log.scoped(.Teletype);
const sched = @import("../../sched.zig");
const lib = @import("../../lib.zig");
const linux = std.os.linux;
const Session = sys.Process.Control.Session;
const sys = @import("../../sys.zig");
const vfs = @import("../../vfs.zig");
const vm = @import("../../vm.zig");

const Self = @This();

pub const termios = linux.termios2;
pub const T = std.os.linux.T;
pub const V = linux.V;

pub const WinSize = extern struct {
    rows: u16,
    cols: u16
};

pub const dev_tty = @import("Teletype/dev_tty.zig");
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
        if (self.pos == self.len) { @branchHint(.unlikely); return 0; }

        const end_pos = @min(self.len, self.pos + buf.len);
        const len = end_pos - self.pos;

        @memcpy(self.ptr[self.pos..end_pos], buf[0..len]);
        self.pos = end_pos;
        return len;
    }

    pub fn writeByte(self: *Buffer, byte: u8) bool {
        if (self.pos == self.len) { @branchHint(.unlikely); return false; }

        const end_pos = @min(self.len, self.pos + 1);

        self.ptr[self.pos] = byte;
        self.pos = end_pos;
        return true;
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
        .poll = &filePoll
    }
};

dev_file: devfs.DevFile,

ops: *const Operations,
line_disc: *const LineDiscipline = &LineDiscipline.null_disc,

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

pub fn setup(
    self: *Self, name: []const u8, dev_region: *devfs.Region,
    access: devfs.DevFile.Access, ops: *const Operations, data: ?*anyopaque
) !void {
    const dev_num = dev_region.alloc() orelse return error.DevMinorLimit;
    errdefer dev_region.free(dev_num);

    self.* = .{
        .dev_file = .{
            .name = try .print("{s}{}", .{name, dev_num.minor}),
            .num = dev_num,
            .access = access,
            .ops = &devfile_ops,
        },
        .ops = ops,
        .data = .fromPtr(data)
    };
    errdefer self.dev_file.name.deinit();

    try devfs.registerCharDev(&self.dev_file);
}

pub inline fn fromDevFile(dev_file: *devfs.DevFile) *Self {
    return @fieldParentPtr("dev_file", dev_file);
}

pub inline fn fromFile(file: *const vfs.File) *Self {
    return file.data.asPtr(Self).?;
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

pub fn eraseInputAtomic(self: *Self, num: u32) bool {
    if (self.inputEmpty()) return false;

    const mask = self.in_buffer.len - 1;
    const avail = (self.in_buffer.pos -% self.in_seek) & mask;
    const min_num = @min(num, avail);

    const new_pos = (self.in_buffer.pos -% min_num) & mask;
    if (self.in_buffer.ptr[new_pos] == std.ascii.control_code.lf) return false;

    self.in_buffer.pos = new_pos;
    return true;
}

pub fn eraseInputLineAtomic(self: *Self) void {
    if (self.inputEmpty()) return;

    const mask = self.in_buffer.len - 1;
    var i = self.in_buffer.pos;

    while (i != self.in_seek) : (i = (i -% 1) & mask) {
        if (self.in_buffer.ptr[i] == std.ascii.control_code.lf) {
            std.debug.assert(i < self.in_buffer.pos);

            i += 1;
            break;
        }
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
        const idx = (self.in_seek +% i) & mask;
        buffer[i] = self.in_buffer.ptr[idx];
    }

    self.in_seek = (self.in_seek +% len) & mask;
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

pub fn writeOutputAtomic(self: *Self, buffer: []const u8) Error!usize {
    var writen: usize = 0;
    while (true) {
        if (self.out_buffer.len == 0) {
            try self.flushRaw(buffer);
            return buffer.len;
        }

        const tmp = self.out_buffer.write(buffer[writen..]);
        writen += tmp;

        if (writen >= buffer.len) break;
        try self.flushAtomic();
    }

    return writen;
}

pub fn writeOutputByteAtomic(self: *Self, byte: u8) Error!void {
    if (!self.out_buffer.writeByte(byte)) {
        @branchHint(.unlikely);
        try self.flushAtomic();
        if (!self.out_buffer.writeByte(byte)) try self.flushRaw(&.{byte});
    }
}

pub fn bufferOutput(self: *Self, output: []const u8) usize {
    if (output.len == 0) return 0;

    self.out_lock.lock();
    defer self.out_lock.unlock();

    return self.out_buffer.write(output);
}

pub fn discardOutput(self: *Self) void {
    self.out_lock.lock();
    defer self.out_lock.unlock();

    self.out_buffer.reset();
}

pub fn discardInput(self: *Self) void {
    self.in_lock.lock();
    defer self.in_lock.unlock();

    self.in_seek = 0;
    self.in_buffer.reset();
}

pub fn flush(self: *Self) Error!void {
    self.out_lock.lock();
    defer self.out_lock.unlock();

    try self.flushAtomic();
}

pub inline fn flushAtomic(self: *Self) Error!void {
    try self.flushRaw(self.out_buffer.ptr[0..self.out_buffer.pos]);
    self.out_buffer.reset();
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

pub fn attachSessionAtomic(self: *Self, sid: *sys.Process.Id) vfs.Error!void {
    std.debug.assert(sid.lock.isLocked());
    std.debug.assert(self.sid == null);

    if (sid.session.tty != null) return error.Busy;

    sid.session.tty = self;
    sid.ref();

    self.sid = sid;
    self.foreground_group = sid;
}

pub fn detachSession(self: *Self) void {
    self.conf_lock.lockAtomic();
    defer self.conf_lock.unlockAtomic();

    const sid = self.sid orelse return;
    defer sid.deref();

    std.debug.assert(sid.lock.isLocked());

    self.sid = null;
    if (self.foreground_group) |f| {
        if (sid == f) {
            f.sendSignalToGroupAtomic(.Hangup);
        } else {
            f.sendSignalToGroup(.Hangup);
        }

        self.foreground_group = null;
    }
}

pub fn controlSignal(self: *Self, sig: sys.Process.Signal) void {
    self.conf_lock.lock();
    if (self.foreground_group) |f| {
        f.ref();
        defer f.deref();

        self.conf_lock.unlock();
        f.sendSignalToGroup(sig);
    } else {
        self.conf_lock.unlock();
    }
}

fn devOpen(dev_file: *devfs.DevFile, file: *vfs.File) vfs.Error!void {
    const tty = fromDevFile(dev_file);
    defer file.data.setPtr(tty);

    tty.conf_lock.lock();
    defer tty.conf_lock.unlock();

    if (tty.users.value.fetchAdd(1, .release) == 0) try tty.ops.enable(tty);
    errdefer if (tty.users.put()) tty.ops.disable(tty);

    if (tty.sid == null) {
        const task = sched.getCurrentTask();
        const proc = if (task.spec == .user) task.spec.user.process else return;

        const group = proc.getGroup();
        defer group.deref();

        group.lock.lockAtomic();
        defer group.lock.unlockAtomic();

        const sid = group.getSessionWeak().getId();
        if (group != sid) sid.lock.lockAtomic();
        defer if (group != sid) sid.lock.unlockAtomic();

        tty.attachSessionAtomic(sid) catch |err| if (err != error.Busy) return err;
    }
}

fn devClose(dev_file: *devfs.DevFile, file: *vfs.File) void {
    const tty = fromDevFile(dev_file);
    file.data.setPtr(null);

    tty.conf_lock.lock();
    defer tty.conf_lock.unlock();

    if (tty.users.put()) {
        tty.setLineDiscipline(&LineDiscipline.null_disc) catch {};
        tty.ops.disable(tty);
    }
}

fn fileRead(file: *const vfs.File, _: usize, buffer: []u8) vfs.Error!usize {
    const tty = fromFile(file);
    return tty.line_disc.read(tty, buffer);
}

fn fileWrite(file: *vfs.File, _: usize, buffer: []const u8) vfs.Error!usize {
    const tty = fromFile(file);

    if (tty.config.oflag.OPOST) return tty.line_disc.write(tty, buffer);
    return LineDiscipline.throw_disc.write(tty, buffer);
}

fn fileIoctl(file: *vfs.File, cmd: c_uint, arg: usize) vfs.Error!void {
    const tty = fromFile(file);

    switch_blk: switch (cmd) {
        //T.CGETA => {},
        //T.CSETA => {},
        //T.CSETAW => {},
        //T.CSETAF => {},
        T.CGETS => {
            tty.conf_lock.lock();
            defer tty.conf_lock.unlock();
            // TODO: There is some difference between termios structure
            // in Zig standard library and termios within libc.
            // Fix termios structure?

            const tos: *termios = if (arg != 0) @ptrFromInt(arg) else return error.SegFault;
            tos.iflag = tty.config.iflag;
            tos.oflag = tty.config.oflag;
            tos.cflag = tty.config.cflag;
            tos.lflag = tty.config.lflag;
            tos.line = tty.config.line;

            @memcpy(tos.cc[0..19], tty.config.cc[0..19]);
        },
        T.CSETS => {
            const tos: *termios = if (arg != 0) @ptrFromInt(arg) else return error.SegFault;

            log.debug("set config: {any}, {any}, {any}, {any}, line:{}", .{tos.cflag, tos.iflag, tos.oflag, tos.lflag, tos.line});

            tty.conf_lock.lock();
            defer tty.conf_lock.unlock();

            if (tty.config.line != tos.line) {
                const num: LineDiscipline.Builtin =
                    if (tos.line >= LineDiscipline.max_discpline_num)
                        .null
                    else
                        @enumFromInt(tos.line);

                const disc = LineDiscipline.choose(num);
                try disc.setup(tty);

                tty.line_disc = disc;
            }

            const old = tty.config;
            tty.config = tos.*;
            errdefer tty.config = old;

            if (tty.ops.config) |config| try config(tty, &old);
        },
        T.CSETSW => {
            // TODO: Implement TTY drain.
            continue :switch_blk T.CSETS;
        },
        T.CSETSF => {
            // TODO: Implement TTY drain.
            tty.discardInput();
            continue :switch_blk T.CSETS;
        },
        T.CFLSH => {
            const TCIFLUSH  = 1;
            const TCOFLUSH  = 2;
            const TCIOFLUSH = 3;
            switch (arg) {
                TCIFLUSH  => tty.discardInput(),
                TCOFLUSH  => tty.discardOutput(),
                TCIOFLUSH => { tty.discardInput(); tty.discardOutput(); },
                else      => return error.InvalidArgs
            }
        },
        T.FIONREAD => {
            tty.in_lock.lock();
            defer tty.in_lock.unlock();

            const mask = tty.in_buffer.len - 1;
            const avail = (tty.in_buffer.pos -% tty.in_seek) & mask;

            const ptr: *u32 = if (arg != 0) @ptrFromInt(arg) else return error.SegFault;
            ptr.* = avail;
        },
        T.IOCOUTQ => {
            tty.out_lock.lock();
            defer tty.out_lock.unlock();

            const ptr: *u32 = if (arg != 0) @ptrFromInt(arg) else return error.SegFault;
            ptr.* = tty.out_buffer.pos;
        },
        T.IOCGPGRP => {
            const proc = sys.Process.getCurrent();
            const group = proc.getGroup();
            defer group.deref();

            tty.conf_lock.lock();
            defer tty.conf_lock.unlock();

            if (tty.sid != group.getSessionWeakAtomic().getId()) return error.NoTTY;
            const foreground = tty.foreground_group orelse return error.NoTTY;

            const ptr: *u32 = if (arg != 0) @ptrFromInt(arg) else return error.SegFault;
            ptr.* = foreground.value;
        },
        T.IOCSPGRP => {
            const ptr: *const u32 = if (arg != 0) @ptrFromInt(arg) else return error.SegFault;
            const group_id = ptr.*;

            const proc = sys.Process.getCurrent();
            const group = proc.getGroup();
            defer group.deref();

            const sid = blk: {
                // Get session and release the lock before
                // locking `sid` structure to prevent deadlocking.
                tty.conf_lock.lock();
                defer tty.conf_lock.unlock();

                if (tty.sid != group.getSessionWeakAtomic().getId()) return error.NoTTY;
                if (tty.foreground_group) |f| if (f.value == group_id) return;

                break :blk tty.sid.?;
            };

            sid.lock.lock();
            defer sid.lock.unlock();

            // Because we release `conf_lock` before aquiring `sid.lock`,
            // the session can be detached from tty, so check if session is still attached
            if (sid.session.tty != tty) { @branchHint(.cold); return error.NoTTY; }

            // Don't use `Id.lookup` it's better to iterate over the list,
            // anyway we need to check if session includes target group.
            var node = sid.session.groups.first;
            while (node) |n| : (node = n.next) {
                const gid = sys.Process.Id.fromGNode(n);
                if (gid.value != group_id) continue;

                tty.foreground_group = gid;
                return;
            }

            return error.NoAccess;
        },
        T.IOCGSID => {
            const proc = sys.Process.getCurrent();
            const group = proc.getGroup();
            defer group.deref();

            tty.conf_lock.lock();
            defer tty.conf_lock.unlock();

            if (tty.sid != group.getSessionWeakAtomic().getId()) return error.NoTTY;

            const ptr: *u32 = if (arg != 0) @ptrFromInt(arg) else return error.SegFault;
            ptr.* = tty.sid.?.value;
        },
        T.IOCSERCONFIG,
        T.IOCSERGETLSR,
        T.IOCSERGETMULTI,
        T.IOCSERGSTRUCT,
        T.IOCSERGWILD,
        T.IOCSERSETMULTI,
        T.IOCSERSWILD,
        T.IOCSSERIAL,
        T.IOCGSERIAL,
        T.IOCGWINSZ,
        T.IOCSWINSZ => {
            if (tty.ops.control == null) return error.BadOperation;
            return tty.ops.control.?(tty, cmd, .from(arg));
        },
        else => return error.BadOperation
    }
}

fn filePoll(file: *vfs.File) vfs.Error!vfs.File.Poll {
    const tty = fromFile(file);
    return .{
        .read_avail = blk: {
            tty.in_lock.lock(); defer tty.in_lock.unlock();
            break :blk !tty.inputEmpty();
        },
        .may_write = blk: {
            tty.out_lock.lock(); defer tty.out_lock.unlock();
            break :blk !tty.outputFull();
        },
    };
}
