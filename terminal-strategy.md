# Maru 터미널 개발 계획

작성일: 2026-06-03
배경: Ghostty를 참고하면서, 더 작고 커스텀하기 쉬운 macOS 우선 네이티브 터미널을 만든다.

이 문서는 대화 내용을 그대로 옮긴 것이 아니라, 실제 개발을 시작하기 위한 결정 로그와 작업 계획이다.

## 1. 제품 방향

Maru는 IDE 터미널이나 Warp식 워크플로우 제품이 아니라, 가볍고 빠른 네이티브 셸 포지션을 목표로 한다.

목표:

- 기본기가 좋은 터미널
- 작고 빠른 네이티브 앱
- cmux 정도의 단순한 탭 경험
- 설정과 키바인딩 커스텀이 쉬운 구조
- 나중에 WASM 플러그인으로 확장 가능한 구조
- macOS 우선 개발
- 장기적으로 Windows, Linux, WebGPU 타깃을 고려할 수 있는 코어 구조

처음부터 하지 않을 것:

- tmux 대체
- IDE형 워크스페이스 제품
- Warp식 command block UI
- AI 터미널
- 클라우드/계정 기반 제품
- 플러그인 플랫폼 우선 제품
- 첫 버전부터 완전한 크로스 플랫폼 앱

짧게 정리하면:

```text
Ghostty = 고품질, 고기능 네이티브 터미널
Maru    = 더 작고 단순한 네이티브 셸 + 쉬운 커스텀
```

## 2. 1차 타깃

처음에는 macOS만 고려한다.

권장 스택:

```text
호스트 앱: Swift/AppKit
코어:      Zig
렌더러:    Metal
터미널 코어: libghostty-vt 또는 Ghostty에서 배운 구조를 facade 뒤에 숨김
장기 웹:   WebGPU only
```

SwiftUI 레이아웃을 핵심으로 삼는 것이 아니다. Swift/AppKit은 macOS 앱으로서 필요한 얇은 호스트 레이어만 맡는다.

Swift/AppKit이 맡을 것:

- `NSWindow` / `NSView`
- 키 입력
- IME / marked text
- 메뉴
- 클립보드
- 포커스
- 필요한 경우 drag/drop
- 추후 접근성

Zig가 맡을 것:

- 터미널/session 모델
- 탭 모델
- action registry
- config parser와 hot reload
- 터미널 코어 facade
- render snapshot 생성
- Metal renderer
- 향후 backend 경계

## 3. 핵심 아키텍처

Ghostty나 `libghostty-vt`에 직접 의존하지 말고, 반드시 로컬 facade 뒤에 숨긴다.

```text
Swift/AppKit Host
  -> Zig App/Core
    -> TerminalCoreFacade
      -> libghostty-vt 또는 Ghostty-derived core
    -> RenderSnapshot
    -> MetalRenderer
```

앱 전체가 Ghostty 타입에 직접 묶이면 나중에 자체 엔진으로 갈아타기 어렵다. 그래서 처음부터 다음 형태의 경계를 둔다.

```zig
pub const TerminalCore = struct {
    pub fn write(self: *TerminalCore, bytes: []const u8) void {}
    pub fn resize(self: *TerminalCore, cols: u16, rows: u16) void {}
    pub fn snapshot(self: *TerminalCore) RenderSnapshot {}
    pub fn encodeKey(self: *TerminalCore, key: KeyEvent) []const u8 {}
};
```

이렇게 하면 구현을 단계적으로 바꿀 수 있다.

```text
v1: libghostty-vt 사용
v2: Ghostty VT 코어를 vendoring/fork
v3: 자체 엔진
```

핵심은 "Ghostty급 코어 위에 UX를 얹는다"가 아니라, "Ghostty에서 배운 경계를 유지하면서 Maru 코어를 독립시킨다"이다.

## 4. 백엔드 경계

macOS만 먼저 구현하되, 경계는 처음부터 나눈다.

