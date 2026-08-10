# 레퍼런스와 공개 명세

Maru는 외부 터미널 소스를 복사하지 않고 **공개 명세를 기준으로 독립 구현**한다(clean-room). 이 문서는 그 "기준"이 무엇이고 어디서 구하는지, 그리고 동작 비교용 오라클을 어디서 구하는지 정하는 단일 출처다.

`references/`는 git에 커밋하지 않는 로컬 디렉터리다(`.gitignore`). 파일 자체는 각 개발자가 받아 두고, 이 문서가 그 출처 목록을 git에 남겨 재현 가능하게 한다.

## 받는 법

```sh
sh tools/fetch-references.sh
```

공개 명세를 `references/specs/`에 내려받는다. 오라클 구현은 아래 안내를 따른다.

## 공개 명세 (ground truth — 구현은 여기서 유도한다)

VT 파서/state machine을 구현할 때는 아래 명세를 1차 출처로 삼고, PR에 "구현한 명세 섹션"을 인용한다. 레퍼런스 구현의 코드 표현을 옮기지 않는다.

| 명세 | 무엇 | 로컬 경로 | 출처 |
| --- | --- | --- | --- |
| ECMA-48 (5th, 1991) | 제어 시퀀스 ISO 표준 | `references/specs/ECMA-48_5th_edition_june_1991.pdf` | https://ecma-international.org/publications-and-standards/standards/ecma-48/ |
| xterm ctlseqs | xterm 제어 시퀀스 사전(실제 프로그램이 기대하는 것) | `references/specs/xterm-ctlseqs.txt` | https://invisible-island.net/xterm/ctlseqs/ctlseqs.html |
| DEC ANSI parser | Paul Williams VT 파서 state machine | `references/specs/vt100net-dec-ansi-parser.html` | https://vt100.net/emu/dec_ansi_parser |
| VT100 User Guide | DEC VT100 동작 매뉴얼 | `references/specs/vt100-user-guide-contents.html` | https://vt100.net/docs/vt100-ug/contents.html |

