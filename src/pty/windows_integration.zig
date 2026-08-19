//! Windows 셸 통합 주입의 **내용** — cmd의 `PROMPT` 값과 PowerShell의 인라인 `-Command` 스크립트.
//!
//! **왜 여기인가.** macOS는 통합 자산이 **파일**이라 그 내용을 플랫폼 레이어(`platform/macos/shell_integration.zig`)가
//! 쓰고, PTY 백엔드는 그 디렉터리를 `ZDOTDIR`로 매핑만 한다. Windows는 §3.3이 **파일을 금지**했으므로
//! (`ExecutionPolicy`가 서명 없는 `.ps1`을 막는다) 내용 자체가 곧 메커니즘이다 — 인라인 인자와 환경변수 값이라
//! 백엔드가 조립하는 수밖에 없다. 그래서 백엔드 옆에 둔다.
//!
//! **이 파일에는 Win32 심볼이 없다.** 그래서 macOS·Linux에서도 컴파일되고 `zig build test`가 **모든 타깃에서**
//! 여기 테스트를 돈다 — Windows CI 러너가 없는 이 저장소에서 그 규칙이 공허참이 되지 않게 하는 그물이다.
//!
//! 계약: [docs/windows-platform.md](../../docs/windows-platform.md) §3.3·§3.4.

const std = @import("std");

/// 셸 종류(주입 메커니즘이 갈린다). `other`는 통합 없이 그대로 띄운다 — macOS `shell_integration.detect`와 같은
/// 모양이고, 같은 이유로 **모르는 셸에 아무것도 심지 않는다**(잘못 심으면 프롬프트가 깨진다).
pub const Family = enum { powershell, cmd, other };

