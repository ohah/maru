# present cadence와 chrome 독립 present (§10 · §11)

**언제 화면을 내보내는가**의 계약이다. 프레임 페이싱 결정과, chrome(사이드바 스피너)을 sync(2026) 게이트에서 떼어 독립 present하는 규칙을 담는다. 스레딩 재설계 전반은 [I/O–렌더 스레딩 분리 전략](io-render-threading.md)이 소유한다.

> **절 번호는 파일을 넘어 이어진다.** 본문이 `§9`처럼 절만 가리키면 여기서 소유 파일을 찾는다 — §1~§7 [io-render-threading.md](io-render-threading.md) · §10·§11 [present cadence](io-render-present.md) · §8·§9·§12 [Phase 2~4 계획](plans/io-render-threading.md)

## 10. present cadence / 프레임 페이싱

### 10.1 동기 (관찰)

호버/스크롤 반응이 "FPS 낮은 느낌"이라는 사용자 관찰이 있었다. 원인은 **메인 스레드 `NSTimer` present cadence**(`src/platform/macos/MaruAppHost.swift` `startFrameLoopTicks`)다 — 호버 상태 변경은 이미 `metal_generation`을 bump해 그려지지만, 다음 timer tick까지 대기한다. 기본값은 `render.frame-rate = 60`이라 최대 대기 시간은 약 16ms다(기존 30Hz 고정은 약 33ms).

**현재 상태**: `render.frame-rate` config로 30~120Hz를 선택한다(기본 60Hz). Cmd+, 세팅 화면의 창 섹션에도 같은 스키마 필드가 노출된다. Swift host는 ABI `frame_rate_hz`로 config의 희망값을 읽어 **앱 전역 단일 `NSTimer`** 간격을 정하고, 설정 변경은 다음 tick에 timer를 재시작한다. `maru_macos_app_session_tick(session, frame_loop_rate_hz, ...)`는 Swift가 실제로 쓰는 전역 timer cadence를 매 tick 각 Zig 세션에 넘긴다. Zig 내부의 blink/fade/poll/sync timeout은 이 host cadence로 ms→tick 환산하므로, 여러 창/quick 세션의 `loaded_config`가 일시적으로 달라도 실제 시간이 active 세션 rate에 끌려 과속/저속으로 흐르지 않는다.

**중요(범위)**: 이는 comfort 수준 폴리시다. §1의 4.2초 질의-응답 지연이나 #700 데드락 같은 측정된 결함과 다르다. 키 이벤트 자체는 AppKit→Zig→PTY 경로로 즉시 전달되고, 이번 변경은 주로 **입력/출력 후 화면에 보이는 다음 frame 갱신 대기 시간**을 줄인다. shell/프로그램 처리 시간이나 PTY 출력 지연을 해결하는 변경은 아니다.

### 10.2 옵션 스펙트럼 (트레이드오프)

| 옵션 | 작업량 | 효과 | 비용/리스크 |
|---|---|---|---|
| **A. 설정형 timer** (`render.frame-rate`) | 완료 | 기본 60Hz로 지연 33→16ms, 30/120Hz opt-in | vsync 비정렬 judder(맥놀이), 실제 모니터 주사율 자동 추적 없음, higher Hz는 **idle wakeup 증가(배터리)** |
| **B. CVDisplayLink가 메인 tick을 깨움** | focused PR | vsync 정렬(judder 0)·주사율 적응(120Hz)·idle/blur 시 stop(배터리 절약) | per-vsync 메인 hop coalesce 필요, 모달/라이브리사이즈 런루프 응답성, 생명주기 엣지 |
| **C. 렌더 스레드에서 직접 present** | rework | B + **대량 출력 중 메인 응답성 분리** | Metal present를 @MainActor 밖으로 + drawable 리사이즈 동기화(코어 thread-safety는 Phase 1–3로 이미 충족이 유일한 위안) |

호버 "즉시 리드로우"는 별도 레버지만 **A/B와 중복**이 크다(호버는 이미 generation bump로 그려짐 — cadence만 지연). 하더라도 **상태 변화 시 dirty 플래그만**(동기 draw는 이중 present·타이밍 위험이라 지양).

### 10.3 제약 / 사실 (확인됨)

