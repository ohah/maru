//! session_host — 영속 터미널 세션 호스트(`maru-sessiond`) 구현 barrel(P3, docs/persistent-session-host.md).
//!
//! GUI가 종료돼도 terminal PTY·자식 프로세스·화면 상태를 유지하고, 다시 실행한 GUI 또는 다른 터미널의 `maru attach`가
//! 재접속하는 기능을 담는다. `maru.control.v1`(control-plane)과 ID·socket·wire를 공유하지 않는다.
//!
//! 레이어 규율(project-structure.md session_host/): **codec/state machine은 OS 중립**(platform import 0)이고,
//! macOS launch/peer-cred/socket adapter만 platform 경계에 둔다. 그래서 이 서브트리는 platform/macos 아래 있지만
//! `protocol`/`framing` 같은 codec은 std만 의존해 나중에 이식하거나 CLI(P5)와 공유할 수 있다.
//!
//! 구현 순서(각 슬라이스가 별도 PR):
//!   - P3-a: `protocol`(MRSH 32-byte header·kind/flag·error 어휘) + `framing`(partial I/O parser·cap). ← 현재
//!   - P3-b: screen-stream codec(snapshot/delta record, §12).
//!   - P3-c: `TerminalRuntimeRegistry`(runtime 소유·controller state machine).
//!   - P3-d: server(unix socket·hello/command dispatch·bounded queue) + detached-helper on-demand launch + entrypoint.
//!   - P3-e: client(hello/RPC/stream demux) + host-backed `TermRuntimeBackend` + GUI 재접속.

pub const protocol = @import("session_host/protocol.zig");
pub const framing = @import("session_host/framing.zig");

test {
    // 자식 파일의 inline test를 이 barrel의 test 그래프에 모은다(refAllDecls는 얕아 명시 참조가 필요).
    @import("std").testing.refAllDecls(@This());
}
