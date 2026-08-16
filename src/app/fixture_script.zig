//! 헤드리스 데모·스모크가 띄우는 **fixture 명령**을 한 곳에서 만든다.
//!
//! 이 경로들의 요점은 "실제 프로세스 출력이 런타임 경계를 끝까지 통과하는가"이지 셸이 아니다. 그래서
//! 출력할 **내용**은 같게 두고 그것을 내는 **방법**만 OS로 가른다. 규칙이 파일마다 흩어지면 한 곳만
//! 고쳐 놓고 나머지가 조용히 POSIX 전용으로 남는다(실제로 W4에서 세 자리가 동시에 걸렸다).
//!
//! **OS를 인자로 받는다.** `builtin.os.tag`로 분기하면 Windows 갈래가 macOS·Linux CI에서 컴파일조차 안 돼
//! 공허참이 된다 — 이 저장소가 W1.5·W2에서 두 번 밟은 함정이다.

const std = @import("std");

pub const Fixture = struct {
    command: []const u8,
    args: []const []const u8,
};

/// POSIX 셸의 절대 경로. fixture는 사용자의 셸이 아니라 **정해진 것**을 띄워야 한다(테스트 재현성).
const posix_shell = "/bin/sh";
/// Windows에서는 cmd를 쓴다. PowerShell이 아닌 이유는 실행 정책과 무관하게 도는 쪽이 fixture에 맞기
/// 때문이다(사용자 기본 셸 선택은 `pty.resolveInteractiveShellFor` — 별개 결정, 계약 §3.1a).
const windows_shell = "C:\\Windows\\System32\\cmd.exe";

/// 한 번 돌고 끝나는 스크립트를 그 OS의 셸로 띄우는 fixture.
///
/// **Windows 스크립트는 반드시 인자 하나로 넘어간다.** cmd는 CRT argv 파싱을 쓰지 않아(계약 §4.2) 토큰을
/// 나눠 주면 `echo`가 첫 단어만 받는다(실측: `maru headless demo`가 아니라 `maru`만 나왔다).
pub fn oneShot(os_tag: std.Target.Os.Tag, posix: []const u8, windows: []const u8) Fixture {
    if (os_tag == .windows) return .{ .command = windows_shell, .args = &.{ "/c", windows } };
    return .{ .command = posix_shell, .args = &.{ "-c", posix } };
}

/// 짧은 지연 — 출력이 **여러 이벤트로 나뉘어** 도착하게 만드는 자리에 쓴다(프레임 루프 스모크).
/// cmd에는 sub-second `sleep`이 없다. `timeout /t`는 1초 미만을 못 받고 콘솔 입력을 가로채므로,
/// 관례대로 `ping`의 대기 시간을 쓴다.
pub const posix_short_sleep = "sleep 0.05";
pub const windows_short_sleep = "ping -n 1 -w 100 127.0.0.1 >nul";

/// 대화형 스모크가 찾는 표식. 셸에 **타이핑해서** 받아 내는 값이라 입력과 기대값이 같은 곳에 있어야 한다.
pub const interactive_marker = "MARU_APP_PTY_INTERACTIVE_LOOP_OK";

pub const Interactive = struct {
    /// 사용자의 대화형 셸에 줄 인자.
    args: []const []const u8,
    /// 프레임 루프가 키 이벤트로 흘려 넣을 문자열.
    input: []const u8,
};

/// 대화형 셸을 띄워 표식 한 줄을 받아 내고 끝내는 각본.
///
/// `echo`와 `exit`만 쓴다 — cmd·PowerShell·POSIX 셸이 **모두 아는** 두 낱말이라, Windows 쪽 기본 셸이
/// pwsh든 cmd든(계약 §3.1a의 티어) 같은 각본이 통한다. `printf`는 PowerShell에 없다.
///
/// Windows에서 인자를 주지 않는 이유도 같다. POSIX의 `-i`에 해당하는 것이 PowerShell엔 없고(기본이
/// 대화형), cmd는 그 플래그를 모른다. 줄바꿈은 `\r\n`이다 — 콘솔 입력의 Enter는 CR이다.
pub fn interactiveEcho(os_tag: std.Target.Os.Tag) Interactive {
    if (os_tag == .windows) return .{
        .args = &.{},
        .input = "echo " ++ interactive_marker ++ "\r\nexit\r\n",
    };
    return .{
        .args = &.{"-i"},
        .input = "printf '" ++ interactive_marker ++ "\\n'; exit\n",
    };
}

test "oneShot: 두 갈래 모두 절대경로 셸에 스크립트를 인자 하나로 넘긴다" {
    for ([_]std.Target.Os.Tag{ .windows, .macos, .linux }) |os| {
        const f = oneShot(os, "echo posix", "echo windows");
        try std.testing.expectEqual(@as(usize, 2), f.args.len); // 셸 플래그 + 스크립트 하나
        const abs = if (os == .windows)
            std.fs.path.isAbsoluteWindows(f.command)
        else
            std.fs.path.isAbsolutePosix(f.command);
        try std.testing.expect(abs); // 상대 경로면 maru의 작업 디렉터리에 따라 다른 것이 실행된다
    }
    try std.testing.expectEqualStrings("/c", oneShot(.windows, "p", "w").args[0]);
    try std.testing.expectEqualStrings("w", oneShot(.windows, "p", "w").args[1]);
    try std.testing.expectEqualStrings("-c", oneShot(.macos, "p", "w").args[0]);
    try std.testing.expectEqualStrings("p", oneShot(.macos, "p", "w").args[1]);
}

test "interactiveEcho: 두 갈래가 같은 표식을 내고 스스로 끝낸다" {
    for ([_]std.Target.Os.Tag{ .windows, .macos, .linux }) |os| {
        const it = interactiveEcho(os);
        // 표식이 입력 안에 있어야 한다 — 기대값과 입력이 갈리면 스모크가 영원히 안 끝난다.
        try std.testing.expect(std.mem.indexOf(u8, it.input, interactive_marker) != null);
        // `exit`가 없으면 셸이 안 끝나 드레인이 타임아웃한다.
        try std.testing.expect(std.mem.indexOf(u8, it.input, "exit") != null);
        // 마지막 줄도 개행으로 끝나야 셸이 그 줄을 실행한다.
        try std.testing.expect(it.input[it.input.len - 1] == '\n');
    }
    // Windows 갈래는 POSIX 전용 플래그를 물려받으면 안 된다(pwsh·cmd 둘 다 `-i`를 모른다).
    try std.testing.expectEqual(@as(usize, 0), interactiveEcho(.windows).args.len);
    try std.testing.expectEqualStrings("-i", interactiveEcho(.macos).args[0]);
}