- **macOS 11.0 floor**(`build.zig`·`LSMinimumSystemVersion`) → 깔끔한 `NSView.displayLink`(CADisplayLink)는 macOS 14+라 못 씀. **CVDisplayLink**(10.4+, macOS 15 deprecated이나 동작)가 11.0 호환 선택 — **Ghostty 선례**(`references/ghostty/pkg/macos/video/display_link.zig`가 CVDisplayLink만, `@available` 분기 없이 사용; `set_display_id`로 멀티모니터 주사율 추적). 깔끔히 가려면 `@available(macOS 14, *)`로 14+는 CADisplayLink 분기.
- **프레임 페이싱은 본질적으로 platform 책임**([[portability-is-roadmap-goal]], [layering](layering-and-portability.md)): macOS=CVDisplayLink, Win=DXGI/WaitForVBlank, Linux=Wayland frame 콜백, web=rAF. 비-macOS는 타이머 폴백(Ghostty `DisplayLink == void` 패턴). 코어 tick은 cadence 무관·idle-cheap을 유지해야 어댑터만 갈아끼움.
- **현재 timer는 실제 모니터 주사율에 영향받지 않는다**: 120Hz 모니터에서도 config가 60이면 60Hz로 tick하고, 60Hz 모니터에서 config를 120으로 올리면 120Hz wakeup을 시도한다. 표시 장치가 그 이상을 보여주지 못하면 이득은 제한적이고 wakeup/전력 비용만 늘 수 있다.
- §7 비목표의 "deadline 스케줄러" 시간-모델(blink/애니메이션)과 합류 가능 — present cadence가 vsync-구동이 되면 그 위에 시간-모델을 얹는 게 자연스럽다.

### 10.4 결정 자세 (현재)

**기본/권장값은 60Hz.** 30Hz는 저전력/낮은 wakeup 우선 옵션, 120Hz는 ProMotion/고주사율에서 체감 반응성을 우선할 때의 opt-in 상한이다. 144/240Hz는 현재 `NSTimer` 구조에서 vsync 정렬 없이 wakeup만 늘 가능성이 커 열지 않는다. ProMotion 수준 진짜 매끄러움과 모니터별 자동 적응을 원하면 **B(CVDisplayLink)를 doc-first 설계 후** 착수 — C(렌더 스레드)는 *대량 출력 중 메인 응답성*까지 필요해질 때.

### 10.5 애니메이션 cadence가 tick throughput에 묶임 (스피너 지연 진단)

**증상(사용자 관찰)**: 원격(SSH) 쉘에 포커스하거나 **탭을 전환하면** 다른 탭/카드의 에이전트 스피너 애니메이션이 느려지거나 멈춘다.

**PRIMARY 원인 — 출력 게이트가 스피너 advance를 굶김(수정됨)**: 스피너 위상 진행(`agent_spin_ticks += 1`)이 원래 `updateCursorBlink` 안에 있었는데, tick()은 `if (output_events > 0) resetCursorBlink() else updateCursorBlink()`로 **출력 없는 tick에만** `updateCursorBlink`를 부른다(`resetCursorBlink`는 스피너를 안 만짐). `output_events`는 **모든 Term 합계**라, 어느 surface든 연속 출력(SSH firehose·바쁜 원격 TUI·에이전트 자기 출력)을 흘리면 **매 tick 스피너 advance가 스킵**돼 다른 탭 running 에이전트 스피너가 멈춘다. 출력 시 커서를 보이는 위상으로 리셋하는 건 커서엔 정당하지만(타이핑/출력 중 커서 유지), **출력과 무관한 스피너까지 같은 게이트에 얹힌 게 버그**였다. **수정**: 스피너 진행을 `advanceAgentSpinner`로 떼어 tick()에서 **출력 게이트 밖에서 매 tick** 호출한다(회귀 테스트 "advanceAgentSpinner: … 출력 게이트 굶김"). 이게 "SSH 포커스/탭 이동 시 다른 탭 스피너 멈춤" 증상의 직접 원인이다.

**같은 게이트의 두 번째 피해자 — 커서 blink(수정됨)**: 위 수정은 스피너만 게이트 밖으로 뺐고 **커서/텍스트 blink는 전역 `output_events` 게이트에 그대로 남겼는데**, 그게 "커서가 전혀 안 깜빡인다"의 원인이었다. 출력 시 커서를 보이는 위상으로 리셋하는 규칙 자체는 옳지만(타이핑/출력 중 커서 유지), 판정 대상이 **모든 Term 합계**라 백그라운드 Term 하나가 계속 출력하면(에이전트·로그 tail·dev 서버 — 워크스페이스를 여러 개 띄우면 사실상 상시) 활성 커서가 **매 tick `resetCursorBlink`로 위상 0에 묶여** 영영 깜빡이지 않는다. 스피너와 달리 커서 blink는 게이트가 필요하다 — 다만 그 게이트는 "**내가 보는 커서**가 움직이는 중인가"여야 하므로 전역 합이 아니라 **활성 surface 자신의 출력**이다. **수정**: drain 루프가 활성 surface의 출력만 `active_output_events`로 따로 세고, blink 게이트(및 `viewportHasBlink` 스캔 게이트)가 그 값을 본다(회귀 테스트 "cursor blink: 백그라운드 Term이 계속 출력해도 활성 커서 위상은 진행한다"). 기존 blink 단위 테스트가 이걸 못 잡은 이유는 전부 `updateCursorBlink`를 **직접** 불러 tick 게이트를 건너뛰기 때문이다 — 그래서 회귀 테스트는 반드시 `tick()`을 돈다.

