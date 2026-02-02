//! # x86-64 Registers
//!
//! Provides access to various x86-64 CPU registers, Global/Interrupt Descriptor Tables (GDT/IDT).
//! It includes functions for reading/writing MSRs and saving/restoring CPU state.

// Copyright (C) 2024-2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const arch = @import("arch.zig");
const intr = arch.intr;
const smp = @import("../../smp.zig");

// Model-Specific Register (MSR) addresses.
pub const MSR_PAT = 0x277;
pub const MSR_EFER = 0xC0000080;
pub const MSR_STAR = 0xC0000081;
pub const MSR_LSTAR = 0xC0000082;
pub const MSR_CSTAR = 0xC0000083;
pub const MSR_SFMASK = 0xC0000084;
pub const MSR_FS_BASE = 0xC0000100;
pub const MSR_GS_BASE = 0xC0000101;
pub const MSR_SWAPGS_BASE = 0xC0000102;
pub const MSR_APIC_BASE = 0x1B;

const gs_tss_offset = @offsetOf(smp.LocalData, "arch_specific") + @offsetOf(arch.CpuLocalData, "tss");

pub const call_clobers: std.builtin.assembly.Clobbers = .{
    .rax = true, .rcx = true, .rdx = true,
    .rdi = true, .rsi = true, .r8 = true,
    .r9 = true, .r10 = true, .r11 = true,
    .memory = true
};

/// Interrupt Descriptor Table Register.
pub const IDTR = packed struct {
    limit: u16 = undefined,
    base: u64 = undefined,

    pub fn format(self: *const IDTR, _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("base = 0x{x}, limit = {}", .{ self.base, self.limit });
    }
};

/// Global Descriptor Table Register.
pub const GDTR = IDTR;

/// Represents the Extended Feature Enable Register.
pub const EFER = packed struct {
    syscall_ext: u1,
    reserved_1: u7,
    long_mode_enable: u1,
    reserved_2: u1,
    long_mode_active: u1,
    noexec_enable: u1,
    secure_vm_enable: u1,
    long_mode_seg_limit_enable: u1,
    fast_fxsave_restor_enable: u1,
    translation_cache_ext: u1,
    reserved_3: u48,
};

pub const STAR = packed struct {
    eip: u32,
    kernel_segment_sel: u16,
    user_segment_sel: u16
};

pub const Flags = packed struct {
    carry: bool = false,
    reserved_1: u1 = 1,
    parity: bool = false,
    reserved_2: u1 = 1,
    aux_carry: bool = false,
    reserved_3: u1 = 1,
    zero: bool = false,
    sign: bool = false,
    trap: bool = false,
    intr_enable: bool = false,
    direction: bool = false,
    overflow: bool = false,
    io_privilege: u2 = undefined,
    nested_task: u1 = undefined,
    reserved_4: u1 = 0,
    @"resume": bool = false,
    virt_mode: bool = false,
    align_check: bool = false,
    virt_intr: bool = false,
    virt_intr_pending: bool = false,
    cpuid: bool = true,
    reserved_5: u8 = 0,
    aes: bool = false,
    alt_instr_set: bool = false
};

pub const ScratchRegs = extern struct {
    rax: u64 = 0,
    rdi: u64 = 0,
    rsi: u64 = 0,
    rdx: u64 = 0,
    rcx: u64 = 0,
    r8: u64 = 0,
    r9: u64 = 0,
    r10: u64 = 0,
    r11: u64 = 0,
};

pub const CalleeRegs = extern struct { rbx: u64 = 0, rbp: u64 = 0, r12: u64 = 0, r13: u64 = 0, r14: u64 = 0, r15: u64 = 0 };

pub const State = extern struct {
    callee: CalleeRegs,
    scratch: ScratchRegs,
};

/// Stack frame that is automatically pushed
/// when a hardware interrupt occurs.
pub const InterruptFrame = extern struct { rip: u64 = 0, cs: u64 = 0, rflags: u64 = 0, rsp: u64 = 0, ss: u64 = 0 };

/// Represents the full state of the CPU during an interrupt, including the
/// callee-saved registers, scratch registers, and the interrupt frame.
pub const IntrState = extern struct {
    callee: CalleeRegs = .{},
    scratch: ScratchRegs = .{},
    intr: InterruptFrame = .{},
};

