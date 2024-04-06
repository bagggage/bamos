#pragma once

#include "definitions.h"
#include "dev/display.h"

#include <stdarg.h>

/*
Raw kernel logger.
Can be used only after display device initialization.
*/

// Put delailed error message here

#define COLOR_BLACK     0,      0,      0
#define COLOR_WHITE     255,    255,    255
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

extern const char* error_str;

typedef enum LogType {
    LOG_MSG,
    LOG_WARN,
    LOG_ERROR
} LogType;

typedef struct Color {
    uint8_t r, g, b;
} Color;

bool_t is_logger_initialized();

// Initialize logger framebuffer just only with GOP framebuffer, needed for early acces before display initialized
Status init_kernel_logger_raw(const uint8_t* font_binary_ptr);
Status init_kernel_logger(Framebuffer* fb, const uint8_t* font_binary_ptr);

uint16_t kernel_logger_get_rows();
uint16_t kernel_logger_get_cols();

void kernel_logger_set_color(uint8_t r, uint8_t g, uint8_t b);
Color kernel_logger_get_color();

static inline void kernel_logger_set_color_struct(const Color color) {
    kernel_logger_set_color(color.r, color.g, color.b);
}

void kernel_logger_set_cursor_pos(uint16_t row, uint16_t col);

void raw_putc(char c);
void raw_puts(const char* string);

void raw_print_number(uint64_t number, bool_t is_signed, uint8_t notation);

void kernel_raw_log(LogType log_type, const char* fmt, va_list args);

// Prints log to display framebuffer
static inline void kernel_log(LogType log_type, const char* fmt, ...) {
    va_list args;

    va_start(args, fmt);
    kernel_raw_log(log_type, fmt, args);
    va_end(args);
}

// Prints message to log
static inline void kernel_msg(const char* fmt, ...) {
    va_list args;

    va_start(args, fmt);
    kernel_raw_log(LOG_MSG, fmt, args);
    va_end(args);
}

// Prints warning to log
static inline void kernel_warn(const char* fmt, ...) {
    va_list args;

    va_start(args, fmt);
    kernel_raw_log(LOG_WARN, fmt, args);
    va_end(args);
}

// Prints error to log
static inline void kernel_error(const char* fmt, ...) {
    va_list args;

    va_start(args, fmt);
    kernel_raw_log(LOG_ERROR, fmt, args);
    va_end(args);
}

#ifdef KDEBUG
static inline void kernel_debug(const char* fmt, ...) {
    va_list args;

    va_start(args, fmt);
    kernel_raw_log(LOG_MSG, fmt, args);
    va_end(args);
}
#else
#define kernel_debug(...)
#endif

void draw_kpanic_screen();
void debug_point();