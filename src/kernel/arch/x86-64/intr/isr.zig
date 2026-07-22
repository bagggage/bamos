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

pub fn makeIrqHandler(
    comptime name: []const u8,
    comptime call_name: []const u8,
    comptime arg: ?u32,
) Fn {
    const isr_name =
        if (arg) |value|
            std.fmt.comptimePrint("isr_"++name++"_{x}", .{value})
        else
            "isr_"++name;

    return opaque {
        fn isr() callconv(.naked) noreturn {
            if (comptime arg) |value| {
                asm volatile(
                    "call interruptEntry\n" ++
                    "mov %[arg], %edi\n" ++
                    "call " ++ call_name ++ "\n" ++
                    "jmp interruptExit\n"
                    :: [arg] "i" (value)
                );
            } else {
                asm volatile(
                    "call interruptEntry\n" ++
                    "call " ++ call_name ++ "\n" ++
                    "jmp interruptExit\n"
                );
            }

            comptime {
                @export(&isr, .{ .name = isr_name });
            }
        }
    }.isr;
}

pub fn stubIrqHandler(comptime vec: u8) Fn {
    return makeIrqHandler("stub", "handleStubIrq", vec);
}

pub fn irqHandler(idx: u8, comptime kind: enum { irq, msi }, comptime max_num: comptime_int) Fn {
    @setEvalBranchQuota(28000);

    const name = comptime @tagName(kind);
    const call_name = if (comptime kind == .irq) "handleIrq" else "handleMsi";

    const table: [max_num]Fn = comptime blk: {
        var result: [max_num]Fn = undefined;
        for (0..max_num) |i| result[i] = makeIrqHandler(name, call_name, i);

        break :blk result;
    };

    return table[idx];
}
