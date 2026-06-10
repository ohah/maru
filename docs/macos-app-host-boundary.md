# macOS 앱 호스트 경계

이 문서는 실제 macOS 제품 앱을 만들기 직전에 Swift와 Zig가 어디서 만나는지 정한다. 목적은 빨리 창을 띄우는 것이 아니라, 제품 앱이 smoke 전용 Objective-C bridge를 복제하거나 PTY/runtime 책임을 AppKit 쪽으로 끌고 가지 않게 하는 것이다.

## 정책: 네이티브 레이어는 최대한 얇게

**Swift/Objective-C 같은 네이티브 의존성은 최소화한다.** 플랫폼에 묶이지 않는 모든 로직(계산·결정·정책)은 Zig에 두고 `std.testing`으로 테스트한다. 네이티브 레이어는 다음만 한다: AppKit/window lifecycle, focus/input, Metal draw 호출, ABI record marshaling. **비즈니스 로직·수치 계산·상태 결정은 네이티브에 두지 않는다** — 네이티브엔 단위 테스트 프레임워크가 없어 회귀를 못 막고, Linux/headless에서 재사용도 안 되기 때문이다.

판단 기준: "이 코드를 테스트하려면 window/run loop가 필요한가?" 아니라면 Zig로 간다. 예: 창 backing 픽셀 → grid(cols/rows) 계산, resize 중복 방지(같은 size+scale skip), backing scale → 폰트 device 픽셀 크기는 모두 Zig가 소유하고(dev session의 `gridFromBacking`·resize dedup, `renderer.deviceFontSizeFromMilli`), Swift는 AppKit 값(backing 픽셀·scale)만 모아 ABI로 넘긴다. grid 계산은 별도 export로 빼지 않고 dev session이 resize 처리 중 자기 cell 메트릭으로 내부에서 직접 한다(Swift가 부르는 grid helper export는 없다).

## 현재 결정

- Swift는 지속 실행되는 `NSApplication`을 소유한다.
- Swift는 window/tab/split lifecycle, focus, `keyDown:`, close/menu/preferences, IME, accessibility 같은 macOS UX를 소유한다.
- Zig는 `PtySession`, `LivePtySession`, `SurfaceRuntime`, `RuntimeEventPump`, `FrameLoop`, keybinding resolver, renderer frame 조립, 그리고 grid 계산·resize 중복 방지·device 픽셀 메트릭 같은 플랫폼 비의존 로직을 소유한다.
- Swift는 terminal storage, PTY file descriptor, renderer atlas/resource를 직접 만지지 않는다.
- Swift가 Zig에 넘기는 값은 `src/platform/macos/app_host_abi.h`의 fixed-width C ABI record만 사용한다. cols/rows 같은 파생값은 Swift가 계산하지 않는다. Swift는 backing 픽셀·scale만 resize 이벤트로 넘기고, dev session(Zig)이 자기 cell 메트릭으로 grid를 내부에서 계산한다.
- Objective-C `*.m` smoke bridge는 삭제하지 않는다. 제품 앱 회귀와 low-level AppKit/Metal/CoreText 회귀를 분리해서 보기 위한 regression smoke로 남긴다.

## 현재 제품 앱 dev shell 범위

현재 dev shell PR은 다음만 목표로 한다.

- Swift `@main` entrypoint가 실제 `NSApplication`을 실행한다.
- Swift가 Zig C ABI static library를 링크하고 startup 때 capability/version을 확인한다.
- terminal window(`MaruMetalTerminalView`, CAMetalLayer)가 계속 떠 있고, dev session의 shell glyph와 반전 블록 커서를 그린다.
- Swift는 opaque dev session handle만 보유하고, Zig가 shell surface, `LivePtySession`, `SurfaceRuntime`, `RuntimeEventPump`, `FrameLoop`, `RendererState`를 소유한다.
- Swift timer가 Zig `maru_macos_app_dev_session_tick`을 반복 호출해 frame loop를 진행하고, metal generation이 바뀐 tick에만 lean renderer로 다시 그린다(idle tick은 재드로우 생략).
- terminal view의 `keyDown`, window resize, window close가 fixed-width C ABI record를 통해 Zig dev session으로 내려간다. resize는 backing 픽셀·scale만 넘기고 grid(cols/rows)는 Zig가 실제 cell 메트릭으로 계산한다.
- smoke 실행은 `zig-out/maru-macos-app-dev/app-dev.summary.txt`에 `visible_ui=true`, `swift_host=true`, `abi_ready=true`, `terminal_surface=true`, `terminal_surface_note=zig_runtime_rendered_to_swift_cametal_layer`, `metal_renderer_created=true`, `metal_frames_drawn>0`, `frame_prepared=true`, `output_events>0`, `exit_events=1`, `key_events=2`, `terminal_input_events=2`, `resize_events=1`, `close_events=1`을 남긴다.

