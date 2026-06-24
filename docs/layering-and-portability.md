# 레이어링과 이식성 전략

Maru를 macOS-first로 구현하되 **이식성(Linux/Windows/web)을 로드맵 목표로** 두고, OS-중립 코드가 `platform/macos`에 갇히지 않도록 목표 위상(layering)과 분해 순서를 정한다. 이 문서는 코드↔OS 경계의 단일 출처다. chrome 레이어 상세는 [Chrome 전략](chrome-strategy.md), 렌더 백엔드 상세는 [렌더러 전략](renderer-strategy.md)을 단일 출처로 둔다.

## 1. 확정 결정

- **이식성은 가설이 아니라 로드맵 목표다(사용자 확정).** 따라서 chrome 추출만으로 끝내지 않고, 남는 OS-중립 세션 로직도 능동 추출한다("chrome 추출은 필요하나 충분하지 않다").
- **경계(위상)는 지금 전부 긋고, 물리 이동은 의존성 순서로 점진**한다. 각 단계는 tests green을 유지한다.
- **베이스**([document-basis-and-decision]): Ghostty(가장 성숙한 from-scratch Zig 터미널)가 같은 구조(중립 계약 + comptime 백엔드 + WebGPU 회피 + shaping 분리)로 독립 수렴했다 — 우리 전략은 외톨이가 아니라 검증된 다수파다. 적대적 검증으로 위험·이식 비용을 정직하게 계량했다(§5, §7).

## 2. 목표 위상 (4층)

```mermaid
flowchart TD
    theme["theme 토큰: tui / rich"] --> chrome
    chrome["L3 chrome (src/chrome): tokens·ChromeDraw·components·ChromeState·Host"] -->|"props로 모델만 읽음"| session
    session["L2 session core (src/session): workspace·split/tab/pane ops·IME·scroll·reorder"] --> contract
    contract["L1 renderer 중립 계약 (src/renderer): DrawList·Glyph*Frame"]
    adapter["L4 platform adapter (platform/macos, 후속 platform/linux…): CoreText·render projection·GPU 백엔드·ABI·OS host"]
    adapter -.->|"OS만 담당, 위 3층을 구현/투영"| contract
    boundary["check-boundaries: 의존은 아래로만. L1~L3에 OS 타입(Metal·CoreText·AppKit) 0"] -.-> session
```

| 층 | 위치 | 책임 | 이식 시 |
|---|---|---|---|
| **L1 renderer 중립 계약** | `src/renderer/` (존재) | `RenderSnapshot→DrawList→Glyph*Frame` + native DTO 투영(`metal_frame` — §8로 platform에서 이주, 이름만 "Metal"). 백엔드 무관 frame. | **재사용**(Ghostty가 같은 모양으로 입증) |
| **L2 session core** | `src/session/` (신설) | workspace 모델·직렬화·복원, split/tab/pane 트리+연산, IME 결정, scroll/reorder 수학 | **재사용**(순수 로직, OS 무관) |
| **L3 chrome** | `src/chrome/` (신설) | tokens, ChromeDraw(semantic), components(view+hitTest), ChromeState, ChromeHost. session을 **props로만** 읽음 | **재사용**(theme/백엔드만 가장자리) |
| **L4 platform adapter** | `platform/macos/` (+ 후속 OS) | CoreText shaper/raster, GPU 백엔드(Metal/WebGPU — L1 `metal_frame` DTO를 GPU로 그림), ABI, OS host(윈도우·입력·IME·PTY·클립보드) | **타깃별 신규** |

**의존 방향**: L3→L2→L1, L4가 가장자리에서 셋을 구현/투영. L1~L3에 OS 타입이 새지 않는다(check-boundaries로 강제 — §8).

