/* Independent syscall experiment: change only the ordering of two group requests. */
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

struct child_observation { int result, error; pid_t group, session; };
static void move_bytes(int fd, void *data, size_t size, int send) {
    unsigned char *p = data;
    while (size) {
        ssize_t n = send ? write(fd, p, size) : read(fd, p, size);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) _exit(3);
        p += n; size -= (size_t)n;
    }
}
int main(int argc, char **argv) {
    if (argc != 3) return 2;
    int parent_first = !strcmp(argv[1], "parent-first");
    int child_first = !strcmp(argv[1], "child-first");
    int child_only = !strcmp(argv[1], "child-only");
    if (!parent_first && !child_first && !child_only && strcmp(argv[1], "overlap")) return 2;
    int count = atoi(argv[2]);
    int parent_fail = 0, child_fail = 0, wrong_group = 0, wrong_session = 0, other_errno = 0;
    for (int iteration = 0; iteration < count; ++iteration) {
        int report[2], gate[2];
        if (pipe(report) || pipe(gate)) return 3;
        pid_t session = getsid(0);
        pid_t child = fork();
        if (child < 0) return 3;
        if (!child) {
            close(report[0]); close(gate[1]);
            char token = 0;
            if (parent_first) move_bytes(gate[0], &token, 1, 0);
            struct child_observation result;
            result.result = setpgid(0, 0);
            result.error = result.result ? errno : 0;
            result.group = getpgrp(); result.session = getsid(0);
            move_bytes(report[1], &result, sizeof result, 1);
            move_bytes(gate[0], &token, 1, 0);
            _exit(0);
        }
        close(report[1]); close(gate[0]);
        int result = 0, error = 0;
        char token = 0;
        if (!child_first && !child_only) { result = setpgid(child, child); error = result ? errno : 0; }
        if (parent_first) move_bytes(gate[1], &token, 1, 1);
        struct child_observation observed;
        move_bytes(report[0], &observed, sizeof observed, 0);
        if (child_first) { result = setpgid(child, child); error = result ? errno : 0; }
        pid_t final_group = getpgid(child);
        parent_fail += result != 0; child_fail += observed.result != 0;
        wrong_group += final_group != child;
        wrong_session += observed.session != session;
        other_errno += (result && error != EPERM) || (observed.result && observed.error != EPERM);
        if ((result || observed.result || final_group != child) && parent_fail + child_fail + wrong_group < 9)
            printf("mode=%s iteration=%d child=%d parent_rc=%d parent_errno=%d child_rc=%d child_errno=%d observed_group=%d final_group=%d inherited_session=%d child_session=%d\n", argv[1], iteration, child, result, error, observed.result, observed.error, observed.group, final_group, session, observed.session);
        move_bytes(gate[1], &token, 1, 1);
        close(gate[1]); close(report[0]);
        int status = 0;
        while (waitpid(child, &status, 0) < 0) if (errno != EINTR) return 3;
        if (!WIFEXITED(status) || WEXITSTATUS(status)) return 3;
    }
    printf("summary mode=%s iterations=%d parent_failures=%d child_failures=%d wrong_group=%d changed_session=%d other_errno=%d\n", argv[1], count, parent_fail, child_fail, wrong_group, wrong_session, other_errno);
    return 0;
}
