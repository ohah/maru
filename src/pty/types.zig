const std = @import("std");
const terminal = @import("../terminal.zig");

/// Windows에서 기본으로 띄울 셸의 종류(config `shell.windows-shell`). 값의 뜻은
/// `config/theme.zig`의 `WindowsShell`이 소유한다 — 여기서는 티어를 고르는 스위치로만 쓴다.
/// 중립 pty 레이어가 config 모듈을 import하지 않도록 같은 모양을 따로 둔다(값 전달은 호출자 몫).
pub const WindowsShellKind = enum { powershell, cmd };

/// Windows 기본 셸 후보의 **정적 경로**. 실제 기기 경로가 여기서 벗어나면(비표준 `%SystemRoot%` 등) 아래
/// `%COMSPEC%` 폴백과 `shell.command` 명시 지정이 받아 준다 — 그 두 개가 있어 정적 목록으로 충분하다.
const win_pwsh7 = "C:\\Program Files\\PowerShell\\7\\pwsh.exe";
const win_powershell51 = "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe";
const win_cmd = "C:\\Windows\\System32\\cmd.exe";

/// 후보 버퍼에 필요한 칸 수. 지금 최대는 Windows+powershell의 4(pwsh7·5.1·`%COMSPEC%`·정적 cmd)로 **정확히
/// 가득 찬다.** 버퍼 타입이 `*[max_shell_candidates]`라 티어를 하나 더 넣으면 조용히 넘치는 대신 그 자리에서
/// 경계 검사에 걸린다 — 크기를 상수로 묶어 둔 이유다(호출부가 제각기 `[4]`를 적으면 한 곳만 늘리게 된다).
pub const max_shell_candidates = 4;

/// `os_tag`와 사용자 선택으로 **후보를 우선순위 순으로** 낸다. 순수 함수다 — 파일시스템도 환경도 보지 않고
/// (`comspec`은 인자로 받는다), 그래서 테스트가 **두 OS 갈래를 모두** 돈다. OS를 컴파일 타임 분기로 두면
/// Windows 갈래가 ubuntu·macOS만 도는 CI에서 공허참이 된다(W1.5·W2에서 두 번 밟은 함정).
///
/// 계약 §3.1a의 해석 순서 중 이 함수가 맡는 부분은 **뒤쪽 티어**다. 앞쪽(`MARU_INTERACTIVE_SHELL` →
/// `shell.command`)은 각각 `resolveInteractiveShell`과 호출자(config 소비자)가 처리한다.
pub fn interactiveShellCandidates(
    os_tag: std.Target.Os.Tag,
    kind: WindowsShellKind,
    comspec: ?[:0]const u8,
    buf: *[max_shell_candidates][:0]const u8,
) []const [:0]const u8 {
    if (os_tag != .windows) {
        buf[0] = "/bin/sh";
        return buf[0..1];
    }
    var n: usize = 0;
    if (kind == .powershell) {
        buf[n] = win_pwsh7;
        n += 1;
        buf[n] = win_powershell51;
        n += 1;
    }
    // `%COMSPEC%`을 정적 cmd 경로보다 **먼저** 본다 — 비표준 설치에서 정확한 값을 아는 유일한 출처다.
    if (comspec) |c| if (c.len > 0) {
        buf[n] = c;
        n += 1;
    };
    buf[n] = win_cmd;
    n += 1;
    return buf[0..n];
}

/// 경로가 실재하는가. `std.c.access(F_OK)`는 Windows에서도 동작한다(W1.5에서 실측: 존재 0, 미존재 -1).
fn shellPathExists(path: [:0]const u8) bool {
    return std.c.access(path.ptr, std.posix.F_OK) == 0;
}

/// 대화형 shell 경로를 한 곳에서 결정한다. 진입점(main, app session, metal smoke)마다
/// 복사하면 fallback이나 trim 정책이 갈라진다(실제로 `/bin/sh` vs `/bin/zsh`, trim 유무로
/// 어긋나 있었다). 환경값은 앞뒤 공백을 제거해 trailing newline이 경로에 섞여 spawn이
/// 실패하는 것을 막는다. 반환 slice는 process environ 또는 정적 리터럴을 가리키므로 caller가
/// 소유/해제하지 않는다.
///
/// 우선순위는 OS로 갈린다(docs/windows-platform.md §3.1a):
///
/// ```text
/// POSIX    MARU_INTERACTIVE_SHELL -> SHELL -> /bin/sh
/// Windows  MARU_INTERACTIVE_SHELL -> pwsh 7 -> PowerShell 5.1 -> %COMSPEC% -> cmd.exe
/// ```
///
/// `MARU_INTERACTIVE_SHELL`은 maru 자체 변수라 OS 무관하게 1순위다. `SHELL`은 **POSIX에서만** 본다 —
/// Windows에 그 변수가 있으면 git-bash 같은 POSIX 에뮬레이션이 심어 둔 `/usr/bin/bash`라, 네이티브
/// Windows 세션의 기본으로 삼으면 사용자가 기대한 셸이 아니다.
///
/// `kind`는 config `shell.windows-shell`에서 온다. 기본값(`.powershell`)은 계약 §3.1a의 사용자 확정이다 —
/// cmd는 `OSC 133 D`를 원리적으로 못 내(§3.4) 기본이 되면 ADE가 반쯤 꺼진 채 시작한다.
pub fn resolveInteractiveShellFor(kind: WindowsShellKind) []const u8 {
    if (std.c.getenv("MARU_INTERACTIVE_SHELL")) |raw| {
        const value = std.mem.trim(u8, std.mem.span(raw), " \t\r\n");
        if (value.len > 0) return value;
    }
    if (@import("builtin").os.tag != .windows) {
        if (std.c.getenv("SHELL")) |raw| {
            const value = std.mem.trim(u8, std.mem.span(raw), " \t\r\n");
            if (value.len > 0) return value;
        }
        return "/bin/sh";
    }

    const comspec: ?[:0]const u8 = if (std.c.getenv("COMSPEC")) |raw| std.mem.span(raw) else null;
    var buf: [max_shell_candidates][:0]const u8 = undefined;
    const candidates = interactiveShellCandidates(.windows, kind, comspec, &buf);
    for (candidates) |c| if (shellPathExists(c)) return c;
    // 하나도 없으면 마지막 후보를 그대로 돌려준다 — spawn이 실패하며 진짜 원인을 말하는 편이,
    // 여기서 빈 문자열을 내 호출자가 엉뚱하게 처리하는 것보다 낫다.
    return candidates[candidates.len - 1];
}

