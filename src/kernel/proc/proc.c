#include "proc.h"

#include <bootboot.h>

#include "assert.h"
#include "elf.h"
#include "local.h"
#include "logger.h"
#include "math.h"
#include "mem.h"
#include "task_scheduler.h"

#include "cpu/spinlock.h"

#include "fs/vfs.h"

#include "vm/buddy_page_alloc.h"

#include "libc/errno.h"

#define INIT_PROC_FILENAME "/usr/bin/init"

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

bool_t load_init_proc() {
    VfsDentry* file_dentry = vfs_open(INIT_PROC_FILENAME, NULL);

    if (file_dentry == NULL) {
        error_str = "'init' process executable file at path " INIT_PROC_FILENAME " not found";
        return FALSE;
    }

    Process* process = proc_new();

    if (process == NULL) {
        error_str = "Not enough memory";
        return FALSE;
    }

    Task* task = tsk_new();

    if (task == NULL) {
        proc_delete(process);

        error_str = "Not enough memory";
        return FALSE;
    }

    ELF* elf = elf_load_file(file_dentry);

    if (elf == NULL) {
        proc_delete(process);
        tsk_delete(task);
        error_str = "Failed to load elf file " INIT_PROC_FILENAME;
        return FALSE;
    }

    if (is_elf_valid_and_supported(elf) == FALSE) {
        proc_delete(process);
        tsk_delete(task);
        kfree(elf);
        error_str = "Incorrect elf file format " INIT_PROC_FILENAME;
        return FALSE;
    }

    vm_map_kernel(process->addr_space.page_table);
    cpu_set_pml4(process->addr_space.page_table);

    if (elf_load_prog(elf, process) == FALSE) {
        proc_delete(process);
        tsk_delete(task);
        kfree(elf);
        error_str = "Invalid program segments or not enough memory";
        return FALSE;
    }

    task->thread.instruction_ptr = elf->entry;

    kfree(elf);

    const VMMemoryBlockNode* top_segment = (VMMemoryBlockNode*)process->addr_space.segments.prev;

    vm_heap_construct(
        &process->addr_space.heap,
        (
            top_segment->block.virt_address +
            ((uint64_t)top_segment->block.pages_count * PAGE_BYTE_SIZE) +
            PAGE_BYTE_SIZE
        )
    );

    if (thread_allocate_stack(process, &task->thread) == FALSE) {
        proc_clear_segments(process);
        proc_delete(process);
        tsk_delete(task);
        error_str = "Failed to allocate stack";
        return FALSE;
    }

    task->thread.stack_ptr = (uint64_t*)(
        task->thread.stack.virt_address +
        ((uint64_t)task->thread.stack.pages_count * PAGE_BYTE_SIZE) - 8
    );
    task->thread.base_ptr = task->thread.stack_ptr;

    task->process = process;
    init_proc = process;

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
        process->pid = proc_generate_id();
        process->addr_space.page_table = vm_alloc_page_table();

        if (process->addr_space.page_table == NULL) {
            oma_free((void*)process, proc_oma);
            return NULL;
        }

        process->addr_space.lock = spinlock_init();
        process->addr_space.heap = (VMHeap){
            .free_list = (ListHead){
                .next = NULL,
                .prev = NULL
            },
            .virt_base = 0,
            .virt_top = 0
        };
        process->addr_space.segments = (ListHead){
            .next = NULL,
            .prev = NULL
        };
        process->addr_space.stack_base = 0;

        process->work_dir = NULL;

        process->files = NULL;
        process->files_capacity = 0;
        process->files_lock = spinlock_init();

        process->vm_lock = spinlock_init();
        process->vm_pages = (ListHead){
            .next = NULL,
            .prev = NULL
        };

        process->parent = NULL;
        process->childs.next = NULL;
        process->childs.prev = NULL;
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

    VMMemoryBlockNode* node = oma_alloc(seg_oma);

    if (node == NULL) return NULL;

    if (process->addr_space.segments.next == NULL) {
        node->prev = NULL;
        process->addr_space.segments.next = (ListHead*)node;
    }
    else {
        node->prev = (VMMemoryBlockNode*)process->addr_space.segments.prev;
        process->addr_space.segments.prev->next = (ListHead*)node;
    }

    node->next = NULL;
    process->addr_space.segments.prev = (ListHead*)node;

    return node;
}

