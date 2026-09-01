//! L2 session core — OS-중립 세션 모델(Term/Pane/Tab + split 트리).
//!
//! 런타임 부착(PTY 세션·이벤트 펌프·생애 플래그)은 generic 파라미터 `Rt`로 주입한다 —
//! platform/macos/app_session이 `TermRuntime`을 넣어 `Model(TermRuntime)`으로 인스턴스화하고, 이 레이어는
//! PTY/렌더 핸들을 모른 채 모델만 소유한다(`SplitTree(comptime Leaf)` 선례). 단일 출처:
//! docs/layering-and-portability.md §3.1.
//!
//! 이 레이어엔 OS 타입(Metal·CoreText·AppKit·PTY)이 식별자로 새지 않는다 — tests/boundary/imports.zig가 강제.
//! `surface`(터미널 그리드/스크롤백)·`split_tree`(레이아웃 트리)는 이미 OS-중립인 src/app 모듈이고, `agent_state`는
//! 중립 판정 결과(agent_observer.State)다.

const std = @import("std");
const surface_mod = @import("surface.zig");
const split_tree = @import("split_tree.zig");
const agent_observer = @import("agent_observer.zig");
const agent_transcript_mod = @import("agent_transcript.zig");
const agent_hook_event = @import("agent_hook_event.zig");
const agent_hook_mode = @import("agent_hook_mode.zig");
const agent_state_arbiter = @import("agent_state_arbiter.zig");
const agent_hook_command = @import("agent_hook_command.zig"); // RA5: 원격 pane 신원 상수·대조
const remote_agent_stream = @import("remote_agent_stream.zig"); // RA5: 원격 이벤트 채널 수명
const agent_image_index = @import("agent_image_index.zig");
const workspace = @import("workspace.zig"); // OS-중립 직렬화 모델(session.workspace.v1) — TreeNode 변환용
const control_surface = @import("control_surface.zig");
const dock_panel = @import("dock_panel.zig"); // FP16: 파일 entry 소유를 Term으로 옮긴다(§1). 의존은 workspace.zig 경유로 이미 존재. // SurfaceKind(terminal|web)·PanelKind 열거 재사용(web-panel.md §6 4e)

const Surface = surface_mod.Surface;

/// surface 종류(terminal|web) — 단일 출처는 control_surface(§3). `Term.kind`가 트리에 **web surface**(WKWebView 패널)를
/// terminal과 같은 leaf/탭 모델로 담게 한다(web-panel.md §6 "web surface는 Term이다"). platform·web_panel_layout과
/// 같은 열거를 공유해 kind가 경계마다 재정의되지 않는다.
pub const SurfaceKind = control_surface.SurfaceKind;
/// web 패널 종류(markdown|browser) — 단일 출처는 control_surface. web Term의 라벨(`Term.webPanelLabel`) 파생과
/// (후속) trust/WKWebView config 선택의 기반. "닫힌 열거"(web-panel.md §7 — 새 종류는 사용자 승인 필요).
pub const PanelKind = control_surface.PanelKind;

/// Term 포그라운드에서 도는 에이전트 CLI 종류. 사이드바에 심볼로 표시(claude=✶, codex=◆).
/// platform이 PTY proc_name 폴링(pollAgentKinds)으로 채우는 파생값이고, 모델은 라벨 표시에만 쓴다.
pub const AgentKind = enum(u8) { none = 0, claude, codex };

