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

/// 이벤트 로그가 사는 자리(`sessionCacheBase()` 아래 상대 경로). platform 이 **미리 만들고**(0700) 그
/// 절대 경로를 `build` 에 넘긴다 — 커맨드는 디렉터리를 만들지 않는다(훅이 하는 일이 적을수록 턴이 빨리 끝나고,
/// `mkdir` 이 실패하는 경우를 훅 안에서 처리할 방법도 없다).
pub const log_dir_rel = "agent-turn-events";

/// 우리가 거는 이벤트(계약 §2). **한 번에 확정한다** — Codex는 나중에 늘리면 사용자에게 재승인을 요구한다.
pub const Event = struct {
    name: []const u8,
    /// `null`이면 matcher 없이 등록한다.
    matcher: ?[]const u8 = null,
};

/// 훅을 설치하는 대상. **세트가 provider 마다 다르므로** 이 값이 곧 «어떤 이벤트를 거는가» 를 정한다.
pub const Provider = enum {
    claude,
    codex,

    /// 로그 줄 앞에 붙는 표식(파서가 읽는 그 값). `looksLikeProvider` 를 통과하는 이름이어야 한다.
    pub fn tag(self: Provider) []const u8 {
        return switch (self) {
            .claude => "claude",
            .codex => "codex",
        };
    }
};

/// claude 세트(계약 §2). **한 번에 확정한다.**
pub const claude_events = [_]Event{
    .{ .name = "SessionStart" },
    .{ .name = "UserPromptSubmit" },
    .{ .name = "Stop" },
    // 오류로 끝난 턴은 `Stop` 이 **오지 않는다** — 이것을 안 걸면 그 pane 이 영영 «진행 중» 이다(계약 §2).
    // codex 열거에는 없어 claude 세트에만 둔다.
    .{ .name = "StopFailure" },
    .{ .name = "Notification" },
    .{ .name = "PermissionRequest", .matcher = "*" },
    .{ .name = "PreToolUse", .matcher = "*" },
    // 자식 수를 **세는** 유일한 신뢰 신호다(계약 §2). 자식이 도는 동안 lead 의 `Stop` 은 턴 끝이
    // 아니고, 세지 않으면 «자식이 아직 도는데 완료 알림» 이 나간다. 양 provider 열거에 다 있다(실측).
    .{ .name = "SubagentStart" },
    .{ .name = "SubagentStop" },
};

/// codex 세트 — **`Notification` 과 `StopFailure` 가 없다**(2026-08-21 실측). codex 자신에게 물어
/// 확정했다: app-server `hooks/list` 는 **codex 가 실제로 로드한 것만** 돌려주므로, 모르는 이름을 함께
/// 적어 두고 목록에서 빠지는지를 보면 추측이 필요 없다. 그렇게 물었을 때 빠진 것이 정확히 이 둘이다.
/// 없는 이벤트를 걸면 잘해야 무시되고, 나쁘면 그 파일의 파싱을 통째로 깨뜨린다 — 남의 설정 파일이라
/// 시험 삼아 넣지 않는다.
///
/// codex 에는 `PostToolUse`·`SessionEnd`·`PreCompact` 도 있으나 걸지 않는다 — 앞의 것은 비용 때문이고
/// (계약 §3.1) 나머지 둘은 지금 쓰는 자리가 없다.
///
/// 나머지 일곱은 claude 와 같은 이름이다(codex 도 `hooks.json` 에는 PascalCase 로 적는다 — 실측).
pub const codex_events = [_]Event{
    .{ .name = "SessionStart" },
    .{ .name = "UserPromptSubmit" },
    .{ .name = "Stop" },
    .{ .name = "PermissionRequest", .matcher = "*" },
    .{ .name = "PreToolUse", .matcher = "*" },
    // 자식 수를 **세는** 유일한 신뢰 신호다(계약 §2). 자식이 도는 동안 lead 의 `Stop` 은 턴 끝이
    // 아니고, 세지 않으면 «자식이 아직 도는데 완료 알림» 이 나간다. 양 provider 열거에 다 있다(실측).
    .{ .name = "SubagentStart" },
    .{ .name = "SubagentStop" },
};

