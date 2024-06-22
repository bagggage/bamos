#include "task_scheduler.h"

#include <bootboot.h>

#include "assert.h"
#include "local.h"
#include "logger.h"
#include "math.h"
#include "mem.h"

#include "cpu/gdt.h"
#include "cpu/spinlock.h"
#include "cpu/regs.h"

#include "intr/apic.h"

#include "vm/object_mem_alloc.h"

extern BOOTBOOT bootboot;
static TaskScheduler* schedulers = NULL;
static ObjectMemoryAllocator* task_oma = NULL;

Status init_task_scheduler() {
    schedulers = (TaskScheduler*)kcalloc(sizeof(TaskScheduler) * bootboot.numcores);

    if (schedulers == NULL) {
        error_str = "Scheduler: not enough memory";
        return KERNEL_ERROR;
    }

    task_oma = oma_new(sizeof(Task));

    if (task_oma == NULL) {
        kfree(schedulers);

        error_str = "Scheduler: not enough memory for task allocator";
        return KERNEL_ERROR;
    }

    for (uint32_t i = 0; i < bootboot.numcores; ++i) {
        schedulers[i].lock = spinlock_init();
    }

    return KERNEL_OK;
}

Task* tsk_new() {
    return (Task*)oma_alloc(task_oma);
}

void tsk_delete(Task* const task) {
    oma_free((void*)task, task_oma);
}

static inline void tsk_push(Task* const task) {
    TaskScheduler* scheduler = NULL;
    uint32_t cpu_idx = 0;

    for (; cpu_idx < bootboot.numcores; ++cpu_idx) {
        if (schedulers[cpu_idx].count == 0) {
            scheduler = &schedulers[cpu_idx];
            break;
        }
        else if (scheduler == NULL || schedulers[cpu_idx].count < scheduler->count) {
            scheduler = &schedulers[cpu_idx];
        }
    }

    kassert(scheduler != NULL);

    spin_lock(&scheduler->lock);

    task->next = NULL;
    task->prev = NULL;

    if (scheduler->task_queue.next == NULL) {
        scheduler->task_queue.next = (void*)task;
    }
    else {
        task->prev = (void*)scheduler->task_queue.prev;
        scheduler->task_queue.prev->next = (void*)task;
    }

    scheduler->task_queue.prev = (void*)task;
    scheduler->count++;

    spin_release(&scheduler->lock);
}

void tsk_awake(Task* const task) {
    tsk_push(task);
}

void tsk_extract(Task* const task) {
    TaskScheduler* scheduler = &schedulers[proc_get_local()->idx];

    spin_lock(&scheduler->lock);

    if ((void*)task == (void*)scheduler->task_queue.next) {
        if ((void*)task == (void*)scheduler->task_queue.prev) {
            scheduler->task_queue.prev = NULL;
            scheduler->task_queue.next = NULL;
        }
        else {
            scheduler->task_queue.next = (void*)task->next;
            task->next->prev = NULL;
        }
    }
    else if ((void*)task == (void*)scheduler->task_queue.prev) {
        scheduler->task_queue.prev = (void*)task->prev;
        task->prev->next = NULL;
    }
    else {
        task->next->prev = task->prev;
        task->prev->next = task->next;
    }

    scheduler->count--;

    spin_release(&scheduler->lock);

    thread_dealloc_stack(&task->thread);

    oma_free((void*)task, task_oma);
}

__attribute__((noreturn, naked)) void tsk_launch(const Task* task) {
    register uint64_t rdi asm("%rdi") = task->thread.exec_state.rdi;
    register uint64_t rsi asm("%rsi") = task->thread.exec_state.rsi;
    register uint64_t rdx asm("%rdx") = task->thread.exec_state.rdx;
    register uint64_t r12 asm("%r12") = task->thread.exec_state.r12;
    register uint64_t r13 asm("%r13") = task->thread.exec_state.r13;
    register uint64_t r14 asm("%r14") = task->thread.exec_state.r14;
    register uint64_t r15 asm("%r15") = task->thread.exec_state.r15;

    asm volatile(
        "pushfq \n"
        "popq %%r11 \n"
        "mov %[instr_ptr],%%rcx \n"
        "mov %[stack_ptr],%%rsp \n"
        "mov %[base_ptr],%%rbp \n"
        "xor %%rax,%%rax \n"
        "xor %%rbx,%%rbx \n"
        "sysretq"
        :
        :
        [instr_ptr] "g" (task->thread.instruction_ptr),
        [stack_ptr] "g" (task->thread.stack_ptr),
        [base_ptr] "g" (task->thread.base_ptr),
        "r"(rdi),"r"(rsi),"r"(rdx),
        "r"(r12),"r"(r13),"r"(r14),"r"(r15)
        : "%rcx", "memory"
    );
}

