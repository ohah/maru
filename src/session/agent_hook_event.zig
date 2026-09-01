//! provider 훅이 남긴 **이벤트 로그 한 줄**을 읽는 순수 파서와 tail 소비 상태(L2, I/O 없음).
//! 계약의 단일 출처는 [docs/agent-hooks.md](../../docs/agent-hooks.md)이고, 이 파일은 그 §4(전달 채널)의
//! 코어다. 실제 파일 읽기는 platform이 하고, 여기서는 **바이트 → 이벤트**만 한다.
//!
//! **왜 JSON 라이브러리를 쓰지 않는가**: ⑴ 우리가 쓰는 필드는 십여 개뿐인데 payload에는 셸 명령 출력까지
//! 실려 전체를 트리로 만들 이유가 없고, ⑵ `std.json`의 typed 파싱은 f128 소프트플로트를 제품 링크로 끌어와
//! ReleaseSafe 빌드를 깨뜨린 전례가 있다(같은 이유로 알림 디코더도 손으로 짰다). 그래서 **구조를 아는 최소
//! 스캐너**를 둔다 — 문자열/이스케이프/중첩 깊이만 인지하고 나머지는 건너뛴다.
//!
//! **왜 깊이를 세는가**: 단순 문자열 검색은 값 안에 든 `"file_path"` 같은 글자에 걸린다. 에이전트가 그 단어를
//! 프롬프트에 쓰는 일은 흔하다. 그래서 최상위(depth 1)와 `tool_input` 안(depth 2)의 **키 위치**만 인정한다.

const std = @import("std");

/// 한 줄의 최대 길이. 넘으면 그 줄은 **버린다**(잘라서 반쪽 JSON을 만들지 않는다 — 파서가 어차피 거절하고,
/// 잘린 조각이 다음 줄과 붙는 사고만 는다). 훅 쪽도 같은 값으로 스스로 자른다.
///
/// **32 KiB인 근거(2026-08-20 실측)**: 우리 세트에서 가장 큰 이벤트가 `PreToolUse(Agent)` 4,249 B였고
/// 그 다음이 `PreToolUse(Bash)` 3,593 B였다. 거대한 `tool_response.stdout`·`originalFile`을 싣던
/// `PostToolUse`는 세트에서 뺐다(계약 §3.1). 8 KiB로 잡으면 긴 서브에이전트 프롬프트가 걸리고, 더 키우면
/// 훅이 한 번에 밀어 넣는 양만 는다.
pub const max_line_bytes: usize = 32 * 1024;

/// 한 tick에 처리할 이벤트 상한. 도구 폭주 구간에서 tick 하나가 수백 줄을 파싱하며 렌더를 붙잡지 않게 한다.
/// 남은 줄은 다음 tick이 이어서 읽는다(오프셋이 전진하므로 다시 읽지 않는다).
pub const max_events_per_tick: usize = 64;

/// 이 크기를 넘으면 회전한다(계약 §4.2). **1 MiB** 인 근거: `PreToolUse` payload 가 실측 최대 4 KB 이고
/// 경계 훅은 그보다 훨씬 작다(§3). 도구를 많이 쓰는 턴이 수십 KB 이므로 이 값은 «정상 세션 여러 턴을
/// 담되» 디스크에 오래 남을 양은 아니다.
///
/// ⚠️ **상한과 유실은 반대로 움직인다.** 낮추면 회전이 잦아지고, 회전할 때마다 «훅이 옛 fd 로 계속 쓰는»
/// 창이 열린다(§4.2의 절차가 그 창을 tail 재수집으로 메운다). 그래서 평시의 잔존 축소는 «회전을 자주» 가
/// 아니라 «상한을 적당히» 로 얻는다.
pub const rotate_at_bytes: u64 = 1024 * 1024;

/// 회전본 이름의 접미. 원본이 `<pane>.ndjson` 이면 회전본은 `<pane>.ndjson.rotated` 다.
///
/// **시작 시 정리가 이 이름도 지우게** 같은 접두를 유지한다 — 회전 도중 죽으면 회전본만 남는데, 이름이
/// 우리 것으로 안 보이면 영영 치워지지 않는다.
pub const rotated_suffix = ".rotated";

/// 지금 회전해야 하는가. **크기만 본다** — 시간으로 잡으면 조용한 세션도 회전해 유실 창을 공짜로 연다.
pub fn shouldRotate(size: u64) bool {
    return size >= rotate_at_bytes;
}

/// 로그 한 줄의 provider 표식과 payload를 가르는 구분자. **payload에는 절대 나오지 않는다** — JSON은 제어문자를
/// 이스케이프하므로 raw 탭이 들어올 수 없다(실측: payload는 개행 없는 한 줄 JSON이다).
pub const field_separator: u8 = '\t';

/// 훅이 payload 길이 상한을 넘겼을 때 대신 적는 표식. **이벤트를 조용히 없애지 않는다** — 무엇이 잘렸는지
/// 세는 것과 아무 일도 없던 것은 다르다.
pub const oversized_marker = "__oversized__";

pub const Kind = enum {
    session_start,
    user_prompt_submit,
    stop,
    /// 오류로 끝난 턴. provider 가 `Stop` **대신** 보낸다 — 걸지 않으면 그 pane 이 영영 «진행 중» 이다.
    stop_failure,
    /// 서브에이전트가 떴다. 자식 수를 **세는** 유일한 신뢰 신호다.
    subagent_start,
    /// 서브에이전트가 끝났다.
    subagent_stop,
    permission_request,
    pre_tool_use,
    notification,
    /// 상한을 넘겨 훅이 버린 이벤트. 종류를 알 수 없다.
    oversized,
    /// 우리가 걸지 않은 이벤트거나 모르는 이름. 소비자는 무시한다.
    unknown,
};

/// 한 이벤트. **모든 슬라이스는 입력 줄을 빌린다**(할당 없음) — 줄 버퍼가 살아 있는 동안만 유효하다.
/// 문자열 값은 **JSON 이스케이프가 남아 있는 원문**이다. 화면에 올릴 때만 `decodeInto`로 푼다.
pub const Event = struct {
    /// 훅이 줄 앞에 적은 provider 이름. payload에는 이 정보가 없어서 **우리가 붙인다**(계약 §4.1).
    provider: []const u8 = "",
    kind: Kind = .unknown,
    session_id: []const u8 = "",
    transcript_path: []const u8 = "",
    /// 훅이 돈 **작업 디렉터리**. 두 provider 가 모두 싣는다 — codex 는 스키마가 직접 못 박고
    /// (`codex-rs/hooks/src/schema.rs`, `deny_unknown_fields`; 계약 §3 이 인용한 그 목록에 `cwd` 가 있다),
    /// claude 는 실측 payload 에 있다.
    ///
    /// **왜 필요한가**: 원격 pane 의 cwd 는 OSC 7 로만 오는데, 그 보고자는 `precmd` 라 **프롬프트가
    /// 그려질 때만** 발화한다. `cd proj && claude` 처럼 셸이 곧바로 전면 TUI 에 자리를 내주면 그 뒤로
    /// 프롬프트가 없어 값이 **그 직전**에서 멈춘다 — 에이전트 세션들이 사이드바에 전부 홈으로 뜨는
    /// 모양이 이것이다(ssh-integration.md §9.5). 훅은 그 구간에도 **매 턴** 오므로 이 값이 산다.
    ///
    /// ⚠️ **소비는 한 지점에서 정한다**(`sidebarCwdPath`). 예전에 그 자리만 관측을 직접 읽어 「같은
    /// 화면의 두 뷰가 다른 답을 내던」 회귀가 있었다 — 소스를 하나 더 들이면 그 함정이 되살아난다.
    cwd: []const u8 = "",
    /// 턴 식별자. Claude는 `prompt_id`, Codex는 `turn_id`로 온다 — 같은 자리에 담는다.
    turn_key: []const u8 = "",
    tool_name: []const u8 = "",
    /// `Notification.message` — 사람이 읽는 «무엇을 기다리는지».
    ///
    /// **주의 알림 본문은 승인 경로와 이 경로가 다르다.** `PermissionRequest` 는 `tool_name`·
    /// `tool_input` 을 싣지만 `Notification` payload 는 `message`·`title`·`notification_type` 뿐이라
    /// (실측 2026-08-22 — 생성부 확인) 도구 이름 규칙을 그대로 쓰면 **본문이 빈 문자열**이다.
    /// 알림이 뜨는데 아무 말도 안 하면 사용자는 창을 열어 다시 찾아야 한다.
    ///
    /// `text` 에 넣지 않고 자리를 따로 두는 이유: `text` 는 `Stop` 의 응답·`UserPromptSubmit` 의 프롬프트가
    /// 쓰는 자리다. 뒷날 어느 provider 가 그 이벤트에 `message` 를 더하면 **대화 줄이 조용히 오염된다.**
    notice_text: []const u8 = "",
    /// `tool_input.description` — 사람이 읽는 도구 설명. 진행 중 배지가 쓴다(명령 원문은 길고 민감해 쓰지 않는다).
    tool_description: []const u8 = "",
    /// `tool_input.file_path` — 편집 도구가 만지는 경로. **AI 소행 확정(AT3)이 쓸 값이고, 지금은 파싱만
    /// 한다** — 제품 소비자가 아직 없다.
    ///
    /// 이 줄이 「쓴다」라고 현재형이던 것을 고쳤다(2026-08-25). 형제 필드(`tool_description`·`text`)는
    /// 실제로 소비자가 있어, 같은 어투가 이 필드에도 배관이 있다고 읽히게 했다.
    ///
    /// **Claude 에만 있다.** Codex 의 `tool_input` 은 `command` 하나뿐이고 경로는 그 안의 패치 텍스트에
    /// 들어 있다(실측 2026-08-20). Codex 경로는 `patchPaths` 로 훑는다.
    file_path: []const u8 = "",
    /// `tool_input.command` 원문(이스케이프 미해제). Codex 의 `apply_patch` 는 여기에 패치 전체가 들어오고,
    /// 셸 도구는 실행할 명령이 들어온다.
    tool_command: []const u8 = "",
    /// `UserPromptSubmit.prompt` 또는 `Stop.last_assistant_message`. 사이드바 대화 줄이 쓴다.
    text: []const u8 = "",
    /// `SessionStart.source`(startup/resume/…).
    source: []const u8 = "",
    /// 참이면 이 `Stop`은 재진입이므로 **턴 종료로 세지 않는다**(계약 §2).
    stop_hook_active: bool = false,
    /// 서브에이전트 이벤트가 실어 오는 자식 식별자(계약 §2). 있으면 그 이벤트는 **자식의 것**이라 부모
    /// 상태에 그대로 섞으면 안 된다.
    agent_id: []const u8 = "",
    /// `Notification.notification_type`(계약 §6). 종류를 모르면 상태를 흔들지 않는다 — 아는 것만 옮긴다.
    notification_type: NotificationKind = .none,
    /// `background_tasks` 배열의 **원문 슬라이스**(`[` 부터 `]` 까지). 비면 그 키가 없었다는 뜻이다.
    ///
    /// 값이 아니라 원문을 드는 이유: 이 목록에서 뽑아야 하는 것은 «지금 도는 서브에이전트 id 집합» 인데,
    /// 그것을 `Event` 에 배열로 담으면 이벤트 하나당 수백 바이트가 되고 tick 당 상한(64개)만큼 곱해진다.
    /// 슬라이스 하나(16 바이트)만 들고, 필요한 자리에서 `liveSubagentIds` 로 다시 훑는다. 슬라이스는
    /// 읽기 버퍼를 가리키므로 **그 배치를 처리하는 동안만** 유효하다.
    background_tasks_raw: []const u8 = "",
};

