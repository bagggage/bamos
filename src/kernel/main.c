/*
 * mykernel/c/kernel.c
 *
 * Copyright (C) 2017 - 2021 bzt (bztsrc@gitlab)
 *
 * Permission is hereby granted, free of charge, to any person
 * obtaining a copy of this software and associated documentation
 * files (the "Software"), to deal in the Software without
 * restriction, including without limitation the rights to use, copy,
 * modify, merge, publish, distribute, sublicense, and/or sell copies
 * of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be
 * included in all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
 * EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
 * MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
 * NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
 * HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
 * WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 * DEALINGS IN THE SOFTWARE.
 *
 * This file is part of the BOOTBOOT Protocol package.
 * @brief A sample BOOTBOOT compatible kernel
 *
 */

/* function to display a string, see below */
void puts(char *s);

/* we don't assume stdint.h exists */
typedef short int           int16_t;
typedef unsigned char       uint8_t;
typedef unsigned short int  uint16_t;
typedef unsigned int        uint32_t;
typedef unsigned long int   uint64_t;

#include <bootboot.h>

/* imported virtual addresses, see linker script */
extern BOOTBOOT bootboot;               // see bootboot.h
extern unsigned char environment[4096]; // configuration, UTF-8 text key=value pairs
extern uint8_t fb;                      // linear framebuffer mapped

/******************************************
 * Entry point, called by BOOTBOOT Loader *
 ******************************************/
void _start()
{
    /*** NOTE: this code runs on all cores in parallel ***/
    int x, y, s=bootboot.fb_scanline, w=bootboot.fb_width, h=bootboot.fb_height;

    if(s) {
        // cross-hair to see screen dimension detected correctly
        for(y=0;y<h;y++) { *((uint32_t*)(&fb + s*y + (w*2)))=0x00FFFFFF; }
        for(x=0;x<w;x++) { *((uint32_t*)(&fb + s*(h/2)+x*4))=0x00FFFFFF; }

        // red, green, blue boxes in order
        for(y=0;y<20;y++) { for(x=0;x<20;x++) { *((uint32_t*)(&fb + s*(y+20) + (x+20)*4))=0x00FF0000; } }
        for(y=0;y<20;y++) { for(x=0;x<20;x++) { *((uint32_t*)(&fb + s*(y+20) + (x+50)*4))=0x0000FF00; } }
        for(y=0;y<20;y++) { for(x=0;x<20;x++) { *((uint32_t*)(&fb + s*(y+20) + (x+80)*4))=0x000000FF; } }

        // say hello
        puts("Hello from a simple BOOTBOOT kernel");
    }
    // hang for now
    while(1);
}

/**************************
 * Display text on screen *
 **************************/
struct Font {
  uint8_t *glyphs;
  uint32_t length;
  uint32_t charsize;
  uint32_t height;
  uint32_t width;
};

// Ver 1
struct PSF1 {
  uint16_t magic; /* 0x0436 */
  uint8_t flags;  /* how many glyps and if unicode, etc. */
  uint8_t height; /* height; width is always 8 */
                  /* glyphs start here */
};
#define PSF1_MODE512 0x01
#define PSF1_MAGIC 0x0436

// Ver 2
struct PSF2 {
  uint32_t magic; /* 0x864ab572 */
  uint32_t version;
  uint32_t headersize; /* offset of bitmaps in file */
  uint32_t flags;
  uint32_t length;   /* number of glyphs */
  uint32_t charsize; /* number of bytes for each character */
  uint32_t height;   /* dimensions of glyphs */
  uint32_t width;
  /* glyphs start here */
} __attribute__((packed));
#define PSF2_MAGIC 0x864ab572

struct Font font;

extern volatile unsigned char _binary_font_psf_start;

void load_font() {
  if (*((uint16_t *)&_binary_font_psf_start) == PSF1_MAGIC) {
    const struct PSF1 *psf1 = (const struct PSF1 *)&_binary_font_psf_start;
    font.glyphs = (uint8_t *)&_binary_font_psf_start + sizeof(struct PSF1);
    font.length = (psf1->flags & PSF1_MODE512) ? 512 : 256;
    font.charsize = psf1->height;
    font.width = 8;
    font.height = psf1->height;
    return;
  }

  if (*((uint32_t *)&_binary_font_psf_start) == PSF2_MAGIC) {
    const struct PSF2 *psf2 = (const struct PSF2 *)&_binary_font_psf_start;
    font.glyphs = (uint8_t *)&_binary_font_psf_start + psf2->headersize;
    font.length = psf2->length;
    font.charsize = psf2->charsize;
    font.width = psf2->width;
    font.height = psf2->height;
  }
}

void puts(char *s)
{
    load_font();

    int offset = 0;
    int bpl = (font.width + 7) / 8;

    while(*s) {
        const uint8_t *const glyph = font.glyphs + *s * font.charsize;
        int curr_offset = offset;

        for (int y = 0; y < font.height; ++y)
        {
            int y_bit_idx = 0;
            int mask = (1 << (font.width - 1));

            for (int x = 0; x < font.width; ++x)
            {
                *(uint32_t*)(&fb + curr_offset + (x << 2)) = (glyph[y] & mask ? 0xFFFFFFFF : 0x00000000);
                mask >>= 1;
            }

            curr_offset += bootboot.fb_scanline;
        }

        offset += font.width << 2;

        s++;
    }
}