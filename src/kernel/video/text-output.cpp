#include "text-output.h"

#include "boot.h"

#include "utils/string.h"

Framebuffer TextOutput::fb = {};
RawFont     TextOutput::font = {};
Cursor      TextOutput::cursor = {};
uint16_t    TextOutput::cols = {};
uint16_t    TextOutput::rows = {};
uint32_t    TextOutput::curr_col = {};

extern const uint8_t _binary_font_psf_start;

typedef __attribute__((vector_size(32), aligned(256))) long long m256i;

static inline void fast_memcpy256(const void* src, void* dst, const size_t size) {
    m256i* dst_vec = (m256i*)dst;
    const m256i* src_vec = (const m256i*)src;

    size_t count = size / sizeof(m256i);

    for (; count > 0; count -= 4, src_vec += 4, dst_vec += 4) {
        *dst_vec = *src_vec;
        *(dst_vec + 1) = *(src_vec + 1);
        *(dst_vec + 2) = *(src_vec + 2);
        *(dst_vec + 3) = *(src_vec + 3);
    }
}

static inline void fast_memset256(void* const dst, const size_t size, const uint8_t value) {
    m256i val;

    for (uint64_t i = 0; i < sizeof(m256i) / sizeof(uint64_t); ++i) ((uint64_t*)&val)[i] = value;

    m256i* dst_vec = (m256i*)dst;
    size_t count = size / sizeof(m256i);

    for (; count > 0; count -= 4, dst_vec += 4) {
        *dst_vec       = val;
        *(dst_vec + 1) = val;
        *(dst_vec + 2) = val;
        *(dst_vec + 3) = val;
    }
}

uint64_t TextOutput::calc_fb_offset() {
    return (static_cast<uint64_t>(cursor.row) * (static_cast<uint64_t>(fb.scanline) * font.height)) +
        ((cursor.col * font.width) * sizeof(uint32_t));
}

void TextOutput::scroll_fb(uint8_t rows_offset) {
    const size_t rows_byte_offset = static_cast<uint64_t>(rows_offset) * fb.scanline * font.height;
    const size_t fb_size = static_cast<uint64_t>(fb.height) * fb.scanline;

    fast_memcpy256(reinterpret_cast<void*>(fb.base + rows_byte_offset), reinterpret_cast<void*>(fb.base), fb_size - rows_byte_offset);
    fast_memset256(reinterpret_cast<void*>(fb.base + (fb_size - rows_byte_offset)), rows_byte_offset, 0);
}

void TextOutput::init() {
    Boot::get_fb(&fb);
    RawFont::init(&font, static_cast<const void*>(&_binary_font_psf_start));

    rows = fb.height / font.height;
    cols = fb.width / font.width;

    cursor = { 0, 0 };
    curr_col = Color(COLOR_LRED).pack(fb.format);
}

// FIXME: when array size set to uint32_max - program terminated 1 error
static uint32_t last_cursor_positions_in_columns[UINT16_MAX];

void TextOutput::move_cursor(int8_t row_offset, int8_t col_offset) {
    if (col_offset > 0 || static_cast<int16_t>(cursor.col) >= -col_offset) {
        cursor.col += col_offset;
    }
    else {
        if (cursor.row == cursor.col && cursor.col == 0) return;

        row_offset -= ((-col_offset) / cols) + 1;

        (cursor.row > 0) ?
        (cursor.col = last_cursor_positions_in_columns[cursor.row - 1]) :
        (cursor.col = 0);
    }

    if (row_offset > 0 || (int64_t)cursor.row >= -row_offset) {
        last_cursor_positions_in_columns[cursor.row] = cursor.col;
        cursor.row += row_offset;
    }

    if (cursor.col >= cols) {
        last_cursor_positions_in_columns[cursor.row] = cols;
        cursor.col = cursor.col % cols;
        ++cursor.row;
    }
    if (cursor.row >= rows) {
        scroll_fb((cursor.row - rows) + 1);
        cursor.row = rows - 1;
    }
}

void TextOutput::print(const char* string) {
    while (*string != '\0') print(*(string++));
}

void TextOutput::print(const char* string, const size_t length) {
    for (size_t i = 0; i < length; ++i) print(string[i]);
}

void TextOutput::print(const char c) {
    if (c == '\0') return;
    if (c == '\n') {
        move_cursor(1, 0);
        cursor.col = 0;

        return;
    }

    uint64_t curr_offset;

    if (c == '\b') {
        move_cursor(0, -1);
        curr_offset = calc_fb_offset();

        for (uint32_t y = 0; y < font.height; ++y) {
            for (uint32_t x = 0; x < font.width; ++x) {
                *(uint32_t*)(fb.base + curr_offset + (x << 2)) = 0x00000000;
            }

            curr_offset += fb.scanline;
        }

        return;
    }

    const uint8_t* const glyph = font.glyphs + (font.charsize * c);
    curr_offset = calc_fb_offset();

    for (uint32_t y = 0; y < font.height; ++y) {
        uint32_t mask = (1 << (font.width - 1));

        for (uint32_t x = 0; x < font.width; ++x) {
            const uint32_t color = (glyph[y] & mask ? curr_col : 0x0);
            *reinterpret_cast<uint32_t*>(fb.base + curr_offset + (x << 2)) = color;
            mask >>= 1;
        }

        curr_offset += fb.scanline;
    }

    move_cursor(0, 1);
}

void TextOutput::clear() {
    cursor.col = 0;
    cursor.row = 0;

    const size_t fb_size = (static_cast<uint64_t>(fb.height) * fb.scanline);

    fast_memset256(reinterpret_cast<void*>(fb.base), fb_size, 0);
}

Color TextOutput::get_color() {
    return Color::unpack(fb.format, curr_col);
}

void TextOutput::set_color(const uint8_t r, const uint8_t g, const uint8_t b) {
    set_color(Color(r, g, b));
}

void TextOutput::set_color(const Color color) {
    curr_col = color.pack(fb.format);
}