**창 chrome 분해 예시(사이드바 헤더·신호등)**: 네이티브 타이틀바를 숨기고 신호등(traffic lights)만 남기는 **창 스타일 inset은 L4 macOS 전용**이다(AppKit `titlebarAppearsTransparent`/`.fullSizeContentView` — `platform/macos`의 Swift host, [macos-app-host-boundary.md](macos-app-host-boundary.md)). 반면 **헤더 레이아웃(검색바·view options·새 워크스페이스 아이콘의 위치·hit-test)은 L3 chrome**(`chrome/components/sidebar.zig` `headerHit`)이라 OS-중립으로 **재사용**된다 — 이식 시 타깃별로 새로 짜는 건 "신호등을 남기는 창 chrome" 한 조각뿐이고(Linux/Win/web은 각자의 창 데코레이션 모델), 그 위에 그려지는 헤더는 같은 L3 코드가 투영된다. 신호등 영역만큼 헤더를 아래로 미는 좌표 시프트(`sidebar_header_height_px`)는 L1 DTO로 L4에 전달돼 GPU 백엔드가 적용한다. 같은 분해가 **창 이동/확대**에도: '어디가 드래그/더블클릭-확대 영역인가'(헤더·타이틀바 띠의 빈 곳) hit-test는 **L3 chrome**(`isWindowDragRegion`)이라 OS-중립이고, 실제 창 이동/확대 호출(performDrag/zoom)만 **L4 platform**(AppKit) — 이식 시 타깃별 창 API로 그 한 줄만 바꾼다. 숨긴 타이틀바 높이만큼 터미널을 아래로 내리는 **타이틀바 띠**(`titlebar_strip_px`)는 L2/L3 레이아웃 수치(termRect inset)라 OS-중립으로 재사용된다.

## 3. 두 번의 추출

현재 `platform/macos/app_session.zig`(~1.9만 줄 규모 — 이 줄 수는 예시일 뿐이고, 이 계획을 쓴 이후 약 2.5배로 커졌다. S2로 세션 모델(Term/Pane/Tab)을 `src/session/session_model.zig`로 추출 완료(§3.1, app_session −113줄)했고, 그 전까지는 보류된 채 자랐다)는 L3+L4를 담고, L2 모델은 session으로 빠졌다. 추출:

**1차 — chrome(L3) → `src/chrome/`** ([chrome-strategy.md] 상세)
- 손조립 `NativeMetalCell`(`sentinelBgCell`·`appendVerticalLine`·`BarMetrics` 등 ~18곳) → `ChromeDraw`(semantic) → 백엔드 lowering.

**2차 — session core(L2) → `src/session/`**
| 옮길 것 | 현 위치(예) |
|---|---|
| workspace 모델·capture·serialize·restore | `captureWorkspaceWindow`·`flattenPaneTree`·`buildWorkspaceTab`·`applyWorkspaceWindow` |
| split/tab/pane **모델** | `Term`/`Pane`/`Tab`/`PaneTree`(✅ 이동). 순수 연산 중 pane hit-test(`paneAtPoint`·`paneInDirection`)만 이동; `splitActivePane`·`collapsePane`·`focusPaneInDirection`은 spawn·resize 강결합이라 platform 잔류 |
| 입력 수학(순수) | `imeDecide`(static), `wheelDeltaToLines`·`pageScrollDelta`, `rotateMove`·`reselectAfterClose`·`adjustActiveForMove` |

추출 후 `platform/macos`엔 **L4 어댑터만** 남는다: CoreText 프레임 빌드, render projection, Metal 렌더러, ABI, Swift host. (`split_tree.zig`는 이미 `src/app`에 generic·platform 무참조로 있어 2차의 선례다.)

### 3.1 S2 추출 설계 (Term 모델/런타임 분리 — 측정 후 재개)

**보류 사유의 실체:** `Term`(`app_session.zig`)이 런타임 핸들(`app.LivePtySession`·`RuntimeEventPump`)을 필드로 품고, `app`이 "의도적 혼합 레이어"라(§8) 모델을 `src/session/`(순수)으로 통째 옮기면 session→pty 의존이 생긴다. 그래서 한동안 "상호 합의 보류"였다.

**측정(2026-06):** `Term`의 의존 표면을 코드로 셌다 — 정면돌파가 할 만함이 드러났다.
- `surface.core`(36개 API)는 **이미 OS-중립**(`terminal.TerminalCore`)이라 동반 이동만 하면 된다 — 추상화 대상이 아니다.
- 진짜 떼어낼 런타임 표면은 `live_pty`(9개, 대부분 init/소유권) + `pump`(1개 `drainAvailable`) = **약 10개**.
- 추상화 선례: `PtyIo`(`src/app/runtime.zig`)가 `ctx + *const fn` vtable로 이미 있다 → 그대로 따른다.
- 핫패스: 실질 vtable은 `pump.drainAvailable`(매 tick 1회/term) 하나. frame 빌드의 `lockCore`/`core.*`는 OS-중립이라 추상화하지 않아 vtable이 안 낀다. `mise run perf`로 회귀 감지.

