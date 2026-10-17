//! # Input device interface

// Copyright (C) 2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const dev = @import("../../dev.zig");
const devfs = @import("../../vfs.zig").devfs;
const lib = @import("../../lib.zig");
const log = std.log.scoped(.@"dev.Input");
const sched = @import("../../sched.zig");
const sys = @import("../../sys.zig");
const vfs = @import("../../vfs.zig");
const vm = @import("../../vm.zig");

pub const Error = vfs.Error;

pub const Kind = enum(u8) {
    keyboard = 0,
    mouse    = 1,
    joystick = 2
};

/// Linux kernel scancodes
/// source: https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/include/uapi/linux/input-event-codes.h
pub const Scancode = enum(u16) {
    unknown    = 0,
    esc        = 1,

    @"1"       = 2,
    @"2"       = 3,
    @"3"       = 4,
    @"4"       = 5,
    @"5"       = 6,
    @"6"       = 7,
    @"7"       = 8,
    @"8"       = 9,
    @"9"       = 10,
    @"0"       = 11,

    minus      = 12,
    equal      = 13,
    backspace  = 14,
    tab        = 15,

    Q          = 16,
    W          = 17,
    E          = 18,
    R          = 19,
    T          = 20,
    Y          = 21,
    U          = 22,
    I          = 23,
    O          = 24,
    P          = 25,

    left_brace  = 26,
    right_brace = 27,
    enter       = 28,
    left_ctrl   = 29,

    A          = 30,
    S          = 31,
    D          = 32,
    F          = 33,
    G          = 34,
    H          = 35,
    J          = 36,
    K          = 37,
    L          = 38,

    semicolon  = 39,
    apostrope  = 40,
    grave      = 41,
    left_shift = 42,
    backslash  = 43,

    Z          = 44,
    X          = 45,
    C          = 46,
    V          = 47,
    B          = 48,
    N          = 49,
    M          = 50,

    comma         = 51,
    dot           = 52,
    slash         = 53,
    right_shift   = 54,
    kp_asterik    = 55,
    left_alt      = 56,
    space         = 57,
    capslock      = 58,

    f1         = 59,
    f2         = 60,
    f3         = 61,
    f4         = 62,
    f5         = 63,
    f6         = 64,
    f7         = 65,
    f8         = 66,
    f9         = 67,
    f10        = 68,

    numlock     = 69,
    scrolllok   = 70,
    kp_7        = 71,
    kp_8        = 72,
    kp_9        = 73,
    kp_minus    = 74,
    kp_4        = 75,
    kp_5        = 76,
    kp_6        = 77,
    kp_plus     = 78,
    kp_1        = 79,
    kp_2        = 80,
    kp_3        = 81,
    kp_0        = 82,
    kp_dot      = 83,

    zenkakuhankaku   = 85,
    @"102nd"         = 86,

    f11              = 87,
    f12              = 88,

    ro               = 89,
    katakana         = 90,
    hiragana         = 91,
    henkan           = 92,
    katakanahiragana = 93,
    muhenkan         = 94,

    kp_jpcomma       = 95,
    kp_enter         = 96,

    right_ctrl       = 97,

    kp_slash         = 98,

    sysrq            = 99,
    right_alt        = 100,
    line_feed        = 101,
    home             = 102,
    up               = 103,
    page_up          = 104,
    left             = 105,
    right            = 106,
    end              = 107,
    down             = 108,
    page_down        = 109,
    insert           = 110,
    delete           = 111,
    macro            = 112,
    mute             = 113,
    volume_down      = 114,
    volume_up        = 115,
    power            = 116,	// SC System power down

    kp_equal         = 117,
    kp_plus_minus    = 118,

    pause            = 119,
    scale            = 120,	// AL Cosmpiz scale (expose)

    @"fn"           = 0x1d0,
    fn_esc          = 0x1d1,
    fn_f1           = 0x1d2,
    fn_f2           = 0x1d3,
    fn_f3           = 0x1d4,
    fn_f4           = 0x1d5,
    fn_f5           = 0x1d6,
    fn_f6           = 0x1d7,
    fn_f7           = 0x1d8,
    fn_f8           = 0x1d9,
    fn_f9           = 0x1da,
    fn_f10          = 0x1db,
    fn_f11          = 0x1dc,
    fn_f12          = 0x1dd,
    fn_1            = 0x1de,
    fn_2            = 0x1df,
    fn_d            = 0x1e0,
    fn_e            = 0x1e1,
    fn_f            = 0x1e2,
    fn_s            = 0x1e3,
    fn_b            = 0x1e4,
    fn_right_shift  = 0x1e5,

    pub inline fn toInt(self: Scancode) u16 {
        return @intFromEnum(self);
    }

    pub inline fn isFunctionKey(self: Scancode) bool {
        const int = self.toInt();
        return (int >= Scancode.f1.toInt() and int <= Scancode.f10.toInt()) or
            (int == Scancode.f11.toInt() or int == Scancode.f12.toInt());
    }

    pub inline fn isNumpad(self: Scancode) bool {
        const int = self.toInt();
        return (int >= Scancode.kp_7.toInt() and int <= Scancode.kp_dot.toInt());
    }

    /// Converts scancode value to legacy PS/2 set 1 code.
    pub fn toLegacy(self: Scancode) u16 {
        const code = @intFromEnum(self);
        if (code < @intFromEnum(Scancode.kp_enter)) return @truncate(code);

        return switch (self) {
            .right_ctrl => 0xe01d,
            .right_alt  => 0xe038,
            .insert => 0xe052,
            .home => 0xe047,
            .page_up => 0xe049,
            .delete => 0xe053,
            .end => 0xe04f,
            .page_down => 0xe051,
            .up => 0xe048,
            .left => 0xe04b,
            .right => 0xe04d,
            .down => 0xe050,
            .kp_slash => 0xe035,
            .kp_enter => 0xe01c,
            .mute => 0xe020,
            .volume_up => 0xe030,
            .volume_down => 0xe02e,
            .power => 0xe05e,
            else => 0x0
        };
    }
};

