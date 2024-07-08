#pragma once

#include "definitions.h"

class Framebuffer;
struct DebugSymbolTable;

class Boot {
public:
    static void get_fb(Framebuffer* const fb);

    static uint32_t get_cpus_num();
    static const DebugSymbolTable* get_dbg_table();
};