// 입력 사본에서만 쓰는 단조 CPU 시계와 drawable 획득 경계다. main에서 기록/복사한다.
#include <time.h>
static uint64_t input_draw_rows[2048][9],input_draw_count,input_draw_overflow,input_draw_failures[2];
static uint64_t input_terminal_begin,input_terminal_end,input_overlay_begin,input_overlay_end;
uint64_t maru_input_display_cpu(void) {
    struct timespec value={0};
    if (clock_gettime(CLOCK_THREAD_CPUTIME_ID,&value)!=0) return 0;
    return (uint64_t)value.tv_sec*1000000000ULL+(uint64_t)value.tv_nsec;
}
uint64_t maru_input_display_thread(void) {
    uint64_t tid=0;pthread_threadid_np(NULL,&tid);return tid;
}
static void inputDrawableReset(void) {
    input_terminal_begin=input_terminal_end=input_overlay_begin=input_overlay_end=0;
}
static void inputDrawableBegin(unsigned overlay) {
    if (overlay) input_overlay_begin=stream_now();else input_terminal_begin=stream_now();
}
static void inputDrawableEnd(unsigned overlay,bool acquired) {
    if (!acquired) input_draw_failures[overlay?1:0]++;
    if (overlay) input_overlay_end=stream_now();else input_terminal_end=stream_now();
}
static void inputDrawableRecord(uint64_t gen,uint64_t prefix,uint64_t ready) {
    if (input_draw_count==2048) { input_draw_overflow=1;return; }
    uint64_t *r=input_draw_rows[input_draw_count++];
    r[0]=gen;r[1]=prefix;r[2]=ready;r[3]=post_renderer_ns;
    r[4]=input_terminal_begin;r[5]=input_terminal_end;r[6]=input_overlay_begin;r[7]=input_overlay_end;
    r[8]=maru_input_display_thread();
}
void maru_input_display_draws(uint64_t *header,uint64_t *rows) {
    header[0]=input_draw_count;header[1]=input_draw_overflow;header[2]=input_draw_failures[0];header[3]=input_draw_failures[1];
    memcpy(rows,input_draw_rows,sizeof(input_draw_rows));
}
