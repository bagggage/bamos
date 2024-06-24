#include "syscalls.h"

#include <stddef.h>

#include "logger.h"
#include "math.h"
#include "mem.h"

#include "cpu/regs.h"

#include "fs/vfs.h"

#include "libc/asm/prctl.h"
#include "libc/dirent.h"
#include "libc/errno.h"
#include "libc/fcntl.h"
#include "libc/stdio.h"
#include "libc/unistd.h"
#include "libc/sys/mman.h"
#include "libc/sys/syscall.h"

#include "proc/local.h"
#include "proc/proc.h"

#define ALIGN(x, a) (((x) + (a) - 1) & ~((a) - 1))

typedef long (*syscall_t)(uint64_t,uint64_t,uint64_t,uint64_t,uint64_t,uint64_t);

void* syscall_table[512] = { NULL };

void invalid_syscall_msg(uint64_t syscall_idx) {
    kernel_warn("INVALID SYSCALL: %u\n", syscall_idx);
}

ATTR_NAKED void _syscall_handler() {
    register uint64_t ip asm("%rcx");
    register uint64_t rflags asm("%r11");

    register uint64_t syscall asm("%rax");

    register uint64_t arg1 asm("%rdi");
    register uint64_t arg2 asm("%rsi");
    register uint64_t arg3 asm("%rdx");
    register uint64_t arg4 asm("%r10");
    register uint64_t arg5 asm("%r8");
    register uint64_t arg6 asm("%r9");

    if (syscall >= sizeof(syscall_table) / sizeof(syscall_table[0])) goto invalid_syscall;

    {
        // Get syscall handler in asm, in case to use only rax register
        asm volatile("mov syscall_table(,%1,8),%0":"=r"(syscall):"r"(syscall));

        if (syscall == 0) goto invalid_syscall;

        // Protect rcx,r11 from compiler allocation before saving
        USE(ip); USE(rflags);
        store_syscall_frame();

        {
            register ProcessorLocal* proc_local asm("%rcx") = proc_get_local();
            USE(proc_local);

            store_stack((uint64_t*)&proc_local->user_stack);
            load_stack((uint64_t)proc_local->kernel_stack);
        }

        register long result asm("%rax") = ((syscall_t)syscall)(arg1,arg2,arg3,arg4,arg5,arg6);

        {
            register ProcessorLocal* proc_local asm("%r11") = proc_get_local();
            USE(proc_local);

            proc_local->user_stack->rflags |= RFLAGS_IF;

            load_stack((uint64_t)proc_local->user_stack);
        }

        restore_syscall_frame();
        sysret();

        USE(result);
    }

    //asm volatile (
    //    "cmp $512,%%rax \n"                     // Check syscall idx
    //    "jae _invalid_syscall \n"
    //    "pushq %%rax \n"
    //    "movq syscall_table(,%%rax,8),%%rax \n"  // Get pointer to handler
    //    "test %%rax,%%rax \n"                   // Check if syscall handler exists
    //    "jz _invalid_syscall \n"
    //    "add $8,%%rsp \n"
    //    "pushq %%rbp \n"                        // Save rbp
    //    "pushq %%rcx \n"                        // Save return address
    //    "or %a3,%%r11 \n"                       // Enable interrupts
    //    "pushq %%r11 \n"                        // Save rflags
    //    "movq %%gs:0,%%r11 \n"                  // Get processor local data pointer
    //    "movq %%rsp,%a0(%%r11) \n"              // Save user stack
    //    "movq %%rcx,%a2(%%r11) \n"              // Save instruction pointer
    //    "movq %a1(%%r11),%%rsp \n"              // Switch to kernel stack
    //    "movq %%rsp,%%rbp \n"                   // Might be unnecessary?
    //    "movq %%r10,%%rcx \n"                   // r10 contains arg3 (Syscall ABI), mov it to rcx (System V call ABI)
    //    "call *%%rax \n"                        // Make call
    //    "mov %%gs:0,%%r11 \n"
    //    "movq %a0(%%r11),%%rsp \n"              // Restore user stack, return address, flags
    //    "popq %%r11 \n"
    //    "popq %%rcx \n"
    //    "popq %%rbp \n"
    //    "sysretq \n"                            // Return rax;
    //    "_invalid_syscall: \n"
    //    "popq %%rdi \n"
    //    "pushq %%rbp \n"                        // Save rbp
    //    "pushq %%rcx \n"                        // Save return address
    //    "pushq %%r11 \n"                        // Save rflags
    //    "call invalid_syscall_msg \n"
    //    "popq %%r11 \n"                         // Restore rflags
    //    "popq %%rcx \n"                         // Restore return address
    //    "popq %%rbp \n"                         // Restore rbp
    //    "movq $0xffffffffffffffff,%%rax \n"     // Return -1;
    //    "sysretq"
    //    ::
    //    "i" (offsetof(ProcessorLocal, user_stack)),
    //    "i" (offsetof(ProcessorLocal, kernel_stack)),
    //    "i" (offsetof(ProcessorLocal, instruction_ptr)),
    //    "i" (RFLAGS_IF)
    //);

invalid_syscall:
    {
        register uint64_t result asm("%rax") = -1ll;

        USE(result);
        sysret();
    }
}

