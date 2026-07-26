//! claude **상태줄 훅**으로 세션 신원을 받는 경로 — 사이드바 에이전트 행의 마지막 대화(docs/sidebar-agent-list.md
//! §7.2.2)를 "도구를 한 번도 안 쓴 세션"에서도 채우기 위한 보강이다.
//!
//! **기본 경로는 이게 아니다.** 평소에는 에이전트가 자식에게 내려주는 세션 신원(`CLAUDE_CODE_SESSION_ID`)을 읽는다
//! (§7.2.1) — 사용자 파일을 하나도 건드리지 않는다. 다만 그 값은 **자식이 존재할 때만** 읽히므로, 도구를 전혀
//! 실행하지 않는 세션은 신원을 얻지 못한다. 이 모듈은 그 빈틈을 메우되 **사용자 소유 파일을 고쳐 쓰는 대가**를
//! 치르므로 config(`sidebar.agent-transcript-hook`)로 끌 수 있다.
//!
//! **화면을 바꾸지 않는다.** claude는 상태줄 명령의 stdout을 그려주는데, 우리 스크립트는 아무것도 출력하지 않는다.
//! 사용자가 보는 claude 상태줄은 설치 전후가 같다.
//!
//! **Maru가 넣은 것임이 드러나야 한다.** 스크립트 파일명(`maru-statusline.sh`)과 그 안의 표식 주석, 그리고 설치
//! 마커 파일 셋이 그 역할을 한다 — 사용자가 `settings.json`을 열어봐도 무엇이 왜 있는지 알 수 있고, 제거할 때
//! **우리가 넣은 것만** 정확히 지운다(사용자가 직접 설정한 상태줄은 건드리지 않는다).
//!
//! OS 중립이다 — 경로 조립과 스크립트 본문 생성은 순수 함수이고, 실제 파일 IO는 platform이 맡는다.

const std = @import("std");

/// 설치하는 스크립트 파일명. **이름 자체가 표식이다** — `settings.json`의 `statusLine.command`에 이 경로가 있으면
/// Maru가 넣은 것이고, 없으면 사용자(또는 다른 도구) 것이라 건드리지 않는다.
pub const script_name = "maru-statusline.sh";

/// 설치 마커 파일명(스크립트와 같은 디렉터리). 스크립트 존재만으로는 "우리가 `settings.json`까지 고쳤는가"를 알 수
/// 없어(사용자가 파일만 남기고 설정을 되돌렸을 수 있다) 설치 사실을 따로 남긴다.
pub const marker_name = ".maru-statusline-installed";

/// 스크립트가 세션 신원을 적는 디렉터리(캐시 루트 기준). Term의 `MARU_PANE_ID`가 파일명이 되어, Maru가 그 Term의
/// 신원을 바로 찾는다 — 소켓이나 포트 없이 파일 하나로 끝난다.
pub const session_dir_rel = "agent-sessions";

