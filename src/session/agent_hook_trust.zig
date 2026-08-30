//! codex 훅 **신뢰 값**을 만드는 순수 층(L2, I/O 없음).
//!
//! codex 는 훅을 그냥 실행하지 않는다. `~/.codex/config.toml` 의
//! `[hooks.state."<키>"] trusted_hash` 에 그 훅의 값이 적혀 있어야 돈다. 없으면 사용자에게 묻는다.
//! 계약의 단일 출처는 [docs/agent-hooks.md](../../docs/agent-hooks.md) §2.1 이고, 파일 읽기·쓰기는
//! platform 이 한다.
//!
//! **입력은 커맨드 바이트가 아니라 «이벤트 신원» 이다.** 그래서 같은 커맨드도 이벤트마다 값이 다르다:
//!
//! ```
//! { "event_name": <snake_case>, "matcher": <있을 때만>,
//!   "hooks": [ { "async": false, "command": <커맨드>, "timeout": <초>, "type": "command" } ] }
//! ```
//!
//! 키는 재귀적으로 **정렬**하고 구분자는 **compact**(`,` `:`)다. 그 JSON 의 sha256 앞에 `sha256:` 를 붙인다.
//!
//! **어떻게 알아냈나**: codex 에게 물었다. app-server 의 `hooks/list` 가 훅마다 `key` 와 `currentHash`
//! 를 돌려준다(모델 호출 없이, 프로세스 하나로). 아래 golden 은 그렇게 받은 **codex 자신의 값**이다.
//! 그 전에는 «우리가 계산한 값을 써 넣고 훅이 실제로 도는지» 로 확인했고(신뢰 우회 대조군과 함께),
//! 두 방법이 같은 답을 냈다.

const std = @import("std");
const command = @import("agent_hook_command.zig");

/// 그 이벤트의 규칙을 **실측했는가**. 미측정 항목에 기대는 코드를 쓰지 않기 위해 값으로 들고 다닌다.
pub const Confidence = enum {
    /// 대조군을 둔 실행 실험으로 확인했다.
    measured,
    /// 확인하지 못했다 — 헤드리스로 그 이벤트를 발화시키지 못했다. 이 값에 기대는 결정을 하지 않는다
    /// (platform 은 «신뢰 키가 비어 있을 때만 쓴다» 규칙으로 감당한다, 계약 §2.1).
    unmeasured,
};

/// 한 이벤트의 신뢰 계산 규칙.
pub const EventTrust = struct {
    /// `hooks.json` 에 적히는 이름(PascalCase).
    json_name: []const u8,
    /// trust 키에 적히는 이름(snake_case). **둘은 다르다** — 한쪽만 보고 키를 만들면 영영 안 맞는다.
    snake: []const u8,
    /// 해시 입력에 `matcher` 를 넣는가. **이벤트마다 다르다**(실측): `session_start`·`pre_tool_use` 는
    /// 넣어야 맞고 `user_prompt_submit` 은 빼야 맞다. 틀리면 그 훅이 영영 미신뢰로 남는다.
    matcher_in_hash: bool,
    confidence: Confidence,
};

/// codex 세트(`agent_hook_command.codex_events`)의 이벤트별 규칙. **다섯 다 실측이다.**
///
/// 메커니즘까지 드러났다: `hooks.json` 에 `matcher` 를 적어도 codex 는 `user_prompt_submit`·`stop` 에서
/// **로드할 때 그것을 버린다**(목록이 `matcher: null` 로 온다). 해시는 그 정규화된 결과를 담을 뿐이라,
/// 우리가 적은 값이 아니라 **codex 가 남긴 값** 을 기준으로 계산해야 맞는다.
pub const events = [_]EventTrust{
    .{ .json_name = "SessionStart", .snake = "session_start", .matcher_in_hash = true, .confidence = .measured },
    .{ .json_name = "UserPromptSubmit", .snake = "user_prompt_submit", .matcher_in_hash = false, .confidence = .measured },
    .{ .json_name = "Stop", .snake = "stop", .matcher_in_hash = false, .confidence = .measured },
    .{ .json_name = "PermissionRequest", .snake = "permission_request", .matcher_in_hash = true, .confidence = .measured },
    .{ .json_name = "PreToolUse", .snake = "pre_tool_use", .matcher_in_hash = true, .confidence = .measured },
    .{ .json_name = "SubagentStart", .snake = "subagent_start", .matcher_in_hash = true, .confidence = .measured },
    .{ .json_name = "SubagentStop", .snake = "subagent_stop", .matcher_in_hash = true, .confidence = .measured },
};

pub fn forEvent(json_name: []const u8) ?EventTrust {
    for (events) |e| {
        if (std.mem.eql(u8, e.json_name, json_name)) return e;
    }
    return null;
}

/// JSON 문자열 리터럴로 쓴다. **비-ASCII 는 그대로 둔다** — 상대편이 그렇게 쓰기 때문이고, 여기서
/// `\u` 로 풀면 같은 내용인데 해시가 달라진다(한글 홈 디렉터리에서만 나타나는 종류의 어긋남이다).
fn appendJsonString(out: *std.ArrayListUnmanaged(u8), a: std.mem.Allocator, value: []const u8) !void {
    try out.append(a, '"');
    for (value) |c| {
        switch (c) {
            '"' => try out.appendSlice(a, "\\\""),
            '\\' => try out.appendSlice(a, "\\\\"),
            '\n' => try out.appendSlice(a, "\\n"),
            '\r' => try out.appendSlice(a, "\\r"),
            '\t' => try out.appendSlice(a, "\\t"),
            0x08 => try out.appendSlice(a, "\\b"),
            0x0c => try out.appendSlice(a, "\\f"),
            else => {
                if (c < 0x20) {
                    try out.print(a, "\\u{x:0>4}", .{c});
                } else {
                    try out.append(a, c);
                }
            },
        }
    }
    try out.append(a, '"');
}

/// 해시 입력이 되는 정규 JSON. **키 순서를 손으로 정렬해 둔다** — `event_name` < `hooks` < `matcher`,
/// 핸들러 안은 `async` < `command` < `timeout` < `type`. 정렬을 코드로 하지 않는 이유는 이 순서가
/// **프로토콜이라서**다: 나중에 필드가 늘면 그 자리를 사람이 정해야 하고, 자동 정렬은 그 결정을 숨긴다.
pub fn appendIdentity(
    out: *std.ArrayListUnmanaged(u8),
    a: std.mem.Allocator,
    entry: EventTrust,
    cmd: []const u8,
    timeout_seconds: u32,
    matcher: ?[]const u8,
) !void {
    try out.appendSlice(a, "{\"event_name\":");
    try appendJsonString(out, a, entry.snake);
    try out.appendSlice(a, ",\"hooks\":[{\"async\":false,\"command\":");
    try appendJsonString(out, a, cmd);
    try out.print(a, ",\"timeout\":{d},\"type\":\"command\"}}]", .{timeout_seconds});
    if (entry.matcher_in_hash) {
        if (matcher) |m| {
            try out.appendSlice(a, ",\"matcher\":");
            try appendJsonString(out, a, m);
        }
    }
    try out.append(a, '}');
}

