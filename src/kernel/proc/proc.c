#include "proc.h"

#include <bootboot.h>

#include "assert.h"
#include "elf.h"
#include "local.h"
#include "logger.h"
#include "math.h"
#include "mem.h"
#include "task_scheduler.h"
#include "syscalls.h"

#include "cpu/spinlock.h"

#include "fs/vfs.h"

#include "vm/object_mem_alloc.h"
#include "vm/buddy_page_alloc.h"

#include "utils/string_utils.h"

#include "libc/errno.h"
#include "libc/fcntl.h"

#define INIT_PROC_FILENAME "/usr/bin/init"
#define ENVIRONS_FILENAME  "/etc/environment"

extern BOOTBOOT bootboot;

// Statically allocated space for 'g_proc_local'
ATTR_ALIGN(PAGE_BYTE_SIZE)
ProcessorLocal g_proc_local;

static ProcessorLocal* proc_local_buffer = NULL;
static ProcessorLocal** proc_local_ptrs = NULL;

static ObjectMemoryAllocator* proc_oma = NULL;
static ObjectMemoryAllocator* seg_oma = NULL;
static ObjectMemoryAllocator* page_frame_oma = NULL;

static pid_t last_pid = 0;
static Spinlock pid_lock = { .exclusion = 0 };

static Process* init_proc = NULL;

bool_t init_proc_local() {
    kassert(sizeof(ProcessorLocal) == PAGE_BYTE_SIZE);

    proc_local_ptrs = (ProcessorLocal**)kmalloc(bootboot.numcores * sizeof(ProcessorLocal*));
    proc_local_buffer = (ProcessorLocal*)bpa_allocate_pages(log2upper(bootboot.numcores));

    if (proc_local_buffer == NULL) return FALSE;

    for (uint32_t i = 0; i < (uint32_t)bootboot.numcores; ++i) {
        proc_local_buffer[i].idx = i;
        proc_local_buffer[i].kernel_page_table = NULL;
        proc_local_buffer[i].current_task = NULL;
        proc_local_buffer[i].kernel_stack = NULL;
        proc_local_buffer[i].user_stack = NULL;

        proc_local_ptrs[i] = &proc_local_buffer[i];
    }

    return TRUE;
}

ProcessorLocal** _proc_get_local_ptr(const uint32_t cpu_idx) {
    return proc_local_ptrs + cpu_idx;
}

ProcessorLocal* _proc_get_local_data_by_idx(const uint32_t cpu_idx) {
    return proc_local_ptrs[cpu_idx];
}

pid_t proc_generate_id() {
    pid_t result;
    
    spin_lock(&pid_lock);
    result = ++last_pid;
    spin_release(&pid_lock);

    return result;
}

void proc_release_id(pid_t id) {
    spin_lock(&pid_lock);
    if (last_pid == id) --last_pid;
    spin_release(&pid_lock);
}

void log_process(const Process* process) {
    kernel_warn("Process: %x\n", process);

    if (process == NULL) return;

    kernel_msg("Pid: %u\n", process->pid);
    kernel_msg("Parent (%u): %x\n", process->parent->pid, process->parent);

    Process* child = (void*)process->childs.next;

    while (child != NULL) {
        kernel_msg("   child (%u): %x\n", child->pid, child);
        child = child->next;
    }

    char buffer[256] = { '\0' };

    if (process->work_dir != NULL) vfs_get_path(process->work_dir, buffer);
    else buffer[0] = '~';

    kernel_msg("Work dir (%x): %s\n", process->work_dir, buffer);
    kernel_msg("Page table: %x\n", process->addr_space.page_table);
    kernel_msg("Segments:\n");

    VMMemoryBlockNode* segment = (void*)process->addr_space.segments.next;

    while (segment != NULL) {
        kernel_msg("   seg(%x): %x : %x, %u KB\n", 
            segment,
            segment->block.virt_address,
            (uint64_t)segment->block.page_base * PAGE_BYTE_SIZE,
            segment->block.pages_count * (PAGE_BYTE_SIZE / KB_SIZE)
        );

        segment = segment->next;
    }

    log_heap(&process->addr_space.heap);

    kernel_msg("VM Pages:\n");

    VMPageFrameNode* page = (void*)process->vm_pages.next;

    while (page != NULL) {
        kernel_msg("  page: %x : ", page->frame.virt_address);

        VMPageList* phys_page = (void*)page->frame.phys_pages.next;

        while (phys_page != NULL) {
            raw_print_number((uint64_t)phys_page->phys_page_base * PAGE_BYTE_SIZE, FALSE, 16);
            raw_puts(", ");

            phys_page = phys_page->next;
        }

        raw_print_number((uint32_t)page->frame.count * (PAGE_BYTE_SIZE / KB_SIZE), FALSE, 10);
        raw_puts(" KB\n");

        page = page->next;
    }
}