/// 세션 모델 생성자 — 런타임 부착 타입 `Rt`로 parametrize한다(platform=`TermRuntime`).
/// `const Model = session_model.Model(TermRuntime); const Term = Model.Term;` 식으로 platform이
/// 별칭을 잡으면 기존 `Term`/`*Term`/`Pane`/`Tab`/`PaneTree` 참조가 전부 그대로다.
pub fn Model(comptime Rt: type) type {
    return struct {
        /// 한 터미널의 모델 — surface(OS-중립 그리드/스크롤백)와 라벨·git·agent 메타. 런타임 부착은 `rt: Rt`로
        /// 주입(platform=TermRuntime). 모델은 `Rt`(PTY 결합)를 모른 채 surface·메타만 소유한다.
        pub const Term = struct {
            /// 한 surface를 **참조만** 한다(소유 아님) — M3a: surface는 앱 전역 `LiveSurfaceRegistry`가 `LiveSurface`
            /// 번들 슬롯으로 소유하고(주소 안정 heap), Term은 그 슬롯의 `&slot.surface`를 든다. 값→포인터는 M2b가
            /// `live_pty`에 한 것과 동형(auto-deref로 `term.surface.core` 등 읽기 접근은 그대로 유효).
            /// 단일 출처: docs/window-surface-mobility.md §8A.1(옵션 A).
            surface: *Surface = undefined,
            /// surface 종류(terminal|web). 기본 `.terminal` — 기존 terminal Term 생성(`.{ ... }`)은 이 기본을 받아
            /// **byte-identical**(호출부 무변경). `.web`이면 `surface`는 registry LiveSurface **web arm의 sentinel**
            /// (빈 core — 렌더/PTY 없음)을 가리키고 `rt`엔 live PTY가 없다(web-panel.md §6 "web surface는 Term"). 렌더
            /// skip·WKWebView 부착은 후속(4e-2/4e-3) — 이 필드는 트리에 web을 담는 판별자다.
            kind: SurfaceKind = .terminal,
            /// web Term(`kind == .web`)의 패널 종류(markdown|browser). terminal Term엔 무의미(기본값 무시). web Term
            /// 라벨(`webPanelLabel`)과 (후속) trust/WKWebView config 파생의 **단일 출처** — LiveSurface web arm에
            /// 중복 저장하지 않는다("중복 저장 없이"). 기본 `.markdown`이라 terminal Term은 byte-identical.
            web_panel_kind: PanelKind = .markdown,
            /// 이 Term이 파일 패널이면 그 파일 entry(경로·kind·mode·dirty·revision·pending). FP16이 소유를
            /// `DockGroup`에서 여기로 옮긴다 — Term이 곧 entry의 집이므로 "어느 탭에 어느 파일" 관계가 별도
            /// 자료구조 없이 성립한다(docs/file-panel.md §1).
            ///
            /// **값이 아니라 포인터**인 이유: `Entry`는 필드 27개(대부분 u64)라 값으로 박으면 파일과 무관한
            /// terminal Term까지 전부 그 비용을 내고, OS-중립 L2 모델이 파일 패널 필드를 통째로 알게 된다.
            /// heap 포인터는 Term 이동·pane ArrayList 변형에도 안정적이라 비동기 ack가 들고 있기에도 낫다
            /// (오늘의 `&group.entries.items[i]`는 append 한 번에 무효화된다).
            ///
            /// null이면 파일 패널이 아니다. `kind == .web`이어도 브라우저면 null이다.
            file_entry: ?*dock_panel.Entry = null,
            /// WP-P: 복원된 브라우저 Term이 **자기 WKWebView가 생긴 뒤** 로드할 URL(owned, 소비하면 null).
            /// 복원 즉시 navigate할 수 없기 때문에 Term이 들고 있는다 — WKWebView는 `computeWebSurfaceTransitions`가
            /// `created`를 내고 Swift가 붙인 뒤에야 존재한다(docs/workspace-restore.md §WP-P). 주소창 commit이 쓰는
            /// 단일 슬롯은 복원(여러 개 동시)을 담을 수 없어 소유를 Term으로 둔다.
            pending_url: ?[]u8 = null,
            /// 런타임 부착(PTY 세션·pump·생애 플래그) — generic `Rt`로 주입. platform이 `TermRuntime`을 넣는다.
            rt: Rt = .{},
            /// git 브랜치 표시 캐시(owned, cwd 파생). termGitBranch가 cwd 변경 또는 주기 만료에 재계산. destroyTerm이 해제.
            git_branch: ?[]const u8 = null,
            git_branch_cwd: ?[]const u8 = null,
            /// 그 캐시를 마지막으로 계산한 시각(ns, awake clock; 0=아직 없음). **cwd만으로는 무효화되지 않기
            /// 때문에** 있다: 같은 폴더에서 `git checkout`·`git init`·저장소 삭제가 일어나면 답이 바뀌는데 cwd는
            /// 그대로다. 실제 앱에서 저장소를 지웠을 때 도크는 "git 저장소가 아닙니다"인데 상태바·사이드바는 옛
            /// 브랜치를 계속 보여줬다(2026-08-12 GUI 확인).
            ///
            /// 갱신은 `.git` 변경 이벤트가 이 값을 앞당겨(platform `invalidateTermGitBranches`) 일어나고, 시간
            /// 만료는 그 이벤트가 닿지 않는 저장소를 위한 백스톱이다. 그래서 이 필드는 "언제 다시 읽을지"의
            /// 단일 지점이고, 이벤트와 백스톱이 같은 값을 통해 만난다.
            git_branch_polled_ns: i128 = 0,
            /// 포그라운드가 어떤 에이전트 CLI인지(파생값). pollAgentKinds가 ≈0.5s마다 proc_name으로 갱신.
            agent_kind: AgentKind = .none,
            /// **권위표가 낸 결과**(docs/agent-hooks.md §1.1). 배지·사이드바가 읽는 값이다.
            ///
            /// 예전에는 이 자리 하나를 훅과 화면이 **번갈아 직접** 썼다. 훅은 그것을 상태 기계의 입력으로도
            /// 쓰므로(`advance(current = agent_state)`) 화면이 덮으면 기계가 오염됐다 — 중재가 아니라
            /// 마지막에 쓴 쪽이 이기는 덮어쓰기였다. 그래서 소스별 자리를 따로 두고(`agent_hook_state`·
            /// `agent_screen_state`) 이 필드는 **중재 결과만** 담는다(§1.6-⑴).
            agent_state: agent_observer.State = .unknown,
            /// 훅 payload 만으로 세운 상태(§1.1 의 `hook`). `agent_hook_mode.advance` 의 입력이자 출력이라
            /// **화면이 절대 건드리면 안 된다.**
            agent_hook_state: agent_observer.State = .unknown,
            /// 화면·OSC 만으로 세운 상태(§1.1 의 `screen`). `Stabilizer` 를 통과한 값이다.
            agent_screen_state: agent_observer.State = .unknown,
            /// 화면 판정이 함께 낸 신뢰도 플래그. 권위표의 C1·C2 가 이 둘로 선다.
            agent_screen_visible_blocker: bool = false,
            agent_screen_visible_idle: bool = false,
            /// 화면 상태를 세운 근거(§1.4). A 경로에서 그대로 결과의 출처가 된다.
            agent_screen_origin: agent_state_arbiter.Origin = .screen,
            /// 화면을 새로 판정한 횟수. 중재기가 «같은 관측을 두 번 세지 않게» 하는 입력이다 — 한 tick 에
            /// 중재가 여러 번 불릴 수 있어(원격 채널 드레인 + 폴링 소비자) 호출을 세면 C2 임계가 몇 배
            /// 빨리 온다.
            agent_screen_seq: u64 = 0,
            /// 이 Term 의 중재기. C2 의 연속 셈을 들고 있어 **Term 마다 하나**여야 한다.
            agent_arbiter: agent_state_arbiter.Arbiter = .{},
            /// 마지막 판정의 출처·규칙(§1.4 — 진단용). 배지 옆에 소스를 밝힐 수 있어야 버그 보고가 성립한다.
            agent_state_origin: agent_state_arbiter.Origin = .hook,
            agent_state_rule: []const u8 = "",
            /// 훅이 연 턴의 일련번호. `turn_key` 가 바뀔 때 올린다 — C2 의 연속 셈을 언제 버릴지의 유일한
            /// 입력이고, 안 올리면 C2 가 한 번 성공한 뒤 다음 턴을 즉시 접는다(§1.6-⑵-a).
            agent_hook_turn_seq: u64 = 0,
            agent_stabilizer: agent_observer.Stabilizer = .{},
            /// observer가 마지막으로 읽은 TerminalCore write sequence와 마지막 PTY activity 시각(ms, awake clock).
            agent_screen_generation: u64 = 0,
            agent_last_output_ms: u64 = 0,
            /// 마지막 출력의 **wall clock** 시각(ns, 0=없음). `agent_last_output_ms`는 awake clock이라 시스템이
            /// 잠든 동안 멈춰, 사이드바 활동 시각이 잠자기를 통째로 건너뛴 값을 보여준다(밤새 재운 뒤 "3m"). 경과
            /// 표시는 이 값으로 잰다. 판정용 activity window는 계속 awake clock을 쓴다 — 그쪽은 "앱이 깨어 있는
            /// 동안 얼마나 최근인가"가 맞는 질문이라 의미가 다르다.
            agent_last_output_wall_ns: i96 = 0,
            /// 이 Term 이 **마지막 알림 확인 이후 새 출력을 받았는가**. 알림은 출력의 결과로만 생기므로,
            /// 조용한 Term 을 매 프레임 훑을 이유가 없다. 세우는 쪽은 drain 루프, 내리는 쪽은 확인한 소비자다.
            ///
            /// 이것만으로 «알림 없음» 을 단정하지는 않는다 — OSC 9/777 은 화면을 안 바꿀 수 있어 출력 신호가
            /// 서지 않을 수 있다. 그래서 소비자는 이 표시를 «먼저 볼 대상» 을 좁히는 힌트로만 쓰고, 바닥 주기
            /// 순회를 따로 남겨 놓친 것을 반드시 줍는다.
            output_since_notify_check: bool = false,
            /// 훅 모드에서 이벤트 로그를 어디까지 읽었는가(docs/agent-hooks.md §4.2). 파일이 회전하면
            /// 커서가 스스로 되돌아간다. 훅을 쓰지 않는 Term 에서는 손대지 않으므로 비용이 0이다.
            agent_hook_cursor: agent_hook_event.Cursor = .{},
            /// 그 pane 의 이벤트 로그가 **있는가**(마지막 tick 기준). 모드 판정의 유일한 입력이다
            /// (계약 §1.2 — 이벤트 개수나 시간으로 잡으면 가만히 있는 세션·이미 돌던 세션이 잘못 강등된다).
            agent_hook_log_present: bool = false,
            /// 커서가 읽고 있는 파일의 inode. **회전을 크기만으로 판정하면 놓친다** — 같은 크기로 갈린
            /// 파일이 있으면 옛 오프셋으로 새 내용을 읽어 줄 가운데부터 파싱한다(`resetIfRotated` 계약).
            agent_hook_cursor_inode: u64 = 0,
            /// 부재 중 쌓인 로그를 **따라잡는 중**인가(docs/agent-hooks.md §4). 그동안의 이벤트는 창이
            /// 없던 시간의 것이라 상태만 세우고 **알리지 않는다** — 재접속하자마자 몇 시간 전 턴의 «완료»
            /// 가 뜨면 거짓말이다. 첫 tick 만 막으면 안 된다: tick 상한은 이벤트 **개수**라 짧은 줄이 많은
            /// 파일은 여러 tick 에 걸쳐 따라잡고, 그 2번째 tick 부터 옛 알림이 새어 나간다.
            agent_hook_backlog_catchup: bool = false,
            /// 아직 띄우지 않은 훅 알림(계약 §6). 전이에서 예약하고 드레인 루프가 꺼내 간다 — 고정 크기라
            /// 힙을 잡지 않는다.
            agent_hook_notice: agent_hook_mode.PendingNotice = .{},
            /// 원격(SSH) Term 의 이벤트 채널([계획](../../docs/plans/remote-agent-state.md) RA5).
            ///
            /// **로컬 훅 경로와 자리를 나눈다.** 로컬은 `agent_hook_cursor` 로 파일을 tail 하지만 원격은
            /// 그 파일이 저쪽 기계에 있어, `maru agent-events` 가 흘린 wire 를 이 채널이 받는다. 두 입력이
            /// 한 Term 에 동시에 서면 계약 §1 이 금지하는 «두 소스» 가 되므로, **모드 판정이 그 둘을
            /// 배타로 가른다**(원격 Term 은 로컬 로그가 애초에 없다).
            ///
            /// `null` 이면 이 Term 에는 원격 축이 안 열렸다 — `maru ssh` 가 아니거나, 제한 서버라
            /// `hello` 가 안 왔거나(§11), 아직 여는 중이다.
            agent_remote_channel: ?remote_agent_stream.Channel = null,
            /// 그 Term 에 발급한 원격 pane 신원. 채널에 섞여 오는 이벤트 중 **우리 것**을 고르는 잣대다
            /// (`agent_hook_command.remoteNonceMatches`). 고정 크기라 힙을 안 잡는다.
            agent_remote_nonce: [agent_hook_command.remote_pane_nonce_max]u8 = undefined,
            agent_remote_nonce_len: u8 = 0,
            /// 이 턴의 진행 상태 — 자식이 몇이나 도는지와 lead 가 이미 끝났는지(계약 §2). 자식이 도는
            /// 동안 lead 의 `Stop` 은 턴 끝이 아니고, 그것을 완료로 다루면 «자식이 아직 도는데 완료
            /// 알림» 이 나간다.
            agent_hook_progress: agent_hook_mode.Progress = .{},
            /// lead 의 턴이 **열린 시각**(wall clock ns, 0=닫혀 있거나 모름). 훅 payload 에는 시각이 없어
            /// (provider 가 안 싣는다) 「이 턴이 얼마나 오래 열려 있었나」 를 답할 근거가 없었다 — 파일
            /// mtime 은 로그 전체의 마지막 쓰기라 개별 턴의 것이 아니다.
            ///
            /// **읽은 순간을 찍는다.** 훅에서 찍는 편이 정확하지만 그 셸(macOS `/bin/sh` = bash 3.2)에는
            /// 시각 내장이 없어 `date` 프로세스가 훅마다 하나씩 늘어난다(계약 §4.1 이 피한 비용).
            /// 그래서 해상도를 폴 간격으로 낮추는 대신 훅 비용을 0 으로 둔다.
            ///
            /// **backlog 따라잡기 중에는 찍지 않는다.** 그 이벤트는 창이 없던 시간의 것이라 지금을 찍으면
            /// 몇 시간 전 턴이 «방금 열렸다» 가 된다 — 알림·캡처를 억제하는 것과 같은 자리·같은 근거다.
            /// 그 구간의 턴은 시각을 **주장하지 않는다**(0 으로 남는다).
            agent_hook_turn_opened_wall_ns: i96 = 0,
            /// 훅 모드의 **진행 중 세부**(계약 §2). 관측 모드는 이 값을 쓰지 않는다 — 모드가
            /// 바뀌면 소비처가 아니라 `pollAgentConsumer` 가 비운다(남은 값이 다른 소스의 배지
            /// 옆에 붙으면 그것이 곧 두 소스 혼합이다).
            agent_hook_tool: agent_hook_mode.ToolLabel = .{},
            /// 훅이 알려 준 작업 디렉터리. **원격 pane 에서 OSC 7 이 멈춘 구간을 메운다** —
            /// 그 보고자는 `precmd` 라 전면 TUI 가 붙어 있는 동안 발화하지 못한다.
            agent_hook_cwd: agent_hook_mode.CwdLabel = .{},
            /// 사이드바 에이전트 행의 **마지막 대화**(프롬프트·응답) 캐시 + 세션 기록 파일 매핑
            /// (docs/sidebar-agent-list.md §7). 고정 크기라 힙을 잡지 않아 destroyTerm이 따로 해제하지 않는다.
            agent_transcript: agent_transcript_mod.Cache = .{},
            /// 이미지 갤러리가 읽을 트랜스크립트 절대 경로(docs/agent-image-gallery.md §4.1). 훅
            /// `transcript_path` 가 통째로 주므로 추측이 없다 — `agent_transcript.Cache.name` 은 파일 **이름**
            /// 뿐이라 디렉터리를 다시 조립해야 하고, 그 조립이 과거에 «다른 세션의 대화를 붙이는» 사고를 냈다.
            /// 고정 크기라 destroyTerm 이 따로 해제하지 않는다.
            agent_image_source: agent_image_index.Source = .{},
            /// 사이드바·탭 라벨용 자동 제목 캐시(owned). syncAutoTitles가 core.windowTitle()을 복사해 채운다. destroyTerm이 해제.
            auto_title: std.ArrayListUnmanaged(u8) = .empty,
            /// syncAutoTitles가 마지막으로 auto_title에 반영한 core.title_generation(P4-1). 코어의 현재 generation과 같으면
            /// 제목/cwd가 안 바뀐 것이라 lock+복사를 건너뛴다(매 tick 전-Term lock 제거 — docs/plans/io-render-threading.md §12).
            /// 0=아직 미반영(초기 windowTitle이 빈 상태와 일치 — 코어 title/cwd가 세팅돼야 generation이 ≥1로 오른다).
            last_title_gen: u32 = 0,

            /// 이 Term의 surface_id. terminal은 live surface, web은 sentinel surface의 id이고, **둘 다** 앱 전역
            /// `SurfaceIdAllocator`가 발급한 값이 `surface.id`에 실린다 — kind와 무관하게 여기서 파생하므로 Term에
            /// surface_id를 **중복 저장하지 않는다**(web arm sentinel이 web id를 든다). registry 조회·라우팅 키.
            pub fn surfaceId(self: *const Term) u64 {
                return self.surface.id;
            }

            /// web Term(`kind == .web`)의 kind 파생 기본 라벨(사용자 `custom_name`이 없을 때 탭·사이드바 표시).
            /// terminal Term에서 부르면 `web_panel_kind` 기본값 기준이라 무의미 — 호출자(platform termLabel)가
            /// `kind == .web`일 때만 쓴다. 값은 "닫힌 열거"(web-panel.md §7)라 exhaustive switch로 고정한다.
            pub fn webPanelLabel(self: *const Term) []const u8 {
                return switch (self.web_panel_kind) {
                    .markdown => "Markdown",
                    .browser => "Browser",
                };
            }
        };

        /// split leaf 하나 = 가로 탭(Term) 묶음. 항상 Term ≥1. tree leaf가 active_term의 surface를 가리킨다.
        pub const Pane = struct {
            terms: std.ArrayList(*Term) = .empty,
            active_term: usize = 0,
            /// 가로 탭 스크롤 offset(컬럼). 탭이 바 폭을 넘으면 ‹›/트랙패드가 이 값을 움직인다(per-pane).
            tab_scroll_cols: u32 = 0,
            /// 스크롤바 fade 타이머(per-pane). updateScrollbarFade가 view_offset 변화를 감지해 리셋.
            scrollbar_idle_ticks: u32 = 0,
            scrollbar_last_view_offset: usize = 0,
            /// 사용자 지정 이름(rename, owned). Pane은 자동 제목 출처가 없어 custom_name 하나뿐. destroyPane이 해제.
            custom_name: ?[]const u8 = null,

            /// 활성 Term(보이는 터미널). 입력/커서/렌더가 이 Term의 surface를 쓴다. Pane은 항상 Term ≥1.
            pub fn activeTerm(self: *Pane) *Term {
                return self.terms.items[self.active_term];
            }
        };

        /// 한 탭의 split 레이아웃 트리. leaf=`*Pane`. 순수 연산(layout·removeLeaf 등)은 split_tree가 소유.
        pub const PaneTree = split_tree.SplitTree(*Pane);

        /// 워크스페이스(사이드바 탭)의 panel들 + split 트리 루트. tree leaf가 각 Pane의 활성 Term surface를 가리킨다.
        pub const Tab = struct {
            panes: std.ArrayList(*Pane) = .empty,
            active_pane: usize = 0,
            /// SplitTree 루트(split 모델). 단일 leaf면 panel 1개 = 풀 탭. split이 leaf를 split 노드로 바꾼다.
            tree: PaneTree.Node = undefined,
            /// 워크스페이스 사용자 지정 이름(rename, owned). 없으면 활성 Term 라벨로 폴백. destroyTab이 해제.
            custom_name: ?[]const u8 = null,
            /// 위치 고정(Pin) — true면 드래그 재정렬에서 안 움직인다. workspace.v1 영속.
            pinned: bool = false,
            /// 사이드바 카드 배경 tint(0xRRGGBB, 0=기본 테마색). workspace.v1 영속.
            background_color: u32 = 0,
            /// 사이드바 카드 좌측 accent 막대색(0xRRGGBB, 0=기본 — 활성 카드는 테마 앰버, 비활성은 막대 없음).
            /// 지정하면 활성·비활성 카드 모두 그 색으로 막대 표시(배경 tint와 직교). workspace.v1 영속.
            accent_color: u32 = 0,
            /// 사이드바 그룹 **시작 마커**(위치 파생 소속 — docs/sidebar-groups.md §2.1). null=그룹 시작 아님
            /// (자기 위 가장 가까운 마커에 소속되거나, 위에 마커가 없으면 최상위). 소속 자체는 저장하지 않고
            /// self.tabs 순서에서 파생한다 — 이 필드는 "이 탭부터 이 이름의 그룹 시작"만 든다. owned(destroyTab 해제).
            group_start: ?[]const u8 = null,
            /// group_start!=null일 때만 의미 — 그 그룹이 접혔는지(영속). 검색 활성 동안은 projectRows가 일시 무시.
            group_collapsed: bool = false,
            /// 카드 하위 **에이전트 목록**이 접혔는가(docs/sidebar-agent-list.md §4). 에이전트가 2개 이상일 때만
            /// 토글 행이 생기므로 그때만 의미가 있다. **영속하지 않는다** — 에이전트 구성은 실행마다 달라져
            /// (어제 2개·오늘 0개) 접힘만 복원하면 빈 토글이나 어긋난 상태가 된다(파생 상태 비영속 규율).
            agents_collapsed: bool = false,
            /// 중첩 그룹 깊이 레벨(SG5-3 — docs/plans/sidebar-groups.md §9). group_start!=null일 때만 의미: 1=최상위 그룹,
            /// 2=그 안 중첩, … 소속과 마찬가지로 **정규화 depth는 위치에서 파생**(projectRows가 스택으로 재계산·클램프)하고
            /// 이 필드는 "이 마커가 얼마나 깊이 들어가려는가"의 힌트다. 최상위에서 create_group=1, 그룹 안에서=그 카드
            /// depth+1. workspace.v1 영속(group-depth, 기본 1=키 생략). 기본 1(비마커 탭에선 무의미).
            group_depth: u8 = 1,
            /// 사이드바 그룹 공통 색(0xRRGGBB, 0=색 없음/기본 폴백 — docs/plans/sidebar-groups.md §9 SG5-2). group_start!=null일
            /// 때만 의미 — 그룹 시작 마커 **하나에만** 저장하고, 소속 카드는 위치 파생으로 그 색을 따른다(별도 저장 없음,
            /// §2.1 위치 파생과 동형). 헤더 밴드 tint·소속 카드 좌측 accent 막대에 실린다. 개별 카드 background_color와는
            /// 다른 층(그룹 색=헤더+막대, 카드 배경=별도 tint)이라 서로 안 덮는다. workspace.v1 영속(group-color). 기본 0.
            group_color: u32 = 0,
            /// 그룹-로컬 pin(GL — docs/sidebar-groups-pinning.md §13). 이 카드가 **자기 그룹 subtree 안에서** 위로(마커 직후)
            /// 고정됐는가(그룹 안 leaf 멤버 전용). 전역 핀(Tab.pinned = [고정][비고정] 리전, §12)과 **직교하는 별개 축**이다:
            /// pinned=전역 프리픽스, local_pinned=한 그룹 subtree [marker, end) 내부 순서. group_start!=null(마커)·top-level
            /// 카드에선 무의미(마커=그룹 고정 권위·top카드=개별 pin은 Tab.pinned가 든다). **전역 파티션 머신**
            /// (countPinnedTabs·stablePartitionPinned·clampMoveToGroup·normalizePinnedFromGroups)은 이 필드를 **안 읽는다**
            /// — 멤버 pinned를 재해석하면 전역 partition이 그룹을 shred(C3)하므로 새 필드로 격리한다(§13). stablePartitionSubtree만
            /// 이 값으로 subtree 내부를 물리 재배열한다. workspace.v1 영속(local-pinned, 기본 false=키 생략). destroyTab 무관(스칼라).
            local_pinned: bool = false,
            /// §2.1 재설계 서브파티션 마커(docs/sidebar-groups-top-level.md §14). 한 핀 리전 **안**에서 이 카드가 **최상위(depth 0)로
            /// 복귀**하는 지점 = 앞 그룹 리전을 끝내는 리딩 break 신호(pin 플립과 동형의 두 번째 리셋 신호). 위치 파생 소속을
            /// **override**: 이 카드는 depth 0(top-level)이고 depth 스택을 비우며, 뒤 비마커 카드는 sticky-reset으로 빈 스택을 타
            /// 다음 마커 전까지 자동 top-level이다(§2.1 위치 파생을 서브파티션으로 일반화 — pin ⊃ subregion(top_level) ⊃ group ⊃
            /// nest). group_start==null(비마커)·leaf 카드 전용(마커의 형제 top-level 그룹은 group_depth=1 pop으로 표현하므로
            /// 마커엔 세팅 금지, local_pinned §13.8 선례). 전역 파티션과 직교(핀 프리픽스 I1 불변 — top_level은 항상 한 핀 리전
            /// 안의 안쪽 파티션). 소속·depth는 저장하지 않고 위치에서 파생하며(§2.1) 이 필드는 "여기서 그룹 리전 끝, 최상위 복귀"만
            /// 든다. workspace.v1 영속(top-level, 기본 false=키 생략 → 전 탭 false면 7 파생 경계 리셋/break가 no-op = byte-identical).
            /// destroyTab 무관(스칼라). SR1은 저장+파생 토대만 — 배선(createGroup write·드래그 전이·normalize 재작성)은 SR2~5.
            top_level: bool = false,

            /// 포커스된 panel. pane 내부(Term/surface) 접근에 쓴다. 탭은 항상 panel ≥1.
            pub fn activePane(self: *Tab) *Pane {
                return self.panes.items[self.active_pane];
            }
            /// 포커스된 panel의 활성 Term(탭 대표 surface).
            pub fn activeTerm(self: *Tab) *Term {
                return self.activePane().activeTerm();
            }
        };

        // ── workspace 직렬화 변환(PaneTree ↔ session.workspace.TreeNode) ──────────────────────────────────
        // 라이브 split 트리(세션 모델)와 직렬화 모델(session.workspace.v1) 사이의 pure 변환. PTY/렌더 없이
        // 트리 구조만 다루므로 session core가 소유한다(capture/restore 오케스트레이션·PTY spawn은 platform).

        /// 활성 탭 트리(PaneTree, `*Pane` leaf)를 `workspace.TreeNode` preorder 리스트로 평탄화(저장용).
        /// leaf는 `tab.panes`의 인덱스로, split은 방향+ratio_milli로 인코딩. arena만 할당하는 pure 함수.
        pub fn flattenTree(arena: std.mem.Allocator, tab: *Tab, node: PaneTree.Node, out: *std.ArrayList(workspace.TreeNode)) !void {
            switch (node) {
                .leaf => |pane_ptr| {
                    const idx = paneIndexOf(tab, pane_ptr) orelse return error.PaneNotFound;
                    try out.append(arena, .{ .leaf = idx });
                },
                .split => |s| {
                    const milli: u16 = @intFromFloat(@round(std.math.clamp(s.ratio, 0.0, 1.0) * 1000.0));
                    try out.append(arena, .{ .split = .{ .direction = s.direction, .ratio_milli = milli } });
                    try flattenTree(arena, tab, s.a, out);
                    try flattenTree(arena, tab, s.b, out);
                },
            }
        }

        fn paneIndexOf(tab: *Tab, pane: *Pane) ?usize {
            for (tab.panes.items, 0..) |p, i| {
                if (p == pane) return i;
            }
            return null;
        }

        /// `workspace.TreeNode` preorder를 `PaneTree.Node`(`*Pane`)로 복원. leaf 인덱스→`panes[i]`, split은
        /// 새 노드(allocator로 생성, `splits`에 추적). 같은 pane을 두 leaf로 참조하면 error(UAF 차단). allocator만
        /// 쓰는 pure 함수 — `self.allocator` 대신 인자로 받아 platform 비의존(호출자가 splits capacity 예약).
        pub fn buildTreeNode(allocator: std.mem.Allocator, panes: []const *Pane, nodes: []const workspace.TreeNode, idx: *usize, splits: *std.ArrayList(*PaneTree.Split), used: []bool) !PaneTree.Node {
            if (idx.* >= nodes.len) return error.MalformedTree;
            const node = nodes[idx.*];
            idx.* += 1;
            switch (node) {
                .leaf => |pane_index| {
                    if (pane_index >= panes.len) return error.MalformedTree;
                    if (used[pane_index]) return error.MalformedTree; // 같은 pane을 두 leaf로 참조(중복) — UAF 차단
                    used[pane_index] = true;
                    return .{ .leaf = panes[pane_index] };
                },
                .split => |s| {
                    const split = try allocator.create(PaneTree.Split);
                    splits.appendAssumeCapacity(split); // capacity 예약됨 — 무실패 추적(create↔추적 사이 누수 없음)
                    split.* = .{
                        .direction = s.direction,
                        .ratio = split_tree.clampRatio(@as(f32, @floatFromInt(s.ratio_milli)) / 1000.0),
                        .a = try buildTreeNode(allocator, panes, nodes, idx, splits, used),
                        .b = try buildTreeNode(allocator, panes, nodes, idx, splits, used),
                    };
                    return .{ .split = split };
                },
            }
        }

        // ── pane hit-test / 방향 탐색(순수, 레이아웃 rect 기반) ──────────────────────────────────────
        // 마우스 클릭 panel·키보드 방향 이동 대상을 split 레이아웃 rect로만 고른다(self/OS 무관). platform이
        // termRect로 layout해 leaf_rects를 만들어 넘긴다 — divider/sidebar hit-test가 chrome인 것과 같은 결로,
        // pane 선택은 session 모델 연산이다.

        /// 키보드 pane 이동 방향(좌/우/상/하). split 탭에서 활성 panel 기준 인접 panel을 고른다.
        pub const FocusDirection = enum { left, right, up, down };

        /// 레이아웃 rect들에서 (x_px,y_px)를 담는 panel을 hit-test([x,x+w)×[y,y+h) 반열린). 비유한/밖이면 null.
        /// 순수 함수(레이아웃 rect만 입력) — OS 무관.
        pub fn paneAtPoint(leaf_rects: []const PaneTree.LeafRect, x_px: f64, y_px: f64) ?*Pane {
            if (!std.math.isFinite(x_px) or !std.math.isFinite(y_px)) return null;
            for (leaf_rects) |lr| {
                const x0: f64 = @floatFromInt(lr.rect.x);
                const y0: f64 = @floatFromInt(lr.rect.y);
                if (x_px >= x0 and x_px < x0 + @as(f64, @floatFromInt(lr.rect.w)) and
                    y_px >= y0 and y_px < y0 + @as(f64, @floatFromInt(lr.rect.h)))
                {
                    return lr.leaf;
                }
            }
            return null;
        }

        /// 활성 panel에서 dir 방향 가장 가까운 인접 panel(없으면 null). panel rect 중심 비교 — 방향 반평면 안
        /// 후보 중 주축거리 + 부축어긋남×2(정렬 우대) 최소. 순수 함수 — OS 무관.
        pub fn paneInDirection(leaf_rects: []const PaneTree.LeafRect, active_pane: *Pane, dir: FocusDirection) ?*Pane {
            var active_rect: ?split_tree.Rect = null;
            for (leaf_rects) |lr| {
                if (lr.leaf == active_pane) {
                    active_rect = lr.rect;
                    break;
                }
            }
            const ar = active_rect orelse return null;
            const acx = @as(f64, @floatFromInt(ar.x)) + @as(f64, @floatFromInt(ar.w)) / 2.0;
            const acy = @as(f64, @floatFromInt(ar.y)) + @as(f64, @floatFromInt(ar.h)) / 2.0;
            var best: ?*Pane = null;
            var best_score: f64 = std.math.inf(f64);
            for (leaf_rects) |lr| {
                if (lr.leaf == active_pane) continue;
                const cx = @as(f64, @floatFromInt(lr.rect.x)) + @as(f64, @floatFromInt(lr.rect.w)) / 2.0;
                const cy = @as(f64, @floatFromInt(lr.rect.y)) + @as(f64, @floatFromInt(lr.rect.h)) / 2.0;
                const dx = cx - acx;
                const dy = cy - acy;
                const in_dir = switch (dir) {
                    .left => dx < 0,
                    .right => dx > 0,
                    .up => dy < 0,
                    .down => dy > 0,
                };
                if (!in_dir) continue;
                const primary: f64 = switch (dir) {
                    .left, .right => @abs(dx),
                    .up, .down => @abs(dy),
                };
                const secondary: f64 = switch (dir) {
                    .left, .right => @abs(dy),
                    .up, .down => @abs(dx),
                };
                const score = primary + 2.0 * secondary; // 부축 정렬(같은 행/열)을 우대
                if (score < best_score) {
                    best_score = score;
                    best = lr.leaf;
                }
            }
            return best;
        }
    };
}

