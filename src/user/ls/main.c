#include <stdio.h>
#include <dirent.h>
#include <unistd.h>

#define NULL ((void*)0)

int main() {
    //write(stdout->_fileno, "LS!\n", 4);

    const char** argv = NULL; int argc = 0;
    const char* path;

    if (argc < 2) {
        static char buffer[256] = { '\0' };
        path = getcwd(buffer, sizeof(buffer));
    }
    else {
        //path = argv[1];
    }

    //printf("Before open dir: %s\n", path);

    DIR* dir = opendir(path);

    if (dir == NULL) {
        fprintf(stderr, "ls: '%s': No such file or directory\n", path);
        return -1;
    }

    struct dirent* dirent = readdir(dir);

    for (; dirent != NULL; dirent = readdir(dir)) {
        if (dirent->d_name[0] == '.' && (dirent->d_name[1] == '\0' ||
            (dirent->d_name[1] == '.' && dirent->d_name[2] == '\0'))) continue;

        printf("%s ", dirent->d_name);
    }

    putchar('\n');

    return 0;
}