static uint32_t count_strings(const char** strings) {
    uint32_t result = 0;

    while (*(strings++) != NULL) result++;

    return result;
}

static char** load_environs(uint32_t* const count) {
    VfsDentry* dentry = vfs_open(ENVIRONS_FILENAME, NULL);

    if (dentry == NULL || dentry->inode->type != VFS_TYPE_FILE) return NULL;
    if (dentry->inode->file_size < 3) return NULL;

    char* buffer = (char*)kmalloc(dentry->inode->file_size + 1);

    if (buffer == NULL) return NULL;
    if (vfs_read(dentry, 0, dentry->inode->file_size, (void*)buffer) != dentry->inode->file_size) {
        kfree(buffer);
        return NULL;
    }

    *count = 0;
    char** envp = (char**)kmalloc(sizeof(char*));

    for (uint32_t i = 0; i < dentry->inode->file_size - 1; ++i) {
        char* var = &buffer[i];
        bool_t is_valid = buffer[i] != '\0' && buffer[i] != '\n';

        while(buffer[i] != '\0' && buffer[i] != '\n') {
            if (isspace(buffer[i])) is_valid = FALSE;
            i++;
        }

        if (is_valid) {
            (*count)++;

            char** new_envp = krealloc(envp, (*count + 1) * sizeof(char*));

            if (new_envp == NULL) {
                kfree(buffer);
                kfree(envp);

                *count = 0;
                return NULL;
            }
    
            envp = new_envp;
            envp[*count - 1] = var;
        }

        if (buffer[i] == '\0') break;

        buffer[i] = '\0';
    }

    envp[*count] = NULL;

    return envp;
}

static inline int proc_load_elf_file(ElfFile* const elf_file, const char* filename, const VfsDentry* parent_dir) {
    kernel_msg("Filename: %s: parent_dir: %x\n", filename, parent_dir);

    VfsDentry* file = vfs_open(filename, parent_dir);

    if (file == NULL) return -ENOENT;
    if (file->inode->type != VFS_TYPE_FILE || file->inode->file_size < 3) return -ENOEXEC;

    elf_file->dentry = file;

    int result = elf_read_file(elf_file);
    if (result < 0) return result;

    if (is_elf_valid_and_supported(elf_file->header) == FALSE) {
        elf_free_file(elf_file);
        return -ENOEXEC;
    }

    return 0;
}

static uint64_t proc_calc_brk(const VMMemoryBlockNode* last_seg) {
    const uint64_t result = last_seg->block.virt_address +
        (last_seg->block.pages_count * PAGE_BYTE_SIZE) + PROC_BRK_MAX_SIZE;

    return (result / GB_SIZE) * GB_SIZE;
}

static void proc_make_aux_vec(Task* const task, const char* prog_name, const ElfFile* const prog_elf) {
    const bool_t align = (task->thread.stack_ptr % 16) == 0;
    const uint32_t progs_size = prog_elf->header->prog_entries_count * prog_elf->header->prog_entry_size;
    const uint64_t ph_ptr = (task->thread.stack_ptr - progs_size) & (~0xFull);

    memcpy(prog_elf->progs, (void*)ph_ptr, progs_size);

    const uint32_t name_len = strlen(prog_name) + 1;
    const uint64_t fn_ptr = (ph_ptr - name_len) & (~0xFull);
    memcpy(prog_name, (void*)fn_ptr, name_len);

    task->thread.stack_ptr = fn_ptr - (align ? 0 : 8);

    proc_add_aux(&task->thread, AT_NULL, 0);

    proc_add_aux(&task->thread, AT_SECURE, 0);
    proc_add_aux(&task->thread, AT_FLAGS, 0);

    proc_add_aux(&task->thread, AT_GID, 0);
    proc_add_aux(&task->thread, AT_UID, 0);
    proc_add_aux(&task->thread, AT_EGID, 0);
    proc_add_aux(&task->thread, AT_EUID, 0);

    proc_add_aux(&task->thread, AT_PAGESZ, PAGE_BYTE_SIZE);

    if (task->process->addr_space.interp_seg != NULL) {
        proc_add_aux(&task->thread, AT_BASE, task->process->addr_space.interp_seg->block.virt_address);
    }
    else {
        proc_add_aux(&task->thread, AT_BASE, prog_elf->load_base);
    }

    proc_add_aux(&task->thread, AT_ENTRY, prog_elf->header->entry + prog_elf->load_base);

    proc_add_aux(&task->thread, AT_PHNUM, prog_elf->header->prog_entries_count);
    proc_add_aux(&task->thread, AT_PHENT, prog_elf->header->prog_entry_size);

    proc_add_aux(&task->thread, AT_PHDR, ph_ptr);
    proc_add_aux(&task->thread, AT_EXECFN, fn_ptr);
}

