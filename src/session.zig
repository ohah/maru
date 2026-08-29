//! L2 session core 파사드. **OS-중립** 세션 로직을 담는다 — 입력/재정렬 수학(input_math)·IME 판정(ime)·
//! 에이전트 관찰 상태(agent_observer)·세션 모델(session_model: Term/Pane/Tab/PaneTree + workspace 트리
//! 변환 + pane hit-test). S2(2차)로 세션 모델을, 3차(D1·D2)로 src/app 순수 모델(split_tree·workspace·surface·window·core_command)을
//! session으로 이동 완료 — session→app=0을 check-boundaries 가드로 고정(docs/layering-and-portability.md §3.1·§3.2). chrome(L3)이
//! props로 읽고 platform(L4)이 구현/투영한다. 이 레이어엔 OS 타입(Metal·CoreText·AppKit·PTY)이 새지 않는다
//! — tests/boundary/imports.zig가 강제.

pub const ssh = struct {
    /// SSH 바이너리 패킷(RFC 4253 §6) — **sans-io**(계약 docs/ssh-client.md §2: 소켓을 모른다).
    pub const packet = @import("session/ssh/packet.zig");
    /// 와이어 자료형(RFC 4251 §5) — string·name-list·mpint.
    pub const wire = @import("session/ssh/wire.zig");
    /// 버전 교환(RFC 4253 §4.2) — 배너 여러 줄을 넘긴다.
    pub const version = @import("session/ssh/version.zig");
    /// KEXINIT 협상(RFC 4253 §7.1) + strict KEX 표시자.
    pub const kexinit = @import("session/ssh/kexinit.zig");
    /// curve25519 키 교환(RFC 8731 + RFC 5656 §4) — 공유 비밀·교환 해시 H·키 유도.
    pub const kex = @import("session/ssh/kex.zig");
    /// `chacha20-poly1305@openssh.com` — 패킷 암호화·인증(명세 워크드 예제로 못박았다).
    pub const cipher = @import("session/ssh/cipher.zig");
    /// 전송 루프 — 시퀀스 번호·`NEWKEYS` 전환·strict KEX 수신 게이트.
    pub const transport = @import("session/ssh/transport.zig");
    /// 호스트키 — `ssh-ed25519` 서명 검증과 지문(RFC 8709).
    pub const hostkey = @import("session/ssh/hostkey.zig");
    /// `known_hosts` 대조 — 이 서버가 우리가 아는 그 서버인가(TOFU·지문 변경 거부).
    pub const known_hosts = @import("session/ssh/known_hosts.zig");
    /// 사용자 인증(RFC 4252) — publickey(ed25519)·password.
    pub const userauth = @import("session/ssh/userauth.zig");
    /// `openssh-key-v1` 개인키 파싱(평문·bcrypt+aes256-ctr).
    pub const private_key = @import("session/ssh/private_key.zig");
    /// `session` 채널(RFC 4254) — `pty-req`·`shell`·데이터·`window-change`·종료 + 흐름 제어 양방향.
    pub const channel = @import("session/ssh/channel.zig");
    /// **세션 하나를 잇는 상태기계** — 버전 교환→KEX→인증→채널→셸. sans-io 라 host 가 바이트를
    /// 밀어 넣는다(모바일은 그것 말고는 방법이 없다). 검증 도구와 모바일이 **같은 것**을 쓴다.
    pub const client = @import("session/ssh/client.zig");
    // **sans-io 경계는 `tests/boundary/ssh_sans_io.zig` 가 강제한다** — 이 디렉터리를 직접 훑어
    // `std.<X>` 를 허용 목록으로 건다. 여기 안에 두면 스캐너가 자기 자신을 스캔하게 되고,
    // 등록 목록으로 세던 앞선 판정자가 그래서 무력했다(그 파일 머리 주석에 실측을 적어 뒀다).
};
pub const input_math = @import("session/input_math.zig");
pub const layout_math = @import("session/layout_math.zig");
pub const web_panel_layout = @import("session/web_panel_layout.zig"); // Phase 4a: 웹 패널 rect(본문 rect)·px↔pt y-flip·surface 생애주기 diff 순수 계산(docs/plans/web-panel.md §10 4a·§11·§14)
pub const resource_usage = @import("session/resource_usage.zig"); // 상태바 리소스 항목: pid 표본 합산·CPU 차분·고정 폭 포맷(순수 — syscall 없음, docs/status-bar.md §6)
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
pub const agent_transcript = @import("session/agent_transcript.zig"); // 세션 기록 파일에서 마지막 대화(사이드바 행 §7)
pub const agent_session_archive = @import("session/agent_session_archive.zig"); // Codex·Claude 과거 세션 JSONL 요약(우측 기록 도크)
pub const agent_session_archive_view = @import("session/agent_session_archive_view.zig"); // archive workspace group·3줄 카드 순수 투영
pub const agent_session_archive_detail = @import("session/agent_session_archive_detail.zig"); // 도크 inline disclosure의 최근 turn·action 요약 순수 투영
pub const agent_image_index = @import("session/agent_image_index.zig"); // IG1: 트랜스크립트 JSONL에서 이미지 **위치**만 찾는 순수 스캐너(바이트를 옮기지 않는다)
pub const image_scale = @import("session/image_scale.zig"); // IG3: 텍스처 상한 안으로 줄이는 **계산**(생성 아님 — 초과는 abort 라 계산만 CI가 본다)
pub const agent_statusline = @import("session/agent_statusline.zig"); // claude 상태줄 훅(§7.2.2 — 옵션 보강)
pub const agent_hook_command = @import("session/agent_hook_command.zig"); // provider 훅 인라인 커맨드(docs/agent-hooks.md §4.1, 순수)
pub const agent_hook_event = @import("session/agent_hook_event.zig"); // 훅 이벤트 로그 파서·tail 커서(§4, 순수)
pub const agent_hook_install = @import("session/agent_hook_install.zig"); // 훅 설치 계획 판정(§5, 순수)
pub const agent_hook_trust = @import("session/agent_hook_trust.zig"); // codex 훅 신뢰 값 계산(§2.1, 순수)
pub const agent_hook_mode = @import("session/agent_hook_mode.zig"); // 훅 모드 판정·상태 전이(§1.2·§4, 순수)
pub const remote_agent_stream = @import("session/remote_agent_stream.zig"); // RA5: 원격 스트리머 wire 소비·채널 수명(hello·하트비트·강등, 순수)
pub const remote_tmux_route = @import("session/remote_tmux_route.zig"); // RA6: 원격 tmux 에서 오염된 nonce 를 역조회로 되찾는 판정(순수)
pub const session_model = @import("session/session_model.zig");
pub const split_tree = @import("session/split_tree.zig");
pub const dock_panel = @import("session/dock_panel.zig"); // FP1: 창 레벨 파일 도크의 OS-중립 소유 모델 + 단일 그룹 영속 DTO
pub const dock_layout = @import("session/dock_layout.zig"); // FP3: right/bottom 도크·terminal·chrome rect와 resize 순수 기하
pub const git_status = @import("session/git_status.zig"); // git porcelain v2·numstat 순수 파서(도크 소스 컨트롤 뷰)
pub const git_command = @import("session/git_command.zig"); // 읽기 전용 git argv·env 조립(외부 프로세스 실행 경로 차단)
pub const git_write_command = @import("session/git_write_command.zig"); // 쓰기 git argv·안전 술어(읽기와 환경·플래그가 갈린다 — 쓰기 문서 §1)
pub const git_locate = @import("session/git_locate.zig");
pub const turn_snapshot = @import("session/turn_snapshot.zig"); // 에이전트 턴 경계 스냅샷 정책(§6.1, 순수)
pub const turn_capture = @import("session/turn_capture.zig"); // 턴이 만진 파일의 그림자 사본 보관 정책(§4.4, 순수)
pub const repo_path = @import("session/repo_path.zig"); // 저장소 루트 안쪽 상대경로 판정(심층 방어 — 순수)
pub const diff_payload = @import("session/diff_payload.zig"); // E1: diff 본문 페이로드 상한·binary 정책(순수) // git 실행 파일 후보 열거(설치 여부 판정 — shim 회피)
pub const scm_view = @import("session/scm_view.zig"); // 도크 소스 컨트롤 뷰 행 모델(섹션·개수·증감)
pub const scm_repos = @import("session/scm_repos.zig"); // 도크가 세울 저장소·워크트리 목록(순서·중복·상한)
pub const git_log = @import("session/git_log.zig"); // 히스토리 탭 커밋 목록 파서(--format 단일 출처, 순수)
pub const content_menu = @import("session/content_menu.zig"); // 파일 본문 우클릭 메뉴 항목 정책(file-panel-kinds.md §2.6)
pub const file_panel_bridge = @import("session/file_panel_bridge.zig"); // FP4: readAsset 상대 경로·읽기 상한·MIME 순수 정책
pub const syntax_theme = @import("session/syntax_theme.zig"); // FP12b: 터미널 색상 테마 → text 소스 편집기 syntax 색 파생(순수)
pub const syntax_capture = @import("session/syntax_capture.zig"); // N4 §5.3: tree-sitter capture 이름 → syntax 색 역할(다대일, 순수)
pub const agent_selection = @import("session/agent_selection.zig"); // 파일 패널 선택 → 에이전트 CLI 페이로드(순수)
pub const mermaid_protocol = @import("session/mermaid_protocol.zig"); // FP10c1: parent/helper가 공유하는 bounded wire codec SSOT
pub const mermaid_coordinator = @import("session/mermaid_coordinator.zig"); // FP10c1: 앱 전역 queue/capability/deadline/failure 정책 SSOT
pub const mermaid_theme = @import("session/mermaid_theme.zig"); // 터미널 색상 테마 → mermaid 팔레트 파생(순수, per-render)
pub const file_tree = @import("session/file_tree.zig"); // FP7: OS-중립 파일 트리 snapshot·접힘·멀티루트·최근 파일 모델
pub const file_tree_navigation = @import("session/file_tree_navigation.zig"); // 파일 트리 transient selection·키보드 탐색·scroll 순수 정책
pub const file_tree_mutation = @import("session/file_tree_mutation.zig"); // 파일 트리 변경 이름·root·dirty 보호·path remap 순수 정책
pub const file_tree_layout = @import("session/file_tree_layout.zig"); // 파일 트리 픽셀 스크롤 ↔ 행 인덱스 순수 산술 — 그리기와 히트테스트의 단일 출처
pub const workspace = @import("session/workspace.zig");
pub const workspace_checkpoint = @import("session/workspace_checkpoint.zig"); // P4 C1: dirty 세대·debounce/retry·final Quit 순수 coordinator
pub const runtime_reconcile = @import("session/runtime_reconcile.zig"); // P4 R2b: manifest↔host inventory 순수 분류
/// 화면 레코드 wire 코덱(§12). **OS 를 안 부르는 순수 코드**라 여기 산다 — host 가 굽고,
/// GUI 가 읽고, 폰이 SSH 너머로 받은 것을 같은 코덱으로 조립한다(소비자가 셋이다).
pub const screen_stream = @import("session/screen_stream.zig");
/// 위 레코드를 화면 모델로 되돌리는 조립기. 투영의 역이고 역시 순수하다.
pub const screen_assembler = @import("session/screen_assembler.zig");
pub const host_protocol = @import("session/host_protocol.zig"); // P5a2: daemon/CLI 공용 typed error와 bounded inventory 응답 정책 SSOT
pub const cache_path = @import("session/cache_path.zig"); // public CLI와 GUI session-host discovery의 `<cache>/maru` 경로 정책 SSOT

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

