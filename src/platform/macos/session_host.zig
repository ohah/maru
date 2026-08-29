//! session_host — 영속 터미널 세션 호스트(`maru-sessiond`) 구현 barrel(P3, docs/persistent-session-host.md).
//!
//! GUI가 종료돼도 terminal PTY·자식 프로세스·화면 상태를 유지하고, 다시 실행한 GUI 또는 다른 터미널의 `maru attach`가
//! 재접속하는 기능을 담는다. `maru.control.v1`(control-plane)과 ID·socket·wire를 공유하지 않는다.
//!
//! 레이어 규율(project-structure.md session_host/): **codec/state machine은 OS 중립**(platform import 0)이고,
//! macOS launch/peer-cred/socket adapter만 platform 경계에 둔다. 그래서 이 서브트리는 platform/macos 아래 있지만
//! `protocol`/`framing` 같은 codec은 std와 OS-중립 L2 shared leaf만 의존해 나중에 이식하거나 CLI(P5)와 공유할 수 있다.
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
//!     - e2e-2a ✅: `remote_screen`(조립기 runs → `terminal.RenderSnapshot` cells). 렌더 경로가 로컬/원격에서 같은 DTO를 소비하는 SSOT 변환(Run→Cell·wide·cluster·rgb).
//!     - e2e-2b ✅: `Surface.renderSnapshot()` 렌더 seam 도입(로컬 core 위임). GUI 렌더 read를 `surface.core.renderSnapshot()`→`surface.renderSnapshot()`로 이관 — 원격 backing이 갈릴 단일 접근점.
//!     - e2e-2c-1 ✅: `Surface`에 화면 소스 추상(`ScreenSource` vtable) + `RemoteScreen`(조립기+CellGrid+mutex) source. Surface.remote 설정 시 renderSnapshot/lockCore가 원격 조립 화면으로 갈린다.
//!     - e2e-2c-2 ✅: `remote_runtime`(client 쪽 원격 runtime — host runtime_manager의 상대). spawn(runtime.spawn+attach+snapshot)→원격-backed Surface, sendInput/resize→client RPC, pumpDelta→delta 소비, terminate. **`TermRuntimeBackend` vtable 어댑터+frame-loop pump 배선은 e3**(pump=RuntimeEventPump가 frame-loop와 얽힘).
//!   - P3-e3 ✅ core: `app_session` 배선(discovery→launch→attach) + 원격 `TermRuntimeBackend` + 앱 전역 backend/connection +
//!     GUI 종료→재실행 재접속(`runtime_handle`). 남은 P4/P5 범위는 docs/persistent-session-host.md의 구현 상태를 따른다.

const builtin = @import("builtin");

pub const entrypoint = @import("session_host/entrypoint.zig");
pub const startup_readiness = if (builtin.os.tag == .macos)
    @import("session_host/startup_readiness.zig")
else
    struct {};
pub const protocol = @import("session_host/protocol.zig");
pub const framing = @import("session_host/framing.zig");
pub const compatibility = @import("session_host/compatibility.zig");
pub const host_identity = @import("session_host/host_identity.zig");
pub const short_endpoint = if (builtin.os.tag == .macos)
    @import("session_host/short_endpoint.zig")
else
    struct {};
pub const host_authority = if (builtin.os.tag == .macos)
    @import("session_host/host_authority.zig")
else
    struct {};
pub const core_command_wire = @import("session_host/core_command_wire.zig");
pub const notification_journal = @import("session_host/notification_journal.zig");
pub const notification_admission = @import("session_host/notification_admission.zig");
pub const notification_os_delivery = @import("session_host/notification_os_delivery.zig");
pub const notification_macos_adapter = if (builtin.os.tag == .macos)
    @import("session_host/notification_macos_adapter.zig")
else
    struct {};
pub const screen_stream = @import("maru").session.screen_stream;
// screen_assembler(records → client 화면 모델, screen_snapshot 투영의 역)는 screen_stream codec만 써서 순수 계층으로
// 둔다(platform-import-0, non-macOS에서도 테스트). 실 렌더/backend 배선은 macOS 전용 후속(e2e-2)에서 이 조립기를 쓴다.
pub const screen_assembler = @import("maru").session.screen_assembler;
pub const registry = @import("session_host/registry.zig");
pub const server = @import("session_host/server.zig");
pub const discovery = @import("session_host/discovery.zig");
pub const admin_client = if (builtin.os.tag == .macos)
    @import("session_host/admin_client.zig")
else
    struct {};