static int proc_load_elf_interp(const char* filename, Task* const task) {
    ElfFile elf_file;

    int result = proc_load_elf_file(&elf_file, filename, task->process->work_dir);
    if (result < 0) return (result == -ENOEXEC) ? -ELIBBAD : result;

    const VMMemoryBlockNode* last_proc_seg = (void*)task->process->addr_space.segments.prev;

    elf_file.load_base = proc_calc_brk(last_proc_seg);

    if (elf_load(&elf_file, task->process) < 0) result = (result == -ENOEXEC) ? -ELIBBAD : result;
    else {
        task->process->addr_space.interp_seg = last_proc_seg->next;
        task->ip = elf_file.header->entry + elf_file.load_base;
    }

    elf_free_file(&elf_file);
    return result;
}

int proc_load_from_elf(const char* filename, Task* const task) {
    ElfFile elf_file;
    elf_file.load_base = USER_SPACE_ADDR_BEGIN;

    int result = proc_load_elf_file(&elf_file, filename, task->process->work_dir);
    if (result < 0) return result;

    // Find interpreter
    const ElfProgramHeader* interp = elf_find_prog(&elf_file, ELF_PROG_TYPE_INTERP);

    char interp_str[256] = { '\0' };
    if (interp) {
        result = -ENOEXEC;
        if (interp->file_size > 256) goto out_free_elf;

        result = -EIO;
        if (vfs_read(elf_file.dentry, interp->offset, interp->file_size, (void*)interp_str) < interp->file_size) goto out_free_elf;
    }

    // Load program
    result = elf_load(&elf_file, task->process);
    task->ip = elf_file.header->entry + elf_file.load_base;

    if (interp != NULL && strcmp(interp_str, ELF_INTERP_IGNORE) != 0) {
        result = proc_load_elf_interp(interp_str, task);

        if (result < 0) proc_clear_segments(task->process);
    }

    if (result == 0) proc_make_aux_vec(task, filename, &elf_file);

out_free_elf:
    elf_free_file(&elf_file);
    return result;
}

static void proc_files_close_on_exec(Process* const process) {
    for (uint32_t i = 0; i < process->files_capacity; ++i) {
        FileDescriptor* const file = process->files[i];

        if (file == NULL) continue;
        if (file->mode & O_CLOEXEC) fd_close(process, i);
    }
}

static void proc_construct_heap(Process* const process) {
    const VMMemoryBlockNode* last_seg =
        (VMMemoryBlockNode*)process->addr_space.segments.prev;

    const uint64_t virt_base = (process->addr_space.interp_seg == NULL) ?
        proc_calc_brk(last_seg) : (last_seg->block.virt_address + 
        ((uint64_t)last_seg->block.pages_count * PAGE_BYTE_SIZE) + PAGE_BYTE_SIZE);

    vm_heap_construct(&process->addr_space.heap, virt_base);
}

static ExecutionState* proc_make_exec_frame(uint64_t stack_ptr, const uint64_t entry_ptr,
    const char** envp, const uint32_t env_count,
    const char** argv, const uint32_t arg_count
) {
    // Complete auxiliary vector
    uint64_t* const env_vec = ((uint64_t*)stack_ptr) - (env_count + 1);
    env_vec[env_count] = 0;
    if (envp) memcpy(envp, env_vec, env_count * sizeof(char*));

    uint64_t* const arg_vec = env_vec - (arg_count + 2);
    arg_vec[arg_count + 1] = 0;
    arg_vec[0] = arg_count;
    if (argv) memcpy(argv, arg_vec + 1, arg_count * sizeof(char*));

    stack_ptr = (uint64_t)arg_vec;

    kernel_msg("stack: %x: argc: %u envc: %u\n", stack_ptr, arg_count, env_count);
    kassert((stack_ptr % 16) == 0);

    // Make syscall frame
    stack_ptr -= sizeof(SyscallFrame);
    SyscallFrame* const syscall_frame = (SyscallFrame*)stack_ptr;
    syscall_frame->rflags = get_rflags() | RFLAGS_IF;
    syscall_frame->rip = entry_ptr;

    // Init registers
    stack_ptr -= sizeof(ArgsRegs);
    ArgsRegs* const args_regs = (ArgsRegs*)stack_ptr;
    args_regs->arg0 = arg_count;
    args_regs->arg1 = (uint64_t)(arg_vec + 1);
    args_regs->arg2 = (uint64_t)env_vec;

    return (ExecutionState*)stack_ptr;
}

