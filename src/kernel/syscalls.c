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
#include "libc/sys/uio.h"

#include "proc/local.h"
#include "proc/proc.h"

#include "vm/buddy_page_alloc.h"

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
        asm volatile("push %rax");
        asm volatile("mov syscall_table(,%1,8),%0":"=r"(syscall):"r"(syscall));

        if (syscall == 0) {
            asm volatile("pop %rax");
            store_syscall_frame();
            invalid_syscall_msg(syscall);
            restore_syscall_frame();
            goto invalid_syscall;
        }

        asm volatile("add $8,%rsp");

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
    Process* const process = proc_get_local()->current_task->process;
    kernel_warn("SYS OPEN: %x:%s, %u\n", filename, filename, flags);

    //if (filename[0] == '\0') raw_hexdump(filename, 16);

    if (is_virt_addr_mapped_userspace(
            process->addr_space.page_table,
            (uint64_t)filename) == FALSE
        )
    {
        return -EFAULT;
    }

    if ((flags & O_WRONLY) && (flags & O_RDWR)) return -EINVAL;

    long result = fd_open(process, NULL, filename, flags);

    //raw_hexdump((uint64_t)proc_local->instruction_ptr & (~0xFFull), 32);
    //kernel_warn("SYS OPEN: result: %i: ret: %x\n", result, proc_local->instruction_ptr);

    return result;
}

long _sys_close(unsigned int fd) {
    ProcessorLocal* proc_local = proc_get_local();

    return (fd_close(proc_local->current_task->process, fd) ? 0 : -EBADF);
}

static inline bool_t is_addr_in_range(const uint64_t address, const uint64_t length, const uint64_t base, const uint32_t pages_count) {
    return address >= base && (address + length) <= (base + ((uint64_t)pages_count * PAGE_BYTE_SIZE));
}

long _sys_mmap(const void* address, size_t length, int protection, int flags, int fd, uint32_t offset) {
    Process* const process = proc_get_local()->current_task->process;
    kernel_warn("SYS MMAP: %x; %x; %u; %u; %u; %u\n",
        address, length, protection, flags, fd, offset);

    if (length == 0 ||
        protection == PROT_NONE ||
        (protection & (PROT_READ | PROT_EXEC)) == 0 ||
        (flags & (MAP_ANONYMOUS | MAP_PRIVATE | MAP_FIXED) == 0)) {
        return -EINVAL;
    }

    VMPageFrameNode* frame_node;
    const uint32_t pages_count = div_with_roundup(length, PAGE_BYTE_SIZE);
    const uint32_t map_flags = (
        VMMAP_USER_ACCESS |
        ((protection & PROT_WRITE) ? VMMAP_WRITE : 0) |
        ((protection & PROT_EXEC) ? VMMAP_EXEC : 0)
    );
    bool_t need_ctrl = FALSE;

    if (address == NULL) {
        frame_node = proc_push_vm_page(process);
        if (frame_node == NULL) return -ENOMEM;

        if ((flags & MAP_ANONYMOUS) == 0 && (protection & PROT_WRITE) == 0) need_ctrl = TRUE;

        frame_node->frame = vm_alloc_pages(
            pages_count,
            &process->addr_space.heap,
            process->addr_space.page_table,
            need_ctrl ? VMMAP_WRITE : map_flags
        );

        if (frame_node->frame.count == 0) {
            proc_dealloc_vm_page(process, frame_node);
            return -ENOMEM;
        }

        if (flags & MAP_ANONYMOUS) return (long)frame_node->frame.virt_address;
    }
    else {
        if ((uint64_t)address + length > process->addr_space.heap.virt_top ||
            (uint64_t)address < process->addr_space.heap.virt_base ||
            is_virt_addr_range_mapped((uint64_t)address, div_with_roundup(length, PAGE_BYTE_SIZE)) == FALSE)
            return -EINVAL;

        frame_node = (void*)process->vm_pages.next;

        do {
            if (is_addr_in_range((uint64_t)address, length, frame_node->frame.virt_address, frame_node->frame.count)) {
                break;
            }

            frame_node = frame_node->next;
        } while (frame_node != NULL);

        if (frame_node == NULL) return -EINVAL;

        if (frame_node->frame.flags != map_flags) {
            if ((map_flags & VMMAP_WRITE) != 0) {
                vm_map_ctrl((uint64_t)address, process->addr_space.page_table, pages_count, map_flags);
            }
            else {
                need_ctrl = TRUE;

                if ((frame_node->frame.flags & VMMAP_WRITE) == 0) {
                    vm_map_ctrl(address, process->addr_space.page_table, pages_count, VMMAP_WRITE);
                }
            }
        }
        else if ((frame_node->frame.flags & VMMAP_WRITE) == 0) {
            need_ctrl = TRUE;
            vm_map_ctrl(address, process->addr_space.page_table, pages_count, VMMAP_WRITE);
        }
    }

    long result = -EBADFD;
    if (fd < 0 || fd >= process->files_capacity) goto out_fail;

    const FileDescriptor* file = process->files[fd];
    if (file == NULL || file->dentry->inode->type != VFS_TYPE_FILE) goto out_fail;

    const uint64_t inner_offset = (address != NULL) ? address - frame_node->frame.virt_address : 0;
    const uint64_t result_addr = frame_node->frame.virt_address + inner_offset;

    vfs_read(file->dentry, offset, length, (void*)result_addr);

    if (need_ctrl) {
        vm_map_ctrl(result_addr, process->addr_space.page_table, pages_count, map_flags);
    }

    kernel_warn("MMAP: %x\n", result_addr);
    return (long)result_addr;

out_fail:
    if (address == NULL) {
        vm_free_pages(&frame_node->frame, &process->addr_space.heap, process->addr_space.page_table);
        proc_dealloc_vm_page(process, frame_node);
    }
    kernel_warn("MMAP: %u\n", result);
    return result;
}

