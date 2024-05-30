#include "string_utils.h"

#include "mem.h"

bool_t is_buffer_binary(const char* const buffer) {
    if (buffer == NULL) return FALSE;

    const uint32_t buffer_len = strlen(buffer);

    for (uint32_t i = 0; i < buffer_len; ++i) {
        if (!is_ascii(buffer[i])) return TRUE;
    }

    return FALSE;
}