/// `Notification` 이 말하는 종류(계약 §6).
///
/// **아는 것만 든다.** 상태를 옮길 만한 것은 «사용자 입력을 기다린다» 는 다섯뿐이고, 나머지(유휴·인증
/// 성공·쿼터 재개·elicitation 완료 등)는 배지와 무관하므로 **모르는 것과 같이 취급한다** — 종류를 모르는
/// 채 배지를 옮기면 임의의 provider 알림이 「입력 대기」로 보인다.
///
/// **권위 있는 두 목록이 서로 다르다**(2026-08-22 대조). 공개 스펙(`code.claude.com/docs/en/hooks` 의
/// Notification matcher)은 아홉을 적고, 제품이 실제로 내는 값은 열넷이다. 어느 한쪽에만 있는 것이 있다:
///
///   문서에만: `elicitation_complete`·`elicitation_response`(둘 다 «끝났다» 라 안 옮긴다)
///   제품에만: `worker_permission_prompt`(자식의 승인 요구 — **옮긴다**)·`push_notification`·
///            `computer_use_enter`/`exit`·`quota_auto_resume_*`
///
/// 그래서 **블랙리스트로 짜면 어느 한쪽에서 틀린다.** 화이트리스트 + 「모르면 안 옮긴다」는 두 목록 모두에
/// 대해 성립하고, 목록이 또 갈라져도 조용히 무시되는 쪽으로 틀린다.
pub const NotificationKind = enum {
    /// `Notification` 이 아니거나 종류가 없다.
    none,
    /// 승인·입력을 기다린다 — `permission_prompt`·`worker_permission_prompt`·`elicitation_dialog`·
    /// `elicitation_url_dialog`·`agent_needs_input`.
    needs_input,
    /// 우리가 아는 종류지만 배지와 무관하다(`idle_prompt`·`auth_success`·쿼터 재개 등).
    other,
};

/// 종류 이름을 위 셋으로 접는다.
pub fn notificationKindOf(name: []const u8) NotificationKind {
    const needs_input = [_][]const u8{
        "permission_prompt",
        "worker_permission_prompt",
        "elicitation_dialog",
        "elicitation_url_dialog",
        "agent_needs_input",
    };
    for (needs_input) |k| {
        if (std.mem.eql(u8, name, k)) return .needs_input;
    }
    return .other;
}

/// `liveSubagentIds` 의 결과.
pub const SubagentTally = struct {
    /// 담은 id 수.
    count: usize = 0,
    /// 담을 자리가 모자랐다 — **목록이 불완전하다**. 이때는 «없으니 끝났다» 로 읽으면 안 된다.
    truncated: bool = false,
    /// 목록을 읽다 모양이 어긋났다. 역시 판단 근거로 쓰지 않는다.
    malformed: bool = false,
};

/// `background_tasks` 원문에서 **`type` 이 `subagent` 이고 `status` 가 `running` 인 항목의 `id`** 를 모은다.
///
/// 이것이 «아직 도는 자식» 의 목록이다. 여기 없는데 우리가 붙잡고 있는 자식은 **끝난 것**이다 — 종료
/// 이벤트를 놓쳤거나(줄 유실) 담을 자리가 없었거나 한 유령이다.
///
/// ⚠️ `truncated`·`malformed` 면 목록이 진실의 일부일 뿐이므로 **회수 근거로 쓰면 안 된다**. 살아 있는
/// 자식을 지우는 쪽이 훨씬 나쁜 실패다.
pub fn liveSubagentIds(raw: []const u8, out: [][]const u8) SubagentTally {
    var tally: SubagentTally = .{};
    if (raw.len == 0) return tally;
    var scan: Scanner = .{ .src = raw, .i = 0 };
    if ((scan.peek() orelse return .{ .malformed = true }) != '[') return .{ .malformed = true };
    scan.i += 1;

    var depth: usize = 1;
    var id: []const u8 = "";
    var is_subagent = false;
    var is_running = false;
    var pending: enum { none, id, status, kind } = .none;

    while (scan.i < raw.len) {
        const ch = raw[scan.i];
        if (ch == '"') {
            const text = scan.rawString() orelse return .{ .malformed = true };
            // 항목 하나의 깊이(2)에서만 본다 — 더 깊은 곳의 같은 이름에 걸리지 않게.
            if (depth == 2) {
                switch (pending) {
                    .id => {
                        id = text;
                        pending = .none;
                    },
                    .status => {
                        is_running = std.mem.eql(u8, text, "running");
                        pending = .none;
                    },
                    .kind => {
                        is_subagent = std.mem.eql(u8, text, "subagent");
                        pending = .none;
                    },
                    .none => {
                        if (std.mem.eql(u8, text, "id")) {
                            pending = .id;
                        } else if (std.mem.eql(u8, text, "status")) {
                            pending = .status;
                        } else if (std.mem.eql(u8, text, "type")) {
                            pending = .kind;
                        }
                        if (pending != .none) {
                            scan.skipWs();
                            if (scan.i < raw.len and raw[scan.i] == ':') scan.i += 1;
                        }
                    },
                }
            }
            continue;
        }
        scan.i += 1;
        switch (ch) {
            '[', '{' => depth += 1,
            ']', '}' => {
                depth -= 1;
                if (depth == 1) {
                    // 항목 하나가 끝났다 — 셋이 다 맞으면 담는다.
                    if (is_subagent and is_running and id.len != 0) {
                        if (tally.count < out.len) {
                            out[tally.count] = id;
                            tally.count += 1;
                        } else {
                            tally.truncated = true;
                        }
                    }
                    id = "";
                    is_subagent = false;
                    is_running = false;
                    pending = .none;
                }
                if (depth == 0) return tally;
            },
            else => {},
        }
    }
    return .{ .malformed = true };
}

fn kindFromName(name: []const u8) Kind {
    const table = .{
        .{ "SessionStart", Kind.session_start },
        .{ "UserPromptSubmit", Kind.user_prompt_submit },
        .{ "Stop", Kind.stop },
        .{ "StopFailure", Kind.stop_failure },
        .{ "SubagentStart", Kind.subagent_start },
        .{ "SubagentStop", Kind.subagent_stop },
        .{ "PermissionRequest", Kind.permission_request },
        .{ "PreToolUse", Kind.pre_tool_use },
        .{ "Notification", Kind.notification },
        .{ oversized_marker, Kind.oversized },
    };
    inline for (table) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return entry[1];
    }
    return .unknown;
}