pub const Sync = enum(u16) {
    report    = 0,
    config    = 1,
    mt_report = 2,
    dropped   = 3,
};

pub const AnyCode = extern union {
    scan: Scancode,
    sync: Sync,
};

pub const Action = enum(u8) {
    press   = 0,
    release = 1,
    repeat  = 2,
};

pub const Leds = packed struct {
    numlock: bool     = false,
    capslock: bool    = false,
    scroll_lock: bool = false,
    fn_lock: bool     = false,
    specific0: bool = false,
    specific1: bool = false,
    specific2: bool = false,
    specific3: bool = false,

    pub inline fn all() Leds {
        return @bitCast(@as(u8, 0xff));
    }
};

pub const Event = struct {
    pub const Type = enum(u8) {
        sync = 0,
        key = 1,
        relative = 2,
        absolute = 3,
        misc = 4,
        @"switch" = 5,
        led = 17,
        sound = 18,
        repeat = 19,

        max,
    };

    pub const Supported = struct {
        pub const KeyBits = std.bit_set.ArrayBitSet(usize, 0x300);

        const TypeBitSet = std.bit_set.IntegerBitSet(std.meta.fields(Event.Type).len);

        const bits_sizes: []const u32 = &.{ @sizeOf(KeyBits) };

        types: TypeBitSet,
        bits: [*]const u8,

        pub fn build(comptime pairs: []const struct{ Type, []const AnyCode }) Supported {
            var type_bits: TypeBitSet = .initEmpty();
            inline for (pairs) |p| {
                const bit_idx: comptime_int = @intFromEnum(p.@"0");
                if (type_bits.isSet(bit_idx)) {
                    @compileError("Duplicates of code sets with type '"++@tagName(p.@"0")++"'' is found");
                }

                type_bits.set(bit_idx);
            }

            var types: []const Type = &.{};
            comptime var bits_size: comptime_int = 0;
            inline for (0..type_bits.capacity()) |i| {
                if (!type_bits.isSet(i)) continue;
                const item: []const Type = &.{ @enumFromInt(i) };
                types = types ++ item;

                if (i == 0) continue;
                bits_size += bits_sizes[i - 1];
            }

            var bits: std.bit_set.ArrayBitSet(usize, bits_size * @sizeOf(usize)) = .initEmpty();
            var offset: u32 = 0;
            for (types, 0..) |t, i| {
                if (t == .sync) continue;
                const code_set = blk: {
                    for (pairs) |p| if (p.@"0" == t) break :blk p.@"1";
                    unreachable;
                };

                for (code_set) |c| {
                    const bit_idx: u16 = @bitCast(c);
                    bits.set(bit_idx);
                }

                offset += bits_sizes[i - 1];
            }

            const bits_masks = bits.masks;
            const Static = opaque { const static_bits = bits_masks; };

            return .{
                .types = type_bits,
                .bits = @ptrCast(&Static.static_bits),
            };
        }

        pub fn getBits(self: *const Supported, @"type": Type) []const u8 {
            if (@"type" == .sync) return @as([*]const u8, @ptrCast(&self.types.mask))[0..1];
            const bit_idx = @intFromEnum(@"type") - 1;

            var offset: usize = 0;
            for (0..bit_idx) |i| {
                if (i >= bits_sizes.len) break;
                if (self.types.isSet(i)) offset += bits_sizes[i];
            }

            if (bit_idx >= bits_sizes.len) return &.{};
            return self.bits[offset..offset + bits_sizes[bit_idx]];
        }
    };

    pub const Handle = struct {
        pub const List = lib.rcu.SinglyLinkedList;
        pub const Node = List.Node;

        pub const alloc_config: vm.auto.Config = .{
            .allocator = .gpa,
            .capacity = 128
        };

        device: *Self,
        handler: *Handler,

        node: Node = .{},
        dev_node: Node = .{},

        pub inline fn fromNode(node: *Node) *Handle {
            return @fieldParentPtr("node", node);
        }

        pub inline fn fromDevNode(dev_node: *Node) *Handle {
            return @fieldParentPtr("dev_node", dev_node);
        }

        inline fn process(self: *Handle, event: Event) bool {
            return self.handler.callback(self.handler.ctx, self.device, event);
        }
    };

    pub const Handler = struct {
        pub const Fn = *const fn (ctx: lib.AnyData, device: *Self, event: Event) bool;

        pub const List = lib.rcu.SinglyLinkedList;
        pub const Node = List.Node;

        callback: Fn,
        ctx: lib.AnyData = .{},

        handles: Handle.List = .{},
        node: Node = .{},

        pub inline fn fromNode(node: *Node) *Handler {
            return @fieldParentPtr("node", node);
        }
    };

    pub const Listener = struct {
        const List = lib.rcu.SinglyLinkedList;
        const Node = List.Node;

        pub const default_len = 64;

        pub const alloc_config: vm.auto.Config = .{
            .allocator = .gpa,
            .capacity = 128
        };

        events: lib.RingBuffer(Event) = .{},
        node: Node = .{},

        pub fn init(capacity: u16) Error!Listener {
            return .{ .events = try .create(capacity) };
        }

        pub inline fn deinit(self: *Listener) void {
            self.events.delete();
        }

        inline fn fromNode(node: *Node) *Listener {
            return @fieldParentPtr("node", node);
        }
    };

    /// Linux kernel `struct input_event`
    /// source: https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/include/uapi/linux/input.h
    pub const Linux = extern struct {
        sec: u64 = 0,
        usec: u64 = 0,
        @"type": u16,
        code: u16 = undefined,
        value: u32 = undefined,
    };

    @"type": Type,
    action: Action,
    code: AnyCode,

    timestamp_us: u32,

    pub inline fn initSync(code: Sync, timestamp_us: u32) Event {
        return .initAny(
            .sync, @enumFromInt(0),
            .{ .sync = code }, timestamp_us,
        );
    }

    pub inline fn initKey(action: Action, code: Scancode, timestamp_us: u32) Event {
        return .initAny(
            .key, action,
            .{ .scan = code }, timestamp_us,
        );
    }

    inline fn initAny(@"type": Type, action: Action, code: AnyCode, timestamp_us: u32) Event {
        return .{
            .@"type" = @"type",
            .action = action,
            .code = code,
            .timestamp_us = timestamp_us,
        };
    }

    inline fn toLinux(self: *const Event) Linux {
        return .{
            .sec = self.timestamp_us / std.time.us_per_s,
            .usec = self.timestamp_us % std.time.us_per_s,
            .@"type" = @intFromEnum(self.@"type"),
            .code = @bitCast(self.code),
            .value = @intFromEnum(self.action),
        };
    }
};

