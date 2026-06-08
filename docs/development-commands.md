# 개발 명령

Maru 작업에서 사용하는 기본 명령이다.

## 도구

- 도구 설치/선택: `mise install`
- Zig 버전 확인: `zig version`
- mise가 선택한 Zig 확인: `mise current zig`

테스트된 Zig 버전은 정확히 `0.16.0`이다(`.mise.toml`, `build.zig.zon`의 `minimum_zig_version`). 0.16 개발 주기에서 `std.Io`(I/O 인터페이스), Writer/Reader, process 진입 API가 크게 바뀌었으므로, 같은 `0.16.0`이라도 다른 스냅샷/커밋에서는 빌드가 깨질 수 있다. 빌드가 std API 불일치로 실패하면 먼저 `mise current zig`로 정확한 버전을 확인한다.

## 빌드와 테스트

- 빌드: `mise run build`
- headless PTY 데모 실행: `mise run demo`
- app host smoke 실행: `mise run app-smoke` (`zig-out/maru-app-smoke/app-host.summary.txt`, `app-host.draw-list.txt`, `app-host.glyph-frame.txt`를 남긴다. 아직 실제 UI는 아니다)
- app frame loop smoke 실행: `mise run app-loop-smoke` (`zig-out/maru-app-loop-smoke/app-loop.summary.txt`, `app-loop.frames.txt`, `app-loop.screen.txt`를 남긴다. 실제 AppKit event loop는 아니지만, output frame, idle frame, termination frame을 반복 tick으로 만들 수 있는지 검증한다)
- live PTY app frame loop smoke 실행: `mise run app-pty-loop-smoke` (`zig-out/maru-app-pty-loop-smoke/app-pty-loop.summary.txt`, `app-pty-loop.frames.txt`, `app-pty-loop.raw.txt`, `app-pty-loop.screen.txt`, `app-pty-loop.snapshot.txt`를 남긴다. 실제 PTY reader thread와 반복 `FrameLoop`를 함께 검증하지만 아직 실제 UI는 아니다. PTY event drain은 기본 5000ms deadline을 갖고, summary에 `drain_timeout_ms`를 남긴다)
- interactive shell app frame loop smoke 실행: `mise run app-pty-interactive-loop-smoke` (`zig-out/maru-app-pty-interactive-loop-smoke/app-pty-loop.summary.txt`, `app-pty-loop.frames.txt`, `app-pty-loop.raw.txt`, `app-pty-loop.screen.txt`, `app-pty-loop.snapshot.txt`를 남긴다. `$MARU_INTERACTIVE_SHELL` 또는 `$SHELL -i`를 실행하고, `FrameLoop.handleKeyEvent -> KeyBindingResolver -> SurfaceRuntime.writeInput` 경계로 marker command를 보내 반복 frame artifact까지 확인한다. 사용자 dotfile/prompt escape 영향을 받으므로 기본 `check`에는 넣지 않는다. PTY event drain은 기본 5000ms deadline을 갖고, summary에 `drain_timeout_ms`를 남긴다)
- live PTY app host smoke 실행: `mise run app-pty-smoke` (`zig-out/maru-app-pty-smoke/app-pty.summary.txt`, `app-pty.raw.txt`, `app-pty.screen.txt`, `app-pty.snapshot.txt`, `app-pty.frame.txt`를 남긴다. 실제 PTY output이 app host renderer frame까지 들어가는지 검증하지만 아직 실제 UI는 아니다. PTY event drain은 기본 5000ms deadline을 갖고, summary에 `drain_timeout_ms`를 남긴다)
- macOS visible window smoke 실행: `mise run macos-window-smoke` (창이 너무 빨리 닫히면 `MARU_WINDOW_SMOKE_MS`로 노출 시간을 ms 단위로 늘려 수동 확인한다. 기본 1500ms, 상한 600000ms)
- macOS window smoke 계약 테스트: `mise run test-macos-window-smoke`
- macOS Metal 제품 atlas shader sampling smoke 실행: `mise run macos-metal-smoke` (창이 너무 빨리 닫히면 `MARU_METAL_SMOKE_MS`로 노출 시간을 ms 단위로 늘려 수동 확인한다. 기본 1500ms, 상한 600000ms)
- macOS Metal smoke 계약 테스트: `mise run test-macos-metal-smoke`
- macOS live PTY Metal smoke 실행: `mise run macos-app-pty-metal-smoke` (controlled PTY command output과 AppKit synthetic `keyDown:`에서 얻은 key event가 app host keybinding resolver를 통과하는 roundtrip을 실제 AppKit/CAMetalLayer 창의 CoreText glyph atlas shader sampling까지 태우고 `zig-out/maru-macos-app-pty-metal-smoke/app-pty-metal-frame.ppm` screenshot artifact를 남긴다. 마지막 visible frame 뒤에는 같은 Metal terminal window의 AppKit close delegate가 Zig callback을 통해 `FrameLoop.closeActiveLivePty -> LivePtyRegistry.closeActive -> LivePtySession.closeAndDetach` 경로를 호출하고, `terminal_close_*`, window close, registry mapping 제거 gate도 summary에 남긴다. PTY ready marker와 종료 drain은 기본 5000ms deadline을 갖고, summary에 `drain_timeout_ms`를 남긴다. 창이 너무 빨리 닫히면 `MARU_APP_PTY_METAL_SMOKE_MS`로 조절한다. 이 controlled smoke 자체는 실제 shell startup이나 제품 tab/window close button 검증이 아니다)
- macOS interactive shell live PTY Metal smoke 실행: `mise run macos-app-pty-interactive-metal-smoke` (`$MARU_INTERACTIVE_SHELL` 또는 `$SHELL -i`를 실제 AppKit/CAMetalLayer 창 경로에 태우고, AppKit synthetic `Cmd+B`에서 얻은 key event가 app host keybinding resolver를 통과해 marker command와 `exit`를 shell에 보내는지 확인한다. `zig-out/maru-macos-app-pty-interactive-metal-smoke/` 아래 raw/screen/snapshot/screenshot artifact를 남긴다. prompt/dotfile 영향을 받는 실제 shell을 visible renderer에 연결하지만, 아직 사용자가 계속 타이핑하는 제품 event loop는 아니다)
- macOS live PTY Metal manual keyDown smoke 실행: `MARU_APP_PTY_METAL_KEYDOWN_SOURCE=manual MARU_APP_PTY_METAL_KEYDOWN_MS=15000 mise run macos-app-pty-metal-smoke` (Metal terminal window가 뜨면 사용자가 `Cmd+B`를 직접 누른다. 이 경로는 물리 키보드 -> 같은 Metal terminal window의 AppKit `keyDown:` -> Zig `terminal.KeyEvent` -> app host resolver -> PTY write -> Metal screenshot까지 확인하지만, 여전히 한 번의 smoke이고 지속 실행되는 제품 shell loop는 아니다)
- macOS live PTY Metal smoke 계약 테스트: `mise run test-macos-app-pty-metal-smoke`
- macOS Swift/Zig app host ABI 계약 테스트: `mise run test-macos-app-host-abi` (Swift 제품 app host가 호출할 C ABI version, ownership capability, key/resize DTO layout을 Zig와 C header 양쪽에서 검증한다)
- macOS Swift/Zig app host ABI static library 빌드: `mise run macos-app-host-abi-lib` (Swift host가 링크할 Zig exported C ABI static library를 `zig-out/lib/`에 만든다. 이 명령 자체는 앱을 실행하지 않는다)
- macOS Swift app host type-check: `mise run macos-app-host-swift-check` (`MaruAppHost.swift`가 `app_host_abi.h`를 import하고 AppKit 타입을 type-check할 수 있는지 확인한다)
- macOS Swift app host dev shell 빌드: `mise run macos-app-dev-build` (`zig-out/bin/maru-macos-app-dev`를 만든다. 이 executable은 Zig ABI static library를 링크하고, Swift placeholder window 뒤에서 Zig dev session ABI를 호출할 수 있어야 한다)
- macOS Swift app host dev shell 실행: `mise run macos-app-dev` (지속 실행되는 `NSApplication` placeholder window를 띄우고 Zig 쪽 interactive shell surface와 `FrameLoop`를 30Hz timer로 tick한다. 아직 Metal terminal view가 아니므로 화면은 placeholder지만 summary에는 `terminal_surface=true`와 frame/output 통계가 남는다)
- macOS Swift app host dev shell smoke 실행: `mise run macos-app-dev-smoke` (`MARU_MACOS_APP_DEV_SMOKE_MS=1500`으로 placeholder window를 잠깐 띄운 뒤 controlled PTY command를 Zig `LivePtySession -> SurfaceRuntime -> FrameLoop -> RendererState` 경로에 태우고 `zig-out/maru-macos-app-dev/app-dev.summary.txt`를 남긴다. `visible_ui=true`, `swift_host=true`, `abi_ready=true`, `terminal_surface=true`, `output_events>0`, `exit_events=1`, `frame_prepared=true`를 확인한다. 실제 terminal glyph를 Swift window에 그리는 단계는 아니다)
- macOS CoreText font shaping/raster smoke 실행: `mise run macos-coretext-smoke` (창이나 GPU 없이 CoreText font resolve, glyph run 생성, `RendererState -> RenderFrame` 준비 계약, 제품 후보 `coretext_raster.zig` wrapper와 smoke native bridge를 통한 `GlyphRasterFrame` byte 생성, CPU bitmap raster를 확인한다)
- macOS CoreText smoke 계약 테스트: `mise run test-macos-coretext-smoke`
- macOS glyph texture smoke 실행: `mise run macos-glyph-texture-smoke` (창 없이 CoreText CPU bitmap을 Metal texture에 업로드하고 readback한다)
- macOS glyph texture smoke 계약 테스트: `mise run test-macos-glyph-texture-smoke`
- macOS glyph text smoke 실행: `mise run macos-glyph-text-smoke` (CoreText glyph texture를 실제 AppKit/CAMetalLayer 창에서 shader sampling으로 그리고 readback한다. `zig-out/maru-macos-glyph-text-smoke/glyph-text-frame.ppm` screenshot artifact도 남긴다. 창이 너무 빨리 닫히면 `MARU_GLYPH_TEXT_SMOKE_MS`로 노출 시간을 ms 단위로 늘린다. 기본 1500ms, 상한 600000ms)
- macOS glyph text smoke 계약 테스트: `mise run test-macos-glyph-text-smoke`
- 테스트: `mise run test`
- E2E 테스트: `mise run e2e`
- 오라클 비교 테스트: `mise run oracle`
- 외부 오라클(opt-in, libvterm 필요): `mise run oracle-ext`
- 외부 오라클(opt-in, Ghostty libghostty-vt 필요): `mise run oracle-ghostty`
- 외부 오라클(opt-in, Alacritty Rust dumper 필요): `mise run oracle-alacritty`
- 빠른 스트레스 테스트: `mise run stress`
- 긴 opt-in 스트레스 테스트: `mise run stress-soak`
- 성능 예산 측정: `mise run perf`
- macOS PTY opt-in 테스트: `mise run pty` (macOS `openpty` controlled command, SurfaceRuntime routing, resize, reader close/reap, bounded queue stress, 그리고 `$MARU_INTERACTIVE_SHELL` 또는 `$SHELL`을 `-i`로 실행하는 interactive shell smoke를 검증한다. interactive shell smoke는 `tests/artifacts/integration/pty/interactive-shell.*` raw/screen/snapshot/summary artifact를 남기지만, 사용자 dotfile/prompt escape 영향을 받으므로 기본 `mise run check`에는 넣지 않는다)
- 포맷: `mise run fmt`
- 포맷 검사(변경 없이): `mise run fmt-check`
- facade import 경계 검사: `mise run check-boundaries`
- 전체 확인: `mise run check`
- Zig 테스트 직접 실행: `zig build test`

## 완료 전 확인

코드나 빌드 설정을 바꾼 PR은 기본적으로 다음을 통과해야 한다.

```sh
mise run check
git diff --check
```

문서만 바꾼 PR은 `git diff --check`를 최소 검증으로 사용한다. 다만 문서가 명령, 구조, 테스트 경로를 바꾸면 관련 명령도 함께 실행한다.
