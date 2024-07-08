#pragma once

#include "fb.h"
#include "font.h"

#define COLOR_BLACK     0,      0,      0
#define COLOR_WHITE     255,    255,    255
#define COLOR_GRAY      128,    128,    128
#define COLOR_LGRAY     165,    165,    165
#define COLOR_RED       255,    0,      0
#define COLOR_LRED      250,    5,      50
#define COLOR_GREEN     0,      255,    0
#define COLOR_LGREEN    5,      250,    70
#define COLOR_BLUE      0,      0,      255
#define COLOR_LBLUE     5,      70,     250
#define COLOR_YELLOW    250,    240,    5
#define COLOR_LYELLOW   255,    235,    75
#define COLOR_ORANGE    255,    165,    0

struct Cursor {
    uint16_t row = 0;
    uint16_t col = 0;
};

class TextOutput {
private:
    static Framebuffer fb;
    static RawFont font;

    static Cursor cursor;
    static uint16_t cols;
    static uint16_t rows;

    static uint32_t curr_col;

    static uint64_t calc_fb_offset();
    static void scroll_fb(uint8_t rows_offset);
public:
    static void init();

    static void print(const char* string);
    static void print(const char* string, const size_t length);
    static void print(const char c);

    static void move_cursor(int8_t row_offset, int8_t col_offset);

    static void clear();

    static Color get_color();
    static void set_color(const uint8_t r, const uint8_t g, const uint8_t b);
    static void set_color(const Color color);
};