// 이식성 증거: 진짜 `TermRuntime`(PTY/렌더 핸들) 없이 빈 fake `Rt`로 모델을 인스턴스화해 Term/Pane/Tab/
// split 트리를 헤드리스로 구성·조회할 수 있어야 한다. 이게 가능하면 모델이 OS/런타임에 결합하지 않았다는
// 뜻이고(Linux 등 다른 타깃이 같은 모델을 재사용), S2-4b 추출이 의도대로 됐음을 증명한다.
test "session model: 헤드리스 — fake Rt로 Term/Pane/Tab/PaneTree 구성(PTY·surface 없이)" {
    const FakeRt = struct {}; // PTY/OS 핸들 0 — platform의 TermRuntime을 대신하는 빈 런타임.
    const M = Model(FakeRt);
    const allocator = std.testing.allocator;

    // Term을 PTY 없이 만든다(surface는 undefined로 두고 모델 메타만 단언 — 모델은 런타임을 모른다).
    var t1: M.Term = .{ .agent_kind = .claude };
    try std.testing.expectEqual(AgentKind.claude, t1.agent_kind);
    try std.testing.expectEqual(agent_observer.State.unknown, t1.agent_state);

    // Pane이 *Term을 가로 탭으로 들고 activeTerm을 반환한다.
    var pane: M.Pane = .{};
    defer pane.terms.deinit(allocator);
    try pane.terms.append(allocator, &t1);
    try std.testing.expectEqual(&t1, pane.activeTerm());

    // PaneTree(split 트리)가 *Pane leaf로 구성된다 — surface/PTY 없이 레이아웃 모델만(split_tree 위임).
    var p2: M.Pane = .{};
    var split = M.PaneTree.Split{ .direction = .horizontal, .a = .{ .leaf = &pane }, .b = .{ .leaf = &p2 } };
    const root: M.PaneTree.Node = .{ .split = &split };
    try std.testing.expectEqual(@as(usize, 2), M.PaneTree.leafCount(root));

    // Tab이 트리를 들고 activePane/activeTerm을 반환한다.
    var tab: M.Tab = .{ .tree = root };
    defer tab.panes.deinit(allocator);
    try tab.panes.append(allocator, &pane);
    try std.testing.expectEqual(&pane, tab.activePane());
    try std.testing.expectEqual(&t1, tab.activeTerm());
}