/// `trusted_hash` 값(`sha256:<hex>`).
pub fn appendHash(
    out: *std.ArrayListUnmanaged(u8),
    a: std.mem.Allocator,
    entry: EventTrust,
    cmd: []const u8,
    timeout_seconds: u32,
    matcher: ?[]const u8,
) !void {
    var identity: std.ArrayListUnmanaged(u8) = .empty;
    defer identity.deinit(a);
    try appendIdentity(&identity, a, entry, cmd, timeout_seconds, matcher);

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(identity.items, &digest, .{});
    try out.appendSlice(a, "sha256:");
    for (digest) |b| try out.print(a, "{x:0>2}", .{b});
}

/// trust 키. **`hooks_path` 는 실체 경로여야 한다** — 심링크 경로로 적으면 codex 가 정규화한 키와
/// 어긋나 그 훅이 «신뢰 없음» 이 된다(실측: macOS 의 `/tmp` 가 `/private/tmp` 로 가는 심링크라 그것만으로
/// 훅이 돌지 않았다). 해석은 platform 의 몫이다.
pub fn appendKey(
    out: *std.ArrayListUnmanaged(u8),
    a: std.mem.Allocator,
    hooks_path_real: []const u8,
    entry: EventTrust,
    group_index: usize,
    handler_index: usize,
) !void {
    try out.print(a, "{s}:{s}:{d}:{d}", .{ hooks_path_real, entry.snake, group_index, handler_index });
}

// ── `config.toml` 의 신뢰 항목 ──────────────────────────────────────────────────────────────────
//
// 이 저장소에는 TOML 파서가 없다. 그래서 **텍스트 수술**을 하는데, 규칙 하나가 다른 모든 것보다 중요하다:
// **같은 테이블을 두 번 적으면 안 된다.** TOML 은 테이블 중복을 오류로 보므로, 그 순간 codex 는
// `config.toml` **전체**를 못 읽는다 — 훅이 아니라 사용자의 설정이 통째로 죽는다.
//
// 그래서 판정을 «정확히 이 헤더 줄이 있는가» 가 아니라 «이 키 문자열이 파일 어딘가에 있는가» 로 둔다.
// 헤더는 공백·따옴표 종류가 달라도 같은 테이블일 수 있어 정확히 맞히려면 파서가 필요한데, 못 맞히는
// 쪽이 **중복 추가**로 이어진다. 반대로 이 보수적 판정이 틀리면(주석 안에 우연히 그 문자열이 있으면)
// 우리는 «이미 있다» 로 보고 쓰지 않을 뿐이고, 대가는 승인 프롬프트 한 번이다. 방향이 다르다.

/// 이 키의 신뢰 항목이 이미 파일에 있는가(보수적 판정 — 위 주석).
pub fn hasTrustEntry(config_text: []const u8, key: []const u8) bool {
    return std.mem.indexOf(u8, config_text, key) != null;
}

/// 이 키의 테이블에 **적혀 있는** `trusted_hash` 값. 없거나 모양을 못 읽으면 `null`.
///
/// `hasTrustEntry` 와 갈라 두는 이유: 그쪽은 «키가 있나» 만 본다. 키는 **항목의 자리**(경로·이벤트·인덱스)로
/// 만들어지므로 **커맨드가 바뀌어도 그대로**다. 그래서 커맨드를 고치면 키는 있고 값만 낡는데, 그 상태를
/// codex 는 `modified` 로 보고 **그 훅을 실행하지 않는다**(2026-08-25 실측 — `hooks/list` 의 `trustStatus`
/// 가 `modified`, TUI 는 "hooks won't run" 이라고 적는다). 값을 꺼내야 그 어긋남이 보인다.
///
/// **못 읽으면 `null` 이다 — «다르다» 가 아니다.** 이 값을 쓰는 쪽은 어긋남을 사용자에게 알리므로,
/// 파싱을 실패한 것을 어긋남으로 세면 멀쩡한 설정에 거짓 경고가 뜬다.
pub fn storedHash(config_text: []const u8, key: []const u8) ?[]const u8 {
    var in_table = false;
    var lines = std.mem.splitScalar(u8, config_text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            // 다른 테이블이 시작되면 우리 테이블은 끝난 것이다.
            in_table = isStateHeaderFor(line, key);
            continue;
        }
        if (!in_table) continue;
        if (trustedHashValue(line)) |v| return v;
    }
    return null;
}

/// 이 줄이 `trusted_hash = "…"` 이면 그 값. 아니면 `null`.
///
/// **이름을 통째로 비교한다.** `startsWith` 로 보면 `trusted_hash_algo` 같은 이웃 키가 통과해 그 값을
/// 우리 값으로 읽는다 — 그러면 멀쩡한 설정에 「어긋났다」 경고가 뜬다(거짓 경고).
fn trustedHashValue(trimmed_line: []const u8) ?[]const u8 {
    const eq = std.mem.indexOfScalar(u8, trimmed_line, '=') orelse return null;
    if (!std.mem.eql(u8, std.mem.trim(u8, trimmed_line[0..eq], " \t"), "trusted_hash")) return null;
    const rest = std.mem.trim(u8, trimmed_line[eq + 1 ..], " \t");
    if (rest.len < 2 or rest[0] != '"') return null;
    const end = std.mem.indexOfScalarPos(u8, rest, 1, '"') orelse return null;
    return rest[1..end];
}

/// 표식 줄에 값을 적을 때 쓰는 접두. `# MARU_HOOK_V3 tried=sha256:…`
///
/// **이 한 조각이 「무한 승인 프롬프트」를 구조로 막는다**(계약 §2.1). 갱신은 값 하나당 **한 번**만 한다 —
/// 우리가 써 넣은 값을 여기 남겨 두고, 다음에 또 어긋나 있는데 그 값이 **지금 쓰려는 것과 같으면** 이미
/// 써 봤고 누군가 되돌렸다는 뜻이므로 다시 쓰지 않는다. 우리 공식이 틀린 경우가 정확히 그 모양이고,
/// 그때 사용자는 승인 프롬프트를 **한 번만** 본다.
pub const tried_prefix = " tried=";

/// 이 키의 테이블 **바로 앞 표식 줄**에 적힌 «우리가 시도했던 값». 없으면 `null`.
pub fn triedHash(config_text: []const u8, key: []const u8) ?[]const u8 {
    var last_marker: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, config_text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '#') {
            last_marker = if (std.mem.indexOf(u8, line, command.marker) != null) line else null;
            continue;
        }
        if (line[0] != '[') continue;
        if (!isStateHeaderFor(line, key)) {
            last_marker = null; // 남의 테이블을 지났다 — 그 앞의 표식은 이 키의 것이 아니다
            continue;
        }
        const marker_line = last_marker orelse return null;
        const at = std.mem.indexOf(u8, marker_line, tried_prefix) orelse return null;
        const value = std.mem.trim(u8, marker_line[at + tried_prefix.len ..], " \t");
        return if (value.len == 0) null else value;
    }
    return null;
}

