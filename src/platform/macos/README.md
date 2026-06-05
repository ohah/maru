# `src/platform/macos`

macOS 전용 bridge를 담는 폴더다.

초기 후보 책임은 AppKit host, Metal surface, CoreText font access, openpty-backed PTY, clipboard, IME, accessibility다. PTY 운영은 [문서](../../../docs/pty-operating-model.md)를 따른다.

`window_smoke.zig`와 `appkit_window_smoke.m`은 첫 visible UI smoke다. 이 경로는 실제 터미널 화면이나 Metal renderer를 검증하지 않고, macOS window server와 AppKit lifecycle에 접근할 수 있는지만 확인한다. 계약 테스트는 `mise run test-macos-window-smoke`, 실제 창 smoke는 `mise run macos-window-smoke`다.