// 4e-1: web Term(kind=.web)이 트리에 담기고, surfaceId()/webPanelLabel()이 kind로 분기하며, 한 Pane이
// terminal+web Term을 혼합해도 activeTerm()이 활성 Term(web 포함)을 돌려줌을 헤드리스로 못박는다(web-panel.md §6).
// sentinel surface는 빈 core(1×1)로 흉내낸다 — 렌더/PTY 없이 id만 싣는 실제 Surface(platform이 registry web arm에
// 두는 것과 동형). terminal Term의 kind 기본값(.terminal)·surfaceId 파생이 byte-identical임도 함께 단언한다.
test "session model: web Term(kind=.web) + surfaceId/webPanelLabel kind 분기(fake Rt, sentinel surface)" {
    const FakeRt = struct {};
    const M = Model(FakeRt);
    const allocator = std.testing.allocator;

    // web Term(browser): sentinel surface(빈 core)에 web surface_id를 싣고, Term.kind=.web + web_panel_kind.
    var web_surface = try Surface.init(allocator, 4242, .{ .cols = 1, .rows = 1 });
    defer web_surface.deinit();
    var wt: M.Term = .{ .kind = .web, .web_panel_kind = .browser, .surface = &web_surface };
    try std.testing.expectEqual(SurfaceKind.web, wt.kind);
    try std.testing.expectEqual(@as(u64, 4242), wt.surfaceId()); // sentinel surface.id에서 파생(중복 저장 없음)
    try std.testing.expectEqualStrings("Browser", wt.webPanelLabel());

    // markdown web Term은 "Markdown" 라벨(닫힌 열거 분기).
    var md_surface = try Surface.init(allocator, 7, .{ .cols = 1, .rows = 1 });
    defer md_surface.deinit();
    var md: M.Term = .{ .kind = .web, .web_panel_kind = .markdown, .surface = &md_surface };
    try std.testing.expectEqualStrings("Markdown", md.webPanelLabel());

    // terminal Term 기본은 .terminal(생성부 무변경 byte-identical) — surfaceId도 live surface.id.
    var term_surface = try Surface.init(allocator, 9, .{ .cols = 4, .rows = 2 });
    defer term_surface.deinit();
    var tt: M.Term = .{ .surface = &term_surface };
    try std.testing.expectEqual(SurfaceKind.terminal, tt.kind); // 기본값
    try std.testing.expectEqual(@as(u64, 9), tt.surfaceId());
}