bool_t load_init_proc() {
    Process* const process = proc_new();

    if (process == NULL) {
        error_str = "Not enough memory";
        return FALSE;
    }

    Task* const task = tsk_new();

    if (task == NULL) {
        proc_delete(process);

        error_str = "Not enough memory";
        return FALSE;
    }

    task->process = process;

    vm_map_kernel(process->addr_space.page_table);
    cpu_set_pml4(process->addr_space.page_table);

    if (thread_allocate_stack(process, &task->thread) == FALSE) {
        proc_delete(process);
        tsk_delete(task);
        error_str = "Failed to allocate stack";
        return FALSE;
    }

    uint32_t env_count = 0;
    char** environs = load_environs(&env_count);

    uint64_t stack_ptr = thread_get_stack_top(&task->thread) & (~0xFull);
    char** env_ptr = proc_put_args_strings(&stack_ptr, environs, env_count);

    if (environs) {
        kfree(environs[0]);
        kfree(environs);
    }

    if ((env_count + 3) % 2 != 0) stack_ptr -= 8;
    task->thread.stack_ptr = stack_ptr;

    int result = proc_load_from_elf(INIT_PROC_FILENAME, task);

    if (result < 0) {
        thread_dealloc_stack(&task->thread);
        cpu_set_pml4(g_proc_local.kernel_page_table);
        proc_delete(process);
        tsk_delete(task);

        switch (-result) {
        case ENOENT:
            error_str = "'init' process executable file at path " INIT_PROC_FILENAME " not found";
            break;
        case ENOMEM:
            error_str = "Not enough memory to load program";
            break;
        case ENOEXEC:
            error_str = INIT_PROC_FILENAME ": Incorrect elf file format";
            break;
        default:
            error_str = "Something went wrog while loading process from ELF file";
            break;
        }

        return FALSE;
    }

    proc_construct_heap(process);

    task->thread.exec_state = proc_make_exec_frame(task->thread.stack_ptr, task->ip, env_ptr, env_count, NULL, 0);
    task->state = TSK_STATE_EXEC;

    kfree(env_ptr);

    init_proc = process;

    kernel_msg("Init process starting...\n");

    tsk_awake(task);

    return TRUE;
}

Process* proc_new() {
    if (proc_oma == NULL) {
        proc_oma = oma_new(sizeof(Process));

        if (proc_oma == NULL) return NULL;
    }

    Process* process = (Process*)oma_alloc(proc_oma);

    if (process != NULL) {
        memset(process, sizeof(Process), 0);

        process->pid = proc_generate_id();
        process->addr_space.page_table = vm_alloc_page_table();

        if (process->addr_space.page_table == NULL) {
            oma_free((void*)process, proc_oma);
            return NULL;
        }

        process->addr_space.lock = spinlock_init();
        process->files_lock = spinlock_init();
        process->vm_lock = spinlock_init();
    }

    return process;
}

void proc_delete(Process* process) {
    kassert(process != NULL);

    if (process->addr_space.page_table != NULL) {
        vm_free_page_table(process->addr_space.page_table);
    }

    proc_release_id(process->pid);

    oma_free((void*)process, proc_oma);
}

VMMemoryBlockNode* proc_push_segment(Process* const process) {
    kassert(process != NULL);

    if (seg_oma == NULL) {
        seg_oma = oma_new(sizeof(VMMemoryBlockNode));

        if (seg_oma == NULL) return NULL;
    }

    VMMemoryBlockNode* node = (VMMemoryBlockNode*)oma_alloc(seg_oma);

    if (node == NULL) return NULL;

    if (process->addr_space.segments.next == NULL) {
        node->prev = NULL;
        process->addr_space.segments.next = (void*)node;
    }
    else {
        node->prev = (void*)process->addr_space.segments.prev;
        process->addr_space.segments.prev->next = (void*)node;
    }

    node->next = NULL;
    process->addr_space.segments.prev = (void*)node;

    return node;
}

VMMemoryBlockNode* proc_insert_segment(Process* const process, VMMemoryBlockNode* const prev_seg) {
    kassert(seg_oma != NULL);

    VMMemoryBlockNode* node = (VMMemoryBlockNode*)oma_alloc(seg_oma);

    if (node == NULL) return NULL;

    if (process->addr_space.segments.prev == (void*)prev_seg) {
        node->next = NULL;
        process->addr_space.segments.prev = (void*)node;
    }
    else {
        node->next = prev_seg->next;
        prev_seg->next->prev = node;
    }

    node->prev = prev_seg;
    prev_seg->next = node;

    return node;
}

