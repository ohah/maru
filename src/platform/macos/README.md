# `src/platform/macos`

macOS 전용 bridge를 담는 폴더다.

초기 후보 책임은 AppKit host, Metal surface, CoreText font access, openpty-backed PTY, clipboard, IME, accessibility다. PTY 운영은 [문서](../../../docs/pty-operating-model.md)를 따른다.

현재 `*.m` 파일들은 제품 UI가 아니라 smoke bridge다. 얇은 C ABI로 Zig에서 AppKit/Metal/CoreText의 저수준 경계를 검증하기 위해 Objective-C로 둔다. Swift는 실제 macOS app host를 시작할 때 도입한다. 그때 대상은 지속 실행되는 `NSApplication`, window/tab/split lifecycle, menu/command, preferences, IME/accessibility/focus/input routing 같은 제품 UX 영역이다. Swift app host가 생겨도 기존 Objective-C smoke는 low-level regression smoke로 남긴다.

`window_smoke.zig`와 `appkit_window_smoke.m`은 첫 visible UI smoke다. 이 경로는 실제 터미널 화면이나 Metal renderer를 검증하지 않고, macOS window server와 AppKit lifecycle에 접근할 수 있는지만 확인한다. 계약 테스트는 `mise run test-macos-window-smoke`, 실제 창 smoke는 `mise run macos-window-smoke`다.

`metal_smoke.zig`와 `appkit_metal_smoke.m`은 첫 Metal DrawList readback smoke다. 이 경로는 아직 터미널 글자 glyph를 그리지 않지만, `TerminalCore -> DrawList`에서 만든 셀을 AppKit 창 위 CAMetalLayer에 placeholder quad로 실제 present하고 셀 중심 픽셀을 readback한다. 계약 테스트는 `mise run test-macos-metal-smoke`, 실제 Metal smoke는 `mise run macos-metal-smoke`다.

`coretext_smoke.zig`와 `coretext_smoke.m`은 첫 CoreText font shaping/glyph-frame/raster smoke다. 이 경로는 창과 GPU를 만들지 않고 macOS 기본 고정폭 폰트를 찾은 뒤 ASCII/CJK/emoji probe 문자열이 glyph run으로 shape되는지 확인한다. glyph count만 보지 않고 각 probe 구간이 `.notdef`가 아닌 glyph로 매핑됐는지도 확인한다. 그 다음 Zig 쪽 `GlyphRunList -> GlyphFrame` 준비 계약에 glyph id/font id 후보를 넣어 frame과 atlas 후보가 만들어지는지도 확인하고, 같은 `CTLine`을 CPU bitmap에 그려 non-clear pixel이 생기는지도 확인한다. 계약 테스트는 `mise run test-macos-coretext-smoke`, 실제 CoreText smoke는 `mise run macos-coretext-smoke`다. 아직 Metal texture upload나 실제 화면 glyph draw 검증은 아니다.

`glyph_texture_smoke.zig`와 `glyph_texture_smoke.m`은 첫 CoreText bitmap -> Metal texture upload smoke다. 이 경로는 창을 만들지 않고 CoreText/CoreGraphics가 만든 CPU glyph bitmap을 Metal texture에 업로드한 뒤 blit readback으로 source bitmap과 같은지 확인한다. 계약 테스트는 `mise run test-macos-glyph-texture-smoke`, 실제 texture smoke는 `mise run macos-glyph-texture-smoke`다. 아직 shader sampling이나 실제 화면 glyph draw 검증은 아니다.

`glyph_text_smoke.zig`와 `appkit_glyph_text_smoke.m`은 첫 glyph texture shader sampling smoke다. 이 경로는 실제 AppKit 창과 CAMetalLayer를 만들고, CoreText/CoreGraphics가 만든 CPU glyph bitmap을 Metal texture로 올린 뒤 fragment shader로 샘플링한다. source glyph의 ink 위치를 drawable 좌표로 변환해 blit readback하고, 선택한 모든 샘플이 clear 색이 아니며 배경보다 충분히 밝고 `glyph-text-frame.ppm` screenshot artifact가 쓰였을 때만 성공한다. 계약 테스트는 `mise run test-macos-glyph-text-smoke`, 실제 화면 smoke는 `mise run macos-glyph-text-smoke`다. 아직 제품 terminal renderer, atlas packing, cell-grid text layout 검증은 아니다.