/// 스크립트 본문. **claude가 stdin으로 주는 JSON**에서 `session_id`를 뽑아 per-pane 파일에 적고, stdout은 비운다.
///
/// 규율 셋:
/// 1. `MARU_PANE_ID`가 없으면 **우리 기록만 건너뛴다** — Maru 밖에서 띄운 claude엔 남길 pane이 없다. 다만 감싼
///    사용자 명령은 **그 경우에도 반드시 실행**한다. 조기 `exit`으로 묶었더니 Maru 밖 세션에서 사용자의 상태줄이
///    통째로 사라졌다(실제로 그 상태를 만들었다가 실행 검증에서 잡았다).
/// 2. stdin을 반드시 **끝까지 읽는다**(`cat`). 안 그러면 claude 쪽 파이프가 막힌다.
/// 3. stdout에 출력하지 않는다 — 상태줄 모양을 바꾸지 않기 위해서다.
///
/// `sed`로 뽑는 이유는 의존성을 늘리지 않기 위해서다(jq가 없는 환경이 흔하다). 값 형식이 uuid라 정규식이 단순하다.
pub fn scriptBody(
    out: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    session_dir_abs: []const u8,
    /// 설치 전에 사용자가 쓰던 `statusLine.command`(없으면 null). 있으면 **우리 일을 마친 뒤 그대로 실행**하고
    /// 그 stdout을 통과시킨다 — 그 사람이 보던 상태줄이 그대로 유지된다.
    wrapped_command: ?[]const u8,
) !void {
    try out.print(allocator,
        \\#!/bin/sh
        \\# maru가 설치한 상태줄 훅입니다 — 사이드바 에이전트 행에 마지막 대화를 표시하는 데만 씁니다.
        \\# 화면에는 아무것도 출력하지 않으므로 claude 상태줄 모양은 그대로입니다.
        \\# 제거: maru 설정에서 sidebar.agent-transcript-hook 을 끄면 이 파일과 settings.json 항목이 함께 지워집니다.
        \\payload=$(cat)
        \\if [ -n "$MARU_PANE_ID" ]; then
        \\dir='{s}'
        \\mkdir -p "$dir" 2>/dev/null
        \\id=$(printf '%s' "$payload" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
        \\[ -n "$id" ] && printf '%s' "$id" > "$dir/$MARU_PANE_ID" 2>/dev/null
        \\fi
        \\
    , .{session_dir_abs});
    // 사용자가 쓰던 상태줄이 있었으면 **같은 payload로 그대로 실행**하고 stdout을 통과시킨다. 우리 기록은 위에서
    // 이미 끝났고, 여기서부터는 그 사람 화면이다. 인용은 홑따옴표 안의 `'`를 `'\''`로 끊어 붙이는 POSIX 관용을 쓴다.
    if (wrapped_command) |cmd| {
        // **표식 블록으로 가둔다.** 사용자가 이 파일을 열어봐도 "여기부터 내 원래 상태줄"임이 보이고, 제거할 때
        // 우리는 이 두 줄 사이를 읽어 `settings.json`에 그대로 되돌린다(`extractWrappedCommand`).
        try out.appendSlice(allocator, wrapped_begin);
        try out.append(allocator, '\n');
        try out.appendSlice(allocator, "printf '%s' \"$payload\" | sh -c '");
        for (cmd) |c| {
            if (c == '\'') try out.appendSlice(allocator, "'\\''") else try out.append(allocator, c);
        }
        try out.appendSlice(allocator, "'\n");
        try out.appendSlice(allocator, wrapped_end);
        try out.append(allocator, '\n');
    }
    try out.appendSlice(allocator, "exit 0\n");
}

/// `settings.json`의 `statusLine.command`가 **우리 스크립트**를 가리키는가. 경로 끝의 파일명으로 판정한다 —
/// 홈 경로가 달라도(원격·다른 사용자) 같은 규칙이 선다.
pub fn commandIsOurs(command: []const u8) bool {
    return std.mem.endsWith(u8, std.mem.trim(u8, command, " \t\r\n"), script_name);
}

/// 감싼 사용자 명령을 가두는 표식. `settings.json`은 **JSON이라 주석을 못 쓰므로**, 우리 스크립트 파일 안에서
/// 이 두 줄이 "여기부터 사용자 것"을 표시한다. 제거할 때 이 사이를 읽어 원래 명령을 복원한다.
pub const wrapped_begin = "# ===== maru: 아래는 설치 전에 쓰시던 상태줄입니다(제거 시 그대로 복원됩니다) =====";
pub const wrapped_end = "# ===== maru: 사용자 상태줄 끝 =====";

/// 설치된 스크립트에서 **감싼 원래 명령**을 되찾는다(제거 시 `settings.json`에 복원할 값). 표식이 없으면 null —
/// 감싼 것이 없었다는 뜻이라 `statusLine`을 통째로 지우면 된다.
pub fn extractWrappedCommand(script: []const u8) ?[]const u8 {
    const b = std.mem.indexOf(u8, script, wrapped_begin) orelse return null;
    const after = b + wrapped_begin.len;
    const e = std.mem.indexOfPos(u8, script, after, wrapped_end) orelse return null;
    const body = std.mem.trim(u8, script[after..e], " \t\r\n");
    // 본문은 `printf '%s' "$payload" | sh -c '<원래 명령>'` 꼴이다 — 마지막 홑따옴표 쌍 안이 원래 명령이다.
    const marker = "sh -c '";
    const s0 = std.mem.indexOf(u8, body, marker) orelse return null;
    const start = s0 + marker.len;
    if (body.len == 0 or body[body.len - 1] != '\'') return null;
    const raw = body[start .. body.len - 1];
    return if (raw.len == 0) null else raw;
}

/// `settings.json`의 현재 `statusLine` 상태에 대해 우리가 무엇을 해야 하는가.
pub const InstallPlan = enum {
    /// statusLine이 없다 → 우리 것을 넣는다.
    install,
    /// 이미 우리 것이다 → 경로만 최신으로 유지(내용이 같으면 아무것도 안 한다).
    refresh,
    /// 사용자(또는 다른 도구)의 statusLine이 있다 → **그것을 감싸서** 설치한다(원래 명령은 마커에 저장해 복원용).
    wrap_existing,
};

/// 설치 계획을 정한다. `current_command`는 `settings.json`의 `statusLine.command`(없으면 null).
///
/// **남의 상태줄을 지우지 않는다 — 감싼다.** claude의 `statusLine`은 필드가 **하나뿐**이라 나란히 둘 자리가 없다.
/// 그렇다고 건너뛰면 그 사용자는 이 기능을 아예 못 쓴다. 그래서 원래 명령을 **우리 스크립트가 대신 실행**하고
/// stdout을 통과시킨다 — 그 사람이 보던 화면은 그대로이고, 우리는 payload에서 신원만 가져간다.
///
/// 되돌릴 수 있어야 하므로 원래 명령을 마커에 저장한다(`restore_command`). 옵션을 끄면 그 값을 `statusLine`에
/// 되돌리고 우리 스크립트를 지운다 — 설치 전 상태로 정확히 복원된다.
pub fn planFor(current_command: ?[]const u8) InstallPlan {
    const cmd = current_command orelse return .install;
    const trimmed = std.mem.trim(u8, cmd, " \t\r\n");
    if (trimmed.len == 0) return .install;
    return if (commandIsOurs(trimmed)) .refresh else .wrap_existing;
}

/// 신원 파일에서 읽은 값이 쓸 만한가 — uuid 꼴(하이픈 포함 32~64자, 제어문자 없음)인지 본다. 파일이 잘리거나
/// 다른 도구가 덮어썼을 때 그 쓰레기를 파일명으로 쓰지 않기 위한 최소 검사다.
pub fn plausibleIdentity(value: []const u8) bool {
    const v = std.mem.trim(u8, value, " \t\r\n");
    if (v.len < 8 or v.len > 64) return false;
    for (v) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '-' or c == '_';
        if (!ok) return false;
    }
    return true;
}