long _sys_read(unsigned int fd, char* buffer, size_t count) {
    ProcessorLocal* proc_local = proc_get_local();
    //kernel_warn("SYS READ: CPU: %u\n", proc_local->idx);

    if (count == 0) return -EINVAL;

    if (is_virt_addr_mapped_userspace(
            proc_local->current_task->process->addr_space.page_table,
            (uint64_t)buffer
        ) == FALSE) {
        return -EFAULT;
    }

    if (fd >= proc_local->current_task->process->files_capacity) {
        return -EBADF;
    }

    FileDescriptor* file = proc_local->current_task->process->files[fd];

    if (file == NULL || (file->mode & O_WRONLY) != 0) return -EBADF;

    const uint32_t readed = vfs_read(file->dentry, file->cursor_offset, count, (void*)buffer);

    file->cursor_offset += readed;

    return readed;
}

long _sys_write(unsigned int fd, const char* buffer, size_t count) {
    ProcessorLocal* proc_local = proc_get_local();
    //kernel_warn("SYS WRITE: CPU: %u: fd: %u: buffer: %x - %u bytes\n", proc_local->idx, fd, buffer, count);

    if (count == 0) return -EINVAL;

    if (is_virt_addr_mapped_userspace(
            proc_local->current_task->process->addr_space.page_table,
            (uint64_t)buffer
        ) == FALSE) {
        return -EFAULT;
    }

    if (fd >= proc_local->current_task->process->files_capacity) {
        return -EBADF;
    }

    FileDescriptor* file = proc_local->current_task->process->files[fd];

    if (file == NULL ||
        (file->mode & O_WRONLY || file->mode & O_RDWR) == 0) {
        return -EBADF;
    }

    const uint32_t writen = vfs_write(file->dentry, file->cursor_offset, count, buffer);

    file->cursor_offset += writen;

    return writen;
}

long _sys_open(const char* filename, int flags) {
    ProcessorLocal* proc_local = proc_get_local();
    //kernel_warn("SYS OPEN: CPU %x: %u: %x:%s, %u\n", proc_local, proc_local->idx, filename, filename, flags);

    //if (filename[0] == '\0') raw_hexdump(filename, 16);

    if (((flags & O_WRONLY) && (flags & O_RDWR)) ||
        is_virt_addr_mapped_userspace(
            proc_local->current_task->process->addr_space.page_table,
            (const uint64_t)filename
        ) == FALSE) {
        return -EINVAL;
    }

    long result = fd_open(
        proc_local->current_task->process,
        filename,
        flags
    );

    //raw_hexdump((uint64_t)proc_local->instruction_ptr & (~0xFFull), 32);
    //kernel_warn("SYS OPEN: result: %i: ret: %x\n", result, proc_local->instruction_ptr);

    return result;
}

