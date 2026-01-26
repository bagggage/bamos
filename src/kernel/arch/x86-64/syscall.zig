//! # Syscall Handler

// Copyright (C) 2025-2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const arch = @import("arch.zig");
const gdt = @import("gdt.zig");
const lib = @import("../../lib.zig");
const log = std.log.scoped(.@"arch.x86-64.syscall");
const regs = @import("regs.zig");
const sched = @import("../../sched.zig");
const smp = @import("../../smp.zig");
const sys = @import("../../sys.zig");
const vm = @import("../../vm.zig");

pub const Context = extern struct {
    rsp: usize,
    rip: usize,
    rflags: usize,

    pub inline fn setInstrPtr(self: *Context, value: usize) void {
        self.rip = value;
    }

    pub inline fn getInstrPtr(self: *const Context) usize {
        return self.rip;
    }

    pub inline fn setStackPtr(self: *Context, value: usize) void {
        std.debug.assert(std.mem.isAligned(value, @alignOf(usize)));
        self.rsp = value;
    }

    pub inline fn getStackPtr(self: *const Context) usize {
        return self.rsp;
    }

    inline fn save() void {
        asm volatile (
            \\ push %r11
            \\ push %r10
            \\ push %r9
            \\ push %r8
            \\ push %rcx
            \\ push %rdx
            \\ push %rsi
            \\ push %rdi
            \\
            \\ mov %r10, %rcx
        );
    }

    inline fn restore() void {
        asm volatile (
            \\ pop %rdi
            \\ pop %rsi
            \\ pop %rdx
            \\ pop %rcx
            \\ pop %r8
            \\ pop %r9
            \\ pop %r10
            \\ pop %r11
        );
    }
};

/// Mask IE (interrupts enable) flag
const rflags_mask = 1 << @bitOffsetOf(regs.Flags, "intr_enable");

pub fn init() void {
    comptime {
        std.debug.assert(gdt.kernel_ss_sel.index == gdt.kernel_cs_sel.index + 1);
        std.debug.assert(gdt.user_cs_sel.index == gdt.user_ss_sel.index + 1);
    }

    const star: regs.STAR = .{
        .eip = 0,
        .kernel_segment_sel = @bitCast(gdt.kernel_cs_sel),
        .user_segment_sel = @as(u16, @bitCast(gdt.user_ss_sel)) - 8
    };

    regs.setMsr(regs.MSR_STAR, @bitCast(star));
    regs.setMsr(regs.MSR_SFMASK, rflags_mask);
}

pub fn setupTaskAbi(task: *sched.Task, abi: sys.call.Abi) void {
    const local = smp.getLocalData();
    local.arch_specific.tss.rsps[0] = lib.misc.alignDown(usize, task.getKernelStackTop(), 16);

    const syscall_handler: sys.call.Handler = switch (abi) {
        .linux_sysv => linuxHandler
    };

    regs.setMsr(regs.MSR_LSTAR, @intFromPtr(syscall_handler));
}

pub fn startProcess(proc: *sys.Process, run_ctx: sys.exe.RunContext) void {
    const task = proc.getMainTask().?;
    const ctx_regs = task.context.stack_ptr.asCtxRegs();

    ctx_regs.callee.r12 = run_ctx.entry_ptr;
    ctx_regs.callee.r13 = run_ctx.stack_ptr;
    task.context.setInstrPtr(@intFromPtr(&linuxRunProcess));
}

export fn linuxRunProcess() noreturn {
    const entry_ptr = asm volatile ("": [_] "={r12}" (-> usize));
    const stack_ptr = asm volatile ("": [_] "={r13}" (-> usize));

    const local = smp.getLocalData();
    const task = local.scheduler.current_task.?;

    const rflags: regs.Flags = .{
        .cpuid = true,
        .intr_enable = true,
    };

    arch.intr.disableForCpu();
    local.arch_specific.tss.rsps[0] = lib.misc.alignDown(usize, task.getKernelStackTop(), 16); 

    asm volatile (
        \\ mov %[sp], %rsp
        \\
        \\ xor %rax, %rax
        \\ xor %rdx, %rdx
        \\ xor %rbx, %rbx
        \\ xor %rsi, %rsi
        \\ xor %rdi, %rdi
        \\ xor %rbp, %rbp
        \\ xor %r8, %r8
        \\ xor %r9, %r9
        \\ xor %r10, %r10
        \\ xor %r12, %r12
        \\ xor %r13, %r13
        \\ xor %r14, %r14
        \\ xor %r15, %r15
        \\
        \\ swapgs
        \\ sysretq
        :
        : [sp] "r" (stack_ptr),
          [ip] "{rcx}" (entry_ptr),
          [rflags] "{r11}" (rflags)
    );
    unreachable;
}

fn linuxHandler() callconv(.naked) noreturn {
    @setRuntimeSafety(false);

    // Save context
    regs.swapgs();
    regs.swapStackToKernel();

    Context.save();
    regs.saveFpuRegsUnaligned();

    defer {
        regs.restoreFpuRegsUnaligned();
        Context.restore();

        regs.restoreUserStack();
        regs.swapgs();

        asm volatile ("sysretq");
    }

    arch.intr.enableForCpu();

    asm volatile (
        \\ cmp %[table_len], %rax
        \\ jae 0f
        :: [table_len] "i" (sys.call.linux.table.len)
    );
    asm volatile (
        \\ mov (%r10,%rax,8), %r11
        \\ test %r11, %r11
        \\ jnz 1f
        \\
        \\ 0:
        \\ mov %rax, %rdi
        \\ call linuxBadCallHandler
        \\ jmp 2f
        \\
        \\ 1:
        \\ call *%r11
        \\ 2:
        :
        : [table] "{r10}" (&sys.call.linux.table),
        : .{ .memory = true }
    );
}

export fn linuxBadCallHandler(n: usize) callconv(.c) isize {
    return sys.call.linux.badCallHandler(n);
}
