# Facade 계약

이 문서는 Maru의 핵심 facade가 무엇을 책임지고 무엇을 몰라야 하는지 정한다. 초보자 관점에서 중요한 이유는 간단하다. 터미널은 PTY, parser, renderer, session restore, plugin이 쉽게 서로 얽힌다. facade 계약은 얽힘을 막고, 나중에 내부 구현을 바꿔도 바깥 API를 크게 흔들지 않게 하는 울타리다.

## 공통 규칙

- 루트 `src/*.zig` 파일은 안정된 import 경로를 제공하는 얇은 facade다.
- 구현 세부사항은 하위 폴더에 둔다.
- facade는 다른 레이어의 private 구현 타입을 public API로 노출하지 않는다.
- 새로운 기능은 먼저 어떤 facade의 책임인지 정한 뒤 구현한다.
- 계약을 바꿔야 하면 같은 PR에서 문서, 테스트, PR 전략 영향 평가를 함께 갱신한다.

## `TerminalCore`

책임:

- raw terminal output bytes를 screen state로 반영한다.
- terminal size 변경을 적용한다.
- cursor, visible cells, scrollback 같은 terminal state를 소유한다.
- renderer와 test가 소비할 snapshot을 만든다.

몰라야 하는 것:

- shell process를 어떻게 실행했는지.
- PTY file descriptor나 platform API.
- macOS window, renderer, GPU.
- workspace, tab, split, plugin runtime.

초기 테스트:

- ANSI fixture -> `TerminalCore.write` -> screen golden.
- recorded oracle snapshot 비교.
- resize/write stress.
- core hot path performance budget.

## `PtySession`

책임:

- local shell/process를 실행한다.
- PTY output bytes를 읽어 domain event로 내보낸다.
- 사용자 input bytes와 resize request를 PTY에 전달한다.
- process exit 상태를 보고한다.

몰라야 하는 것:

- escape sequence가 무슨 뜻인지.
- screen cell이나 cursor state.
- renderer frame timing.
- workspace restore 저장 포맷.

초기 테스트:

- 통제된 command가 stdout으로 낸 bytes를 읽는다.
- resize request가 PTY layer까지 전달된다.
- process exit가 domain event로 관측된다.
- app/global shortcut으로 소비된 key가 PTY input으로 내려오지 않는다.

## `Pane`

책임:

- 하나의 사용 가능한 terminal surface를 표현한다.
- `PtySession`과 `TerminalCore`를 연결한다.
- pane의 title, cwd, env, command, size 같은 복구 가능한 metadata를 보관한다.
- snapshot을 만들 때 terminal state와 pane metadata를 함께 제공한다.

몰라야 하는 것:

- app window의 실제 좌표 계산.
- GPU draw call.
- workspace 파일 저장 방식.
- plugin 실행 방식.

초기 테스트:

- PTY output event가 pane의 `TerminalCore`로 전달된다.
- pane size 변경이 core resize와 PTY resize request로 분리되어 전달된다.

## `Workspace`

책임:

- 프로젝트별 workspace 식별자와 root path를 관리한다.
- 탭/분할 layout restore에 필요한 선언적 상태를 저장한다.
- 최근 작업 세션 목록을 관리한다.
- repo별 기본 레이아웃과 scratch terminal 정책을 나중에 수용한다.

몰라야 하는 것:

- live PTY file descriptor.
- terminal parser 내부 상태.
- renderer resource handle.

초기 테스트:

- 저장 가능한 layout model round-trip.
- cwd/env/command metadata가 민감정보 정책을 지키는지 확인.

## `Snapshot`

책임:

- test, debug log, replay, future inspector가 같은 terminal 상태를 보게 한다.
- visible screen, cursor, size, pane/workspace metadata를 구조화한다.
- 실패 artifact로 저장할 수 있는 안정된 텍스트 표현을 제공한다.

몰라야 하는 것:

- snapshot을 만든 원인이 PTY인지 replay인지 renderer인지.
- GPU texture나 platform window handle.

초기 테스트:

- 같은 terminal state는 같은 snapshot text를 만든다.
- trailing spaces, cursor, size가 손실되지 않는다.

## `Trace/Event`

책임:

- raw output bytes, key input, resize, process lifecycle을 시간순 event로 기록한다.
- replay runner가 public facade만 통해 같은 상태를 재현할 수 있게 한다.
- 민감정보가 들어갈 수 있는 cwd/env/command/raw bytes를 sanitized fixture로 바꿀 경계를 둔다.

몰라야 하는 것:

- private parser storage.
- renderer 내부 frame resource.
- plugin 내부 메모리.

초기 테스트:

- trace -> replay -> snapshot이 원래 snapshot과 같아야 한다.
- 민감정보가 있는 event를 fixture로 저장할 때 제거 규칙을 적용한다.

## Plugin 경계

v0에서는 Wasm plugin을 구현하지 않는다. 다만 나중에 plugin이 들어와도 core를 직접 만지지 못하게 다음 방향만 유지한다.

- plugin은 domain event와 action facade를 통해서만 상호작용한다.
- plugin은 `TerminalCore` private storage, PTY handle, renderer resource를 직접 받지 않는다.
- plugin 실패는 pane/session 전체를 죽이지 않고 격리되어야 한다.

Plugin ABI나 권한 모델을 확정해야 하는 순간이 오면, 구현 전에 사용자와 별도 논의한다.

## 키 입력과 글로벌 핫키 경계

글로벌 핫키는 platform/app layer 책임이다. `TerminalCore`와 `PtySession`은 글로벌 핫키가 있다는 사실을 몰라야 한다.

계약:

- platform layer는 OS 전역 shortcut 등록 성공/실패를 app layer에 보고한다.
- app layer는 key event를 `AppAction` 또는 `TerminalInput`으로 분류한다.
- `PtySession`은 이미 terminal input으로 분류된 bytes만 받는다.
- app/global shortcut으로 소비된 key event는 PTY로 전달하지 않는다.

세부 충돌 규칙은 [키 입력과 단축키 경계](key-input-and-shortcuts.md)를 따른다.
