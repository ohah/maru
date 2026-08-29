# 실제 구현 계획

이 문서는 Maru의 실제 구현 순서를 정한다. 기준은 "빨리 화면을 띄우는 것"이 아니라, 나중에 PTY, parser, renderer, workspace, plugin이 서로 엉켜서 다시 갈아엎지 않게 하는 것이다.

## 핵심 판단

초기 구현은 [초기 세로 슬라이스](initial-vertical-slice.md)를 기준으로 한다.

```text
macOS 로컬 shell 1개 surface
-> PTY output bytes
-> TerminalCore
-> snapshot/trace artifact
-> headless test 통과
```

중요한 점은 parser 전체를 먼저 만들지 않는 것이다. 완전한 VT parser를 먼저 파면 실제 PTY와 E2E 없이 parser 코드만 커질 가능성이 높다. 초기 구현에서는 실제 shell bytes가 Maru의 책임 경계를 지나가는 경로를 먼저 만들고, parser는 fixture가 요구하는 만큼만 작게 확장한다.

## TDD 기준

모든 단계가 같은 형태의 TDD를 갖지는 않는다.

- 순수 동작은 전통적인 red -> green -> refactor TDD를 한다.
- facade와 책임 경계는 compile-time contract test, import boundary test, public API smoke test로 검증한다.
- macOS PTY나 global shortcut처럼 OS 상태에 묶이는 영역은 unit test와 opt-in integration/app smoke test를 분리한다.
- 자동화가 불가능한 영역은 PR에서 이유와 수동 검증 산출물을 보고한다.

즉 1단계부터 TDD는 가능하지만, 1단계의 TDD는 화면 출력 테스트가 아니라 "이 경계가 유지되는가"를 검증하는 contract test다.

## 계획 문서 인덱스

단계·이니셔티브별 구현 계획과 완료 이력은 `docs/plans/` 아래 파일이 소유한다. 이 문서는 인덱스와
모든 계획에 공통인 원칙만 들고, 개별 단계의 서술은 갖지 않는다.

- [1~7단계 — facade·snapshot·parser·PTY·runtime·E2E·renderer 구현 계획](plans/core-slices.md)
- [8단계 — 탭·사이드바·split 구현 계획](plans/tabs-and-splits.md)
- [8단계 — chrome 폴리시와 에이전트 표시 구현 이력](plans/chrome-polish.md)
- [8단계 — 전역 단축키와 quick terminal 구현 이력](plans/quick-terminal-and-shortcuts.md)
- [터미널 입력 인코딩과 VT 프로토콜 구현 이력](plans/terminal-input-and-protocols.md)
- [메뉴바와 커맨드 팝업(Action 카탈로그) 구현 계획](plans/menu-and-command-palette.md)
- [9·10단계 — Workspace restore와 Plugin/Wasm 구현 계획](plans/workspace-restore.md)
- [백로그 — New Window와 chrome 고급화 (설계 근거 보존)](plans/new-window-and-chrome.md)
- [에이전트 세션 기록 도크 구현 계획](plans/agent-session-dock.md)
- [원격 에이전트 상태(배지·대화 줄) 구현 계획](plans/remote-agent-state.md)
- [ScrollArea 이관 구현 계획](plans/scroll-area.md)
- [네이티브 편집기 구현 계획](plans/native-editor.md)
- [에디터 Surface 단계 계획](plans/editor-surface.md)
- [소스 컨트롤 도크 2판 단계 계획](plans/scm-dock.md)
- [파일 탐색기 트리 컴포넌트 이관 단계 계획](plans/file-tree-component.md)
- [에이전트 훅 통합 단계 계획](plans/agent-hooks.md)
- [에이전트 턴 변경분 단계 계획](plans/agent-turn-changes.md)
- [에이전트 세션 도크 카드 구현 계획](plans/agent-session-list.md)
- [에이전트 이미지 갤러리 구현 계획](plans/agent-image-gallery.md)
- [사이드바 그룹 단계 분해](plans/sidebar-groups.md)
- [웹 패널 구현 계획](plans/web-panel.md)
- [다국어(i18n) 구현 계획](plans/i18n.md)
- [모바일 플랫폼 구현 계획](plans/mobile-platform.md)
- [Metal UI 구현·검증 순서](plans/metal-ui-layout.md)
- [I/O–렌더 스레딩 Phase 2~4](plans/io-render-threading.md)
- [TerminalCore 분해 기록](plans/terminal-core-decomposition.md)
- [Screen struct fold (방향 B)](plans/screen-struct-fold.md)
- [page-aligned storage](plans/page-aligned-storage.md)
- [Windows 플랫폼 구현 계획](plans/windows-platform.md)
- [SSH 클라이언트 구현 계획](plans/ssh-client.md)
- [maru-term 라이브러리 구현 계획](plans/maru-term-library.md)

설계 **계약**은 계획 문서가 아니라 각 영역의 설계 문서가 소유한다([AGENTS.md](../AGENTS.md) 참조).
계획 문서는 그 계약을 어떤 순서로 구현했고 무엇이 남았는지만 기록한다.

## 완료 기능 잔여 후속 (자투리 모음 — 각 완료 기능의 미착수 후속)

아래는 이미 **완료**된 기능들에 문서 곳곳 "한계/후속"으로 적힌 작은 잔여 항목을 한 곳에 모은 것이다(단일 출처는 여전히 각 기능 절). 새 기능이 아니라 다듬기라 우선순위는 낮고, 필요할 때 각자 작은 PR로 집어간다.

- **스크롤백 Find(⌘F)**: **⌘G/⌘⇧G(오버레이 닫힌 채 다음/이전 매치) — 완료**(`find_next`/`find_previous` 액션 + ⌘G/⌘⇧G 바인딩. `findNavigate`가 보존된 검색어로 재검색해 네비, `find_nav` 플래그로 닫힌 채도 현재 매치 하이라이트·출력 시 재검색 유지, 셸 타이핑이 종료. macOS Find Next 관례). **유니코드 케이스폴딩 — 완료**(`foldCase`: ASCII + Latin-1 À-Þ·Greek Α-Ω·Cyrillic 깔끔한 오프셋 블록까지 대소문자 무시 — café↔CAFÉ·αλφα↔ΑΛΦΑ·привет↔ПРИВЕТ. width.zig와 같은 "small first table" 정책 — Latin Ext-A는 parity flip이라 표 필요해 후속). **팝업에서 Find 띄우기 — 완료**(`toggle_find`/`find_next`/`find_previous`를 command 카탈로그에 등재 → ⌘⇧P 팝업에 Find/Find Next/Find Previous 노출, 선택 시 acceptPalette가 팝업을 닫고 Find를 연다. 자기 토글이라 재귀인 toggle_command_palette와 달리 Find는 별개 모달이라 띄운다). **alt screen에서도 Find — 완료(결정 B 반전)**: 이전엔 alt에서 Find를 껐으나(사용자 결정 B, iTerm2 관례), 자체 검색(`/`)이 없는 TUI(Claude/Codex)에선 검색 수단이 통째로 사라져 다시 켰다. 베이스: Ghostty도 alt에선 active area(현재 화면)만 검색한다(`search/active.zig` ActiveSearch — 동작만 참조, 구조는 maru 독립). `findSuppressed` 게이트(toggleFind/findNavigate/tick-close 3곳) 제거 → alt에서도 Find가 열리고 tick이 닫지 않는다. core `findMatches`는 alt에선 현재 화면(`[sb_count,total)`)만 스캔한다 — primary 스크롤백 매치는 scrollToAbs가 잠겨[무동작] 갈 수 없고 alt는 화면 밖을 스크롤백에 안 쌓으므로. 화면 전환(primary↔alt) 시 render-tick이 현재 매치 인덱스를 리셋한다(`find_was_alt` 비교). 반전은 사용자 재확인 완료. 잔여: regex/fuzzy(현재 부분일치).
- **런타임 폰트 크기(⌘+/⌘-/⌘0)**: **View 메뉴 항목(Bigger/Smaller/Actual Size) — 완료**(`command_catalog`의 `increase_font_size`/`decrease_font_size`/`reset_font_size` 3행을 `buildMainMenu`의 View 메뉴가 `catalogMenuItem`으로 얹어, 바인딩 chord가 keyEquivalent로 표시된다). **`set_font_size` 절대 지정 — 완료**(`Action.set_font_size: f32` — config 바인딩 전용 `set_font_size:18` 형태, `dispatchAppAction`이 `setFontSize`로 [6,72]pt 클램프. 절대값이라 어느 크기인지 고정 못 해 메뉴/팝업엔 안 넣는다). 잔여: **step 파라미터화**(현재 `font_size_step` 1pt 상수 고정 — config 노출 안 됨).
- **메뉴바(NSMenu)**: **Services·Open Config·Find 메뉴 항목 — 완료**. Services(Edit 서브메뉴 `NSApp.servicesMenu`), Open Config(App 메뉴 ⌘, — ABI v54 `config_path`로 경로[Zig loader `defaultConfigPath` 단일 출처]를 받아 Swift가 없으면 생성 후 기본 편집기로 열기), Find 서브메뉴(Find…/Find Next/Find Previous — keyEquivalent 없이 runAction, 단축키 ⌘F/⌘G/⌘⇧G는 Zig 키바인딩 소유라 안 가림). **Reload Config·Reset to Defaults — 완료**(ABI v56 — App 메뉴 "Reload Config"가 `menuReloadConfig`→`maru_macos_app_session_reload_config`로 config 파일을 재로드하고 `reapplyLoadedConfig`가 폰트·여백·테마·palette·scrollback·bell·page-keys를 재시작 없이 재적용한다. "Reset to Defaults"는 확인 모달 뒤 전체 기본값 복원). 잔여: **Cut/Undo**(터미널은 cut/undo 의미가 없어 보류 — 입력 필드 편집은 chrome 오버레이가 자체 처리), **config 파일 변경 자동 감지**(현재는 수동 Reload Config만 — watcher 없음).
- **커맨드 팝업(⌘⇧P)**: fuzzy 필터(현재 부분일치)·한글 IME 필터(현재 ASCII).
- **선택/클립보드**: 블록(직사각형) 선택 — **완료**(Option+드래그 = 직사각형 — iTerm2/Terminal.app 관례). `selection_block` 플래그 + `SelectionSpan.block`로 `extractSelection`(각 행 [lo,hi]·행마다 개행·뒤 빈칸 trim)·`inSelection`(모든 행 동일 열 범위)·`selectionViewportSpan`(col min/max 정렬)이 분기. platform mouse가 Option(mods&8)이면 `setSelectionBlock`하고 mouse-reporting override에 option 포함. `selectionStart` 시그니처는 불변(기존 호출처 보존).
- **New Window(멀티 윈도우)**: W3/W4 잔여 — global hotkey(toggle_window/quick)의 멀티 창 타게팅·창별 독립 config·탭 tear-off(창 간 탭 이동); W5 — atlas 공유(SharedGridSet식 grid-per-size, memory `multi-window-atlas-ownership` — 프로파일 후).
- **Workspace restore**: config 토글(현재 `MARU_NO_WORKSPACE_RESTORE` env-var)·부분 복구 artifact(한 surface 실패 시 이유 기록)·startup_recipe/env allowlist(정책 재확인 후)·repo별 workspace.
- **kitty graphics**: 비활성 panel 이미지 렌더·reflow 후 정밀 재배치·멀티 윈도우 텍스처 캐시 소유권(atlas 소유권 재검토와 함께). query/애니메이션은 위 kitty 절 K5 참조.

## Session host 실행 중 transport reconnect (CR, CR0a·CR2a~CR2e·CR3a·CR3b R1·R2a·R2b·R2c·R3 완료)

