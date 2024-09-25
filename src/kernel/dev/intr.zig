//! # Interrupt subsystem

const std = @import("std");

const arch = utils.arch;
const boot = @import("../boot.zig");
const dev = @import("../dev.zig");
const io = dev.io;
const log = @import("../log.zig");
const utils = @import("../utils.zig");
const vm = @import("../vm.zig");

pub const Chip = struct {
    pub const Operations = struct {
        const IrqFn = *const fn(*const Irq) void;

        pub const EoiFn = *const fn() void;
        pub const BindIrqFn = IrqFn;
        pub const UnbindIrqFn = IrqFn;
        pub const MaskIrqFn = IrqFn;
        pub const UnmaksIrqFn = IrqFn;

        eoi: EoiFn,
        bindIrq: BindIrqFn,
        unbindIrq: UnbindIrqFn,
        maskIrq: MaskIrqFn,
        unmaskIrq: UnmaksIrqFn
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
};

pub const Error = error {
    NoMemory,
    NoVector,
    IrqBusy,
    AlreadyUsed,
};

pub const Irq = struct {
    pub const Handler = struct {
        pub const Fn = *const fn(*const Irq, *dev.Device) bool;

        device: *dev.Device,
        func: Fn,
    };
    pub const TriggerMode = enum(u1) {
        edge,
        level
    };

    const HandlerList = utils.List(Handler);
    const HandlerNode = HandlerList.Node;

    vector: Vector,
    pin: u8,
    trigger_mode: TriggerMode,
    shared: bool,
    pending: std.atomic.Value(bool) = .{.raw = false},

    handlers: HandlerList = .{},
    handlers_lock: utils.Spinlock = .{},

    pub fn init(pin: u8, vector: Vector, trigger_mode: TriggerMode, shared: bool) Irq {
        return .{
            .pin = pin,
            .vector = vector,
            .trigger_mode = trigger_mode,
            .shared = shared
        };
    }

    pub inline fn eql(self: *const Irq, pin: u8) bool {
        return self.pin == pin;
    }

    pub fn addHandler(self: *Irq, func: Handler.Fn, device: *dev.Device) Error!void {
        if (!self.shared and self.handlers.len > 0) return error.IrqBusy;

        self.waitWhilePending();

        const node: *HandlerNode = @ptrCast(vm.kmalloc(@sizeOf(HandlerNode)) orelse return error.NoMemory);

        node.data.* = .{
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

        var node = self.handlers.first;

        while (node) |handler| : (node = handler.next) {
            if (handler.data.device == device) {
                if (self.handlers.len == 1) chip.maskIrq(self);

                self.waitWhilePending();

                self.handlers.remove(handler);
                vm.kfree(handler);

                return;
            }
        }

        unreachable;
    }

    pub fn handle(self: *Irq) bool {
        self.pending.store(true, .release);
        defer self.pending.store(false, .release);

        var node = self.handlers.first;

        while (node) |handler| : (node = handler.next) {
            if (handler.data.func(self, handler.data.device)) return true;
        }

        return false;
    }

    inline fn waitWhilePending(self: *const Irq) void {
        while (self.pending.load(.acquire)) {}
    }
};

pub const Vector = struct {
    pub const Cpu = union {
        specific: u16,
        all: void
    };

    cpu: Vector.Cpu,
    vec: u16,
};

const Cpu = struct {
    pub const IrqList = utils.SList(Irq);
    pub const IrqNode = IrqList.Node;

    bitmap: utils.Bitmap,
    allocated: u16 = 0,

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

pub const max_irqs = 128;

const max_cpus = 128;

const OrderArray = std.BoundedArray(*Cpu, max_cpus);
const CpuArray = std.BoundedArray(Cpu, max_cpus);
const IrqArray = std.BoundedArray(Irq, max_irqs);

var cpus_order = OrderArray.init(0) catch unreachable;
var cpus = CpuArray.init(0) catch unreachable;
var cpus_lock = utils.Spinlock.init(.unlocked);

var irqs = std.BoundedArray(?Irq, max_irqs).init(max_irqs) catch unreachable;

var chip: Chip = undefined;

pub fn init() !void {
    const cpus_num = boot.getCpusNum();

    cpus = try CpuArray.init(cpus_num);
    cpus_order = try OrderArray.init(cpus_num);

    const bytes_per_bm = std.math.divCeil(comptime_int, arch.intr.avail_vectors, utils.byte_size) catch unreachable;
    const bitmap_pool: [*]u8 = @ptrCast(vm.kmalloc(bytes_per_bm * cpus_num) orelse return error.NoMemory);

    for (cpus.buffer[0..cpus.len], 0..) |*cpu, i| {
        const bm_offset = i * bytes_per_bm;

        cpu.* = .{
            .bitmap = utils.Bitmap.init(bitmap_pool[bm_offset..bm_offset + bytes_per_bm], false),
        };
        cpus_order.set(i, cpu);
    }

    chip = try arch.intr.init();

    log.info("Interrupt controller: {s}", .{chip.name});
}

pub fn deinit() void {
    const pool = cpus.get(0).bitmap.bits.ptr;

    vm.kfree(pool);
}

pub fn requestIrq(pin: u8, device: *dev.Device, handler: Irq.Handler.Fn, tigger_mode: Irq.TriggerMode, shared: bool) Error!void {
    const irq_item = &irqs.buffer[pin];

    const irq = if (irq_item.*) |*irq_ent| blk: {
        if (!shared or irq_ent.trigger_mode != tigger_mode) return error.IrqBusy;
        break :blk irq_ent;
    }
    else blk: {
        const vector = allocVector(null) catch return error.NoVector;
        irq_item.* = Irq.init(pin, vector, tigger_mode, shared);

        const ptr = &irq_item.*.?;

        chip.bindIrq(ptr);
        break :blk ptr;
    };

    try irq.addHandler(device, handler);
}

pub fn releaseIrq(pin: u8, device: *const dev.Device) void {
    const irq = &irqs.buffer[pin].?;

    irq.removeHandler(device);

    if (irq.handlers.len > 0) return;

    irqs.buffer[pin] = null;

    chip.unbindIrq(irq);
    freeVector(irq.vector);
}

pub fn reserveVectors(cpu_idx: u16, vec_base: u16, num: u8) void {
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

pub fn handleIrq(pin: u8) void {
    _ = irqs.buffer[pin].?.handle();

    chip.eoi();
}

fn allocVector(cpu_idx: ?u16) ?Vector {
    cpus_lock.lock();
    defer cpus_lock.unlock();

    const cpu = if (cpu_idx) |idx| &cpus.buffer[idx] else cpus_order.get(0);

    const idx = cpu_idx orelse calcCpuIdx(cpu);
    const vec = cpu.allocVector() orelse return null;

    reorderCpus(idx, .forward);

    return .{
        .cpu = .{ .specific = idx },
        .vec = vec
    };
}

fn freeVector(vec: Vector) void {
    std.debug.assert(vec.cpu_idx < cpus.len and vec.vec < arch.intr.max_vectors);

    cpus_lock.lock();
    defer cpus_lock.unlock();

    cpus.buffer[vec.cpu_idx].freeVector(vec.vec);

    reorderCpus(vec.cpu.specific, .backward);
}

inline fn calcCpuIdx(cpu: *const Cpu) u16 {
    return @truncate((@intFromPtr(cpu) - @intFromPtr(&cpus.buffer)) / @sizeOf(Cpu));
}

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