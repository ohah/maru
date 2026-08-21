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
    try out.print(a, "\n# {s}\n[hooks.state.\"{s}\"]\ntrusted_hash = \"{s}\"\n", .{ command.marker, key, hash });
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
