#include "stdio.h"

#include "sys/syscall.h"

#include "stdlib.h"

FILE* stderr;

int fflush(FILE* restrict stream) {

}

int vfprintf(FILE* restrict stream, const char* restrict fmt, va_list args) {
    
}

int vsprintf(const char* buffer, const char* fmt, va_list args) {

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

    file->_fileno = syscall(SYS_OPEN, filename, oflags);

    if (file->_fileno < 0) {
        free(file);
        return NULL;
    }

    return file;
}

int fclose(FILE* restrict stream) {
    if (stream == NULL) return EOF;

    if (syscall(SYS_CLOSE, stream->_fileno) != 0) return EOF;

    stream->_fileno = -1;

    free(stream);

    return 0;
}

size_t fread(void* restrict buffer, size_t size, size_t count, FILE* restrict stream) {
    long result = syscall(SYS_READ, stream->_fileno, buffer, size * count);

    return (result < 0) ? 0 : result;
}

size_t fwrite(const void* restrict buffer, size_t size, size_t count, FILE* restrict stream) {

}

int fseek(FILE* restrict stream, long offset, int whence) {

}

void setbuf(FILE* restrict stream, char* restrict buffer) {
}