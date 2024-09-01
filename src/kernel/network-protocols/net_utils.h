#pragma once

#include "definitions.h"
#include "utils.h"

static inline uint16_t flip_short(uint16_t short_int) {
    return (short_int >> 8) | (short_int << 8);
}

static inline uint32_t flip_int(uint32_t nb) {
    return ((nb >> 24) & 0xff) |
        ((nb << 8) & 0xff0000) |
        ((nb >> 8) & 0xff00) |
        ((nb << 24) & 0xff000000);
}