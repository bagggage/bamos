#pragma once

#include "definitions.h"

/*
Kernel math library.
*/

//extern bool_t _is_cpu_popcnt;

static inline uint32_t popcount(const uint32_t number) {
    uint32_t result = number;

    //if (_is_cpu_popcnt) {
    //    asm volatile("popcnt %1,%0":"=r"(result):"r"(number));
//
    //}
    //else {
        result = (result & 0x55555555u) + ((result >> 1) & 0x55555555u);
        result = (result & 0x33333333u) + ((result >> 2) & 0x33333333u);
        result = (result & 0x0f0f0f0fu) + ((result >> 4) & 0x0f0f0f0fu);
        result = (result & 0x00ff00ffu) + ((result >> 8) & 0x00ff00ffu);
        result = (result & 0x0000ffffu) + ((result >>16) & 0x0000ffffu);
    //}

    return result;
}

static inline uint64_t div_with_roundup(const uint64_t value, const uint64_t divider) {
    return (value / divider) + ((value % divider) == 0 ? 0 : 1);
}

uint32_t log2(uint32_t number);

static inline uint32_t log2upper(uint32_t number) {
    return (popcount(number) > 1) ? (log2(number) + 1) : log2(number);
}