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
- live PTY app host smoke 실행: `mise run app-pty-smoke` (`zig-out/maru-app-pty-smoke/app-pty.summary.txt`, `app-pty.raw.txt`, `app-pty.screen.txt`, `app-pty.snapshot.txt`, `app-pty.frame.txt`를 남긴다. 실제 PTY output이 app host renderer frame까지 들어가는지 검증하지만 아직 실제 UI는 아니다)
- macOS visible window smoke 실행: `mise run macos-window-smoke` (창이 너무 빨리 닫히면 `MARU_WINDOW_SMOKE_MS`로 노출 시간을 ms 단위로 늘려 수동 확인한다. 기본 1500ms, 상한 600000ms)
- macOS window smoke 계약 테스트: `mise run test-macos-window-smoke`
- macOS Metal 제품 atlas shader sampling smoke 실행: `mise run macos-metal-smoke` (창이 너무 빨리 닫히면 `MARU_METAL_SMOKE_MS`로 노출 시간을 ms 단위로 늘려 수동 확인한다. 기본 1500ms, 상한 600000ms)
- macOS Metal smoke 계약 테스트: `mise run test-macos-metal-smoke`
- macOS live PTY Metal smoke 실행: `mise run macos-app-pty-metal-smoke` (controlled PTY command output과 scripted input roundtrip을 실제 AppKit/CAMetalLayer 창의 CoreText glyph atlas shader sampling까지 태우고 `zig-out/maru-macos-app-pty-metal-smoke/app-pty-metal-frame.ppm` screenshot artifact를 남긴다. 창이 너무 빨리 닫히면 `MARU_APP_PTY_METAL_SMOKE_MS`로 조절한다. 아직 AppKit 키 이벤트나 interactive shell loop는 아니다)
- macOS live PTY Metal smoke 계약 테스트: `mise run test-macos-app-pty-metal-smoke`
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
- macOS PTY opt-in 테스트: `mise run pty`
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