**핵심 설계 — `Term`을 둘로 쪼갠다(shim 없이 완전 분리, [project-rules.md] "구조와 파일 분리"):**
- `session.Term`(모델, → `src/session/`): `surface`(OS-중립 `TerminalCore`+메타)·자식 관계·`auto_title` 등 순수 상태.
- platform `TermRuntime`(`app_session` 잔류): `live_pty`·`pump`·`live_initialized`·`terminated`·agent 런타임 + PTY spawn·render·drag UI 포인터.
- 모델은 런타임을 직접 모른다 — platform이 인덱스/포인터로 런타임을 매핑하거나 `PtyIo`식 추상 핸들만 모델에 준다.
- `Pane`/`Tab`은 이미 OS 타입 참조 0(측정 확인) → 거의 그대로 모델로. `PaneTree = app.SplitTree(*Pane)`은 generic 선례.

**단계(실제 진행 — 모두 ✅ 완료, 각 green + 헤드리스 TDD):**

| 단계 | 내용 | 상태 |
|---|---|---|
| S2-1 | 이 설계 명문화(본 절). 코드 0 | ✅ |
| S2-2 | (pump 경계 정리 — 측정 결과 `pump`가 이미 중립(`drainAvailable` 1곳)이라 불필요, S2-3에 흡수) | ✅ 흡수 |
| S2-3a | `live_pty`·`pump`·생애 플래그를 inner `rt: TermRuntime`으로 격리(~48곳 `term.X`→`term.rt.X`) | ✅ |
| S2-3b | `Term`을 `TermGeneric(comptime Rt)` + `const Term = TermGeneric(TermRuntime)` 별칭으로 — 런타임 타입 은닉 | ✅ |
| S2-4 | `Term`/`Pane`/`Tab`/`PaneTree`를 `session_model.Model(comptime Rt)`로 이동(`AgentKind`·`agent_answer_max` 동반, `agent_state`는 중립 `AgentState`). app_session −113줄 | ✅ |
| S2-5 | workspace 트리 변환(`flattenTree`·`buildTreeNode`)을 `Model`로(`allocator` 인자로 pure화) | ✅ |
| 후속 | pane hit-test/방향 탐색(`paneAtPoint`·`paneInDirection`·`FocusDirection`)을 `Model`로 | ✅ |

순수 연산 중 `splitActivePane`·`collapsePane`·`focusPaneInDirection`은 `self`(spawn·resize) 강결합이라 platform orchestration으로 잔류. `surface` 등 `src/app`의 중립 모델 추가 정리는 §3.2(3차 추출, 계획).

**검증:** 헤드리스 fake `Rt`로 Term/Pane/Tab/PaneTree 구성·workspace round-trip·pane hit-test를 PTY/surface 없이 단언(`session_model.zig` 테스트, tamper로 수집 확인). 매 단계 `zig build test`·`check-boundaries`(session에 pty/platform/OS 타입명 0)·`macos-app-build` + 실기 `zig build macos-app`. `/code-review max` 결함 0.

### 3.2 3차 추출 (계획): `src/app`의 중립 모델을 session core로

**동기:** S2로 `Term`/`Pane`/`Tab`은 session으로 갔지만, 그 모델이 의존하는 **중립 모델이 아직 `src/app`에 남아** session이 `src/app`을 import한다(`session_model`이 `app/surface.zig`·`split_tree.zig`·`workspace.zig`를 참조). `src/app`은 중립 모델과 런타임이 섞인 혼합 레이어다(코드로 분류):

| `src/app` 중립 모델 (`pty` 미참조) | `src/app` 런타임 어댑터 (`pty` 참조 = L4적) |
|---|---|
| `surface`·`split_tree`·`workspace`·`window`·`core_command`·`label`·`agent_resume`·`artifact_io` | `live_pty`·`runtime`·`runtime_pump`·`frame_loop`·`host`·`pty_reader`·`live_pty_registry` |

**목표:** 중립 모델을 session core(`src/session/`)로 모으고 `src/app`엔 런타임 어댑터만 남겨, `session→app` 의존을 **0으로** 만든다(session은 terminal·renderer 계약만 의존). 이식 시 모델 전부가 OS-중립으로 재사용된다.

