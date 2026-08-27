pub const types = @import("pty/types.zig");
pub const session = @import("pty/session.zig");
/// Windows 백엔드의 순수 조립부(커맨드라인 인용·환경 블록 내용). **모든 타깃에서** 컴파일되므로 여기 배럴에
/// 걸어 두면 그 테스트가 macOS·Linux CI에서도 돈다 — Windows CI가 없는 이 저장소에서 그 규칙이 공허참이
/// 되지 않게 하는 유일한 그물이다(`pty/windows.zig`는 Windows에서만 컴파일된다).
pub const windows_spawn = @import("pty/windows_spawn.zig");
/// Windows 셸 통합 주입의 내용(cmd `PROMPT` 값·PowerShell 인라인 스크립트). 같은 이유로 배럴에 건다 —
/// Win32 심볼이 없어 모든 타깃에서 컴파일되고, 그래야 그 규칙이 macOS·Linux CI에서도 검증된다.
pub const windows_integration = @import("pty/windows_integration.zig");

pub const ChildPid = types.ChildPid; // 자식 pid의 중립 이름 — POSIX는 std.c.pid_t 그대로, Windows는 u32(계약 §4)
pub const Backend = types.Backend;
pub const ExitStatus = types.ExitStatus;
pub const PtyEvent = types.PtyEvent;
pub const PtyHandle = types.PtyHandle;
pub const PtySession = session.PtySession;
pub const backend_available = session.backend_available;
/// 이번 프로세스가 쓰는 ConPTY 구현. **진단 전용**이다 — `conpty.dll` 은 `OpenConsole.exe` 를 못 찾으면
/// 시스템 conhost 로 **조용히 되돌아가므로**(실패하지 않는다) 이것 없이는 "배치가 틀린 것"과 "잘 된
/// 것"을 못 가른다(계약 §4.3). 비-Windows 에서는 언제나 `.system` 이다.
pub const WindowsConptySource = enum { system, bundled };

/// **런타임 값이다.** 첫 spawn 에서 정해지므로 그 전에 물으면 아직 `.system` 이다.
pub fn windowsConptySource() WindowsConptySource {
    if (@import("builtin").os.tag != .windows) return .system;
    return switch (@import("pty/windows.zig").conpty_source) {
        .system => .system,
        .bundled => .bundled,
    };
}

/// 번들을 못 쓴 이유(진단). 성공했거나 아직 안 정해졌으면 빈 문자열이다.
pub fn windowsConptyRejectReason() []const u8 {
    if (@import("builtin").os.tag != .windows) return "";
    return @import("pty/windows.zig").conpty_reject_reason;
}
// Windows 기본 셸 선택(config `shell.windows-shell`)을 소비할 호스트가 배럴을 통해 닿을 수 있어야 한다 —
// W7에서 배선할 때 `pty.types.`를 직접 파고들지 않도록 여기서 함께 내보낸다.
pub const WindowsShellKind = types.WindowsShellKind;
pub const resolveInteractiveShellFor = types.resolveInteractiveShellFor;
pub const resolveShell = types.resolveShell;
pub const configuredShellCandidate = types.configuredShellCandidate;
pub const interactiveShellCandidates = types.interactiveShellCandidates;
pub const SpawnRequest = types.SpawnRequest;
pub const plannedBackendForMacOS = types.plannedBackendForMacOS;
pub const resolveInteractiveShell = types.resolveInteractiveShell;
pub const selfResourceSample = session.selfResourceSample;
// host-backed 터미널의 트리를 앱이 직접 재려면 **뿌리 pid를 밖에서 받는** 표본기가 필요하다(그 PTY의
// `PtySession`은 세션 host 프로세스 안에 있다). 배럴에서 내보내 소비처가 `pty/macos.zig`를 직접 파고들지 않게 한다.
pub const processTreeSamples = session.processTreeSamples;
pub const processResourceSample = session.processResourceSample;

test {
    // Aggregate this layer's child-file tests into the build. refAllDecls is
    // shallow and does not recurse through the maru barrel, so without this
    // block the unit tests in pty/* never compile into `zig build test`.
    @import("std").testing.refAllDecls(@This());
}
