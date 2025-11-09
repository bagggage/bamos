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

pub const Fn = *const fn () callconv(.naked) noreturn;
pub const ExceptionFn = @TypeOf(&commonExcpHandler);

pub const page_fault_vec = 14;
pub const double_fault_vec = 8;

const isrEntryName = "isr.entry";
const isrErrorEntryName = "isr.entryError";
const isrExitName = "isr.exit";

fn IsrHelper(comptime has_error_code: bool) type {
    return opaque {
        /// Enter into interrupt context.
        pub fn entry() callconv(.naked) void {
            // Check if interrupt received from userspace (CS == 0b11).
            // `cs` offset: 8-bytes.
            if (comptime has_error_code) {
                asm volatile ("testb $3, 0x18(%rsp)");
            } else {
                asm volatile ("testb $3, 0x10(%rsp)");
            }

            // Jump to `entryFromKernel`
            asm volatile ("jz 1f");

            // Entry from userspace.
            {
                regs.swapgs();
                regs.swapStackToKernel();

                regs.saveScratchRegs();

                // Put user stack pointer into `rdi`
                // Do return using `jmp`.
                asm volatile (std.fmt.comptimePrint(
                        \\ mov %gs:{}, %rdi
                        \\ jmp *(%rdi)
                    , .{@offsetOf(smp.LocalData, "current_sp")}));
            }

            // Entry from kernel.
            {
                asm volatile ("1:");

                regs.saveScratchRegs();
                const frame_offset = comptime @sizeOf(regs.ScratchRegs);

                // Align stack.
                regs.stackAlloc(1);

                // Do return using `jmp` to return address.
                asm volatile (std.fmt.comptimePrint(
                        \\ jmp *{}(%rsp)
                    , .{frame_offset + @sizeOf(u64)}));
            }
        }

        pub fn exit() callconv(.naked) void {
            regs.stackFree(1);
            regs.restoreScratchRegs();

            asm volatile (
                \\ test %rsp, %rsp
                \\ js 1f
            );

            // Exit from userspace.
            regs.swapStackToUser();
            regs.swapgs();

            arch.intr.iret();

            // Exit from kernel.
            asm volatile ("1:");

            regs.stackFree(1);
            arch.intr.iret();
        }
    };
}

const excp_state_size = @sizeOf(regs.State);

const excp_err_offset = excp_state_size + @sizeOf(u64);
const excp_vec_offset = excp_state_size + @sizeOf(u64) * 2;

export fn excpHandlerCaller() callconv(.naked) noreturn {
    @setRuntimeSafety(false);
    // Check if interrupt received from userspace (CS == 0b11).
    // `cs` offset: 8-bytes.
    asm volatile ("testb $3, 0x8(%rsp)");

    // Jump to `entryFromKernel`
    asm volatile ("jz 0f");

    // Entry from userspace.
    {
        defer arch.intr.iret();

        regs.swapgs();
        regs.swapStackToKernel();
        defer regs.swapgs();
        defer regs.swapStackToUser();

        regs.saveState();
        defer regs.restoreState();

        // Put user stack pointer into `rdi` and
        // move arguments from old stack.
        asm volatile (std.fmt.comptimePrint(
                \\ mov %gs:{}, %rdi
                \\ mov %rsp, %rsi
                \\ mov -{}(%rdi), %rdx
                \\ mov -{}(%rdi), %rcx
            , .{ @offsetOf(smp.LocalData, "current_sp"), excp_vec_offset, excp_err_offset }));

        callExcpHandler(@sizeOf(regs.State));
    }

    // Entry from kernel.
    {
        asm volatile ("0:");
        defer arch.intr.iret();

        regs.saveState();
        defer regs.restoreState();

        // Move error code(-0x8) into %rcx and
        // exception vector(-0x10) into %rdx.
        asm volatile (std.fmt.comptimePrint(
                \\ lea {}(%rsp), %rdi
                \\ mov %rsp, %rsi
                \\ mov -0x8(%rsp), %rcx
                \\ mov -0x10(%rsp), %rdx
            , .{excp_state_size}));

        callExcpHandler(excp_state_size + @sizeOf(regs.InterruptFrame));
    }
}