long _sys_munmap(void* address, size_t length) {
    if (address == NULL || length == 0) return -EINVAL;

    Process* const process = proc_get_local()->current_task->process;

    spin_lock(&process->vm_lock);

    VMPageFrameNode* frame_node = (VMPageFrameNode*)process->vm_pages.next;

    while (frame_node != NULL &&
        frame_node->frame.virt_address != (uint64_t)address) {
        frame_node = frame_node->next;
    }

    spin_release(&process->vm_lock);

    if (frame_node == NULL) return -EINVAL;
    
    uint32_t pages_count = div_with_roundup(length, PAGE_BYTE_SIZE);

    if (pages_count != frame_node->frame.count) return -EINVAL;

    proc_dealloc_vm_page(process, frame_node);

    return 0;
}

uint64_t _sys_brk(uint64_t brk) {
    kernel_warn("SYS BRK: %x\n", brk);

    Process* const process = proc_get_local()->current_task->process;

    VMMemoryBlockNode* const last_seg = (void*)
        process->addr_space.interp_seg == NULL ?
        process->addr_space.segments.prev : process->addr_space.interp_seg->prev;

    const uint64_t curr_brk = last_seg->block.virt_address + 
        ((uint64_t)last_seg->block.pages_count * PAGE_BYTE_SIZE);

    if (brk == 0) return curr_brk;

    const int64_t diff = brk - curr_brk;

    if (diff == 0) return brk;
    if (diff < 0) return 0;

    const uint32_t pages_count = div_with_roundup(diff, PAGE_BYTE_SIZE);
    const uint32_t page_base = bpa_allocate_pages(log2upper(pages_count)) / PAGE_BYTE_SIZE;

    if (page_base == 0) return -ENOMEM;

    VMMemoryBlockNode* const new_brk_seg = proc_insert_segment(process, last_seg);

    new_brk_seg->block.virt_address = curr_brk;
    new_brk_seg->block.pages_count = pages_count;
    new_brk_seg->block.page_base = page_base;

    vm_map_phys_to_virt((uint64_t)page_base * PAGE_BYTE_SIZE, curr_brk, pages_count, VMMAP_USER_ACCESS | VMMAP_WRITE);

    return curr_brk + ((uint64_t)pages_count * PAGE_BYTE_SIZE);
}