pub const admin_cli = if (builtin.os.tag == .macos)
    @import("session_host/admin_cli.zig")
else
    struct {};
// host_connect(client의 connect-or-launch 오케스트레이션 — discovery 결정을 실 connect/flock/spawnDetached로 수행)는 실
// syscall을 써서 macOS 전용이다(순수 결정은 discovery.zig가 이미 테스트). AppSession이 keep-alive일 때 이걸 부른다(e3-4).
pub const host_connect = if (builtin.os.tag == .macos)
    @import("session_host/host_connect.zig")
else
    struct {};
pub const recovery_discovery = if (builtin.os.tag == .macos)
    @import("session_host/recovery_discovery.zig")
else
    struct {};
pub const recovered_sessions_projection = if (builtin.os.tag == .macos)
    @import("session_host/recovered_sessions_projection.zig")
else
    struct {};
pub const recovered_session_adopt = if (builtin.os.tag == .macos)
    @import("session_host/recovered_session_adopt.zig")
else
    struct {};
pub const connection_slot = @import("session_host/connection_slot.zig");
pub const user_action_queue = @import("session_host/user_action_queue.zig");
// 창 닫기 graph는 syscall이나 backend 포인터를 갖지 않는 scalar 권위 leaf라 ABI 교차 빌드에서도 같은
// 저장 형식과 전이를 검사한다. 실제 RemoteRuntime 실행 경로만 아래 macOS 전용 barrel에 남긴다.
pub const pending_term_close_graph = @import("session_host/pending_term_close_graph.zig");
pub const pending_app_quit_shutdown = @import("session_host/pending_app_quit_shutdown.zig");
pub const incident_publisher_registry = if (builtin.os.tag == .macos)
    @import("session_host/incident_publisher_registry.zig")
else
    struct {};
pub const app_process_incident_owner = if (builtin.os.tag == .macos)
    @import("session_host/app_process_incident_owner.zig")
else
    struct {};
pub const client_idle_pump_evidence = if (builtin.os.tag == .macos)
    @import("session_host/client_idle_pump_evidence.zig")
else
    struct {};
pub const session_host_coordinator = if (builtin.os.tag == .macos)
    @import("session_host/session_host_coordinator.zig")
else
    struct {};
pub const incident_bootstrap_contract = @import("session_host/incident_bootstrap_contract.zig");
pub const subscription_identity = @import("session_host/subscription_identity.zig");
pub const connection_turn = if (builtin.os.tag == .macos)
    @import("session_host/connection_turn.zig")
else
    struct {};
pub const poll_owner = if (builtin.os.tag == .macos)
    @import("session_host/poll_owner.zig")
else
    struct {};
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
// client(GUI/CLI가 host에 connect)도 실 socket을 써서 macOS에서만 컴파일한다. Barrel은
// 제품 소비자가 쓰는 facade만 다시 내보내고 owner의 unchecked commit authority는 숨긴다.
const client_impl = if (builtin.os.tag == .macos)
    @import("session_host/client.zig")
else
    struct {};
pub const client = if (builtin.os.tag == .macos) struct {
    pub const Client = client_impl.Client;
    pub const extractRuntimeId = client_impl.extractRuntimeId;
    pub const extractU64Field = client_impl.extractU64Field;
} else struct {};

test "client barrel exposes only the supported facade" {
    if (builtin.os.tag != .macos) return;
    try @import("std").testing.expect(@hasDecl(client, "Client"));
    try @import("std").testing.expect(@hasDecl(client, "extractRuntimeId"));
    try @import("std").testing.expect(@hasDecl(client, "extractU64Field"));
    try @import("std").testing.expect(!@hasDecl(client, "ExternalAdoptionTake"));
    try @import("std").testing.expect(
        !@hasDecl(client, "commitExternalAdoptionTake" ++ "Unchecked"),
    );
    try @import("std").testing.expect(
        !@hasDecl(client.Client, "commitExternalAdoptionTake" ++ "Unchecked"),
    );
    try @import("std").testing.expect(
        !@hasDecl(client.Client, "commitExternalRecoveryDiscard" ++ "Unchecked"),
    );
    try @import("std").testing.expect(!@hasDecl(@This(), "external_event_materialization"));
    try @import("std").testing.expect(!@hasDecl(@This(), "BorrowedMetadataView"));
    try @import("std").testing.expect(!@hasDecl(@This(), "OwnerEventView"));
    try @import("std").testing.expect(!@hasDecl(@This(), "OwnerEventProjector"));
    try @import("std").testing.expect(!@hasDecl(@This(), "projectOwnerEventInternal"));
}