**SECONDARY 원인 — cadence가 tick throughput에 묶임(스피너는 수정됨)**: 애니메이션이 **tick 카운트**로 진행하면 cadence가 §10.2의 **단일 전역 `NSTimer`**가 목표 Hz로 tick을 발사한다는 전제에 의존한다. 그런데 `NSTimer`는 이전 핸들러가 도는 동안 다음 발사가 밀리므로 **한 tick이 무거우면 실효 tick rate가 목표 Hz 아래로 떨어진다** → tick-카운트 애니메이션이 그만큼 느려진다(freeze는 아님 — PRIMARY 수정 후엔 멈추지 않고 느려지는 잔여 효과). 무겁게 만드는 것: **탭 전환**(새 활성 surface 전체 grid CoreText reshape), **SSH 포커스**(활성 surface 매 tick 재빌드 + `syncAutoTitles`가 매 tick **모든 코어** lock + `sync_view` 활성 코어 lock이 바쁜 리더와 `core_mutex` 경합). **수정**: `advanceAgentSpinner`가 위상을 tick 카운트가 아니라 **wall-clock 경과**(`agent_spin_last_ns` 이후 실경과 ms, `std.Io.Clock.awake`)로 진행한다 — tick rate가 떨어져도 위상이 실시간을 따라가고, stall(무거운 tick으로 tick이 밀린 뒤) 후엔 경과분만큼 여러 프레임을 한 번에 catch-up한다(drift 없이 나머지 보존). 스피너는 이제 tick rate와 무관하게 매끄럽다(잔여 hitch는 tick이 실제로 present를 못 하는 순간뿐 — 그건 §10.2 옵션 B/C 영역). 커서/텍스트 blink도 **같은 이유로 wall-clock으로 이주했다(완료)** — 옛 틱-카운트는 ms를 *설정* `render.frame-rate` 기준으로 환산해, 실효 tick rate가 그보다 낮으면(실측 ~17Hz vs 설정 60Hz) 500ms 반주기가 1.7초가 돼 깜빡임이 3배 넘게 느려졌다("커서가 너무 느리다" 제보의 원인). 이제 `blink_phase_ns` baseline + 경과분 catch-up으로 tick rate와 무관하게 설정 속도를 지킨다(스피너와 동일 모델). 게이트가 전역 합이 아니라 활성 surface 출력인 이유는 위 PRIMARY 항목의 "두 번째 피해자" 참고.

**실측 계측(`.frametime` 스코프)**: `MARU_DEBUG=1`이면 `logFrameTime`이 tick의 wall-clock을 단계별(pre·**titles**=syncAutoTitles 전체 코어 lock·**drain**=리더 PTY pump·mid·**project**=활성 surface build+투영)로 분해해, 느린 tick(총>8ms)은 즉시 `SLOW` 한 줄, 약 1초 창마다 **실효 rate·mean/max·단계 비중**을 요약한다(SECONDARY 요인 실측). 게이트는 `diag.zig` 단일 출처(`.sync`와 동형, release 비용 0). **초기 실측(controlled smoke, 단일 surface)**: 전체 grid build tick ≈ **13ms, `project` 단계가 지배**(12.9/13.0) — 탭 전환 reshape가 한 프레임 hiccup임을 확인.

**SECONDARY 픽스 상태**: (A) 스피너를 **wall-clock 경과** 기반으로 전환 — **완료**(`advanceAgentSpinner`, 위 참조). (B) tick당 비용 축소 — **후속**: `syncAutoTitles`를 매 tick 전체 코어 lock 대신 사이드바에 보이는 Term/변화 시만, 리더 lock 보유 축소, 탭 전환 reshape 결과 캐시. (C) 근본은 §10.2 옵션 B(CVDisplayLink)/C(렌더 스레드 present)로 cadence를 tick throughput에서 분리 — **후속**. (B)(C)는 스피너 외 chrome/present 매끄러움과 tick 자체 응답성을 더 개선하나, 사용자가 보고한 스피너 지연은 PRIMARY(굶김) + (A)(wall-clock)로 해소된다.