/// 실행 파일 경로의 basename으로 종류를 판정한다. **경로 구분자 둘 다** 본다 — 이 값은 config에서 올 수도
/// 있고(`shell.command`) 거기에는 `/`가 섞일 수 있다.
pub fn familyOf(command: []const u8) Family {
    var base = command;
    if (std.mem.lastIndexOfAny(u8, command, "/\\")) |i| base = command[i + 1 ..];
    if (eqlIgnoreCase(base, "pwsh.exe") or eqlIgnoreCase(base, "pwsh") or
        eqlIgnoreCase(base, "powershell.exe") or eqlIgnoreCase(base, "powershell")) return .powershell;
    if (eqlIgnoreCase(base, "cmd.exe") or eqlIgnoreCase(base, "cmd")) return .cmd;
    return .other;
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

/// cmd가 프롬프트를 그릴 때 확장하는 코드. `$E`=ESC, `$P`=현재 경로, `$G`=`>`.
/// 사용자가 `PROMPT`를 안 정했을 때 cmd가 쓰는 기본값이 `$P$G`다.
pub const cmd_default_prompt = "$P$G";

/// cmd용 `PROMPT` 값을 만든다 — **사용자 프롬프트 앞에 OSC만 덧붙인다**(계약 §3.3).
///
/// | 시퀀스 | 언제 | 왜 |
/// |---|---|---|
/// | `OSC 133;A` | 프롬프트 시작 | 거터·프롬프트 점프의 경계 |
/// | `OSC 9;9;<cwd>` | 매 프롬프트 | cwd 보고(§3.2 — Windows의 사실상 표준) |
/// | `OSC 133;B` | 프롬프트 끝 | 입력 시작 경계 |
///
/// **`OSC 133;D`는 없다.** cmd의 `PROMPT` 확장 코드에 직전 명령의 **종료 코드가 없어서**(계약 §3.4) 실을 값이
/// 없다. 우회하지 않고 그대로 둔다 — sticky command처럼 종료 상태에 기대는 기능은 cmd에서 동작하지 않는다.
///
/// `parent_prompt`는 부모 환경의 `PROMPT`(없으면 null). 반환은 `"PROMPT=..."` 형태의 owned 문자열이라
/// `env_overrides`에 그대로 실을 수 있다.
pub fn cmdPromptEntry(allocator: std.mem.Allocator, parent_prompt: ?[]const u8) ![]u8 {
    const user = if (parent_prompt) |p| (if (p.len > 0) p else cmd_default_prompt) else cmd_default_prompt;
    return std.fmt.allocPrint(
        allocator,
        "PROMPT=$E]133;A$E\\$E]9;9;$P$E\\{s}$E]133;B$E\\",
        .{user},
    );
}

/// PowerShell에 인라인으로 넣을 `prompt` 재정의.
///
/// **파일이 아니라 인라인인 이유**: `ExecutionPolicy`가 `AllSigned`·`Restricted`면 서명 없는 `.ps1`이 막혀
/// 통합이 통째로 죽는다. 인라인 `-Command`는 정책 적용 대상이 아니다(계약 §3.3, 실측).
///
/// **사용자 프롬프트를 덮지 않는다.** 기존 `prompt`를 붙잡아 두고 그 결과 **앞뒤로** OSC만 감싼다. pwsh가
/// 프로필을 먼저 로드하고 `-Command`를 나중에 실행하므로(실측), 사용자가 프로필에서 정의한 `prompt`가 여기
/// 잡힌다. 없으면 PowerShell 기본 모양을 쓴다.
///
/// **cmd와 달리 `OSC 133;D`를 낸다** — `$LASTEXITCODE`로 직전 명령의 종료 코드를 알 수 있다. 첫 프롬프트에는
/// 직전 명령이 없으므로 건너뛴다.
///
/// 큰따옴표를 쓰지 않는다. 이 문자열은 `-Command`의 인자로 커맨드라인에 실리는데, 우리 인용기는 CRT 규칙대로
/// `"`를 `\"`로 이스케이프하고 그 형태가 셸마다 다르게 읽힌다(W4에서 cmd가 그 때문에 깨졌다). 작은따옴표와
/// `[char]27`만으로 같은 일을 한다.
/// **`$?`와 `$LASTEXITCODE`를 맨 앞에서 붙잡는다.** 둘 다 "직전 문장"의 상태라, 함수 안에서 다른 문장을
/// 하나라도 실행한 뒤에 읽으면 **그 문장의 성공**을 보게 된다 — 실측으로 잡았다: `cmd /c exit 3` 뒤인데
/// `OSC 133;D`에 `0`이 실렸다. 값이 틀린 D는 없느니만 못하다(거터가 거짓말을 한다).
///
/// 첫 프롬프트에는 직전 명령이 없으므로 D를 건너뛴다(macOS zsh 통합의 `_maru_osc133_started`와 같은 규율).
pub const powershell_prompt_command =
    "$global:__maruInner = if (Test-Path Function:\\prompt) { (Get-Item Function:\\prompt).ScriptBlock } else { $null };" ++
    "function global:prompt {" ++
    "$ok = $?;" ++
    "$code = $LASTEXITCODE;" ++
    "$e = [char]27;" ++
    "$c = if ($ok) { 0 } else { if ($null -ne $code) { $code } else { 1 } };" ++
    "$d = if ($global:__maruStarted) { $e + ']133;D;' + $c + $e + '\\' } else { '' };" ++
    "$global:__maruStarted = $true;" ++
    "$inner = if ($null -ne $global:__maruInner) { & $global:__maruInner } else { 'PS ' + $PWD.Path + '> ' };" ++
    "$d + $e + ']133;A' + $e + '\\' + $e + ']9;9;' + $PWD.Path + $e + '\\' + $inner + $e + ']133;B' + $e + '\\'" ++
    "}";

/// PowerShell을 통합과 함께 띄울 때 **뒤에 붙이는** 인자들.
///
/// `-NoExit`이 없으면 `-Command`가 스크립트를 실행하고 **셸이 곧바로 끝난다**(실측 — §3.3). `-Command`는
/// 나머지를 전부 먹으므로 **반드시 마지막**이라, 사용자 인자 뒤에 붙인다.
pub fn powershellArgs() []const []const u8 {
    return &.{ "-NoLogo", "-NoExit", "-Command", powershell_prompt_command };
}

// ── 테스트 ────────────────────────────────────────────────────────────────────────────────────
// 전부 순수라 **모든 타깃에서** 돈다.

const testing = std.testing;

test "familyOf: 경로·대소문자·구분자를 가리지 않는다" {
    const cases = [_]struct { in: []const u8, want: Family }{
        .{ .in = "C:\\Windows\\System32\\cmd.exe", .want = .cmd },
        .{ .in = "C:/Windows/System32/CMD.EXE", .want = .cmd },
        .{ .in = "cmd", .want = .cmd },
        .{ .in = "C:\\Program Files\\PowerShell\\7\\pwsh.exe", .want = .powershell },
        .{ .in = "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe", .want = .powershell },
        .{ .in = "PWSH.EXE", .want = .powershell },
        // 정규화된 경로는 이제 **실제 입력**이다 — config 값이 `/` 로 들어온다(계약 §5 규칙 1).
        .{ .in = "C:/Program Files/PowerShell/7/pwsh.exe", .want = .powershell },
        // 모르는 셸에는 아무것도 심지 않는다.
        .{ .in = "C:\\msys64\\usr\\bin\\bash.exe", .want = .other },
        .{ .in = "C:\\Windows\\System32\\wsl.exe", .want = .other },
        .{ .in = "/bin/zsh", .want = .other },
        .{ .in = "", .want = .other },
        // 이름이 겹쳐 보이는 것에 속지 않는다.
        .{ .in = "notcmd.exe", .want = .other },
        .{ .in = "cmd.exe.bak", .want = .other },
        .{ .in = "pwshx.exe", .want = .other },
    };
    for (cases) |c| try testing.expectEqual(c.want, familyOf(c.in));
}

test "cmdPromptEntry: 사용자 프롬프트를 감싸고 덮지 않는다" {
    const a = testing.allocator;
    {
        const got = try cmdPromptEntry(a, "MYPROMPT$G");
        defer a.free(got);
        try testing.expect(std.mem.startsWith(u8, got, "PROMPT="));
        // 사용자 것이 그대로 남고, 그 **앞**에 133;A와 9;9가, **뒤**에 133;B가 붙는다.
        const a_at = std.mem.indexOf(u8, got, "]133;A").?;
        const cwd_at = std.mem.indexOf(u8, got, "]9;9;$P").?;
        const user_at = std.mem.indexOf(u8, got, "MYPROMPT$G").?;
        const b_at = std.mem.indexOf(u8, got, "]133;B").?;
        try testing.expect(a_at < cwd_at);
        try testing.expect(cwd_at < user_at);
        try testing.expect(user_at < b_at);
    }
    // 부모 PROMPT가 없거나 비었으면 cmd 기본값을 쓴다.
    for ([_]?[]const u8{ null, "" }) |p| {
        const got = try cmdPromptEntry(a, p);
        defer a.free(got);
        try testing.expect(std.mem.indexOf(u8, got, cmd_default_prompt) != null);
    }
}

test "cmdPromptEntry: 종료 코드(133;D)는 내지 않는다 — cmd에 그 값이 없다" {
    const a = testing.allocator;
    const got = try cmdPromptEntry(a, null);
    defer a.free(got);
    try testing.expect(std.mem.indexOf(u8, got, "]133;D") == null); // 계약 §3.4
}

test "powershell: 인라인 스크립트가 큰따옴표를 쓰지 않는다" {
    // 커맨드라인 인용 규칙이 셸마다 달라, 큰따옴표가 들어가면 조용히 다른 것이 실행된다(W4 실측).
    try testing.expect(std.mem.indexOfScalar(u8, powershell_prompt_command, '"') == null);
}

test "powershell: 세 경계와 cwd 보고를 모두 낸다" {
    for ([_][]const u8{ "]133;A", "]133;B", "]133;D", "]9;9;" }) |needle| {
        if (std.mem.indexOf(u8, powershell_prompt_command, needle) == null) {
            std.debug.print("PowerShell 스크립트에 {s}가 없다\n", .{needle});
            return error.TestUnexpectedResult;
        }
    }
    // 사용자 프롬프트를 붙잡아 두고 다시 부른다(덮지 않는다).
    try testing.expect(std.mem.indexOf(u8, powershell_prompt_command, "Function:\\prompt") != null);
    try testing.expect(std.mem.indexOf(u8, powershell_prompt_command, "$global:__maruInner") != null);
}

test "powershellArgs: -Command가 마지막이고 -NoExit이 있다" {
    const args = powershellArgs();
    try testing.expectEqualStrings("-Command", args[args.len - 2]);
    try testing.expectEqualStrings(powershell_prompt_command, args[args.len - 1]);
    var saw_noexit = false;
    for (args) |x| {
        if (std.mem.eql(u8, x, "-NoExit")) saw_noexit = true;
    }
    try testing.expect(saw_noexit); // 없으면 셸이 곧바로 끝난다(실측)
}
