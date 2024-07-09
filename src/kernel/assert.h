#pragma once

#include "logger.h"

#ifdef KDEBUG
static inline void _kernel_assert(
    const char* expr_str,
    unsigned int line,
    const char* file_str,
    const char* func_str
) {
    error("Assertion failed: (", expr_str, ")\n", file_str,':',line," '",func_str,'\'');
}

#define kassert(expression) \
{ \
    if (!(expression)) { \
        _kernel_assert(#expression, (__LINE__), (__FILE__), (__PRETTY_FUNCTION__)); \
        _kernel_break(); \
    } \
}
#else
#define kassert(a)
#endif