// A small owned executable named bash exercises the observer's actor branch.
// Compare its native return values/errno with and without the diagnostic library.
#include <errno.h>
#include <stdio.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <util.h>
int main(void) {
    int master,slave;struct winsize size={.ws_row=27,.ws_col=91};
    if(openpty(&master,&slave,NULL,NULL,&size)) return 125;
    int values[8];
    errno=E2BIG;values[0]=ioctl(slave,TIOCGWINSZ,&size);values[1]=errno;
    errno=E2BIG;values[2]=ioctl(slave,TIOCSWINSZ,&size);values[3]=errno;
    errno=E2BIG;values[4]=ioctl(-1,TIOCGWINSZ,&size);values[5]=errno;
    errno=E2BIG;values[6]=ioctl(-1,TIOCSWINSZ,&size);values[7]=errno;
    for(int i=0;i<8;++i) printf("%d%c",values[i],i==7?'\n':' ');
    close(master);close(slave);
    return values[0]!=0 || values[2]!=0 || values[4]!=-1 || values[5]!=EBADF || values[6]!=-1 || values[7]!=EBADF;
}
