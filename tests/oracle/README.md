# `tests/oracle`

Maru 실행 결과와 reference terminal의 기록된 결과를 비교하는 테스트를 담는다.

초기에는 외부 터미널 바이너리를 실행하지 않고, `tests/fixtures/ansi` 입력과 `tests/golden/screen` 기대값을 비교한다. 이 방식은 개발환경에 `xterm`, `libvterm`, `alacritty`, `ghostty`가 없어도 동작한다.

현재 한계: 커밋된 fixture에는 아직 escape sequence가 없고 core에 VT parser도 없다. 따라서 지금 oracle은 평문/제어문자(CR/LF/tab/backspace) 배치와 한 줄 스크롤만 검증한다. golden은 사람이 손으로 기록한 기대값이며 실제 reference terminal에서 캡처한 것이 아니다. 자세한 내용은 [오라클 비교 테스트 전략](../../docs/oracle-testing.md)을 참고한다.

- `recorded.zig`: 기본 oracle. Maru 출력과 커밋된 golden을 비교한다(`mise run oracle`, `check`에 포함).
- `external.zig`: opt-in 외부 oracle(libvterm). 동일 golden을 실제 libvterm 출력과 비교해 golden 자체를 검증한다(`mise run oracle-ext`, libvterm 필요). C shim은 `vterm_shim.c`.
- `external_ghostty.zig`: opt-in 외부 oracle(Ghostty libghostty-vt). C shim은 `ghostty_shim.c`(`mise run oracle-ghostty`).
- `external_alacritty.zig`: opt-in 외부 oracle(Alacritty alacritty_terminal). Rust dumper(`alacritty-dumper/`)를 subprocess로 호출한다(`mise run oracle-alacritty`).

opt-in 외부 oracle은 모두 `check`에는 미포함이며 각 reference 설치/빌드가 필요하다. 새 reference 실행기를 붙일 때도 이 폴더의 테스트는 같은 데이터 모델(fixture/golden)을 사용해야 한다.