**위상은 깨지지 않는다(핵심):** 런타임 어댑터(L4: `live_pty`·`runtime` 등)가 모델(L2: `surface`)을 참조하는 건 **L4→L2 정상 방향**이다(L4가 가장자리에서 위 층을 구현/소비 — §2 의존 규칙). 즉 `surface`를 session으로 옮겨도 `app/live_pty`가 `session.surface`를 참조하는 건 위반이 아니라 더 정합적이다. **본질적 트레이드오프는 거의 없고**, 비용은 작업량 + 단위(아래)뿐이다.

**왜 묶어서 하나(단위):** `surface` 1개만 단독 이동하면 `split_tree`·`workspace`·`window`이 `src/app`에 남아 `session→app`이 그대로다(절반만 정리). 가치는 중립 모델을 **한꺼번에** 옮겨 의존을 0으로 닫을 때 생긴다 — 그래서 surface 단독 후속은 미뤘고, 이 3차로 묶는다.

**단계(의존 순서, 각 green + 헤드리스 — 계획):**

| 단계 | 옮길 것 | 비고 |
|---|---|---|
| A1 | `split_tree`·`workspace`·`label`·`agent_resume`·`artifact_io`(이미 순수, import 0) | 가장 쉬움 — 파일 이동 + barrel/참조 경로만 |
| A2 | `surface`·`window`·`core_command`(`terminal`만 참조) | `session→terminal`(이미 있음). 런타임 참조처(`live_pty` 등) import 갱신 |
| A3 | `session→app` 잔여 의존 0 확인 + `check-boundaries`에 `session`의 `app` 금지 추가 | 의존 소거를 가드로 고정 |

**선결 설계 포인트(이 3차 착수 전 결정):** 중립 모델이 빠지면 `src/app`은 "런타임 어댑터"만 남는데, 이게 L4(`platform/macos`)와 어떻게 다른지 경계를 먼저 못박아야 한다 — 현재 `src/app`은 **OS 비종속 런타임**(PTY 추상·이벤트 펌프·frame loop 본문), `platform/macos`는 **OS 종속**(CoreText·Metal·ABI·Swift host)다. 이 "OS-중립 런타임" 층의 이름·위치(예: `src/runtime/`로 개명? `src/app` 유지?)를 정하는 게 선결이다.

**리스크/한계(정직):**
- 작업량: `surface` 참조 런타임 10+ 파일 import 경로 변경(기계적·저위험, 동작 보존).
- 위 선결 설계(런타임 층 정체성)가 미정이면 A1만 해도 어중간 — 그래서 **계획만** 두고 착수는 그 결정 후.
- 본질적 단점 없음: L4→L2 참조 정상이라 위상 손해 없고, 순수 이동이라 동작 변화 0.

**검증(계획):** 각 단계 `zig build test`·`check-boundaries`(A3에서 `session→app` 금지 추가)·`macos-app-build` + 실기. 이동만이라 기존 테스트가 그대로 그물.

## 4. 렌더 백엔드 + 호스트 이식 (검증된 현실)

이식 작업을 **GPU 백엔드(공유 가능) vs 플랫폼 호스트(타깃별 신규)** 2층으로 분리해 본다. 적대적 검증의 정직한 계량:

| 레이어 | 실효 재사용 | 타깃별 작업 |
|---|---|---|
| 도메인 파이프라인(L1, Zig) | **~85–95%** | 거의 그대로(UV·raster·atlas 계약 재사용) |
| 셰이더 | ~70% | MSL→WGSL: `textureSample`→`textureSampleLevel`(WGSL uniform control flow), vertex pulling→attribute |
| GPU 백엔드(.m) | ~45% 재작성 | bytesPerRow 256 정렬(WebGPU), per-frame 버퍼→ring, 6정점확장→instancing, 포맷/sRGB 협상 |
| presentation/host | ~20% | 동기 present→async(rAF); **호스트 전체(윈도우·입력·IME·PTY·클립보드)는 타깃별 신규** |

