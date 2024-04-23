#include "syscalls.h"

#include <stddef.h>

#include "proc/local.h"
#include "proc/proc.h"

typedef int (*SysCall_t)();

SysCall_t syscall_table[256] = { NULL };

typedef enum SysCallsIdx {
    SYS_READ = 0,
    SYS_WRITE,
    SYS_OPEN,
    SYS_CLOSE,
    SYS_STAT,

    SYS_CLONE = 0x38,
    SYS_FORK,
    SYS_VFORK,
    SYS_EXECVE,
} SysCallsIdx;

void __syscall_handler_asm() {
    asm volatile (
        "_syscall_handler:\n"
        ".global _syscall_handler \n"
        "cmp $256,%%rax \n"                     // Check syscall idx
        "jge _invalid_syscall \n"
        "lea syscall_table(,%%rax,8),%%rax \n"  // Get pointer to handler
        "test %%rax,%%rax \n"                   // Check if syscall handler exists
        "jz _invalid_syscall \n"
        "pushq %%rbp \n"                        // Save rbp
        "pushq %%rcx \n"                        // Save return address
        "pushq %%r11 \n"                        // Save rflags
        "movq %%rsp,g_proc_local+%a0 \n"        // Save user stack
        "movq g_proc_local+%a1,%%rsp \n"        // Switch to kernel stack
        "movq %%rsp,%%rbp \n"                   // Might be unnecessary?
        "movq %%r10,%%rcx \n"                   // r10 contains arg3 (Syscall ABI), mov it to rcx (System V call ABI)
        "call *%%rax \n"                        // Make call
        "xor %%rdi,%%rdi \n"                    // Clear registers for safety
        "xor %%rsi,%%rsi \n"
        "xor %%rdx,%%rdx \n"
        "xor %%r8,%%r8 \n"
        "xor %%r9,%%r9 \n"
        "xor %%r10,%%r10 \n"
        "movq g_proc_local+%a0,%%rsp \n"        // Restore user stack, return address, flags
        "popq %%r11 \n"
        "popq %%rcx \n"
        "popq %%rbp \n"
        "sysretq \n"                            // Return rax;
        "_invalid_syscall: \n"
        "movq $0xffffffffffffffff,%%rax \n"     // Return -1;
        "sysretq"
        ::
        "i" (offsetof(ProcessorLocal, user_stack)),
        "i" (offsetof(ProcessorLocal, kernel_stack))
    );
}

void init_syscalls() {
    syscall_table[SYS_CLONE]    = &_sys_clone;
    syscall_table[SYS_FORK]     = &_sys_fork;
    syscall_table[SYS_EXECVE]   = &_sys_execve;
}