test "session-host 테스트 root는 지원 OS의 process-owned generation state를 먼저 초기화한다" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return;
    try @import("session_host/client_slot.zig").ClientSlot.initializeProcessRuntime();
}
// client_deadline(P5c3c-1a)는 nonblocking connect/read/write의 absolute deadline과 syscall
// injection만 소유한다. protocol parser와 hello/capability 상태의 SSOT는 계속 client.zig 하나다.
pub const client_deadline = if (builtin.os.tag == .macos)
    @import("session_host/client_deadline.zig")
else
    struct {};
// client_pump(P5c3c-2b2a)는 fd/parser/JSON/allocator를 모르는 순수 turn/state DTO다.
pub const client_pump = @import("session_host/client_pump.zig");
pub const client_poison = @import("session_host/client_poison.zig");
// client_control_correlation(P5c3c-2b2f2)는 control request/response의 단일 outstanding
// correlation reducer다. fd/TX queue/payload allocator는 owning pump adapter가 계속 소유한다.
pub const client_control_correlation =
    @import("session_host/client_control_correlation.zig");
pub const control_response_wire =
    @import("session_host/control_response_wire.zig");
pub const external_recovery_types =
    @import("session_host/external_recovery_types.zig");
// external_rx_types는 parser/ledger/recovery가 공유하는 pointer-free observation DTO다.
// owning demux/ledger mechanics는 barrel로 노출하지 않는다.
pub const external_rx_types = @import("session_host/external_rx_types.zig");
test {
    _ = @import("session_host/external_rx_demux.zig");
    _ = @import("session_host/ended_purge_transaction.zig");
}
// runtime_event_reducer(P5c3c-2b2c3-c3b)는 이미 common wire/classifier를 통과한 inherited
// event FIFO를 allocation/ownership 없이 fold한다. Client·ledger·pump lifecycle은 import하지 않는다.
pub const runtime_event_reducer = @import("session_host/runtime_event_reducer.zig");
// client_external_source_decision(P5c3c-2b2c3-c3b)는 sealed fold를 allocation 없이
// terminal/action/recovery/adopted 중 하나로 닫는다. owning materialization과 pump publish는 소유하지 않는다.
pub const external_source_decision = if (builtin.os.tag == .macos)
    @import("session_host/external_source_decision.zig")
else
    struct {};
// Metadata owner 구현은 client_external_pump 내부 전용이며 barrel에서 재노출하지 않는다.
pub const external_adoption_limits =
    @import("session_host/external_adoption_limits.zig");
// client_source_transcript(P5c3c-2b2c3-c3b)는 Client/protocol 의미를 모르는 std-only
// domain-separated byte encoder다. schema field order는 후속 Client adapter가 명시적으로 소유한다.
pub const client_source_transcript = @import("session_host/client_source_transcript.zig");
// attach_phase_deadline(P5c3c-1b)는 public attach의 네 pre-raw phase label과 client_deadline의
// non-resettable absolute deadline만 결합한다. parser/resolver와 Client transport는 phase enum을 모른다.
pub const attach_phase_deadline = if (builtin.os.tag == .macos)
    @import("session_host/attach_phase_deadline.zig")
else
    struct {};
// external_tty(P5c1)는 공개 attach parser보다 먼저 local controlling TTY의 transactional raw/restore와
// 종료 signal self-pipe 경계를 고정한다. host runtime을 소유하지 않으며 macOS 제품 CLI에서만 사용한다.
pub const external_tty = if (builtin.os.tag == .macos)
    @import("session_host/external_tty.zig")
else
    struct {};
pub const external_detach_chord = @import("session_host/external_detach_chord.zig");
pub const external_stdout_progress = @import("session_host/external_stdout_progress.zig");
pub const external_loop_policy = @import("session_host/external_loop_policy.zig");
pub const external_loop_owner = @import("session_host/external_loop_owner.zig");
pub const external_tty_output = if (builtin.os.tag == .macos)
    @import("session_host/external_tty_output.zig")
else
    struct {};
pub const external_resize = if (builtin.os.tag == .macos)
    @import("session_host/external_resize.zig")
else
    struct {};
pub const external_ansi = if (builtin.os.tag == .macos)
    @import("session_host/external_ansi.zig")
else
    struct {};
pub const external_attach = if (builtin.os.tag == .macos)
    @import("session_host/external_attach.zig")
else
    struct {};
pub const external_attach_evidence = if (builtin.os.tag == .macos)
    @import("session_host/external_attach_evidence.zig")
else
    struct {};
