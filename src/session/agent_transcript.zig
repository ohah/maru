//! L2 session core — 에이전트(claude·codex) 세션 JSONL 트랜스크립트의 순수 상태 판정. 터미널에서 도는
//! 에이전트가 디스크에 남기는 세션 트랜스크립트의 *끝부분(tail)* 바이트만 받아 running/idle/interrupted/unknown과
//! 마지막 답변 미리보기를 계산한다. 파일 I/O(세션 찾기·tail read·디렉터리 나열)는 platform(L4)이 하고, 여기는
//! 바이트→상태의 순수 함수라 라이브 에이전트 없이 헤드리스로 단위 테스트한다(docs/agent-session.md
//! "아키텍처/레이어" — session core). OS·렌더 무관, std + 중립 width 유틸(순수 Unicode)만 의존 —
//! tests/boundary/imports.zig가 OS 타입 누수를 막는다. 에이전트별 스키마 어댑터(claude/codex)가 같은 `AgentState`/`Status` 타입을 공유하고, 어느
//! 어댑터를 부를지는 platform이 `agent_kind`로 디스패치한다(PR3).
//!
//!   - claude: `~/.claude/projects/<enc-cwd>/<session-uuid>.jsonl`. 완료 = 마지막 *대화* 엔트리가 turn-종료
//!     assistant(stop_reason). cwd 인코딩으로 디렉터리를 찾는다.
//!   - codex:  `~/.codex/sessions/<YYYY>/<MM>/<DD>/rollout-<ts>-<uuid>.jsonl`. 완료 = 마지막 turn 엔트리가
//!     `event_msg`/`task_complete`(명시적). 날짜 분할이라 cwd로 디렉터리를 못 찾아 첫 줄 session_meta.cwd로
//!     매핑한다.
//!
//! 베이스(document-basis-and-decision): claude 포맷은 공식 문서(code.claude.com/docs, statusline 훅의
//! transcript_path), codex 포맷은 오픈소스(openai/codex, Apache-2.0)와 실 세션 파일을 베이스로 한다. 완료를
//! mtime이 아니라 "마지막 turn 엔트리의 완료 여부"로 본 근거는 느린 API(응답까지 수십 초~분)에도 false idle이
//! 없게 하기 위함이다 — "턴 미완료"는 파일이 안 써져도 성립하는 구조적 사실이다(docs/agent-session.md "상태
//! 모델"). 데이터 포맷(JSONL)은 저작권 대상이 아니며 Maru 자체 파서로 읽는다(clean-room). 참고 OSS 파서는
//! *포맷 이해*용으로만 보고 코드는 복사하지 않는다.

const std = @import("std");

/// transcript 코어가 판정하는 상태. `none`(포그라운드가 에이전트가 아님)은 platform이 `agent_kind`로 정하므로
/// 여기엔 없다 — 이 레이어는 "트랜스크립트가 말하는" 세 상태만 안다. platform이 `agent_kind == .none`이면
/// 이 판정을 무시하고 none으로 덮는다(docs/agent-session.md "상태 모델": running/idle/interrupted는 포그라운드 AND로 묶임).
pub const AgentState = enum {
    /// tail에 완전한 *대화* 엔트리가 없음(메타 엔트리뿐이거나, 초대형 단일 줄이라 tail 창 안에 완전한 줄이
    /// 없음). platform이 더 큰 tail로 재시도하거나 보수적으로 다룬다(이전 상태 유지 등).
    unknown,
    /// 마지막 대화 엔트리가 미완료 — user 제출 후 응답 대기 / assistant가 tool_use 중 / tool_result 후 다음
    /// 응답 대기. 느린 API에도 이 판정은 false idle이 없다("턴 미완료"는 구조적 사실).
    running,
    /// 마지막 대화 엔트리가 완료된 assistant 턴(stop_reason이 턴-종료 사유).
    idle,
    /// 마지막 대화 엔트리가 **사용자 인터럽트**(ESC) — 턴이 완료된 게 아니라 사용자가 끊었다.
    /// 에이전트는 프롬프트로 돌아와 대기하므로 **진행 중이 아니다**(스피너·탭 ● 는 꺼져야 한다). 다만 **완료도
    /// 아니므로 "에이전트 완료" 알림은 쏘지 않는다** — 사용자가 직접 ESC를 눌러 이미 키보드 앞에 있다(사용자 결정).
    /// 이 상태가 없으면 인터럽트 엔트리가 `user` 타입이라 running으로 접혀(claude) / else 분기라 running으로 접혀
    /// (codex) **스피너가 영영 안 풀린다** — 게다가 그 뒤 파일 변화가 없어 mtime 게이트가 재파싱조차 막는다.
    interrupted,
};

/// 상태 + (idle일 때) 마지막 답변 미리보기(여러 줄 평탄화 — copyPreviewFlattened).
pub const Status = struct {
    state: AgentState,
    /// idle일 때 마지막 답변을 **여러 줄→한 줄로 평탄화**(개행·탭·CR·연속 공백 → 공백 1칸)해 호출자 `answer_buf`에
    /// UTF-8 경계로 복사한 슬라이스. running/unknown이거나 답변 텍스트가 없으면 길이 0. `answer_buf`를 가리키므로 buf
    /// 수명만큼 유효하다. 알림 본문·사이드바 상태줄이 이 미리보기를 공유한다(copyPreviewFlattened 단일 출처).
    answer: []const u8,
};

