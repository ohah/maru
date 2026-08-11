# Snapshot Versioning

이 문서는 snapshot schema version을 언제 유지하고 언제 올릴지 정한다.

## 한 줄 정의

Snapshot version은 제품 버전이 아니라 **테스트와 디버깅 데이터 계약 버전**이다.

현재 schema는 `maru.snapshot.v3`이다.

## 왜 필요한가

터미널 snapshot은 단순 문자열이 아니다. 다음 상태가 함께 들어간다.

- 화면 크기
- cursor 위치와 표시 여부
- dirty region
- cell text
- style
- future mode
- future scrollback
- future alternate screen

이 구조의 의미가 바뀌면, 오래된 artifact나 fixture를 어떻게 읽어야 하는지 알 수 없게 된다. 그래서 version을 둔다.

## 버전을 올리는 경우

다음은 `maru.snapshot.v3`처럼 version을 올린다.

- 기존 필드의 의미가 바뀐다.
- cell 표현 방식이 바뀐다. 예: `text` 하나에서 `codepoint + width + continuation`으로 바뀐다.
- cursor, style, alternate screen, scrollback을 reader가 다르게 해석해야 한다.
- replay나 inspector가 기존 reader로는 안전하게 읽을 수 없다.
- 같은 terminal state가 기존 규칙과 다른 snapshot 의미를 갖게 된다.

## 버전을 유지할 수 있는 경우

다음은 version을 유지할 수 있다.

- 사람이 읽기 위한 non-semantic debug line을 추가한다.
- 기존 reader가 무시할 수 있는 optional metadata를 추가한다.
- artifact 파일명이나 저장 위치만 바뀐다.
- 단순히 expected output fixture가 바뀐다.
- 버그 수정으로 실제 화면 결과가 바뀌었지만 snapshot schema 의미는 그대로다.

주의: version을 유지하려면 old consumer가 깨지지 않는다는 근거가 있어야 한다. 근거가 애매하면 version을 올리는 쪽이 안전하다.

## v3 reader 규칙

v3 reader는 **구현됐다** — `observability/snapshot.zig`의 `parseSnapshot(allocator, text) → ParsedSnapshot`이 writer(`renderTerminalSnapshot`)가 낸 텍스트를 되읽는다(round-trip 테스트). **부분 복원**임에 유의: writer가 직렬화하는 필드(size·cursor·dirty·행 텍스트·cell-metadata·styled-cells)만 채우고, writer가 안 쓰는 필드(cursor_shape·cursor_blink·prompt_marks·last_command_exit·kitty placements/images·`Style`의 dim/reverse/blink 등)는 복원 대상이 아니다 — 이들이 필요해지면 writer를 먼저 확장한다. 아래 규칙대로 보수적으로 동작한다.

- 첫 줄 전체가 bare 토큰 `maru.snapshot.v3`인지 확인한다(아니면 `BadHeader`). `schema=` 같은 접두어 없이 첫 줄이 곧 schema 토큰이다(현재 코드가 내보내는 형식).
- dirty 상태는 `dirty start_row=<n> end_row=<n>` 또는 `dirty none` 중 하나다. `dirty none`은 renderer가 이미 변경 범위를 소비했거나 변경 범위가 없다는 뜻이다.
- `cell-metadata` section은 width가 1이 아니거나 continuation cell이거나 combining mark가 있는 cell만 기록한다.
- continuation cell은 앞 cell의 double-width glyph가 차지한 두 번째 cell이다. row text에는 중복 출력하지 않는다.
- combining mark는 직전에 출력된 printable cell에 붙는 zero-width codepoint다. cursor를 전진시키지 않으며, 마지막 열에서 cursor가 그 cell에 머물러도 같은 cell에 붙는다. 붙을 base가 없으면(스트림 시작, CR/LF 직후) 어디에도 기록되지 않는다.
- 알 수 없는 semantic section을 만나면 실패한다(`UnknownSection` — styled-cells `none` 뒤 낯선 라인 등).
- `debug.` prefix를 가진 non-semantic line은 무시한다(LineReader가 건너뜀).

이 규칙의 의도는 조용히 잘못 해석하는 것을 막는 것이다.

## PR 규칙

snapshot 출력이 바뀌는 PR은 PR 설명에 다음을 적는다.

```text
snapshot schema version:
  유지 / 다음 버전으로 증가 (현재 v2 -> v3)

이유:
  schema 의미 변경인지, 단순 expected output 변경인지

consumer 영향:
  replay, inspector, golden, artifact reader가 영향을 받는지
```

## 초기 테스트 (`observability/snapshot.zig`)

- snapshot text 첫 줄에 schema가 있다(writer 테스트).
- **round-trip**: writer가 낸 v3 텍스트를 `parseSnapshot`으로 되읽으면 직렬화된 필드(size·cursor·dirty·행 텍스트·wide/grapheme cell-metadata·styled-cells)가 구조로 복원된다.
- v3 reader가 모르는 semantic section을 만나면 실패한다(`UnknownSection`), 잘못된 헤더는 `BadHeader`.
- debug-only(`debug.`) line은 무시하고 version bump 없이 허용된다.
- rgb/indexed 색·`\|`·`\\` escape된 행 텍스트가 복원된다.