/// `resolveInteractiveShellFor`를 config 기본값(`.powershell`)으로 부르는 얇은 래퍼. config를 아직 읽지 않는
/// 진입점(main smoke 등)이 쓴다 — config를 읽는 호출자는 `resolveInteractiveShellFor`에 사용자 선택을 넘긴다.
pub fn resolveInteractiveShell() []const u8 {
    return resolveInteractiveShellFor(.powershell);
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

/// 프로세스 하나의 자원 표본(상태바 리소스 항목 — docs/status-bar.md §6).
/// 값의 뜻은 플랫폼 어댑터가 정한다: macOS는 `ri_phys_footprint`와 user+system CPU 누적 나노초다.
/// 계산(합산·차분·포맷)은 이 타입을 받는 `session.resource_usage`가 순수하게 한다.
pub const ProcessResourceSample = struct {
    pid: i32,
    footprint_bytes: u64,
    cpu_ns: u64,
};

pub fn plannedBackendForMacOS() Backend {
    return .macos_openpty;
}

test "macOS backend is openpty" {
    try @import("std").testing.expectEqual(Backend.macos_openpty, plannedBackendForMacOS());
}

// 후보 목록은 순수라 **두 OS 갈래를 모두** 여기서 돈다 — 컴파일 타임 분기로 두면 Windows 갈래가
// ubuntu·macOS만 도는 CI에서 공허참이 된다(W1.5·W2에서 두 번 밟은 함정).
test "interactiveShellCandidates: POSIX는 /bin/sh 하나, Windows는 티어 순서" {
    const t = std.testing;
    var buf: [max_shell_candidates][:0]const u8 = undefined;

    // 비-Windows는 종류와 무관하게 하나다 — `SHELL`·`MARU_INTERACTIVE_SHELL`은 호출자가 먼저 본다.
    for ([_]std.Target.Os.Tag{ .macos, .linux }) |os| {
        for ([_]WindowsShellKind{ .powershell, .cmd }) |kind| {
            const c = interactiveShellCandidates(os, kind, "C:\\ignored.exe", &buf);
            try t.expectEqual(@as(usize, 1), c.len);
            try t.expectEqualStrings("/bin/sh", c[0]);
        }
    }

    // Windows + powershell: pwsh 7 → 5.1 → %COMSPEC% → cmd.exe (계약 §3.1a).
    {
        const c = interactiveShellCandidates(.windows, .powershell, "D:\\alt\\cmd.exe", &buf);
        try t.expectEqual(@as(usize, 4), c.len);
        try t.expectEqualStrings(win_pwsh7, c[0]);
        try t.expectEqualStrings(win_powershell51, c[1]);
        try t.expectEqualStrings("D:\\alt\\cmd.exe", c[2]); // 비표준 설치를 아는 유일한 출처라 정적 경로보다 먼저
        try t.expectEqualStrings(win_cmd, c[3]);
    }

    // Windows + cmd: PowerShell 티어를 통째로 건너뛴다(사용자가 명시적으로 고른 것이다).
    {
        const c = interactiveShellCandidates(.windows, .cmd, "D:\\alt\\cmd.exe", &buf);
        try t.expectEqual(@as(usize, 2), c.len);
        try t.expectEqualStrings("D:\\alt\\cmd.exe", c[0]);
        try t.expectEqualStrings(win_cmd, c[1]);
    }

    // %COMSPEC%이 없거나 비었으면 그 칸만 빠지고 나머지는 그대로 — 후보가 0이 되는 일은 없다.
    for ([_]?[:0]const u8{ null, "" }) |comspec| {
        const ps = interactiveShellCandidates(.windows, .powershell, comspec, &buf);
        try t.expectEqual(@as(usize, 3), ps.len);
        try t.expectEqualStrings(win_cmd, ps[ps.len - 1]);
        const cmd = interactiveShellCandidates(.windows, .cmd, comspec, &buf);
        try t.expectEqual(@as(usize, 1), cmd.len);
        try t.expectEqualStrings(win_cmd, cmd[0]);
    }
}

// 후보는 모두 **절대경로**여야 한다. 상대경로가 섞이면 spawn이 프로세스 cwd에 따라 다른 것을 실행한다.
test "interactiveShellCandidates: 모든 후보가 절대경로다" {
    var buf: [max_shell_candidates][:0]const u8 = undefined;
    for ([_]std.Target.Os.Tag{ .windows, .macos, .linux }) |os| {
        for ([_]WindowsShellKind{ .powershell, .cmd }) |kind| {
            for (interactiveShellCandidates(os, kind, "C:\\x\\cmd.exe", &buf)) |c| {
                try std.testing.expect(c.len > 0);
                const abs = if (os == .windows) std.fs.path.isAbsoluteWindows(c) else std.fs.path.isAbsolutePosix(c);
                try std.testing.expect(abs);
            }
        }
    }
}
