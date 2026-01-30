//! # AT Keyboard driver

// Copyright (C) 2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const dev = @import("../../../dev.zig");
const Input = dev.classes.Input;
const log = std.log.scoped(.@"at.kbd");
const lib = @import("../../../lib.zig");
const ps2 = @import("../../stds/ps2.zig");
const vm = @import("../../../vm.zig");

const Leds = packed struct {
    scroll_lock: bool = false,
    numlock: bool = false,
    capslock: bool = false,

    specific0: bool = false,
    specific1: bool = false,
    specific2: bool = false,
    specific3: bool = false,
    specific4: bool = false,
};

const scancodes = opaque {
    const Subcommand = enum(u8) {
        get_current = 0,
        set_1st_set = 1,
        set_2nd_set = 2,
        set_3rd_set = 3
    };

    const Current = enum(u8) {
        @"1st_set" = 0x43,
        @"2nd_set" = 0x41,
        @"3rd_set" = 0x3f
    };

    const Code = enum(u8) {
        ack = 0xfa,
        repeat = 0xfe,

        extended = 0xe0,
        extended2 = 0xe1,
        release = 0xf0,
        _
    };

    const Set2 = enum(u8) {
        unknown     = 0x00,

        f9          = 0x01,
        f5          = 0x03,
        f3          = 0x04,
        f1          = 0x05,
        f2          = 0x06,
        f12         = 0x07,
        f10         = 0x09,
        f8          = 0x0a,
        f6          = 0x0b,
        f4          = 0x0c,
        tab         = 0x0d,
        grave       = 0x0e,
        left_alt    = 0x11,
        left_shift  = 0x12,
        left_ctrl   = 0x14,
        Q           = 0x15,
        @"1"        = 0x16,
        Z           = 0x1a,
        S           = 0x1b,
        A           = 0x1c,
        W           = 0x1d,
        @"2"        = 0x1e,
        C           = 0x21,
        X           = 0x22,
        D           = 0x23,
        E           = 0x24,
        @"4"        = 0x25,
        @"3"        = 0x26,
        space       = 0x29,
        V           = 0x2a,
        F           = 0x2b,
        T           = 0x2c,
        R           = 0x2d,
        @"5"        = 0x2e,
        N           = 0x31,
        B           = 0x32,
        H           = 0x33,
        G           = 0x34,
        Y           = 0x35,
        @"6"        = 0x36,
        M           = 0x3a,
        J           = 0x3b,
        U           = 0x3c,
        @"7"        = 0x3d,
        @"8"        = 0x3e,
        comma       = 0x41,
        K           = 0x42,
        I           = 0x43,
        O           = 0x44,
        @"0"        = 0x45,
        @"9"        = 0x46,
        dot         = 0x49,
        slash       = 0x4a,
        L           = 0x4b,
        semicolon   = 0x4c,
        P           = 0x4d,
        minus       = 0x4e,
        apostrope   = 0x52,
        left_brace  = 0x54,
        equal       = 0x55,
        capslock    = 0x58,
        right_shift = 0x59,
        enter       = 0x5a,
        right_brace = 0x5b,
        backslash   = 0x5d,

        backspace   = 0x66,
        kp_1        = 0x69,
        kp_4        = 0x6b,
        kp_7        = 0x6c,
        kp_0        = 0x70,
        kp_dot      = 0x71,
        kp_2        = 0x72,
        kp_5        = 0x73,
        kp_6        = 0x74,
        kp_8        = 0x75,
        esc         = 0x76,
        numlock     = 0x77,
        f11         = 0x78,
        kp_plus     = 0x79,
        kp_3        = 0x7a,
        kp_minus    = 0x7b,
        kp_asterik  = 0x7c,
        kp_9        = 0x7d,
        scroll_lock = 0x7e,
        f7          = 0x83,

        // extended
        www_search  = 0x80 | 0x10,
        right_alt   = 0x80 | 0x11,
        right_ctrl  = 0x80 | 0x14,
        prev_track  = 0x80 | 0x15,
        www_fav     = 0x80 | 0x18,
        left_gui    = 0x80 | 0x1f,
        www_refresh = 0x80 | 0x20,
        volume_down = 0x80 | 0x21,
        mute        = 0x80 | 0x23,
        right_gui   = 0x80 | 0x27,
        www_stop    = 0x80 | 0x28,
        calculator  = 0x80 | 0x2b,
        apps        = 0x80 | 0x2f,
        www_forward = 0x80 | 0x30,
        volume_up   = 0x80 | 0x32,
        play_pause  = 0x80 | 0x34,
        power       = 0x80 | 0x37,
        www_back    = 0x80 | 0x38,
        www_home    = 0x80 | 0x3a,
        stop        = 0x80 | 0x3b,
        sleep       = 0x80 | 0x3f,
        my_computer = 0x80 | 0x40,
        email       = 0x80 | 0x48,
        kp_slash    = 0x80 | 0x4a,
        next_track  = 0x80 | 0x4d,
        mm_select   = 0x80 | 0x50,
        kp_enter    = 0x80 | 0x5a,
        wake        = 0x80 | 0x5e,
        end         = 0x80 | 0x69,
        left        = 0x80 | 0x6b,
        home        = 0x80 | 0x6c,
        insert      = 0x80 | 0x70,
        delete      = 0x80 | 0x71,
        down        = 0x80 | 0x72,
        right       = 0x80 | 0x74,
        up          = 0x80 | 0x75,
        page_down   = 0x80 | 0x7a,
        page_up     = 0x80 | 0x7d,

        max,
        _,

        const len = @intFromEnum(Set2.max);
        const set_to_input: [len]Input.Scancode = blk: {
            var table: [len]Input.Scancode = .{ .unknown } ** len;
            const set2 = std.meta.fields(Set2);
            for (set2) |set2_code| {
                if (@hasField(Input.Scancode, set2_code.name)) {
                    table[set2_code.value] = @field(Input.Scancode, set2_code.name);
                }
            }
            break :blk table;
        };

        inline fn toInputScancode(self: Set2) Input.Scancode {
            return set_to_input[@intFromEnum(self)];
        }
    };
};

