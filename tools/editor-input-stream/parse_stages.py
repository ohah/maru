"""외부 진단 사본의 요청 identity로 워커·수락·뷰 설치 시각을 연결한다."""


def worker(source, once):
    source = once(source, '        const allocator = state.options.copy_allocator;', '        streamStage(self.tag, 2, 0);\n        defer streamStage(self.tag, 3, @intFromEnum(self.outcome));\n        const allocator = state.options.copy_allocator;')
    source = once(source, '        state.waiting.push(job);', '        streamStage(tag, 1, 0);\n        state.waiting.push(job);')
    source = once(source, '                if (self.stopping) self.retiring.push(job) else self.completed.push(job);', '                streamStage(job.tag, 4, @intFromEnum(job.outcome));\n                if (self.stopping) self.retiring.push(job) else self.completed.push(job);')
    return source + '''
extern fn maru_parse_stage(stage: u64, owner: u64, slot: u64, generation: u64, revision: u64, serial: u64, aux: u64) void;
pub fn streamStage(tag: request.Request, stage: u64, aux: u64) void {
    maru_parse_stage(stage, @intCast(tag.input.document.owner), @intCast(tag.input.document.slot), tag.input.document.generation, tag.input.revision, tag.serial, aux);
}
'''


def runtime(source, once):
    return once(source, '            entry.current = value;', '            entry.current = value;\n            worker.streamStage(value.tag(), 5, 0);')


def view(source, once):
    source = once(source, '        return true;', '        worker.streamStage(held.tag(), 8, @intFromPtr(target));\n        return true;')
    source = once(source, '    const copied = if (source.tree == null)', '    worker.streamStage(held.tag(), 6, 0);\n    const copied = if (source.tree == null)')
    return once(source, '    return .{ .allocator = allocator, .provider = copied, .result = held };', '    worker.streamStage(held.tag(), 7, 0);\n    return .{ .allocator = allocator, .provider = copied, .result = held };')


def present(source, once):
    # 별도 mutex에는 시각 기록/복사만 있다. 제품 큐나 UI를 기다리지 않는다.
    return source + '''
static pthread_mutex_t parse_stage_lock=PTHREAD_MUTEX_INITIALIZER;
static uint64_t parse_stage_rows[2048][9], parse_stage_count, parse_stage_overflow;
void maru_parse_stage(uint64_t stage,uint64_t owner,uint64_t slot,uint64_t generation,uint64_t revision,uint64_t serial,uint64_t aux) {
    pthread_mutex_lock(&parse_stage_lock);
    if (parse_stage_count==2048) parse_stage_overflow=1;
    else {
        uint64_t tid=0;pthread_threadid_np(NULL,&tid);
        uint64_t *row=parse_stage_rows[parse_stage_count++];
        row[0]=stage;row[1]=stream_now();row[2]=owner;row[3]=slot;row[4]=generation;
        row[5]=revision;row[6]=serial;row[7]=aux;row[8]=tid;
    }
    pthread_mutex_unlock(&parse_stage_lock);
}
void maru_parse_stage_copy(uint64_t *header,uint64_t *out) {
    pthread_mutex_lock(&parse_stage_lock);
    header[0]=parse_stage_count;header[1]=parse_stage_overflow;
    memcpy(out,parse_stage_rows,sizeof(parse_stage_rows));
    pthread_mutex_unlock(&parse_stage_lock);
}
'''


def driver(source, once):
    source = '@_silgen_name("maru_parse_stage_copy") private func parseStageCopy(_ header: UnsafeMutablePointer<UInt64>,_ rows: UnsafeMutablePointer<UInt64>)\n' + source
    return once(source, '        record["initial_tail_sha256"]=', '''        var parseHeader=[UInt64](repeating:0,count:2),parseFlat=[UInt64](repeating:0,count:2048*9)
        parseStageCopy(&parseHeader,&parseFlat)
        record["parse_stage_header"]=parseHeader
        record["parse_stages"]=(0..<min(2048,Int(parseHeader[0]))).map { Array(parseFlat[$0*9..<($0+1)*9]) }
        record["initial_tail_sha256"]=''')
