//! # Interrupt subsystem

// Copyright (C) 2024 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const arch = utils.arch;
const boot = @import("../boot.zig");
const dev = @import("../dev.zig");
const io = dev.io;
const log = std.log.scoped(.intr);
const smp = @import("../smp.zig");
const utils = @import("../utils.zig");
const vm = @import("../vm.zig");

const cpu_any: u16 = 0xFFFF;

pub const Chip = struct {
    pub const Operations = struct {
        const IrqFn = *const fn(*const Irq) void;

        pub const EoiFn = *const fn() void;
        pub const BindIrqFn = IrqFn;
        pub const UnbindIrqFn = IrqFn;
        pub const MaskIrqFn = IrqFn;
        pub const UnmaksIrqFn = IrqFn;
        pub const ConfigMsiFn = *const fn(*Msi, u8, TriggerMode) void;

        eoi: EoiFn,
        bindIrq: BindIrqFn,
        unbindIrq: UnbindIrqFn,
        maskIrq: MaskIrqFn,
        unmaskIrq: UnmaksIrqFn,
        configMsi: ConfigMsiFn,
    };

    name: []const u8,
    ops: Operations,

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
};

pub const Error = error {
    NoMemory,
    NoVector,
    IntrBusy,
    AlreadyUsed,
};

pub const TriggerMode = enum(u2) {
    edge,
    level_high,
    level_low
};

pub const Handler = struct {
    pub const Fn = *const fn(*dev.Device) bool;

    device: *dev.Device,
    func: Fn,
};

