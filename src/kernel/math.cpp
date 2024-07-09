#include "math.h"

uint32_t log2(uint32_t number) {
    number |= (number >> 1);
    number |= (number >> 2);
    number |= (number >> 4);
    number |= (number >> 8);
    number |= (number >> 16);

    return (popcount(number) - 1);
}

uint64_t pow(const uint64_t value, uint64_t power) {
    if (power <= 1) return 1;

    uint64_t return_value = value;

    while (power > 1) {
        return_value *= value;

        --power;
    }

    return return_value;
}