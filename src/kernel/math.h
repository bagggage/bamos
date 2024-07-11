#pragma once

#include "definitions.h"

static constexpr uint64_t div_roundup(const uint64_t arg, const uint64_t divider) {
    return (arg / divider) + ((arg % divider) == 0 ? 0 : 1);
}

template<typename T1, typename T2>
static inline constexpr T1 min(const T1& lhs, const T2& rhs) {
    return (lhs <= rhs) ? lhs : static_cast<T1>(rhs);
}

template<typename T1, typename T2>
static inline constexpr T1 max(const T1& lhs, const T2& rhs) {
    return (lhs >= rhs) ? lhs : static_cast<T1>(rhs);
}

static inline uint32_t popcount(const uint32_t number) {
    uint32_t result = number;

    result = (result & 0x55555555u) + ((result >> 1) & 0x55555555u);
    result = (result & 0x33333333u) + ((result >> 2) & 0x33333333u);
    result = (result & 0x0f0f0f0fu) + ((result >> 4) & 0x0f0f0f0fu);
    result = (result & 0x00ff00ffu) + ((result >> 8) & 0x00ff00ffu);
    result = (result & 0x0000ffffu) + ((result >>16) & 0x0000ffffu);

    return result;
}

uint32_t log2(uint32_t number);

static inline uint32_t log2upper(uint32_t number) {
    return (popcount(number) > 1) ? (log2(number) + 1) : log2(number);
}

static inline uint32_t bcd_to_decimal(const uint32_t bcd) {
    return ((bcd / 16 * 10) + (bcd % 16));
}

static inline uint32_t decimal_to_bcd(const uint32_t decimal) {
    return ((decimal / 10 * 16) + (decimal % 10));
}

uint32_t log2(uint32_t number);
uint64_t pow(const uint64_t value, uint64_t power);