void proc_clear_segments(Process* const process) {
    kassert(process != NULL);

    while (process->addr_space.segments.next != NULL) {
        VMMemoryBlockNode* node = (void*)process->addr_space.segments.next;
        process->addr_space.segments.next = process->addr_space.segments.next->next;

        if (node->block.pages_count > 0) {
            vm_unmap(
                node->block.virt_address,
                process->addr_space.page_table,
                node->block.pages_count
            );
            bpa_free_pages(
                (uint64_t)node->block.page_base * PAGE_BYTE_SIZE,
                log2upper(node->block.pages_count)
            );
        }

        oma_free((void*)node, seg_oma);
    }

    process->addr_space.segments.prev = NULL;
}

bool_t proc_copy_segments(const Process* src_proc, Process* const dst_proc) {
    kassert(src_proc != NULL && dst_proc != NULL);

    const VMMemoryBlockNode* src_node = (void*)src_proc->addr_space.segments.next;

    while (src_node != NULL) {
        //kernel_warn("src: %x: size: %u KB\nseg[0x20]: %x\n",
        //    src_node->block.virt_address,
        //    src_node->block.pages_count * 4,
        //    ((uint8_t*)src_node->block.virt_address + 0x20)[0]
        //);

        VMMemoryBlockNode* curr_node = (VMMemoryBlockNode*)oma_alloc(seg_oma);

        if (curr_node == NULL) {
            proc_clear_segments(dst_proc);
            return FALSE;
        }

        curr_node->block = src_node->block;
        curr_node->block.page_base = bpa_allocate_pages(log2upper(curr_node->block.pages_count)) / PAGE_BYTE_SIZE;

        if (curr_node->block.page_base == 0) {
            oma_free((void*)curr_node, seg_oma);
            proc_clear_segments(dst_proc);
            return FALSE;
        }

        if (_vm_map_phys_to_virt(
                (uint64_t)curr_node->block.page_base * PAGE_BYTE_SIZE,
                curr_node->block.virt_address,
                dst_proc->addr_space.page_table,
                curr_node->block.pages_count,
                (VMMAP_EXEC | VMMAP_USER_ACCESS | VMMAP_WRITE)
            ) != KERNEL_OK) {
            oma_free((void*)curr_node, seg_oma);
            proc_clear_segments(dst_proc);
            return FALSE;
        }
        
        memcpy(
            (const void*)src_node->block.virt_address,
            (void*)((uint64_t)curr_node->block.page_base * PAGE_BYTE_SIZE),
            curr_node->block.pages_count * PAGE_BYTE_SIZE
        );

        curr_node->next = NULL;
        curr_node->prev = (void*)dst_proc->addr_space.segments.prev;

        if (curr_node->prev) curr_node->prev->next = curr_node;

        dst_proc->addr_space.segments.prev = (void*)curr_node;

        if (dst_proc->addr_space.segments.next == NULL) {
            dst_proc->addr_space.segments.next = (void*)curr_node;
        }

        src_node = src_node->next;
    }

    return TRUE;
}

bool_t proc_copy_files(const Process* src_proc, Process* const dst_proc) {
    if (src_proc->files_capacity == 0) return TRUE;

    dst_proc->files = (FileDescriptor**)kcalloc(sizeof(FileDescriptor*) * src_proc->files_capacity);

    if (dst_proc->files == NULL) return FALSE;

    dst_proc->files_capacity = src_proc->files_capacity;

    for (uint32_t i = 0; i < src_proc->files_capacity; ++i) {
        if (src_proc->files[i] == NULL) continue;

        dst_proc->files[i] = fd_new();

        if (dst_proc->files[i] == NULL) {
            proc_close_files(dst_proc);
            return FALSE;
        }

        *dst_proc->files[i] = *src_proc->files[i];
        dst_proc->files[i]->lock = spinlock_init();
    }

    return TRUE;
}

void proc_close_files(Process* const process) {
    if (process->files == NULL) return;

    for (uint32_t i = 0; i < process->files_capacity; ++i) {
        if (process->files[i] == NULL) continue;

        fd_close(process, i);
    }

    kfree((void*)process->files);

    process->files = NULL;
    process->files_capacity = 0;
}