## 11. chrome(사이드바 스피너) 독립 present — sync(2026) 게이트에서 분리 (구현)

### 11.1 동기

`shouldProjectFrame`(`src/platform/macos/app_session.zig`)의 sync(2026) hold는 **터미널 grid 본문의 tearing만** 막아야 하는데, present가 창 전체를 한 프레임으로 묶으므로 **maru 자체 chrome(사이드바 에이전트 스피너 `agent_spin_frame`)까지 함께 멈춘다.** 그 결과 활성 pane이 DECSET 2026을 쓰는 동안(Claude/mux 등) 스피너 애니메이션이 hold에 걸린다. ESU edge(§sync, `sync_esu_count`)로 "완성 프레임 flush"는 이미 해결했지만, **프레임 미완성(BSU 진행 중)의 정당한 hold** 동안에는 스피너도 여전히 멈춘다 — 이 남은 절반을 chrome을 sync 게이트에서 분리해 해소한다.

### 11.2 조사 사실 (코드 확인)

- **사이드바 셀은 이미 grid와 물리적으로 별개 배열**이다: `MetalFrameBuffer.sidebar_cells`(`src/renderer/metal_frame.zig`)는 grid `cells`와 다른 슬라이스. 렌더러(`maru_metal_renderer.m`)도 `pre_sidebar_vertices` 이후를 **별도 `MARU_DRAW_CELLS` 구간**으로 그린다 — grid 본문/커서 페이드와 분리된 draw pass.
- **retained grid cells + persistent atlas → 부분 present 인프라 불필요.** 사이드바만 교체해 `generation++`로 whole-frame을 재present해도, grid `cells`는 마지막 non-hold 투영의 **완성 스냅샷**이라 half-drawn tearing이 없다. atlas 텍스처는 dims가 바뀔 때만 재생성되고 글리프 slot은 프레임 간 유지된다. → **Swift(`MaruAppHost.swift` generation 게이트)·Metal 렌더러 변경 불필요.**
- **커서 페이드의 스칼라++ 패턴은 확장 불가**: `setCursorFadeMilli`는 opacity 스칼라 하나만 바꾸지만, 스피너는 위상(`agent_spin_frame`)마다 글리프 codepoint 자체(▁~█)가 바뀌어 `sidebar_cells` 배열 교체가 필요하다.
- **upload 분리는 새 채널이 불필요**(재조사로 정정): `buildMergedUploadsN`이 만드는 `uploads`는 "이번 프레임의 **신규 glyph delta**"(atlas miss만)이고 atlas 텍스처는 persistent다. 따라서 `replaceSidebar`가 기존 `raster_uploads`/`pixels` 채널을 **사이드바 자체 delta로만** 채우면 된다(사이드바 빌드에서 공짜로 나옴). 별도 `sidebar_uploads` 슬라이스·ABI 추가 불필요. 단 delta를 비워 두면 warm-up/eviction 후 새 파형 글리프가 깨지므로 반드시 채운다.
- **최소 dirty 접근으로 충분**: `metal_dirty`(전체 dirty)를 유지하고 `chrome_dirty`를 **신규 추가**해 스피너 tick(`agent_spin_frame` 진행) 한 곳만 재배선한다 — 135개 `metal_dirty` 사이트 전면 재분류는 불필요. 스피너는 유일한 "연속 애니메이션 chrome × sync hold 무한 겹침"이고, 나머지 chrome(hover·모달·drop 등)은 discrete라 hold와 겹쳐도 ≤1초(sync timeout, 기존 트레이드오프)로 반영된다.
- **atlas는 공유(per-size)**: 사이드바를 grid와 독립 place하면 `atlas.grow()`뿐 아니라 **clean-repack invalidate**(dims 불변이나 전 slot 이동)도 retained grid UV를 stale로 만든다 → **dims가 아니라 `GlyphAtlas.generation` 변화**를 감지해 폴백해야 한다(둘 다 generation을 bump). 스피너 글리프(블록 8종)는 실무상 resident라 grow/repack이 드물다.

### 11.3 설계 (구현: chrome_dirty 최소 접근 + atlas.generation 폴백)

