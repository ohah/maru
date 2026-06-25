//! L2 session core — 에이전트(claude·codex) 세션 JSONL 트랜스크립트의 순수 상태 판정. 터미널에서 도는
//! 에이전트가 디스크에 남기는 세션 트랜스크립트의 *끝부분(tail)* 바이트만 받아 running/idle/unknown과 마지막
//! 답변 미리보기를 계산한다. 파일 I/O(세션 찾기·tail read·디렉터리 나열)는 platform(L4)이 하고, 여기는
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
/// 이 판정을 무시하고 none으로 덮는다(docs/agent-session.md "상태 모델": running/idle은 포그라운드 AND로 묶임).
pub const AgentState = enum {
    /// tail에 완전한 *대화* 엔트리가 없음(메타 엔트리뿐이거나, 초대형 단일 줄이라 tail 창 안에 완전한 줄이
    /// 없음). platform이 더 큰 tail로 재시도하거나 보수적으로 다룬다(이전 상태 유지 등).
    unknown,
    /// 마지막 대화 엔트리가 미완료 — user 제출 후 응답 대기 / assistant가 tool_use 중 / tool_result 후 다음
    /// 응답 대기. 느린 API에도 이 판정은 false idle이 없다("턴 미완료"는 구조적 사실).
    running,
    /// 마지막 대화 엔트리가 완료된 assistant 턴(stop_reason이 턴-종료 사유).
    idle,
};

/// 상태 + (idle일 때) 마지막 답변 첫 줄 미리보기.
pub const Status = struct {
    state: AgentState,
    /// idle일 때 마지막 답변 첫 줄을 호출자 `answer_buf`에 UTF-8 경계로 말줄임 복사한 슬라이스. running/unknown
    /// 이거나 답변 텍스트가 없으면 길이 0. `answer_buf`를 가리키므로 buf 수명만큼 유효하다.
    answer: []const u8,
};

/// claude 세션 JSONL의 tail 바이트에서 상태·마지막 답변을 계산한다(순수). `tail`은 파일 끝 N KB를 seek해 읽은
/// 바이트라 보통 첫 줄이 잘려 있다 — JSON 파싱에 실패한 줄은 건너뛰므로(잘린 선두 줄·불량 줄 포함) "어디서부터
/// 완전한 줄인가"를 알려주는 별도 플래그가 필요 없다. `scratch`는 줄 파싱용 임시 할당(각 줄 파싱 직후 해제).
/// `answer_buf`엔 idle일 때 마지막 답변 첫 줄을 복사한다.
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
            state = .running;
            answer_len = 0;
        }
        // 그 밖의 타입은 메타 — 상태 불변(마지막 대화 엔트리만 의미를 갖는다).
    }

    return .{ .state = state, .answer = answer_buf[0..answer_len] };
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

/// assistant `content` 배열에서 첫 `text` 블록의 첫 줄을 `dst`에 UTF-8 경계로 말줄임 복사하고 쓴 바이트 수를
/// 반환한다. content가 배열이 아니거나 text 블록이 없으면 0(thinking/tool_use만 있는 턴 등).
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
        if (pending_space) { // 비공백 앞에서만 공백 1칸 flush → 말미 공백은 안 써진다
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
    return n;
}

