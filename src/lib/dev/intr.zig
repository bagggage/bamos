//! # Interrupt subsystem

// Copyright (C) 2024-2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const arch = lib.arch;
const bindings = @import("../bindings.zig");
const dev = @import("../dev.zig");
const lib = @import("../lib.zig");
const vm = @import("../vm.zig");

pub const Error = error {
    NoMemory,
    NoVector,
    IntrBusy,
    AlreadyUsed,
};

pub const Chip = struct {
    pub const Operations = struct {
        const IrqFn = *const fn(*const Irq) void;

        pub const EoiFn = *const fn() void;
        pub const BindIrqFn = IrqFn;
        pub const UnbindIrqFn = IrqFn;
        pub const MaskIrqFn = IrqFn;
        pub const UnmaksIrqFn = IrqFn;
        pub const ConfigMsiFn = *const fn(*Msi, u8, TriggerMode) void;
        pub const InitPerCpuFn = *const fn (u16) void;

        eoi: EoiFn,
        bindIrq: BindIrqFn,
        unbindIrq: UnbindIrqFn,
        maskIrq: MaskIrqFn,
        unmaskIrq: UnmaksIrqFn,
        configMsi: ConfigMsiFn,
        initPerCpu: ?InitPerCpuFn = null,
    };

    name: []const u8,
    ops: Operations,

    pub fn is(self: *const Chip, check_name: []const u8) bool {
        return std.mem.eql(u8, self.name, check_name);
    }

    pub inline fn eoi(self: *const Chip) void {
        self.ops.eoi();
    }

    pub inline fn bindIrq(self: *const Chip, irq: *const Irq) void {
        self.ops.bindIrq(irq);
    }

    pub inline fn unbindIrq(self: *const Chip, irq: *const Irq) void {
        self.ops.unbindIrq(irq);
    }

    pub inline fn maskIrq(self: *const Chip, irq: *const Irq) void {
        self.ops.maskIrq(irq);
    }

    pub inline fn unmaskIrq(self: *const Chip, irq: *const Irq) void {
        self.ops.unmaskIrq(irq);
    }

    pub inline fn configMsi(self: *const Chip, msi: *Msi, idx: u8, trigger_mode: TriggerMode) void {
        self.ops.configMsi(msi, idx, trigger_mode);
    }

    pub inline fn initPerCpu(self: *const Chip, cpu: u16) void {
        if (self.ops.initPerCpu) |func| func(cpu);
    }
};

pub const TriggerMode = enum(u2) {
    edge,
    level_high,
    level_low
};

pub const Handler = struct {
    const List = std.DoublyLinkedList;
    const Node = List.Node;

    pub const Fn = *const fn(*dev.Device) bool;

    pub const alloc_config: vm.auto.Config = .{
        .allocator = .oma
    };

    device: *dev.Device,
    func: Fn,

    node: Node = .{},

    pub inline fn fromNode(node: *Node) *Handler {
        return @fieldParentPtr("node", node);
    }
};

pub const SoftHandler = struct {
    pub const List = std.SinglyLinkedList;

    pub const Node = List.Node;
    pub const Fn = *const fn(?*anyopaque) void;

    func: Fn,
    ctx: ?*anyopaque = null,

    node: Node = .{},

    pub fn init(func: Fn, ctx: ?*anyopaque) SoftHandler {
        return .{
            .func = func,
            .ctx = ctx
        };
    }

    pub inline fn acquire(self: *SoftHandler) bool {
        return @cmpxchgStrong(
            ?*Node, &self.node.next, null,
            &self.node, .release, .monotonic
        ) == null;
    }

    pub inline fn release(self: *SoftHandler) void {
        @atomicStore(?*Node, &self.node.next, null, .release);
    }

    pub inline fn fromNode(node: *Node) *SoftHandler {
        return @fieldParentPtr("node", node);
    }
};

pub const Irq = struct {
    in_use: bool = false,

    vector: Vector,
    pin: u8,

    trigger_mode: TriggerMode,
    shared: bool,

    pending: std.atomic.Value(bool) = .init(false),

    handlers: Handler.List = .{},
    handlers_lock: lib.sync.Spinlock = .{},

    pub fn init(pin: u8, vector: Vector, trigger_mode: TriggerMode, shared: bool) Irq {
        return .{
            .in_use = true,
            .pin = pin,
            .vector = vector,
            .trigger_mode = trigger_mode,
            .shared = shared,
        };
    }

    pub inline fn eql(self: *const Irq, pin: u8) bool {
        return self.pin == pin;
    }
};

pub const Msi = struct {
    pub const Message = extern struct {
        address: usize,
        data: u32
    };

    in_use: bool = false,

    vector: Vector,
    handler: Handler,
    message: Message,
};

pub const Vector = struct {
    cpu: u16,
    vec: u16,
};

pub const max_intr = 128;
pub const max_msi = max_intr;

/// Enable all interrupts for current CPU.
pub inline fn enableForCpu() void {
    arch.intr.enableForCpu();
}

/// Disable all interrupts (except NMI) for current CPU.
pub inline fn disableForCpu() void {
    arch.intr.disableForCpu();
}

/// Returns `true` if interrupts is enabled for current CPU,
/// `false` otherwise.
pub inline fn isEnabledForCpu() bool {
    return arch.intr.isEnabledForCpu();
}

/// Disable interrupts for current CPU.
/// 
/// Returns `true` if interrupts was enabled before 
/// this function disable it, `false` otherwise.
pub inline fn saveAndDisableForCpu() bool {
    const intr_enable = arch.intr.isEnabledForCpu();
    arch.intr.disableForCpu();
    return intr_enable;
}

/// Enable interrupts for current CPU if `intr_enable`=`true`,
/// otherwise do nothing.
/// 
/// Used in pair with `saveAndDisableForCpu`.
pub inline fn restoreForCpu(intr_enable: bool) void {
    if (intr_enable) arch.intr.enableForCpu();
}

pub inline fn requestIrq(
    pin: u8,
    device: *dev.Device,
    handler: Handler.Fn,
    tigger_mode: TriggerMode,
    shared: bool,
) Error!void {
    return bindings.getInstance().dev.intr.requestIrq(pin, device, handler, tigger_mode, shared);
}

pub inline fn releaseIrq(pin: u8, device: *const dev.Device) void {
    bindings.getInstance().dev.intr.releaseIrq(pin, device);
}

pub inline fn requestMsi(
    device: *dev.Device,
    handler: Handler.Fn,
    trigger_mode: TriggerMode,
    cpu_idx: ?u16,
) Error!u8 {
    return bindings.getInstance().dev.intr.requestMsi(device, handler, trigger_mode, cpu_idx);
}

pub inline fn releaseMsi(idx: u8) void {
    bindings.getInstance().dev.intr.releaseMsi(idx);
}

pub inline fn getMsiMessage(idx: u8) Msi.Message {
    return bindings.getInstance().dev.intr.getMsiMessage(idx);
}

pub inline fn allocVector(cpu_idx: ?u16) ?Vector {
    return bindings.getInstance().dev.intr.allocVector(cpu_idx);
}

pub inline fn freeVector(vec: Vector) void {
    bindings.getInstance().dev.intr.freeVector(vec);
}

pub inline fn scheduleImmediate(intr: *SoftHandler) void {
    bindings.getInstance().dev.intr.scheduleImmediate(intr);
}

pub inline fn scheduleSoft(intr: *SoftHandler) void {
    bindings.getInstance().dev.intr.scheduleSoft(intr);
}
