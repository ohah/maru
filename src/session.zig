//! L2 session core 파사드. **OS-중립** 세션 로직을 담는다 — 입력/재정렬 수학(input_math)·IME 판정(ime)·
//! 에이전트 관찰 상태(agent_observer)·세션 모델(session_model: Term/Pane/Tab/PaneTree + workspace 트리
//! 변환 + pane hit-test). S2(2차)로 세션 모델을, 3차(D1·D2)로 src/app 순수 모델(split_tree·workspace·surface·window·core_command)을
//! session으로 이동 완료 — session→app=0을 check-boundaries 가드로 고정(docs/layering-and-portability.md §3.1·§3.2). chrome(L3)이
//! props로 읽고 platform(L4)이 구현/투영한다. 이 레이어엔 OS 타입(Metal·CoreText·AppKit·PTY)이 새지 않는다
//! — tests/boundary/imports.zig가 강제.

pub const input_math = @import("session/input_math.zig");
pub const layout_math = @import("session/layout_math.zig");
pub const web_panel_layout = @import("session/web_panel_layout.zig"); // Phase 4a: 웹 패널 rect(본문 rect)·px↔pt y-flip·surface 생애주기 diff 순수 계산(docs/web-panel.md §10 4a·§11·§14)
pub const surface_id = @import("session/surface_id.zig"); // M0a: 앱 전역 surface_id allocator(순수 타입, 인스턴스 소유는 L4)
pub const SurfaceIdAllocator = surface_id.SurfaceIdAllocator;
pub const window_membership = @import("session/window_membership.zig"); // M0b: window↔surface membership DTO + metadata scope 필터(순수 판정)
pub const WindowMembershipSnapshot = window_membership.WindowMembershipSnapshot;
pub const WindowKind = window_membership.WindowKind;
pub const MetadataScope = window_membership.MetadataScope;
pub const window_graph = @import("session/window_graph.zig"); // M1: window→workspace→pane→surface_ref 순수 배치 모델 + move/merge
pub const WindowGraph = window_graph.WindowGraph;
pub const group_normalize = @import("session/group_normalize.zig"); // M3c: 사이드바 그룹 정규화 순수 함수(마커 승계·핀 재정규화·depth 파생) L2 리프트
pub const live_surface_registry = @import("session/live_surface_registry.zig"); // M2a: 앱 전역 live surface 런타임 소유자 골격(주소 안정 heap, generic Rt)
pub const LiveSurfaceRegistry = live_surface_registry.LiveSurfaceRegistry;
pub const surface_move = @import("session/surface_move.zig"); // M3d-1: cross-window 이동 원자 트랜잭션(구독 재평가·trust cap·빈 창 판정, 순수 오라클 위)
pub const MoveOutcome = surface_move.MoveOutcome;
pub const SurfaceMovedEvent = surface_move.SurfaceMovedEvent;
pub const control_plane = @import("session/control_plane.zig"); // Track C 1a: 세션 컨트롤 플레인 wire 프로토콜(JSON-RPC 2.0/ndjson/hello, 순수 schema/parser/framing)
pub const control_surface = @import("session/control_surface.zig"); // Track C 1c: 컨트롤 플레인 Surface 엔티티 DTO + 직렬화 + read-only 디스패치 코어(§3·§6·§8.3)
pub const SurfaceDto = control_surface.SurfaceDto;
pub const CollectorSnapshot = control_surface.CollectorSnapshot;
pub const control_dispatch = @import("session/control_dispatch.zig"); // Track C 1d: read-only 바이트→바이트 디스패치 라우터(요청 바이트 + snapshot → 응답 바이트, §6·§8.3)
pub const control_capability = @import("session/control_capability.zig"); // Track C 1e: capability fd 인가 코어(hash(nonce)→cap store, constant-time lookup, scope↔method, fd payload, §8.3·§8.5)
pub const CapabilityStore = control_capability.CapabilityStore;
pub const Capability = control_capability.Capability;
pub const control_capture = @import("session/control_capture.zig"); // Track C 1f: session.capture 프로토콜 코어(chunk 스트림 상태머신·base64·generation 고정/invalidated·재시도 상한 fallback·authz ack, §4.3·§6·§8.3·§8.5)
pub const control_browser = @import("session/control_browser.zig"); // Track C 5a: browser.* wire 스키마 + 디스패치 + browser capability authz(제어코어 skeleton, §9.1)
pub const control_bridge = @import("session/control_bridge.zig"); // Track C 5b: 신뢰 웹 브리지(window.maru.*) 디스패치 코어(auth 없음=신뢰는 Swift origin/frame 검증, §8.1.1)
pub const control_events = @import("session/control_events.zig"); // Track C 5f-0: browser 이벤트 채널 코어(EventBroker 구독 레지스트리·매칭·notification 직렬화·coalesce 분류, §9.5.2)
pub const control_outbound = @import("session/control_outbound.zig"); // Track C 5f-0b: per-connection outbound 프레임 큐(응답+이벤트 통합 bounded FIFO·coalesce·purge, §9.5.1·9.5.6)
pub const control_result = @import("session/control_result.zig"); // Track C 5f-5b: executeScript result-byte 예약·outbound 회계
pub const control_pane_grant = @import("session/control_pane_grant.zig"); // Track C 1e-confirm: pane-bound confirm-grant 저장소(Model B — grant를 tty-검증 pane 신원에 묶어 저장, §9.2)
pub const app_scheme = @import("session/app_scheme.zig"); // Phase 5c-1: maru-app:// 경로 샌드박스(traversal/whitelist, L2 순수) + CSP([web-panel.md] §7.1)
pub const Capture = control_capture.Capture;
pub const CaptureIdAllocator = control_capture.CaptureIdAllocator;
pub const BrowserMethod = control_browser.BrowserMethod;
pub const ime = @import("session/ime.zig");
pub const keyhint_hold = @import("session/keyhint_hold.zig"); // 단축키 힌트 홀드 gesture 정책(OS-중립, platform이 alias로 참조)
pub const agent_observer = @import("session/agent_observer.zig");
pub const session_model = @import("session/session_model.zig");
pub const split_tree = @import("session/split_tree.zig");
pub const dock_panel = @import("session/dock_panel.zig"); // FP1: 창 레벨 파일 도크의 OS-중립 소유 모델 + 단일 그룹 영속 DTO
pub const dock_layout = @import("session/dock_layout.zig"); // FP3: right/bottom 도크·terminal·chrome rect와 resize 순수 기하
pub const dock_drag = @import("session/dock_drag.zig"); // FP9: 파일 탭 drag gesture·dock-local target snapshot(terminal drag와 typed 격리)
pub const file_panel_bridge = @import("session/file_panel_bridge.zig"); // FP4: readAsset 상대 경로·읽기 상한·MIME 순수 정책
pub const syntax_theme = @import("session/syntax_theme.zig"); // FP12b: 터미널 색상 테마 → text 소스 편집기 syntax 색 파생(순수)
pub const live_preview_budget = @import("session/live_preview_budget.zig"); // FP10b: 앱 전역 worker admission과 64/16 MiB 상한
pub const mermaid_protocol = @import("session/mermaid_protocol.zig"); // FP10c1: parent/helper가 공유하는 bounded wire codec SSOT
pub const mermaid_coordinator = @import("session/mermaid_coordinator.zig"); // FP10c1: 앱 전역 queue/capability/deadline/failure 정책 SSOT
pub const file_tree = @import("session/file_tree.zig"); // FP7: OS-중립 파일 트리 snapshot·접힘·멀티루트·최근 파일 모델
pub const file_tree_navigation = @import("session/file_tree_navigation.zig"); // 파일 트리 transient selection·키보드 탐색·scroll 순수 정책
pub const file_tree_mutation = @import("session/file_tree_mutation.zig"); // 파일 트리 변경 이름·root·dirty 보호·path remap 순수 정책
pub const workspace = @import("session/workspace.zig");

// split_tree 헬퍼 re-export(app.zig에서 D1로 이동 — divider·app_session이 쓴다). SplitTree는 leaf-generic이라
// platform이 `session.SplitTree(*Pane)`으로 인스턴스화한다.
pub const SplitTree = split_tree.SplitTree;
pub const SplitDirection = split_tree.SplitDirection;
pub const SplitRect = split_tree.Rect;
pub const splitRect = split_tree.splitRect; // leaf-독립 헬퍼(생성용 a/b rect)
pub const clampRatio = split_tree.clampRatio; // divider 드래그가 layout과 같은 ratio 한도를 쓰게(단일 출처)
pub const surface = @import("session/surface.zig");
pub const window = @import("session/window.zig");
pub const core_command = @import("session/core_command.zig");

// surface/window 헬퍼 re-export(app.zig에서 D2로 이동 — platform이 쓴다).
pub const Surface = surface.Surface;
pub const RestorableSurfaceMetadata = surface.RestorableSurfaceMetadata;
pub const ProcessState = surface.ProcessState;
pub const AppWindow = window.AppWindow;

test {
    @import("std").testing.refAllDecls(@This());
}
