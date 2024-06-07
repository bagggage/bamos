#pragma once

#include "proc.h"
#include "thread.h"

#include "utils/list.h"

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
void tsk_launch(const Task* task);
void tsk_next();

void tsk_start_scheduler();

void tsk_switch_to(Task* const task);