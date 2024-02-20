#include "font.h"

#define PSF1_MODE512 0x01
#define PSF1_MAGIC 0x0436

// Ver 1
typedef struct PSF1 {
    uint16_t magic; // 0x0436
    uint8_t flags;  // how many glyps and if unicode, etc.
    uint8_t height; // height; width is always 8
    /* glyphs start here */
} PSF1;

#define PSF2_MAGIC 0x864ab572

// Ver 2
typedef struct PSF2 {
    uint32_t magic; // 0x864ab572
    uint32_t version;
    uint32_t headersize; // offset of bitmaps in file
    uint32_t flags;
    uint32_t length;   // number of glyphs
    uint32_t charsize; // number of bytes for each character
    uint32_t height;   // dimensions of glyphs
    uint32_t width;
    /* glyphs start here */
} __attribute__((packed)) PSF2;

Status load_raw_font(const uint8_t* font_binary_ptr, RawFont* out) {
    if (*((const uint16_t*)font_binary_ptr) == PSF1_MAGIC) {
        const PSF1 *psf1 = (const PSF1*)font_binary_ptr;
        out->glyphs = font_binary_ptr + sizeof(PSF1);
        out->length = (psf1->flags & PSF1_MODE512) ? 512 : 256;
        out->charsize = psf1->height;
        out->width = 8;
        out->height = psf1->height;
    }
    else if (*((const uint32_t*)font_binary_ptr) == PSF2_MAGIC) {
        const PSF2 *psf2 = (const PSF2*)font_binary_ptr;
        out->glyphs = font_binary_ptr + psf2->headersize;
        out->length = psf2->length;
        out->charsize = psf2->charsize;
        out->width = psf2->width;
        out->height = psf2->height;
    }
    else {
        return KERNEL_INVALID_ARGS;
    }

    return KERNEL_OK;
}