test "session model: 한 Pane에 terminal+web Term 혼합, activeTerm이 활성 Term(web 포함)을 반환(fake Rt)" {
    const FakeRt = struct {};
    const M = Model(FakeRt);
    const allocator = std.testing.allocator;

    var ts = try Surface.init(allocator, 1, .{ .cols = 4, .rows = 2 });
    defer ts.deinit();
    var ws = try Surface.init(allocator, 2, .{ .cols = 1, .rows = 1 });
    defer ws.deinit();
    var t_term: M.Term = .{ .surface = &ts }; // terminal(kind 기본)
    var w_term: M.Term = .{ .kind = .web, .web_panel_kind = .markdown, .surface = &ws };

    // 한 Pane이 terminal + web Term을 가로 탭으로 섞는다(§6 "한 Pane이 terminal Term + web Term을 가로 탭으로 섞을 수 있고").
    var pane: M.Pane = .{};
    defer pane.terms.deinit(allocator);
    try pane.terms.append(allocator, &t_term);
    try pane.terms.append(allocator, &w_term);
    try std.testing.expectEqual(@as(usize, 2), pane.terms.items.len);

    // 활성=0(terminal): activeTerm이 terminal Term.
    try std.testing.expectEqual(&t_term, pane.activeTerm());
    try std.testing.expectEqual(SurfaceKind.terminal, pane.activeTerm().kind);

    // 활성을 web으로 전환: activeTerm이 web Term(트리에 담긴 web surface — §6).
    pane.active_term = 1;
    try std.testing.expectEqual(&w_term, pane.activeTerm());
    try std.testing.expectEqual(SurfaceKind.web, pane.activeTerm().kind);
    try std.testing.expectEqual(@as(u64, 2), pane.activeTerm().surfaceId());
    try std.testing.expectEqualStrings("Markdown", pane.activeTerm().webPanelLabel());
}

