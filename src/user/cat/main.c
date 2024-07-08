#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <errno.h>

const char* err_to_str(const int error_code) {
    switch (error_code)
    {
    case ENOENT:
        return "No such file or directory";
    case EISDIR:
        return "Is a directory";
    default:
        return "Something went wrong";
    }
}

int cat_file(const char* filepath) {
    FILE* file = fopen(filepath, "r");

    if (file == NULL) return -ENOENT;

    char buffer[128] = { '\0' };
    size_t readed;

    while ((readed = fread(buffer, 1, sizeof(buffer) - 1, file)) > 0) {
        buffer[readed] = '\0';
        puts(buffer);
    }

    fclose(file);

    return 0;
}

int main(int argc, char** argv, char** envp) {
    if (argc < 2) {
        fprintf(stderr, "%s: No input\n\n", argv[0]);
        return -1;
    }

    for (int i = 1; i < argc; ++i) {
        int result = access(argv[i], R_OK);

        if (result == 0) result = cat_file(argv[i]);
        if (result < 0) {
            fprintf(stderr, "%s: %s: %s\n", argv[0], argv[i], err_to_str(-result));
            continue;
        }
    }

    return 0;
}