void tsk_next() {
    ProcessorLocal* proc_local = proc_get_local();
    volatile TaskScheduler* scheduler = &schedulers[proc_local->idx];

    while (scheduler->count == 0);

    spin_lock((Spinlock*)&scheduler->lock);

    Task* task = (void*)scheduler->task_queue.next;

    proc_local->current_task = task;

    if (scheduler->task_queue.prev != scheduler->task_queue.next) {
        scheduler->task_queue.next = (void*)task->next;
        task->next->prev = NULL;
        task->next = NULL;

        task->prev = (void*)scheduler->task_queue.prev;
        task->prev->next = task;
        scheduler->task_queue.prev = (void*)task;
    }

    spin_release((Spinlock*)&scheduler->lock);

    if (cpu_get_current_pml4() != task->process->addr_space.page_table) {
        cpu_set_pml4(task->process->addr_space.page_table);
    }

    tsk_launch(task);
}

void tsk_start_scheduler() {
    kassert(schedulers != NULL);

    ProcessorLocal* proc_local = proc_get_local();
    volatile TaskScheduler* scheduler = &schedulers[proc_local->idx];

    kassert(proc_local->idx != 0 || scheduler->task_queue.next != NULL);

    while (scheduler->count == 0);

    spin_lock((Spinlock*)&scheduler->lock);

    Task* task = (void*)scheduler->task_queue.next;

    proc_local->current_task = task;

    if (scheduler->task_queue.prev != scheduler->task_queue.next) {
        scheduler->task_queue.next = (void*)task->next;
        task->next->prev = NULL;
        task->next = NULL;

        task->prev = (void*)scheduler->task_queue.prev;
        task->prev->next = task;
        scheduler->task_queue.prev = (void*)task;
    }

    spin_release((Spinlock*)&scheduler->lock);

    cpu_set_pml4(task->process->addr_space.page_table);

    //kernel_msg("Starting scheduler %u: pml4: %x: ip: %x:[%x]:%x (%x): sp: %x\n",
    //    proc_local->idx,
    //    task->process->addr_space.page_table,
    //    task->thread.instruction_ptr,
    //    *(uint8_t*)task->thread.instruction_ptr,
    //    get_phys_address(task->thread.instruction_ptr),
    //    (uint64_t)((VMMemoryBlockNode*)task->process->addr_space.segments.next)->block.page_base * PAGE_BYTE_SIZE,
    //    task->thread.stack_ptr
    //);
    //if (((uint64_t)task->thread.stack_ptr & 0xF0) != 0xF0) {
    //    kernel_msg("sp[0]: %x, sp[1]: %x, sp[2]: %x\n",
    //        task->thread.stack_ptr[0],
    //        task->thread.stack_ptr[1],
    //        task->thread.stack_ptr[2]
    //    );
    //}
    //if (proc_local->idx == 0) kernel_logger_clear();

    tsk_launch(task);
}

void tsk_switch_to(Task* const task) {
    ProcessorLocal* proc_local = proc_get_local();
    TaskScheduler* scheduler = &schedulers[proc_local->idx];

    if (scheduler->task_queue.prev != (void*)task && scheduler->task_queue.next == (void*)task) {
        scheduler->task_queue.next = (void*)task->next;
        task->next->prev = NULL;
        task->next = NULL;

        task->prev = (void*)scheduler->task_queue.prev;
        task->prev->next = task;
        scheduler->task_queue.prev = (void*)task;
    }

    if (cpu_get_current_pml4() != task->process->addr_space.page_table) {
        cpu_set_pml4(task->process->addr_space.page_table);
    }
}