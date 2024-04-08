#include "math.h"

uint32_t log2(uint32_t number)
{
    number |= (number >> 1);
    number |= (number >> 2);
    number |= (number >> 4);
    number |= (number >> 8);
    number |= (number >> 16);

    return (popcount(number) - 1);
}