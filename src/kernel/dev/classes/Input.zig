//! # Input device interface

// Copyright (C) 2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const dev = @import("../../dev.zig");
const devfs = @import("../../vfs.zig").devfs;
const lib = @import("../../lib.zig");
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
};

pub const Action = enum(u8) {
    press   = 0,
    release = 1,
    repeat  = 2
};

pub const Event = struct {
    pub const Type = enum(u8) {
        key,
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

        pub inline fn fromNode(node: *Node) *Handle {
            return @fieldParentPtr("node", node);
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

    @"type": Type,
    action: Action,
    code: Scancode,

    timestamp: u32,

    pub inline fn initKey(action: Action, code: Scancode) Event {
        return .initAny(.key, action, code);
    }

    inline fn initAny(@"type": Type, action: Action, code: Scancode) Event {
        return .{
            .@"type" = @"type",
            .action = action,
            .code = code,
            .timestamp = sys.time.getShortTimestamp(),
        };
    }
};

pub const Request = union(Kind) {
    pub const Fn = *const fn (*Self, Request) Error!void;

    pub const Keyboard = union(enum) {
        set_leds: packed struct {
            numlock: bool     = false,
            capslock: bool    = false,
            scroll_lock: bool = false,
            fn_lock: bool     = false,

            specific0: bool = false,
            specific1: bool = false,
            specific2: bool = false,
            specific3: bool = false
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

const Self = @This();

const max_num = 512;
const dev_ops: devfs.DevFile.Operations = .{
    .fops = vfs.internals.file.default.ops,
};

var num_map: std.bit_set.ArrayBitSet(usize, max_num) = .{ .masks = undefined };
var num_lock: lib.sync.Spinlock = .{};
var dev_region: devfs.Region = .{ .major = 13 };

idx: u16,
kind: Kind,
device: dev.Device = .{ .bus = undefined },
dev_file: devfs.DevFile,

request_op: ?Request.Fn = null,

handles: Event.Handle.List = .{},
listeners: Event.Listener.List = .{},

wait_lock: lib.sync.Spinlock = .{},
event_wait: sched.WaitQueue = .{},

node: INode = .{},

immediate: dev.intr.SoftHandler = .{ .func = &immediateHandler },

pub inline fn preinit() void {
    @memset(&num_map.masks, std.math.maxInt(usize));
}

pub fn setup(self: *Self, name: dev.Name, kind: Kind) Error!void {
    const num = allocDevNum() orelse return error.MaxSize;
    errdefer freeDevNum(num);

    const idx = allocIndex() orelse return error.MaxSize;
    errdefer freeIndex(idx);

    self.* = .{
        .idx = @intCast(idx),
        .kind = kind,
        .device = .{ .name = name, .bus = undefined },
        .dev_file = .{
            .name = try .print("event{}", .{idx}),
            .num = num,
            .ops = &dev_ops,
            .data = .fromPtr(self)
        },
    };
    errdefer self.dev_file.name.deinit();

    self.immediate.ctx = self;

    try devfs.registerCharDev(&self.dev_file);
    try sys.input.registerDevice(self);
}

pub fn deinit(self: *Self) void {
    // devfs.unregisterDevice(&self.dev_file);
    sys.input.unregisterDevice(self);

    {
        num_lock.lock();
        defer num_lock.unlock();

        num_map.set(self.idx);
        dev_region.free(self.dev_file.num);
    }

    self.device.deinit();
    self.dev_file.name.deinit();
}

pub inline fn fromNode(node: *INode) *Self {
    return @fieldParentPtr("node", node);
}

pub inline fn pushKeyEvent(self: *Self, action: Action, code: Scancode) void {
    self.processEvent(.initKey(action, code));
}

pub fn createHandle(self: *Self, handler: *Event.Handler) Error!*Event.Handle {
    const handle = vm.auto.alloc(Event.Handle) orelse return error.NoMemory;
    handle.* = .{ .device = self, .handler = handler };

    self.handles.prepend(&handle.node);
    return handle;
}

pub fn deleteHandle(self: *Self, handle: *Event.Handle) void {
    _ = self.handles.remove(&handle.node);
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
    self.listeners.remove(&listener.node);

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

fn immediateHandler(ctx: ?*anyopaque) void {
    const self: *Self = @alignCast(@ptrCast(ctx.?));
    self.notifyListeners();
}

fn processEvent(self: *Self, event: Event) void {
    std.debug.assert(!dev.intr.isEnabledForCpu());

    if (self.processHandles(event)) return;
    self.processListeners(event);
}

fn processHandles(self: *Self, event: Event) bool {
    const gen = self.handles.ctrl.readLock();
    defer self.handles.ctrl.readUnlock(gen);

    var filtered = false;
    var node = self.handles.head.load(.acquire);
    while (node) |n| : (node = n.next) {
        const handle = Event.Handle.fromNode(n);
        filtered = handle.process(event) or filtered;
    }

    return filtered;
}

fn processListeners(self: *Self, event: Event) void {
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

            listener.events.pushOverflow(event);
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

fn allocIndex() ?usize {
    num_lock.lock();
    defer num_lock.unlock();

    return num_map.toggleFirstSet();
}

fn freeIndex(idx: usize) void {
    num_lock.lock();
    defer num_lock.unlock();

    num_map.set(idx);
}
