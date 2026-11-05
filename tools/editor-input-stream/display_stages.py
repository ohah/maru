"""외부 사본에서만 같은 프레임의 tick·그리기·제출·표시 시각을 기록한다."""


def session(source, once):
    source = once(source, '    pub fn tick(self: *AppSession) !FrameSummary {', '    pub fn tick(self: *AppSession) !FrameSummary {\n        const stream_tick_ns = debug_fixtures.postTickStart();\n        defer debug_fixtures.postTickEnd(stream_tick_ns);')
    return once(source, '                    debug_fixtures.latencyStamp(self);', '                    debug_fixtures.latencyStamp(self);\n                    debug_fixtures.postFrame(stream_tick_ns);')


def witness(source):
    return source + '''
extern fn maru_post_now() u64;
extern fn maru_post_tick_end(tick: u64) void;
extern fn maru_post_frame(tick: u64, stamp: [*]const u64) void;
pub fn postTickStart() u64 { return maru_post_now(); }
pub fn postTickEnd(tick: u64) void { maru_post_tick_end(tick); }
pub fn postFrame(tick: u64) void { maru_post_frame(tick, &latency_frame); }
'''


def swift(source, once):
    source = once(source, '    private func drawMetalFrame(inspectorOnly: Bool = false) {', '    private func drawMetalFrame(inspectorOnly: Bool = false) {\n        let postSwiftNs = UInt64(CACurrentMediaTime()*1e9)')
    return once(source, '        let drew = maru_metal_renderer_draw(', '        postSwiftStart(frame.generation,postSwiftNs)\n        let drew = maru_metal_renderer_draw(')


def renderer(source, once):
    source = once(source, '    // W3c: 이 draw 가 commit 하지 않고 끝나면', '    postRendererEntry();\n    // W3c: 이 draw 가 commit 하지 않고 끝나면')
    source = once(source, '    if (!enabled) return;\n    [drawable addPresentedHandler:', '    if (!enabled) return;\n    postArm(drawable,gen,prefix,ready);\n    [drawable addPresentedHandler:')
    return once(source, '    [command_buffer commit];\n    return !overlay_content_dropped;', '    postCommit();\n    [command_buffer commit];\n    return !overlay_content_dropped;')


def driver(source, once):
    source = '''@_silgen_name("maru_post_swift") private func postSwiftStart(_ gen: UInt64,_ start: UInt64)
@_silgen_name("maru_post_copy") private func postCopy(_ header: UnsafeMutablePointer<UInt64>,_ frames: UnsafeMutablePointer<UInt64>,_ draws: UnsafeMutablePointer<UInt64>)
@_silgen_name("maru_post_pending") private func postPending() -> UInt64
''' + source
    source = once(source, 'header[4]>0 && header[8]==0 {', 'header[4]>0 && header[8]==0 && postPending()==0 {')
    return once(source, '        record["initial_tail_sha256"]=', '''        var postHeader=[UInt64](repeating:0,count:4),postFrames=[UInt64](repeating:0,count:2048*9),postDraws=[UInt64](repeating:0,count:2048*9)
        postCopy(&postHeader,&postFrames,&postDraws)
        record["display_stage_header"]=postHeader
        record["display_frames"]=(0..<min(2048,Int(postHeader[0]))).map { Array(postFrames[$0*9..<($0+1)*9]) }
        record["display_draws"]=(0..<min(2048,Int(postHeader[1]))).map { Array(postDraws[$0*9..<($0+1)*9]) }
        record["initial_tail_sha256"]=''')