여기까지로 dev session의 shell glyph·커서가 실제 Swift window에 그려지고, resize cell 수도 실제 CoreText font metrics(advance×line-height)와 분수 backing scale에서 Zig가 계산한다. 렌더는 **fixed-cell pixel layout**이다(각 cell을 고정 픽셀 사각형 col×cw, row×ch에 두고 drawable 크기로 NDC 투영 — 창을 키우면 글자가 늘어나는 대신 더 많은 cell이 보인다).

현재 dev shell에서 아직 하지 않는 것:

- underline overlay 렌더(SGR 4의 밑줄 선 — hover 밑줄과 같은 부분-사각형 기법 재사용 가능)
- 탭/분할 UI (선택/클립보드는 구현됨 — 아래)
- workspace restore
- settings UI/runtime reload
- plugin/Wasm
- global shortcut
- IME preedit(조합 중 글자) 표시·후보창 커서 위치(1단계 조합/확정·레이아웃 독립 단축키는 완료)
- full VT parser 호환성(alternate screen, scroll region, mouse mode 등)

## C ABI 규칙

- ABI version은 `MARU_MACOS_APP_HOST_ABI_VERSION`으로 시작한다.
- Swift는 startup 때 `maru_macos_app_host_abi_version()`과 `maru_macos_app_host_capabilities()`를 확인한다.
- Swift와 Zig 사이에는 Swift class, Zig slice, Zig allocator-owned buffer를 직접 넘기지 않는다.
- 포인터를 넘겨야 하는 API는 어느 쪽이 해제하는지 함수 이름과 문서에 함께 적는다.
- key/resize/close 같은 입력 event는 fixed-width struct로 넘기고, 실제 app action 판정은 Zig `KeyBindingResolver`/`FrameLoop` 쪽에서 한다.
- status는 "치명적 세션 fault"와 "이 한 event만 거부됨", "정상 종료"를 구분한다. host는 셋을 다르게 처리한다.
  - per-event 거부(`KeyFailed`/`ResizeFailed`): 닫힌 pane의 late input 등. 앱을 죽이지 않고 무시·기록만 한다. Zig dev session도 이미 종료된 세션의 key/resize는 fail이 아니라 ignored로 닫는다.
  - 정상 종료(`SessionEnded`): `tick`이 PTY 셸 종료(exit/read_error)를 관측하면 ok 대신 이 status를 올린다. host는 frame loop tick을 멈추고 우아하게(exitCode 0) 내려간다. 죽은 세션을 계속 tick하지 않는다.
  - 세션 fault(`TickFailed`/`CreateFailed` 등): 앱을 비정상 종료(exitCode 1)한다.
- `*_close`는 idempotent하지만 `*_destroy`는 단발성이다. host는 `destroy` 직후 handle을 비워 재호출(use-after-free)을 막는다.

## MainActor와 thread 규칙

- Swift AppKit entrypoint는 `@MainActor` 또는 main thread에서만 window/focus/input을 만진다.
- Zig PTY reader와 event queue는 Swift main thread에 묶지 않는다.
- Swift는 display tick 또는 AppKit event에서 Zig의 non-blocking frame tick API만 호출한다.
- Zig 호출이 blocking drain을 요구하면 제품 앱 loop에 넣지 않는다. blocking wait는 smoke나 opt-in test에만 둔다.

## 검증 경로

