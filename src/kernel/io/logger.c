#include "logger.h"

#include <bootboot.h>
#include <stdarg.h>

#include "font.h"

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

extern BOOTBOOT bootboot;
extern uint32_t fb[];

#define BOOTBOOT_FB_BPP 4

const char* error_str = NULL;

typedef struct Logger {
    Framebuffer* fb;
    RawFont font;
    uint32_t row;
    uint32_t col;
    uint32_t max_row;
    uint32_t max_col;
    uint8_t color[4];
} Logger;

Logger logger = { NULL, {}, 0, 0, 0, 0, 0xFFFFFFFF };
Framebuffer early_fb;

void debug_point() {
    static uint32_t offset = 0;

    uint32_t* base = fb + offset;

    for (size_t i = 0; i < 100; ++i) {
        base[i] = 0x00FFFFFF;
    }

    offset += 200;
}

void logger_set_color(uint8_t r, uint8_t g, uint8_t b) {
    switch (logger.fb->format)
    {
    case FB_FORMAT_ABGR:
        logger.color[0] = r;
        logger.color[1] = g;
        logger.color[2] = b;
        break;
    case FB_FORMAT_ARGB:
        logger.color[0] = b;
        logger.color[1] = g;
        logger.color[2] = r;
        break;
    case FB_FORMAT_BGRA:
        logger.color[1] = r;
        logger.color[2] = g;
        logger.color[3] = b;
        break;
    case FB_FORMAT_RGBA:
        logger.color[1] = b;
        logger.color[2] = g;
        logger.color[3] = r;
        break;
    default:
        break;
    }
}

bool_t is_initialized = FALSE;

bool_t is_logger_initialized() {
    return is_initialized;
}

Status init_kernel_logger_raw(const uint8_t* font_binary_ptr) {
    early_fb.base = fb;
    early_fb.width = bootboot.fb_width;
    early_fb.height = bootboot.fb_height;
    early_fb.scanline = bootboot.fb_scanline;
    early_fb.format = (FbFormat)bootboot.fb_type;
    early_fb.bpp = BOOTBOOT_FB_BPP;

    return init_kernel_logger(&early_fb, font_binary_ptr);
}

Status init_kernel_logger(Framebuffer* fb, const uint8_t* font_binary_ptr) {
    if (fb == NULL || font_binary_ptr == NULL) return KERNEL_INVALID_ARGS;
    if (load_raw_font(font_binary_ptr, &logger.font) != KERNEL_OK) return KERNEL_INVALID_ARGS;

    logger.fb = fb;
    logger.max_col = logger.fb->width / logger.font.width;
    logger.max_row = logger.fb->height / logger.font.height;

    logger_set_color(COLOR_LGRAY);
    is_initialized = TRUE;

    return KERNEL_OK;
}

// Scrolls raw terminal up
void scroll_logger_fb(uint8_t rows_offset) {
}

static void move_cursor(int8_t row_offset, int8_t col_offset) {
    if (col_offset > 0 || logger.col >= -col_offset) {
        logger.col += col_offset;
    }
    else {
        if (logger.row == logger.col && logger.col == 0)
            return;

        row_offset -= ((-col_offset) / logger.max_col) + 1;
        logger.col = logger.max_col + col_offset + logger.col;
    }

    if (row_offset > 0 || logger.row >= -row_offset) {
        logger.row += row_offset;
    }

    if (logger.col >= logger.max_col) {
        logger.col = logger.col % logger.max_col;
        ++logger.row;
    }
    if (logger.row >= logger.max_row) {
        scroll_logger_fb((logger.row - logger.max_row) + 1);
        logger.row = logger.max_row - 1;
    }
}

static uint64_t calc_logger_fb_offset() {
    return (logger.row * (logger.fb->scanline * logger.font.height)) + ((logger.col * logger.font.width) << 2);
}

void raw_putc(char c) {
    if (c == '\0') return;
    if (c == '\n') {
        logger.col = 0;
        move_cursor(1, 0);

        return;
    }

    uint64_t curr_offset;

    if (c == '\b') {
        move_cursor(0, -1);
        curr_offset = calc_logger_fb_offset();

        for (int y = 0; y < logger.font.height; ++y) {
            for (int x = 0; x < logger.font.width; ++x) {
                *(uint32_t*)(logger.fb->base + curr_offset + (x << 2)) = 0x00000000;
            }

            curr_offset += logger.fb->scanline;
        }

        return;
    }

    const uint8_t* const glyph = logger.font.glyphs + (logger.font.charsize * c);
    curr_offset = calc_logger_fb_offset();

    for (int y = 0; y < logger.font.height; ++y) {
        uint32_t y_bit_idx = 0;
        uint32_t mask = (1 << (logger.font.width - 1));

        for (int x = 0; x < logger.font.width; ++x) {
            *(uint32_t*)(logger.fb->base + curr_offset + (x << 2)) = (glyph[y] & mask ? *(uint32_t*)logger.color : 0x00000000);
            mask >>= 1;
        }

        curr_offset += logger.fb->scanline;
    }

    move_cursor(0, 1);
}

