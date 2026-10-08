//! 부모 환경에서 자식에게 **물려주면 거짓이 되는** 터미널 세션 변수 — 목록 하나(중립 leaf).
//!
//! maru 가 띄우는 자식(PTY 셸 — `pty/macos.zig`·`pty/windows_spawn.zig`, 언어 서버의 환경 해석기 —
//! `session/lsp/shell_env.zig`)은 모두 이 목록을 떨군다. 예전에는 두 PTY 백엔드에 같은 목록이 손으로 있었다 — 갈리면 같은
//! 오염이 한쪽에서만 막힌다(계획 docs/plans/workspace-trust.md WT3a).
//!
//! 무엇이 왜 들어 있나:
//! - `TERM`·`COLORTERM`·`TERM_PROGRAM`·`TERM_PROGRAM_VERSION` — 바깥 터미널의 신원. PTY 는 `TERM`·`COLORTERM`·`TERM_PROGRAM` 을
//!   자기 값으로 다시 넣고(중복 키는 첫 항목이 이기므로 부모 것을 먼저 뺀다) `TERM_PROGRAM_VERSION` 은 넣지 않는다. 언어 서버는
//!   터미널 안이 아니다.
//! - `TERMINFO` — 바깥 터미널의 terminfo DB. 우리 `TERM` 을 엉뚱한 곳에서 찾는다.
//! - `CLICOLOR_FORCE`·`FORCE_COLOR` — 런처·CI 가 남긴 색 강제 override. maru 는 색 capability 를 `TERM`/`COLORTERM` 으로만
//!   알린다.
//! - `MARU_PANE_ID`·`MARU_HOOK_INSTANCE`·`MARU_HOOK_PANE` — 컨트롤 플레인 self selector·에이전트 훅 로그 경로(docs/agent-hooks.md
//!   §4). 물려받으면 다른 surface 를 자기로 오인하고 다른 인스턴스의 로그에 쓴다.
//! - `TMUX`·`TMUX_PANE` — 바깥 멀티플렉서의 신원. maru 가 띄운 자식은 그 pane 이 아니다.

const std = @import("std");

pub const terminal_session_keys = [_][]const u8{
    "TERM",               "COLORTERM",      "TERM_PROGRAM", "TERM_PROGRAM_VERSION",
    "TERMINFO",           "CLICOLOR_FORCE", "FORCE_COLOR",  "MARU_PANE_ID",
    "MARU_HOOK_INSTANCE", "MARU_HOOK_PANE", "TMUX",         "TMUX_PANE",
};

/// 환경 항목(`KEY=VALUE`)의 키. `=` 가 없으면 `null`. Windows 의 `=C:=C:\work` 처럼 이름이 `=` 로 시작하는 항목은 키가 빈다.
pub fn key(entry: []const u8) ?[]const u8 {
    const eq = std.mem.indexOfScalar(u8, entry, '=') orelse return null;
    return entry[0..eq];
}

/// 키가 `name` 인가. `ignore_case` 는 Windows(환경 이름이 대소문자를 가리지 않는다).
pub fn keyIs(entry: []const u8, name: []const u8, ignore_case: bool) bool {
    const k = key(entry) orelse return false;
    return if (ignore_case) std.ascii.eqlIgnoreCase(k, name) else std.mem.eql(u8, k, name);
}

/// 터미널 세션 변수인가(위 목록).
pub fn isTerminalSession(entry: []const u8, ignore_case: bool) bool {
    for (terminal_session_keys) |name| if (keyIs(entry, name, ignore_case)) return true;
    return false;
}

test "inherited_env: 목록의 키는 떨구고 접두만 같은 키·값 속 이름은 남긴다; Windows 는 대소문자를 가리지 않는다" {
    for (terminal_session_keys) |name| {
        var buf: [64]u8 = undefined;
        const entry = try std.fmt.bufPrint(&buf, "{s}=x", .{name});
        try std.testing.expect(isTerminalSession(entry, false));
        try std.testing.expect(isTerminalSession(entry, true));
    }
    try std.testing.expect(!isTerminalSession("TERMINAL=x", false)); // 접두만 같다
    try std.testing.expect(!isTerminalSession("PATH=/bin:TERM", false)); // 값 속 이름
    try std.testing.expect(!isTerminalSession("TERM", false)); // `=` 가 없다
    try std.testing.expect(!isTerminalSession("term=x", false));
    try std.testing.expect(isTerminalSession("term=x", true));
    try std.testing.expect(isTerminalSession("Tmux_Pane=%1", true));
}
