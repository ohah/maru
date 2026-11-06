// 외부 단일 앱 진단의 main-thread 전용 예산. 제품 저장소/큐 상한이 아니다.
typedef struct { uint64_t owner,last,hz; } TargetBudget;
static TargetBudget target_budgets[16];
static uint64_t target_budget_count,target_budget_errors,target_budget_denied;
static uint64_t target_budget_rows[4096][4],target_budget_row_count;
static int target_enabled(void) { const char *v=getenv("MARU_STREAM_IMMEDIATE_PARSE_FRAME");return v && strcmp(v,"1")==0; }
static TargetBudget *target_budget(uint64_t owner) {
    if (!owner) { target_budget_errors++;return NULL; }
    for (uint64_t i=0;i<target_budget_count;i++) if (target_budgets[i].owner==owner) return &target_budgets[i];
    if (target_budget_count==16) { target_budget_errors++;return NULL; }
    TargetBudget *slot=&target_budgets[target_budget_count++];slot->owner=owner;return slot;
}
static uint64_t target_deadline_at(uint64_t owner,uint64_t hz) {
    TargetBudget *slot=target_budget(owner);
    if (!slot || !hz || hz>1000) { target_budget_errors++;return UINT64_MAX; }
    if (!slot->last) return 0;
    const uint64_t gap=(1000000000ULL+hz-1)/hz;
    if (slot->last>UINT64_MAX-gap) { target_budget_errors++;return UINT64_MAX; }
    return slot->last+gap;
}
static uint32_t target_permit_at(uint64_t owner,uint64_t hz,uint64_t now,int enabled) {
    const uint64_t deadline=target_deadline_at(owner,hz);
    TargetBudget *slot=target_budget(owner);
    const uint32_t allowed=slot && deadline!=UINT64_MAX && (!enabled || !slot->last || now>=deadline);
    if (slot && slot->last && now<slot->last) target_budget_errors++;
    if (allowed) { slot->last=now;slot->hz=hz; } else target_budget_denied++;
    if (target_budget_row_count==4096) target_budget_errors++;
    else {
        uint64_t *row=target_budget_rows[target_budget_row_count++];
        row[0]=owner;row[1]=now;row[2]=hz;row[3]=allowed;
    }
    return allowed;
}
uint32_t maru_target_frame_permit(uint64_t owner,uint64_t hz) { return target_permit_at(owner,hz,stream_now(),target_enabled()); }
uint64_t maru_target_frame_deadline(uint64_t owner,uint64_t hz) { return target_enabled()?target_deadline_at(owner,hz):0; }
void maru_target_frame_stats(uint64_t *out) { out[0]=target_budget_row_count;out[1]=target_budget_denied;out[2]=target_budget_errors;out[3]=target_budget_count; }
void maru_target_frame_copy(uint64_t *out) { memcpy(out,target_budget_rows,sizeof(target_budget_rows)); }
static void (*target_frame_callback)(uint64_t);
void maru_target_frame_register(void (*callback)(uint64_t)) { target_frame_callback=callback; }
void maru_target_frame_notice(uint64_t owner) { if (target_frame_callback) target_frame_callback(owner); }
