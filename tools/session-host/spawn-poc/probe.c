/* Self-contained child oracle: inspect the descriptor table before a shell can modify it. */
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc == 2 && !strcmp(argv[1], "group")) {
        printf("%d %d\n", getpid(), getpgrp());
        return 0;
    }
    if (argc == 3 && !strcmp(argv[1], "fd")) {
        puts(fcntl(atoi(argv[2]), F_GETFD) < 0 ? "closed" : "open");
        return 0;
    }
    return 2;
}
