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
    /// Used with clone/fork
    const Extra = extern struct {
        callee: regs.CalleeRegs,
        ret_ptr: usize,

        inline fn save() void {
            regs.saveCallerRegs();
            regs.stackAlloc(1);
        }

        inline fn restore() void {
            regs.restoreCallerRegs();
            regs.stackFree(1);
        }

        inline fn free() void {
            regs.stackFree((@sizeOf(regs.CalleeRegs) / @sizeOf(usize)) + 1);
        }
    };

    fxsave: [512]u8 align(@alignOf(usize)),
    rdi: usize,
    rsi: usize,
    rdx: usize,
    rcx: usize,
    rbp: usize,
    r8:  usize,
    r9:  usize,
    r10: usize,
    r11: usize,
    rsp: usize,

    inline fn save() void {
        asm volatile (
            \\ push %r11
            \\ push %r10
            \\ push %r9
            \\ push %r8
            \\ push %rbp
            \\ push %rcx
            \\ push %rdx
            \\ push %rsi
            \\ push %rdi
            \\
            \\ mov %r10, %rcx
        );

        regs.saveFpuRegs();
    }

    inline fn restore() void {
        regs.restoreFpuRegs();

        asm volatile (
            \\ pop %rdi
            \\ pop %rsi
            \\ pop %rdx
            \\ pop %rcx
            \\ pop %rbp
            \\ pop %r8
            \\ pop %r9
            \\ pop %r10
            \\ pop %r11
        );
    }

    inline fn toExtra(self: *Context) *Extra {
        return @ptrFromInt(@intFromPtr(self) - @sizeOf(Extra));
    }
};

/// Linux specific data stored per each task
pub const LinuxAbi = struct {
    gs_base: usize = 0,
    fs_base: usize = 0,
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
        .linux_sysv => blk: {
            linuxSetupAbi(task);
            break :blk linuxHandler;
        }
    };

    regs.setMsr(regs.MSR_LSTAR, @intFromPtr(syscall_handler));
}

pub fn startThread(_: sys.call.Abi, task: *sched.Task, run_ctx: sys.exe.RunContext) void {
    const ctx_regs = task.context.stack_ptr.asCtxRegs();

    ctx_regs.callee.r12 = run_ctx.entry_ptr;
    ctx_regs.callee.r13 = run_ctx.stack_ptr;
    task.context.setInstrPtr(@intFromPtr(&linuxRunProcess));
}

pub inline fn jumpThread(_: sys.call.Abi, _: *sched.Task, run_ctx: sys.exe.RunContext) noreturn {
    asm volatile (
        "jmp linuxRunProcess"
        :
        : [entry_ptr] "{r12}" (run_ctx.entry_ptr),
          [stack_ptr] "{r13}" (run_ctx.stack_ptr)
    );

    unreachable;
}

pub fn cloneThread(_: sys.call.Abi, _: *sched.Task, dest: *sched.Task, ctx: *Context) void {
    const stack_top = lib.misc.alignDown(usize, dest.getKernelStackTop(), 16);
    const dest_ctx: *Context = @ptrFromInt(stack_top - @sizeOf(Context));
    const dest_ext = dest_ctx.toExtra();

    dest_ext.* = ctx.toExtra().*;
    dest_ctx.* = ctx.*;

    dest.context = .initUnaligned(@intFromPtr(dest_ext), @intFromPtr(&linuxCloneReturn));
}

pub fn contextCall(
    comptime call: anytype,
    comptime name: []const u8
) *const fn () isize {
    const symbol_name = std.fmt.comptimePrint("syscall.contextCall_{s}", .{name});
    @export(&call, .{ .name = symbol_name });

    const wrapper = opaque {
        fn entry() callconv(.naked) void {
            asm volatile (
                \\ mov %rdi, %r9
                \\ lea 0x8(%rsp), %rdi
            );

            Context.Extra.save();
            asm volatile (std.fmt.comptimePrint(
                "call {s}", .{symbol_name}
            ));

            Context.Extra.free();
            asm volatile ("retq");
        }
    };

    return @ptrCast(&wrapper.entry);
}