inline fn callExcpHandler(comptime frame_size: comptime_int) void {
    const need_align = comptime (frame_size % 0x10 != 0);

    // Align stack.
    if (comptime need_align) regs.stackAlloc(1);
    defer if (comptime need_align) regs.stackFree(1);

    // Load handler table pointer to %rax
    // and do call: table[vec](%rdi, %rsi, %rdx, %rcx).
    asm volatile (
        \\ mov %[table], %rax
        \\ call *(%rax,%rdx,8)
        :
        : [table] "i" (&arch.intr.except_handlers),
    );
}

pub fn ExcpHandler(vec: comptime_int) type {
    return struct {
        fn hasErrorCode() bool {
            return switch (vec) {
                8, 10, 11, 12, 13, 14, 17, 21 => true,
                else => false,
            };
        }

        pub fn isr() callconv(.naked) noreturn {
            // Put error code on the stack.
            const instr = if (comptime hasErrorCode()) "pop -{}(%%rsp)" else "movq $0,-{}(%%rsp)";
            asm volatile (std.fmt.comptimePrint(instr, .{excp_err_offset}));

            asm volatile (std.fmt.comptimePrint(
                    \\movq %[vec],-{}(%%rsp)
                    \\jmp excpHandlerCaller
                , .{excp_vec_offset})
                :
                : [vec] "i" (vec),
            );
        }
    };
}

pub fn commonExcpHandler(frame: *regs.InterruptFrame, state: *regs.State, vec: u32, error_code: u32) callconv(.c) void {
    panic.exception(frame.rip, frame.rsp, state.callee.rbp,
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
        vec,               error_code,
        state.scratch.rax, state.scratch.rcx,
        state.scratch.rdx, state.callee.rbx,
        frame.rip,         frame.rsp,
        state.callee.rbp,  frame.rflags,
        state.scratch.r8,  state.scratch.r9,
        state.scratch.r10, state.scratch.r11,
        state.callee.r12,  state.callee.r13,
        state.callee.r14,  state.callee.r15,
        regs.getCr2(),     regs.getCr3(),
        regs.getCr4(),     frame.cs,
        frame.ss,          if (apic.lapic.isInitialized()) apic.lapic.getId() else 9999,
    });

    utils.halt();
}

pub fn pageFaultHandler(frame: *regs.InterruptFrame, state: *regs.State, vec: u32, error_code: u32) callconv(.c) void {
    const addr = regs.getCr2();
    const cause: vm.FaultCause =
        if ((error_code & 0b10010) == 0) .read
        else if ((error_code & 0b00010) != 0) .write
        else .exec;
    const userspace = (error_code & 0b0100) != 0;

    const success = vm.pageFaultHandler(addr, cause, userspace);
    if (success) {
        @branchHint(.likely);
        return;
    }

    commonExcpHandler(frame, state, vec, error_code);
}

pub fn irqHandler(idx: u8, comptime kind: enum { irq, msi }, comptime max_num: comptime_int) *const fn () callconv(.naked) noreturn {
    const Static = opaque {
        fn getIsr(comptime n: comptime_int) *const fn () callconv(.naked) noreturn {
            return opaque {
                fn isr() callconv(.naked) noreturn {
                    switch (comptime kind) {
                        .irq => asm volatile (
                            \\ call isr.entry
                            \\ mov %[idx], %edi
                            \\ call handleIrq
                            \\ jmp isr.exit
                            :
                            : [idx] "i" (n),
                        ),
                        .msi => asm volatile (
                            \\ call isr.entry
                            \\ mov %[idx], %edi
                            \\ call handleMsi
                            \\ jmp isr.exit
                            :
                            : [idx] "i" (n),
                        ),
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
            var result: []const *const fn () callconv(.naked) noreturn = &.{};

            for (0..max_num) |i| {
                result = result ++ .{getIsr(i)};
            }

            break :blk result;
        };
    };

    return Static.table[idx];
}

comptime {
    @export(&IsrHelper(false).entry, .{ .name = isrEntryName });
    @export(&IsrHelper(true).entry, .{ .name = isrErrorEntryName });
    @export(&IsrHelper(false).exit, .{ .name = isrExitName });
}
