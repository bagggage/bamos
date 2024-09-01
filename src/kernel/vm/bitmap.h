#pragma once

#include "definitions.h"

#define SET_BIT(bit) (1 << bit)
#define SET_BITS(first, last) (((1 << (last - first + 1)) - 1) << first)

static inline uint8_t _bitmap_get_bit(const uint8_t* bitmap, const uint32_t bit_idx) {
    return (bitmap[bit_idx / BYTE_SIZE] & (1 << (bit_idx % BYTE_SIZE)));
}

static inline void _bitmap_set_bit(uint8_t* bitmap, const uint32_t bit_idx) {
    bitmap[bit_idx / BYTE_SIZE] |= (1 << (bit_idx % BYTE_SIZE));
}

static inline void _bitmap_clear_bit(uint8_t* bitmap, const uint32_t bit_idx) {
    bitmap[bit_idx / BYTE_SIZE] &= ~(1 << (bit_idx % BYTE_SIZE));
}