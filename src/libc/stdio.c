#include "stdio.h"

#include "errno.h"
#include "fcntl.h"
#include "stdlib.h"
#include "string.h"
#include "unistd.h"

#include "sys/syscall.h"
#include "sys/mman.h"

FILE* stdout = NULL;
FILE* stdin = NULL;
FILE* stderr = NULL;

static char* print_buffer = NULL;

int fflush(FILE* restrict stream) {

}

unsigned int fmt_num(const unsigned long long number, char* buffer, const char is_signed, unsigned short notation) {
    static const char* digits = "0123456789abcdef";

    char* cursor = buffer;

    unsigned long long num = number;
    const char is_negative = is_signed && ((long long)number < 0);

    if (is_negative) {
        num = (unsigned int)(-(long long)number);
        *(cursor++) = '-';
    }

    do {
        *(cursor++) = digits[num % notation];
        num /= notation;
    } while (num > 0);

    const unsigned int lenght = ((unsigned long long)cursor - (unsigned long long)buffer);

    for (unsigned int i = is_negative ? 1 : 0; i < (lenght / 2); ++i) {
        char temp = buffer[i];
        buffer[i] = *(--cursor);
        *cursor = temp;
    }

    return lenght;
}

int _vsprintf(char* buffer, const char* fmt, va_list args, char** out_end) {
    int parsed = 0;
    char* cursor = buffer;
    char c;

    while ((c = *(fmt++)) != '\0') {
        if (c == '%') {
            c = *(fmt++);

            char is_signed = 0;
            unsigned long long num = 0;
            const char* str;

            switch (c)
            {
            case '\0': goto end_loop; break;
            case '%':
                *(cursor++) = c;
                break;
            case 'i':
            case 'd': is_signed = 1;
            case 'u':
                num = va_arg(args, unsigned int);
                cursor += fmt_num(num, cursor, is_signed, 10);
                break;
            case 'x':
                num = va_arg(args, unsigned int);
                cursor += fmt_num(num, cursor, 0, 16);
                break;
            case 'o':
                num = va_arg(args, unsigned int);
                cursor += fmt_num(num, cursor, 0, 8);
                break;
            case 'c':
                *(cursor++) = (char)va_arg(args, int);
                break;
            case 's':
                str = va_arg(args, const char*);
                while (*str != '\0') *(cursor++) = *(str++);
                break;
            default:
                parsed--;
                break;
            }

            parsed++;
        }
        else {
            *(cursor++) = c;
        }
    }

end_loop:

    *cursor = '\0';
    *out_end = cursor;

    return parsed;
}

int vsprintf(char* buffer, const char* fmt, va_list args) {
    return _vsprintf(buffer, fmt, args, NULL);
}

int vfprintf(FILE* restrict stream, const char* restrict fmt, va_list args) {
    if (print_buffer == NULL) {
        print_buffer = mmap(
            NULL,
            4096,
            PROT_WRITE | PROT_READ,
            MAP_ANONYMOUS | MAP_PRIVATE,
            0, 0
        );

        if (print_buffer == NULL) return -1;
    }

    char* str_end;
    int result = _vsprintf(print_buffer, fmt, args, &str_end);

    if (result == -1) return -1;

    const unsigned int size = str_end - print_buffer;

    return (fwrite(print_buffer, size, 1, stream) == size ? result : -1);    
}

static inline int make_oflags(const char* restrict mode) {
    if (mode[0] == '\0') return -1;

    int result = 0;

    if (mode[0] == 'r') {
        if (mode[1] == 'w') result = O_RDWR;
        else if (mode[1] != '\0') return -1;
        else result = O_RDONLY;
    }
    else if (mode[0] == 'w') {
        if (mode[1] == 'r') result = O_RDWR;
        else if (mode[1] != '\0') return -1;
        else result = O_WRONLY;
    }
    else {
        return -1;
    }

    return result;
}

FILE* fopen(const char* restrict filename, const char* restrict mode) {
    if (filename == NULL || mode == NULL) return NULL;

    int oflags = make_oflags(mode);

    if (oflags < 0) return NULL;

    FILE* file = (FILE*)malloc(sizeof(FILE));

    if (file == NULL) return NULL;

    file->_fileno = _syscall_arg2(SYS_OPEN, (size_t)filename, oflags);

    if (file->_fileno < 0) {
        free(file);
        errno = -file->_fileno;
        return NULL;
    }

    return file;
}

int fclose(FILE* restrict stream) {
    if (stream == NULL) return EOF;

    long result = _syscall_arg1(SYS_CLOSE, stream->_fileno);

    if (result < 0) {
        errno = -result;
        return EOF;
    }

    stream->_fileno = -1;

    free(stream);

    return 0;
}

size_t fread(void* restrict buffer, size_t size, size_t count, FILE* restrict stream) {
    long result = _syscall_arg3(SYS_READ, stream->_fileno, (size_t)buffer, size * count);

    if (result < 0) {
        errno = -result;
        return 0;
    }

    return ((size_t)result / size);
}

size_t fwrite(const void* restrict buffer, size_t size, size_t count, FILE* restrict stream) {
    long result = _syscall_arg3(SYS_WRITE, stream->_fileno, (size_t)buffer, size * count);

    if (result < 0) {
        errno = -result;
        return 0;
    }

    return ((size_t)result / size);
}

int fseek(FILE* restrict stream, long offset, int whence) {
}

void setbuf(FILE* restrict stream, char* restrict buffer) {
}

int fputc(int c, FILE* restrict stream) {
    return write(stream->_fileno, (char*)&c, 1);
}

int fputs(const char* string, FILE* restrict stream) {
    return write(stream->_fileno, string, strlen(string));
}

int fgetc(FILE* restrict stream) {
    char c;

    if (read(stream->_fileno, &c, 1) < 1) return EOF;

    return (int)c;
}

char* fgets(char* buffer, int size, FILE* restrict stream) {
    const long readed = read(stream->_fileno, buffer, (size_t)(size - 1));

    if (readed < 0) return NULL;

    buffer[readed] = '\0';

    return buffer;
}

char* gets(char* buffer) {
    size_t readed;
    char* cursor = buffer;

    do {
        readed = read(stdin->_fileno, cursor, 4096);
        cursor += readed;
    } while (readed == 4096);

    *cursor = '\0';

    return buffer;
}