pub const Request = union(Kind) {
    pub const Fn = *const fn (*Self, Request) Error!void;

    pub const Keyboard = union(enum) {
        set_leds: struct {
            values: Leds,
            mask: Leds,
        },

        set_repeat_rate_and_delay: struct {
            delay_ms: u8 = 0,
            rate_hz: u8 = 0,
        },
    };

    pub const Mouse = void;
    pub const Joystick = void;

    keyboard: Keyboard,
    mouse: Mouse,
    joystick: Joystick,
};

pub const IList = lib.rcu.SinglyLinkedList;
pub const INode = IList.Node;

const Ioctl = enum(u32) {
    const IOCTL = std.os.linux.IOCTL;

    const BusType = enum(u16) {
        pci = 0x1,
        isa_pnp = 0x2,
        usb = 0x3,
        hil = 0x4,
        bluetooth = 0x5,
        virtual = 0x6,

        isa = 0x10,
        i8042 = 0x11,
        xtkbd = 0x12,
        rs232 = 0x13,
        game_port = 0x14,
        parallel_port = 0x15,
        amiga = 0x16,
        adb = 0x17,
        i2c = 0x18,
        host = 0x19,
        gsc = 0x1a,
        atari = 0x1b,
        spi = 0x1c,
        rmi = 0x1d,
        cec = 0x1e,
        intel_ishtp = 0x1f,
        amd_sfh = 0x20,
        sdw = 0x21,
    };

    const Id = extern struct {
        bus_type: BusType,
        vendor: u16,
        product: u16,
        version: u16,
    };

    get_version = IOCTL.IOR('E', 0x01, u32),
    get_device_id = IOCTL.IOR('E', 0x02, Id),

    get_name = IOCTL.IOR('E', 0x06, void),
    get_phys_loc = IOCTL.IOR('E', 0x07, void),
    get_unique_id = IOCTL.IOR('E', 0x08, void),
    get_properties = IOCTL.IOR('E', 0x09, void),
    get_global_key_state = IOCTL.IOR('E', 0x18, void),
    get_all_leds = IOCTL.IOR('E', 0x19, void),
    get_all_sounds = IOCTL.IOR('E', 0x1a, void),
    get_all_switches = IOCTL.IOR('E', 0x1b, void),
    get_event_bits = IOCTL.IOR('E', 0x20, void),
    get_key_bits = IOCTL.IOR('E', 0x21, void),
    get_relative_bits = IOCTL.IOR('E', 0x22, void),
    get_absolute_bits = IOCTL.IOR('E', 0x23, void),
    get_misc_bits = IOCTL.IOR('E', 0x24, void),
    get_sw_bits = IOCTL.IOR('E', 0x25, void),
    get_led_bits = IOCTL.IOR('E', 0x31, void),
    get_sound_bits = IOCTL.IOR('E', 0x32, void),
    get_repeat_bits = IOCTL.IOR('E', 0x33, void),
    get_ff_bits = IOCTL.IOR('E', 0x34, void),
    get_power_bits = IOCTL.IOR('E', 0x35, void),
    get_ff_status_bits = IOCTL.IOR('E', 0x36, void),
    grab = IOCTL.IOW('E', 0x90, u32),
    _,

    inline fn maskSize(self: Ioctl) struct{ Ioctl, u16 } {
        var req: IOCTL.Request = @bitCast(@intFromEnum(self));
        const size = req.size;
        req.size = 0;

        return .{ @enumFromInt(@as(u32, @bitCast(req))), size };
    }

    inline fn getNumber(self: Ioctl) u8 {
        const req: IOCTL.Request = @bitCast(@intFromEnum(self));
        return req.nr;
    }
};

