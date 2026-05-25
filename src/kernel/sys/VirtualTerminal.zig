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

const IoCtl = enum(u32) {
    const Mode = enum(u8) { text = 0, graphics = 1 };

    const ConsoleFont = extern struct {
        const OpCode = enum(u32) {
            set = 0,
            get = 1,
            set_default = 2,
            copy = 3,
            set_tall = 4,
            get_tall = 5,
        };

        const Operation = extern struct {
            op: OpCode,
            flags: u32,
            width: u32,
            height: u32,
            char_num: u32,
            data: [*]u8,
        };

        num: u16,
        height: u16,
        data: [*]u8,
    };

    const Kbd = opaque {
        const Type = enum(u8) {
            @"84" = 1,
            @"101" = 2,
            other = 3,
        };

        const Leds = packed struct(u8) {
            scroll_lock: bool = false,
            num_lock: bool = false,
            caps_lock: bool = false,
            _reserved: u5 = 0,
        };
    };

    const Vt = enum(u32) {
        const Mode = extern struct {
            mode: enum(u8) {
                auto = 0,
                process = 1,
                ack_switch = 2,
            },
            wait: bool = false,
            release_sig: u16,
            acquisition_sig: u16,
            _unused: u16 = 0,
        };

        const State = extern struct {
            active: u16,
            signal: u16,
            state: u16,
        };

        const Sizes = extern struct {
            rows: u16,
            cols: u16,
            scroll_size: u16,
        };

        const ConsoleSize = extern struct {
            rows: u16,
            cols: u16,
            screen_height: u16,
            char_height: u16,
            screen_width: u16,
            char_width: u16,
        };

        const Event = extern struct {
            event: packed struct (u32) {
                @"switch": bool = false,
                blank: bool = false,
                unblank: bool = false,
                resize: bool = false,
                _reserved: u28 = 0,
            },
            old_dev: u32,
            new_dev: u32 = 0,
            pad: [4]u32 = undefined,
        };

        const SetActivate = extern struct {
            console: u32,
            mode: Vt.Mode,
        };

        get_mode        = 0x5601,
        set_mode        = 0x5602,
        get_state       = 0x5603,
        send_sig        = 0x5604,
        release_display = 0x5605,
        activate        = 0x5606,
        wait_activate   = 0x5607,
        free_memory     = 0x5608,
        resize          = 0x5609,
        resize_ex       = 0x560a,
        lock_switch     = 0x560b,
        unlock_switch   = 0x560c,
        get_hifont_mask = 0x560d,
        wait_event      = 0x560e,
        set_activate    = 0x560f,
        _,
    };

    get_font      = 0x4b60,
    set_font      = 0x4b61,
    get_fontx     = 0x4b6b,
    set_fontx     = 0x4b6c,
    reset_font    = 0x4b6d,

    get_color_map = 0x4b70,
    set_color_map = 0x4b71,

    sound_start   = 0x4b2f,
    sound_tone    = 0x4b30,
    get_led       = 0x4b31,
    set_led       = 0x4b32,
    get_kbd_type  = 0x4b33,
    add_io_ports  = 0x4b34,
    del_io_ports  = 0x4d35,
    enable_io     = 0x4b36,
    disable_io    = 0x4b37,

    set_mode      = 0x4b3a,
    get_mode      = 0x4b3b,
    map_display   = 0x4b3c,
    unmap_display = 0x4b3d,

    get_kbd_mode  = 0x4b44,
    set_kbd_mode  = 0x4b45,
    get_kbd_entry = 0x4b46,
    set_kbd_entry = 0x4b47,

    set_kbd_repeat = 0x4b52,

    get_kbd_meta  = 0x4b62,
    set_kbd_meta  = 0x4b63,
    get_kbd_flags = 0x4b64,
    set_kbd_flags = 0x4b65,
    _
};

const KbdMode = enum(u8) {
    raw = 0,
    translate = 1,
    medium_raw = 2,
    unicode = 3,
    off = 4
};

var tty_ops: Teletype.Operations = .{
    .enable = &ttyEnable,
    .disable = &ttyDisable,
    .flush = &ttyNullFlush,
    .config = &ttyConfig,
    .control = &ttyControl,
};

var dev_region: devfs.Region = .{ .major = 4 };

var cursor_init: bool = false;
var cursor_enable: bool = false;
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

kbd_mode: KbdMode = .translate,
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

pub inline fn isEnabled() bool {
    return active != null;
}

pub fn select(idx: u8) !*Teletype {
    const vt = &vts[idx];
    if (vt == active) return &vt.tty;

    if (active) |t| t.disable();

    try vt.enable();
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
        tty_ops.flush = &ttyVideoFlush;
        active = self;

        video.terminal.clear();
        video.terminal.setColor(.lgray);
        video.terminal.setCursor(0, 0);

        cursor_enable = true;
        if (cursor_init) return;

        cursor_init = true;
        sched.enqueue(cursor_task);
    } else {
        log.warn("video output is not enabled", .{});
        return error.Uninitialized;
    }
}

