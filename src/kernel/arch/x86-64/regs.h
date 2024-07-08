#pragma once

#include "definitions.h"

/*
Registers is structured according to System V ABI (x86-64).
In reverse order of putting on stack.
*/

struct ScratchRegs {
    uint64_t rax;
    uint64_t rdi;
    uint64_t rsi;
    uint64_t rdx;
    uint64_t rcx;
    uint64_t r8;
    uint64_t r9;
    uint64_t r10;
    uint64_t r11;
};

struct CalleeRegs {
    uint64_t rbx;
    uint64_t rbp;
    uint64_t r12;
    uint64_t r13;
    uint64_t r14;
    uint64_t r15;
};

struct InterruptFrame {
    uint64_t rip;
    uint64_t cs;
    uint64_t eflags;
    uint64_t rsp;
    uint64_t ss;
};

struct ATTR_PACKED Regs {
    CalleeRegs callee;
    ScratchRegs scratch;
    InterruptFrame intr;
};

struct ArgsRegs {
    union {
        uint64_t rdi;
        uint64_t arg0;
    };
    union {
        uint64_t rsi;
        uint64_t arg1;
    };
    union {
        uint64_t rdx;
        uint64_t arg2;
    };
    union {
        uint64_t rcx;
        uint64_t arg3;
    };
};

struct SyscallFrame {
    uint64_t rip;
    uint64_t rflags;
};

struct ATTR_PACKED IDTR {
    uint16_t limit;
    uint64_t base;
};

static ATTR_INLINE_ASM uint64_t get_stack() {
    uint64_t result;

    asm volatile("mov %%rsp,%0":"=g"(result));

    return result;
}

static ATTR_INLINE_ASM void store_stack(uint64_t* const storage) {
    asm volatile("mov %%rsp,%0":"=g"(*storage));
}

static ATTR_INLINE_ASM void load_stack(const uint64_t value) {
    asm volatile("mov %0,%%rsp"::"g"(value));
}

static ATTR_INLINE_ASM void save_caller_regs() {
    asm volatile(
        "push %r15 \n"
        "push %r14 \n"
        "push %r13 \n"
        "push %r12 \n"
        "push %rbp \n"
        "push %rbx"
    );
}

static ATTR_INLINE_ASM void restore_caller_regs() {
    asm volatile(
        "pop %rbx \n"
        "pop %rbp \n"
        "pop %r12 \n"
        "pop %r13 \n"
        "pop %r14 \n"
        "pop %r15"
    );
}

static ATTR_INLINE_ASM void load_caller_regs(CalleeRegs* const regs) {
    asm volatile(
        "pop (%0) \n"
        "pop 0x8(%0) \n"
        "pop 0x10(%0) \n"
        "pop 0x18(%0) \n"
        "pop 0x20(%0) \n"
        "pop 0x28(%0) \n"
        :
        : "g"(regs)
        : "memory"
    );
}

static ATTR_INLINE_ASM void save_scratch_regs() {
    asm volatile(
        "push %r11 \n"
        "push %r10 \n"
        "push %r9 \n"
        "push %r8 \n"
        "push %rcx \n"
        "push %rdx \n"
        "push %rsi \n"
        "push %rdi \n"
        "push %rax"
    );
}

static ATTR_INLINE_ASM void restore_scratch_regs() {
    asm volatile(
        "pop %rax \n"
        "pop %rdi \n"
        "pop %rsi \n"
        "pop %rdx \n"
        "pop %rcx \n"
        "pop %r8 \n"
        "pop %r9 \n"
        "pop %r10 \n"
        "pop %r11"
    );
}

static ATTR_INLINE_ASM void save_regs() {
    save_scratch_regs();
    save_caller_regs();
}

static ATTR_INLINE_ASM void restore_regs() {
    restore_caller_regs();
    restore_scratch_regs();
}

static ATTR_INLINE_ASM uint16_t get_cs() {
    uint16_t result;

    asm volatile("mov %%cs,%0":"=g"(result));
    
    return result;
}

static ATTR_INLINE_ASM void set_idtr(const IDTR idtr) {
    asm volatile("lidt %0"::"memory"(idtr));
}