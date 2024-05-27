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

static void lapic_timer_intr_handler() {
    
}

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

    return KERNEL_OK;
}

Task* tsk_new() {
    return (Task*)oma_alloc(task_oma);
}

void tsk_delete(Task* const task) {
    oma_free((void*)task, task_oma);
}

static inline void tsk_push(Task* const task) {
    TaskScheduler* scheduler = &schedulers[g_proc_local.idx];

    task->next = NULL;

    if (scheduler->task_queue.next == NULL) {
        scheduler->task_queue.next = task;
    }
    else {
        task->prev = (Task*)scheduler->task_queue.prev;
        scheduler->task_queue.prev->next = (ListHead*)task;
    }

    scheduler->task_queue.prev = (ListHead*)task;
}

void tsk_awake(Task* const task) {
    tsk_push(task);
}

void tsk_start_scheduler() {
    TaskScheduler* scheduler = &schedulers[g_proc_local.idx];

    kassert(scheduler->task_queue.next != NULL);

    Task* task = scheduler->task_queue.next;

    g_proc_local.current_task = task;

    if (scheduler->task_queue.prev != scheduler->task_queue.next) {
        scheduler->task_queue.next = (ListHead*)task->next;
        task->next->prev = NULL;
        task->next = NULL;

        task->prev = (Task*)scheduler->task_queue.prev;
        task->prev->next = task;
        scheduler->task_queue.prev = (ListHead*)task;
    }

    if (cpu_get_current_pml4() != task->process->addr_space.page_table) {
        cpu_set_pml4(task->process->addr_space.page_table);
    }

    kernel_logger_clear();

    asm volatile(
        "mov %[instr_ptr],%%rcx \n"
        "mov %[stack_ptr],%%rsp \n"
        "xor %%rax,%%rax \n"
        "xor %%rdi,%%rdi \n"
        "xor %%rsi,%%rsi \n"
        "xor %%rdx,%%rdx \n"
        "xor %%rbx,%%rbx \n"
        "mov %%rsp,%%rbp \n"
        "sysretq"
        : 
        :
        [instr_ptr] "g" (task->thread.instruction_ptr),
        [stack_ptr] "g" (task->thread.stack_ptr)
        : "%rcx"
    );
}

bool_t tsk_switch_to(Task* const task) {
    TaskScheduler* scheduler = &schedulers[g_proc_local.idx];

    if (scheduler->task_queue.prev != task && scheduler->task_queue.next == task) {
        scheduler->task_queue.next = (ListHead*)task->next;
        task->next->prev = NULL;
        task->next = NULL;

        task->prev = (Task*)scheduler->task_queue.prev;
        task->prev->next = task;
        scheduler->task_queue.prev = (ListHead*)task;
    }

    if (cpu_get_current_pml4() != task->process->addr_space.page_table) {
        cpu_set_pml4(task->process->addr_space.page_table);
    }
}