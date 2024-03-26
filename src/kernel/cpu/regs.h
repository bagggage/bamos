#pragma once

#include "definitions.h"

static inline uint64_t cpu_get_rsp() {
    uint64_t rsp;

    asm volatile("mov %%rsp,%0":"=a"(rsp));

    return rsp;
}

static inline void cpu_set_rsp(uint64_t rsp) {
    asm volatile("mov %0,%%rsp"::"a"(rsp));
}

static inline uint64_t cpu_get_cr2() {
    uint64_t cr2;

    asm volatile("mov %%cr2,%0":"=a"(cr2));

    return cr2;
}

static inline uint64_t cpu_get_cr3() {
    uint64_t cr3;

    asm volatile("mov %%cr3,%0":"=a"(cr3));

    return cr3;
}