pub fn linuxArchPrCtl(op: c_int, addr: ?*usize) !void {
    const ARCH_SET_GS = 0x1001;
    const ARCH_SET_FS = 0x1002;
    const ARCH_GET_FS = 0x1003;
    const ARCH_GET_GS = 0x1004;
    const ARCH_GET_CPUID = 0x1011;
    const ARCH_SET_CPUID = 0x1012;
    const ARCH_GET_XCOMP_SUPP = 0x1021;
    const ARCH_GET_XCOMP_PERM = 0x1022;
    const ARCH_REQ_XCOMP_PERM = 0x1023;
    const ARCH_GET_XCOMP_GUEST_PERM = 0x1024;
    const ARCH_REQ_XCOMP_GUEST_PERM = 0x1025;
    const ARCH_XCOMP_TILECFG = 17;
    const ARCH_XCOMP_TILEDATA = 18;
    const ARCH_MAP_VDSO_X32 = 0x2001;
    const ARCH_MAP_VDSO_32 = 0x2002;
    const ARCH_MAP_VDSO_64 = 0x2003;
    const ARCH_GET_UNTAG_MASK = 0x4001;
    const ARCH_ENABLE_TAGGED_ADDR = 0x4002;
    const ARCH_GET_MAX_TAG_BITS = 0x4003;
    const ARCH_FORCE_TAGGED_SVA = 0x4004;
    const ARCH_SHSTK_ENABLE = 0x5001;
    const ARCH_SHSTK_DISABLE = 0x5002;
    const ARCH_SHSTK_LOCK = 0x5003;
    const ARCH_SHSTK_UNLOCK = 0x5004;
    const ARCH_SHSTK_STATUS = 0x5005;

    const task = sched.getCurrentTask();
    const abi_data = task.spec.user.abi_data.asPtr(sys.call.linux.AbiData).?;

    switch (op) {
        ARCH_SET_GS => {
            abi_data.arch_specific.gs_base = @intFromPtr(addr);
            regs.setMsr(regs.MSR_SWAPGS_BASE, @intFromPtr(addr));
        },
        ARCH_SET_FS => {
            abi_data.arch_specific.fs_base = @intFromPtr(addr);
            regs.setMsr(regs.MSR_FS_BASE, @intFromPtr(addr));
        },
        ARCH_GET_FS => addr.?.* = regs.getMsr(regs.MSR_FS_BASE),
        ARCH_GET_GS => addr.?.* = regs.getMsr(regs.MSR_SWAPGS_BASE),
        ARCH_GET_CPUID,
        ARCH_SET_CPUID,
        ARCH_GET_XCOMP_SUPP,
        ARCH_GET_XCOMP_PERM,
        ARCH_REQ_XCOMP_PERM,
        ARCH_GET_XCOMP_GUEST_PERM,
        ARCH_REQ_XCOMP_GUEST_PERM,
        ARCH_XCOMP_TILECFG,
        ARCH_XCOMP_TILEDATA,
        ARCH_MAP_VDSO_X32,
        ARCH_MAP_VDSO_32,
        ARCH_MAP_VDSO_64,
        ARCH_GET_UNTAG_MASK,
        ARCH_ENABLE_TAGGED_ADDR,
        ARCH_GET_MAX_TAG_BITS,
        ARCH_FORCE_TAGGED_SVA,
        ARCH_SHSTK_ENABLE,
        ARCH_SHSTK_DISABLE,
        ARCH_SHSTK_LOCK,
        ARCH_SHSTK_UNLOCK,
        ARCH_SHSTK_STATUS => return error.InvalidArgs,
        else => return error.InvalidArgs
    }
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

fn linuxCloneReturn() callconv(.naked) noreturn {
    Context.Extra.restore();

    asm volatile (
        \\ xor %rax, %rax
        \\ jmp linuxSyscallReturn
    );
}

fn linuxSetupAbi(task: *sched.Task) void {
    const abi_data = task.spec.user.abi_data.asPtr(sys.call.linux.AbiData).?;

    if (abi_data.rseq) |rseq| {
        @atomicStore(u32, &rseq.cpu_id, smp.getIdx(), .release);
    }

    regs.setMsr(regs.MSR_SWAPGS_BASE, abi_data.arch_specific.gs_base);
    regs.setMsr(regs.MSR_FS_BASE, abi_data.arch_specific.fs_base);
}

fn linuxHandler() callconv(.naked) noreturn {
    @setRuntimeSafety(false);

    // Save context
    regs.swapgs();
    regs.swapStackToKernel();

    Context.save();

    defer {
        asm volatile("linuxSyscallReturn:");

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