void raw_puts(const char* string) {
    char c;

    while ((c = *string) != '\0') {
        raw_putc(c);
        ++string;
    }
}

static void raw_print_number(uint64_t number, bool_t is_signed, uint8_t notation) {
    static const char digit_table[] = "0123456789ABCDEF";
    static char out_buffer[32] = { '\0' };

    char* cursor = &out_buffer[sizeof(out_buffer) - 1];

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
        *(uint16_t*)cursor = 'b0';
        break;
    case 8:
        *(uint16_t*)cursor = 'o0';
        break;
    case 16:
        *(uint16_t*)cursor = 'x0';
        break;
    default:
        cursor += 2;
        break;
    }

    if (is_negative) *(--cursor) = '-';

    raw_puts(cursor);
}

static void kernel_raw_log(LogType log_type, const char* fmt, va_list args) {
    switch (log_type)
    {
    case LOG_MSG:
        logger_set_color(COLOR_LGRAY);
        raw_puts("[Debug]: ");
        break;
    case LOG_WARN:
        logger_set_color(COLOR_LYELLOW);
        raw_puts("[Warn]:  ");
        break;
    case LOG_ERROR:
        logger_set_color(COLOR_LRED);
        raw_puts("[Error]: ");
        break;
    default:
        raw_puts("[Unknown]: ");
        break;
    }

    char c;

    while ((c = *(fmt++)) != '\0') {
        if (c == '%') {
            c = *(fmt++);

            // For decimal numbers
            bool_t is_signed = TRUE;
            uint64_t arg_value;
            uint64_t temp_color = *(uint64_t*)logger.color;

            switch (c)
            {
            case '\0':
                return;
            case 'u': // Unsigned
                is_signed = FALSE;
            case 'd': // Decimal
            case 'i':
                arg_value = va_arg(args, int);
                raw_print_number(arg_value, is_signed, 10);
                break;
            case 'l':
                arg_value = va_arg(args, int64_t);
                raw_print_number(arg_value, TRUE, 10);
                break;
            case 'o': // Unsigned octal
                arg_value = va_arg(args, uint64_t);
                raw_print_number(arg_value, FALSE, 8);
                break;
            case 'x': // Unsigned hex
                arg_value = va_arg(args, uint64_t);
                raw_print_number(arg_value, FALSE, 16);
                break;
            case 's': // String
                arg_value = va_arg(args, uint64_t);
                if (arg_value != NULL) raw_puts((const char*)arg_value);
                break;
            case 'c': // Char
                arg_value = va_arg(args, uint64_t);
                raw_putc((char)arg_value);
                break;
            case 'p': // Pointer
                arg_value = va_arg(args, uint64_t);
                
                if (arg_value == NULL) {
                    raw_puts("nullptr");
                }
                else {
                    raw_print_number(arg_value, FALSE, 16);
                }

                break;
            case 'e': // Kernel 'Status'
                arg_value = va_arg(args, Status);
                switch (arg_value)
                {
                case KERNEL_OK:
                    logger_set_color(COLOR_LGREEN);
                    raw_puts("KERNEL OK");
                    break;
                case KERNEL_INVALID_ARGS:
                    logger_set_color(COLOR_LYELLOW);
                    raw_puts("KERNEL INVALID ARGS");
                    break;
                case KERNEL_ERROR:
                    logger_set_color(COLOR_LRED);
                    raw_puts("KERNEL ERROR");
                    break;
                case KERNEL_PANIC:
                    logger_set_color(COLOR_LRED);
                    raw_puts("KERNEL PANIC");
                    break;
                default:
                    logger_set_color(COLOR_LRED);
                    raw_puts("KERNEL INVALID RESULT");
                    break;
                }
                *(uint64_t*)logger.color = temp_color;
                break;
            case '%':
                raw_putc(c);
                break;
            default:
                break;
            }
        }
        else {
            raw_putc(c);
        }
    }
}

void kernel_log(LogType log_type, const char* fmt, ...) {
    va_list args;

    va_start(args, fmt);
    kernel_raw_log(log_type, fmt, args);
    va_end(args);
}

void kernel_msg(const char* fmt, ...) {
    va_list args;

    va_start(args, fmt);
    kernel_raw_log(LOG_MSG, fmt, args);
    va_end(args);
}

void kernel_warn(const char* fmt, ...) {
    va_list args;

    va_start(args, fmt);
    kernel_raw_log(LOG_WARN, fmt, args);
    va_end(args);
}

void kernel_error(const char* fmt, ...) {
    va_list args;

    va_start(args, fmt);
    kernel_raw_log(LOG_ERROR, fmt, args);
    va_end(args);
}