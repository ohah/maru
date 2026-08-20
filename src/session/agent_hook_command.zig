//! provider 설정에 넣을 **인라인 훅 커맨드**를 만드는 순수 모듈(L2, I/O 없음).
//! 계약의 단일 출처는 [docs/agent-hooks.md](../../docs/agent-hooks.md) §4.1이고, 실제 설치(파일 읽기·쓰기·
//! `flock`·Codex trust 갱신)는 AH2가 맡는다.
//!
//! **왜 스크립트 파일이 아니라 인라인인가**: 파일을 두면 provider가 매 이벤트마다 그 절대경로를 실행하므로,
//! 그 파일을 덮어쓸 수 있는 누구든 사용자 권한으로 임의 코드를 돌린다. 우리가 하는 일은 한 줄 append라
//! 파일이 필요 없다. 대가는 Codex `trusted_hash`가 커맨드 바이트 해시라 **로직을 고치면 재승인**이 뜬다는
//! 것이므로, 커맨드는 한 번에 확정하고 자주 바꾸지 않는다.
//!
//! **왜 추가 프로세스를 하나도 안 쓰는가**: 실측(2026-08-20)에서 훅 1회 비용의 65%가 `sh` spawn 자체였다
//! (`/bin/sh -c "exit 0"` 8.04 ms, 훅 전체 12.27 ms). 스크립트가 `cat`·`mkdir`·`head`를 부르면 그만큼
//! 프로세스가 더 뜨고 도구 호출마다 그 값이 얹힌다. 그래서 stdin은 셸 내장 `read`로 받고, 길이 제한은
//! `${#var}`로 하고, 디렉터리는 **설치할 때 maru가 미리 만든다**(훅은 없으면 조용히 실패하고 나간다).

const std = @import("std");
const event = @import("agent_hook_event.zig");

/// 커맨드 끝에 붙는 표식. **우리 항목을 고르는 유일한 근거**다(파일이 없으므로 파일명 매칭이 불가능하다).
///
/// 사람이 읽는 안내를 함께 넣는다 — 사용자가 이 커맨드를 복사해 자기 항목으로 쓰면 우리가 그것을 우리 것으로
/// 오인해 지운다. 그 사고를 막는 것은 "이건 maru 것이고 임의로 사라진다"는 문장뿐이다.
///
/// **이 문장만은 UI 언어를 따르지 않고 영어로 고정한다**(i18n `t()`를 쓰지 않는다). Codex는
/// `config.toml`의 `trusted_hash`가 **커맨드 바이트의 sha256**이라, 문구가 언어에 따라 달라지면
/// **앱 언어를 바꾸는 것만으로 훅이 미신뢰가 되어 매 실행에 확인 프롬프트가 뜬다.** 설정 파일에 남는
/// 문자열이라 표시 계층이 아니라 **프로토콜 상수**로 다룬다(docs/i18n.md §7의 "영어 고정 표면"과 같은 결).
pub const marker = "MARU_HOOK_V3";
pub const marker_comment = "# " ++ marker ++ " managed by maru: added and removed automatically, do not copy";

/// payload 길이 상한. 넘으면 훅이 **표식 한 줄로 바꿔** 적는다(잘라서 반쪽 JSON을 만들지 않는다).
///
/// **줄 상한에서 접두를 뺀 값이다.** 훅이 적는 줄은 `<provider><구분자><payload>` 라서 payload 를 줄 상한과
/// 같게 두면 그만큼 줄이 길어져 **파서가 버린다** — 커맨드는 통과시키고 파서는 버리는, 상한 경계에서만
/// 나타나는 유실이다. 접두 최대치(provider 이름 + 구분자 1)를 미리 뺀다.
pub const max_payload_bytes: usize = event.max_line_bytes - event.max_provider_len - 1;

/// 훅 항목에 함께 적는 타임아웃(초). **기본값에 맡기지 않는다** — provider 가 그 기본을 바꾸면 우리 훅이
/// 조용히 길어지고, 그동안 에이전트 턴이 물린다(계약 §4.1).
///
/// **2초인 근거**: 훅 1회 실측이 12.27 ms 이고 하는 일은 로컬 파일 append 하나뿐이다. 그 100배를 넘겨도
/// 안 끝난다면 디스크·파일 잠금에 뭔가 잘못된 것이고, 그때는 **훅을 포기하는 쪽이 옳다** — 이벤트 하나를
/// 잃는 것과 사용자의 턴이 멈추는 것 중 전자가 낫다.
pub const timeout_seconds: u32 = 2;

