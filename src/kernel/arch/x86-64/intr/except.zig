//! # CPU Exceptions handlers

// Copyright (C) 2025-2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const apic = @import("apic.zig");
const arch = @import("../arch.zig");
const gdt = @import("../gdt.zig");
const log = std.log.scoped(.@"intr.except");
const panic = @import("../../../panic.zig");
const regs = @import("../regs.zig");
const sched = @import("../../../sched.zig");
const smp = @import("../../../smp.zig");
const vm = @import("../../../vm.zig");

pub const Fn = *const fn (frame: *Frame, state: *regs.State) callconv(.c) void;

pub const Vector = enum(u8) {
    divide_by_zero              = 0,
    debug                       = 1,
    non_maskable_interrupt      = 2,
    breakpoint                  = 3,
    overflow                    = 4,
    bound_range                 = 5,
    invalid_opcode              = 6,
    device_not_available        = 7,
    double_fault                = 8,
    coprocessor_segment_overrun = 9,
    invalid_tss                 = 10,
    segment_not_present         = 11,
    stack                       = 12,
    general_protection          = 13,
    page_fault                  = 14,

    floating_point              = 16,
    alignment_check             = 17,
    machine_check               = 18,
    simd_floating_point         = 19,

    control_protection          = 21,

    hypervisor_injection        = 28,
    vmm_communication           = 29,
    security                    = 30,
    _,

    pub inline fn toInt(self: Vector) u5 {
        return @intFromEnum(self);
    }
    
    pub inline fn fromInt(int: u8) Vector {
        return @enumFromInt(int);
    }

    pub inline fn name(self: Vector) []const u8 {
        return @tagName(self);
    }
};

const Frame = extern struct {
    vector: u8, // <- stack points to this
    error_code: u64,

    source: regs.InterruptFrame,

    inline fn fromUserspace(self: *const Frame) bool {
        const cs: u16 = @truncate(self.source.cs);
        return @as(gdt.SegmentSelector, @bitCast(cs)).rpl == .userspace;
    }
};

fn handlerCaller() callconv(.naked) noreturn {
    @setRuntimeSafety(false);
    // Check if interrupt received from userspace (CS == 0b11).
    asm volatile (std.fmt.comptimePrint(
        \\ testb $3, {}(%rsp)
        \\ jz 0f
        , .{@offsetOf(Frame, "source") + @offsetOf(regs.InterruptFrame, "cs")}
    ));

    // Entry from userspace.
    regs.swapgs();

    // Entry from kernel.
    asm volatile ("0:");
    arch.intr.enableForCpu();
    regs.saveState();

    // Put interrupt stack pointer into %rdi and state into %rsi.
    asm volatile (std.fmt.comptimePrint(
        \\ lea {}(%rsp), %rdi
        \\ mov %rsp, %rsi
        , .{@sizeOf(regs.State)}
    ));

    regs.alignStackUnsafe();
    regs.saveFpuRegs();

    // Load table pointer into %rax and vector into %rdx,
    // then do call: table[vec](%rdi, %rsi).
    asm volatile (
        \\ mov (%rdi), %rdx
        \\ mov %[table], %rax
        \\ call *(%rax,%rdx,8)
        :
        : [table] "i" (&arch.intr.except_handlers),
    );

    handlerExit();
}

inline fn handlerExit() noreturn {
    regs.restoreFpuRegs();
    regs.restoreStackUnsafe();
    regs.restoreState();
    // Free `err_code` and `vector`.
    regs.stackFree(2);

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

pub fn handler(vec: comptime_int) type {
    if (comptime vec == 0) @export(&handlerCaller, .{ .name = "exceptionHandlerCaller" });

    return struct {
        fn hasErrorCode() bool {
            return switch (vec) {
                8, 10, 11, 12, 13, 14, 17, 21 => true,
                else => false,
            };
        }

        pub fn isr() callconv(.naked) noreturn {
            arch.intr.disableForCpu();

            // Put error code on the stack.
            if (comptime !hasErrorCode()) asm volatile ("push $0");

            asm volatile (
                \\ push %[vec]
                \\ jmp exceptionHandlerCaller
                :
                : [vec] "i" (vec),
            );
        }
    };
}

pub fn commonHandler(frame: *Frame, state: *regs.State) callconv(.c) void {
    arch.intr.disableForCpu();

    traceException(frame, state);
    defer arch.halt();

    if (frame.vector != Vector.double_fault.toInt()) {
        @branchHint(.likely);

        arch.intr.enableForCpu();
        if (sched.isInitialized()) sched.pause();
    }
}

pub fn pageFaultHandler(frame: *Frame, state: *regs.State) callconv(.c) void {
    const error_code = frame.error_code;
    const cause: vm.FaultCause =
        if ((error_code & 0b10010) == 0) .read
        else if ((error_code & 0b00010) != 0) .write
        else .exec;
    const userspace = (error_code & 0b0100) != 0;
    const address = regs.getCr2();

    log.debug("page fault: 0x{x:.>16} - {t}: userspace: {}", .{address, cause, userspace});
    log.debug("\trip: 0x{x:.>16}, - rsp: 0x{x:.>16}", .{frame.source.rip, frame.source.rsp});

    const success = vm.pageFaultHandler(address, cause, userspace);
    if (success) {
        @branchHint(.likely);
        return;
    }

    commonHandler(frame, state);
}

fn traceException(frame: *Frame, state: *regs.State) callconv(.c) void {
    const source = &frame.source;
    const context_name = if ((frame.source.cs & 0b11) != 0) "userspace" else "kernel";
    const except_name = Vector.fromInt(frame.vector).name();

    panic.exception(source.rip, source.rsp, state.callee.rbp,
        \\#{} error: 0x{x} ({s} - {s})
        \\
        \\Regs:
        \\rax: 0x{x:.>16}, rbx: 0x{x:.>16}, rcx: 0x{x:.>16}, rdx: 0x{x:.>16}
        \\rsi: 0x{x:.>16}, rdi: 0x{x:.>16}, rbp: 0x{x:.>16}, rsp: 0x{x:.>16}
        \\r8:  0x{x:.>16}, r9:  0x{x:.>16}, r10: 0x{x:.>16}, r11: 0x{x:.>16}
        \\r12: 0x{x:.>16}, r13: 0x{x:.>16}, r14: 0x{x:.>16}, r15: 0x{x:.>16}
        \\rip: 0x{x:.>16}, rflags: 0x{x:.>13},
        \\cr2: 0x{x:.>16}, cr3: 0x{x:.>16}, cr4: 0x{x:.>16}
        \\
        \\cs: 0x{x}, ss: 0x{x}, lapic id: {}
    , .{
        frame.vector,      frame.error_code, except_name, context_name,
        state.scratch.rax, state.callee.rbx,
        state.scratch.rcx, state.scratch.rdx,
        state.scratch.rsi, state.scratch.rdi,
        state.callee.rbp,  source.rsp,
        state.scratch.r8,  state.scratch.r9,
        state.scratch.r10, state.scratch.r11,
        state.callee.r12,  state.callee.r13,
        state.callee.r14,  state.callee.r15,
        source.rip,        source.rflags,
        regs.getCr2(),     regs.getCr3(), regs.getCr4(),
        source.cs,         source.ss,
        if (apic.lapic.isInitialized()) apic.lapic.getId() else 9999,
    });
}
