#pragma once

#include "definitions.h"

#include "vm/vm.h"

typedef struct Process Process;

typedef enum ThreadState {
    THREAD_RUNNING,
    THREAD_RUNNABLE,
    THREAD_SLEEPING,
    THREAD_WAITING,
    THREAD_TERMINATED
} ThreadState;

typedef struct Thread {
    VMMemoryBlock stack;

    uint64_t instruction_ptr;
    uint64_t* stack_ptr;

    uint8_t state;
} Thread;

bool_t thread_allocate_stack(Process* const process, Thread* const thread);
