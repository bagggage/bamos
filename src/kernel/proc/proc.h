#pragma once

#include "definitions.h"
#include "thread.h"

#include "cpu/spinlock.h"

#include "vm/vm.h"

#include "utils/list.h"

typedef uint32_t pid_t;

typedef struct ProcessAddressSpace {
    VMMemoryBlock code;
    VMMemoryBlock data;
    VMMemoryBlock stack;

    VMMemoryBlock environment;

    VMHeap heap;

    Spinlock lock;

    PageMapLevel4Entry* page_table;
} ProcessAddressSpace;

typedef struct Process {
    pid_t pid;
    ProcessAddressSpace addr_space;
} Process;

typedef struct Task {
    LIST_STRUCT_IMPL(Task);

    Process* process;
    Thread thread;
} Task;

Process* proc_new();
void proc_delete(Process* process);

int _sys_clone();
pid_t _sys_fork();
int _sys_execve(const char* filename, char* const argv[], char* const envp[]);