VMPageFrameNode* proc_push_vm_page(Process* const process) {
    kassert(process != NULL);

    if (page_frame_oma == NULL) {
        page_frame_oma = oma_new(sizeof(VMPageFrameNode));

        if (page_frame_oma == NULL) return NULL;
    }

    VMPageFrameNode* node = (VMPageFrameNode*)oma_alloc(page_frame_oma);

    if (node == NULL) return NULL;

    node->next = NULL;

    spin_lock(&process->vm_lock);

    if (process->vm_pages.next == NULL) {
        node->prev = NULL;
        process->vm_pages.next = (ListHead*)node;
    }
    else {
        node->prev = (VMPageFrameNode*)process->vm_pages.prev;
        process->vm_pages.prev->next = (ListHead*)node;
    }

    process->vm_pages.prev = (ListHead*)node;

    spin_release(&process->vm_lock);

    return node;
}

static void proc_copy_vm_page_data(const VMPageFrameNode* src_frame, VMPageFrameNode* dst_frame, const PageMapLevel4Entry* dst_pml4) {
    for (uint32_t i = 0; i < src_frame->frame.count; ++i) {
        const uint64_t offset = (uint64_t)i * PAGE_BYTE_SIZE;
        const uint64_t dst_address = _get_phys_address(dst_pml4, dst_frame->frame.virt_address + offset);

        kassert(dst_address != INVALID_ADDRESS);
        memcpy((const void*)(src_frame->frame.virt_address + offset), (void*)dst_address, PAGE_BYTE_SIZE);
    }
}

bool_t proc_copy_vm_pages(Process* const src_proc, Process* const dst_proc) {
    dst_proc->addr_space.heap = vm_heap_copy(&src_proc->addr_space.heap);

    if (src_proc->vm_pages.next == NULL) return TRUE;

    spin_lock(&src_proc->vm_lock);

    const VMPageFrameNode* src_frame = (const void*)src_proc->vm_pages.next;

    while (src_frame != NULL) {
        VMPageFrameNode* dst_frame = (VMPageFrameNode*)oma_alloc(page_frame_oma);

        if (dst_frame == NULL) {
            spin_release(&src_proc->vm_lock);
            proc_dealloc_vm_pages(dst_proc);
            return FALSE;
        }

        dst_frame->frame = _vm_alloc_pages(
            src_frame->frame.count,
            src_frame->frame.virt_address,
            dst_proc->addr_space.page_table,
            src_frame->frame.flags
        );

        if (dst_frame->frame.count == 0) {
            spin_release(&src_proc->vm_lock);
            proc_dealloc_vm_pages(dst_proc);
            return FALSE;
        }

        //kernel_msg("Src vm: %x: dst vm: %x\n",
        //    ((VMPageList*)src_frame->frame.phys_pages.next)->phys_page_base * PAGE_BYTE_SIZE,
        //    ((VMPageList*)dst_frame->frame.phys_pages.next)->phys_page_base * PAGE_BYTE_SIZE
        //);

        proc_copy_vm_page_data(src_frame, dst_frame, dst_proc->addr_space.page_table);

        src_frame = src_frame->next;

        dst_frame->next = NULL;
        dst_frame->prev = (void*)dst_proc->vm_pages.prev;

        if (dst_frame->prev != NULL) dst_frame->prev->next = dst_frame;
        if (dst_proc->vm_pages.next == NULL) {
            dst_proc->vm_pages.next = (void*)dst_frame;
        }

        dst_proc->vm_pages.prev = (void*)dst_frame;
    }

    spin_release(&src_proc->vm_lock);

    return TRUE;
}

void proc_dealloc_vm_page(Process* const process, VMPageFrameNode* const page_frame) {
    kassert(process != NULL && page_frame != NULL);

    spin_lock(&process->vm_lock);

    if ((void*)page_frame == (void*)process->vm_pages.next) {
        if ((void*)page_frame == (void*)process->vm_pages.prev) {
            process->vm_pages.next = NULL;
            process->vm_pages.prev = NULL;
        }
        else {
            page_frame->next->prev = NULL;
            process->vm_pages.next = (void*)page_frame->next;
        }
    }
    else if ((void*)page_frame == (void*)process->vm_pages.prev) {
        page_frame->prev->next = NULL;
        process->vm_pages.prev = (void*)page_frame->prev;
    }
    else {
        page_frame->prev->next = page_frame->next;
        page_frame->next->prev = page_frame->prev;
    }

    vm_free_pages(&page_frame->frame, &process->addr_space.heap, process->addr_space.page_table);

    spin_release(&process->vm_lock);

    oma_free((void*)page_frame, page_frame_oma);
}

void proc_dealloc_vm_pages(Process* const process) {
    kassert(process != NULL);

    spin_lock(&process->vm_lock);

    VMPageFrameNode* curr_node = (void*)process->vm_pages.next;

    while (curr_node != NULL) {
        VMPageFrameNode* next = curr_node->next;

        vm_free_pages(&curr_node->frame, &process->addr_space.heap, process->addr_space.page_table);
        oma_free((void*)curr_node, page_frame_oma);

        curr_node = next;
    }

    process->vm_pages.next = NULL;
    process->vm_pages.prev = NULL;

    spin_release(&process->vm_lock);
}