/// claude 세션 JSONL의 tail 바이트에서 상태·마지막 답변을 계산한다(순수). `tail`은 파일 끝 N KB를 seek해 읽은
/// 바이트라 보통 첫 줄이 잘려 있다 — JSON 파싱에 실패한 줄은 건너뛰므로(잘린 선두 줄·불량 줄 포함) "어디서부터
/// 완전한 줄인가"를 알려주는 별도 플래그가 필요 없다. `scratch`는 줄 파싱용 임시 할당(각 줄 파싱 직후 해제).
/// `answer_buf`엔 idle일 때 마지막 답변의 평탄화 미리보기(copyPreviewFlattened)를 복사한다.
///
/// 판정(줄을 순서대로 fold, 마지막 *대화* 엔트리의 mark가 최종):
///   - `type=="assistant"`: `message.stop_reason`가 턴-종료(end_turn/stop_sequence/max_tokens)면 **idle** +
///     첫 `text` 블록 첫 줄을 answer로. tool_use/null/모르는 사유면 **running**(아래 isTerminalStop 근거).
///   - `type=="user"` && `isMeta!=true`: **running**(새 프롬프트거나 tool_result 후 응답 대기).
///   - 그 밖의 타입(mode/system/attachment/pr-link/file-history-snapshot/queue-operation/…): 메타라 무시.
/// 대화 엔트리를 하나도 못 보면 **unknown**.
///
/// 핵심(docs/agent-session.md, 실측): 파일의 *물리적 마지막 줄*은 대화가 아니라 메타(mode/permission-mode/
/// pr-link)인 경우가 잦다. 그래서 "마지막 줄"이 아니라 "마지막 *대화* 엔트리"를 본다 — 메타 꼬리를 건너뛴다.
pub fn parseClaudeTail(scratch: std.mem.Allocator, tail: []const u8, answer_buf: []u8) Status {
    var state: AgentState = .unknown;
    var answer_len: usize = 0;
    // **인터럽트 latch**: 인터럽트 마커를 본 뒤 따라오는 *꼬리* 엔트리가 상태를 도로 뒤집지 못하게 한다.
    // 실측(이 머신 트랜스크립트): ESC 직후 claude가 `assistant` + `stop_reason:"stop_sequence"` +
    // "No response requested." 를 붙이는 판이 있다(81건 중 5건). 그걸 그대로 접으면 **idle("✓ 완료")**이 되고
    // **가짜 "에이전트 완료" 알림**까지 뜬다 — 사용자는 끊었는데 완료됐다고 통보받는다. latch는 **새 프롬프트
    // 제출**(일반 user 엔트리)이 오면 풀린다 — 그때가 진짜 재개다.
    var interrupt_latch = false;

    var lines = std.mem.splitScalar(u8, tail, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;

        // 잘린 선두 줄·불량 줄은 파싱 실패 → 그대로 skip(헛방어 없이 한 곳에서 처리).
        const parsed = std.json.parseFromSlice(std.json.Value, scratch, line, .{}) catch continue;
        defer parsed.deinit();

        const obj = asObject(parsed.value) orelse continue;
        const entry_type = asString(obj.get("type") orelse continue) orelse continue;

        if (std.mem.eql(u8, entry_type, "assistant")) {
            if (interrupt_latch) continue; // 인터럽트 꼬리 응답 — 상태를 안 뒤집는다(위 latch 주석)
            const msg = asObject(obj.get("message") orelse continue) orelse continue;
            if (isTerminalStop(msg.get("stop_reason"))) {
                state = .idle;
                // 답변은 Value(arena) 해제 전에 buf로 복사한다 — parsed.deinit() 전에 끝낸다.
                answer_len = copyAnswerPreview(answer_buf, msg.get("content"));
            } else {
                state = .running;
                answer_len = 0;
            }
        } else if (std.mem.eql(u8, entry_type, "user")) {
            // isMeta=true user는 시스템 주입(local-command caveat·hook 등)이라 대화가 아니다 — 무시해야
            // 완료된 턴 뒤에 caveat 한 줄이 붙어도 false running으로 뒤집히지 않는다(실측 함정).
            if (isMetaTrue(obj.get("isMeta"))) continue;
            // **사용자 인터럽트(ESC)** — 일반 user(=새 프롬프트)로 보면 running으로 접혀 스피너가 영영 안 풀린다
            // (그 뒤 파일이 안 자라 mtime 게이트가 재파싱도 막는다). 판별은 isClaudeInterrupt가 단일 출처다.
            if (isClaudeInterrupt(obj)) {
                state = .interrupted;
                answer_len = 0;
                interrupt_latch = true;
                continue;
            }
            state = .running; // 새 프롬프트 제출 = 진짜 재개 → latch 해제
            answer_len = 0;
            interrupt_latch = false;
        }
        // 그 밖의 타입은 메타 — 상태 불변(마지막 대화 엔트리만 의미를 갖는다).
    }

    return .{ .state = state, .answer = answer_buf[0..answer_len] };
}

/// claude가 인터럽트 마커 본문으로 쓰는 문구(실측 전수). 이 **정확한 문자열**만 마커로 본다 — prefix 매칭은
/// 사용자가 그 문구로 *시작하는* 프롬프트를 내면(이 기능을 디버깅하며 로그를 인용하는 개발자 등) 그 턴 전체가
/// false interrupted로 latch돼 **스피너가 아예 안 켜지고 완료 알림도 안 뜬다**(이 수정의 정반대 실패 — code-review).
const claude_interrupt_texts = [_][]const u8{
    "[Request interrupted by user]",
    "[Request interrupted by user for tool use]",
};

/// 이 `user` 엔트리가 **사용자 인터럽트(ESC)** 마커인가. 두 신호를 **OR**로 본다:
///   ① top-level `interruptedMessageId` 필드(구조적 판별자 — 있으면 확실).
///   ② `message.content` **블록 배열**의 `text` 블록이 위 마커 문구와 **정확히 일치**(필드가 **없는** 판 대비).
/// ②가 필요한 이유(실측 — 이 머신 ~/.claude/projects 전수): 메인체인 인터럽트 엔트리 109건 중 **12건(11%)이
/// `interruptedMessageId` 없이** 본문만 남긴다(같은 claude 버전에서도 섞여 나와 버전 게이트로도 못 가른다).
/// 필드만 보면 그 9회 중 1회꼴로 스피너가 그대로 고착된다 — 수정이 무효화되는 구멍.
/// ②의 범위를 좁게 잡은 근거(같은 실측): 인터럽트 엔트리의 본문은 **109건 전부 블록 배열**이고 문구는 위 두 가지가
/// 전부다(92 + 17). 반면 일반 프롬프트의 content는 문자열이다 — 그래서 문자열 content는 아예 안 보고, 블록 텍스트도
/// **정확 일치**만 본다(오탐 표면 0). 새 문구 변형이 생기면 그건 ①(필드)이 받는다.
fn isClaudeInterrupt(obj: std.json.ObjectMap) bool {
    if (obj.get("interruptedMessageId") != null) return true;
    const msg = asObject(obj.get("message") orelse return false) orelse return false;
    const content = msg.get("content") orelse return false;
    const arr = switch (content) {
        .array => |a| a,
        else => return false, // 문자열 content = 일반 프롬프트(실측: 인터럽트는 전부 블록 배열)
    };
    for (arr.items) |item| {
        const o = asObject(item) orelse continue;
        const t = asString(o.get("type") orelse continue) orelse continue;
        if (!std.mem.eql(u8, t, "text")) continue;
        const txt = asString(o.get("text") orelse continue) orelse continue;
        for (claude_interrupt_texts) |marker| {
            if (std.mem.eql(u8, txt, marker)) return true;
        }
    }
    return false;
}

