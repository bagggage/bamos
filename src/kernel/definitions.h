#pragma once

#include "stdint.h"

// Kernel defenitions used in implementetion

#define XSTRINGIFY(x) STRINGIFY(x)
#define STRINGIFY(x) #x

#ifndef NULL
    #define NULL ((void*)0)
#endif

#ifdef TRUE
    #undef TRUE
#endif
#ifdef FALSE
    #undef FALSE
#endif

#define UNUSED(x) (void)(x)
#define USE(x)      asm volatile(""::"g"(x))

typedef uint8_t bool_t;
typedef uint64_t size_t;
typedef __int128_t int128_t;
typedef __uint128_t uint128_t;

typedef union {
    struct {
        uint32_t lo;
        uint32_t hi;
    };
    uint64_t val;
} uint64_32_t;

#define TRUE 1
#define FALSE 0

// Result of the operation
typedef enum Status {
    KERNEL_OK = 0,
    KERNEL_COUGH,
    KERNEL_INVALID_ARGS,
    KERNEL_ERROR,
    KERNEL_PANIC,
} Status;

#define BYTE_SIZE 8
#define KB_SIZE 1024U
#define MB_SIZE ((uint64_t)KB_SIZE * 1024U)
#define GB_SIZE (MB_SIZE * 1024U)

#define ATTR_ALIGN(align)   __attribute__((aligned(align)))
#define ATTR_PACKED         __attribute__((packed))
#define ATTR_INTRRUPT       __attribute__((interrupt, target("general-regs-only")))
#define ATTR_NORETURN       __attribute__((noreturn))
#define ATTR_USED           __attribute__((used))
#define ATTR_INLINE_ASM     inline __attribute__((always_inline, target("general-regs-only")))
#define ATTR_NAKED          __attribute__((naked))

#define FALLTHROUGH __attribute__ ((fallthrough))

static ATTR_INLINE_ASM void _hlt() { asm volatile("hlt"); }

static inline ATTR_NORETURN void _kernel_break() { while(1) _hlt(); }