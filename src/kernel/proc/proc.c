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

bool_t init_proc_local() {
    kassert(sizeof(ProcessorLocal) == PAGE_BYTE_SIZE);

    proc_local_buffer = (ProcessorLocal*)bpa_allocate_pages(log2upper(bootboot.numcores - 1));

    if (proc_local_buffer == NULL) return FALSE;

    for (uint32_t i = 0; i < bootboot.numcores; ++i) {
        proc_local_buffer->kernel_stack = NULL;
        proc_local_buffer->user_stack = NULL;
    }

    return TRUE;
}

ProcessorLocal* _proc_get_local_data_by_idx(const uint32_t cpu_idx) {
    return (ProcessorLocal*)((uint64_t)proc_local_buffer + (cpu_idx * PAGE_BYTE_SIZE));
}

int _sys_clone() {
    return 0;
}

int _sys_fork() {
    return 0;
}

int _sys_execve() {
    return 0;
}