const Typematic = packed struct {
    const Delay = enum(u2) {
        @"250ms" = 0,
        @"500ms" = 1,
        @"750ms" = 2,
        @"1s" = 3,
    };

    const max_rate_hz = 30;
    const min_rate_hz = 2;

    repeat_rate: u5 = 0,
    repeat_delay: Delay,

    reserved: u1 = 0,
};

const Command = enum(u8) {
    set_led = 0xed,
    echo = 0xee,
    scancode_set = 0xf0,
    identify = 0xf2,
    set_typematic_rate_delay = 0xf3,
    enable_scanning = 0xf4,
    disable_scanning = 0xf5,
    set_defaults = 0xf6,
    set_all_typematic_autorepeat = 0xf7,
    set_all_make_release = 0xf8,
    set_all_make_only = 0xf9,
    set_all_make_typematic_autorepeat_make_release = 0xfa,
    set_specific_typematic_autorepeat = 0xfb,
    set_specific_make_release = 0xfc,
    set_specific_make_only = 0xfd,
    resend = 0xfe,
    reset = 0xff,

    pub inline fn toInt(self: Command) u8 {
        return @intFromEnum(self);
    }
};

const Keyboard = struct {
    input: Input,

    state: packed struct {
        capslock: bool = false,
        numlock: bool = false,
        scroll_lock: bool = false,

        release: bool = false,
        ext: u2 = 0,

        update_leds: bool = false,
        update_typematic: bool = false,
    } = .{},
    last_code: u8 = 0,

    typematic: Typematic = .{ .repeat_delay = .@"250ms" },

    scancode_set: scancodes.Current = .@"2nd_set",
    immediate: dev.intr.SoftHandler = .{ .func = &immediateHandler },

    fn identify() !*Keyboard {
        const id = try ps2.identifyDevice(0);
        switch (id) {
            .at_keyboard, .mf2_keyboard, .short_keyboard, .ncd_n97_keyboard, .@"122_key_keyboard", .ncd_sun_keyboard => {},
            else => return error.Unsupported,
        }

        const self = vm.gpa.create(Keyboard) orelse return error.NoMemory;
        errdefer vm.gpa.free(self);

        var name: dev.Name = try .print("0.ps2.{t}", .{id});
        errdefer name.deinit();

        self.* = .{ .input = undefined };
        self.immediate.ctx = self;

        const irq = ps2.getIrqPin(0);
        try dev.intr.requestIrq(irq, &self.input.device, &interruptHandler, .edge, true);
        errdefer dev.intr.releaseIrq(irq, &self.input.device);

        try self.input.setup(name, .keyboard);
        errdefer self.input.deinit();

        self.input.request_op = &inputRequest;

        try self.enable();
        return self;
    }

    fn deinit(self: *Keyboard) void {
        self.disable() catch {};
        self.device.bus.removeDevice(self);
        dev.intr.releaseIrq(ps2.getIrqPin(0), &self.device);
    }

    inline fn delete(self: *Keyboard) void {
        self.deinit();
        vm.gpa.free(self);
    }

    inline fn fromInput(device: *Input) *Keyboard {
        return @fieldParentPtr("input", device);
    }

    fn enable(_: *Keyboard) !void {
        try ps2.sendPortCmdAck(0, Command.set_defaults.toInt());
        try ps2.sendPortCmdAck(0, Command.enable_scanning.toInt());
        errdefer ps2.sendPortCmdAck(0, Command.disable_scanning.toInt()) catch {};

        try ps2.enableIrq(0);
    }

    fn disable(self: *Keyboard) !void {
        try ps2.sendPortCmdAck(0, Command.disable_scanning.toInt());
        try ps2.disableIrq(0);

        try self.setLeds(.{});
    }

    fn setRepeatRateAndDelay(_: *Keyboard, rate: u5, delay: Typematic.Delay) !void {
        const tmp_rate = (@as(u16, rate) -| Typematic.min_rate_hz) * 1134;
        const raw_rate: u5 = @truncate(std.math.maxInt(u5) - (tmp_rate / 1024));
        const typematic: Typematic = .{ .repeat_delay = delay, .repeat_rate = raw_rate };

        dev.intr.disableForCpu();
        defer dev.intr.enableForCpu();

        try ps2.sendPortCmdAck(0, Command.set_typematic_rate_delay.toInt());
        try ps2.writeData(@bitCast(typematic));
    }

    fn setLeds(_: *Keyboard, leds: Leds) !void {
        dev.intr.disableForCpu();
        defer dev.intr.enableForCpu();

        try ps2.sendPortCmdAck(0, Command.set_led.toInt());
        try ps2.writeData(@bitCast(leds));
    }

    fn interruptHandler(device: *dev.Device) bool {
        const input: *Input = @fieldParentPtr("device", device);
        const kbd = Keyboard.fromInput(input);

        const code: scancodes.Code = @enumFromInt(ps2.readDataRaw());

        switch (code) {
            .ack,
            .repeat => return true,
            .extended => kbd.state.ext = 1,
            .extended2 => kbd.state.ext = 2,
            .release => kbd.state.release = true,
            else => {
                const int_code = @intFromEnum(code) | @as(u8, (if (kbd.state.ext > 0) 0x80 else 0));
                const set_code: scancodes.Set2 = @enumFromInt(int_code);

                defer kbd.state.release = false;
                defer kbd.state.ext = 0;

                const action: Input.Action = if (kbd.state.release) blk: {
                    if (kbd.last_code == int_code) kbd.last_code = 0;
                    break :blk .release;
                } else if (kbd.last_code == int_code) blk: {
                    break :blk .repeat;
                } else blk: {
                    kbd.last_code = int_code;
                    break :blk .press;
                };

                kbd.input.pushKeyEvent(action, set_code.toInputScancode());
            }
        }

        return true;
    }

    fn immediateHandler(ctx: ?*anyopaque) void {
        const self: *Keyboard = @alignCast(@ptrCast(ctx.?));
        if (self.state.update_leds) {
            self.state.update_leds = false;
            self.setLeds(.{
                .capslock = self.state.capslock,
                .numlock = self.state.numlock,
                .scroll_lock = self.state.scroll_lock
            }) catch {};
        }
        if (self.state.update_typematic) {
            self.state.update_typematic = false;
            self.setRepeatRateAndDelay(
                self.typematic.repeat_rate,
                self.typematic.repeat_delay
            ) catch {};
        }
    }

    inline fn bufferByte(self: *Keyboard, byte: u8) void {
        self.scan_buffer[self.scan_pos] = byte;
        self.scan_pos = (self.scan_pos + 1) & @as(u8, @truncate(self.scan_buffer.len - 1));
    }
};

