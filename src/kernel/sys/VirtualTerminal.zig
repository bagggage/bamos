//! # Virtual Terminal

// Copyright (C) 2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const dev = @import("../dev.zig");
const devfs = vfs.devfs;
const Input = dev.classes.Input;
const lib = @import("../lib.zig");
const log = std.log.scoped(.VirtualTerminal);
const logger = @import("../logger.zig");
const sched = @import("../sched.zig");
const sys = @import("../sys.zig");
const Teletype = dev.classes.Teletype;
const uart = @import("../dev/drivers/uart/8250.zig");
const vfs = @import("../vfs.zig");
const video = @import("../video.zig");
const vm = @import("../vm.zig");

const Self = @This();

const max_terminals = 4;

var tty_ops: Teletype.Operations = .{
    .enable = &ttyEnable,
    .disable = &ttyDisable,
    .flush = &ttyNullFlush,
    .control = &ttyControl,
};

var dev_region: devfs.Region = .{ .major = 4 };

var cursor_task: *sched.Task = undefined;
var kbd_handler: Input.Event.Handler = .{ .callback = &keyboardHandler };
var kbd_immediate: dev.intr.SoftHandler = .{ .func = &keyboardImmediate };

var vts: [max_terminals]Self = undefined;
var active: ?*Self = null;

idx: u8,
tty: Teletype,

kbd_lock: lib.sync.Spinlock = .{},
kbd_state: packed struct {
    shift: u2 = 0,
    alt: u2   = 0,
    ctrl: u2  = 0,

    capslock: bool = false,
    numlock: bool = false,
    initialized: bool = false,

    inline fn isControl(self: @This()) bool {
        return self.ctrl != 0;
    }

    inline fn isAlt(self: @This()) bool {
        return self.alt != 0;
    }

    inline fn isShift(self: @This()) bool {
        return self.shift != 0;
    }
} = .{},

kbd_events: [16]Input.Event = undefined,
kbd_pos: u8 = 0,

pub fn init() !void {
    cursor_task = try sched.Task.create(
        .{ .kernel = .{ .name = "vt.cursor" } },
        @intFromPtr(&cursorTask)
    );

    for (&vts, 0..) |*vt, i| {
        try vt.setup(i);
    }
}

pub fn select(idx: u8) !*Teletype {
    const vt = &vts[idx];
    if (vt == active) return &vt.tty;

    if (active) |t| t.disable();

    try vt.enable();
    active = vt;

    return &vt.tty;
}

pub fn setup(self: *Self, idx: usize) !void {
    self.* = .{
        .idx = @intCast(idx),
        .tty = undefined,
    };

    try self.tty.setup(
        "tty", &dev_region,
        .{ .gid = 0, .perm = vfs.Permissions.makeInt(.rw, .none, .none) },
        &tty_ops, null
    );
}

pub fn enable(self: *Self) !void {
    kbd_handler.ctx = .fromPtr(self);

    try sys.input.registerHandler(.keyboard, &kbd_handler);

    if (video.terminal.isInitialized()) {
        video.terminal.setColor(.lgray);
        video.terminal.setCursor(0, 0);
        video.terminal.clear();

        logger.switchToUserspace();

        tty_ops.flush = &ttyVideoFlush;
        sched.enqueue(cursor_task);
    } else {
        log.warn("video output is not enabled", .{});
        return error.Uninitialized;
    }
}

pub fn disable(self: *Self) void {
    tty_ops.flush = &ttyNullFlush;

    if (active == self) active = null;

    sys.input.unregisterHandler(.keyboard, &kbd_handler);
    self.kbd_state = .{};
}

fn ttyEnable(tty: *Teletype) Teletype.Error!void {
    tty.out_buffer.reset();
    tty.in_buffer.reset();
    tty.in_seek = 0;

    try tty.setLineDiscipline(&Teletype.LineDiscipline.tty_disc);

    try tty.in_buffer.ensureCapacity(1);
    errdefer tty.in_buffer.deinit();

    try tty.out_buffer.ensureCapacity(1);
}

fn ttyDisable(tty: *Teletype) void {
    tty.in_buffer.deinit();
    tty.out_buffer.deinit();
}

fn ttyNullFlush(_: *Teletype, _: []const u8) Teletype.Error!void {}

fn ttyVideoFlush(_: *Teletype, buffer: []const u8) Teletype.Error!void {
    video.terminal.write(buffer);
}

fn ttyControl(_: *Teletype, cmd: u32, arg: lib.AnyData) vfs.Error!void {
    if (!video.terminal.isInitialized()) return error.BadOperation;

    switch (cmd) {
        Teletype.T.IOCGWINSZ => {
            const win_size = arg.asPtr(Teletype.WinSize).?;
            const size = video.terminal.getSize();

            win_size.rows = size[0];
            win_size.cols = size[1];
        },
        Teletype.T.IOCSWINSZ => {
            const win_size = arg.asPtr(Teletype.WinSize).?;
            try video.terminal.setSize(.{ win_size.rows, win_size.cols });
        },
        else => return error.BadOperation
    }
}

