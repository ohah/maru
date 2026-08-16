pub const types = @import("pty/types.zig");
pub const session = @import("pty/session.zig");

pub const Backend = types.Backend;
pub const ExitStatus = types.ExitStatus;
pub const PtyEvent = types.PtyEvent;
pub const PtyHandle = types.PtyHandle;
pub const PtySession = session.PtySession;
pub const backend_available = session.backend_available;
// Windows 기본 셸 선택(config `shell.windows-shell`)을 소비할 호스트가 배럴을 통해 닿을 수 있어야 한다 —
// W7에서 배선할 때 `pty.types.`를 직접 파고들지 않도록 여기서 함께 내보낸다.
pub const WindowsShellKind = types.WindowsShellKind;
pub const resolveInteractiveShellFor = types.resolveInteractiveShellFor;
pub const interactiveShellCandidates = types.interactiveShellCandidates;
pub const SpawnRequest = types.SpawnRequest;
pub const plannedBackendForMacOS = types.plannedBackendForMacOS;
pub const resolveInteractiveShell = types.resolveInteractiveShell;
pub const selfResourceSample = session.selfResourceSample;

test {
    // Aggregate this layer's child-file tests into the build. refAllDecls is
    // shallow and does not recurse through the maru barrel, so without this
    // block the unit tests in pty/* never compile into `zig build test`.
    @import("std").testing.refAllDecls(@This());
}
