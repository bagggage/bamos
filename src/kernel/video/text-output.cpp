#include "text-output.h"

#include "assert.h"
#include "arch.h"
#include "boot.h"
#include "logger.h"

#include "vm/vm.h"

#include "utils/string.h"

Framebuffer TextOutput::fb = {};
char*       TextOutput::buffer = nullptr;
RawFont     TextOutput::font = {};
uint32_t*   TextOutput::font_texture = 0;
Cursor      TextOutput::cursor = {};
uint16_t    TextOutput::cols = {};
uint16_t    TextOutput::rows = {};
uint32_t    TextOutput::curr_col = {};

extern const uint8_t _binary_font_psf_start;

typedef __attribute__((vector_size(32), aligned(256))) long long m256i;

static void __attribute__((target("avx2")))
fast_memcpy256(const void* src, void* dst, const size_t size) {
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

static void __attribute__((target("avx2")))
fast_memset256(void* const dst, const size_t size, const uint8_t value) {
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

uint64_t TextOutput::calc_fb_offset(const uint32_t row, const uint32_t col) {
    return (static_cast<uint64_t>(row) *
        (static_cast<uint64_t>(fb.scanline) * font.height)) +
        ((col * font.width) * sizeof(uint32_t));
}

void TextOutput::fast_blt(const uintptr_t src, const uintptr_t dst, const uint32_t width, const uint32_t height) {
    const auto width_size = div_roundup(width * sizeof(uint32_t), 256) * 256;
    size_t offset = 0;

    for (auto i = 0u; i < height; ++i) {
        fast_memcpy256(
            reinterpret_cast<void*>(src + offset),
            reinterpret_cast<void*>(dst + offset),
            width_size
        );

        offset += fb.scanline;
    }
}

void TextOutput::scroll_fb(uint8_t rows_offset) {
    const auto fb_size = fb.scanline * fb.height;
    const auto row_size = fb.scanline * font.height;
    size_t buff_offset = 0;

    for (auto row = 1u; row < rows; ++row) {
        buff_offset += cols;

        for (auto col = 0u; col < cols; ++col) {
            const auto prev_offset = buff_offset - cols;
            const char c = buffer[buff_offset + col];

            if (c == '\n' || c == '\0') [[unlikely]] {
                char prev_c = buffer[prev_offset + col];

                while (prev_c != '\0' && prev_c != '\n' && col < cols) {
                    draw(' ', row - 1, col);
                    buffer[prev_offset + col] = '\0';

                    ++col;
                    prev_c = buffer[prev_offset + col];
                }

                break;
            }

            buffer[prev_offset + col] = c;

            draw(c, row - 1, col);
        }
    }

    fast_memset256(reinterpret_cast<void*>(fb.base + fb_size - row_size), row_size, 0);
}

static void render_font_texture(uint32_t* const texture, const RawFont& font) {
    uint32_t curr_offset = 0;

    for (auto c = 0u; c < 256; ++c) {
        const uint8_t* const glyph = font.glyphs + (font.charsize * c);

        for (uint32_t y = 0; y < font.height; ++y) {
            uint32_t mask = (1 << (font.width - 1));

            for (uint32_t x = 0; x < font.width; ++x) {
                const uint32_t color = (glyph[y] & mask ? 0xFFFFFFFF : 0x0);
                texture[curr_offset + x] = color;

                mask >>= 1;
            }

            curr_offset += font.width;
        }
    }
}

void TextOutput::init() {
    Boot::get_fb(&fb);
    RawFont::init(&font, static_cast<const void*>(&_binary_font_psf_start));

    const uint32_t texture_size = font.width * font.height * 256 * sizeof(uint32_t);

    font_texture = reinterpret_cast<uint32_t*>(Boot::alloc(div_roundup(texture_size, Arch::page_size)));
    font_texture = VM::get_virt_dma(font_texture);

    render_font_texture(font_texture, font);

    rows = fb.height / font.height;
    cols = fb.width / font.width;

    cursor = { 0, 0 };
    curr_col = Color(COLOR_LRED).pack(fb.format);

    const auto buffer_pages = div_roundup(rows * cols, Arch::page_size);
    buffer = reinterpret_cast<char*>(Boot::alloc(buffer_pages));
    buffer = VM::get_virt_dma(buffer);

    fast_memset256(buffer, buffer_pages * Arch::page_size, 0x0);
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
    if (c == '\0') [[unlikely]] return;
    if (c == '\b') [[unlikely]] {
        move_cursor(0, -1);
        draw(' ', cursor.row, cursor.col);

        return;
    }

    buffer[(cursor.row * cols) + cursor.col] = c;

    if (c == '\n') [[unlikely]] {
        move_cursor(1, 0);
        cursor.col = 0;

        return;
    }

    draw(c, cursor.row, cursor.col);
    move_cursor(0, 1);
}

__attribute__((target("avx2")))
void TextOutput::draw(const char c, const uint16_t row, const uint16_t col) {
    uint64_t curr_offset;

    const uint32_t* glyph = font_texture + ((font.width * font.height) * c);
    curr_offset = calc_fb_offset(row, col);

    const uint32_t color_arr[] = { curr_col, curr_col, curr_col, curr_col, curr_col, curr_col, curr_col, curr_col };

    const m256i color = *(const m256i*)reinterpret_cast<const void*>(&color_arr);
    const uint32_t size = font.width * sizeof(uint32_t);

    for (auto y = 0u; y < font.height; ++y) {
        const void* dst = reinterpret_cast<void*>(fb.base + curr_offset);
        const void* src = glyph;

        {
            m256i* dst_vec = (m256i*)dst;
            const m256i* src_vec = (const m256i*)src;

            *dst_vec = (*src_vec & color);
        }

        glyph += font.width;
        curr_offset += fb.scanline;
    }

    //const uint8_t* const glyph = font.glyphs + (font.charsize * c);
    //curr_offset = calc_fb_offset();
//
    //for (uint32_t y = 0; y < font.height; ++y) {
    //    uint32_t mask = (1 << (font.width - 1));
//
    //    for (uint32_t x = 0; x < font.width; ++x) {
    //        const uint32_t color = (glyph[y] & mask ? curr_col : 0x0);
    //        *reinterpret_cast<uint32_t*>(double_base + curr_offset + (x << 2)) = color;
    //        mask >>= 1;
    //    }
//
    //    curr_offset += fb.scanline;
    //}
}

void TextOutput::clear() {
    cursor.col = 0;
    cursor.row = 0;

    const auto fb_size = static_cast<uint64_t>(fb.height) * fb.scanline;
    const auto buffer_size = div_roundup(rows * cols, Arch::page_size) * Arch::page_size;

    fast_memset256(buffer, buffer_size, 0);
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