#pragma once

#include "cpu/spinlock.h"
#include "definitions.h"

typedef void (*CpuTaskHandler)(void*);

typedef struct CpuTaskNode {
    CpuTaskHandler handler;
    void* parameters;

    uint64_t bitfield;
    Spinlock mutilock;

    struct CpuTaskNode* next;
} CpuTaskNode;

typedef struct CpuTaskList {
    CpuTaskNode* next;
    Spinlock lock;
} CpuTaskList;

bool_t tks_is_queue_empty();

bool_t tsk_push(CpuTaskHandler task, void* parameters, const bool_t is_foreach);

/*
Wait cpu for tasks and excecute them if there are
*/
void tsk_exec();