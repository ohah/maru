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
    // 에이전트 훅 전용의 Term별 임의 매핑 id. 셸에 MARU_AGENT_MAPPING_ID=<이 값>으로 주입한다. surface.id와
    // 분리되어 별도 maru 프로세스가 같은 surface 숫자를 발급해도 매핑 파일이 충돌하지 않는다.
    agent_mapping_id: ?u64 = null,
    size: terminal.Size = terminal.Size.default,
};

/// captureAgentArgv가 KERN_PROCARGS2로 캡처한 결과 — exec_path(실제 실행 파일 절대경로)와 전체 argv. 두 슬라이스
/// 모두 호출자가 넘긴 버퍼를 가리킨다(정적 procargs_buf 수명에 안 묶임). 백엔드 간 공유 타입이라 types에 둔다 —
/// macOS 캡처(macos.zig)와 비-macOS 스텁(session.zig)이 같은 시그니처로 컴파일되게.
pub const ProcArgs = struct {
    exec_path: []const u8,
    argv: []const []const u8,
};

pub fn plannedBackendForMacOS() Backend {
    return .macos_openpty;
}

test "macOS backend is openpty" {
    try @import("std").testing.expectEqual(Backend.macos_openpty, plannedBackendForMacOS());
}