long _sys_close(unsigned int fd) {
    ProcessorLocal* proc_local = proc_get_local();

    return (fd_close(proc_local->current_task->process, fd) ? 0 : -EBADF);
}

long _sys_mmap(const void* address, size_t length, int protection, int flags, int fd, uint32_t offset) {
    UNUSED(fd); UNUSED(offset);

    ProcessorLocal* proc_local = proc_get_local();
    //kernel_warn("SYS MMAP: CPU: %u: %x; %x; %u; %u; %u; %u\n", proc_local->idx,
    //    address, length, protection, flags, fd, offset);

    if (address != NULL || length == 0 ||
        protection == PROT_NONE ||
        (protection & PROT_READ) == 0 ||
        flags != (MAP_ANONYMOUS | MAP_PRIVATE)) {
        return -EINVAL;
    }

    VMPageFrameNode* frame_node = proc_push_vm_page(proc_local->current_task->process);

    if (frame_node == NULL) return -ENOMEM;

    frame_node->frame = vm_alloc_pages(
        div_with_roundup(length, PAGE_BYTE_SIZE),
        &proc_local->current_task->process->addr_space.heap,
        proc_local->current_task->process->addr_space.page_table,
        (
            VMMAP_USER_ACCESS |
            ((protection & PROT_WRITE) ? VMMAP_WRITE : 0) |
            ((protection & PROT_EXEC) ? VMMAP_EXEC : 0)
        )
    );

    if (frame_node->frame.count == 0) {
        proc_dealloc_vm_page(proc_local->current_task->process, frame_node);
        return -ENOMEM;
    }

    return (long)frame_node->frame.virt_address;
}

long _sys_munmap(void* address, size_t length) {
    if (address == NULL || length == 0) return -EINVAL;

    ProcessorLocal* proc_local = proc_get_local();

    spin_lock(&proc_local->current_task->process->vm_lock);

    VMPageFrameNode* frame_node = (VMPageFrameNode*)proc_local->current_task->process->vm_pages.next;

    while (frame_node != NULL &&
        frame_node->frame.virt_address != (uint64_t)address) {
        frame_node = frame_node->next;
    }

    spin_release(&proc_local->current_task->process->vm_lock);

    if (frame_node == NULL) return -EINVAL;
    
    uint32_t pages_count = div_with_roundup(length, PAGE_BYTE_SIZE);

    if (pages_count != frame_node->frame.count) return -EINVAL;

    proc_dealloc_vm_page(proc_local->current_task->process, frame_node);

    return 0;
}

long _sys_brk(uint64_t brk) {
    UNUSED(brk);

    return -ENOMEM;
}

long _sys_pread64(unsigned int fd, char* buffer, size_t count, int64_t offset) {
    ProcessorLocal* proc_local = proc_get_local();

    if (count == 0) return -EINVAL;
    if (is_virt_addr_mapped_userspace(
            proc_local->current_task->process->addr_space.page_table,
            (uint64_t)buffer
        ) == FALSE) {
        return -EFAULT;
    }

    if (fd >= proc_local->current_task->process->files_capacity) {
        return -EBADF;
    }

    FileDescriptor* file = proc_local->current_task->process->files[fd];

    if (file == NULL || (file->mode & O_WRONLY) != 0) return -EBADF;
    if (offset >= (int64_t)file->dentry->inode->file_size) return 0;

    const uint32_t readed = vfs_read(file->dentry, offset, count, (void*)buffer);

    return readed;
}