```text
TerminalCore
  - VT/parser 연동
  - terminal state
  - scrollback
  - render snapshot
  - AppKit 없음
  - Metal 직접 노출 없음
  - forkpty를 앱 코드에 직접 노출하지 않음

PtyBackend
  - macOS: forkpty
  - Windows: ConPTY later
  - Web: WebSocket remote PTY later

WindowBackend
  - macOS: AppKit
  - Windows: Win32/WinUI later
  - Linux: GTK/Wayland/X11 later
  - Web: browser host later

RendererBackend
  - macOS: Metal
  - Web: WebGPU
  - Windows: WebGPU native 또는 D3D12
  - Linux: Vulkan/WebGPU/OpenGL later

FontBackend
  - macOS: CoreText/HarfBuzz
  - Windows: DirectWrite/HarfBuzz later
  - Web: browser font/canvas metrics later
```

Windows와 Linux를 지금 구현하지는 않는다. 다만 `TerminalCore`, `PtyBackend`, `WindowBackend`, `RendererBackend`, `FontBackend` 경계를 섞지 않는다.

## 5. 왜 Zig인가

현재 프로젝트에는 Zig가 가장 자연스럽다.

이유:

- 이미 Zig로 고성능 번들러를 만든 경험이 있다.
- Ghostty가 Zig라서 구조를 직접 읽고 참고하기 쉽다.
- terminal buffer, glyph atlas, allocator, C/ObjC/Metal interop에 Zig가 잘 맞는다.
- 코어를 WASM/WebGPU 방향으로 가져갈 여지도 있다.

다만 모든 것을 순수 Zig로 밀어붙이는 것은 피한다. macOS 앱 호스트까지 Zig로 직접 만들면 터미널 개발이 아니라 AppKit 바인딩 개발이 된다.

권장 분리:

```text
Zig: terminal core, session/tab model, render data, Metal renderer
Swift/AppKit: macOS shell only
```

## 6. Ghostty에서 참고할 범위

Ghostty는 제품을 복제할 대상이 아니라 기술 레퍼런스다.

강하게 참고할 것:

- VT/render-state 경계
- parser -> stream -> terminal-state 파이프라인
- dirty tracking
- row/cell render iterator
- glyph atlas 구조
- Metal pipeline 구조
- CoreText/HarfBuzz/font shaping 구성
- macOS input/IME host 경계
- 테스트 전략

초기 버전에서 따라 하지 않을 것:

- 거대한 config surface
- macOS native tabs 중심 설계
- split/workspace 복잡도
- GTK/Linux host
- WebGL path
- inspector
- Ghostty 전체 기능 parity

Ghostty 기술 관찰:

- native renderer는 wgpu, mach-gpu, Electron, Skia를 쓰지 않는다.
- 자체 renderer abstraction을 갖고 있다.
- macOS/iOS backend는 Metal이다.
- Linux/BSD backend는 OpenGL이다.
- WebGL 파일은 존재하지만, 현재 Maru v1과는 무관하다.
- 텍스트 렌더링은 glyph atlas와 custom shader 기반이다.
- macOS font path는 CoreText와 HarfBuzz를 사용한다.
- parser는 `libvterm`, `vaxis`, `alacritty_terminal`이 아니라 Zig로 만든 자체 VT parser다.
- parser는 vt100.net의 DEC ANSI parser state machine 모델을 따른다.

Maru에서 중요한 결론:

```text
Ghostty 코드를 그대로 크게 포크하기보다,
Ghostty의 경계와 파이프라인을 읽고 Maru에 맞는 작은 구조로 다시 설계한다.
```

## 7. MVP 범위

첫 목표는 "매일 쓸 수 있는 작고 빠른 단일 창 터미널"이다.

v1에 포함:

- 단일 터미널 창
- 로컬 셸 실행
- 탭
- 키바인딩
- theme/font config
- config hot reload
- copy/paste/selection
- search
- `ssh`, `vim`, `tmux`, `neovim`, `less`, `htop` 기본 sanity

v1에서 제외:

