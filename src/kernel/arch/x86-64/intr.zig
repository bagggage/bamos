const std = @import("std");

const apic = @import("intr/apic.zig");
const arch = @import("arch.zig");
const boot = @import("../../boot.zig");
const intr = @import("../../dev/intr.zig");
const log = @import("../../log.zig");
const panic = @import("../../panic.zig");
const pic = @import("intr/pic.zig");
const regs = @import("regs.zig");
const utils = @import("../../utils.zig");
const vm = @import("../../vm.zig");

pub const table_len = max_vectors;

pub const trap_gate_flags = 0x8F;
pub const intr_gate_flags = 0x8E;

pub const kernel_stack = 0;
pub const user_stack = 2;

pub const max_vectors = 256;
pub const reserved_vectors = 32;
pub const avail_vectors = max_vectors - reserved_vectors;

pub const irq_base_vec = reserved_vectors;

const rsrvd_vec_num = 32;

pub const Descriptor = packed struct {
    offset_1: u16 = 0,
    selector: u16 = 0,
    ist: u8 = 0,
    type_attr: u8 = 0,
    offset_2: u48 = 0,
    rsrvd: u32 = 0,

    pub fn init(isr: u64, stack: u8, attr: u8) @This() {
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

const IsrFn = *const fn() callconv(.Naked) noreturn;
const ExceptionIsrFn = @TypeOf(&commonExcpHandler);

var except_handlers: [rsrvd_vec_num]ExceptionIsrFn = undefined;

var idts: []DescTable = &.{};

pub fn preinit() void {
    const cpus_num = boot.getCpusNum();
    const idts_pages = std.math.divCeil(u32, @as(u32, cpus_num) * @sizeOf(DescTable), vm.page_size) catch unreachable;

    const base = boot.alloc(idts_pages) orelse @panic("No memory to allocate IDTs per each cpu");

    idts.ptr = @ptrFromInt(vm.getVirtLma(base));
    idts.len = cpus_num;

    initExceptHandlers();
    useIdt(&idts[arch.getCpuIdx()]);
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

pub fn setupIsr(vec: intr.Vector, isr: IsrFn, stack: enum{kernel,user}, type_attr: u8) void {
    idts[vec.cpu.specific][vec.vec] = Descriptor.init(
        @intFromPtr(isr),
        switch (stack) {
            .kernel => 0,
            .user => 2
        },
        type_attr
    );
}

pub inline fn getIdtForCpu(cpu_idx: u16) *DescTable {
    return &idts[cpu_idx];
}

pub inline fn useIdt(idt: *DescTable) void {
    const idtr: regs.IDTR = .{ .base = @intFromPtr(idt), .limit = @sizeOf(DescTable) - 1 };

    regs.setIdtr(idtr);
}

fn initIdts() !void {
    for (idts[1..idts.len]) |*idt| {
        for (0..rsrvd_vec_num) |vec| {
            idt[vec] = idts[0][vec];
        }

        @memset(idt[rsrvd_vec_num..max_vectors], std.mem.zeroes(Descriptor));
    }
}

fn initExceptHandlers() void {
    inline for (0..rsrvd_vec_num) |vec| {
        const Handler = ExcpHandler(vec);

        idts[0][vec] = Descriptor.init(
            @intFromPtr(&Handler.isr),
            kernel_stack,
            trap_gate_flags
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
    log.excp(vec, error_code);
    log.warn(
        \\Regs:
        \\rax: 0x{x}, rcx: 0x{x}, rdx: 0x{x}, rbx: 0x{x}
        \\rip: 0x{x}, rsp: 0x{x}, rbp: 0x{x}, rflags: 0x{x}
        \\r8: 0x{x}, r9: 0x{x}, r10: 0x{x}, r11: 0x{x}
        \\r12: 0x{x}, r13: 0x{x}, r14: 0x{x}, r15: 0x{x}
        \\cr2: 0x{x}, cr3: 0x{x}, cr4: 0x{x}
    , .{
        state.scratch.rax, state.scratch.rcx, state.scratch.rdx, state.callee.rbx,
        state.intr.rip, state.intr.rsp, state.callee.rbp, state.intr.rflags,
        state.scratch.r8, state.scratch.r9, state.scratch.r10, state.scratch.r11,
        state.callee.r12, state.callee.r13, state.callee.r14, state.callee.r15,
        regs.getCr2(), regs.getCr3(), regs.getCr4()
    });

    var it = std.debug.StackIterator.init(state.intr.rip, state.callee.rbp);
    panic.trace(&it);

    utils.halt();
}

pub fn lowLevelIrqHandler(pin: u8) *const fn() callconv(.Naked) noreturn {
    const Anon = struct {
        fn getIsr(comptime idx: u8) *const fn() callconv(.Naked) noreturn {
            return &struct {
                pub fn isr() callconv(.Naked) noreturn {
                    asm volatile(std.fmt.comptimePrint(
                        \\push ${}
                        \\jmp commonIrqHandler
                        , .{idx}
                    ));
                }

                comptime {
                    @export(isr, .{ .name = std.fmt.comptimePrint("irq{x}_isr", .{idx}) });
                }
            }.isr;
        }

        pub const isr_table = blk: {
            var table: []const IsrFn = &.{};

            for (0..intr.max_irqs) |i| {
                table = table ++ .{ getIsr(i) };
            }

            break :blk table;
        };
    };

    return Anon.isr_table[pin];
}

/// Needed just for switch from naked calling convention to C.
export fn irqHandlerCaller(pin: u8) callconv(.C) void {
    intr.handleIrq(pin);
}

export fn commonIrqHandler() callconv(.Naked) noreturn {
    regs.saveScratchRegs();

    // Call `irqHandlerCaller` and pass `pin` number.
    asm volatile(std.fmt.comptimePrint(
        \\mov %rdi, -{}(%%rsp)
        \\call irqHandlerCaller
        , .{@sizeOf(regs.ScratchRegs)}
    ));

    regs.restoreScratchRegs();
    // Pop `pin` number from stack;
    regs.stackFree(1);

    iret();
}

inline fn iret() void {
    asm volatile("iret");
}
