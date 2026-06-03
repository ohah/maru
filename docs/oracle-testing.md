# 오라클 비교 테스트 전략

오라클 비교 테스트는 Maru의 terminal core가 reference terminal과 같은 최종 화면 상태를 만드는지 확인하는 테스트다.

## 왜 필요한가

터미널 버그는 대부분 "화면이 깨졌다"로 보인다. 하지만 실제 원인은 parser, cursor movement, scrollback, resize, line wrapping, style state 중 하나일 수 있다.

오라클 비교 테스트의 목적은 Maru의 결과를 reference 결과와 작은 fixture 단위로 계속 비교해서, 어느 시점부터 호환성이 어긋나는지 빠르게 찾는 것이다.

## 레퍼런스 후보

초기 비교 기준:

- `xterm` 계열 동작: ANSI/VT 동작의 기본 기대값
- `libvterm`: Neovim 내장 터미널 계열 검증 기준
- `Alacritty`/`vte`: 빠른 parser/state machine 참고 기준
- Ghostty: Zig/native terminal behavior 참고 기준

장기 비교 기준:

- `kitty`: 고급 프로토콜과 그래픽 기능
- `WezTerm`: mux, font, 복잡한 터미널 기능

비교 오라클이 아닌 것:

- `tmux`, `vim`, `less`, `htop`, `ssh`는 터미널 안에서 실행되는 workload다.
- 이 도구들은 PTY/E2E smoke test에는 중요하지만, terminal parser나 renderer의 정답 구현으로 보지는 않는다.
- 예를 들어 `tmux`는 Maru가 복잡한 escape sequence, resize, alternate screen, mouse reporting을 잘 처리하는지 압박하는 대상이지, Maru의 최종 screen snapshot을 대신 계산해 주는 오라클이 아니다.

## POC 범위

현재 POC는 외부 바이너리나 외부 라이브러리를 필수 의존성으로 추가하지 않는다.

대신 다음 흐름을 먼저 고정한다.

```text
ANSI fixture
-> Maru TerminalCore 실행
-> screen snapshot 생성
-> recorded oracle snapshot과 비교
-> tests/artifacts/oracle 아래에 actual/expected/input snapshot 저장
```

이 구조를 먼저 만드는 이유는 CI와 로컬 개발환경이 `xterm`, `libvterm`, `alacritty`, `ghostty` 설치 여부에 묶이지 않게 하기 위해서다.

## 나중에 추가할 것

실제 오라클 실행기는 선택 기능으로 붙인다.

```text
reference terminal/parser 실행
-> snapshot capture
-> sanitized recorded oracle 갱신
-> Maru 결과와 비교
```

외부 오라클 실행기를 추가할 때는 사용자와 먼저 논의한다. 새 바이너리나 라이브러리를 필수 테스트 의존성으로 만드는 것은 의존성 전략에 영향을 주기 때문이다.

## 명령

```sh
mise run oracle
```

`mise run check`에도 포함된다.
