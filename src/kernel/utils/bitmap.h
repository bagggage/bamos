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
        const uint8_t bitmask = 1 << (bit_idx % BYTE_SIZE);

        return bytes[bit_idx / BYTE_SIZE] & bitmask;
    }

    inline void clear(const size_t bit_idx) {
        const uint8_t bitmask = 1 << (bit_idx % BYTE_SIZE);

        bytes[bit_idx / BYTE_SIZE] &= ~bitmask;
    }

    inline void set(const size_t bit_idx) {
        const uint8_t bitmask = 1 << (bit_idx % BYTE_SIZE);

        bytes[bit_idx / BYTE_SIZE] |= bitmask;
    }

    inline void inverse(const size_t bit_idx) {
        const uint8_t bitmask = 1 << (bit_idx % BYTE_SIZE);

        bytes[bit_idx / BYTE_SIZE] ^= bitmask;
    }

    inline uint32_t find_clear() {
        uint32_t bit_idx = 0;

        while (bytes[bit_idx / BYTE_SIZE] == 0xFF) bit_idx += BYTE_SIZE;

        const uint8_t byte = bytes[bit_idx / BYTE_SIZE];
        const uint32_t end = bit_idx + BYTE_SIZE;
        uint8_t bitmask = 1;

        for (; bit_idx < end; ++bit_idx) {
            if ((byte & bitmask) == 0) return bit_idx;

            bitmask <<= 1;
        }

        return bit_idx;
    }
};