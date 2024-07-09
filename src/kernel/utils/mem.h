#pragma once

#include "definitions.h"

template<typename T, typename V>
static inline void fill(T* buffer, const V& value, const size_t size) {
    for (auto i = 0; i < size; ++i) {
        buffer[i] = static_cast<const T>(value);
    }
}