- split panes
- workspace/session restore
- AI
- cloud/account
- command block UI
- plugin runtime
- GUI settings app
- heavy inspector

탭 기능 범위:

```text
Cmd+T        새 탭
Cmd+W        탭 닫기
Cmd+1..9     탭 선택
Cmd+Shift+[  이전 탭
Cmd+Shift+]  다음 탭
탭 순서 변경
shell title/cwd/process 기반 탭 제목
필요 시 닫기 확인
```

초기 모델:

```zig
const AppWindow = struct {
    tabs: []TerminalSession,
    active_tab: usize,
};
```

각 탭:

```zig
const TerminalSession = struct {
    pty: PtyHandle,
    core: TerminalCore,
    render_state: RenderSnapshot,
    title: []const u8,
    cwd: ?[]const u8,
    process_state: ProcessState,
};
```

## 8. 커스텀 전략

처음부터 플러그인을 넣지 않는다.

v1 커스텀은 다음 세 가지로 충분하다.

```text
config + action registry + keybinding map + hot reload
```

모든 동작은 action을 통해 실행한다.

```text
Keybinding -> Action
Menu       -> Action
Command palette -> Action
```

예시 config:

```toml
font.family = "JetBrains Mono"
font.size = 14
theme = "custom-dark"

[keys]
cmd+t = "new_tab"
cmd+w = "close_tab"
cmd+1 = "select_tab:1"
cmd+shift+left = "previous_tab"

[theme]
background = "#101010"
foreground = "#e8e8e8"
cursor = "#ffffff"
selection = "#334455"
```

이 구조를 먼저 만들면 나중에 플러그인, command palette, 메뉴, 키바인딩이 같은 action 시스템을 공유할 수 있다.

## 9. WASM 플러그인 전략

WASM 플러그인은 좋은 장기 차별점이지만 v1 기능은 아니다.

장점:

- 여러 언어로 플러그인 작성 가능
- sandbox 가능한 확장 모델
- local-only 확장성
- native dylib ABI 문제 회피

리스크:

- WASM runtime 크기와 복잡도
- API versioning 부담
- permission model 필요
- debugging/logging/diagnostics 필요
- hot path에 들어오면 성능 문제 발생

나중에 허용할 플러그인 영역:

- 탭 제목 formatter
- statusline
- command palette provider
- theme generator
- notification rule
- output matcher
- hyperlink provider
- shell integration event handler

금지할 플러그인 영역:

- per-byte VT hook
- per-cell render hook
- Metal draw loop
- keyboard critical path
- PTY blocking path
- glyph shaping hot path

플러그인 실행은 반드시 hot path 밖에서 처리한다.

```text
terminal event -> queue -> plugin worker -> result/action -> main app applies safely
```

단계:

```text
v1: config/action/keybindings
v2: command palette + statusline customization
v3: WASM plugin runtime
```

## 10. Ghostty와의 차별점

Ghostty의 강점:

- 매우 빠르고 반응성이 좋다.
- 터미널 호환성이 강하다.
- 플랫폼 네이티브 통합이 좋다.
- macOS/Linux 터미널 동작이 성숙하다.
- Zig 기반 커스텀 VT parser와 renderer를 갖고 있다.
- font rendering과 glyph handling이 좋다.

Ghostty의 약점 또는 Maru가 노릴 수 있는 지점:

- Windows는 아직 핵심 shipped target이 아니다.
- Linux GTK/OpenGL 경로는 환경 이슈와 플랫폼 오버헤드를 가질 수 있다.
- `TERM=xterm-ghostty`는 remote terminfo 마찰을 만들 수 있다.
- macOS native tabs는 tiling window manager와 어색할 수 있다.
- 기능 표면적이 작은 셸 앱보다 넓다.
- 플러그인/확장 모델이 제품 철학의 중심은 아니다.

Maru 차별화:

- 더 작은 기능 표면
- 단순한 custom-drawn tabs
- tiling WM 친화적인 탭 동작
- action/config-first 커스텀
- 장기 WASM plugin 경로
- 장기 웹은 WebGPU only
- 적은 기능, 강한 기본값

