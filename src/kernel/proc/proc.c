#include "proc.h"

#include <bootboot.h>

#include "assert.h"
#include "local.h"
#include "logger.h"
#include "math.h"
#include "task_scheduler.h"

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

    for (uint32_t i = 0; i < bootboot.numcores - 1; ++i) {
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

        if (proc_oma == NULL) retrun NULL;
    }

    Process* process = (Process*)oma_alloc(proc_oma);

    return process;
}

void proc_delete(Process* process) {
    kassert(process != NULL);

    oma_free((void*)process, proc_oma);
}

int _sys_clone() {
    return 0;
}

pid_t _sys_fork() {
    Process* process = proc_new();

    if (process == NULL) return -1;

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