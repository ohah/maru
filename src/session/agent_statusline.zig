//! claude **상태줄 훅**으로 세션 신원을 받는 경로 — 사이드바 에이전트 행의 마지막 대화(docs/sidebar-agent-list.md
//! §7.2.2)를 "도구를 한 번도 안 쓴 세션"에서도 채우기 위한 보강이다.
//!
//! **기본 경로는 이게 아니다.** 평소에는 에이전트가 자식에게 내려주는 세션 신원(`CLAUDE_CODE_SESSION_ID`)을 읽는다
//! (§7.2.1) — 사용자 파일을 하나도 건드리지 않는다. 다만 그 값은 **자식이 존재할 때만** 읽히므로, 도구를 전혀
//! 실행하지 않는 세션은 신원을 얻지 못한다. 이 모듈은 그 빈틈을 메우되 **사용자 소유 파일을 고쳐 쓰는 대가**를
//! 치렀다. **이제 설치하지 않는다**(계약 §5, 2026-08-21) — 이 모듈에 남은 것은 지난 버전이
//! 설치해 둔 것을 **알아보고 되돌리는** 규칙뿐이다.
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

/// 설치 마커 파일명(스크립트와 같은 디렉터리). **감쌌던 원래 명령의 단일 출처**이고, read-modify-write 전체를
/// 인스턴스 사이에서 직렬화하는 **락 대상**이다.
///
/// 스크립트 안의 표식 블록은 사람이 읽으라고 있는 것이지 우리가 믿는 근거가 아니다 — 그 파일은 우리가 매 실행마다
/// 덮어쓰므로, 그 안의 wrap을 유일한 근거로 삼으면 wrap 없는 본문을 **한 번** 쓰는 순간 원본이 영구 소실된다.
/// 실제로 그렇게 잃었다(인스턴스 여럿이 엇갈려 `refresh` + wrap 없음으로 판정 — docs/sidebar-agent-list.md §7.2.2).
pub const marker_name = ".maru-statusline-installed";

/// 마커 1행 — 포맷 식별자. 이 줄로 시작하지 않으면 우리 마커가 아니고, 그때는 "감쌀 것이 없었다"가 아니라
/// **"모른다"**로 접힌다(그 구분이 `actionFor`의 안전장치를 만든다).
///
/// v2에서 본문 **길이**를 함께 적는다. v1은 "본문은 파일 끝까지"라 잘린 마커가 **짧고 틀린 명령으로 유효하게
/// 파싱됐다** — 적대 검증이 절단 길이를 전수로 돌려 25개의 위험한 파싱을 실측했다. "잘리면 파싱이 실패해 안전
/// 방향으로 접힌다"는 설계 주장이 거짓이었고, 그 값이 옵션을 끌 때 사용자 `settings.json`에 복원됐다.
pub const marker_header = "maru-statusline v2";

/// 설치 마커의 내용. `wrapped == null`은 **설치 시점에 감쌀 것이 없었다는 확정**이다 — 마커 자체가 없거나 깨진
/// 경우(= 모른다)와 다르다.
pub const Marker = struct {
    wrapped: ?[]const u8,
};

/// 마커를 읽는다. null = 우리 마커가 아니거나 잘렸다 → **모른다**.
///
/// 본문 길이가 적힌 값과 **정확히** 같아야 한다. 길이 없이 "끝까지"로 읽던 v1은 어느 지점에서 잘려도 유효한
/// 명령으로 파싱돼(적대 검증 실측) 잘린 쓰레기가 사용자 `settings.json`에 복원될 수 있었다.
pub fn parseMarker(text: []const u8) ?Marker {
    var it = std.mem.splitScalar(u8, text, '\n');
    const header = std.mem.trim(u8, it.next() orelse return null, " \t\r");
    if (!std.mem.eql(u8, header, marker_header)) return null;
    const flag = std.mem.trim(u8, it.next() orelse return null, " \t\r");
    if (std.mem.eql(u8, flag, "wrapped 0")) return .{ .wrapped = null };
    const prefix = "wrapped 1 ";
    if (!std.mem.startsWith(u8, flag, prefix)) return null;
    const len = std.fmt.parseInt(usize, flag[prefix.len..], 10) catch return null;
    const rest = it.rest();
    // 길이가 어긋나면 잘렸거나 오염된 것이다. 빈 명령·짧은 명령을 감싸는 것보다 "모른다"가 안전하다.
    if (len == 0 or rest.len != len) return null;
    return .{ .wrapped = rest };
}