const Self = @This();

const max_num = 512;
const dev_ops: devfs.DevFile.Operations = .{
    .open = devFileOpen,
    .close = devFileClose,
    .fops = .{
        .read = fileRead,
        .write = fileWrite,
        .poll = filePoll,
        .ioctl = fileIoctl,
    },
};

var num_map: std.bit_set.ArrayBitSet(usize, max_num) = .{ .masks = undefined };
var num_lock: lib.sync.Spinlock = .{};
var dev_region: devfs.Region = .{ .major = 13 };

idx: u16,
kind: Kind,
name: [*:0]const u8,
id: Ioctl.Id,
events: Event.Supported,
dev_file: devfs.DevFile,

request_op: ?Request.Fn = null,

handles: Event.Handle.List = .{},
listeners: Event.Listener.List = .{},

wait_lock: lib.sync.Spinlock = .{},
event_wait: sched.WaitQueue = .{},

immediate: dev.intr.SoftHandler = .{ .func = &immediateHandler },

node: INode = .{},

pub inline fn preinit() void {
    @memset(&num_map.masks, std.math.maxInt(usize));
}

pub fn setup(self: *Self, kind: Kind, events: Event.Supported, name: [*:0]const u8, id: Ioctl.Id) Error!void {
    const num = allocDevNum() orelse return error.MaxSize;
    errdefer freeDevNum(num);

    const idx = allocIndex() orelse return error.MaxSize;
    errdefer freeIndex(idx);

    self.* = .{
        .idx = @intCast(idx),
        .kind = kind,
        .events = events,
        .name = name,
        .id = id,
        .dev_file = .{
            .name = dev.Name.print("event{}", .{idx}) catch unreachable,
            .num = num,
            .access = .{
                .gid = 0,
                .perm = vfs.Permissions.makeInt(.rw, .rw, .none) 
            },
            .ops = &dev_ops,
        },
    };
    errdefer self.dev_file.name.deinit();

    self.immediate.ctx = self;

    try devfs.registerCharDev(&self.dev_file, "input");
    try sys.input.registerDevice(self);
}

