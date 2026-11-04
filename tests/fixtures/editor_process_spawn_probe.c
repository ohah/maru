/* Inspect inherited state before a shell can close or rearrange descriptors. */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
int main(int argc, char **argv) {
    if (argc < 2) return 2;
    if (!strcmp(argv[1], "group")) { printf("%d|%d\n", getpid(), getpgrp()); return 0; }
    if (!strcmp(argv[1], "fd") && argc == 3) { puts(fcntl(atoi(argv[2]), F_GETFD) < 0 ? "closed" : "open"); return 0; }
    if (!strcmp(argv[1], "context") && argc == 3) {
        char cwd[4096]; if (!getcwd(cwd, sizeof cwd)) return 3;
        const char *value = getenv("EDITOR_SPAWN_PROBE");
        printf("%s|%s|%s\n", argv[2], cwd, value ? value : "unset"); return 0;
    }
    if (!strcmp(argv[1], "streams")) { write(1, "out", 3); write(2, "err", 3); return 0; }
    if (!strcmp(argv[1], "exit") && argc == 3) return atoi(argv[2]);
    if (!strcmp(argv[1], "sleep")) { sleep(30); return 0; }
    return 2;
}
