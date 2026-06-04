# `tests/fixtures/ansi`

ANSI/VT 입력 fixture를 담는다.

현재 한계: 지금 커밋된 fixture에는 아직 escape sequence(`\e`)가 없다. core에 VT parser가 생기기 전까지는 평문과 일부 control(CR/LF/tab/backspace)만 검증한다. 포맷은 `\e`를 지원하지만, escape를 쓰는 fixture는 parser가 자라면서 함께 추가한다.

각 fixture는 어떤 터미널 동작을 재현하는지 설명해야 한다.

- `split_utf8.ansi`: PTY read 경계가 UTF-8 codepoint 중간에서 잘려도 최종 화면에는 원래 한글/이모지 텍스트가 남는지 검증한다.
- `mixed_width.ansi`: ASCII와 한글이 섞일 때 한글이 2 cell을 차지하고 다음 ASCII가 continuation cell 위에 겹치지 않는지 검증한다.
- `combining_mark.ansi`: combining mark가 이전 cell에 붙고 cursor를 전진시키지 않는지 검증한다.

제어 문자는 사람이 읽고 리뷰할 수 있게 escaped text로 저장한다. 예를 들어 실제 carriage return + line feed bytes는 `\r\n`으로 적고, oracle test가 실행 전에 실제 bytes로 디코딩한다.

지원하는 escape 목록과 golden 비교 규칙은 [Fixture와 Oracle 포맷](../../../docs/fixture-format.md)을 따른다.