long _sys_pwrite64(unsigned int fd, const char* buffer, size_t count, int64_t offset) {
    ProcessorLocal* proc_local = proc_get_local();

    if (count == 0) return -EINVAL;
    if (is_virt_addr_mapped_userspace(
            proc_local->current_task->process->addr_space.page_table,
            (uint64_t)buffer
        ) == FALSE) {
        return -EFAULT;
    }

    if (fd >= proc_local->current_task->process->files_capacity) {
        return -EBADF;
    }

    FileDescriptor* file = proc_local->current_task->process->files[fd];

    if (file == NULL ||
        (file->mode & O_WRONLY || file->mode & O_RDWR) == 0) {
        return -EBADF;
    }

    const uint32_t writen = vfs_write(file->dentry, offset, count, (const void*)buffer);

    return writen;
}

long _sys_access(const char* pathname, int mode) {
    ProcessorLocal* proc_local = proc_get_local();

    if (is_virt_addr_mapped_userspace(
            proc_local->current_task->process->addr_space.page_table,
            (const uint64_t)pathname
        ) == FALSE) {
        return -EFAULT;
    }

    const VfsDentry* dentry = vfs_open(pathname, proc_local->current_task->process->work_dir);

    if (dentry == NULL) return -ENOENT;
    if (mode == F_OK) return 0;
    if (((int)dentry->inode->mode & mode) == mode) return 0;

    return -EACCES;
}

long _sys_getdents(unsigned int fd, struct dirent* dirent, unsigned int count) {
    ProcessorLocal* proc_local = proc_get_local();

    if (is_virt_addr_mapped_userspace(
            proc_local->current_task->process->addr_space.page_table,
            (uint64_t)dirent
        ) == FALSE) {
        return -EFAULT;
    }

    if ((count / sizeof(struct dirent)) == 0 || count == 0) {
        return -EINVAL;
    }

    if (fd >= proc_local->current_task->process->files_capacity) {
        return -EBADF;
    }

    FileDescriptor* file = proc_local->current_task->process->files[fd];

    if (file == NULL) return -EBADF;

    VfsDentry* dentry = file->dentry;

    if (dentry->inode->type != VFS_TYPE_DIRECTORY) {
        return -ENOTDIR;
    }
    if (dentry->childs == NULL && dentry->interface.fill_dentry != NULL) {
        dentry->interface.fill_dentry(dentry);
    }

    uint32_t result = 0;
    uint32_t current_offset = 0;

    uint8_t* buffer = (uint8_t*)dirent;

    for (uint32_t i = file->cursor_offset; i < count / sizeof(struct dirent) && dentry->childs[i] != NULL; ++i) {
        struct dirent* entry = (struct dirent*)(buffer + current_offset);

        const uint32_t name_len = strlen(dentry->childs[i]->name);

        entry->d_ino = dentry->childs[i]->inode->index;
        entry->d_reclen = ALIGN(
            offsetof(struct dirent, d_name) + name_len + 1,
            sizeof(long)
        );
        entry->d_off = entry->d_reclen;
        memcpy(dentry->childs[i]->name, entry->d_name, name_len);

        current_offset += entry->d_off;
        result += entry->d_reclen;
        file->cursor_offset++;
    }

    return result;
}

long _sys_getcwd(char* buffer, size_t length) {
    if (length == 0) return -EINVAL;

    ProcessorLocal* proc_local = proc_get_local();

    if (is_virt_addr_mapped_userspace(
            proc_local->current_task->process->addr_space.page_table,
            (uint64_t)buffer
        ) == FALSE) {
        return -EFAULT;
    }

    if (proc_local->current_task->process->work_dir == NULL) {
        buffer[0] = '/';
        buffer[1] = '\0';
    }
    else {
        vfs_get_path(proc_local->current_task->process->work_dir, buffer);
    }

    return (long)buffer;
}

long _sys_chdir(const char* path) {
    ProcessorLocal* proc_local = proc_get_local();

    if (is_virt_addr_mapped_userspace(
            proc_local->current_task->process->addr_space.page_table,
            (uint64_t)path
        ) == FALSE) {
        return -EFAULT;
    }

    VfsDentry* dentry = vfs_open(path, proc_local->current_task->process->work_dir);

    if (dentry == NULL) return -ENOENT;
    if (dentry->inode->type != VFS_TYPE_DIRECTORY) return -ENOTDIR;

    proc_local->current_task->process->work_dir = dentry;

    return 0;
}