/// 이미 있는 항목의 값을 **제자리에서** 갈아 끼운다(계약 §2.1 의 갱신 경로). 성공하면 `true`.
///
/// **덧붙이지 않는다.** 같은 테이블을 두 번 적으면 TOML 이 깨져 codex 가 `config.toml` **전체**를 못 읽는다 —
/// 훅이 아니라 사용자의 설정이 통째로 죽는다(이 파일의 첫 번째 규칙). 그래서 갱신은 값 한 줄만 바꾼다.
///
/// 표식 줄도 함께 맞춘다. 없으면(= codex 가 사용자 승인으로 적은 항목) **새로 넣는다** — 그 항목은 우리
/// 훅의 것이고, 우리가 값을 손댄 이상 누가 손댔는지 파일에 보여야 한다. 그 줄에 `tried=` 로 이번에 쓴 값을
/// 남겨 다음 판단의 근거로 삼는다.
///
/// 못 찾으면(테이블이 없거나 값 줄이 없으면) `false` 를 주고 **아무것도 안 바꾼다** — 호출부는 그때 쓰지
/// 않고 사용자에게 알리는 쪽으로 간다.
pub fn rewriteTrustEntry(
    out: *std.ArrayListUnmanaged(u8),
    a: std.mem.Allocator,
    config_text: []const u8,
    key: []const u8,
    hash: []const u8,
) !bool {
    var in_target = false;
    var found_table = false;
    var wrote_value = false;
    var marker_done = false;
    // 표식 줄은 헤더 **앞**에 오므로 판단을 미룬다 — 대상 헤더가 뒤따르면 갈아 끼우고, 아니면 원문
    // 그대로 내보낸다. 그 사이의 **빈 줄은 투명하게 넘긴다**: 손으로 편집한 파일에서 표식과 헤더 사이가
    // 벌어져 있으면, 안 그럴 경우 옛 표식을 흘려보낸 뒤 새것을 또 넣어 **표식이 둘**이 된다.
    var pending_marker: ?[]const u8 = null;
    var pending_blanks: usize = 0;
    var first = true;

    var lines = std.mem.splitScalar(u8, config_text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const is_marker = line.len != 0 and line[0] == '#' and
            std.mem.indexOf(u8, line, command.marker) != null;
        const is_header = line.len != 0 and line[0] == '[';
        const is_target_header = is_header and isStateHeaderFor(line, key);

        if (pending_marker != null and line.len == 0) {
            pending_blanks += 1;
            continue;
        }
        if (pending_marker) |m| {
            pending_marker = null;
            if (is_target_header) {
                try emitLine(out, a, &first, null);
                try out.print(a, "# {s}{s}{s}", .{ command.marker, tried_prefix, hash });
                marker_done = true;
            } else {
                try emitLine(out, a, &first, m);
            }
            while (pending_blanks != 0) : (pending_blanks -= 1) try emitLine(out, a, &first, "");
        }

        if (is_marker) {
            pending_marker = raw;
            continue;
        }
        if (is_header) {
            if (is_target_header) {
                found_table = true;
                in_target = true;
                if (!marker_done) {
                    try emitLine(out, a, &first, null);
                    try out.print(a, "# {s}{s}{s}", .{ command.marker, tried_prefix, hash });
                    marker_done = true;
                }
            } else in_target = false;
            try emitLine(out, a, &first, raw);
            continue;
        }
        if (in_target and !wrote_value and trustedHashValue(line) != null) {
            try emitLine(out, a, &first, null);
            try out.print(a, "trusted_hash = \"{s}\"", .{hash});
            wrote_value = true;
            continue;
        }
        try emitLine(out, a, &first, raw);
    }
    if (pending_marker) |m| {
        try emitLine(out, a, &first, m);
        while (pending_blanks != 0) : (pending_blanks -= 1) try emitLine(out, a, &first, "");
    }

    return found_table and wrote_value;
}

/// 줄 사이 `\n` 만 넣는다(마지막 줄 뒤에는 안 넣는다) — 원문 바이트를 그대로 되살리기 위해서다.
/// `line` 이 `null` 이면 구분자만 넣고 내용은 호출부가 이어 쓴다.
fn emitLine(out: *std.ArrayListUnmanaged(u8), a: std.mem.Allocator, first: *bool, line: ?[]const u8) !void {
    if (!first.*) try out.append(a, '\n');
    first.* = false;
    if (line) |l| try out.appendSlice(a, l);
}

/// `[hooks.state."<키>"]` 인가. **따옴표 안을 통째로 비교한다** — 키에 `.` 와 `:` 가 들어가서
/// 부분 일치로 보면 `…:0:0` 이 `…:0:0` 을 담은 다른 키와 섞인다.
fn isStateHeaderFor(line: []const u8, key: []const u8) bool {
    const prefix = "[hooks.state.\"";
    if (!std.mem.startsWith(u8, line, prefix)) return false;
    const rest = line[prefix.len..];
    if (!std.mem.endsWith(u8, rest, "\"]")) return false;
    return std.mem.eql(u8, rest[0 .. rest.len - 2], key);
}

/// 파일 끝에 붙일 신뢰 항목. **덮어쓰지 않고 붙이기만 한다**(계약 §2.1 — 키가 비어 있을 때만 쓴다).
///
/// 앞에 개행을 넣을지는 원본이 개행으로 끝나는지에 달렸다. 그것을 안 보면 마지막 줄에 헤더가 이어 붙어
/// 그 줄이 통째로 깨진다.
pub fn appendTrustEntry(
    out: *std.ArrayListUnmanaged(u8),
    a: std.mem.Allocator,
    config_text: []const u8,
    key: []const u8,
    hash: []const u8,
) !void {
    if (config_text.len != 0 and config_text[config_text.len - 1] != '\n') try out.append(a, '\n');
    // 사람이 열어 봤을 때 **누가 넣었는지** 보이게 한다. 훅 커맨드의 표식과 같은 역할이다.
    // `tried=` 로 **이번에 쓴 값**을 함께 남긴다 — 갱신 경로(`rewriteTrustEntry`)와 같은 형식이라야
    // 「이 값은 이미 써 봤다」 판단이 첫 설치분에도 성립한다.
    try out.print(a, "\n# {s}{s}{s}\n[hooks.state.\"{s}\"]\ntrusted_hash = \"{s}\"\n", .{
        command.marker,
        tried_prefix,
        hash,
        key,
        hash,
    });
}

