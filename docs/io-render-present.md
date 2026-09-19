# present cadence와 chrome 독립 present (§10 · §11)

**언제 화면을 내보내는가**의 계약이다. 프레임 페이싱 결정과, chrome(사이드바 스피너)을 sync(2026) 게이트에서 떼어 독립 present하는 규칙을 담는다. 스레딩 재설계 전반은 [I/O–렌더 스레딩 분리 전략](io-render-threading.md)이 소유한다.

> **절 번호는 파일을 넘어 이어진다.** 본문이 `§9`처럼 절만 가리키면 여기서 소유 파일을 찾는다 — §1~§7 [io-render-threading.md](io-render-threading.md) · §10·§11 [present cadence](io-render-present.md) · §8·§9·§12 [Phase 2~4 계획](plans/io-render-threading.md)

## 10. present cadence / 프레임 페이싱

### 10.1 동기 (관찰)

호버/스크롤 반응이 "FPS 낮은 느낌"이라는 사용자 관찰이 있었다. 원인은 **메인 스레드 `NSTimer` present cadence**(`src/platform/macos/MaruAppHost.swift` `startFrameLoopTicks`)다 — 호버 상태 변경은 이미 `metal_generation`을 bump해 그려지지만, 다음 timer tick까지 대기한다. 기본값은 `render.frame-rate = 60`이라 최대 대기 시간은 약 16ms다(기존 30Hz 고정은 약 33ms).

**present cadence 계약**: `render.frame-rate` config로 30~120Hz를 선택한다(기본 60Hz). Cmd+, 세팅 화면의 창 섹션에도 같은 스키마 필드가 노출된다. Swift host는 ABI `frame_rate_hz`로 config의 희망값을 읽어 **앱 전역 단일 `NSTimer`** 간격을 정하고, 설정 변경은 다음 tick에 timer를 재시작한다. `maru_macos_app_session_tick(session, frame_loop_rate_hz, ...)`는 Swift가 실제로 쓰는 전역 timer cadence를 매 tick 각 Zig 세션에 넘긴다. Zig 내부의 blink/fade/poll/sync timeout은 이 host cadence로 ms→tick 환산하므로, 여러 창/quick 세션의 `loaded_config`가 일시적으로 달라도 실제 시간이 active 세션 rate에 끌려 과속/저속으로 흐르지 않는다.

**중요(범위)**: 이는 comfort 수준 폴리시다. §1의 4.2초 질의-응답 지연이나 #700 데드락 같은 측정된 결함과 다르다. 키 이벤트 자체는 AppKit→Zig→PTY 경로로 즉시 전달되고, 이번 변경은 주로 **입력/출력 후 화면에 보이는 다음 frame 갱신 대기 시간**을 줄인다. shell/프로그램 처리 시간이나 PTY 출력 지연을 해결하는 변경은 아니다.

### 10.2 옵션 스펙트럼 (트레이드오프)

| 옵션 | 작업량 | 효과 | 비용/리스크 |
|---|---|---|---|
| **A. 설정형 timer** (`render.frame-rate`) | 완료 | 기본 60Hz로 지연 33→16ms, 30/120Hz opt-in | vsync 비정렬 judder(맥놀이), 실제 모니터 주사율 자동 추적 없음, higher Hz는 **idle wakeup 증가(배터리)** |
| **B. CVDisplayLink가 메인 tick을 깨움** | focused PR | vsync 정렬(judder 0)·주사율 적응(120Hz)·idle/blur 시 stop(배터리 절약) | per-vsync 메인 hop coalesce 필요, 모달/라이브리사이즈 런루프 응답성, 생명주기 엣지. **⚠️ tick 이 예산을 넘는 상황은 B 로 안 고쳐진다** — vsync 에 맞춰 깨워도 그 시각에 프레임이 준비돼 있지 않다. 2026-09-14 실측 기각 기록은 §10.6 |
| **C. 렌더 스레드에서 직접 present** | rework | B + **대량 출력 중 메인 응답성 분리** | Metal present를 @MainActor 밖으로 + drawable 리사이즈 동기화(코어 thread-safety는 Phase 1–3로 이미 충족이 유일한 위안) |

호버 "즉시 리드로우"는 별도 레버지만 **A/B와 중복**이 크다(호버는 이미 generation bump로 그려짐 — cadence만 지연). 하더라도 **상태 변화 시 dirty 플래그만**(동기 draw는 이중 present·타이밍 위험이라 지양).

### 10.3 제약 / 사실 (확인됨)

- **macOS 11.0 floor**(`build.zig`·`LSMinimumSystemVersion`) → 깔끔한 `NSView.displayLink`(CADisplayLink)는 macOS 14+라 못 씀. **CVDisplayLink**(10.4+, macOS 15 deprecated이나 동작)가 11.0 호환 선택 — **Ghostty 선례**(`references/ghostty/pkg/macos/video/display_link.zig`가 CVDisplayLink만, `@available` 분기 없이 사용; `set_display_id`로 멀티모니터 주사율 추적). 깔끔히 가려면 `@available(macOS 14, *)`로 14+는 CADisplayLink 분기.
- **프레임 페이싱은 본질적으로 platform 책임**([[portability-is-roadmap-goal]], [layering](layering-and-portability.md)): macOS=CVDisplayLink, Win=DXGI/WaitForVBlank, Linux=Wayland frame 콜백, web=rAF. 비-macOS는 타이머 폴백(Ghostty `DisplayLink == void` 패턴). 코어 tick은 cadence 무관·idle-cheap을 유지해야 어댑터만 갈아끼움.
- **현재 timer는 실제 모니터 주사율에 영향받지 않는다**: 120Hz 모니터에서도 config가 60이면 60Hz로 tick하고, 60Hz 모니터에서 config를 120으로 올리면 120Hz wakeup을 시도한다. 표시 장치가 그 이상을 보여주지 못하면 이득은 제한적이고 wakeup/전력 비용만 늘 수 있다.
- §7 비목표의 "deadline 스케줄러" 시간-모델(blink/애니메이션)과 합류 가능 — present cadence가 vsync-구동이 되면 그 위에 시간-모델을 얹는 게 자연스럽다.

