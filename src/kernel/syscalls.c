#include "syscalls.h"

#include <stddef.h>

#include "mem.h"
#include "math.h"

#include "fs/vfs.h"

#include "libc/errno.h"

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

    SYS_MMAP = 8,
    SYS_MUNMAP = 10,

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

typedef enum SysOpenFlags {
    O_RDONLY    = 00,
    O_WRONLY    = 01,
    O_RDWR      = 02,
    O_ACCMODE   = 03,
    O_CREAT     = 0100,
    O_EXCL      = 0200,
    O_NOCTTY    = 0400,
    O_TRUNC     = 01000,
    O_APPEND    = 02000,
    O_NONBLOCK  = 04000,
    O_DSYNC     = 010000,
    O_DIRECT    = 040000,
    O_LARGEFILE = 0100000,
    O_DIRECTORY = 0200000,
    O_NONFOLLOW = 0400000,
    O_NOATIME   = 01000000,
    O_CLOEXEC   = 02000000
} SysOpenFlags;

typedef enum MMapFlags {
    PROT_NONE = 0,
    PROT_EXEC = 01,
    PROT_READ = 02,
    PROT_WRITE = 04,

    MAP_FIXED = 0,
    MAP_SHARED = 01,
    MAP_PRIVATE = 02,
    MAP_ANONYMOUS = 04
} MMapFlags;

long _sys_read(unsigned int fd, char* buffer, size_t count) {
    
}

long _sys_write(unsigned int fd, const char* buffer, size_t count) {
    
}

long _sys_open(const char* filename, int flags) {
    if (is_virt_addr_mapped_userspace(
            g_proc_local.current_task->process->addr_space.page_table,
            (const uint64_t)filename
        ) == FALSE) {
        return -EINVAL;
    }

    long result = fd_open(
        g_proc_local.current_task->process,
        filename,
        ((flags & O_WRONLY) || (flags & O_RDWR)) ? VFS_WRITE : VFS_READ
    );

    if (result < 0) return (result == -2) ? -ENOENT : -ENOMEM;

    return result;
}

long _sys_close(unsigned int fd) {
    return (fd_close(g_proc_local.current_task->process, fd) ? 0 : -EBADF);
}

long _sys_mmap(void* address, size_t length, int protection, int flags, int fd, uint32_t offset) {
    if (address != NULL || length == 0 ||
        protection == PROT_NONE ||
        (protection & PROT_READ) == 0 ||
        flags != (MAP_ANONYMOUS | MAP_PRIVATE)) {
        return -EINVAL;
    }

    VMPageFrameNode* frame_node = proc_push_vm_page(g_proc_local.current_task->process);

    if (frame_node == NULL) return -ENOMEM;

    frame_node->frame = vm_alloc_pages(
        div_with_roundup(length, PAGE_BYTE_SIZE),
        &g_proc_local.current_task->process->addr_space.heap,
        g_proc_local.current_task->process->addr_space.page_table,
        (
            VMMAP_USER_ACCESS |
            ((protection & PROT_WRITE) ? VMMAP_WRITE : 0) |
            ((protection & PROT_EXEC) ? VMMAP_EXEC : 0)
        )
    );

    if (frame_node->frame.count == 0) {
        proc_dealloc_vm_page(g_proc_local.current_task->process, frame_node);
        return -ENOMEM;
    }

    return (long)frame_node->frame.virt_address;
}

long _sys_munmap(void* address, size_t length) {
    if (address == NULL || length == 0) return -EINVAL;

    spin_lock(&g_proc_local.current_task->process->vm_lock);

    VMPageFrameNode* frame_node = (VMPageFrameNode*)g_proc_local.current_task->process->vm_pages.next;

    while (frame_node != NULL &&
        frame_node->frame.virt_address != address) {
        frame_node = frame_node->next;
    }

    spin_release(&g_proc_local.current_task->process->vm_lock);

    if (frame_node == NULL) return -EINVAL;
    
    uint32_t pages_count = div_with_roundup(length, PAGE_BYTE_SIZE);

    if (pages_count != frame_node->frame.count) return -EINVAL;

    proc_dealloc_vm_page(g_proc_local.current_task->process, frame_node);

    return 0;
}

void init_syscalls() {
    syscall_table[SYS_READ]     = &_sys_read;
    syscall_table[SYS_WRITE]    = &_sys_write;
    syscall_table[SYS_OPEN]     = &_sys_open;
    syscall_table[SYS_CLOSE]    = &_sys_close;

    syscall_table[SYS_MMAP]     = &_sys_mmap;

    syscall_table[SYS_CLONE]    = &_sys_clone;
    syscall_table[SYS_FORK]     = &_sys_fork;
    syscall_table[SYS_EXECVE]   = &_sys_execve;
}