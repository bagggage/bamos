#pragma once

#include "definitions.h"
#include "dev/display.h"

#include <stdarg.h>

/*
Raw kernel logger.
Can be used only after display device initialization.
*/

// Put delailed error message here
extern const char* error_str;

typedef enum LogType {
    LOG_MSG,
    LOG_WARN,
    LOG_ERROR
} LogType;

bool_t is_logger_initialized();

// Initialize logger framebuffer just only with GOP framebuffer, needed for early acces before display initialized
Status init_kernel_logger_raw(const uint8_t* font_binary_ptr);
Status init_kernel_logger(Framebuffer* fb, const uint8_t* font_binary_ptr);

uint16_t kernel_logger_get_rows();
uint16_t kernel_logger_get_cols();

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

void draw_kpanic_screen();
void debug_point();