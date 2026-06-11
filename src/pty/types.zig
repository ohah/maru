const std = @import("std");
const terminal = @import("../terminal.zig");

/// 대화형 shell 경로를 한 곳에서 결정한다. 진입점(main, app dev session, metal smoke)마다
/// 복사하면 fallback이나 trim 정책이 갈라진다(실제로 `/bin/sh` vs `/bin/zsh`, trim 유무로
/// 어긋나 있었다). 환경값은 앞뒤 공백을 제거해 trailing newline이 경로에 섞여 spawn이
/// 실패하는 것을 막고, 우선순위는 `MARU_INTERACTIVE_SHELL` -> `SHELL` -> `/bin/sh`다.
/// 반환 slice는 process environ 또는 정적 리터럴을 가리키므로 caller가 소유/해제하지 않는다.
pub fn resolveInteractiveShell() []const u8 {
    if (std.c.getenv("MARU_INTERACTIVE_SHELL")) |raw| {
        const value = std.mem.trim(u8, std.mem.span(raw), " \t\r\n");
        if (value.len > 0) return value;
    }
    if (std.c.getenv("SHELL")) |raw| {
        const value = std.mem.trim(u8, std.mem.span(raw), " \t\r\n");
        if (value.len > 0) return value;
    }
    return "/bin/sh";
}

pub const Backend = enum {
    macos_openpty,
    windows_conpty,
    remote_websocket,
};

pub const ExitStatus = union(enum) {
    exited: u8,
    signaled: u8,
    unknown: i32,
};

// PtyEvent는 PTY backend가 SurfaceRuntime으로 올리는 최소 domain event다.
// escape parsing은 TerminalCore 책임이므로 output은 해석하지 않은 bytes로 유지한다.
pub const PtyEvent = union(enum) {
    output: []u8,
    exited: ExitStatus,

    pub fn deinit(self: PtyEvent, allocator: @import("std").mem.Allocator) void {
        switch (self) {
            .output => |bytes| allocator.free(bytes),
            .exited => {},
        }
    }
};

pub const PtyHandle = struct {
    backend: Backend,
    size: terminal.Size,
};

pub const SpawnRequest = struct {
    // command는 shell을 거치지 않고 execve에 직접 넘길 실행 파일 경로다.
    // 이렇게 두면 테스트에서 shell quoting과 process spawning 책임을 분리할 수 있다.
    command: []const u8,
    args: []const []const u8 = &.{},
    cwd: ?[]const u8 = null,
    // login shell로 띄울지. macOS backend는 true면 `login(1)`으로 감싸 전체 로그인 세션(getlogin·
    // SHELL·utmp·hushlogin)을 셋업한 뒤 셸을 login shell로 exec한다(Terminal.app·Ghostty와 동일).
    // 그래야 PATH·EDITOR·키바인딩(예: `bindkey -e`)과 $TERM_PROGRAM 의존 셸 설정까지 완전히 잡힌다.
    // non-login이면 .zshrc만 읽어 키맵이 달라질 수 있다(예: $EDITOR=nvim → vi-keymap → Ctrl+A·E
    // self-insert → Cmd+←/→가 줄 시작/끝으로 안 감).
    login: bool = false,
    env: []const []const u8 = &.{},
    // env가 빈(부모 상속) 경로에서 셸에 줄 TERM 값. 사용자 config(`term =`)로 바꿀 수 있다 —
    // 일부 셸 설정/통합이 $TERM에 따라 키바인딩을 다르게 잡기 때문이다(예: Ctrl+A 줄-시작).
    // env를 명시로 넘기면(테스트) 이 값은 무시된다.
    term: []const u8 = "xterm-256color",
    size: terminal.Size = terminal.Size.default,
};

pub fn plannedBackendForMacOS() Backend {
    return .macos_openpty;
}

test "macOS backend is openpty" {
    try @import("std").testing.expectEqual(Backend.macos_openpty, plannedBackendForMacOS());
}