pub fn deinit(self: *Self) void {
    // FIXME: Implement proper deinitialization
    // devfs.unregisterDevice(&self.dev_file);
    sys.input.unregisterDevice(self);

    {
        num_lock.lock();
        defer num_lock.unlock();

        num_map.set(self.idx);
        dev_region.free(self.dev_file.num);
    }

    self.dev_file.name.deinit();
}

pub inline fn fromNode(node: *INode) *Self {
    return @fieldParentPtr("node", node);
}

pub inline fn fromDevFile(devf: *devfs.DevFile) *Self {
    return @fieldParentPtr("dev_file", devf);
}

pub inline fn pushKeyEvent(self: *Self, action: Action, code: Scancode) void {
    const timestamp_us: u32 = @truncate(sys.time.getTimestamp() / std.time.ns_per_us);
    self.processEvents(&.{
        .initKey(action, code, timestamp_us),
        .initSync(.report, timestamp_us),
    });
}

pub fn createHandle(self: *Self, handler: *Event.Handler) Error!*Event.Handle {
    const handle = vm.auto.alloc(Event.Handle) orelse return error.NoMemory;
    handle.* = .{ .device = self, .handler = handler };

    self.handles.prepend(&handle.dev_node);
    return handle;
}

pub fn deleteHandle(self: *Self, handle: *Event.Handle) void {
    _ = self.handles.remove(&handle.dev_node);
    vm.auto.free(Event.Handle, handle);
}

pub fn createListener(self: *Self) !*Event.Listener {
    const listener = vm.auto.alloc(Event.Listener) orelse return error.NoMemory;
    errdefer vm.auto.free(Event.Listener, listener);

    listener.* = try .init(Event.Listener.default_len);
    self.listeners.prepend(&listener.node);

    return listener;
}

pub fn deleteListener(self: *Self, listener: *Event.Listener) void {
    _ = self.listeners.remove(&listener.node);

    listener.deinit();
    vm.auto.free(Event.Listener, listener);
}

pub fn safeNotifyListeners(self: *Self) void {
    if (!dev.intr.isEnabledForCpu()) {
        dev.intr.scheduleImmediate(&self.immediate);
        return;
    }

    self.notifyListeners();
}

