#pragma once

#include "sys/syscall.h"

static inline int open(const char* pathname, int flags) {
    return _syscall_arg2(SYS_OPEN, (_arg_t)pathname, flags);
}