- **"런타임 의존성 0"은 macOS 한정**이다. Linux/Windows WebGPU는 Dawn/wgpu-native(C++ 의존성) + Wayland/X11/Win32 호스트가 필요 → 그 원칙이 그 타깃에선 깨진다(사용자 논의 후 추가).
- **browser는 PTY가 없어 아키텍처가 다른 제품**이다(서버사이드 PTY 또는 다른 백엔드). "Win/Linux/browser를 하나의 WebGPU로"는 GPU API 레이어만의 환상 — 호스트는 0% 공유.
- **백엔드 선택은 시점에 결정**: 후속은 WebGPU(WezTerm 선례, 통일·큰 의존성) 또는 OS별 OpenGL/Vulkan(Ghostty 선례, 다중 백엔드·의존성 작음). **중립 계약이 둘 다 지원**하므로 지금 고를 필요 없다. [renderer-strategy.md]가 WebGPU 검토 조건의 단일 출처.
- **OS 창 속성 = L4 platform adapter 계약의 깨끗한 사례**(window.blur, F3-1): "창 뒤 데스크톱 블러"는 어느 OS도 **GPU 렌더러로 못 한다**(Metal/WebGPU는 backdrop 픽셀을 못 읽음 — WindowServer/컴포지터가 창 뒤를 합성). 그래서 **정책은 Zig 단일 출처**(`app_session.effectiveWindowBlur` — opacity 게이트 + 유효 반경, ABI getter `window_blur_radius`)가 정하고, **실제 OS 호출만 platform host가 타깃별로** 채운다: macOS=`CGSSetWindowBackgroundBlurRadius`(비공개 CGS, Ghostty·Terminal.app 동일), Windows=`DwmSetWindowAttribute`(추후), Linux=`_KDE_NET_WM_BLUR_BEHIND_REGION`(X11)/kde-blur(Wayland, 컴포지터 의존 best-effort, 추후). GPU 백엔드와 완전 무관 — 백엔드를 WebGPU로 바꿔도 이 계약은 그대로다. 같은 모양: 시스템 외관(`set_system_appearance`)·클립보드·알림.

## 5. 시퀀싱 (의존성 순서, 각 단계 green)