/// 우리가 거는 이벤트(계약 §2). **한 번에 확정한다** — Codex는 나중에 늘리면 사용자에게 재승인을 요구한다.
pub const Event = struct {
    name: []const u8,
    /// `null`이면 matcher 없이 등록한다.
    matcher: ?[]const u8 = null,
};

pub const events = [_]Event{
    .{ .name = "SessionStart" },
    .{ .name = "UserPromptSubmit" },
    .{ .name = "Stop" },
    .{ .name = "Notification" },
    .{ .name = "PermissionRequest", .matcher = "*" },
    .{ .name = "PreToolUse", .matcher = "*" },
};

/// 셸 single-quote 이스케이프. 경로에 `'`가 있어도 커맨드가 깨지지 않게 `'\''`로 끊어 붙인다.
fn appendQuoted(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    try out.append(allocator, '\'');
    for (value) |c| {
        if (c == '\'') {
            try out.appendSlice(allocator, "'\\''");
        } else {
            try out.append(allocator, c);
        }
    }
    try out.append(allocator, '\'');
}

/// 한 provider의 훅 커맨드를 만든다. `log_dir_abs`는 maru가 **미리 만들어 둔** 이벤트 로그 디렉터리다.
///
/// 계약이 요구하는 것을 순서대로 지킨다:
/// 1. **stdin을 먼저 전부 삼킨다** — 첫 줄을 payload로 받고 나머지를 드레인한다. 안 그러면 provider 파이프가
///    막힌다. 실측상 payload는 개행 없는 한 줄 JSON이라 드레인 루프는 즉시 끝난다.
/// 2. pane 식별자가 없으면 **아무것도 하지 않고** 나간다(maru 밖에서 띄운 세션에는 남길 pane이 없다).
/// 3. 상한을 넘으면 표식으로 바꾼다 — 이벤트를 조용히 없애지 않는다.
/// 4. provider 이름을 **우리가 붙인다**(payload에는 그 정보가 없다).
/// 5. 무슨 일이 있어도 `exit 0`.
pub fn build(
    out: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    provider: []const u8,
    log_dir_abs: []const u8,
) error{ OutOfMemory, InvalidProvider }!void {
    // **provider 이름을 검증한다.** 이 값은 줄 앞에 그대로 적히므로 탭이나 개행이 들어오면 **모든 줄이
    // 깨진다**(구분자가 둘이 되거나 줄이 둘로 갈린다). 파서와 같은 규칙을 쓴다 — 두 곳이 기준이 다르면
    // «훅은 적었는데 파서는 못 읽는» 이름이 생긴다.
    if (!event.looksLikeProvider(provider)) return error.InvalidProvider;
    // `|| :` — provider가 `sh -e`로 실행해도 마지막 줄의 read 실패(개행 없이 끝남)가 훅을 죽이지 않게.
    try out.appendSlice(allocator, "IFS= read -r mh_p || :; while IFS= read -r mh_x; do :; done; ");
    // **pane 식별자를 숫자로 검증한다.** 그 값이 그대로 파일명이 되므로 검증 없이 쓰면 경로를 벗어난다 —
    // `MARU_PANE_ID='../outside/pwned'` 로 로그 디렉터리 **밖에** 파일이 만들어지는 것을 실측으로 확인했다.
    // maru 가 주입하는 값은 언제나 surface.id(숫자)이므로(`pty/macos.zig`), 그 밖의 모양이면 우리 세션이
    // 아니라고 보고 나간다. `case` 는 셸 내장이라 프로세스가 늘지 않는다.
    try out.appendSlice(allocator, "case \"$MARU_PANE_ID\" in ''|*[!0-9]*) exit 0 ;; esac; ");
    try out.print(allocator, "if [ ${{#mh_p}} -gt {d} ]; then mh_p='{{\"hook_event_name\":\"{s}\"}}'; fi; ", .{
        max_payload_bytes,
        event.oversized_marker,
    });
    // **`{ … } 2>/dev/null` 로 감싼다.** `printf … 2>/dev/null` 은 printf 자신의 stderr 만 막고 **리다이렉션
    // 대상이 없을 때 셸이 내는 에러**(`No such file or directory`)는 못 막는다 — 실측에서 로그 디렉터리가
    // 없을 때 그 메시지가 provider 화면으로 샜다. 훅은 어떤 실패도 사용자에게 보이지 않아야 한다.
    // **구분자는 파서와 같은 상수여야 한다.** 셸 포맷 문자열에는 `\t` 를 글자로 적을 수밖에 없어(작은따옴표
    // 안의 실제 탭은 읽는 사람이 못 본다) 두 곳에 따로 적히는 모양이 된다. 그 드리프트는 «모든 이벤트가
    // 조용히 파싱 실패» 로 나타나므로, 상수가 탭이 아니게 되면 **컴파일이 깨지게** 묶어 둔다.
    comptime {
        if (event.field_separator != '\t') {
            @compileError("훅 커맨드가 쓰는 구분자와 `agent_hook_event.field_separator` 가 어긋났다 — " ++
                "포맷 문자열의 `\\t` 를 함께 고쳐라");
        }
    }
    try out.print(allocator, "{{ printf '{s}\\t%s\\n' \"$mh_p\" >> ", .{provider});
    try appendQuoted(out, allocator, log_dir_abs);
    // 파일명은 pane 식별자다 — 따옴표 밖에서 확장해야 값이 들어간다.
    try out.appendSlice(allocator, "\"/$MARU_PANE_ID.ndjson\"; } 2>/dev/null; exit 0 ");
    try out.appendSlice(allocator, marker_comment);
}

