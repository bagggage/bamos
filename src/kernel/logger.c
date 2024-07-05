#include "logger.h"

#include <bootboot.h>
#include <stdarg.h>

#include "cpu/spinlock.h"

#include "math.h"
#include "mem.h"

#include "video/font.h"

#define _RGB_TO_UINT32(r, g, b) (uint32_t)((r << 16) | (g << 8) | (b))
#define RGB_TO_UINT32(color) _RGB_TO_UINT32(color)

extern BOOTBOOT bootboot;
extern uint32_t fb[];

#define BOOTBOOT_FB_BPP 4

typedef struct Logger {
    Framebuffer* fb;
    RawFont font;
    uint32_t row;
    uint32_t col;
    uint32_t max_row;
    uint32_t max_col;
    uint8_t color[4];

    uint32_t color_stack[16];
    uint32_t color_stack_size;

    Spinlock lock;
} Logger;

Logger logger = { NULL, {}, 0, 0, 0, 0, { 0xFF, 0xFF, 0xFF, 0xFF }, { 0 } };
Framebuffer early_fb;

void kernel_logger_push_color(uint8_t r, uint8_t g, uint8_t b) {
    if (logger.color_stack_size >= (sizeof(logger.color_stack) / sizeof(uint32_t))) return;

    kernel_logger_set_color(r, g, b);

    logger.color_stack[logger.color_stack_size++] = *(uint32_t*)(&logger.color[0]);
}

void kernel_logger_pop_color() {
    if (logger.color_stack_size <= 1) return;

    logger.color_stack_size--;
    *(uint32_t*)(&logger.color[0]) = logger.color_stack[logger.color_stack_size - 1];
}

void kernel_logger_lock() {
    spin_lock(&logger.lock);
}

void kernel_logger_release() {
    while (logger.color_stack_size > 1) kernel_logger_pop_color();
    
    spin_release(&logger.lock);
}

void debug_point() {
    static uint32_t offset = 0;

    uint32_t* base = fb + offset;

    for (size_t i = 0; i < 100; ++i) {
        base[i] = 0x00FFFFFF;
    }

    offset += 200;
}