long _sys_pread64(unsigned int fd, char* buffer, size_t count, int64_t offset) {
    Process* const process = proc_get_local()->current_task->process;

    if (count == 0) return -EINVAL;
    if (is_virt_addr_mapped_userspace(
            process->addr_space.page_table,
            (uint64_t)buffer
        ) == FALSE) {
        return -EFAULT;
    }

    if (fd >= process->files_capacity) return -EBADF;

    FileDescriptor* file = process->files[fd];

    if (file == NULL || (file->mode & O_WRONLY) != 0) return -EBADF;
    if (offset >= (int64_t)file->dentry->inode->file_size) return 0;

    const uint32_t readed = vfs_read(file->dentry, offset, count, (void*)buffer);

    return readed;
}

long _sys_pwrite64(unsigned int fd, const char* buffer, size_t count, int64_t offset) {
    Process* const process = proc_get_local()->current_task->process;

    if (count == 0) return -EINVAL;
    if (is_virt_addr_mapped_userspace(
           process->addr_space.page_table,
            (uint64_t)buffer
        ) == FALSE) {
        return -EFAULT;
    }

    if (fd >= process->files_capacity) return -EBADF;

    FileDescriptor* const file = process->files[fd];

    if (file == NULL ||
        (file->mode & O_WRONLY || file->mode & O_RDWR) == 0) {
        return -EBADF;
    }

    const uint32_t writen = vfs_write(file->dentry, offset, count, (const void*)buffer);

    return writen;
}

long _sys_writev(int fd, const iovec* io_vec, int io_count) {
    Process* const process = proc_get_local()->current_task->process;

    if (io_count <= 0 || io_count > INT16_MAX) return -EINVAL;
    if (io_vec == NULL ||
        is_virt_addr_mapped_userspace(
            process->addr_space.page_table, (uint64_t)io_vec
        ) == FALSE) return -EFAULT;

    if (fd >= process->files_capacity) return -EBADF;

    FileDescriptor* const file = process->files[fd];

    if (file == NULL ||
        (file->mode & O_WRONLY || file->mode & O_RDWR) == 0) {
        return -EBADF;
    }

    size_t total_size = 0;

    for (int i = 0; i < io_count; ++i) {
        if (is_virt_addr_mapped_userspace(
            process->addr_space.page_table,
            (uint64_t)io_vec[i].iov_base
        ) == FALSE) return -EFAULT;

        total_size += io_vec[i].iov_len;
    }

    if (total_size > INT64_MAX) return -EINVAL;

    uint32_t total_writen = 0;

    for (int i = 0; i < io_count; ++i) {
        const uint32_t writen = vfs_write(file->dentry, file->cursor_offset, io_vec[i].iov_len, io_vec[i].iov_base);

        file->cursor_offset += writen;
        total_writen += writen;
    }

    return total_writen;
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
    kernel_warn("SYS ARCH_PRCTL: CODE: %x\n", code);

    const ProcessorLocal* proc_local = proc_get_local();
    const bool_t is_mapped = is_virt_addr_mapped_userspace(
        proc_local->current_task->process->addr_space.page_table,
        address
    );

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

long _sys_openat(int dir_fd, const char* pathname, int flags, mode_t mode) {
    kernel_warn("SYS OPENAT: %u: %s: %u: %u\n", dir_fd, pathname, flags, mode);

    Process* const process = proc_get_local()->current_task->process;

    const VfsDentry* dir_dentry;

    if (dir_fd == AT_FDCWD) {
        dir_dentry = process->work_dir;
    }
    else {
        if (dir_fd >= process->files_capacity) return -EBADF;
        const FileDescriptor* dir = process->files[dir_fd];

        if (dir == NULL || dir->dentry->inode->type != VFS_TYPE_DIRECTORY) return -EBADF;
        dir_dentry = dir->dentry;
    }

    if (is_virt_addr_mapped_userspace(
            process->addr_space.page_table, 
            (uint64_t)pathname
        ) == FALSE)
    {
        return -EFAULT;
    }

    long result = fd_open(process, dir_dentry, pathname, flags);

    return result;
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

    syscall_table[SYS_WRITEV]   = (void*)&_sys_writev;
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

    syscall_table[SYS_EXIT_GROUP] = (void*)&_sys_exit;

    syscall_table[SYS_OPENAT]   = (void*)&_sys_openat;
}
