#pragma once

#include "definitions.h"
#include "thread.h"
#include "file.h"

#include "cpu/spinlock.h"

#include "vm/vm.h"

#include "utils/list.h"

#define PROC_STACK_VIRT_ADDRESS (USER_SPACE_ADDR_BEGIN + (GB_SIZE * 512ULL * 48ULL))

typedef int32_t pid_t;
typedef struct ProcessorLocal ProcessorLocal;
typedef struct Task Task;

typedef struct VMMemoryBlockNode {
    LIST_STRUCT_IMPL(VMMemoryBlockNode);
    VMMemoryBlock block;
} VMMemoryBlockNode;

typedef struct ProcessAddressSpace {
    ListHead segments;
    VMMemoryBlockNode* interp_seg;

    VMHeap heap;

    uint64_t stack_base; // Top address of the start of the stack

    Spinlock lock;

    PageMapLevel4Entry* page_table;
} ProcessAddressSpace;

typedef struct VMPageFrameNode {
    LIST_STRUCT_IMPL(VMPageFrameNode);
    VMPageFrame frame;
} VMPageFrameNode;

typedef struct Process {
    LIST_STRUCT_IMPL(Process);

    struct Process* parent;

    ListHead childs;

    pid_t pid;

    ProcessAddressSpace addr_space;
    ListHead vm_pages;
    Spinlock vm_lock;

    VfsDentry* work_dir;

    FileDescriptor** files;
    uint32_t files_capacity;
    Spinlock files_lock;

    uint32_t result_value;
} Process;

typedef enum TaskState {
    TSK_STATE_EXEC = 0,
    TSK_STATE_AFTER_FORK,
    TSK_STATE_SWITCH,
    TSK_STATE_WAIT,

    TSK_STATE_NONE
} TaskState;

typedef struct Task {
    LIST_STRUCT_IMPL(Task);

    Process* process;
    
    union {
        uint64_t ip; // Temporary storage for instruction pointer
        uint64_t state;
    };

    Thread thread;
} Task;

bool_t load_init_proc();

pid_t proc_generate_id();
void proc_release_id(pid_t id);

Process* proc_new();
void proc_delete(Process* process);

void log_process(const Process* process);

VMMemoryBlockNode* proc_push_segment(Process* const process);
VMMemoryBlockNode* proc_insert_segment(Process* const process, VMMemoryBlockNode* const prev_seg);
void proc_clear_segments(Process* const process);
bool_t proc_copy_segments(const Process* src_proc, Process* const dst_proc);
bool_t proc_copy_files(const Process* src_proc, Process* const dst_proc);
void proc_close_files(Process* const process);

VMPageFrameNode* proc_push_vm_page(Process* const process);
void proc_dealloc_vm_page(Process* const process, VMPageFrameNode* const page_frame);
void proc_dealloc_vm_pages(Process* const process);

void proc_shutdown(Task* const task, const int status_code);

char** proc_put_args_strings(uint64_t** const stack, char** strings, const uint32_t count);

static inline void proc_add_aux(Thread* const thread, const uint32_t type, const uint64_t value) {
    thread->stack_ptr -= sizeof(uint64_t) * 2;
    uint64_t* const dst = (uint64_t*)thread->stack_ptr;

    dst[0] = type;
    dst[1] = value;
}

long _sys_clone();
pid_t _sys_fork();
long _sys_execve(const char* filename, char** argv, char** envp);
long _sys_wait4(pid_t pid, int* stat_loc, int options);
void _sys_exit(int error_code);