void kernel_logger_set_color(uint8_t r, uint8_t g, uint8_t b) {
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

Color kernel_logger_get_color() {
    Color color;

    switch (logger.fb->format)
    {
    case FB_FORMAT_ABGR:
        color = (Color){ logger.color[0], logger.color[1], logger.color[2] };
        break;
    case FB_FORMAT_ARGB:
        color = (Color){ logger.color[2], logger.color[1], logger.color[0] };
        break;
    case FB_FORMAT_BGRA:
        color = (Color){ logger.color[1], logger.color[2], logger.color[3] };
        break;
    case FB_FORMAT_RGBA:
        color = (Color){ logger.color[3], logger.color[2], logger.color[1] };
        break;
    default:
        break;
    }

    return color;
}

typedef __attribute__((vector_size(32), aligned(256))) long long m256i;

static inline void fast_memcpy256(const void* src, void* dst, const size_t size) {
    m256i* dst_vec = (m256i*)dst;
    const m256i* src_vec = (const m256i*)src;

    size_t count = size / sizeof(m256i);

    for (; count > 0; count -= 4, src_vec += 4, dst_vec += 4) {
        *dst_vec = *src_vec;
        *(dst_vec + 1) = *(src_vec + 1);
        *(dst_vec + 2) = *(src_vec + 2);
        *(dst_vec + 3) = *(src_vec + 3);
    }
}

static inline void fast_memset256(void* const dst, const size_t size, const uint8_t value) {
    m256i val;

    for (uint64_t i = 0; i < sizeof(m256i) / sizeof(uint64_t); ++i) ((uint64_t*)&val)[i] = value;

    m256i* dst_vec = (m256i*)dst;
    size_t count = size / sizeof(m256i);

    for (; count > 0; count -= 4, dst_vec += 4) {
        *dst_vec       = val;
        *(dst_vec + 1) = val;
        *(dst_vec + 2) = val;
        *(dst_vec + 3) = val;
    }
}

bool_t is_initialized = FALSE;

bool_t is_logger_initialized() {
    return is_initialized;
}

Status init_kernel_logger_raw(const uint8_t* font_binary_ptr) {
    early_fb.base = (uint8_t*)&fb;
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

    kernel_logger_push_color(COLOR_LGRAY);
    is_initialized = TRUE;

    return KERNEL_OK;
}

uint16_t kernel_logger_get_rows() {
    return logger.max_row;
}

uint16_t kernel_logger_get_cols() {
    return logger.max_col;
}

void kernel_logger_set_cursor_pos(uint16_t row, uint16_t col) {
    logger.row = row % logger.max_row;
    logger.col = col % logger.max_col;
}

// Scrolls raw terminal up
static inline void scroll_logger_fb(uint8_t rows_offset) {
    const size_t rows_byte_offset = (uint64_t)rows_offset * logger.fb->scanline * logger.font.height;
    const size_t fb_size = (uint64_t)logger.fb->height * logger.fb->scanline;

    fast_memcpy256((logger.fb->base + rows_byte_offset), logger.fb->base, fb_size - rows_byte_offset);
    fast_memset256(logger.fb->base + (fb_size - rows_byte_offset), rows_byte_offset, 0);
}

void kernel_logger_clear() {
    spin_lock(&logger.lock);

    logger.col = 0;
    logger.row = 0;

    const size_t fb_size = ((uint64_t)logger.fb->height * logger.fb->scanline);

    fast_memset256(logger.fb->base, fb_size, 0);
    spin_release(&logger.lock);
}

// FIXME: when array size set to uint32_max - program terminated 1 error
uint32_t last_cursor_positions_in_columns[UINT16_MAX];

static void move_cursor(int8_t row_offset, int8_t col_offset) {
    if (col_offset > 0 || (int64_t)logger.col >= -col_offset) {
        logger.col += col_offset;
    }
    else {
        if (logger.row == logger.col && logger.col == 0)
            return;

        row_offset -= ((-col_offset) / logger.max_col) + 1;

        (logger.row > 0) ? (logger.col = last_cursor_positions_in_columns[logger.row - 1]) :
                           (logger.col = 0);

    }

    if (row_offset > 0 || (int64_t)logger.row >= -row_offset) {
        last_cursor_positions_in_columns[logger.row] = logger.col;
        logger.row += row_offset;
    }

    if (logger.col >= logger.max_col) {
        last_cursor_positions_in_columns[logger.row] = logger.max_col;
        logger.col = logger.col % logger.max_col;
        ++logger.row;
    }
    if (logger.row >= logger.max_row) {
        scroll_logger_fb((logger.row - logger.max_row) + 1);
        logger.row = logger.max_row - 1;
    }
}

static uint64_t calc_logger_fb_offset() {
    return ((uint64_t)logger.row * ((uint64_t)logger.fb->scanline * logger.font.height)) +
        ((logger.col * logger.font.width) * sizeof(uint32_t));
}

void raw_putc(char c) {
    if (c == '\0') return;
    if (c == '\n') {
        move_cursor(1, 0);
        logger.col = 0;

        return;
    }

    uint64_t curr_offset;

    if (c == '\b') {
        move_cursor(0, -1);
        curr_offset = calc_logger_fb_offset();

        for (uint32_t y = 0; y < logger.font.height; ++y) {
            for (uint32_t x = 0; x < logger.font.width; ++x) {
                *(uint32_t*)(logger.fb->base + curr_offset + (x << 2)) = 0x00000000;
            }

            curr_offset += logger.fb->scanline;
        }

        return;
    }

    const uint8_t* const glyph = logger.font.glyphs + (logger.font.charsize * c);
    curr_offset = calc_logger_fb_offset();

    for (uint32_t y = 0; y < logger.font.height; ++y) {
        uint32_t mask = (1 << (logger.font.width - 1));

        for (uint32_t x = 0; x < logger.font.width; ++x) {
            const uint32_t color = (glyph[y] & mask ? *(uint32_t*)logger.color : 0x00000000);
            *(uint32_t*)(logger.fb->base + curr_offset + (x << 2)) = color;
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

void raw_print_number(uint64_t number, bool_t is_signed, uint8_t notation) {
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

    raw_puts(cursor);
}

void raw_hexdump(const void* data, const size_t size) {
	char ascii[17];
	ascii[16] = '\0';

	size_t i, j;

	for (i = 0; i < size; ++i) {
        uint8_t num = ((unsigned char*)data)[i];

        if (num < 0x10) raw_putc('0');

        raw_print_number(num, FALSE, 16);
        raw_putc(' ');

		if (((unsigned char*)data)[i] >= ' ' && ((unsigned char*)data)[i] <= '~') {
			ascii[i % 16] = ((unsigned char*)data)[i];
		}
        else {
		    ascii[i % 16] = '.';
		}
		if ((i+1) % 8 == 0 || i+1 == size) {
			raw_putc(' ');

			if ((i+1) % 16 == 0) {
                raw_puts("| ");
                raw_puts(ascii);
                raw_puts(" \n");
			}
            else if (i+1 == size) {
				ascii[(i+1) % 16] = '\0';

				if ((i+1) % 16 <= 8) {
					raw_putc(' ');
				}

				for (j = (i+1) % 16; j < 16; ++j) {
					raw_puts("   ");
				}

				raw_puts("| ");
                raw_puts(ascii);
                raw_puts(" \n");
			}
		}
	}
}

static void vprintf(const char* fmt, va_list args) {
    char c;

    while ((c = *(fmt++)) != '\0') {
        if (c == '%') {
            c = *(fmt++);

            // For decimal numbers
            bool_t is_signed = TRUE;
            uint64_t arg_value;

            switch (c)
            {
            case '\0':
                return;
            case 'u': // Unsigned
                is_signed = FALSE; FALLTHROUGH;
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
            case 'b':
                arg_value = va_arg(args, uint32_t);
                raw_print_number(arg_value, FALSE, 2);
                break;
            case 's': // String
                arg_value = va_arg(args, uint64_t);
                if ((const char*)arg_value != NULL) raw_puts((const char*)arg_value);
                break;
            case 'c': // Char
                arg_value = va_arg(args, uint64_t);
                raw_putc((char)arg_value);
                break;
            case 'p': // Pointer
                arg_value = va_arg(args, uint64_t);
                
                if ((void*)arg_value == NULL) {
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
                    kernel_logger_push_color(COLOR_LGREEN);
                    raw_puts("KERNEL OK");
                    break;
                case KERNEL_INVALID_ARGS:
                    kernel_logger_push_color(COLOR_LYELLOW);
                    raw_puts("KERNEL INVALID ARGS");
                    break;
                case KERNEL_ERROR:
                    kernel_logger_push_color(COLOR_LRED);
                    raw_puts("KERNEL ERROR");
                    break;
                case KERNEL_PANIC:
                    kernel_logger_push_color(COLOR_LRED);
                    raw_puts("KERNEL PANIC");
                    break;
                default:
                    kernel_logger_push_color(COLOR_LRED);
                    raw_puts("KERNEL INVALID RESULT");
                    break;
                }
                kernel_logger_pop_color();
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

void kprintf(const char* fmt, ...) {
    va_list args;

    va_start(args, fmt);
    vprintf(fmt, args);
    va_end(args);
}

void kernel_raw_log(LogType log_type, const char* fmt, va_list args) {
    spin_lock(&logger.lock);

    switch (log_type)
    {
    case LOG_MSG:
        kernel_logger_push_color(COLOR_LGRAY);
        raw_puts("[Debug]: ");
        break;
    case LOG_WARN:
        kernel_logger_push_color(COLOR_LYELLOW);
        raw_puts("[Warn]:  ");
        break;
    case LOG_ERROR:
        kernel_logger_push_color(COLOR_LRED);
        raw_puts("[Error]: ");
        break;
    default:
        kernel_logger_push_color(COLOR_LGRAY);
        raw_puts("[Unknown]: ");
        break;
    }

    vprintf(fmt, args);

    kernel_logger_pop_color();
    spin_release(&logger.lock);
}

void draw_kpanic_screen() {
    const size_t pixels_count = bootboot.fb_size / sizeof(uint32_t);

    for (uint32_t i = 0; i < pixels_count; ++i) {
        fb[i] = RGB_TO_UINT32(COLOR_LRED);
    }
}