def present(source):
    # 각 draw는 자기 row 번호를 callback에 값으로 캡처한다. 전역 최신 세대로 재귀속하지 않는다.
    return 'static void postArm(id<CAMetalDrawable> drawable,uint64_t gen,uint64_t prefix,uint64_t ready);\n' + source + '''
static pthread_mutex_t post_lock=PTHREAD_MUTEX_INITIALIZER;
static uint64_t post_frames[2048][9],post_draws[2048][9];
static uint64_t post_frame_count,post_draw_count,post_overflow,post_pending;
static uint64_t post_swift_gen,post_swift_ns,post_renderer_ns,post_active_draw;
uint64_t maru_post_now(void) { return stream_now(); }
void maru_post_frame(uint64_t tick,const uint64_t *stamp) {
    pthread_mutex_lock(&post_lock);
    if (post_frame_count==2048) post_overflow=1;
    else {
        uint64_t *r=post_frames[post_frame_count++],tid=0;pthread_threadid_np(NULL,&tid);
        r[0]=stamp[0];r[1]=stamp[1];r[2]=stamp[7];r[3]=stamp[3];r[4]=stamp[6];
        r[5]=tick;r[6]=stream_now();r[8]=tid;
    }
    pthread_mutex_unlock(&post_lock);
}
void maru_post_tick_end(uint64_t tick) {
    pthread_mutex_lock(&post_lock);
    for (uint64_t i=0;i<post_frame_count;i++) if (post_frames[i][5]==tick) post_frames[i][7]=stream_now();
    pthread_mutex_unlock(&post_lock);
}
void maru_post_swift(uint64_t gen,uint64_t start) { post_swift_gen=gen;post_swift_ns=start; }
static void postRendererEntry(void) { post_renderer_ns=stream_now();post_active_draw=0; }
static void postArm(id<CAMetalDrawable> drawable,uint64_t gen,uint64_t prefix,uint64_t ready) {
    pthread_mutex_lock(&post_lock);
    if (post_draw_count==2048) { post_overflow=1;pthread_mutex_unlock(&post_lock);return; }
    const uint64_t index=post_draw_count++;
    uint64_t *r=post_draws[index],tid=0;pthread_threadid_np(NULL,&tid);
    r[0]=gen;r[1]=prefix;r[2]=ready;r[3]=post_swift_gen==gen?post_swift_ns:0;
    r[4]=post_renderer_ns;r[5]=stream_now();r[8]=tid;
    post_active_draw=index+1;post_pending++;
    pthread_mutex_unlock(&post_lock);
    [drawable addPresentedHandler:^(id<MTLDrawable> shown) {
        pthread_mutex_lock(&post_lock);
        post_draws[index][7]=(uint64_t)(shown.presentedTime*1e9);
        if (post_pending) post_pending--;else post_overflow=1;
        pthread_mutex_unlock(&post_lock);
    }];
}
static void postCommit(void) {
    pthread_mutex_lock(&post_lock);
    if (post_active_draw) {
        if (post_draws[post_active_draw-1][6]) post_overflow=1;
        else post_draws[post_active_draw-1][6]=stream_now();
    }
    pthread_mutex_unlock(&post_lock);
}
uint64_t maru_post_pending(void) { pthread_mutex_lock(&post_lock);uint64_t n=post_pending;pthread_mutex_unlock(&post_lock);return n; }
void maru_post_copy(uint64_t *header,uint64_t *frames,uint64_t *draws) {
    pthread_mutex_lock(&post_lock);
    header[0]=post_frame_count;header[1]=post_draw_count;header[2]=post_overflow;header[3]=post_pending;
    memcpy(frames,post_frames,sizeof(post_frames));memcpy(draws,post_draws,sizeof(post_draws));
    pthread_mutex_unlock(&post_lock);
}
'''


def analyze(app, meta, installed, main_thread, require):
    header = app.get('display_stage_header')
    frames = app.get('display_frames')
    draws = app.get('display_draws')
    require(type(header) is list and len(header) == 4 and all(type(n) is int and 0 <= n < 2**64 for n in header), 'display header shape')
    require(type(frames) is list and type(draws) is list and 0 < len(frames) <= 2048 and 0 < len(draws) <= 2048 and header == [len(frames),len(draws),0,0], 'display population/overflow/pending')
    require(all(type(row) is list and len(row) == 9 and all(type(n) is int and 0 <= n < 2**64 for n in row) for row in frames+draws), 'display row shape')
    shown, generation, prefix = app['syntax_presentations'][-1]
    found = [row for row in frames if row[0] == generation]
    require(len(found) == 1, 'unique producing frame')
    frame = found[0]
    found = [row for row in draws if row[0] == generation and row[7] == shown]
    require(len(found) == 1, 'unique presented drawable')
    draw = found[0]
    require(frame[1] == app['baseline'][1]+meta['count'] and frame[2] == prefix == meta['count'], 'display revision/prefix')
    require(frame[3] == draw[2] == 1 and frame[4]&1 == 1 and draw[1] == prefix, 'display readiness')
    require(frame[8] == draw[8] == main_thread and main_thread > 0, 'display main thread')
    tick, prepared, ended = frame[5:8]
    swift, renderer, armed, commit = draw[3:7]
    require(all(n > 0 for n in (installed,tick,prepared,ended,swift,renderer,armed,commit,shown)), 'display missing time')
    require(tick <= prepared <= ended <= swift <= renderer <= armed <= commit <= shown and installed <= prepared, 'display time order')
    # 설치가 tick 내부에서 이뤄지면 이미 시작한 tick까지의 대기는 0이다.
    points = [installed,max(installed,tick),prepared,ended,swift,renderer,armed,commit,shown]
    names = ('wait_for_tick','frame_prepare','tick_finalize','wait_for_swift','swift_prepare','renderer_prepare','arm_to_commit','commit_to_present')
    result = {name:(end-start)/1e6 for name,start,end in zip(names,points,points[1:])}
    result['installed_to_present'] = (shown-installed)/1e6
    require(abs(sum(result[name] for name in names)-result['installed_to_present']) < 1e-6, 'display sum')
    return dict(generation=generation, tick_in_progress_at_install=tick < installed, elapsed_ms=result)