pub fn init() !void {
    if (!ps2.isAvailable()) return;

    const driver = dev.getKernelDriver();
    const kbd = Keyboard.identify() catch |err| {
        if (err == error.Unsupported) return;
        return err;
    };

    driver.attachDevice(&kbd.input.device);
}

fn inputRequest(device: *Input, request: Input.Request) Input.Error!void {
    const kbd = Keyboard.fromInput(device);
    switch (request.keyboard) {
        .set_leds => |arg| {
            kbd.state.numlock = arg.numlock;
            kbd.state.capslock = arg.capslock;
            kbd.state.scroll_lock = arg.scroll_lock;

            if (!dev.intr.isEnabledForCpu()) {
                kbd.state.update_leds = true;
                dev.intr.scheduleImmediate(&kbd.immediate);
            } else {
                kbd.setLeds(.{
                    .numlock = arg.numlock,
                    .capslock = arg.capslock,
                    .scroll_lock = arg.scroll_lock
                }) catch return error.IoFailed;
            }
        },
        .set_repeat_rate_and_delay => |arg| {
            if (arg.rate_hz < 2 or arg.rate_hz > 30 or
                arg.delay_ms < 250 or arg.delay_ms > 1000
            ) return error.InvalidArgs;

            const delay = if (arg.delay_ms == 1000) blk: {
                break :blk Typematic.Delay.@"1s";
            } else if (arg.delay_ms >= 750) blk: {
                break :blk Typematic.Delay.@"750ms";
            } else if (arg.delay_ms >= 500) blk: {
                break :blk Typematic.Delay.@"500ms";
            } else Typematic.Delay.@"250ms";

            kbd.typematic = .{ .repeat_rate = @truncate(arg.rate_hz), .repeat_delay = delay };

            if (!dev.intr.isEnabledForCpu()) {
                kbd.state.update_typematic = true;
                dev.intr.scheduleImmediate(&kbd.immediate);
            } else {
                kbd.setRepeatRateAndDelay(
                    kbd.typematic.repeat_rate,
                    kbd.typematic.repeat_delay
                ) catch return error.IoFailed;
            }
        },
    }
}
