#pragma once

#include "stdint.h"

// Kernel defenitions used in implementetion

#ifndef NULL
    #define NULL ((void*)0)
#endif

#ifdef TRUE
    #undef TRUE
#endif
#ifdef FALSE
    #undef FALSE
#endif

typedef uint8_t bool_t;
typedef uint64_t size_t;

#define TRUE 1
#define FALSE 0

// Result of the operation
typedef enum Status {
    KERNEL_OK = 0,
    KERNEL_COUGHT,
    KERNEL_INVALID_ARGS,
    KERNEL_ERROR,
    KERNEL_PANIC,
} Status;

#define ATTR_PACKED __attribute__((packed))