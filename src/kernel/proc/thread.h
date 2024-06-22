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

typedef struct ExecutionState {
    uint64_t rdi;
    uint64_t rsi;
    uint64_t rdx;
    uint64_t r12;
    uint64_t r13;
    uint64_t r14;
    uint64_t r15;
} ExecutionState;

typedef struct Thread {
    VMMemoryBlock stack;

    uint64_t instruction_ptr;
    uint64_t* stack_ptr;
    uint64_t* base_ptr;

    ExecutionState exec_state;

    uint8_t state;
} Thread;

bool_t thread_allocate_stack(Process* const process, Thread* const thread);
bool_t thread_copy_stack(const Thread* src_thread, Thread* const dst_thread, const Process* dst_proc);
void thread_dealloc_stack(Thread* const thread);
