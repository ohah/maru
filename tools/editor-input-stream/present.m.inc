// 고정 크기는 측정 입력의 서로 다른 ASCII 36개에만 적용한다. 제품 저장소 상한이 아니다.
#include <pthread.h>
static pthread_mutex_t stream_lock=PTHREAD_MUTEX_INITIALIZER;
static uint64_t stream_rows[36][12], stream_header[9], latency_mark[8];
static uint64_t stream_base_len, stream_views, stream_suppressed;
static const uint64_t stream_codes[]={@STREAM_CODES@};
static uint64_t stream_now(void) { return (uint64_t)(CACurrentMediaTime()*1e9); }
void maru_stream_begin(uint64_t count, uint64_t bytes, uint64_t views, uint64_t mode) {
    pthread_mutex_lock(&stream_lock);
    memset(stream_rows,0,sizeof(stream_rows));memset(stream_header,0,sizeof(stream_header));
    stream_suppressed=0;
    if (!count || count>36) { stream_header[0]=128;pthread_mutex_unlock(&stream_lock);return; }
    stream_header[1]=count;stream_header[7]=mode;stream_base_len=bytes;stream_views=views;
    for (uint64_t i=0;i<count && i<36;i++) stream_rows[i][0]=i+1;
    pthread_mutex_unlock(&stream_lock);
}
void maru_stream_keydown(uint64_t token,uint64_t code,uint64_t modifiers,double timestamp) {
    pthread_mutex_lock(&stream_lock);
    if (!stream_header[1]) { pthread_mutex_unlock(&stream_lock);return; }
    const uint64_t seq=token&255;
    if ((token&~(uint64_t)255)!=@STREAM_MAGIC@ULL || !seq || seq>stream_header[1]) stream_header[0]|=1;
    else {
        uint64_t *r=stream_rows[seq-1];
        if (seq!=stream_header[2]+1) stream_header[0]|=2;
        if (r[11]) stream_header[0]|=4;
        if (code!=stream_codes[seq-1] || modifiers) stream_header[0]|=8;
        r[1]=token;r[2]=(uint64_t)(timestamp*1e9);r[3]=stream_now();r[4]=code;r[5]=modifiers;r[11]++;
        stream_header[2]++;
    }
    pthread_mutex_unlock(&stream_lock);
}
void maru_latency_mark_frame(const uint64_t *v) { memcpy(latency_mark,v,sizeof(latency_mark)); }
void maru_stream_copy(uint64_t *header,uint64_t *rows) {
    pthread_mutex_lock(&stream_lock);
    memcpy(header,stream_header,sizeof(stream_header));memcpy(rows,stream_rows,sizeof(stream_rows));
    pthread_mutex_unlock(&stream_lock);
}
uint64_t maru_stream_drop_count(void) {
    pthread_mutex_lock(&stream_lock);uint64_t count=stream_suppressed;pthread_mutex_unlock(&stream_lock);return count;
}
static void latency_arm(id<CAMetalDrawable> drawable) {
    const uint64_t gen=latency_mark[0], prefix=latency_mark[7], bytes=latency_mark[5], views=latency_mark[4];
    const uint64_t ready=latency_mark[3], full=(latency_mark[6]&1), mode=(latency_mark[6]>>1);
    pthread_mutex_lock(&stream_lock);
    const uint64_t total=stream_header[1];
    if (!total || !gen || !prefix) { pthread_mutex_unlock(&stream_lock);return; }
    if (prefix>total || bytes!=stream_base_len+prefix) stream_header[0]|=16;
    if (views!=stream_views || mode!=stream_header[7] || latency_mark[2]) stream_header[0]|=64;
    const bool valid=!stream_header[0];
    const bool enabled=valid && getenv("MARU_STREAM_DROP_PRESENT")==NULL;
    if (valid && !enabled) stream_suppressed++;
    if (enabled) stream_header[8]++;
    pthread_mutex_unlock(&stream_lock);
    if (!enabled) return;
    [drawable addPresentedHandler:^(id<MTLDrawable> shown) {
        const uint64_t at=(uint64_t)(shown.presentedTime*1e9);
        pthread_mutex_lock(&stream_lock);
        if (stream_header[8]) stream_header[8]--; else stream_header[0]|=256;
        if (!at) { pthread_mutex_unlock(&stream_lock);return; }
        for (uint64_t i=0;i<prefix;i++) {
            uint64_t *r=stream_rows[i];
            if (!r[3] || at<r[3]) { stream_header[0]|=32;continue; }
            if (!r[6] || at<r[6]) {
                if (!r[6]) stream_header[3]++;
                r[6]=at;r[7]=gen;r[8]=prefix;r[9]=ready;r[10]=ready && full;
            }
        }
        if (prefix>stream_header[6]) stream_header[6]=prefix;
        if (prefix==total && ready && full && (!stream_header[4] || at<stream_header[4])) {
            stream_header[4]=at;stream_header[5]=gen;
        }
        pthread_mutex_unlock(&stream_lock);
    }];
}
