# 백로그 — New Window와 chrome 고급화 (설계 근거 보존)

둘 다 구현이 끝난 항목이고, 이 문서는 당시의 설계 근거와 확정 순서를 보존한다. 창·surface 이동 계약의 단일 출처는 [윈도우와 Surface 이동성](../window-surface-mobility.md), chrome 계약은 [Chrome 전략](../chrome-strategy.md)이다.

## 백로그: 큰 항목 — New Window·chrome 고급화 (둘 다 ✅ 구현 완료; 아래는 설계 근거 보존)

9·10단계(Workspace restore·Plugin)는 위에 목표/완료기준이 있다. 아래 둘(New Window·chrome 고급화)은 **설계 PR(레퍼런스 조사 → 분해 → ABI/경계 영향 → 사용자 합의) 원칙대로(메뉴바·split처럼) 구현 완료**됐다 — New Window는 W1/W2(⌘N·per-window 세션/렌더러·R4b 복원, 아래 상세), chrome 고급화는 C4b(GPU SDF quad/shadow)+U(VSCode 탭·고정폭·가로 스크롤·affordance — `layering-and-portability.md` §5·`chrome-strategy.md` 참조). 아래 설계안은 합의·구현 근거로 보존한다(한 줄 스텁으로 바로 코딩하지 않는 원칙을 그대로 따랐다).

### New Window (멀티 윈도우) — ✅ 구현 완료 (W1·W2·⌘N·R4b 동작; W3/W4 잔여·atlas 공유는 후속)

> **현황(2026-06)**: ⌘N(File > New Window) → `createTerminalWindow`(새 NSWindow + per-window AppSession + Metal 렌더러 + 첫 paint), `tickAppSession`이 `windows` 컬렉션을 매 tick 순회해 **전 창 렌더**, 마지막 일반 창 닫힘 시 앱 종료(D4), 워크스페이스 다중 창 복원(R4b)까지 동작 — 앱에서 확인됨. 아래 설계안(D1~D4·W1·W2)이 그대로 구현됐다. 남은 건 W3/W4 잔여(global hotkey 창 타게팅·창별 config·탭 tear-off)와 atlas 공유(grid-per-size, D2 후속) — 전부 선택적 후속.

**베이스**: Ghostty의 App→Surface 소유 모델 — `App`이 `surfaces: ArrayListUnmanaged(*Surface)`를 소유하고, `new_window`가 새 NSWindow(TerminalController) + 새 surface(`ghostty_surface_new`)를 만들며, `SharedGridSet`이 폰트 grid를 ref-count로 창 간 공유, 마지막 창 닫힘은 apprt별 quit 정책(quit-after-last-window-closed), surface별 독립 렌더/IO 스레드.

**현재 구조 (연구 결과 — 토대가 이미 상당)**:

- **Zig/ABI는 이미 멀티 세션 지원**: `maru_macos_app_session_create`(opaque 핸들 반환)·`_destroy` + 모든 ABI 함수(tick/key/resize/close…)가 세션 포인터를 명시. 전역 싱글턴·고정 슬롯 없음.
- **quick terminal이 이미 "2번째 독립 세션"**: 별도 AppSession(별도 PTY)·별도 NSWindow(borderless panel)·별도 metalRenderer·별도 renderer_state/atlas. `ensureQuickTerminal`이 `session_create`를 2번째로 호출하는 게 정확한 선례.
- **단일 가정은 Swift 호스트에만**: `MaruAppHost`의 `primary`/`quick` 2개 명시 필드(배열 아님), `activeSurface` forwarder(key 창 기준 2갈래), `tickAppSession`(primary→quick 고정 순서), `windowWillClose`가 무조건 `NSApp.terminate`, 메뉴/`runCatalogAction`이 primary 세션 고정.

→ **결론: New Window는 주로 Swift 호스트 리팩터. Zig/ABI는 대부분 그대로(quick = 살아있는 선례).**

**결정 사항 (합의 대상)**:

- **D1 윈도우↔세션 = 1:1**(권장): NSWindow 1개 = AppSession 1개(탭/split은 AppSession 내부, 이미 구현). quick과 동일 패턴 → `primary`/`quick`를 `windows` 컬렉션으로.
- **D2 atlas 소유권 = per-session 유지**(권장, memory `multi-window-atlas-ownership`): v1은 창마다 자기 atlas(quick이 이미 그럼). 공유(SharedGridSet식 grid-per-size)는 프로파일 후 후속.
- **D3 New Window = 네이티브 액션**(권장): NSWindow 생성은 OS 소유라 Zig in-session Action(dispatchAppAction)이 못 만든다 → **File > New Window 메뉴 + ⌘N(NSMenuItem keyEquivalent)** 을 Swift가 처리(quick terminal 토글이 네이티브인 것과 같은 경계). 새 창 config = 기본(interactive shell, chrome full). Zig action.zig/keybinding.zig **무변경**.
- **D4 lifecycle = 앱 종료**(사용자 결정 2026-06-14): 마지막 일반 창이 닫히면 앱을 종료한다 — 현재 동작(primary 닫힘=`NSApp.terminate`)의 자연스러운 일반화, 단순·기존 lifecycle 재사용. quick 패널은 카운트에서 제외(숨김이라 창이 아님). macOS 표준 "앱 유지(메뉴바만)"는 미채택 — 필요하면 config 토글(`quit-after-last-window-closed`)로 후속.

**분해 (Swift 중심)**:

- **W1 세션 컬렉션 — 완료(소유권 seam, 동작 불변)**: `MaruAppHost`의 stored `primary`(단일 필드)를 `windows: [TerminalSurface]`(컬렉션, 단일 출처)로 일반화하고 `primary`를 계산 별칭(`windows.first`)으로. 창 생성이 `windows.append`(launch는 여전히 1개), 창별 라우팅을 컬렉션 경유로 — `surfaceForView`는 view의 창으로 매칭, `activeSurface`는 key인 일반 창(없으면 첫 창)을 고른다. 단일 창에선 둘 다 그 창이라 동작 불변(split PR2a "Tab→tree seam"과 같은 결). `TerminalSurface`가 reference라 `primary?.field = x` 변형은 그대로 동작. 자료구조는 dict 대신 array(순서=생성순, primary=first)로 단순화. 검증: swift-check + 실제 앱 호스트 smoke(`macos-app-smoke` — 창 생성·tick·렌더·정상 종료, frame_consistent=true) + ABI 계약 + 전체 Zig 테스트 + boundaries + coretext/metal 스모크. **ABI 무변경**. quick은 별도(특수) surface 유지. **tickAppSession 순회·NSWindow delegate(per-창)·per-window lifecycle은 W2/W3로** — 2번째 창이 생겨 실제로 exercise·테스트되는 시점에 일반화한다(seam은 구조만).
- **W2 New Window 생성 + per-window tick/lifecycle — 완료(동작하는 멀티 윈도우)**: 2번째 창이 실제로 생기므로 "동작하는 New Window"가 되도록 W3(per-window lifecycle)·W4(포커스 타게팅)의 필요한 부분을 함께 넣었다. ① **팩토리** `newTerminalWindow(_:)`: `makePlaceholderWindow`(titled, full chrome) + `withSurface(새 surface)` 스코프로 렌더러·세션 생성(`createSessionForActiveSurface` — `startAppSession`에서 앱-전역 tick과 분리 추출) + 즉시 `renderTick`. 컬렉션에 append, cascade 위치, 실패 시 정리. **File > New Window + ⌘N**(네이티브 — NSWindow는 OS 소유). ② **tickAppSession 순회**: `windows` snapshot을 돌며 각 창 tick, 셸 종료(SessionEnded)/fault면 그 창을 `closeWindowOrQuit`로 — 마지막 일반 창이면 앱 종료(D4, 타이머 멈춰 재진입 terminate 방지), 아니면 그 창만 닫는다(quick과 같은 per-window). ③ **delegate 타게팅**: `windowWillClose`/`windowDidResize`/`windowDidEndLiveResize`가 `surfaceForWindow(notification.object)`로 그 창을 명시 대상(기존 primary 고정 → 멀티 창 정확). 마지막 창 닫기는 `NSApp.terminate`로 기존 단일 창 경로 보존(정리·요약은 applicationWillTerminate). ④ **teardown**: `teardownWindowSurface`(세션 close+destroy + renderer destroy + 컬렉션 제거, 요약 보존) 공유, `shutdownAppSession`이 남은 모든 창을 snapshot 순회 정리, `applicationWillTerminate`가 요약 기준 surface를 shutdown '전에' 캡처(컬렉션이 비기 전). 검증: swift-check + **단일 창 회귀 smoke**(`macos-app-smoke` — close_events=1·final_frame_ended=true·요약 W2 이전과 동일) + ABI 계약 + 전체 Zig 테스트 + boundaries + coretext/metal 스모크. **ABI 무변경**. 베이스: 2번째 창+렌더러+세션 패턴은 quick terminal이 이미 증명(팩토리는 `ensureQuickTerminal`의 일반 창 버전). 한계: **멀티 창 런타임(⌘N→2번째 창, 각자 입력·resize·닫기, 마지막 창 종료)은 앱 수동**(헤드리스 smoke는 단일 창) — Swift 호스트는 단위 테스트가 없어 기존 quick/메뉴 PR과 같은 검증 경로.
- **W3/W4 잔여**: 위에서 per-window lifecycle·delegate 타게팅·메뉴 Zig-액션 타게팅(W1 `activeSurface`가 key 창)을 흡수했다. 남은 것: global hotkey(toggle_window/quick)가 멀티 창에서 어느 창을 대상으로 할지 정교화, 창별 독립 config, 탭 tear-off — 필요 시 후속.
- **(W5) glyph atlas 공유 + #5~7 kitty 이미지 캐시 정합 — 설계 분해(2026-06 조사·측정, 구현 보류)**:
  - **측정(왜 보류인가)**: glyph atlas는 세션별로 1024² RGBA8Unorm(초기 **창당 4MB GPU 텍스처**)에서 시작하고, 한 프레임의 고유 글리프가 모자라면 max 8192²까지 grow한다([font-strategy.md](../font-strategy.md) growable atlas). 멀티 윈도우 중복의 기본 비용은 창 2~3개에 4~8MB·10개여도 36MB 수준이라 GPU/통합 메모리(GB) 대비 작고, grow도 정확성 장치이지 공유의 즉시 근거가 아니다. 따라서 **W5c(GPU 텍스처 공유)의 실질 이득은 측정된 atlas churn/메모리 압박이 나오기 전까지 작아 현재 macOS에선 구현 보류**(#10 이미지 캐시화를 측정으로 기각한 것과 같은 패턴 — 측정 없이 큰 재설계로 들어가지 않는다). 단 **WebGPU 이식** 시 재업로드×256정렬 비용이 곱해져 더 시급해질 수 있고([레이어링](../layering-and-portability.md) §5 노트), 그때 grid-per-size/ref-count `GridSet`은 growable atlas를 창 간 공유하는 문제로 재검토한다.
  - **현재 구조**: glyph atlas는 per-AppSession(per-window) 소유(`renderer_state.atlas`). 키(`GlyphCacheKey`)는 device-pixel identity(font+size+scale+cell)에 session id가 없어 **이미 공유 호환**(memory `multi-window-atlas-ownership` 주장이 코드상 맞음). 폰트 크기 변경은 `atlas.invalidate(.font_size_changed)`로 per-session in-place — 공유 시 다른 창 grid를 날리는 충돌점이다.
  - **베이스**: Ghostty `SharedGridSet`(ref-count grid = atlas + glyph cache 묶음, RwLock 보호). 폰트 변경 시 새 key를 ref + 옛 key를 deref(in-place invalidate 안 함). `Surface`가 init에 ref·deinit에 deref.
  - **분해**: **W5a** 소유권 캡슐화 seam(`Grid` 객체로 atlas+glyph cache 묶기, 동작 불변 — W1의 `primary`→`windows`식 seam). **W5b** ref-count `GridSet`(실제 공유 — **font-size 변경을 in-place invalidate에서 ref-new/deref-old로 교체**가 핵심 correctness; in-place invalidate는 eviction/atlas_full 사유에만 남긴다). **W5c** atlas `MTLTexture`를 공유 grid로 이동(실질 GPU 절감, 프로파일/WebGPU 게이트). W5a/b는 CPU raster/packing dedup만이라 단독 이득이 작다.
  - **#5~7 kitty 이미지 캐시(별개 축, 멀티 pane 이미지 렌더 전제)**: `image_id`가 surface-local opaque counter라 두 surface의 `image_id=1`이 다른 픽셀 — 공유 키가 **틀림**(atlas의 content-derived 키와 반대). fix는 ref-count가 아니라 **namespacing**: `(surface_id, image_id)` 복합 키를 4곳(`kitty_uploaded`·`planImageUploads`/`buildGpuImages`·Swift `imageTextures`·evict live-set)에 적용. 현재는 **활성 surface만 이미지 렌더**(`app_session` active-only)라 충돌이 잠재 — 비활성 pane 이미지 렌더(별도 기능)가 충돌을 노출하므로 그 기능과 함께 구현한다.
  - **순서·전제**: W5(atlas)와 #5~7(이미지)은 disjoint 캐시·다른 키 원리(content-shared vs identity-namespaced)라 독립. 공통 토대는 "per-surface id"(#5~7이 도입, W5b가 ref-count에 개념 재사용). W5는 프로파일/WebGPU 게이트, #5~7은 멀티 pane 렌더 게이트 — **둘 다 현재 단일 윈도우/active-only라 미트리거**라 지금은 설계만 고정한다.

**ABI·경계 영향**: ABI **무변경 예상**(create/destroy/tick/key/resize가 이미 세션 명시 — Swift가 opaque 핸들 컬렉션을 들면 Zig는 창 수를 몰라도 됨). 경계: window=OS(Swift 소유), session/terminal=Zig. New Window는 네이티브 액션이라 정책 일관. global_hotkey는 앱-전역 유지.

**검증 전략**: Swift 헤드리스 테스트가 어려우므로 — ① Zig 반-E2E(`session_create` 2회 → 독립 세션 2개가 각자 tick/resize/입력·destroy, quick 테스트 패턴 일반화)로 멀티 세션 격리·leak 없음 고정, ② swift-check 컴파일, ③ 앱 수동(⌘N→2번째 창, 각자 입력·resize·닫기, 마지막 창 D4 정책).

**의존**: tab/split 모델 안정(완료). **9단계 restore가 이걸 window-aware로 전제**(확정 순서의 하드 제약). 한계/후속: atlas 공유(W5), 창별 독립 config, 탭 tear-off·창 간 탭 이동.

### chrome 고급화 (렌더러 프리미티브 확장) — ✅ 구현 완료 (C4b + U)

> **현황(2026-06)**: `layering-and-portability.md` §5의 **C4b**(metal SDF quad/shadow 파이프라인·`ChromeDraw.quad`+모양 토큰·둥근 사이드바 밴드/모달·tabbar 픽셀 retrofit·둥근 탭)와 **U**(사이드바 세로 카드·VSCode식 평평 탭+앰버 언더바·고정폭·가로 스크롤·‹› 사각 버튼/hover/커서/스크롤 방향 강조·트랙패드 가로)로 구현 완료. 아래는 착수 전 설계 근거(atlas 소유권·권장 순서·미채택 대안)로 보존한다.

- **무엇**(위 "chrome 고급화" 항목): 둥근 모서리·그라데이션·그림자·비례 UI 폰트의 measured artifact·아이콘 텍스처·격자 무관 sub-pixel.
- **무엇을 건드리나**: 렌더러 draw-list 프리미티브 + Metal 셰이더 + 셀/프리미티브 ABI, chrome consumer(사이드바·탭·팝업·Find·테두리) 점진 적용, 그리고 `GlyphQuadFrame` shared atlas에 연결되는 UI font glyph placement. 별도 UI atlas는 만들지 않는다.
- **분해 스케치**: C1 SDF rounded-rect(둥근 모서리·테두리) 1개부터 → C2 그림자/그라데이션 → C3 비례 UI text artifact·final pixel placement → C4 아이콘 텍스처. consumer는 단계마다 점진 적용.
- **의존**: 렌더러/ABI 확장. C3는 New Window의 atlas 소유권과 같은 **shared atlas growth·UV renormalization** 축이지만, 제2 atlas의 별도 수명이나 공유 가정을 만들지 않는다.

### 의존성·확정 순서 (사용자 결정 2026-06-14: New Window → restore → chrome)

- **하드 제약(반드시 지킴)**: **9단계 Workspace restore는 window-aware여야 한다.** New Window보다 먼저 하면 단일-창 스키마로 짜여, 멀티 창 도입 때 저장 포맷 migration이 강제된다 → **New Window를 먼저** 하거나, restore 스키마를 처음부터 `windows: […]` 차원으로 설계한다.
- **소프트 결합(규율로 흡수)**: rich Chrome glyph의 shared atlas ⨯ New Window의 atlas 소유권. atlas 소유권을 캡슐화(현재 `renderer_state`가 소유)해 두면 어느 순서든 재작업이 거의 없다 — 새 Chrome text가 "atlas는 싱글턴" 또는 terminal cell 위치를 다시 계산한다는 가정을 박지 않는 게 조건.
- **확정 순서(사용자 결정 — 재작업 최소 = 토대 먼저)**:
  1. **BCE(완료) + 작은 VT 갭(G1~G14 — 위 "VT 호환성 갭" 절)** — 결합 0, 순수 코어, 호환성. 아무 때나(워밍업·가성비, 위 순서와 독립이라 사이사이 끼움 가능). 우선순위 순(G1 SGR 속성·G2 OSC 색/클립보드부터)으로 각자 작은 PR.
  2. **New Window** — 세션·atlas 소유권이라는 가장 큰 가정을 먼저 확정(뒤 항목이 이를 전제).
  3. **9단계 Workspace restore** — 이제 자연히 window-aware.
  4. **chrome 고급화** — 확정된 atlas 소유권 위에서 점진(C1 rounded-rect부터).
  5. **영속 session host / 10단계 Plugin** — 독립 / 먼 미래. session host는 tmux-CC layout driver가 아니라
     Maru runtime backend이며 [영속 터미널 세션 호스트](../persistent-session-host.md)의 제품 완료 범위 P1~P5를 따른다.
     앱 업데이트 사이 실행 중 runtime 보존은 [Session host 실행 중 업그레이드](../session-host-upgrade.md)의 U0~U5를
     따른다. 현재 U0 inventory와 U1~U5 component seam, 제품 daemon controller 및 caller-attested signed
     N-1→current 하네스와 앱 재실행 orchestration wiring까지 구현되어 있다. 그러나 immutable release manifest provenance,
     실제 제품 rollback activation, 최대치 multi-runtime exact reattach, 전 구간 failure injection, frozen release 기반
     app-relaunch E2E·notice·soak가 남아 있으므로 U5 완료나 기본 자동 migration으로 표시하지 않는다. 정확한 증거 수준은
     [검증 매트릭스](../verification-matrix.md#session-host-실행-중-업그레이드-gate)를 단일 출처로 따른다.
     P6 전체 workspace TUI/외부 tmux import adapter와 Plugin은 각각 실제 수요·착수 전 별도 논의.
- **검토했으나 미채택한 대안**(UI 완성도 먼저, 구조 리스크 뒤로): chrome 고급화를 New Window보다 앞에 두는 안. atlas 소유권 캡슐화 + restore 스키마 window-aware면 재작업은 낮으나, 큰 구조 변경을 미루는 대신 나중에 공유 검토할 atlas가 2개가 되는 트레이드오프 — 사용자가 "토대 먼저"를 택해 미채택.
