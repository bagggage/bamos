#pragma once

#include "definitions.h"
#include "arch.h"

struct ATTR_PACKED DebugSymbol {
    uint64_t address;
    uint32_t size;

    const char name[64];
};

struct DebugSymbolTable {
    uint64_t magic;
    uint64_t count;
    
    DebugSymbol symbols[];
};

void trace_init();

const DebugSymbol* trace_symbol(const uintptr_t func_ptr);

void trace();
void trace(const uintptr_t ip, const Arch::StackFrame* frame, const uint8_t depth);