/// 이 커맨드가 우리 것인가. **표식만 본다** — 경로·상한이 바뀌어도 우리 것으로 남고, 사용자 항목은 표식이
/// 없으므로 걸리지 않는다.
pub fn isOurs(command: []const u8) bool {
    return std.mem.indexOf(u8, command, marker) != null;
}

/// 과거 표식. [persistent-session-host.md](../../docs/persistent-session-host.md) P1이 "legacy 잔재를 자동
/// 정리하지 않는다"고 정했으므로 **우리는 이 항목을 지우지 않는다.** 여기 두는 이유는 우리 표식과 구분해
/// «건드리지 않았음»을 테스트로 고정하기 위해서다.
pub const legacy_markers = [_][]const u8{"MARU_AGENT_MAP_HOOK_V2"};

pub fn isLegacy(command: []const u8) bool {
    for (legacy_markers) |m| {
        if (std.mem.indexOf(u8, command, m) != null) return true;
    }
    return false;
}

const testing = std.testing;

fn buildAlloc(provider: []const u8, dir: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(testing.allocator);
    try build(&out, testing.allocator, provider, dir);
    return out.toOwnedSlice(testing.allocator);
}

test "pane 식별자가 숫자가 아니면 나간다 — 그 값이 파일명이 되므로 경로를 벗어날 수 있다" {
    // 실측: 검증이 없을 때 `MARU_PANE_ID='../outside/pwned'` 가 로그 디렉터리 밖에 파일을 만들었다.
    const cmd = try buildAlloc("claude", "/tmp/ev");
    defer testing.allocator.free(cmd);
    try testing.expect(std.mem.indexOf(u8, cmd, "*[!0-9]*") != null);
    // 검증이 파일에 쓰기 **전에** 와야 한다.
    const guard = std.mem.indexOf(u8, cmd, "*[!0-9]*").?;
    const write = std.mem.indexOf(u8, cmd, "printf").?;
    try testing.expect(guard < write);
}

test "커맨드는 추가 프로세스를 하나도 띄우지 않는다" {
    // 비용의 65%가 sh spawn이라 스크립트가 프로세스를 더 부르면 그만큼 도구 호출마다 얹힌다.
    // `cat`·`mkdir`·`head`·`tr`·`jq`는 모두 프로세스다 — 셸 내장(`read`·`printf`·`${#var}`)으로만 짠다.
    const cmd = try buildAlloc("claude", "/home/u/.cache/maru/agent-turn-events");
    defer testing.allocator.free(cmd);
    for ([_][]const u8{ "cat ", "mkdir", "head ", "tr ", "jq ", "sed ", "curl" }) |bad| {
        try testing.expect(std.mem.indexOf(u8, cmd, bad) == null);
    }
    try testing.expect(std.mem.indexOf(u8, cmd, "read -r") != null);
    try testing.expect(std.mem.indexOf(u8, cmd, "printf") != null);
}