목표는 Ghostty 엔진을 직접 이기는 것이 아니다.

```text
잘못된 목표: Ghostty보다 빠른 VT parser / Metal renderer 만들기
올바른 목표: Ghostty보다 작아서 체감이 빠른 native shell 만들기
```

이기는 방식은 더 적게 하는 것이다.

- UI를 줄인다.
- config surface를 줄인다.
- background work를 줄인다.
- v1 플랫폼 범위를 줄인다.
- 기능 욕심을 줄인다.

## 11. 테스트 전략

터미널은 TDD가 가능한 영역과 불가능한 영역이 명확히 나뉜다.

순수 TDD가 가능한 영역:

- VT parser facade behavior
- terminal state
- screen/scrollback
- resize/reflow
- selection
- key encoding
- mouse encoding
- tab model
- action system
- config parser
- render snapshot generation

통합 테스트 영역:

- `forkpty`
- shell command execution
- resize -> `TIOCSWINSZ`
- `ssh localhost`
- `vim`, `tmux`, `less`, `htop` smoke test

snapshot/golden test 영역:

- ANSI bytes -> final grid text/style
- asciinema cast -> screen state snapshots
- render snapshot -> glyph/background/cursor instances
- recorded oracle snapshot -> Maru screen snapshot 비교

순수 TDD가 어려운 영역:

- Metal pixel output
- font rasterization exact pixels
- IME/marked text
- AppKit focus/menu/clipboard/accessibility
- GPU driver issue

권장 접근:

```text
Core: TDD
PTY/SSH: integration tests
Renderer data: snapshot/golden tests
Metal/AppKit/IME: smoke + screenshot + manual matrix
```

Ghostty 테스트 규모 관찰:

```text
Zig test declarations: 3,106
Zig files with tests: 237
macOS Swift/XCTest-related files: 27
test/ directory files: about 4,019
fuzz corpus files: about 4,002
```

대략적인 분포:

```text
src/terminal: 2,114 tests
src/input:      239 tests
src/config:     173 tests
src/font:       133 tests
src/cli:        100 tests
src/termio:      30 tests
src/renderer:    23 tests
```

해석:

- Ghostty는 terminal core와 parser/stream/OSC/fuzz 쪽을 강하게 테스트한다.
- renderer/GUI는 상대적으로 테스트가 적고 smoke/manual coverage가 필요하다.
- Maru도 core는 테스트 우선으로 가고, GUI/Metal은 smoke와 수동 매트릭스를 병행한다.

## 12. 디버깅/로그/리플레이 전략

Maru는 모든 개발 과정에서 디버깅, 테스트, 로그, 리플레이가 같은 상태 모델을 공유하도록 설계한다.

핵심 규칙:

- 새 기능은 구현 전에 어떤 로그, snapshot, trace, E2E 경로로 검증할지 정한다.
- `println` 로그, 테스트 fixture, inspector 전용 상태를 따로 만들지 않는다.
- `DebugEvent`, `TraceEvent`, `DebugSnapshot` 같은 공통 도메인 데이터를 먼저 만들고, 로그/테스트/리플레이/나중의 GUI inspector는 이 데이터를 소비한다.
- 실제 shell, ssh, vim, tmux에서 발생한 버그는 가능한 한 raw byte trace와 screen snapshot으로 저장해 headless replay test로 바꾼다.
- trace에는 cwd, env, token, host, command output 같은 민감정보가 들어갈 수 있으므로 기본은 local-only이고, git에 넣는 fixture는 반드시 sanitized 데이터여야 한다.

목표 흐름:

```text
버그 발생
-> trace/snapshot 저장
-> replay test 추가
-> root cause 수정
-> fixture가 영구 regression test가 됨
```