추가로 참고(받지는 않고 링크만):
- DEC STD 070 종합 VT 명세 — vt100.net 아카이브
- kitty keyboard protocol(향후 CSI-u): https://sw.kovidgoyal.net/kitty/keyboard-protocol/
- 적합성 테스트 스위트: vttest(https://invisible-island.net/vttest/), esctest(iTerm2)

## 동작 비교 오라클 (cross-check — 구현을 베끼지 않는다)

오라클은 "정답"이 아니라 명세를 근사하는 second opinion이다. 진짜 기준은 위 명세이고, 오라클은 의견이 갈리는 지점을 드러내는 용도다. 비교 전략은 [오라클 비교 테스트 전략](oracle-testing.md)을 따른다.

## 레퍼런스를 쓰는 방법

허용한다:

- 공개 명세와 platform 문서에서 동작을 유도한다.
- reference terminal을 실행해 최종 화면, escape 처리 결과, 성능/UX 기준을 비교한다.
- "core와 renderer를 분리한다", "snapshot을 테스트 산출물로 둔다"처럼 추상적인 책임 경계와 품질 기준을 참고한다.

허용하지 않는다:

- reference source의 자료구조 레이아웃, 함수 분해, iterator/control-flow 구조를 옮긴다.
- copyleft 레퍼런스(GNOME vte, kitty 등)의 소스를 구현 유도 목적으로 읽는다.
- renderer/storage/platform interop 구현을 reference source에서 line-by-line으로 포팅한다.

renderer, storage, platform interop는 VT 명세처럼 하나의 공개 표준만으로 설명되지 않을 수 있다. 이 경우 PR은 "public platform 문서에서 유도", "Maru 독립 설계", "동작 비교만 reference 사용" 중 어느 근거인지 설명해야 한다.

| 오라클 | 라이선스 | 받는 법 | 상태 |
| --- | --- | --- | --- |
| libvterm | MIT | `brew install libvterm` (또는 배포판 패키지) | ✅ CI 강제(매 푸시/PR) + 로컬 opt-in (`mise run oracle-ext`) |
| Ghostty `libghostty-vt` | MIT | `git clone --depth 1 https://github.com/ghostty-org/ghostty.git references/ghostty` 후 `mise exec zig@0.15.2 -- zig build -Demit-lib-vt=true` | ✅ 로컬 opt-in만 (`mise run oracle-ghostty`, 무거운 빌드라 CI 제외). golden 화면 비교. reflow 비교 경로(shim `maru_ghostty_dump_resize`)도 있으나, Maru가 커서 줄 reflow를 생략(xterm.js식)해 libghostty-vt와 분기하므로 현재 skip — 커서 없는 줄 reflow 검증으로 확장 시 재활성화. Ghostty의 셸 통합(OSC 133 semantic_prompt) reflow 처리도 동작 참고함 |
| Alacritty `alacritty_terminal` | Apache-2.0 | `tests/oracle/alacritty-dumper`에서 `cargo build --release` (Rust 툴체인) | ✅ CI 강제(매 푸시/PR) + 로컬 opt-in (`mise run oracle-alacritty`) |
| xterm.js | MIT | `git clone --depth 1 https://github.com/xtermjs/xterm.js.git references/xterm.js` | 📖 동작/코드 레퍼런스(headless oracle 아님). resize reflow에서 **커서가 있는 줄을 건드리지 않는**(`reflowCursorLine=false`) 방식을 참고했다(셸이 SIGWINCH로 그 줄을 다시 그림). 동작 비교만 — 코드 미복사 |

## 기능 동작 레퍼런스 (터미널 코어 밖 — clean-room, 코드 미복사)

터미널 코어가 아닌 기능(웹뷰 패널·세션 컨트롤 플레인·브라우저 자동화)을 설계할 때 **동작과 아키텍처만** 참고하는 레퍼런스다. 위 오라클과 같은 규칙을 따른다 — 공개 코드라도 자료구조 레이아웃/함수 분해/control-flow를 옮기지 않고, 동작·계약·설계 패턴만 유도한다([필수 프로젝트 규칙](project-rules.md) clean-room). PR은 "동작 비교만 reference 사용" 또는 "Maru 독립 설계" 근거를 남긴다.

| 레퍼런스 | 라이선스 | 받는 법 | 무엇을 참고 |
| --- | --- | --- | --- |
| vercel-labs/agent-browser | Apache-2.0 | `git clone --depth 1 https://github.com/vercel-labs/agent-browser references/agent-browser` | 브라우저 자동화 CLI의 **백엔드 추상화**(CDP=Chrome / **W3C WebDriver**=Safari·iOS — `cli/src/native/webdriver/`, `backend.rs`의 `BrowserBackend` trait)와 **명령 표면**(navigate/evaluate/screenshot/click/find_element 등 ~15개). Maru가 WKWebView를 **WebDriver 어댑터**로 노출하는 경로와, 별도 Chrome/Chrome for Testing 프로세스를 CDP로 붙이는 **외부 자동화 어댑터**의 동작 베이스로만 참고한다(코드 미복사). CEF는 CDP endpoint가 있어도 Chrome for Testing과 동일 호환으로 간주하지 않고, agent-browser 명령 subset smoke로 증명한다. Chrome/CDP 레퍼런스는 사용자 Chrome을 Maru 내부 NSView에 임베드할 수 있음을 뜻하지 않는다. 단일 출처: [세션 컨트롤 플레인](control-plane-browser.md) §9(`browser.*`), [웹 패널 인프라](web-panel.md) §13(CEF/Chrome 경계) |

`ohah/agent-devtools`는 공식 레퍼런스로 두지 않는다. 코드베이스 점검 결과 자체 문서와 소스 주석이 `agent-browser` 패리티·동기화 구현임을 전제로 하고 있어, Maru 입장에서는 독립적인 동작 근거가 아니다. 테스트 전략은 외부 repo 선례가 아니라 Maru 자체 원칙(프로토콜 프레이밍·JSON-RPC 디스패치·권한 판정·소켓 발견/서버를 순수 로직과 통합 E2E로 분리)으로 문서화한다.

오라클이 **아닌** 것:

- `tmux`, `vim`, `less`, `htop`, `ssh`는 Maru **안에서 돌리는 workload**다(PTY/E2E smoke 대상). 이들은 Maru의 파서를 압박하는 대상이지, 정답 화면을 대신 계산해 주는 오라클이 아니다. 특히 tmux는 내부에 VT 엔진이 있긴 하지만, 외부에서 raw byte를 직접 먹일 수 없고(팬 안 프로세스가 출력해야 함) `capture-pane`이 trailing space를 다듬고 타이밍 레이스가 있어, in-process 라이브러리(libvterm/libghostty-vt)보다 오라클로서 떨어진다.
- copyleft(LGPL: GNOME vte, GPL: kitty)는 소스 열람으로 구현을 유도하지 않고 최종 화면 동작 비교로만 쓴다(그나마도 vte/kitty는 그리드 덤프 수단이 마땅치 않아 현실적이지 않다). `xterm`은 X11 화면 스크래핑이 필요해 headless 오라클로 부적합하다.

규칙 전문은 [필수 프로젝트 규칙](project-rules.md)을 따른다.