/// N1: 네이티브 편집기 L2 문서 모델(docs/native-editor-document-model.md §3). 위치 정본은 UTF-8 byte offset이고
/// 화면 좌표로의 변환은 L3(chrome)가 맡는다 — 이 네임스페이스는 플랫폼·렌더를 import하지 않는다.
pub const editor = struct {
    pub const line_index = @import("session/editor/line_index.zig");
    pub const selection = @import("session/editor/selection.zig");
    pub const document = @import("session/editor/document.zig");
    /// 읽어 온 bytes를 문서 + 논리행 인덱스로 묶는다 — 뷰가 필요로 하는 것을 한 번에 준다.
    pub const open = @import("session/editor/open.zig");
    /// N1.5: diff 본문의 줄 대응(§7 — git은 두 쪽 전문만 주고 대응은 여기서 만든다).
    pub const diff = @import("session/editor/diff.zig");
    pub const diff_state = @import("session/editor/diff_state.zig");
    pub const intraline = @import("session/editor/intraline.zig");
    pub const fold = @import("session/editor/fold.zig");
    /// 문서 내 검색의 일치 계산(§5.1) — 순수 함수라 여기 산다. 오버레이 UI는 chrome이 이미 갖고 있다.
    pub const find = @import("session/editor/find.zig");
    /// N2: 편집 가능한 텍스트 버퍼(§3.0 — persistent rope). `document`가 파일 *속성*을 든다면
    /// 이쪽은 *내용*을 들고, 스냅숏이 §2.1의 워커 분리를 가능하게 하는 성질이다.
    pub const buffer = @import("session/editor/buffer.zig");
    /// N2: 커서 이동 일습(§3.2 — 문자·낱말·smart home·줄 끝·목표 열). **논리 축만 안다** —
    /// 랩이 켜졌을 때의 시각 행 이동은 화면 폭을 아는 L3가 조립한다.
    pub const motion = @import("session/editor/motion.zig");
    /// N2: 클립보드 조각 경계와 분배 규칙(§3.4 — 멀티 커서가 규칙을 규정한다). 시스템 클립보드에는
    /// 통짜가 들어가므로 "조각이 몇 개였나"는 앱이 따로 기억해야 하고, 그 기억이 지금 클립보드를
    /// 설명하는지 판정하는 것이 순수 계산이라 여기 산다.
    pub const clipboard = @import("session/editor/clipboard.zig");
    /// N2: 타이핑 보조 — 괄호·따옴표 자동 닫기·type-over·surround(§3.7). **문맥을 묻지 않는다** —
    /// 문자열/주석 판정은 토큰 층(§5.3)의 일이고 아직 없어, 그 절이 정한 **저하 동작**을 한다.
    pub const pairs = @import("session/editor/pairs.zig");
    /// N2: 파일이 어떤 **언어**인가(확장자·파일명). 계약은 [문서 모델] §3.7a가 소유한다 — 세 곳이
    /// 없는 §5를 가리키고 있어서 그 절을 새로 세웠다(§5는 언어를 **입력으로 받는** 쪽이다).
    /// 지금 실소비처는 주석 토글(§3.7)이고, 구문 강조·자동 들여쓰기가 뒤따를 자리다.
    pub const language = @import("session/editor/language.zig");
    /// N2: 한 번의 편집을 값으로 만든다(§3.3 — 여러 range를 담고 selection을 같은 연산에서 민다).
    /// 스택·그룹핑은 시계와 입력 사건을 읽어야 해서 여기 없다.
    pub const delta = @import("session/editor/delta.zig");
    /// N2: "다음 일치 추가"가 커서를 놓을 자리(§9.1). 대소문자를 가리고 씨앗이 낱말이면 경계를
    /// 본다 — `find`(⌘F)와 일부러 다른 규칙이고, 그 근거는 모듈 머리말이 든다.
    pub const occurrence = @import("session/editor/occurrence.zig");
    /// N2: 편집 가능한 문서 — 버퍼(§3.0)와 소비처가 읽는 평탄한 축을 한 소유자에게 묶는다.
    /// `open`(읽기 전용, bytes를 빌린다)의 편집판이다.
    pub const edit_doc = @import("session/editor/edit_doc.zig");
};

// surface/window 헬퍼 re-export(app.zig에서 D2로 이동 — platform이 쓴다).
pub const Surface = surface.Surface;
pub const RestorableSurfaceMetadata = surface.RestorableSurfaceMetadata;
pub const ProcessState = surface.ProcessState;
pub const AppWindow = window.AppWindow;

test {
    @import("std").testing.refAllDecls(@This());
    @import("std").testing.refAllDecls(editor);
    // **네임스페이스 자식은 따로 ref 한다** — `refAllDecls` 는 한 단계라, 소비처가 아직 없는
    // 모듈은 테스트를 써 놔도 집계 밖이다(chrome.ui.gesture 가 실제로 그랬다).
    @import("std").testing.refAllDecls(ssh);
}