// workspace 직렬화 변환(flattenTree→buildTreeNode)이 라이브 트리를 PTY/surface 없이 round-trip한다.
// 저장(라이브→TreeNode)·복원(TreeNode→라이브)이 session core에서 pure하게 닫힘을 증명한다(S2-5).
test "session model: workspace 트리 round-trip(flattenTree→buildTreeNode, fake Rt)" {
    const FakeRt = struct {};
    const M = Model(FakeRt);
    const allocator = std.testing.allocator;

    var pane0: M.Pane = .{};
    var pane1: M.Pane = .{};
    defer pane0.terms.deinit(allocator);
    defer pane1.terms.deinit(allocator);
    var split = M.PaneTree.Split{ .direction = .vertical, .ratio = 0.4, .a = .{ .leaf = &pane0 }, .b = .{ .leaf = &pane1 } };

    var tab: M.Tab = .{ .tree = .{ .split = &split } };
    defer tab.panes.deinit(allocator);
    try tab.panes.append(allocator, &pane0);
    try tab.panes.append(allocator, &pane1);

    // 라이브 트리 → preorder TreeNode 리스트([split, leaf0, leaf1]).
    var arena_inst = std.heap.ArenaAllocator.init(allocator);
    defer arena_inst.deinit();
    var nodes: std.ArrayList(workspace.TreeNode) = .empty;
    try M.flattenTree(arena_inst.allocator(), &tab, tab.tree, &nodes);
    try std.testing.expectEqual(@as(usize, 3), nodes.items.len);

    // TreeNode 리스트 → 라이브 트리 복원(leaf 인덱스→panes[i], split 새 노드).
    const panes = [_]*M.Pane{ &pane0, &pane1 };
    var splits: std.ArrayList(*M.PaneTree.Split) = .empty;
    defer {
        for (splits.items) |sp| allocator.destroy(sp);
        splits.deinit(allocator);
    }
    try splits.ensureTotalCapacity(allocator, 1);
    var used = [_]bool{ false, false };
    var idx: usize = 0;
    const root = try M.buildTreeNode(allocator, &panes, nodes.items, &idx, &splits, &used);
    try std.testing.expectEqual(@as(usize, 2), M.PaneTree.leafCount(root));
    try std.testing.expect(std.meta.activeTag(root) == .split);
}