/// 그 provider 가 거는 이벤트. **전역 세트를 두지 않는다** — 하나로 두면 codex 에 없는 이벤트가
/// 조용히 섞이고, 그 사실이 드러나는 자리는 사용자의 설정 파일뿐이다.
pub fn eventsFor(provider: Provider) []const Event {
    return switch (provider) {
        .claude => &claude_events,
        .codex => &codex_events,
    };
}

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
    // **파일 권한을 훅이 정한다.** 이 로그에는 payload 가 그대로 실리고 거기엔 소스 코드와 셸 명령 원문이
    // 들어간다(계약 §7). `>>` 가 만드는 파일의 권한은 **셸의 umask** 에 끌려가므로, 두지 않으면 흔한 기본값
    // (022)에서 0644 로 만들어져 같은 머신의 다른 사용자가 읽는다. 디렉터리는 platform 이 0700 으로 만들지만
    // 그것만으로는 부족하다 — 디렉터리 권한은 나중에 사용자가 바꿀 수 있고, 파일 자체가 안전해야 한다.
    // `umask` 는 셸 내장이라 프로세스가 늘지 않는다.
    try out.appendSlice(allocator, "umask 077; ");
    try out.appendSlice(allocator, "IFS= read -r mh_p || :; while IFS= read -r mh_x; do :; done; ");
    // **pane 식별자를 숫자로 검증한다.** 그 값이 그대로 파일명이 되므로 검증 없이 쓰면 경로를 벗어난다 —
    // `MARU_PANE_ID='../outside/pwned'` 로 로그 디렉터리 **밖에** 파일이 만들어지는 것을 실측으로 확인했다.
    // maru 가 주입하는 값은 언제나 surface.id(숫자)이므로(`pty/macos.zig`), 그 밖의 모양이면 우리 세션이
    // 아니라고 보고 나간다. `case` 는 셸 내장이라 프로세스가 늘지 않는다.
    try out.appendSlice(allocator, "case \"$MARU_PANE_ID\" in ''|*[!0-9]*) exit 0 ;; esac; ");
    // **인스턴스 식별자도 같은 규율로 검증한다.** 로그 디렉터리는 사용자 캐시 하나뿐이라 **maru 를 두 개
    // 띄우면 두 인스턴스가 같은 디렉터리를 쓴다.** 그런데 `surface_id` 는 프로세스마다 1 부터 발급되므로
    // (`SurfaceIdAllocator`) 두 인스턴스의 첫 pane 이 **같은 파일 이름**을 갖는다 — 서로의 이벤트를 읽고,
    // 시작 시 정리가 남의 살아 있는 로그를 지운다. 그래서 파일 이름 앞에 인스턴스 칸을 하나 둔다.
    // 값은 maru 가 주입하는 자기 pid 라 숫자이고, 그 밖의 모양이면 우리 세션이 아니라고 보고 나간다
    // (경로 탈출 방어는 pane 식별자와 같은 이유·같은 방법이다).
    try out.appendSlice(allocator, "case \"$MARU_HOOK_INSTANCE\" in ''|*[!0-9]*) exit 0 ;; esac; ");
    // **상한을 넘겨도 «무엇이었는지» 는 살린다**(2026-08-21 실사용에서 실제로 넘겼다 — codex payload 하나).
    //
    // 예전에는 이름까지 버리고 `__oversized__` 하나만 남겼다. 그런데 `Stop` 은 최종 답변 전문
    // (`last_assistant_message`)을 싣는다 — 긴 보고서를 낸 턴이면 상한을 넘고, 그러면 **턴 끝 신호를
    // 통째로 잃어 배지가 안 풀린다.** 이 층이 막으려는 바로 그 실패다.
    //
    // 그래서 payload 를 버리기 **전에** 이름만 뽑는다. 세트의 이름을 `case` 로 훑는 것이라 프로세스가
    // 늘지 않는다(셸 내장). 이름을 못 찾으면 예전처럼 표식만 남긴다 — 모르는 것을 지어내지 않는다.
    // 본문은 사라지므로 알림 문구는 비지만, **상태는 옳게 간다**. 그 둘 중 무엇을 지킬지는 계약이
    // 이미 정해 두었다: 안 풀리는 배지가 더 나쁘다.
    try out.print(allocator, "if [ ${{#mh_p}} -gt {d} ]; then case \"$mh_p\" in ", .{max_payload_bytes});
    // **claude 세트로 훑는다 — codex 세트는 그 부분집합이다**(위 테스트가 못박는다). 그래서 커맨드가
    // provider 마다 갈리지 않고, 한 벌로 두 곳을 덮는다.
    for (claude_events) |e| {
        try out.print(allocator, "*'\"hook_event_name\":\"{s}\"'*) mh_p='{{\"hook_event_name\":\"{s}\"}}' ;; ", .{ e.name, e.name });
    }
    try out.print(allocator, "*) mh_p='{{\"hook_event_name\":\"{s}\"}}' ;; esac; fi; ", .{event.oversized_marker});
    // **`{ … } 2>/dev/null` 로 감싼다.** `printf … 2>/dev/null` 은 printf 자신의 stderr 만 막고 **리다이렉션
    // 대상이 없을 때 셸이 내는 에러**(`No such file or directory`)는 못 막는다 — 실측에서 로그 디렉터리가
    // 없을 때 그 메시지가 provider 화면으로 샜다. 훅은 어떤 실패도 사용자에게 보이지 않아야 한다.
    // **구분자는 파서와 같은 상수여야 한다.** 셸 포맷 문자열에는 `\t` 를 글자로 적을 수밖에 없어(작은따옴표
    // 안의 실제 탭은 읽는 사람이 못 본다) 두 곳에 따로 적히는 모양이 된다. 그 드리프트는 «모든 이벤트가
    // 조용히 파싱 실패» 로 나타나므로, 상수가 탭이 아니게 되면 **컴파일이 깨지게** 묶어 둔다.
    comptime {
        if (event.field_separator != '\t') {
            // 개발자 메시지는 영어로 둔다(i18n 원장 §7.2 — 표시 문자열이 아니고 컴파일 로그에 뜬다).
            @compileError("hook command separator drifted from `agent_hook_event.field_separator`; " ++
                "update the `\\t` in the printf format string too");
        }
    }
    try out.print(allocator, "{{ printf '{s}\\t%s\\n' \"$mh_p\" >> ", .{provider});
    try appendQuoted(out, allocator, log_dir_abs);
    // 경로는 `<로그 디렉터리>/<인스턴스>/<pane>.ndjson` 이다 — 따옴표 밖에서 확장해야 값이 들어간다.
    // 인스턴스 칸이 있어야 maru 를 여러 개 띄워도 이름이 안 겹친다(위 가드 주석). 디렉터리는 maru 가
    // 미리 만든다 — 훅이 `mkdir` 을 부르면 그만큼 프로세스가 늘고(계약 §4.1), 없으면 조용히 나간다.
    try out.appendSlice(allocator, "\"/$MARU_HOOK_INSTANCE/$MARU_PANE_ID.ndjson\"; } 2>/dev/null; exit 0 ");
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