test "stdin을 먼저 받고 나머지를 드레인한 뒤에야 가드가 온다" {
    // 가드를 먼저 두면 pane 식별자가 없는 세션에서 stdin을 안 읽고 나가 provider 파이프가 막힌다.
    const cmd = try buildAlloc("claude", "/tmp/ev");
    defer testing.allocator.free(cmd);
    const read_at = std.mem.indexOf(u8, cmd, "read -r mh_p").?;
    const drain_at = std.mem.indexOf(u8, cmd, "while IFS= read -r mh_x").?;
    const guard_at = std.mem.indexOf(u8, cmd, "case \"$MARU_PANE_ID\" in").?;
    try testing.expect(read_at < drain_at);
    try testing.expect(drain_at < guard_at);
}

test "provider 이름을 우리가 붙인다 — payload에는 그 정보가 없다" {
    const claude = try buildAlloc("claude", "/tmp/ev");
    defer testing.allocator.free(claude);
    const codex = try buildAlloc("codex", "/tmp/ev");
    defer testing.allocator.free(codex);
    try testing.expect(std.mem.indexOf(u8, claude, "printf 'claude\\t%s\\n'") != null);
    try testing.expect(std.mem.indexOf(u8, codex, "printf 'codex\\t%s\\n'") != null);
}

test "상한을 넘긴 payload는 표식으로 바뀐다 — 파서가 아는 그 이름이다" {
    const cmd = try buildAlloc("claude", "/tmp/ev");
    defer testing.allocator.free(cmd);
    try testing.expect(std.mem.indexOf(u8, cmd, event.oversized_marker) != null);
    // 파서가 그 줄을 실제로 oversized로 읽는지까지 본다(두 모듈이 같은 이름을 쓴다는 증명).
    const line = "claude\t{\"hook_event_name\":\"" ++ event.oversized_marker ++ "\"}";
    try testing.expectEqual(event.Kind.oversized, event.parseLine(line).?.kind);
}

test "어떤 경로로 나가든 exit 0이다" {
    const cmd = try buildAlloc("claude", "/tmp/ev");
    defer testing.allocator.free(cmd);
    // 가드 탈출도, 정상 종료도 0이어야 훅이 에이전트 턴을 물지 않는다.
    try testing.expect(std.mem.indexOf(u8, cmd, ") exit 0 ;; esac") != null);
    try testing.expect(std.mem.indexOf(u8, cmd, "; exit 0 ") != null);
    try testing.expect(std.mem.indexOf(u8, cmd, "2>/dev/null") != null);
}

test "디렉터리 경로의 따옴표가 커맨드를 깨지 않는다" {
    const cmd = try buildAlloc("claude", "/home/o'brien/.cache/maru/ev");
    defer testing.allocator.free(cmd);
    try testing.expect(std.mem.indexOf(u8, cmd, "'/home/o'\\''brien/.cache/maru/ev'") != null);
}

test "표식으로 우리 항목만 고른다 — 사용자 항목과 legacy는 남는다" {
    const cmd = try buildAlloc("claude", "/tmp/ev");
    defer testing.allocator.free(cmd);
    try testing.expect(isOurs(cmd));
    try testing.expect(!isLegacy(cmd));

    try testing.expect(!isOurs("my-own-hook.sh"));
    try testing.expect(!isOurs("bunx ccusage statusline"));

    // legacy 항목은 우리 것이 아니고, P1이 자동 정리를 금지했으므로 건드리지 않는다.
    const legacy = "if [ -n \"$MARU_AGENT_MAPPING_ID\" ]; then cat > x; fi # MARU_AGENT_MAP_HOOK_V2";
    try testing.expect(!isOurs(legacy));
    try testing.expect(isLegacy(legacy));
}