/// stop_reason이 "턴 종료"(idle) 사유인지. tool_use/null/누락/모르는 값은 false(running)로 본다 — 모르는 값을
/// idle로 보면 느린 API 중 false idle이 생기므로, 턴-종료 사유를 **명시 allowlist** 하고 나머지는 running으로
/// 보수 판정한다. 값 근거(베이스): Anthropic Messages API의 stop_reason(end_turn / stop_sequence / max_tokens /
/// tool_use). 실측 분포는 tool_use가 다수(도구 호출마다)이고 end_turn은 턴 종료에만 — 그래서 tool_use를
/// 명시적으로 running으로 둔다.
fn isTerminalStop(sr: ?std.json.Value) bool {
    const s = asString(sr orelse return false) orelse return false; // null/누락 → running
    return std.mem.eql(u8, s, "end_turn") or
        std.mem.eql(u8, s, "stop_sequence") or
        std.mem.eql(u8, s, "max_tokens");
}

/// `isMeta` 필드가 boolean true인지(누락/다른 타입은 false).
fn isMetaTrue(v: ?std.json.Value) bool {
    return switch (v orelse return false) {
        .bool => |b| b,
        else => false,
    };
}

/// assistant `content` 배열에서 첫 `text` 블록을 `dst`에 평탄화 미리보기로(여러 줄→한 줄, copyPreviewFlattened)
/// 복사하고 쓴 바이트 수를 반환한다. content가 배열이 아니거나 text 블록이 없으면 0(thinking/tool_use만 있는 턴 등).
fn copyAnswerPreview(dst: []u8, content: ?std.json.Value) usize {
    const arr = switch (content orelse return 0) {
        .array => |a| a,
        else => return 0,
    };
    for (arr.items) |block| {
        const bo = asObject(block) orelse continue;
        const bt = asString(bo.get("type") orelse continue) orelse continue;
        if (!std.mem.eql(u8, bt, "text")) continue;
        const txt = asString(bo.get("text") orelse return 0) orelse return 0;
        return copyPreviewFlattened(dst, txt);
    }
    return 0;
}

/// `src`를 `dst`에 미리보기로 복사한다 — **첫 줄에 한정하지 않고 여러 줄을 한 줄로 평탄화**한다(개행·탭·CR·연속
/// 공백 → 공백 1칸, 선두/말미 공백 제거). 알림 본문이 답변 첫 줄만이 아니라 더 많이 보이게 하기 위함이다(사용자
/// 요청). 사이드바 상태줄은 같은 문자열을 **카드 폭으로 다시 말줄임**하므로(width 기준) 평탄화해도 한 줄로 보인다
/// — 둘이 같은 미리보기를 공유한다(단일 출처). `dst`를 넘치면 UTF-8 코드포인트 경계까지만 복사한다(continuation
/// 바이트 0x80~0xBF 중간에서 안 끊음 — 깨진 글자 방지). 쓴 바이트 수를 반환.
fn copyPreviewFlattened(dst: []u8, src: []const u8) usize {
    var n: usize = 0;
    var pending_space = false; // 공백 run을 만남(다음 비공백 앞에 공백 1칸을 쓴다 — 선두 공백은 n==0이라 무시)
    var i: usize = 0;
    while (i < src.len) {
        const cp_len = std.unicode.utf8ByteSequenceLength(src[i]) catch 1;
        const end = @min(i + cp_len, src.len);
        const is_ws = cp_len == 1 and (src[i] == ' ' or src[i] == '\t' or src[i] == '\n' or src[i] == '\r');
        if (is_ws) {
            if (n > 0) pending_space = true; // 선두 공백은 무시
            i = end;
            continue;
        }
        if (pending_space) { // 비공백 앞에서만 공백 1칸 flush
            if (n + 1 > dst.len) break;
            dst[n] = ' ';
            n += 1;
            pending_space = false;
        }
        const cplen = end - i;
        if (n + cplen > dst.len) break; // 코드포인트가 통째로 안 들어가면 경계에서 멈춤(UTF-8 안 깨짐)
        @memcpy(dst[n .. n + cplen], src[i..end]);
        n += cplen;
        i = end;
    }
    // 말미 공백 제거: 위에서 pending_space를 flush한 직후 다음 코드포인트가 dst를 넘쳐 break하면 끝에 공백 1칸이
    // 남는다(버퍼 cap이 단어 경계에 딱 떨어질 때). 알림 본문 끝의 군더더기 공백을 없앤다.
    while (n > 0 and dst[n - 1] == ' ') n -= 1;
    return n;
}

// ── codex 어댑터 ────────────────────────────────────────────────────────────────────
// 베이스: openai/codex(Apache-2.0) rollout 포맷 + 실 세션 파일 검증. claude와 달리 완료가 **명시적**이라
// (event_msg/task_complete) 추론이 필요 없다.

