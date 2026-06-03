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
