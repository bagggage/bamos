#pragma once

#include "definitions.h"

#include "vm/vm.h"

#include "intr/intr.h"

typedef struct Process Process;

typedef enum ThreadState {
    THREAD_RUNNING,
    THREAD_RUNNABLE,
    THREAD_SLEEPING,
    THREAD_WAITING,
    THREAD_TERMINATED
} ThreadState;

typedef struct CallerSaveRegs {
    uint64_t rbx;
    uint64_t rbp;
    uint64_t r12;
    uint64_t r13;
    uint64_t r14;
    uint64_t r15;
} CallerSaveRegs;

typedef struct ArgsRegs {
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
} ArgsRegs;

typedef struct ScratchRegs {
    uint64_t rax;
    uint64_t rdi;
    uint64_t rsi;
    uint64_t rdx;
    uint64_t rcx;
    uint64_t r8;
    uint64_t r9;
    uint64_t r10;
    uint64_t r11;
} ScratchRegs;

typedef struct SyscallFrame {
    uint64_t rip;
    uint64_t rflags;
} SyscallFrame;

/*
Registers are grouped according to System V ABI
*/
typedef struct ExecutionState {
    CallerSaveRegs caller_save;

    union {
        ScratchRegs scratch;
        SyscallFrame syscall_frame;
    };

    InterruptFrame64 intr_frame;
} ExecutionState;

typedef struct Thread {
    VMMemoryBlock stack;

    union {
        ExecutionState* exec_state;
        uint64_t stack_ptr;
    };

    uint8_t state;
} Thread;

static ATTR_INLINE_ASM void switch_stack(const uint64_t stack) {
    asm volatile(
        "mov %%rsp,%%rax \n"
        "mov %0,%%rsp \n"
        "push (%%rax)"
        ::"g"(stack)
        : "%rax"
    );
}

static ATTR_INLINE_ASM void stack_round(const uint32_t size) {
    asm volatile(
        "and $~0xf,%%rsp \n"
        "sub %0,%%rsp"
        ::"g"(size)
    );
}

static ATTR_INLINE_ASM void stack_alloc(const uint32_t size) {
    asm volatile("sub %0,%%rsp"::"g"(size));
}

static ATTR_INLINE_ASM void stack_free(const uint32_t size) {
    asm volatile("add %0,%%rsp"::"g"(size));
}

static ATTR_INLINE_ASM void save_syscall_frame() {
    asm volatile(
        "pop %rax \n"
        "pushf \n"
        "push %rax"
    );
}

static ATTR_INLINE_ASM void store_syscall_frame() {
    asm volatile(
        "push %r11 \n"
        "push %rcx"
    );
}

static ATTR_INLINE_ASM void restore_syscall_frame() {
    asm volatile(
        "pop %rcx \n"
        "pop %r11"
    );
}

static ATTR_INLINE_ASM void restore_args_regs() {
    asm volatile(
        "pop %rdi \n"
        "pop %rsi \n"
        "pop %rdx \n"
        "pop %rcx"
    );
};

static ATTR_INLINE_ASM void ret(const uint64_t rax) {
    asm volatile("ret"::"a"(rax));
}

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

static ATTR_INLINE_ASM void save_stack(Thread* const thread) {
    asm volatile(
        "mov %%rsp,%0"
        : "=g" (thread->exec_state)
    );
}

static ATTR_INLINE_ASM void restore_stack(const Thread* thread) {
    asm volatile(
        "mov %0,%%rsp"
        :
        : "g" (thread->exec_state)
    );
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

static ATTR_INLINE_ASM void load_caller_regs(CallerSaveRegs* const regs) {
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

static inline uint64_t thread_get_stack_top(const Thread* const thread) {
    return thread->stack.virt_address + ((uint64_t)thread->stack.pages_count * PAGE_BYTE_SIZE) - 0x10;
}

bool_t thread_allocate_stack(Process* const process, Thread* const thread);
bool_t thread_copy_stack(const Thread* src_thread, Thread* const dst_thread, const Process* dst_proc);
void thread_dealloc_stack(Thread* const thread);
