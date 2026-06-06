# 검증 매트릭스

이 문서는 Maru의 각 영역이 무엇으로 검증되는지 추적하기 위한 표다. 목표는 "나중에 구현하자"가 아니라, 아직 구현되지 않은 영역도 어떤 자동 테스트와 산출물로 증명할지 먼저 정해 두는 것이다.

## 현재 자동 검증되는 영역

| 영역 | 현재 검증 방법 | 산출물 | 의미 |
| --- | --- | --- | --- |
| 기본 Zig 빌드 | `mise run build` | 없음 | 프로젝트가 Zig 0.16.0으로 컴파일되는지 확인한다. |
| 단위 테스트 | `mise run test` | 없음 | facade, config, terminal core 같은 작은 단위가 의도대로 동작하는지 확인한다. `PtyEventQueue`의 bounded capacity, close, event ownership과 `RuntimeEventPump`의 queue drain/runtime 적용/해제 규칙도 여기서 검증한다. 각 facade 배럴(src/*.zig)에 refAllDecls 집계 블록을 두어 구현 파일의 inline 테스트가 모두 빌드에 포함된다. |
| headless E2E | `mise run e2e` | `tests/artifacts/e2e/headless/*.screen.txt`, `*.snapshot.txt`, `*.stdout.txt` | 실제 프로세스 stdout이 terminal core 상태로 변환되는지 확인한다. |
| recorded oracle 비교 | `mise run oracle` | `tests/artifacts/oracle/*/*.actual.txt`, `*.expected.txt`, `*.snapshot.txt`, `input.decoded.txt` | Maru의 화면 결과가 기록된 reference snapshot과 같은지 확인한다. 현재 golden은 사람이 손으로 기록한 기대값이며 실제 reference terminal 캡처가 아니다. |
| 빠른 스트레스 | `mise run stress` | `tests/artifacts/stress/quick/*.screen.txt`, `*.snapshot.txt`, `*.summary.txt` | 대량 출력과 반복 resize가 terminal core 상태를 깨지 않는지 확인한다. |
| 성능 예산 측정 | `mise run perf`, GitHub `Performance` workflow(main push/수동/주간) | `tests/artifacts/perf/core.txt`, CI `maru-performance-artifacts` | terminal core hot path가 보수적인 초기 성능 guardrail 안에 있는지 확인한다. PR required check는 아니다. |
| macOS PTY opt-in | `mise run pty` | `tests/artifacts/integration/pty/*.raw.txt`, `*.screen.txt`, `*.snapshot.txt`, `*.surface.txt`, `runtime-backpressure.summary.txt`, `reader-stop.summary.txt` | macOS `openpty`가 controlled command stdout, process exit, resize를 실제 PTY로 전달하는지 확인한다. `SurfaceRuntime` 경로는 실제 PTY output이 `PtyReader -> PtyEventQueue -> RuntimeEventPump -> SurfaceRuntime -> Surface -> TerminalCore`를 통과하고, surface metadata artifact에 live handle/env가 새지 않는지 확인한다. 대량 stdout은 queue capacity 1로 marker count와 output event 수를 검증한다. reader close 경로는 출력 없는 long-running child에서 `PtyReader.stopAndJoin`이 blocking read를 정리하고 child를 reap하는지 검증한다. 환경 의존이라 기본 `check`에는 아직 넣지 않는다. |
| headless PTY 데모 | `mise run demo` | `zig-out/maru-demo/headless-pty.screen.txt`, `.snapshot.txt`, `.summary.txt` | GUI가 붙기 전에도 실제 `PTY -> PtyReader -> RuntimeEventPump -> SurfaceRuntime -> Surface -> snapshot` 경로를 사람이 바로 실행해 확인한다. 테스트 실패 판정용이 아니라 개발 중 빠른 수동 확인과 디버깅 산출물을 남기는 경로다. |
| app host smoke | `mise run app-smoke` | `zig-out/maru-app-smoke/app-host.summary.txt`, `app-host.draw-list.txt` | 실제 UI는 아직 띄우지 않는다(`visible_ui=false`). AppKit/Metal 전에 `AppWindow -> SurfaceRuntime -> RuntimeEventPump -> DrawList` frame 조립, resize routing, focused input routing을 사람이 실행해 확인한다. |
| macOS visible window smoke | `mise run test-macos-window-smoke`, `mise run macos-window-smoke` | `zig-out/maru-macos-window-smoke/window.summary.txt` | display가 있는 macOS에서 실제 AppKit 창을 띄운다(`visible_ui=true`). 계약 테스트는 summary schema를 확인하고, visible smoke는 실제 window server/AppKit lifecycle을 확인한다. display가 없는 headless 세션(SSH, GUI 없는 CI)에서는 창을 보일 수 없으므로 `visible_ui=false`로 기록하고 non-zero로 실패한다. 아직 Metal surface, font, terminal grid는 없으므로 화면 내용 검증이 아니다. |
| macOS Metal DrawList readback smoke | `mise run test-macos-metal-smoke`, `mise run macos-metal-smoke` | `zig-out/maru-macos-metal-smoke/metal.summary.txt` | display가 있는 macOS에서 실제 AppKit 창 위 CAMetalLayer에 `DrawList` 기반 placeholder 셀을 present하고, 셀 중심 픽셀을 blit-readback한다(`metal_surface=true`, `terminal_grid=true`, `glyph_text=false`). `terminal_grid=true`는 입력 cell count가 아니라 `readback_samples > 0`, `readback_non_clear_pixels == readback_samples`, `readback_failures == 0`일 때만 기록한다. 계약 테스트는 summary schema, `TerminalCore -> DrawList -> NativeMetalCell` fixture, readback 없는 false/부분 readback false case를 확인한다. display가 없는 headless 세션(SSH, GUI 없는 CI)이나 window activation 실패에서는 `visible_ui=false`, `metal_surface=false`로 기록하고 non-zero로 실패한다. 아직 실제 font/glyph atlas/text rasterization은 없다. |
| macOS CoreText font shaping/atlas-key/raster smoke | `mise run test-macos-coretext-smoke`, `mise run macos-coretext-smoke` | `zig-out/maru-macos-coretext-smoke/coretext.summary.txt` | 창이나 GPU 없이 macOS CoreText가 기본 고정폭 폰트를 resolve하고 ASCII/CJK/emoji probe 문자열을 glyph run으로 shape하는지 확인한다(`font_resolved=true`, `shaped_text=true`). `shaped_text=true`는 glyph count만 보지 않고 `ascii_glyph_present=1`, `cjk_glyph_present=1`, `emoji_glyph_present=1`, `missing_glyph_count=0`일 때만 기록한다. 또한 CoreText glyph record를 Zig `GlyphAtlas` domain cache에 넣어 `atlas_keys_ready=true`를 확인하고, 같은 `CTLine`을 CPU bitmap에 그려 `glyph_rasterized=true`, `raster_non_clear_pixels>0`인지 확인한다. fallback run은 OS/font 상태에 따라 달라질 수 있어 pass/fail 조건이 아니라 진단값으로만 남긴다. 아직 Metal texture upload, Metal text draw, pixel-perfect 비교는 없다. |
| macOS glyph texture upload smoke | `mise run test-macos-glyph-texture-smoke`, `mise run macos-glyph-texture-smoke` | `zig-out/maru-macos-glyph-texture-smoke/glyph-texture.summary.txt` | 창 없이 CoreText/CoreGraphics가 만든 CPU glyph bitmap을 Metal `RGBA8Unorm` texture에 업로드하고, 같은 texture를 blit readback해 source bitmap과 byte 단위로 같은지 확인한다(`source_rasterized=true`, `metal_texture=true`, `glyph_texture_uploaded=true`). 계약 테스트는 summary schema와 raster/GPU/upload/readback 단계별 false case(device 없음, status 비-0, readback 실패, byte mismatch, 0-ink 등)를 확인한다. display가 없거나 Metal device를 만들 수 없는 headless 세션(GUI 없는 CI 포함)에서는 `metal_texture=false`, `glyph_texture_uploaded=false`로 기록하고 non-zero로 실패한다. 아직 shader sampling, atlas packing, AppKit window 위 실제 glyph text draw, screenshot artifact는 없다. |
| renderer DrawList 계약 | `mise run test`, `mise run check` | 없음 | `RenderSnapshot`이 GPU/Metal 없이 backend-neutral `DrawList`로 변환되는지 확인한다. 현재 dirty 모델은 row 범위이므로 dirty row만 draw command로 만들고, wide glyph continuation cell은 별도 draw command로 만들지 않는다. cursor와 underline은 glyph가 아닌 overlay command로 검증한다. |
| fake font/glyph layout 계약 | `mise run test`, `mise run check` | 없음 | CoreText 없이 fake font backend로 `DrawList -> GlyphRunList` 경로를 검증한다. primary/fallback/replacement, combining mark, style/size/scale/color glyph cache key가 renderer domain data로 보존되는지 확인한다. |
| glyph atlas cache 계약 | `mise run test`, `mise run check` | 없음 | GPU texture 없이 `GlyphCacheKey -> AtlasSlot` domain cache를 검증한다. repeated key hit, raster-affecting key separation, upload byte 후보, eviction, invalidation reason이 기록되는지 확인한다. |
| facade import 경계 | `mise run check-boundaries` | 없음 | terminal/renderer/plugin/pty가 금지된 레이어를 import하지 않는지 자동으로 확인한다. |
| 전체 확인 | `mise run check` | 위 산출물 전체 | fmt-check, unit, E2E, oracle, stress, boundary, build를 한 번에 확인한다. |

## 구조화 스냅샷

`*.screen.txt`는 사람이 보기 좋지만 터미널 내부 상태를 모두 증명하지 못한다. 그래서 `*.snapshot.txt`는 `RenderSnapshot`에서 다음 상태를 함께 기록한다.

- 화면 크기
- 커서 위치와 표시 여부
- dirty region
- 각 row의 셀 텍스트
- wide/continuation/combining cell metadata
- non-default style이 있는 셀 목록

이 포맷은 현재 테스트 산출물이면서, 나중에 replay trace와 inspector가 같은 도메인 데이터를 보도록 하기 위한 첫 관측 가능성 경계다.

fixture, golden, trace 파일의 저장 규칙은 [Fixture와 Oracle 포맷](fixture-format.md)을 따른다.

GitHub `CI` workflow는 `mise run check`와 외부 오라클 실행 후 `tests/artifacts/**`를 각각 `maru-check-artifacts`, `maru-external-oracle-artifacts`로 업로드한다. 실패했을 때 로그만 보는 대신 실제 screen/snapshot/summary를 내려받아 원인을 확인하기 위한 장치다.

## 아직 완전 자동 검증이 아닌 영역

불가 이유는 다음 의미로 쓴다.

- `구현 전`: 기능이나 테스트 러너가 아직 없어서 못 검증한다. 만들면 자동화할 수 있다.
- `환경 의존`: 외부 바이너리, SSH 서버, macOS window server, GPU driver, font stack처럼 실행 환경에 따라 결과가 달라질 수 있다.
- `시스템 한계에 가까움`: 순수 headless 테스트만으로는 실제 화면이나 하드웨어 동작을 완전히 증명하기 어렵다. 대신 내부 snapshot, screenshot, 수동 산출물을 함께 남긴다.

| 영역 | 불가 이유 | 현재 한계 | 손해 | 예정 검증 경로 |
| --- | --- | --- | --- | --- |
| 실제 외부 오라클 실행 | Ghostty 다리·로컬 기본 `check`만 opt-in/환경 의존 | `mise run oracle-ext`(libvterm)와 `mise run oracle-alacritty`(Alacritty alacritty_terminal)는 CI `oracles` 잡이 매 푸시/PR에서 강제한다(golden == reference). `mise run oracle-ghostty`(Ghostty libghostty-vt)는 무거운 빌드 탓에 CI에서 제외돼 로컬 opt-in만이다. 셋 다 로컬 기본 `check`에는 미포함이고(각 reference 설치/빌드 필요), xterm 직접 실행은 비현실적이라 없다. | Ghostty 다리는 로컬 opt-in을 돌리지 않으면 golden이 검증되지 않는다. libvterm·Alacritty는 CI가 강제하지만 로컬 `check`만으로는 확인되지 않는다. | escape fixture가 늘면 세 reference로 golden을 생성/교차검증하고, Ghostty 다리의 CI 편입도 검토한다. |
| PTY/openpty controlled command | 환경 의존 | `mise run pty`가 macOS `openpty` backend로 controlled command, exit status, resize propagation, SurfaceRuntime routing, reader thread + bounded queue + RuntimeEventPump 경로를 검증한다. 대량 stdout은 capacity 1 queue로 drop 없이 marker가 보존되는지 검증한다. reader close 경로는 signal을 무시하고 출력이 없는 child에서도 `stopAndJoin`이 blocking read를 정리하고 zombie를 남기지 않는지 검증한다. 아직 기본 `mise run check`에는 포함하지 않는다. | macOS가 아닌 환경이나 로컬 PTY 정책 문제는 기본 CI만으로 잡지 못한다. PTY backpressure의 RSS/latency/UI responsiveness 성능 예산은 아직 별도 검증 전이다. macOS window/app loop가 pump를 frame/input lifecycle에 연결하거나 tab/window close에서 `stopAndJoin`을 호출하는 검증도 아직 없다. | [PTY 운영 모델](pty-operating-model.md)에 따라 `tests/integration/pty/` artifact를 남긴다. 다음 단계에서는 app host가 pump와 close lifecycle을 실제 window loop에서 호출하는 경로를 추가한다. |
| interactive shell smoke | 구현 전, 환경 의존 | 사용자의 login shell, prompt, dotfiles, locale에 따라 출력이 달라진다. | 실제 shell prompt, job control, shell startup escape 문제를 조기에 놓칠 수 있다. | PTY 구현 PR에서 `mise run pty` 같은 opt-in smoke 명령을 추가하고 artifact를 남긴다. |
| 터미널 내부 workload (tmux/vim/htop/less/ssh) | 구현 전, 환경 의존 | 실제 TUI 프로그램을 Maru PTY 안에서 돌리는 workload smoke가 아직 없다. 이들은 정답을 계산하는 오라클이 아니라 파서를 압박하는 workload다. | alt screen, 복잡한 CSI, resize/SIGWINCH, mouse 처리 회귀를 실제 프로그램으로 잡지 못한다. | PTY와 runtime pump 경로 위에 opt-in smoke로 tmux/vim/htop 등을 실행해 crash 없이 snapshot까지 도달하는지 확인한다. |
| VT parser | 구현 전 | 현재 core는 UTF-8 텍스트와 일부 control만 처리한다. | ANSI 색상, cursor movement, alternate screen, mouse mode 같은 터미널 핵심 호환성을 검증하지 못한다. | 작은 ANSI fixture를 TDD로 추가하고 oracle snapshot을 함께 늘린다. |
| autowrap/line wrap | 구현 전 | core는 마지막 열에서 셀을 덮어쓰고 줄바꿈하지 않는다(DECAWM 없음). | 폭을 넘는 셸 출력, 긴 프롬프트, man page가 손실된다. | step 3에서 pending-wrap 플래그 기반 DECAWM과 폭 초과 fixture를 추가한다. |
| wide-character(East-Asian width) | 자동 검증 중 | `Cell.width`, `Cell.continuation`, `Cell.combining`이 있고 한글/CJK/emoji의 2-cell, combining mark의 0-cell(CJK 블록 내부 U+3099/U+309A/U+302A–302F 포함)을 기본 검증한다. combining mark는 직전 출력 cell에 붙어 마지막 열·LF 직후에도 정확히 배치되고, base가 없으면 drop한다. UAX#11 전체와 ambiguous width 설정은 아직 없다. | ZWJ emoji, 국기, skin-tone, ambiguous width, box drawing alignment 같은 긴 꼬리 케이스는 아직 보장하지 못한다. | unit test(마지막 열 combining 배치, no-base drop, wide glyph backspace 포함), `mixed_width`/`combining_mark` recorded oracle, v3 snapshot metadata를 기본 `mise run check`에 포함한다. Unicode table 확장은 fixture를 추가하며 진행한다. |
| PTY 경계 분할 UTF-8 | 자동 검증 중 | `TerminalCore`가 incomplete UTF-8 tail buffer를 보존한다. 아직 invalid UTF-8 복구 정책은 별도 설계 전이다. | malformed byte stream 처리 정책은 아직 제품 UX로 확정되지 않았다. | unit test, split UTF-8 recorded oracle fixture, split chunk stress가 기본 `mise run check`에 포함된다. invalid UTF-8 정책을 정할 때 별도 fixture를 추가한다. |
| modifier/application-cursor 키 인코딩 | 구현 전 | `encodeKey`가 modifiers를 읽지 않고 normal-mode 화살표만 낸다. | Ctrl+C→0x03, Alt meta, DECCKM(SS3), CSI-u가 없어 실제 대화형 프로그램 입력이 어긋난다. | C0 control/meta/DECCKM 분기와 modifier 단위 테스트를 추가하고 키 버퍼를 확장한다. |
| GPU renderer | 부분 구현, 환경 의존, 시스템 한계에 가까움 | backend-neutral `DrawList` 계약은 있고, cursor-only 이동 dirty와 cursor/underline overlay command도 자동 검증한다. app host smoke가 `DrawList` frame까지 조립하고, macOS window smoke가 실제 AppKit 창을 띄우며, macOS Metal smoke가 `DrawList` placeholder 셀을 present하고 셀 중심 픽셀을 readback한다. macOS CoreText smoke는 GPU 없이 font stack, atlas key 후보, CPU glyph rasterization을 분리 검증하고, macOS glyph texture smoke는 CPU glyph bitmap이 Metal texture로 보존 업로드되는지 확인한다. 즉 `DrawList -> Metal` 소비 경로와 `CoreText -> glyph record -> GlyphAtlas key -> CPU bitmap -> Metal texture` 경계는 생겼지만, 아직 shader sampling이나 Metal text renderer는 아니다. 실제 화면 검증은 macOS window server, GPU driver, font stack 영향을 받는다. | frame pacing, shader sampling, 실제 cursor blink/selection 렌더링 문제를 검증하지 못한다. selection dirty는 아직 selection domain data가 없어 검증하지 않는다. placeholder 셀은 글자 모양을 검증하지 못한다. glyph texture smoke는 창 없이 texture readback만 보므로 화면에 글자가 보이는지는 증명하지 못한다. | [렌더러 전략](renderer-strategy.md)에 따라 texture sampling 기반 text draw를 붙이고, 그 뒤 GUI screenshot artifact를 연결한다. selection overlay는 selection 모델 도입 PR에서 별도 검증한다. |
| font/layout/glyph atlas | 부분 구현, 환경 의존 | fake backend 기반 `DrawList -> GlyphRunList` 계약, GPU 없는 `GlyphCacheKey -> AtlasSlot` cache 계약, macOS CoreText font resolve/glyph run/atlas key/CPU raster smoke, CoreText bitmap -> Metal texture upload smoke가 있다. 실제 glyph atlas packing 좌표와 device scale별 atlas eviction/upload policy는 아직 없다. | 실제 fallback cache 성능, Retina glyph 선명도, font 설정 오류, 실제 texture packing 문제를 검증하지 못한다. glyph id와 atlas key 후보, CPU bitmap, Metal texture 보존은 확인하지만 shader sampling과 atlas slot 좌표는 아직 확인하지 않는다. | [폰트 전략](font-strategy.md)에 따라 실제 atlas slot/texture sampling/pixel smoke는 macOS opt-in으로 추가한다. 다음 단계에서는 atlas slot이 실제 text draw shader와 연결되는 경계를 만든다. |
| workspace/surface restore | 구현 전 | 아직 surface model만 초기 구조다. | cwd/env/command/layout restore가 실제 사용자 UX로 보장되지 않는다. | [Workspace Restore 전략](workspace-restore.md)에 따라 serialized workspace fixture와 restore E2E를 추가한다. |
| Wasm plugin | 구현 전 | 현재 plugin registry는 no-op 구조다. | plugin boundary, 권한, event ABI, 실패 격리를 검증하지 못한다. | plugin hook API가 정해진 뒤 fixture plugin과 sandbox failure test를 추가한다. |
| global shortcut | 구현 전, 환경 의존 | macOS 전역 핫키 등록과 충돌 검증이 아직 없다. | quick terminal/focus UX가 terminal input과 충돌하지 않는지 증명하지 못한다. | config conflict unit test, resolver test, macOS app smoke test를 추가한다. |
| trace/replay | 구현 전 | snapshot은 있지만 event trace/replay는 아직 없다. | 실패를 시간순으로 재현하기 어렵다. | [Trace와 Replay](trace-replay.md)에 따라 terminal input/output event를 domain event로 기록하고 replay test를 추가한다. |
| OSC52 ask flow | 구현 전 | clipboard 요청을 app/platform layer로 올리는 `AppRequest.clipboard` 구현이 아직 없다. | 기본 정책이 `ask`인데도 구현자가 임시로 allow/deny shortcut을 만들 위험이 있다. | OSC52 read/write fixture, `AppRequest.clipboard` unit test, deny/allow completion test, redacted artifact를 추가한다. |
| shell integration domain event | 구현 전 | opt-in zsh hook과 shell event vocabulary는 문서화됐지만 trace schema에는 아직 들어가지 않았다. | cwd/session 복구 기능을 raw output parser나 workspace 코드가 제각각 구현할 위험이 있다. | hook fixture, `AppRequest.shell_integration` test, trace schema 갱신 PR에서 replay test를 추가한다. |
| SSH workload | 구현 전, 환경 의존 | SSH 전용 integration은 아직 실행하지 않는다. 외부 네트워크나 특정 원격 서버에 묶이지 않는 방식이 필요하다. | 원격 shell, latency, locale, terminal mode 차이를 검증하지 못한다. | 로컬 테스트 서버나 opt-in 환경변수 기반 SSH smoke test를 추가한다. |
| 긴 soak/제품 성능 예산 | 부분 구현, 환경 의존 | `mise run perf`와 GitHub `Performance` workflow는 core 기준만 측정한다. 앱 시작, 입력 지연, frame budget, RSS는 아직 없다. | GUI/PTY/renderer 성능 회귀는 아직 숫자로 실패시키지 못한다. | macOS host, PTY, renderer가 붙으면 startup, latency, memory, throughput 기준을 확장한다. |

호환성/보안 기본값(`TERM`, OSC52, bracketed paste, shell integration, command restore, plugin permission, update/telemetry, global shortcut)은 [터미널 호환성/보안 정책](terminal-compatibility-policy.md)의 검증 계획을 따른다. 새 구현 PR이 이 기본값을 바꾸려면 사용자와 먼저 논의하고, 이 매트릭스의 자동/수동 검증 경로도 함께 갱신한다.

## PR마다 확인할 질문

- 새 기능이 이 표의 어느 검증 경로에 연결되는가?
- 자동 검증이 불가능하다면 어떤 수동 검증 산출물을 남기는가?
- 새 산출물이 기존 snapshot, trace, replay, future inspector와 같은 도메인 데이터를 쓰는가?
- 한계가 새로 드러났다면 PR 설명과 사용자 보고에 적었는가?
