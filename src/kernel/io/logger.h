#pragma once

#include "definitions.h"
#include "dev/display.h"

/*
Raw kernel logger.
Can be used only after display device initialization.
*/

typedef enum LogType {
    LOG_MSG,
    LOG_WARN,
    LOG_ERROR
} LogType;

Status init_kernel_logger(Framebuffer* fb, const uint8_t* font_binary_ptr);

void raw_putc(char c);
void raw_puts(const char* string);

// Prints log to display framebuffer
void kernel_log(LogType log_type, const char* fmt, ...);

// Prints msg log
void kernel_msg(const char* fmt, ...);
// Prints warning log
void kernel_warn(const char* fmt, ...);
// Prints error log
void kernel_error(const char* fmt, ...);

void debug_point();