pub const Irq = struct {
    const HandlerList = utils.List(Handler);
    const HandlerNode = HandlerList.Node;

    in_use: bool = false,

    vector: Vector,
    pin: u8,

    trigger_mode: TriggerMode,
    shared: bool,

    pending: std.atomic.Value(bool) = .{.raw = false},

    handlers: HandlerList = .{},
    handlers_lock: utils.Spinlock = .{},

    pub fn init(pin: u8, vector: Vector, trigger_mode: TriggerMode, shared: bool) Irq {
        return .{
            .in_use = true,
            .pin = pin,
            .vector = vector,
            .trigger_mode = trigger_mode,
            .shared = shared,
        };
    }

    pub fn deinit(self: *Irq) void {
        self.waitWhilePending();

        var node = self.handlers.first;

        while (node) |handler| {
            node = handler.next;
            vm.free(handler);
        }

        self.handlers = HandlerList{};
    }

    pub inline fn eql(self: *const Irq, pin: u8) bool {
        return self.pin == pin;
    }

    pub fn addHandler(self: *Irq, func: Handler.Fn, device: *dev.Device) Error!void {
        if (!self.shared and self.handlers.len > 0) return error.IntrBusy;

        self.waitWhilePending();

        const node: *HandlerNode = @alignCast(@ptrCast(vm.malloc(@sizeOf(HandlerNode)) orelse return error.NoMemory));

        node.data = .{
            .device = device,
            .func = func
        };

        self.handlers_lock.lock();
        defer self.handlers_lock.unlock();

        self.handlers.append(node);

        if (self.handlers.len == 1) chip.unmaskIrq(self);
    }

    pub fn removeHandler(self: *Irq, device: *const dev.Device) void {
        self.handlers_lock.lock();
        defer self.handlers_lock.unlock();

        const handler = self.findHandlerByDevice(device);

        if (self.handlers.len == 1) chip.maskIrq(self);

        self.waitWhilePending();

        self.handlers.remove(handler);
        vm.free(handler);
    }

    pub fn handle(self: *Irq) bool {
        self.pending.store(true, .release);
        defer self.pending.store(false, .release);

        var node = self.handlers.first;

        while (node) |handler| : (node = handler.next) {
            if (handler.data.func(handler.data.device)) return true;
        }

        return false;
    }

    inline fn waitWhilePending(self: *const Irq) void {
        while (self.pending.load(.acquire)) {}
    }

    fn findHandlerByDevice(self: *const Irq, device: *const dev.Device) *HandlerNode {
        var node = self.handlers.first;

        while (node) |handler| : (node = handler.next) {
            if (handler.data.device == device) return handler;
        }

        unreachable;
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

/// @noexport
const Cpu = struct {
    bitmap: utils.Bitmap = .{},
    allocated: u16 = 0,

    pub fn init(bits: []u8) Cpu {
        return .{ .bitmap = utils.Bitmap.init(bits, false) };
    }

    pub fn allocVector(self: *Cpu) ?u16 {
        if (self.allocated == arch.intr.avail_vectors) return null;

        const vec = self.bitmap.find(false) orelse return null;
        self.bitmap.set(vec);
        self.allocated += 1;

        return @truncate(vec + arch.intr.reserved_vectors);
    }

    pub fn freeVector(self: *Cpu, vec: u16) void {
        const raw_vec = vec - arch.intr.reserved_vectors;

        std.debug.assert(self.bitmap.get(raw_vec) != 0);

        self.bitmap.clear(raw_vec);
        self.allocated -= 1;
    }

    pub fn format(value: *const Cpu, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("{}:{}", .{calcCpuIdx(value), value.allocated});
    }
};

pub const max_intr = 128;

/// @noexport
const max_cpus = 128;

/// @noexport
const OrderArray = std.BoundedArray(*Cpu, max_cpus);
/// @noexport
const CpuArray = std.BoundedArray(Cpu, max_cpus);
/// @noexport
const IrqArray = std.BoundedArray(Irq, max_intr);
/// @noexport
const MsiArray = std.BoundedArray(Msi, max_intr);

var cpus_order = OrderArray.init(0) catch unreachable;
var cpus = CpuArray.init(0) catch unreachable;
var cpus_lock = utils.Spinlock.init(.unlocked);
var msis_lock = utils.Spinlock.init(.unlocked);

var irqs = IrqArray.init(max_intr) catch unreachable;
var msis = MsiArray.init(max_intr) catch unreachable;
var msis_used: u8 = 0;

pub var chip: Chip = undefined;

pub inline fn enableForCpu() void {
    arch.intr.enableForCpu();
}

pub inline fn disableForCpu() void {
    arch.intr.disableForCpu();
}

pub fn init() !void {
    const cpus_num = smp.getNum();

    cpus = try CpuArray.init(cpus_num);
    errdefer cpus.resize(0) catch unreachable;

    cpus_order = try OrderArray.init(cpus_num);
    errdefer cpus_order.resize(0) catch unreachable;

    const bytes_per_bm = std.math.divCeil(comptime_int, arch.intr.avail_vectors, utils.byte_size) catch unreachable;
    const bitmap_pool: [*]u8 = @ptrCast(vm.malloc(bytes_per_bm * cpus_num) orelse return error.NoMemory);

    for (cpus.slice(), 0..) |*cpu, i| {
        const bm_offset = i * bytes_per_bm;

        cpu.* = Cpu.init(bitmap_pool[bm_offset..bm_offset + bytes_per_bm]);
        cpus_order.set(i, cpu);
    }

    chip = try arch.intr.init();

    @memset(std.mem.asBytes(&msis.buffer), 0);
    @memset(std.mem.asBytes(&irqs.buffer), 0);

    log.info("controller: {s}", .{chip.name});
}

pub fn deinit() void {
    const pool = cpus.slice()[0].bitmap.bits.ptr;

    cpus.resize(0) catch unreachable;
    cpus_order.resize(0) catch unreachable;

    vm.free(pool);

    for (irqs.constSlice()) |*irq_ent| {
        if (irq_ent.*) |irq| {
            chip.unbindIrq(&irq);
            irq.deinit();
        }
    }
}

pub inline fn requestIrq(pin: u8, device: *dev.Device, handler: Handler.Fn, tigger_mode: TriggerMode, shared: bool) Error!void {
    const result = requestIrqEx(pin, device, handler, @intFromEnum(tigger_mode), shared);
    if (result < 0) return utils.intToErr(Error, result);
}

pub export fn releaseIrq(pin: u8, device: *const dev.Device) void {
    const irq = &irqs.buffer[pin];

    irq.removeHandler(device);

    if (irq.handlers.len > 0) return;

    irq.in_use = false;

    chip.unbindIrq(irq);
    freeVector(irq.vector);
}

pub fn handleIrq(pin: u8) void {
    @setRuntimeSafety(false);

    _ = irqs.buffer[pin].handle();

    chip.eoi();
}

pub fn handleMsi(idx: u8) void {
    @setRuntimeSafety(false);

    const handler = &msis.buffer[idx].handler;
    _ = handler.func(handler.device);

    chip.eoi();
}

pub inline fn requestMsi(
    device: *dev.Device, handler: Handler.Fn,
    trigger_mode: TriggerMode, cpu_idx: ?u16
) Error!u8 {
    const result = requestMsiEx(
        device, handler,
        @intFromEnum(trigger_mode), cpu_idx orelse cpu_any
    );
    return if (result < 0) utils.intToErr(Error, result) else @intCast(result);
}

pub export fn releaseMsi(idx: u8) void {
    msis_lock.lock();
    defer msis_lock.unlock();

    const msi = &msis.buffer[idx];

    std.debug.assert(msi.in_use);

    freeVector(msi.vector);

    msi.in_use = false;
    msis_used -= 1;
}

pub export fn getMsiMessage(idx: u8) Msi.Message {
    msis_lock.lock();
    defer msis_lock.unlock();

    const msi = &msis.buffer[idx];

    std.debug.assert(msi.in_use);

    return msi.message;
}

pub fn allocVector(cpu_idx: ?u16) ?Vector {
    cpus_lock.lock();
    defer cpus_lock.unlock();

    const cpu = if (cpu_idx) |idx| &cpus.buffer[idx] else cpus_order.get(0);

    const idx = cpu_idx orelse calcCpuIdx(cpu);
    const vec = cpu.allocVector() orelse return null;

    reorderCpus(idx, .forward);

    log.debug("allocated: cpu: {}, vec: {}", .{idx, vec});

    return .{
        .cpu = idx,
        .vec = vec
    };
}

pub fn freeVector(vec: Vector) void {
    std.debug.assert(vec.cpu < cpus.len and vec.vec < arch.intr.max_vectors);

    cpus_lock.lock();
    defer cpus_lock.unlock();

    cpus.buffer[vec.cpu].freeVector(vec.vec);

    reorderCpus(vec.cpu, .backward);
}

export fn requestIrqEx(pin: u8, device: *dev.Device, handler: *const anyopaque, tigger_int: u8, shared: bool) i16 {
    const tigger_mode: TriggerMode = @enumFromInt(tigger_int);
    const irq = &irqs.buffer[pin];

    if (irq.in_use) {
        if (!shared or irq.trigger_mode != tigger_mode) return utils.errToInt(Error.IntrBusy);
    } else {
        const vector = allocVector(null) orelse return utils.errToInt(Error.NoVector);
        irq.* = Irq.init(pin, vector, tigger_mode, shared);

        chip.bindIrq(irq);
    }

    irq.addHandler(@ptrCast(handler), device) catch |err| {
        return utils.errToInt(err);
    };

    return 0;
}

export fn requestMsiEx(device: *dev.Device, handler: *const anyopaque, trigger_int: u8, cpu_idx: u16) i16 {
    const trigger_mode: TriggerMode = @enumFromInt(trigger_int);

    msis_lock.lock();
    defer msis_lock.unlock();

    if (msis_used == max_intr) return utils.errToInt(Error.NoMemory);

    var idx = @intFromPtr(handler) % msis.len;
    while (msis.buffer[idx].in_use) {
        idx = (idx +% 1) % msis.len;
    }

    const msi = &msis.buffer[idx];
    const vec = allocVector(
        if (cpu_idx == cpu_any) null else cpu_idx
    ) orelse return utils.errToInt(Error.NoVector);

    msi.* = .{
        .message = undefined,
        .in_use = true,
        .vector = vec,
        .handler = .{ .func = @ptrCast(handler), .device = device },
    };

    chip.configMsi(msi, @truncate(idx), trigger_mode);
    msis_used += 1;

    return @intCast(idx);
}

inline fn calcCpuIdx(cpu: *const Cpu) u16 {
    return @truncate((@intFromPtr(cpu) - @intFromPtr(&cpus.buffer)) / @sizeOf(Cpu));
}

fn reserveVectors(cpu_idx: u16, vec_base: u16, num: u8) void {
    std.debug.assert(vec_base < arch.intr.max_vectors and num > 0);
    std.debug.assert(vec_base + num <= arch.intr.max_vectors);

    cpus_lock.lock();
    defer cpus_lock.unlock();

    const raw_base = vec_base - arch.intr.reserved_vectors;
    const cpu = &cpus.buffer[cpu_idx];

    for (0..num) |i| {
        const vec = raw_base + i;

        std.debug.assert(cpu.bitmap.get(vec) == 0);

        cpu.bitmap.set(vec);
    }

    cpu.allocated += num;

    reorderCpus(cpu_idx, .forward);
}

/// @noexport
fn reorderCpus(cpu_idx: u16, comptime direction: enum{forward, backward}) void {
    const cpu = &cpus.buffer[cpu_idx];
    var order_idx = std.mem.indexOf(
        *Cpu,
        cpus_order.slice(),
        &.{ cpu }
    ) orelse unreachable;

    switch (direction) {
        .forward => {
            while (
                order_idx < cpus.len - 1 and
                cpu.allocated > cpus_order.get(order_idx + 1).allocated
            ) : (order_idx += 1) {
                const temp = cpus_order.get(order_idx + 1);
                cpus_order.set(order_idx, temp);
                cpus_order.set(order_idx + 1, cpu);
            }
        },
        .backward => {
            while (
                order_idx > 0 and
                cpu.allocated < cpus_order.get(order_idx - 1).allocated
            ) : (order_idx -= 1) {
                const temp = cpus_order.get(order_idx - 1);
                cpus_order.set(order_idx, temp);
                cpus_order.set(order_idx - 1, cpu);
            }
        }
    }
}