/// 로그 한 줄을 이벤트로 읽는다. **손상된 줄은 조용히 `null`** 이다 — 동시 append로 섞이거나 상한에 잘린 줄이
/// 정상적으로 생길 수 있고(계약 §4), 그때 파서가 죽으면 그 뒤 모든 이벤트를 잃는다.
pub fn parseLine(line: []const u8) ?Event {
    const sep = std.mem.indexOfScalar(u8, line, field_separator) orelse return null;
    const provider = line[0..sep];
    if (provider.len == 0) return null;
    const json = std.mem.trim(u8, line[sep + 1 ..], " \r\n");
    if (json.len < 2 or json[0] != '{') return null;

    var ev: Event = .{ .provider = provider };
    var scan: Scanner = .{ .src = json };
    if (!scan.expectObjectStart()) return null;

    var saw_event_name = false;
    while (scan.nextKey()) |key| {
        if (std.mem.eql(u8, key, "hook_event_name")) {
            const v = scan.stringValue() orelse return null;
            ev.kind = kindFromName(v);
            saw_event_name = true;
        } else if (std.mem.eql(u8, key, "session_id")) {
            ev.session_id = scan.stringValue() orelse return null;
        } else if (std.mem.eql(u8, key, "transcript_path")) {
            ev.transcript_path = scan.stringValue() orelse return null;
        } else if (std.mem.eql(u8, key, "cwd")) {
            ev.cwd = scan.stringValue() orelse return null;
        } else if (std.mem.eql(u8, key, "prompt_id") or std.mem.eql(u8, key, "turn_id")) {
            ev.turn_key = scan.stringValue() orelse return null;
        } else if (std.mem.eql(u8, key, "tool_name")) {
            ev.tool_name = scan.stringValue() orelse return null;
        } else if (std.mem.eql(u8, key, "agent_id")) {
            ev.agent_id = scan.stringValue() orelse return null;
        } else if (std.mem.eql(u8, key, "source")) {
            ev.source = scan.stringValue() orelse return null;
        } else if (std.mem.eql(u8, key, "prompt") or std.mem.eql(u8, key, "last_assistant_message")) {
            ev.text = scan.stringValue() orelse return null;
        } else if (std.mem.eql(u8, key, "stop_hook_active")) {
            ev.stop_hook_active = scan.boolValue() orelse return null;
        } else if (std.mem.eql(u8, key, "message")) {
            ev.notice_text = scan.stringValue() orelse return null;
        } else if (std.mem.eql(u8, key, "notification_type")) {
            const name = scan.stringValue() orelse return null;
            ev.notification_type = notificationKindOf(name);
        } else if (std.mem.eql(u8, key, "background_tasks")) {
            // **원문 슬라이스만** 잡는다 — 이 목록의 유일한 쓰임은 «도는 자식을 거두는» 것이고(계약 §2),
            // 그 판정은 `liveSubagentIds` 가 `type` 까지 보며 따로 한다. 예전엔 여기서 «running 인 것의
            // 수» 를 함께 세어 그것으로 배지를 붙잡았는데, 그 셈은 `type` 을 안 가려 **셸 백그라운드
            // 작업까지** 붙잡았고 그것을 푸는 이벤트가 없어 알림이 영영 안 나갔다.
            const raw_start = scan.i;
            if (!scan.skipValue()) return null;
            if (scan.i > raw_start) ev.background_tasks_raw = std.mem.trim(u8, scan.src[raw_start..scan.i], " \t\r\n");
        } else if (std.mem.eql(u8, key, "tool_input")) {
            // 중첩 객체 안에서도 **키 위치**만 본다. 값 안에 같은 단어가 있어도 걸리지 않는다.
            if (!scan.expectObjectStart()) {
                // 객체가 아니면(형이 바뀌었다) 값을 통째로 건너뛴다 — `expectObjectStart` 는 실패해도
                // 커서를 옮기지 않으므로 그 값이 그대로 남아 있다.
                if (!scan.skipValue()) return null;
                continue;
            }
            while (scan.nextKey()) |inner| {
                if (std.mem.eql(u8, inner, "file_path")) {
                    ev.file_path = scan.stringValue() orelse return null;
                } else if (std.mem.eql(u8, inner, "description")) {
                    ev.tool_description = scan.stringValue() orelse return null;
                } else if (std.mem.eql(u8, inner, "command")) {
                    ev.tool_command = scan.stringValue() orelse return null;
                } else if (!scan.skipValue()) return null;
            }
            if (scan.failed) return null;
        } else if (!scan.skipValue()) return null;
    }
    if (scan.failed) return null;
    if (!saw_event_name) return null;
    return ev;
}

/// Codex `apply_patch` 의 패치 텍스트에서 **바뀌는 파일 경로**를 훑는다.
///
/// **왜 필요한가**: Claude 는 `tool_input.file_path` 로 경로를 직접 주지만, **Codex 는 주지 않는다** —
/// `tool_input` 이 `command` 하나뿐이고 그 안에 패치 전체가 들어 있다(실측 2026-08-20). 그래서 AI 소행
/// 확정이 Codex 에서 통째로 비었다.
///
/// 패치 형식은 실측한 모양 그대로다:
/// ```text
/// *** Begin Patch
/// *** Update File: /abs/path.txt
/// @@
/// -alpha
/// +beta
/// *** End Patch
/// ```
/// **한 패치에 파일이 여럿일 수 있으므로 이터레이터**다 — 첫 경로만 집으면 나머지가 조용히 빠진다.
/// 입력은 JSON 문자열 원문이라 줄바꿈이 `\n`(두 글자)로 이스케이프돼 있고, 그 상태 그대로 훑는다.
pub const PatchPaths = struct {
    rest: []const u8,

    const markers = [_][]const u8{ "*** Update File: ", "*** Add File: ", "*** Delete File: " };

    pub fn next(self: *PatchPaths) ?[]const u8 {
        while (self.rest.len > 0) {
            var best: ?usize = null;
            var best_len: usize = 0;
            for (markers) |m| {
                var from: usize = 0;
                // **줄 시작의 표식만 인정한다.** 패치 *본문*에도 같은 글자가 들어올 수 있다 — 이 표식을
                // 설명하는 문서를 편집하면 그 줄이 `+*** Update File: …` 로 패치에 실린다. 줄 위치를 안 보면
                // 그 가짜 경로가 «AI 가 고친 파일» 로 둔갑한다.
                while (std.mem.indexOfPos(u8, self.rest, from, m)) |at| {
                    if (isLineStart(self.rest, at)) {
                        if (best == null or at < best.?) {
                            best = at;
                            best_len = m.len;
                        }
                        break;
                    }
                    from = at + 1;
                }
            }
            const at = best orelse return null;
            const from_path = at + best_len;
            self.rest = self.rest[from_path..];
            // 경로는 다음 줄 경계까지다. payload 안에서 줄바꿈은 `\n` 두 글자로 이스케이프돼 있다.
            const end = std.mem.indexOf(u8, self.rest, "\\n") orelse self.rest.len;
            const path = self.rest[0..end];
            self.rest = self.rest[@min(end + 2, self.rest.len)..];
            if (path.len > 0) return path;
        }
        return null;
    }

    /// 이 위치가 줄의 처음인가 — 문자열의 시작이거나 바로 앞이 이스케이프된 줄바꿈(`\n`, 두 글자)인가.
    fn isLineStart(text: []const u8, at: usize) bool {
        if (at == 0) return true;
        if (at < 2) return false;
        return text[at - 2] == '\\' and text[at - 1] == 'n';
    }
};

/// 이 이벤트가 만지는 경로를 훑는다. Claude 는 `file_path` 하나를, Codex 는 패치 텍스트의 여러 경로를 준다.
pub fn patchPaths(ev: Event) PatchPaths {
    return .{ .rest = ev.tool_command };
}

/// 손상된 줄 안에서 **온전한 이벤트를 다시 찾는다**(재동기화).
///
/// **왜 필요한가**: 동시 append 는 간헐적으로 줄을 섞는다(실측 2026-08-20 — 24개 동시 쓰기에서 회차마다
/// 0~2줄, 같은 조건에서도 결과가 갈렸다). `printf` 가 큰 출력을 여러 write 로 쪼개면 O_APPEND 는 각 write 의
/// 오프셋만 원자적으로 잡아 주기 때문이다. 그때 섞인 줄은 보통 «A의 앞부분 + **B 전체** + A의 뒷부분» 모양이라,
/// 버리기만 하면 **멀쩡한 B까지 함께 잃는다**. 계약이 "이벤트를 조용히 없애지 않는다"를 요구하므로 건진다.
///
/// 줄 앞부터 파싱해 보고, 실패하면 다음 «`구분자` + `{`» 자리부터 다시 시도한다. 시도 횟수를 묶어 둬서
/// 손상 줄 하나가 파싱 비용을 무한히 끌지 않게 한다.
pub const Resynced = struct {
    event: Event,
    /// 줄 앞에서 바로 읽히지 않고 **안쪽에서 건진** 것인가. 호출자가 세기만 하고 내용은 남기지 않는다(§7).
    recovered: bool,
};

pub fn parseLineResync(line: []const u8) ?Resynced {
    if (parseLine(line)) |ev| return .{ .event = ev, .recovered = false };
    // **인덱스로 훑는다**(포인터 산술이 아니라). 슬라이스 주소 차이로 위치를 되짚는 방식은 맞더라도
    // 읽는 사람이 검산해야 하고, 여기서 필요한 것은 «다음 후보의 시작 위치» 하나뿐이다.
    var from: usize = 0;
    var attempts: usize = 0;
    while (attempts < max_resync_attempts) : (attempts += 1) {
        const sep_rel = std.mem.indexOfScalar(u8, line[from..], field_separator) orelse return null;
        const sep = from + sep_rel;
        from = sep + 1;
        if (from >= line.len or line[from] != '{') continue;
        // 이 구분자 앞의 토큰을 되짚는다. **provider 글자만 따라간다** — 이전 구분자까지 거슬러 가면 A의
        // payload 꼬리를 통째로 토큰으로 삼게 되고, 그러면 멀쩡한 B도 «모양이 아니다»라며 버린다.
        var start = sep;
        while (start > 0 and sep - start < max_provider_len and isProviderChar(line[start - 1])) start -= 1;
        if (!looksLikeProvider(line[start..sep])) continue;
        if (parseLine(line[start..])) |ev| {
            var recovered_ev = ev;
            // **섞인 줄에서는 발신자를 확신할 수 없다.** 이 토큰은 A의 payload 꼬리에 B의 이름이 붙은
            // 조각일 수 있다(실측한 인터리브가 정확히 그 모양이었다). provider 를 그대로 실으면 «누가
            // 보냈는지 틀린» 이벤트가 상태·소행에 섞이므로, 모른다고 말한다 — `recovered` 가 그 사실을
            // 알리고, 소비자는 파일 컨텍스트(파일당 pane 하나)에서 필요한 만큼 메운다.
            recovered_ev.provider = "";
            return .{ .event = recovered_ev, .recovered = true };
        }
    }
    return null;
}

/// 손상 줄 하나에서 재동기화를 시도할 횟수.
///
/// **4는 실측이 아니라 판단이다.** 실측한 것은 «섞임이 일어난다»와 «간헐적이다»까지이고, 한 줄에 몇 겹이
/// 겹치는지는 재현이 안 돼 세지 못했다. 관측된 모양은 모두 한 겹(A 사이에 B 하나)이었고, 겹이 깊어질수록
/// 그 줄에서 건질 값어치도 떨어진다. 상한이 없으면 병리적인 줄 하나가 tick 을 붙잡으므로 작게 잡는다.
pub const max_resync_attempts: usize = 4;

