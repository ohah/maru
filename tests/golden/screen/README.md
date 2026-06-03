# `tests/golden/screen`

screen snapshot 기대값을 담는다.

ANSI bytes 또는 trace replay 후 최종 grid text/style을 비교하는 용도다.

`xterm/` 하위 폴더는 xterm 계열 동작을 기준으로 삼겠다는 의도로 이름 붙인 기대 화면을 담는다. 현재 golden은 사람이 손으로 기록한 기대값이며 실제 xterm에서 캡처한 것이 아니다. 실제 외부 오라클 실행기를 붙이기 전까지는 사람이 읽을 수 있는 recorded oracle로 사용한다.

줄 끝 공백과 마지막 newline 처리 규칙은 [Fixture와 Oracle 포맷](../../../docs/fixture-format.md)을 따른다.