1. **`chrome_dirty` 신규 필드**(`AppSession`). 스피너 tick(`updateCursorBlink`의 `agent_spin_frame` 진행)이 `metal_dirty` 대신 이걸 세운다 — 부수 효과로 sync 여부와 무관하게 매 ~133ms full-grid 재셰이프를 안 하고 사이드바만 재빌드한다(에이전트 실행 중 CPU 절감).
2. **게이트**: `shouldProjectFrame`은 **무변경**. tick에서 `project_chrome = chrome_dirty and !will_project`로 별도 분기한다 — `will_project`(grid)면 기존 전체 투영이 사이드바까지 그려 `chrome_dirty`를 소진, 아니고 `project_chrome`면 사이드바 전용 경로.
3. **`replaceSidebar()`**(`metal_frame.zig`): `sidebar_cells` + `uploads`/`pixels`(사이드바 delta)만 build-then-swap하고 `generation++`. `self.cells`(터미널+chrome+헤더+오버레이)와 `cursor_cells`/`modal_cells_start` 인덱스는 **불변** — 헤드리스 테스트로 고정.
4. **사이드바 전용 빌드 분기**: `buildSidebarTitleDrawList` → `collectShaped(.sidebar)` → `placeAndDistribute`(사이드바만, 나머지 out은 throwaway) → `replaceSidebar`. grid shapeOnly/core 재읽기는 건너뛴다.
5. **atlas.generation 폴백**: 사이드바 place 전후 `renderer_state.atlas.generation` 변화(grow **또는** clean-repack)를 감지해 변했으면 부분 swap을 버리고 `metal_dirty=true`로 다음 tick 전체 재투영(모든 pane+사이드바를 한 세대로 재정규화). 스피너 글리프 resident라 드묾.

렌더러(`maru_metal_renderer.m`)·Swift(`MaruAppHost.swift`)·ABI **무변경**(whole-frame 재draw + generation 게이트가 그대로 동작, retained `self.cells`가 byte-identical로 다시 그려져 tearing 없음).

**대안 옵션 B(사이드바 전용 atlas)**는 grow/repack 간섭을 원천 차단하나 침습이 크다(UV 재정규화 완전 분리). 스피너 글리프가 소수라 generation 폴백으로 충분 — B는 chrome이 대량 글리프를 쓰게 되면 재검토.

### 11.4 구현 규모

단일 변경으로 충분(재조사로 확정): `chrome_dirty` 필드 + 스피너 tick 1곳 재배선 + tick의 `project_chrome` 분기(~50줄, 기존 `buildSidebarTitleDrawList`/`collectShaped`/`placeAndDistribute` 재사용) + `MetalFrameBuffer.replaceSidebar`(~40줄) + 불변식 헤드리스 테스트. **2개 Zig 파일, 렌더러 .m/Swift/ABI 0줄, ABI bump 없음.**

### 11.5 트레이드오프 / 한계

- **whole-frame 재present**: 사이드바 갱신마다 grid도 GPU re-draw된다(비용 있음). 단 grid는 재셰이프·atlas 재업로드가 없고(generation만 상승, Swift가 newFrame일 때만 atlas 처리) 스피너 cadence가 ~133ms라 sync hold(최대 1초) 중 최대 ~7회/초 재draw. **idle 셸에는 무영향**(`chrome_dirty`가 running 카드 있을 때만).
- **범위**: 이 설계는 사이드바 스피너에 한정. 탭바 tui 셀·모달 caret은 메인 `cells` 버퍼에 인터리브돼 커서 suffix bookkeeping과 얽혀 있어 별도 레이어 추출이 필요(더 큰 작업, 후속).
- **베이스/결정**: Ghostty·xterm.js는 GPU chrome이 없어 이 문제가 없다(선례 없음) — **Maru 독립 설계**. sync는 "리더가 완성한 grid 프레임 경계"의 문제이고 chrome은 그 대상이 아니라는 원칙에서 유도.

### 11.6 관측 (`.sync` 스코프 로거)