/// 우리 표식이 붙은 신뢰 블록을 거둔다. **표식이 유일한 기준이다** — 사용자가 직접 승인해 codex 가 적은
/// 항목에는 표식이 없으므로 살아남는다. 그 판정을 키로 하면(«우리가 만들 법한 키인가») 사용자가 같은 훅을
/// 손수 승인한 경우를 우리 것으로 오인해 **남의 신뢰를 지운다**.
///
/// 우리가 쓰는 모양은 `appendTrustEntry` 가 정한 그대로다:
///
///     <빈 줄>
///     # MARU_HOOK_V3
///     [hooks.state."<키>"]
///     trusted_hash = "sha256:…"
///
/// 표식 줄을 만나면 **다음 테이블 헤더 직전까지** 건너뛴다(그 사이가 그 테이블의 몸통이다).
/// 거둔 것이 있으면 `true`.
pub fn removeTrustEntries(out: *std.ArrayListUnmanaged(u8), a: std.mem.Allocator, config_text: []const u8) !bool {
    var removed = false;
    var skipping = false;
    // 표식 **바로 뒤의** 헤더는 우리 테이블 자신이다. 그것을 «다음 테이블» 로 오인하면 우리 헤더만 남고
    // 몸통이 사라져 파일이 더 이상해진다(첫 구현이 그랬다).
    var our_header_pending = false;

    var it = std.mem.splitScalar(u8, config_text, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");

        // **표식 검사가 가장 먼저다.** skip 분기 뒤에 두면 우리 블록이 연달아 있을 때 두 번째 표식에
        // 영영 닿지 못해 그 블록이 살아남는다(두 번째 구현이 그랬다).
        if (std.mem.startsWith(u8, trimmed, "#") and std.mem.indexOf(u8, trimmed, command.marker) != null) {
            skipping = true;
            our_header_pending = true;
            removed = true;
            // 표식 **앞의** 빈 줄도 우리가 넣은 것이라 함께 거둔다(안 그러면 껐다 켤 때마다 빈 줄이 쌓인다).
            while (out.items.len >= 2 and
                out.items[out.items.len - 1] == '\n' and
                out.items[out.items.len - 2] == '\n')
            {
                out.items.len -= 1;
            }
            continue;
        }

        if (skipping) {
            if (std.mem.startsWith(u8, trimmed, "[")) {
                if (our_header_pending) {
                    our_header_pending = false; // 우리 헤더 — 함께 거둔다
                    continue;
                }
                skipping = false; // 남의 테이블이 시작됐다
            } else {
                continue;
            }
        }

        try out.appendSlice(a, line);
        try out.append(a, '\n');
    }

    // `splitScalar` 는 마지막 개행 뒤의 빈 조각도 주므로 개행이 하나 더 붙는다. 원본이 개행으로 끝났으면
    // 그 하나를 되돌린다(원본이 개행 없이 끝났으면 우리가 더한 것도 없다).
    if (out.items.len > 0 and out.items[out.items.len - 1] == '\n') out.items.len -= 1;
    if (config_text.len > 0 and config_text[config_text.len - 1] == '\n' and
        out.items.len > 0 and out.items[out.items.len - 1] != '\n')
    {
        try out.append(a, '\n');
    }
    return removed;
}

/// 거둔 뒤 남은 것이 **우리 것 말고 없는가**(공백뿐인가). platform 은 이때 파일째 지워 설치 전 상태로
/// 되돌린다 — 우리가 만든 파일이었다는 뜻이기 때문이다.
pub fn isBlank(text: []const u8) bool {
    return std.mem.trim(u8, text, " \t\r\n").len == 0;
}

const testing = std.testing;

fn hashAlloc(entry: EventTrust, cmd: []const u8, timeout_seconds: u32, matcher: ?[]const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try appendHash(&out, testing.allocator, entry, cmd, timeout_seconds, matcher);
    return out.toOwnedSlice(testing.allocator);
}

// ── golden: **codex 자신이 계산한 값** ──────────────────────────────────────────────────────────
//
// 어떻게 얻었나: codex app-server 의 `hooks/list` 는 훅마다 `key` 와 **`currentHash`** 를 돌려준다.
// 즉 codex 에게 «네가 계산한 값이 뭐냐» 고 물을 수 있다 — 역산도, 모델 호출도 필요 없다.
// 아래 다섯은 그렇게 받은 값이고, 우리 구현이 그것과 어긋나면 그 훅은 영영 미신뢰로 남는다.
//
// fixture 는 `hooks.json` 의 세트 이벤트 **모두에** `matcher: "*"` 를 적은 상태다. 그런데도
// `user_prompt_submit`·`stop` 의 값은 matcher 없이 계산해야 맞는다 — codex 가 그 둘에서 matcher 를
// **로드할 때 버리기** 때문이다(목록이 `matcher: null` 로 온다). 이 대비가 이 fixture 의 핵심이다.
const golden_command = "printf fired > /dev/null; exit 0";
const golden_timeout: u32 = 2;

const GoldenCase = struct { json_name: []const u8, hash: []const u8 };
const golden = [_]GoldenCase{
    .{ .json_name = "SessionStart", .hash = "sha256:9b1757037d5ae6563e2fb361ce7b37fc0899aae52c1b7d80bfab17816d62b8e3" },
    .{ .json_name = "PreToolUse", .hash = "sha256:75d94ad4c3d9f7b851f02876acd2e9c7dc427f0b4f5929310516df12dc0b0635" },
    .{ .json_name = "PermissionRequest", .hash = "sha256:75cb26dffd4ee64f19c90136bc2f5299e5a9df1133c4ad35fd447e717024268f" },
    .{ .json_name = "SubagentStart", .hash = "sha256:97c305fa72ceb659e6097ac1f91571ffa57d6b6c2bfaceb64c27c8c6641dffeb" },
    .{ .json_name = "SubagentStop", .hash = "sha256:fd60f580c15c67ed17cef4dca2b2a8092c6452e63f62a842ea0b0bf2bdc16d19" },
    // 아래 둘은 fixture 에 matcher 가 **있는데도** 없이 계산한 값이다.
    .{ .json_name = "UserPromptSubmit", .hash = "sha256:6ccb18ff90f1de0bbc4e0ddc0818549d36697d64710ab0c5040a165fd86ba45a" },
    .{ .json_name = "Stop", .hash = "sha256:d445818a88b2e64da7d09e58850802e0f15124c6a7d9d428e44e437e433f017d" },
};

test "golden: 세트의 모든 이벤트가 codex 가 계산한 값과 같다" {
    // 세트 전체를 덮는다 — 하나라도 빠지면 그 이벤트만 조용히 미신뢰가 된다.
    try testing.expectEqual(command.codex_events.len, golden.len);
    for (golden) |g| {
        const h = try hashAlloc(forEvent(g.json_name).?, golden_command, golden_timeout, "*");
        defer testing.allocator.free(h);
        try testing.expectEqualStrings(g.hash, h);
    }
}

test "golden: matcher 를 빼는 두 이벤트는 matcher 를 줘도 값이 같다" {
    // «넣을지 말지» 를 우리가 실제로 가른다는 증거. 이 대조가 없으면 위 테스트는 matcher 를 늘 무시하는
    // 구현으로도 통과한다.
    for ([_][]const u8{ "UserPromptSubmit", "Stop" }) |name| {
        const with_m = try hashAlloc(forEvent(name).?, golden_command, golden_timeout, "*");
        defer testing.allocator.free(with_m);
        const without_m = try hashAlloc(forEvent(name).?, golden_command, golden_timeout, null);
        defer testing.allocator.free(without_m);
        try testing.expectEqualStrings(with_m, without_m);
    }
    // 반대로 넣는 이벤트는 달라야 한다.
    for ([_][]const u8{ "SessionStart", "PreToolUse", "PermissionRequest", "SubagentStart", "SubagentStop" }) |name| {
        const with_m = try hashAlloc(forEvent(name).?, golden_command, golden_timeout, "*");
        defer testing.allocator.free(with_m);
        const without_m = try hashAlloc(forEvent(name).?, golden_command, golden_timeout, null);
        defer testing.allocator.free(without_m);
        try testing.expect(!std.mem.eql(u8, with_m, without_m));
    }
}

