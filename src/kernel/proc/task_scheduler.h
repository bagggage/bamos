#pragma once

#include "proc.h"
#include "thread.h"

#include "utils/list.h"

#define TSK_WAIT_INTR 128

/*
Simple task schebuler.
The scheduling algorithm will be changed in future.
*/

typedef struct TaskScheduler {
    ListHead task_queue;
    uint64_t count;
    Spinlock lock;
} TaskScheduler;

Status init_task_scheduler();

Task* tsk_new();
void tsk_delete(Task* const task);

void tsk_awake(Task* const task);
void tsk_extract(Task* const task);
void tsk_exec(const Task* task);
Task* tsk_next(volatile TaskScheduler* const scheduler);

void tsk_wait();

ATTR_NORETURN void tsk_schedule();

void tsk_wait_intr();
void tsk_timer_intr();