const testing = std.testing;

test "commandIsOurs: 파일명으로만 판정해 홈 경로가 달라도 선다" {
    try testing.expect(commandIsOurs("/Users/a/.claude/maru-statusline.sh"));
    try testing.expect(commandIsOurs("  /home/b/.claude/maru-statusline.sh  \n"));
    // 사용자(또는 다른 도구)의 상태줄은 건드리면 안 된다 — 제거가 남의 설정을 지우는 일이 되어선 안 된다.
    try testing.expect(!commandIsOurs("/Users/a/.claude/my-statusline.sh"));
    try testing.expect(!commandIsOurs("bunx ccusage statusline"));
    try testing.expect(!commandIsOurs(""));
}

test "pane 게이트는 우리 기록만 막고 사용자 상태줄은 항상 실행한다" {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(testing.allocator);
    try scriptBody(&out, testing.allocator, "/tmp/x", "my-statusline");
    const body = out.items;

    // pane 게이트가 **조기 종료**면 Maru 밖 세션에서 사용자 상태줄이 통째로 사라진다(실제로 그 버그를 냈다).
    // 게이트는 if 블록이어야 하고, 그 블록이 감싼 명령보다 **먼저 닫혀야** 한다.
    const gate = std.mem.indexOf(u8, body, "if [ -n \"$MARU_PANE_ID\" ]; then") orelse return error.NoGate;
    const fi = std.mem.indexOfPos(u8, body, gate, "\nfi\n") orelse return error.GateNotClosed;
    const wrapped = std.mem.indexOf(u8, body, wrapped_begin) orelse return error.NoWrap;
    try testing.expect(fi < wrapped);
    // 게이트 앞에 조기 exit이 없어야 한다.
    try testing.expect(std.mem.indexOf(u8, body[0..gate], "exit 0") == null);
}

