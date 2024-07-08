#include "font.h"

#define PSF1_MODE512 0x01
#define PSF1_MAGIC 0x0436
#define PSF2_MAGIC 0x864ab572

struct ATTR_PACKED PSF1 {
    uint16_t magic; // 0x0436
    uint8_t flags;  // how many glyps and if unicode, etc.
    uint8_t height; // height; width is always 8

    uint8_t glyphs[];
};

struct ATTR_PACKED PSF2 {
    uint32_t magic; // 0x864ab572
    uint32_t version;
    uint32_t headersize; // offset of bitmaps in file
    uint32_t flags;
    uint32_t length;   // number of glyphs
    uint32_t charsize; // number of bytes for each character
    uint32_t height;   // dimensions of glyphs
    uint32_t width;

    uint8_t glyphs[];
};

void RawFont::init(RawFont* const out, const void* data) {
    if (*((const uint16_t*)data) == PSF1_MAGIC) {
        const PSF1* psf1 = reinterpret_cast<const PSF1*>(data);
        out->glyphs = psf1->glyphs;
        out->length = (psf1->flags & PSF1_MODE512) ? 512 : 256;
        out->charsize = psf1->height;
        out->width = 8;
        out->height = psf1->height;
    }
    else if (*((const uint32_t*)data) == PSF2_MAGIC) {
        const PSF2* psf2 = reinterpret_cast<const PSF2*>(data);
        out->glyphs = reinterpret_cast<const uint8_t*>(data) + psf2->headersize;
        out->length = psf2->length;
        out->charsize = psf2->charsize;
        out->width = psf2->width;
        out->height = psf2->height;
    }
}