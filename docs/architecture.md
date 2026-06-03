# Maru 초기 아키텍처

Maru는 Ghostty 코드를 복붙하지 않는 clean-room 터미널로 시작한다.

Ghostty는 다음 용도로만 사용한다.

- 구조 레퍼런스
- 테스트 전략 참고
- 동작 비교 오라클
- 성능/UX 기준점

사용하지 않을 것:

- Ghostty 소스 vendoring
- `libghostty-vt` 런타임 의존
- Ghostty 타입을 Maru public API에 노출

## 1차 모듈 경계

```text
src/maru.zig
  -> app.zig
  -> config.zig
  -> pty.zig
  -> renderer.zig
  -> terminal.zig
```

현재 스캐폴드는 실제 터미널 구현이 아니라, 앞으로 지켜야 할 경계를 컴파일 가능한 형태로 세운 것이다.

## 핵심 경계

```text
AppWindow
  - 탭 목록
  - active tab
  - UI action 적용

TerminalSession
  - PtyHandle
  - TerminalCore
  - RenderSnapshot
  - title/cwd/process state

TerminalCore
  - bytes 입력
  - resize
  - key encoding
  - render snapshot 생성

Renderer
  - RenderSnapshot 소비
  - v1 macOS Metal
```

## 개발 순서

1. `TerminalCore` facade를 유지한 채 자체 VT parser를 만든다.
2. ANSI fixture와 golden test를 먼저 쌓는다.
3. `forkpty`를 붙여 로컬 shell bytes를 core로 넣는다.
4. `RenderSnapshot`을 Metal renderer로 그린다.
5. 탭 모델과 action/keybinding/config를 얹는다.
6. Ghostty, xterm, Alacritty, libvterm을 오라클로 비교한다.

## 테스트 원칙

Maru는 가능한 모든 영역에서 TDD를 기본값으로 둔다.

TDD가 의도하는 것은 "테스트 개수 늘리기"가 아니다. 구현 전에 원하는 동작을 작게 고정해서, 코드가 커져도 책임 경계가 흐려지지 않게 만드는 것이다.

각 테스트는 다음 질문에 답해야 한다.

```text
이 동작은 사용자의 어떤 터미널 경험을 지키는가?
이 테스트가 실패하면 어느 책임 영역을 의심해야 하는가?
이 테스트보다 더 위/아래 레이어의 테스트가 필요한가?
```

E2E는 레이어별로 둔다.

```text
Headless E2E:
  real process -> stdout bytes -> TerminalCore -> screen snapshot

PTY E2E:
  forkpty -> shell/program -> TerminalCore -> screen snapshot

App E2E:
  macOS app -> key input/resize/paste -> rendered result
```

어떤 영역이 자동 E2E로 검증 불가능하면, 그 이유와 수동 검증 방법을 사용자에게 보고해야 한다.

## 메모리 전략

Ghostty는 앱 전체를 하나의 mmap allocator로만 운영하지 않는다. 일반 영역은 Zig allocator interface를 주입하고, terminal page backing memory처럼 성능과 zero-fill 특성이 중요한 영역은 `mmap`/`VirtualAlloc`을 직접 쓴다.

Maru도 같은 방향을 참고한다.

```text
일반 객체:
  std.mem.Allocator 주입

초기 ScreenStorage:
  단순 allocator 기반 cells

고성능 ScreenStorage later:
  page-aligned storage
  mmap/VirtualAlloc 고려
  scrollback/page 책임을 별도 모듈로 분리
```

이 결정의 의도는 메모리 최적화를 성급하게 전체 구조에 섞지 않고, hot storage가 명확해졌을 때 그 책임만 교체할 수 있게 만드는 것이다.

## 개발환경

필수 도구:

```text
mise
zig 0.16.0
```

명령:

```sh
mise run fmt
mise run test
mise run build
mise run check
```

현재 단계의 성공 기준:

```text
zig build
zig build test
mise run check
```
