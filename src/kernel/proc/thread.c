#include "thread.h"

#include "assert.h"
#include "logger.h"
#include "math.h"
#include "mem.h"
#include "proc.h"


#include "vm/buddy_page_alloc.h"
#include "vm/vm.h"

bool_t thread_allocate_stack(Process* const process, Thread* const thread) {
    kassert(process != NULL && thread != NULL);

    if (process->addr_space.stack_base == 0) {
        process->addr_space.stack_base = PROC_STACK_VIRT_ADDRESS;
    }

    thread->stack.page_base = bpa_allocate_pages(log2upper(PAGES_PER_2MB)) / PAGE_BYTE_SIZE;

    if (thread->stack.page_base == 0) return FALSE;

    thread->stack.pages_count = PAGES_PER_2MB;
    thread->stack.virt_address = process->addr_space.stack_base - (2 * MB_SIZE);

    if (_vm_map_phys_to_virt(
            (uint64_t)thread->stack.page_base * PAGE_BYTE_SIZE,
            thread->stack.virt_address,
            process->addr_space.page_table,
            thread->stack.pages_count,
            (VMMAP_USER_ACCESS | VMMAP_WRITE)
        ) != KERNEL_OK) {
        bpa_free_pages(
            (uint64_t)thread->stack.page_base * PAGE_BYTE_SIZE,
            log2upper(PAGES_PER_2MB)
        );
        thread->stack.page_base = 0;
        thread->stack.pages_count = 0;
        thread->stack.virt_address = 0;
        return FALSE;
    }

    return TRUE;
}

bool_t thread_copy_stack(const Thread* src_thread, Thread* const dst_thread, const Process* dst_proc) {
    dst_thread->stack = src_thread->stack;
    dst_thread->stack.page_base =
        bpa_allocate_pages(log2upper(src_thread->stack.pages_count)) / PAGE_BYTE_SIZE;

    if (dst_thread->stack.page_base == 0) return FALSE;

    if (_vm_map_phys_to_virt(
        (uint64_t)dst_thread->stack.page_base * PAGE_BYTE_SIZE,
        dst_thread->stack.virt_address,
        dst_proc->addr_space.page_table,
        dst_thread->stack.pages_count,
        (VMMAP_USER_ACCESS | VMMAP_WRITE)
    ) != KERNEL_OK) {
        bpa_free_pages(
            (uint64_t)dst_thread->stack.page_base * PAGE_BYTE_SIZE,
            log2upper(src_thread->stack.pages_count)
        );
        return FALSE;
    }

    memcpy(
        (void*)src_thread->stack.virt_address,
        (void*)((uint64_t)dst_thread->stack.page_base * PAGE_BYTE_SIZE),
        dst_thread->stack.pages_count * PAGE_BYTE_SIZE
    );

    return TRUE;
}

void thread_dealloc_stack(Thread* const thread) {
    if (thread->stack.pages_count == 0) return;

    bpa_free_pages(
        (uint64_t)thread->stack.page_base * PAGE_BYTE_SIZE,
        log2upper(thread->stack.pages_count)
    );

    thread->stack.page_base = 0;
    thread->stack.pages_count = 0;
}