/// codex 세션 rollout JSONL의 tail 바이트에서 상태·마지막 답변을 계산한다(순수). claude와 같은 tail 규약
/// (파싱 실패한 줄 skip). 줄을 순서대로 fold, 마지막 *turn* 엔트리의 mark가 최종:
///   - `event_msg`/`task_complete`: **idle** + payload.last_agent_message 첫 줄을 answer로(최종 답변이 이
///     엔트리에 직접 담긴다 — claude처럼 content 블록을 뒤질 필요 없음).
///   - `event_msg`/`token_count`: 토큰 회계라 **무시**(턴 내내 자주 찍히고 task_complete 뒤에도 올 수 있어
///     상태를 바꾸면 안 된다).
///   - 그 밖의 `event_msg`(user_message/agent_message/task_started/patch_apply_*/…)와 모든 `response_item`
///     (message/reasoning/function_call/function_call_output/…): 턴 진행 중이므로 **running**.
///   - `session_meta`/`turn_context`/모르는 타입: 메타라 무시.
/// turn 엔트리를 하나도 못 보면 **unknown**.
///
/// 근거(docs/agent-session.md): codex 완료는 `event_msg`+`task_complete`로 명시적이다. token_count를 무시하지
/// 않으면 task_complete 뒤 회계 엔트리에 false running이 될 수 있어 명시적으로 거른다(실측: 한 턴에 token_count
/// 19건). 마지막 turn 엔트리만 의미를 가지므로 메타는 건너뛴다.
pub fn parseCodexTail(scratch: std.mem.Allocator, tail: []const u8, answer_buf: []u8) Status {
    var state: AgentState = .unknown;
    var answer_len: usize = 0;
    // 인터럽트 latch — claude 파서와 같은 이유(아래 turn_aborted 분기 주석). 새 턴(user_message/task_started)이
    // 오거나 턴이 완료(task_complete)되면 풀린다.
    var interrupt_latch = false;

    var lines = std.mem.splitScalar(u8, tail, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;

        const parsed = std.json.parseFromSlice(std.json.Value, scratch, line, .{}) catch continue;
        defer parsed.deinit();

        const obj = asObject(parsed.value) orelse continue;
        const entry_type = asString(obj.get("type") orelse continue) orelse continue;
        const payload = if (obj.get("payload")) |pv| (asObject(pv) orelse continue) else continue;
        const payload_type: ?[]const u8 = if (payload.get("type")) |tv| asString(tv) else null;

        if (std.mem.eql(u8, entry_type, "event_msg")) {
            const pt = payload_type orelse continue;
            if (std.mem.eql(u8, pt, "task_complete")) {
                // **latch를 존중한다**: 중단된 턴 뒤에 붙는 마무리 이벤트를 완료로 접으면, 사용자가 직접 끊은 턴이
                // idle이 되고 알림 게이트((running|interrupted)→idle)가 **가짜 "에이전트 완료"**를 쏜다 —
                // 본문은 중단된 턴의 부분 답변이다(claude 쪽 latch가 막는 것과 같은 실패, code-review).
                // 진짜 재개는 아래 user_message/task_started가 latch를 풀고 나서 온다.
                if (interrupt_latch) continue;
                state = .idle;
                // 최종 답변이 task_complete 엔트리에 직접 담긴다 — Value 해제 전에 buf로 복사.
                answer_len = copyJsonStringPreview(answer_buf, payload.get("last_agent_message"));
            } else if (std.mem.eql(u8, pt, "turn_aborted")) {
                // **중단된 턴** — codex는 ESC에 `turn_aborted`를 남긴다(실측 36건 전부 `reason:"interrupted"`).
                // `reason`은 **보지 않는다**: 다른 사유(리뷰 종료·예산 초과 등)의 abort도 "완료가 아니고 진행 중도
                // 아니다"라는 점은 같아, 같은 상태로 접는 게 안전하다(사유를 가려 running으로 흘리면 그 경우에
                // 스피너가 영구 고착된다 — 이 수정이 없애려는 실패). 상태줄 문구도 "· 중단됨"으로 사유 중립적이다.
                state = .interrupted;
                answer_len = 0;
                interrupt_latch = true;
            } else if (std.mem.eql(u8, pt, "token_count")) {
                // 토큰 회계 — 상태 불변(무시).
            } else if (std.mem.eql(u8, pt, "user_message") or std.mem.eql(u8, pt, "task_started")) {
                state = .running; // **새 턴 시작** = 진짜 재개 → latch 해제
                answer_len = 0;
                interrupt_latch = false;
            } else {
                // 그 밖의 진행 신호(agent_message/patch_apply_*/exec_command_* 등).
                // **인터럽트 뒤 꼬리 이벤트는 상태를 안 뒤집는다**: 실측 rollout에서 `turn_aborted` **다음 줄**에
                // 중단된 명령의 `exec_command_end`가 붙는다(ESC로 끊은 `gh pr checks --watch` 등 — 34건 중 3건).
                // 그걸 running으로 접으면 codex 인터럽트 수정이 통째로 무효가 된다(파일이 더 안 자라 mtime
                // 게이트가 재파싱도 막는다). 재개는 위 user_message/task_started가 명시적으로 푼다.
                if (interrupt_latch) continue;
                state = .running;
                answer_len = 0;
            }
        } else if (std.mem.eql(u8, entry_type, "response_item")) {
            if (interrupt_latch) continue; // 인터럽트 꼬리(중단된 도구 호출의 잔여 출력 등) — 상태 불변
            state = .running; // 모델 출력/도구 호출 — 턴 진행 중.
            answer_len = 0;
        }
        // session_meta/turn_context/모르는 타입은 메타 — 상태 불변.
    }

    return .{ .state = state, .answer = answer_buf[0..answer_len] };
}

/// codex rollout 첫 줄(`session_meta`)의 `payload.<field>` 문자열을 `out`으로 복사해 돌려준다. session_meta가
/// 아니거나 필드가 없거나 버퍼가 작으면 null. parseCodexId의 구현(순수 — 줄 파싱만).
fn parseCodexMetaField(scratch: std.mem.Allocator, first_line: []const u8, field: []const u8, out: []u8) ?[]const u8 {
    const line = std.mem.trim(u8, first_line, " \t\r\n");
    const parsed = std.json.parseFromSlice(std.json.Value, scratch, line, .{}) catch return null;
    defer parsed.deinit();

    const obj = asObject(parsed.value) orelse return null;
    const entry_type = asString(obj.get("type") orelse return null) orelse return null;
    if (!std.mem.eql(u8, entry_type, "session_meta")) return null;
    const payload = asObject(obj.get("payload") orelse return null) orelse return null;
    const val = asString(payload.get(field) orelse return null) orelse return null;

    if (val.len > out.len) return null;
    @memcpy(out[0..val.len], val);
    return out[0..val.len];
}

/// codex rollout 첫 줄(`session_meta`)에서 `payload.id`(세션 UUID)를 뽑는다. `codex resume <id>`의 대상 식별자다
/// (UUIDv7 — docs/workspace-restore.md "에이전트 세션 자동 resume"). session_meta가 아니면 null(회전/잘못된 첫 줄 보호).
pub fn parseCodexId(scratch: std.mem.Allocator, first_line: []const u8, out: []u8) ?[]const u8 {
    return parseCodexMetaField(scratch, first_line, "id", out);
}

/// JSON 문자열 값을 `dst`에 평탄화 미리보기로 복사하고 쓴 바이트 수를 반환(문자열이 아니거나 null이면 0).
/// codex의 last_agent_message처럼 답변이 단일 문자열일 때 쓴다(claude content와 같은 copyPreviewFlattened 공유).
fn copyJsonStringPreview(dst: []u8, v: ?std.json.Value) usize {
    const s = asString(v orelse return 0) orelse return 0;
    return copyPreviewFlattened(dst, s);
}