1. **C0 — Notice + chrome 백엔드 골격** (greenfield) ✅ **완료**. 손상 알림(`workspace_window_count < 0`) 연결, ChromeDraw→backend 패턴 증명.
2. **S1 — session-tree 수명 계약 형식화**(§6) ✅ **완료**(`invalidateForFreedPane` chokepoint).
3. **S2 — session core(L2) 물리 추출** → `src/session/`. `input_math`·`ime`는 추출 완료. 모델(Pane/Tab/Term)은 라이브-결합이라 한동안 보류였으나, 측정(§3.1)으로 추상화 표면이 좁음을 확인하고(런타임 핸들 ~10개 + `PtyIo` 선례·핫패스 vtable 1개) **완료**했다(§3.1) — `Term`을 모델/런타임으로 쪼개 모델(Term/Pane/Tab/PaneTree·workspace 변환·pane hit-test)을 `session_model.Model(Rt)`로 이동(app_session −113줄). C1~C4는 S2 모델 추출 없이 완료됐고, 모델이 이제 session 소유다. 남은 `src/app`의 중립 모델(`surface` 등) 정리는 §3.2(3차).
4. **C1 — palette/find chrome 이주** ✅ **완료**(C1a=find, C1b=palette). 두 오버레이가 `src/chrome/components/{find,palette}.zig`(neutral State+view+handle)로, platform이 props·카탈로그 행 주입·ChromeDraw lowering. **입력 caret은 터미널 커서 메커니즘을 재활용**: cursor-role fill → 오버레이 `PaneFrame.cursor`(반전 블록) → `setCursorVisible`(suffix-trim) 깜빡임(틱-카운터 위상 공유, 재빌드 0). EAW 폭(한글 2칸)·IME 조합 표시도 find/palette/터미널이 같은 경로. **C2 — divider chrome 이주** ✅ **완료**: divider 선·hit-test·드래그 수학이 neutral `chrome/components/divider.zig`로 — **마우스 hit-test 컴포넌트의 첫 선례**(State 없는 순수 함수 `hitTest`(마우스→seg index)/`view`(seg→Rule op 선)/`dragRatio`; 키보드 오버레이의 State+handle 변형). platform이 `layoutDividers`→중립 `Seg` 변환 주입·app `*Split` 매핑(index)·드래그 상태(§6 라이브 트리 포인터는 platform 유지, freed 시 invalidate)·Rule op→부분사각형 `NativeMetalCell` lowering(overlay rasterizer가 아닌 pane chrome 셀)을 맡는다. **C3a — sidebar chrome 이주** ✅ **완료**: sidebar hit-test(순수 함수 6개 `inSidebar`/`onResizeEdge`/`slotAt`/`inPlus`/`closeButton`/`dragTargetSlot`)·밴드 view(활성/호버/+ fill)가 neutral `chrome/components/sidebar.zig`로 — divider 마우스 hit-test 패턴 확장(드래그 재정렬이 **인덱스 기반**이라 라이브 포인터 부담이 divider보다 적음). platform이 중립 `Tab`(라벨·활성) 주입·라이브 상태(폭·드래그 인덱스·hover)·제목 glyph(`buildSidebarTitleFrame` — CoreText는 platform 책임)·밴드 fill→`NativeMetalCell` lowering을 맡는다. **C3b — tabbar hit-test chrome 이주** ✅ **완료**: 탭 컬럼 분할 hit-test(tabIndex/inCloseZone/inPlusZone/hasPlusZone)가 neutral `chrome/components/tabbar.zig`의 `Metrics` 메서드로 — 호출처가 `m.tabIndex(...)`를 그대로 쓴다(옛 BarMetrics struct 제거, init→`barMetrics` helper). 활성 탭 강조 밴드는 platform이 **단일 셀**(tabbarHighlightCell)로 직접 그린다 — 밴드가 한 칸이라 chrome view→cell round-trip이 무의미(C3a 리뷰 §3 반영; divider/sidebar의 다중 op view와 달리 tabbar는 hit-test만 chrome). 라이브 `*Pane`·드롭존·제목 glyph(buildPaneTabBarDrawList)는 platform 유지(§6). 이로써 chrome hit-test(divider·sidebar·tabbar)가 전부 컴포넌트화 — **C4(rich 백엔드 + 토큰)**만 남는다.
5. **C4a — rich 토큰셋 + config 분기** ✅ **완료**: tui가 sidebar_active로 공유하던 role(divider/focus_accent/drop_zone/tab_hover_bg/muted_fg)을 `Tokens.rich`가 분리 파생색(darken/lighten)으로 채우고, config `chrome.theme = tui|rich`로 `buildChromeTokens`가 분기. **컴포넌트·lowering 0줄 변경**(같은 ColorRole, 색만 다름 — 기본 tui). **C4b — GPU 렌더 프리미티브** ✅ **완료**: metal SDF quad/shadow 파이프라인(셀 패스와 별개 draw call)·`ChromeDraw.quad` Op + 모양 토큰(corner/border/shadow/modal_padding/gradient)·사이드바 둥근 밴드·모달 둥근 배경+테두리+그림자+안쪽 패딩·tabbar 픽셀 retrofit(§6 seam 해소 — `segCols` 단일 소스가 hit-test·활성 밴드·제목·✕를 공유)·둥근 활성 탭 + vertical gradient(draw layer 3분할 bottom/under/over로 제목 가림·바 배경 z-order 해소). **U — UI 형태 다듬기(C4b 이후, maru 독립 설계)**: 사이드바 세로 카드 + 좌측 maru-accent 막대(U1, accent=앰버 고정 브랜드색)·카드 레이아웃(U2)·가로 탭 VSCode식(U3 — 활성 탭을 채워진 밴드 대신 **평평한 약한 배경 + 하단 maru 앰버 언더바**(active indicator, 탭 seg 폭)로. 둥근 밴드·vertical gradient(C4b-5 초기안)는 폐기하고 평평 VSCode 탭으로 대체(`tab_corner_radius_px`·`tab_gradient_delta`·`shiftBrightnessU32` 제거). 탭바 하단 구분선은 `line_thickness_px` 토큰 두께로 1px GpuQuad SDF 흐림 회피. 활성 pane 강조도 사각 ring 대신 이 탭 언더바로 일원화. 그 위에 **탭 전용 고정 폭**(`tab_width_cols` — 균등 stretch 대신, 적으면 왼쪽정렬+빈 영역; tui는 0=균등 유지)·**탭 바 세로 패딩**(`tab_bar_pad_y_px` — 텍스트 위아래 여유, 제목 세로 중앙)·**넘치면 가로 스크롤**(`tabLayout`이 우측에 ‹·공백·›(3칸 사각 버튼) 예약하고 `Pane.tab_scroll_cols` offset을 `segCols` 단일 통합점에 적용 — view·hit-test 동시 이동(§6); `eff_scroll = min(scroll, total-tab_cols)` clamp로 탭 닫기 후 stale 자동 복구, rich 고정폭만; 활성 탭 선택(⌘[]·클릭) 시 `focusTerm`이 `ensureActiveTermVisible`로 그 탭이 보이게 자동 스크롤-인). ‹›는 사각 버튼·사이 공백(GpuQuad 배경)으로 표시하고 hover 시 밝게(`sidebarActiveBg` — 클릭 가능 표시)하며, 클릭 가능 영역(탭 바의 탭·‹/›·+·pane 포커스, 사이드바 워크스페이스 슬롯)은 hover 시 **pointingHand 커서**로 affordance를 준다(`hoverCursor`가 `CursorKind.link` 반환 → Swift NSCursor.pointingHand — URL hover용 기존 메커니즘 재사용, ABI 무변경). 또 ‹/›는 스크롤 여지가 있는 방향만 강조색(`active_fg`)으로·더 갈 수 없는 경계 방향은 muted(`fg`)로 그려, ‹가 진하면 "왼쪽에 잘린 부분 탭이 더 있음"을 알리는 단서가 된다(`eff_scroll` clamp로 경계 판정 정확, 새 색 인자 없이 기존 `fg`/`active_fg` 재사용). 트랙패드 2-finger 가로 스와이프(`scroll_wheel`의 `delta_x`, ABI v44 — Swift `scrollingDeltaX`→Zig `wheelDeltaToLines` 셀 환산→커서 아래 pane `tab_scroll_cols`를 클릭 ‹›와 같은 `eff` 기준으로 조정)로도 탭 바를 스크롤한다. **U3 완료**(VSCode 탭·고정폭·세로 패딩·가로 스크롤·‹› 사각 버튼/hover/커서/스크롤 방향 강조·트랙패드 가로).
6. **B(병행)** ✅ **완료** — renderer **backend-neutrality 가드 테스트**(`tests/boundary/imports.zig`의 `scanForbiddenIdentifiers` — 중립 레이어 **terminal·renderer·session·chrome**에 OS 런타임 타입명(`MetalRenderer`·CT*·CG*·NS*·MTL*)이 식별자로 새면 빌드 실패; `@import` 금지 1차에 더한 2차 re-export 가드) **+** `metal_frame`(중립 투영 DTO) **renderer 이주**(platform/macos→renderer — 이름만 "Metal"인 frame 계약을 renderer가 소유해 백엔드 Metal/WebGPU가 공유). 가드는 이름이 아니라 **의존성** 기준(frame DTO=OS 의존 0이라 중립, 실제 OS 런타임만 platform).

> **커서/애니메이션 시간-모델(후속)**: 현재 blink는 30Hz 틱-카운터(15틱=500ms) + `setCursorVisible` suffix-trim이며, 터미널 커서·오버레이 caret이 이를 공유한다(고정 30Hz라 정확). 장기적으로 **벽시계 ms 위상**(드리프트 0·틱레이트 무관)·**config 간격**(`cursor_blink_interval_ms`)·**deadline 스케줄러**(30Hz 폴링 대신 blink edge에만 깨어남)로 정제한다 — Ghostty `renderer/Thread.zig`(ms 간격 재무장 타이머·활동 reset·포커스 시 취소) 선례. deadline 모델은 idle·blink 깨어남을 급감시켜 순이득이나, suffix-trim의 "재빌드 회피"는 caret-only 갱신으로 보존해야 한다. (Zig 0.16 std.time엔 timestamp가 없어 ms 시계는 Io/posix 경유 — 그래서 지금은 틱-카운터 재활용.)

## 6. 핵심 계약 2개 (지금 못박는다 — 검증이 짚은 약한 관절)

- **session-tree 구조-무효화 계약**: `divider_drag:?*Split`·`tab_drag_pane:?*Pane`은 라이브 트리 포인터다. 트리 변형 시 stale 포인터 무효화를 **단일 콜백(session→ChromeState)** 으로 형식화한다. 15필드를 ChromeState로 옮겨도 결합은 안 옮겨지므로, 이 계약 없이는 C3가 UAF다(스냅샷 가드는 UAF를 못 잡는다 — [[devsession-undefined-test-field-trap]]).
- **rich 픽셀-레이아웃 모델**: `view`와 `hitTest`가 **단일 레이아웃 소스**(탭 advance·padding·icon slot, 픽셀)를 공유한다. tui는 그 모델을 셀에 스냅, rich는 다른 토큰만 준다. 셀-열 고정 hit-test로 시작 후 retrofit하면 그려진 ✕와 클릭 ✕가 어긋난다 — 처음부터 공유 모델로 둔다(테마=토큰이 색뿐 아니라 레이아웃까지 데이터화).

## 7. 리스크 & 미해결 (정직)

- **chrome 3위험**: ① UAF 결합(→§6 S1 계약), ② 추출 necessary-not-sufficient(→2차 추출), ③ rich-layout(→§6 레이아웃 모델). 셋 다 본 문서가 흡수.
- **atlas 1024² 고정·성장 미구현**(renderer TODO): grid-per-size로 키운다([[multi-window-atlas-ownership]]와 합류). WebGPU에선 재업로드×256정렬 비용이 곱해져 더 시급.
- **`zig_owns_frame_loop`는 라벨 과장**: Zig는 tick **본문**을 소유, 클럭은 OS(macOS `NSTimer` `.common` 모드 — drag-resize 우회)다. 타깃별 클럭/vsync 필요.
- **정점확장→instancing 부채**: 현재 셀당 6정점(264B)은 Ghostty/Alacritty/kitty의 instancing 대비 ~10× 대역폭. 계약 불변이라 백엔드에서 교체 가능.
- **renderer-strategy.md 자기모순 정정**: WebGPU-통일 표 vs Ghostty 3-backend 인용 — §4의 백엔드/호스트 2층 구분으로 정리.
- **모달 px 클리핑 인프라(`MetalFrame.modal_clip`, ABI v84) — 적용 보류**: 모달 오버레이를 px 사각으로 scissor 클리핑하는 인프라(chrome `draw.Op.clip` → `OverlayRaster.clip_rect` → `PaneFrame.clip_rect` → `MetalFrame.modal_clip_*` → Swift `maru_metal_renderer.m` `setScissorRect`)는 머지됐다. 단 **이 clip을 내는 컴포넌트가 아직 없어**(`modal_clip_w==0`) 기존 렌더는 완전 무변이다. **한계(정직)**: 오버레이 **텍스트**는 `placeText`가 `@divTrunc`로 셀 행에 스냅하고 viewport(`rows`) 밖이면 자동 skip하므로, clip은 텍스트엔 사실상 불필요하고 **배경 quad(rich 모달, px 렌더)에만 실효**다 — 즉 텍스트의 픽셀-부드러운 스크롤/클리핑은 셀 그리드 구조상 불가능하고, clip은 "행 단위 부분 카드 + 배경" 정리용이다. 첫 실사용 후보(알림 패널 행 단위 스크롤[`docs/notifications.md` §6], 긴 설정 목록·command palette의 부분 행 클리핑)가 생기면 그때 적용한다. 진짜 px 부드러운 스크롤은 텍스트 렌더를 셀 그리드→px 기반으로 바꾸는 근본 작업이라 별도 대형 과제다.

## 8. neutrality 가드 + topological note

- **가드 테스트**(B) ✅: `NativeMetalCell`·`MetalFrame`·CoreText/CoreGraphics/AppKit/Metal 타입명이 중립 레이어(**terminal·renderer·session·chrome**)에 **식별자로 등장하면 빌드 실패**(`tests/boundary/imports.zig`의 `scanForbiddenIdentifiers` — `std.zig.Tokenizer`로 .identifier 토큰만 검사해 중립 계약을 설명하는 주석·문자열 속 "Metal"/"CoreText" 언급은 오탐 0). cross-layer `@import` 금지(1차)에 더한 **2차 re-export 가드**(import이 막혀도 타입명이 새는 경로 차단). `app`은 의도적 혼합 레이어(runtime+중립 모델)라 비범위 — 컨벤션으로 다룬다. = [renderer-strategy.md] WebGPU 조건 1("중립 frame만 소비함을 테스트로 증명")의 실제 충족.
- **topological note**: `metal_frame.zig`(중립 투영 + `replace` Z-합성)는 B에서 **renderer로 이주 완료** — 이름만 "Metal"인 중립 frame 계약(NativeMetalCell·MetalFrame extern DTO, OS 의존 0)을 renderer가 소유해 백엔드(Metal/WebGPU)가 공유한다. 가드는 이제 **이름이 아니라 의존성** 기준이다(frame DTO는 중립, 실제 OS 런타임 `MetalRenderer`·CT*/CG*/NS*/MTL*만 platform 가드). S2 모델 추출 **완료**(§3.1: `Term`을 모델/런타임 분리, 모델을 `session_model.Model(Rt)`로). 추가로 `src/app`에 남은 중립 모델(`surface`·`split_tree`·`workspace`·`window` 등)을 session으로 마저 모아 `session→app` 의존을 없애는 정리는 §3.2(3차 추출, 계획).