shared `Client`가 실행 중 unusable이 되어도 기존 Term/Surface/runtime handle을 유지한 채 exact host에 다시 붙이는 단계다.
규범 계약은 [영속 터미널 세션 호스트](persistent-session-host.md#실행-중-connection-invalidation과-재연결), 검증 상태와
종료 gate는 [검증 매트릭스](verification-matrix.md#영속-host-cr-실행-중-transport-reconnect-gate)가 소유한다. cold workspace
restore, host spawn, same-PID exec upgrade와는 별도 state machine이다.

1. **CR0a — typed poison taxonomy (완료):** reconnect와 artifact writer 없이 raw `Client.failClosed`와 내부 raw
   `invalidateConnection*` 직접 호출을 typed poison boundary로 모았다. 분류용 `Outcome`과 connection-fatal만 허용하는
   `ConnectionReason`을 타입으로 분리하고 `{scope,disposition,transport_usable,expected}` exhaustive golden table을 고정했다.
   최초 reason은 immutable이며 source/adoption/projection seal에 포함된다. clean EOF·read timeout/transport failure·framing
   truncation/malformed·write progress ambiguous/known partial·queue/OOM·peer contract·attachment cleanup을 구분하고 source
   boundary test가 named terminalization leaf 밖의 raw untyped callsite를 감시한다. semantic `Outcome` 4종은 이 단계에서는
   model-only이며 production semantic decode/dispatch 연결과 scope 축소는 CR1 범위다. reconnect와 artifact writer는 CR0b
   이후 범위다.
2. **CR0b — poison observability:** CR0a DTO만 소비하는 immutable `ConnectionIncident`, 최초 원인 보존, redaction/rate-limit,
   exact 208-byte DTO와 256-byte envelope, 120 incident+8 aggregate의 32 KiB emergency ring, first-reason과 incident의 단일
   publication suffix, process/fork/sequence authority, ring handoff→bounded disk writer 순서, Debug fail-stop과 Release
   artifact-before-recovery gate를 구현한다. exact schema와 lifecycle은 trace-replay의 CR0b 절을 단일 출처로 삼는다.
   Client publication은 실제 `Client -> ClientSlot -> HostAdapter -> HostPool` 소유권을 따르며, HostPool의 fallible generation/map
   reservation을 먼저 봉인하고 final-address Client binding을 게시한 뒤 같은 permit의 no-fail map suffix로 끝낸다. HostPool이
   Client를 직접 import하거나 pool publication 뒤 binding을 채우는 역방향 경로는 허용하지 않는다.
3. **CR1 — poison 범위 축소와 scheduler admission:** semantic stream 오류가 shared connection을 불필요하게 poison하지 않도록
   callsite를 정리하고 partial read/write, sibling stream, artifact 실패를 결정적으로 교차하는 production-type scheduler
   admission fixture를 만든다. CR1의 scheduler는 host에 접속하거나 runtime generation을 교체하지 않는다. CR0b의 sealed
   `ReconnectAdmission`을 exact 한 번 claim하고 `scheduled|retry_later|discarded_stale`로 정산하는 bounded owner와 closed decision만
   소유한다. `scheduled`는 같은 inline row를 scheduled job으로 바꾸고, `retry_later`는 admitted row를 보존하되 claim만 exact once 회수하며,
   `discarded_stale`는 pool membership/connection generation이 바뀌었다는 owner 증거가 있을 때만 소비한다. 실제
   `connectExistingHost`와 `PreparedReconnect`는 각각 CR4와 CR2e가 소유하므로 CR1이 raw socket, HostPool adapter 교체 또는
   Window tree 순회를 추가하면 선행 gate 우회다.
4. **CR2 — stable shell 기반:** CR2a는 current `RemoteRuntime`의 generation-owned field 12개
   (`connection`, `attachment`, `event_generation_tracking`, resize wire state 3개, pump state 4개, `observation`)와
   stable-shell 잔류 owner를 closed inventory로 고정하고 `RemoteGeneration`만 추출한다. Zig의 nested aggregate 정렬로
   `RemoteRuntime`은 Debug/ReleaseFast 모두 정확히 16바이트만 증가하며 기존 4,096-runtime 상한에서 64 KiB가 추가된다. direct-input/control queue와
   allocator/io/runtime ID, Surface, pending/close/lifetime owner는 이 단계에서 이동하지 않는다. **CR2b 완료:** 기존 Surface API를
   유지하는 final-address stable proxy gate를 배선했다. proxy는 exact pinned target unlock, writer-pending 우선권,
   checked-monotonic generation, unavailable placeholder와 shell destroy drain을 소유한다. `RemoteRuntime`은 proxy pointer를
   stable field로 두고 attach 때 live target을 게시하며 detach/deinit 때 proxy를 먼저 닫은 뒤 attachment screen을 파괴한다.
   **CR2c 완료:** local/remote `InputOwner` facade를 도입하되 입력 의미를
   바꾸지 않는다. transport-neutral facade는 `src/app/input_owner.zig`가 opaque runtime handle과
   blocking input·nonblocking partial progress·`CoreCommand` dispatch만 결속하고, `TermRuntimeBackend`가 backend별 함수표를
   공급한다. local/remote 구현은 기존 write leaf를 그대로 재사용하므로 오류·부분 수락·ordering이 달라지지 않는다.
   ordered queue/epoch/sequence/paused paste storage의 실제 소유권 이동은 CR2d가 담당한다. **CR2d1 완료:**
   remote paste·IME 확정·OSC52 응답을 `InputBatchKind`로 구분해 `InputOwner.enqueueBatch` 한 번에 stable
   `RemoteRuntime` queue로 소유 이전한다. batch는 checked-nonzero epoch/sequence와 byte range를 함께 기록하고 IME
   확정+replay 두 slice 및 LF→CR 정규화를 한 allocation transaction으로 수락한다. local Term은 closed
   `caller_owned` 결과로 기존 `AppSession.pending_pastes`를 계속 사용하며, remote 성공 뒤에는 Window-local queue entry를
   만들지 않는다. **CR2d2 완료:** paste 전용 public kind와 분리된 closed `QueueRecordKind`를 두고 blocking key bytes,
   scroll-to-bottom 및 core-command barrier도 같은 stable epoch/checked sequence transcript에 합친다. byte backing과
   control FIFO/barrier는 기존 물리 wire 순서를 유지하며 두 backing reserve 뒤에만 record를 게시하고, record는 실제
   byte/control ownership이 Client로 넘어갈 때 같은 순서로 retire한다. **CR2d3 완료:** event cursor를 stable shell에
   두며 `RemoteRuntime`은 CR2d2 기준 Debug 32바이트, ReleaseFast 48바이트 증가한다. 기존 4,096-runtime 상한의 추가
   inline budget은 각각 128 KiB와 192 KiB다. **CR2d4 완료:** cross-Window move/merge의 기존
   `PreparedPendingPasteTransfer`는 local caller-owned queue만 옮기고 remote Term은 제외한다. 마지막 source Window를
   닫은 뒤에도 stable input transcript와 BEL/OSC52 cursor가 같은 `RemoteRuntime`에 남는 parity를 golden test로 닫는다.
   **CR2e-a 완료:** pointer-free `ReconnectReducer`가 job phase, runtime authority ledger, local publication,
   mutation gate와 close overlay의 닫힌 전이를 소유한다. clean·ambiguous precommit 실패, controller evidence 없는
   writable publish, frozen retry reservation 누락, terminal summary 위조를 closed enum inventory와
   authority-prefix independent legal-event table로 거부한다. 제품 executor caller는 아직 0이다.
   **CR2e-b 완료:** final-address owner-thread mutation lease는 runtime당 64개를 상한으로 sealing 게시 뒤 active ordinal set 0을 기다리고 copied
   lease replay와 신규 admission을 거부한다. kind별 count/bytes/sequence range metadata를 남기며 완전본 paste 하나만
   paste당 1 MiB·app-global 8 MiB atomic budget 아래 secure buffer로 격리한다. resend staging도 같은 budget에 포함하고
   `Clock.boot` 10분 TTL과 prepared staging deinit/discard/expiry에서 non-elidable wipe 뒤 free한다. allocation 전 실패는
   caller-owned source와 budget을 mutation 없이 보존한다. 제품 caller는 아직 0이며 실제 queue enqueue의 single-use consume은
   CR2e-d/e가 닫는다.
   **CR2e-c 완료:** generic final-address `GenerationSlot`이 stable shell의 최초 inline node와 reconnect별 heap node를
   같은 payload 타입으로 소유하고, current/retiring exact pointer, retiring 1개 backoff, inline tombstone 재사용 금지,
   inline/heap final-address payload 초기화, exact-one reclaim, allocator OOM/empty·owned abort current 보존과
   copied/stale/cross-slot authority 거부를 닫는다.
   **CR2e-d 완료:** 실제 `RemoteGeneration`을 candidate node final address에서 완성하는 `PreparedReconnect` 제품 owner가
   stable screen writer gate 안에서 slot current와 screen target을 함께 게시하고, old/candidate/current payload를 값으로
   옮기지 않은 채 canonical node 주소에서 exact once 파괴한다. abort/current 보존, copied token과 allocator fail-index도 닫는다.
   **CR2e-e 진행:** e1은 기존 `RemoteRuntime.generation`의 내부 접근을 단일 current accessor로 모으고,
   `RemoteTermBackend`의 raw generation field 접근과 attachment→generation→runtime `@fieldParentPtr` 역산을 제거한다.
   e2a는 stable shell의 실제 `GenerationSlot`을 제품 runtime의 최초/current 저장소로 활성화하고 최초 inline payload와
   stable screen publication 및 teardown을 결속한다. e2b는 final-address `ReconnectProductExecutor`가 reducer state와
   inline `PreparedReconnect`를 함께 소유하고, reducer 결과를 actual prepare/abort/publish/reclaim effect가 성공한 뒤에만
   게시한다. 31개 `Decision`의 closed generation-effect table과 initial state에서 도달 가능한 모든 canonical state sequence가 같은
   decision inventory를 전수 소비한다. executor의 inline 증가는 runtime당 256바이트, 4,096-runtime 상한에서 1 MiB이며
   runtime size golden으로 고정한다. e3은 다음 세 하위 gate를 순서대로 닫는다. **e3a**는 실제 제품
   `RemoteGeneration` candidate/retiring의 empty-screen structural base lower bound를 allocator ledger로 고정하는
   **e3a1 완료** (candidate allocation 1개, CR6d typed event-payload allocator와 CR5b-2a retirement preparation owner 반영 뒤 Debug 3,504바이트/ReleaseFast 3,488바이트; abort baseline 복원,
   두 reconnect 뒤 heap current 1개, teardown final 0)와,
   별도 ReleaseFast process RSS를 측정하고, generation당 구조적 charge 상한
   `base_update_max_bytes = 16 MiB screen + 256 KiB metadata`와 reconnect mutation lease와 같은 64개 fixed
   inventory를 검증하는 **e3a2**로 나뉜다. 이 둘의 곱은 정책 예산이 아니라 inventory가 표현 가능한
   `max_tracked_bytes`이며 app-global admission 상한은 e3b의 실제 동시 runtime 모델에서 별도로 결정한다.
   candidate/current/retiring/retry 역할은 final-address fixed entry가 소유하고 구조적 bound+1은
   allocation·role mutation 0이어야 한다. ReleaseFast exec child는
   64 current→64 candidate+retiring 압력을 만들고 부모가 PID RSS/footprint를 반복 측정하며, typed artifact validator가
   logical delta+64 MiB 측정 tolerance와 actual cleanup receipt를 독립 재계산한다. 측정 전 임의 상한을
   제품 정책으로 채택하거나 reconnect ingress를 열지 않는다. **e3b**는 두 하위 gate로 닫는다. **e3b1**은
   process-global admission inventory 64개를 sealed 대기열 상한으로 유지하면서 active reconnect resident entry는 8개,
   GUI reconnect 전용 resident byte 상한은 128 MiB로 둔다. 이 byte 상한은 daemon `ConnectionSlot`의 128 MiB와 값을
   맞추지만 서로 다른 process·owner의 독립 정책이며 budget을 공유하지 않는다. 작은 generation도 동시에 최대 8개만
   실행하고, `base_update_max_bytes`를 모두 쓰는 generation은 byte cap 때문에 7개까지만 admit된다. 각 cap의 다음 budget
   reserve는 allocation·lease·role mutation 0으로 거부된다. Budget·entry·lease는 final address, OS PID, canonical process
   nonce, monotonic owner incarnation과 policy domain을 공유해 fork 및 same-address 재사용 권위를 거부한다. **e3b2**는 이 typed 거부를 actual sealed admission queue와
   결속해 요청을 잃지 않고 후속 drain에서 다시 시도한다. Candidate lease는 final-address stable executor가 mutation seal·authority commit retain 구간부터
   actual generation publish와 terminal reclaim까지 소유하며, product effect 성공 뒤에만 reducer state를 게시한다.
   **e3c1**은 reconnect 정책만 소유하는 final-address `SessionHostCoordinator` shell을 먼저 열고, 기존
   `AppProcessIncidentOwner` queue/budget과 `RemoteTermBackend` map을 옮기지 않은 채 one-turn sealed borrow로 sole drain을 소유한다.
   이 shell은 raw backend/pool pointer를 장기 저장하지 않고 backend singleton generation·seal과 process identity를 매 호출 재검증한다.
   **e3c2**는 CR4 socket parser가 채울 pointer-free direct-release evidence를 current backend/runtime projection과 exact 비교하고,
   consumer-side closed typed receipt를 coordinator final address, backend singleton generation,
   exact runtime row와 `retry_wait_release` projection에 결속해 copy/replay/stale event를 mutation 0으로 거부한다. 실제 host socket이
   이 receipt를 발급하는 wire evidence는 CR4 범위다. **e3c3**은 coordinator가 외부 before/after state를 신뢰하지 않고
   current backend/runtime row에서 termination request, reconnect quiesced, timeout, abandon event의 canonical projection을
   직접 계산한 뒤 keyed final-address receipt로 봉인한다. request deadline은 prepare/apply 양쪽에서, timeout은 coordinator
   monotonic clock과 sealed close deadline으로 재검증한다. 같은 stable executor가 preserve-old, paused notice, publish-new,
   retry freeze, terminal finish effect와 candidate/current lease 정산을 수행하며 invalid/copy/replay/stale-row/expired event는
   mutation 0이다. logical charge final-zero와 e3a2 별도 PID RSS artifact를 상속하되 실제 wire issuer는 CR4에 남긴다.
   e3 전체가 mutation seal·authority/retry/close effect의 실제 제품 결속, 외부 reconnect ingress,
   close 경쟁·mixed outcome과 app-global candidate/retiring count·byte 상한·peak RSS를 닫는다.
   a~e 다섯 gate가 모두 green이기 전에는 CR2e 완료가 아니다.
5. **CR3 — shared Client 세대:** CR3a는 두 merge slice로 닫았고 CR3b R1까지 완료했다. **CR3a-1(완료)**은 현
   Client/external-pump/final-address cleanup ownership inventory를 먼저 고정하고 cleanup lease의 제품 callback이 0인
   transport-neutral `ConnectionLease`와 generation 1 전용 `HostAdapter.ClientSlot` skeleton을 넣는다. `HostAdapter`는
   `initInPlace(out,node_allocator,source)`로만 생성하고 inline slot이 세대별 heap-pinned `ClientNode`를 단독 소유한다.
   process-global atomic `ClientIdentityIssuer`가 한 tagged checked counter에서 burn-on-reserve하는 nonzero
   `slot_incarnation`/`node_incarnation`이 address reuse ABA를 막는다. attachment당
   `ConnectionLease`는 exact node를 pin하는 immutable cleanup-only capability이고 마지막 pin release만 one-shot이다. 각
   drop/release/cancel은 canonical cleanup owner의 reservation을 얻어 `{kind,stream,opaque token digest}`에 결속된 별도
   final-address one-shot `CleanupPermit`으로 실행한다. permit 동안 parent pin release는 busy이며 cleanup result는
   `completed|retryable_preserved|indeterminate_or_partial`의 닫힌 전이다.
   두 타입 모두 raw `*Client`, 임의 callback, request/read/write admission을 노출하지 않는다. **CR3a-2**는 generation 1 compatibility
   wiring을 다섯 vertical merge gate로 닫고 각 gate 끝의 실제 제품 경로에는 canonical cleanup owner를 하나만 둔다.
   **CR3a-2a(구현):** GUI `RemoteRuntime` 안에 final-address `GenerationAttachment`, neutral binding leaf와
   `GenerationTransport` 최소 core(`capabilities|prepareRequest|executePreparedRequest|abortPreparedRequest|poison`)를 넣어 실제 attach/deinit의
   stream-drop reservation·lease release를 배선하고, 외부 CLI의 movable `RemoteAttachment` graph는 바꾸지 않는다.
   node-local cleanup registry의 canonical transport/response seal, opaque prepared RPC storage, response/binding/transport/request
   backing의 wire 전 non-alias preflight, wire 전 captured allocator와 Frame schema를 바꾸지 않는 parser out-parameter가 frame마다
   반환하는 실제 payload allocator를 제품
   타입으로 고정했다. response payload는 GUI parent 전체와 node canonical owner range에 겹치지 않아야 하며, forged alias나
   allocator drift는 connection을 poison하고 해당 bounded payload를 free하지 않는다. copy/ABA/reentry,
   poison-before-free, snapshot EOF rollback과 실제 daemon의 기본 attach/detach/reattach를 자동 검증한다. 이는 최소 core와 GUI
   attachment shell만의 완료이며 raw batch context 제거, 나머지 primitive, typed teardown, 전체 actual-socket parity는 각각
   2b~2e에 남는다.
   CR3a-2b는 `Client` 내부 accounting을 보존한 batch queue→node registry owner transaction을 실제 pump/release에 배선하고 GUI
   `AttachmentTransport.context=*Client`를 node-bound batch/drop adapter로 즉시 교체한다. 이 단계는 다음 두 TDD merge gate를
   순서대로 닫는다. **CR3a-2b1(구현)**은 node-local fixed-cap batch entry와 pointer-free token, `Client`의
   `pending -> transferred -> released` 회계를 도입하고, 이미 buffered된 batch와 방금 parser에서 완성된 requested-stream batch를
   같은 reserve-first all-or-none transaction으로 옮긴다. red test는 0/1/4,096/4,097 entry, 18 MiB exact/cap+1,
   0/1/4,096회 idle 뒤 reservation final-zero, allocator fail-index, direct-parser actual allocator drift·payload alias·partial rollback,
   foreign-stream demux, accounting receipt/counter drift의 free 0, release callback 재진입 중 charge 보존을
   production `ClientNode` 타입으로 고정했다. registry별 incarnation과 checked-monotonic entry generation이 copy·ABA·cross-node·
   stream splice를 거부하고, exact transfer ledger가 duplicate/replay receipt를 차단한다. parser가 실제 사용한 allocator를
   node/slot/source canonical range와 대조하며 batch scope 전후 descriptor 복원과 일반 RPC 재사용을 검증한다. parser의
   guarded allocator alloc/free callback에서는 same/foreign `ClientSlot` read/release/deinit 재진입을 busy로 닫는다.
   모든 batch release callback은 nested release/deinit을 막고, buffered payload callback의 read는 allocation 없는 exact pending
   sibling만 허용하며 miss는 registry reserve·socket/parser 전에 busy로 거부한다. callback 종료 뒤 원래 token·미소비 wire와
   teardown이 정상 진행됨을 production-type unit으로 고정했다. **CR3a-2b2(구현)**는 `GenerationAttachment`가 inline 소유하는
   final-address node-bound batch adapter를 실제 `RemoteAttachment.pumpScreen`/release에 연결한다.
   `AttachmentBatchLease.generation`은 pointer-free node registry token만 보관하고 external recovery ledger의 `.charged`와 섞지
   않는다. adapter callback context는 exact inline adapter이며 raw `*Client`/`*HostAdapter`를 노출하지 않는다.
   `commitAccepted`의 legacy transport 인자를 제거하고 generation payload는 이 adapter를 직접 bind한다. 신규 read admission을
   닫은 뒤에도 pending generation token 전량을 release할 때까지 release-only draining authority를 유지하고, 전량 settle 뒤 기존
   2a canonical `beginAttachmentDrop -> deinitPayloadOnly -> finishActiveAttachmentDrop`이 stream drop과 lease release를 exact once
   수행한다. 별도 transport drop callback은 만들지 않고 기존 canonical drop의 무회귀를 증명한다. 정상 generation release는
   completed-only strict 경로이며 stale/spliced/replay token은 generic `failed_release` 보존이나 sibling 진행 전에 제품 invariant
   fail-stop한다. retryable/indeterminate handoff는 CR3a-2d 전에는 열지 않는다. source boundary는 legacy GUI fallback의 raw
   `attachmentTransport(*Client)`와 initial snapshot/event/input/RPC allowlist를 유지하되 generation commit/pump에서는 raw
   context/cast를 0으로, raw `readGenerationBatch`/`dropBufferedStream`은 `ClientSlot` sole canonical caller로 고정한다. external
   movable `RemoteAttachment`의 outer field 목록, 기존 `untracked|charged` reachable 의미와 `ExternalPumpStorage`/external
   `Prepared|Attached`의 outer owner schema·동작은 바꾸지 않는다. 내부 `AttachmentBatchLease`에는 generation 전용 variant가 추가되므로
   그 union의 state space/layout 불변은 주장하지 않는다. 2b2 끝에 production type GUI attach→post-initial snapshot/delta
   pump→release→deinit, buffered/direct, idle/error/OOM, multi-token FIFO/compaction과 exact-once cleanup을 실행하고
   Debug/ReleaseFast/boundary/전체 check를 재실행한다. initial snapshot의 raw `Client.readSnapshot` 제거와 전체 actual-socket
   failure parity는 각각 2c/2e 범위다. 두 gate 모두 reconnect/current publish, incident/artifact, workspace 및
   host/runtime lifecycle mutation은 0이다. CR3a-2c는 나머지 stream/event primitive를 최소 core에 추가해
   `RemoteRuntime.client` direct escape를 HostAdapter가 발급하는 작은 closed transport facade로 완전히 교체한다. exact
   15-method 집합은 2b2가 별도 소유하는 `readAttachmentBatch`를 중복하지 않고 `purgeEndedStream`을 포함한다. purge는 임의
   stream ID가 아니라 exact binding/runtime/controller generation에 결속된 one-shot ended receipt만 소비하며 조기 demux
   purge와 최종 canonical drop 권한을 분리한다. initial snapshot은 bare slice가 아니라 allocator provenance와
   transport/binding/stream identity를 봉인한 final-address owner로 반환해 apply 성공·OOM·malformed 모두 exact once free한다.
   `RemoteRuntime`은 `legacy|generation` connection union을 유일한 mode SSOT로 쓰며 기존 raw Client entrypoint는 legacy arm에만
   격리하고 generation 실패를 legacy로 fallback하지 않는다. 2c는 review 가능한 네 TDD merge gate로 닫는다.
   **2c1(구현)**은 `InitialSnapshotOwner`와 generation `readInitialSnapshot`을 제품 attach stack에 배선하고 raw snapshot read를 legacy
   arm에만 남긴다. owner/transport stale 복원은 heap-pinned `ClientNode`의 checked-monotonic canonical stream-operation permit으로
   차단하고, allocator free callback 동안 permit을 유지해 attachment/slot teardown 재진입을 `busy`로 고정한다. 이 permit의 exact
   binding seal과 닫힌 외부 error normalization을 2c2~2c4가 공통 admission 기반으로 재사용한다. **2c2**는 sealed ended receipt와
   all-or-none early demux purge를 배선한다. generation arm은 일반 event loop보다 먼저 무인자
   `purgeEndedStream() -> PurgeEndedError!PurgeEndedOutcome`을 호출한다. outcome은 `.not_ended|purged`, error는
   `.busy|invalid_owner|corrupt|terminal`의 닫힌 집합이다. registry/다른 stream operation 충돌은 모든 mutation 0의 `.busy`, moved/copy/thread/binding
   불일치는 모든 mutation 0의 `.invalid_owner`, precommit descriptor/counter/seal 손상은 demux queue/counter·attachment·lease/registry
   mutation 0과 connection terminal poison exact 1의 `.corrupt`로 normalize한다. 이미 committed인 process quarantine latch는 현재
   connection을 추가로 poison하거나 mutate하지 않고 `.terminal`이다.
   transport는 현재 binding의
   `{slot/node/transport, host, connection generation, immutable binding incarnation/runtime, non-reused stream}`과 admission seal이 살아
   있는 target-stream 첫 `runtime.ended` event만 private stack-final-address receipt에 결속해 같은 호출에서 소비한다. ended는 role과
   무관한 lifecycle event이고 mutable current role/controller generation은 binding SSOT에 없으므로 receipt가 추측하거나 봉인하지
   않는다. 작은 allocation-free peek가 ended가 없으면 event take/release와 대형 scratch frame 없이 즉시 `.not_ended`를 반환하고,
   ended가 확인된 때만 별도 noinline transaction helper에 들어가므로 2c3의 일반 event facade를 선취하지 않는다.

   prepare는 Client-owned 미전달 `pending_batches`, optional `partial_batch`, 이미 분류된 `pending_stream`, `pending_events`의 전체
   descriptor·allocator provenance·event seal·byte counter를 fixed inline scratch에 복사해 검증하며 mutation/free/allocation 0이다.
   scratch는 per-item digest 대신 compact target bitset과 queue별 aggregate payload seal을 쓰며, descriptor 배열 cap은 제품 queue cap과
   같고 기존 `ExternalAdoptionCleanupScratch`와 같은 compile-time `<= 512 KiB` 예산을 지킨다. target stream에
   `GenerationBatchRegistry`의 reserved/ingress/live/releasing entry가 하나라도 있으면 mutation 전에 `busy`로 닫는다. transferred
   batch/token/accounting, parser raw RX/framing, attachment pending lease/screen, cleanup registry와 connection lease는 정상 purge와 모든
   precommit failure의 payload cleanup 대상이 아니다. postcommit Client-owned deinit graph drift의 terminal suffix만 owned allocation을
   개별 정리하거나 권위를 넘기지 않고 no-free 상태로 버리며 borrowed ledger/attachment/registry/lease는 그대로 둔다. commit은 receipt
   `EndedPurgePreparation.sealForCommit` 뒤 immutable target descriptor scalar에 대한 cleanup authority를 취득하고 별도 private cursor를 callback 전에 advance한다. descriptor bytes를 overlay하거나 별도
   full-size 배열을 만들지 않고, 네 queue stable compaction과 최종 counter publish를 첫 allocator callback 전에 끝낸다. 이후 fallible
   work는 0이고 callback 중 canonical queue/source reread도 0이다. 마지막 callback 뒤에는 frozen survivor descriptor/range seal과 current
   queue ownership metadata를 비교하는 post-validation을 정확히 한 번 수행하고, 구조가 일치할 때만 sibling aggregate payload seal을 다시 읽는다.
   node permit은 이 post-validation까지 유지한 뒤 node permit→transport receipt 순으로 소비한다. permit이 live인 동안 sibling을
   포함한 Client input/event/RPC/queue mutation과 attachment/slot teardown은 모두 `busy`이며 read-only scalar 관측만 허용한다. public
   Maru API callback 재진입은 같은 규칙으로 sibling을 byte-for-byte 보존한다. blocking generation Client의 `build_id`/`Client.lifecycle`,
   parser backing, optional pending outbound, 네 queue
   backing과 nested owned extent를 포함한 complete Client-owned deinit graph checked sum이
   `max_ended_purge_quarantine_bytes = 64 MiB` 이하임을 검증한다. list/parser/partial은 capacity backing을, slice payload와
   `build_id`/`Client.lifecycle`/pending outbound는 exact owned length를 합산한다. external mode는 mutation 0으로 거부한다. cap 초과의 precommit
   no-cleanup poison은 owner free/tombstone/quarantine 0으로 reason/unusable을 latch하고 validated captured fd만 detach+close해 later ordinary
   deinit이 intact owner를 회수하게 한다. 모든 graph/cap/profile 검증 뒤 commit gate의 마지막 fallible step으로 one-slot reservation을
   잡고, 성공 뒤에는 `EndedPurgePreparation.sealForCommit`과 no-fail suffix만 남긴다. 정상 post-validation은 reservation을 release하되
   node permit→transport receipt paired consume이 끝날 때까지 Client exclusive를 유지하고, 그 뒤에만 exclusive를 clean release한다. 구조 drift에서는
   current pointer·allocator·fd를 역참조하지 않고 canonical Client-owned deinit fields를 empty/null로 tombstone하고 reservation을 exact
   once 영구 commit한 뒤 `quarantined_no_free` absorbing poison을 게시한다. 어떤 postcallback drift에서도 fd는 close하지 않는다. allocator,
   generation accounting ledger, observer, attachment, registry와 lease 같은 borrowed authority는 dereference/release/mutate 0이다. exact 순서는
   `all target cleanup -> Client-owned deinit tombstone -> Registry.commit(+CommitReceipt) ->
   Registry.consumeCommitted(+ConsumedCommitProof) -> no-free poison + PreparedEndedPurgeCommit consumed -> terminal fence -> node permit ->
   EndedPurgePreparation transport receipt`이다. 이 sticky process latch 뒤 새 generation Client/reconnect/ended-purge admission은 terminal로
   거부되어 누적 quarantine은 한 건·64 MiB를 넘지 않는다. replay charge는 0이다. 이후 generic teardown은 변조된 pointer를 다시 읽거나
   free하지 않으며 해당 connection의 남은 Client-owned allocation은 버린다. commit 전 오류는 `.not_ended`와 구별된 typed error이며
   위 error별 허용 mutation만 수행한다. commit 뒤 정상과 drift-poison 모두 target cleanup을
   끝내고 no-fail node permit/transport receipt consume을 실행하며, clean은 그 뒤 Client exclusive clean release를 마지막으로 실행한다.
   public 결과는 `.purged`다. tests는 poison latch를 별도로
   검증한다. early purge는 canonical attachment drop·registry token release·node cleanup
   registry·connection lease를 소비하지 않으며 later teardown의 raw demux 정리는 idempotent no-op이다. **2c2a(구현)**는 2c1의 snapshot
   전용 permit/active tuple/process registry를 kind-tagged `StreamOperationPermit` SSOT로 migration하고 snapshot↔ended-purge 상호 busy와
   copy/splice/replay 거부를 production-type test로 고정했다. `GenerationBatchRegistry.streamIdle(stream_id)`도
   reserved/ingress/live/releasing 전 상태를 target purge blocker로 분류한다. **2c2b1(구현)**은 `pending_events`에서 대상 stream의 첫
   event만 bounded scan하고, admission identity가 보존된 `runtime.ended` 후보의 비권위적 index hint만 allocation·payload hash·queue/counter
   mutation 0으로 반환한다. payload byte와 전체 queue ownership metadata의 권위 검증은 permit 아래 slow transaction이 다시 수행하며,
   hint 자체로 receipt나 purge 권위를 만들지 않는다. **2c2b2(구현)**는 exact binding과 common stream-operation permit 아래 fixed inline
   scratch를 사용해 모든 Client-owned demux queue와 기존 Client owner graph의 descriptor·allocator provenance·counter·event admission
   seal·payload·exact/partial alias를 allocation/free와 Client queue/owner 및 process-global quarantine mutation 0으로 검증한다. target
   bitset·queue별 aggregate seal·checked quarantine capacity는 final-address private preparation에 봉인한다. process-global quarantine은
   이 prepare 단계에서 예약하지 않으며 실제 reservation은 첫
   allocator callback 전에 수행하는 commit gate가 소유한다. 아직 target detach/stable compaction, callback cleanup, post-validation,
   quarantine reservation/commit과 poison suffix, transport/GUI 제품 배선은 구현하지 않았으므로 2c2 완료를 주장하지 않는다.
   **2c2b3a(구현)**는 neutral `ended_purge_transaction.zig`가 target bitset의 stable source/target/survivor ordinal과 b2-provided
   count/byte scalar의 checked survivor 산술만 계산하는 non-owning pure plan이다. pointer-free/copyable `QueueInput`은 source/claimed-target
   count와 source/target bytes만, `QueuePlan={state:u8,scalars:QueueScalars}`는 성공한 source/target/survivor count와 bytes만 가진다.
   raw state 0/1 이외 값은 ReleaseFast에서도 scalar 해석 전에 `InvalidState`로 닫는다.
   empty success도 planned이며 오류에서는 입력 out을 byte-for-byte 보존한다(pristine 실패는 pristine, occupied 실패는 기존 값 유지).
   검증 우선순위는 destination→count→target map→checked arithmetic이고 `max_items<=4,096`, 비용은
   `O(source_count + ceil(max_items / word bits))`다. ephemeral `DispositionCursor`만 bitset을 borrow해 stable
   `{source ordinal,target-or-survivor ordinal}`을 반환하고 위조 ordinal/count는 typed error로 fail-close하며 완주 상태는
   `validateComplete()`가 target map/count/ordinal을 typed 재검증한다. caller의 targets/out non-alias는 b3b actual preflight가 재검증한다. plan/step의
   address·allocator·payload pointer·scratch reference와 seal
   mint/검증은 0이다. `buildQueuePlan` error set은 `InvalidCount|InvalidTargetMap|ArithmeticOverflow|DestinationOccupied|InvalidState`다. Client/allocator callback/quarantine import, scratch·queue·process mutation,
   owner freeze, allocation/free와 permit/receipt consume은 0이다. **2c2b3b(B3b-F·B3b-S·B3b-O 구현 완료)**가 private scratch의 immutable/no-escape 원본 descriptor를
   cleanup authority로 사용해 exact preparation revalidation부터 reservation, `EndedPurgePreparation.sealForCommit`, stable compaction/counter publication,
   모든 target exact-once callback, post-validation, 정상 release 또는 absorbing no-free quarantine을 하나의 vertical transaction으로
   닫는다. revalidation/cap/reservation까지는 typed precommit failure, `EndedPurgePreparation.sealForCommit` 뒤 suffix만 no-fail이다. private scratch의 coherent arbitrary overwrite와 cleanup authority 밖에서 이미 수행된 deallocation의
   탐지·복구는 비목표지만 callback 재진입·canonical descriptor drift·allocator provenance/alias 검증은 유지한다. b3a만으로 target
   final-zero나 2c2 완료를 주장하지 않는다. b3b의 doc-first boundary는 AST canonical
   `(parent,kind,visibility,modifier,name)` production inventory를 사용해 root와 owner container를 함께 검사한다.
   허용 tuple 제외 baseline은 client(root+Client+EndedPurgeScratch+PreparedEndedPurgeInventory)=527/SHA-256
   `594178e6c653e30be0ddc64564d2783922e0c0b4895c3543479f86e5977db6fd`,
   client_slot(root+ClientSlot+EndedPurgePreparation)=126/SHA-256
   `03a92a146dbf8935466d0b9250b09c884d575f15fc148f73c6db8979bc69d968`이다. B3b-F/S 전체 신규 top-level allowlist는 client의
   `ClientOperationFence|generationAllocatorCallbackActive|ended_purge_transaction|ended_purge_quarantine|PreparedEndedPurgeCommit|
   EndedPurgeCommitError|EndedPurgeClientCommitOutcome`, client_slot의
   `ended_purge_quarantine|ended_purge_quarantine_registry|process_runtime_pid`뿐이다. B3b-F/S/O의 신규 nested method/type exact
   allowlist는 `persistent-session-host.md`를 SSOT로 사용하고 executable boundary inventory가 이를 고정하므로 여기서 중복 열거하지 않는다. 별도
   `ended_purge_quarantine.zig`는 std와 scalar identity/bytes만 아는 allocation-free one-slot
   `max_ended_purge_quarantine_bytes|Error|Reservation|CommitReceipt|ConsumedCommitProof|Registry` API를
   소유한다. nested exact allowlist는 `Reservation.Lifecycle`, `CommitReceipt.Lifecycle`, `ConsumedCommitProof.matches`,
   `Registry.State|init|reserve|release|commit|consumeCommitted`뿐이다. proof는 인증 capability가 아니라 pointer-free correlation evidence이며
   semantic-exact 합성의 런타임 방지는 주장하지 않으며 B3b-O exact production caller/source closure가 정상 제품 proof의 provenance와
   consume→finalizer 순서를 소유한다. `pending_outbound`는 nullable 거부가 아니라 `build_id`·`Client.lifecycle`과 함께 각각 독립된
   scratch frozen descriptor, complete-owner cap/alias/seal,
   postvalidation과 tombstone 전 구간에 포함한다. preparation 재검증 뒤 registry reservation이 마지막 fallible step이고,
   `EndedPurgePreparation.sealForCommit` 뒤 Client no-fail commit을 실행한다. drift는 `finalization_pending` preparation과 Client-owned graph tombstone까지만 게시하고,
   ClientSlot이 quarantine commit으로 발급한 exact-once `CommitReceipt`를 trusted Registry로 consume해 pointer-free
   `ConsumedCommitProof`를 만들고, Client finalizer가 proof를 검증한 뒤 poison/terminal을 게시하고,
   prevalidated node permit→`EndedPurgePreparation` transport receipt paired consume을 끝낸다. clean은 paired consume 뒤에만 Client
   exclusive를 clean release하고, drift는 이미 terminal fence가 absorbing 상태를 소유한다. client는 raw owner mutation/direct cleanup과
   scalar proof sealed finalization만, client_slot은 registry receipt consume과 node permit→preparation transport receipt paired consume 순서만 소유한다.
   B3b-O의 red gate는 `EndedPurgePreparation`의 `prepared→committing→consumed` final-address 전이,
   Client prepare/commit/finalize의 test 밖 production callsite exact one, clean의 reservation release→node permit→transport receipt→exclusive release,
   drift의 Registry commit→consume→finalizer→node permit→transport receipt 순서를 먼저 실패로 고정한다. 구현 green 뒤에도 reconnect/current publish는 0이며,
   Debug·ReleaseFast subprocess의 validated suffix mismatch fail-stop, 격리된 drift subprocess의 quarantine commit→proof→finalizer→paired
   consume과 boundary source-order oracle까지 통과해야 B3b-O를 구현으로 승격한다.
   node permit consume은 기존 global mutex unregister를 callback 뒤 재호출하지 않는다. 기존 registry entry에 atomic
   `empty|live|consume_reserved|consumed` state를 추가하고 live `{id,permit}` payload를 immutable하게 유지하며, callback 전 private final-address
   `PreparedStreamOperationPermitConsume`을 준비한다. irreversible suffix는 canonical operation thread를 graph 접근 전에 검증하고
   `consume_reserved→consumed` CAS, node active tuple clear,
   preparation consume, `consumed→empty` reclaim만 수행하고 mutex·scan·allocation·fallible lookup은 0이다. 중간 `consumed`가 transport
   receipt 게시 전 같은 index 재사용을 막는다. multi-thread winner 경쟁은 범위가 아니며 same-thread copy/replay exact-once만
   계약한다. 등록과 empty entry 재사용은 기존 mutex와
   checked-monotonic id를 유지하며 CAS 뒤 payload는 다음 등록 전까지 지우지 않는다.
   **2c3**은 capability/input/control/event/RPC primitive를 exact facade로 옮긴다. **2c3a 구현 완료**:
   exact input/revoke/output-progress facade, raw lifecycle admission, canonical controller authority와
   bound-drop transaction을 Debug·ReleaseFast `test-session-host` 및 boundary gate로 닫았다. 내부 순서는 2c3a
   input/revoke/output-progress+raw lifecycle admission, 2c3b capability+closed RPC, 2c3c control, 2c3d one-shot event,
   2c3e generation 제품 RPC/decoder direct-call source-zero+immediate EOF/unread RX-first socket parity다. event/effect repo-wide
   source-zero와 admitted-event socket parity는 2c3d C3-3c가 소유한다. 2c3a~e가 모두 green일 때만 generation arm의 direct
   `logicalClient()`/`Client` method 사용 0을 주장한다. **2c3b-1 capability facade 구현 완료**: const receiver의 raw-first admission과
   registry-resolved canonical node operation pin 아래 exact `GenerationCapabilities` value projection을 구현했다. untrusted slot 주소는
   registry 비교 전 역참조하지 않고 owner-seal/capability enum의 invalid raw byte를 fail-close하며, facade production callsite 0과
   shared `RemoteRuntime` architecture raw-read exact baseline을 boundary gate로 고정했다.
   **2c3b-2 request-side canonical authority와 2c3b-3의 B3-0a~B3-6 internal aggregate strict completion은
   구현·검증 완료**했으며, public decoder와 legacy/generation observable parity는 2c3e 후속이다. 다음 gate는 2c3c control facade다.
   2c3b-2는 `RuntimeRequestTag -> RequestFamily -> role/phase -> method` 전수표와 닫힌 prepare/abort error,
   같은 binding entry의 node-sealed `PreparedRequestAuthority`가 opaque `PreparedBlockingRpcStorage`의 frame descriptor·allocator
   provenance·incarnation·tag/id/digest를 한 transaction으로 pair-seal하는 경로까지 구현했다. 기존 attach-compatible execute도 이
   authority를 begin/revalidate/settle하도록 hardened했다. request allocation fail-index, scope token·owner/client-backing exact/partial
   alias, cross-splice·same-address ABA, issuer exact-max와 actual socket accepted/uncertain 경계를 Debug/ReleaseFast에서 고정했다.
   legacy/generation 제품 decoder parity는 계획대로 2c3e가 소유한다. `GenerationTransport`의 direct prepared-Client API 호출은 0이 되며 모든
   prepare/abort는 registry scalar lookup 뒤 canonical node operation pin 아래 실행한다. 이 gate는 public RPC destination, 반복 RPC
   response authority·borrow/finish 또는 새 관측 가능 wire/product behavior를 열지 않고 기존 attach 실행 parity를 유지한다. `spawn_full`은
   connection/bootstrap 전용 tag로 union에는 유지하지만 attachment-bound facade의 classifier가 prepare 전에 항상
   `Unauthorized`/wire 0으로 거부한다. union 제거 여부는 2c4 surface cleanup에서 판단하며 그 전까지 허용 의미는 바뀌지 않는다.
   request/execute의 temporary allocator 교체는 final-address scope token을 caller stack에 in-place mint하고 그 exact range를 guarded
   allocator에 포함한다. public token은 pointer-free allocator scalar만 가지며 Client-private identity만 typed allocator를 보유한다.
   prepared request가 executing으로 전이된 뒤의 allocator-scope·response-incarnation issuer 소진은 canonical request backing을
   먼저 exact settle한 뒤 authority terminal+connection poison으로 닫는다. 아직 authority를 publish하지 않은 transport/registry
   issuer의 preflight 소진은 mutation 없는 `IdentityExhausted`다. declared attachment owner range는 transport와 opaque
   prepared storage를 완전히 포함하면서 canonical slot/node/Client/owner-seal range와 겹치지 않아야 한다.

   **2c3b-3은 response-side execution/ownership**을 구현한다. client-slot-internal
   `ResponseDestination = attach:*ExecutedResponse|rpc:void` 전환, 별도 node-sealed
   checked-monotonic RPC epoch authority, Client의 zero-write/ambiguous-write closed progress evidence, canonical `GenerationTransport`
   inline single-slot `RpcExecutedResponse` publish·private lexical borrow·owner-only finish와 strict fail-stop을 한 gate로 닫는다. production
   `RemoteRuntime` decoder 전환과 legacy/generation observable parity는 2c3e가 소유하며, 2c3b-3은 private borrow bridge와 production
   callsite 0 baseline까지만 고정한다. attach는 기존 registry의 one-shot `ExecutedResponse`를 유지하고 반복 RPC는 독립 authority로
   분리한다. 독립 movable payload, 호출 수에 비례하는 one-shot destination collection/fixed response pool과 임의·public reset은 두지 않는다.
   오직 성공한 `.reusable` finish의 같은 registered operation no-fail suffix만 clean terminal을 bytewise pristine single slot으로 rearm한다. red gate는
   2회·64회 순차 RPC, attach/RPC destination tag mismatch wire 0, copy/move/same-address ABA, cross transport/binding/request/
   digest/epoch splice, pre-wire typed reject 뒤 재사용, uncertain·accepted 미소비 뒤 terminal, allocator drift·alias·free callback 재진입,
   node-sealed authority/whole-transport restore, exact safe-free와 ambiguous no-free product fail-stop, epoch 소진,
   teardown busy/fail-close를 production type·subprocess·Darwin socketpair로 고정한다.
   이 aggregate gate는 내부 TDD slice `B3-0a`~`B3-6`을 순서대로 병합했고, 마지막 slice 전까지 상태를
   `2c3b-3 구현 중`으로 유지한 뒤 B3-6 merge로 완료했다. 내부 slice는 공개 RPC surface를 부분 완료로 노출하지 않았으며 generation 제품
   callsite와 정상 observable wire/product behavior는 0이다.

   1. **B3-0a attach ambiguous-free remediation:** 현재 attach accepted tail의 exact-owned safe-free와 owner/allocator/range가
      불명확한 no-free를 먼저 분리한다. alias·overflow·allocator drift는 forged payload를 read/hash/free하지 않고 terminal evidence를
      `client_slot.executeGenerationRequest` production strict wrapper가 즉시 fail-stop으로 소비한다. operation-scoped 단일 in-place
      payload allocation slot의 Frame generation 기반 exact target promotion(ptr/len scan 0), OOB 1/64/누적 cap 초과와 immediate retired-slot
      reuse, observer 밖 parser/pending backing resize/remap parity, ledger heap backing allocate/grow/free 0과 callback 전후 in-place semantic seal,
      sealed forbidden inventory 기반 payload disjoint 검증, zero-length와
      generation wrap을 함께 닫는다.
   2. **B3-0 attach execution transaction seam (완료):** request backing과 `PreparedRequestAuthority`만 함께 정산하는 private final-address
      `PreparedExecutionTxn`의 상태·결정표를 characterization gate로 고정한 뒤 현재 attach-only 실행을 이 owner로 옮긴다. attach
      response owner·payload와 미래 RPC authority는 transaction에 넣지 않는다. 공개 signature, registry layout, frame schema와 정상
      response bytes는 바꾸지 않는다. 내부 순서는 **B3-0.1(완료)** 현재 attach 종료 행의 반환값·storage settlement·exact
      authority lifecycle·최초 poison·canonical guarded-wrapper 진입과 parent physical free golden,
      **B3-0.2(완료)** final-address transaction pure lifecycle/copy·move·duplicate·scope hostile tests. bounded live operation receipt,
      raw-safe phase/settlement, callback 전 canonical snapshot과 descriptor-splice 무역참조, fork child의 inherited mutex 선차단,
      fixed free-stack O(1)과 live receipt를 보유한 동안의 sibling teardown 강제 중첩을 Debug/ReleaseFast 및 boundary oracle로 닫았다.
      **B3-0.3(완료)**은 `executeGenerationRequest`가 valid backing을 확인한 직후 stack final-address transaction을 만들고,
      registry begin·pre-wire rollback·issuer exhaustion·post-execute reusable/terminal 정산을 모두 transaction method로만 수행하게
      이관한다. 공개 response destination은 pointer materialization 전에 두 단계로 검증한다. registry admission 전 caller scalar owner의
      overflow/full-containment를 비역참조 prefilter로 거르고, admission 뒤에는 그 owner가 registry의 canonical owner와 exact-match하는지와
      canonical owner 안 full-containment를 다시 증명한 뒤에만 pointer를 만든다. guard 이후 final-address cleanup coordinator가
      ledger→allocator→guard를 exact once로 닫고, transaction/cleanup 자체 stack authority도 allocator payload alias 금지 inventory에
      포함한다. 별도 보호된 caller-local expected stage가 cleanup transcript drift와 무관하게 실제 획득한 resource suffix를 결정하며,
      caller-local completion byte만 defer의 idempotent no-op를 허가한다. `.settled`/`.finishing` lifecycle 값만으로 완료나 reentry를
      주장할 수 없고, address-bound thread-local active finisher가 일치하는 실제 same-thread reentry만 outer finisher가 남은 suffix를
      닫을 때까지 failure로 latch한다. 각 callback 뒤 final-address transcript를 재검증한다.
      모든 transaction settlement는 cleanup의 typed 결과 뒤에만 authority를 게시하며, cleanup 실패는 reusable publication 없이
      request authority를 terminal fail-stop으로 정산한 뒤 process를 중단한다. 네 settlement method의 공통 precondition은 exact live
      operation/final-address owner를 먼저 mutation 0으로 인증하고 그 뒤 operation guard가 닫혔음을 검사한다. copy/move/foreign
      operation은 canonical guard를 읽거나 바꾸지 않는 typed `ProtocolError`이고, exact owner의 열린 guard만 cleanup 누락 terminal
      fail-stop이다. guard 이후 ordinary exit는 단일 `settleExecutionAfterCleanup` seam만 사용하며 그 함수가
      cleanup→closed intent settlement→transaction finish 순서를 소유한다. 따라서 새 exit가 coordinator 호출을 빠뜨려도
      reusable/terminal publication으로 진행하지 못하고, exit별 복제 순서가 서로 drift하지 않는다. 기존 `ExecuteDisposition`,
      `rollbackExecutingRequest`, `terminalizeExecutingRequest`,
      `terminalizeExecutingRequestWithStorageCleanup`의 product identifier/callsite/declaration은 0이어야 하며 정상 wire/result/최초 poison은
      바뀌지 않는다. issuer exhaustion의 backing abort가 reusable이면 기존 `IdentityExhausted`, 이미 terminal이면 정산 후
      `ProtocolError`라는 기존 error mapping도 transaction method가 보존한다. **B3-0.4/B3-0(완료)**는 test-private
      `B3ExecutionHarness`와 closed 13-row `B3Scenario`/`B3Expected` 표를 단일 출처로 두는 actual socket·fail-index·strict cleanup
      aggregate gate다. Darwin socketpair에서 accepted payload, request 전체 수신 뒤 EOF, partial response 뒤 EOF를 public
      `prepareRequest→executePreparedRequest`로 실행하고 0-byte EOF는 `connection_eof`, partial frame EOF는 `frame_malformed`로
      구분한다. request bytes, result/error, storage settlement, authority idle/terminal,
      first poison, response transcript/bytes와 request/payload alloc/free를 비교한다. request prepare와 execute/response allocation은
      서로 다른 ordinal sweep으로 0부터 최초 성공까지 전수한다. request-prepare OOM은 wire 0/reusable, execute-side OOM은 request
      전체 전송 뒤 terminal uncertain이라는 phase 경계를 고정하며 success sentinel과 guard/allocator scope/ledger/registered operation
      final-zero를 요구한다. txn/cleanup/expected-stage/completion alias와 cleanup transcript·allocator restore·guard-end drift는
      compile-filtered `/usr/bin/env -i` subprocess에서 terminal authority publication-before-SIGABRT와 ambiguous free 0을 증명한다.
      focused B3-0.4 artifact는 exact expected test count와 process-local category sentinel로 zero-test/skip green을 막고 같은 gate를
      Debug·ReleaseFast에서 실행한다. public declaration/callsite/frame/registry layout delta는 0이다.
      현재 `B3ExecutionHarness`는 final-address allocator chain·ClientSlot/binding/transport·actual peer join·response/authority teardown을
      소유하며 actual EOF/partial-frame와 execute alloc/resize sweep이 이 harness를 함께 쓴다. request-prepare ordinal은 같은 focused
      artifact에 포함되고 alloc/resize는 실패가 실제 주입되지 않은 첫 성공 전까지 독립 전수한다. closed 표는 exact error 계열·최초
      poison·response lifecycle·request/payload free·final-zero 필드를 포함하며 admission/local-preflight/pending-flush terminal/uncertain/
      accepted/accepted-alias를 포함한 13행 모두가 제품 실행 또는 strict child와 연결됐다. focused root는 무관한 barrel test 없이
      B3 8개, strict root는 2개를 각 optimize mode에서 exact-count하며 issuer clean/content-drift 4행의 전용 product fixture 1개도
      양 모드 dependency다. strict root는 response owner alias와 cleanup descriptor/stage·ledger end·allocator restore·guard end의
      여섯 격리 실행을 각각 통과해야 focused runner가 시작된다.
      content drift는 exact descriptor free 뒤 `ProtocolError`·terminal authority·local invariant poison이라는 현재 제품 결과를 표에 고정한다.
      fail-index는 호출 ordinal마다 전진해 target 한 번만 실패하며, harness teardown은 ReleaseFast에서도 allocator outstanding byte 0과
      operation-registry의 bounded begin/end receipt transcript가 모든 순차 operation을 exact once로 반환하고 allocator outstanding byte가
      0인지 ReleaseFast에서도 fail-stop으로 강제한다. txn/cleanup/expected-stage/completion exact·left/right partial·overflow alias 행렬도
      focused 제품 모듈에서 실행한다. 10개 일반 행은 실제 call result/error·authority query·response payload free receipt·cleanup 이후
      final-zero로 만든 `B3Observed` 전체를 표와 비교한다. issuer 4-case 제품 fixture와 두 aggregate 행은 중립
      `b3_issuer_oracle`을 공유하며 socket wire byte 0, payload 미관측, cleanup·operation receipt·allocator final-zero를 비교한다.
      response-alias child는 실제 exact request peer와 제품 상태에서 낸 transcript를 표로부터 생성한 문자열과 비교한다. 여섯 strict
      child는 canonical request free exact 1, noncanonical backing free 0, response payload free 0을 독립 marker로 고정하고 cleanup
      5개는 terminal publication marker가 panic보다 앞서는지 검증한다. 이 증거로 B3-0.4와 B3-0을 완료했다.
   3. **B3-1 inert RPC authority (완료):** production execute callsite 0인 node-local `RpcResponseAuthority` leaf와 같은 cleanup-registry
      binding entry의 `rpc_response_authority` field를 넣는다. reserve가 final address에서 exact binding identity로 authority를
      초기화하고 clear 뒤에는 다시 pristine zero가 된다. leaf는 raw-first
      `idle|executing|published|borrowed|releasing|terminal`, checked-monotonic nonzero epoch, exact
      `{authority address,registry incarnation,binding,transport incarnation,request family/tag,id,digest,destination}` receipt를 소유한다. 이 PR에서는
      test/leaf 전이만 존재하고 Client·socket·allocator·payload·decoder·reconnect 제품 callsite는 0이다. production-type unit은
      copy/move, 같은 주소의 entry 재예약 ABA, cross-binding/transport/request/destination splice, epoch 0/max 소진, 모든 invalid raw
      lifecycle을 역참조·I/O 없이 거부하고, registry abort/drop/deinit이 idle/terminal-settled만 허용하며
      executing/published/borrowed/releasing은 busy, incoherent 상태는 corrupt로 분류함을 고정한다.
      authority가 payload를 소유하지 않으므로 coherent terminal이 곧 terminal-settled이며 별도 settlement bit는 두지 않는다.
      authority-owned issuer의 module-public 전이는 `reserveExecuting→rollbackExecuting|settleExecutingTerminal`로 제한한다.
      publish/borrow/release/finish는 leaf test-private이며 B3-4/5 payload-aware capability 전에는 제품에서 호출할 수 없다. 모든
      전이는 registry current binding+exact receipt/final-address를 요구한다. registry만 reserve suffix의 init, settled 확인, zero
      clear를 소유하고 authority pointer accessor/forwarding execute API는 이 단계에 없다.
      same-address 과거 authority 전체 복원은 leaf seal만 신뢰하지 않고 registry의 현재 exact binding identity와 재비교해 clear를
      거부한다. registry incarnation+reservation ID가 재사용되지 않는 freshness anchor다.
      기존 Entry의 exact identity 저장소는 authority binding 하나로 통합하고 active transcript는 binding을 중복 저장하지 않는다.
      `@sizeOf(Authority)<=256`, 4,096-entry registry의 기존 Entry 대비 증가량 `<=512 KiB`를 제품 타입 gate로 고정한다.
      registry incarnation과 Entry의 현재 reservation ID를 authority seal/receipt에 함께 결속해 stale authority+stale identity의
      동시 splice 및 같은 주소 registry reincarnation 뒤 reservation ID 재사용도 거부한다. leaf는 tag-family 구조 일치와 bound RPC family만 canonical로 만들며, role/phase/stream/
      destination admission은 B3-2가 소유한다. Debug·ReleaseFast leaf 4개와 registry 2개, boundary 1개의 exact-count
      focused gate와 전체 session-host gate가 B3-1 완료 증거다.
   4. **B3-2 private destination admission(완료):** classifier SSOT는 private `EntryLifecycle`·`ControllerAuthority`와 canonical
      `PreparedRequestAuthority`를 함께 소유한 `AttachmentCleanupRegistry` 하나다. 기존 prepare admission과 새 execute destination
      admission은 하나의 private closed decision table을 공유하되, prepare는 `RuntimeRequest.decode()`가 만든 tag/family를 소비하고
      execute는 `{Reservation, exact BindingIdentity, transport address/incarnation, PreparedCallReceipt, current bound_stream_id,
      AdmissionContext}`만 받아 registry의 canonical prepared transcript에서 tag/family를 다시 resolve한다. `AdmissionContext`는
      raw-first `prepare|execute_attach|execute_rpc`인 closed enum 하나이며 stage와 destination을 별도 입력으로 두지 않는다. execute caller가
      tag/family/role/phase/controller 상태를 별도 scalar로 주입하거나, registry `Entry` snapshot을 외부로 투영하는 API는 금지한다.
      이 context는 session-host 내부 분류일 뿐 public contract/response union이 아니다.
      `current bound_stream_id`는 authority가 아니라 final-address `GenerationTransport.requestOperation`이 매 호출 투영하는
      drift probe다. lower wrapper에 임의 scalar를 넣어도 canonical entry stream보다 권한을 넓힐 수 없고, source oracle은 제품
      execute callsite가 이 필드를 `self.bound_stream_id`에서만 채우는지 고정한다.
      현재 public `GenerationTransport.executePreparedRequest(receipt,*ExecutedResponse)`와 `client_slot.executeGenerationRequest` signature는
      그대로 두고 public wrapper는 pointer/owner preflight 뒤 내부 `.attach`만 선택한다. `.rpc`는 B3-2 focused test-private caller만
      사용하며 제품 constructor/callsite는 0이다. `attach_only`는 attach destination, 세 bound family는 rpc destination에서만
      허용하고 destination mismatch를 role/phase/stream authorization보다 먼저 판정한다.
      반환은 `Error!Decision`으로 분리한다. `Decision`은 저장·재생 가능한 permit이 아닌 즉시 read-only
      `allowed|unauthorized|busy`, `Error`는 `InvalidOwner|InvalidReceipt|InvalidResponseDestination`의 닫힌 집합이다. public wrapper의
      zero/overflow/response-owner containment 같은 비역참조 structural preflight가 먼저이고, 그 뒤 classifier exact precedence는
      outer operation conflict `Busy` → raw context `InvalidResponseDestination` → registry/reservation/binding 및 raw
      entry/controller/role drift `InvalidOwner` → canonical transcript 부재·transport/receipt 또는 raw tag/family 불일치
      `InvalidReceipt` → structurally denied `spawn_full`의 `Unauthorized` → family/context mismatch `InvalidResponseDestination` →
      semantic `busy|unauthorized|allowed`다. 따라서 structural preflight가 통과했다는 전제에서 invalid context+receipt mismatch는 destination error, invalid tag/family+outer
      conflict는 Busy, spawn_full+wrong execute context는 Unauthorized, revoke-pending detach+wrong execute context는 destination error가 이긴다.
      controller `detach`는 `live|revoked`에서 허용하고 `revoke_pending`은 `beginBoundDrop`과 동시에 진행할 수 없으므로
      `Busy`; observer는 canonical `unavailable`에서 허용한다. `spawn_full`은 모든 stage/destination에서 거부한다.
      invalid raw context/entry/controller/role/tag/family, 14 tag×5 family×3 context×phase `empty|reserved|bound|drop_active`×role×
      controller-state×`entry_stream {0,A,B}`×`current_stream {0,A,B}`, `find(scroll=false|true)`, 모든 identity/receipt/transport/
      context splice와 same-address registry ABA를
      production registry type으로 전수한다. 각 verdict 전후 registry entry, prepared/RPC authority lifecycle·epoch, response owner,
      stream/controller state는 byte-identical이어야 한다. storage는 classifier 입력이 아니므로 접근/callsite 0을 source oracle로
      고정한다. Client·socket·pending flush·wire·allocator·payload·response
      publication과 `RpcResponseAuthority.reserveExecuting` call은 0이며 public facade/signature delta 0 source oracle, Debug·ReleaseFast
      exact-count focused gate와 boundary gate를 통과한다. pure table은 `spawn_full`과 invalid tag-family를 structurally deny하지만 실제
      product prepare는 canonical publication 전에 spawn을 `Unauthorized`로 끝내고, execute fixture에는 그런 canonical receipt가 없어
      `InvalidReceipt|InvalidOwner`에서 닫힘을 별도로 검증한다. B3-2 verdict를 cache/permit화하지 않는다. B3-3은 flush 전
      expected lifecycle `.prepared`, `beginPreparedRequestExecute` 뒤 flush 후 `.executing`으로 같은 receipt의 canonical transcript와
      current entry를 각각 새로 resolve해 동일 classifier를 다시 호출하며 post-flush 결과만 first-byte 권위로 쓴다. Debug·ReleaseFast
      registry 3개와 product 2개, boundary 1개를 합친 exact 11-test focused gate와 전체 session-host 회귀가 완료 증거다.
   5. **B3-3 progress/execute integration (완료):** caller-final storage에 Client가 in-place 초기화·seal하는
      `PreparedRequestExecutionLease`와 closed
      `PreparedRequestWireProgress{request_zero_clean,prior_pending_ambiguous,request_maybe_written}`의 유일한 생산자가
      된다. error/lifecycle에서 progress를 추론하거나 byte count·bool을 caller가 permit처럼 재주입하지 않는다. exact 순서는
      registry `preparedRpcAdmission(.prepared)` → `initPreparedRpcExecutionTxn`+defer 설치 → registry-owned `reserveRpcResponseExecution` →
      `beginPreparedRequestExecute` → Client `beginPreparedRequestExecution`의 pending flush+lease → registry
      `executingRpcAdmission(.executing)` → callback/allocation 없는 lease consume+첫 request write다. post-flush verdict는 저장하지 않고
      first-byte 직전에 같은 classifier로 canonical transcript를 새로 resolve한다. reusable rollback은 오직
      `request_zero_clean && Client usable`에서 request backing abort와 RPC authority `executing→idle`을
      함께 끝낼 때 허용한다. prior pending partial/ambiguous, 첫 request positive write, closed/poisoned Client, epoch 소진은
      RPC authority terminal+connection fail-close로 닫는다. B3-3에서는 correlated response publication을 열지 않고 Darwin
      socketpair peer가 exact request를 관측한 뒤 EOF를 내는 terminal sink로 first-byte/complete-write 경계만 증명한다.
      private pristine `RpcExecutedResponse` destination을 txn이 봉인하되 payload/publication API는 0으로 유지한다. B3-4/5 correction은
      이 fixture-owned destination을 canonical `GenerationTransport` inline slot exact address 하나로 수렴시킨다.
      focused Debug·ReleaseFast gate는 progress raw/monotonic 전수, pre/post classifier와 authority reserve/rollback/terminal,
      pending cleanup callback 재진입을 고정한다. macOS socketpair gate는 pending 0/partial/full, request 0/1/len-1/full,
      actual kernel의 zero/positive-partial/full과 EOF/EPIPE를 관측한다. exact 1/len-1·EINTR/EAGAIN/zero/hard error는 injected write ops가
      결정적으로 전수한다. boundary는 pre/post classifier exact 1회, first-write adjacency,
      legacy writeAll·public RPC destination·response publish/borrow 0을 강제한다. private final-address
      `PreparedRpcExecutionTxn` 하나가 기존 `PreparedExecutionTxn`과 RPC canonical을 합성해
      `pristine→response_reserved→settled`의 닫힌 phase와 request-cleanup 선행 뒤 response rollback/terminal 순서만 소유한다. request
      phase는 내장 txn, wire phase는 lease progress만 조회하며 중복 저장하지 않는다. 합성 txn은 response reserve 전에 mutation 0으로
      초기화되고 즉시 defer 보호를 얻는다. request backing 정리 구현을 복제하지 않는다. B3-3 내부 production 타입/함수는 test
      fixture 3개가 exact private wrapper를 8회 호출해 reserve 뒤 rollback, lease 뒤 rollback, response epoch 소진의 wire 0·fail-close,
      pending ambiguity, request hard failure, frame alias, full-write+EOF, pending-free callback destination 점유를 검증한다. execution
      lease를 얻은 뒤에는 request backing과 두 authority를 모두 정산한 다음 fence를 마지막에 해제한다. 테스트 밖 제품 caller는
      B3-6 전까지 0이다. execution fence는 주소·generation 외 process-local checked-monotonic incarnation을 lease와 Client latch에
      함께 봉인하며 same-address reincarnation은 새 fence를 release하지 않고 fail-closed한다.
   6. **B3-4/5 원자적 publication+borrow/finish (single-slot correction 완료):** published payload 생성·정리 primitive와
      canonical `GenerationTransport` inline single slot correction을 구현·검증했다. actual transport slot의 2회·64회 재사용,
      exact safe-free/ambiguous no-free,
      `published→borrowed→releasing` exact-once lexical borrow와 owner finish, 2회·64회 순차 RPC를 구현한다. `client.zig`는 기존 response
      loop를 request 재전송·request-id 증가 없는 `readPreparedResponseUnderExecutionLease`로 추출하고, 새
      `rpc_executed_response.zig`가 반복 RPC byte owner/borrow receipt를 소유한다. 기존 attach `executed_response.zig`와 owner seal은
      변경하지 않는다. response primitive는 B3-3과 동일한 `.blocking` only이고 새 deadline/clock SSOT는 0이다. socketpair fixture는
      bounded peer response/EOF로 종료하며 deadline mode는 2c3e가 결정한다. authority protocol lifecycle과 byte owner lifecycle은 분리된
      SSOT이며 registry raw authority pointer escape는 0,
      `client_slot.zig`만 product orchestration을 소유하되 `PreparedRpcExecutionTxn`은 publication/정산까지만 소유한다. borrow begin은
      fresh-operation preflight/permit 뒤 종료되고 lifetime은 `RpcResponseBorrow` receipt만 소유하며, final-address
      `RpcResponseFinishTxn`은 finish만 소유한다. 기존 payload ledger의 새
      `transferPromotedRpcResponse`가 publication preflight 뒤 owner를
      in-place seal하면서 promoted entry를 atomically `transferred_response`로 소비하고, 그 다음 authority의 final-address
      `PreparedRpcTransitionPermit`을 `commitPublishedNoFail`로 exact once 소비한다. authority는 named prepare/no-fail consume 쌍만
      module-public으로 열고 registry 외 callsite와 raw pointer escape는 0이다.
      import는 `response_payload_allocation -> rpc_executed_response` 단방향이고 owner는 ledger type 대신 owner-local neutral
      `AllocationProvenance` scalar만 받는다.
      attach `transferPromotedResponse` 의미 변화 0을 differential gate로 고정한다. publish 후 request/backing 정산, ledger operation end,
      마지막 lease release를 고정하고 borrow/finish는 fresh registered operation pin을 callback suffix까지 유지한다. raw bytes는 owner 파일
      내부 `builtin.is_test` lexical helper 1곳에만 노출하고 production raw-byte bridge와 family decoder callsite는 0이다. 실제 cross-module
      decoder API와 default protocol-failure cleanup guard/error·early-return integrated finish는 2c3e doc-first가 소유한다. B3-4/5
      product-shaped test는 begin-borrow/finish를 fresh operation 아래 명시적으로 호출한다. 기존 payload ledger를 재사용하며 1..control cap,
      empty/cap+1/OOM/truncation, 전체 owner-range alias, pre-free terminal-no-free와 `free_committed→terminal_clean|node/txn
      terminal_freed_once` callback drift를 전수한다. begin-borrow는 현재 operation/borrow permit/output receipt, finish는 현재 borrow receipt와
      fresh finish txn/operation/releasing·finish permit 각각에 대해 payload disjoint를 검사하며 종료된 begin stack 주소는 저장·재검사하지
      않는다. finish는 `prepareReleasing→owner free_committed→commitReleasingNoFail` 순서를 지킨다. node-local
      `RpcFreeEvidenceRecord{empty|free_call_committed|terminal_freed_once,response_epoch,digest}`는 정상 callback/authority commit 뒤 operation
      release 전에 exact epoch로 empty retire하고 fail-stop evidence는 재사용하지 않는다. private strict
      wrapper는 byte-owner tombstone/free를 먼저 끝내고 authority terminal을 게시한 뒤 fail-stop outcome을 즉시 소비한다. 원 B3-4/5
      slice는 terminal-before-return source oracle과 private noreturn sink까지만 소유한다. single-slot correction이 internal normal strict
      callsite와 module-public entry의 immediate consumption을 소유하고, B3-6은 dedicated isolated subprocess/source 증거만 소유한다.
      correction boundary는 `fail_stop_required` return/store 0과 private noreturn sink adjacency를 고정한다. Debug·ReleaseFast exact-count leaf/registry/product/
      boundary, actual socketpair fragmented response·OOB-before-response·wrong kind/id·EOF, allocation fail-index, publish/transition permit
      preflight mutation 0·copy/move/replay 거부,
      correction의 정상 suffix는 fresh finish registered operation에서 callback 복귀 뒤 owner/finish/evidence를 재검증하고
      reusable-authority, evidence-retire, owner-rearm permit을 모두 fallible prepare한 다음
      `finishCleanNoFail→commitReusableNoFail→commitEvidenceRetireNoFail→commitReusableRearmNoFail→operation release` 순서다.
      evidence-retire는 `client_slot.zig` 소유 final-address `PreparedRpcFreeEvidenceRetirePermit`이며 record address, epoch/digest,
      `free_call_committed` seal, consumed bit를 봉인하고 authority idle commit 직후 callback/lookup 없이 exact record를 empty로 소비한다.
      owner-rearm은 `rpc_executed_response.zig` 소유 final-address `PreparedReusableRearmPermit`이며 response/self address, old identity/epoch,
      current `free_committed` owner+freed-once finish transcript에서 계산한 expected `terminal_clean` owner seal, expected consumed finish digest,
      consumed bit만 봉인한다. owner leaf는 registry/authority/evidence를 import하거나 caller bool을 받지 않는다. held operation/current binding과
      세 permit의 exact lineage를 `client_slot.zig` private reusable-finish suffix 진입 전에 한 번에 검증하고 이후 commit 사이
      registry lookup/fallible validation 0으로 인접 소비한다. copy/move/replay/wrong-order/drift는
      reset 0 isolated fail-stop이다. prepare/commit rearm leaf의 production direct caller는 그 suffix에서 각각 exact 1이고,
      다른 module과 `generation_transport.zig`의 direct caller, public reset/rearm 노출은 0이다. owner-file test caller는 별도 allowlist다.
      rearm 뒤 recoverable error·callback·allocation·lookup·추가 semantic mutation은 0이고 canonical operation release만 허용한다.
      protocol failure·terminal-no-free·terminal-freed-once·authority terminal은 영구 tombstone이며 rearm 0이다. prepare/abort/pre-wire reject는
      slot bytes·epoch·rearm mutation 0이다. 동일 inline slot exact address의 reusable 2/64회와 매회 fresh epoch·payload free exact 1·finish 반환
      `pristine+authority idle+evidence empty`, stale owner/borrow/finish/permit replay의 read/free/mutation 0, callback reentry Busy와 두 선형화
      순서 source oracle이 correction merge gate다. 이 correction은 import cycle 없이 actual transport slot 2/64회를 증명하도록
      `GenerationTransport.rpc_response` inline field와 generation-transport-file-private `executePreparedRpcSubstrate(receipt)`의
      ownership-only private settlement `.rpc` path exact-one callsite까지 함께 소유한다. payload semantic read와 normal `RemoteRuntime`
      product caller는 0이고 2c3e가 typed decoder path로 교체한다. finish function entry에는 releasing authority, finish reusable|terminal
      authority, evidence-retire, rearm의 네 permit storage를 client-slot-private `FinishPermitRawStorage` 하나가 aligned `undefined` raw
      storage로 먼저 예약한다. sealed response identity와 stored addr/len/digest scalar의 checked-add만으로 typed/payload read·hash·allocator
      access 0 상태에서 allocator capability capture 전에
      payload/finish/borrow/response/operation/node/outer-owner 및 서로 간 exact/partial/overflow alias closed set을 통과한다. alias면
      capability copy·free·permit init/prepare/commit·owner/authority/connection mutation 0이다. 새 recovery facade 없이 parent-minted
      `permit-alias-preflight-rejected` sentinel 뒤 즉시 strict fail-stop하며, disjoint branch만 bytewise pristine init→permit prepare를 진행한다. process가
      종료되는 이 exact local-invariant branch는 terminal-before-panic graph 게시 요구의 명시적 예외다. caller/GUI만 종료하고 daemon/PTY
      direct terminate/kill/control frame은 0이다. fd close에 따른 EOF-driven client detach/revoke는 exact once이며 daemon PID/runtime/PTY
      child는 생존해 fresh reattach와 output 연속성을 유지한다. disjoint 뒤에만 full payload live/digest 검증을 허용하며 이후 generic terminal-no-free
      alias 문구는 raw permit-reservation alias를 제외한다.
      attachment drop은 prepared request와 RPC response readiness를 같은 canonical registry entry에서 확인해 published·borrowed·releasing 동안
      mutation 0의 `AdminBusy`로 닫고, reusable finish의 `authority idle+evidence empty+slot pristine` 뒤에만 다시 허용한다.
      `GenerationTransport` 크기는 Debug·ReleaseFast에서 2048 bytes 이하로 고정한다.
   7. **B3-6 internal aggregate strict completion:** 기존 public attach facade
      `executePreparedRequest(receipt,*ExecutedResponse)`의 signature/behavior를 유지한다. correction에서 연 private
      `executePreparedRpcSubstrate(receipt)` ownership-only private settlement path는 correction부터 client-slot module-public entry에서 `fail_stop_required`를 반환형에
      노출하거나 저장하지 않고 기존 private noreturn sink로 즉시 소비한다. B3-6은 public facade와 semantic decode를 바꾸지 않되,
      peer/resource read 실패를 local invariant fail-stop으로 오분류하던 내부 settlement를 process-alive terminal로 교정하고 나머지 strict behavior를
      dedicated subprocess/source oracle로 증명한 뒤에만 `2c3b-3 완료`로 승격한다. public RPC execute·`*RpcExecutedResponse`·borrow·finish·reset,
      normal `RemoteRuntime` family callsite와 사용자 가시 동작은 0이다. decoder 제품
      전환은 계속 2c3e 소유다.
      기존 B3-0a response-alias count 4 artifact를 이 완료 증거로 재사용하지 않는다. correction은 별도
      `CR3a-2c3b reusable response correction` count 5 artifact로 same-slot 2/64, evidence-retire, rearm permit drift/replay,
      post-rearm 금지 동작을 고정한다. B3-6은 별도 `CR3a-2c3b internal rpc substrate` focused gate의 runtime 2+boundary 1,
      total count 3으로 private wrapper의
      peer-error non-crash actual-socket matrix, local invariant isolated fail-stop matrix, public/private boundary+exact-one callsite를
      고정한다. peer wire frame/header/envelope malformed·wrong-id·truncated·empty·cap+1·OOM은 process alive+connection terminal+
      registry response authority permanent tombstone+payload owner pristine+rearm 0+
      second free 0이고 local seal/allocator/authority/rearm drift만 abnormal exit다. parent-minted stage sentinel은 free exact once,
      authority idle, evidence retire, rearm precondition을 구분하며 reset 전 fail-stop과 rearm 뒤 operation release 외 동작 0을 증명한다.
      bounded nonempty correct-id payload의 JSON/application semantic 오류는 2c3e decoder가 소유한다.

      여기서 `empty`는 response header를 한 byte도 받기 전의 zero-byte EOF다. correct-id response의 payload 길이 0도 canonical
      accepted owner가 아니므로 process-alive protocol terminal로 정산하며 permanent tombstone, semantic read 0, rearm 0이다. peer 행렬은 bad magic, wrong major, invalid kind, wrong request id,
      header cap+1, header truncation, payload truncation, zero-byte EOF, allocation fail-index와 correct-id empty payload를 exact case로
      갖는다. correct response 뒤 같은 write에 붙은 duplicate old-id response는 첫 cycle을 정상 정산한 뒤 다음 cycle에서 correlation
      loss로 terminal된다. 이때 두 번째 RPC-slot publication/owner-free/rearm은 0이고 parser discard payload free는 정확히 1회다.
      host가 미래 request id와 올바른 response frame을 미리 위조하는 경우는 wire만으로 정상 future response와 구분할 수 없는
      compromised-peer 범위이며 이 gate의 local memory-safety 증거가 아니다.
      OOM은 parser frame backing과 payload allocation/promotion까지 observer가 실제로 도달한 모든 ordinal을 최초 성공까지 전수하고,
      publication 이후에는 recoverable allocation 지점을 새로 만들지 않는다.
      isolated child 증거는 단순 panic 문자열을 성공으로 세지 않는다. parent가 별도 capability/stage pipe로 민트한
      `{version,case_id,nonce,stage}` 11-byte record(`nonce` little-endian)의 case별 exact prefix와 final sentinel, 예상 abnormal termination을 함께 검증한다.
      response seal/allocator drift는 `free_once` 뒤, authority drift는 permit 준비 뒤, rearm drift는
      `authority_idle -> evidence_retired -> rearm_precondition` 뒤에만 주입한다. exec 126/127, capability/nonce mismatch, generic panic, stage
      누락·중복·역전은 실패다. parent는 stderr와 stage pipe를 child 종료 전 nonblocking으로 함께 drain하고 capture cap 뒤에도 EOF까지
      discard-drain하며 truncation은 실패 처리한다. absolute timeout은 kill 뒤 waitpid exact once로 닫는다.
   8. **2c3c control facade (C1·C2·C3 완료):** C1은 별도 raw-discriminator-safe `RuntimeControl` DTO와 exact
      `ValidatedRuntimeControl=scroll_to_bottom|core_command`를 두고 `sendControl|sendControlNonBlocking` substrate를
      `ClientSlot` canonical operation 아래 추가한다. unsupported capability는
      `ControlError.Unsupported`, nonblocking `false`는 backpressure만 뜻하며 raw method/JSON/stream ID escape는 0이다. C2는 기존
      `PendingControl.barrier` queue의 generation nonblocking scroll/core 호출을 facade로 전환하고, C3는 blocking flush를 전환한다.
      C2의 encode OOM은 typed queue dequeue와 새 control owner/wire를 0으로 유지하되 prior pending progress만 허용하고 duplicate 없이
      재시도한다. C3 queue flush는 response 없는 stream frame만 써서
      `RuntimeRequest.core_command`로 fallback하지 않는다. outer scroll은 dedicated scroll capability/frame, nested
      `core_command(.scroll_to_bottom)`은 core capability/frame을 유지하며 unsupported wire-kind fallback은 `RemoteRuntime`만 결정한다.
      C3 encode OOM은 prior pending progress만 허용하고 새 control wire 0·queue retain·재시도 duplicate 0을 고정한다.
      facade `Unsupported`는 generation adapter 한 곳에서 consumed no-op으로 normalize해 기존 사용자 가시 동작을 보존하고,
      backpressure만 queue를 유지한다. public raw DTO는 zero-init outer tag+module-private shared `RawCoreCommand` representation을 쓰며
      decode가 검증한 active member만 semantic authority로 삼는다.
      C1은 `test-session-host-2c3c-c1`의 Debug·ReleaseFast runtime 7+boundary 1 exact-count로 구현·검증 완료했다.
      C2는 `RuntimeAttachment`의 generation arm에만 nonblocking control adapter를 두고 `PendingControl`을
      `RuntimeControl`로 투영한다. 이 한 경계가 `Unsupported`만 consumed no-op으로 접고, `false`와
      `ResourceExhausted|Busy`는 queue retain, 나머지 오류는 기존 `ClientError` 의미로 전파한다. legacy arm과 queue/barrier 저장 구조는
      변경하지 않는다.
      C2의 Debug·ReleaseFast gate는 runtime 5+C1 runtime 7+boundary 1의 exact inventory로 모든 15개 command projection,
      canonical frame allocation OOM 뒤 retain·무독성·exact-once retry, zero/partial/full pending progress, peer close의 hard-error retain,
      1/64/65 queue와 allocation fail-close, unsupported wire 0, coalescing과 `input prefix -> control -> input suffix` 순서를 검증한다.
      C3는 같은 closed projection을 재사용해 `flushQueuedInputBlocking`의 generation arm만
      `GenerationAttachment.sendControl`로 전환한다. 성공과 `Unsupported` no-op만 dequeue하고,
      `ResourceExhausted`는 `OutOfMemory`, `Busy`는 `AdminBusy`, authority/protocol/close 오류는 기존 `ClientError` 의미로 전파해
      queue를 유지한다. encode OOM 전 기존 pending frame offset 진전은 허용하지만 새 control wire와 duplicate는 0이며,
      legacy blocking direct Client 두 호출과 recovery resync baseline은 변경하지 않는다.
      일반 RPC는 retained queue를 추월하지 않는다. `terminateBestEffort`만 blocking flush OOM에서 runtime 파괴가 queue를 대체하는
      명시적 예외로 retained mutation을 폐기한 뒤 terminate를 시도한다. `detachBestEffort`는 flush 오류에서 detach RPC 0을 유지하고,
      `ConnectionClosed` 외의 OOM/Busy/authority/protocol 오류는 connection fail-close→host EOF lease 회수로 수렴한다.
      queue·registry authority는 새로 만들지 않고 legacy arm과 recovery-owned resync는 유지한다. 각 slice는 Debug·ReleaseFast focused
      test와 boundary oracle을 통과한다. C3 RemoteRuntime 5+slice-exclusive Client write 1은 blocking drain 단일-owner 재진입 방지, 새 scroll/core frame의
      injected zero/1/len-1/full·EINTR 분류, ambiguous partial fail-close, generation teardown actual RPC를 고정하고 generation scroll/core
      direct Client callsite 0과 recovery resync baseline 1을 유지한다. event는 2c3d,
      response-bearing RPC decoder와 실제 socket parity는 2c3e, `RemoteRuntime.client` 필드 제거는 2c4가 소유한다.
   9. **2c3d one-shot event facade (doc-first):** generation event는 raw `BufferedEvent` 값 반환 대신 caller-final-address
      `EventOwner`의 event-incarnation별 one-shot lifecycle을 사용한다. inline storage는 정상 release 뒤 pristine으로 재사용하고,
      ClientNode binding-registry entry의 checked-monotonic `event_generation`이 canonical SSOT이고 `GenerationAttachment` mirror는
      검증된 projection이므로 owner+attachment bytes의 same-address ABA도 막는다. 짧은 `.event`
      take/release stream-operation permit과 그 사이의 기존 `ConnectionLease` 기반 node/slot cleanup pin을 분리해 revoked-event의
      `fenceRevoke`는 허용한다. attachment teardown은 별도 inline lifecycle/generation mirror로 live owner를 `Busy` 처리한다.
      `takeEvent(out)` 결과는 `idle|ended_pending|taken`, 공통 오류는 `Busy|InvalidOwner|Corrupt|Terminal`이며 무할당이다.
      GUI ingress는 accepted/unknown 모두의 header·verdict·payload·canonical Client allocator identity를 seal한다.
      `releaseEvent(owner)`는 connection poison 뒤에도 canonical cleanup을 허용하고 exact-once free하며 callback 뒤 no-fail suffix로
      permit/reservation/pin/owner를 소비한다. unsafe provenance는 ordinary 후보 검증 뒤 take 때 미리 예약하고 trusted cleanup mirror를
      owner bytes와 독립 봉인한 `max_gui_attachments=4,096`, retained byte 1 GiB bounded no-free quarantine으로 transfer한다.
      별도 issuer 없이 `{node incarnation,event generation,owner address}`를 reservation identity로 쓰며 정상 release는 slot을 empty로
      재사용한다. ended 판정은 예약보다 먼저다.
      generation pump는 purge-first이고 ordinary take도 ended를 반환하지 않는다. C1 admission/allocator seal·node-canonical reusable owner/generation·ordinary take는 구현됐고,
      C2 release/pin/quarantine/callback closure는 public `releaseEvent` exact 1개, std/scalar-only 4,096-slot·1 GiB
      dedicated quarantine leaf, mutex 전 PID/owner-thread gate, binding registry의 one-shot recovery permit과 cleanup-only canonical
      pin projection이 함께 있어야 하는 damaged-lease recovery, callback 전 전수 검증·모든 mutex 해제와 logical registered-node
      operation pin 유지, stack final-address completion receipt에 의한 callback 뒤 lookup 없는 binding settlement와 pin-last no-fail
      suffix를 한 vertical slice로 닫는다. `client_slot`만 transaction을 조정하고 raw Client는
      canonical resource handoff를 알며, owner-local lifecycle은 기존 import 방향대로 `generation_event_contract`가 소유하고
      `GenerationTransport.releaseEvent`가 scalar prepare→owner tombstone→resource commit→owner finalize를 조정한다. C2는
      production-type facade exact 14이고 제품 event callsite는 0이다.
      C3는 세 PR-size gate로 나누며 각 gate가 Debug·ReleaseFast focused sentinel과 boundary를 가진다.
      **C3-1**은 `GenerationAttachment` 안의 exact 512-byte `EventOwner`, 권위 없는
      `event_generation_mirror:u64` projection(0=idle/settled, nonzero=검증된 live generation), attachment-only
      `takeEvent/viewEvent/releaseEvent` wrapper와 teardown `Busy -> explicit release -> success`만 소유한다. canonical
      generation과 cleanup readiness의 SSOT는 계속 ClientNode binding registry이고 mirror는 free/drop/release 권위가 아니다.
      transport가 canonical take 결과에서 generation을 함께 투영한 뒤에만 mirror를 게시하며 public owner bytes나 payload를
      재해석하지 않는다. clean release는 mirror를 0으로 만들고, `Busy|InvalidOwner`는 owner/mirror를 보존하며, corrupt
      release는 C2 trusted no-free handoff와 poison을 끝낸 뒤 owner terminal·mirror 0을 게시하고 `Corrupt`를 반환한다.
      explicit release는 mirror를 cleanup 권위로 쓰지 않으므로 mirror drift가 있어도 C2 canonical cleanup 결과를 우선한다.
      clean/`Corrupt` settlement만 mirror를 0으로 동기화한다. stream-operation identity 소진은 live event를 재시도 불가능한
      `Terminal`로 고립시키지 않고 registered-node operation 아래 C2 trusted no-free handoff로 수렴해 `Corrupt`를 반환한다.
      `Terminal`은 callback 중 live/releasing뿐 아니라 canonical already-settled/terminal을 포함하므로 이 결과만으로 settlement를
      추론하지 않고 mirror를 보존한다. mirror 단독 terminal/idle 값은 teardown 권위가 아니며 release 밖의 registry 불일치는 mutation 0
      `Corrupt`다. `tryDeinit`은 allocator callback이나 release를
      내부 실행하지 않고 canonical owner가 live/releasing이면 `Busy`; explicit `releaseEvent` 뒤 재호출만 기존 drop을 시작한다.
      construction은 binding reserve → transport mint → inline owner exact-address reserve → request prepare 순서이고, 실패는
      transport terminalize → binding abort의 기존 역순 rollback으로 request/pin/queue/quarantine leak 0을 보장한다.
      **C3-2**는 이 wrapper를 소비하는 purge-first 제품 drain과 ended priority를 소유한다. focused gate는
      `test-session-host-2c3d-c3-2`이며 C3-1 전체와 Debug·ReleaseFast attachment runtime sentinel 8+
      actual generation `RemoteRuntime` product drain 1+boundary 1을
      exact-count로 실행한다. C3-3까지의 generation drain은
      `pending settlement -> purge -> take -> immutable snapshot -> classify/prepare -> effect+release settlement -> semantic commit`이며,
      settlement `Busy` 뒤에는 같은 canonical owner와 sealed `PendingEventOwner`를 다음 tick의 purge보다 먼저 재시도한다.
      `event_pending`은 제품 error/ended가 아니라 process-state live인 progress이고, pending 동안 해당 Runtime semantic mutation과
      connection TX/RPC flush를 멈추되 shared RX/demux tail append는 허용한다.
      `.ended_pending`은 `protocol.max_client_pending_events`에서 파생한 유계 budget 안에서 purge로 되돌아간다.
      budget 소진은 입력·출력·화면 진전 0의 `Busy`로 다음 tick에 넘긴다. legacy raw acquisition과 공통 semantic
      classify/apply SSOT는 분리하며 generation 실패의 legacy fallback은 0이다. **C3-3**은 actual socket의
      revoked→borrow/classify→fence→release와 generation raw Client event source-zero를 소유한다. C3-1에는 제품 pump/socket
      consumer가 0이고, C3-3 전에는 2c3d 완료나 generation event source-zero를 주장하지 않는다.
      C3-3은 `applyObservationEvent` generation arm의 raw `self.client.wire_major`, `metadata_support`, `poison`과 raw Client
      revoke-fence 인자, `settlePendingGenerationEvent`의 raw `self.client.poison`을 제거한다. registry/ClientSlot identity와
      `expected_major|metadata_support`만 opaque `EventCorrelation`에 묶고 mutable role/controller generation/tracking은
      `RuntimeSemanticSnapshot`과 final-address pending owner가 소유한다. classify/materialize는 live Runtime mutation 0의 owned
      `PreparedEvent`를 만들고, package-private settlement가 poison/fence/terminal cleanup과 exact release를 한 preflight+no-fail
      transaction으로 닫은 뒤에만 semantic state를 no-fail commit한다. 같은 Client는 수명 전체에서 legacy 또는 generation attachment만 소유하고 mixed-mode mint/adopt는
      ClientSlot/node membership을 canonical proof로 source/product oracle에서 거부한다. generation external mode는 stable Busy가
      아니라 typed invalid-owner다. `busy`는 durable effect mutation 0이고 canonical 검증 shared receipt는 exact begin/end로 정산되며,
      admitted settlement는 guarded cleanup callback을 허용하되 effect 성공 뒤 release Busy가 없는 no-fail suffix로 수렴한다. sealed queue
      latch는 take commit에서 event generation과 connection ordering blocker를 발급하며 exact-receipt in-flight `live` row로 원자 이전되고
      settlement commit에서 consumed된다. 모든 taken event가 settlement까지 blocker를 유지하며 기존 EventAuthority lifecycle과 cleanup
      pin 외 별도 cleanup charge는 만들지 않는다. C3-3은 공통 Client ingress cadence를
      바꾸지 않는 열린-peer actual socket roundtrip까지만 소유한다. 이미 admitted unknown/semantic violation의 typed effect/release는
      C3-3, immediate EOF, admission 뒤 yield 집합, unread RX-first, socket ingress malformed/unknown cadence와 legacy/generation observable
      parity는 2c3e doc-first blocking gate로 남긴다.
      C3-3 첫 runtime slice는 등록된 ClientSlot/node owner-thread admission을 통해 exact-15 poison을 confirmed effect에
      연결한다. blocking deferred fd-open은 외부 owner가 없을 때 같은 effect에서 take/close해 영구 Busy 없이 수렴하고,
      external typed invalid/exclusive Busy는 reason/fd/pending durable mutation 0이다. guarded pending free callback의 poison/input/control과
      foreign teardown 재진입 Busy, effect 뒤 fence 재사용, exact free 1, peer EOF, first-reason/idempotency를
      `test-session-host-2c3d-c3-3` Debug·ReleaseFast에서 고정한다.
      이 slice만으로 기존 `EventAuthority` revoke class/derived cache, 제품 settlement/source-zero, revoked actual-socket roundtrip
      완료를 주장하지 않는다.
      다음 활성화는 **C3-3a revoke ordering gate**이며 세 reviewable gate로 닫는다. **C3-3a1 dormant authority substrate**는 새
      row·generation·RemoteRuntime 단계 복제를 만들지 않고 canonical `AttachmentCleanupRegistry.Entry.event_authority`에 closed
      `none|controller_revoke` class와 node-local checked derived cache를 추가한다. per-entry class/lifecycle가 SSOT이고 cache는
      `reserved|live|releasing` revoke 수의 O(1) projection일 뿐이다. production은 affected row의 exact lifecycle/receipt와 checked
      counter bound/transition만 O(1)으로 검증한다. Debug·ReleaseFast test-only invariant oracle만 bounded full scan으로 cache 일치를 확인한다.
      trusted class 인자는 기존 ClientSlot take가 canonical payload를 재검증해 얻은 preflight 결과에서만 만든다. aggregate query는
      payload를 다시 파싱하지 않는다. 성공한 revoke reserve가 `0 -> 1`, pre-reserve 실패는 `0 -> 0`, reserve 뒤 abort는
      `0 -> 1 -> 0`이다. live publication과 releasing 시작은 delta 0이다. 정상 release는 allocator callback/quarantine settlement 뒤
      `finishEventReleaseNoFail`에서 감소하고, live `StreamOperationPermit`이 그 뒤 permit consume까지 mutation을 계속 막는다. corrupt는
      terminalize 때 감소하지 않고 recovery permit 최종 consume 뒤 감소한다. teardown은 live/releasing owner를 정산하지 않고 explicit
      release까지 `Busy`다. stale/copy/ABA/double consume과 unauthorized underflow는 delta 0으로 fail-stop하며 production은 invalid raw
      lifecycle/receipt나 counter bound 위반을 fail-closed한다. 임의 row/cache bit drift의 전수 복구·탐지는 주장하지 않는다. a1은 product take/release caller exact 0인 dormant component로 구현됐고
      `test-session-host-2c3d-c3-3a1`의 Debug·ReleaseFast registry runtime 7+boundary 1을 통과한다. copied registry, same-address
      generation ABA, typed stale/double settlement까지 a1이 소유하고 no-fail continuation/recovery replay와 unauthorized underflow의
      격리 subprocess는 실제 활성화와 함께 a3가 소유한다. 따라서 이 시점의 제품 동작은 C3-3과 동일하며 revoke ordering 활성화는 주장하지 않는다.
      **C3-3a2 dormant final-admission substrate(구현 완료)**는 `client_slot.zig`의 기존 `RegisteredNodeOperation`/`ClientOperationFence` 아래 사용할
      단일 internal transaction/core predicate를 만들되 product caller를 exact 0으로 유지한다. 새 mutex·fence·aggregate generation은
      만들지 않는다. owner query에서 operation을 여는 wrapper와 이미 operation을 보유한 control/test-harness 경로용 wrapper는
      ownership만 다르고 predicate는 하나다. 후자는 registered operation을 중첩하지 않는다. attach prepared product caller는 a2에서
      0이고 future typed execute가 같은 wrapper를 재사용한다. transaction은 single shared pin을 기존 Client operation execution lease로
      upgrade하고, held-path는 public Client API의 shared pin을 다시 중첩하지 않는 internal leaf를 사용한다. lease는 final 검사부터
      allocation·queue offset·syscall commit까지 유지한다. 정산 순서는 held leaf 완료 또는 blocked 판정 -> single shared로 downgrade ->
      transaction lifecycle consume -> registered operation의 마지막 shared pin release다. canonical owner는 lease-held 상태에서
      lifecycle/receipt 검증과 no-fail settlement plan을 끝낸다. pre-acquire invalid/copy/stale/already-consumed replay와 foreign
      settlement는 canonical lease·transaction·pin mutation 0으로 typed reject하고 canonical active owner만 위 순서를 수행한다.
      active self/ownership/content drift는 raw `u8` tag 선검증, registry-bound ownership mode와 scalar seal로 fail-stop한다.
      held-operation wrapper는 operation exact extent를 pointer로 직접 선검증하고 caller의 추가 control/prepared authority는 최대 4개
      protected range로 받아 output alias·overflow·cap 초과를 pre-acquire 거부한다. transaction은
      `error{InvalidOwner, Busy}!Decision`을 반환하고 `Decision`만 `blocked|admitted`다. invalid/copy/stale/replay는 `InvalidOwner`,
      operation/lease contention은 `Busy`를 재사용한다. a2는 injected closed decision으로 transaction을 검증한다.
      a1 query는 declaration exact 1·production caller exact 0, a2 transaction도 declaration exact 1·production caller exact 0을
      유지하며 실제 queued+a1 query 연결은 a3가 모든 family와 동시에 소유한다.
      현재 존재하는 blocking/nonblocking input, generation control, pending output, 모든 raw `callOrdered` RPC와 두 resync 경로의
      error/progress·owner-retention 표를 Debug·ReleaseFast transaction runtime 7+current-family regression 5+boundary 1로 고정한다. attach prepared request/execute는 기존
      owner/fence 회귀만 상속하며 일반 runtime typed execute가 아니다. `callOrdered`는 read-only처럼 보이는 method도 pending mutation을
      flush할 수 있으므로 현행 queued-revoke 정책처럼 전부 막고, method별 세분화는 2c3e가 소유한다. raw identity/role/corruption,
      capability `Unsupported`, revoke 결과 순서로 현행 결과를 보존한다. generation transport는 typed `Busy`, RemoteRuntime
      nonblocking pump와 pending-output/resync stream은 progress `false`, raw `callOrdered` RPC는 `AdminBusy`, observer resize는 success
      no-op다. owner-retention exact 표의 SSOT는 persistent-session-host.md가 소유한다. future 2c3e RPC execute는 helper signature만 예약하고
      caller 편입은 2c3e gate가 소유한다.
      **C3-3a3 product activation(구현·활성화 완료)**은 기존 take/release에 a1을, 현재 존재하는 모든 generation mutation
      consumer에 a2를 동시에 배선한다. take는 blocker producer이므로 target queued event와 자신이 reserve한 aggregate에 다시 막히는 a2
      consumer predicate를 사용하지 않고 producer 전용 final-address activation transaction을 쓴다. permit→prepare→registered
      operation→direct execution lease→held validate/borrow 뒤에만 payload를 역참조하고 quarantine/pin/a1을 reserve·bind한다. accepted
      preflight의 exact `event == .revoked`만 `EventOrderingClass.controller_revoke`이고 unknown 및 다른 accepted event는 `.none`이다.
      transaction은 canonical receipt lifecycle을 복제하지 않고 final-address seal, closed phase와 live-bit tuple만 rollback orchestration
      SSOT로 소유한다. held commit 뒤 a1 publish→permit no-fail consume→lease downgrade→transaction consume→operation release는
      실패·callback 0 suffix다.
      mutation consumer final gate는 검사부터 allocation·queue offset·syscall commit까지 family별 existing execution lease를 유지한다.
      shared pin만으로는 다른 shared mutation을 배제하지 않으므로 직렬화 근거로 쓰지 않는다. a1/a2 standalone substrate gate의
      역사적 product caller는 0이고, 현재 활성 caller inventory는 C3-3a3 boundary가 단일 출처로 소유한다.
      execution lease mint는 private live-operation row와 neutral TLS thread incarnation을 검증한 final-address receipt만 Client에 넘긴다.
      receipt의 canonical SSOT는 process-global bounded 4,096-slot registry이며 mutex 아래 O(1) free-stack pop과
      `slot_index` direct lookup을 쓴다. receipt의 atomic registry token은 pre-lock locator일 뿐이며 registry row/receipt의 exact key는
      slot generation·monotonic registry key·final address·Client/
      operation·PID/process nonce·thread id/incarnation이다. issue/consume/abort는 mutex 전에 PID/process nonce/TLS를 검사하고 lock 뒤
      PID를 재검사해 fork child가 상속 mutex나 Client graph를 만지기 전에 거부한다. tuple/live는 mutex 안에서만 판정·변경하고
      consume-vs-abort는 한 winner만 slot을 회수한다. Client는 exact registry receipt를 먼저 consume·slot
      generation 증가·free-stack 반환한 뒤에만 fence/graph를 읽고 final-address capability body를 완성해 address·identity·thread tuple을
      release-publish한다. held API는 raw pointer/public digest/local pin 대신 opaque handle
      `{slot index,slot generation,private key,publication identity,operation identity}`만 받는다. receipt registry와 별도인
      process-private bounded 4,096-slot capability registry가 O(1) free-stack/direct-slot으로 active/closing/readers를 소유한다.
      capability registry와 별도인 bounded 4,096-slot O(1) reader-pin registry는 caller-final pin address+
      reader slot/generation/key+capability slot/generation/key row를 먼저 등록한 뒤 readers를 올린다. exact one-shot row
      consume만 unpin/close owner reader를 내리며 copy/move/forge/double-unpin/sibling은 mutation 0이다. capability key는
      settlement pre-lock은 registry PID/nonce+reader-slot bounds만 읽고 public `pin.fields` authority를 쓰지 않는다. mutex 안
      final-address/reader slot-generation-key row exact consume→canonical capability slot-generation-key materialize→owner process/thread/TLS
      compare 후에만 readers--를 수행한다. close drain은 canonical captured capability tuple만 사용한다.
      module-private 256-bit production random secret의 keyed BLAKE3
      `maru.capability.registry-key.v1 || counter || slot || generation` transcript의 64-bit 축약이다. immediate reuse의 exact ABA
      authority는 slot generation이고 key는 probabilistic private discriminator다. runtime test의 old/new key inequality는 관측
      oracle이며 absolute collision-free 계약이 아니다.
      preflight는 registry pin 성공 후에만 capability pointer/fence/body projection을 private guard에 materialize하고,
      require는 마지막 fence/body read까지 guard를 유지한다. publish exhaustion은 body·local identity·fence tuple을
      pristine rollback한다. end는 active→closing, self reader release, readers==0 대기, generation bump+free-slot 반환 후
      body lifetime을 종료한다. 반환 후 same-address reuse/new generation은 허용하며 old handle은 pointer materialization 전
      거부한다. closing 게시 직후 late pin reject+close wait, OOB/foreign/fork fields tamper mutation 0,
      injected reader-capacity exhaustion seam의 out-pristine/readers unchanged와 즉시 reuse, mmap-unmap stale, forged key/fork/replay,
      caller/private-registry closure를 exact-5/boundary가 고정한다. fault/closing hook은 `builtin.is_test` conditional
      private storage/API로 production callable API가 없는 설계이며 nm/symbol-zero gate는 주장하지 않는다.
      consume 전 후속 실패는 두 canonical mint caller의 `errdefer abortMintReceipt`가 exact slot/capacity를 반환하며
      미회수 receipt를 허용하지 않는다. held leaf는
      graph read 전에 reader pin 후 검증한다. exact-5 runtime은 max-terminal issuer,
      copied/forged/foreign/callback/publication-teardown, deterministic end-vs-reader·consume-vs-abort, fork pre-lock reject,
      abort-capacity 원복과 O(1) free-count oracle의 typed reject·mutation 0을 고정한다. Zig build에 TSAN target은 없으며
      Debug·ReleaseFast deterministic interleaving과 atomic ordering review를 검증 경계로 두다.
      `idle|ended_pending`은 payload 역참조와 activation transaction/operation/lease/quarantine/pin/a1이 모두 0이다. `idle`은 prepared
      storage pristine을 유지하고 `ended_pending`만 prepared descriptor를 먼저 tombstone하며 둘 다 permit no-fail consume을 수행한다.
      a3은 Debug·ReleaseFast product runtime 10+actual-socket 2+boundary 1을 실행한다. quarantine reserve→pin reserve→generation
      reserve→quarantine/cleanup bind의 각 precommit fault와 ClientSlot-only held commit wrapper의
      `Terminal|Corrupt|InvalidPrepared`는 reserve 뒤 cache를 exact rollback한다. direct lease 획득 `Busy`는 transaction 생성 전
      public prepared abort/reset→operation release→permit abort로 정산해 reserve 전 mutation 0과
      `(queue=1,prepared=pristine,aggregate=0,permit/pin/quarantine/reserved-authority=0)`으로 수렴한다. queue commit 성공 뒤에는
      `(queue=0,aggregate=1)`만 허용한다. target pending outbound
      offset 0은 exact free 1/wire 0, partial offset은 no-retry fail-close, sibling pending은 offset/owner 보존·flush 0 뒤 aggregate zero에서
      재개한다. activation authority-live 상태의 callback reentry·foreign·teardown은 mutation 전에 거부하고, facade별 blocker gate는
      persistent-session-host.md closed 7-row의 `Busy|AdminBusy|false|observer success no-op`와 queue/pending owner retention을 고정한다.
      public nonblocking input은 `0`,
      public control은 성공 반환+FIFO 유지, internal pump는 progress `false`다. public `GenerationTransport`는 세 gate 모두 exact 15다.
      **C3-3b1 correlation·ordering migration, C3-3b2a process-seal prerequisite와 C3-3b2b의 b2b0·b2b1·b2b2·b2b3는 구현됐고, b3 이후 event settlement와 비동기 close는 미구현**이다. 다음 TDD slice를 닫는다. b2는
      process-domain seal 이전과 immutable preparation을 각각 독립 PR인 **b2a → b2b**로 나누며, 제품 `event_pending` 활성화 전에 async close를 먼저 닫기 위해
      실제 구현 순서는 **b2a → b2b → b3 → b5 → b4 → b6**이다. 각 slice는 앞 slice의 focused
      Debug·ReleaseFast gate와 source boundary를 상속하고, 마지막 slice 전에는 C3-3b 완료나 제품 close parity를 주장하지 않는다.

      1. **C3-3b1 correlation·ordering migration:** canonical take-only opaque `EventCorrelation`, minimal ClientSlot classification context,
         `EventOrderingClass.none|non_revoke_effect|controller_revoke`와 모든 taken event의
         `connection_ordering_blocker_count`를 먼저 red→green으로 만든다. 기존 revoke-only counter/query identifier는 0으로 만들고,
         EventAuthority lifecycle+cleanup pin을 sole cleanup SSOT로 유지한다. `none`은 idle/settled row 전용 inactive sentinel이며,
         모든 live non-revoke/unknown event는 `non_revoke_effect`다. benign도 release까지 blocker를 유지하며 sibling TX/RPC는 wire 0,
         queued revoke 뒤에도 RX/demux tail은 진행하는 actual socket oracle을 포함한다. take 당시 `expected_major|metadata_support`는
         canonical quarantine mirror에 immutable snapshot으로 봉인하고 release는 mutable Client current state를 다시 권위로 사용하지 않는다.
         b1의 RX/correlation projection은 내부 substrate이며 실제 `RemoteRuntime` 제품 pump 연결과 dormant semantic owner handoff는 각각 b4와 b2b가 소유한다.
      2. **C3-3b2a process-seal prerequisite:** dependency-neutral `process_identity.zig`를 macOS/Linux 실제 PID의 sole SSOT로 먼저 두고,
         neutral `process_seal_service.zig`를 별도 PR로 구현하며 기존
         `operation_thread_identity`의 capability key를 원자적으로 이전한다. ClientSlot process bootstrap의 기존 mutex 아래
         `nonce -> unpublished service prepare -> registry/issuer no-fail publication -> service ready release` 순서를 단일 transaction으로
         고정하고, 모든 reader는 PID/process nonce/domain의 ready acquire 검증 전 key·registry mutex를 만지지 않는다. production entropy는
         neutral `secureEntropy` provider가 service private unpublished storage에 직접 쓰며 raw key는 module 밖으로 나오지 않는다.
         non-secret cross-target fallback은 두지 않는다. 모든 byte OR가 0이면
         retry·fallback·`commitReady` 없이 permanent terminal이다. test-only deterministic scalar seed는 local service private seam에서만 내부
         KDF로 확장하고 seed/output 0을 거부하며 non-test import/caller/storage는 0이다. fork child는 inherited key/lock 전에 PID mismatch로
         거부한다. 전용 non-test helper의 public singleton을 두 clean exec에서 초기화해 process 간 derived tag 비재사용과 각 process의 typed derivation
         idempotence를 검증한다. 구 key/storage/lazy initializer/API/callsite는 source 0이며 source-level cutover라 과거 binary의
         storage zeroization이나 live key migration을 주장하지 않는다. b2a domain API는 capability registry key만 제공하며 b2 cleanup
         transcript/progress concrete typed input과 seal method는 b2b가 추가한다. raw key나 arbitrary-byte MAC oracle은 제공하지 않는다.
         service lifecycle은 `uninitialized -> initializing -> ready | terminal`이고 initializing claim 뒤 모든 실패는 terminal release를
         게시한다. package-private `prepare/commitReady/validateReady/capabilityRegistryKey`의 closed errors와 ClientSlot의
         `ProcessDomainMismatch|ProcessSealUnavailable` 정규화는 persistent SSOT를 따른다. focused gate는 기존 capability/reader/fork 전수와 동시 최초
         init·publication boundary pause·entropy/zero·cross-domain/replay를 Debug·ReleaseFast로 고정한다. Client fence, generation transport,
         initial snapshot owner, generation batch allocator-scope registry와 ended-purge quarantine receipt/proof도 같은 PID leaf로 이관하고
         unsupported target PID zero fail-close, Linux sentinel 권위와 fork-child
         inherited-authority acceptance가 0임을 source/process gate로 검증한다.
      3. **C3-3b2b immutable preparation:** 이 단계는 **b2b0 exact observation → b2b1 trusted preparation seal prerequisite →
         b2b2 pure preparation recipe → b2b3 immutable owner preparation**의 네 독립 merge gate로 구현한다. **b2b0은 구현 완료**로 공용
         `RuntimeObservation.replace`와 기존 cache admission을 exact-capacity로 먼저 닫았고 session-host event lifecycle이나 제품 caller를
         변경하지 않는다. **b2b1은 구현 완료**로 기존 quarantine trusted mirror와 opaque correlation의 ClientSlot 내부 SSOT를 재사용한다. ClientSlot의
         exact-correlation validator가 pointer-free instantaneous preparation projection과 canonical binding digest를 만들고 private identity를
         소유한 generation-event contract가 기존 borrowed `EventOwner.view()`와 별도 필드로 조합한다. GenerationTransport는 이 seam만
         호출하며 correlation value는 validation input으로만 쓰고 projection 반환·저장/raw accessor는 0이다. public
         `EventOwner.view()`/`EventView` 계약은 그대로이며 `RemoteRuntime` field와 normal product caller는 0이다. 같은 gate가 named fixed-shape
         cleanup graph(`preparation = DTO backing + next observation 7 owners`, `committed_observation = old observation 7 owners`)와 stateless
         fixed-domain typed 256-bit transcript/progress MAC을 닫는다. generic writer/MAC, raw key, permit registry, persistent expected-MAC mirror는 없다.
         **b2b2는 구현 완료**다. pointer/slice/allocator/owned storage 0인 `EventPreparationRecipe`와
         allocation-free metadata recipe/size/fill mapping을 추출한다. 기존 allocation-free `classifyEventView`는 바꾸지 않고 기존 owning API와
         future b2b3 generation-event staged path만 exact provenance를 가진 같은 `Classification` projection을 공유한다. 현재 authority가 없는
         external materialization path를 재분류하거나 두 번째 recipe를 만들지 않는다. compatibility adapter가 allocator callback 뒤 canonical
         payload/classification을 재검증하고 caller-owned scratch fill 성공 뒤에만 기존 owned metadata DTO를 조립해 accepted/violation 전 arm,
         기존 error/OOM 의미, zero/nonzero allocation 0/1, DTO 의미 동등성을 보존한다. event facade에만 local drift/alias를 peer failure와
         분리하는 `LocalInvariant`를 추가하고 legacy `DecodeError`는 넓히지 않는다. wire leaf는 `RuntimeObservation`을 import하지 않는다. recipe의
         pointer-free fixed-field shape, raw-first metadata scalar/presence, explicit outer tags, module DAG, two-pass fill·publication atomicity,
         오류 매핑과 recipe 10+compatibility 5+RemoteRuntime mapping 1+boundary 1의 exact-17 TDD inventory를 persistent SSOT대로
         Debug·ReleaseFast에서 통과했다. `runtime_event_preparation.zig`가 pure recipe/fill을, `runtime_metadata_wire.zig`가 기존 owning API의
         compatibility adapter를 소유하며 normal b2b3/product caller는 아직 0이다.
         **b2b3는 구현 완료**다. final-address `PendingEventOwner`, immutable Runtime snapshot, final closed `PreparedEvent`/effect, typed scratch handoff,
         4-part prepare peak·3-part published rehash와 proof-loss cleanup을 production source에 구현했고 real `GenerationAttachment` take의 test-mode
         dormant orchestration으로 호출한다. source·operation·destination preflight 뒤 기존 cleanup registry의 exact active
         `EventAuthority`를 `live -> preparation_pending`으로 바꾸는 것이 begin no-fail suffix의 첫 mutation이다. 이 상태는 canonical
         preparation view에는 live와 동등하지만 ordinary release·attachment teardown·ended purge에는 `Busy`이고, 별도 pending registry나 owner
         주소를 registry에 추가하지 않는다. b2b3 제품 코드의 pending settlement/rollback caller는 0이다. focused fixture만 exact identity를
         재검증한 test-only `preparation_pending -> live` rollback으로 real-take owner를 정리하며, b3의 sole product settlement만 exact release
         receipt 검증 뒤 `preparation_pending -> releasing`을 연다. b2b3까지 normal product pump caller는 0이며 b2b0·b2b1·b2b2·b2b3 네 gate와
         umbrella `test-session-host-2c3d-c3-3b2b`가 이를 검증한다. 이후 b3·b5·b4·b6은 C3-3b event settlement/close의 별도 gate다. 세부 lifecycle·allocation 순서·seal 입력·fatal 경계의 SSOT는
         [persistent-session-host.md의 C3-3b 계약](persistent-session-host.md#c3-3b-event-settlement와-비동기-close-계약)이며 이 계획은
         그 계약을 복제하지 않는다.
      4. **C3-3b3 atomic settlement:** Attachment가 Runtime semantic type을 import하지 않는
         개념상 `settlePendingEvent(correlation,effect_request)`인 transaction을 구현하며 exact coordinator signature는
         persistent-session-host의 C3-3b3 API 표를 따른다. 모든 authority/callback/allocator preflight 뒤
         registry ordering row뿐 아니라 source EventOwner payload·allocator provenance·ConnectionLease pin·quarantine
         continuation까지 ClientSlot 소유 composite prepared event-release permit에 봉인하고, private registry-only
         subpermit은 전체 completion을 주장하지 않는다. source tombstone/pin·quarantine publication 뒤
         payload callback exact once와 registry/EventOwner/correlation/mirror source-zero를 완료한다.
         none·poison·revoke clean/cancel/partial→poison·already-terminal cleanup과 exact release를 같은 no-fail suffix로 닫는다.
         sealed PRE state에서 canonical plan을 한 번만 산출하고 POST state는 재분류하지 않으며, optional first-reason presence,
         unusable 전후, target/sibling relation, fd disposition/close-attempt와 ordered allocator cleanup을 evidence에 결속한다.
         revoke sibling은 byte-exact 보존하고 poison/terminal은 connection-owned outbound를 정산한다. deferred terminal fd는
         callback 전 detach하고 direct no-retry close를 exact 한 번 시도한다. trusted
         mismatch recovery, first-reason 보존, callback/fork/ABA/proof-loss subprocess를 포함한다.
         직렬화는 기존 final-address `RuntimeLifetimeOwner`의 새 closed `settlement` lease가 prepare·다른 settlement와 상호 배제하고,
         Pending의 단일 paired arm suffix 안에서 lease의 `prepared -> admitted`가 recoverable 경계를 닫고 즉시 Pending을
         `prepared -> settling`으로 게시한다. low-level admit의 paired arm 밖 product caller는 0이다. Attachment/Pending은 복사 가능한 binding만으로 admission하지 않고
         exact Runtime owner와 original live lease를 함께 재검증하며, `PendingEventOwner`는 그 admitted lease 아래
         `prepared -> settling`만 소유한다. b3 성공 뒤 registry/ordering blocker와 pending release receipt는
         exact once 닫히지만 prepared semantics는 유지하며, `settling -> committed_cleanup -> idle`과 제품 pump는 b4만 소유한다.
         b3는 b4 admission용 sealed closed `SettlementDisposition`만 Pending owner에 남긴다. 실제 close acquire와
         close-vs-settlement 검증은 b5가 소유한다.
         registry의 일반 live release를 느슨하게 넓히지 않고 exact pending receipt 전용
         `preparation_pending -> releasing` continuation을 추가한다. ClientSlot은 neutral closed effect plan의 preflight/no-fail commit만
         소유한다. 같은 owner의 Busy 세 번은 각각 mutation 0이고 네 번째 호출이 prepare 재실행 없이 성공하는 회귀 oracle이며
         b3 내부 retry loop는 두지 않는다. focused gate는 `test-session-host-2c3d-c3-3b3`이고 Debug·ReleaseFast와 boundary,
         callback/fork/ABA/proof-loss subprocess를 모두 통과하기 전 b3 완료를 표시하지 않는다. connection-wide terminalization은
         Client의 단일 connection-owned outbound를 target/sibling relation과 무관하게 정산하되 event sibling payload·registry owner는 보존한다.
         payload suffix는 final validation 뒤 `EventOwner tombstone -> registry/quarantine/pin begin -> correlation tombstone ->
         attachment mirror tombstone -> callback` 순서다. caller-provided final-address `PendingEventReleaseBegun`이 process-sealed
         closed phase로 각 전이를 결속하고 callback TLS도 이 typed authority만 가리킨다. callback 뒤 begun/TLS drift는 `_exit(86)`이며,
         후속 scratch-range proof 승격 때 continuation ABI를 바꾸지 않는다.
         begun을 coordinator의 일곱 번째 external scratch로 편입하고 actual payload extent가 일곱 scratch와 세 owner 모두에 대해
         exact/partial/overflow non-overlap임을 arm 전에 검증한다. completion POST transcript는 registry/quarantine/pin/callback/
         owner/correlation/mirror의 ordered closed receipt만 봉인하며 allocator 성공을 주장하지 않는다. 전체 completion publisher는
         ClientSlot 하나이고 registry 계층의 stale whole-graph naming은 제거한다.
         각 leaf/phase primitive가 actual before/after와 lifecycle/TLS invocation을 담은 typed process-sealed receipt 원문을
         반환하고, contextual validator가 composite permit identity와 3 leaf + 4 phase receipt를 직접 대조한다. quarantine은
         lock 내부 retained `-payload_len`/occupied `-1` receipt로 종결하며 unlock 뒤 empty-slot 재조회는 하지 않는다.
         phase after-zero는 magic marker 없이 actual canonical zero/TLS-cleared projection으로 계산하고, owner/correlation/mirror
         PRE identity와 begun/full pin projection까지 context에 보존해 coherent re-sealed splice를 contextual-only로 거부한다.
         ClientSlot production suffix는 이 context를 actual receipt/permit에서 항상 구성해 completion publication 직전 exact once
         검증하며, test snapshot은 검증된 pointer-free context의 복사본만 가진다.
      5. **C3-3b5 common close progress:** 기존 VTable 메서드 수를 늘리지 않고 close 계열 반환을
         `CloseProgress`, remove를 `RemoveProgress`로 바꾼다. heap-pinned `RemoteRuntime.CloseAuthority`와 backend closing receipt,
         bounded/fair `CloseSweep`, pending lifecycle readiness, handle ABA와 real AppSession synchronous in-process tab/window close parity를
         검증한다. b4가 실제 `event_pending`을 활성화하기 전에 dormant pending 상태 전수를 먼저 닫으며 actual generation
         `event_pending` close E2E는 b4가 소유한다. focused gate `test-session-host-2c3d-c3-3b5`는 최적화 모드마다
         neutral contract 6개, lifecycle readiness 6개, close authority 8개, close sweep 8개, remote backend 8개,
         close graph 2개와 AppSession parity 4개인 unique component 42개와 boundary 1개를 exact-count한다. RED 이후 GREEN에서 범주를
         합치거나 이름만 남기지 않으며, 각 테스트명은 실제로 관측하는 불변식을 한글로 기술한다. AppSession은
         stable Term membership과 request generation을 봉인한 `PendingTermClose`와 all-or-none `PendingTermCloseGraph`를
         topology mutation 전에 preflight한다. window close는 `windowShouldClose`까지 전달한 공통 `CloseProgress`로 닫기를 막고,
         graph가 전부 removed가 된 뒤에만 one-shot programmatic close latch를 발행한다. graph는 모든 target의 fallible
         AppSession reservation과 process-sealed `WindowCloseTicketReservation`을 먼저 완성한 뒤
         `publishWindowCloseAuthoritiesNoFail`의 callback·allocation·failure 0 suffix로 authority와 routing을 함께 게시한다.
         backend-global runtime admission도 host RPC·allocator·layout보다 먼저 one-shot reservation한다. CloseAuthority는
         `CloseRequestKind`와 disposition을 immutable identity seal에 봉인하고 lifecycle은 별도 checked-monotonic state seal로 관리한다.
         RemoteTermBackend의 process-sealed singleton owner는 movable 생성자 반환값을 AppSession 전역 슬롯에 설치한 직후
         exact 두 제품 호출부에서 final address를 claim하고, 단일 GUI-thread operation owner가 map relookup부터
         final-address `CloseOperationPin` publication까지 선형화한다. b5의 dormant `advanceClosePinned`는 pending semantic call 0인
         readiness projection만 반환하며 b4가 그 함수 내부 exact-one settlement adapter를 활성화한다.
      6. **C3-3b4 product semantic commit/pump:** 모든 event kind를 mutation-free prepare→settle→no-fail commit으로 전환하고
         `idle|event_pending|drained|ended` typed progress를 `RemoteTermBackend.drainRemote`까지 연결한다. settlement/observation cleanup callback
         전후 full seal, `committed_cleanup` read/mutation guard, actual product Busy→next-tick success·surface live E2E와
         `RemoteRuntime` generation semantic arm의 raw `Client` event/effect callsite 0 focused allowlist를 고정한다. focused gate
         `test-session-host-2c3d-c3-3b4`는 최적화 모드마다 중립 pump 계약 6개, Pending semantic commit 9개,
         실제 Runtime event kind 9개, pump·round-robin 8개, async close parity 4개인 unique component 36개와
         callback 뒤 proof-loss subprocess 3개, boundary 1개를 exact-count한다.
      7. **C3-3b6 app-quit/current+N-1 shutdown:** 모든 outcome의 exact target/attempt `ShutdownAttemptKey`, connection-dependent와
         post-connection terminal의 one-shot `ShutdownConnectionReceipt{connection,GUI-local lease generation,operation,inventory_attempt}`,
         pre/post `bounded_unconfirmed` evidence matrix와 closed `ShutdownAdminOutcome`,
         exact-host one-shot admin lease barrier, target당 terminate attempt 3회와 app-quit global 15초 deadline, target별 순차 connection과 ambiguous
         membership/inventory reconciliation, exact artifact/major와 list/terminate/barrier bool을 가진 frozen
         `compatibility.ShutdownProfile`을 단일 출처로 참조하는 `compatibility.Profile.shutdown_profile`,
         C3-3b5 제품 커밋 `314b7912`와 frozen `source.patch`로 만든 wire-major 1 ad-hoc signed
         universal 회귀 baseline manifest와 실제 list/terminate transcript를 사용한다. 이 baseline은 배포 사용자 호환성이나
         과거 공개 릴리스를 뜻하지 않고 ambiguous destructive request의 at-most-once 회귀만 증명한다. baseline provenance가
         없거나 불일치한 previous row는 request 0 incompatible로 닫고,
         runtime-manifest-only endpoint seal,
         N-1 ambiguous at-most-once bounded 종료,
         non-published noreturn fatal integrity, 5경계 전후 monotonic elapsed bucket과 backend-neutral fixed-64
         `ShutdownDiagnosticSink`→neutral consumer port만 쓰는 sole app-host `ShutdownDiagnosticBridge` value fan-out/reset,
         `terminalizeSharedConnectionNoDestroy`,
         per-owner cleanup→zero assertion→graph-last destroy, host EOF detach/reconnect actual socket을
         닫는다. generation GUI background blocking reader source 0도 boundary로 고정하며 생기면 fd wake-before-join 선행 gate를 요구한다.
         기존 AppKit `terminateLater` 보류 구간에서 final-address `PendingAppQuitShutdown`을 frame tick당 exact 한 target씩
         진행하고, heap-pin된 Runtime inline attempt authority가 backend-global 15초 deadline을 소비한 뒤에만
         `quit_decision=accepted`를 게시한다. detach-only target 0은 기존처럼 즉시 승인한다.
         focused gate `test-session-host-2c3d-c3-3b6`는 최적화 모드마다 중립 계약 8개, attempt/outcome 권위 10개,
         종료 manifest snapshot 2개, app-quit transaction owner 2개, current admin connector 3개,
         current-host admin 9개, N-1 profile 7개, 진단 sink/bridge 8개, AppSession app-quit 8개인 unique component 57개,
         actual-socket product replay 4개, fresh proof-loss subprocess 3개, boundary 1개를 exact-count한다.
         세부 행과 actual replay·subprocess·source-boundary의 증거 범위는 persistent-session-host의 C3-3b6 첫 RED 인벤토리를
         단일 출처로 삼는다.

      **C3-3c product socket/source-zero**는 열린 peer에서
      revoked/unknown/semantic failure roundtrip과 transport 구현·test fixture를 제외한 `src/**/*.zig` 제품 전체 generation raw `Client`
      event/effect source-zero를 닫는다. focused gate는 최적화 모드마다 actual-socket component 3개, 봉인된 unknown의 ended
      빠른 판별 회귀 1개와 source boundary 1개를 exact-count하며 Pending/EventOwner/correlation/mirror/event queue zero,
      blocker/pin/quarantine의 event 전 live attachment 기준선 복귀와 payload callback exact 1회를 동일 제품 호출 뒤 검증한다.
      RPC/decoder direct-call inventory는 2c3e가 소유한다. immediate EOF·unread RX-first와
      decoder cadence/parity는 계속 2c3e 범위다.
      **2c3e는 C1 scoped decoder bridge, C2 bound RPC family 전환, C3 actual-socket EOF/RX-first parity 순서로
      병합한다.** C1은 typed `RuntimeRequest` execute 뒤 transport-owned inline response를 final-address borrow로
      잠시 빌리고 `RpcDecodeDisposition.reusable|protocol_failure`만 돌려받는다. raw bytes·owner·receipt는 callback
      밖으로 반환하지 않으며 accepted callback 뒤 exact free와 reusable rearm 또는 protocol terminal을 완료한다.
      C2는 attach를 제외한 exact 12 family를 이 bridge로 옮겼고 `RemoteRuntime`을 decoder/ordered-input SSOT로
      유지한다. Debug·ReleaseFast에서 실제 제품 family 12개와 source boundary 1개가 이를 고정한다. C3는 immediate EOF,
      unread revoke/event 우선, response 뒤 event와 malformed/unknown cadence를 실제
      socket의 legacy/generation 공통 oracle로 닫는다. 세부 API·count·proof-loss와 source boundary는
      persistent-session-host의 2c3e 계약을 단일 출처로 따른다.
      C3 첫 RED는 EOF 3행, response 전 RX 3행, response 뒤 RX 3행, malformed/unknown-correlation 2행,
      unread revoke 대 queued TX 1행인 exact 12개 actual-socket 시나리오다.
      12행 모두 legacy/generation 공통 제품 fixture로 구현됐고 C3 source boundary가 owner와 순서를 고정한다.
   제품 gate는 RPC family별 legacy/generation decode parity와 input→RPC/revoke ordering을 포함한다. decode와 ordered input policy는
   `RemoteRuntime` 하나만 소유한다. **2c4**는
   `RuntimeConnection` union을 mode SSOT로 전환해 `RemoteRuntime.client`와 `generation_adapter` 병렬 필드를 제거하고 exact
   15-method/signature/source oracle을 닫는다. 제거할 legacy 인자·shim·split helper의 exact 목록은
      persistent-session-host의 CR3a-2c4 계약과 boundary oracle을 단일 출처로 따른다.
      2c4는 `RemoteRuntime.connection: RuntimeConnection`의 `legacy(*Client)|generation(*HostAdapter)`만 mode SSOT로 남기고
      병렬 `client`/nullable adapter 필드와 두-owner private 생성자·teardown shim을 제거한다. exact semantic facade 15개와
      legacy reviewed allowlist, generation raw Client source-zero는 persistent-session-host의 exact 목록을 그대로 사용한다.
   각 gate는 reconnect/current publish와 제품 동작 변화 0을 유지하며 마지막 2c4
   전에는 2c 전체 완료를 주장하지 않는다. **CR3a-2d는 2d1→2d2→2d3의 세 세로 gate로 닫는다.**
   2d1·2d2·2d3은 구현 완료했다. 2d1은 실제 generation batch release가
   `completed|retryable_preserved|indeterminate_or_partial`을 반환하는 owner-owned 결과와 최초 retryable 한 건의 attachment
   보존·deinit 재시도를 배선했다. 2d2는 두 번째 retryable 또는
   indeterminate에서 남은 batch/drop owner 전부를 node-owned terminal handoff receipt 하나로 이전하고
   `ClientSlot.tryDeinit`의 drain/quarantine→Client→node 순서를 닫는다. handoff state seal은
   `published→draining→consumed→terminal`을 exact generation으로 결속하고 첫 indeterminate lease는 재호출하지 않는다.
   node-final receipt와 attachment ordered lease view의
   allocation-free 2-pass preflight/commit, surviving exact-free와 no-free quarantine을 unique component 14개와 boundary 1개로
   검증한다. 2d3은 final-address `TerminalDrainContinuation`, typed callback binding과 callback-returned receipt를 추가해 allocator
   callback reentry, permit/receipt proof loss, exact surviving descriptor drain과 no-free quarantine의 제품 subprocess/source
   boundary를 닫는다. 2d3은 unique component 12개, stage별 전용 fresh-exec subprocess 3개, boundary 1개를
   Debug·ReleaseFast로 검증한다.
   각 gate의 exact API·RED 인벤토리는 persistent-session-host의 CR3a-2d 절을 단일 출처로 삼는다. 2d focused gate와 전체 검증이
   green이므로 2d는 완료됐다. CR3a-2e도 actual socket parity와 production boundary를 닫았다. HostAdapter는 RPC 전에 neutral
   binding의 node pin·빈 cleanup entry·final-address batch adapter를 하나의 준비 suffix로 예약한다. batch adapter는 이때
   `stream_id=0`인 `reserved` 상태이고, accepted attach 응답 뒤에는 allocation 없이 exact stream ID를 결속해 `live`로 게시한다.
   따라서 post-attach lease/batch mint 실패 rollback을 만들지 않는다. external-pump의 `ExternalInboxLedger`와 movable attachment
   graph는 흡수·공유하지 않는다. focused gate `test-session-host-2e`는 Debug·ReleaseFast마다 준비 계약 4개, actual socket attach
   parity 6개, rollback 4개인 unique component 14개와 boundary 1개를 exact-count하며 현재 Debug·ReleaseFast에서 green이다. 이때
   reconnect, current 교체, retired node 생성은 여전히 0이고 cleanup은 typed result만 반환하며 incident/artifact mutation은
   CR0b까지 0이다.
   CR3b는 pool membership과 독립된 connection generation의 checked-monotonic 전이·publish·overflow, main-thread
   `withCurrent` stack borrow, admission close,
   `Client.canRetire()`와 tick-end deferred retirement(동시 retired Client hard cap 2)를 닫는다. CR3c에서 `RemoteGeneration`을
   실제 slot에 연결한다.
   CR3b R1은 generation 1 current를 바꾸거나 runtime/screen을 publish하지 않는 독립 inactive 기반이므로 CR2보다 먼저
   완료했다. final-address `PreparedAdmissionClose`로 신규 Client admission을
   store-only close/cancel하고, raw `logicalClient()`를 반환하지 않는 closed-operation `withCurrent` stack borrow로 제품 호출을
   전환한다. 독립 allocator-owned RPC response만 각 facade의 기존 소유 계약으로 반환할 수 있다. R1의 reconnect/current publish·
   retired node·Client destroy·generation increment 제품 caller는 0이다. R2는 CR0b·CR1·CR2a~e가 모두 green이고
   stable shell의 `RemoteGeneration`·proxy·preallocated `UnavailableCore`·`PreparedReconnect`가 실제 제품 타입으로 존재한
   뒤에만 시작한다. R2가 그 기반을 새로 만들거나 우회하지 않고 detach+placeholder와 Client generation publish를,
   R3가 final seal/canRetire/tick-end destroy를 이어서 소유한다. R2는 다시 세 개의 닫힌 gate로 나눈다. **R2a**는
   committed admission-close와 exact current identity를 봉인한 final-address permit으로 stable proxy writer gate 안에서
   `live -> unavailable`과 Client의 detached tombstone만 callback·allocation 없이 함께 게시한다. **R2b**는 R2a 호출 전에
   준비할 caller-owned final-address cleanup handle을 도입하고, R2a commit 뒤 그 handle만 소비해 fd/attachment pending owner를
   gate 밖에서 exact once 정산한다. **R2b 완료:** 실제 fd·pending frame allocator와 external-mode deinit reservation을 keyed
   final-address handle에 봉인하고, writer gate에서는 Client owner를 callback 없이 handle로 옮긴 뒤 gate 밖에서 external cleanup,
   close/free를 exact once 수행한다. copied handle·wrong generation·Client-owned allocation alias는 mutation 0이고 abort는 admission cancel 권위를 보존한다.
   **R2c 완료:** final-address `PreparedClientReplacement`가 새 Client node를 완성하고 managed incident binding을 새 주소와
   generation으로 재봉인한 뒤, registry row와 checked-monotonic connection generation/current pointer를 같은 no-fail suffix로
   게시한다. prepare는 usable한 live fd를 요구하며, 새 current에서 발급하는 attachment reservation도 그 connection generation에 exact 결속한다.
   copied/hostile binding은 mutation 전에 거부하고 abort는 old registry admission을 복구하며, published old node는
   detached retired inventory에 보존한다. R2a는 cleanup callback, 새 Client
   allocation/current 교체, retired Client destroy를 소유하지 않고, R2b는 새 generation publication을 소유하지 않으며,
   R2c는 old node destroy를 소유하지 않는다. CR3c는 R2/R3 결과를 CR2의 실제 `RemoteGeneration` slot에
   연결하며 stable shell 자체를 처음 도입하는 단계가 아니다. CR3c는 두 닫힌 gate로 진행한다.
   **CR3c1**은 prepared admission close를 검증한 상태에서 old `RemoteGeneration` attachment를 먼저 terminalize하고 같은
   no-fail suffix로 admission close를 게시한다. 그래야 old transport/event 권위를 반납한 뒤 R2a/R2b/R2c와 새 attachment
   준비가 진행될 수 있다. 이어 같은 `HostAdapter`와 exact old/next connection generation에 결속된 R2c published receipt와
   fully prepared `PreparedReconnect`를 stable screen writer gate에서 결속한다.
   shell generation과 connection generation은 별도 축이다. R2a가 `old shell + 1`에 게시한 unavailable placeholder를
   같은 shell generation의 live candidate로 승격하고, `RemoteGeneration.connection_generation`은 Client의
   `old connection + 1`과 exact 일치시킨다. candidate `RemoteGeneration.connection`이 다른 adapter이거나 두 connection
   generation이 어긋나면 screen과 generation slot은 mutation 0이며 이미 게시된 Client current/retired graph도 그대로다.
   Client publication 뒤 전용 forward-recovery prepare가 실패하면 terminal old attachment, unavailable placeholder와 새 Client를 보존해 같은 generation으로
   재시도하는 forward-recovery 상태가 된다. 이 단계는 old `RemoteGeneration`과 old Client를 각각 retiring inventory에
   보존하며 어느 쪽도 파괴하지 않는다. **CR3c2**는 exact 같은 retiring generation을 먼저
   `RemoteGeneration` attachment/observation owner에서 정산하고, 그 정산으로 readiness가 열린 oldest retired Client를 같은
   tick-end owner turn에서 final-address reclaim 권위로 회수한다. 둘 중 한쪽만 다른 generation을 가리키거나 준비된 권위가
   drift하면 destroy 0이며, 정상 suffix의 순서는 RemoteGeneration teardown 뒤 Client node destroy다. focused gate
   `test-session-host-cr3c-c2`는 이 두 final-address receipt를 PID/process nonce와 owner·slot·node incarnation으로 묶고,
   terminalized old attachment만 no-fail suffix에 admit한다. 정상·hostile 2행과 source boundary 1행을 Debug·ReleaseFast에서
   실행한다. 따라서 CR3c의 구조적 integration은 완료됐고, 실제 socket reconnect는 CR4다.
   **R3**는 retired inventory를 exact 2-slot bounded owner로 확장하고, pure `Client.canRetireFromGenerationNode` projection과
   final-address `PreparedRetiredClientReclaim` seal로 oldest generation을 고정한다. tick-end no-fail suffix만 Client graph와
   node-local registries/accounting을 정산하고 allocator destroy한 뒤 inventory를 compact한다. cap 2 상태의 세 번째 prepare,
   copied/stale handle, readiness 또는 complete-node digest drift는 destroy/current mutation 0이다. R3의 제품 caller는 CR3c 전까지 0이다.
6. **CR4 — 단일 host 실제 reconnect:** 세 닫힌 gate로 진행한다. **CR4a**는 먼저 CR3c의 forward-recovery 경계
   (old attachment terminal, unavailable shell, fresh Client replacement 게시) 뒤 같은 `HostAdapter`에서 observer attach와
   final-address candidate initial snapshot을 검증하는 prerequisite를 닫는다. 이어 screen wire prerequisite가 initial attach snapshot
   sequence 0, 같은 stream의 resync/fallback snapshot과 delta는 직전 committed frontier exact +1이며 queue-admission 뒤에만
   commit됨을 고정한다. 이 sequence만으로 local socket idle을 caught-up으로
   판정하지 않는다. host가 같은 stream의 coalesced output과 immutable target frontier를 한 owner turn에 발행하는 catch-up barrier를
   통과한 뒤에만 staged receipt를 만들 수 있다. 그 위에서 실제 `connectExistingHost` issuer가 fresh Client를
   replacement 경계로 넘기고, snapshot을 base로 하는 bounded contiguous delta까지 조립한 뒤 immutable staged receipt를
   게시한다. replacement 게시 전 실패는 old graph mutation 0이다. 게시 뒤 typed reject는 unavailable shell과 usable Client
   generation을 보존한 채 candidate 권위만 정산하고, EOF/불확실 transport 실패는 동일 node·generation을 보존하되 Client를
   fail-close하여 다음 replacement 시도로 넘긴다. **CR4b**는 그 receipt 아래
   mutation lease/seal을 닫고 fresh `controller.status`와 generation-CAS `controller.takeover`를 exact once 실행한다. observer
   conflict를 자동 takeover하지 않으며 takeover write가 시작된 뒤 reply를 잃으면 local authority를 발행하거나 old writable을
   복원하지 않는다. **CR4c**는 proven controller candidate를 CR3c의 Client/RemoteGeneration publication에 연결하고 forced first
   resize와 input을 새 generation에서만 연 뒤 retiring owner를 ordered reclaim한다. 세 gate 모두 실제 socket fixture를 사용하며
   CR4a만으로 takeover나 사용자 가시 reconnect 완료를 주장하지 않는다.
   barrier 구현은 dependency-neutral pointer-free contract와 두 제품 prerequisite로 나눈다. 계약은 host issuer가 소비하되 host
   process/subscription identity와 GUI-local staged identity를 섞지 않는다. 먼저 host issuer는 negotiated capability, correlated pending row,
   core-lock projection receipt와 screen frames+barrier의 단일 queue transaction을 닫는다. 현재 host frontier slice는
   projection 발급, barrier-last 실제 queue admission, admission 뒤 base/frontier/pending 원자 commit과 copied/process/Client-address/ConnectionKey/thread drift
   mutation 0, 실제 global queue-pressure의 prefix/base/frontier/pending mutation 0, no-change barrier-only exact 1과 preparation allocation fail-index를 제품 경로에서 닫았다. client consumer의 첫 slice는
   negotiated capability를 `Client` hello provenance에 저장하고, RPC/screen과 섞인 fixed barrier를 기존 multi-stream demux 아래 bounded connection-local inbox에 보존하며 하나의 absolute deadline으로 exact identity를 소비한다. sibling screen/barrier는 canonical inbox에 남고 capability·identity drift는 receipt 전에 connection을 fail-close한다. 이어지는 slice가
   일반 multi-runtime inbox와 구분되는 catch-up 전용 상한을 batch 64개, encoded 16 MiB,
   decoded cell 1,048,576개로 고정하고 마지막 초과 batch를 apply 전에 거부한다.
   `GenerationAttachment`가 이 accounting과 실제 assembler frontier를 소유하며 final-address staged receipt를 닫는다.
   host issuer만 green인 상태는 caught-up 또는 CR4a 완료가 아니다. barrier target은 server가 subscription을 재조회하거나
   encoded screen record를 파싱해 만들지 않고 `RuntimeManager`의 immutable projection receipt만 전달한다.
   actual issuer는 `RemoteTermBackend`가 소유하는 host별 `HostReconnectJob`으로 연결한다. AppSession은 base-cache path와
   owner-turn capability만 전달하고 raw Client/receipt를 보존하지 않는다. job은 host당 max 1, actual
   `connectExistingHostUntil` exact 1, same-adapter Client replacement exact 1을 소유하며 하나의 absolute deadline을
   connect/hello부터 staged receipt까지 연장 없이 공유한다. 단일-runtime actual socket 제품 행도 이 job을 우회하지 않는다.
   현재 제품 행은 actual manifest/socket Client를 job final address에 보존하고 unavailable shell 전환과 same-adapter replacement
   publication exact 1 뒤 observer candidate와 staged receipt까지 연결했다. connect에서 발급한 같은 absolute deadline은
   attach/snapshot/delta/barrier까지 재생성하지 않으며, 만료는 candidate 전 sealed failure와 새 Client fail-close로 닫는다.
   typed reject job은 exact request nonce와 usable Client projection을 seal하고, connection failure job은 exact poison reason과
   현재 published Client의 fd/unusable/first-reason terminal projection을 다시 대조하므로 두 결과나 실패 provenance를 서로 세탁할 수 없다.
   replacement node OOM은 rollback하지 않고 sealed forward-failed state로 남긴다. allocator fail-index는 manifest/connect,
   replacement preflight/node, observer attach/snapshot, delta apply와 staged seal의 첫 성공+1까지
   순회하고 pre-publication은 old graph mutation 0, post-publication은 unavailable shell과 node/generation 보존 및 Client
   fail-close, candidate/receipt/ledger final zero를 고정한다. 이 행까지 green이면 CR4a를 완료로 세지만 controller status/takeover,
   RemoteGeneration publication, forced first resize와 input은 CR4b·CR4c 전까지 0이다.
   **CR4b는 CR4a가 이미 넘은 Client publication 경계를 되돌리지 않는다.** 같은 adapter의 replacement를 게시하면서 old
   attachment를 retirement하고 stable shell을 unavailable generation으로 전진시켰으므로, CR4b의 pre-takeover 실패도
   이 제품 경로에서는 old writable을 복원하지 않는다. CR4a publication은 mutation owner를 old generation에 그대로
   두어 placeholder generation의 새 input과 queue pump를 모두 거부하고 기존 queue를 보존한다. exact staged receipt 뒤
   runtime queue를 mutation seal로 닫은 다음 같은 CR4a absolute
   deadline 아래 `controller.status`와 generation-CAS `controller.takeover`를 각각 최대 한 번 실행한다. exact takeover
   response와 buffered revoke 부재가 함께 증명된 경우만 `new_controller_evidenced`로 봉인하되 local attachment와 cleanup
   binding은 CR4c publication 전까지 observer quarantine을 유지한다. request byte가 일부라도 송신된 뒤
   response를 잃으면 `takeover_sent_unknown`, status가 다른 controller를 증명하거나 CAS가 거부되면
   `authority_conflict`로 봉인한다. 뒤의 두 결과는 자동 takeover 재시도·old input 재개·candidate publication이 모두 0이고
   CR4c가 소비할 frozen-unavailable ledger만 남긴다. observer conflict는 새 연결 여부를 식별할 transfer receipt가 없으므로
   status를 다시 읽어 자기 요청 성공으로 추정하지 않는다.
   **CR4c는 `controller_evidenced` job만 소비한다.** 먼저 attachment-owned final-address publication
   authority가 cleanup binding, transport binding과 candidate `RemoteAttachment.State`를 같은
   observer identity에서 같은 controller generation으로 승격할 수 있는지 allocation 없이 preflight한다.
   이 승격 뒤에도 stable shell과 mutation owner는 unavailable/sealed 상태를 유지한다. candidate 전용
   forced-first-resize가 현재 local `Surface` viewport를 같은 stream/controller generation으로 host에 적용하고
   strict response를 확인한 뒤에만 CR3c `publishAfterClientReplacement`를 호출한다. 마지막 suffix는
   RemoteGeneration+stable screen publication, mutation owner의 새 shell generation/open 전환, staged/controller
   evidence consume, retiring RemoteGeneration-first/Client-second ordered reclaim과 host job 정산을 한 owner turn에서
   수행한다. 따라서 공개 input/resize는 publication 전 0이고, publication 뒤에는 새 generation에서만 열린다.
   role 승격 또는 forced resize가 실패하면 candidate와 새 Client를 fail-close하고 unavailable shell을 유지하며,
   old writable 복원·candidate publication·input 재생은 0이다. resize 성공 뒤 publication suffix의 authority drift는
   복구 가능한 오류가 아니라 common proof-loss fail-stop이다. 현재 C2 actual manifest/socket success는 forced resize,
   RemoteGeneration+screen publication, reconnect executor와 mutation epoch의 동일 shell generation 전진, 새 input,
   remote-first/client-second reclaim을 실행하고, expired resize는 sealed mutation을 보존한 forward-failed job으로 닫는다.
   actual socket leaf는 stale/wrong-size/EOF/OOM provenance를 분리한다. publication suffix의 controller-generation drift는
   actual host job subprocess에서 recoverable return 없이 common proof-loss exit 86으로 끝나며, parent가 child process group과
   manifest/socket artifact를 유계 정산한다. 이 증거로 단일-runtime real-socket CR4c를 닫되 실제 AppKit 수동 경로는 CR6,
   다중 runtime/Window owner 확장은 CR5가 소유한다.
7. **CR5 — 멀티윈도우·다중 runtime:** CR2e-e3c의 reconnect-only `SessionHostCoordinator` shell을 host job,
   runtime별 authority ledger와 upgrade gate로 확장하고,
   부분 commit forward resolution, Window move/close 경쟁을 자동 검증한다.
   첫 CR5a prerequisite는 CR2e reducer의 runtime/local/mutation enum을 재사용하는 canonical runtime-set 값 계약과 terminal
   summary를 고정한다. 이 단계의 제품 caller는 0이며, 다음 제품 slice가 같은 계약을 `RemoteTermBackend.HostReconnectJob`의
   final-address runtime-set owner에 결속한다. 별도 model enum이나 AppSession-owned ledger를 만들지 않는다.
   CR5b-1은 actual connect/manifest I/O 전에 backend의 같은 `{host_id,pool_membership_generation}` runtime을 정렬된 exact
   목록으로 캡처하고, job final address·process identity·backend generation·connection generation과 job 내부 고정 backing/digest를
   함께 봉인한다. host당 active job 하나가 최대 4,096행을 inline 소유하고 전체 job 크기는 512 KiB 이하로 제한한다.
   connect 실패·OOM·빈 집합은 runtime map과 adapter를 바꾸지 않고 목록 owner를 회수하며, copied job,
   runtime add/remove/address·generation·runtime-id drift는 후속 Client publication 전에 거부한다. 이 단계는 목록의 각 행을
   아직 takeover하거나 terminal summary로 닫지 않는다. CR5b-2는 이 동일 owner를 바꾸지 않고 다음 세 단계로 닫는다.
   CR5b-2a는 모든 captured runtime의 old attachment retirement와 unavailable publication 권위를 먼저 final-address job에
   준비하며, k번째 preflight 실패에서 앞선 runtime·공유 Client·screen·ledger를 하나도 바꾸지 않는다. CR5b-2b는 모든
   prepared runtime을 no-fail suffix로 unavailable에 전환한 뒤 공유 old Client를 한 번만 정산하고 같은 adapter에 replacement를
   exact 한 번 게시한다. replacement node backing과 identity는 old graph가 live인 준비 구간에서 final-address reserved receipt로
   먼저 확보하고, commit suffix 안에서는 allocation·identity 발급·callback 없이 전 runtime unavailable → shared old Client
   cleanup → fresh Client move → replacement publish만 수행한다. CR5b-2c는 그 published replacement receipt를 각 행의 CR4 observer/takeover/publication transaction이
   순서대로 재검증해 소비하고, usable shared Client 아래 k번째 `authority_conflict`를 앞선 성공은 `published_new`, 실패/잔여 행은
   `frozen_unavailable` 또는 `ended`로 forward-resolve한 terminal summary로 닫는다. host job은 inline runtime cursor와 한 행짜리
   final-address CR4 scratch를 재사용하며, 각 성공 publication 뒤 row commit→scratch tombstone→cursor advance를 no-fail 순서로
   수행한다. 마지막 row의 terminal summary를 봉인하기 전에는 job과 shared replacement receipt를 파기하지 않는다. 어느 단계도 runtime마다 Client replacement를
   반복하거나 첫 runtime 정산 중 sibling attachment가 참조하는 shared Client를 파괴하지 않는다. shared Client 자체를
   fail-close하는 candidate/resize/transport failure는 CR5c가 앞선 published 행의 controller provenance를 유지한 채 전 행을
   `frozen_unavailable/closed`로 전환하고, 모든 published retirement prepare가 성공한 뒤에만 no-fail unavailable suffix를
   실행한다. CR5c summary는 `published_new=0`과 `retry_reserved=total`을 봉인하고 terminal runtime/retired Client/replacement
   receipt를 retry job에 유지한다. 이어지는 CR5 Window gate는 이 terminal summary를 소비해 2 Window move/close,
   stale Take Control/close action, `termination_unconfirmed→abandoned_to_inventory` 경쟁을 닫는다.
   CR5d-1은 그 Window gate의 첫 제품 prerequisite다. backend가 보존한 exact terminal summary와 runtime row를
   재검증한 뒤, 두 Window의 현재 binding projection을 final-address owner의 active transaction 하나에 정렬·봉인한다. owner는
   active/spent action generation을 보존해 같은 gesture의 두 번째 transaction 발급도 거부한다. move/close
   action은 `{window address, AppSession generation, graph generation, runtime handle/generation, surface id,
   action generation, expiry}` 전체가 일치할 때만 한 번 admit하고, copied/moved/replayed transaction과 Window 이동,
   close, TTL exact expiry, runtime/job generation drift는 topology·binding·wire mutation 0으로 거부한다. 이 단계는
   AppSession topology를 아직 바꾸지 않으며 CR5d-2가 같은 transaction을 실제 2 Window move/close와
   `termination_unconfirmed→abandoned_to_inventory`에 연결한다.
   CR5d-2는 별도의 Window 수술을 만들지 않는다. 두 AppSession의 현재 Term binding을 backend terminal job의
   canonical runtime row와 대조해 CR5d-1 transaction을 준비한다. 같은 Window의 다른 host Term은 해당 host job의
   canonical row에 없으므로 transaction에서 제외하고 그대로 보존한다. 기존 `moveWorkspaceToSession`이 어느 Window의
   graph generation을 전진시키면 그 전에 준비된 Take Control/close action을 topology·wire mutation 0으로 stale 처리한다.
   close action은 transaction과 backend의 typed `abandon_to_inventory` projection을 모두 preflight한 뒤 transaction을
   먼저 one-shot consume하고, reducer의 `termination_unconfirmed→abandoned_to_inventory`를 게시한 다음 해당 Window의
   로컬 Term을 terminate 없이 detach·제거한다. transaction consume과 reducer publication까지는 allocation/callback 없는
   authority suffix이며, 그 뒤 기존 AppSession close chokepoint의 cleanup callback은 forward-only로 실행돼 옛 Window graph를
   복원하거나 host runtime을 terminate하지 않는다. action expiry exact/+1, Window 이동/닫기, runtime row/job drift,
   double-click/replay는 reducer·topology·takeover/terminate wire mutation 0이어야 한다.
8. **CR6 — 제품 gate:** CR6c에서 actual daemon/manifest → 일반 launch discovery → primary recovery row → 실제
   AppKit `NSEvent` click → remote Term/CAMetalLayer readback을 먼저 닫는다. 다음 CR6d는 실제 macOS IME와 OS
   clipboard의 reconnect 연속성·historical replay 0을 닫는다. CR6d는 복구된 실제 `MaruMetalTerminalView`의
   `NSTextInputContext`를 2-Set Korean input source에 결속한 뒤 Accessibility event-post 권한을 사전 확인하고 HID event tap의 물리 key-code `CGEvent`로 `한글`을 조합·확정하고,
   `NSPasteboard.general`에 넣은 구분 가능한 UTF-8 한 줄을 실제 Cmd+V `NSEvent`로 붙인다. `/bin/cat` runtime의
   제품 screen projection에는 IME와 clipboard marker가 각각 exact 1이어야 하며, 복구 전에 host가 한 번 출력한
   historical marker도 exact 1을 유지해야 한다. 복구 전 OSC 52 write는 새 AppKit process의 pasteboard sentinel을
   바꾸면 안 되고, 새 Cmd+V 직전의 pasteboard 값만 실제 PTY 입력이 된다. 실제 macOS IME가 합성 물리 키를 처리하도록
   opt-in smoke에서만 시스템 전역 source를 한국어 2벌식으로 전환한다. 권한이 없으면 전환 전 `accessibility-unavailable`로 닫는다. original/selected ID를 전환 전 atomic record로
   남기고 정상·실패·종료에서 복원하며, 앱 강제 종료 뒤에는 부모의 별도 restore helper가 같은 record를 소비한다.
   복원은 current가 selected와 같을 때만 original을 다시 선택해 사용자 중간 변경을 덮지 않는다. view-local
   `NSTextInputContext`, marked text와 first-responder state도 종료 전에 정산하고 current source exact original과 restore
   record 소멸을 executable oracle로 고정한다. CR6e는 세 gate로 나눈다. **CR6e-a1 transport baseline**은 제품 deadline-aware
   exact-host issuer에 실제 Unix peer의 accept 후 hello 무응답과 transient connect backoff를 주입하고, absolute deadline,
   attempt/wait 수, elapsed, fd/RSS를 strict-schema raw artifact로 남긴다. **CR6e-a2 recovery baseline**은 반복 CR6c
   recovery의 launch→row→click→remote-visible→Quit 구간과 runtime/authority/cleanup을 별도 strict-schema raw artifact로
   남긴다. 두 baseline 단계는 수치 상한이나 CR6 완료를 주장하지 않는다. **CR6e-b budget/soak**는 같은 runner에서 얻은 baseline을
   `performance-budget.md`에 하드 상한과 하드웨어/OS 조건으로 확정한 뒤 20 batch(transport 40행·actual-AppKit recovery 100행) 반복에서 stalled peer의 deadline 초과 0,
   backoff 과잉 attempt 0, runtime/controller/observer/fd leak 0, RSS·CPU·recovery latency 예산 준수를 자동 판정한다.
   CR6c·CR6d·CR6e-a1·CR6e-a2·CR6e-b의 제품 증거를 모두 통과한 뒤에만 자동 reconnect를 제품 설정에 연결한다. 후속
   **CR6e-c**는 c1 app-global bounded job/completion owner → c2 thread/queue 비소유 blocking worker entrypoint의
   deadline-aware exact-host connect/hello와 move-only candidate completion →
   c3a main owner의 128-bit incident identity·pool/connection generation·bound admission·deadline 재검증과 이미 연결된
   candidate의 비차단 CR5 job adoption → c3b1 app-global final-address physical worker와 cancellation wake/join →
   c3b2a admission-loss 없는 main-owner 예약·exact-identity coalesce·worker frame 왕복 →
   c3b2b bound admission 제품 정산과 closed-state CR5 host transaction publication →
   c3c actual AppKit disconnect→자동복구 E2E
   순서로 닫는다. c2의 thread spawn과 AppSession caller는 0이고, c3 app-global worker가 thread 수·cancellation wake·Quit
   join을 소유한다. frame owner는 connect/hello/backoff/join을 실행하지 않고, worker는 raw runtime/adapter pointer를
   보존하거나 제품 generation을 게시하지 않는다. keep-alive opt-in 밖과 G3 default migration은 이 배선으로 바뀌지 않는다.
   현재 c3b2b까지 final-address coordinator의 admission 선예약·철회·coalesce, stored admission/budget identity의
   terminal 정산, actual daemon candidate의 CR5 adoption과 closed-state driver를 구현했다. c3b2b는 (1) stored admission/budget identity의
   all-runtime preflight와 no-fail release, (2) terminal failed logical completion 정산과 `retry_later` 동일 c1 snapshot 재큐잉,
   (3) connected candidate의 CR5 job move 뒤 logical 정산, (4) frame당 CR5 closed-state 한 단계 driver 순서로 TDD한다.
   CR5c `host_failure_complete` retry job은 c3b2b finalizer가 파기하지 않는다. 남은 AppSession caller와 actual disconnect E2E는
   이 네 계약과 actual daemon coordinator E2E가 green인 뒤 c3c에서만 연다.
   **CR6f — output wake와 입력 echo 예산:** daemon-global nonblocking self-pipe를 `RuntimeManager`가 소유하고, 각
   `PtyEventQueue`는 성공한 output/terminal publication 뒤 byte wake만 수행한다. `poll_owner.Owner`가 read end를 유일하게
   poll/drain하고 같은 owner turn에서 runtime event drain과 producer sweep을 시작한다. reader thread가 socket, `Connection`,
   subscription 또는 `collectDeltas`를 직접 호출하는 경로는 0이다. PTY output의 정상 push는 20ms cadence를 조건으로 사용하지
   않는다. self-pipe 포화는 이미 resident한 wake와 coalesce하고 reader를 block하지
   않으며, EOF/broken read end는 host owner를 fail-close한다. fresh spawn과 same-PID restore가 각각 새 process-local pipe와
   notifier를 만들고 handoff inventory는 notifier/fd를 직렬화하지 않는다. 실제 forkpty `/bin/cat` input→valid delta artifact가
   구조적 20ms floor 제거와 hard latency cap, 250ms idle wake/CPU, active notifier/write/drain, fd·child cleanup을 증명한다.
   실제 pipe 포화·broken read end와 restore graph의 새 notifier는 process/unit gate가 맡고, 장시간 idle은 운영 soak 범위다.

   **P3-e4d-1 metadata isolation·reattach gate:** 별도 실제 daemon, 하나의 generation-backed GUI
   connection, 두 forkpty runtime으로 metadata event의 stream/runtime 격리와 detach 중 변경된
   full-state가 같은 persistent handle의 다음 attach 최초 observation이 되는지 검증한다. harness-owned
   trigger를 child가 소비한 뒤 screen marker와 metadata change token이 모두 전진한 것을 본 후에만
   reattach하며, reattach 후 추가 event pump가 없어도 attach response의 full-state가 최신이어야 한다.
   A 변경 전·후 B의 revision·owned string·foreground projection은 byte-for-byte 불변이고,
   copied/stale/foreign stream을 수용하는 test seam은 만들지 않는다. Debug·ReleaseFast focused gate와
   source-boundary test가 실제 제품 type·wire만 쓰는지 고정한다.

   **P3-e4d-2a current-host foreground·consumer parity gate:** e4d-1과 같은 별도 실제 daemon과
   generation-backed GUI connection에서 controlled `claude`·`codex` foreground process를 차례로 실행해
   host PTY sampler→revisioned metadata→`RemoteRuntime` observation→AppSession consumer의 한 제품 흐름을
   검증한다. 임시 local Git repository의 OSC 7 cwd는 기존 `termGitBranch`에서 branch로 파생되고,
   foreground process는 기존 `pollAgentKinds`에서 exact provider로 분류되며, OSC 5379 destination은
   파일 drop 직전 `refreshObservation` barrier와 기존 SSH upload route에서 remote 분기로 소비돼야 한다.
   provider 전환과 cwd/SSH 제거도 stale 캐시를 남기지 않고 `codex→none`, branch/destination `present→absent`로
   수렴해야 한다. 테스트는 제품 backend/vtable과 실제 filesystem·process observation만 쓰고 raw cwd,
   destination, argv, file payload를 artifact나 실패 로그에 쓰지 않는다. Debug·ReleaseFast focused gate와
   source-boundary test가 direct field 주입, test-only wire·consumer seam, fake upload 성공을 금지한다.

   **P3-e4d-2b legacy-binary compatibility gate:** historical source commit과 봉인된 patch로 빌드해 별도
   프로세스로 실행하는 capability 없는 N-1 protocol fixture executable에 current GUI가
   접속하는 별도 packaging gate다. current source를 legacy mode로 분기하거나 test-only capability toggle을
   열지 않고, 고정된 signed/ad-hoc N-1 artifact의 hello·attach 결과로 metadata unavailable degradation과
   cwd·agent·SSH 소비자의 fail-closed 동작을 검증한다. artifact·source patch digest, universal architecture와
   ad-hoc signature를 먼저 검증한다. 이는 release/notarization provenance를 주장하는 출하 artifact가 아니라
   compatibility test artifact다. artifact가 만든 exact manifest/endpoint를 현재 `connectExistingHost`→
   generation `HostAdapter`→attach-only `RemoteTermBackend`→`term_ops.createTerm` 제품 복원 흐름으로 소비한다.
   negotiated transport profile은 metadata `.unsupported`, AppSession observation은 `.unavailable`이고
   cwd/process/SSH owned field가 비어 있어야 하며, 기존
   `termGitBranch`·`pollAgentKinds`·`remoteUploadContext`는 각각 null·none·null로 닫혀야 한다. raw cwd,
   destination, argv 또는 file payload는 artifact/실패 log에 남기지 않는다. 2a와 2b의 Debug·ReleaseFast 제품 gate와
   source boundary가 모두 green이어서 P3-e4d runtime metadata parity 자동 gate를 완료로 선언한다. notarized 과거
   release provenance와 실제 AppKit 입력기/픽셀 검증은 이 선언의 범위가 아니다.

   **P3-e4d-3 actual host-backed SSH upload product gate(완료):** harness-owned localhost `sshd`와 실제
   OpenSSH ControlMaster, 별도 daemon의 host-owned PTY를 사용한다. 실제 OSC 5379 뒤 AppSession 공개 file drop/image
   paste가 managed-generation freshness barrier를 지나 원격 bytes와 동작 시작 surface의 경로를 함께 증명한다. 닫힌
   localhost port의 실제 worker 실패는 파일·이미지별 notice로 올라오고 terminal input/local fallback은 0이다. source
   boundary는 observation 주입, private action/upload drain과 fake ssh 성공을 금지한다.

   **P3-e4d-4 reconnect destination·ControlMaster isolation gate(완료):** 서로 다른 destination을 가진 실제 host
   runtime A/B를 detach한 뒤 AppSession의 공개 recovered-runtime adoption으로 재접속한다. 새 OSC 없이 attach 초기
   full-state가 각 destination을 복원하고 공개 file/image upload가 각 ControlMaster와 원래 surface를 선택해야 한다.
   A/B 실제 성공 뒤 A master만 종료하고 harness key를 제거해 B의 기존 socket 성공과 A의 실제 인증 실패를 동시에
   단언한다. control path inequality만으로 격리를 주장하지 않으며 remote byte equality, failure notice, terminal input/local
   fallback 0을 함께 요구한다. harness는 임시 manifest/socket/key/control path/remote bytes를 exact 회수하고 민감한
   destination·payload artifact를 남기지 않는다.

   **P4 E3 event-driven producer (E3a·E3b 구현 완료):** runtime별 checked screen token과 output wake가 unchanged
   projector를 닫고, runtime-owned 100ms metadata sampler가 lock-free source generation을 token으로 접어 변경 runtime의
   stream만 producer로 연다. initial/fresh/resync admission과 same-PID restore가 delivery base를 재구성하며, exhaustion은
   target runtime만 fail-close한다. Debug·ReleaseFast gate와 ReleaseFast artifact v4는 actual `/bin/cat` runtime 1·10·100의
   steady idle screen/metadata producer·materialization·core-lock exact 0과 100-runtime 단일 source 변경의 target-only work를
   고정한다. 세부 계약과 수치는 persistent-session-host.md와 performance-budget.md가 소유한다.

   **P4 parity micro-gate (완료):** P4의 C4→E1→E2 다음 순서로, host-backed DECSET 1003
   motion과 selection autoscroll을 독립 제품 gate로 승격한다. `test-session-host-input-parity`는 Debug·ReleaseFast에서
   AppSession 관측 게이트, 실제 forkpty host reader의 xterm SGR motion byte, 실제 host selection scroll-and-extend 뒤
   authoritative copy와 source boundary를 함께 실행한다. 같은 셀/비-any/override/chrome 억제는 제품형 테스트로,
   capability 없는 구 host의 fail-closed degradation은 source boundary로 고정했다.

   **P4 N1 bounded notification journal (구현 완료):** parity micro-gate 다음 순서로 host-owned pure
   journal을 독립 gate로 세운다. stable host/runtime/event identity, dual GUI/OS delivery bit, checked-monotonic ID,
   event/resident/field cap, prepare-before-evict와 allocator fail-index rollback을 고정한다.

   **P4 N2a product admission·handoff (구현 완료):** `RuntimeManager` owner tick이 실제 PTY OSC slot을 UTF-8/control-sequence
   sanitizer 뒤 N1 journal에 generation-CAS로 옮기고 기존 `runtime.notification` GUI consume을 journal 위로 이관한다.
   same-PID outer optional handoff는 row/ID/delivery bit/drop counter를 보존하고 capture 뒤 mutation을 semantic digest로
   fail-close한다. config/label control과 daemon-internal macOS sink는 N2b, cold-launch route는 N3가 소유한다.

   **P4 N2b notification delivery:** N2a 다음을 세 owner slice로 닫는다. N2b1은 additive
   `notification_delivery_v1` capability 아래 runtime 생성 시의 완전한 notification metadata snapshot과 exact controller
   `config.update`를 제품 wire에 연결한다. update는 `{stream_id, expected_controller_generation, config_generation,
   notifications_osc, display_label}` 다섯 필드를 정확히 요구하며, 같은 controller generation에서는
   `config_generation`이 strictly increasing이어야 한다. controller generation이 바뀐 경우에만 새 controller의 nonzero
   generation 축으로 교체한다. observer·legacy·미지 필드·stale controller·cross-runtime 요청은 allocator/core/journal
   mutation 0이다. spawn authority의 초기 snapshot은 PTY reader publication 전에 설치하고, snapshot이 없거나 capability가
   없으면 `notifications_osc=false`와 runtime-ID label fallback으로 fail-closed한다. N2b1의 새 GUI
   `runtime.notification` 요청은 capability 확인 뒤 exact `{stream_id,delivery_version:1}`로 opt-in하고 응답은 exact
   `{event:null|{hid,rid,eid,occurred_at_ns,title,body,display_label}}`이다. 기존 `{stream_id}` 또는 `runtime_id` 요청에는
   `{title,body}` adapter를 유지한다. 두 경로 모두 response control queue admission 뒤 같은 stable key의
   `.gui` bit만 ack한다. **N2b1 구현 완료:** GUI frame owner가 기존 `notificationLocation` SSOT로 현재
   `workspace › term` binding label을 동기화하고, restore attach는 map publication 전에 현재 config 완전본과 runtime-ID
   fallback을 재설치한다. typed HostAdapter canonical encoder도 협상 capability에 따라 exact `delivery_version:1`을
   주입한다. multi-runtime config 전파/보상 중 실패한 entry는 미적용으로 남겨 frame binding 완전본이 재수렴시킨다. 실제
   daemon/socket/PTY detach→재attach gate가 이 제품 경로를 Debug·ReleaseFast에서 고정한다.

   **N2b2 구현 완료:** daemon owner 안의 bounded OS delivery machine과 macOS adapter를 연결한다. adapter 입력은 borrowed presentation
   text와 typed `{hid,rid,eid}`뿐이며 MRSH client나 AppSession을 만들지 않는다. `accepted` 뒤에만 `.os` bit를 ack하고,
   `denied`/bundle·entitlement 부재는 row를 재요청하지 않는 degraded terminal 결과로 기록하며, transient 실패는 같은 key를
   250ms에서 시작해 최대 8초인 지수 backoff로 최대 6회 재시도한다. framework callback이 10초 동안 돌아오지 않으면 process-local
   inflight slot도 함께 비워 다음 backoff가 실제 새 request를 만들며, retry state는 row 하나만 final-address로 pin하고 다른
   runtime의 admission·GUI delivery를 막지 않는다. primary backoff에서 async pending이 된 sibling은 exact secondary inflight
   owner가 정산할 때까지 adapter의 단일 slot을 독점한다. primary와 secondary inflight owner는 제출 당시 전체 typed route를
   보존해 journal 축출이나 delivery-bit 선행 정산에서도 exact request를 expire하고 slot을 회수한다. 자동 gate는 product type과
   bare-binary bundle fail-close까지 증명한다. 실제
   Notification Center 게시는 provisioned signed runner가 없어 미완료 제품 gate로 남는다. **N2b3 구현 완료:** host-backed GUI history와 Swift OS request identifier/userInfo에
   같은 stable key를 투영해 daemon/GUI 동시 제출도 Notification Center에서 같은 request를 replace하도록 한다. host-backed
   history row는 optional typed `{hid,rid,eid}`를 owned scalar로 보존하고 occurrence timestamp와 발화 시점 display label을
   host snapshot에서 사용한다. GUI→Swift ABI는 route 유무와 세 scalar를 별도 out field로 전달하고, Swift identifier는 daemon과
   같은 `maru-{hid:032x}-{rid:032x}-{eid}` canonical 형식이며 userInfo에도 문자열 `hid`/`rid`와 숫자 `eid`를 싣는다.
   in-process·hook·앱 자체 알림은 route가 없으므로 기존 UUID identifier와 window-token/surface route를 유지한다. 표시 문자열을
   stable key로 역파싱하지 않으며 GUI는 `.os` bit를 내리지 않는다. N3는 그 route의 response를 cold-launch exact attach로
   소비하는 별도 slice다. Debug·ReleaseFast 집중 gate와 AppHost ABI 4,070-test aggregate, Swift type-check 및 실제
   `Maru.app` 링크가 이 투영을 검증한다. 실제 Notification Center 게시·replace는 위 provisioned 제품 gate에 남긴다.

   **N3 cold-launch notification route:** Notification Center response의 `userInfo`는 저장된 OS 입력이라 권위가 아니다.
   Swift는 문자열 `hid`/`rid`를 정확히 32자의 lowercase hex, `eid`를 0이 아닌 정수로 읽고, 세 값으로 shared C
   formatter가 만든 canonical request identifier가 실제 request identifier와 byte-for-byte 같을 때만 stable route를
   admit한다. stable route가 있으면 process-local `wt`/`sid`는 새 앱 epoch에서 재사용될 수 있으므로 attach 권위나
   fast path로 쓰지 않는다. delegate는 `NSApplication.run()` 전에 설치하고, AppSession/recovery publication 전 response는
   bounded exact-key queue에 보관해 launch 완료 뒤 main actor에서 한 번만 소비한다.

   Zig 제품 경로는 먼저 모든 live Window에서 mutation 없이 exact `{host_id,runtime_id}` binding을 probe해 앱 전체에서
   정확히 하나일 때만 그 Surface를 활성화하며 cross-Window duplicate는 실패시킨다. 없으면 현재 app-global Recovered
   Sessions projection에서 같은 handle의 행이 정확히 하나일 때는 기존
   `activateRecoveredSessionAt`을 호출해 fresh `host.info`/`runtime.get` 검증과 orphan 새 tab 또는 ended placeholder 교체를
   그대로 재사용한다. 배너보다 나중에 keep-alive 설정이 꺼져 projection이 없더라도 secure current registry의
   runtime membership을 fresh resolve하고 selected `host_id`까지 같을 때만 기존 attachExisting staging으로 새 비고정 tab을
   연다. 이 resolve는 host/runtime을 시작하지 않는다. unknown·duplicate·stale host/runtime, malformed route와 attach 실패는 topology/workspace/runtime spawn
   mutation 0이며 default shell로 폴백하지 않는다. `event_id`는 response dedup/identity이지 attach capability가 아니므로
   journal row가 이미 회수됐다는 이유로 attach를 거부하지 않는다. route 없는 local/app-owned 알림만 기존 `wt`/`sid`
   process-local 클릭 경로를 유지한다.

   **G1 config loader provenance:** opt-in 설정의 의도를 보존하기 위해 config loader가 resolved bool과 별도로
   `session.keep-alive-after-quit`의 source를 `absent | explicit_valid | explicit_invalid`로 보존한다.
   같은 적용 축에서 마지막 syntactic occurrence가 provenance를 소유하므로 `true` 뒤 invalid는
   resolved bool `true`를 유지한 `explicit_invalid`, invalid 뒤 `false`는 `explicit_valid(false)`다. 즉 invalid는
   provenance를 바꾸되 앞서 적용된 resolved bool을 덮지 않는다. 주석·다른 key·다른 OS 전용 줄은 이 축을
   바꾸지 않으며, 현재 OS suffix가 적용되는 경우에는 generic key와 같은 파일 순서 규칙 및 occurrence 집합을
   사용한다. 파일 I/O 결과도 `missing | readable | unreadable | oversize`의 닫힌 상태로
   보존하고, unreadable/oversize를 missing으로 축소하지 않는다. G1은 관측만 추가하며 default=false,
   파일 write/materialization, notice, app-global bootstrap 정책은 바꾸지 않는다. pure parser의 duplicate/invalid/
   OS-suffix matrix와 실제 file의 missing/readable/unreadable/1 MiB exact/cap+1을 Debug·ReleaseFast에서 검증한다.
   G2만 이 provenance를 소비해 explicit override materialization·Reset retention을 소유한다.

   **G2 explicit override materialization·retention:** L0 lease 직후 AppKit/첫 AppSession 전에 app-global owner가 G1의
   resolved bool·keep-alive provenance·file provenance를 scalar snapshot으로 exact once seal한다. release A default는
   `false`로 유지하고 bootstrap 자체는 파일/notice를 만들지 않는다. 모든 Window는 이 snapshot을 빌리며 Workspace
   토글·외부 reload만 새 snapshot을 게시한다. whole Reset은 `absent`면 줄을 만들지 않고 explicit valid/invalid면 Reset
   직전 live bool을 기본값과 같아도 canonical explicit override로 같은 atomic replace에 보존한다. row Reset/Backspace는
   값·snapshot·write-back queue mutation 0 + 수동 Workspace 토글 notice다. lease 없는/중복 bootstrap, 실제 atomic replace
   실패, multi-Window, source-order와 fresh-process loser I/O 0을 Debug·ReleaseFast/product gate로 고정한다. G2는
   absent→true materialization과 default flip을 하지 않는다. 그 전환은 현재 실행 순서 밖의 G3 release 백로그만 소유한다.

   **백로그 — G3 frozen-release default migration:** 이 항목은 현재 P1~P5 완료 조건과 실행 순서에서 제외한다. 사용자가
   default-on을 다시 승인한 뒤에만 `session-host-upgrade.md`의 `maru.session-host-release.v1` B manifest가 지목한
   exact immutable A와 provisioned `Session host product / default-on` runner가 모두 준비된 뒤에만 시작한다. B bootstrap은
   `missing|readable_absent`를 atomic explicit true로 materialize한 성공 suffix에서만 app-global snapshot을 true로 publish한다.
   explicit valid는 보존하고 invalid/unreadable/oversize와 write 실패는 false·파일 mutation 0·persistent typed notice다.
   exact A rollback, A runtime→B adapter attach, B 새 runtime 분리, config/topology/tombstone/Quit/Notification matrix를 같은
   manifest/evidence test UUID로 결속하며 한 leaf라도 없으면 B publish를 막는다. SemVer 산술 인접성이나
   `latest` 조회는 A 선택 권위가 아니다.

CR0a~CR3은 사용자 가시 동작이 없는 구조/TDD 단계다. 어느 단계도 workspace를 쓰거나 host/runtime을 spawn·upgrade하지
않는다. 새 transfer receipt RPC는 현재 범위에 포함하지 않으며 seamless lost-reply 복구가 별도 목표가 될 때 다시 결정한다.
각 gate의 증거를 `model-only | production-type unit | real socket | real AppKit`으로 표시하며 CR2/CR3 완료는 `/tmp` PoC가 아니라
실제 production type을 import한 테스트가 필요하다. 최초 구현 순서는 CR0a → CR3a-1 inactive skeleton → CR3a-2
generation 1 compatibility wiring → CR3b R1 inactive admission close → CR0b → CR1 → CR2a → CR2b → CR2c → CR2d → CR2e →
CR3b R2 → CR3b R3 → CR3c다. R1만 current pointer·runtime/screen publication·generation 증가가 모두 0인 독립 기반이라
CR2보다 먼저 허용된다. 이 비제품 구조 slice가 green이기 전 CR4 socket reconnect를 시작하지 않는다.

실행 중 connection invalidation이 현재 session-host 제품 사용과 검증을 막으므로 CR은 나머지 제품 polish보다 먼저 닫는
blocking track이다.
단 CR4 admission은 CR0a+CR0b+CR1+CR2a~e+CR3a~c 전체 완료를 요구하며 scaffold 순서를 우회 조건으로 해석하지 않는다.
partial migration 실패의 마지막 screen/scrollback deep-freeze와 `FrozenProjection`은 범위 밖이다. 실패 runtime은 경량
unavailable placeholder로 전환하고 Retry 성공 시 host snapshot으로 재구성한다.
CR6 제품 활성화는 R2b Recovered Sessions projection/adopt 제품 경로가 완료된 뒤에만 가능하다. 그 전에는 unconfirmed Term이
있는 Window close를 제품에서 허용하지 않아 사용자가 찾을 수 없는 orphan runtime을 만들지 않는다.

CR6a-1은 그 경로의 app-global 파생 projection owner를 먼저 닫는다. 전체 Workspace binding과 complete inventory를
transactional reconcile해 typed system row DTO만 게시하며, opt-out/secondary/quick은 row publish·owner mutation 0, 실패는 기존 projection
mutation 0이다. socket issuer와 sidebar row materialization, 사용자 adopt는 각각 CR6a-2/CR6b에 남긴다.

CR6a-2는 첫 일반 Window의 deferred terminal publication보다 앞선 app-global coordinator를 제품 경로에 연결한다.
secure discovery와 ephemeral inventory가 모두 완결된 뒤에만 CR6a-1 projection을 교체하고, primary sidebar에 typed
`Recovered Sessions` system header/row를 materialize한다. secondary/quick 중복 0, 일반 group/tab action 0,
attach/spawn/terminate/checkpoint 0을 focused product/ABI/sidebar/boundary 및 시각 fixture로 검증한다. collector 실패는
launch를 실패시키지 않고 기존 projection mutation 0 + 정상 restore/default-surface 진행으로 귀결한다. 완료된 CR6b
제품 경로만 row의 explicit one-item adopt와 fresh `host.info`/`runtime.get` revalidation을 연다.
개별 dead/malformed/unknown host evidence는 빈 inventory로 삭제하지 않고 typed unavailable row로 reconcile한다.

CR6b는 primary typed row의 실제 click과 검색 Enter를 one-item product action에 연결한다. projection/workspace/pool
generation, ended manifest ordinal과 Window graph를 preflight하고, 하나의 5초 absolute deadline으로 fresh
`host.info`/`runtime.get`을 재검증한 뒤 orphan은 새 비고정 tab, ended conflict는 exact tombstone slot만 publish한다.
성공 뒤 row를 one-shot consume하고 deferred surface를 활성화한다. stale generation/ordinal, missing runtime과 모든
pre-publication 실패는 topology/projection mutation 0이며 host terminate/spawn/checkpoint는 호출하지 않는다.

## Provider session continuity 잔여 제거(persistent-session P1, 완료)

Claude/Codex provider-native resume/fork는 제품 경로로 되살리지 않는다. P1에서 legacy workspace typed field/parser,
restore 설정 alias, 과거 hook/mapping cleanup과 전용 환경변수 차단을 제거했다.

- provider continuity 호환과 같은 loader branch의 dead notification alias를 제거했고 세 설정 key는 일반 unknown-key
  진단으로 돌린다. 구 workspace의 미지 scalar는 일반 key-addressed 규칙으로 무시하되 독립
  `max_line_fields=512`, 512-field 성공과 513번째 거부를 유지한다.
- 과거 source build가 provider config에 설치한 Maru hook은 자동 회수하지 않는다. 잔여 hook/config/mapping은 Maru의
  소유 범위 밖에 두고 읽거나 신뢰하지 않는다. provider가 고아 hook을 계속 실행할 수 있다는 결과는 사용자 문서에 명시하고,
  정리가 필요하면 `agent-session.md` support runbook으로 정확히 식별된 Maru 항목만 제거한다.
- foreground process·screen 기반 live `agent_kind/agent_state` observer는 provider session continuity가 아니므로 유지한다.
- [Workspace Restore 전략](workspace-restore.md), [에이전트 상태 감지](agent-session.md), [알림 전략](notifications.md),
  `configuration.md`, verification matrix는 현재 계약만 남기고 삭제된 구현 역사는 Git/PR로 보낸다.
- host/runtime 종료 뒤 provider ID로 복구하는 fallback은 구현하지 않는다. 영속성은 host가 동일 PTY/process를 계속
  소유하는 동안에만 성립한다.

## 개발 순서 단일 출처

개발 순서의 단일 출처는 이 문서다. [초기 아키텍처](architecture.md)는 이전에 parser를 너무 앞에 둔 표현이었지만, 지금은 본문에서 그 parser-first 표현을 철회하고 큰 구조 설명만 유지하며 구체적인 순서는 이 문서에 위임한다.

## PR마다 확인할 질문

- 이번 PR은 위 단계 중 어디에 속하는가?
- 그 단계의 TDD 방식으로 구현 전에 실패하는 테스트를 만들 수 있는가?
- 만들 수 없다면 contract test, smoke test, 수동 artifact 중 무엇으로 대체하는가?
- 새 코드가 이전 단계의 facade 계약을 깨지 않는가?
- 자동화할 수 없는 한계를 PR 설명에 보고했는가?