// ── std.json.Value 접근 helper(태그 확인 후 안전 추출) ───────────────────────────────
// 태그 union을 switch로 좁혀 잘못된 활성 필드 접근(safety panic)을 원천 차단한다.

fn asObject(v: std.json.Value) ?std.json.ObjectMap {
    return switch (v) {
        .object => |o| o,
        else => null,
    };
}

fn asString(v: std.json.Value) ?[]const u8 {
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

// ── 테스트(헤드리스, Linux CI 포함) ─────────────────────────────────────────────────
// 고정 JSONL fixture로 상태 판정을 못박는다. 파싱이 순수 함수라 OS·라이브 에이전트 무관. fixture의 \n은
// `\\` 멀티라인 리터럴에서 escape 처리가 안 되므로 두 글자(backslash-n)로 남아 JSON escape가 되고, 파서가
// 실제 개행으로 푼다(첫 줄 말줄임 테스트에 사용). 각 테스트는 무엇을 증명하는지 적는다.

test "copyPreviewFlattened: 여러 줄 평탄화·공백 collapse·선두/말미 trim·버퍼 cap 말미공백·UTF-8 경계" {
    var buf: [64]u8 = undefined;
    // 선두 공백 무시 + 내부 개행/탭/연속공백 → 공백 1칸 + 말미 공백/개행 제거.
    {
        const n = copyPreviewFlattened(&buf, "  a\n\nb\t c   \n");
        try std.testing.expectEqualStrings("a b c", buf[0..n]);
    }
    // 공백뿐/빈 입력이면 0.
    try std.testing.expectEqual(@as(usize, 0), copyPreviewFlattened(&buf, "   \n\t "));
    try std.testing.expectEqual(@as(usize, 0), copyPreviewFlattened(&buf, ""));
    // 버퍼 cap이 flush된 단어 경계 공백에 딱 떨어져도 말미 공백이 안 남는다(회귀 가드 — trailing trim).
    {
        var small: [3]u8 = undefined; // "ab" + 공백 flush(n=3) 후 'c'가 안 들어감 → "ab "가 아니라 "ab"
        const n = copyPreviewFlattened(&small, "ab cd");
        try std.testing.expectEqualStrings("ab", small[0..n]);
    }
    // UTF-8 경계: 한글이 cap에 걸리면 깨진 바이트 없이 직전 코드포인트까지만.
    {
        var k: [5]u8 = undefined; // "가"(3B) + " " + "나"(3B) 중 "가 "(4B)까지만, "나"(3B)는 5<7이라 안 들어감
        const n = copyPreviewFlattened(&k, "가 나");
        try std.testing.expectEqualStrings("가", k[0..n]); // 말미 공백도 trim
    }
}

test "parseClaudeTail: 마지막 대화가 user면 running (느린 API 갭 — 응답 전)" {
    // user 제출 즉시 기록되고 assistant는 응답 시 기록된다(실측 44초 갭). 그 사이 마지막 대화 = user → running.
    // 물리적 마지막 줄이 메타(system)여도 마지막 *대화*는 user다.
    const tail =
        \\{"type":"user","message":{"role":"user","content":"브랜치 만들어줘"},"timestamp":"2026-06-18T02:18:09Z"}
        \\{"type":"system","content":"meta-only"}
    ;
    var buf: [256]u8 = undefined;
    const s = parseClaudeTail(std.testing.allocator, tail, &buf);
    try std.testing.expectEqual(AgentState.running, s.state);
    try std.testing.expectEqual(@as(usize, 0), s.answer.len);
}

test "parseClaudeTail: ESC 인터럽트(interruptedMessageId)는 interrupted — running으로 접히면 스피너가 영영 안 풀린다" {
    // 실제 회귀: 사용자가 ESC로 에이전트를 끊으면 claude가 `interruptedMessageId`를 단 **user** 엔트리를
    // append한다. 옛 파서는 type=="user"를 무조건 running으로 봐서 상태가 진행 중에 고착됐다 — 게다가 그 뒤로
    // 파일이 안 자라 mtime 게이트(agent_session.poll)가 재파싱조차 막아 영구화됐다. 판별자는 **필드 존재**다
    // (본문 "[Request interrupted by user]" 문구 매칭보다 견고 — 실측 트랜스크립트 전수에 이 필드가 있다).
    const tail =
        \\{"type":"assistant","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"text","text":"파일 읽는 중"}]}}
        \\{"type":"user","interruptedMessageId":"msg_01ABC","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}
    ;
    var buf: [256]u8 = undefined;
    const s = parseClaudeTail(std.testing.allocator, tail, &buf);
    try std.testing.expectEqual(AgentState.interrupted, s.state);
    try std.testing.expectEqual(@as(usize, 0), s.answer.len); // 인터럽트는 답변이 없다(완료가 아니다)

    // 인터럽트 뒤 사용자가 새 프롬프트를 내면 **다시 running**(고착이 아니라 정상 전이).
    const resumed = tail ++
        \\
        \\{"type":"user","message":{"role":"user","content":"다시 해줘"}}
    ;
    const s2 = parseClaudeTail(std.testing.allocator, resumed, &buf);
    try std.testing.expectEqual(AgentState.running, s2.state);
}

test "parseClaudeTail: 인터럽트 판별 — 필드 단독 / 본문 단독 / 오탐 0(문자열 content·인용 프롬프트)" {
    // 실측(~/.claude/projects 전수, 메인체인 인터럽트 109건): 12건(11%)이 `interruptedMessageId` **없이** 본문만
    // 남기고, 본문은 **109건 전부 블록 배열**이며 문구는 두 가지뿐이다("[Request interrupted by user]" 92건,
    // "…for tool use" 17건). 일반 프롬프트의 content는 문자열이다. 판별자는 그 사실에 맞춰 좁게 잡는다.
    var buf: [256]u8 = undefined;

    // ① **필드만** 있는 인터럽트(본문 문구가 없어도 잡아야 한다 — 이 arm이 없으면 89%가 고착).
    const field_only =
        \\{"type":"assistant","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"text","text":"실행 중"}]}}
        \\{"type":"user","interruptedMessageId":"msg_01X","message":{"role":"user","content":[{"type":"text","text":"다른 본문"}]}}
    ;
    try std.testing.expectEqual(AgentState.interrupted, parseClaudeTail(std.testing.allocator, field_only, &buf).state);

    // ② **본문만** 있는 인터럽트(필드 없는 11% — 이 arm이 없으면 9회 중 1회꼴로 고착). "for tool use" 변형 포함.
    const body_only =
        \\{"type":"assistant","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"text","text":"실행 중"}]}}
        \\{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}
    ;
    try std.testing.expectEqual(AgentState.interrupted, parseClaudeTail(std.testing.allocator, body_only, &buf).state);

    // ③ **오탐 0**: 사용자가 그 문구를 *인용*하거나 그 문구로 시작하는 프롬프트를 내도 인터럽트가 아니다.
    //    prefix 매칭이면 여기서 false interrupted로 latch돼 그 턴 내내 스피너가 안 켜지고 완료 알림도 안 뜬다.
    const quoted =
        \\{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user] 이 문구가 왜 뜨는지 설명해줘"}]}}
    ;
    try std.testing.expectEqual(AgentState.running, parseClaudeTail(std.testing.allocator, quoted, &buf).state);
    // 문자열 content는 아예 안 본다(실측: 인터럽트는 전부 블록 배열, 일반 프롬프트가 문자열).
    const string_content =
        \\{"type":"user","message":{"role":"user","content":"[Request interrupted by user]"}}
    ;
    try std.testing.expectEqual(AgentState.running, parseClaudeTail(std.testing.allocator, string_content, &buf).state);
    // 평범한 프롬프트도 당연히 running.
    const normal =
        \\{"type":"user","message":{"role":"user","content":[{"type":"text","text":"인터럽트 얘기 좀 해줘"}]}}
    ;
    try std.testing.expectEqual(AgentState.running, parseClaudeTail(std.testing.allocator, normal, &buf).state);
}

test "parseClaudeTail: 인터럽트 뒤 꼬리 응답(stop_sequence \"No response requested.\")이 idle로 뒤집지 못한다" {
    // 실측 회귀(81건 중 5건): ESC 직후 claude가 `assistant` + stop_reason:"stop_sequence" +
    // "No response requested." 를 붙인다. latch가 없으면 isTerminalStop이 이걸 받아 **idle("✓ 완료")**이 되고,
    // 한 poll 창에 둘 다 관측되면 running→idle 엣지로 **가짜 "에이전트 완료" 알림**까지 뜬다(사용자는 끊었는데).
    const tail =
        \\{"type":"assistant","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"text","text":"작업 중"}]}}
        \\{"type":"user","interruptedMessageId":"msg_01X","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}
        \\{"type":"assistant","message":{"role":"assistant","stop_reason":"stop_sequence","content":[{"type":"text","text":"No response requested."}]}}
    ;
    var buf: [256]u8 = undefined;
    const s = parseClaudeTail(std.testing.allocator, tail, &buf);
    try std.testing.expectEqual(AgentState.interrupted, s.state); // ★ idle이 아니다
    try std.testing.expectEqual(@as(usize, 0), s.answer.len); // "No response requested."가 답변으로 새지 않는다

    // 그 뒤 사용자가 **새 프롬프트**를 내면 latch가 풀려 정상 재개(running) — 그 턴이 끝나면 idle + 완료 알림.
    const resumed = tail ++
        \\
        \\{"type":"user","message":{"role":"user","content":[{"type":"text","text":"다시 해줘"}]}}
        \\{"type":"assistant","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"완료했습니다"}]}}
    ;
    const s2 = parseClaudeTail(std.testing.allocator, resumed, &buf);
    try std.testing.expectEqual(AgentState.idle, s2.state);
    try std.testing.expectEqualStrings("완료했습니다", s2.answer);
}

test "parseCodexTail: turn_aborted 뒤 꼬리 이벤트(exec_command_end)가 running으로 되돌리지 못한다" {
    // 실측 회귀: rollout 파일 **끝**이 `turn_aborted` → `exec_command_end`(ESC로 끊긴 명령의 뒤늦은 종료
    // 이벤트) 순서인 경우가 있다(34건 중 3건). catch-all else가 그걸 running으로 접으면 codex 인터럽트
    // 수정이 통째로 무효가 된다 — 파일이 더 안 자라 mtime 게이트가 재파싱도 막는다(code-review).
    const tail =
        \\{"type":"event_msg","payload":{"type":"exec_command_begin","command":"gh pr checks --watch"}}
        \\{"type":"response_item","payload":{"type":"function_call"}}
        \\{"type":"event_msg","payload":{"type":"turn_aborted","reason":"interrupted","duration_ms":372476}}
        \\{"type":"event_msg","payload":{"type":"exec_command_end","exit_code":130}}
    ;
    var buf: [256]u8 = undefined;
    try std.testing.expectEqual(AgentState.interrupted, parseCodexTail(std.testing.allocator, tail, &buf).state);

    // 새 턴(task_started)이 오면 latch가 풀려 running으로 정상 복귀(고착이 아니다).
    const resumed = tail ++
        \\
        \\{"type":"event_msg","payload":{"type":"task_started"}}
    ;
    try std.testing.expectEqual(AgentState.running, parseCodexTail(std.testing.allocator, resumed, &buf).state);
}

test "parseCodexTail: 중단 뒤 task_complete는 완료로 접히지 않는다 + latch는 새 턴에서만 풀린다" {
    // (a) 중단된 턴 뒤에 붙는 마무리 이벤트를 완료로 접으면, 알림 게이트((running|interrupted)→idle)가
    //     **가짜 "에이전트 완료"**를 쏜다 — 본문은 사용자가 끊은 턴의 부분 답변이다(code-review).
    var buf: [256]u8 = undefined;
    const aborted_then_complete =
        \\{"type":"event_msg","payload":{"type":"task_started"}}
        \\{"type":"event_msg","payload":{"type":"turn_aborted","reason":"interrupted"}}
        \\{"type":"event_msg","payload":{"type":"task_complete","last_agent_message":"부분 답변"}}
    ;
    const s1 = parseCodexTail(std.testing.allocator, aborted_then_complete, &buf);
    try std.testing.expectEqual(AgentState.interrupted, s1.state); // ★ idle이 아니다
    try std.testing.expectEqual(@as(usize, 0), s1.answer.len); // 부분 답변이 완료 알림 본문으로 새지 않는다

    // (b) latch는 **새 턴**(user_message/task_started)에서만 풀린다 — 그 뒤 완료면 정상 idle + 답변.
    const resumed = aborted_then_complete ++
        \\
        \\{"type":"event_msg","payload":{"type":"user_message","message":"다시"}}
        \\{"type":"event_msg","payload":{"type":"task_complete","last_agent_message":"진짜 완료"}}
    ;
    const s2 = parseCodexTail(std.testing.allocator, resumed, &buf);
    try std.testing.expectEqual(AgentState.idle, s2.state);
    try std.testing.expectEqualStrings("진짜 완료", s2.answer);
}

test "parseCodexTail: turn_aborted(ESC 인터럽트)는 interrupted — else 분기로 새면 claude와 같은 고착" {
    // codex는 인터럽트에 `event_msg/turn_aborted`(reason:"interrupted")를 남긴다. task_complete가 아니므로
    // 옛 파서의 else(=running)로 떨어져 같은 버그가 됐다.
    const tail =
        \\{"type":"event_msg","payload":{"type":"task_started"}}
        \\{"type":"event_msg","payload":{"type":"turn_aborted","reason":"interrupted","duration_ms":372476}}
    ;
    var buf: [256]u8 = undefined;
    const s = parseCodexTail(std.testing.allocator, tail, &buf);
    try std.testing.expectEqual(AgentState.interrupted, s.state);
    try std.testing.expectEqual(@as(usize, 0), s.answer.len);

    // 인터럽트 뒤 새 턴이 시작되면 다시 running.
    const resumed = tail ++
        \\
        \\{"type":"event_msg","payload":{"type":"user_message","message":"다시"}}
    ;
    const s2 = parseCodexTail(std.testing.allocator, resumed, &buf);
    try std.testing.expectEqual(AgentState.running, s2.state);
}

test "parseClaudeTail: 마지막 assistant가 tool_use면 running (도구 실행 중)" {
    // stop_reason=tool_use는 턴 미완료(도구 결과 대기) — running. content가 thinking뿐이라 답변 미리보기 없음.
    const tail =
        \\{"type":"assistant","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"thinking","thinking":"..."}]}}
    ;
    var buf: [256]u8 = undefined;
    const s = parseClaudeTail(std.testing.allocator, tail, &buf);
    try std.testing.expectEqual(AgentState.running, s.state);
    try std.testing.expectEqual(@as(usize, 0), s.answer.len);
}

test "parseClaudeTail: 마지막 assistant가 end_turn이면 idle + 답변 미리보기(여러 줄 평탄화, 메타 꼬리 무시)" {
    // 완료된 턴(end_turn) 뒤에 mode/pr-link 메타가 붙어도 idle 유지 — "물리적 마지막 줄"이 아니라 "마지막
    // 대화 엔트리"를 본다는 핵심 불변식. 답변 미리보기는 첫 text 블록을 여러 줄→한 줄로 평탄화(개행=공백 1칸,
    // 알림 본문이 더 많이 보이게; 사이드바는 폭으로 다시 말줄임). 이후 블록은 버린다.
    const tail =
        \\{"type":"user","message":{"role":"user","content":"PR0 머지해줘"}}
        \\{"type":"assistant","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"PR0 머지 완료\n둘째 줄도 보임"}]}}
        \\{"type":"mode","mode":"default"}
        \\{"type":"pr-link","prNumber":654}
    ;
    var buf: [256]u8 = undefined;
    const s = parseClaudeTail(std.testing.allocator, tail, &buf);
    try std.testing.expectEqual(AgentState.idle, s.state);
    try std.testing.expectEqualStrings("PR0 머지 완료 둘째 줄도 보임", s.answer); // 개행 → 공백 1칸으로 평탄화
}

test "parseClaudeTail: end_turn 뒤 tool_result(user)면 다시 running" {
    // 완료처럼 보여도 그 뒤 user(tool_result/새 프롬프트)가 오면 다음 응답 대기 → running, 답변 미리보기 해제.
    const tail =
        \\{"type":"assistant","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"이전 답변"}]}}
        \\{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]}}
    ;
    var buf: [256]u8 = undefined;
    const s = parseClaudeTail(std.testing.allocator, tail, &buf);
    try std.testing.expectEqual(AgentState.running, s.state);
    try std.testing.expectEqual(@as(usize, 0), s.answer.len);
}

test "parseClaudeTail: end_turn 뒤 isMeta user는 무시 — idle 유지" {
    // local-command caveat·hook이 isMeta=true user로 주입돼도 대화가 아니므로 false running으로 안 뒤집힌다.
    const tail =
        \\{"type":"assistant","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"답변 본문"}]}}
        \\{"type":"user","isMeta":true,"message":{"role":"user","content":"<local-command-caveat>...</local-command-caveat>"}}
    ;
    var buf: [256]u8 = undefined;
    const s = parseClaudeTail(std.testing.allocator, tail, &buf);
    try std.testing.expectEqual(AgentState.idle, s.state);
    try std.testing.expectEqualStrings("답변 본문", s.answer);
}

test "parseClaudeTail: 잘린 선두 줄은 건너뛴다 (tail이 줄 중간부터 시작)" {
    // tail은 파일 끝 N KB를 seek해 읽어 첫 줄이 잘려 있다 — JSON 파싱 실패로 자동 skip(별도 플래그 불필요).
    const tail =
        \\_reason":"end_turn"}}  ← 이건 잘린 첫 줄(불량 JSON)
        \\{"type":"assistant","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"온전한 줄"}]}}
    ;
    var buf: [256]u8 = undefined;
    const s = parseClaudeTail(std.testing.allocator, tail, &buf);
    try std.testing.expectEqual(AgentState.idle, s.state);
    try std.testing.expectEqualStrings("온전한 줄", s.answer);
}

test "parseClaudeTail: 메타 엔트리뿐이면 unknown" {
    // 대화(user/assistant) 엔트리가 하나도 없으면 판정 불가 → unknown(platform이 더 큰 tail 재시도/보수 처리).
    const tail =
        \\{"type":"mode","mode":"default"}
        \\{"type":"pr-link","prNumber":1}
        \\{"type":"file-history-snapshot"}
    ;
    var buf: [256]u8 = undefined;
    const s = parseClaudeTail(std.testing.allocator, tail, &buf);
    try std.testing.expectEqual(AgentState.unknown, s.state);
    try std.testing.expectEqual(@as(usize, 0), s.answer.len);
}

test "parseClaudeTail: 답변 미리보기는 UTF-8 경계로 말줄임 (글자 안 깨짐)" {
    // answer_buf가 작으면 코드포인트 중간에서 안 자른다. "가나다라마"(각 3바이트)·buf 7바이트 → "가나"(6바이트).
    const tail =
        \\{"type":"assistant","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"가나다라마"}]}}
    ;
    var small: [7]u8 = undefined;
    const s = parseClaudeTail(std.testing.allocator, tail, &small);
    try std.testing.expectEqual(AgentState.idle, s.state);
    try std.testing.expectEqualStrings("가나", s.answer); // 6바이트(7로 자르면 '다' 중간이라 되돌림)
}

test "parseClaudeTail: 빈 입력/공백 줄은 unknown(크래시 없음)" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqual(AgentState.unknown, parseClaudeTail(std.testing.allocator, "", &buf).state);
    try std.testing.expectEqual(AgentState.unknown, parseClaudeTail(std.testing.allocator, "\n  \n\t\n", &buf).state);
}

// ── codex 어댑터 테스트 ──────────────────────────────────────────────────────────────

test "parseCodexTail: 마지막이 task_complete면 idle + last_agent_message 미리보기(여러 줄 평탄화)" {
    // codex 완료는 명시적(event_msg/task_complete)이고 최종 답변이 그 엔트리에 직접 담긴다 — 여러 줄을 한 줄로
    // 평탄화한 미리보기(개행=공백 1칸, claude와 같은 copyPreviewFlattened 공유; 알림 본문이 더 많이 보임).
    const tail =
        \\{"type":"event_msg","payload":{"type":"agent_message","message":"진행하겠습니다."}}
        \\{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"..."}]}}
        \\{"type":"event_msg","payload":{"type":"task_complete","turn_id":"t1","last_agent_message":"설치와 설정 완료했습니다.\n둘째 줄도 보임"}}
    ;
    var buf: [256]u8 = undefined;
    const s = parseCodexTail(std.testing.allocator, tail, &buf);
    try std.testing.expectEqual(AgentState.idle, s.state);
    try std.testing.expectEqualStrings("설치와 설정 완료했습니다. 둘째 줄도 보임", s.answer); // 개행 → 공백 1칸
}

test "parseCodexTail: task_complete 뒤 token_count는 무시 — idle 유지" {
    // token_count는 턴 내내·완료 뒤에도 찍히는 회계라 무시해야 false running이 안 된다(실측 한 턴 19건).
    const tail =
        \\{"type":"event_msg","payload":{"type":"task_complete","turn_id":"t1","last_agent_message":"완료"}}
        \\{"type":"event_msg","payload":{"type":"token_count","info":{"total":123}}}
    ;
    var buf: [256]u8 = undefined;
    const s = parseCodexTail(std.testing.allocator, tail, &buf);
    try std.testing.expectEqual(AgentState.idle, s.state);
    try std.testing.expectEqualStrings("완료", s.answer);
}

test "parseCodexTail: 진행 신호(agent_message / response_item / user_message)는 running" {
    // task_complete 전의 모든 turn 활동은 running. 답변 미리보기는 idle에서만 — running이면 길이 0.
    var buf: [256]u8 = undefined;
    const commentary =
        \\{"type":"event_msg","payload":{"type":"task_started"}}
        \\{"type":"event_msg","payload":{"type":"agent_message","message":"먼저 확인하겠습니다."}}
    ;
    try std.testing.expectEqual(AgentState.running, parseCodexTail(std.testing.allocator, commentary, &buf).state);
    const tool =
        \\{"type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{}"}}
    ;
    try std.testing.expectEqual(AgentState.running, parseCodexTail(std.testing.allocator, tool, &buf).state);
    const new_prompt =
        \\{"type":"event_msg","payload":{"type":"task_complete","last_agent_message":"이전 완료"}}
        \\{"type":"event_msg","payload":{"type":"user_message","message":"또 해줘"}}
    ;
    const s = parseCodexTail(std.testing.allocator, new_prompt, &buf);
    try std.testing.expectEqual(AgentState.running, s.state); // 새 user 입력 → 다시 running
    try std.testing.expectEqual(@as(usize, 0), s.answer.len);
}

test "parseCodexTail: 메타(session_meta/turn_context)뿐이면 unknown, 잘린 선두 줄 skip" {
    var buf: [256]u8 = undefined;
    const meta_only =
        \\{"type":"session_meta","payload":{"id":"x","cwd":"/Users/y/ws"}}
        \\{"type":"turn_context","payload":{"cwd":"/Users/y/ws"}}
    ;
    try std.testing.expectEqual(AgentState.unknown, parseCodexTail(std.testing.allocator, meta_only, &buf).state);
    // 잘린 선두 줄(불량 JSON)은 skip되고 온전한 task_complete로 idle.
    const partial =
        \\complete","last_agent_message":"x"}}  ← 잘린 첫 줄
        \\{"type":"event_msg","payload":{"type":"task_complete","last_agent_message":"온전"}}
    ;
    const s = parseCodexTail(std.testing.allocator, partial, &buf);
    try std.testing.expectEqual(AgentState.idle, s.state);
    try std.testing.expectEqualStrings("온전", s.answer);
}

test "parseCodexId: session_meta 첫 줄에서 payload.id(세션 UUID) 추출" {
    var scratch_buf: [256]u8 = undefined;
    const meta =
        \\{"timestamp":"2026-06-01T18:52:03Z","type":"session_meta","payload":{"id":"019e8298-f7bf-7b63-b9a4-46626868c072","cwd":"/Users/yoonhb"}}
    ;
    try std.testing.expectEqualStrings(
        "019e8298-f7bf-7b63-b9a4-46626868c072",
        parseCodexId(std.testing.allocator, meta, &scratch_buf).?,
    );
    // session_meta가 아니면 null.
    const not_meta =
        \\{"type":"response_item","payload":{"type":"message"}}
    ;
    try std.testing.expectEqual(@as(?[]const u8, null), parseCodexId(std.testing.allocator, not_meta, &scratch_buf));
    // id 누락도 null.
    const no_id =
        \\{"type":"session_meta","payload":{"cwd":"/x"}}
    ;
    try std.testing.expectEqual(@as(?[]const u8, null), parseCodexId(std.testing.allocator, no_id, &scratch_buf));
}
