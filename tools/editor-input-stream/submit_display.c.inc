// GPU/커널 시각은 완료 handler 안에서만 읽는다(Apple MTLCommandBuffer 문서).
// 실제 시각과 callback 도착 시각을 구분하고 index·객체 신원을 값으로 캡처한다.
#include <math.h>
static pthread_mutex_t submit_lock=PTHREAD_MUTEX_INITIALIZER;
static uint64_t submit_rows[2048][S_WIDTH],submit_count,submit_overflow,submit_pending,submit_errors;
static bool submitEnabled(void) {
    static int value=-1;
    if (value<0) { const char *env=getenv("MARU_SUBMIT_DISPLAY_TIMED");value=env && strcmp(env,"1")==0; }
    return value==1;
}
static uint64_t submitNs(double seconds) {
    const double scaled=seconds*1e9;
    return isfinite(scaled) && scaled>0 && scaled<(double)UINT64_MAX ? (uint64_t)scaled : 0;
}
static uint64_t submitObject(id object) { return (uint64_t)(uintptr_t)(__bridge void *)object; }
static void submitDone(void) { if (submit_pending) submit_pending--;else submit_errors++; }
static uint64_t submitArm(id<MTLCommandBuffer> buffer,id<CAMetalDrawable> drawable) {
    if (!submitEnabled()) return UINT64_MAX;
    uint64_t stamp[9]={0};
    pthread_mutex_lock(&post_lock);
    if (post_active_draw) memcpy(stamp,post_draws[post_active_draw-1],sizeof(stamp));
    pthread_mutex_unlock(&post_lock);
    if (!stamp[0]) return UINT64_MAX; // 입력 계측 시작 전의 draw는 기존 계약처럼 제외한다.
    pthread_mutex_lock(&submit_lock);
    if (submit_count==2048) { submit_overflow=1;pthread_mutex_unlock(&submit_lock);return UINT64_MAX; }
    const uint64_t index=submit_count++,buffer_id=submitObject(buffer),drawable_id=submitObject(drawable);
    uint64_t *r=submit_rows[index];
    r[S_GENERATION]=stamp[0];r[S_PREFIX]=stamp[1];r[S_READY]=stamp[2];r[S_RENDERER]=stamp[4];r[S_COMMIT]=stamp[6];r[S_MAIN_THREAD]=stamp[8];
    r[S_COMMAND_BUFFER]=buffer_id;r[S_DRAWABLE]=drawable_id;
    submit_pending+=3;
    pthread_mutex_unlock(&submit_lock);
    [buffer addScheduledHandler:^(id<MTLCommandBuffer> scheduled) {
        const uint64_t at=stream_now(),tid=maru_input_display_thread(),identity=submitObject(scheduled);
        pthread_mutex_lock(&submit_lock);
        uint64_t *row=submit_rows[index];
        if (row[S_SCHEDULED_CB]) submit_errors++;
        row[S_SCHEDULED_CB]=at;row[S_SCHEDULED_THREAD]=tid;row[S_SCHEDULED_BUFFER]=identity;
        if (identity!=buffer_id) submit_errors++;
        submitDone();pthread_mutex_unlock(&submit_lock);
    }];
    [buffer addCompletedHandler:^(id<MTLCommandBuffer> completed) {
        const uint64_t at=stream_now(),tid=maru_input_display_thread(),identity=submitObject(completed);
        const uint64_t kernel_start=submitNs(completed.kernelStartTime),kernel_end=submitNs(completed.kernelEndTime);
        const uint64_t gpu_start=submitNs(completed.GPUStartTime),gpu_end=submitNs(completed.GPUEndTime);
        const uint64_t status=(uint64_t)completed.status,error=completed.error!=nil;
        pthread_mutex_lock(&submit_lock);
        uint64_t *row=submit_rows[index];
        if (row[S_COMPLETED_CB]) submit_errors++;
        row[S_COMPLETED_CB]=at;row[S_COMPLETED_THREAD]=tid;row[S_COMPLETED_BUFFER]=identity;
        row[S_KERNEL_START]=kernel_start;row[S_KERNEL_END]=kernel_end;row[S_GPU_START]=gpu_start;row[S_GPU_END]=gpu_end;
        row[S_STATUS]=status;row[S_ERROR]=error;
        if (identity!=buffer_id) submit_errors++;
        submitDone();pthread_mutex_unlock(&submit_lock);
    }];
    [drawable addPresentedHandler:^(id<MTLDrawable> shown) {
        const uint64_t at=stream_now(),tid=maru_input_display_thread(),identity=submitObject(shown),presented=submitNs(shown.presentedTime);
        pthread_mutex_lock(&submit_lock);
        uint64_t *row=submit_rows[index];
        if (row[S_PRESENTED_CB]) submit_errors++;
        row[S_PRESENTED_CB]=at;row[S_PRESENTED_THREAD]=tid;row[S_PRESENTED_DRAWABLE]=identity;row[S_PRESENTED]=presented;
        if (identity!=drawable_id) submit_errors++;
        submitDone();pthread_mutex_unlock(&submit_lock);
    }];
    return index;
}
static void submitReturn(uint64_t index) {
    if (index==UINT64_MAX) return;
    const uint64_t at=stream_now();
    pthread_mutex_lock(&submit_lock);
    if (index>=submit_count || submit_rows[index][S_RETURNED]) submit_errors++;
    else submit_rows[index][S_RETURNED]=at;
    pthread_mutex_unlock(&submit_lock);
}
uint64_t maru_submit_pending(void) {
    pthread_mutex_lock(&submit_lock);const uint64_t n=submit_pending;pthread_mutex_unlock(&submit_lock);return n;
}
void maru_submit_copy(uint64_t *header,uint64_t *rows) {
    pthread_mutex_lock(&submit_lock);
    header[0]=submit_count;header[1]=submit_overflow;header[2]=submit_pending;header[3]=submitEnabled();header[4]=submit_errors;
    memcpy(rows,submit_rows,sizeof(submit_rows));
    pthread_mutex_unlock(&submit_lock);
}
