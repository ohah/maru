# `tests/oracle`

Maru 실행 결과와 reference terminal의 기록된 결과를 비교하는 테스트를 담는다.

초기에는 외부 터미널 바이너리를 실행하지 않고, `tests/fixtures/ansi` 입력과 `tests/golden/screen` 기대값을 비교한다. 이 방식은 개발환경에 `xterm`, `libvterm`, `alacritty`, `ghostty`가 없어도 동작한다.

나중에 실제 오라클 실행기를 붙일 때도 이 폴더의 테스트는 같은 데이터 모델을 사용해야 한다.

