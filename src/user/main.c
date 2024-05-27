#include <stdio.h>
#include <errno.h>
#include <sys/syscall.h>
#include <stdlib.h>

#define NULL ((void*)0)

void _start() {
    FILE* stdout = fopen("/dev/tty0", "rw");

    if (stdout == NULL) return -errno;

    const char logo_str[] =
        "\n"
        " :::::::::      :::     ::::    ::::   ::::::::   :::::::: \n"
        " :+:    :+:   :+: :+:   +:+:+: :+:+:+ :+:    :+: :+:    :+:\n"
        " +:+    +:+  +:+   +:+  +:+ +:+:+ +:+ +:+    +:+ +:+       \n"
        " +#++:++#+  +#++:++#++: +#+  +:+  +#+ +#+    +:+ +#++:++#++\n"
        " +#+    +#+ +#+     +#+ +#+       +#+ +#+    +#+        +#+\n"
        " #+#    #+# #+#     #+# #+#       #+# #+#    #+# #+#    #+#\n"
        " #########  ###     ### ###       ###  ########   ######## \n\n\n"
    ;
    const char welcome_str[] = 
        " Welcome to BamOS v0.0.1 !\n"
        " Made by Pigulevskiy Konstantin & Borisevich Matvey\n\n"
        " GitHub: https://github.com/bagggage/bamos\n\n"
    ;

    fwrite(logo_str, sizeof(logo_str) - 1, 1, stdout);
    fwrite(welcome_str, sizeof(welcome_str) - 1, 1, stdout);
    fwrite("$ ", 2, 1, stdout);

    char c;
    char* buffer[512] = { '\0' };

    size_t cursor_idx = 0;

    while (1) {
        if (fread(&c, 1, 1, stdout) == 1) {
            if (c == '\n') {
                fwrite("\n$ ", 3, 1, stdout);
                buffer[0] = '\0';
                cursor_idx = 0;
                continue;
            }
            else if (c != '\b') {
                fwrite(&c, 1, 1, stdout);
                buffer[cursor_idx++] = c;
                buffer[cursor_idx] = '\0';
            }
            else if (cursor_idx > 0) {
                fwrite(&c, 1, 1, stdout);
                buffer[--cursor_idx] = '\0';
            }
        }
    }

    fclose(stdout);

    while(1);
}
