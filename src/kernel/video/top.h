#pragma once

#include "definitions.h"

/*
Kernel text output protocol (TOP).
Used for printing text into display framebuffer.
TOP uses text buffer in case to save printed chars and use them when scrolling.

The text buffer contains only current charactes displayed on the screen.
All blank charactes are filled with '\0', only space and new line charactes are saves in same format.

Special characters handling:
'\0' - draws as blank character and move cursor forward, petty same as space character.
'\n' - put the cursor at the begining of next line. At last line invokes scolling.
'\r' - move cursor down on one line.
'\b' - move cursor back on one column and clear character. At beginning of first line just clear current char.
'\t' - clear next six characters and move cursor on six columns.
*/

// Color structure
typedef struct TOPColor {
    uint8_t r, g, b, a;
};

// Init kernel text output protocol.
Status init_top();

// Draws character at the current cursor state.
void top_draw_char(const char c);

// Redraws entire view with the content stored in the text buffer. Leaves the cursor unchanged.
void top_redraw();

uint16_t top_get_cursor_row();
uint16_t top_get_cursor_col();

// Set cursor position. If position goes outside it will be cliped.
void top_set_cursor_pos(const uint16_t row, const uint16_t col);

// Returns current cursor color in packed format.
uint32_t top_get_cursor_color();
// Returns current cursor color in struct format.
TOPColor top_get_cursor_color_struct();

// Set cursor color directly by packed 4 byte value.
void top_set_cursor_color(const uint32_t color);
// Set cursor color by RGB channels.
void top_set_cursor_color_rgb(const uint8_t r, const uint8_t g, const uint8_t b);
// Set cursor color by color struct
void top_set_cursor_color_struct(const TOPColor color);

// Print string using current cursor state. Special characters are handled.
void top_puts(const char* string);
// Print character using current cursor state. Special characters are handled.
void top_putc(const char c);

// Scroll whole view by given rows offset and redraw it. May clear top rows content, so save it before if needed. 
void top_scroll_view(uint16_t rows_offset);

// Clear view and text buffer.
void top_clear();