### 10.4 결정 자세 (현재)

**먼저 tick 이 예산 안에 드는지 본다**(§10.6) — cadence 결정은 그 다음이다. tick 이 16.7ms 를 넘고 있으면 아래 어떤 선택지도 체감을 바꾸지 못한다.

**기본/권장값은 60Hz.** 30Hz는 저전력/낮은 wakeup 우선 옵션, 120Hz는 ProMotion/고주사율에서 체감 반응성을 우선할 때의 opt-in 상한이다. 144/240Hz는 현재 `NSTimer` 구조에서 vsync 정렬 없이 wakeup만 늘 가능성이 커 열지 않는다. ProMotion 수준 진짜 매끄러움과 모니터별 자동 적응을 원하면 **B(CVDisplayLink)를 doc-first 설계 후** 착수 — C(렌더 스레드)는 *대량 출력 중 메인 응답성*까지 필요해질 때.

### 10.5 애니메이션 cadence가 tick throughput에 묶임 (스피너 지연 진단)

**증상(사용자 관찰)**: 원격(SSH) 쉘에 포커스하거나 **탭을 전환하면** 다른 탭/카드의 에이전트 스피너 애니메이션이 느려지거나 멈춘다.

**PRIMARY 원인 — 출력 게이트가 스피너 advance를 굶김(수정됨)**: 스피너 위상 진행(`agent_spin_ticks += 1`)이 원래 `updateCursorBlink` 안에 있었는데, tick()은 `if (output_events > 0) resetCursorBlink() else updateCursorBlink()`로 **출력 없는 tick에만** `updateCursorBlink`를 부른다(`resetCursorBlink`는 스피너를 안 만짐). `output_events`는 **모든 Term 합계**라, 어느 surface든 연속 출력(SSH firehose·바쁜 원격 TUI·에이전트 자기 출력)을 흘리면 **매 tick 스피너 advance가 스킵**돼 다른 탭 running 에이전트 스피너가 멈춘다. 출력 시 커서를 보이는 위상으로 리셋하는 건 커서엔 정당하지만(타이핑/출력 중 커서 유지), **출력과 무관한 스피너까지 같은 게이트에 얹힌 게 버그**였다. **수정**: 스피너 진행을 `advanceAgentSpinner`로 떼어 tick()에서 **출력 게이트 밖에서 매 tick** 호출한다(회귀 테스트 "advanceAgentSpinner: … 출력 게이트 굶김"). 이게 "SSH 포커스/탭 이동 시 다른 탭 스피너 멈춤" 증상의 직접 원인이다.

**같은 게이트의 두 번째 피해자 — 커서 blink(수정됨)**: 위 수정은 스피너만 게이트 밖으로 뺐고 **커서/텍스트 blink는 전역 `output_events` 게이트에 그대로 남겼는데**, 그게 "커서가 전혀 안 깜빡인다"의 원인이었다. 출력 시 커서를 보이는 위상으로 리셋하는 규칙 자체는 옳지만(타이핑/출력 중 커서 유지), 판정 대상이 **모든 Term 합계**라 백그라운드 Term 하나가 계속 출력하면(에이전트·로그 tail·dev 서버 — 워크스페이스를 여러 개 띄우면 사실상 상시) 활성 커서가 **매 tick `resetCursorBlink`로 위상 0에 묶여** 영영 깜빡이지 않는다. 스피너와 달리 커서 blink는 게이트가 필요하다 — 다만 그 게이트는 "**내가 보는 커서**가 움직이는 중인가"여야 하므로 전역 합이 아니라 **활성 surface 자신의 출력**이다. **수정**: drain 루프가 활성 surface의 출력만 `active_output_events`로 따로 세고, blink 게이트(및 `viewportHasBlink` 스캔 게이트)가 그 값을 본다(회귀 테스트 "cursor blink: 백그라운드 Term이 계속 출력해도 활성 커서 위상은 진행한다"). 기존 blink 단위 테스트가 이걸 못 잡은 이유는 전부 `updateCursorBlink`를 **직접** 불러 tick 게이트를 건너뛰기 때문이다 — 그래서 회귀 테스트는 반드시 `tick()`을 돈다.

**SECONDARY 원인 — cadence가 tick throughput에 묶임(스피너는 수정됨)**: 애니메이션이 **tick 카운트**로 진행하면 cadence가 §10.2의 **단일 전역 `NSTimer`**가 목표 Hz로 tick을 발사한다는 전제에 의존한다. 그런데 `NSTimer`는 이전 핸들러가 도는 동안 다음 발사가 밀리므로 **한 tick이 무거우면 실효 tick rate가 목표 Hz 아래로 떨어진다** → tick-카운트 애니메이션이 그만큼 느려진다(freeze는 아님 — PRIMARY 수정 후엔 멈추지 않고 느려지는 잔여 효과). 무겁게 만드는 것: **탭 전환**(새 활성 surface 전체 grid CoreText reshape), **SSH 포커스**(활성 surface 매 tick 재빌드 + `syncAutoTitles`가 매 tick **모든 코어** lock + `sync_view` 활성 코어 lock이 바쁜 리더와 `core_mutex` 경합). **수정**: `advanceAgentSpinner`가 위상을 tick 카운트가 아니라 **wall-clock 경과**(`agent_spin_last_ns` 이후 실경과 ms, `std.Io.Clock.awake`)로 진행한다 — tick rate가 떨어져도 위상이 실시간을 따라가고, stall(무거운 tick으로 tick이 밀린 뒤) 후엔 경과분만큼 여러 프레임을 한 번에 catch-up한다(drift 없이 나머지 보존). 스피너는 이제 tick rate와 무관하게 매끄럽다(잔여 hitch는 tick이 실제로 present를 못 하는 순간뿐 — 그건 §10.2 옵션 B/C 영역). 커서/텍스트 blink도 **같은 이유로 wall-clock으로 이주했다(완료)** — 옛 틱-카운트는 ms를 *설정* `render.frame-rate` 기준으로 환산해, 실효 tick rate가 그보다 낮으면(실측 ~17Hz vs 설정 60Hz) 500ms 반주기가 1.7초가 돼 깜빡임이 3배 넘게 느려졌다("커서가 너무 느리다" 제보의 원인). 이제 `blink_phase_ns` baseline + 경과분 catch-up으로 tick rate와 무관하게 설정 속도를 지킨다(스피너와 동일 모델). 게이트가 전역 합이 아니라 활성 surface 출력인 이유는 위 PRIMARY 항목의 "두 번째 피해자" 참고.

