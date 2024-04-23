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
    ListHead sleep_queue;
} TaskScheduler;

Status init_task_scheduler();

bool_t tsk_switch_to(Task* task);