/// provider 토큰의 최대 길이. 이름은 `claude`·`codex` 처럼 짧고, 상한이 있어야 손상 줄에서 긴 쓰레기가
/// 토큰으로 인정되지 않는다.
pub const max_provider_len: usize = 16;

fn isProviderChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-';
}

/// 토큰이 provider 이름 모양인가 — 비어 있지 않고, 짧고, 소문자·숫자·하이픈뿐인가.
///
/// 커맨드 빌더도 같은 규칙으로 입력을 검증한다 — 두 곳이 다른 기준을 쓰면 «훅은 적었는데 파서는 못 읽는»
/// 이름이 생긴다.
pub fn looksLikeProvider(token: []const u8) bool {
    if (token.len == 0 or token.len > max_provider_len) return false;
    for (token) |c| {
        if (!isProviderChar(c)) return false;
    }
    return true;
}

/// JSON 문자열 이스케이프를 풀어 `out`에 담는다(표시 직전에만 쓴다). 담을 수 있는 만큼만 담고 자른다 —
/// 사이드바 한 줄에 들어갈 분량이면 충분하고, 여기서 할당하지 않기 위해서다.
/// `\uXXXX`는 **대체 문자 하나로** 접는다: 이 자리에 필요한 것은 사람이 읽을 한 줄이지 정확한 코드포인트 복원이
/// 아니고, surrogate pair까지 다루면 파서가 이 모듈의 목적보다 커진다.
///
/// ⚠️ **`out`이 꽉 차면 글자 중간에서 끊는다.** 결과를 사람에게 보이는 자리는 **호출자가** 경계를 물려야 한다
/// (`agent_transcript.trimToCharBoundary`) — 받는 쪽의 `clampUtf8`은 «상한을 **넘을** 때만» 자르므로 길이가
/// 정확히 상한인 이 슬라이스를 손대지 않는다. 512바이트면 한글 170자 + 2바이트라 실제로 자주 걸린다.
pub fn decodeInto(out: []u8, raw: []const u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < raw.len and n < out.len) {
        const c = raw[i];
        if (c != '\\') {
            out[n] = c;
            n += 1;
            i += 1;
            continue;
        }
        if (i + 1 >= raw.len) break;
        const esc = raw[i + 1];
        i += 2;
        const mapped: u8 = switch (esc) {
            'n' => '\n',
            't' => '\t',
            'r' => '\r',
            'b' => 8,
            'f' => 12,
            '"' => '"',
            '\\' => '\\',
            '/' => '/',
            'u' => blk: {
                i = @min(i + 4, raw.len); // 코드포인트는 건너뛰고 자리만 지킨다
                break :blk '?';
            },
            else => esc,
        };
        out[n] = mapped;
        n += 1;
    }
    return out[0..n];
}

/// 로그 파일 하나의 tail 소비 상태. **오프셋만 든다** — 버퍼는 호출자가 소유한다(플랫폼이 읽어 넘긴다).
pub const Cursor = struct {
    /// 다음에 읽기 시작할 바이트 위치.
    offset: u64 = 0,

    pub const Batch = struct {
        /// 이번에 채운 이벤트 수.
        count: usize,
        /// 이번에 읽어 낸 바이트 수(마지막 **완결된 줄**까지만).
        ///
        /// **커서는 이미 이만큼 전진했다.** 이 값으로 `cursor.offset` 을 또 더하면 두 번 전진해 그 구간을
        /// 통째로 건너뛴다. 이 값이 필요한 곳은 «넘긴 chunk 에서 남은 부분이 어디부터인가» 하나다.
        advanced: usize,
        /// 상한에 걸려 버린 줄 수. 0이 아니면 관측에 센다(내용은 남기지 않는다 — 계약 §7).
        dropped: usize,
        /// 섞인 줄에서 재동기화로 건진 이벤트 수(§동시 append). 0이 아니면 그 파일에 인터리브가 있었다는 뜻이다.
        recovered: usize,
        /// 상한(`max_events_per_tick`)에 걸려 남은 줄이 있다. 다음 tick이 이어 읽는다.
        more: bool,
    };

    /// `chunk`(파일의 `offset` 이후 바이트)에서 완결된 줄만 뽑아 `out`에 채운다.
    ///
    /// **호출자가 지켜야 할 것 둘.**
    /// 1. `out` 에 담긴 `Event` 의 문자열은 **`chunk` 를 빌린다**(할당하지 않는다). 그 버퍼를 다음 읽기에
    ///    재사용하려면 **이번 tick 안에 필요한 값을 옮겨 담아라** — 안 그러면 다음 tick 이 그 위를 덮는다.
    /// 2. 파일이 회전했는지는 `resetIfRotated` 로 **먼저** 판정하라. 회전한 파일을 옛 오프셋으로 읽으면
    ///    엉뚱한 지점부터 파싱한다.
    ///
    /// **마지막 줄에 개행이 없으면 그 줄은 남긴다.** 훅이 쓰는 중일 수 있고, 반쪽 줄을 파싱하면 정상 이벤트를
    /// 손상으로 오인해 버린다. 그 줄은 다음 tick에 완결된 채로 다시 온다(오프셋을 전진시키지 않았으므로).
    pub fn take(self: *Cursor, chunk: []const u8, out: []Event) Batch {
        // **빈 `out` 은 진전을 만들지 못한다.** 호출자가 `more` 를 보고 반복하는 흔한 모양에서 그대로
        // 무한 루프가 된다(한 줄도 담지 못하니 오프셋이 안 움직이고, 남은 개행이 있으니 `more` 는 계속 참이다).
        // 호출자의 실수를 여기서 멈춘다.
        std.debug.assert(out.len > 0);
        var count: usize = 0;
        var dropped: usize = 0;
        var recovered: usize = 0;
        var consumed: usize = 0;
        const limit = @min(out.len, max_events_per_tick);
        var rest = chunk;
        while (rest.len > 0) {
            const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse break;
            const line = rest[0..nl];
            const advance = nl + 1;
            if (count == limit) break;
            rest = rest[advance..];
            consumed += advance;
            if (line.len == 0) continue; // 빈 줄은 정상이다(훅이 상한 처리로 남길 수 있다)
            if (line.len > max_line_bytes) {
                dropped += 1;
                continue;
            }
            if (parseLineResync(line)) |r| {
                out[count] = r.event;
                count += 1;
                if (r.recovered) recovered += 1;
            } else {
                dropped += 1;
            }
        }
        self.offset += consumed;
        return .{
            .count = count,
            .advanced = consumed,
            .dropped = dropped,
            .recovered = recovered,
            .more = std.mem.indexOfScalar(u8, rest, '\n') != null,
        };
    }

    /// 파일이 회전(rename 후 새로 생성)됐으면 오프셋을 되돌린다.
    ///
    /// **크기만으로는 부족하다.** 회전 직후 훅이 몰아치면 새 파일이 옛 오프셋보다 이미 커져 있을 수 있고,
    /// 그러면 «줄어들지 않았으니 같은 파일»로 오인해 **앞부분을 통째로 건너뛴다**(그만큼 이벤트를 잃는다).
    /// 그래서 파일 **아이덴티티**(platform이 보는 inode·생성 시각 등)가 바뀌었는지를 함께 받는다 —
    /// 판정 재료는 platform이 모으고, 그것으로 무엇을 할지는 이 순수 층이 정한다.
    pub fn resetIfRotated(self: *Cursor, file_size: u64, same_file: bool) bool {
        if (same_file and file_size >= self.offset) return false;
        self.offset = 0;
        return true;
    }
};

// ─── 최소 JSON 스캐너 ────────────────────────────────────────────────────────
// 목적은 «키를 정확한 깊이에서 찾고 나머지는 건너뛰기»다. 숫자·null의 값 형태는 검증하지 않는다 —
// 우리가 읽는 것은 문자열·불리언·배열의 빈 여부뿐이고, 나머지는 건너뛰기만 하면 된다.

