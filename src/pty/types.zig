const std = @import("std");
const terminal = @import("../terminal.zig");

/// 대화형 shell 경로를 한 곳에서 결정한다. 진입점(main, app session, metal smoke)마다
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

/// 포그라운드 process group 구성원 한 명의 식별용 이름이다. PTY backend는 OS 프로세스 열거와
/// comm/argv 해소까지만 맡고, 이 이름이 claude/codex인지 같은 제품 정책은 app 계층이 판정한다.
/// 고정 버퍼라 주기적 observer poll에서 allocator와 raw argv 로그를 만들지 않는다.
pub const ForegroundProcessName = struct {
    pid: i32 = 0,
    len: u8 = 0,
    bytes: [128]u8 = undefined,

    pub fn slice(self: *const ForegroundProcessName) []const u8 {
        return self.bytes[0..self.len];
    }
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
    // env가 비었을 때 상속할 부모 환경 snapshot. null이면 현재 프로세스 environ(일반 in-process spawn), non-null이면
    // 그 snapshot을 부모로 삼는다(session host가 GUI 재실행 시점 환경을 보존하는 transport seam).
    parent_env: ?[]const []const u8 = null,
    // 사용자 config `env.<KEY> = value`로 주입할 환경변수(각 "KEY=VALUE"). 부모 상속 env(또는 명시 env)와
    // maru override(TERM 등) **위에** upsert한다 — 같은 KEY가 있으면 덮어쓰고, 없으면 추가한다("부모 + 사용자"
    // 정책). env(전체 명시)와 달리 부모 상속을 끊지 않는다. 비어 있으면(기본) 무동작. EnvStorage.init이 적용.
    env_overrides: []const []const u8 = &.{},
    // env가 빈(부모 상속) 경로에서 셸에 줄 TERM 값. 사용자 config(`term =`)로 바꿀 수 있다 —
    // 일부 셸 설정/통합이 $TERM에 따라 키바인딩을 다르게 잡기 때문이다(예: Ctrl+A 줄-시작).
    // env를 명시로 넘기면(테스트) 이 값은 무시된다.
    term: []const u8 = "xterm-256color",
    // 셸 통합 디렉터리(zsh). 설정되면 셸에 ZDOTDIR=<이 값>을 주입하고(기존 ZDOTDIR은 MARU_ZDOTDIR_
    // PREV로 보존) zsh가 그 디렉터리의 Maru .zshenv를 로드해 macOS 편집키를 바인딩한다. null이면
    // 통합 없이 띄운다. env를 명시로 넘기면(테스트) 무시된다.
    zdotdir: ?[]const u8 = null,
    // 셸 통합 ssh 라우팅(opt-in)이 켜졌을 때 현재 maru 실행 파일 경로. 설정되면 셸에 MARU_BIN=<이 값>과
    // MARU_SSH_INTEGRATION=1을 주입한다 — 통합 .zshenv가 이 둘을 보고 `ssh`를 `maru ssh`로 라우팅하는
    // 함수를 정의한다(없으면 평범한 ssh 그대로). 이 단일 optional이 "기능 on + 바이너리 경로"를 함께
    // 인코딩한다(null이면 주입 안 함). env를 명시로 넘기면(테스트) 무시된다.
    ssh_integration_bin: ?[]const u8 = null,
    // 컨트롤 플레인 self selector인 surface.id. 셸에 MARU_PANE_ID=<surface.id>로 주입한다.
    pane_id: ?u64 = null,
    size: terminal.Size = terminal.Size.default,
};

/// 토큰 하나를 POSIX 셸의 작은따옴표로 감싸 `buf`에 붙인다. 안의 `'`는 `'\''`로 끊어 잇는다.
///
/// 셸 문자열에 사용자 데이터(경로·세션 id)를 넣는 곳이 둘 이상이라(login(1) 래핑, 아카이브 resume)
/// **메커니즘을 한 곳에 둔다**. 백슬래시 이스케이프(`shellEscapeJoin`)와 달리 따옴표 안에서는 셸이
/// 어떤 확장도 하지 않으므로, 명령 문자열을 조립할 때는 이 형태를 쓴다.
pub fn appendSingleQuoted(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), token: []const u8) !void {
    try buf.append(allocator, '\'');
    for (token) |c| {
        if (c == '\'') {
            try buf.appendSlice(allocator, "'\\''");
        } else {
            try buf.append(allocator, c);
        }
    }
    try buf.append(allocator, '\'');
}

pub fn plannedBackendForMacOS() Backend {
    return .macos_openpty;
}

test "macOS backend is openpty" {
    try @import("std").testing.expectEqual(Backend.macos_openpty, plannedBackendForMacOS());
}
