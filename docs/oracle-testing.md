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

### 레퍼런스 라이선스와 허용 상호작용

레퍼런스마다 라이선스가 다르므로 허용되는 상호작용도 다르다. 어떤 레퍼런스의 소스도 Maru에 복사하지 않으며, 구현은 공개 명세(ECMA-48, vt100.net DEC ANSI state machine, xterm ctlseqs)에서 유도한다.

| 레퍼런스 | 라이선스 | 허용 상호작용 |
| --- | --- | --- |
| xterm | MIT 계열 | 공개 명세/동작 기준점. 소스 복사 금지. |
| libvterm | MIT | 동작 비교 오라클. 소스 복사 금지. |
| Alacritty | Apache-2.0 | 구조 참고/동작 비교. 소스 복사 금지. |
| GNOME vte | LGPL-2.1+ (copyleft) | 최종 화면 동작 비교(오라클)로만. 구현 유도를 위한 소스 열람 금지. |
| Ghostty | MIT | 구조 레퍼런스/동작 비교. 소스 복사 금지. |
| kitty | GPL-3.0 (copyleft) | 프로토콜 명세 참고만. 구현 유도를 위한 소스 열람 금지. |
| WezTerm | MIT | 기능 참고/동작 비교. 소스 복사 금지. |

copyleft(LGPL/GPL) 레퍼런스는 read-only 동작 오라클로만 쓰고, 구현을 유도하려고 소스를 읽지 않는다. 규칙 전문은 [필수 프로젝트 규칙](project-rules.md)을 따른다.

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

현재 한계를 분명히 한다. 지금 커밋된 fixture에는 아직 escape sequence(`\e`)가 하나도 없고, core에도 VT parser가 없다. 따라서 이 단계의 oracle은 ANSI/VT 적합성이 아니라 평문과 일부 control(CR/LF/tab/backspace) 배치, 그리고 한 줄 스크롤만 검증한다. golden 파일은 사람이 손으로 기록한 기대값이며 실제 reference terminal에서 캡처한 것이 아니다. `tests/fixtures/ansi`, golden 경로 `tests/golden/screen/xterm/`, 케이스 라벨의 `xterm` 표기는 "이런 출처를 기준으로 삼겠다"는 의도 표시일 뿐, 현재 자동 검증된 호환성을 뜻하지 않는다. 다만 아래의 외부 오라클(`mise run oracle-ext`, opt-in)이 이 golden을 실제 libvterm 출력과 대조해 검증한다.

fixture와 golden 파일의 저장 형식은 [Fixture와 Oracle 포맷](fixture-format.md)을 따른다.

## 외부 오라클 (opt-in)

실제 reference VT 엔진과 비교하는 외부 오라클은 opt-in으로만 실행하며, 기본 경로(`mise run check`)에는 넣지 않아 외부 의존성 없이도 개발할 수 있다. 현재 세 reference를 지원한다.

| reference | 테스트 | 명령 | 받는 법 |
| --- | --- | --- | --- |
| libvterm | `tests/oracle/external.zig` | `mise run oracle-ext` | `brew install libvterm` |
| Ghostty libghostty-vt | `tests/oracle/external_ghostty.zig` | `mise run oracle-ghostty` | clone 후 `references/ghostty`에서 `mise exec zig@0.15.2 -- zig build -Demit-lib-vt=true` |
| Alacritty alacritty_terminal | `tests/oracle/external_alacritty.zig` | `mise run oracle-alacritty` | `tests/oracle/alacritty-dumper`에서 `cargo build --release` |

각 reference에 동일한 fixture를 먹여 최종 화면을 덤프하고 커밋된 golden과 비교한다.

```text
ANSI fixture
-> reference(libvterm / libghostty-vt / alacritty_terminal) 실행
-> 최종 screen 덤프
-> 커밋된 golden과 비교
```

이 구조로 맞물린다.

- `recorded.zig`(기본 oracle): Maru == golden
- `external*.zig`(opt-in oracle): golden == libvterm, golden == Ghostty, golden == Alacritty

세 opt-in 오라클을 모두 실행하면 Maru == 세 reference가 transitively 성립한다. 다만 이 성립 범위는 실행 경로마다 다르다.

- 로컬 기본 `mise run check`는 recorded 오라클(Maru == golden)만 강제한다.
- CI는 매 푸시/PR에서 libvterm·Alacritty 다리(golden == reference)를 함께 돌리므로, recorded 오라클과 합쳐 Maru == libvterm, Maru == Alacritty까지 standing으로 강제된다.
- Ghostty 다리는 무거운 빌드 때문에 CI에서도 제외되며 로컬 opt-in(`mise run oracle-ghostty`)으로만 검증한다.

세 reference가 서로 다른 구현이므로, 실행했을 때 golden이 한쪽 구현의 특이동작을 따라가지 않았는지도 교차 확인된다. 단 현재 golden에는 escape sequence가 없어 이 교차검증은 평문과 일부 control 동작까지만 다룬다. 앞으로 escape sequence fixture가 늘어날 때 golden을 손으로 적지 않고 reference로 검증/생성할 수 있다.

연동 방식은 reference마다 다르다. libvterm과 Ghostty libghostty-vt는 C 라이브러리라 in-process로 링크하되, bitfield/opaque 핸들 때문에 Zig translate-c로 직접 다루기 까다로워 셀 접근용 얇은 C shim을 둔다(`tests/oracle/vterm_shim.c`, `tests/oracle/ghostty_shim.c`). Alacritty `alacritty_terminal`은 Rust 크레이트라 작은 dumper 바이너리(`tests/oracle/alacritty-dumper`)로 빌드해 subprocess로 호출한다. 새 reference를 **필수**(기본 `check`) 의존성으로 승격할 때는 의존성 전략에 영향을 주므로 사용자와 먼저 논의한다.

## 명령

```sh
mise run oracle           # 기본: Maru vs 기록된 golden (check에 포함)
mise run oracle-ext       # opt-in: golden vs libvterm
mise run oracle-ghostty   # opt-in: golden vs Ghostty libghostty-vt
mise run oracle-alacritty # opt-in: golden vs Alacritty alacritty_terminal
```

`mise run oracle`만 `mise run check`에 포함된다. 외부 reference 오라클 세 개는 opt-in이라 `check`에 넣지 않는다(각 reference 설치/빌드 필요).
