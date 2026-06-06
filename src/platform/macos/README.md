# `src/platform/macos`

macOS 전용 bridge를 담는 폴더다.

초기 후보 책임은 AppKit host, Metal surface, CoreText font access, openpty-backed PTY, clipboard, IME, accessibility다. PTY 운영은 [문서](../../../docs/pty-operating-model.md)를 따른다.

`window_smoke.zig`와 `appkit_window_smoke.m`은 첫 visible UI smoke다. 이 경로는 실제 터미널 화면이나 Metal renderer를 검증하지 않고, macOS window server와 AppKit lifecycle에 접근할 수 있는지만 확인한다. 계약 테스트는 `mise run test-macos-window-smoke`, 실제 창 smoke는 `mise run macos-window-smoke`다.

`metal_smoke.zig`와 `appkit_metal_smoke.m`은 첫 Metal DrawList readback smoke다. 이 경로는 아직 터미널 글자 glyph를 그리지 않지만, `TerminalCore -> DrawList`에서 만든 셀을 AppKit 창 위 CAMetalLayer에 placeholder quad로 실제 present하고 셀 중심 픽셀을 readback한다. 계약 테스트는 `mise run test-macos-metal-smoke`, 실제 Metal smoke는 `mise run macos-metal-smoke`다.

`coretext_smoke.zig`와 `coretext_smoke.m`은 첫 CoreText font shaping smoke다. 이 경로는 창과 GPU를 만들지 않고 macOS 기본 고정폭 폰트를 찾은 뒤 ASCII/CJK/emoji probe 문자열이 glyph run으로 shape되는지 확인한다. glyph count만 보지 않고 각 probe 구간이 `.notdef`가 아닌 glyph로 매핑됐는지도 확인한다. 계약 테스트는 `mise run test-macos-coretext-smoke`, 실제 CoreText smoke는 `mise run macos-coretext-smoke`다.