test "표식에 사람이 읽는 안내가 있고, 그 문구는 언어에 따라 흔들리지 않는다" {
    // 표식만 있으면 사용자가 커맨드를 복사했을 때 우리가 그것을 지운다. 그 사고를 막는 것은 문장뿐이다.
    try testing.expect(std.mem.indexOf(u8, marker_comment, "maru") != null);
    try testing.expect(std.mem.indexOf(u8, marker_comment, "do not copy") != null);
    try testing.expect(std.mem.startsWith(u8, marker_comment, "# "));
    // **ASCII 고정**: 커맨드 바이트가 UI 언어를 타면 Codex trusted_hash 가 깨져 언어 변경만으로 재승인이 뜬다.
    for (marker_comment) |c| try testing.expect(c < 0x80);
}

test "이벤트 세트는 계약 §2 그대로다" {
    try testing.expectEqual(@as(usize, 6), events.len);
    var star: usize = 0;
    for (events) |e| {
        if (e.matcher) |m| {
            try testing.expectEqualStrings("*", m);
            star += 1;
        }
    }
    // matcher가 붙는 것은 도구 이벤트 둘뿐이다(PermissionRequest·PreToolUse).
    try testing.expectEqual(@as(usize, 2), star);
    // PostToolUse는 세트에 없다 — payload가 originalFile을 실어 상한에 잘린다(계약 §3.1).
    for (events) |e| try testing.expect(!std.mem.eql(u8, e.name, "PostToolUse"));
}

test "커맨드 구조가 셸 게이트가 검증한 그 모양이다" {
    // `tools/check-agent-hook-command.sh` 가 실제 `/bin/sh` 로 돌려 계약 6개를 보는 fixture
    // (`tests/golden/agent_hook_command.sh`)와 **같은 구조**여야 한다. 파일을 직접 비교하지 못하는 것은
    // `@embedFile` 이 패키지 경로 밖을 못 읽기 때문이고, 대신 ⑴ 여기서 구조 불변식을 고정하고 ⑵ 셸 게이트가
    // 표식 버전으로 fixture 의 신선도를 본다. 두 검사가 만나는 지점이 `marker` 다.
    const cmd = try buildAlloc("claude", "__LOG_DIR__");
    defer testing.allocator.free(cmd);
    // 리다이렉션 실패까지 삼키는 그룹으로 감쌌는지 — 감싸지 않으면 디렉터리가 없을 때 셸 에러가
    // provider 화면으로 샌다(실측으로 잡은 결함).
    try testing.expect(std.mem.indexOf(u8, cmd, "{ printf ") != null);
    try testing.expect(std.mem.indexOf(u8, cmd, "; } 2>/dev/null;") != null);
    // fixture 가 치환하는 자리표시자가 그대로 있는지.
    try testing.expect(std.mem.indexOf(u8, cmd, "'__LOG_DIR__'") != null);
    try testing.expect(std.mem.endsWith(u8, cmd, marker_comment));
}

test "커맨드가 쓴 줄을 파서가 읽는다 — 형식이 두 곳에 따로 적히면 조용히 깨진다" {
    // 셸 게이트는 «파일에 이 모양으로 적혔다» 까지 보고, 파서 테스트는 «이 모양을 읽는다» 를 본다.
    // 그 사이가 비면 형식 드리프트가 «모든 이벤트가 파싱 실패» 로만 드러난다. 여기서 양쪽을 잇는다.
    const cmd = try buildAlloc("codex", "/tmp/ev");
    defer testing.allocator.free(cmd);
    // 커맨드가 만드는 줄 모양: <provider><구분자><payload>
    try testing.expect(std.mem.indexOf(u8, cmd, "printf 'codex\\t%s\\n'") != null);

    var line: std.ArrayListUnmanaged(u8) = .empty;
    defer line.deinit(testing.allocator);
    try line.appendSlice(testing.allocator, "codex");
    try line.append(testing.allocator, event.field_separator);
    try line.appendSlice(testing.allocator, "{\"hook_event_name\":\"Stop\"}");
    const ev = event.parseLine(line.items).?;
    try testing.expectEqualStrings("codex", ev.provider);
    try testing.expectEqual(event.Kind.stop, ev.kind);
}