**실측 계측(`.frametime` 스코프)**: `MARU_DEBUG=1`이면 `logFrameTime`이 tick의 wall-clock을 단계별(pre·**titles**=syncAutoTitles 전체 코어 lock·**drain**=리더 PTY pump·mid·**project**=활성 surface build+투영)로 분해해, 느린 tick(총>8ms)은 즉시 `SLOW` 한 줄, 약 1초 창마다 **실효 rate·mean/max·단계 비중**을 요약한다(SECONDARY 요인 실측). 게이트는 `diag.zig` 단일 출처(`.sync`와 동형, release 비용 0). **초기 실측(controlled smoke, 단일 surface)**: 전체 grid build tick ≈ **13ms, `project` 단계가 지배**(12.9/13.0) — 탭 전환 reshape가 한 프레임 hiccup임을 확인. **이 단계 분해는 §10.6에서 더 잘게 쪼개졌다**(project → grid/chrome/place/assemble, assemble → 이미지 4단계, chrome → 카드/상태바/헤더) — 아래 절이 그 트리와 실측의 단일 출처다.

**SECONDARY 픽스 상태**: (A) 스피너를 **wall-clock 경과** 기반으로 전환 — **완료**(`advanceAgentSpinner`, 위 참조). (B) tick당 비용 축소 — **후속**: `syncAutoTitles`를 매 tick 전체 코어 lock 대신 사이드바에 보이는 Term/변화 시만, 리더 lock 보유 축소, 탭 전환 reshape 결과 캐시. (C) 근본은 §10.2 옵션 B(CVDisplayLink)/C(렌더 스레드 present)로 cadence를 tick throughput에서 분리 — **후속**. ⚠️ **이 «근본» 판단은 축을 하나 빠뜨린다**: tick 자체가 예산을 넘으면 cadence를 vsync 에 붙여도 낼 프레임이 없다. 2026-09-14 진단(§10.6)에서 옵션 B 가설은 실측으로 기각됐고, 실제 해법은 **tick 비용을 줄이는 것**이었다. (B)(C)는 스피너 외 chrome/present 매끄러움과 tick 자체 응답성을 더 개선하나, 사용자가 보고한 스피너 지연은 PRIMARY(굶김) + (A)(wall-clock)로 해소된다.

### 10.6 kitty graphics 화면의 프레임 비용 — 터미널 브라우저 진단 (2026-09-14)

**증상(사용자 관찰)**: 터미널 브라우저(kitty graphics 로 웹을 그리는 TUI)를 띄우면 **스크롤하거나 클릭했을 때 화면 반응이 느리다**. 화면이 뜨는 것 자체는 문제가 없고 **동작할 때**만 느리다. 같은 기기의 Ghostty 는 부드럽다.

**결론 먼저**: 원인은 present cadence 가 아니라 **한 tick 이 예산을 넘는 것**이었다. 그리고 그 비용의 주인은 「이미지 렌더링」이 아니라 **매 프레임 수 MB 를 새로 할당하는 두 번의 픽셀 복사 + 빈 칸까지 전부 CoreText 에 넘기는 shaping** 이었다. 세 곳을 고쳐 **최저 실효 rate 45.4 → 58.6Hz, 예산 초과 tick 91.6 → 11.8회**(각 5회 반복, 부하 통제)가 됐다.

#### 기각된 가설 (전부 실측으로)

| 가설 | 기각 근거 |
|---|---|
| **§10.2 옵션 B(CVDisplayLink) 부재가 원인** | 사용자 화면이 75Hz 라 `render.frame-rate = 75` 로 주파수를 맞춰도 체감 동일. cadence 를 vsync 에 붙여도 **tick 이 25ms 면 낼 프레임이 없다** |
| 주사율 불일치(60 vs 75Hz) 맥놀이 | 위와 같음 |
| Debug 빌드라서 | ReleaseSafe 로도 느림. (다만 Debug 는 실제로 **15배** 느리다 — 아래 참고) |
| `MARU_DEBUG` 로깅이 측정을 만든 것 | trim 켠 쪽이 로그를 23% **더** 뿜고도 빨랐다 |
| 이미지 배치(`buildGpuImages`)가 비싸다 | 실측 **0.0ms** |
| `replace` 3.5ms 는 셀 배열 생성 | 셀 생성 **0.0ms**. dupe + 미계측 구간이었다 |

**참고 — 빌드 모드별 이미지 경로 비용**(캡처한 실제 프레임, 760×486 RGBA):

| 단계 | Debug | ReleaseSafe | ReleaseFast |
|---|---|---|---|
| base64 디코드 | 0.34ms | 0.01ms | 0.01ms |
| zlib inflate | 4.04ms | 0.40ms | 0.32ms |
| 업로드 memcpy | 0.73ms | 0.04ms | 0.00ms |

`mise run macos-app`(=`zig build macos-app`)은 `standardOptimizeOption` 기본이라 **Debug** 다. 성능을 재려면 반드시 `-Doptimize=` 를 준다.

#### 부하의 실체 (PTY 캡처)

터미널 브라우저가 보내는 것은 `a=T, f=32, o=z, t=d` — **RGBA 원본을 zlib 로 압축한 direct transmit** 이다. 1920×1080 창에서 프레임당 **5.6MB**(압축 후 수십 KB)이고, 스크롤 중 4.7~7.3 img/s 가 들어온다. 즉 **초당 25~40MB 의 픽셀**이 코어→렌더 경로를 지난다.