fn cursorTask() noreturn {
    while (true) {
        sched.getCurrent().sleepFor(std.time.ns_per_ms * 350);
        if (active != null) video.terminal.blinkCursor();
    }
}

fn keyboardHandler(ctx: lib.AnyData, device: *Input, event: Input.Event) bool {
    const self = ctx.asPtr(Self).?;
    if (!self.kbd_state.initialized) {
        @branchHint(.cold);
        self.kbd_state.initialized = true;
        device.request(.{ .keyboard = .{ .set_leds = .{} } }) catch {};
        device.request(.{ .keyboard = .{ .set_repeat_rate_and_delay = .{
            .delay_ms = 250, .rate_hz = 30
        }}}) catch {};
    }

    switch (event.code) {
        .unknown => return false,
        .capslock => {
            if (event.action != .press) return false;

            self.kbd_lock.lockAtomic();
            defer self.kbd_lock.unlockAtomic();

            self.kbd_state.capslock = !self.kbd_state.capslock;
            self.keyboardUpdateLeds(device) catch {};
        },
        .numlock => {
            if (event.action != .press) return false;

            self.kbd_lock.lockAtomic();
            defer self.kbd_lock.unlockAtomic();

            self.kbd_state.numlock = !self.kbd_state.numlock;
            self.keyboardUpdateLeds(device) catch {};
        },
        .left_alt,
        .right_alt => {
            if (event.action == .repeat) return false;

            self.kbd_lock.lockAtomic();
            defer self.kbd_lock.unlockAtomic();
            if (event.action == .press) {
                self.kbd_state.alt += 1;
            } else {
                self.kbd_state.alt -= 1;
            }
        },
        .left_ctrl,
        .right_ctrl => {
            if (event.action == .repeat) return false;

            self.kbd_lock.lockAtomic();
            defer self.kbd_lock.unlockAtomic();
            if (event.action == .press) {
                self.kbd_state.ctrl += 1;
            } else {
                self.kbd_state.ctrl -= 1;
            }
        },
        .left_shift,
        .right_shift => {
            if (event.action == .repeat) return false;

            self.kbd_lock.lockAtomic();
            defer self.kbd_lock.unlockAtomic();
            if (event.action == .press) {
                self.kbd_state.shift += 1;
            } else {
                self.kbd_state.shift -= 1;
            }
        },
        else => {
            if (event.action == .release or event.code == .unknown) return false;

            self.kbd_events[self.kbd_pos] = event;
            self.kbd_pos = (self.kbd_pos +% 1) % comptime @as(u8, @intCast(self.kbd_events.len));

            kbd_immediate.ctx = ctx.ptr;
            dev.intr.scheduleImmediate(&kbd_immediate);
        }
    }

    return false;
}

fn keyboardUpdateLeds(self: *Self, device: *Input) !void {
    try device.request(.{ .keyboard = .{ .set_leds = .{
        .numlock = self.kbd_state.numlock,
        .capslock = self.kbd_state.capslock,
    }}});
}

