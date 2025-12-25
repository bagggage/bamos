//! # Interrupt Service Routine functions

// Copyright (C) 2025-2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const arch = @import("../arch.zig");
const log = std.log.scoped(.isr);
const logger = @import("../../../logger.zig");
const regs = @import("../regs.zig");
const smp = @import("../../../smp.zig");

pub const Fn = *const fn () callconv(.naked) noreturn;

/// Enter into interrupt context.
export fn interruptEntry() callconv(.naked) void {
    // Check if interrupt received from userspace (CS == 0b11).
    // Jump to `entryFromKernel`
    asm volatile (std.fmt.comptimePrint(
        \\ testb $3, {}(%rsp)
        \\ jz 1f
        , .{@offsetOf(regs.InterruptFrame, "cs") + @sizeOf(u64)}
    ));

    // Entry from userspace.
    regs.swapgs();

    // Entry from kernel.
    asm volatile ("1:");
    regs.saveScratchRegs();
    regs.alignStackSafe();
    regs.saveFpuRegs();

    // Do return using `jmp` to return address.
    asm volatile (std.fmt.comptimePrint(
        \\ jmp *{}(%rbp)
        , .{@sizeOf(regs.ScratchRegs) + @sizeOf(u64)}
    ));
}

export fn interruptExit() callconv(.naked) noreturn {
    regs.restoreFpuRegs();
    regs.restoreStackSafe();
    regs.restoreScratchRegs();
    // Free return address, that was placed on a stack
    // by `call` instruction when calling `interruptEntry`.
    regs.stackFree(1);

    // Check if interrupt is from userspace.
    asm volatile (std.fmt.comptimePrint(
        \\ testb $3, {}(%rsp)
        \\ jz 1f
        , .{@offsetOf(regs.InterruptFrame, "cs")}
    ));

    // Exit from userspace.
    arch.intr.disableForCpu();
    regs.swapgs();

    // Exit from kernel.
    asm volatile ("1:");
    arch.intr.iret();
}

pub fn stubIrqHandler(comptime vec: u8) *const fn () callconv(.naked) noreturn {
    const Static = opaque {
        fn isr() callconv(.naked) noreturn {
            asm volatile (
                \\ call interruptEntry
                \\ mov %[vec], %edi
                \\ call handleStubIrq
                \\ jmp interruptExit
                :
                : [vec] "i" (vec),
            );

            comptime {
                @export(&isr, .{ .name = std.fmt.comptimePrint("isr{x}_stub", .{vec}) });
            }
        }
    };

    return &Static.isr;
}

pub fn irqHandler(idx: u8, comptime kind: enum { irq, msi }, comptime max_num: comptime_int) *const fn () callconv(.naked) noreturn {
    const Static = opaque {
        fn getIsr(comptime n: comptime_int) *const fn () callconv(.naked) noreturn {
            return opaque {
                fn isr() callconv(.naked) noreturn {
                    switch (comptime kind) {
                        .irq => asm volatile (
                            \\ call interruptEntry
                            \\ mov %[idx], %edi
                            \\ call handleIrq
                            \\ jmp interruptExit
                            :
                            : [idx] "i" (n),
                        ),
                        .msi => asm volatile (
                            \\ call interruptEntry
                            \\ mov %[idx], %edi
                            \\ call handleMsi
                            \\ jmp interruptExit
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