void proc_add_child(Process* const parent, Process* const child) {
    child->parent = parent;
    child->next = NULL;

    if (parent->childs.next == NULL) {
        parent->childs.next = (void*)child;
        child->prev = NULL;
    }
    else {
        parent->childs.prev->next = (void*)child;
        child->prev = (void*)parent->childs.prev;
    }

    parent->childs.prev = (void*)child;
}

void proc_detach_child(Process* const parent, Process* const child) {
    if (parent->childs.next == (void*)child) {
        parent->childs.next = NULL;
        parent->childs.prev = NULL;
    }
    else if (parent->childs.prev == (void*)child) {
        parent->childs.prev = (void*)child->prev;
        child->prev->next = NULL;
    }
    else {
        child->prev->next = child->next;
        child->next->prev = child->prev;
    }
}

void proc_detach_childs(Process* const parent) {
    if (parent->childs.next == NULL) return;

    if (init_proc->childs.next == NULL) {
        init_proc->childs.next = parent->childs.next;
        init_proc->childs.prev = parent->childs.prev;
    }
    else {
        parent->childs.next->prev = init_proc->childs.prev;
        init_proc->childs.prev->next = parent->childs.next;
        init_proc->childs.prev = parent->childs.prev;
    }

    Process* child = (void*)parent->childs.next;

    while (child != NULL) {
        child->parent = init_proc;
        child = child->next;
    }
}

void proc_shutdown(Task* const task, const int status_code) {
    Process* const process = task->process;

    process->result_value = status_code;

    proc_dealloc_vm_pages(process);
    proc_clear_segments(process);
    proc_close_files(process);
    proc_detach_childs(process);

    vm_free_page_table(process->addr_space.page_table);

    tsk_extract(task);

    process->addr_space.page_table = NULL;
}

static char** copy_strings(const char** strings, const uint32_t count) {
    uint32_t length = 0;

    for (uint32_t i = 0; i < count; ++i) {
        length += strlen(strings[i]) + 1;
    }

    char** result = (char**)kmalloc((count + 1) * sizeof(char*) + length);

    if (result == NULL) return NULL;

    char* buffer = (char*)result + ((count + 1) * sizeof(char*));

    for (uint32_t i = 0; i < count; ++i) {
        size_t len = strlen(strings[i]);

        result[i] = buffer;

        memcpy(strings[i], buffer, len + 1);

        buffer += len + 1;
    }

    result[count] = NULL;

    return result;
}

char** proc_put_args_strings(uint64_t** const stack, char** strings, const uint32_t count) {
    uint64_t* cursor = *stack;

    char** result = count > 0 ? (char**)kmalloc(count * sizeof(char*)) : NULL;

    for (uint32_t i = 0; i < count; ++i) {
        const char* arg = strings[i];
        const size_t length = strlen(arg) + 1;

        cursor = (uint64_t*)((uint8_t*)cursor - length);
        memcpy((const void*)arg, (void*)cursor, length);

        result[i] = (char*)cursor;
    }

    *stack = (uint64_t*)((uint64_t)cursor & (~0xFull));

    return result;
}

long _sys_clone() {
    return 0;
}

pid_t _do_fork() {
    ProcessorLocal* const proc_local = proc_get_local();
    Process* const curr_process = proc_local->current_task->process;
    //kernel_warn("SYS FORK: CPU: %u\n", proc_local->idx);

    Process* const process = proc_new();
    if (process == NULL) goto out;

    Task* const task = tsk_new();
    if (task == NULL) goto out_task;

    task->process = process;

    vm_map_kernel(process->addr_space.page_table);

    if (thread_copy_stack(&proc_local->current_task->thread, &task->thread, process) == FALSE) {
        goto out_stack;
    }
    if (proc_copy_segments(curr_process, process) == FALSE) {
        goto out_segments;
    }
    if (proc_copy_vm_pages(curr_process, process) == FALSE) {
        goto out_vm_pages;
    }
    if (proc_copy_files(curr_process, process) == FALSE) {
        goto out_files;
    }

    process->work_dir = curr_process->work_dir;
    proc_add_child(curr_process, process);

    task->thread.stack_ptr = (uint64_t)proc_local->user_stack - sizeof(CallerSaveRegs);
    task->state = TSK_STATE_AFTER_FORK;

    tsk_awake(task);

    return process->pid;

out_files:
    proc_dealloc_vm_pages(process);
out_vm_pages:
    proc_clear_segments(process);
out_segments:
    thread_dealloc_stack(&task->thread);
out_stack:
    tsk_delete(task);
out_task:
    proc_delete(process);
out:
    return -ENOMEM;
}

