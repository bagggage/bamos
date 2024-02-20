#pragma once

#include "definitions.h"

typedef enum LogType {
    MSG,
    WARN,
    ERROR
} LogType;

void kernel_log(LogType log_type, const char* fmt, ...);

void kernel_msg(const char* fmt, ...);
void kernel_warn(const char* fmt, ...);
void kernel_error(const char* fmt, ...);