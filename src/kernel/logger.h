#pragma once

#include "definitions.h"
#include "dev/display.h"

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

// Prints log to display framebuffer
void kernel_log(LogType log_type, const char* fmt, ...);

// Prints msg log
void kernel_msg(const char* fmt, ...);
// Prints warning log
void kernel_warn(const char* fmt, ...);
// Prints error log
void kernel_error(const char* fmt, ...);

void debug_point();