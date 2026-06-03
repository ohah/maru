# `tests/fixtures/ansi`

ANSI/VT 입력 fixture를 담는다.

각 fixture는 어떤 터미널 동작을 재현하는지 설명해야 한다.

제어 문자는 사람이 읽고 리뷰할 수 있게 escaped text로 저장한다. 예를 들어 실제 carriage return + line feed bytes는 `\r\n`으로 적고, oracle test가 실행 전에 실제 bytes로 디코딩한다.

지원하는 escape 목록과 golden 비교 규칙은 [Fixture와 Oracle 포맷](../../../docs/fixture-format.md)을 따른다.