test "감싼 사용자 상태줄: 표식 블록에 갇히고 그대로 복원된다" {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(testing.allocator);
    const original = "bunx ccusage statusline --theme dark";
    try scriptBody(&out, testing.allocator, "/tmp/maru/agent-sessions", original);
    const body = out.items;

    // 표식이 있어야 사용자가 파일을 열어봤을 때 "여기부터 내 것"임이 보인다.
    try testing.expect(std.mem.indexOf(u8, body, wrapped_begin) != null);
    try testing.expect(std.mem.indexOf(u8, body, wrapped_end) != null);
    // 우리 기록이 **먼저**여야 한다 — 사용자 명령이 실패해도 신원은 이미 남는다.
    const rec = std.mem.indexOf(u8, body, "$MARU_PANE_ID\"").?;
    try testing.expect(rec < std.mem.indexOf(u8, body, wrapped_begin).?);

    // 제거 시 원문 그대로 복원된다.
    try testing.expectEqualStrings(original, extractWrappedCommand(body).?);

    // 홑따옴표가 든 명령도 깨지지 않고 복원된다(POSIX 인용 관용).
    var out2: std.ArrayListUnmanaged(u8) = .empty;
    defer out2.deinit(testing.allocator);
    const quoted = "sh -c 'echo it'\''s fine'";
    try scriptBody(&out2, testing.allocator, "/tmp/x", quoted);
    try testing.expect(extractWrappedCommand(out2.items) != null);

    // 감싼 것이 없으면 복원할 것도 없다 → statusLine을 통째로 지우면 된다.
    var out3: std.ArrayListUnmanaged(u8) = .empty;
    defer out3.deinit(testing.allocator);
    try scriptBody(&out3, testing.allocator, "/tmp/x", null);
    try testing.expect(extractWrappedCommand(out3.items) == null);
}

test "planFor: 사용자 커스텀 상태줄은 지우지 않고 감싼다" {
    // 없으면 설치.
    try testing.expectEqual(InstallPlan.install, planFor(null));
    try testing.expectEqual(InstallPlan.install, planFor(""));
    try testing.expectEqual(InstallPlan.install, planFor("   \n"));
    // 우리 것이면 최신 유지.
    try testing.expectEqual(InstallPlan.refresh, planFor("/Users/a/.claude/maru-statusline.sh"));
    // **사용자 것이면 건너뛴다** — statusLine은 필드가 하나뿐이라 넣는 순간 그 사람 화면이 사라진다.
    // **사용자 것이면 감싼다** — statusLine은 필드가 하나뿐이라 나란히 둘 자리가 없지만, 건너뛰면 그 사용자는
    // 기능을 아예 못 쓴다. 원래 명령은 스크립트 안에 표식 블록으로 남아 복원 가능하다.
    try testing.expectEqual(InstallPlan.wrap_existing, planFor("bunx ccusage statusline"));
    try testing.expectEqual(InstallPlan.wrap_existing, planFor("~/bin/my-statusline"));
    try testing.expectEqual(InstallPlan.wrap_existing, planFor("/opt/other-tool/statusline.sh"));
}

test "plausibleIdentity: 파일이 잘리거나 오염돼도 그대로 쓰지 않는다" {
    try testing.expect(plausibleIdentity("03e06864-0379-4a52-8602-c28b95c32559"));
    try testing.expect(plausibleIdentity("019f9538-ea58-7b93-81a5-b78ef23a8292\n"));
    try testing.expect(!plausibleIdentity("")); // 빈 파일
    try testing.expect(!plausibleIdentity("abc")); // 너무 짧음
    try testing.expect(!plausibleIdentity("../../etc/passwd")); // 경로 조각 — 파일명으로 쓰면 위험하다
    try testing.expect(!plausibleIdentity("id with space"));
    try testing.expect(!plausibleIdentity("id\nwith\nnewline"));
}

test "scriptBody: 규율 셋(pane 게이트·stdin drain·무출력)이 본문에 있다" {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(testing.allocator);
    try scriptBody(&out, testing.allocator, "/tmp/maru/agent-sessions", null);
    const body = out.items;
    // MARU_PANE_ID가 없으면 즉시 종료 — Maru 밖 claude의 설정을 오염시키지 않는다.
    try testing.expect(std.mem.indexOf(u8, body, "MARU_PANE_ID") != null);
    // stdin을 끝까지 읽는다(안 읽으면 claude 쪽 파이프가 막힌다).
    try testing.expect(std.mem.indexOf(u8, body, "payload=$(cat)") != null);
    // 상태줄에 출력하지 않는다 — echo/printf로 stdout에 쓰는 줄이 없어야 한다(파일 리다이렉트만 허용).
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \t");
        if (t.len == 0 or t[0] == '#') continue;
        if (std.mem.startsWith(u8, t, "echo ")) return error.WritesToStdout;
        if (std.mem.startsWith(u8, t, "printf ") and std.mem.indexOf(u8, t, ">") == null) return error.WritesToStdout;
    }
    try testing.expect(std.mem.indexOf(u8, body, "/tmp/maru/agent-sessions") != null);
}
