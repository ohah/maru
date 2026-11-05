// Diagnostic interposer for owned, ad-hoc signed actor copies only.
// Observe the actual ioctl writer and hold one SET to choose the syscall order.
// This is never loaded into a product or an installed system binary.
#include <sys/ioctl.h>
#include <sys/ioccom.h>
#include <sys/types.h>
#include <sys/time.h>
#include <stdarg.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <time.h>
#include <string.h>
static int observed_ioctl(int fd, unsigned long request, ...) {
    int entry_errno=errno;
    void *argument=NULL;
    // SDK data requests use a pointer. The void tty requests in these actors
    // have no payload; this restricted diagnostic is not a general ioctl shim.
    if ((request & (IOC_IN|IOC_OUT)) != 0) {
        va_list args; va_start(args,request); argument=va_arg(args,void *); va_end(args);
    }
    static int gated=0;
    const char *gate=getenv("MARU_POC_GATE");
    int this_gate=0;
    if(request==TIOCSWINSZ && !gated && gate && !strcmp(getprogname(),"bash")) {
        char path[4096];snprintf(path,sizeof(path),"%s/arm",gate);
        if(access(path,F_OK)==0) {
            gated=1;this_gate=1;
            snprintf(path,sizeof(path),"%s/ready.tmp",gate);
            int note=open(path,O_WRONLY|O_CREAT|O_EXCL,0600);
            if(note>=0) {
                struct winsize *ws=argument;
                dprintf(note,"%d %u %u %u %u\n",getpid(),ws->ws_row,ws->ws_col,ws->ws_xpixel,ws->ws_ypixel);
                close(note);
                char ready_path[4096];snprintf(ready_path,sizeof(ready_path),"%s/ready",gate);
                (void)rename(path,ready_path); // publish the complete gate record
            }
            snprintf(path,sizeof(path),"%s/release",gate);
            struct timespec begin,now;clock_gettime(CLOCK_MONOTONIC,&begin);
            while(access(path,F_OK)!=0) {
                clock_gettime(CLOCK_MONOTONIC,&now);
                if(now.tv_sec-begin.tv_sec>=3) {
                    snprintf(path,sizeof(path),"%s/timeout",gate);
                    int timeout_fd=open(path,O_WRONLY|O_CREAT|O_EXCL,0600);
                    if(timeout_fd>=0) close(timeout_fd);
                    break;
                }
                usleep(1000);
            }
        }
    }
    int skip=0;
    if(this_gate && getenv("MARU_POC_DROP_STALE")) {
        struct winsize actual;struct winsize *proposed=argument;
        if(ioctl(fd,TIOCGWINSZ,&actual)==0 && memcmp(&actual,proposed,sizeof(actual))) skip=1;
    }
    // Gate/logging syscalls must not leak their errno into the observed call.
    errno=entry_errno;
    int rc=skip?0:ioctl(fd,request,argument); int saved=errno;
    if(request==TIOCGWINSZ || request==TIOCSWINSZ) {
        struct winsize snapshot={0};
        if(argument && (request==TIOCSWINSZ || rc==0)) snapshot=*(struct winsize *)argument;
        struct winsize *ws=&snapshot;
        const char *path=getenv("MARU_POC_TRACE");
        if(path && ws) {
            int log=open(path,O_WRONLY|O_CREAT|O_APPEND,0600);
            if(log>=0) {
                char line[384];int n=snprintf(line,sizeof(line),"{\"pid\":%d,\"op\":\"%s\",\"fd\":%d,\"size\":[%u,%u,%u,%u],\"rc\":%d,\"gated\":%d}\n",getpid(),skip?"skip":(request==TIOCSWINSZ?"set":"get"),fd,ws->ws_row,ws->ws_col,ws->ws_xpixel,ws->ws_ypixel,rc,this_gate);
                if(n>0 && n<(int)sizeof(line)) (void)write(log,line,(size_t)n);
                close(log);
            }
        }
    }
    errno=saved;return rc;
}
__attribute__((used,section("__DATA,__interpose"))) static const struct {
    const void *replacement;const void *original;
} mapping={(const void *)observed_ioctl,(const void *)ioctl};