test "정규 JSON 의 키 순서와 모양이 프로토콜 그대로다" {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(testing.allocator);
    try appendIdentity(&out, testing.allocator, forEvent("SessionStart").?, "echo hi", 2, "*");
    try testing.expectEqualStrings(
        "{\"event_name\":\"session_start\",\"hooks\":[{\"async\":false,\"command\":\"echo hi\"," ++
            "\"timeout\":2,\"type\":\"command\"}],\"matcher\":\"*\"}",
        out.items,
    );
}

test "커맨드의 따옴표·역슬래시·탭이 JSON 을 깨지 않는다" {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(testing.allocator);
    try appendIdentity(&out, testing.allocator, forEvent("Stop").?, "a\"b\\c\td", 2, null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"command\":\"a\\\"b\\\\c\\td\"") != null);
}

test "비-ASCII 경로를 그대로 싣는다 — 풀어 쓰면 같은 내용이 다른 해시가 된다" {
    // 한글 홈 디렉터리에서만 나타나는 종류의 어긋남이라 눈으로는 안 보인다.
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(testing.allocator);
    try appendIdentity(&out, testing.allocator, forEvent("Stop").?, "cd '/Users/사용자/로그'", 2, null);
    try testing.expect(std.mem.indexOf(u8, out.items, "/Users/사용자/로그") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\\u") == null);
}

test "trust 키는 실체 경로 + snake 이름 + 두 인덱스다" {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(testing.allocator);
    try appendKey(&out, testing.allocator, "/Users/u/.codex/hooks.json", forEvent("PreToolUse").?, 0, 0);
    try testing.expectEqualStrings("/Users/u/.codex/hooks.json:pre_tool_use:0:0", out.items);
}

test "codex 세트의 모든 이벤트에 규칙이 있다 — 한쪽만 늘면 그 훅이 조용히 미신뢰가 된다" {
    for (command.codex_events) |e| {
        const entry = forEvent(e.name) orelse {
            std.debug.print("no trust rule for codex event '{s}'\n", .{e.name});
            return error.MissingTrustRule;
        };
        // snake 이름은 소문자와 `_` 뿐이어야 한다 — PascalCase 를 그대로 실으면 키가 영영 안 맞는다.
        for (entry.snake) |c| {
            try testing.expect((c >= 'a' and c <= 'z') or c == '_');
        }
    }
    // 반대 방향도 본다: 규칙만 있고 세트에 없는 이벤트는 죽은 코드다.
    for (events) |entry| {
        var found = false;
        for (command.codex_events) |e| {
            if (std.mem.eql(u8, e.name, entry.json_name)) found = true;
        }
        try testing.expect(found);
    }
}

test "규칙은 전부 실측이다 — 추측이 하나라도 섞이면 드러나야 한다" {
    // 지금은 다섯 다 `measured` 다. 이벤트를 늘리면서 규칙을 «아마 이럴 것» 으로 채우면 여기가 걸린다.
    // 재는 방법은 코드 주석이 아니라 계약 §2.1 이 소유한다(app-server `hooks/list` 가 codex 자신의 값을
    // 알려준다 — 모델 호출 없이 잰다).
    for (events) |e| {
        try testing.expectEqual(Confidence.measured, e.confidence);
    }
}

test "신뢰 항목이 없으면 붙이고, 있으면 손대지 않는다" {
    const a = testing.allocator;
    const key = "/Users/u/.codex/hooks.json:session_start:0:0";
    const hash = "sha256:abc";

    try testing.expect(!hasTrustEntry("", key));
    try testing.expect(!hasTrustEntry("[hooks.state]\n", key));
    // 헤더로 있으면 당연히 «있다».
    try testing.expect(hasTrustEntry("[hooks.state.\"" ++ key ++ "\"]\ntrusted_hash = \"x\"\n", key));

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(a);
    const before = "model = \"gpt\"\n";
    try out.appendSlice(a, before);
    try appendTrustEntry(&out, a, before, key, hash);
    try testing.expect(std.mem.startsWith(u8, out.items, before)); // 원본이 앞에 그대로
    try testing.expect(std.mem.indexOf(u8, out.items, "[hooks.state.\"" ++ key ++ "\"]") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "trusted_hash = \"sha256:abc\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, command.marker) != null); // 우리 것임이 보인다

    // **한 번 붙인 뒤에는 다시 붙지 않는다** — 중복 테이블은 codex 가 config 전체를 못 읽게 만든다.
    try testing.expect(hasTrustEntry(out.items, key));
}

test "개행으로 끝나지 않는 파일에도 헤더가 이어 붙지 않는다" {
    const a = testing.allocator;
    const before = "model = \"gpt\""; // 개행 없음
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(a);
    try out.appendSlice(a, before);
    try appendTrustEntry(&out, a, before, "k", "sha256:x");
    // 마지막 줄이 살아 있어야 한다.
    try testing.expect(std.mem.indexOf(u8, out.items, "model = \"gpt\"\n") != null);
    // 그리고 헤더는 줄 맨 앞에서 시작해야 한다.
    const at = std.mem.indexOf(u8, out.items, "[hooks.state.").?;
    try testing.expectEqual(@as(u8, '\n'), out.items[at - 1]);
}

test "다른 키는 서로 방해하지 않는다" {
    const a = testing.allocator;
    const k1 = "/h.json:session_start:0:0";
    const k2 = "/h.json:stop:0:0";
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(a);
    try appendTrustEntry(&out, a, "", k1, "sha256:1");
    try testing.expect(hasTrustEntry(out.items, k1));
    try testing.expect(!hasTrustEntry(out.items, k2)); // 접두가 같아도 다른 키다
}

test "우리 세트 전체를 붙여도 키가 겹치지 않는다" {
    // 키가 겹치면 같은 테이블을 두 번 적는 것이 되어 codex 가 config 를 통째로 못 읽는다.
    const a = testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(a);
    for (command.codex_events) |e| {
        const entry = forEvent(e.name).?;
        var key: std.ArrayListUnmanaged(u8) = .empty;
        defer key.deinit(a);
        try appendKey(&key, a, "/Users/u/.codex/hooks.json", entry, 0, 0);
        try testing.expect(!hasTrustEntry(out.items, key.items)); // 아직 없다
        try appendTrustEntry(&out, a, out.items, key.items, "sha256:x");
        try testing.expect(hasTrustEntry(out.items, key.items));
    }
}

test "우리 표식이 붙은 신뢰 블록만 거둔다 — 사용자가 승인한 것은 남는다" {
    const a = testing.allocator;
    // 사용자가 직접 승인해 codex 가 적은 항목에는 우리 표식이 없다. 그 줄을 지우면 남의 신뢰를 지우는 것이다.
    const before =
        "model = \"gpt-5\"\n" ++
        "\n[hooks.state.\"/h.json:session_start:0:0\"]\ntrusted_hash = \"sha256:user\"\n" ++
        "\n# " ++ command.marker ++ "\n[hooks.state.\"/h.json:stop:1:0\"]\ntrusted_hash = \"sha256:ours\"\n";

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(a);
    try testing.expect(try removeTrustEntries(&out, a, before));

    try testing.expect(std.mem.indexOf(u8, out.items, "sha256:ours") == null); // 우리 것은 갔다
    try testing.expect(std.mem.indexOf(u8, out.items, "sha256:user") != null); // 남의 것은 남았다
    try testing.expect(std.mem.indexOf(u8, out.items, "session_start") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "stop:1:0") == null);
    try testing.expect(std.mem.indexOf(u8, out.items, "model = \"gpt-5\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, command.marker) == null);
}

test "거둘 것이 없으면 바꾸지 않는다" {
    const a = testing.allocator;
    const before = "model = \"gpt-5\"\n\n[hooks.state.\"/h.json:stop:0:0\"]\ntrusted_hash = \"sha256:user\"\n";
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(a);
    try testing.expect(!(try removeTrustEntries(&out, a, before)));
    try testing.expectEqualStrings(before, out.items);
}

test "넣었다 거두면 원래 바이트로 돌아온다 — 껐다 켜도 빈 줄이 쌓이지 않는다" {
    const a = testing.allocator;
    const before = "model = \"gpt-5\"\n";

    var installed: std.ArrayListUnmanaged(u8) = .empty;
    defer installed.deinit(a);
    try installed.appendSlice(a, before);
    try appendTrustEntry(&installed, a, before, "/h.json:stop:0:0", "sha256:x");
    try appendTrustEntry(&installed, a, installed.items, "/h.json:session_start:0:0", "sha256:y");

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(a);
    try testing.expect(try removeTrustEntries(&out, a, installed.items));
    try testing.expectEqualStrings(before, out.items);
}

test "블록 뒤에 사용자 내용이 있어도 빈 줄이 남지 않는다" {
    // 우리 블록이 **파일 끝일 때는** 꼬리 정규화가 빈 줄을 대신 흡수해 버려서, 그 경우만 보면 앞의 빈 줄을
    // 거두는 코드가 있으나 없으나 같아 보인다(뮤테이션이 «못 잡음» 으로 그것을 드러냈다). 뒤에 사용자
    // 내용이 오는 배치라야 그 차이가 나타난다.
    const a = testing.allocator;
    const head = "a = 1\n";
    const tail = "\n[other]\nv = 1\n";

    var installed: std.ArrayListUnmanaged(u8) = .empty;
    defer installed.deinit(a);
    try installed.appendSlice(a, head);
    try appendTrustEntry(&installed, a, head, "/h.json:stop:0:0", "sha256:x");
    try installed.appendSlice(a, tail);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(a);
    try testing.expect(try removeTrustEntries(&out, a, installed.items));
    try testing.expectEqualStrings("a = 1\n[other]\nv = 1\n", out.items);
}

test "우리 것만 있던 파일은 비어서 돌아온다 — platform 이 그때 파일째 지운다" {
    const a = testing.allocator;
    var installed: std.ArrayListUnmanaged(u8) = .empty;
    defer installed.deinit(a);
    for ([_][]const u8{ "/h.json:stop:0:0", "/h.json:pre_tool_use:0:0" }) |key| {
        try appendTrustEntry(&installed, a, installed.items, key, "sha256:x");
    }
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(a);
    try testing.expect(try removeTrustEntries(&out, a, installed.items));
    try testing.expect(isBlank(out.items));
    // 대조: 사용자 줄이 하나라도 있으면 «비었다» 가 아니다.
    try testing.expect(!isBlank("model = \"gpt-5\"\n"));
}

test "표식 뒤에 다른 테이블이 붙어 있어도 그 테이블은 살아남는다" {
    const a = testing.allocator;
    const before =
        "\n# " ++ command.marker ++ "\n[hooks.state.\"/h.json:stop:0:0\"]\ntrusted_hash = \"sha256:ours\"\n" ++
        "\n[other.table]\nvalue = 1\n";
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(a);
    try testing.expect(try removeTrustEntries(&out, a, before));
    try testing.expect(std.mem.indexOf(u8, out.items, "sha256:ours") == null);
    try testing.expect(std.mem.indexOf(u8, out.items, "[other.table]") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "value = 1") != null);
}

test "적힌 값을 꺼낸다 — 키만 보면 «있다» 인데 값이 낡은 자리를 가른다" {
    const a = testing.allocator;
    var installed: std.ArrayListUnmanaged(u8) = .empty;
    defer installed.deinit(a);
    try appendTrustEntry(&installed, a, installed.items, "/h.json:stop:1:0", "sha256:old");

    // 이것이 이 함수가 존재하는 이유다: 키는 **자리**로 만들어져 커맨드가 바뀌어도 그대로다.
    try testing.expect(hasTrustEntry(installed.items, "/h.json:stop:1:0"));
    try testing.expectEqualStrings("sha256:old", storedHash(installed.items, "/h.json:stop:1:0").?);

    // 없는 키는 null — «다르다» 와 갈라야 한다(호출부가 그것으로 경고를 낸다).
    try testing.expect(storedHash(installed.items, "/h.json:stop:0:0") == null);
}

test "다른 테이블의 값을 우리 것으로 읽지 않는다" {
    const a = testing.allocator;
    var text: std.ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(a);
    try appendTrustEntry(&text, a, text.items, "/h.json:stop:0:0", "sha256:aaa");
    try appendTrustEntry(&text, a, text.items, "/h.json:stop:1:0", "sha256:bbb");
    // 우리 테이블 뒤에 사용자 테이블이 이어져도 그 값이 새어 들어오면 안 된다.
    try text.appendSlice(a, "\n[tui]\ntrusted_hash = \"sha256:not-ours\"\n");

    try testing.expectEqualStrings("sha256:aaa", storedHash(text.items, "/h.json:stop:0:0").?);
    try testing.expectEqualStrings("sha256:bbb", storedHash(text.items, "/h.json:stop:1:0").?);
    try testing.expect(storedHash(text.items, "/h.json:pre_tool_use:0:0") == null);
}

test "키가 다른 키의 부분 문자열이어도 섞이지 않는다" {
    const a = testing.allocator;
    var text: std.ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(a);
    // `…:0:0` 은 `…:0:00` 의 부분 문자열이다. 헤더를 통째로 비교하지 않으면 앞의 값을 돌려준다.
    try appendTrustEntry(&text, a, text.items, "/h.json:stop:0:00", "sha256:long");
    try appendTrustEntry(&text, a, text.items, "/h.json:stop:0:0", "sha256:short");

    try testing.expectEqualStrings("sha256:short", storedHash(text.items, "/h.json:stop:0:0").?);
    try testing.expectEqualStrings("sha256:long", storedHash(text.items, "/h.json:stop:0:00").?);
}

test "갱신은 값 한 줄만 바꾼다 — 테이블을 새로 만들지 않는다" {
    const a = testing.allocator;
    const key = "/h.json:stop:1:0";
    // codex 가 사용자 승인으로 적은 모양(우리 표식이 없다) + 앞뒤에 사용자 내용.
    const before = "model = \"gpt-5\"\n\n[hooks.state.\"" ++ key ++ "\"]\ntrusted_hash = \"sha256:old\"\n\n[tui]\nx = 1\n";
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(a);
    try testing.expect(try rewriteTrustEntry(&out, a, before, key, "sha256:new"));

    try testing.expectEqualStrings("sha256:new", storedHash(out.items, key).?);
    // **테이블은 하나뿐이다** — 둘이 되면 TOML 이 깨져 codex 가 파일 전체를 못 읽는다.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.items, "[hooks.state.\"" ++ key ++ "\"]"));
    // 남의 내용은 그대로다.
    try testing.expect(std.mem.indexOf(u8, out.items, "model = \"gpt-5\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "[tui]") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "x = 1") != null);
    // 우리가 손댔다는 표식과 «이번에 쓴 값» 이 남는다.
    try testing.expectEqualStrings("sha256:new", triedHash(out.items, key).?);
}

test "이미 우리 표식이 있으면 그 줄을 갈아 끼운다 — 표식이 쌓이지 않는다" {
    const a = testing.allocator;
    const key = "/h.json:stop:1:0";
    var before: std.ArrayListUnmanaged(u8) = .empty;
    defer before.deinit(a);
    try appendTrustEntry(&before, a, before.items, key, "sha256:first");
    try testing.expectEqualStrings("sha256:first", triedHash(before.items, key).?);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(a);
    try testing.expect(try rewriteTrustEntry(&out, a, before.items, key, "sha256:second"));
    try testing.expectEqualStrings("sha256:second", storedHash(out.items, key).?);
    try testing.expectEqualStrings("sha256:second", triedHash(out.items, key).?);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.items, command.marker));
}

test "표식과 헤더 사이가 벌어져 있어도 표식이 둘이 되지 않는다" {
    const a = testing.allocator;
    const key = "/h.json:stop:1:0";
    // 손으로 편집한 파일의 모양. 빈 줄을 투명하게 넘기지 않으면 옛 표식을 흘려보낸 뒤 새것을 또 넣는다.
    const before = "# " ++ command.marker ++ " tried=sha256:old\n\n[hooks.state.\"" ++ key ++ "\"]\ntrusted_hash = \"sha256:old\"\n";
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(a);
    try testing.expect(try rewriteTrustEntry(&out, a, before, key, "sha256:new"));

    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.items, command.marker));
    try testing.expectEqualStrings("sha256:new", storedHash(out.items, key).?);
    try testing.expectEqualStrings("sha256:new", triedHash(out.items, key).?);
    // 벌어져 있던 빈 줄은 그대로 남는다(사용자 파일의 모양을 우리가 정리하지 않는다).
    try testing.expect(std.mem.indexOf(u8, out.items, "\n\n[hooks.state.") != null);
}

