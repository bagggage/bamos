#include "proc.h"

#include <bootboot.h>

#include "assert.h"
#include "local.h"
#include "logger.h"
#include "math.h"
#include "mem.h"
#include "task_scheduler.h"

#include "fs/vfs.h"

#include "vm/buddy_page_alloc.h"

extern BOOTBOOT bootboot;

// Statically allocated space for 'g_proc_local'
ATTR_ALIGN(PAGE_BYTE_SIZE)
ProcessorLocal g_proc_local;

static ProcessorLocal* proc_local_buffer = NULL;
static ObjectMemoryAllocator* proc_oma = NULL;

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

Process* proc_new() {
    if (proc_oma == NULL) {
        proc_oma = oma_new(sizeof(Process));

        if (proc_oma == NULL) return NULL;
    }

    Process* process = (Process*)oma_alloc(proc_oma);

    return process;
}

void proc_delete(Process* process) {
    kassert(process != NULL);

    oma_free((void*)process, proc_oma);
}

VMPageFrameNode* proc_push_vm_page(Process* const process) {
    kassert(process != NULL);

    VMPageFrameNode* node = kmalloc(sizeof(VMPageFrameNode));

    if (node == NULL) return NULL;

    spin_lock(&process->vm_lock);

    if (process->vm_pages.next == NULL) {
        node->next = NULL;
        node->prev = NULL;

        process->vm_pages.next = (ListHead*)node;
    }
    else {
        node->next = NULL;
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

    kfree(page_frame);
}

void proc_dealloc_vm_pages(Process* const process) {
    kassert(process != NULL);

    spin_lock(&process->vm_lock);

    VMPageFrameNode* curr_node = process->vm_pages.next;

    while (curr_node != NULL) {
        VMPageFrameNode* next = curr_node->next;

        kfree((void*)curr_node);

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