const Scanner = struct {
    src: []const u8,
    i: usize = 0,
    failed: bool = false,

    fn skipWs(self: *Scanner) void {
        while (self.i < self.src.len) : (self.i += 1) {
            switch (self.src[self.i]) {
                ' ', '\t', '\r', '\n' => {},
                else => return,
            }
        }
    }

    fn peek(self: *Scanner) ?u8 {
        self.skipWs();
        if (self.i >= self.src.len) return null;
        return self.src[self.i];
    }

    fn expectObjectStart(self: *Scanner) bool {
        const c = self.peek() orelse return false;
        if (c != '{') return false;
        self.i += 1;
        return true;
    }

    /// 현재 객체의 다음 키를 돌려준다(객체가 닫히면 `null`). 값은 호출자가 읽거나 건너뛴다.
    ///
    /// **깊이는 인자로 받지 않는다.** 중첩 진입은 호출자가 `expectObjectStart` 로 명시하고 그 객체가 닫힐
    /// 때까지 도는 구조라, 깊이를 넘겨받아도 쓸 데가 없다. 예전에는 `depth` 를 받아 버렸는데(`_ = depth`),
    /// 읽는 사람에게 «깊이 검증이 있다»는 **거짓 신호**만 줬다.
    fn nextKey(self: *Scanner) ?[]const u8 {
        if (self.failed) return null;
        var c = self.peek() orelse {
            self.failed = true;
            return null;
        };
        if (c == ',') {
            self.i += 1;
            c = self.peek() orelse {
                self.failed = true;
                return null;
            };
        }
        if (c == '}') {
            self.i += 1;
            return null;
        }
        const key = self.rawString() orelse {
            self.failed = true;
            return null;
        };
        const colon = self.peek() orelse {
            self.failed = true;
            return null;
        };
        if (colon != ':') {
            self.failed = true;
            return null;
        }
        self.i += 1;
        return key;
    }

    /// 따옴표 안의 **원문**(이스케이프 미해제)을 돌려주고 커서를 닫는 따옴표 뒤로 옮긴다.
    fn rawString(self: *Scanner) ?[]const u8 {
        const c = self.peek() orelse return null;
        if (c != '"') return null;
        self.i += 1;
        const start = self.i;
        while (self.i < self.src.len) {
            const ch = self.src[self.i];
            if (ch == '\\') {
                // 이스케이프는 두 바이트를 통째로 건너뛴다 — `\"`가 문자열을 닫는 것으로 오인되지 않게.
                self.i += 2;
                continue;
            }
            if (ch == '"') {
                const out = self.src[start..self.i];
                self.i += 1;
                return out;
            }
            self.i += 1;
        }
        return null;
    }

    fn stringValue(self: *Scanner) ?[]const u8 {
        const v = self.rawString();
        if (v == null) self.failed = true;
        return v;
    }

    fn boolValue(self: *Scanner) ?bool {
        const c = self.peek() orelse {
            self.failed = true;
            return null;
        };
        if (c == 't' and self.remaining() >= 4) {
            self.i += 4;
            return true;
        }
        if (c == 'f' and self.remaining() >= 5) {
            self.i += 5;
            return false;
        }
        // 불리언이 아니면 값을 건너뛰고 «없음»으로 본다(형이 바뀌어도 줄 전체를 잃지 않게).
        if (!self.skipValue()) {
            self.failed = true;
            return null;
        }
        return false;
    }

    /// 배열 값을 건너뛰면서 **비어 있지 않은지**만 답한다.
    fn nonEmptyArrayValue(self: *Scanner) ?bool {
        const c = self.peek() orelse {
            self.failed = true;
            return null;
        };
        if (c != '[') {
            if (!self.skipValue()) {
                self.failed = true;
                return null;
            }
            return false;
        }
        self.i += 1;
        const inner = self.peek() orelse {
            self.failed = true;
            return null;
        };
        if (inner == ']') {
            self.i += 1;
            return false;
        }
        // 비어 있지 않다 — 나머지는 건너뛴다.
        var depth: usize = 1;
        while (self.i < self.src.len) {
            const ch = self.src[self.i];
            if (ch == '"') {
                _ = self.rawString() orelse {
                    self.failed = true;
                    return null;
                };
                continue;
            }
            self.i += 1;
            if (ch == '[' or ch == '{') depth += 1;
            if (ch == ']' or ch == '}') {
                depth -= 1;
                if (depth == 0) return true;
            }
        }
        self.failed = true;
        return null;
    }

    fn remaining(self: *Scanner) usize {
        return self.src.len - self.i;
    }

    /// 다음 값 하나를 통째로 건너뛴다(문자열·객체·배열·그 밖).
    fn skipValue(self: *Scanner) bool {
        const c = self.peek() orelse return false;
        return self.skipValueWith(c);
    }

    fn skipValueWith(self: *Scanner, c: u8) bool {
        if (c == '"') {
            return self.rawString() != null;
        }
        if (c == '{' or c == '[') {
            var depth: usize = 0;
            while (self.i < self.src.len) {
                const ch = self.src[self.i];
                if (ch == '"') {
                    _ = self.rawString() orelse return false;
                    continue;
                }
                self.i += 1;
                if (ch == '{' or ch == '[') depth += 1;
                if (ch == '}' or ch == ']') {
                    depth -= 1;
                    if (depth == 0) return true;
                }
            }
            return false;
        }
        // 숫자·true·false·null: 구분자 전까지 먹는다.
        while (self.i < self.src.len) : (self.i += 1) {
            switch (self.src[self.i]) {
                ',', '}', ']' => return true,
                else => {},
            }
        }
        return false;
    }
};

const testing = std.testing;

test "실측 payload 모양을 그대로 읽는다 — SessionStart" {
    // 2026-08-20 실측(Claude, 격리 설정 + 헤드리스 1회)에서 회수한 필드 구성이다.
    const line = "claude\t{\"session_id\":\"9efa0c23\",\"transcript_path\":\"/x/y.jsonl\",\"cwd\":\"/w\"," ++
        "\"hook_event_name\":\"SessionStart\",\"source\":\"startup\"}";
    const ev = parseLine(line).?;
    try testing.expectEqualStrings("claude", ev.provider);
    try testing.expectEqual(Kind.session_start, ev.kind);
    try testing.expectEqualStrings("9efa0c23", ev.session_id);
    try testing.expectEqualStrings("/x/y.jsonl", ev.transcript_path);
    // **작업 디렉터리도 뽑는다.** 픽스처에는 예전부터 있었는데 단언이 없어, 필드만 있고 추출을 안 해도
    // 아무도 몰랐다. 이 값은 원격 pane 에서 OSC 7 이 멈춘 구간을 메운다(ssh-integration.md §9.5).
    try testing.expectEqualStrings("/w", ev.cwd);
    try testing.expectEqualStrings("startup", ev.source);
}

test "Stop의 재진입 가드와 background_tasks 원문을 읽는다" {
    // `stop_hook_active`가 참이면 턴 종료가 아니다. `background_tasks`는 **세지 않고 원문만** 잡는다 —
    // 그 목록의 유일한 쓰임은 «도는 자식을 거두는» 것이고, 판정은 `liveSubagentIds`가 `type`까지 보며
    // 따로 한다(계약 §2).
    const busy = "codex\t{\"hook_event_name\":\"Stop\",\"prompt_id\":\"p1\"," ++
        "\"background_tasks\":[{\"id\":\"bc3k\",\"status\":\"running\"}]," ++
        "\"stop_hook_active\":false,\"last_assistant_message\":\"끝났습니다\"}";
    const ev = parseLine(busy).?;
    try testing.expectEqual(Kind.stop, ev.kind);
    try testing.expectEqualStrings("p1", ev.turn_key);
    try testing.expectEqualStrings("[{\"id\":\"bc3k\",\"status\":\"running\"}]", ev.background_tasks_raw);
    try testing.expect(!ev.stop_hook_active);
    try testing.expectEqualStrings("끝났습니다", ev.text);

    const idle = "codex\t{\"hook_event_name\":\"Stop\",\"background_tasks\":[],\"stop_hook_active\":true}";
    const ev2 = parseLine(idle).?;
    try testing.expectEqualStrings("[]", ev2.background_tasks_raw);
    try testing.expect(ev2.stop_hook_active);
}

test "tool_input 안의 키만 인정한다 — 값에 든 같은 단어에 걸리지 않는다" {
    // 에이전트가 프롬프트에 `file_path`를 언급하는 일은 흔하다. 최상위 문자열 값에 든 그 단어를 경로로 읽으면
    // 고치지도 않은 파일이 «AI 편집»으로 표시된다.
    const line = "claude\t{\"hook_event_name\":\"UserPromptSubmit\"," ++
        "\"prompt\":\"tool_input 의 file_path 를 설명해줘\"}";
    const ev = parseLine(line).?;
    try testing.expectEqual(Kind.user_prompt_submit, ev.kind);
    try testing.expectEqualStrings("", ev.file_path);
    try testing.expectEqualStrings("tool_input 의 file_path 를 설명해줘", ev.text);

    const edit = "claude\t{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Edit\"," ++
        "\"tool_input\":{\"file_path\":\"/repo/src/a.zig\",\"old_string\":\"a\",\"new_string\":\"b\"}}";
    const ev2 = parseLine(edit).?;
    try testing.expectEqualStrings("/repo/src/a.zig", ev2.file_path);
    try testing.expectEqualStrings("Edit", ev2.tool_name);
}

test "PreToolUse(Bash)는 description을 싣고 명령 원문은 배지가 쓰지 않는다" {
    const line = "claude\t{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\"," ++
        "\"tool_input\":{\"command\":\"npm run build\",\"description\":\"빌드 실행\",\"timeout\":120000}}";
    const ev = parseLine(line).?;
    try testing.expectEqualStrings("Bash", ev.tool_name);
    try testing.expectEqualStrings("빌드 실행", ev.tool_description);
    try testing.expectEqualStrings("", ev.file_path); // Bash에는 경로가 없다
}

test "이스케이프된 따옴표가 문자열을 닫지 않는다" {
    // `\"`를 종료로 오인하면 그 뒤 키가 값으로 밀려 이벤트 전체가 어긋난다.
    const line = "claude\t{\"hook_event_name\":\"Stop\",\"last_assistant_message\":\"그는 \\\"네\\\"라고 했다\"," ++
        "\"prompt_id\":\"p9\"}";
    const ev = parseLine(line).?;
    try testing.expectEqualStrings("p9", ev.turn_key);
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("그는 \"네\"라고 했다", decodeInto(&buf, ev.text));
}

test "손상된 줄은 조용히 버린다 — 동시 append로 섞일 수 있다" {
    try testing.expect(parseLine("") == null);
    try testing.expect(parseLine("claude") == null); // 구분자 없음
    try testing.expect(parseLine("\t{}") == null); // provider 없음
    try testing.expect(parseLine("claude\tnot-json") == null);
    try testing.expect(parseLine("claude\t{\"hook_event_name\":\"Stop\"") == null); // 잘림
    try testing.expect(parseLine("claude\t{\"session_id\":\"x\"}") == null); // 이벤트 이름 없음
}

test "모르는 이벤트는 버리지 않고 unknown으로 든다" {
    // 버리면 provider가 이벤트를 늘렸을 때 «아무 일도 없음»과 구분되지 않는다.
    const ev = parseLine("claude\t{\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"Edit\"}").?;
    try testing.expectEqual(Kind.unknown, ev.kind);
    try testing.expectEqualStrings("Edit", ev.tool_name);
}

test "상한을 넘긴 이벤트는 표식으로 남는다 — 조용히 사라지지 않는다" {
    const ev = parseLine("claude\t{\"hook_event_name\":\"" ++ oversized_marker ++ "\"}").?;
    try testing.expectEqual(Kind.oversized, ev.kind);
}