test "대상이 없으면 아무것도 안 바꾼다 — 호출부가 알리는 쪽으로 간다" {
    const a = testing.allocator;
    const before = "model = \"gpt-5\"\n\n[tui]\nx = 1\n";
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(a);
    try testing.expect(!try rewriteTrustEntry(&out, a, before, "/h.json:stop:1:0", "sha256:new"));

    // 값 줄이 없는 테이블도 «못 했다» 다 — 헤더만 있는데 성공이라고 하면 호출부가 안 알린다.
    var out2: std.ArrayListUnmanaged(u8) = .empty;
    defer out2.deinit(a);
    const headerless = "[hooks.state.\"/h.json:stop:1:0\"]\n\n[tui]\nx = 1\n";
    try testing.expect(!try rewriteTrustEntry(&out2, a, headerless, "/h.json:stop:1:0", "sha256:new"));
}

test "남의 테이블 앞 표식을 이 키의 것으로 읽지 않는다" {
    const a = testing.allocator;
    var text: std.ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(a);
    try appendTrustEntry(&text, a, text.items, "/h.json:stop:0:0", "sha256:aaa");
    // 우리 블록 뒤에 **표식 없는** 남의 테이블이 온다 — 그 키에는 시도 기록이 없어야 한다.
    try text.appendSlice(a, "\n[hooks.state.\"/h.json:stop:1:0\"]\ntrusted_hash = \"sha256:bbb\"\n");

    try testing.expectEqualStrings("sha256:aaa", triedHash(text.items, "/h.json:stop:0:0").?);
    try testing.expect(triedHash(text.items, "/h.json:stop:1:0") == null);
}

