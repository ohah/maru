// 측정 사본 전용. callback은 encoding 시 복사한 frame 증명만 읽는다.
#include <pthread.h>
static pthread_mutex_t latency_lock = PTHREAD_MUTEX_INITIALIZER;
static uint64_t latency_seq, latency_base_rev, latency_base_pre, latency_post, latency_event, latency_arrival, latency_key;
static uint64_t latency_first, latency_color, latency_first_gen, latency_color_gen, latency_full, latency_full_gen;
static uint64_t latency_mark[7];
static uint64_t latency_now(void) { return (uint64_t)(CACurrentMediaTime() * 1e9); }
void maru_latency_begin(uint64_t seq, uint64_t revision, uint64_t pre) {
    pthread_mutex_lock(&latency_lock);
    latency_seq=seq; latency_base_rev=revision; latency_base_pre=pre; latency_post=latency_now();
    latency_event=latency_arrival=latency_key=latency_first=latency_color=latency_first_gen=latency_color_gen=latency_full=latency_full_gen=0;
    pthread_mutex_unlock(&latency_lock);
}
void maru_latency_keydown(uint64_t code, double timestamp) {
    pthread_mutex_lock(&latency_lock);
    if (latency_seq && !latency_arrival) { latency_arrival=latency_now(); latency_event=(uint64_t)(timestamp*1e9); latency_key=code; }
    pthread_mutex_unlock(&latency_lock);
}
void maru_latency_mark_frame(const uint64_t *v) { memcpy(latency_mark,v,sizeof(latency_mark)); }
void maru_latency_poll(uint64_t *out) {
    pthread_mutex_lock(&latency_lock);
    uint64_t v[]={latency_seq,latency_post,latency_event,latency_arrival,latency_key,latency_first,latency_color,latency_first_gen,latency_color_gen,latency_full,latency_full_gen};
    memcpy(out,v,sizeof(v));
    pthread_mutex_unlock(&latency_lock);
}
static void latency_arm(id<CAMetalDrawable> drawable) {
    const uint64_t gen=latency_mark[0], rev=latency_mark[1], pre=latency_mark[2], ready=latency_mark[3], full=(latency_mark[6]&1);
    pthread_mutex_lock(&latency_lock);
    const uint64_t seq=latency_seq;
    const bool changed=gen && (rev!=latency_base_rev || pre!=latency_base_pre);
    pthread_mutex_unlock(&latency_lock);
    if (!seq || !changed || getenv("MARU_LATENCY_DROP_PRESENT") != NULL) return;
    [drawable addPresentedHandler:^(id<MTLDrawable> shown) {
        const uint64_t at=(uint64_t)(shown.presentedTime*1e9);
        if (!at) return; // 드롭되거나 표시되지 않은 drawable을 지연 표본에 넣지 않는다.
        pthread_mutex_lock(&latency_lock);
        if (latency_seq==seq && at>=latency_post && latency_arrival) {
            if (!latency_first || at<latency_first) { latency_first=at; latency_first_gen=gen; }
            if (ready && full && (!latency_full || at<latency_full)) { latency_full=at;latency_full_gen=gen; }
            if (ready && (!latency_color || at<latency_color)) { latency_color=at; latency_color_gen=gen; }
        }
        pthread_mutex_unlock(&latency_lock);
    }];
}
#include <sys/resource.h>
#include <mach/mach.h>
void maru_latency_memory(uint64_t *out) {
    struct rusage usage={0};
    mach_task_basic_info_data_t info={0};
    mach_msg_type_number_t count=MACH_TASK_BASIC_INFO_COUNT;
    getrusage(RUSAGE_SELF,&usage);
    const kern_return_t status=task_info(mach_task_self(),MACH_TASK_BASIC_INFO,(task_info_t)&info,&count);
    out[0]=(uint64_t)usage.ru_maxrss; // Darwin getrusage(2): bytes, 자식 프로세스 제외.
    out[1]=status==KERN_SUCCESS ? info.resident_size : 0;
}