/// Represents the saved state of the CPU during an IRQ interrupt.
pub const LowLevelIntrState = extern struct {
    scratch: ScratchRegs,

    idx: u64,
    intr: InterruptFrame,

    comptime {
        std.debug.assert(@sizeOf(@This()) == (@sizeOf(ScratchRegs) + @sizeOf(InterruptFrame) + 0x8));
    }
};

/// Read Model-Specific Register.
///
/// - `msr_addr`: The address of the MSR to read.
/// - Returns: The value of the MSR.
pub inline fn getMsr(msr_addr: u32) u64 {
    var value_l: u32 = undefined;
    var value_h: u32 = undefined;

    asm volatile ("rdmsr"
        : [ret] "={eax}" (value_l),
          [ret_2] "={edx}" (value_h),
        : [msr_addr] "{ecx}" (msr_addr),
    );

    return value_l | (@as(u64, value_h) >> 32);
}

/// Write Model-Specific Register.
///
/// - `msr_addr`: The address of the MSR to write.
/// - `value`: The value to write to the MSR.
pub inline fn setMsr(msr_addr: u32, value: u64) void {
    const ptr: [*]const u32 = @ptrCast(&value);

    asm volatile ("wrmsr"
        :
        : [in_1] "{eax}" (ptr[0]),
          [in_2] "{edx}" (ptr[1]),
          [msr_addr] "{ecx}" (msr_addr),
    );
}

pub inline fn getEfer() EFER {
    const efer = getMsr(MSR_EFER);
    const efer_ptr: *const EFER = @ptrCast(&efer);

    return efer_ptr.*;
}

pub inline fn setEfer(efer: EFER) void {
    const efer_ptr: *const u64 = @ptrCast(&efer);

    setMsr(MSR_EFER, efer_ptr.*);
}

pub inline fn getGdtr() GDTR {
    var gdtr: GDTR = undefined;

    asm volatile ("sgdt %[val]"
        : [val] "=memory" (gdtr),
    );

    return gdtr;
}

pub inline fn setGdtr(gdtr: GDTR) void {
    asm volatile ("lgdt %[val]"
        :
        : [val] "memory" (gdtr),
    );
}

pub inline fn getCr0() u64 {
    return asm volatile ("mov %%cr0,%[res]"
        : [res] "=r" (-> u64),
    );
}

pub inline fn setCr0(cr0: u64) void {
    asm volatile ("mov %[val],%%cr0"
        :
        : [val] "r" (cr0),
    );
}

pub inline fn getCr2() u64 {
    return asm volatile ("mov %%cr2,%[res]"
        : [res] "=r" (-> u64),
    );
}

pub inline fn getCr3() u64 {
    return asm volatile ("mov %%cr3,%[res]"
        : [res] "=r" (-> u64),
    );
}

pub inline fn setCr3(cr3: u64) void {
    asm volatile ("mov %[val],%%cr3"
        :
        : [val] "r" (cr3),
    );
}

pub inline fn getCr4() u64 {
    return asm volatile ("mov %%cr4,%[res]"
        : [res] "=r" (-> u64),
    );
}

pub inline fn setCr4(cr4: u64) void {
    asm volatile ("mov %[val],%%cr4"
        :
        : [val] "r" (cr4),
    );
}

pub inline fn getCs() u16 {
    return asm volatile ("mov %%cs,%[res]"
        : [res] "=r" (-> u16),
    );
}

pub inline fn setGs(selector: u16) void {
    asm volatile ("mov %[val],%%gs"
        :: [val] "r" (selector),
    );
}

pub inline fn getSs() u16 {
    return asm volatile ("mov %%ss,%[res]"
        : [res] "=r" (-> u16),
    );
}

pub inline fn setSs(selector: u16) void {
    asm volatile ("mov %[val],%%ss"
        :: [val] "r" (selector),
    );
}

pub inline fn setDs(selector: u16) void {
    asm volatile ("mov %[val],%%ds"
        :: [val] "r" (selector),
    );
}

pub inline fn setEs(selector: u16) void {
    asm volatile ("mov %[val],%%es"
        :: [val] "r" (selector),
    );
}

pub inline fn getFlags() Flags {
    return asm volatile (
        \\pushfq
        \\pop %rax
        : [out] "={rax}" (-> Flags),
        :
        : .{ .memory = true }
    );
}

pub inline fn swapgs() void {
    asm volatile ("swapgs");
}

