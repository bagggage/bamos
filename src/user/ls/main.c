#include <stdio.h>
#include <dirent.h>
#include <unistd.h>

#define NULL ((void*)0)

void list_dir(const char* pathname, const char* print_dir_fmt) {
    DIR* dir = opendir(pathname);

    if (dir == NULL) {
        fprintf(stderr, "ls: cannot access '%s': No such file or directory\n", pathname);
        return;
    }

    if (print_dir_fmt != NULL) printf(print_dir_fmt, pathname);

    struct dirent* dirent = readdir(dir);

    for (; dirent != NULL; dirent = readdir(dir)) {
        if (dirent->d_name[0] == '.' && (dirent->d_name[1] == '\0' ||
            (dirent->d_name[1] == '.' && dirent->d_name[2] == '\0'))) continue;

        printf("%s ", dirent->d_name);
    }

    closedir(dir);
    putchar('\n');
}

int main(int argc, char** argv) {
    if (argc < 2) {
        static char buffer[256] = { '\0' };
        getcwd(buffer, sizeof(buffer));

        list_dir(buffer, NULL);
    }
    else if (argc == 2) {
        list_dir(argv[1], NULL);
    }
    else {
        for (int i = 1; i < argc; ++i) {
            if (i > 1) putchar('\n');

            list_dir(argv[i], "%s:\n");
        }
    }

    return 0;
}