// pane hit-test/방향 탐색이 레이아웃 rect만으로(self/OS 없이) 동작 — 마우스 pane 전환·키보드 pane 이동의
// 기하 코어. leaf는 pointer-identity만 쓰므로 빈 Pane 더미로 충분하다.
test "session model: paneAtPoint 헤드리스 hit-test(레이아웃 rect만, fake Rt)" {
    const M = Model(struct {});
    var a: M.Pane = .{};
    var b: M.Pane = .{};
    // 좌우 2-panel: a=[0,100)×[0,200), b=[100,200)×[0,200).
    const rects = [_]M.PaneTree.LeafRect{
        .{ .leaf = &a, .rect = .{ .x = 0, .y = 0, .w = 100, .h = 200 } },
        .{ .leaf = &b, .rect = .{ .x = 100, .y = 0, .w = 100, .h = 200 } },
    };
    try std.testing.expectEqual(&a, M.paneAtPoint(&rects, 50, 100).?);
    try std.testing.expectEqual(&b, M.paneAtPoint(&rects, 150, 100).?);
    try std.testing.expectEqual(&a, M.paneAtPoint(&rects, 0, 0).?); // 좌상단 경계 포함
    try std.testing.expectEqual(&b, M.paneAtPoint(&rects, 100, 0).?); // x=100 경계는 b(반열린)
    try std.testing.expect(M.paneAtPoint(&rects, 200, 0) == null); // 오른쪽 밖
    try std.testing.expect(M.paneAtPoint(&rects, 50, 200) == null); // 아래 밖
    try std.testing.expect(M.paneAtPoint(&rects, std.math.nan(f64), 5) == null); // 비유한
}

