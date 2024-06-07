#pragma once

#include <stddef.h>

#include "definitions.h"

#include "proc.h"

#include "vm/vm.h"

/*
Local data per logical processor.
*/

typedef struct UserStack {
    uint64_t rflags;
    uint64_t return_address;
    uint64_t base_pointer;
} ATTR_PACKED UserStack;

typedef struct ProcessorLocal {
    uint32_t idx;
    uint32_t ioapic_idx;

    uint64_t* kernel_stack;
    UserStack* user_stack;
    uint64_t* instruction_ptr;

    Task* current_task;
    PageMapLevel4Entry* kernel_page_table;

    const char* kernel_error_str;

    // Filling to page size
    uint8_t __page_size_filler[PAGE_BYTE_SIZE - 56];
} ProcessorLocal;

extern ProcessorLocal g_proc_local;

bool_t init_proc_local();

ProcessorLocal** _proc_get_local_ptr(const uint32_t cpu_idx);
ProcessorLocal* _proc_get_local_data_by_idx(const uint32_t cpu_idx);

static inline ProcessorLocal* proc_get_local() {
    ProcessorLocal* result;

    asm volatile("mov %%gs:0,%0":"=g"(result));

    return result;
}