> 이미지 감지는 `TERM_PROGRAM` 이 아니라 **`a=q` APC 질의**로 한다. maru 는 0.1ms 안에 `ESC_Gi=<id>;OK ESC\` 로 답하므로(한도 500ms), `TERM_PROGRAM=maru` 정직 선언([터미널 호환성/보안 정책](terminal-compatibility-policy.md))이 이미지 경로를 막지 않는다 — `pty/macos.zig` 의 위장 철회 주석이 예측한 그대로다.

#### 계측 확장 (`.frametime`)

§10.5 의 5단계를 트리로 쪼갰다. 모두 `ft_on`(=`MARU_DEBUG`) 게이트라 release 는 진입하지 않는다.

```
tick ─ pre · titles · drain · mid · project
                                    ├─ grid    활성 본문 CoreText 수집
                                    ├─ chrome  사이드바·상태바·헤더·오버레이
                                    │          └ 카드 / 상태바 / 헤더~pane직전
                                    ├─ place   placeMultiPane(atlas)
                                    └─ assemble
                                       ├─ 이미지앞 · buildGpuImages
                                       ├─ 픽셀복사 (planImageUploads)
                                       ├─ 조립
                                       └─ replace (셀 / 병합 / dupe)
```

렌더러(`metal_frame`)에는 시계가 없으므로(`std.Io` 는 platform 소유) **platform 이 `diag_now` 함수 포인터를 꽂는다**. 미주입이면 모든 계측이 0 이다.

**창 크기 재현**: 기본 창(960×600)에서는 이 증상이 **재현되지 않는다**(계속 61Hz). 진단 전용 `MARU_FT_WINDOW_SIZE=WxH` 로 실환경 크기를 줘야 한다 — 셀 수와 이미지 크기가 함께 커져야 비용이 드러나기 때문이다. 이 함정 때문에 조사 초반을 통째로 헛짚었다.

#### 실측 (1920×1080, 브라우저 스크롤, ReleaseSafe)

```
현행:      tick mean 6.20ms, 최저 45.4Hz, SLOW 91.6회/40초
           assemble 40~59%  ≫  shape 38~52%

수정 후:   tick mean 1.59ms, 최저 58.6Hz, SLOW 11.8회/40초
           shape 65~84% (chrome 36~54% + grid 26~49%)  ≫  assemble 2~10%