fn scancodeToAscii(self: *Self, code: Input.Scancode) u8 {
    const Code = Input.Scancode;
    const cc = std.ascii.control_code;

    const base_table = comptime blk: {
        const len = Code.delete.toInt() + 1;
        var table: [len]u8 = .{ 0 } ** len;

        table[Code.esc.toInt()]         = cc.esc;
        table[Code.@"0".toInt()]        = '0';
        table[Code.@"1".toInt()]        = '1';
        table[Code.@"2".toInt()]        = '2';
        table[Code.@"3".toInt()]        = '3';
        table[Code.@"4".toInt()]        = '4';
        table[Code.@"5".toInt()]        = '5';
        table[Code.@"6".toInt()]        = '6';
        table[Code.@"7".toInt()]        = '7';
        table[Code.@"8".toInt()]        = '8';
        table[Code.@"9".toInt()]        = '9';
        table[Code.minus.toInt()]       = '-';
        table[Code.equal.toInt()]       = '=';
        table[Code.backspace.toInt()]   = cc.del;
        table[Code.tab.toInt()]         = cc.ht;
        table[Code.Q.toInt()]           = 'q';
        table[Code.W.toInt()]           = 'w';
        table[Code.E.toInt()]           = 'e';
        table[Code.R.toInt()]           = 'r';
        table[Code.T.toInt()]           = 't';
        table[Code.Y.toInt()]           = 'y';
        table[Code.U.toInt()]           = 'u';
        table[Code.I.toInt()]           = 'i';
        table[Code.O.toInt()]           = 'o';
        table[Code.P.toInt()]           = 'p';
        table[Code.left_brace.toInt()]  = '[';
        table[Code.right_brace.toInt()] = ']';
        table[Code.enter.toInt()]       = '\r';
        table[Code.A.toInt()]           = 'a';
        table[Code.S.toInt()]           = 's';
        table[Code.D.toInt()]           = 'd';
        table[Code.F.toInt()]           = 'f';
        table[Code.G.toInt()]           = 'g';
        table[Code.H.toInt()]           = 'h';
        table[Code.J.toInt()]           = 'j';
        table[Code.K.toInt()]           = 'k';
        table[Code.L.toInt()]           = 'l';
        table[Code.semicolon.toInt()]   = ';';
        table[Code.apostrope.toInt()]   = '\'';
        table[Code.grave.toInt()]       = '`';
        table[Code.backslash.toInt()]   = '\\';
        table[Code.Z.toInt()]           = 'z';
        table[Code.X.toInt()]           = 'x';
        table[Code.C.toInt()]           = 'c';
        table[Code.V.toInt()]           = 'v';
        table[Code.B.toInt()]           = 'b';
        table[Code.N.toInt()]           = 'n';
        table[Code.M.toInt()]           = 'm';
        table[Code.comma.toInt()]       = ',';
        table[Code.dot.toInt()]         = '.';
        table[Code.slash.toInt()]       = '/';
        table[Code.space.toInt()]       = ' ';

        table[Code.home.toInt()]        = 0xff;
        table[Code.up.toInt()]          = 0xff;
        table[Code.page_up.toInt()]     = 0xff;
        table[Code.left.toInt()]        = 0xff;
        table[Code.right.toInt()]       = 0xff;
        table[Code.end.toInt()]         = 0xff;
        table[Code.down.toInt()]        = 0xff;
        table[Code.page_down.toInt()]   = 0xff;
        table[Code.insert.toInt()]      = 0xff;
        table[Code.delete.toInt()]      = 0xff;

        break :blk table;
    };

    const code_int = code.toInt();
    if (code.isNumpad()) {
        const numpad_base = comptime Code.kp_7.toInt();
        const numpad_len = comptime Code.kp_dot.toInt() - numpad_base + 1;

        const numpad_table: [numpad_len]u8 = comptime .{
            '7', '8', '9', '-',
            '4', '5', '6', '+',
            '1', '2', '3', '0', '.'
        };
        const numpad_alt_table: [numpad_len]u8 = comptime .{
            0xff, 0xff, 0xff, '-',
            0xff, 0xff, 0xff, '+',
            0xff, 0xff, 0xff, 0xff, 0xff
        };

        const table = if (self.kbd_state.numlock) &numpad_table else &numpad_alt_table;
        return table[code_int - numpad_base];
    } else if (code_int < base_table.len) {
        const ascii = base_table[code_int];
        return if (self.kbd_state.isShift()) switch (ascii) {
            '`' => '~',
            '1' => '!',
            '2' => '@',
            '3' => '#',
            '4' => '$',
            '5' => '%',
            '6' => '^',
            '7' => '&',
            '8' => '*',
            '9' => '(',
            '0' => ')',
            '-' => '_',
            '=' => '+',
            '[' => '{',
            ']' => '}',
            ';' => ':',
            '\'' => '"',
            ',' => '<',
            '.' => '>',
            '/' => '?',
            '\\' => '|',
            else => if (!self.kbd_state.capslock) std.ascii.toUpper(ascii) else ascii,
        } else if (self.kbd_state.capslock) std.ascii.toUpper(ascii) else ascii;
    } else return switch (code) {
        .kp_enter => '\r',
        .kp_slash => '/',
        .kp_equal => '=',
        else => 0
    };
}

fn scancodeToEscape(code: Input.Scancode) []const u8 {
    return switch (code) {
        .kp_8,
        .up        => "\x1b[A",
        .kp_4,
        .left      => "\x1b[D",
        .kp_6,
        .right     => "\x1b[C",
        .kp_2,
        .down      => "\x1b[B",
        .kp_7,
        .home      => "\x1b[1~",
        .kp_0,
        .insert    => "\x1b[2~",
        .kp_dot,
        .delete    => "\x1b[3~",
        .kp_1,
        .end       => "\x1b[4~",
        .kp_9,
        .page_up   => "\x1b[5~",
        .kp_3,
        .page_down => "\x1b[6~",

        else => &.{},
    };
}

fn keyboardImmediate(ctx: ?*anyopaque) void {
    const self: *Self = @alignCast(@ptrCast(ctx.?));
    defer self.kbd_pos = 0;

    var buffer: [self.kbd_events.len]u8 = undefined;
    var i: usize = 0;

    for (self.kbd_events[0..self.kbd_pos]) |event| {
        const ascii = self.scancodeToAscii(event.code);
        if (ascii == 0) continue;

        if (ascii == 0xff) {
            if (i > 0) self.tty.insertInput(buffer[0..i]) catch {};
            i = 0;

            self.tty.insertInput(scancodeToEscape(event.code)) catch {};
            continue;
        } else if (self.kbd_state.isControl()) {
            if (ascii < 0x40) continue;
            buffer[i] = std.ascii.toUpper(ascii) - 0x40;
        } else {
            buffer[i] = ascii;
        }

        i += 1;
    }

    if (i > 0) self.tty.insertInput(buffer[0..i]) catch {};
}
