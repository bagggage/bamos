//! # Interrupts subsystem low-level implementation

// Copyright (C) 2024-2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");
const builtin = @import("builtin");

const apic = @import("intr/apic.zig");
const boot = @import("../../boot.zig");
const gdt = @import("gdt.zig");
const intr = @import("../../dev/intr.zig");
const log = std.log.scoped(.@"x86-64.intr");
const pic = @import("intr/pic.zig");
const regs = @import("regs.zig");
const smp = @import("../../smp.zig");
const vm = @import("../../vm.zig");

pub const isr = @import("intr/isr.zig");
pub const except = @import("intr/except.zig");

pub const table_len = max_vectors;

pub const trap_gate_flags = 0x8F;
pub const intr_gate_flags = 0x8E;

pub const max_vectors = 256;
pub const reserved_vectors = 32;
pub const avail_vectors = max_vectors - reserved_vectors;

pub const irq_base_vec = reserved_vectors;

const irq_stack_size = std.math.ceilPowerOfTwoAssert(usize, @sizeOf(regs.InterruptFrame) * 2);

pub const Descriptor = packed struct {
    offset_1: u16 = 0,
    selector: u16 = 0,
    ist: u3 = 0,
    rsrvd: u5 = 0,

    type_attr: u8 = 0,
    offset_2: u48 = 0,

    rsrvd_1: u32 = 0,

    pub fn init(isr_ptr: u64, stack: Stack, attr: u8) @This() {
        var result: @This() = .{ .ist = @intFromEnum(stack), .type_attr = attr, .selector = @bitCast(gdt.kernel_cs_sel) };

        result.offset_1 = @truncate(isr_ptr);
        result.offset_2 = @truncate(isr_ptr >> 16);

        return result;
    }
};

pub const DescTable = [table_len]Descriptor;

pub const TaskStateSegment = extern struct {
    rsrvd: u32 = 0,

    rsps: [3]u64 align(@alignOf(u32)),
    rsrvd_1: u64 align(@alignOf(u32)) = 0,

    ists: [7]u64 align(@alignOf(u32)),
    rsrvd_2: u64 align(@alignOf(u32)) = 0,

    rsrvd_3: u16 = 0,
    io_map_base: u16,

    comptime {
        std.debug.assert(@sizeOf(TaskStateSegment) == 0x68);
    }
};

pub const Stack = enum(u3) { self = 0x0, double_fault = 0x1 };

pub var except_handlers: [reserved_vectors]except.Fn = undefined;

const IrqStack = [irq_stack_size / @sizeOf(u64)]u64;

var idts: []DescTable = &.{};
var irq_stacks: []IrqStack = &.{};

pub fn preinit() void {
    const cpus_num: u32 = smp.getNum();
 
    const stacks_pages = vm.bytesToPages(cpus_num * @sizeOf(IrqStack));
    const idts_pages = vm.bytesToPages(cpus_num * @sizeOf(DescTable));

    const idts_phys = boot.alloc(idts_pages) orelse @panic("No memory to allocate IDTs per each cpu");
    const stacks_phys = boot.alloc(stacks_pages) orelse @panic("No memory to allocate IRQ stacks per each cpu");

    idts.ptr = @ptrFromInt(vm.getVirtLma(idts_phys));
    idts.len = cpus_num;

    irq_stacks.ptr = @ptrFromInt(vm.getVirtLma(stacks_phys));
    irq_stacks.len = cpus_num;

    initExceptHandlers();
    initStubHandlers();
}

pub fn init() !intr.Chip {
    try initIdts();

    pic.init() catch return error.PicIoBusy;

    return blk: {
        apic.init() catch |err| {
            log.warn("APIC initialization failed: {}; using PIC", .{err});
            break :blk pic.chip();
        };

        break :blk apic.chip();
    };
}

pub inline fn setupCpu(cpu_idx: u16) void {
    // 2048 - because of `gdt.getTssOffset` (see it for details).
    comptime std.debug.assert(smp.max_cpus == 2048);

    const local = smp.getCpuData(cpu_idx);
    const tss = &local.arch_specific.tss;
    tss.* = std.mem.zeroes(TaskStateSegment);

    const stack = &irq_stacks[cpu_idx];
    const stack_top = @intFromPtr(stack) + @sizeOf(IrqStack);

    tss.ists[@intFromEnum(Stack.double_fault) - 1] = stack_top;
    gdt.addTss(tss) catch @panic("Failed to add TSS into GDT");

    useIdt(&idts[cpu_idx]);
    regs.setTss(gdt.getTssSelectorOffset(cpu_idx));
}

pub fn setupIsr(vec: intr.Vector, isr_ptr: isr.Fn, stack: Stack, type_attr: u8) void {
    idts[vec.cpu][vec.vec] = .init(@intFromPtr(isr_ptr), stack, type_attr);
}

pub inline fn useIdt(idt: *DescTable) void {
    const idtr: regs.IDTR = .{ .base = @intFromPtr(idt), .limit = @sizeOf(DescTable) - 1 };

    regs.setIdtr(idtr);
}

pub inline fn enableForCpu() void {
    asm volatile ("sti");
}

pub inline fn disableForCpu() void {
    asm volatile ("cli");
}

pub inline fn isEnabledForCpu() bool {
    @setRuntimeSafety(false);
    const flags = regs.getFlags();
    return flags.intr_enable;
}

pub inline fn iret() noreturn {
    @setRuntimeSafety(false);

    asm volatile ("iretq");
    unreachable;
}

fn initIdts() !void {
    for (idts[1..]) |*idt| {
        @memcpy(idt, &idts[0]);
    }
}

fn initExceptHandlers() void {
    inline for (0..reserved_vectors) |vec| {
        const handler = except.handler(vec);
        const vector = except.Vector.fromInt(@intCast(vec));

        const args = switch (vector) {
            .page_fault   => .{ .self,         &handler.isr, &except.pageFaultHandler },
            //.double_fault => .{ .double_fault, &handler.isr, &except.commonHandler },
            else          => .{ .self,         &handler.isr, &except.commonHandler }
        };

        idts[0][vec] = .init(@intFromPtr(args.@"1"), args.@"0", trap_gate_flags);
        except_handlers[vec] = args.@"2";
    }
}

fn initStubHandlers() void {
    inline for (reserved_vectors..max_vectors) |vec| {
        idts[0][vec] = .init(@intFromPtr(isr.stubIrqHandler(vec)), .self, intr_gate_flags);
    }
}