test "커서는 완결된 줄만 소비하고 반쪽 줄을 남긴다" {
    var cur: Cursor = .{};
    var out: [8]Event = undefined;
    const chunk = "claude\t{\"hook_event_name\":\"SessionStart\"}\n" ++
        "claude\t{\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"hi\"}\n" ++
        "claude\t{\"hook_event_name\":\"Sto"; // 훅이 쓰는 중
    const batch = cur.take(chunk, &out);
    try testing.expectEqual(@as(usize, 2), batch.count);
    try testing.expectEqual(@as(usize, 0), batch.dropped);
    try testing.expectEqual(Kind.session_start, out[0].kind);
    try testing.expectEqual(Kind.user_prompt_submit, out[1].kind);
    // 반쪽 줄은 오프셋에 넣지 않는다 — 다음 tick에 완결된 채로 다시 온다.
    const half_len = "claude\t{\"hook_event_name\":\"Sto".len;
    try testing.expectEqual(chunk.len - half_len, batch.advanced);
    try testing.expectEqual(@as(u64, chunk.len - half_len), cur.offset);
}

test "tick당 상한을 지키고 남은 줄을 다음 tick에 넘긴다" {
    var cur: Cursor = .{};
    var out: [2]Event = undefined;
    const one = "claude\t{\"hook_event_name\":\"Stop\"}\n";
    const chunk = one ++ one ++ one ++ one;
    const first = cur.take(chunk, &out);
    try testing.expectEqual(@as(usize, 2), first.count);
    try testing.expect(first.more);
    try testing.expectEqual(@as(u64, one.len * 2), cur.offset);

    const second = cur.take(chunk[first.advanced..], &out);
    try testing.expectEqual(@as(usize, 2), second.count);
    try testing.expect(!second.more);
    try testing.expectEqual(@as(u64, chunk.len), cur.offset);
}

test "긴 줄은 버리고 그 사실을 센다 — 그 줄이 다음 줄을 먹지 않는다" {
    var cur: Cursor = .{};
    var out: [4]Event = undefined;
    var big: [max_line_bytes + 64]u8 = undefined;
    @memset(&big, 'x');
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try buf.appendSlice(testing.allocator, &big);
    try buf.append(testing.allocator, '\n');
    try buf.appendSlice(testing.allocator, "claude\t{\"hook_event_name\":\"Stop\"}\n");

    const batch = cur.take(buf.items, &out);
    try testing.expectEqual(@as(usize, 1), batch.count);
    try testing.expectEqual(@as(usize, 1), batch.dropped);
    try testing.expectEqual(Kind.stop, out[0].kind);
}

test "빈 줄은 손상이 아니다" {
    var cur: Cursor = .{};
    var out: [4]Event = undefined;
    const batch = cur.take("\n\nclaude\t{\"hook_event_name\":\"Stop\"}\n", &out);
    try testing.expectEqual(@as(usize, 1), batch.count);
    try testing.expectEqual(@as(usize, 0), batch.dropped);
}

test "파일이 회전하면 오프셋을 되돌린다 — 크기만 보면 놓친다" {
    var cur: Cursor = .{ .offset = 4096 };
    try testing.expect(!cur.resetIfRotated(4096, true)); // 같은 파일·같은 크기 = 그대로
    try testing.expect(!cur.resetIfRotated(8192, true)); // 같은 파일·자람 = 그대로
    try testing.expect(cur.resetIfRotated(10, true)); // 같은 파일인데 줄었다 = truncate
    try testing.expectEqual(@as(u64, 0), cur.offset);

    // **크기만 보는 판정이 놓치는 경우**: 회전 직후 훅이 몰아쳐 새 파일이 옛 오프셋보다 이미 크다.
    // 아이덴티티를 안 보면 «자랐으니 같은 파일»로 오인해 앞부분을 건너뛴다.
    var busy: Cursor = .{ .offset = 4096 };
    try testing.expect(busy.resetIfRotated(9000, false));
    try testing.expectEqual(@as(u64, 0), busy.offset);
}

test "decodeInto는 담을 수 있는 만큼만 담는다" {
    var buf: [4]u8 = undefined;
    try testing.expectEqualStrings("abcd", decodeInto(&buf, "abcdefgh"));
    var nl: [8]u8 = undefined;
    try testing.expectEqualStrings("a\nb", decodeInto(&nl, "a\\nb"));
    var uni: [8]u8 = undefined;
    try testing.expectEqualStrings("a?b", decodeInto(&uni, "a\\u0041b")); // 코드포인트는 자리만 지킨다
}

test "섞인 줄 안의 온전한 이벤트를 건진다 — 버리면 멀쩡한 것까지 잃는다" {
    // 실측한 인터리브 모양: A의 앞부분이 나가다 B가 통째로 끼어들고 A의 뒷부분이 이어진다.
    // 앞에서부터 읽으면 A가 깨져 실패하지만, 그 안의 B는 멀쩡하다.
    const mixed = "claude\t{\"hook_event_name\":\"PreToolUse\",\"pad\":\"aaa" ++
        "claude\t{\"hook_event_name\":\"Stop\",\"prompt_id\":\"p-inner\"}";
    try testing.expect(parseLine(mixed) == null); // 앞부터는 못 읽는다
    const r = parseLineResync(mixed).?; // 안쪽 B는 건진다
    try testing.expect(r.recovered);
    try testing.expectEqual(Kind.stop, r.event.kind);
    try testing.expectEqualStrings("p-inner", r.event.turn_key);
    // **발신자는 비운다** — 이 토큰은 A의 payload 꼬리에 B의 이름이 붙은 조각일 수 있다.
    try testing.expectEqualStrings("", r.event.provider);

    // 멀쩡한 줄은 «건졌다»로 세지 않는다 — 그 수가 인터리브의 신호이기 때문이다.
    const clean = parseLineResync("claude\t{\"hook_event_name\":\"Stop\"}").?;
    try testing.expect(!clean.recovered);
}

test "재동기화 시도 상한이 실제로 멈춘다" {
    // **상한이 없어도 통과하는 테스트는 상한을 검증하지 못한다.** 그래서 «상한 너머에 멀쩡한 이벤트를 두고
    // 그것을 못 찾는지»로 본다 — 상한을 지우면 이 단언이 깨진다(뮤테이션 가능).
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try buf.appendSlice(testing.allocator, "claude\t{broken");
    // 시도 상한보다 많은 «구분자만 있는» 후보를 깔아 시도를 소진시킨다.
    for (0..max_resync_attempts + 2) |_| try buf.appendSlice(testing.allocator, "\tnope");
    // 그 너머에 멀쩡한 이벤트가 있어도 도달하지 못해야 한다.
    try buf.appendSlice(testing.allocator, "\tclaude\t{\"hook_event_name\":\"Stop\"}");
    try testing.expect(parseLineResync(buf.items) == null);

    // 같은 이벤트가 **상한 안**에 있으면 건진다 — 위 실패가 «상한 때문»임을 이 대조가 증명한다.
    var near: std.ArrayListUnmanaged(u8) = .empty;
    defer near.deinit(testing.allocator);
    try near.appendSlice(testing.allocator, "claude\t{broken\tclaude\t{\"hook_event_name\":\"Stop\"}");
    try testing.expect(parseLineResync(near.items) != null);
}

test "손상 조각을 provider 로 인정하지 않는다" {
    // 재동기화는 쓰레기 바이트 위를 걷는다. 토큰 검증이 없으면 «누가 보냈는지 틀린» 이벤트가 만들어지고,
    // 그건 버리는 것보다 나쁘다(상태·소행에 섞인다).
    // 토큰이 «모양은 맞는» 조각이면 이벤트는 건지되 **발신자는 비운다** — 이벤트 자체는 진짜이고,
    // 그 이름이 A의 꼬리에서 잘려 나온 것인지 B의 진짜 이름인지 구분할 방법이 없기 때문이다.
    const bogus = "claude\t{aaa\u{7f}\u{7f}bad name\t{\"hook_event_name\":\"Stop\"}";
    const salvaged = parseLineResync(bogus).?;
    try testing.expect(salvaged.recovered);
    try testing.expectEqual(Kind.stop, salvaged.event.kind);
    try testing.expectEqualStrings("", salvaged.event.provider);

    // 구분자 앞이 provider 글자가 아니면 토큰이 비고, 그때는 건지지 않는다 — 되짚기가 «어디부터가 이름인지»
    // 를 못 정하는 자리다.
    try testing.expect(parseLineResync("claude\t{x }\t{\"hook_event_name\":\"Stop\"}") == null);

    // 앞에서부터 멀쩡히 읽힌 줄은 발신자를 그대로 싣는다(재동기화가 아니므로 확신할 수 있다).
    const straight = parseLineResync("codex\t{\"hook_event_name\":\"Stop\"}").?;
    try testing.expect(!straight.recovered);
    try testing.expectEqualStrings("codex", straight.event.provider);

    // 정상 provider 이름은 그대로 통과한다.
    try testing.expect(looksLikeProvider("claude"));
    try testing.expect(looksLikeProvider("codex"));
    try testing.expect(looksLikeProvider("mimo-code"));
    try testing.expect(!looksLikeProvider(""));
    try testing.expect(!looksLikeProvider("Claude")); // 대문자는 우리 표기가 아니다
}

test "커서가 건진 이벤트를 세고 그 사실을 알린다" {
    var cur: Cursor = .{};
    var out: [4]Event = undefined;
    const mixed = "claude\t{\"hook_event_name\":\"PreToolUse\",\"pad\":\"aaa" ++
        "claude\t{\"hook_event_name\":\"Stop\"}\n";
    const clean = "claude\t{\"hook_event_name\":\"SessionStart\"}\n";
    const batch = cur.take(mixed ++ clean, &out);
    try testing.expectEqual(@as(usize, 2), batch.count);
    try testing.expectEqual(@as(usize, 1), batch.recovered);
    try testing.expectEqual(@as(usize, 0), batch.dropped);
}

