#pragma once

#include "definitions.h"

class String {
public:
    static inline size_t len(const char* string) {
        size_t result = 0;

        while (*(string++) != '\0') result++;

        return result;
    }
};