#pragma once

#include "logger.h"
#include "trace.h"

#ifdef KDEBUG
static ATTR_INLINE_ASM void _kernel_assert(
    const char* expr_str,
    unsigned int line,
    const char* file_str
) {
    error("Assertion failed: (", expr_str, ")\n", file_str, ':', line);
    trace();
}

#define kassert(expression) \
{ \
    if (!(expression)) { \
        _kernel_assert(#expression, (__LINE__), (__FILE__)); \
        _kernel_break(); \
    } \
}
#else
#define kassert(a)
#endif