test "갱신해도 껐다 켜면 원래 바이트로 돌아온다" {
    const a = testing.allocator;
    const key = "/h.json:stop:1:0";
    const user = "model = \"gpt-5\"\n";
    var installed: std.ArrayListUnmanaged(u8) = .empty;
    defer installed.deinit(a);
    try installed.appendSlice(a, user);
    try appendTrustEntry(&installed, a, installed.items, key, "sha256:first");

    var refreshed: std.ArrayListUnmanaged(u8) = .empty;
    defer refreshed.deinit(a);
    try testing.expect(try rewriteTrustEntry(&refreshed, a, installed.items, key, "sha256:second"));

    // 갱신은 우리 블록의 모양을 안 바꾼다 — 제거가 그 모양을 근거로 삼기 때문이다.
    var removed: std.ArrayListUnmanaged(u8) = .empty;
    defer removed.deinit(a);
    try testing.expect(try removeTrustEntries(&removed, a, refreshed.items));
    try testing.expectEqualStrings(user, removed.items);
}

test "표식 없던 항목을 고친 뒤 껐다 켜도 사용자 내용이 남는다" {
    const a = testing.allocator;
    const key = "/h.json:stop:1:0";
    // codex 가 사용자 승인으로 적은 모양이다 — **우리 표식이 없고 앞뒤로 남의 테이블이 붙어 있다.**
    // 갱신이 여기에 표식을 넣으므로, 그 뒤 «끄기» 가 남의 것을 함께 지우면 안 된다.
    const before =
        "model = \"gpt-5\"\n" ++
        "\n[hooks.state]\n" ++
        "\n[hooks.state.\"" ++ key ++ "\"]\ntrusted_hash = \"sha256:old\"\n" ++
        "\n[tui]\nvalue = 1\n";

    var refreshed: std.ArrayListUnmanaged(u8) = .empty;
    defer refreshed.deinit(a);
    try testing.expect(try rewriteTrustEntry(&refreshed, a, before, key, "sha256:new"));
    try testing.expectEqualStrings("sha256:new", storedHash(refreshed.items, key).?);

    var removed: std.ArrayListUnmanaged(u8) = .empty;
    defer removed.deinit(a);
    try testing.expect(try removeTrustEntries(&removed, a, refreshed.items));

    // 우리 것만 사라지고 남의 것은 **내용도 순서도** 그대로다.
    try testing.expect(std.mem.indexOf(u8, removed.items, key) == null);
    try testing.expect(std.mem.indexOf(u8, removed.items, command.marker) == null);
    const model_at = std.mem.indexOf(u8, removed.items, "model = \"gpt-5\"") orelse return error.TestUnexpectedResult;
    const state_at = std.mem.indexOf(u8, removed.items, "[hooks.state]") orelse return error.TestUnexpectedResult;
    const tui_at = std.mem.indexOf(u8, removed.items, "[tui]") orelse return error.TestUnexpectedResult;
    try testing.expect(model_at < state_at and state_at < tui_at);
    try testing.expect(std.mem.indexOf(u8, removed.items, "value = 1") != null);
}

