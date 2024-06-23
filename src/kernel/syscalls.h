#pragma once

#include "definitions.h"

#define RFLAGS_IF (1 << 9)

extern void _syscall_handler();

void init_syscalls();

static ATTR_INLINE_ASM void sysret() {
    asm volatile("sysretq");
}

static ATTR_INLINE_ASM void store_rflags() {
    asm volatile (
        "pushfq \n"
        "pop %r11"
    );
}

static ATTR_INLINE_ASM uint64_t get_rflags() {
    uint64_t result;

    asm volatile(
        "pushfq \n"
        "pop %0"
        : "=g" (result)
    );

    return result;
}