test "Codex apply_patch 의 경로를 패치 텍스트에서 훑는다 — 그쪽엔 file_path 가 없다" {
    // 실측(2026-08-20, 격리 CODEX_HOME): Codex `PreToolUse.tool_input` 은 `command` 하나뿐이고
    // 경로는 그 안의 `*** Update File: …` 줄에 있다. Claude 처럼 `file_path` 를 기대하면 통째로 빈다.
    const line = "codex\t{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"apply_patch\"," ++
        "\"tool_input\":{\"command\":\"*** Begin Patch\\n*** Update File: /repo/a.txt\\n@@\\n-alpha\\n+beta\\n*** End Patch\"}}";
    const ev = parseLine(line).?;
    try testing.expectEqualStrings("apply_patch", ev.tool_name);
    try testing.expectEqualStrings("", ev.file_path); // Codex 는 이 필드를 주지 않는다
    var it = patchPaths(ev);
    try testing.expectEqualStrings("/repo/a.txt", it.next().?);
    try testing.expect(it.next() == null);
}

test "한 패치에 파일이 여럿이면 모두 훑는다 — 첫 경로만 집으면 나머지가 조용히 빠진다" {
    const line = "codex\t{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"apply_patch\"," ++
        "\"tool_input\":{\"command\":\"*** Begin Patch\\n*** Update File: /repo/a.zig\\n@@\\n-x\\n+y\\n" ++
        "*** Add File: /repo/b.md\\n+new\\n*** Delete File: /repo/c.txt\\n*** End Patch\"}}";
    const ev = parseLine(line).?;
    var it = patchPaths(ev);
    try testing.expectEqualStrings("/repo/a.zig", it.next().?);
    try testing.expectEqualStrings("/repo/b.md", it.next().?);
    try testing.expectEqualStrings("/repo/c.txt", it.next().?);
    try testing.expect(it.next() == null);
}

test "셸 도구의 command 는 경로를 내지 않는다 — 그 안의 파일 변경은 훅이 못 본다" {
    const line = "codex\t{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\"," ++
        "\"tool_input\":{\"command\":\"sed -i '' s/alpha/gamma/ /repo/d.txt\"}}";
    const ev = parseLine(line).?;
    try testing.expectEqualStrings("sed -i '' s/alpha/gamma/ /repo/d.txt", ev.tool_command);
    var it = patchPaths(ev);
    // 패치 표식이 없으므로 경로가 나오지 않는다 — 계약이 말하는 셸 사각지대가 여기서 드러난다.
    try testing.expect(it.next() == null);
}

test "패치 본문에 든 가짜 표식을 경로로 읽지 않는다" {
    // 이 표식을 설명하는 문서를 편집하면 그 줄이 `+*** Update File: …` 로 패치 본문에 실린다.
    // 줄 위치를 안 보면 그 가짜 경로가 «AI 가 고친 파일» 로 둔갑한다 — 실제로 이 저장소의 계약 문서가
    // 그 문자열을 담고 있다.
    const line = "codex\t{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"apply_patch\"," ++
        "\"tool_input\":{\"command\":\"*** Begin Patch\\n*** Update File: /repo/docs/a.md\\n@@\\n" ++
        "+*** Update File: /etc/passwd\\n+설명 문장\\n*** End Patch\"}}";
    const ev = parseLine(line).?;
    var it = patchPaths(ev);
    try testing.expectEqualStrings("/repo/docs/a.md", it.next().?);
    try testing.expect(it.next() == null); // 본문의 가짜 표식은 세지 않는다
}

test "provider 가 필드의 형을 바꿔도 줄 전체를 잃지 않는다" {
    // 파서에는 «형이 예상과 다르면 그 필드만 포기하고 계속» 하는 분기가 셋 있는데(객체 아닌 `tool_input`,
    // 배열 아닌 `background_tasks`, 불리언 아닌 `stop_hook_active`) 그 방어가 실제로 도는지 본 적이 없었다.
    // provider 가 payload 모양을 바꾸는 일은 실제로 일어나고, 그때 **줄 전체를 잃으면** 그 턴이 통째로 사라진다.

    // `tool_input` 이 객체가 아니다 → 그 필드만 비고 나머지는 읽힌다.
    const not_object = "claude\t{\"hook_event_name\":\"PreToolUse\",\"tool_input\":\"문자열이 왔다\"," ++
        "\"tool_name\":\"Bash\",\"prompt_id\":\"p1\"}";
    const a = parseLine(not_object).?;
    try testing.expectEqual(Kind.pre_tool_use, a.kind);
    try testing.expectEqualStrings("Bash", a.tool_name);
    try testing.expectEqualStrings("p1", a.turn_key);
    try testing.expectEqualStrings("", a.file_path);

    // `background_tasks` 가 배열이 아니다 → «없음» 으로 보고 계속.
    const not_array = "claude\t{\"hook_event_name\":\"Stop\",\"background_tasks\":42,\"prompt_id\":\"p2\"}";
    const b = parseLine(not_array).?;
    // 배열이 아니면 회수 규칙이 그것을 근거로 쓰지 못해야 한다 — `liveSubagentIds` 가 `malformed` 로 답한다.
    {
        var out: [4][]const u8 = undefined;
        try testing.expect(liveSubagentIds(b.background_tasks_raw, &out).malformed);
    }
    try testing.expectEqualStrings("p2", b.turn_key);

    // `stop_hook_active` 가 불리언이 아니다 → 거짓으로 보고 계속(턴 종료를 놓치는 쪽이 아니라 세는 쪽).
    const not_bool = "claude\t{\"hook_event_name\":\"Stop\",\"stop_hook_active\":\"yes\",\"prompt_id\":\"p3\"}";
    const c = parseLine(not_bool).?;
    try testing.expect(!c.stop_hook_active);
    try testing.expectEqualStrings("p3", c.turn_key);

    // 중첩이 더 깊어져도(`tool_input` 안에 객체·배열) 최상위 필드는 그대로 읽힌다.
    const nested = "claude\t{\"hook_event_name\":\"PreToolUse\"," ++
        "\"tool_input\":{\"edits\":[{\"file_path\":\"/deep/a.txt\"}],\"file_path\":\"/top/b.txt\"}," ++
        "\"prompt_id\":\"p4\"}";
    const d = parseLine(nested).?;
    try testing.expectEqualStrings("/top/b.txt", d.file_path); // 한 겹 안의 키만 인정한다
    try testing.expectEqualStrings("p4", d.turn_key);
}

test "빈 out 은 진전을 못 만든다 — more 로 도는 호출자가 무한 루프에 빠진다" {
    // `take` 는 이 경우를 assert 로 멈춘다. 여기서는 그 조건이 실제로 «진전 0 · more 참» 이라는 것을,
    // 즉 막지 않으면 무한 루프가 된다는 것을 고정한다.
    var cur: Cursor = .{};
    var out: [1]Event = undefined;
    const two = "claude\t{\"hook_event_name\":\"Stop\"}\nclaude\t{\"hook_event_name\":\"Stop\"}\n";
    const batch = cur.take(two, &out);
    try testing.expectEqual(@as(usize, 1), batch.count);
    try testing.expect(batch.advanced > 0); // out 이 있으면 반드시 전진한다
    try testing.expect(batch.more);
}

test "회전은 크기로만 판정한다" {
    try testing.expect(!shouldRotate(0));
    try testing.expect(!shouldRotate(rotate_at_bytes - 1));
    try testing.expect(shouldRotate(rotate_at_bytes));
    try testing.expect(shouldRotate(rotate_at_bytes * 4));
}

test "상한은 한 줄보다 충분히 크다 — 한 줄도 못 담으면 회전이 끝나지 않는다" {
    // 상한이 줄 상한보다 작으면, 긴 줄 하나를 적는 순간 넘겨 매 tick 회전하고 그때마다 유실 창이 열린다.
    try testing.expect(rotate_at_bytes > max_line_bytes);
    // tick 당 처리량보다도 커야 한다 — 한 번에 읽을 수 있는 양보다 작으면 읽기 전에 회전한다.
    try testing.expect(rotate_at_bytes >= max_line_bytes * max_events_per_tick / 2);
}

test "회전본 이름은 원본 이름으로 시작한다 — 시작 시 정리가 같이 치운다" {
    // 회전 도중 죽으면 회전본만 남는다. 이름이 우리 것으로 안 보이면 영영 치워지지 않는다.
    try testing.expect(std.mem.startsWith(u8, "7.ndjson" ++ rotated_suffix, "7.ndjson"));
    try testing.expect(rotated_suffix.len > 0);
}

test "셸 백그라운드 작업은 이 목록의 소비자에게 보이지 않는다" {
    // 이 목록을 읽는 곳은 회수 규칙 하나이고, 그것은 **서브에이전트만** 본다(계약 §2). 예전에는 파서가
    // `type` 을 안 가리고 «running 인 것의 수» 를 함께 세어 그것으로 배지를 붙잡았는데, 셸 작업에는 푸는
    // 이벤트가 없어 그 pane 의 완료 알림이 영영 안 나갔다(실측). 그래서 그 셈을 없앴다.
    const line = "claude\t{\"hook_event_name\":\"Stop\",\"background_tasks\":[" ++
        "{\"id\":\"a\",\"type\":\"shell\",\"status\":\"completed\",\"description\":\"빌드\"}," ++
        "{\"id\":\"b\",\"type\":\"shell\",\"status\":\"running\",\"description\":\"테스트\"}," ++
        "{\"id\":\"c\",\"type\":\"shell\",\"status\":\"failed\",\"description\":\"린트\"}]}";
    const ev = parseLine(line).?;
    try testing.expect(ev.background_tasks_raw.len > 0); // 원문은 잡는다(회수가 훑는다)
    var out: [4][]const u8 = undefined;
    const tally = liveSubagentIds(ev.background_tasks_raw, &out);
    try testing.expect(!tally.malformed and !tally.truncated);
    try testing.expectEqual(@as(usize, 0), tally.count); // 셸은 하나도 안 잡힌다

    // 서브에이전트는 그대로 잡힌다 — 그 축은 `SubagentStop` 이라는 푸는 이벤트가 있다.
    const child = "claude\t{\"hook_event_name\":\"Stop\",\"background_tasks\":[" ++
        "{\"id\":\"c1\",\"type\":\"subagent\",\"status\":\"running\"}," ++
        "{\"id\":\"s1\",\"type\":\"shell\",\"status\":\"running\"}]}";
    const child_tally = liveSubagentIds(parseLine(child).?.background_tasks_raw, &out);
    try testing.expectEqual(@as(usize, 1), child_tally.count);
    try testing.expectEqualStrings("c1", out[0]);
}

