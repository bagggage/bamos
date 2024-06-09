#include <sys/wait.h>

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#define UNUSED(x) (void)(x)

int main(int argc, const char** argv, char** envp) {
    UNUSED(argc);
    UNUSED(argv);

    pid_t pid;

    if ((pid = getpid()) != 1) {
        fprintf(stderr, "Init process is already started\n");
        exit(-1);
    }

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

    puts(logo_str);
    puts(welcome_str);

    const char* shell_path = getenv("SHELL");

    if (shell_path == NULL) {
        fprintf(stderr, "Failed to get shell path environ\n");
        while (1);
    }

    while (1) {
        pid_t pid = fork();

        if (pid == 0) {
            int result = execve(shell_path, NULL, envp);

            fprintf(stderr, "[ERROR]: Failed to load shell: %s\n", shell_path);
            exit(result);
        }

        int result;
        pid = waitpid(-1, &result, 0);

        if (result < 0) {
            fprintf(stderr, "[ERROR]: The process pid: %u: exited with the code: %u\n", pid, -result);
            while(1);
        }
        else {
            puts("\033[H\033[J");
        }
    }
}