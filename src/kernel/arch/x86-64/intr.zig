//! # Interrupts subsystem low-level implementation

// Copyright (C) 2024-2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

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

pub const table_len = max_vectors;

pub const trap_gate_flags = 0x8F;
pub const intr_gate_flags = 0x8E;

pub const max_vectors = 256;
pub const reserved_vectors = 32;
pub const avail_vectors = max_vectors - reserved_vectors;

pub const irq_base_vec = reserved_vectors;

const irq_stack_size = vm.page_size;

pub const Descriptor = packed struct {
    offset_1: u16 = 0,
    selector: u16 = 0,
    ist: u3 = 0,
    rsrvd: u5 = 0,

    type_attr: u8 = 0,
    offset_2: u48 = 0,

    rsrvd_1: u32 = 0,

    pub fn init(isr_ptr: u64, stack: u3, attr: u8) @This() {
        var result: @This() = .{ .ist = stack, .type_attr = attr, .selector = @bitCast(gdt.kernel_cs_sel) };

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

pub const Stack = enum(u3) { kernel = 0x0, nmi = 0x1, double_fault = 0x2 };

pub var except_handlers: [reserved_vectors]isr.ExceptionFn = undefined;

const IrqStack = [irq_stack_size / @sizeOf(u64)]u64;

var idts: []DescTable = &.{};
var tss_pool: []TaskStateSegment = &.{};
var irq_stacks: []IrqStack = &.{};

pub fn preinit() void {
    const cpus_num = smp.getNum();
    const idts_pages = std.math.divCeil(u32, @as(u32, cpus_num) * @sizeOf(DescTable), vm.page_size) catch unreachable;

    const tss_pages = std.math.divCeil(u32, cpus_num * @sizeOf(TaskStateSegment), vm.page_size) catch unreachable;

    const base = boot.alloc(idts_pages + tss_pages) orelse @panic("No memory to allocate IDTs per each cpu");
    const tss_base = base + (vm.page_size * idts_pages);

    idts.ptr = @ptrFromInt(vm.getVirtLma(base));
    idts.len = cpus_num;

    tss_pool.ptr = @ptrFromInt(vm.getVirtLma(tss_base));
    tss_pool.len = cpus_num;

    @memset(tss_pool, std.mem.zeroes(TaskStateSegment));

    for (tss_pool) |*tss| {
        gdt.addTss(tss) catch @panic("Failed to add TSS to GDT: Overflow");
    }

    initExceptHandlers();
    initStubHandlers();
}

pub fn init() !intr.Chip {
    try initTss();
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

    useIdt(&idts[cpu_idx]);
    regs.setTss(gdt.getTssOffset(cpu_idx));
}

pub fn setupIsr(vec: intr.Vector, isr_ptr: isr.Fn, stack: Stack, type_attr: u8) void {
    idts[vec.cpu][vec.vec] = .init(@intFromPtr(isr_ptr), @intFromEnum(stack), type_attr);
}

pub inline fn useIdt(idt: *DescTable) void {
    const idtr: regs.IDTR = .{ .base = @intFromPtr(idt), .limit = @sizeOf(DescTable) - 1 };

    regs.setIdtr(idtr);
}

pub inline fn enableForCpu() void {
    @setRuntimeSafety(false);
    asm volatile ("sti");
}

pub inline fn disableForCpu() void {
    @setRuntimeSafety(false);
    asm volatile ("cli");
}

pub inline fn isEnabledForCpu() bool {
    @setRuntimeSafety(false);
    const flags = regs.getFlags();
    return flags.intr_enable;
}

pub inline fn iret() void {
    asm volatile ("iretq");
}

fn initIdts() !void {
    for (idts[1..]) |*idt| {
        @memcpy(idt, &idts[0]);
    }
}

fn initTss() !void {
    const cpus_num = smp.getNum();
    const stacks_pages = std.math.divCeil(u32, @as(u32, cpus_num) * irq_stack_size, vm.page_size) catch unreachable;
    const rank = std.math.log2_int_ceil(u32, stacks_pages);

    const base = vm.PageAllocator.alloc(rank) orelse return error.NoMemory;

    irq_stacks.ptr = @ptrFromInt(vm.getVirtLma(base));
    irq_stacks.len = cpus_num;

    for (irq_stacks, tss_pool) |*stack, *tss| {
        const stack_ptr: u64 = @intFromPtr(stack) + irq_stack_size;
        const aligned_ptr = stack_ptr & 0xFFFF_FFFF_FFFF_FFF0;

        inline for (tss.ists[0..]) |*ist| {
            ist.* = aligned_ptr;
        }
        inline for (tss.rsps[0..]) |*rsp| {
            rsp.* = aligned_ptr;
        }
    }
}

fn initExceptHandlers() void {
    inline for (0..reserved_vectors) |vec| {
        const Handler = isr.ExcpHandler(vec);

        idts[0][vec] = .init(@intFromPtr(&Handler.isr), 0, trap_gate_flags);
        except_handlers[vec] = switch (vec) {
            isr.page_fault_vec => &isr.pageFaultHandler,
            else => &isr.commonExcpHandler,
        };
    }
}

fn initStubHandlers() void {
    inline for (reserved_vectors..max_vectors) |vec| {
        idts[0][vec] = .init(@intFromPtr(isr.stubIrqHandler(vec)), 0, intr_gate_flags);
    }
}