test "이웃 키를 우리 키로 오인하지 않는다 — 접두가 같은 이름이 먼저 와도" {
    const key = "/h.json:stop:0:0";
    // 상대편이 필드를 하나 늘리면 이런 모양이 된다. 접두만 보면 **그 값을 우리 값으로 읽고**,
    // 그 순간 멀쩡한 설정에 「어긋났다」 경고가 뜬다 — 세지 않기로 한 방향과 정반대다.
    const text = "[hooks.state.\"" ++ key ++ "\"]\n" ++
        "trusted_hash_algo = \"sha256\"\n" ++
        "trusted_hash = \"sha256:real\"\n";
    try testing.expectEqualStrings("sha256:real", storedHash(text, key).?);
}

test "모양을 못 읽으면 null 이다 — 거짓 경고를 만들지 않는다" {
    const key = "/h.json:stop:0:0";
    // 값이 따옴표로 안 닫혔다.
    try testing.expect(storedHash("[hooks.state.\"" ++ key ++ "\"]\ntrusted_hash = \"unterminated\n", key) == null);
    // 키 문자열이 **주석에만** 있다 — `hasTrustEntry` 는 true 를 주지만 적힌 값은 없다.
    const only_comment = "# " ++ key ++ " 는 예전에 여기 있었다\n[tui]\nx = 1\n";
    try testing.expect(hasTrustEntry(only_comment, key));
    try testing.expect(storedHash(only_comment, key) == null);
}

/// 신뢰 항목 하나를 만들 자리. `agent_hook_install.Placement` 에 **세트가 정한 matcher** 를 붙인 것이다
/// (파일에 적힌 값이 아니라 — 우리가 넣은 항목이므로 세트의 값이 맞다).
///
/// `Placement` 를 그대로 안 받는 이유: 이 모듈은 `agent_hook_install` 을 들여오지 않는다(그쪽이 이쪽을
/// 쓰는 방향이다). 필드 넷을 호출자가 옮겨 담는 편이 그 방향을 지킨다.
pub const Slot = struct {
    json_name: []const u8,
    group_index: usize,
    handler_index: usize,
    matcher: ?[]const u8,
};

/// 이 판정이 세운 수. **개수는 «지금» 의 값이다** — «있었던 적이 있다» 가 아니다(latch 금지).
pub const Stats = struct {
    /// 새로 붙인 항목.
    added: usize = 0,
    /// 값 한 줄만 갈아 끼운 항목.
    refreshed: u32 = 0,
    /// 모양을 못 읽어 **손대지 않은** 항목. 사용자에게 「codex 에서 승인하라」고 말할 근거다.
    stale: u32 = 0,
    /// 우리 값을 써 봤는데 누군가(거의 언제나 **승인을 받은 codex**)가 다른 값으로 되돌린 항목.
    /// **«안 돈다» 가 아니다** — 그때 파일의 값이 codex 의 정답이므로 훅은 정상으로 돌고 있다.
    diverged: u32 = 0,
};

/// `config.toml` 본문에 우리 신뢰 항목들을 반영한다. **순수하다** — 파일을 안 읽고 안 쓴다.
///
/// **로컬 GUI 설치기와 원격 CLI 가 이 함수를 함께 쓴다.** 이 판정에는 두 겹의 미묘함이 있어(값이 낡았을
/// 때의 갱신, 그리고 «이미 써 본 값» 을 다시 안 쓰는 루프 방지) 두 곳에 따로 적으면 반드시 갈린다 —
/// 갈린 쪽은 **매 실행 승인 프롬프트가 뜨는 무한 루프**가 되고, 그 증상은 원격에서 더 늦게 발견된다.
///
/// `out` 은 **호출자가 원본 본문으로 채워 둔** 상태로 들어온다(그 위에서 고친다).
pub fn applyEntries(
    out: *std.ArrayListUnmanaged(u8),
    a: std.mem.Allocator,
    hooks_real: []const u8,
    slots: []const Slot,
    cmd: []const u8,
    timeout_seconds: u32,
) !Stats {
    var stats: Stats = .{};
    for (slots) |slot| {
        const entry = forEvent(slot.json_name) orelse continue;

        var key: std.ArrayListUnmanaged(u8) = .empty;
        defer key.deinit(a);
        try appendKey(&key, a, hooks_real, entry, slot.group_index, slot.handler_index);

        var hash: std.ArrayListUnmanaged(u8) = .empty;
        defer hash.deinit(a);
        try appendHash(&hash, a, entry, cmd, timeout_seconds, slot.matcher);

        if (hasTrustEntry(out.items, key.items)) {
            // 이미 있다. 그런데 **값이 다르면 그 훅은 안 돈다**: 키는 항목의 자리로 만들어져 커맨드가
            // 바뀌어도 그대로이므로, 커맨드를 고친 뒤에는 키가 있는 채로 값만 낡는다. codex 는 그것을
            // `modified` 로 보고 실행하지 않는다(계약 §2.1).
            //
            // 못 읽으면(`null`) **아무것도 하지 않는다** — 모르는 것을 어긋남으로 세면 거짓 경고가 되고,
            // 모르는 것을 덮으면 남의 값을 지운다.
            const stored = storedHash(out.items, key.items) orelse continue;
            if (std.mem.eql(u8, stored, hash.items)) continue; // 멀쩡하다

            // **이 값을 이미 써 봤으면 다시 안 쓴다.** 그때는 누군가(= 사용자 승인을 받은 codex)가 우리
            // 값을 되돌린 것이고, 그 모양이 곧 «우리 공식이 틀렸다» 다. 다시 쓰면 매 실행 승인 프롬프트가
            // 뜨는 무한 루프가 된다 — §2.1 이 값을 매겨 둔 바로 그 위험이다. 값 하나당 시도는 한 번뿐이다.
            if (triedHash(out.items, key.items)) |tried| {
                if (std.mem.eql(u8, tried, hash.items)) {
                    stats.diverged += 1;
                    continue;
                }
            }

            // 갱신한다 — **덧붙이지 않고 값 한 줄만** 바꾼다(같은 테이블을 두 번 적으면 codex 가
            // `config.toml` 전체를 못 읽는다).
            var next: std.ArrayListUnmanaged(u8) = .empty;
            defer next.deinit(a);
            const done = rewriteTrustEntry(&next, a, out.items, key.items, hash.items) catch false;
            if (!done) {
                stats.stale += 1; // 모양을 못 읽었다 — 손대지 않고 알린다
                continue;
            }
            out.clearRetainingCapacity();
            try out.appendSlice(a, next.items);
            stats.refreshed += 1;
            continue;
        }

        try appendTrustEntry(out, a, out.items, key.items, hash.items);
        stats.added += 1;
    }
    return stats;
}
