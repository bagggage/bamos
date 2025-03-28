//! # Interrupts subsystem low-level implementation

// Copyright (C) 2024 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const apic = @import("intr/apic.zig");
const arch = @import("arch.zig");
const boot = @import("../../boot.zig");
const gdt = @import("gdt.zig");
const intr = @import("../../dev/intr.zig");
const log = std.log.scoped(.@"x86-64.intr");
const logger = @import("../../logger.zig");
const panic = @import("../../panic.zig");
const pic = @import("intr/pic.zig");
const regs = @import("regs.zig");
const smp = @import("../../smp.zig");
const utils = @import("../../utils.zig");
const vm = @import("../../vm.zig");

pub const table_len = max_vectors;

pub const trap_gate_flags = 0x8F;
pub const intr_gate_flags = 0x8E;

pub const max_vectors = 256;
pub const reserved_vectors = 32;
pub const avail_vectors = max_vectors - reserved_vectors;

pub const irq_base_vec = reserved_vectors;

const rsrvd_vec_num = 32;
const irq_stack_size = vm.page_size;

pub const Descriptor = packed struct {
    offset_1: u16 = 0,
    selector: u16 = 0,
    ist: u3 = 0,
    rsrvd: u5 = 0,

    type_attr: u8 = 0,
    offset_2: u48 = 0,

    rsrvd_1: u32 = 0,

    pub fn init(isr: u64, stack: u3, attr: u8) @This() {
        var result: @This() = .{
            .ist = stack,
            .type_attr = attr,
            .selector = regs.getCs()
        };

        result.offset_1 = @truncate(isr);
        result.offset_2 = @truncate(isr >> 16);

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

const IsrFn = *const fn() callconv(.Naked) noreturn;
const ExceptionIsrFn = @TypeOf(&commonExcpHandler);

const IrqStack = [irq_stack_size / @sizeOf(u64)]u64;

var except_handlers: [rsrvd_vec_num]ExceptionIsrFn = undefined;

var idts: []DescTable = &.{};
var tss_pool: []TaskStateSegment = &.{};
var irq_stacks: []IrqStack = &.{};

pub fn preinit() void {
    const cpus_num = smp.getNum();
    const idts_pages = std.math.divCeil(
        u32, @as(u32, cpus_num) * @sizeOf(DescTable),
        vm.page_size
    ) catch unreachable;

    const tss_pages = std.math.divCeil(
        u32, cpus_num * @sizeOf(TaskStateSegment),
        vm.page_size
    ) catch unreachable;

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

pub inline fn setupCpu(cpu_idx: u8) void {
    useIdt(&idts[cpu_idx]);
    regs.setTss(gdt.getTssOffset(cpu_idx));
}

pub fn setupIsr(vec: intr.Vector, isr: IsrFn, stack: enum{kernel,user}, type_attr: u8) void {
    idts[vec.cpu][vec.vec] = Descriptor.init(
        @intFromPtr(isr),
        switch (stack) {
            .kernel => 1,
            .user => 2
        },
        type_attr
    );
}

pub inline fn useIdt(idt: *DescTable) void {
    const idtr: regs.IDTR = .{ .base = @intFromPtr(idt), .limit = @sizeOf(DescTable) - 1 };

    regs.setIdtr(idtr);
}

pub inline fn enableForCpu() void {
    @setRuntimeSafety(false);
    asm volatile("sti");
}

pub inline fn disableForCpu() void {
    @setRuntimeSafety(false);
    asm volatile("cli");
}

fn initIdts() !void {
    for (idts[1..idts.len]) |*idt| {
        for (0..rsrvd_vec_num) |vec| {
            idt[vec] = idts[0][vec];
        }

        @memset(idt[rsrvd_vec_num..max_vectors], std.mem.zeroes(Descriptor));
    }
}

fn initTss() !void {
    const cpus_num = smp.getNum();
    const stacks_pages = std.math.divCeil(
        u32,
        @as(u32, cpus_num) * irq_stack_size,
        vm.page_size
    ) catch unreachable;
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
    inline for (0..rsrvd_vec_num) |vec| {
        const Handler = ExcpHandler(vec);

        idts[0][vec] = Descriptor.init(
            @intFromPtr(&Handler.isr),
            0, trap_gate_flags
        );
        except_handlers[vec] = &commonExcpHandler;
    }
}

export fn excpHandlerCaller() callconv(.Naked) noreturn {
    @setRuntimeSafety(false);
    regs.saveState();

    asm volatile(
        \\mov %rsp,%rdi
        \\mov -0x8(%rsp),%rdx
        \\mov -0x10(%rsp),%rsi
    );

    if (comptime (@sizeOf(regs.IntrState) % 0x10) == 0) {
        asm volatile("sub $0x8,%rsp");
    }

    asm volatile(
        \\mov %[table],%rcx
        \\jmp *(%rcx,%rsi,8)
        :
        : [table] "i" (&except_handlers),
    );
}

fn ExcpHandler(vec: comptime_int) type {
    return struct {
        fn hasErrorCode() bool {
            const vec_with_errors = comptime [_]comptime_int{
                8, 10, 11, 12, 13, 14, 17, 21
            };

            for (vec_with_errors) |entry| {
                if (vec == entry) return true;
            }

            return false;
        }

        pub fn isr() callconv(.Naked) noreturn {
            const size = comptime @sizeOf(regs.CalleeRegs) + @sizeOf(regs.ScratchRegs) + @sizeOf(u64);

            if (comptime hasErrorCode()) {
                asm volatile(std.fmt.comptimePrint("pop -{}(%%rsp)", .{size}));
            } else {
                asm volatile(std.fmt.comptimePrint("movq $0,-{}(%%rsp)", .{size}));
            }

            asm volatile(std.fmt.comptimePrint(
                    \\movq %[vec],-{}(%%rsp)
                    \\jmp excpHandlerCaller
                , .{size + @sizeOf(u64)})
                :
                : [vec] "i" (vec),
            );
        }
    };
}

fn commonExcpHandler(state: *regs.IntrState, vec: u32, error_code: u32) callconv(.C) noreturn {
    panic.exception(
        state.intr.rip,
        state.intr.rsp,
        state.callee.rbp,
        \\#{} error: 0x{x}
        \\
        \\Regs:
        \\rax: 0x{x:.>16}, rcx: 0x{x:.>16}, rdx: 0x{x:.>16}, rbx: 0x{x:.>16}
        \\rip: 0x{x:.>16}, rsp: 0x{x:.>16}, rbp: 0x{x:.>16}, rflags: 0x{x:.>8}
        \\r8:  0x{x:.>16}, r9:  0x{x:.>16}, r10: 0x{x:.>16}, r11: 0x{x:.>16}
        \\r12: 0x{x:.>16}, r13: 0x{x:.>16}, r14: 0x{x:.>16}, r15: 0x{x:.>16}
        \\cr2: 0x{x:.>16}, cr3: 0x{x:.>16}, cr4: 0x{x:.>16}
        \\
        \\cs: 0x{x}, ss: 0x{x}, lapic id: {}
        , .{
            vec, error_code,
            state.scratch.rax, state.scratch.rcx, state.scratch.rdx, state.callee.rbx,
            state.intr.rip, state.intr.rsp, state.callee.rbp, state.intr.rflags,
            state.scratch.r8, state.scratch.r9, state.scratch.r10, state.scratch.r11,
            state.callee.r12, state.callee.r13, state.callee.r14, state.callee.r15,
            regs.getCr2(), regs.getCr3(), regs.getCr4(),
            state.intr.cs, state.intr.ss, apic.lapic.getId(),
        }
    );

    utils.halt();
}

pub fn lowLevelIntrHandler(
    idx: u8,
    comptime handler: []const u8
) *const fn() callconv(.Naked) noreturn {
    const Anon = struct {
        fn getIsr(comptime n: comptime_int) *const fn() callconv(.Naked) noreturn {
            return struct {
                fn isr() callconv(.Naked) noreturn {
                    asm volatile(std.fmt.comptimePrint(
                        \\push ${}
                        \\jmp {s}
                        , .{n, handler}
                    ));

                    comptime {
                        @export(&isr, .{
                            .name = std.fmt.comptimePrint(
                                "isr{x}_{x}",
                                .{n, std.hash.crc.Crc16Arc.hash(handler)}
                            )
                        });
                    }
                }
            }.isr;
        }

        pub const table = blk: {
            var result: []const *const fn() callconv(.Naked) noreturn = &.{};

            for (0..intr.max_intr) |i| {
                result = result ++ .{ getIsr(i) };
            }

            break :blk result;
        };
    };

    return Anon.table[idx];
}

fn CommonIntrHandler(comptime handlerCaller: []const u8) type {
    return struct {
        pub fn handler() callconv(.Naked) noreturn {
            regs.saveScratchRegs();

            // Load index to arg0 
            asm volatile(std.fmt.comptimePrint(
                \\mov {}(%rsp),%rdi
                , .{@sizeOf(regs.ScratchRegs)})
            );

            const is_stack_aligned = comptime (@sizeOf(regs.LowLevelIntrState) % 0x10) == 0;
            if (comptime !is_stack_aligned) regs.stackAlloc(1);

            // Call `handlerCaller`
            asm volatile(std.fmt.comptimePrint(
                "call {s}", .{handlerCaller}
            ));

            if (!is_stack_aligned) regs.stackFree(1);
            regs.restoreScratchRegs();

            // Pop `pin` number from stack;
            regs.stackFree(1);
            iret();
        }
    };
}

/// Needed just for switch from naked calling convention to C.
export fn irqHandlerCaller(pin: u8) callconv(.C) void {
    intr.handleIrq(pin);
}

/// Needed just for switch from naked calling convention to C.
export fn msiHandlerCaller(idx: u8) callconv(.C) void {
    intr.handleMsi(idx);
}

comptime{
    @export(&CommonIntrHandler("irqHandlerCaller").handler, .{ .name = "commonIrqHandler" });
    @export(&CommonIntrHandler("msiHandlerCaller").handler, .{ .name = "commonMsiHandler" });
}

pub inline fn iret() void {
    asm volatile("iretq");
}
