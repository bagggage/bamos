#pragma once

#include "definitions.h"

struct RawFont {
    const uint8_t *glyphs;

    uint32_t length;
    uint32_t charsize;
    uint32_t height;
    uint32_t width;

    static void init(RawFont* const out, const void* data);
};