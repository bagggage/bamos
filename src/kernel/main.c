#include <bootboot.h>

#include "definitions.h"

void puts(char *s);

/* we don't assume stdint.h exists */
typedef short int int16_t;
typedef unsigned char uint8_t;
typedef unsigned short int uint16_t;
typedef unsigned int uint32_t;
typedef unsigned long int uint64_t;

void print_hex16(uint16_t x);

#include "ps2_dirver.h"

/* imported virtual addresses, see linker script */
extern BOOTBOOT bootboot;               // see bootboot.h
extern unsigned char environment[4096]; // configuration, UTF-8 text key=value pairs

// Entry point, called by BOOTBOOT Loader
void _start() {
  Status status = init_kernel();

  if (status == KERNEL_PANIC) {
    // TODO: handle kernel panic
  }

  // TODO: handle user space, do some stuff

  while (1);
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

void print_hex16(uint16_t x) {
  const char *hex = "0123456789ABCDEF";

  char buf[2 * sizeof(x) + 1];
  buf[sizeof(buf) - 1] = '\0';

  char *p = buf + sizeof(buf) - 2;

  while (1) {
    *p = hex[x & 0xF];

    x >>= 4;

    if (p == buf) break;

    --p;
  }

  puts(buf);
}