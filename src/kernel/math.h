#pragma once

#include "definitions.h"

/*
Kernel math library.
*/

static inline uint32_t popcount(const uint32_t number) {
    uint32_t result;

    asm volatile("popcnt %1,%0":"=r"(result):"r"(number));

    return result;
}

static inline uint64_t div_with_roundup(const uint64_t value, const uint64_t divider) {
    return (value / divider) + ((value % divider) == 0 ? 0 : 1);
}

uint32_t log2(uint32_t number);

static inline uint32_t log2upper(uint32_t number) {
    return (popcount(number) > 1) ? (log2(number) + 1) : log2(number);
}