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

첫 구현 목표는 [v0 세로 슬라이스](v0-vertical-slice.md)를 따른다. 각 facade가 맡는 책임과 금지된 의존성은 [Facade 계약](facade-contracts.md)을 단일 출처로 둔다. 키 입력, app shortcut, global shortcut의 충돌 규칙은 [키 입력과 단축키 경계](key-input-and-shortcuts.md)를 따른다.

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

구체적인 구현 순서는 [실제 구현 계획](implementation-plan.md)을 단일 출처로 둔다.

이전에는 parser를 먼저 만든다고 표현했지만, 실제 순서는 더 좁게 잡는다. 먼저 facade 계약과 snapshot/artifact 경계를 고정하고, v0 shell 경로에 필요한 parser 동작만 fixture 기반으로 작게 추가한다. 그다음 macOS PTY, pane 연결, headless E2E, renderer/app host 순서로 진행한다.

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

## 관측 가능성 원칙

Maru는 처음부터 디버깅, 테스트, 로그, 리플레이가 같은 데이터를 공유하는 구조로 만든다.

이 원칙의 의도는 실제 터미널에서만 보이는 버그를 재현 가능한 테스트로 바꾸는 것이다. `println` 로그, 테스트 fixture, 나중의 GUI inspector가 서로 다른 상태 모델을 보면 버그를 고칠 때마다 같은 정보를 여러 번 해석해야 하고, 어느 도구가 진짜 상태를 말하는지 알기 어려워진다.

공통 흐름:

```text
PTY/input/parser/terminal/renderer/workspace
  -> DebugEvent / TraceEvent / DebugSnapshot
  -> structured log
  -> headless replay
  -> golden snapshot
  -> failure artifact
  -> future GUI inspector
```

새 기능을 만들 때는 구현 전에 다음 질문에 답해야 한다.

```text
이 기능의 중요한 상태는 어떤 snapshot으로 볼 수 있는가?
실패 상황을 replay trace로 저장할 수 있는가?
테스트 실패 시 어떤 artifact가 남아 root cause를 찾게 해주는가?
로그에 민감한 cwd/env/token/server 정보가 섞일 수 있는가?
```

초기 구현 우선순위:

1. `DebugSnapshot`: cursor, grid, mode, dirty region, pane/workspace 상태를 설명한다.
2. `TraceRecorder`: raw bytes, key input, resize, parser event를 재생 가능한 이벤트로 저장한다.
3. `ReplayRunner`: 저장된 trace를 headless test에서 다시 실행한다.
4. `FailureArtifact`: 테스트 실패 시 trace, snapshot, config를 로컬 산출물로 남긴다.

릴리스 빌드에서는 이 관측 기능이 꺼졌을 때 hot path에 의미 있는 비용을 남기지 않아야 한다. trace와 artifact는 기본적으로 로컬 전용이며, 회귀 테스트로 추가할 때만 민감정보를 제거한 fixture를 git에 넣는다.

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