sync(2026) 게이트는 폴링 렌더 루프의 미묘한 부분이라(hold가 과잉 차단하면 freeze·scroll stale·완성 프레임 MISS — §sync·§11 참고) **실환경에서 게이트가 언제 붙잡고 언제 flush하는지**를 데이터로 봐야 한다. `app_session.zig`의 `sync_diag`(`std.log.scoped(.sync)`) + `logSyncGateDiag`가 이를 담당한다 — `screen_diag`(.screen)·`shell_diag`(.shell)·`coreq.*`(§9.7)와 같은 **MARU_DEBUG 게이트 scoped 로거** 관용구다(관측 가능성 원칙). tick마다 sync 게이트 상태를 한 줄 찍되, 노이즈를 줄이려 **sync 에피소드 중이거나 ESU/active가 바뀐 tick 또는 사이드바 전용 투영(cproj) tick만** emit한다(idle 정적 화면은 침묵). 필드: `active`(활성 surface sync_output)·`hold`(sync_hold_ticks/timeout)·`gproj`(grid 전체 투영 `will_project`)·`cproj`(사이드바 전용 `project_chrome`)·`force`(force_reproject)·`dirty`/`chrome`(metal/chrome_dirty)·`voff`(view_offset)·`esuadv`/`scr`(이 tick 투영을 unblock한 **실제 게이트 이유** — esu_advanced=완성 프레임 flush / view_scrolled=스크롤; 분석기가 active 중 투영을 esu_edge vs scroll로 추론 없이 가르게 `shouldProjectFrame` 입력을 그대로 실음)·`bsu`/`esu`(리더 `parser.feed`가 처리한 BSU=hold 시작/ESU=완성 프레임 누적)·`out`(tick output_events). 이 계측으로 `shouldProjectFrame`의 각 안전판(스크롤·ESU edge·timeout)이 실제로 발동하는 빈도를 잰다("연속 프레임 워크로드에서 sync 막힘의 약 절반이 ESU MISS였다"는 §sync 실측이 이 로거의 산물). **release 비용 ≈ 0**: `diag.maruDebugEnabled()`(env 1회 읽고 캐시)에서 즉시 return하고, `sync_diag_*` 상태 필드는 debug일 때만 쓰인다.

**`bsu`/`esu` vs `active` — SSH sync 어긋남 추적**: `bsu`/`esu`(리더 스레드 `parser.setPrivateModes`가 `+%=`로 세는 `core.sync_bsu_count`/`sync_esu_count`)는 **리더가 실제로 처리한 transition 횟수**이고, `active`는 **메인이 per-tick으로 샘플링한 `sync_output`**이다. 로그에서 `bsu`/`esu` 누적이 메인이 관측한 sync 구간(`active=1` tick 수)보다 **훨씬 빨리 늘면** → per-tick 폴링이 리더의 BSU→ESU 사이클(특히 flush 창 < 1 tick)을 놓치는 것이다. `maru ssh` 원격에서 bubbletea 등 Sync-cap TUI가 SSH 바이트 fragmentation으로 색·셀렉터가 깨지는(로컬·plain ssh는 정상) 이슈의 재현·계측 토대다 — 그 이슈의 **원인은 이 로거가 확정했고**(아래 조사 진행) **픽스는 리더의 바이트 경계 추적**(`sync_frame_split`)으로 들어갔다. 로거는 그대로 남아 회귀를 잰다: 픽스가 살아 있으면 `active=1 tick`과 half-frame이 **0**이다.

**조사 진행(2026-07)** — 아래 test·분석기·주석은 `.sync` 로거와 짝을 이루는 **영구 sync 관측 인프라**다(조사가 끝나도 유지; 로그 형식이 바뀌면 함께 갱신). "유력 가설" 문구만 원인 확정·픽스 시 갱신한다.
- **파싱 fragmentation 가설 = 기각.** "SSH가 `ESC[?2026h`/`l`를 write 중간에 쪼개 파서가 오파싱한다"는 가설은 헤드리스 회귀 테스트(`core.zig` "조각난 write에도 재조립" — 파서 리팩터가 fragmentation을 깨는 것도 막는 영구 가드)로 반증됐다. 파서(`self.parser` 상태 persist하는 resumable 상태머신)가 **모든 split 경계·바이트 단위**에서 재조립해 `sync_output`·카운터가 정확하다. desync는 파서가 아니라 **리더↔메인 타이밍/투영 게이트** 문제로 좁혀졌다.
- **원인 확정 + 픽스(2026-09-04) = 리더가 «청크 통째로» 적용한 것.** 아래 「유력 가설」이 실측으로
  맞았고, 그 위층(투영 게이트)이 아니라 **아래층(리더)**에 원인이 있었다. 리더는 `read(2)`가 준
  4096 B 청크를 그대로 `core.write` 하는데, SSH 스트림은 거의 언제나 프레임 한가운데서 끊긴다 —
  그래서 코어 격자에 「완성 프레임 N + 그리다 만 N+1」이 남고, **게이트가 무엇을 하든 메인이 읽는
  것은 그 상태**다. 게이트만으로는 못 고친다: `esu_advanced`를 빼면 연속 애니메이션에서 완성 순간을
  영영 못 봐 화면이 얼고(실측: 18/18 tick이 `active=1`), 두면 그리다 만 프레임을 올린다.
  **픽스는 `src/app/sync_frame_split.zig` + `PtyReader.applySyncFramed`** — 아직 안 끝난 프레임의
  꼬리를 코어에 안 넣고 들고 있다가 다음 청크와 이어 붙인다(= 이 절이 「진짜 픽스」로 적어 둔
  **바이트 경계 기준 sync 추적**). 그러면 코어 격자는 **언제 읽어도 완성 프레임**이라 게이트는 2선이
  된다. 보류가 없으면 복사도 없다(2026을 안 쓰는 스트림은 예전과 같은 한 번의 write).
  · **상한 256 KiB · 시한 1초로 접는다** — 프레임 **안에서** 질의를 보내고 답을 기다리는 앱이 있으면
    보류가 곧 교착이므로, 교착 대신 지연(=옛 동작)으로 접는다.
  · **pause/handoff 안전점에서 먼저 흘려보낸다** — 안 그러면 그 바이트가 사라져 이어지는 diff가 없는
    셀을 전제하고 **모델이 영구히 어긋난다**(handoff 인벤토리가 `sync_held_len`을 `must_be_empty`로 못 박는다).
  · **자르는 자리가 틀려도 안전하다** — 파서는 재개형이라 어느 바이트 경계에서 잘라도 재조립하고
    (아래 fragmentation 항의 회귀 테스트), 바이트는 순서대로 전부 들어간다. 최악은 「개선이 안 됨」이다.
  · **실측(2026-09-04, 임시 sshd + 시뮬레이션 프레임 스트림, `analyze_sync_log.py`)**:
    | | 픽스 전 | 픽스 후 |
    |---|---|---|
    | `active=1` tick | 18 | **0** |
    | half-drawn 투영(esu_edge) | **18/18** | **0** |
    | 리더 BSU/ESU | 2935 / 2934 | **2949 / 2949** |
