#pragma once

#include "definitions.h"
#include "intr.h"

class Arch_x86_64 {
public:
    using Intr = Intr_x86_64;

    struct ATTR_PACKED StackFrame {
        StackFrame* next;
        uintptr_t ret_ptr;
    };
public:
    static void preinit();

    static uint32_t get_cpu_idx();
};