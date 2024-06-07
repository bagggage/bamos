#include <ctype.h>
#include <errno.h>
#include <stdio.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <unistd.h>

#define NULL ((void*)0)

static char current_dir[256] = { '\0' };

char** parse_args(char* string, unsigned int* out_argc) {
    char* cursor = string;
    unsigned int argc = 0;
    *out_argc = 0;

    char** argv = calloc(sizeof(char*), 16);

    if (argv == NULL) return NULL;

    while (isspace(*cursor)) cursor++;

    while (*cursor != '\0') {
        char* arg_cursor = cursor;
        argv[argc] = cursor;

        for (unsigned int i = 0; !isspace(cursor[i]) && cursor[i] != '\0'; ++i) {
            if (cursor[i] == '\\') {
                i++;
                if (cursor[i] == '\0') break;
            }

            *(arg_cursor++) = cursor[i];
        }

        *arg_cursor = '\0';
        argc++;

        cursor = arg_cursor + 1;

        while (isspace(*cursor)) cursor++;
    }

    if (argc == 0) {
        free(argv);
        return NULL;
    }

    *out_argc = argc;

    return argv;
}

void print_err(const char* str_cmd, unsigned int error) {
    const char* error_str;

    switch (error)
    {
    case ENOENT:
        error_str = "No such file or directory";
        break;
    case EISDIR:
        error_str = "Is a directory";
        break;
    case ENOTDIR:
        error_str = "Not a directory";
        break;
    case ENOEXEC:
        error_str = "Permission denied";
        break;
    default:
        error_str = "Command not found";
        break;
    }

    fprintf(stderr, "%s: %s\n", str_cmd, error_str);
}

void cd_impl(char** argv, unsigned int argc) {
    if (argc > 1) {
        if (argc == 2) {
            int result = chdir(argv[1]);

            if (result < 0) print_err(argv[0], -result);

            getcwd(current_dir, 256);
        }
        else {
            fprintf(stderr, "%s: Too many arguments\n", argv[0]);
        }
    }
}

void echo_impl(char** argv, unsigned int argc) {
    for (unsigned int i = 1; i < argc; ++i) {
        puts(argv[i]);
        putchar(' ');
    }

    putchar('\n');
}

void clear_impl(char** argv, unsigned int argc) {
    if (argc > 1) {
        fprintf(stderr, "%s: Too many arguments", argv[0]);
        return;
    }

    puts("\033[H\033[J");
}

void exec_impl(char** argv) {
    pid_t pid = fork();

    if (pid == 0) {
        int result = execve(argv[0], argv, NULL);

        print_err(argv[0], -result);
        exit(0);
    }

    waitpid(-1, NULL, 0);
}

void exec_cmd(char* str_cmd) {
    unsigned int i = 0;

    while (str_cmd[i] != '\0' && str_cmd[i] != '\n') i++;

    str_cmd[i] = '\0';

    unsigned int argc = 0;
    char** argv = parse_args(str_cmd, &argc);

    if (strcmp(argv[0], "cd") == 0) cd_impl(argv, argc);
    else if (strcmp(argv[0], "echo") == 0) echo_impl(argv, argc);
    else if (strcmp(argv[0], "clear") == 0) clear_impl(argv, argc);
    else if (strcmp(argv[0], "exit") == 0) exit(0);
    else exec_impl(argv);

    free(argv);
}

int main() {
    current_dir[0] = '/';

    char c;
    char buffer[512] = { '\0' };

    size_t cursor_idx = 0;

    printf("%s$ ", current_dir);

    while (1) {
        c = getchar();

        if (c == '\n') {
            putchar('\n');

            buffer[cursor_idx + 1] = '\0';
            if (cursor_idx != 0) exec_cmd(buffer);

            printf("%s$ ", current_dir);
            buffer[0] = '\0';
            cursor_idx = 0;
            continue;
        }
        else if (c != '\b') {
            putchar(c);
            buffer[cursor_idx++] = c;
            buffer[cursor_idx] = '\0';
        }
        else if (cursor_idx > 0) {
            putchar(c);
            buffer[--cursor_idx] = '\0';
        }
    }

    return 0;
}