- **(위 픽스가 지운) 유력 가설 = active 중 half-drawn 투영.** `shouldProjectFrame`이 `sync_active=1`(리더 기준 프레임 미완성)인데 grid를 투영하는 두 경로가 half-drawn을 만든다 — bubbletea는 diff 렌더라 그 stale 셀을 이후 안 고쳐(변경분만 보냄) 색·셀렉터가 깨지고 `Ctrl+L`도 무효다. (a) **esu_edge(SSH 빈발, 유력)**: `esu_advanced` flush가 "리더가 이미 **다음** 프레임 BSU를 시작"한 시점에 떨어지면 진행 중 next 프레임을 half-drawn으로 투영한다(로컬은 다음 ESU가 곧 교정하지만 SSH diff는 안 함) — `shouldProjectFrame` 테스트 [B] case 주석 참고. (b) **timeout(드묾)**: 조각 전달이 `sync_timeout_ms`(1초)를 넘겨 hold를 강제 해제. `.sync` 로그의 `active=1 gproj=1`로 잡히고 원인은 아래 분석기가 분해한다.
- **분석 도구(영구)**: `tools/sync/analyze_sync_log.py`가 캡처한 `.sync` 로그를 파싱해 half-frame(active 중 투영)을 원인별(esu_edge/timeout/scroll/force)로, 샘플링 누락(리더 BSU/ESU ≫ 메인 active)을 자동으로 짚는다 — `.sync` 로거(영구 관측)의 동반 도구(`tools/perf` 선례). 사용: `MARU_DEBUG=1 ./maru-macos-app 2> log` → `python3 tools/sync/analyze_sync_log.py log`.

### 11.7 활성 surface 전환 시 게이트 baseline 재설정 (구현)

`shouldProjectFrame`의 세 안전판은 **렌더-측 baseline과 코어-측 per-surface 값을 쌍으로 비교**한다: `esu_advanced`=(`last_rendered_esu` vs `core.sync_esu_count`), `view_scrolled`=(`last_rendered_view_offset` vs `core.view_offset`), timeout=(`sync_hold_ticks`가 `syncTimeoutTicks()` 초과). 문제는 이 세 baseline이 전부 **단일 `AppSession` 필드**인데 비교 대상은 **per-surface**라는 것 — 한 surface에 머물면 정확하지만, **탭/pane 전환 tick**에선 baseline에 이전 surface 값이 남아 새 surface 코어값과 비교돼 셋 다 "달라졌다"로 오판한다.

**증상(수정한 버그)**: sync(2026) TUI(Claude 등) 탭으로 전환하면 화면이 사라진다(blank). 전환은 `resizeTabPanes`→SIGWINCH로 대상 앱의 전체 clear+repaint(2026 블록)를 유발하는데, 그 "clear됐고 리페인트 전"인 중간 상태를 위 오판이 **강제 투영**한다(공유 `metal_buffer`엔 새 surface의 완성 프레임이 없어 비워진 grid가 그려진다). 되살릴 완성 프레임은 esu-edge MISS로 드롭돼 스크롤(view_offset 변화만 게이트 우회) 전까지 남는다. 세 오판 경로가 각각 blank를 낼 수 있다: (a) `esu_advanced`(이전 esu vs 새 esu>0), (b) `view_scrolled`(이전 탭이 스크롤돼 있으면), (c) `hold>=timeout`(이전 탭의 만료 hold 이월).