ATTR_NAKED pid_t _sys_fork() {
    save_caller_regs();

    const ProcessorLocal* proc_local = proc_get_local();
    CallerSaveRegs* const caller_regs = (CallerSaveRegs*)((uint64_t)proc_local->user_stack - sizeof(CallerSaveRegs));

    load_caller_regs(caller_regs);

    const uint64_t result = _do_fork();

    ret(result);
}

long _sys_execve(const char* filename, char** argv, char** envp) {
    ProcessorLocal* proc_local = proc_get_local();
    Task* const task = proc_local->current_task;

    {
        const PageMapLevel4Entry* const page_table = task->process->addr_space.page_table;

        if (is_virt_addr_mapped_userspace(
                page_table,
                (uint64_t)filename
            ) == FALSE) {
            return -EFAULT;
        }
        if (argv != NULL) {
            if (is_virt_addr_mapped_userspace(
                    page_table,
                    (uint64_t)argv
                ) == FALSE) {
                return -EFAULT;
            }
        }
        if (envp != NULL) {
            if (is_virt_addr_mapped_userspace(
                    page_table,
                    (uint64_t)envp
                ) == FALSE) {
                return -EFAULT;
            }
        }
    }

    // Copy args and environs
    const uint64_t envc_val = (envp == NULL ? 0 : count_strings(envp));
    const uint64_t argc_val = (argv == NULL ? 0 : count_strings(argv));

    if (envp) envp = copy_strings(envp, envc_val);
    if (argv) argv = copy_strings(argv, argc_val);

    char filename_temp[128] = { '\0' };
    strcpy(filename_temp, filename);

    uint64_t stack_ptr = thread_get_stack_top(&task->thread);

    // Put args and environs on the stack
    char** env_ptr = proc_put_args_strings(&stack_ptr, envp, envc_val);
    char** argv_ptr = proc_put_args_strings(&stack_ptr, argv, argc_val);

    kfree(envp);
    kfree(argv);

    if ((envc_val + argc_val + 3) % 2 != 0) stack_ptr -= 8;
    task->thread.stack_ptr = stack_ptr;

    proc_clear_segments(task->process);
    proc_dealloc_vm_pages(task->process);

    // Load from file
    int result = proc_load_from_elf(filename_temp, task);
    if (result < 0) return result;

    proc_files_close_on_exec(task->process);
    proc_construct_heap(task->process);

    task->thread.exec_state = proc_make_exec_frame(task->thread.stack_ptr, task->ip, env_ptr, envc_val, argv_ptr, argc_val);
    task->state = TSK_STATE_NONE;

    kfree(env_ptr);
    kfree(argv_ptr);

    tsk_exec(task);

    return 0;
}

long _do_wait4(pid_t pid, int* stat_loc, int options) {
    UNUSED(options);

    ProcessorLocal* const proc_local = proc_get_local();
    Process* const process = proc_local->current_task->process;

    if (stat_loc != NULL &&
        is_virt_addr_mapped_userspace(
                process->addr_space.page_table,
                (uint64_t)stat_loc
            ) == FALSE) {
        return -EFAULT;
    }

    if (pid == -1) {
        volatile Process* const child = (void*)process->childs.next;

        if (child != NULL) {
            while (child->addr_space.page_table != NULL) {
                tsk_wait();
            }

            const pid_t pid = child->pid;

            if (stat_loc != NULL) *stat_loc = child->result_value;

            proc_detach_child(process, (Process*)child);
            proc_delete((Process*)child);

            return pid;
        }
    }

    return 0;
}

void raw_stack_dump(const uint64_t* stack, const uint32_t count) {
    for (uint32_t i = 0; i < count; ++i) {
        raw_print_number(stack[i], FALSE, 16);
        raw_puts(" <- (");
        raw_print_number((uint64_t)(stack + i), FALSE, 16);
        raw_puts(")\n");
    }
}

ATTR_NAKED long _sys_wait4(pid_t pid, int* stat_loc, int options) {
    register ProcessorLocal* const proc_local = proc_get_local();
    load_stack((uint64_t)proc_local->user_stack);

    const long result = _do_wait4(pid, stat_loc, options);

    restore_syscall_frame();
    sysret();
}

ATTR_NORETURN ATTR_NAKED void _sys_exit(int error_code) {
    ProcessorLocal* const proc_local = proc_get_local();

    cpu_set_pml4(proc_local->kernel_page_table);

    proc_shutdown(proc_local->current_task, error_code);

    tsk_schedule();
}