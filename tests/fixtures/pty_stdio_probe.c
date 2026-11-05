/* Observe the real terminal before shell startup can repair its descriptors. */
#include <sys/ioctl.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int main(int argc, char **argv) {
    const char *mode = argc > 1 ? argv[1] : "report";
    if (!strcmp(mode, "exit")) return 42;
    if (!strcmp(mode, "read")) {
        char data[128]; ssize_t n = read(0, data, sizeof data - 1);
        if (n <= 0) return 3;
        data[n] = 0; printf("read:%s", data); return 0;
    }
    struct winsize size = {0}; char cwd[4096];
    if (ioctl(0, TIOCGWINSZ, &size) || !getcwd(cwd, sizeof cwd)) return 4;
    printf("tty:%d%d%d sid:%d group:%d foreground:%d size:%dx%d px:%dx%d\n",
        isatty(0), isatty(1), isatty(2), getsid(0) == getpid(), getpgrp() == getpid(),
        tcgetpgrp(0) == getpgrp(), size.ws_col, size.ws_row, size.ws_xpixel, size.ws_ypixel);
    printf("cwd:%s env:%s arg:%s\n", cwd, getenv("PTY_PROBE") ? getenv("PTY_PROBE") : "unset", argc > 2 ? argv[2] : "none");
    puts("COUT"); fputs("CERR\n", stderr);
    return 0;
}