/// 스크립트가 세션 신원을 적는 디렉터리(캐시 루트 기준). Term의 `MARU_PANE_ID`가 파일명이 되어, Maru가 그 Term의
/// 신원을 바로 찾는다 — 소켓이나 포트 없이 파일 하나로 끝난다.
pub const session_dir_rel = "agent-sessions";

/// claude 설정 디렉터리 규칙 — `$CLAUDE_CONFIG_DIR`이 있으면 그것, 없으면 `<home>/.claude`(claude 자신의 규칙).
/// env 조회는 platform이 하고 여기서는 값만 받아 규칙을 적용한다. 결과는 `buf` 소유이고, `home`도 없으면 null.
///
/// **훅 설치와 트랜스크립트 읽기가 이 한 판정을 공유해야 한다** — 한쪽만 `<home>/.claude`로 고정하면
/// `CLAUDE_CONFIG_DIR`을 쓰는 사용자에게 훅은 엉뚱한 곳에 설치되고 대화 줄은 영원히 빈다.
pub fn configDir(buf: []u8, config_dir_env: ?[]const u8, home: ?[]const u8) ?[]const u8 {
    const resolved = blk: {
        if (config_dir_env) |dir| {
            if (dir.len > 0) break :blk std.fmt.bufPrint(buf, "{s}", .{dir}) catch null;
        }
        break :blk std.fmt.bufPrint(buf, "{s}/.claude", .{home orelse return null}) catch null;
    } orelse return null;
    // ⚠️ **절대경로가 아니면 없는 것으로 본다.** 소비자가 `openDirAbsolute` 로 여는데 그 함수는 상대경로에
    // `assert` 로 **죽는다** — `catch` 로 못 막는 종류다. HOME 이 상대경로인 환경에서 실제로 앱 전체가
    // abort 했다(제품 스모크 `macos-session-host-c4-quit-cancel-smoke` 가 HOME 을 `zig-out/…` 상대경로로
    // 띄운다 — 2026-08-31 CI 와 로컬에서 같은 자리에서 죽었다).
    //
    // 값 자체로도 그것이 맞다: 이 경로는 **다른 프로세스**(claude CLI)가 해석하는 자리라, 우리 cwd 에
    // 따라 달라지는 상대경로면 훅을 설치해서도 안 된다.
    if (!std.fs.path.isAbsolute(resolved)) return null;
    return resolved;
}

