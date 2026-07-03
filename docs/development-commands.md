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
- macOS Swift app host app shell 빌드: `mise run macos-app-build` (`zig-out/bin/maru-macos-app`를 만든다. 이 executable은 Zig ABI static library를 링크하고, Swift placeholder window 뒤에서 Zig app session ABI를 호출할 수 있어야 한다)
- macOS Swift app host app shell 실행: `mise run macos-app` (지속 실행되는 `NSApplication` window를 띄우고 Zig 쪽 interactive shell surface와 `FrameLoop`를 설정형 timer로 tick한다. 기본은 `render.frame-rate = 60`이며 Cmd+, 설정 화면에서 30~120Hz로 바꿀 수 있다. view의 `keyDown`, window resize, window close는 app session ABI로 내려간다. CoreText로 shape/raster한 glyph를 Metal로 그리며, HiDPI(Retina)와 번들된 JetBrains Mono를 쓴다. summary에 `terminal_surface=true`와 frame/output/input/resize/close 통계, `diag_*`(화면/창 scale, cell 픽셀 크기)를 남긴다)
- **렌더링·입력 디버그**: `MARU_DEBUG=1 mise run macos-app`로 켠다. ad-hoc getenv/fprintf가 아니라 진단을 데이터가 있는 곳에 둔다. (1) glyph rasterize 경로(`coretext_raster.zig`)에서 `std.log.scoped(.font_metrics)`로 `cell=…x… slot=…x…`(cache_key cell 메트릭 vs atlas slot 크기)와 codepoint/scale_milli/ink/status를 stderr로 찍는다 — cell과 slot이 어긋나면(slot ≠ cell × span) 글자 간격 버그라, 이 비교로 "m i s e" 류를 바로 잡는다. (2) 창 제목줄에 live `scr/win/cell/draw`(화면·창 backing scale, cell 픽셀, drawable 폭)를 띄운다. (3) summary 파일에 `diag_*`(화면/창 scale, cell, drawable) 필드를 덧붙인다. (4) 입력 경로 트레이싱: `SurfaceRuntime.debug_input`이 켜져 PTY로 나가는 입력 바이트를 escape해 `core->pty NB: …`로 찍는다 — 키 인코딩(`Cmd+←`→`\x01`, 기능키 `\e[5~` 등)·붙여넣기·zsh SIGWINCH redraw 시퀀스가 실제로 무엇을 보내는지 PTY 캡처 없이 본다. env 미설정 시 일반 실행/summary 계약에는 영향이 없다(로깅도 제목도 diag 필드도 안 나온다)
- **sync(2026) 게이트 관측**: `MARU_DEBUG=1`이면 `app_session.zig`의 `logSyncGateDiag`가 `std.log.scoped(.sync)`로 tick별 sync hold/투영 결정을 한 줄씩 stderr에 찍는다(`active`·`hold/timeout`·`gproj`·`cproj`·`esuadv`/`scr`=투영 unblock 실제 이유·`bsu/esu`=리더 처리 BSU/ESU 누적·`voff` 등). 폴링 렌더 루프가 라이브 프레임을 언제 붙잡고 언제 flush하는지, `maru ssh` 원격 sync 어긋남이 어디서 나는지 본다(단일 출처 [io-render-threading.md §11.6](io-render-threading.md)). 캡처한 로그는 `python3 tools/sync/analyze_sync_log.py <log>`로 half-frame(active 중 grid 투영) 원인(esu_edge/timeout/scroll/force)을 자동 분해한다. 예: `MARU_DEBUG=1 ./zig-out/Maru.app/Contents/MacOS/maru-macos-app 2> /tmp/maru-sync.log` → `python3 tools/sync/analyze_sync_log.py /tmp/maru-sync.log`.
- **제품 renderer 스크린샷**: `MARU_SCREENSHOT=/tmp/maru.ppm mise run macos-app`로 켠다. 제품 Metal renderer가 내용이 있는 첫 frame을 화면(CAMetalLayer drawable)이 아니라 같은 크기·픽셀포맷 오프스크린 텍스처에 그려 BGRA readback 후 PPM(P6)으로 그 경로에 쓰고 프로세스를 종료한다("한 frame 캡처 후 종료"). drawable은 `framebufferOnly=true`라 직접 못 읽으므로 오프스크린에 그린다. PPM은 smoke와 같은 `maru_ppm_writer.h`를 공유하며, `sips -s format png /tmp/maru.ppm --out /tmp/maru.png`로 변환해 본다. env 미설정 시 이 경로는 전혀 타지 않아 일반 실행/frame-loop present에 영향이 없다. 셀 readback gate가 없는 시각 확인용 하니스다(자동 시각 회귀 비교는 후속).
- **세팅 화면 자동 열기(시각 확인)**: `MARU_OPEN_SETTINGS=1 mise run macos-app`(또는 `MARU_OPEN_SETTINGS=1 MARU_SCREENSHOT=/tmp/s.ppm ...`)로 켠다. 첫 frame에서 세팅 화면(⌘,)을 자동으로 연다 — 스크린샷 하니스가 입력 없이 모달 상태를 캡처하게 하는 디버그 훅(MARU_DEBUG와 같은 env-gate). env 미설정이면 무동작(일반 실행은 ⌘,로 연다).
- **IME 콜백 트레이스**: `MARU_IME_DEBUG=1`(렌더링 디버그와 **독립된 게이트** — IME만 따로 켤 수 있다)이면 `MaruMetalTerminalView`가 입력기 콜백을 `[IME] …`로 stderr에 찍는다 — `keyDown`(`mods=[Cmd Ctrl Opt Shift]`·characters·keyCode), `doCommand:`(편집 selector), `insertText`/`setMarkedText`/`unmarkText`, 텍스트는 `U+XXXX` 코드포인트 + utf16 len으로 표기. 입력기가 실제로 보내는 콜백 순서·인자를 그대로 봐서 한글 조합·마지막 자모 삭제(insertText+deleteBackward 상쇄)·확정 후 커서 이동 같은 IME 동작을 실측으로 잡는다("추측 말고 캡처"). 물리 키가 어떻게 정규화되는지(keyDown 수정자/keyCode)도 이 게이트로 본다 — 이번 macOS 편집키 디버깅이 이 경로로 진행됐다.
- macOS Swift app host app shell smoke 실행: `mise run macos-app-smoke` (`MARU_MACOS_APP_SMOKE_MS=1500`으로 placeholder window를 잠깐 띄운 뒤 controlled PTY command를 Zig `LivePtySession -> SurfaceRuntime -> FrameLoop -> RendererState` 경로에 태우고 `zig-out/maru-macos-app/app.summary.txt`를 남긴다. smoke는 scripted key events와 scripted resize도 같은 app session ABI로 보내 `visible_ui=true`, `swift_host=true`, `abi_ready=true`, `terminal_surface=true`, `output_events>0`, `exit_events=1`, `key_events=2`, `terminal_input_events=2`, `resize_events=1`, `close_events=1`, `frame_prepared=true`를 확인한다. 실제 terminal glyph를 Swift window에 그리는 단계는 아니다)
- macOS 배포용 .dmg 빌드: `mise run macos-dmg` (`macos-app-bundle`로 `Maru.app`을 ReleaseFast로 만든 뒤 codesign(Developer ID, hardened runtime, timestamp) → `dist/Maru-<버전>-arm64.dmg` 생성/서명 → `notarytool submit --wait`로 Apple 공증 → `stapler staple` → `spctl` 검증까지 한 번에 한다. arm64 단일 빌드이고 최소 macOS는 11.0(Big Sur, `build.zig`의 `default_target` os_version_min과 `MaruAppHost-Info.plist`의 `LSMinimumSystemVersion`을 함께 11.0으로 맞춘다). **사전조건 두 가지**: ① 키체인에 Developer ID Application 인증서가 있어야 한다(서명 인증서 이름은 `-Dmacos-sign-identity=...`로 덮어쓸 수 있고 기본값은 Payhere 인증서다). ② 공증 자격증명을 notarytool 키체인 프로파일에 미리 저장해 둔다 — `xcrun notarytool store-credentials maru-notary --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD"`(프로파일 이름은 `-Dmacos-notary-profile=...`로 변경 가능). 앱 전용 암호 같은 비밀값은 빌드 스크립트·리포에 두지 않고 키체인 프로파일에만 있다. 산출물 `dist/`는 git에 커밋하지 않는다)
- macOS 배포용 **universal** .dmg 빌드: `mise run macos-dmg-universal` (= `sh tools/build-macos-universal-dmg.sh`. arm64 + x86_64를 각각 빌드해 `lipo`로 합친 universal `Maru.app`을 만들고, codesign → `.app` 공증+staple → `dist/Maru-<버전>-universal.dmg` 생성/서명 → dmg 공증+staple → `spctl` 검증까지 한 번에 한다. Intel·Apple Silicon에서 모두 실행된다. 사전조건은 `macos-dmg`와 동일(키체인 Developer ID 인증서 + `maru-notary` 프로파일; `MARU_SIGN_IDENTITY`/`MARU_NOTARY_PROFILE`로 덮어쓰기). x86_64 cross 빌드의 SDK 통합은 `build.zig`가 처리한다. 배포·업데이트 전략 전체는 [배포·업데이트 전략](distribution.md)을 단일 출처로 둔다. 공증 2회라 `macos-dmg`보다 느리므로 평소 개발엔 arm64 `macos-dmg`를 쓴다)
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