pub fn disable(self: *Self) void {
    tty_ops.flush = &ttyNullFlush;
    cursor_enable = false;

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

fn ttyConfig(tty: *Teletype, _: *const Teletype.termios) Teletype.Error!void {
    const vt: *Self = @fieldParentPtr("tty", tty);
    if (active == vt and video.terminal.isInitialized()) video.terminal.setColor(.lgray);
}

fn ttyControl(tty: *Teletype, cmd: u32, arg: lib.AnyData) vfs.Error!void {
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
        else => return virtualTerminalControl(tty, @enumFromInt(cmd), arg),
    }
}

fn virtualTerminalControl(tty: *Teletype, cmd: IoCtl, arg: lib.AnyData) vfs.Error!void {
    const vt: *Self = @fieldParentPtr("tty", tty);
    switch (cmd) {
        .get_mode => arg.asPtr(u32).?.* = @intFromEnum(IoCtl.Mode.text),
        .set_mode => {
            const mode = arg.as(u8);
            if (mode > @intFromEnum(IoCtl.Mode.graphics)) return error.InvalidArgs;

            // Do nothing else?
            cursor_enable = (mode == @intFromEnum(IoCtl.Mode.text));
        },
        .get_kbd_type => arg.asPtr(u32).?.* = @intFromEnum(IoCtl.Kbd.Type.@"101"),
        .get_kbd_mode => arg.asPtr(u32).?.* = @intFromEnum(vt.kbd_mode),
        .set_kbd_mode => {
            if (arg.as(u8) > @intFromEnum(KbdMode.off)) return error.InvalidArgs;

            const kbd_mode: KbdMode = @enumFromInt(arg.as(u8));
            vt.kbd_mode = kbd_mode;
        },
        else => {
            const vt_cmd: IoCtl.Vt = @enumFromInt(@intFromEnum(cmd));
            switch (vt_cmd) {
                .get_mode => arg.asPtr(IoCtl.Vt.Mode).?.* = .{
                    .mode = .auto,
                    .release_sig = 0,
                    .acquisition_sig = 0,
                },
                .set_mode => {
                    const mode = arg.asPtr(IoCtl.Vt.Mode).?;
                    log.info("vt_setmode: {}", .{@intFromEnum(mode.mode)});
                },
                .get_state => arg.asPtr(IoCtl.Vt.State).?.* = .{
                    .active = if (active) |a| @truncate(@intFromPtr(a) - @intFromPtr(&vts) + 1) else 0,
                    .signal = 0,
                    .state = (@as(u16, 1) << max_terminals) -% 1,
                },
                .activate => _ = try select(arg.as(u8) -% 1),
                .wait_activate => {}, // Do nothing for now?
                else => return error.BadOperation,
            }
        },
    }
}

fn cursorTask() noreturn {
    while (true) {
        sched.getCurrent().sleepFor(std.time.ns_per_ms * 350);
        if (active) |tty| if (tty.kbd_mode == .translate and cursor_enable) {
            video.terminal.blinkCursor();
        };
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

    if (self.kbd_mode != .translate) {
        self.keyboardPutEvent(event);
        return true;
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
            self.keyboardPutEvent(event);
        }
    }

    return false;
}

fn keyboardPutEvent(self: *Self, event: Input.Event) void {
    self.kbd_events[self.kbd_pos] = event;
    self.kbd_pos = (self.kbd_pos +% 1) % comptime @as(u8, @intCast(self.kbd_events.len));

    kbd_immediate.ctx = @ptrCast(self);
    dev.intr.scheduleImmediate(&kbd_immediate);
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

    const events = self.kbd_events[0..self.kbd_pos];
    var buffer: [self.kbd_events.len]u8 = undefined;

    switch (self.kbd_mode) {
        .raw => self.keyboardRawInput(events, &buffer),
        .medium_raw => self.keyboardMediumRawInput(events, &buffer),
        .translate => self.keyboardTranslateInput(events, &buffer),
        .unicode,
        .off => {}
    }
}

fn keyboardRawInput(self: *Self, events: []const Input.Event, buffer: [*]u8) void {
    for (events, 0..) |*event, i| {
        const code: u8 = @truncate(event.code.toLegacy());
        const prefix: u8 = if (event.action == .release) 0x80 else 0x00;

        buffer[i] = code | prefix;
    }

    _ = self.tty.bufferInput(buffer[0..events.len]);
}

fn keyboardMediumRawInput(self: *Self, events: []const Input.Event, buffer: [*]u8) void {
    var i: u32 = 0;
    for (events) |*event| {
        const code: u8 = @truncate(event.code.toInt());
        const prefix: u8 = if (event.action == .release) 0x80 else 0x00;

        buffer[i] = code | prefix;
        i += 1;
    }

    _ = self.tty.bufferInput(buffer[0..i]);
}

fn keyboardTranslateInput(self: *Self, events: []const Input.Event, buffer: [*]u8) void {
    var i: usize = 0;
    for (events) |*event| {
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
