# macOS 앱 호스트 경계

이 문서는 실제 macOS 제품 앱을 만들기 직전에 Swift와 Zig가 어디서 만나는지 정한다. 목적은 빨리 창을 띄우는 것이 아니라, 제품 앱이 smoke 전용 Objective-C bridge를 복제하거나 PTY/runtime 책임을 AppKit 쪽으로 끌고 가지 않게 하는 것이다.

## 현재 결정

- Swift는 지속 실행되는 `NSApplication`을 소유한다.
- Swift는 window/tab/split lifecycle, focus, `keyDown:`, close/menu/preferences, IME, accessibility 같은 macOS UX를 소유한다.
- Zig는 `PtySession`, `LivePtySession`, `SurfaceRuntime`, `RuntimeEventPump`, `FrameLoop`, keybinding resolver, renderer frame 조립을 소유한다.
- Swift는 terminal storage, PTY file descriptor, renderer atlas/resource를 직접 만지지 않는다.
- Swift가 Zig에 넘기는 값은 `src/platform/macos/app_host_abi.h`의 fixed-width C ABI record만 사용한다.
- Objective-C `*.m` smoke bridge는 삭제하지 않는다. 제품 앱 회귀와 low-level AppKit/Metal/CoreText 회귀를 분리해서 보기 위한 regression smoke로 남긴다.

## 첫 제품 앱 범위

첫 제품 앱 PR은 다음만 목표로 한다.

- shell 1개 surface를 만든다.
- 창이 계속 떠 있다.
- Swift window event loop가 Zig `FrameLoop`를 반복 호출한다.
- Swift `keyDown:` payload는 C ABI record로 정규화된 뒤 Zig keybinding resolver로 들어간다.
- window close는 Zig `FrameLoop.closeActiveLivePty`로 내려간다.

첫 제품 앱 PR에서 하지 않는 것:

- 탭/분할 UI
- workspace restore
- settings UI/runtime reload
- plugin/Wasm
- global shortcut
- IME 완성
- full VT parser 호환성

## C ABI 규칙

- ABI version은 `MARU_MACOS_APP_HOST_ABI_VERSION`으로 시작한다.
- Swift는 startup 때 `maru_macos_app_host_abi_version()`과 `maru_macos_app_host_capabilities()`를 확인한다.
- Swift와 Zig 사이에는 Swift class, Zig slice, Zig allocator-owned buffer를 직접 넘기지 않는다.
- 포인터를 넘겨야 하는 API는 어느 쪽이 해제하는지 함수 이름과 문서에 함께 적는다.
- key/resize/close 같은 입력 event는 fixed-width struct로 넘기고, 실제 app action 판정은 Zig `KeyBindingResolver`/`FrameLoop` 쪽에서 한다.

## MainActor와 thread 규칙

- Swift AppKit entrypoint는 `@MainActor` 또는 main thread에서만 window/focus/input을 만진다.
- Zig PTY reader와 event queue는 Swift main thread에 묶지 않는다.
- Swift는 display tick 또는 AppKit event에서 Zig의 non-blocking frame tick API만 호출한다.
- Zig 호출이 blocking drain을 요구하면 제품 앱 loop에 넣지 않는다. blocking wait는 smoke나 opt-in test에만 둔다.

## 검증 경로

- `mise run test-macos-app-host-abi`: C header와 Zig extern layout/version이 맞는지 확인한다.
- `mise run macos-app-host-abi-lib`: 다음 제품 Swift host가 링크할 Zig exported C ABI static library를 만든다.
- `mise run macos-app-host-swift-check`: Swift skeleton이 C header를 import하고 AppKit 타입을 type-check할 수 있는지 확인한다.
- 기존 `mise run macos-app-pty-metal-smoke`: Objective-C smoke bridge가 PTY/output/keyDown/close/render 경계를 계속 검증한다.

## 남은 한계

이번 경계 문서는 실제 제품 앱 loop를 실행하지 않는다. 다음 PR에서 `mise run macos-app-dev` 같은 실행 명령을 추가하고, 그때 summary/artifact 경로와 수동 검증 방법을 함께 문서화한다.
