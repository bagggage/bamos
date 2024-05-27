#include "proc.h"

#include <bootboot.h>

#include "assert.h"
#include "elf.h"
#include "local.h"
#include "logger.h"
#include "math.h"
#include "mem.h"
#include "task_scheduler.h"

#include "fs/vfs.h"

#include "vm/buddy_page_alloc.h"

#define INIT_PROC_FILENAME "/usr/bin/test.app"

extern BOOTBOOT bootboot;

// Statically allocated space for 'g_proc_local'
ATTR_ALIGN(PAGE_BYTE_SIZE)
ProcessorLocal g_proc_local;

static ProcessorLocal* proc_local_buffer = NULL;

static ObjectMemoryAllocator* proc_oma = NULL;
static ObjectMemoryAllocator* seg_oma = NULL;
static ObjectMemoryAllocator* page_frame_oma = NULL;

bool_t init_proc_local() {
    kassert(sizeof(ProcessorLocal) == PAGE_BYTE_SIZE);

    proc_local_buffer = (ProcessorLocal*)bpa_allocate_pages(log2upper(bootboot.numcores - 1));

    if (proc_local_buffer == NULL) return FALSE;

    for (uint32_t i = 0; i < (uint32_t)bootboot.numcores - 1; ++i) {
        proc_local_buffer[i].kernel_page_table = NULL;
        proc_local_buffer[i].current_task = NULL;
        proc_local_buffer[i].kernel_stack = NULL;
        proc_local_buffer[i].user_stack = NULL;
    }

    return TRUE;
}

ProcessorLocal* _proc_get_local_data_by_idx(const uint32_t cpu_idx) {
    return (ProcessorLocal*)((uint64_t)proc_local_buffer + (cpu_idx * PAGE_BYTE_SIZE));
}

bool_t load_init_proc() {
    VfsDentry* file_dentry = vfs_open(INIT_PROC_FILENAME, 0);

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

    task->thread.instruction_ptr = elf->entry;
    task->thread.stack_ptr = (uint64_t*)(
        task->thread.stack.virt_address +
        ((uint64_t)task->thread.stack.pages_count * PAGE_BYTE_SIZE) - 8
    );
    task->process = process;

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
            .virt_base = NULL,
            .virt_top = NULL
        };
        process->addr_space.segments = (ListHead){
            .next = NULL,
            .prev = NULL
        };
        process->addr_space.stack_base = 0;

        process->files = NULL;
        process->files_capacity = 0;
        process->files_lock = spinlock_init();

        process->vm_lock = spinlock_init();
        process->vm_pages = (ListHead){
            .next = NULL,
            .prev = NULL
        };
    }

    return process;
}

void proc_delete(Process* process) {
    kassert(process != NULL);

    if (process->addr_space.page_table != NULL) {
        vm_free_page_table(process->addr_space.page_table);
    }

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

VMPageFrameNode* proc_push_vm_page(Process* const process) {
    kassert(process != NULL);

    if (page_frame_oma == NULL) {
        page_frame_oma = oma_new(sizeof(VMPageFrameNode));

        if (page_frame_oma == NULL) return page_frame_oma;
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

void proc_dealloc_vm_page(Process* const process, VMPageFrameNode* const page_frame) {
    kassert(process != NULL && page_frame != NULL);

    spin_lock(&process->vm_lock);

    if (page_frame == process->vm_pages.next) {
        if (page_frame == process->vm_pages.prev) {
            process->vm_pages.next = NULL;
            process->vm_pages.prev = NULL;
        }
        else {
            page_frame->next->prev = NULL;
            process->vm_pages.next = (ListHead*)page_frame->next;
        }
    }
    else if (page_frame == process->vm_pages.prev) {
        page_frame->prev->next = NULL;
        process->vm_pages.prev = (ListHead*)page_frame->prev;
    }
    else {
        page_frame->prev->next = page_frame->next;
        page_frame->next->prev = page_frame->prev;
    }

    vm_free_pages(&page_frame->frame, &process->addr_space.heap, &process->addr_space.page_table);

    spin_release(&process->vm_lock);

    oma_free((void*)page_frame, page_frame_oma);
}

void proc_dealloc_vm_pages(Process* const process) {
    kassert(process != NULL);

    spin_lock(&process->vm_lock);

    VMPageFrameNode* curr_node = process->vm_pages.next;

    while (curr_node != NULL) {
        VMPageFrameNode* next = curr_node->next;

        vm_free_pages(&curr_node->frame, &process->addr_space.heap, &process->addr_space.page_table);
        oma_free((void*)curr_node, page_frame_oma);

        curr_node = next;
    }

    process->vm_pages.next = NULL;
    process->vm_pages.prev = NULL;

    spin_release(&process->vm_lock);
}

int _sys_clone() {
    return 0;
}

pid_t _sys_fork() {
    Process* process = proc_new();

    if (process == NULL) return -1;

    process->vm_pages.next = NULL;
    process->vm_pages.prev = NULL;
    process->vm_lock = spinlock_init();

    process->files = NULL;
    process->files_capacity = 0;
    process->files_lock = spinlock_init();

    process->addr_space = g_proc_local.current_task->process->addr_space;
    process->addr_space.page_table = vm_alloc_page_table();

    if (process->addr_space.page_table == NULL) {
        proc_delete(process);
        return -1;
    }

    process->addr_space.heap = vm_heap_copy(&process->addr_space.heap);
    
    vm_map_kernel(process->addr_space.page_table);

    return 0;
}

int _sys_execve(const char* filename, char* const argv[], char* const envp[]) {
    

    return 0;
}