**수정(현재 구현, 밴드에이드)**: 활성 surface 변경을 감지한 tick에 세 baseline을 새 surface 현재값으로 재설정한다 — `last_rendered_esu=core.esu`·`last_rendered_view_offset=core.view_offset`·`sync_hold_ticks=0`. 그러면 전환 tick엔 세 비교가 모두 "불변"이 되어 hold(공유 버퍼의 직전 완성 프레임 유지, 미완성 안 그림), 대상이 ESU로 완성하는 순간 투영한다(그 surface에 계속 머문 것과 동형). 비-sync 전환은 `sync_output=false`라 `metal_dirty`로 즉시 투영(stale 없음). 전환 감지는 **`Surface.id`**(세션-로컬 monotonic·재사용 없음)로 한다 — 포인터를 쓰면 닫힌 surface 주소 재사용(ABA)에 전환을 놓쳐 stale baseline이 남는다.

**트레이드오프**: mid-sync surface로 전환하면 완성까지 직전 탭 프레임이 잠깐 보인다 — 보통 ≤1 프레임(다음 ESU), 대상 sync가 stall하면 최악 ~1초(timeout 강제 해제). 지속 blank를 sub-frame~≤1초 잔상으로 바꾸는 순개선.

**루트코즈 / 대안 검토(per-surface baseline은 실익 없음 — 착수 보류)**: 세 baseline이 단일 필드인 것이 오판의 **형식적** 원인이라, 렌더 baseline을 **per-surface**로 옮기면 cross-surface 오염([0]/[2]·idle 탭 esu)은 구조적으로 사라진다. 그러나 **각 surface의 reader 스레드가 배경에서 코어를 계속 진행**시키므로(`app/pty_reader.zig` `runProcessing`가 `core.write`로 `sync_esu_count`·`view_offset`를 계속 증가) 배경 surface의 render baseline은 뒤처지고, 재활성화 tick에 그 surface가 mid-sync면 `esu_advanced`가 참이 돼 **여전히 진행 중(빈) 프레임을 강제 투영**한다(Scenario A: 스트리밍 배경 탭으로 전환). 이를 막으려면 **재활성화 시 baseline을 코어값으로 리셋**해야 하는데, 이는 현재의 전환-리셋과 **동일 동작을 위치만 옮긴 것**이라(코드는 오히려 Surface로 분산) 밴드에이드를 제거하지 못한다. per-surface **무리셋**으로 코드를 줄이면 Scenario A에서 keep-last-good-frame이 깨져 **순간 blank 회귀**가 생긴다(현재 `esu>0` 회귀 테스트가 정확히 이 케이스라 무리셋 구현은 그 테스트를 깬다). **결론: 현재의 전환-시 3-baseline 리셋(+`Surface.id` ABA)이 올바른 최소 해법**이다.

**순간 blank·이전-탭 잔상을 둘 다 없애는 유일한 길**은 **per-surface 마지막-완성-프레임 스냅샷**이다 — 각 surface가 활성 중 투영한 완성 프레임을 보관했다가 전환 즉시 blit(리셋·hold·blank·잔상 0, Scenario A도 무관: 항상 완성 프레임). 대신 surface당 프레임 메모리 + 투영마다 스냅샷·무효화가 필요한 큰 변경이라, **이전-탭 잔상이 실제 체감될 때만** 값어치가 있다(잔상 지속 = 대상의 한 2026 프레임 완성까지 ≈ ≤1 프레임이면 sub-perceptual; §11.6 `.sync` 로그의 hold 지속으로 실측). surface detach/reattach([window-surface-mobility.md](window-surface-mobility.md))에서 surface가 창을 이동해도, 새 세션에서 활성화 시 재활성화 리셋이 baseline을 정합시키므로 현재 밴드에이드로 커버된다.

**관측/회귀**: `.sync` 로거(§11.6)의 `esuadv`/`scr`로 전환 tick의 게이트 이유를 본다(전환 직후 `gproj=0`=hold이 정상). 회귀 테스트는 `app_session.zig`에 4개 — mid-sync·완성없음(esu==0)·mid-sync·완성있음(esu>0)·스크롤된 이전 탭(view_scrolled)·이월된 hold — 음성 대조로 각 리셋의 판별력을 고정한다.
