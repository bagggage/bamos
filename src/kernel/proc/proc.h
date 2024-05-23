#pragma once

#include "definitions.h"
#include "thread.h"
#include "file.h"

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

typedef struct VMPageFrameNode {
    LIST_STRUCT_IMPL(VMPageFrameNode);
    VMPageFrame frame;
} VMPageFrameNode;

typedef struct Process {
    pid_t pid;

    ProcessAddressSpace addr_space;
    ListHead vm_pages;
    Spinlock vm_lock;

    FileDescriptor** files;
    uint32_t files_capacity;
    Spinlock files_lock;
} Process;

typedef struct Task {
    LIST_STRUCT_IMPL(Task);

    Process* process;
    Thread thread;
} Task;

Process* proc_new();
void proc_delete(Process* process);

VMPageFrameNode* proc_push_vm_page(Process* const process);
void proc_dealloc_vm_page(Process* const process, VMPageFrameNode* const page_frame);
void proc_dealloc_vm_pages(Process* const process);

int _sys_clone();
pid_t _sys_fork();
int _sys_execve(const char* filename, char* const argv[], char* const envp[]);