test "type·status 는 그 항목의 깊이에서만 인정한다 — 값에 든 같은 단어에 안 걸린다" {
    // 설명이나 중첩 객체에 «running»·«subagent» 가 들어 있어도 잡으면 안 된다.
    const line = "claude\t{\"hook_event_name\":\"Stop\",\"background_tasks\":[" ++
        "{\"id\":\"a\",\"type\":\"shell\",\"status\":\"completed\"," ++
        "\"description\":\"status running 이라고 적힌 설명\"," ++
        "\"meta\":{\"type\":\"subagent\",\"status\":\"running\"}}]}";
    var deep: [4][]const u8 = undefined;
    try testing.expectEqual(@as(usize, 0), liveSubagentIds(parseLine(line).?.background_tasks_raw, &deep).count);
}

test "StopFailure 를 안다 — 오류로 끝난 턴이 Stop 대신 온다" {
    const line = "claude\t{\"hook_event_name\":\"StopFailure\",\"session_id\":\"s1\"}";
    const ev = parseLine(line).?;
    try testing.expectEqual(Kind.stop_failure, ev.kind);
    try testing.expectEqualStrings("s1", ev.session_id);
}

test "자식 이벤트는 agent_id 를 싣고 온다 — lead 이벤트는 아니다" {
    // 자식 활동은 `agent_id` 를 실은 이벤트로 따로 온다(계약 §2) — 그것이 있으면 부모 상태에 그대로
    // 섞으면 안 된다.
    const child = "claude\t{\"hook_event_name\":\"PreToolUse\",\"agent_id\":\"child-7\",\"tool_name\":\"Bash\"}";
    const ev = parseLine(child).?;
    try testing.expectEqualStrings("child-7", ev.agent_id);

    // 같은 도구 이벤트라도 lead 가 부른 것에는 그 필드가 없다 — 이 대조가 없으면 «늘 비어 있다» 는
    // 파서로도 위 단언이 통과한다.
    const spawn = "claude\t{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Agent\"," ++
        "\"tool_input\":{\"description\":\"조사\"}}";
    const ev2 = parseLine(spawn).?;
    try testing.expectEqualStrings("조사", ev2.tool_description);
    try testing.expectEqual(@as(usize, 0), ev2.agent_id.len); // lead 이벤트라 자식 식별자가 없다
}

test "liveSubagentIds: 도는 서브에이전트의 id 만 모은다 — 실측 모양 그대로" {
    // 실측(2026-08-21): `type: "subagent"` 항목의 `id` 가 수명 이벤트의 `agent_id` 와 **정확히 같다**.
    // 그 사실이 회수 규칙의 근거다 — 이 목록에 없는데 우리가 붙잡고 있으면 그 자식은 끝난 것이다.
    const raw =
        "[{\"id\":\"ab8b2cd7ddd4dce44\",\"type\":\"subagent\",\"status\":\"running\",\"description\":\"List files\"}," ++
        "{\"id\":\"done-1\",\"type\":\"subagent\",\"status\":\"completed\",\"description\":\"끝남\"}," ++
        "{\"id\":\"sh-1\",\"type\":\"shell\",\"status\":\"running\",\"command\":\"sleep 9\"}]";
    var out: [8][]const u8 = undefined;
    const tally = liveSubagentIds(raw, &out);
    try testing.expect(!tally.truncated and !tally.malformed);
    try testing.expectEqual(@as(usize, 1), tally.count); // 도는 **서브에이전트**만
    try testing.expectEqualStrings("ab8b2cd7ddd4dce44", out[0]);
}

test "liveSubagentIds: 자리가 모자라면 «불완전» 이라고 말한다 — 조용히 자르지 않는다" {
    // 잘린 목록을 «없으니 끝났다» 로 읽으면 **살아 있는 자식을 지운다**. 그래서 자름을 드러낸다.
    const raw =
        "[{\"id\":\"a\",\"type\":\"subagent\",\"status\":\"running\"}," ++
        "{\"id\":\"b\",\"type\":\"subagent\",\"status\":\"running\"}]";
    var one: [1][]const u8 = undefined;
    const tally = liveSubagentIds(raw, &one);
    try testing.expect(tally.truncated);
    try testing.expectEqual(@as(usize, 1), tally.count);
}

test "liveSubagentIds: 모양이 어긋나면 판단 근거로 쓰지 않는다" {
    var out: [4][]const u8 = undefined;
    try testing.expect(liveSubagentIds("{\"not\":\"an array\"}", &out).malformed);
    try testing.expect(liveSubagentIds("[{\"id\":\"a\"", &out).malformed); // 닫히지 않았다
    // 빈 원문은 «목록이 없었다» 이지 «비었다» 가 아니다 — 둘 다 회수하지 않는다.
    const none = liveSubagentIds("", &out);
    try testing.expect(!none.malformed and none.count == 0);
}

test "background_tasks 원문 슬라이스를 잡는다 — 회수 규칙이 그것을 다시 훑는다" {
    const line = "claude\t{\"hook_event_name\":\"Stop\",\"background_tasks\":" ++
        "[{\"id\":\"c1\",\"type\":\"subagent\",\"status\":\"running\"}],\"prompt_id\":\"p1\"}";
    const ev = parseLine(line).?;
    try testing.expect(ev.background_tasks_raw.len != 0);
    var out: [4][]const u8 = undefined;
    const tally = liveSubagentIds(ev.background_tasks_raw, &out);
    try testing.expectEqual(@as(usize, 1), tally.count);
    try testing.expectEqualStrings("c1", out[0]);
    // 그 뒤 키도 정상적으로 읽힌다 — 슬라이스를 잡느라 커서가 어긋나지 않았다.
    try testing.expectEqualStrings("p1", ev.turn_key);
}

test "Notification 의 종류를 읽는다 — 아는 것만 상태를 옮길 수 있다" {
    // claude 의 목록은 열넷이다(실측). 그중 «사용자 입력을 기다린다» 는 다섯만 배지를 옮긴다.
    for ([_][]const u8{
        "permission_prompt",      "worker_permission_prompt", "elicitation_dialog",
        "elicitation_url_dialog", "agent_needs_input",
    }) |name| {
        try testing.expectEqual(NotificationKind.needs_input, notificationKindOf(name));
    }
    // 나머지는 배지와 무관하다 — 모르는 것과 같이 취급한다. **공개 스펙에만 있는 두 이름도 여기 박는다**
    // (`elicitation_complete`·`elicitation_response` — 둘 다 «끝났다» 이지 «기다린다» 가 아니다).
    for ([_][]const u8{
        "idle_prompt",        "auth_success",            "agent_completed",      "push_notification",
        "computer_use_enter", "quota_auto_resume_fired", "elicitation_complete", "elicitation_response",
        "무엇인지 모르는 새 종류",
    }) |name| {
        try testing.expectEqual(NotificationKind.other, notificationKindOf(name));
    }
}

test "Notification payload 에서 종류를 뽑는다" {
    const blocked = "claude\t{\"hook_event_name\":\"Notification\",\"notification_type\":\"permission_prompt\"," ++
        "\"message\":\"Claude needs your permission to use Bash\"}";
    const ev = parseLine(blocked).?;
    try testing.expectEqual(Kind.notification, ev.kind);
    try testing.expectEqual(NotificationKind.needs_input, ev.notification_type);

    // 실측에서 받은 유휴 알림 — 배지를 옮기지 않는다.
    const idle = "claude\t{\"hook_event_name\":\"Notification\",\"notification_type\":\"idle_prompt\"}";
    try testing.expectEqual(NotificationKind.other, parseLine(idle).?.notification_type);

    // 종류가 없는 알림도 옮기지 않는다.
    const bare = "claude\t{\"hook_event_name\":\"Notification\"}";
    try testing.expectEqual(NotificationKind.none, parseLine(bare).?.notification_type);
}

test "Notification 의 message 를 싣는다 — 그 자리가 비면 알림이 아무 말도 안 한다" {
    const line = "claude\t{\"hook_event_name\":\"Notification\",\"notification_type\":\"permission_prompt\"," ++
        "\"message\":\"Claude needs your permission to use Bash\",\"title\":\"Claude Code\"}";
    const ev = parseLine(line).?;
    try testing.expectEqualStrings("Claude needs your permission to use Bash", ev.notice_text);
    // **대화 줄을 건드리지 않는다** — `text` 는 `Stop` 의 응답과 프롬프트가 쓰는 자리다.
    try testing.expectEqualStrings("", ev.text);
}

test "message 는 대화 줄을 덮지 않는다 — 두 자리가 섞이면 «질문은 새것, 답은 알림» 이 된다" {
    const stop = "claude\t{\"hook_event_name\":\"Stop\",\"last_assistant_message\":\"다 고쳤습니다\"}";
    const ev = parseLine(stop).?;
    try testing.expectEqualStrings("다 고쳤습니다", ev.text);
    try testing.expectEqualStrings("", ev.notice_text);
}

test "중첩된 message 는 최상위 자리를 안 건드린다 — 커밋 도구가 그 키를 쓴다" {
    const line = "claude\t{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\"," ++
        "\"tool_input\":{\"message\":\"커밋 메시지입니다\",\"description\":\"커밋\"}}";
    const ev = parseLine(line).?;
    try testing.expectEqualStrings("커밋", ev.tool_description);
    try testing.expectEqualStrings("", ev.notice_text);
}
