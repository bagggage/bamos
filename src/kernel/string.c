#include "string.h"

#include <stdarg.h>

#include "definitions.h"
#include "mem.h"

static const char* format_number(char* const buffer, const uint32_t length, uint64_t number, bool_t is_signed, uint8_t notation) {
    static const char digit_table[] = "0123456789ABCDEF";
    char* cursor = &buffer[length - 1];

    bool_t is_negative = is_signed && ((int64_t)number) < 0;

    if (is_negative) number = -number;

    do {
        *(--cursor) = digit_table[number % notation];
        number /= notation;
    } while (number > 0);

    // Print notation prefix (0b, 0o, 0x)
    cursor -= 2;

    switch (notation)
    {
    case 2:
        *(uint16_t*)cursor = (uint16_t)('0' | ('b' << 8)); // '0b' - prefix
        break;
    case 8:
        *(uint16_t*)cursor = (uint16_t)('0' | ('o' << 8)); // '0o' - prefix
        break;
    case 16:
        *(uint16_t*)cursor = (uint16_t)('0' | ('x' << 8)); // '0x' - prefix
        break;
    default:
        cursor += 2;
        break;
    }

    if (is_negative) *(--cursor) = '-';

    return cursor;
}

static uint32_t concat(char* const dst, const char* const src) {
    uint32_t i = 0;

    while (src[i] != '\0') {
        dst[i] = src[i];
        i++;
    }

    return i;
}

static void _sprintf(char* const buffer, const char* fmt, va_list args) {
    char* cursor = buffer;
    char format_buffer[32] = { '\0' };
    char c;

    while ((c = *(fmt++)) != '\0') {
        if (c == '%') {
            c = *(fmt++);

            // For decimal numbers
            bool_t is_signed = TRUE;
            uint64_t arg_value;
            const char* num_str;

            switch (c)
            {
            case '\0':
                *cursor = '\0';
                return;
            case 'u': // Unsigned
                is_signed = FALSE; FALLTHROUGH;
            case 'd': // Decimal
            case 'i':
                arg_value = va_arg(args, int);
                num_str = format_number(format_buffer, sizeof(format_buffer), arg_value, is_signed, 10);
                cursor += concat(cursor, num_str);
                break;
            case 'l':
                arg_value = va_arg(args, int64_t);
                num_str = format_number(format_buffer, sizeof(format_buffer), arg_value, TRUE, 10);
                cursor += concat(cursor, num_str);
                break;
            case 'o': // Unsigned octal
                arg_value = va_arg(args, uint64_t);
                num_str = format_number(format_buffer, sizeof(format_buffer), arg_value, FALSE, 8);
                cursor += concat(cursor, num_str);
                break;
            case 'x': // Unsigned hex
                arg_value = va_arg(args, uint64_t);
                num_str = format_number(format_buffer, sizeof(format_buffer), arg_value, FALSE, 16);
                cursor += concat(cursor, num_str);
                break;
            case 'b':
                arg_value = va_arg(args, uint32_t);
                num_str = format_number(format_buffer, sizeof(format_buffer), arg_value, FALSE, 2);
                cursor += concat(cursor, num_str);
                break;
            case 's': // String
                arg_value = va_arg(args, uint64_t);
                if ((const char*)arg_value != NULL)
                    cursor += concat(cursor, (const char*)arg_value);
                break;
            case 'c': // Char
                arg_value = va_arg(args, uint64_t);
                *(cursor++) = (char)arg_value;
                break;
            case 'p': // Pointer
                arg_value = va_arg(args, uint64_t);
                
                if ((void*)arg_value == NULL) {
                    cursor += concat(cursor, "nullptr");
                }
                else {
                    num_str = format_number(format_buffer, sizeof(format_buffer), arg_value, FALSE, 16);
                    cursor += concat(cursor, num_str);
                }

                break;
            case '%':
                *(cursor++) = c;
                break;
            default:
                break;
            }
        }
        else {
            *(cursor++) = c;
        }
    }

    *cursor = '\0';
}

void sprintf(char* const buffer, const char* fmt, ...) {
    va_list args;

    va_start(args, fmt);
    _sprintf(buffer, fmt, args);
    va_end(args);
}