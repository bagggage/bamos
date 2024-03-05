#pragma once

#include "definitions.h"

typedef struct RawFont {
    const uint8_t *glyphs;
    uint32_t length;
    uint32_t charsize;
    uint32_t height;
    uint32_t width;
} RawFont;

// Initialize RawFont structure with correct values, based on PSF1/PSF2 font binaries.
Status load_raw_font(const uint8_t* font_binary_ptr, RawFont* out);