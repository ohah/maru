// Isolated Darwin experiment, derived from public openpty/setsid/ioctl/spawn APIs.
// This models the product's syscall order; it does not import or replace PtySession.
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>
#include <util.h>
extern char **environ;
static volatile sig_atomic_t owned_child;
static void deadline(int sig) {
    (void)sig;
    if (owned_child > 0) { kill(-owned_child, SIGKILL); kill(owned_child, SIGKILL); }
    _exit(124);
}
static void cleanup(void) {
    if (owned_child > 0) {
        kill(-owned_child,SIGKILL); kill(owned_child,SIGKILL);
        while (waitpid(owned_child,NULL,0)<0 && errno==EINTR) {}
        owned_child=0;
    }
}
static void must(int ok) { if (!ok) { perror("poc setup"); exit(125); } }
static int promote(int fd) {
    if (fd > 2) return fd;
    int moved = fcntl(fd, F_DUPFD_CLOEXEC, 3);
    must(moved >= 0); close(fd); return moved;
}
static void child_cwd(const char *cwd) {
    if (strcmp(cwd, "-") && chdir(cwd)) {
        const char *home = getenv("HOME");
        if (home) (void)chdir(home);
    }
}
static int probe(int argc, char **argv) {
    char cwd[4096]; must(getcwd(cwd, sizeof(cwd)) != NULL);
    int tty = open("/dev/tty", O_RDWR | O_NOCTTY);
    struct winsize ws = {0}; (void)ioctl(0, TIOCGWINSZ, &ws);
    printf("pid=%d sid=%d pgid=%d fg=%d tty=%d stdio=%d%d%d cols=%d rows=%d ambient=%d\n",
           getpid(), getsid(0), getpgrp(), tcgetpgrp(0), tty >= 0,
           isatty(0), isatty(1), isatty(2), ws.ws_col, ws.ws_row,
           fcntl(83, F_GETFD) >= 0);
    printf("login_name=%s\n", getlogin() ?: "<none>");
    printf("cwd=%s\nenv=%s\narg=%s\nlogin=%d\n", cwd,
           getenv("PTY_POC_VALUE") ?: "", argc > 2 ? argv[2] : "", argv[0][0] == '-');
    if (tty >= 0) close(tty);
    fprintf(stderr, "stderr=ok\n"); fflush(NULL);
    if (getenv("PTY_POC_INPUT")) {
        char line[32]; if (!fgets(line, sizeof(line), stdin)) return 97;
        printf("input=%s", line);
    }
    if (getenv("PTY_POC_SIGNAL")) {
        // Readiness marker precedes SIGINT. Never depend on sleep timing.
        struct sigaction sa = {.sa_handler = SIG_DFL}; sigemptyset(&sa.sa_mask);
        sigaction(SIGINT, &sa, NULL); sigset_t empty; sigemptyset(&empty);
        sigprocmask(SIG_SETMASK, &empty, NULL);
        puts("signal-ready"); fflush(NULL); for (;;) pause();
    }
    return getenv("PTY_POC_EXIT") ? atoi(getenv("PTY_POC_EXIT")) : 0;
}
int main(int argc, char **argv) {
    if (argc > 1 && !strcmp(argv[1], "--probe")) return probe(argc, argv);
    if (argc > 1 && !strcmp(argv[1], "--helper")) {
        // Fresh exec image does the operations unavailable as spawn file actions.
        // No threads or allocator state are inherited across this exec boundary.
        if (ioctl(0, TIOCSCTTY, 0)) return 126;
        child_cwd(argv[2]); execve(argv[3], argv + 3, environ); return 127;
    }
    if (argc < 5) return 125;
    must(atexit(cleanup)==0);
    const char *mode = argv[1], *cwd = argv[2];
    int closed = atoi(getenv("PTY_POC_CLOSED") ?: "0");
    int cloexec = atoi(getenv("PTY_POC_CLOEXEC") ?: "0");
    int saved_out = fcntl(1, F_DUPFD_CLOEXEC, 90); must(saved_out >= 0);
    int nullfd = open("/dev/null", O_RDONLY); must(nullfd >= 0);
    must(dup2(nullfd, 83) == 83); close(nullfd); // intentional ambient FD control
    for (int fd = 0; fd < 3; ++fd) {
        if (closed & (1 << fd)) close(fd);
        else if (cloexec & (1 << fd)) must(fcntl(fd, F_SETFD, FD_CLOEXEC) == 0);
    }
    int master, slave; char name[128]; struct winsize ws = {.ws_row=27,.ws_col=91};
    must(openpty(&master, &slave, name, NULL, &ws) == 0);
    master = promote(master); slave = promote(slave);
    must(fcntl(master, F_SETFD, FD_CLOEXEC) == 0);
    must(fcntl(slave, F_SETFD, FD_CLOEXEC) == 0);
    must(fcntl(master, F_SETFL, O_NONBLOCK) == 0);
    signal(SIGALRM, deadline); alarm(8);
    pid_t pid = -1; int spawn_error = 0;
    if (!strcmp(mode, "fork")) {
        pid = fork(); must(pid >= 0);
        if (!pid) {
            if (setsid() < 0 || ioctl(slave, TIOCSCTTY, 0)) _exit(126);
            child_cwd(cwd);
            for (int fd=0; fd<3; ++fd) if (dup2(slave,fd)<0) _exit(126);
            close(master); close(slave); execve(argv[3], argv+3, environ); _exit(127);
        }
    } else {
        posix_spawnattr_t attr; posix_spawn_file_actions_t actions;
        must(posix_spawnattr_init(&attr) == 0);
        must(posix_spawn_file_actions_init(&actions) == 0);
        must(posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT) == 0);
        if (!strcmp(mode, "spawn-open")) {
            must(posix_spawn_file_actions_addopen(&actions, 0, name, O_RDWR, 0) == 0);
            for (int fd=1;fd<3;++fd) must(posix_spawn_file_actions_adddup2(&actions,0,fd)==0);
        } else {
            for (int fd=0;fd<3;++fd) must(posix_spawn_file_actions_adddup2(&actions,slave,fd)==0);
        }
        char **child_argv = argv+3;
        char **helper = NULL;
        const char *exe = argv[3];
        if (!strcmp(mode, "spawn-helper")) {
            helper = calloc((size_t)argc + 1, sizeof(char *)); must(helper != NULL);
            helper[0] = argv[0]; helper[1] = "--helper"; helper[2] = argv[2];
            for (int i=3;i<argc;++i) helper[i]=argv[i];
            exe=argv[0]; child_argv=helper;
        } else if (strcmp(cwd, "-")) {
            // Deliberately no parent preflight: a pathname action cannot express
            // the product's child-time cwd -> HOME -> inherited fallback.
            must(posix_spawn_file_actions_addchdir(&actions,cwd)==0);
        }
        spawn_error = posix_spawn(&pid,exe,&actions,&attr,child_argv,environ);
        free(helper); posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attr);
    }
    if (spawn_error) {
        dprintf(saved_out,"spawn_error=%d\n",spawn_error);
        close(slave); close(master); close(83); close(saved_out); return 0;
    }
    owned_child=pid; close(slave);
    char output[32768] = {0}; size_t used=0; int status=0, reaped=0, signalled=0, input=0;
    time_t interrupt_at=0;
    for (;;) {
        ssize_t n=read(master,output+used,sizeof(output)-used-1);
        if(n>0) { used+=(size_t)n; output[used]=0; }
        if (!input && getenv("PTY_POC_INPUT")) { must(write(master,"hello\n",6)==6); input=1; }
        if (signalled==0 && strstr(output,"signal-ready")) {
            // A terminal-generated interrupt tests real controlling-terminal ownership.
            must(write(master,"\003",1)==1); signalled=1; interrupt_at=time(NULL);
        }
        // Bound the negative Ctrl+C control without throwing away its probe output.
        if (signalled==1 && !reaped && time(NULL)-interrupt_at >= 2) {
            must(kill(pid,SIGKILL)==0); signalled=2;
        }
        if (!reaped) { pid_t got=waitpid(pid,&status,WNOHANG); must(got>=0); reaped=got==pid; if (reaped) owned_child=0; }
        if(reaped && n<=0) break;
        must(used < sizeof(output)-1);
        struct pollfd p={.fd=master,.events=POLLIN}; (void)poll(&p,1,10);
    }
    alarm(0); owned_child=0; output[used]=0;
    errno=0; must(waitpid(pid,NULL,WNOHANG)==-1 && errno==ECHILD);
    dprintf(saved_out,"%s\nexit=%d signal=%d spawn_error=0 reaped=1\n",output,
            WIFEXITED(status)?WEXITSTATUS(status):-1,WIFSIGNALED(status)?WTERMSIG(status):0);
    close(master); close(83); close(saved_out); return 0;
}
