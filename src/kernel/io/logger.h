#pragma once

#include "definitions.h"

/*
Raw kernel logger.
Can be used only after display device initialization.
*/

typedef enum LogType {
    MSG,
    WARN,
    ERROR
} LogType;

// Prints log to display framebuffer
void kernel_log(LogType log_type, const char* fmt, ...);

// Prints msg log
void kernel_msg(const char* fmt, ...);
// Prints warning log
void kernel_warn(const char* fmt, ...);
// Prints error log
void kernel_error(const char* fmt, ...);