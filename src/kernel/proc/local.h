#pragma once

#include <stddef.h>

#include "definitions.h"

#include "proc.h"

#include "vm/vm.h"

/*
Local data per logical processor.
*/

typedef struct ProcessorLocal {
    uint32_t idx;
    uint32_t ioapic_idx;

    uint64_t* kernel_stack;
    uint64_t* user_stack;

    Task* current_task;
    PageMapLevel4Entry* kernel_page_table;

    const char* kernel_error_str;

    // Filling to page size
    uint8_t __page_size_filler[PAGE_BYTE_SIZE - 48];
} ProcessorLocal;

extern ProcessorLocal g_proc_local;

bool_t init_proc_local();

ProcessorLocal* _proc_get_local_data_by_idx(const uint32_t cpu_idx);