- `mise run test-macos-app-host-abi`: C header와 Zig extern layout/version이 맞는지 확인한다.
- `mise run macos-app-host-abi-lib`: Swift host가 링크할 Zig exported C ABI static library를 만든다.
- `mise run macos-app-host-swift-check`: Swift host가 C header를 import하고 AppKit 타입을 type-check할 수 있는지 확인한다.
- `mise run macos-app-dev-build`: Swift host executable을 만들고 Zig static ABI library를 링크한다.
- `mise run macos-app-dev-smoke`: 실제 `NSApplication` placeholder window를 잠깐 띄우고 controlled PTY command, scripted key events, scripted resize, app close가 Zig dev session의 `FrameLoop`까지 도달했는지 summary에 `terminal_surface=true`, `frame_loop_ticks`, `output_events`, `exit_events`, `key_events`, `terminal_input_events`, `resize_events`, `close_events`, renderer frame 통계로 남긴다.
- `mise run macos-app-dev`: 같은 executable을 smoke timeout 없이 실행해 사용자가 window lifecycle을 수동 확인한다. 이때 Zig session은 interactive shell을 띄우지만 아직 Swift window에 terminal glyph를 그리지는 않는다.
- 기존 `mise run macos-app-pty-metal-smoke`: Objective-C smoke bridge가 PTY/output/keyDown/close/render 경계를 계속 검증한다.

## 남은 한계

현재 dev shell은 실제 제품 앱 loop와 Zig shell surface/frame loop를 함께 실행하고, `MaruMetalTerminalView`(CAMetalLayer)에 dev session의 shell glyph와 반전 블록 커서를 그리며, key/resize/close event를 Zig dev session ABI로 내려보낸다. resize cell 수는 실제 CoreText font metrics에서 Zig가 계산한다(`metal_renderer_created`/`metal_frames_drawn`로 gate). 스크롤백은 구현돼 휠/Shift+PageUp으로 과거를 볼 수 있고(타이핑하면 live로 복귀), resize 시 활성 화면을 새 폭으로 reflow하고 넘치는 줄은 스크롤백으로 민다(Ghostty 오라클로 그리드+커서 검증). 스크롤 입력도 Swift는 raw 값만 넘긴다 — 휠은 델타 포인트+정밀 여부를(`scroll_wheel`), Shift+PageUp/Down은 방향만(`scroll_page`) 보내고, 줄 수·page 크기(rows-1) 환산·1줄 미만 델타 누적·NaN/clamp 가드는 권위 있는 cell 메트릭·rows를 가진 Zig가 한다(네이티브 최소화). alt screen(vim/less)에서는 같은 스크롤이 화살표 키로 변환돼 프로그램에 전달된다(xterm alternate scroll, DECSET 1007 기본 on) — 휠/트랙패드와 Shift+PageUp/Down이 같은 경로를 타며, 변환 시퀀스는 배칭해 한 번에 쓴다. 렌더는 fixed-cell pixel layout이라 창 크기에 따라 glyph가 늘어나지 않는다(창을 키우면 cell이 더 보임). 마우스 드래그 선택과 Cmd+C 복사가 동작한다 — Swift는 마우스 raw 좌표(backing px)와 Cmd+C만 처리하고, 셀 변환·선택 모델(절대 행 좌표, 스크롤 추적·eviction 보정)·텍스트 추출(soft-wrap은 줄바꿈 없이 합침)은 Zig가 소유한다. Cmd+V 붙여넣기도 동작한다 — 개행 정규화(\n→\r)와 bracketed paste(DECSET 2004) 감싸기는 Zig(core.encodePaste)가 하고, 클립보드 읽기/쓰기(NSPasteboard)와 URL 열기(NSWorkspace)만 OS API라 Swift다. Cmd+C/Cmd+V는 Shift/Option/Control이 동반되지 않은 정확한 Cmd 조합에서만 동작한다(다른 조합은 키 인코더로). Cmd+클릭은 그 위치의 URL을 열고, Cmd+hover는 URL에 전경색 밑줄을 긋고 마우스 커서를 pointingHand로 바꾼다(평소엔 iBeam) — URL 인식·밑줄 투영은 Zig, 커서 모양 설정(NSCursor)과 mouseMoved 추적(NSTrackingArea)만 Swift다(ABI v17 mouse/copy_text/paste_text/url_at/hover). 커서 깜빡임은 dev session이 30Hz tick으로 토글한다(500ms 반주기, DECSCUSR steady·?25l은 고정, 입력/출력 시 보이는 위상으로 리셋 — off 위상은 커서 투영 생략으로 그려서 새 렌더 경로 없음). 탭/분할 UI는 아직 없다.