pub fn notifyListeners(self: *Self) void {
    self.wait_lock.lockAtomic();
    defer self.wait_lock.unlockAtomic();

    sched.awakeAll(&self.event_wait);
}

pub fn request(self: *Self, rq: Request) Error!void {
    if (self.request_op == null) return error.BadOperation;
    if (std.meta.activeTag(rq) != self.kind) return error.InvalidArgs;

    return self.request_op.?(self, rq);
}

fn linuxRequest(self: *Self, event: *const Event.Linux) Error!void {
    if (event.@"type" >= @intFromEnum(Event.Type.max)) return error.InvalidArgs;

    const @"type": Event.Type = @enumFromInt(event.@"type");
    switch (@"type") {
        .sync => {},
        .led => {
            if (event.code >= std.mem.byte_size_in_bits) return error.InvalidArgs;

            const mask = @as(u8, 1) << @truncate(event.code);
            const values = if (event.value != 0) mask else 0;

            try self.request(.{ .keyboard = .{ .set_leds = .{
                .values = @bitCast(values), .mask = @bitCast(mask),
            }}});
        },
        else => return error.InvalidArgs,
    }
}

fn immediateHandler(ctx: ?*anyopaque) void {
    const self: *Self = @alignCast(@ptrCast(ctx.?));
    self.notifyListeners();
}

fn processEvents(self: *Self, events: []const Event) void {
    std.debug.assert(!dev.intr.isEnabledForCpu());

    if (self.processHandles(events)) return;
    self.processListeners(events);
}

fn processHandles(self: *Self, events: []const Event) bool {
    const gen = self.handles.ctrl.readLock();
    defer self.handles.ctrl.readUnlock(gen);

    var filtered = false;
    var node = self.handles.head.load(.acquire);
    while (node) |n| : (node = n.next) {
        const handle = Event.Handle.fromDevNode(n);
        for (events) |e| {
            filtered = handle.process(e) or filtered;
        }
    }

    return filtered;
}

fn processListeners(self: *Self, events: []const Event) void {
    const need_notify = blk: {
        const gen = self.listeners.ctrl.readLock();
        defer self.listeners.ctrl.readUnlock(gen);

        var node = self.listeners.head.load(.acquire);
        var need_notify: bool = false;
        while (node) |n| : (node = n.next) {
            const listener = Event.Listener.fromNode(n);
            need_notify = true;

            listener.events.lock.lockAtomic();
            defer listener.events.lock.unlockAtomic();

            for (events) |e| listener.events.pushOverflow(e);
        }

        break :blk need_notify;
    };

    if (need_notify) self.safeNotifyListeners();
}

fn allocDevNum() ?devfs.DevNum {
    num_lock.lock();
    defer num_lock.unlock();

    return dev_region.alloc();
}

fn freeDevNum(num: devfs.DevNum) void {
    num_lock.lock();
    defer num_lock.unlock();

    dev_region.free(num);
}

fn allocIndex() ?u16 {
    num_lock.lock();
    defer num_lock.unlock();

    return @intCast(num_map.toggleFirstSet() orelse return null);
}

fn freeIndex(idx: u16) void {
    num_lock.lock();
    defer num_lock.unlock();

    num_map.set(idx);
}

fn devFileOpen(devf: *devfs.DevFile, file: *vfs.File) vfs.Error!void {
    const input = fromDevFile(devf);
    const listener = try input.createListener();

    file.data.setPtr(listener);
}

fn devFileClose(devf: *devfs.DevFile, file: *vfs.File) void {
    const input = fromDevFile(devf);
    const listener = file.data.asPtr(Event.Listener).?;

    file.data.setPtr(null);
    input.deleteListener(listener);
}

fn fileRead(file: *const vfs.File, _: usize, buffer: []u8) vfs.Error!usize {
    const listener = file.data.asPtr(Event.Listener).?;
    const input = fromDevFile(devfs.DevFile.fromDentry(file.dentry));

    if (buffer.len % @sizeOf(Event.Linux) != 0) return error.InvalidArgs;
    const events: []Event.Linux = @alignCast(@ptrCast(buffer));

    var i: usize = 0;
    outer: while (true) {
        {
            listener.events.lock.lock();
            defer listener.events.lock.unlock();

            while (listener.events.pop()) |e| : (i += 1) {
                events[i] = e.toLinux();
            }

            if (i > 0) break :outer;
            input.wait_lock.lock();
        }

        try sched.waitUnlock(&input.event_wait, &input.wait_lock, true);
    }

    return i * @sizeOf(Event.Linux);
}

