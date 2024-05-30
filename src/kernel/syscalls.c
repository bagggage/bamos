#include "syscalls.h"

#include <stddef.h>

#include "logger.h"
#include "math.h"
#include "mem.h"

#include "fs/vfs.h"

#include "libc/dirent.h"
#include "libc/errno.h"
#include "libc/stdio.h"
#include "libc/sys/mman.h"
#include "libc/sys/syscall.h"

#include "proc/local.h"
#include "proc/proc.h"

#define ALIGN(x, a) (((x) + (a) - 1) & ~((a) - 1))

typedef int (*SysCall_t)();

SysCall_t syscall_table[256] = { NULL };

__attribute__((naked)) void _syscall_handler() {
    asm volatile (
        "cmp $256,%%rax \n"                     // Check syscall idx
        "jae _invalid_syscall \n"
        "movq syscall_table(,%%rax,8),%%rax \n"  // Get pointer to handler
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

long _sys_read(unsigned int fd, char* buffer, size_t count) {
    if (count == 0) return -EINVAL;
    if (is_virt_addr_mapped_userspace(
            g_proc_local.current_task->process->addr_space.page_table,
            (uint64_t)buffer
        ) == FALSE) {
        return -EFAULT;
    }

    if (fd >= g_proc_local.current_task->process->files_capacity) {
        return -EBADF;
    }

    FileDescriptor* file = g_proc_local.current_task->process->files[fd];

    if (file == NULL || (file->mode & O_WRONLY) != 0) return -EBADF;

    const uint32_t readed = vfs_read(file->dentry, file->cursor_offset, count, (void*)buffer);

    file->cursor_offset += readed;

    return readed;
}

long _sys_write(unsigned int fd, const char* buffer, size_t count) {
    if (count == 0) return -EINVAL;
    if (is_virt_addr_mapped_userspace(
            g_proc_local.current_task->process->addr_space.page_table,
            (uint64_t)buffer
        ) == FALSE) {
        return -EFAULT;
    }

    if (fd >= g_proc_local.current_task->process->files_capacity) {
        return -EBADF;
    }

    FileDescriptor* file = g_proc_local.current_task->process->files[fd];

    if (file == NULL ||
        (file->mode & O_WRONLY || file->mode & O_RDWR) == 0) {
        return -EBADF;
    }

    const uint32_t writen = vfs_write(file->dentry, file->cursor_offset, count, buffer);

    file->cursor_offset += writen;

    return writen;
}

long _sys_open(const char* filename, int flags) {
    if (((flags & O_WRONLY) && (flags & O_RDWR)) ||
        is_virt_addr_mapped_userspace(
            g_proc_local.current_task->process->addr_space.page_table,
            (const uint64_t)filename
        ) == FALSE) {
        return -EINVAL;
    }

    long result = fd_open(
        g_proc_local.current_task->process,
        filename,
        flags
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

int _sys_getdents(unsigned int fd, struct linux_dirent* dirent, unsigned int count) {
    if (is_virt_addr_mapped_userspace(
            g_proc_local.current_task->process->addr_space.page_table,
            (uint64_t)dirent
        ) == FALSE) {
        return -EFAULT;
    }

    if (count % sizeof(struct linux_dirent) != 0 || count == 0) {
        return -EINVAL;
    }

    if (fd >= g_proc_local.current_task->process->files_capacity) {
        return -EBADF;
    }

    FileDescriptor* file = g_proc_local.current_task->process->files[fd];

    VfsDentry* dentry = file->dentry;

    if (dentry->inode->type != VFS_TYPE_DIRECTORY) {
        return -ENOTDIR;
    }

    int return_value = 0;
    
    long current_offset = 0;
    for (uint32_t i = 0; i < count / sizeof(struct linux_dirent); ++i) {
        (dirent + current_offset)->d_ino = dentry->childs[i]->inode->index;
        (dirent + current_offset)->d_off = (strlen(dentry->name) % 4 == 0) ?
                        8 + strlen(dentry->name) : // 8 means the size of all other fields in bytes
                        8 + ((strlen(dentry->name) / 4) + 1) * 4;
        (dirent + current_offset)->d_reclen = ALIGN(offsetof(struct linux_dirent, d_name) + 
                                                    strlen((dirent + current_offset)->d_name) + 1, sizeof(long));
        strcpy((dirent + current_offset)->d_name, dentry->name);

        current_offset += dirent->d_off;

        return_value += (dirent + current_offset)->d_reclen;
    }

    return return_value;
}

void init_syscalls() {
    syscall_table[SYS_READ]     = &_sys_read;
    syscall_table[SYS_WRITE]    = &_sys_write;
    syscall_table[SYS_OPEN]     = &_sys_open;
    syscall_table[SYS_CLOSE]    = &_sys_close;

    syscall_table[SYS_MMAP]     = &_sys_mmap;

    syscall_table[SYS_MUNMAP]   = &_sys_munmap;

    syscall_table[SYS_CLONE]    = &_sys_clone;
    syscall_table[SYS_FORK]     = &_sys_fork;
    syscall_table[SYS_EXECVE]   = &_sys_execve;

    syscall_table[SYS_GETDENTS]   = &_sys_getdents;
}