pub const external_pump_owner = if (builtin.os.tag == .macos)
    @import("session_host/external_pump_owner.zig")
else
    struct {};
pub const remote_attachment = if (builtin.os.tag == .macos)
    @import("session_host/remote_attachment.zig")
else
    struct {};
pub const attach_resolver = if (builtin.os.tag == .macos)
    @import("session_host/attach_resolver.zig")
else
    struct {};
pub const attach_product_resolver = if (builtin.os.tag == .macos)
    @import("session_host/attach_product_resolver.zig")
else
    struct {};
pub const attach_tty = if (builtin.os.tag == .macos)
    @import("session_host/attach_tty.zig")
else
    struct {};
pub const resize_wire = @import("session_host/resize_wire.zig");
// runtime_manager(실 runtime 소유 — app InProcessTermBackend 재사용)는 `@import("maru")`로 app 스택을 끌어와 macOS에서만
// 컴파일한다. codec(protocol/framing/screen_stream/registry/server)은 여전히 maru를 모르는 platform-import-0 순수 계층이다.
pub const runtime_manager = if (builtin.os.tag == .macos)
    @import("session_host/runtime_manager.zig")
else
    struct {};
// agent_hook_logs(AH7-3a)는 host 가 **자기 소유** 훅 로그 칸을 만들고 치운다(docs/agent-hooks.md §4).
// `maru` 의 계약 모듈에서 이름을 받아 오고 macOS syscall(mkdir/unlink/rmdir/fstatat)을 쓰므로 같은 규율로 gate 한다.
pub const agent_hook_logs = if (builtin.os.tag == .macos)
    @import("session_host/agent_hook_logs.zig")
else
    struct {};
// handoff_inventory(U0)는 실행 중 host upgrade의 owner-field 누락을 compile-time에 막는다. 실제 codec/exec가 아니라
// TerminalCore/PTY/live runtime owner 필드를 serialized/reconstructed/must_be_empty로 전수 분류하는 gate다.
pub const handoff_inventory = if (builtin.os.tag == .macos)
    @import("session_host/handoff_inventory.zig")
else
    struct {};
// handoff_codec(U1)는 native owner inventory와 독립된 stable v1 tag/envelope로 logical TerminalCore candidate를
// encode/decode한다. 실제 live graph capture는 U2 safe-point가 생긴 뒤 runtime_manager가 별도 project 단계로 연결한다.
pub const handoff_codec = if (builtin.os.tag == .macos)
    @import("session_host/handoff_codec.zig")
else
    struct {};
// upgrade_coordinator(U2)는 queue lifecycle과 분리된 process-local admission barrier다. OS syscall이 없어
// non-macOS test에서도 gate 상태 머신을 검증한다.
pub const upgrade_coordinator = @import("session_host/upgrade_coordinator.zig");
pub const upgrade_wire = @import("session_host/upgrade_wire.zig");
pub const upgrade_owner = @import("session_host/upgrade_owner.zig");
pub const exec_fd_set = if (builtin.os.tag == .macos)
    @import("session_host/exec_fd_set.zig")
else
    struct {};
pub const upgrade_attempt = if (builtin.os.tag == .macos)
    @import("session_host/upgrade_attempt.zig")
else
    struct {};
pub const exec_upgrade_e2e = if (builtin.os.tag == .macos)
    @import("session_host/exec_upgrade_e2e.zig")
else
    struct {};
pub const owner_lease = if (builtin.os.tag == .macos)
    @import("session_host/owner_lease.zig")
else
    struct {};
pub const host_pool = @import("session_host/host_pool.zig");
pub const host_adapter = if (builtin.os.tag == .macos)
    @import("session_host/host_adapter.zig")
else
    struct {};
pub const host_manifest = if (builtin.os.tag == .macos)
    @import("session_host/host_manifest.zig")
else
    struct {};
pub const staged_image = if (builtin.os.tag == .macos)
    @import("session_host/staged_image.zig")
else
    struct {};
pub const rollback_image = if (builtin.os.tag == .macos)
    @import("session_host/rollback_image.zig")
else
    struct {};
pub const upgrade_target = if (builtin.os.tag == .macos)
    @import("session_host/upgrade_target.zig")
else
    struct {};
pub const code_signature = if (builtin.os.tag == .macos)
    @import("session_host/code_signature.zig")
else
    struct {};
pub const handoff_store = if (builtin.os.tag == .macos)
    @import("session_host/handoff_store.zig")
else
    struct {};