test "configDir는 CLAUDE_CONFIG_DIR 우선, 없으면 home 기준" {
    var buf: [512]u8 = undefined;
    try testing.expectEqualStrings("/opt/claude", configDir(&buf, "/opt/claude", "/Users/a").?);
    try testing.expectEqualStrings("/Users/a/.claude", configDir(&buf, null, "/Users/a").?);
    // 빈 값은 "설정하지 않음"과 같게 본다 — 빈 경로에 설치하면 루트에 파일을 만든다.
    try testing.expectEqualStrings("/Users/a/.claude", configDir(&buf, "", "/Users/a").?);
    try testing.expectEqual(@as(?[]const u8, null), configDir(&buf, null, null));
    // **상대경로는 없는 것으로 본다.** 소비자가 `openDirAbsolute` 로 여는데 그 함수는 상대경로에 assert 로
    // 죽는다(`catch` 가 못 막는다) — HOME 이 상대경로인 제품 스모크에서 앱이 통째로 abort 했다.
    try testing.expectEqual(@as(?[]const u8, null), configDir(&buf, null, "zig-out/home"));
    try testing.expectEqual(@as(?[]const u8, null), configDir(&buf, "relative/claude", "/Users/a"));
    try testing.expectEqual(@as(?[]const u8, null), configDir(&buf, null, "."));
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

/// 설치된 스크립트에서 **감싼 원래 명령**을 되찾는다 — 마커가 없을 때의 폴백이다(마커가 단일 출처).
///
/// 스크립트 안의 명령은 `sh -c '…'`에 넣으려고 홑따옴표를 끊어 붙인 꼴이라 **되돌려 원문으로 만든다**. 풀지 않으면
/// 다음 설치가 그 결과를 다시 이스케이프해 갱신마다 한 겹씩 쌓이고, 홑따옴표가 든 명령이 서서히 망가진다.
/// 결과는 호출부 소유다(할당). 표식이 없거나 할당에 실패하면 null.
pub fn extractWrappedCommand(allocator: std.mem.Allocator, script: []const u8) ?[]const u8 {
    const raw = wrappedCommandRaw(script) orelse return null;
    return unquoteSingleQuoted(allocator, raw) catch null;
}

/// 표식 블록 안에서 **이스케이프된 그대로의** 명령 조각을 집는다(스크립트 소유 slice).
fn wrappedCommandRaw(script: []const u8) ?[]const u8 {
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

/// `'\''`(홑따옴표를 끊어 붙이는 POSIX 관용)를 홑따옴표 하나로 되돌린다. `scriptBody`의 역함수다.
fn unquoteSingleQuoted(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < raw.len) {
        if (std.mem.startsWith(u8, raw[i..], "'\\''")) {
            try out.append(allocator, '\'');
            i += "'\\''".len;
        } else {
            try out.append(allocator, raw[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

/// `settings.json`에서 읽어낸 `statusLine` 상태.
///
/// **"없다"와 "못 읽었다"는 절대 같지 않다.** 후자를 전자로 접으면 "이 사람은 상태줄이 원래 없었다"를 **확정**으로
/// 기록하게 되고, 그 확정이 나중에 사용자 명령을 지운다. 이 훅이 낸 사고가 정확히 그 접힘이었다 —
/// 근거를 잃은 자리에서 모르는 것을 아는 것처럼 다룬 것.
pub const SettingsState = union(enum) {
    /// 파일을 읽지 못했거나(권한·크기·중간 쓰기) JSON이 아니다 → **아무것도 하지 않는다**.
    unreadable,
    /// 파일은 정상이고 `statusLine`이 없다(확정).
    absent,
    /// `statusLine.command`가 있다.
    command: []const u8,
};

/// 설치된 스크립트 파일의 상태. `settings`와 같은 이유로 **없음과 못 읽음을 가른다** — 0바이트 스크립트는
/// 비원자 쓰기가 남기던 잔해이고, 그것을 "없음"으로 접으면 재생성 예외를 타서 감싼 명령이 사라진다.
pub const ScriptState = enum { absent, unreadable, present };

/// 옵션을 껐을 때 `settings.json`을 어떻게 할 것인가.
pub const RestoreAction = union(enum) {
    /// 현재 상태를 읽지 못했다 — `settings.json`도, **우리 파일도** 건드리지 않는다. 지우고 나면 되돌릴
    /// 근거가 사라지므로, 못 읽은 김에 지우는 것이 가장 나쁜 선택이다.
    unknown,
    /// 우리 것이 아니다 — `settings.json`은 그대로 두고 우리 파일만 거둔다.
    leave,
    /// 감쌌던 원래 명령으로 되돌린다.
    set: []const u8,
    /// `statusLine` 키를 지운다(설치 전 = 상태줄 없음).
    clear,
};

/// 복원 대상을 정한다 — **마커 → 스크립트 wrap** 순. 둘 다 없으면(마커 이전 설치) 키를 지운다: 우리 스크립트를
/// 지우면서 그것을 가리키는 포인터를 남길 수는 없다.
pub fn restoreActionFor(
    settings: SettingsState,
    marker: ?Marker,
    script_wrapped: ?[]const u8,
) RestoreAction {
    const cmd = switch (settings) {
        .unreadable => return .unknown,
        .absent => return .leave,
        .command => |c| c,
    };
    if (!commandIsOurs(cmd)) return .leave;
    if (marker) |m| return if (m.wrapped) |w| .{ .set = w } else .clear;
    if (script_wrapped) |w| return .{ .set = w };
    return .clear;
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

// ── 테스트 전용: 지난 버전이 설치해 둔 모양 ──────────────────────────────────────────────────
//
// 제품 경로는 이제 **거두기만** 한다(계약 §5). 그래도 이 둘은 남긴다 — 복원 규칙이 읽어야 하는
// 것이 «지난 버전이 쓴 바로 그 바이트» 이기 때문이다. 손으로 적은 리터럴로 바꾸면 그 모양이 실제
// 산출물과 조용히 갈리고, 그러면 테스트는 통과하는데 사용자 파일은 못 읽는 상태가 된다.

/// 마커 본문을 만든다. 명령은 **바이트 그대로** 두므로 이스케이프가 없고(개행이 든 명령도 그대로 산다), 대신
/// 길이를 함께 적어 잘림을 검출한다.
fn markerBody(
    out: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    wrapped: ?[]const u8,
) !void {
    try out.appendSlice(allocator, marker_header);
    if (wrapped) |cmd| {
        try out.print(allocator, "\nwrapped 1 {d}\n", .{cmd.len});
        try out.appendSlice(allocator, cmd);
    } else {
        try out.appendSlice(allocator, "\nwrapped 0\n");
    }
}

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
fn scriptBody(
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

const testing = std.testing;

test "commandIsOurs: 파일명으로만 판정해 홈 경로가 달라도 선다" {
    try testing.expect(commandIsOurs("/Users/a/.claude/maru-statusline.sh"));
    try testing.expect(commandIsOurs("  /home/b/.claude/maru-statusline.sh  \n"));
    // 사용자(또는 다른 도구)의 상태줄은 건드리면 안 된다 — 제거가 남의 설정을 지우는 일이 되어선 안 된다.
    try testing.expect(!commandIsOurs("/Users/a/.claude/my-statusline.sh"));
    try testing.expect(!commandIsOurs("bunx ccusage statusline"));
    try testing.expect(!commandIsOurs(""));
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
    const restored = extractWrappedCommand(testing.allocator, body).?;
    defer testing.allocator.free(restored);
    try testing.expectEqualStrings(original, restored);

    // 감싼 것이 없으면 복원할 것도 없다 → statusLine을 통째로 지우면 된다.
    var out3: std.ArrayListUnmanaged(u8) = .empty;
    defer out3.deinit(testing.allocator);
    try scriptBody(&out3, testing.allocator, "/tmp/x", null);
    try testing.expect(extractWrappedCommand(testing.allocator, out3.items) == null);
}

test "홑따옴표가 든 명령은 왕복해도 한 겹도 쌓이지 않는다" {
    // `!= null`만 보던 검사로는 **이스케이프가 풀리지 않은 채 되돌아오는** 것을 못 잡았다. 그 값이 다음 설치에서
    // 다시 이스케이프되어 갱신마다 한 겹씩 쌓이고, 사용자의 명령이 서서히 망가진다. 동치로 못을 박는다.
    const quoted = "echo it's fine | sh -c 'cat'";
    var first: std.ArrayListUnmanaged(u8) = .empty;
    defer first.deinit(testing.allocator);
    try scriptBody(&first, testing.allocator, "/tmp/x", quoted);

    const once = extractWrappedCommand(testing.allocator, first.items).?;
    defer testing.allocator.free(once);
    try testing.expectEqualStrings(quoted, once);

    // 되찾은 값으로 다시 설치해도(= 매 실행의 refresh) 스크립트 본문이 **바이트 그대로**여야 한다.
    var second: std.ArrayListUnmanaged(u8) = .empty;
    defer second.deinit(testing.allocator);
    try scriptBody(&second, testing.allocator, "/tmp/x", once);
    try testing.expectEqualStrings(first.items, second.items);
}

test "마커: 감쌀 것이 없었다와 모른다를 구분한다" {
    var with: std.ArrayListUnmanaged(u8) = .empty;
    defer with.deinit(testing.allocator);
    const original = "sh ~/.claude/statusline-command.sh";
    try markerBody(&with, testing.allocator, original);
    try testing.expectEqualStrings(original, parseMarker(with.items).?.wrapped.?);

    // 개행이 든 명령도 바이트 그대로 산다.
    var multi: std.ArrayListUnmanaged(u8) = .empty;
    defer multi.deinit(testing.allocator);
    const two_lines = "printf a\nprintf b";
    try markerBody(&multi, testing.allocator, two_lines);
    try testing.expectEqualStrings(two_lines, parseMarker(multi.items).?.wrapped.?);

    // 감쌀 것이 없었음 = **확정**(null wrapped), 마커 부재/손상 = 모름(마커 자체가 null).
    var none: std.ArrayListUnmanaged(u8) = .empty;
    defer none.deinit(testing.allocator);
    try markerBody(&none, testing.allocator, null);
    try testing.expectEqual(@as(?[]const u8, null), parseMarker(none.items).?.wrapped);

    try testing.expectEqual(@as(?Marker, null), parseMarker(""));
    try testing.expectEqual(@as(?Marker, null), parseMarker("남의 파일이다"));
    try testing.expectEqual(@as(?Marker, null), parseMarker(marker_header)); // 잘림(플래그 없음)
    // v1 포맷(길이 없음)은 우리 것이 아니다 → 모른다. 길이가 어긋난 것도 마찬가지.
    try testing.expectEqual(@as(?Marker, null), parseMarker(marker_header ++ "\nwrapped 1\nls"));
    try testing.expectEqual(@as(?Marker, null), parseMarker(marker_header ++ "\nwrapped 1 9\nls"));
}

test "마커: 어느 지점에서 잘려도 명령으로 파싱되지 않는다" {
    // 적대 검증이 실측으로 깬 주장 — v1은 "본문은 파일 끝까지"라 절단 지점마다 **짧고 틀린 명령**이 유효하게
    // 파싱됐고, 그 쓰레기가 옵션을 끌 때 사용자 `settings.json`에 복원됐다. 길이 필드가 그것을 막는다.
    const original = "sh /Users/me/statusline-command.sh --theme dark";
    var full: std.ArrayListUnmanaged(u8) = .empty;
    defer full.deinit(testing.allocator);
    try markerBody(&full, testing.allocator, original);

    var cut: usize = 0;
    while (cut < full.items.len) : (cut += 1) {
        if (parseMarker(full.items[0..cut])) |m| {
            std.debug.print("잘린 마커(len={d})가 파싱됐다: {?s}\n", .{ cut, m.wrapped });
            return error.TruncatedMarkerParsed;
        }
    }
    // 온전한 길이에서만 파싱된다.
    try testing.expectEqualStrings(original, parseMarker(full.items).?.wrapped.?);
}

test "restoreActionFor: 마커가 스크립트보다 앞서고, 모르면 아무것도 안 한다" {
    const ours: SettingsState = .{ .command = "/Users/a/.claude/maru-statusline.sh" };
    const user = "sh ~/.claude/statusline-command.sh";
    const stale = "bunx ccusage statusline";

    // 사용자가 그 사이 자기 것으로 바꿔놨으면 settings는 건드리지 않는다(우리 파일만 거둔다).
    try testing.expectEqual(RestoreAction.leave, restoreActionFor(.{ .command = user }, .{ .wrapped = user }, null));
    try testing.expectEqual(RestoreAction.leave, restoreActionFor(.absent, null, null));
    // **못 읽었으면 아무것도 하지 않는다** — 지우고 나면 되돌릴 근거가 사라진다(적대 검증 F2/M4).
    try testing.expectEqual(RestoreAction.unknown, restoreActionFor(.unreadable, .{ .wrapped = user }, user));

    // 마커가 단일 출처 — 스크립트에 다른 값이 남아 있어도 마커를 따른다.
    switch (restoreActionFor(ours, .{ .wrapped = user }, stale)) {
        .set => |cmd| try testing.expectEqualStrings(user, cmd),
        else => return error.MarkerNotPreferred,
    }
    // 마커가 "없었음"을 확정하면 설치 전 상태 = statusLine 없음.
    try testing.expectEqual(RestoreAction.clear, restoreActionFor(ours, .{ .wrapped = null }, null));
    // 마커가 없으면 스크립트 wrap이 폴백이다.
    switch (restoreActionFor(ours, null, user)) {
        .set => |cmd| try testing.expectEqualStrings(user, cmd),
        else => return error.ScriptFallbackIgnored,
    }
    // 둘 다 없으면(마커 이전 설치) 우리 스크립트를 지우면서 그 포인터를 남길 수 없다.
    try testing.expectEqual(RestoreAction.clear, restoreActionFor(ours, null, null));
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
