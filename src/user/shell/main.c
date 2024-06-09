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
#define UNUSED(x) (void)(x)

static char** paths = NULL;
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

void too_many_args(const char* exec_name) {
    fprintf(stderr, "%s: Too many arguments\n", exec_name);
}

void cd_impl(char** argv, unsigned int argc) {
    if (argc > 1) {
        if (argc == 2) {
            int result = chdir(argv[1]);

            if (result < 0) print_err(argv[0], -result);

            getcwd(current_dir, 256);
        }
        else {
            too_many_args(argv[0]);
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
        return too_many_args(argv[0]);
    }

    puts("\033[H\033[J");
}

void env_impl(char** argv, unsigned int argc) {
    if (argc > 1) return too_many_args(argv[0]);

    char** env = environ;

    while (*env != NULL) {
        printf("%s\n", *(env++));
    }
}

int is_direct_path(const char* name) {
    return name[0] != '\0' && (
        name[0] == '/' ||
        memcmp(name, "./", 2) == 0 ||
        memcmp(name, "~/", 2) == 0 ||
        memcmp(name, "../", 3) == 0
    );
}

char* find_exec(char* name) {
    int result = access(name, X_OK);

    if (result == -ENOENT && is_direct_path(name) == 0) {
        static char buffer[256] = { '\0' };

        char** path_ptr = paths;

        while (*path_ptr != NULL && result == -ENOENT) {
            size_t len = strlen(*path_ptr);

            memcpy(buffer, *path_ptr, len);
            buffer[len] = '/';
            memcpy(&buffer[len + 1], name, strlen(name) + 1);

            result = access(buffer, X_OK);

            if (result == 0) return buffer;

            path_ptr++;
        }
    }
    if (result < 0) {
        print_err(name, -result);
        return NULL;
    }

    return name;
}

void exec_impl(char** argv) {
    char* exec_name = find_exec(argv[0]);

    if (exec_name == NULL) return;

    pid_t pid = fork();

    if (pid == 0) {
        int result = execve(exec_name, argv, environ);
        print_err(argv[0], -result);
        exit(0);
    }

    if (exec_name != argv[0]) free(exec_name);

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
    else if (strcmp(argv[0], "env") == 0) env_impl(argv, argc);
    else if (strcmp(argv[0], "clear") == 0) clear_impl(argv, argc);
    else if (strcmp(argv[0], "exit") == 0) exit(0);
    else exec_impl(argv);

    free(argv);
}

char** divide_paths(char* const paths) {
    char** result = NULL;
    unsigned int count = 0;
    char* cursor = paths;

    while (*cursor != '\0') {
        count++;

        do {
            cursor++;
        } while (*cursor != '\0' && *cursor != ';'); 

        if (*cursor == ';') {
            *cursor = '\0';
            cursor++;
        }
    }

    result = (char**)calloc(sizeof(char*), count + 1);

    if (result == NULL) return NULL;

    result[count] = NULL;
    cursor = paths;

    for (unsigned int i = 0; i < count; ++i) {
        result[i] = cursor;
        while (*(cursor++) != '\0');
    }

    return result;
}

void parse_paths() {
    char* var = getenv("PATH");

    if (var == NULL) return;

    const size_t length = strlen(var);
    if (length == 0) return;

    char* paths_buffer = (char*)malloc(length + 1);
    if (paths_buffer == NULL) return;

    for (unsigned int i = 0; i < length + 1; ++i) {
        paths_buffer[i] = var[i];
    }

    paths = divide_paths(paths_buffer);

    if (paths == NULL) free(paths_buffer);
}

int main() {
    parse_paths();

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
