/* A private worker tree for the PTY identity test; never launches an agent. */
#include <stdlib.h>
#include <unistd.h>
#include <sys/wait.h>

int main(int argc, char **argv) {
    if ((argc > 1 && argv[1][0] == 'l') || (argc > 2 && argv[1][0] == 'r')) {
        for (;;) pause();
    }
    if (argc > 1 && setenv("MARU_RESUME_TEST_ID", "other-session", 1)) return 2;
    pid_t pid = fork();
    if (pid < 0) return 3;
    if (!pid) {
        execl(argv[0], argv[0], argc > 1 ? "leaf" : "maru-shared-worker", (char *)0);
        _exit(4);
    }
    int status;
    return waitpid(pid, &status, 0) < 0 ? 5 : 0;
}