test "이벤트 세트는 계약 §2 그대로다 — provider 마다" {
    // 6 → 9: `StopFailure`(오류로 끝난 턴) + `SubagentStart`/`SubagentStop`(자식 세기).
    try testing.expectEqual(@as(usize, 9), claude_events.len);
    // codex 에는 `Notification` 이 없다(계약 §2.1 실측).
    // 5 → 7: 서브에이전트 둘. `StopFailure` 는 codex 열거에 없어 더하지 않는다.
    try testing.expectEqual(@as(usize, 7), codex_events.len);
    for (codex_events) |e| try testing.expect(!std.mem.eql(u8, e.name, "Notification"));
    for (codex_events) |e| try testing.expect(!std.mem.eql(u8, e.name, "StopFailure"));
    // codex 세트는 claude 세트의 **부분집합**이어야 한다(이름도 matcher 도) — 두 세트가 따로 흘러가면
    // provider 마다 다른 상태가 된다.
    for (codex_events) |c| {
        var found = false;
        for (claude_events) |cl| {
            if (std.mem.eql(u8, c.name, cl.name)) {
                try testing.expectEqual(cl.matcher == null, c.matcher == null);
                if (cl.matcher) |m| try testing.expectEqualStrings(m, c.matcher.?);
                found = true;
            }
        }
        try testing.expect(found);
    }

    for ([_]Provider{ .claude, .codex }) |provider| {
        const set = eventsFor(provider);
        var star: usize = 0;
        for (set) |e| {
            if (e.matcher) |m| {
                try testing.expectEqualStrings("*", m);
                star += 1;
            }
        }
        // matcher가 붙는 것은 도구 이벤트 둘뿐이다(PermissionRequest·PreToolUse).
        try testing.expectEqual(@as(usize, 2), star);
        // PostToolUse는 세트에 없다 — payload가 originalFile을 실어 큰 파일 편집에서 상한에 잘린다(계약 §3.1).
        for (set) |e| try testing.expect(!std.mem.eql(u8, e.name, "PostToolUse"));
        // **이름이 겹치면 안 된다.** 겹치면 설치가 그 이벤트에 항목을 둘 넣는데, 설치 판정은 이벤트를 «덮었나»로
        // 세므로 「우리 항목 수 = 세트 크기」가 영영 맞지 않는다 → 시작할 때마다 사용자 파일을 다시 쓴다
        // (`agent_hook_install.planFor`의 마지막 검사). 손으로 보면 안 보이는 종류의 실수라 여기서 막는다.
        for (set, 0..) |a_ev, i| {
            for (set[i + 1 ..]) |b_ev| {
                try testing.expect(!std.mem.eql(u8, a_ev.name, b_ev.name));
            }
        }
        // 표식은 파서가 인정하는 이름이어야 한다 — 아니면 훅이 적은 줄을 우리가 못 읽는다.
        try testing.expect(event.looksLikeProvider(provider.tag()));
    }
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
    // 권한을 **가장 먼저** 좁힌다 — 뒤에 두면 그 사이에 만들어진 파일이 넓은 권한으로 남는다.
    try testing.expect(std.mem.startsWith(u8, cmd, "umask 077; "));

    // **payload 를 커맨드라인에 올리지 않는다**(계약 §4.1). argv 에 실으면 같은 머신의 다른 프로세스가
    // `ps` 로 읽고 보안 제품이 그 명령줄을 수집·저장한다 — 그 안에는 소스 코드와 셸 명령 원문이 있다(§7).
    // payload 는 stdin 으로 받아 변수에 담고(`read -r mh_p`) `printf` 의 **인자로 확장**된다. 그 확장은
    // 우리 프로세스 안에서 일어나므로 커맨드 문자열 자체에는 값이 없다 — 여기서 보는 것은 «커맨드에 값을
    // 박는 모양이 아니다» 이고, 그 모양이면 반드시 `$mh_p` 같은 참조로만 나타난다.
    try testing.expect(std.mem.indexOf(u8, cmd, "read -r mh_p") != null);
    try testing.expect(std.mem.indexOf(u8, cmd, "\"$mh_p\"") != null);
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
    // 두 세트를 합쳐 본다 — provider 하나만 보면 다른 쪽에만 있는 이벤트가 빠진다.
    for (claude_events ++ codex_events) |e| {
        var line: std.ArrayListUnmanaged(u8) = .empty;
        defer line.deinit(testing.allocator);
        try line.appendSlice(testing.allocator, "claude");
        try line.append(testing.allocator, event.field_separator);
        try line.print(testing.allocator, "{{\"hook_event_name\":\"{s}\"}}", .{e.name});
        const ev = event.parseLine(line.items) orelse {
            // 진단 메시지는 영어로 둔다 — CI 로그를 사람과 스크립트가 함께 읽고, 원장(§7.2)을 늘리지 않는다.
            std.debug.print("\nhook event in the set failed to parse: {s}\n", .{e.name});
            return error.TestUnexpectedResult;
        };
        if (ev.kind == .unknown) {
            std.debug.print("\nset has an event the parser does not know: {s}\n", .{e.name});
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
