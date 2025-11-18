//! # Interrupt subsystem

// Copyright (C) 2024-2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const arch = lib.arch;
const boot = @import("../boot.zig");
const dev = @import("../dev.zig");
const io = dev.io;
const lib = @import("../lib.zig");
const log = std.log.scoped(.intr);
const sched = @import("../sched.zig");
const smp = @import("../smp.zig");
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
    const List = std.DoublyLinkedList;
    const Node = List.Node;

    pub const Fn = *const fn(*dev.Device) bool;

    pub const alloc_config: vm.auto.Config = .{
        .allocator = .oma
    };

    device: *dev.Device,
    func: Fn,

    node: Node = .{},

    inline fn fromNode(node: *Node) *Handler {
        return @fieldParentPtr("node", node);
    }
};

pub const SoftHandler = struct {
    const List = std.SinglyLinkedList;

    pub const Node = List.Node;
    pub const Fn = *const fn(?*anyopaque) void;

    ctx: ?*anyopaque,
    func: Fn,

    pending: bool = false,
    node: Node = .{},

    pub fn init(func: Fn, ctx: ?*anyopaque) SoftHandler {
        return .{
            .func = func,
            .ctx = ctx
        };
    }

    inline fn fromNode(node: *Node) *SoftHandler {
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

    pub fn deinit(self: *Irq) void {
        self.waitWhilePending();

        var node = self.handlers.first;
        while (node) |n| {
            node = n.next;
            vm.auto.free(Handler, Handler.fromNode(n));
        }

        self.handlers = .{};
    }

    pub inline fn eql(self: *const Irq, pin: u8) bool {
        return self.pin == pin;
    }

    pub fn addHandler(self: *Irq, func: Handler.Fn, device: *dev.Device) Error!void {
        if (!self.shared and self.handlers.first != null) return error.IntrBusy;

        self.waitWhilePending();

        const handler: *Handler = vm.auto.alloc(Handler) orelse return error.NoMemory;
        handler.* = .{ .device = device, .func = func };

        self.handlers_lock.lock();
        defer self.handlers_lock.unlock();

        self.handlers.append(&handler.node);
        if (self.handlers.first == &handler.node) chip.unmaskIrq(self);
    }

    pub fn removeHandler(self: *Irq, device: *const dev.Device) void {
        self.handlers_lock.lock();
        defer self.handlers_lock.unlock();

        const handler = self.findHandlerByDevice(device);
        if (self.handlers.first == &handler.node) chip.maskIrq(self);

        self.waitWhilePending();

        self.handlers.remove(&handler.node);
        vm.gpa.free(handler);
    }

    pub fn handle(self: *Irq) bool {
        self.pending.store(true, .release);
        defer self.pending.store(false, .release);

        var node = self.handlers.first;

        while (node) |n| : (node = n.next) {
            const handler = Handler.fromNode(n);
            if (handler.func(handler.device)) return true;
        }

        return false;
    }

    inline fn waitWhilePending(self: *const Irq) void {
        while (self.pending.load(.acquire)) {}
    }

    fn findHandlerByDevice(self: *const Irq, device: *const dev.Device) *Handler {
        var node = self.handlers.first;
        while (node) |n| : (node = n.next) {
            const handler = Handler.fromNode(n);
            if (handler.device == device) return handler;
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
    bitmap: lib.Bitmap = .{},
    allocated: u16 = 0,

    pub fn init(bits: []u8) Cpu {
        return .{ .bitmap = .init(bits, false) };
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

const SoftIntrTask = struct {
    task: *sched.Task,

    sched_list: SoftHandler.List = .{},
    num_pending: std.atomic.Value(u8) = .init(0),

    pub fn handler() noreturn {
        const local = smp.getLocalData();
        const self = &soft_tasks[local.idx];

        while (true) {
            while (self.isPending()) {
                const soft_intr = self.pickSoftIntr();
                soft_intr.func(soft_intr.ctx);
            }

            sched.pause();
        }
    }

    pub fn isPending(self: *SoftIntrTask) bool {
        return self.num_pending.raw != 0;
    }

    pub fn schedule(self: *SoftIntrTask, intr: *SoftHandler) void {
        if (intr.pending) return;

        intr.pending = true;
        self.sched_list.prepend(&intr.node);
        self.num_pending.raw += 1;

        switch (self.task.stats.state) {
            .free => {
                self.task.stats.static_prior = sched.Task.high_static_prior;
                sched.enqueue(self.task);
            },
            .waiting => sched.resumeTask(self.task),
            else => {}
        }
    }

    inline fn pickSoftIntr(self: *SoftIntrTask) *SoftHandler {
        disableForCpu();
        defer enableForCpu();

        const intr = SoftHandler.fromNode(self.sched_list.popFirst().?);

        self.num_pending.raw -= 1;
        intr.pending = false;

        return intr;
    }
};

pub const max_intr = 128;
pub const max_msi = max_intr;

const max_cpus = smp.max_cpus;

const OrderArray = std.ArrayList(*Cpu);
const CpuArray = std.ArrayList(Cpu);

var order_buffer: [max_cpus]*Cpu = undefined;
var cpu_buffer: [max_cpus]Cpu = undefined;

var cpus_order: OrderArray = .initBuffer(&order_buffer);
var cpus: CpuArray = .initBuffer(&cpu_buffer);
var irqs: [max_intr]Irq = undefined;
var msis: [max_msi]Msi = undefined;
var msis_used: u8 = 0;

var cpus_lock: lib.sync.Spinlock = .init(.unlocked);
var msis_lock: lib.sync.Spinlock = .init(.unlocked);

var soft_tasks: []SoftIntrTask = undefined;

pub var chip: Chip = undefined;

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

pub fn init() !void {
    const cpus_num = smp.getNum();
    const bytes_per_bm = std.math.divCeil(
        comptime_int,
        arch.intr.avail_vectors,
        lib.byte_size
    ) catch unreachable;
    const bitmap_pool: [*]u8 = @ptrCast(vm.gpa.alloc(bytes_per_bm * cpus_num) orelse return error.NoMemory);
    errdefer vm.gpa.free(bitmap_pool);

    for (0..cpus_num) |i| {
        const bm_offset = i * bytes_per_bm;

        const cpu = cpus.addOneAssumeCapacity();
        cpu.* = .init(bitmap_pool[bm_offset..bm_offset + bytes_per_bm]);

        cpus_order.addOneAssumeCapacity().* = cpu;
    }

    try initSoftIntr(cpus_num);

    chip = try arch.intr.init();

    @memset(std.mem.sliceAsBytes(&irqs), 0);
    @memset(std.mem.sliceAsBytes(&msis), 0);

    log.info("controller: {s}", .{chip.name});
}

fn initSoftIntr(cpus_num: u16) !void {
    soft_tasks.ptr = @alignCast(@ptrCast(
        vm.gpa.alloc(@sizeOf(SoftIntrTask) * cpus_num) orelse return error.NoMemory
    ));
    errdefer vm.gpa.free(soft_tasks.ptr);

    soft_tasks.len = cpus_num;
    for (soft_tasks, 0..) |*soft_task, i| {
        const task = sched.newKernelTask("soft_intr", SoftIntrTask.handler) orelse {
            for (0..i) |j| sched.freeTask(soft_tasks[j].task);
            return error.NoMemory;
        };

        soft_task.* = .{ .task = task };
    }
}

pub fn deinit() void {
    const pool = cpus.items[0].bitmap.bits.ptr;

    cpus.shrinkRetainingCapacity(0);
    cpus_order.shrinkRetainingCapacity(0);

    vm.free(pool);

    for (irqs) |*irq| {
        if (irq.in_use) {
            chip.unbindIrq(irq);
            irq.deinit();
        }
    }

    for (soft_tasks) |*soft_task| sched.freeTask(soft_task.task);
    vm.free(soft_tasks.ptr);
}

pub inline fn requestIrq(pin: u8, device: *dev.Device, handler: Handler.Fn, tigger_mode: TriggerMode, shared: bool) Error!void {
    const result = requestIrqEx(pin, device, handler, @intFromEnum(tigger_mode), shared);
    if (result < 0) return lib.meta.intToErr(Error, result);
}

pub export fn releaseIrq(pin: u8, device: *const dev.Device) void {
    const irq = &irqs[pin];
    irq.removeHandler(device);

    if (irq.handlers.first != null) return;
    irq.in_use = false;

    chip.unbindIrq(irq);
    freeVector(irq.vector);
}

pub export fn handleIrq(pin: u8) void {
    @setRuntimeSafety(false);
    const local = smp.getLocalData();

    handlerEnter(local);
    defer handlerExit(local);

    _ = irqs[pin].handle();
}

pub export fn handleMsi(idx: u8) void {
    @setRuntimeSafety(false);
    const local = smp.getLocalData();

    handlerEnter(local);
    defer handlerExit(local);

    const handler = &msis[idx].handler;
    _ = handler.func(handler.device);
}

pub inline fn requestMsi(
    device: *dev.Device, handler: Handler.Fn,
    trigger_mode: TriggerMode, cpu_idx: ?u16
) Error!u8 {
    const result = requestMsiEx(
        device, handler,
        @intFromEnum(trigger_mode), cpu_idx orelse cpu_any
    );
    return if (result < 0) lib.meta.intToErr(Error, result) else @intCast(result);
}

pub export fn releaseMsi(idx: u8) void {
    msis_lock.lock();
    defer msis_lock.unlock();

    const msi = &msis[idx];

    std.debug.assert(msi.in_use);
    freeVector(msi.vector);

    msi.in_use = false;
    msis_used -= 1;
}

pub export fn getMsiMessage(idx: u8) Msi.Message {
    msis_lock.lock();
    defer msis_lock.unlock();

    const msi = &msis[idx];
    std.debug.assert(msi.in_use);

    return msi.message;
}

pub fn allocVector(cpu_idx: ?u16) ?Vector {
    cpus_lock.lock();
    defer cpus_lock.unlock();

    const cpu = if (cpu_idx) |idx| &cpus.items[idx] else cpus_order.items[0];

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
    std.debug.assert(vec.cpu < cpus.items.len and vec.vec < arch.intr.max_vectors);

    cpus_lock.lock();
    defer cpus_lock.unlock();

    cpus.items[vec.cpu].freeVector(vec.vec);

    reorderCpus(vec.cpu, .backward);
}

// TODO: Fix it, the implementation uses `unsched_list` field, that doesn't exists!
//pub fn allocSoftHandler(device: *dev.Device, cpu_idx: ?u16) bool {
//    const handler = vm.obj.new(SoftHandler) orelse return false;
//
//    const task_idx = if (cpu_idx) |idx| idx else smp.getIdx();
//    const soft_task = &soft_tasks[task_idx];
//
//    log.debug("soft irq: {}, cpu: {}", .{device.name, task_idx});
//
//    const node = &handler.node;
//    node.next = null;
//
//    soft_task.unsched_list.prepend(node);
//    device.soft_intr_num.fetchAdd(1, .release);
//
//    return true;
//}
//
//pub fn freeSoftHandler(device: *dev.Device, cpu_idx: ?u16) void {
//    std.debug.assert(device.soft_intr_num.raw > 0);
//
//    device.soft_intr_num.fetchSub(1, .acquire);
//
//    const task_idx = if (cpu_idx) |idx| idx else smp.getIdx();
//    const soft_task = &soft_tasks[task_idx];
//
//    const node = soft_task.unsched_list.popFirst() orelse unreachable;
//
//    vm.obj.free(SoftHandler, node.data);
//}

pub fn scheduleSoft(intr: *SoftHandler) void {
    const soft_task = &soft_tasks[smp.getIdx()];
    soft_task.schedule(intr);
}

export fn requestIrqEx(pin: u8, device: *dev.Device, handler: *const anyopaque, tigger_int: u8, shared: bool) i16 {
    const tigger_mode: TriggerMode = @enumFromInt(tigger_int);
    const irq = &irqs[pin];

    if (irq.in_use) {
        if (!shared or irq.trigger_mode != tigger_mode) return lib.meta.errToInt(Error.IntrBusy);
    } else {
        const vector = allocVector(null) orelse return lib.meta.errToInt(Error.NoVector);
        irq.* = Irq.init(pin, vector, tigger_mode, shared);

        chip.bindIrq(irq);
    }

    irq.addHandler(@ptrCast(handler), device) catch |err| {
        return lib.meta.errToInt(err);
    };

    return 0;
}

export fn requestMsiEx(device: *dev.Device, handler: *const anyopaque, trigger_int: u8, cpu_idx: u16) i16 {
    const trigger_mode: TriggerMode = @enumFromInt(trigger_int);

    msis_lock.lock();
    defer msis_lock.unlock();

    if (msis_used == max_intr) return lib.meta.errToInt(Error.NoMemory);

    var idx = @intFromPtr(handler) % msis.len;
    while (msis[idx].in_use) {
        idx = (idx +% 1) % msis.len;
    }

    const msi = &msis[idx];
    const vec = allocVector(
        if (cpu_idx == cpu_any) null else cpu_idx
    ) orelse return lib.meta.errToInt(Error.NoVector);

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
    return @truncate((@intFromPtr(cpu) - @intFromPtr(&cpu_buffer)) / @sizeOf(Cpu));
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
    const cpu = &cpus.items[cpu_idx];
    var order_idx = std.mem.indexOf(
        *Cpu,
        cpus_order.items,
        &.{ cpu }
    ) orelse unreachable;

    switch (direction) {
        .forward => {
            while (
                order_idx < cpus.items.len - 1 and
                cpu.allocated > cpus_order.items[order_idx + 1].allocated
            ) : (order_idx += 1) {
                const temp = cpus_order.items[order_idx + 1];
                cpus_order.items[order_idx] = temp;
                cpus_order.items[order_idx + 1] = cpu;
            }
        },
        .backward => {
            while (
                order_idx > 0 and
                cpu.allocated < cpus_order.items[order_idx - 1].allocated
            ) : (order_idx -= 1) {
                const temp = cpus_order.items[order_idx - 1];
                cpus_order.items[order_idx] = temp;
                cpus_order.items[order_idx - 1] = cpu;
            }
        }
    }
}

fn onIntrExit(local: *smp.LocalData) void {
    @setRuntimeSafety(false);

    if (local.tryIfNotNestedInterrupt()) {
        if (local.scheduler.needRescheduling()) {
            local.scheduler.reschedule();
        } else {
            local.exitInterrupt();
        }
    }
}

/// Used only in `handleMsi`, `handleIrq` and in
/// arch-specific timer interrupt routine.
pub inline fn handlerEnter(local: *smp.LocalData) void {
    local.scheduler.disablePreemption();
    local.enterInterrupt();
}

/// Used only in `handleMsi`, `handleIrq` and `intrHandlerExit`.
fn handlerExit(local: *smp.LocalData) void {
    @setRuntimeSafety(false);

    local.exitInterrupt();

    enableForCpu();
    chip.eoi();

    local.scheduler.enablePreemptionNoResched();
    onIntrExit(local);
}

/// Used in arch-specific code to exit from
/// timer interrupt routin.
export fn intrHandlerExit() callconv(.c) void {
    const local = smp.getLocalData();
    handlerExit(local);
}