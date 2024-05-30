#pragma once 

#include "definitions.h"

inline bool_t is_ascii(const char c) {
    return (((c >= ' ') && (c <= '~')) || ((c == '\n') || (c == '\b'))) ? TRUE : FALSE;
}

bool_t is_buffer_binary(const char* const buffer);