#pragma once

#include "definitions.h"
#include "intr/intr.h"
#include "logger.h"

#ifdef KDEBUG
static inline void _kernel_assert(const char* expression_str,
                                unsigned int line,
                                const char* file_str,
                                const char* func_str) {
    kernel_error("Assertion failed: (%s)\n%s:%u \'%s\'\n",
                expression_str,
                file_str,
                line,
                func_str);
#ifdef KTRACE
    log_trace(0);
#endif
}

#define kassert(expression) \
{ \
    if (!(expression)) { \
         _kernel_assert(#expression, (__LINE__), (__FILE__), (__PRETTY_FUNCTION__)); \
         _kernel_break(); \
    } \
}
#else
#define kassert
#endif