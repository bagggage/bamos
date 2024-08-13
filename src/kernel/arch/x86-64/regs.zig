//! # x86-64 Registers
//! 
//! Provides access to various x86-64 CPU registers, Global/Interrupt Descriptor Tables (GDT/IDT). 
//! It includes functions for reading/writing MSRs and saving/restoring CPU state.

const std = @import("std");

// Model-Specific Register (MSR) addresses.
pub const MSR_EFER = 0xC0000080;
pub const MSR_STAR = 0xC0000081;
pub const MSR_LSTAR = 0xC0000082;
pub const MSR_CSTAR = 0xC0000083;
pub const MSR_SFMASK = 0xC0000084;
pub const MSR_FG_BASE = 0xC0000100;
pub const MSR_GS_BASE = 0xC0000101;
pub const MSR_SWAPGS_BASE = 0xC0000102;
pub const MSR_APIC_BASE = 0x1B;

/// Interrupt Descriptor Table Register.
pub const IDTR = packed struct {
    limit: u16 = undefined,
    base: u64 = undefined
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

pub const CalleeRegs = extern struct {
    rbx: u64 = 0,
    rbp: u64 = 0,
    r12: u64 = 0,
    r13: u64 = 0,
    r14: u64 = 0,
    r15: u64 = 0
};

/// Stack frame that is automatically pushed
/// when a hardware interrupt occurs.
pub const InterruptFrame = extern struct {
    rip: u64 = 0,
    cs: u64 = 0,
    rflags: u64 = 0,
    rsp: u64 = 0,
    ss: u64 = 0
};

/// Represents the full state of the CPU during an interrupt, including the 
/// callee-saved registers, scratch registers, and the interrupt frame.
pub const IntrState = extern struct {
    callee: CalleeRegs = .{},
    scratch: ScratchRegs = .{},
    intr: InterruptFrame = .{},
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
        : [ret] "{eax}" (ptr[0]),
          [ret_2] "{edx}" (ptr[1]),
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

pub inline fn getCr2() u64 {
    var result: u64 = undefined;
    asm volatile ("mov %%cr2,%[res]"
        : [res] "=r" (result),
    );

    return result;
}

pub inline fn getCr3() u64 {
    var result: u64 = undefined;
    asm volatile ("mov %%cr3,%[res]"
        : [res] "=r" (result),
    );

    return result;
}

pub inline fn setCr3(cr3: u64) void {
    asm volatile ("mov %[val],%%cr3"
        :
        : [val] "r" (cr3),
    );
}

pub inline fn getCr4() u64 {
    var result: u64 = undefined;
    asm volatile ("mov %%cr4,%[res]"
        : [res] "=r" (result),
    );

    return result;
}

pub inline fn getCs() u16 {
    var cs: u16 = undefined;
    asm volatile ("mov %%cs,%[res]"
        : [res] "=r" (cs),
    );

    return cs;
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

pub inline fn saveState() void {
    saveScratchRegs();
    saveCallerRegs();
}

pub inline fn restoreState() void {
    restoreCallerRegs();
    restoreScratchRegs();
}

pub inline fn setIdtr(idtr: IDTR) void {
    asm volatile ("lidt %[reg]"
        :
        : [reg] "memory" (idtr),
    );
}
