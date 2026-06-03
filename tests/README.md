# `tests`

테스트는 레이어별로 둔다.

테스트 파일은 무엇을 증명하는지와 터미널에서 왜 중요한지를 설명해야 한다. 실제 버그가 생기면 가능한 한 trace나 fixture를 추가해서 재현 가능한 회귀 테스트로 남긴다.

오라클 비교 테스트는 `tests/oracle/`에 둔다. 이 테스트는 Maru의 screen snapshot을 reference terminal에서 기록한 기대값과 비교한다.

스트레스 테스트는 `tests/stress/`에 둔다. 빠른 스트레스는 기본 `check`에 포함하고, 긴 soak 테스트는 opt-in 명령으로 분리한다.