test "payload 상한이 줄 상한을 넘기지 않는다 — 경계에서만 나는 유실이다" {
    // 훅이 적는 줄은 `<provider><구분자><payload>` 다. payload 상한을 줄 상한과 같게 두면 접두만큼 길어져
    // 커맨드는 통과시키고 **파서가 버린다**. 그 유실은 딱 경계에서만 나타나 눈에 안 띈다.
    const longest_prefix = event.max_provider_len + 1; // 이름 + 구분자
    try testing.expect(max_payload_bytes + longest_prefix <= event.max_line_bytes);

    // 실제로 상한 크기의 payload 로 만든 줄이 파서의 상한 안에 드는지 본다.
    var line: std.ArrayListUnmanaged(u8) = .empty;
    defer line.deinit(testing.allocator);
    try line.appendSlice(testing.allocator, "mimo-code"); // 우리가 아는 이름 중 긴 편
    try line.append(testing.allocator, event.field_separator);
    try line.appendSlice(testing.allocator, "{\"hook_event_name\":\"Stop\",\"pad\":\"");
    while (line.items.len < max_payload_bytes) try line.append(testing.allocator, 'x');
    try line.appendSlice(testing.allocator, "\"}");
    try testing.expect(line.items.len <= event.max_line_bytes);
    try testing.expect(event.parseLine(line.items) != null);
}

test "세트의 모든 이벤트를 파서가 안다 — 한쪽만 늘면 그 이벤트가 조용히 unknown 이 된다" {
    // 세트(여기)와 `Kind`(파서)는 따로 적혀 있다. 이벤트를 하나 더 걸고 파서에 넣는 것을 잊으면 그 이벤트는
    // 로그에 쌓이면서 `unknown` 으로만 읽혀, 소비자가 «아무 일도 없었다» 와 구분하지 못한다.
    for (events) |e| {
        var line: std.ArrayListUnmanaged(u8) = .empty;
        defer line.deinit(testing.allocator);
        try line.appendSlice(testing.allocator, "claude");
        try line.append(testing.allocator, event.field_separator);
        try line.print(testing.allocator, "{{\"hook_event_name\":\"{s}\"}}", .{e.name});
        const ev = event.parseLine(line.items) orelse {
            std.debug.print("\n세트의 이벤트를 파싱하지 못했다: {s}\n", .{e.name});
            return error.TestUnexpectedResult;
        };
        if (ev.kind == .unknown) {
            std.debug.print("\n파서가 모르는 이벤트가 세트에 있다: {s}\n", .{e.name});
            return error.TestUnexpectedResult;
        }
    }
}

test "타임아웃이 실측 비용보다 넉넉하되 턴을 물지 않을 만큼 짧다" {
    // 기본값에 맡기면 provider 가 그 기본을 바꿀 때 우리 훅이 조용히 길어진다. 값이 없는 것 자체가 결함이라
    // 여기서 «있다» 와 «범위» 를 함께 고정한다.
    try testing.expect(timeout_seconds >= 1); // 실측 12.27 ms 의 80배 이상
    try testing.expect(timeout_seconds <= 5); // 이보다 길면 사용자가 멈춤을 체감한다
}

test "provider 이름이 줄을 깨뜨릴 수 있으면 거절한다" {
    // 이 값은 줄 앞에 그대로 적힌다 — 탭이면 구분자가 둘이 되고 개행이면 줄이 둘로 갈린다. 그런 이름으로
    // 커맨드를 만들면 **그 provider 의 모든 이벤트가 조용히 파싱 실패**한다.
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(testing.allocator);
    try testing.expectError(error.InvalidProvider, build(&out, testing.allocator, "cl\taude", "/tmp/ev"));
    try testing.expectError(error.InvalidProvider, build(&out, testing.allocator, "cl\naude", "/tmp/ev"));
    try testing.expectError(error.InvalidProvider, build(&out, testing.allocator, "", "/tmp/ev"));
    try testing.expectError(error.InvalidProvider, build(&out, testing.allocator, "Claude", "/tmp/ev"));

    // 우리가 쓰는 이름은 통과한다.
    out.clearRetainingCapacity();
    try build(&out, testing.allocator, "claude", "/tmp/ev");
    try testing.expect(out.items.len > 0);
}