void proc_clear_segments(Process* const process) {
    kassert(process != NULL);

    while (process->addr_space.segments.next != NULL) {
        VMMemoryBlockNode* node = (VMMemoryBlockNode*)process->addr_space.segments.next;
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

bool_t proc_copy_vm_pages(Process* const src_proc, Process* const dst_proc) {
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

        dst_frame->frame = vm_alloc_pages(
            src_frame->frame.count,
            &dst_proc->addr_space.heap,
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

        memcpy(
            (void*)src_frame->frame.virt_address,
            (void*)((uint64_t)((VMPageList*)dst_frame->frame.phys_pages.next)->phys_page_base * PAGE_BYTE_SIZE),
            dst_frame->frame.count * PAGE_BYTE_SIZE
        );

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

long _sys_clone() {
    return 0;
}

pid_t _sys_fork() {
    ProcessorLocal* proc_local = proc_get_local();
    //kernel_warn("SYS FORK: CPU: %u\n", proc_local->idx);

    Process* process = proc_new();

    if (process == NULL) return -ENOMEM;

    Task* task = tsk_new();

    if (task == NULL) {
        proc_delete(process);
        return -ENOMEM;
    }

    task->process = process;

    vm_heap_construct(&process->addr_space.heap, g_proc_local.current_task->process->addr_space.heap.virt_base);
    vm_map_kernel(process->addr_space.page_table);

    if (thread_copy_stack(&proc_local->current_task->thread, &task->thread, process) == FALSE) {
        proc_delete(process);
        tsk_delete(task);
        return -ENOMEM;
    }

    if (proc_copy_segments(proc_local->current_task->process, process) == FALSE) {
        thread_dealloc_stack(&task->thread);
        proc_delete(process);
        tsk_delete(task);
        return -ENOMEM;
    }

    if (proc_copy_vm_pages(proc_local->current_task->process, process) == FALSE) {
        proc_clear_segments(process);
        thread_dealloc_stack(&task->thread);
        proc_delete(process);
        tsk_delete(task);
        return -ENOMEM;
    }

    if (proc_copy_files(proc_local->current_task->process, process) == FALSE) {
        proc_dealloc_vm_pages(process);
        proc_clear_segments(process);
        thread_dealloc_stack(&task->thread);
        proc_delete(process);
        tsk_delete(task);
        return -ENOMEM;
    }

    process->work_dir = proc_local->current_task->process->work_dir;

    task->thread.instruction_ptr = (uint64_t)proc_local->instruction_ptr;
    task->thread.stack_ptr = (uint64_t*)((uint64_t)proc_local->user_stack + sizeof(UserStack));
    task->thread.base_ptr = (uint64_t*)proc_local->user_stack->base_pointer;

    proc_add_child(proc_local->current_task->process, process);

    tsk_awake(task);

    return 1;
}

long _sys_execve(const char* filename, char* const argv[], char* const envp[]) {
    ProcessorLocal* proc_local = proc_get_local();

    if (is_virt_addr_mapped_userspace(
            proc_local->current_task->process->addr_space.page_table,
            (uint64_t)filename
        ) == FALSE) {
        return -EFAULT;
    }
    if (argv != NULL) {
        if (is_virt_addr_mapped_userspace(
                proc_local->current_task->process->addr_space.page_table,
                (uint64_t)argv
            ) == FALSE) {
            return -EFAULT;
        }
    }
    if (envp != NULL) {
        if (is_virt_addr_mapped_userspace(
                proc_local->current_task->process->addr_space.page_table,
                (uint64_t)envp
            ) == FALSE) {
            return -EFAULT;
        }
    }

    VfsDentry* file_dentry = vfs_open(filename, proc_local->current_task->process->work_dir);

    if (file_dentry == NULL) return -ENOENT;
    if (file_dentry->inode->file_size < 3) return -ENOEXEC;

    uint8_t* file_buffer = (uint8_t*)kmalloc(file_dentry->inode->file_size);

    if (file_buffer == NULL) return -ENOMEM;

    uint32_t readed = vfs_read(file_dentry, 0, file_dentry->inode->file_size, (void*)file_buffer);

    if (readed < file_dentry->inode->file_size) {
        kfree(file_buffer);
        return -EIO;
    }

    if (file_buffer[0] == '#' && file_buffer[1] == '!') {
        // It is a shell script
        // TODO
        kassert(FALSE && "Not implemented");
    }
    else if (is_elf_valid_and_supported((ELF*)file_buffer)) {
        ELF* elf = (ELF*)file_buffer;

        proc_dealloc_vm_pages(proc_local->current_task->process);
        proc_clear_segments(proc_local->current_task->process);
        proc_close_files(proc_local->current_task->process);

        if (elf_load_prog(elf, proc_local->current_task->process) == FALSE) {
            proc_delete(proc_local->current_task->process);
            tsk_extract(proc_local->current_task);
            kernel_error("Failed to load process from ELF file\n");
            _kernel_break();
        }

        proc_local->current_task->thread.instruction_ptr = elf->entry;

        kfree(file_buffer);

        const VMMemoryBlockNode* top_segment =
            (VMMemoryBlockNode*)proc_local->current_task->process->addr_space.segments.prev;

        vm_heap_construct(
            &proc_local->current_task->process->addr_space.heap,
            (
                top_segment->block.virt_address +
                ((uint64_t)top_segment->block.pages_count * PAGE_BYTE_SIZE) +
                PAGE_BYTE_SIZE
            )
        );

        proc_local->current_task->thread.stack_ptr = (uint64_t*)(
            proc_local->current_task->thread.stack.virt_address +
            ((uint64_t)proc_local->current_task->thread.stack.pages_count * PAGE_BYTE_SIZE) - 8
        );
        proc_local->current_task->thread.base_ptr = proc_local->current_task->thread.stack_ptr;

        //kernel_msg("phys: %x\n", get_phys_address(proc_local->current_task->thread.instruction_ptr));
        //kernel_msg("real: %x\n", (uint64_t)((VMMemoryBlockNode*)proc_local->current_task->process->addr_space.segments.next)->block.page_base * PAGE_BYTE_SIZE);

        //kernel_msg("Instr: %x\n", proc_local->current_task->thread.instruction_ptr);
        //kernel_msg("Page table cpu: %x\n", g_proc_local.idx);

        tsk_launch(proc_local->current_task);
    }
    else {
        kfree(file_buffer);
        return -ENOEXEC;
    }

    return 0;
}

long _sys_wait4(pid_t pid, int* stat_loc, int options) {
    ProcessorLocal* proc_local = proc_get_local();

    if (stat_loc != NULL &&
        is_virt_addr_mapped_userspace(
                proc_local->current_task->process->addr_space.page_table,
                (uint64_t)stat_loc
            ) == FALSE) {
        return -EFAULT;
    }

    if (pid == -1) {
        volatile Process* child = (void*)proc_local->current_task->process->childs.next;

        if (child != NULL) {
            while (child->addr_space.page_table != NULL);

            const pid_t pid = child->pid;

            if (stat_loc != NULL) *stat_loc = child->result_value;

            proc_detach_child(proc_local->current_task->process, child);
            proc_delete(child);

            return pid;
        }
    }

    return 0;
}

long _sys_exit(int error_code) {
    ProcessorLocal* proc_local = proc_get_local();

    proc_local->current_task->process->result_value = error_code;

    proc_dealloc_vm_pages(proc_local->current_task->process);
    proc_clear_segments(proc_local->current_task->process);
    proc_close_files(proc_local->current_task->process);
    proc_detach_childs(proc_local->current_task->process);

    tsk_extract(proc_local->current_task);

    cpu_set_pml4(proc_local->kernel_page_table);
    vm_free_page_table(proc_local->current_task->process->addr_space.page_table);

    proc_local->current_task->process->addr_space.page_table = NULL;

    tsk_next();
}