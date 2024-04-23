#pragma once

#include "definitions.h"

typedef enum ThreadState {
    THREAD_RUNNING,
    THREAD_RUNNABLE,
    THREAD_SLEEPING,
    THREAD_WAITING,
    THREAD_TERMINATED
} ThreadState;

typedef struct Thread {
    uint64_t* stack;
    uint64_t instruction_ptr;

    uint8_t state;
} Thread;