이 전략의 목적은 디버깅 편의성이 아니라 유지보수성이다. 터미널 버그는 시각적으로는 "화면이 깨짐"으로 보이지만 실제 원인은 parser state, cursor mode, resize propagation, dirty region, renderer snapshot 중 하나일 수 있다. 공통 관측 모델이 없으면 원인을 찾을 때마다 수동 재현에 의존하게 된다.

## 13. SSH 테스트

SSH 관련해서는 두 가지를 구분해야 한다.

1. SSH로 원격 Mac에 접속해서 개발하는 경우:
   - core test와 build command는 가능하다.
   - GUI/Metal/AppKit 테스트는 실제 macOS GUI session이 필요하다.
   - bare SSH session만으로는 앱 화면, IME, focus, Metal 렌더링을 충분히 테스트할 수 없다.

2. Maru 터미널 안에서 SSH 동작을 테스트하는 경우:
   - 반드시 integration test에 포함해야 한다.
   - 처음에는 `ssh localhost`나 통제된 VM/container를 사용한다.

SSH에서 확인할 것:

- remote prompt
- `vim`
- `tmux`
- `htop`
- resize propagation
- bracketed paste
- mouse reporting
- alternate screen
- UTF-8과 한글
- `TERM` / terminfo 동작

## 14. 예상 일정

전제:

- macOS 우선
- Zig core
- Swift/AppKit thin host
- Ghostty 또는 `libghostty-vt`를 facade 뒤에서 사용
- 직접 Metal renderer
- v1에는 plugin 없음

예상:

```text
2주:
  빈 macOS 창, Zig bridge, PTY 연결, bytes -> terminal core

4-6주:
  기본 Metal 렌더링, ASCII/color/cursor, zsh/vim/htop 기본 동작

8-10주:
  input, resize, selection, copy/paste, search, scrollback 안정화

3-4개월:
  tabs, config, actions, theme/font hot reload, daily-driver alpha

6개월+:
  배포 가능한 안정성, polish, edge case, broader compatibility
```

처음부터 parser를 완전히 새로 만들면 이 일정은 깨진다.

## 14. 1차 구현 순서

1. 저장소 기본 구조 만들기
   - `src/core`
   - `src/terminal`
   - `src/pty`
   - `src/renderer`
   - `src/config`
   - `macos`

2. macOS 빈 창 만들기
   - Swift/AppKit host
   - Zig library bridge
   - 최소 event loop

3. PTY 연결
   - `forkpty`
   - 기본 shell 실행
   - shell output을 Zig core로 전달
   - key input을 PTY로 전달

4. TerminalCore facade 만들기
   - Ghostty-derived core 또는 `libghostty-vt` 연결
   - `write`
   - `resize`
   - `snapshot`
   - `encodeKey`

5. RenderSnapshot 정의
   - cell grid
   - style
   - cursor
   - selection
   - dirty region

6. Metal renderer MVP
   - background quad
   - glyph atlas
   - ASCII glyph
   - cursor
   - color

7. 입력 안정화
   - key encoding
   - modifier
   - IME
   - paste
   - mouse 기본값

8. 탭 모델
   - `TerminalSession`
   - `AppWindow.tabs`
   - `active_tab`
   - Cmd+T/Cmd+W/Cmd+1..9

9. 설정 시스템
   - TOML config
   - action registry
   - keybinding map
   - hot reload

10. daily-driver alpha
    - search
    - selection
    - scrollback
    - theme/font
    - SSH/vim/tmux sanity

## 15. 최종 결정

Maru는 "더 큰 Ghostty"가 아니라 "더 작은 네이티브 셸"로 간다.

핵심 결정:

```text
Ghostty는 기술 레퍼런스로 사용한다.
Ghostty/libghostty-vt 의존성은 facade 뒤에 숨긴다.
macOS를 먼저 출시한다.
제품 표면은 작게 유지한다.
커스텀은 config/action/keybinding부터 시작한다.
WASM plugin은 v1 이후로 미룬다.
```

가장 중요한 원칙:

```text
성능은 더 많은 최적화보다 더 적은 제품 범위에서 먼저 나온다.
```
