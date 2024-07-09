#pragma once

#include "definitions.h"

class Bitmap {
private:
    uint8_t* bytes = nullptr;
public:
    Bitmap() = default;
    Bitmap(uint8_t* const base)
    : bytes(base)
    {}

    inline uint8_t get(const size_t bit_idx) {
        const uint8_t bitmask = bit_idx % BYTE_SIZE;

        return bytes[bit_idx / BYTE_SIZE] & bitmask;
    }

    inline void clear(const size_t bit_idx) {
        const uint8_t bitmask = bit_idx % BYTE_SIZE;

        bytes[bit_idx / BYTE_SIZE] &= ~bitmask;
    }

    inline uint8_t set(const size_t bit_idx) {
        const uint8_t bitmask = bit_idx % BYTE_SIZE;

        bytes[bit_idx / BYTE_SIZE] |= bitmask;
    }

    inline uint8_t inverse(const size_t bit_idx) {
        const uint8_t bitmask = bit_idx % BYTE_SIZE;

        bytes[bit_idx / BYTE_SIZE] ^= bitmask;
    }
};