test "session model: paneInDirection 헤드리스 방향 탐색(반평면+정렬, fake Rt)" {
    const M = Model(struct {});
    var a: M.Pane = .{};
    var b: M.Pane = .{};
    var c: M.Pane = .{};
    var d: M.Pane = .{};

    // 좌우 2-panel: a 왼쪽, b 오른쪽.
    const lr = [_]M.PaneTree.LeafRect{
        .{ .leaf = &a, .rect = .{ .x = 0, .y = 0, .w = 100, .h = 200 } },
        .{ .leaf = &b, .rect = .{ .x = 100, .y = 0, .w = 100, .h = 200 } },
    };
    try std.testing.expectEqual(&b, M.paneInDirection(&lr, &a, .right).?);
    try std.testing.expectEqual(&a, M.paneInDirection(&lr, &b, .left).?);
    try std.testing.expect(M.paneInDirection(&lr, &a, .up) == null); // 좌우 split이라 위/아래 없음
    try std.testing.expect(M.paneInDirection(&lr, &c, .left) == null); // 활성 panel이 leaf에 없음

    // 2×2 격자: a=좌상, b=우상, c=좌하, d=우하. 정렬(같은 행/열) 우대.
    const grid = [_]M.PaneTree.LeafRect{
        .{ .leaf = &a, .rect = .{ .x = 0, .y = 0, .w = 100, .h = 100 } },
        .{ .leaf = &b, .rect = .{ .x = 100, .y = 0, .w = 100, .h = 100 } },
        .{ .leaf = &c, .rect = .{ .x = 0, .y = 100, .w = 100, .h = 100 } },
        .{ .leaf = &d, .rect = .{ .x = 100, .y = 100, .w = 100, .h = 100 } },
    };
    try std.testing.expectEqual(&b, M.paneInDirection(&grid, &a, .right).?); // a→우: b(같은 행)
    try std.testing.expectEqual(&c, M.paneInDirection(&grid, &a, .down).?); // a→하: c(같은 열)
    try std.testing.expectEqual(&d, M.paneInDirection(&grid, &b, .down).?); // b→하: d
    try std.testing.expectEqual(&c, M.paneInDirection(&grid, &d, .left).?); // d→좌: c(같은 행)
}