fn fileWrite(file: *vfs.File, _: usize, buffer: []const u8) vfs.Error!usize {
    if (buffer.len % @sizeOf(Event.Linux) != 0) return error.InvalidArgs;

    const input = fromDevFile(devfs.DevFile.fromDentry(file.dentry));
    const events: []const Event.Linux = @alignCast(@ptrCast(buffer));
    for (events) |e| try input.linuxRequest(&e);

    return buffer.len;
}

fn filePoll(
    file: *vfs.File,
    wait_entry: *vfs.File.Poll.WaitEntry,
    action: vfs.File.Poll.WaitAction,
) vfs.Error!vfs.File.Poll {
    const listener = file.data.asPtr(Event.Listener).?;
    const input = fromDevFile(devfs.DevFile.fromDentry(file.dentry));

    switch (action) {
        .enqueue => {
            input.wait_lock.lock();
            defer input.wait_lock.unlock();

            input.event_wait.push(wait_entry);
        },
        .remove => {
            input.wait_lock.lock();
            defer input.wait_lock.unlock();

            input.event_wait.removeWeak(wait_entry);
        },
        .none => {},
    }

   return .{ .read_avail = listener.events.itemsToRead() > 0 };
}

fn fileIoctl(file: *vfs.File, cmd: c_uint, arg: usize) vfs.Error!void {
    const input = fromDevFile(devfs.DevFile.fromDentry(file.dentry));
    const data: lib.AnyData = .from(arg);
    const ioctl: Ioctl = @enumFromInt(cmd);

    switch (ioctl) {
        .get_version => data.asPtr(c_int).?.* = 0x10001,
        .get_device_id => data.asPtr(Ioctl.Id).?.* = input.id,
        .grab => {
            // FIXME: Implement
        },
        else => {
            const masked, const size = ioctl.maskSize();
            switch (masked) {
                .get_name => try ioctlStringCopy(data, input.name, size),
                .get_phys_loc => try ioctlStringCopy(data, "", size), // FIXME: Implement
                .get_unique_id => try ioctlStringCopy(data, "", size), // FIXME: Implement
                .get_properties,
                .get_global_key_state,
                .get_all_leds,
                .get_all_sounds,
                .get_all_switches => {
                    // FIXME: Implement
                    const dst: [*]u8 = @ptrCast(data.asPtr(u8).?);
                    @memset(dst[0..size], 0);
                },
                .get_event_bits,
                .get_key_bits,
                .get_relative_bits,
                .get_absolute_bits,
                .get_misc_bits,
                .get_sw_bits,
                .get_led_bits,
                .get_sound_bits,
                .get_repeat_bits,
                .get_ff_bits,
                .get_power_bits,
                .get_ff_status_bits => {
                    const type_idx = ioctl.getNumber() -% 0x20;
                    if (type_idx >= @intFromEnum(Event.Type.max)) return;

                    const @"type": Event.Type = @enumFromInt(type_idx);
                    const dst: [*]u8 = @ptrCast(data.asPtr(u8).?);
                    const src: []const u8 = @ptrCast(input.events.getBits(@"type"));
                    const len = @min(src.len, size);

                    if (len > 0) @memcpy(dst[0..len], src[0..len]);
                },
                else => {
                    log.debug("unknown ioctl: {}", .{@as(std.os.linux.IOCTL.Request, @bitCast(cmd))});
                    return error.InvalidArgs;
                },
            }
        },
    }
}

fn ioctlStringCopy(data: lib.AnyData, src: [*:0]const u8, size: u32) !void {
    if (size == 0) return error.InvalidArgs;

    const dst: [*]u8 = @ptrCast(data.asPtr(u8).?);
    var i: u32 = 0;

    while (i < size and src[i] != 0) {
        dst[i] = src[i];
        i += 1;
    }

    if (i < size) dst[i] = 0;
}
