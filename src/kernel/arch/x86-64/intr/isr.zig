//! # Interrupt Service Routine functions

// Copyright (C) 2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const arch = @import("../arch.zig");
const apic = @import("apic.zig");
const intr = @import("../../../dev/intr.zig");
const log = std.log.scoped(.isr);
const logger = @import("../../../logger.zig");
const panic = @import("../../../panic.zig");
const regs = @import("../regs.zig");
const smp = @import("../../../smp.zig");
const utils = @import("../../../utils.zig");
const vm = @import("../../../vm.zig");

pub const Fn = *const fn() callconv(.Naked) noreturn;
pub const ExceptionFn = @TypeOf(&commonExcpHandler);

pub const page_fault_vec = 14;
pub const double_fault_vec = 8;

const isrEntryName = "isr.entry";
const isrErrorEntryName = "isr.entryError";
const isrExitName = "isr.exit";

fn IsrHelper(comptime has_error_code: bool) type { return opaque {
    /// Enter into interrupt context.
    pub fn entry() callconv(.naked) void {
        // Check if interrupt received from userspace (CS == 0b11).
        // `cs` offset: 8-bytes.
        if (comptime has_error_code) {
            asm volatile("testb $3, 0x18(%rsp)");
        } else {
            asm volatile("testb $3, 0x10(%rsp)");
        }

        // Jump to `entryFromKernel`
        asm volatile("jz 1f");

        // Entry from userspace.
        {
            regs.swapgs();
            regs.swapStackToKernel();

            regs.saveScratchRegs();

            // Put user stack pointer into `rdi` 
            // Do return using `jmp`.
            asm volatile(std.fmt.comptimePrint(
                \\ mov %gs:{}, %rdi
                \\ jmp *(%rdi)
                , .{@offsetOf(smp.LocalData, "current_sp")}
            ));
        }

        // Entry from kernel.
        {
            asm volatile("1:");
            
            regs.saveScratchRegs();
            const frame_offset = comptime @sizeOf(regs.ScratchRegs);

            // Align stack.
            regs.stackAlloc(1);

            // Do return using `jmp` to return address.
            asm volatile(std.fmt.comptimePrint(
                \\ jmp *{}(%rsp)
                , .{frame_offset + @sizeOf(u64)}
            ));
        }
    }

    pub fn exit() callconv(.naked) void {
        regs.stackFree(1);
        regs.restoreScratchRegs();

        asm volatile(
            \\ test %rsp, %rsp
            \\ js 1f
        );

        // Exit from userspace.
        regs.swapStackToUser();
        regs.swapgs();

        arch.intr.iret();

        // Exit from kernel.
        asm volatile("1:");

        regs.stackFree(1);
        arch.intr.iret();
    }
};
}

export fn excpHandlerCaller() callconv(.Naked) noreturn {
    @setRuntimeSafety(false);
    regs.saveState();

    asm volatile(
        \\mov %rsp,%rdi
        \\mov -0x8(%rsp),%rdx
        \\mov -0x10(%rsp),%rsi
    );

    if (comptime (@sizeOf(regs.IntrState) % 0x10) == 0) asm volatile("sub $0x8,%rsp");

    asm volatile(
        \\mov %[table],%rcx
        \\call *(%rcx,%rsi,8)
        :
        : [table] "i" (&arch.intr.except_handlers),
    );

    if (comptime (@sizeOf(regs.IntrState) % 0x10) == 0) asm volatile("add $0x8,%rsp");

    regs.restoreState();
}

pub fn ExcpHandler(vec: comptime_int) type {
    return struct {
        fn hasErrorCode() bool {
            return switch (vec) {
                8, 10, 11, 12, 13, 14, 17, 21 => true,
                else => false 
            };
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

pub fn commonExcpHandler(state: *regs.IntrState, vec: u32, error_code: u32) callconv(.C) void {
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

pub fn pageFaultHandler(state: *regs.IntrState, vec: u32, error_code: u32) callconv(.C) void {
    const addr = regs.getCr2();
    const cause: vm.FaultCause =
        if ((error_code & 0b10010) == 0) .read
        else if ((error_code & 0b00010) != 0) .write
        else .exec;
    const userspace = (error_code & 0b0100) != 0;

    const success = vm.pageFaultHandler(addr, cause, userspace);
    if (success) { @branchHint(.likely); return; }

    commonExcpHandler(state, vec, error_code);
}

pub fn irqHandler(
    idx: u8,
    comptime kind: enum{irq, msi},
    comptime max_num: comptime_int
) *const fn() callconv(.Naked) noreturn {
    const Static = opaque {
        fn getIsr(comptime n: comptime_int) *const fn() callconv(.Naked) noreturn {
            return opaque {
                fn isr() callconv(.Naked) noreturn {
                    switch (comptime kind) {
                        .irq => asm volatile(
                            \\ call isr.entry
                            \\ mov %[idx], %edi
                            \\ call handleIrq
                            \\ jmp isr.exit
                            :: [idx] "i" (n)
                        ),
                        .msi => asm volatile(
                            \\ call isr.entry
                            \\ mov %[idx], %edi
                            \\ call handleMsi
                            \\ jmp isr.exit
                            :: [idx] "i" (n)
                        )
                    }
                }

                comptime {
                    @export(&isr, .{
                        .name = std.fmt.comptimePrint(
                            "isr{x}_{s}",
                            .{n, @tagName(kind)}
                        )
                    });
                }
            }.isr;
        }

        pub const table = blk: {
            var result: []const *const fn() callconv(.Naked) noreturn = &.{};

            for (0..max_num) |i| {
                result = result ++ .{ getIsr(i) };
            }

            break :blk result;
        };
    };

    return Static.table[idx];
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
            arch.intr.iret();
        }
    };
}

comptime{
    //@export(&CommonIntrHandler("handleIrq").handler, .{ .name = "commonIrqHandler" });
    //@export(&CommonIntrHandler("handleMsi").handler, .{ .name = "commonMsiHandler" });

    @export(&IsrHelper(false).entry, .{ .name = isrEntryName });
    @export(&IsrHelper(true).entry, .{ .name = isrErrorEntryName });
    @export(&IsrHelper(false).exit, .{ .name = isrExitName });
}