```

#### 수정 셋 (제품 동작 — 2026-09-14 승격)

1. **줄 끝 빈 칸 trim**(`draw_list.experiment_trim_blank`) — 행 오른쪽의 «그릴 것 없는» 구간을 CoreText 에 안 넘긴다. 브라우저 화면은 본문이 통째로 이미지라 셀의 99% 가 빈 칸인데 전부 shaping 하고 있었다. **베이스**: Ghostty `font/shaper/run.zig` `RunIterator.next` 의 첫 동작(`Trim the right side of a row that might be empty`) — 같은 착상이고 코드는 maru 자체다. grid 26~57% → 9~15%.
2. **`replace` 이미지 버퍼 capacity 재사용**(`metal_frame.experiment_reuse_image_pixels`) — 길이가 아니라 **capacity** 로 재사용을 판정한다. 길이 일치를 요구하면 generation dedup 때문에 길이가 0 ↔ 5.6MB 로 번갈아 와 **적중률이 22%** 였다(실측). capacity 판정으로 99%. dupe 1.8 → 0.1ms.
3. **`planImageUploads` 재사용** — 픽셀을 매 프레임 새 힙 버퍼로 만들지 않고 AppSession 이 든 방(`kitty_pixels_buf`/`cap`)에 덮어쓴다. 2.7 → 0.1ms.
4. **선택·검색 하이라이트를 격자 기반 pass 로** — 2·3 과 달리 성능이 아니라 **1 을 가능하게 하려고** 넣었다. 아래 「승격 경위」 참고.

**같은 크기 순수 memcpy 벤치가 실제보다 18배 빨랐다** — 비용의 주인이 복사가 아니라 **재할당**임을 그 차이가 가리켰고, 그래서 「복사를 없애기」가 아니라 「방을 유지하기」가 해법이 됐다.

**소유권 규칙**: 2·3 은 「길이 ≠ 할당 크기」와 「비소유 슬라이스」라는 상태를 새로 만든다. free 는 반드시 `cap` 크기로 하고(`image_pixels_cap`·`kitty_pixels_cap`), 재사용 버퍼를 free/교체하는 경로(bg 이미지 합성·갤러리 `appendGpuImages`)는 **실제로 픽셀을 건드리기 직전에** owned 사본으로 승격한다. 승격을 호출부에 무조건 두면 갤러리가 닫힌 프레임에서도 5.6MB 를 헛복사해 **최적화가 없애려던 비용을 그대로 되살린다**(실측 1.9ms — 실제로 한 번 그렇게 만들었고 계측이 잡았다).

#### A/B 5회 (부하 4.7~4.8 img/s 로 통제, 겹침 없음)

| | base | opt |
|---|---|---|
| SLOW | 97, 86, 95, 87, 93 | **14, 14, 15, 11, 5** |
| 최대 mean | 5.84~6.87ms | **1.35~1.84ms** |
| 최저 rate | 43.9~49.0Hz | **57.8~59.0Hz** |

#### 남은 것 / 한계 (정직)

- **병목이 chrome shaping 으로 이동했다**(36~54%, 이제 grid 보다 크다). 사이드바·탭바는 거의 안 바뀌는 텍스트라 **run 단위 shaping 캐시**의 최적 대상이다 — Ghostty `font/shaper/Cache.zig` 가 같은 벽을 만나 도입한 것이고, 그 주석은 shaping 이 자기 기계에서 **프레임 시간의 96%** 였다고 적는다. 키를 **위치 독립**(run 시작 기준 상대 cluster)으로 잡는 것이 핵심이다 — 절대 위치를 넣으면 스크롤마다 전량 미스가 된다.
- **~~trim 은 알려진 회귀가 있다~~ → 해소(승격 조건이었다)**: 빈 셀 경로(`metal_frame` 의 `draw_cells` 루프)가 DrawList 를 돌아, 줄 끝 빈 칸을 빼면 **선택·검색 하이라이트가 그 칸에 안 그려졌다**(테스트가 8칸 → 0칸으로 실증). 커서만 멀쩡했는데 커서가 overlay 경로였기 때문이고, **그 차이가 해법을 가리켰다** — 하이라이트도 셀 목록에서 떼어 **격자 기반 pass** 로 옮겼다(`buildNativeCellsSplit` 의 0) pass). 선택·검색이 없으면 격자를 훑지도 않아 평상시 비용은 0 이고, `draw_cells` 가 덮은 구간은 행별 「덮인 열 수」로 건너뛴다(중복을 두면 셀이 두 배가 된다 — 실측 8 → 16).
- **창을 여는 프레임에 chrome 콜드 스타트 ~24ms** 가 세션당 1회 있다(카드 3.8 + 상태바 8.4 + 헤더~pane직전 11). 스크롤 증상과는 **다른 현상**이고 데워지면 사라진다.
- 재현은 브라우저를 pty 로 몰아 만든 **합성 스크롤**이다. 실제 트랙패드 관성 스크롤은 더 조밀하다.
#### 승격 경위와 최종 수치

승격 전에 **각 최적화 단독 A/B**(4조합 × 3회, 부하 4.7~4.8 img/s 통제)로 역할을 갈랐다:

| 조건 | SLOW(평균) | 최대 mean | 최저 rate |
|---|---|---|---|
| 현행 | 95.7 | 5.39ms | 48.3Hz |
| trim 만 | 61.0 | 4.16ms | 51.4Hz |
| 재사용 만 | 40.7 | 2.86ms | 59.2Hz |
| 둘 다 | 10.7 | 1.71ms | 59.2Hz |

**rate 는 재사용이 거의 다 올리고, SLOW 는 둘이 함께여야 크게 준다.** 둘은 서로 다른 축을 잡는다 —
재사용은 매 프레임 나가는 **지속 비용**(assemble)을, trim 은 **피크**(grid 스파이크)를 없앤다. 조사
초반에 trim 을 먼저 찾은 탓에 그쪽이 주효과인 줄 알았는데 실측은 반대였다.

**제품 동작 실측**(플래그 없이, 1920×1080 브라우저 스크롤): tick mean 1.02~1.34ms · 최저 rate 60.7Hz ·
예산 초과 tick **4회**/45초. 진단 시작점(48.3Hz · 95.7회)과 비교된다.

**trim 승격이 기존 테스트 7개의 기대값을 바꿨다.** DrawList 셀 수를 박아 둔 테스트들이 «열 수»를 세고
있었기 때문이다(예: cols=4 에 "A" → 4 가 아니라 1). 각 테스트의 본래 의도(dirty row 제한·wide glyph
continuation·atlas slot 재사용)는 그대로이고 수치만 「글자 수」로 옮겨 적었다. 하나는 입력을 고쳐야
했다 — zero-ink upload 테스트가 **줄 끝 공백**에 의존해서, trim 이후 검증 대상이 사라졌다(공백을 줄
가운데로 옮겨 살렸다).


### 10.7 grid run 캐시 진단 — «캐시가 적중할 워크로드인가»를 먼저 쟀다 (2026-09-15)

§13(락 양보)·§13.8(이미지 락 밖 디코드)·§12.9(빈 신호 잠금) 뒤 텍스트 폭포에 남은 SLOW tick 은 전부 `grid` 12~13ms — 전 화면이 새 텍스트일 때의 shaping 이다. Ghostty 는 run 내용 해시 → 셰이핑 결과의 LRU(`font/shaper/Cache.zig`, 256×8)로 이걸 피한다. 만들기 전에 두 가지를 쟀다: **(1) shaping 시간이 어디에 쓰이나**, **(2) 실제 워크로드에서 run 이 프레임 간에 얼마나 반복되나** — 폭포는 매 프레임 새 텍스트라 캐시의 최악 경우일 수 있어서다.

**계측**(`MARU_DEBUG=1`, `coretext_shaper.diag_now`·`diag_native_stats` 주입): 활성 grid 의 `shape()` 호출(chrome 호출과 가르려고 `diag_capture_next` 로 표시)을 단계별로 잰다 — Zig 쪽 native 셀 변환 / native 호출 / records 변환 / build, native 안은 mach 시계로 폰트 준비 / 문자열 조립 / **CTLine 생성** / 글리프 방출(폰트 이름 복사 포함). 같은 호출에서 run 반복률을 **시뮬레이션**한다: 행 안 연속 셀(열 이어짐·같은 face)을 run 으로 보고 위치 무관 FNV 해시(codepoint·폭·bold/italic·cluster)를 «직전 프레임」·«최근 64 프레임」 집합과 대조(`diagSimulateRuns`). SLOW 줄 `└ grid=`, 1초 창 `shape:` 줄. 시뮬레이션 비용은 합계에서 뺀다.

**실측 (1920×1080 = 215×47, ReleaseSafe, 프레임당)**

| 워크로드 | 행/f | 글리프/f | shape/f | 그중 **CTLine** | 방출 | records+build | run 적중 직전 / 최근64 (셀 기준) |
|---|---|---|---|---|---|---|---|
| 폭포 (`cat` 32MB) | 43.6 | 2039 | 5.7ms | **4.5** | 0.55 | 0.28 | 8% / 27% (4% / 17%) |
| 페이저 줄 스크롤 (less `j`, 30Hz) | 43.8 | 2082 | **12.3ms** | **10.8** | 0.74 | 0.30 | **89% / 98%** (98% / 98%) |
| 페이저 페이지 넘김 (less `f`) | 45.0 | 1698 | 11.3ms | 10.0 | 0.65 | 0.27 | 22% / 37% (24% / 26%) |
| TUI 상태줄+프롬프트 (tmux/에디터 모양) | 42.0 | 2339 | **9.8ms** | **8.2** | 0.77 | 0.34 | **95% / 95%** (97% / 97%) |

- **CTLine 생성이 shaping 의 80~90%** 다 — run(=행) 하나에 0.10~0.25ms. 폰트 준비·문자열 조립·records·build 는 합쳐 0.5ms 미만. 글리프 방출(레코드마다 폰트 이름 `CFStringGetCString`)은 0.55~0.77ms 로 2위지만 작다.
- **같은 파일인데 CTLine 이 2.3배 다르다**(폭포 0.105ms/run vs 페이저 0.246ms/run): 페이저·TUI 가 보여 준 구간에 한글 주석이 많아 폴백 캐스케이드가 도는 것으로 보인다(미검증 — 착수 시 ASCII-only 대조 1회면 갈린다).
- **캐시의 이득은 워크로드가 정한다.** 줄 스크롤·TUI 갱신은 **전 행이 dirty 인데 내용의 95~98% 가 직전 프레임에 있던 run** 이라 CTLine 10.8ms → ~1ms 가 된다. 폭포는 8~27% 라 이득이 작고, 페이지 넘김은 22~37%(들여쓰기·흔한 줄의 반복). **폭포 SLOW 를 없애는 도구가 아니라 «읽기·TUI」를 빠르게 하는 도구**다 — 이 진단이 없었으면 폭포 수치를 보고 착수했을 것이다.
- **dirty 범위가 왜 전 행인가**: DrawList 는 dirty **행 범위**(start..end)를 담는다(`draw_list.zig`). 한 줄 편집이면 1행만 셰이핑되어 캐시가 무의미하고, 스크롤(전 행 이동)·«맨 위 상태줄 + 맨 아래 프롬프트」 동시 변경(범위가 0..last)이면 전 화면이다. 두 번째가 tmux 상태줄·에디터 헤더/푸터의 일상이라 실사용에서 자주 나는 모양이다.

**설계 방향(미착수)**: native 셰이퍼(`coretext_smoke.m`)의 run 루프에서 CTLine 생성 앞에 캐시 — 키 = run 의 UTF-16 유닛 + face/커서 슬롯(+ ligatures 설정·폰트는 세대로 무효화), 값 = 방출 레코드의 **상대형**(run 시작 기준 셀 오프셋·glyph id·폭·폰트 이름 인덱스). 적중이면 현재 cell_index/row/col 로 재기준해 방출한다. LRU 2048, 항목 길이 상한. 커서 슬롯(합자 해제)은 키가 달라 커서 행만 매 프레임 미스(1/47). 예측: 페이저 줄 스크롤 shape 12.3 → ~2ms, TUI 9.8 → ~1.5ms, 폭포 5.7 → ~4.5ms.

**진단 방법의 적대적 검증**
- **단계 합 = 전체**: native 안 네 단계의 합이 Zig 가 잰 native 호출 시간과 일치(폭포 0.05+0.03+4.54+0.55 = 5.17 vs 5.16 · 페이저 11.66 vs 11.67). 시계가 다른데(mach vs `Io.Clock.awake`) 맞는다.
- **첫 판의 오류**: 같은 shaper 를 chrome 텍스트(상태줄 등)도 쓰는데 «마지막 호출」을 기록해 매 프레임 «행 1·셀 1」로 찍혔다 — 호출자가 «다음 호출이 grid」 를 표시하는 `diag_capture_next` 로 고쳤다. 수치가 화면(43행)과 어긋나는 것을 눈으로 잡았다.
- **`less` 페이로드 실패**: `script`+fifo 로 less 에 키를 넣는 페이로드가 pty 를 못 열어(raw.bin 0B) 빈 창만 남았다 — «입력 없이 같은 화면 변화를 내는」 페이저 흉내(맨 아래 `\n` 30Hz / 지우고 45줄)로 대체했다. 측정 대상은 «전 행 dirty + 내용 이동」이라 동치다.
- **시뮬레이션의 낙관 편향**: native run 은 커서 셀에서 한 번 더 갈라지고(합자 해제) 시뮬레이션은 안 가른다 → 프레임당 run 1개(1/44)만큼 적중을 높게 센다. 해시 충돌(64-bit FNV)은 무시 가능. 시뮬레이션 자체의 비용(0.1~0.3ms)은 합계에서 뺐다.
- **남는 한계**: ReleaseSafe 1종·창 크기 1종·3 워크로드. 진짜 검증은 캐시를 만든 뒤 «절감 = 적중률 × CTLine 시간」 이 맞는지의 예측 실험이다.

### 10.8 grid run 캐시 — 설계 (doc-first, 사용자 결정 2026-09-15)

**목표**: §10.7 이 잰 «CTLine 생성 = shaping 의 80~90%」 를 run 내용이 반복될 때 건너뛴다. 대상은 줄 스크롤·TUI 갱신·멀티 pane(§10.7 실측: 2 pane 34Hz, 3 pane 19.5Hz → 60Hz 회복 예측). 폭포는 8~27% 적중이라 이득이 작다 — 그건 목표가 아니다.

**자리**: native 셰이퍼(`coretext_smoke.m` `maru_macos_coretext_shape_draw_list`)의 run 루프, `CTLineCreateWithAttributedString` **앞**. 이유: run 경계·UTF-16 유닛·`unit_cell` 표가 거기서 만들어지고, 방출 레코드도 거기서 나온다 — Zig 쪽에서 하려면 run 분할을 두 번 하거나 native ABI 를 run 단위로 쪼개야 한다.

**키** = 다음을 이어 붙인 바이트열의 64-bit FNV + **전체 바이트 비교**(해시 충돌은 비교가 거른다):
- 폰트 설정 서명(family·size·fallback·bold/italic family·ligatures) — 전역 «세대」 로 flush 하지 않고 키에 넣는다. 같은 shaper 를 grid(모노 폰트)와 chrome(UI 폰트)이 번갈아 부르므로 세대 flush 는 매 호출 thrash 가 된다.
- style 슬롯(0~7: face 4 × 커서 여부) — 커서 슬롯은 합자를 끄므로 별도 키. 커서 행은 매 프레임 미스(1/47, 무시).
- run 셀들의 `width` 열 — 유닛이 같아도 셀 폭 배치가 다르면(wide 렌더 흡수 등) 레코드가 다르다.
- UTF-16 유닛(`units[0..unit_len]`) — codepoint·cluster 를 이미 담고 있다. 공백도 유닛에 있으니 run 의 «모양」 이 그대로 키다.

**값**(run 시작 셀 기준 **상대형**): 레코드마다 `cell_offset`(u8, <128)·`glyph_id`·`cell_width`·`drawable`·`fallback`·`color_glyph_kind`·`reserved`(오버항 칸)·폰트 이름 인덱스(캐시 소유 문자열 표, ≤64종) + run 합계(`missing_glyph_count`·`fallback_run_count`·shaped 셀 수). 적중 시 현재 `cell_index` 로 재기준해 `row/col` 을 **현재 셀에서** 읽어 방출 — 위치 무관성의 근거. 폰트 이름은 표에서 `memcpy` — 방출 단계의 `CFStringGetCString`(§10.7 0.55~0.77ms)도 함께 사라진다.

**용량**: 2048 항목 open-addressing(선형 탐사, 8칸), 항목당 키 ≤ 128+512×2 B·값 ≤ 256 레코드; 총 바이트 상한 16MB — 넘으면 가장 오래된(clock) 항목부터 비운다. 상한을 넘는 run(유닛 512·셀 128 초과)은 캐시하지 않는다(오늘도 그 상한에서 run 을 자른다).

**무효화**: 키에 설정 서명이 있어 폰트/크기/합자 변경 시 옛 항목은 그냥 안 맞는다(자연 도태). 명시 flush 는 테스트 훅(`…_shape_cache_reset_for_test`)뿐.

**스레드**: 셰이퍼는 메인이 부르지만(grid·chrome) 캐시는 `os_unfair_lock` 아래 — 비용 무시 가능, 다른 스레드가 부르게 되어도 안전.

**끄기**: `maru_macos_coretext_shape_cache_set_enabled(0)` (테스트 차등 비교용). 제품 스위치는 두지 않는다 — 옳다면 항상 켜져 있어야 한다.

**적대적 검증 계획(구현 뒤 — «구현 방법이 옳은가»)**
1. **차등 테스트**: 같은 DrawList 열을 캐시 끔으로 셰이핑한 레코드와 캐시 켬(첫 호출 미스·둘째 호출 적중)의 레코드가 **바이트 단위로 같다** — 합자·한글 cluster·box-drawing 합성·커서 슬롯·wide 렌더 심볼을 섞은 입력으로. 적중 카운터가 실제로 올라야 한다(«같은데 캐시가 안 돈」 것을 가른다).
2. **재기준**: 같은 내용을 다른 행·열에 놓아도 glyph/폭/플래그가 같고 `row/col/cell_index` 만 다르다.
3. **설정 변경**: 폰트 크기/합자 설정을 바꾸면 적중하지 않는다(서명이 키에 있다).
4. **충돌**: 해시가 같고 내용이 다른 키를 주입(테스트 훅으로 해시 함수를 상수로 바꿔)해도 오답을 내지 않는다 — 전체 비교가 거른다.
5. **용량/도태**: 항목 상한을 넘겨 넣어도 죽지 않고, 오래된 것이 나가며, 바이트 상한을 지킨다(`…_stats_for_test`).
6. **예측 실험**: §10.7 하네스 재실행 — 절감 ≈ 적중률 × CTLine 시간(페이저 12.3 → ~2ms, TUI 9.8 → ~1.5, 3 pane 41 → ~6ms tick). 어긋나면 모델이 틀린 것이다.
7. **부작용**: 폭포·유휴·브라우저가 나빠지지 않는다(미스 경로에 키 조립+삽입 비용이 붙는다 — 그 비용을 잰다).

**실측 (구현 뒤, 같은 하네스 — 예측 실험)**

| 시나리오 (215×47 기준, pane 은 `MARU_FT_SPLIT`) | 전 | 후 | 캐시 실적중 |
|---|---|---|---|
| 페이저 줄 스크롤 (1 pane) | shape 12.3ms/f | **0.78~0.97ms** (CTLine 0.16~0.26) | 98~99% |
| TUI 상태줄+프롬프트 (1 pane) | 9.8ms | **0.82ms** | 96% |
| **페이저 3 pane** (전부 스크롤) | rate 최저 19.5Hz · SLOW 463/30s · tick 평균 41ms | **56.3Hz · 5 · 1.8ms** | 83~87% |
| **TUI 2 pane** | 30Hz · SLOW 65/20s | **60.6Hz · 1** | 98% |
| 폭포 (`cat` 32MB) | 5.7ms · SLOW 33 | 5.25ms · SLOW 17 | 46% — LRU 2048 이 반복 줄·chrome run 을 잡아 «직전 프레임」 시뮬(8%)보다 높다 |
| 브라우저 스크롤 | SLOW 1 | SLOW 1 | — (이미지 경로, 변화 없음) |
| 메모리 | — | 항목 ≤ 2048, **≤ 1.6MB** (상한 16MB 의 1/10) | |

예측(페이저 ~2ms·TUI ~1.5ms·3 pane ~6ms tick)보다 좋게 나온 이유는 둘이다: 적중 시 글리프 방출의 폰트 이름 복사(`CFStringGetCString`, 0.55~0.77ms)도 함께 사라지고, 실제 캐시는 «직전 프레임」 이 아니라 LRU 2048 이라 시뮬레이션보다 적중이 높다. 폭포는 «목표가 아니다」 라고 적었던 대로 작게(5.7→5.25ms) 움직였다.

**구현 방법의 적대적 검증 (5회)**
1. **차등**(`coretext_smoke.zig` [적대·차등]): 합자·한글 NFC/NFD·box·이모지·bold/italic·wide·커서 6 시나리오 × 커서 유무 — 캐시 끔 = 첫 호출(전부 미스) = 둘째 호출(전부 적중, 새 미스 0), 글리프 단위 동일.
2. **재기준**([적대·재기준]): 행 이동은 적중하고 row 만 다르다. **열 이동은 미스다** — run 이 앞 공백(들여쓰기)을 포함해 키가 다르기 때문. contextual alternates 의 문맥일 수 있어 키에서 빼지 않는 보수적 선택이고, 미스여도 진실과 같다. 같은 들여쓰기로 다시 오면 적중.
3. **설정·충돌**([적대·설정]·[적대·충돌]): 폰트 크기/합자 변경 시 적중 0(서명이 키에 있음), 각 설정은 자기 것에만 적중. 해시를 상수로 강제해도 다른 내용에 남의 레코드를 주지 않는다(전체 비교).
4. **용량**([적대·용량]): 2600 개의 서로 다른 줄 → 항목 2048 에서 멈추고 바이트 상한 안. **여기서 결함을 잡았다** — 상한에 닿으면 삽입이 창(8칸) 안의 «가장 오래된 칸」 을 대체하는데, 조회가 빈 칸에서 멈춰 그 뒤의 항목을 못 찾았다(방금 넣은 줄이 미스). 조회가 8칸을 끝까지 보게 고쳤다(비용 없음).
5. **퍼즈**([적대·퍼즈]): 시드 난수 200 줄(ASCII·합자·한글·이모지·box·굵게·NFD 섞음, 커서 무작위)을 끔/켬/행 이동 재호출로 셰이핑 — 전부 동일, 재호출 적중 ≥100.
그리고 **예측 실험**(위 표)과 **회귀**(폭포·브라우저·유휴 나빠지지 않음, 미스 경로의 키 조립+삽입 비용은 폭포 shape 안에 들어 있고 5.7→5.25 로 오히려 준다).

**남는 한계**: 열 이동(들여쓰기 변화)은 미스 — 소스 코드 편집기에서 줄이 들여쓰기만 바뀌면 그 줄은 다시 CTLine 을 만든다(1행, 0.1~0.25ms). 커서 행은 매 프레임 미스(1/47). 이 둘을 키에서 빼려면 CoreText 의 문맥 규칙이 앞 공백에 무관하다는 증명이 필요하다 — 미검증이라 안 뺐다.

### 10.9 CTLine 비용의 정체 — 합자와 폴백 캐스케이드 (진단 2026-09-15 · **착수 보류**)

§10.7 의 부수 발견 «같은 파일인데 한글 주석 구간의 CTLine 이 2.3배」 를 통제 실험으로 갈랐다. 하네스가 아니라 native 셰이퍼를 직접 부르는 프로브(`coretext_smoke.zig` `[진단·probe] CTLine 비용`, `MARU_PROBE_CTLINE=1`)로 같은 길이(~120셀) 줄을 종류별로 30회 셰이핑해 run 당 CTLine 중앙값을 냈다(run 캐시 끔, ReleaseSafe).

| 줄 (run 당 CTLine) | JetBrains Mono, 합자 on | 합자 off | 한글 보유 주폰트(Apple SD Gothic Neo) | Menlo |
|---|---|---|---|---|
| ASCII 만 | **55µs** | **9µs** | 7µs | 4µs |
| ASCII + 한글 | 152µs | 73µs | **11µs** | 27µs |
| 한글만 | 215µs | 125µs | — | — |
| 이모지 포함 | 106µs | — | — | — |
| box-drawing | 21µs | — | — | — |
| ASCII+한글, `font.fallback = Apple SD Gothic Neo` 명시 | 169µs | — | — | — |

두 비용이 겹쳐 있었다:
1. **합자(calt/liga) — 6배.** JetBrains Mono 는 CoreText 가 줄 전체에 contextual alternates 를 돌려 ASCII 줄이 9 → 55µs. calt 가 없는 Menlo/SF Mono 는 4µs. 폰트+설정에 내재된 비용 — `font.ligatures = false` 가 유일한 손잡이고, 반복은 run 캐시(§10.8)가 흡수한다.
2. **폴백 캐스케이드 — run 당 ~110µs.** 합자를 꺼도 한글 줄은 125µs 인데 **같은 한글을 한글 보유 폰트가 주폰트면 11µs** 다. 한글 셰이핑이 아니라 **CoreText 가 run 마다 폴백 폰트를 찾는 기계**가 비싸다. `font.fallback` 으로 캐스케이드 목록을 줘도(169µs) 탐색 비용은 그대로다.

**뜻**: 한글 주석이 많은 화면(43행)은 215×43 ≈ 9ms/프레임이 폴백 탐색이다. run 캐시가 **반복**은 막으므로 less·스크롤·TUI 에는 이미 문제가 없고, 남는 것은 **처음 보는 한글 줄이 계속 흐를 때**(폭포·긴 한글 파일 첫 열람·한글 로그 tail)뿐이다.

**방향(착수 보류, 사용자 결정 2026-09-15)**: Ghostty 처럼 폴백을 우리가 푼다 — run 을 스크립트/폰트 경계(셀 경계)에서 갈라 한글 조각은 이미 아는 폴백 폰트를 **주 속성**으로 셰이핑(11µs). 폰트는 처음 한 번 CoreText 캐스케이드가 준 CTRun 폰트를 코드포인트→폰트 표에 학습해 둔다. 예측: 한글 줄 215 → ~15µs, 혼합 줄 152 → ~65µs. 위험은 경계의 합자·cluster 분리(셀 경계에서만 가르면 안전). «한글 파일을 처음 열 때 느리다」 는 체감이 생기면 그때 이 표를 기준으로 착수한다.

**폭포에 적용 — 모델 검산 (2026-09-19)**: §10.8 뒤 폭포(`cat app_session.zig` 32MB)에 남은 SLOW tick 을 분해하면 grid 9~12ms 중 CTLine 이 7.2~9.5ms, run 당 **178~203µs**, 캐시 적중 0/47 — 매 프레임 47행이 전부 처음 보는 줄이고 이 파일은 줄의 24% 에 한글이 있어 한글 밀집 구간에서 튄다. 줄 구성(한글 24%·ASCII 76%)에 위 표의 run 당 비용을 곱한 **기대 CTLine/프레임 = 4.2ms** 가 실측 평균 **4.19ms** 와 일치한다 — 통제 실험이 실제 워크로드를 설명한다. 같은 모델의 선택지: 지금(합자 on) 4.2ms(밀집 구간 9.5) · `font.ligatures = false` 1.7ms · 폴백 직접 해소(위 방향) 2.7ms(밀집 ~3) · 둘 다 0.5ms. 폭포는 지금도 56~60Hz 라 체감 문제가 아니고, 남은 비용을 없애는 길은 위 방향 그대로라 **새로 착수할 것이 없다**(사용자 결정 2026-09-19).

**방법의 한계**: 기기 1대·폰트 3종·줄 5종·30회. 미설치 폰트(SF Mono·Fira Code·D2Coding)를 넣었더니 시스템 폰트로 대체되어 Menlo 와 같은 수치가 나왔다 — 프로브에서 뺐고 «설치된 폰트만」 을 주석으로 못 박았다.

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
