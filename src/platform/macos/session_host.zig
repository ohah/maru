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
//!   - P3-a ✅: `protocol`(MRSH 32-byte header·kind/flag·error 어휘) + `framing`(partial I/O parser·cap).
//!   - P3-b ✅: `screen_stream`(snapshot/delta record codec, §12).
//!   - P3-c ✅: `registry`(`TerminalRuntimeRegistry` + controller/observer capability state machine, §9).
//!   - P3-d1 ✅: `server`(connection dispatch state machine — hello 협상 + read-only command dispatch, 순수).
//!   - P3-d2a ✅: `socket_server`(실 unix socket bind/accept·peer-cred same-UID·read/write I/O loop, self-contained macOS adapter).
//!   - P3-d2b ✅: `discovery`(§10 socket 발견 state machine·경로 — connect-first·auto-start 정책·start lock winner, 순수).
//!   - P3-d2c ✅: `daemon`(`maru-sessiond` entrypoint — host_id·bind·poll-gated accept loop·dispatch, fork/setsid process smoke).
//!   - P3-d2d ✅: `launcher`(double-fork+setsid+execv detached spawn, marker smoke) + `maru __session-host` CLI(main.zig).
//!   - P3-e1 ✅: `client`(GUI/CLI hello/RPC — connect·hello·host_id 확정·read-only command 왕복, fork host roundtrip smoke).
//!   - P3-e2a ✅: `server`에 runtime.spawn/terminate dispatch + `RuntimeOps` seam(중립 vtable, host만 설정, read-only는 unauthorized).
//!   - P3-e2b ✅: 실 `runtime_manager`(app `InProcessTermBackend` 재사용 + runtime_id↔handle 매핑) + daemon 배선(SocketServer.runtime_ops).
//!   - P3-e2c ✅: attach/detach/resize dispatch + input_bytes 라우팅(§9 capability) + `RuntimeOps` write_input/resize. runtime.resized broadcast는 e2d.
//!   - P3-e2d(snapshot/delta stream demux): §12 codec을 실 TerminalCore 화면에 연결.
//!     - e2d-1 ✅: `screen_snapshot`(TerminalCore 화면 → screen_stream 레코드 투영, resolved RGB·wide cell·cursor·modes) + `screen_stream` length-prefixed record-stream framing.
//!     - e2d-2 ✅: attach가 `RuntimeOps.snapshot`(core lock 아래 투영)을 얻어 응답에 이어 `snapshot_chunk` frame으로 전송(§10 순서, 마지막 end_stream). `Action.frames` 확장, client `readSnapshot`.
//!     - e2d-3a ✅: `screen_snapshot.computeDelta`(이전 snapshot 바이트 vs 현재 화면 diff → set_runs/cursor/modes delta record, 순수). row builder 재사용, geometry 변화는 SnapshotRequired.
//!     - e2d-3b ✅: delta async push — `serveConnection` poll-loop(delta tick)이 `collectDeltas`로 stream별 base 대비 diff해 `delta_chunk`를 push. `RuntimeOps.delta` seam + `StreamUpdate`, `Subscription.base` 추적. geometry 변화는 fresh snapshot 재전송. (observer fan-out=P4, dirty-gate 최적화=후속.)
//!   - P3-e2e: host-backed `TermRuntimeBackend`(P2 계약의 원격 구현).
//!     - e2e-1 ✅: `screen_assembler`(snapshot/delta records → client 화면 모델, 투영의 역, 순수). applySnapshot/applyDelta/toSnapshot, generation gap.
//!     - e2e-2: client 위 remote `TermRuntimeBackend` vtable(assembler를 화면 모델로) + GUI 배선. ← 다음
//!   - P3-e3: `app_session` 배선(discovery→launch→attach) + GUI 재접속(manifest runtime_handle).

const builtin = @import("builtin");

pub const protocol = @import("session_host/protocol.zig");
pub const framing = @import("session_host/framing.zig");
pub const screen_stream = @import("session_host/screen_stream.zig");
// screen_assembler(records → client 화면 모델, screen_snapshot 투영의 역)는 screen_stream codec만 써서 순수 계층으로
// 둔다(platform-import-0, non-macOS에서도 테스트). 실 렌더/backend 배선은 macOS 전용 후속(e2e-2)에서 이 조립기를 쓴다.
pub const screen_assembler = @import("session_host/screen_assembler.zig");
pub const registry = @import("session_host/registry.zig");
pub const server = @import("session_host/server.zig");
pub const discovery = @import("session_host/discovery.zig");
// socket_server는 macOS 전용 unix socket syscall(c.fstatat/mkdir/getpeereid, SO_NOSIGPIPE)을 써서 macOS에서만 컴파일한다
// (§10 macOS endpoint). Linux에선 그 syscall 시그니처가 없어 참조만으로 컴파일이 깨지므로 barrel에서 조건부로 제외한다.
// codec/state machine(protocol/framing/screen_stream/registry/server)은 OS 중립이라 그대로 두어 non-macOS에서도 회귀를 잡는다.
pub const socket_server = if (builtin.os.tag == .macos)
    @import("session_host/socket_server.zig")
else
    struct {};
// daemon(maru-sessiond entrypoint)도 실 socket/signal/fork syscall을 써서 macOS에서만 컴파일한다(barrel 조건부 제외).
pub const daemon = if (builtin.os.tag == .macos)
    @import("session_host/daemon.zig")
else
    struct {};
// launcher(detached-helper spawn)도 실 fork/exec/setsid를 써서 macOS에서만 컴파일한다(순수 argv 조립 test도 함께 macOS-gated).
pub const launcher = if (builtin.os.tag == .macos)
    @import("session_host/launcher.zig")
else
    struct {};
// client(GUI/CLI가 host에 connect)도 실 socket을 써서 macOS에서만 컴파일한다(순수 JSON helper test도 함께 macOS-gated).
pub const client = if (builtin.os.tag == .macos)
    @import("session_host/client.zig")
else
    struct {};
// runtime_manager(실 runtime 소유 — app InProcessTermBackend 재사용)는 `@import("maru")`로 app 스택을 끌어와 macOS에서만
// 컴파일한다. codec(protocol/framing/screen_stream/registry/server)은 여전히 maru를 모르는 platform-import-0 순수 계층이다.
pub const runtime_manager = if (builtin.os.tag == .macos)
    @import("session_host/runtime_manager.zig")
else
    struct {};
// screen_snapshot(실 TerminalCore 화면 → screen_stream 레코드 투영)도 `@import("maru")`로 terminal을 읽어 macOS 전용이다.
// 투영 자체는 순수 로직이지만 terminal 타입 의존이라 barrel에서 조건부로 둔다(screen_stream codec은 그대로 순수 유지).
pub const screen_snapshot = if (builtin.os.tag == .macos)
    @import("session_host/screen_snapshot.zig")
else
    struct {};

test {
    // 자식 파일의 inline test를 이 barrel의 test 그래프에 모은다(refAllDecls는 얕아 명시 참조가 필요).
    @import("std").testing.refAllDecls(@This());
}