long _sys_fchdir(unsigned int fd) {
    ProcessorLocal* proc_local = proc_get_local();

    if (fd >= proc_local->current_task->process->files_capacity) return -EBADF;

    FileDescriptor* file = proc_local->current_task->process->files[fd];

    if (file == NULL) return -EBADF;
    if (file->dentry->inode->type != VFS_TYPE_DIRECTORY) return -ENOTDIR;

    proc_local->current_task->process->work_dir = file->dentry;

    return 0;
}

pid_t _sys_getpid() {
    return proc_get_local()->current_task->process->pid;
}

pid_t _sys_getppid() {
    return proc_get_local()->current_task->process->parent->pid;
}

long _sys_arch_prctl(int code, const uint64_t address) {
    const ProcessorLocal* proc_local = proc_get_local();

    const bool_t is_mapped = is_virt_addr_mapped_userspace(
        proc_local->current_task->process->addr_space.page_table,
        address
    );

    kernel_msg("CODE: %x\n", code);

    bool_t is_get = FALSE;
    uint64_t value = 0;

    switch (code)
    {
    case ARCH_GET_CPUID:
        is_get = TRUE; value = proc_local->idx;
        break;
    case ARCH_GET_FS:
        is_get = TRUE; value = cpu_get_fs();
        break;
    case ARCH_SET_FS:
        if (is_mapped) cpu_set_msr(MSR_FG_BASE, address);
        else return -EPERM;
        break;
    case ARCH_GET_GS:
    case ARCH_SET_GS:
        kernel_msg("TRY TO GET/SET GS: %x\n", address);
    default:
        return -EINVAL;
        break;
    }

    if (is_get) {
        if (is_mapped == FALSE) return -EFAULT;

        *((uint64_t*)address) = value;
    }

    return 0;
}

void init_syscalls() {
    syscall_table[SYS_READ]     = (void*)&_sys_read;
    syscall_table[SYS_WRITE]    = (void*)&_sys_write;
    syscall_table[SYS_OPEN]     = (void*)&_sys_open;
    syscall_table[SYS_CLOSE]    = (void*)&_sys_close;

    syscall_table[SYS_MMAP]     = (void*)&_sys_mmap;

    syscall_table[SYS_MUNMAP]   = (void*)&_sys_munmap;
    syscall_table[SYS_BRK]      = (void*)&_sys_brk;

    syscall_table[SYS_PREAD64]  = (void*)&_sys_pread64;
    syscall_table[SYS_PWRITE64] = (void*)&_sys_pwrite64;

    syscall_table[SYS_ACCESS]   = (void*)&_sys_access;

    syscall_table[SYS_GETPID]   = (void*)&_sys_getpid;

    syscall_table[SYS_CLONE]    = (void*)&_sys_clone;
    syscall_table[SYS_FORK]     = (void*)&_sys_fork;
    syscall_table[SYS_EXECVE]   = (void*)&_sys_execve;
    syscall_table[SYS_EXIT]     = (void*)&_sys_exit;
    syscall_table[SYS_WAIT4]    = (void*)&_sys_wait4;

    syscall_table[SYS_GETDENTS] = (void*)&_sys_getdents;
    syscall_table[SYS_GETCWD]   = (void*)&_sys_getcwd;
    syscall_table[SYS_CHDIR]    = (void*)&_sys_chdir;
    syscall_table[SYS_FCHDIR]   = (void*)&_sys_fchdir;

    syscall_table[SYS_GETPPID]  = (void*)&_sys_getppid;

    syscall_table[SYS_ARCH_PRCTL] = (void*)&_sys_arch_prctl;
}