/// claude project 디렉터리 이름 = 절대 cwd의 `/`를 `-`로 치환(예: `/Users/x/ws/maru` → `-Users-x-ws-maru`).
/// `out`에 써서 슬라이스를 돌려준다. `out`이 작으면 null. 순수 함수.
///
/// 베이스: 실 세션 디렉터리로 검증한 규칙 — `/`→`-`은 하이픈을 포함한 경로(`.../agent-devtools`)에서도 디렉터리
/// 이름과 정확히 일치했다. claude는 경로에 `.`/`_` 등이 있으면 추가 치환할 수 있으나(미검증) 로컬에 그런 경로의
/// 세션이 없어 확인하지 못했다 — 그런 cwd는 디렉터리 not-found로 빠지고 platform이 "에이전트 상태 없음"으로
/// graceful 폴백한다(docs/agent-session.md PR1 한계). 치환 문자 집합을 한 곳에 둬서 추후 정정하기 쉽게 한다.
pub fn encodeClaudeProjectDir(out: []u8, cwd: []const u8) ?[]const u8 {
    if (cwd.len > out.len) return null;
    for (cwd, 0..) |ch, i| out[i] = if (ch == '/') '-' else ch;
    return out[0..cwd.len];
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
                state = .idle;
                // 최종 답변이 task_complete 엔트리에 직접 담긴다 — Value 해제 전에 buf로 복사.
                answer_len = copyJsonStringPreview(answer_buf, payload.get("last_agent_message"));
            } else if (std.mem.eql(u8, pt, "token_count")) {
                // 토큰 회계 — 상태 불변(무시).
            } else {
                state = .running; // user_message/agent_message/task_started/patch_apply_* 등 진행 신호.
                answer_len = 0;
            }
        } else if (std.mem.eql(u8, entry_type, "response_item")) {
            state = .running; // 모델 출력/도구 호출 — 턴 진행 중.
            answer_len = 0;
        }
        // session_meta/turn_context/모르는 타입은 메타 — 상태 불변.
    }

    return .{ .state = state, .answer = answer_buf[0..answer_len] };
}

/// codex rollout 첫 줄(`session_meta`)의 `payload.<field>` 문자열을 `out`으로 복사해 돌려준다. session_meta가
/// 아니거나 필드가 없거나 버퍼가 작으면 null. parseCodexCwd/parseCodexId의 공통 구현(순수 — 줄 파싱만).
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

/// codex rollout 첫 줄(`session_meta`)에서 `payload.cwd`를 뽑는다. codex는 날짜 분할(`<YYYY>/<MM>/<DD>/`)이라
/// cwd로 디렉터리를 못 찾으므로, platform이 최근 rollout들의 첫 줄을 읽어 cwd 일치하는 최신 세션을 고른다.
pub fn parseCodexCwd(scratch: std.mem.Allocator, first_line: []const u8, out: []u8) ?[]const u8 {
    return parseCodexMetaField(scratch, first_line, "cwd", out);
}

/// codex rollout 첫 줄(`session_meta`)에서 `payload.id`(세션 UUID)를 뽑는다. `codex resume <id>`의 대상 식별자다
/// (UUIDv7 — docs/workspace-restore.md "에이전트 세션 자동 resume"). 규칙은 parseCodexCwd와 동일.
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

test "encodeClaudeProjectDir: 절대 cwd의 / 를 - 로 치환" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "-Users-x-Documents-workspace-maru",
        encodeClaudeProjectDir(&buf, "/Users/x/Documents/workspace/maru").?,
    );
    // 하이픈 포함 경로도 그대로(실 세션으로 검증한 케이스).
    try std.testing.expectEqualStrings(
        "-Users-x-ws-agent-devtools",
        encodeClaudeProjectDir(&buf, "/Users/x/ws/agent-devtools").?,
    );
    // 버퍼가 작으면 null.
    var tiny: [4]u8 = undefined;
    try std.testing.expectEqual(@as(?[]const u8, null), encodeClaudeProjectDir(&tiny, "/Users/x"));
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

test "parseCodexCwd: session_meta 첫 줄에서 payload.cwd 추출" {
    var scratch_buf: [256]u8 = undefined;
    const meta =
        \\{"timestamp":"2026-06-01T18:52:03Z","type":"session_meta","payload":{"id":"u","cwd":"/Users/yoonhb/Documents/workspace/maru","cli_version":"1.0"}}
    ;
    try std.testing.expectEqualStrings(
        "/Users/yoonhb/Documents/workspace/maru",
        parseCodexCwd(std.testing.allocator, meta, &scratch_buf).?,
    );
    // session_meta가 아니면 null(잘못된 첫 줄/회전된 파일 보호).
    const not_meta =
        \\{"type":"response_item","payload":{"type":"message"}}
    ;
    try std.testing.expectEqual(@as(?[]const u8, null), parseCodexCwd(std.testing.allocator, not_meta, &scratch_buf));
    // cwd 누락도 null.
    const no_cwd =
        \\{"type":"session_meta","payload":{"id":"u"}}
    ;
    try std.testing.expectEqual(@as(?[]const u8, null), parseCodexCwd(std.testing.allocator, no_cwd, &scratch_buf));
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