pub inline fn swapStackToKernel() void {
    asm volatile (std.fmt.comptimePrint(
        \\ xchg %rsp, %gs:{}
        \\ push %gs:{0}
        , .{gs_tss_offset + @offsetOf(intr.TaskStateSegment, "rsps")}
    ));
}

pub inline fn restoreUserStack() void {
    asm volatile (std.fmt.comptimePrint(
        \\ cli
        \\ pop %gs:{}
        \\ xchg %rsp, %gs:{0}
        , .{gs_tss_offset + @offsetOf(intr.TaskStateSegment, "rsps")}
    ));
}

pub inline fn alignStackUnsafe() void {
    asm volatile (
        \\ mov %rsp, %rbp
        \\ and $-16, %rsp
    );
}

pub inline fn restoreStackUnsafe() void {
    asm volatile ("mov %rbp, %rsp");
}

pub inline fn alignStackSafe() void {
    asm volatile ("push %rbp");
    alignStackUnsafe();
}

pub inline fn restoreStackSafe() void {
    restoreStackUnsafe();
    asm volatile ("pop %rbp");
}

pub inline fn saveCallerRegs() void {
    asm volatile (
        \\push %r15
        \\push %r14
        \\push %r13
        \\push %r12
        \\push %rbp
        \\push %rbx
    );
}

pub inline fn restoreCallerRegs() void {
    asm volatile (
        \\pop %rbx
        \\pop %rbp
        \\pop %r12
        \\pop %r13
        \\pop %r14
        \\pop %r15
    );
}

pub inline fn saveScratchRegs() void {
    asm volatile (
        \\push %r11
        \\push %r10
        \\push %r9
        \\push %r8
        \\push %rcx
        \\push %rdx
        \\push %rsi
        \\push %rdi
        \\push %rax
    );
}

pub inline fn restoreScratchRegs() void {
    asm volatile (
        \\pop %rax
        \\pop %rdi
        \\pop %rsi
        \\pop %rdx
        \\pop %rcx
        \\pop %r8
        \\pop %r9
        \\pop %r10
        \\pop %r11
    );
}

pub inline fn saveFpuRegs() void {
    asm volatile (
        \\ sub $512, %rsp
        \\ fxsave64 (%rsp)
    );
}

pub inline fn saveFpuRegsUnaligned() void {
    asm volatile (
        \\ sub $520, %rsp
        \\ fxsave64 (%rsp)
    );
}

pub inline fn restoreFpuRegs() void {
    asm volatile (
        \\ fxrstor64 (%rsp)
        \\ add $512, %rsp
    );
}

pub inline fn restoreFpuRegsUnaligned() void {
    asm volatile (
        \\ fxrstor64 (%rsp)
        \\ add $520, %rsp
    );
}

pub inline fn saveState() void {
    saveScratchRegs();
    saveCallerRegs();
}

pub inline fn restoreState() void {
    restoreCallerRegs();
    restoreScratchRegs();
}

pub inline fn getStack() usize {
    var stack: usize = undefined;
    asm volatile ("mov %%rsp,%[res]"
        : [res] "=r" (stack),
    );

    return stack;
}

pub inline fn setStack(stack: usize) void {
    asm volatile ("mov %[res],%%rsp"
        :
        : [res] "r" (stack),
    );
}

pub inline fn getIdtr() IDTR {
    var idtr: IDTR = undefined;
    asm volatile ("sidt %[reg]"
        : [reg] "=memory" (idtr),
    );

    return idtr;
}

pub inline fn setIdtr(idtr: IDTR) void {
    asm volatile ("lidt %[reg]"
        :
        : [reg] "memory" (idtr),
    );
}

pub inline fn setTss(tss: u16) void {
    asm volatile ("ltr %[seg]"
        :
        : [seg] "r" (tss),
    );
}

pub inline fn getTsc() u64 {
    var hi: u32 = undefined;
    var lo: u32 = undefined;

    asm volatile ("rdtsc"
        : [hi] "={edx}" (hi),
          [lo] "={eax}" (lo),
    );

    return (@as(u64, hi) << 32) | lo;
}

pub inline fn stackAlloc(comptime items_num: comptime_int) void {
    asm volatile ("sub %[size],%rsp"
        :
        : [size] "i" (items_num * @sizeOf(usize)),
    );
}

pub inline fn stackFree(comptime items_num: comptime_int) void {
    asm volatile ("add %[size],%rsp"
        :
        : [size] "i" (items_num * @sizeOf(usize)),
    );
}
