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
} TaskScheduler;

Status init_task_scheduler();

Task* tsk_new();
void tsk_delete(Task* const task);

void tsk_awake(Task* const task);

void tsk_start_scheduler();

bool_t tsk_switch_to(Task* const task);