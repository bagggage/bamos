#include "task_scheduler.h"

#include <bootboot.h>

#include "assert.h"
#include "local.h"
#include "logger.h"
#include "math.h"
#include "mem.h"
#include "syscalls.h"

#include "cpu/gdt.h"
#include "cpu/spinlock.h"
#include "cpu/regs.h"

#include "dev/lapic_timer.h"

#include "intr/apic.h"
#include "intr/intr.h"

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
        const InterruptLocation intr_location = { .cpu_idx = i, .vector = TSK_WAIT_INTR };

        if (intr_take_vector(intr_location) == FALSE ||
            intr_setup_handler(intr_location, tsk_wait_intr, INTR_KERNEL_STACK) == FALSE)
        {
            kfree(schedulers);
            oma_delete(task_oma);
            error_str = "Failed to reserve/setup interrupt vector for task waiting: no:" XSTRINGIFY(TSK_WAIT_INTR);
            return KERNEL_ERROR;
        }

        schedulers[i].lock = spinlock_init();
    }

    return KERNEL_OK;
}

Task* tsk_new() {
    Task* const result = (Task*)oma_alloc(task_oma);

    if (result) result->state = TSK_STATE_NONE;

    return result;
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

void tsk_exec(const Task* task) {
    restore_stack(&task->thread);
    restore_args_regs();
    restore_syscall_frame();

    sysret();
}

static ATTR_INLINE_ASM void tsk_sysret(const Task* task) {
    restore_stack(&task->thread);
    restore_caller_regs();
    restore_syscall_frame();

    asm volatile("xor %rax,%rax");

    sysret();
}

static ATTR_INLINE_ASM void tsk_switch(const Task* task) {
    load_stack((uint64_t)task->thread.exec_state);
    restore_regs();
    intr_ret();
}

Task* tsk_next(volatile TaskScheduler* const scheduler) {
    spin_lock((Spinlock*)&scheduler->lock);

    Task* task = (void*)scheduler->task_queue.next;

    if (scheduler->task_queue.prev != scheduler->task_queue.next) {
        scheduler->task_queue.next = (void*)task->next;
        task->next->prev = NULL;
        task->next = NULL;

        task->prev = (void*)scheduler->task_queue.prev;
        task->prev->next = task;
        scheduler->task_queue.prev = (void*)task;
    }

    spin_release((Spinlock*)&scheduler->lock);

    return task;
}

ATTR_NAKED void tsk_wait() {
    register ProcessorLocal* const proc_local asm("%rax") = proc_get_local();
    save_caller_regs();
    store_stack(&proc_local->tss->rsp0);

    register const uint64_t stack = proc_local->tss->rsp0;

    intr(TSK_WAIT_INTR);

    restore_caller_regs();

    asm("ret");
}

static ATTR_INLINE_ASM void tsk_resume(Task* const task) {
    load_stack((uint64_t)task->thread.exec_state);
    intr_ret();
}

ATTR_NORETURN void tsk_schedule() {
    ProcessorLocal* const proc_local = proc_get_local();
    volatile TaskScheduler* scheduler = &schedulers[proc_local->idx];

    while (scheduler->count == 0);

    Task* const task = tsk_next(scheduler);

    if (task->process->addr_space.page_table != cpu_get_current_pml4()) {
        cpu_set_pml4(task->process->addr_space.page_table);
    }

    proc_local->current_task = task;

    switch (task->state)
    {
    case TSK_STATE_SWITCH:
        tsk_switch(task); break;
    case TSK_STATE_WAIT:
        task->state = TSK_STATE_NONE;
        tsk_resume(task); break;
    case TSK_STATE_EXEC:
        task->state = TSK_STATE_NONE;
        tsk_exec(task); break;
    case TSK_STATE_AFTER_FORK:
        task->state = TSK_STATE_NONE;
        tsk_sysret(task); break;
    default:
        kernel_msg("PID: %u: stack: %x: state: %u\n", task->process->pid, task->thread.exec_state, task->state);
        kassert(FALSE);
        break;
    }
}

ATTR_NAKED void tsk_wait_intr() {
    register ProcessorLocal* const proc_local = proc_get_local();
    store_stack((uint64_t*)&proc_local->current_task->thread.exec_state);
    load_stack((uint64_t)proc_local->kernel_stack);

    proc_local->tss->rsp0 = (uint64_t)proc_local->kernel_stack;
    proc_local->current_task->state = TSK_STATE_WAIT;

    tsk_schedule();
}

ATTR_NAKED void tsk_timer_intr() {
    {
        register InterruptFrame64* frame asm("%rsp");

        load_stack(frame->rsp);
        stack_round(sizeof(InterruptFrame64));
        save_regs();
    }

    register ProcessorLocal* const proc_local = proc_get_local();

    store_stack((uint64_t*)&proc_local->current_task->thread.exec_state);
    load_stack((uint64_t)proc_local->kernel_stack);

    {
        InterruptFrame64* const src = (InterruptFrame64*)(((uint64_t)proc_local->kernel_stack & ~(0xF)) - sizeof(InterruptFrame64));

        src->ss |= 3;
        src->eflags |= RFLAGS_IF;

        proc_local->current_task->thread.exec_state->intr_frame = *src;
        proc_local->current_task->state = TSK_STATE_SWITCH;
    }

    lapic_eoi();
    tsk_schedule();
}