pub const upgrade_attempt_record = @import("session_host/upgrade_attempt_record.zig");
pub const upgrade_deadline = @import("session_host/upgrade_deadline.zig");
pub const upgrade_fd_layout = @import("session_host/upgrade_fd_layout.zig");
pub const upgrade_limits = @import("session_host/upgrade_limits.zig");
pub const upgrade_product_coordinator = if (builtin.os.tag == .macos)
    @import("session_host/upgrade_product_coordinator.zig")
else
    struct {};
pub const upgrade_bootstrap = if (builtin.os.tag == .macos)
    @import("session_host/upgrade_bootstrap.zig")
else
    struct {};
pub const restore_activation = if (builtin.os.tag == .macos)
    @import("session_host/restore_activation.zig")
else
    struct {};
pub const upgrade_executor = if (builtin.os.tag == .macos)
    @import("session_host/upgrade_executor.zig")
else
    struct {};
pub const upgrade_loop = if (builtin.os.tag == .macos)
    @import("session_host/upgrade_loop.zig")
else
    struct {};
pub const upgrade_preflight = if (builtin.os.tag == .macos)
    @import("session_host/upgrade_preflight.zig")
else
    struct {};
// screen_snapshot(실 TerminalCore 화면 → screen_stream 레코드 투영)도 `@import("maru")`로 terminal을 읽어 macOS 전용이다.
// 투영 자체는 순수 로직이지만 terminal 타입 의존이라 barrel에서 조건부로 둔다(screen_stream codec은 그대로 순수 유지).
pub const screen_snapshot = if (builtin.os.tag == .macos)
    @import("session_host/screen_snapshot.zig")
else
    struct {};
// remote_screen(조립기 runs → terminal.RenderSnapshot cells)도 terminal.Cell/Style를 만들어 macOS 전용이다. 렌더 경로가
// 로컬/원격에서 같은 RenderSnapshot을 소비하게 하는 SSOT 변환(e2e-2a). 조립기(screen_assembler)는 순수라 그대로 둔다.
pub const remote_screen = if (builtin.os.tag == .macos)
    @import("session_host/remote_screen.zig")
else
    struct {};
// remote_runtime(client 쪽 원격 runtime — host runtime_manager의 상대)도 client·Surface·terminal을 써서 macOS 전용이다.
// client RPC로 host runtime을 spawn/제어하고 snapshot/delta를 RemoteScreen으로 조립해 원격-backed Surface로 노출한다(e2e-2c-2).
pub const remote_runtime = if (builtin.os.tag == .macos)
    @import("session_host/remote_runtime.zig")
else
    struct {};
// remote_term_backend(host-backed TermRuntimeBackend — P2 계약의 원격 구현)도 client·Surface·app 계약을 써서 macOS 전용이다.
// InProcessTermBackend의 형제로, spawn/pump/입력/resize/close를 client RPC+RemoteRuntime에 매핑한다(e3-2). app_session이
// 이걸 termBackend()로 반환하면(e3-4) GUI가 in-process와 같은 계약으로 host-backed 터미널을 몬다.
pub const remote_term_backend = if (builtin.os.tag == .macos)
    @import("session_host/remote_term_backend.zig")
else
    struct {};
pub const host_reconnect_window_transaction = if (builtin.os.tag == .macos)
    @import("session_host/host_reconnect_window_transaction.zig")
else
    struct {};

test {
    // 자식 파일의 inline test를 이 barrel의 test 그래프에 모은다(refAllDecls는 얕아 명시 참조가 필요).
    _ = @import("session_host/generation_attachment_contract.zig");
    _ = @import("session_host/executed_response.zig");
    _ = @import("session_host/response_payload_allocation.zig");
    _ = @import("session_host/attachment_cleanup_registry.zig");
    _ = @import("session_host/generation_batch_registry.zig");
    _ = @import("session_host/generation_transport.zig");
    _ = @import("session_host/generation_attachment.zig");
    // `--stream` 의 프레이밍과 왕복을 재는 test 가 여기 있다. barrel 이 안 끌면 그 test 는
    // **어느 스위트에서도 안 돈다** — 같은 함정을 S11-1 에서 한 번 겪었다(변이가 SURVIVED 로
    // 나와 스위트를 잘못 골랐음을 알았다).
    if (builtin.os.tag == .macos) _ = @import("session_host/external_attach_cli.zig");
    comptime {
        if (@import("session_host/executed_response.zig").max_owned_response_bytes !=
            protocol.max_control_json)
            @compileError("ExecutedResponse cap drifted from MRSH response frame cap");
    }
    @import("std").testing.refAllDecls(@This());
}
