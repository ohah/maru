// Independent Darwin helper-initialization experiment. Not a product launcher.
// Public SDK pipe/poll/posix_spawn/tty contracts define this wire experiment.
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include <util.h>
extern char **environ;
static volatile sig_atomic_t owned_pid;
static volatile sig_atomic_t alarm_seen;
static void interrupted(int sig){(void)sig;alarm_seen=1;}
static void terminate_owned(int sig){(void)sig;pid_t pid=owned_pid;if(pid>0){kill(-pid,SIGKILL);kill(pid,SIGKILL);while(waitpid(pid,NULL,0)<0 && errno==EINTR){}}_exit(124);}
// Keep cancellation ownership valid across the waitpid/PID-release boundary.
static pid_t owned_wait(pid_t pid,int *status,int options){
    sigset_t guard,old;sigemptyset(&guard);sigaddset(&guard,SIGTERM);
    sigprocmask(SIG_BLOCK,&guard,&old);
    pid_t result=waitpid(pid,status,options);int saved=errno;
    if(result==pid)owned_pid=0;
    sigprocmask(SIG_SETMASK,&old,NULL);errno=saved;return result;
}
enum { REQUEST=1, CHANNEL=2, TTY=3, CWD=4, EXEC=5 };
static int same(const char *a,const char *b){return strcmp(a,b)==0;}
static int64_t now_ms(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return (int64_t)t.tv_sec*1000+t.tv_nsec/1000000;}
static void pause_ms(int n){struct timespec t={n/1000,(n%1000)*1000000L};while(nanosleep(&t,&t)<0 && errno==EINTR){}}
static int write_all(int fd,const void *data,size_t n){const unsigned char *p=data;while(n){ssize_t k=write(fd,p,n);if(k<0 && errno==EINTR)continue;if(k<=0)return -1;p+=k;n-=(size_t)k;}return 0;}
static void frame(unsigned char b[12],int stage,int error){memcpy(b,"PHER",4);b[4]=1;b[5]=(unsigned char)stage;b[6]=b[7]=0;uint32_t e=(uint32_t)error;for(int i=0;i<4;i++)b[8+i]=(unsigned char)(e>>(24-8*i));}
static void fail_stage(int stage,int error){unsigned char b[12];frame(b,stage,error);(void)write_all(4,b,sizeof(b));_exit(126);}
static int target(int argc,char **argv){
    if(argc>2 && same(argv[2],"silent"))return 42;
    if(argc>2 && same(argv[2],"silent-zero"))return 0;
    if(argc>2 && same(argv[2],"hang")){for(;;)pause();}
    if(getenv("INIT_DELAY_TARGET"))pause_ms(15);
    char cwd[4096];const char *expected=getenv("INIT_EXPECT_CWD");
    int cwd_ok=getcwd(cwd,sizeof(cwd)) && expected && same(cwd,expected);
    int req_closed=fcntl(3,F_GETFD)<0 && errno==EBADF;
    int err_closed=fcntl(4,F_GETFD)<0 && errno==EBADF;
    int ambient_closed=fcntl(83,F_GETFD)<0 && errno==EBADF;
    for(int fd=5;fd<256;fd++)if(fcntl(fd,F_GETFD)>=0)ambient_closed=0;
    printf("INIT_READY %ld %d %d %d %d %d %d\n",(long)getpid(),req_closed,err_closed,ambient_closed,
           getsid(0)==getpid() && getpgrp()==getpid() && tcgetpgrp(0)==getpid(),
           isatty(0)&&isatty(1)&&isatty(2),cwd_ok);fflush(stdout);return 0;
}
static int helper(int argc,char **argv){
    if(argc!=5)return 125;
    const char *kind=argv[2];
    // Close-on-exec belongs to the fresh helper, before any fallible setup.
    if(fcntl(4,F_SETFD,FD_CLOEXEC)<0)_exit(125);
    if(same(kind,"request-broken-pipe"))return 23;
    unsigned char req[9];size_t used=0;
    for(;;){ssize_t n=read(3,req+used,sizeof(req)-used);if(n<0 && errno==EINTR)continue;if(n<0)fail_stage(REQUEST,errno);if(!n)break;used+=(size_t)n;if(used==sizeof(req))break;}
    close(3);
    static const unsigned char valid[8]={'P','H','R','Q',1,0,0,0};
    if(used!=8 || memcmp(req,valid,8))fail_stage(REQUEST,EPROTO);
    if(same(kind,"early-death"))_exit(23);
    if(same(kind,"early-zero"))_exit(0);
    if(same(kind,"hang-helper") || same(kind,"cancel") || same(kind,"read-error")){for(;;)pause();}
    if(same(kind,"signal-death")){raise(SIGKILL);_exit(125);}
    if(!strncmp(kind,"wire-",5)){
        unsigned char b[24];frame(b,EXEC,ENOENT);size_t n=12;
        if(same(kind,"wire-magic"))b[0]='X';
        if(same(kind,"wire-version"))b[4]=2;
        if(same(kind,"wire-stage"))b[5]=99;
        if(same(kind,"wire-reserved"))b[6]=1;
        if(same(kind,"wire-zero-errno"))memset(b+8,0,4);
        if(same(kind,"wire-negative-errno"))memset(b+8,255,4);
        if(same(kind,"wire-short") || same(kind,"wire-hold"))n=7;
        if(same(kind,"wire-extra")){b[12]=0;n=13;}
        if(same(kind,"wire-duplicate")){memcpy(b+12,b,12);n=24;}
        if(same(kind,"wire-fragment") || same(kind,"wire-trickle")){for(size_t i=0;i<n;i++){(void)write_all(4,b+i,1);pause_ms(same(kind,"wire-trickle")?80:1);}}
        else (void)write_all(4,b,n);
        if(same(kind,"wire-hold") || same(kind,"wire-full-open"))for(;;)pause();
        _exit(126);
    }
    if(same(kind,"channel-error")){close(4);fail_stage(CHANNEL,EBADF);}
    if(ioctl(0,TIOCSCTTY,0)<0)fail_stage(TTY,errno);
    if(chdir(argv[3])<0){int first=errno;const char *home=getenv("HOME");if(!home)fail_stage(CWD,first);if(chdir(home)<0)fail_stage(CWD,errno);}
    const char *exe=argv[4];
    char *args[]={(char *)exe,"--target",same(kind,"silent-target")?"silent":same(kind,"silent-zero")?"silent-zero":same(kind,"hang-target")?"hang":"ready",NULL};
    execve(exe,args,environ);fail_stage(EXEC,errno);
    return 125;
}
static int high_fd(int fd){if(fd<0)return -1;int n=fcntl(fd,F_DUPFD_CLOEXEC,10);int saved=errno;close(fd);errno=saved;return n;}
static int make_pipe(int fds[2]){int p[2];if(pipe(p)<0)return -1;fds[0]=high_fd(p[0]);fds[1]=high_fd(p[1]);return fds[0]<0 || fds[1]<0?-1:0;}
static void close_fd(int *fd){if(*fd>=0)close(*fd);*fd=-1;}
int main(int argc,char **argv){
    if(argc>1 && same(argv[1],"--target"))return target(argc,argv);
    if(argc>1 && same(argv[1],"--helper"))return helper(argc,argv);
    if(argc!=5){fprintf(stderr,"usage: init_status CASE CWD TARGET BUDGET_MS\n");return 125;}
    const char *kind=argv[1];int budget=atoi(argv[4]);if(budget<50 || budget>5000)return 125;
    int64_t begin=now_ms(),deadline=begin+budget;
    int saved_output=-1;
    if(!strncmp(kind,"closed-",7)){saved_output=high_fd(dup(1));if(saved_output<0)return 125;int mask=atoi(kind+7);for(int fd=0;fd<3;fd++)if(mask&(1<<fd))close(fd);}
    if(same(kind,"cloexec-stdio"))for(int fd=0;fd<3;fd++)(void)fcntl(fd,F_SETFD,FD_CLOEXEC);
    int request[2]={-1,-1},status[2]={-1,-1},master=-1,slave=-1,ambient=-1;
    int spawn_error=0,stage=0,native_error=0,reaped=0,child_status=0,eof=0,ready=0,ready_valid=0,killed=0;
    int held[128],held_count=0;
    int poll_eintr=0;
    int alarm_count=0;pid_t pid=-1;const char *outcome="setup-error";
    unsigned char wire[25];size_t wire_used=0;char output[4096]={0};size_t output_used=0;
    signal(SIGPIPE,SIG_IGN);
    struct sigaction sa={.sa_handler=interrupted};sigemptyset(&sa.sa_mask);sigaction(SIGALRM,&sa,NULL);
    struct sigaction term={.sa_handler=terminate_owned};sigemptyset(&term.sa_mask);sigaction(SIGTERM,&term,NULL);
    // Source FDs stay above mapped 0..4, including when the caller closes stdio.
    if(same(kind,"fd-exhaustion")){
        struct rlimit limit={64,64};if(setrlimit(RLIMIT_NOFILE,&limit)<0)return 125;
        int fd;while((fd=open("/dev/null",O_RDONLY))>=0)held[held_count++]=fd;
    }
    if(same(kind,"prep-deadline"))pause_ms(budget+15);
    if(same(kind,"prep-valid"))pause_ms(20);
    if(now_ms()>=deadline){outcome="timeout";goto done;}
    if(make_pipe(request)<0 || make_pipe(status)<0 || openpty(&master,&slave,NULL,NULL,NULL)<0){native_error=errno;goto done;}
    master=high_fd(master);slave=high_fd(slave);if(master<0 || slave<0){native_error=errno;goto done;}
    ambient=open("/dev/null",O_RDONLY);if(ambient<0 || dup2(ambient,83)<0){native_error=errno;goto done;}close_fd(&ambient);ambient=83;
    if(same(kind,"not-a-tty")){close_fd(&slave);slave=high_fd(open("/dev/null",O_RDWR));}
    posix_spawnattr_t attr;posix_spawn_file_actions_t actions;
    int ae=posix_spawnattr_init(&attr);if(ae){native_error=ae;goto done;}
    int fe=posix_spawn_file_actions_init(&actions);if(fe){posix_spawnattr_destroy(&attr);native_error=fe;goto done;}
    int e=posix_spawnattr_setflags(&attr,POSIX_SPAWN_SETSID|POSIX_SPAWN_CLOEXEC_DEFAULT|POSIX_SPAWN_SETSIGMASK|POSIX_SPAWN_SETSIGDEF);
    sigset_t empty,defaults;sigemptyset(&empty);sigemptyset(&defaults);sigaddset(&defaults,SIGPIPE);
    if(!e)e=posix_spawnattr_setsigmask(&attr,&empty);
    if(!e)e=posix_spawnattr_setsigdefault(&attr,&defaults);
    for(int fd=0;fd<3 && !e;fd++)e=posix_spawn_file_actions_adddup2(&actions,slave,fd);
    if(!e)e=posix_spawn_file_actions_adddup2(&actions,request[0],3);
    if(!e)e=posix_spawn_file_actions_adddup2(&actions,status[1],4);
    if(!e && same(kind,"spawn-bad-fd"))e=posix_spawn_file_actions_adddup2(&actions,9999,4);
    char *args[]={argv[0],"--helper",argv[1],argv[2],argv[3],NULL};
    sigset_t spawn_guard,old_guard;sigemptyset(&spawn_guard);sigaddset(&spawn_guard,SIGTERM);
    sigprocmask(SIG_BLOCK,&spawn_guard,&old_guard);
    if(same(kind,"spawn-missing"))spawn_error=posix_spawn(&pid,"/no/such/maru-init-helper",&actions,&attr,args,environ);
    else spawn_error=e?e:posix_spawn(&pid,argv[0],&actions,&attr,args,environ);
    if(!spawn_error)owned_pid=pid;
    sigprocmask(SIG_SETMASK,&old_guard,NULL);
    posix_spawn_file_actions_destroy(&actions);posix_spawnattr_destroy(&attr);
    close_fd(&request[0]);close_fd(&status[1]);close_fd(&slave);close_fd(&ambient);
    if(spawn_error){outcome="spawn-error";goto done;}
    if(fcntl(master,F_SETFL,O_NONBLOCK)<0 || fcntl(status[0],F_SETFL,O_NONBLOCK)<0){native_error=errno;goto done;}
    unsigned char req[9]={'P','H','R','Q',1,0,0,0,0};size_t n=8;
    if(same(kind,"request-version"))req[4]=2;
    if(same(kind,"request-magic"))req[0]='X';
    if(same(kind,"request-reserved"))req[6]=1;
    if(same(kind,"request-short"))n=4;
    if(same(kind,"request-extra"))n=9;
    if(same(kind,"request-eof"))n=0;
    if(same(kind,"request-write-error")){close_fd(&request[1]);if(write_all(request[1],req,n)<0)native_error=errno;outcome="request-write-error";goto done;}
    if(same(kind,"request-broken-pipe")){
        while(now_ms()<deadline){pid_t w=owned_wait(pid,&child_status,WNOHANG);if(w==pid){reaped=1;owned_pid=0;break;}if(w<0 && errno!=EINTR)break;pause_ms(1);}
    }
    if(write_all(request[1],req,n)<0){native_error=errno;outcome="request-write-error";goto done;}
    if(!same(kind,"request-open"))close_fd(&request[1]);
    if(same(kind,"read-error")){close(status[0]);/* retain the invalid number to exercise POLLNVAL */}
    if(same(kind,"poll-eintr")){ualarm(1000,1000);alarm_count=1;}
    for(;;){
        // One absolute deadline includes preparation, spawn, channel and target.
        int64_t left=deadline-now_ms();if(left<=0){outcome="timeout";break;}
        if(same(kind,"cancel") && now_ms()-begin>=30){outcome="cancelled";break;}
        struct pollfd p[2]={{status[0],POLLIN,0},{master,POLLIN,0}};
        if(eof)p[0].fd=-1;
        int r=poll(p,2,(int)(left>10?10:left));
        if(r<0){if(errno==EINTR){poll_eintr++;continue;}native_error=errno;outcome="read-error";break;}
        if(p[0].revents & POLLNVAL){native_error=EBADF;outcome="read-error";break;}
        if(p[0].revents & (POLLIN|POLLHUP|POLLERR)){
            ssize_t k=read(status[0],wire+wire_used,sizeof(wire)-wire_used);
            if(k>0){wire_used+=(size_t)k;if(wire_used>12){outcome="protocol-error";break;}}
            else if(k==0){eof=1;close_fd(&status[0]);}
            else if(errno!=EAGAIN && errno!=EINTR){native_error=errno;outcome="read-error";break;}
        }
        if(p[1].revents & (POLLIN|POLLHUP|POLLERR)){
            ssize_t k=read(master,output+output_used,sizeof(output)-output_used-1);
            if(k>0){output_used+=(size_t)k;output[output_used]=0;}
        }
        char *mark=strstr(output,"INIT_READY ");
        if(mark){long target_pid=0;int a=0,b=0,c=0,d=0,f=0,g=0;int fields=sscanf(mark,"INIT_READY %ld %d %d %d %d %d %d",&target_pid,&a,&b,&c,&d,&f,&g);ready=fields==7 && target_pid==pid;ready_valid=ready&&a&&b&&c&&d&&f&&g;}
        if(eof && wire_used){
            uint32_t err=0;for(int i=0;i<4 && wire_used==12;i++)err=(err<<8)|wire[8+i];
            if(wire_used!=12 || memcmp(wire,"PHER",4) || wire[4]!=1 || wire[5]<REQUEST || wire[5]>EXEC || wire[6] || wire[7] || err==0 || err>INT_MAX){outcome="protocol-error";break;}
            stage=wire[5];native_error=(int)err;outcome="helper-error";break;
        }
        if(eof && ready)outcome=ready_valid?"target-ready":"target-contract-error";
        if(!reaped){pid_t w=owned_wait(pid,&child_status,WNOHANG);if(w==pid){reaped=1;owned_pid=0;}else if(w<0 && errno!=EINTR){native_error=errno;outcome="wait-error";break;}}
        // Drain the PTY after exit before deciding an absent marker is final.
        if(reaped && eof){if(ready)break;ssize_t k=read(master,output+output_used,sizeof(output)-output_used-1);if(k>0){output_used+=(size_t)k;output[output_used]=0;continue;}if(k<0 && errno==EINTR)continue;outcome="closed-unverified";break;}
    }
done:
    ualarm(0,0);
    for(int i=0;i<held_count;i++)close(held[i]);
    close_fd(&request[0]);close_fd(&request[1]);close_fd(&status[0]);close_fd(&status[1]);close_fd(&master);close_fd(&slave);close_fd(&ambient);
    if(pid>0 && !spawn_error && !reaped){
        pid_t w=owned_wait(pid,&child_status,WNOHANG);if(w==pid){reaped=1;owned_pid=0;}
        if(!reaped){killed=kill(-pid,SIGKILL)==0;/* SETSID makes this owned child's group unique. */
            (void)kill(pid,SIGKILL);while((w=owned_wait(pid,&child_status,0))<0 && errno==EINTR){};reaped=w==pid;if(reaped)owned_pid=0;}
    }
    if(saved_output>=0){(void)dup2(saved_output,1);close(saved_output);}
    int group_gone=pid>0 && reaped && kill(-pid,0)<0 && errno==ESRCH;
    printf("{\"case\":\"%s\",\"outcome\":\"%s\",\"stage\":%d,\"errno\":%d,\"spawn_error\":%d,\"status_bytes\":%zu,\"eof\":%s,\"target_ready\":%s,\"target_contract\":%s,\"reaped\":%s,\"group_gone\":%s,\"group_killed\":%s,\"exit\":%d,\"signal\":%d,\"elapsed_ms\":%lld,\"alarm_armed\":%d,\"alarm_seen\":%d,\"poll_eintr\":%d}\n",kind,outcome,stage,native_error,spawn_error,wire_used,eof?"true":"false",ready?"true":"false",ready_valid?"true":"false",reaped?"true":"false",group_gone?"true":"false",killed?"true":"false",reaped&&WIFEXITED(child_status)?WEXITSTATUS(child_status):-1,reaped&&WIFSIGNALED(child_status)?WTERMSIG(child_status):0,(long long)(now_ms()-begin),alarm_count,(int)alarm_seen,poll_eintr);
    return 0;
}
