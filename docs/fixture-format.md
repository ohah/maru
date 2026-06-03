# Fixture와 Oracle 포맷

이 문서는 테스트 입력과 기대 결과를 어떤 형식으로 저장할지 정한다. 목적은 oracle, E2E, trace/replay가 서로 다른 임시 포맷을 만들지 않게 하는 것이다.

## 기본 원칙

- git에 들어가는 fixture는 사람이 리뷰할 수 있어야 한다.
- 민감정보가 들어간 실제 shell trace는 그대로 커밋하지 않는다.
- fixture는 실행 전에 실제 bytes로 디코딩된다.
- golden screen은 terminal cell의 trailing space를 의미 있는 데이터로 본다.
- 파일 끝의 마지막 newline 하나는 에디터 편의를 위한 것으로 볼 수 있다. 화면 cell의 trailing space를 trim하지 않는다.

## ANSI fixture

위치:

```text
tests/fixtures/ansi/*.ansi
```

저장 형식:

```text
hello\r\n\e[31mred\e[0m
```

지원하는 escape:

```text
\e    ESC, 0x1b
\r    carriage return
\n    line feed
\t    tab
\\    backslash
```

이 방식을 쓰는 이유는 control byte를 직접 넣으면 리뷰에서 무엇이 바뀌었는지 보기 어렵기 때문이다. fixture는 읽기 쉬운 escaped text로 저장하고, 테스트가 실행 직전에 실제 bytes로 바꾼다.

## Screen golden

위치:

```text
tests/golden/screen/<reference>/<case>.txt
```

예시:

아래 예시는 리뷰에서 보이도록 공백을 `·`로 표시한 것이다. 실제 golden 파일에는 `·`가 아니라 진짜 space byte가 들어간다.

```text
hello·······
maru········
············
```

규칙:

- 각 줄은 terminal row 하나를 의미한다.
- 줄 끝의 공백은 cell 데이터이므로 유지한다.
- 파일 마지막 newline 하나는 테스트에서 제거할 수 있다.
- reference 이름은 `xterm`, `libvterm`, `alacritty`, `ghostty`, `kitty`처럼 기대값 출처를 나타낸다.

## Structured snapshot artifact

위치:

```text
tests/artifacts/**/maru.snapshot.txt
```

용도:

- 테스트 실패 시 cursor, size, cells 같은 구조화 상태를 확인한다.
- 나중의 trace/replay와 inspector가 같은 도메인 데이터를 소비하게 만든다.

Snapshot artifact는 기본적으로 로컬 산출물이다. 회귀 테스트 fixture로 승격할 때는 민감정보가 없는지 확인한 뒤 별도 PR에서 추가한다.

## Trace fixture 초안

위치:

```text
tests/fixtures/traces/*.trace.txt
```

직렬화 포맷의 구현은 나중이지만, 최소 event 어휘는 지금 고정한다. step 4(PtySession) 이후 코드가 기능마다 ad-hoc trace 포맷을 만들지 않도록, 다음 네 가지 event 이름과 인자를 확정한다.

```text
output escaped-bytes
input escaped-bytes
resize cols rows
process-exit code
```

이 어휘를 바꾸거나 새 event를 추가할 때는, 직렬화 구현 전이라도 먼저 `docs/facade-contracts.md`의 `Trace/Event` 계약을 갱신한 뒤 진행한다.

## Oracle 기록 흐름

현재 기본 흐름:

```text
ANSI fixture
-> Maru TerminalCore
-> actual screen
-> recorded golden screen과 비교
-> artifact 저장
```

미래 외부 oracle 흐름:

```text
ANSI fixture
-> reference terminal/parser 실행
-> reference snapshot capture
-> sanitized golden 갱신
-> Maru 결과와 비교
```

외부 oracle runner는 선택 기능으로 추가한다. 새 runtime 의존성을 기본 테스트 경로에 넣어야 하는 경우에는 먼저 사용자와 논의한다.
