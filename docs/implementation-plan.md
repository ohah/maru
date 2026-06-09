# 실제 구현 계획

이 문서는 Maru의 실제 구현 순서를 정한다. 기준은 "빨리 화면을 띄우는 것"이 아니라, 나중에 PTY, parser, renderer, workspace, plugin이 서로 엉켜서 다시 갈아엎지 않게 하는 것이다.

## 핵심 판단

초기 구현은 [초기 세로 슬라이스](initial-vertical-slice.md)를 기준으로 한다.

```text
macOS 로컬 shell 1개 surface
-> PTY output bytes
-> TerminalCore
-> snapshot/trace artifact
-> headless test 통과
```

중요한 점은 parser 전체를 먼저 만들지 않는 것이다. 완전한 VT parser를 먼저 파면 실제 PTY와 E2E 없이 parser 코드만 커질 가능성이 높다. 초기 구현에서는 실제 shell bytes가 Maru의 책임 경계를 지나가는 경로를 먼저 만들고, parser는 fixture가 요구하는 만큼만 작게 확장한다.

## TDD 기준

모든 단계가 같은 형태의 TDD를 갖지는 않는다.

- 순수 동작은 전통적인 red -> green -> refactor TDD를 한다.
- facade와 책임 경계는 compile-time contract test, import boundary test, public API smoke test로 검증한다.
- macOS PTY나 global shortcut처럼 OS 상태에 묶이는 영역은 unit test와 opt-in integration/app smoke test를 분리한다.
- 자동화가 불가능한 영역은 PR에서 이유와 수동 검증 산출물을 보고한다.

즉 1단계부터 TDD는 가능하지만, 1단계의 TDD는 화면 출력 테스트가 아니라 "이 경계가 유지되는가"를 검증하는 contract test다.

## 1단계: Facade 계약을 코드로 고정

목표:

- `TerminalCore`, `PtySession`, `Surface`, `SurfaceRuntime`, `Snapshot`, `Trace/Event`의 최소 public 타입과 책임 경계를 만든다.
- 각 facade가 몰라야 하는 레이어를 import하지 않게 한다.
- `KeyBindingResolver`의 최소 타입을 만든다. full global shortcut은 나중에 구현하더라도, app action과 terminal input이 섞이지 않는 경계는 초반에 고정한다.
- `SurfaceRuntime`의 구체 API는 [SurfaceRuntime API 계약](surface-runtime-api.md)을 따른다.

TDD 방식:

- compile smoke test: public facade가 import되고 최소 생성/해제가 가능해야 한다.
- boundary test: `TerminalCore`가 PTY/platform/renderer 타입을 public API로 노출하지 않는다.
- config/action test: app action과 terminal input이 같은 타입으로 섞이지 않는다.
- resolver contract test: app action으로 소비된 key event는 terminal input으로 변환되지 않는다.
- resolver contract test: `send_control("b")` 같은 terminal input macro는 terminal bytes로 변환되지만 app action과 같은 key chord를 공유할 수 없다.

완료 기준:

- `mise run check` 통과.
- 새 facade가 [Facade 계약](facade-contracts.md)과 어긋나지 않는다.
- PR 설명에 각 facade가 왜 존재하는지 초보자용 설명이 들어간다.
- `zig build check-boundaries`가 `mise run check`에 연결되어 있다. 단순 import smoke test만으로 경계가 지켜진다고 주장하지 않는다.

아직 하지 않는다:

- 실제 macOS PTY spawn.
- renderer.
- workspace restore.
- plugin ABI.
- 실제 OS global shortcut 등록.

### 1단계 boundary checker 최소 요구사항

`import boundary test`는 말만으로는 부족하다. 초기에는 `zig build check-boundaries`의 Zig 기반 검사를 사용한다.

이 검사는 금지 import를 자동으로 막는 것이 목적이다. src 트리가 커져 파일 목록을 직접 관리하기 어려워지면 디렉터리 워킹 기반 import graph 검사로 고도화한다.

초기 금지 규칙:

```text
src/terminal/**  -> src/pty/**, src/platform/**, src/renderer/** import 금지
src/pty/**       -> src/terminal/** private 구현 import 금지
src/renderer/**  -> src/pty/** import 금지
src/plugin/**    -> src/terminal/** private 구현, src/pty/** handle import 금지
```

## 2단계: Snapshot과 artifact를 먼저 확정

목표:

- 실패했을 때 볼 수 있는 공통 산출물을 먼저 만든다.
- 테스트, 로그, replay, future inspector가 같은 도메인 데이터를 소비하게 한다.
- snapshot schema는 `maru.snapshot.v3`로 versioning한다. 이 버전은 제품 버전이 아니라 테스트 산출물과 replay consumer가 읽는 데이터 포맷 버전이다.
- version 유지/증가 기준은 [Snapshot Versioning](snapshot-versioning.md)을 따른다.

TDD 방식:

- same state -> same snapshot text.
- trailing spaces, cursor, size가 손실되지 않는 snapshot test.
- 실패 artifact가 `tests/artifacts/` 아래에 남는 E2E/support test.
- snapshot version test: snapshot text에 schema version이 들어간다.

완료 기준:

- screen text와 structured snapshot이 모두 생성된다.
- artifact 포맷은 [Fixture와 Oracle 포맷](fixture-format.md)을 따른다.
- snapshot이 renderer나 PTY 구현 세부사항을 몰라야 한다.
- snapshot 첫 줄에 bare 토큰 `maru.snapshot.v3`가 버전 표시로 들어간다(`schema=` 접두어 없이 첫 줄 전체가 schema 토큰, 현재 코드 기준).
- `future fields`를 어디에 추가할지 문서화되어 있다. cursor mode, style, alternate screen, scrollback이 붙어도 기존 버전 consumer가 깨지지 않게 한다.

아직 하지 않는다:

- full trace/replay 구현.
- GUI inspector.

## 3단계: 초기 shell 경로에 필요한 parser/core 동작만 작게 확장

목표:

- 완전한 VT parser가 아니라, 초기 shell smoke에 필요한 최소 terminal core 동작만 TDD로 추가한다.
- CR/LF, printable text, resize, cursor 위치 같은 기본기를 먼저 안정화한다.

진행 상태:

- CR/LF/Tab/backspace, printable text -> cell은 초기부터 동작한다.
- resize는 화면을 비우지 않고 겹치는 영역(min(old,new) 좌상단)을 보존하고 커서를 새 크기로 clamp한다(완료). 이전에는 resize가 매번 화면을 `@memset`으로 지워, 창을 줄이면 셸이 SIGWINCH로 다시 그리기 전까지 빈 화면이 보였다. cols가 줄어 wide glyph(width=2)의 continuation이 잘리면 짝 없는 base를 blank로 정리한다.
- printable 출력이 마지막 열을 넘으면 다음 줄로 넘어가는 **autowrap(DECAWM deferred/pending wrap)**을 구현했다(완료). 마지막 칸을 채운 직후 커서는 그 칸에 머물고 pending_wrap만 서며, 다음 printable 글자가 먼저 다음 줄로 넘어간 뒤 그려진다(끝 글자마다 빈 줄이 끼지 않게). 명시적 커서 이동(CR/LF/backspace/커서 위치 지정/resize)은 pending_wrap을 무효화하고, wide glyph가 줄 끝에 1칸만 남으면 통째로 다음 줄로 넘긴다. autowrap은 zsh PROMPT_SP 등 거의 모든 셸/프로그램이 의존하는 기본 동작이라 우선 구현했다. 그 위에 행별 soft-wrap 플래그(wrapped)를 추적해 **resize reflow를 스크롤백 위에서 구현했다(완료)**: 논리 줄을 합쳐 새 폭에 다시 wrap하고 넘치는 위쪽 행은 스크롤백으로 민다. **단, 커서가 있는 논리 줄은 reflow하지 않고 그대로 둔다**(xterm.js의 `reflowCursorLine=false` 기본 동작). 이유: zsh는 SIGWINCH 때 이전 폭 기준으로 커서를 상대 이동(`\e[A`)해 프롬프트를 지우고 다시 그리는데, 커서가 있는 줄을 재배치해 커서가 옮겨지면 그 상대 이동이 어긋나(프롬프트에 못 닿아) 프롬프트가 중복된다. 그 줄은 셸이 새 폭으로 직접 다시 그리므로 터미널이 건드리지 않는 게 안전하다. 활성 화면의 다른(커서 없는) 줄과 스크롤백으로 가는 내용은 정상 reflow한다. (한 번은 커서 줄까지 reflow해 라이브에서 프롬프트가 중복됐다 — 단일 resize는 Ghostty 오라클과 일치했지만, 같은 reflow라도 zsh의 상대 redraw와 라이브에서 충돌했다. Ghostty는 셸 통합(OSC 133 semantic_prompt)으로, xterm.js는 커서 줄을 안 건드리는 방식으로 푸는데, 후자가 셸 통합 없이도 되는 더 단순한 길이라 채택했다. perf는 활성 화면만 reflow해 O(활성 행)으로 유지한다 — 기존 스크롤백 행 재-wrap, 그리고 셸 통합(OSC 133)은 이후 단계.)
- `TerminalCore.write`에 VT escape 상태기계(ground/escape/CSI/OSC)를 붙였다(완료). 실제 shell prompt가 내보내는 escape를 글자로 찍지 않고 해석한다: SGR(`m` — bold/italic/underline, 16색·256색·rgb 전경/배경, reset)을 pen으로 적용하고, cursor 이동/위치(CUU/CUD/CUF/CUB, CUP, CHA, VPA), erase(EL `K`, ED `J`)를 처리하고, DSR/CPR(`CSI 6n`→커서 위치 `CSI row;col R`, `CSI 5n`→`CSI 0n`)·DA1(`CSI c`→VT102 식별 `CSI ?6c`)에는 PTY write-back으로 응답하고, DECSC/DECRC(`ESC 7`/`ESC 8` — 커서+pen+pending_wrap 저장/복원, DECSET 1048과 같은 슬롯)를 처리하며(claude CLI가 시작 시 `ESC 7, CSI r, ESC 8`로 region을 리셋하는데 복원이 없으면 커서가 home에 남아 UI가 기존 화면 맨 위를 덮는다), OSC(title 등)와 private(`CSI ? ...`) 시퀀스는 소비만 한다. 시퀀스가 PTY read 경계로 쪼개져도 파서 상태가 write() 호출 사이에 유지된다. CSI 안의 ESC는 시퀀스를 취소하고 새 escape로 재시작하며, C0 control은 실행하고 CSI를 계속한다. 파라미터가 16개를 넘으면 이후는 버린다(마지막 파라미터 오염 방지). erase/eraseInDisplay는 dirty를 덮어쓰지 않고 markDirty로 병합하고, 경계에 걸친 wide glyph 짝을 정리하며, last_print를 비운다.
- SGR 38/48 확장색은 세미콜론(`38;2;r;g;b`, `38;5;n`)과 colon sub-parameter(`38:2:colorspace:r:g:b`, `38:5:n`) 형식을 모두 정확히 처리한다. 파라미터마다 `:`로 들어왔는지(sub-parameter) 추적해, colon mode 2의 colorspace 컴포넌트를 건너뛰고 r/g/b를 읽는다.
- SGR가 정한 cell 배경색은 Metal renderer가 칠한다. 투영이 glyph cell엔 배경색을 같이 싣고, glyph 없는 공백 중 non-default 배경은 배경 전용 cell(sentinel UV)로 내며, 공유 셰이더가 `mix(bg, fg, coverage)`로 배경 위에 glyph를 blend한다(기본 배경은 a=0이라 기존 전경 전용 경로와 동일).
- **scroll region(DECSTBM)을 구현했다(완료)**: `CSI Pt;Pb r`로 상/하단 margin(1-indexed, 기본 전체)을 정하면 LF/IND(`ESC D`)는 하단 margin에서, RI(`ESC M`)는 상단 margin에서 그 구간 안에서만 스크롤한다(less/vim이 상태줄을 고정하고 본문만 스크롤하는 데 쓴다). margin이 화면 최상단(top==0)일 때만 밀려난 줄을 스크롤백에 보관하고, 부분 region(top>0)이나 아래로 스크롤되는 줄은 history가 아니라 버린다. 2행 미만 region은 무시하고, resize는 margin을 전체 화면으로 리셋한다. unit + libvterm·Alacritty 오라클(활성 화면 골든 일치)로 검증.
- **alternate screen(DECSET 1049/47/1047/1048)을 구현했다(완료)**: vim·less 같은 TUI가 보조 버퍼에서 전체 화면을 쓰고 종료 시 원래 셸 화면과 커서를 복원한다. 1049는 들어가며 커서 저장(DECSC)+빈 alt 화면, 나오며 primary+커서 복원(DECRC). 47/1047은 전환만, 1048은 커서 저장/복원만. alt 출력은 스크롤백에 쌓이지 않고(top==0 스크롤도 history 아님) 스크롤백 뷰포트도 잠긴다. alt 중 resize는 reflow/스크롤백 없이 활성 alt와 저장된 primary 그리드를 함께 clip/pad한다(TUI는 SIGWINCH로 전체를 다시 그리고, primary는 복귀 시 크기가 맞아야 한다). unit + libvterm·Alacritty 오라클로 검증(libvterm 오라클은 `vterm_screen_enable_altscreen`을 켜야 실제 터미널과 같다). **alternate scroll(xterm DECSET 1007, 기본 on)**도 구현했다: alt screen에서는 스크롤백이 잠기므로 휠/트랙패드 스크롤을 화살표 키로 변환해 프로그램(less/vim)에 보내 자체 스크롤하게 한다(iTerm2/Terminal.app 기본 동작, DECCKM이면 SS3 형식). 트랙패드의 1줄 미만 정밀 델타는 누적해(`wheel_accum`) 천천히 굴려도 줄이 소실되지 않는다.
- **IL/DL(CSI L/M), 커서 표시(DECTCEM ?25), reverse(SGR 7/27)를 구현했다(완료)**: IL은 커서 행에 빈 줄 n개를 삽입(커서 행~region 하단이 내려가고 넘치는 줄은 버림), DL은 커서 행부터 n줄 삭제(아래가 올라옴) — 둘 다 scroll region 안에서만 동작하고 커서가 밖이면 무시하며, 편집 연산이라 history(스크롤백)에 넣지 않고, 후처리로 커서를 행 첫 칸으로 옮긴다(CR). vim이 줄 열기/삭제를 전체 redraw 없이 하는 핵심 시퀀스다. unit + libvterm·Alacritty 오라클(골든 일치)로 검증. DECTCEM(?25 h/l)은 core가 cursor_visible로 추적하고 snapshot/renderSnapshot이 내보내는 cursor.visible에 합성한다(렌더 overlay 경로는 이미 visible을 따름). reverse(SGR 7/27, SGR 0도 리셋)는 Style.reverse로 추적하고 Metal 투영(packForeground/packBackground)이 전경/배경을 스왑한다 — default 색은 theme 값(default_fg/default_bg)으로 풀어 실제로 칠한다(안 풀면 default 배경이 A=0이라 반전이 안 보인다).
- 아직: 배경색 erase(BCE — 현재 pen 배경으로 지우기)는 아직 없다. DECOM(origin mode)·ICH/DCH(문자 삽입/삭제) 등 나머지 CSI/모드는 소비만 한다.

TDD 방식:

- ANSI fixture -> `TerminalCore.write` -> screen golden.
- recorded oracle snapshot 비교.
- resize/write stress.
- `mise run perf`로 core hot path guardrail 확인.

완료 기준:

- 작은 fixture가 늘어날 때마다 golden과 snapshot artifact가 함께 남는다.
- parser 변경이 `TerminalCore` 내부 책임으로 닫혀 있다.
- PTY나 renderer를 위해 core API를 임시로 새지 않게 한다.

아직 하지 않는다:

- xterm 전체 호환성.
- Kitty graphics protocol.
- OSC/clipboard/advanced mouse mode 전체.
- 기존 스크롤백 행의 재-wrap. 활성 화면 reflow와 wrap 추적은 구현했지만(위 3단계 참고), 이미 스크롤백에 쌓인 행을 resize 때 새 폭으로 다시 wrap하는 것은 이후 단계다(perf상 활성 화면만 reflow하므로 과거 스크롤백은 저장된 폭 그대로 보인다).
- UAX#11 전체/ambiguous width 설정/ZWJ emoji/box drawing 정렬. 현재는 최소 width table과 continuation/combining cell 모델까지만 구현한다.
- Ghostty/libghostty-vt 코드 복사.

## 4단계: macOS `PtySession` 최소 구현

목표:

- macOS `openpty` 기반으로 먼저 통제된 command를 실행한다. `forkpty`는 child setup을 너무 많이 감추므로 초기 제품 backend로 쓰지 않는다.
- 첫 backend는 테스트가 timing race 없이 검증할 수 있도록 blocking pull API인 `PtySession.readEvent`를 제공한다.
- reader thread, queue, backpressure는 `PtySession.readEvent` 루프 위의 app layer 책임이다. 운영 모델은 [PTY 운영 모델](pty-operating-model.md)을 따른다.
- 통제된 command가 안정화된 뒤 interactive shell smoke를 opt-in으로 추가한다.
- PTY output bytes를 domain event로 내보낸다.
- terminal input bytes와 resize request를 PTY에 전달한다.

TDD 방식:

- unit test: spawn request/env/cwd validation.
- integration test: 통제된 command stdout을 읽는다.
- integration test: resize request가 PTY layer까지 전달된다.
- process lifecycle test: exit status가 event로 관측된다.
- artifact test: raw PTY bytes, screen text, structured snapshot이 `tests/artifacts/integration/pty/`에 남는다.
- opt-in smoke test: 사용자의 shell을 실행해 prompt/output이 crash 없이 snapshot까지 도달하는지 확인한다.

완료 기준:

- `PtySession`은 escape sequence 의미를 모른다.
- `TerminalCore`는 PTY file descriptor를 모른다.
- 실패 시 stdout bytes와 snapshot artifact가 남는다.
- deterministic controlled command PTY test와 환경 의존 interactive shell smoke가 분리되어 있다.
- interactive shell smoke는 `mise run pty`에서 `$MARU_INTERACTIVE_SHELL` 또는 `$SHELL`을 `-i`로 실행하고 marker command를 입력해 raw/screen/snapshot/summary artifact를 남긴다. 사용자 dotfile/prompt escape 영향이 있으므로 처음부터 기본 `mise run check`에는 넣지 않는다.
- `mise run pty`는 macOS PTY opt-in 테스트를 실행한다.
- app/demo/smoke 코드는 정상 종료와 close/error cleanup에서 `LivePtySession` owner를 사용한다. 이 owner는 `PtySession`, `PtyEventQueue`, `PtyReader`, runtime attach link를 한 live terminal session 단위로 묶고, 정상 종료 뒤 cleanup이 `stopAndJoin`을 다시 부르지 않게 하며, 조기 실패 경로에서는 아직 join되지 않은 reader를 같은 `PtyReader.stopAndJoin` 순서로 닫게 한다. surface도 함께 닫히는 경로는 `LivePtySession.closeAndDetach`를 통해 runtime routing을 먼저 끊고 같은 close 순서를 탄다.

아직 하지 않는다:

- SSH.
- login shell UX 완성.
- job control 전체 호환성.
- global shortcut.
- macOS app host의 실제 tab/window close button event와 `FrameLoop.closeActiveLivePty` 연결.

## 5단계: `SurfaceRuntime`으로 PTY와 Surface 연결

목표:

- 하나의 사용 가능한 terminal surface를 만든다.
- `PTY output event -> SurfaceRuntime -> Surface -> TerminalCore -> Snapshot` 경로를 완성한다.
- `Surface`는 `TerminalCore`와 복구 가능한 metadata를 보관하고, live `PtySession` handle은 직접 저장하지 않는다.
- `SurfaceRuntime`은 app layer에서 `Surface`와 `PtySession`의 live 연결만 관리한다.
- `SurfaceRuntime`은 concrete `PtySession` 대신 `PtyIo` adapter를 저장한다. 그래야 unit test가 macOS 실제 PTY에 의존하지 않고 routing 계약을 검증할 수 있다.
- surface metadata인 title, cwd, env, command, size를 복구 가능한 형태로 보관한다.
- workspace restore는 구현하지 않더라도 `RestorableSurfaceMetadata` 초안은 만든다.

TDD 방식:

- unit test: PTY output event가 `SurfaceRuntime`을 거쳐 surface의 `TerminalCore`로 전달된다.
- unit test: surface resize가 `SurfaceRuntime`을 통해 core resize와 PTY resize request로 분리되어 전달된다.
- unit test: terminal input bytes가 fake PTY로 전달된다.
- unit test: duplicate attach, detach 이후 late output, process exit 이후 input 거부가 각각 오류로 관측된다.
- snapshot test: surface metadata와 terminal state가 같은 artifact에 함께 보인다.
- metadata test: cwd/env/command/size가 serializable draft model로 round-trip된다.
- 민감정보 test 초안: env 저장 정책이 정해질 때까지 `RestorableSurfaceMetadata.env`가 비어 있음을 검증한다.

완료 기준:

- surface는 renderer 좌표나 GPU resource를 모른다.
- workspace 저장 포맷을 아직 확정하지 않아도, 저장 가능한 metadata 경계는 존재한다.
- live PTY handle은 metadata에 들어가지 않는다.
- live PTY handle은 `Surface`가 아니라 `SurfaceRuntime` 책임이다.
- env 저장은 이번 단계에서 하지 않는다. allowlist/redaction 정책이 정해질 때까지 빈 목록으로 고정한다.

아직 하지 않는다:

- 여러 탭.
- split layout.
- workspace restore.
- 실제 app host lifecycle. `PtyReader`, `PtyEventQueue`, `RuntimeEventPump`는 생겼지만 macOS window/app loop가 아직 이 pump를 frame/input lifecycle에 연결하지 않는다.
- OSC52/shell integration app request queue.

## 6단계: Headless E2E를 초기 성공 기준으로 고정

목표:

- GUI 없이 실제 process/PTY output이 snapshot까지 도달하는지 자동으로 증명한다.
- 기본 check에는 deterministic path만 넣는다. 환경 의존 PTY shell smoke는 opt-in으로 둔다.

TDD 방식:

- E2E fixture: controlled command -> PTY -> SurfaceRuntime -> Surface -> TerminalCore -> screen snapshot.
- failure artifact: raw output, decoded screen, structured snapshot, surface metadata.
- replay 준비: event 이름과 저장 위치를 먼저 맞춘다.
- trace/replay schema와 의미는 [Trace와 Replay](trace-replay.md)를 따른다.
- opt-in smoke: interactive shell -> snapshot까지 crash 없이 도달하는지 확인한다.

완료 기준:

- `mise run check`가 deterministic headless E2E를 포함한다.
- `mise run pty`가 macOS PTY controlled command와 `PtyReader -> PtyEventQueue -> RuntimeEventPump -> SurfaceRuntime` routing 경로를 opt-in으로 검증한다.
- `mise run demo`가 GUI 없이 같은 PTY/runtime/snapshot 경로를 실행하고 `zig-out/maru-demo/`에 screen, snapshot, summary를 남긴다.
- `mise run app-loop-smoke`가 실제 AppKit event loop 없이도 `FrameLoop.tick`을 여러 번 호출해 output frame, idle frame, termination frame을 같은 app/window/runtime/renderer state 위에서 만들고 `zig-out/maru-app-loop-smoke/`에 summary, frame log, screen artifact를 남긴다. 이 smoke는 실제 UI가 아니라 native loop가 호출할 deterministic app-level 계약이다.
- `mise run app-pty-loop-smoke`가 실제 PTY reader thread에서 온 event batch를 반복 `FrameLoop`에 태우고 `zig-out/maru-app-pty-loop-smoke/`에 raw PTY bytes, screen, snapshot, frame loop artifact를 남긴다. 이 smoke는 실제 PTY와 반복 frame loop를 같이 검증하지만 아직 AppKit/Metal 창을 띄우지 않으므로 `visible_ui=false`를 명시한다. PTY event drain은 smoke 전용 5000ms deadline을 가져서 reader/shell hang을 `SmokeDrainTimedOut`으로 실패시키고 summary에 `drain_timeout_ms`를 남긴다.
- `mise run app-pty-interactive-loop-smoke`가 `$MARU_INTERACTIVE_SHELL` 또는 `$SHELL`을 `-i`로 실행하고, marker command를 `FrameLoop.handleKeyEvent -> KeyBindingResolver -> SurfaceRuntime.writeInput` 경계로 보낸 뒤 반복 frame artifact를 `zig-out/maru-app-pty-interactive-loop-smoke/`에 남긴다. 이 smoke는 제품 UI는 아니지만 interactive shell input이 app frame loop 경계를 지나는지 검증한다. 사용자 dotfile/prompt escape 영향이 있으므로 기본 `check`에는 넣지 않는다. PTY event drain은 같은 5000ms deadline을 사용한다.
- `mise run app-pty-smoke`가 실제 PTY controlled command를 `SurfaceRuntime -> AppWindow -> AppHostFrame -> RendererState`까지 통과시키고 `zig-out/maru-app-pty-smoke/`에 raw PTY bytes, screen, snapshot, renderer frame artifact를 남긴다. 이 smoke는 실제 app host 결합 경로를 검증하지만 아직 AppKit/Metal 창을 띄우지 않으므로 `visible_ui=false`를 명시한다. PTY event drain은 같은 5000ms deadline을 사용한다.
- `mise run macos-app-pty-interactive-metal-smoke`가 `$MARU_INTERACTIVE_SHELL` 또는 `$SHELL -i`를 실제 AppKit/CAMetalLayer visible path에 태우고, marker command와 `exit`를 app keybinding 경계로 보낸 뒤 `zig-out/maru-macos-app-pty-interactive-metal-smoke/`에 raw/screen/snapshot/screenshot/summary artifact를 남긴다. 이 smoke는 실제 shell startup, prompt, dotfile 영향이 있는 output이 CoreText/Metal까지 도달하는지 확인하지만, 사용자가 계속 타이핑하는 제품 event loop는 아니다.
- 실패했을 때 원인을 parser, PTY, surface 연결 중 어디서 봐야 하는지 artifact로 판단할 수 있다.
- `headless_demo`, `app-pty-smoke`, `app-pty-loop-smoke`, `macos-app-pty-metal-smoke`는 `LivePtySession` owner를 사용한다. `LivePtySession.closeAndDetach`는 실제 제품 close button이 들어오기 전에 낮은 close 순서(`detachSurface -> close`)를 단위 테스트로 먼저 고정하고, `host.closeActiveLivePty`/`FrameLoop.closeActiveLivePty`는 registry에서 active surface의 live PTY를 찾아 그 owner primitive를 호출하는 app-level close command 경계다. visible smoke는 마지막 frame 뒤 같은 Metal terminal window의 AppKit close delegate에서 Zig callback을 호출하고, 그 callback이 같은 app host close action으로 내려가는지 확인한다. 아직 사용자가 계속 조작하는 제품 tab/window close button lifecycle은 아니다.

아직 하지 않는다:

- renderer frame budget.
- 대량 stdout backpressure의 RSS/latency/UI responsiveness 성능 예산.
- 사용자가 계속 입력하는 제품 interactive shell loop와 제품 window/tab close button lifecycle. scripted visible shell smoke는 생겼지만, 실제 제품 window/tab close button event는 이후 PR에서 `FrameLoop.closeActiveLivePty`를 native lifecycle에 연결해 검증한다.

## 7단계: Renderer와 macOS app host 연결

목표:

- renderer는 snapshot 계약만 소비한다.
- macOS app host는 입력, window, focus, surface lifecycle을 관리한다.
- 실제 backend 선택과 검증 순서는 [렌더러 전략](renderer-strategy.md)을 따른다.
- font resolve, fallback, glyph atlas, emoji/CJK 처리 정책은 [폰트 전략](font-strategy.md)을 따른다.
- app host가 `RuntimeEventPump`를 frame loop에 연결할 때, exit/read_error termination은 [SurfaceRuntime API 계약](surface-runtime-api.md)의 "drain 종료 계약" 절에 따라 `DrainSummary.ended` 데이터로 처리한다.

TDD 방식:

- renderer unit/golden test: snapshot -> draw command model.
- 초기 draw command model은 현재 `TerminalCore` dirty 계약에 맞춰 row dirty 범위를 소비한다. cell 단위 dirty는 dirty 모델 확장 PR에서 별도로 다룬다.
- cursor와 underline은 cell overlay로 그린다. cursor 이동이 dirty 범위를 만든다는 domain 계약(`renderer-strategy.md`)은 CR/backspace/line feed 같은 cursor-only 이동 단위 테스트와 `DrawList` overlay 테스트로 검증한다. selection overlay는 selection domain data가 생길 때 별도 PR에서 다룬다.
- font layout test: fake font backend로 `DrawList -> GlyphRunList` 계약을 검증한다. native shaper가 이미 font id/glyph id 후보를 만든 경로는 `coretext_probe.zig -> coretext_font.zig -> coretext_shaper.zig -> GlyphRunList` adapter test로 별도 검증해 CoreText smoke 전용 변환 로직이 제품 frame 준비 로직과 갈라지지 않게 한다. 제품 shaper adapter는 `ShapedGlyphSurface`를 받아 `DrawList`의 size/cursor/dirty/overlay metadata를 보존해야 한다.
- font identity test: native shaper가 만든 drawable glyph의 platform font face를 macOS `coretext_font.zig` adapter와 `FontIdentityRegistry`에 통과시켜 안정적인 `FontId`로 바꾸는 계약을 검증한다. 이 테스트는 glyph id가 font-relative라는 사실을 고정하기 위한 것이다. 같은 PostScript name은 같은 `FontId`를 재사용하고, 서로 다른 fallback face는 다른 `FontId`를 가져야 하며, 공백처럼 rasterizer에 도달하지 않는 record는 count에 섞지 않는다.
- renderer state shaped-input test: CoreText 같은 제품 shaper가 만든 `GlyphRunList`를 `RendererState`가 직접 받아 `RenderFrame`을 준비할 수 있어야 한다. 이 경계가 없으면 CoreText를 fake backend의 `shape(cell)` 계약에 맞추게 되고, 줄/런 단위 shaping과 fallback metadata가 나중에 다시 갈아엎을 구조로 굳는다.
- glyph atlas test: GPU texture 없이 `GlyphCacheKey -> AtlasSlot` cache, row-packed slot 좌표 후보, upload byte 후보, eviction, invalidation reason을 검증한다. **row packer 좌표가 텍스처를 소진하면 전체 invalidate(`atlas_full`) 후 (0,0)부터 재배치한다** — eviction은 슬롯 수만 줄이고 좌표를 재활용하지 않아, 고유 글리프가 많은 출력(예: claude CLI의 스피너/박스/이모지)을 스크롤하면 y가 텍스처 높이를 넘어 UV가 범위 밖이 되고 글자가 깨지다가 안 보이는 라이브 버그가 있었다. 모든 슬롯의 아래 끝이 항상 텍스처 안임을 회귀 테스트로 고정(소진 직후 한 frame은 앞서 배치된 글리프가 섞일 수 있으나 다음 frame에 자동 회복).
- glyph quad test: GPU 없이 `GlyphFrame -> GlyphQuadFrame`을 만들고, atlas slot pixel rect가 normalized UV로 바뀌며 texture bounds 오류가 backend 전에 실패하는지 검증한다.
- glyph raster test: GPU 없이 `GlyphFrame -> GlyphRasterFrame`을 만들고, upload 후보가 contiguous RGBA bytes 또는 명시적 skip으로 바뀌며 byte offset, row bytes, zero-ink 진단값, skip 이유가 남는지 검증한다. 기본 unit test는 backend input byte 계약을 고정하는 test rasterizer 경로를 쓰고, macOS CoreText/Metal smoke는 같은 `GlyphRasterFrame` 경로에 제품 후보 `coretext_raster.zig` wrapper와 smoke native bridge를 주입해 실제 glyph byte 경계도 확인한다. atlas texture 경계 밖 slot은 byte buffer를 만들지 않고 skip한다.
- config resolve test: raw font/theme/cursor config를 `ResolvedAppearance`로 바꾸고, 빈 font family, 잘못된 font size, 잘못된 `#RRGGBB` 색상을 renderer/backend에 보내기 전에 거부한다.
- app host smoke: 실제 UI 없이 `AppWindow -> SurfaceRuntime -> RuntimeEventPump -> RendererState -> DrawList -> GlyphFrame -> GlyphQuadFrame -> GlyphRasterFrame` frame 조립, resize, focused input artifact를 `mise run app-smoke`로 남긴다. `RendererState`는 frame 사이에 살아남는 `GlyphAtlas`를 소유하므로, app host가 매 frame atlas를 새로 만들지 않는다는 계약도 여기서 고정한다.
- app frame loop smoke: 실제 UI 없이 `FrameLoop.tick`이 같은 `AppWindow`, `SurfaceRuntime`, `RuntimeEventPump`, `RendererState`를 들고 여러 frame을 순서대로 만들 수 있는지 `mise run app-loop-smoke`로 남긴다. 이 단계는 native AppKit loop가 나중에 `drainAvailable -> build frame -> render stats` 순서를 직접 재구현하지 않고 같은 API를 호출하게 만들기 위한 계약이다. 첫 output tick, queue가 빈 idle tick, termination tick을 모두 artifact로 남기지만, 실제 PTY reader thread나 window server는 여기서 검증하지 않는다.
- live PTY app frame loop smoke: 실제 UI 없이 `PtyReader -> PtyEventQueue -> RuntimeEventPump -> SurfaceRuntime -> FrameLoop.tickAfterDrain -> RendererState -> RenderFrame` 반복 경로를 `mise run app-pty-loop-smoke`로 남긴다. 이 단계는 `app-loop-smoke`의 deterministic queue와 `app-pty-smoke`의 real PTY one-shot frame 사이 gap을 줄인다. 첫 event batch 뒤에 빈 queue idle tick을 강제로 넣어 app loop가 output이 없는 frame도 만들 수 있음을 artifact로 남기지만, AppKit window server와 frame pacing은 여기서 검증하지 않는다. smoke drain은 `popBlocking` 직접 대기 대신 deadline helper를 사용해, 멈춘 reader/shell은 timeout으로 실패하고 조기 queue close는 lifecycle 실패로 분리한다.
- interactive shell app frame loop smoke: 실제 UI 없이 `$MARU_INTERACTIVE_SHELL` 또는 `$SHELL -i`를 `PtyReader -> RuntimeEventPump -> SurfaceRuntime -> FrameLoop` 반복 경로에 태우고, marker command를 app keybinding 경계로 PTY에 보낸다. 이 단계는 사람이 지속 입력하는 제품 shell loop가 아니라, dotfile/prompt 영향을 받는 shell이 app 입력 경계와 반복 frame loop를 통과하는지 보는 opt-in smoke다.
- macOS window smoke: `mise run test-macos-window-smoke`로 summary 계약을 검증하고, `mise run macos-window-smoke`로 Metal/terminal grid 없이 AppKit 창을 실제로 띄워 `visible_ui=true` artifact를 남긴다. 이 단계는 app lifecycle smoke이며, terminal renderer 검증은 아니다.
- macOS Metal smoke: `mise run test-macos-metal-smoke`로 summary와 fixture 계약을 검증하고, `mise run macos-metal-smoke`로 AppKit 창 위 CAMetalLayer에 실제 `TerminalCore -> DrawList -> CoreTextDrawListShaper -> RendererState -> GlyphFrame -> GlyphQuadFrame/GlyphRasterFrame -> coretext_raster.zig` 기반 cell quad를 present한다. `terminal_grid=true`는 입력 cell count나 non-clear heuristic이 아니라 source raster에서 고른 texel과 drawable readback 픽셀이 일치할 때만 기록한다. 또한 같은 제품 `GlyphRasterFrame`의 CoreText upload bytes를 Metal `RGBA8Unorm` atlas texture에 올리고 blit readback으로 source bytes와 일치하는지 확인한다(`product_atlas_uploaded=true`). upload가 0개인 all-skip frame은 upload/readback 실패가 아니라 source 누락으로 회계한다. 그 다음 fragment shader가 같은 atlas texture를 샘플링해 drawable readback 픽셀이 source raster texel과 일치하고 source 누락 cell이 없으면 `product_atlas_sampled=true`를 남긴다. `glyph_text`는 fixture 라벨이 아니라 `product_atlas_sampled`(샘플링 증거)이고 그 frame이 실제 CoreText glyph bytes를 쓴 경우에만 참이다. 마지막으로 같은 drawable 전체를 PPM screenshot artifact로 남기고 `screenshot_artifact=true`를 gate에 포함한다. summary에는 `renderer_input=terminal_core_draw_list`, `renderer_shaper=coretext_draw_list`, `renderer_rasterizer=coretext_glyph_rasterizer`, `renderer_frame_prepared=true`, `renderer_atlas_slot_placement=true`, `renderer_glyph_uv_ready=true`, `renderer_glyph_raster_ready=true`, `renderer_glyph_raster_skipped_count`, `product_atlas_uploaded`, `product_atlas_sampled`, `screenshot_artifact`, `screenshot_path`, `atlas_sample_missing_cells`, atlas upload/readback/sample/screenshot 통계를 남긴다. 이 단계는 실제 CoreText glyph bitmap이 terminal cell atlas shader를 통해 보이는 첫 UI 검증이다. 아직 실제 PTY/shell 입력은 없다.
- macOS live PTY Metal smoke: `mise run test-macos-app-pty-metal-smoke`로 summary 계약을 검증하고, 기본 `mise run macos-app-pty-metal-smoke`로 controlled command의 실제 PTY output과 같은 Metal terminal window에서 받은 AppKit `keyDown:` event가 app host keybinding resolver를 통과하는 roundtrip을 검증한다.
  - output 경로는 `PtyReader -> PtyEventQueue -> RuntimeEventPump -> SurfaceRuntime -> FrameLoop -> coretext_frame_builder.zig(active AppWindow surface -> TerminalCore -> DrawList -> CoreTextDrawListShaper -> CoreTextGlyphRasterizer -> RendererState -> GlyphQuadFrame/GlyphRasterFrame) -> Metal atlas shader sampling -> screenshot`까지 이어진다.
  - controlled mode의 입력은 ready marker를 PTY output에서 먼저 관측한 뒤 ready frame을 같은 Metal terminal window에 띄우고, synthetic/manual `Cmd+B`를 그 window의 `keyDown:` 경계에서 받아 `FrameLoop.handleKeyEvent -> KeyBindingResolver -> SurfaceRuntime.writeInput` 경로로 보낸다.
  - interactive shell mode는 shell prompt readiness를 환경별로 신뢰할 수 없어서 marker command를 즉시 보내며, `mise run macos-app-pty-interactive-metal-smoke`는 `$MARU_INTERACTIVE_SHELL` 또는 `$SHELL -i`, marker command, `exit` output을 같은 visible path에 태운다.
  - ready marker drain과 termination drain은 같은 deadline helper를 사용한다. keyDown 수집용 ready frame은 별도 `RendererState`로 만들어 final frame의 glyph atlas cache를 오염시키지 않고, key input 뒤 final frame은 제품 후보 `FrameLoop.tickAfterDrainWithFrameBuilder -> coretext_frame_builder.zig` 경로로 만든다.
  - 마지막 visible frame 뒤에는 같은 Metal terminal window의 AppKit close delegate가 Zig callback을 호출하고, callback은 `FrameLoop.closeActiveLivePty -> host.closeActiveLivePty -> LivePtyRegistry.closeActive -> LivePtySession.closeAndDetach`로 내려가 active surface/link 검증, registry mapping 제거, runtime detach, late output/input 거부, queue close, idempotent close를 같은 smoke gate에 포함한다.
  - `MARU_APP_PTY_METAL_KEYDOWN_SOURCE=manual`을 명시하면 synthetic event 대신 사용자가 같은 Metal terminal window에서 누른 `Cmd+B` payload를 같은 resolver 경로에 태운다. 이 manual mode는 잘못 누른 키를 PTY로 보내지 않도록 기대 chord와 비교한 뒤 진행한다.
  - summary에는 `renderer_input=surface_runtime_live_pty_frame_loop_coretext_render_frame`, `interactive_shell`, `frame_loop_ticks`, `frame_loop_final_tick_index`, `frame_loop_final_ended`, `drain_timeout_ms`, `close_lifecycle=appkit_terminal_window_close_callback_after_visible_frame`, `native_close_*`, `terminal_close_*`, `terminal_window_closed`, `close_surface_detached`, `close_registry_unregistered`, `close_late_output_rejected`, `close_input_rejected`, `close_queue_closed`, `close_idempotent`, `input_source=appkit_keydown_to_app_host_keybinding_resolver`, `native_key_event_source=metal_terminal_synthetic_keydown` 또는 `metal_terminal_manual_keydown`, `native_keydown_*`, `scripted_key_event_sent`, `scripted_key_event_result`, `screen_contains_expected`, `output_events`, `exit_events`, `termination`, `product_atlas_uploaded`, `product_atlas_sampled`, `screenshot_artifact`, raw/screen/snapshot/screenshot artifact 경로를 남긴다.
  - 이 단계는 실제 PTY bytes와 같은 Metal terminal window의 AppKit `keyDown:`으로 정규화된 keybinding-resolved terminal input bytes가 보이는 Metal UI까지 도달하고 같은 terminal window close delegate callback도 app host close action을 호출하는 검증이다. 다만 사용자가 지속적으로 입력하는 제품 interactive shell loop, 제품 tab/window close button, ANSI escape 장기 호환성은 아직 아니다.
- macOS CoreText smoke: `mise run test-macos-coretext-smoke`로 summary 계약을 검증하고, `mise run macos-coretext-smoke`로 창/GPU 없이 default raw config가 `ResolvedAppearance`로 검증된 뒤 그 font family/size 요청이 CoreText bridge까지 전달되는지 확인한다. 그 다음 macOS CoreText가 요청 font 또는 system monospace fallback으로 ASCII/CJK/emoji probe를 glyph run으로 shape하는지 확인한다. 또한 drawable glyph id/font face 후보가 macOS `coretext_probe.zig`, `coretext_font.zig` adapter, `FontIdentityRegistry`, `coretext_shaper.zig`, renderer 중립 `GlyphRunList -> RendererState -> RenderFrame` 준비 계약까지 들어갈 수 있는지 확인하고, 제품 후보 `coretext_raster.zig` wrapper가 같은 PostScript name으로 smoke native bridge를 호출해 제품 `GlyphRasterFrame` bytes를 만들 수 있는지도 확인하며, 같은 `CTLine`을 CPU bitmap에 그려 non-clear pixel이 나오는지도 확인한다. 추가로 실제 `TerminalCore -> DrawList` fixture를 `CoreTextDrawListShaper` native bridge로 shape해 `drawlist_input=terminal_core_draw_list`, `drawlist_renderer_shaper=coretext_draw_list`, `drawlist_frame_prepared=true`, `drawlist_glyph_raster_ready=true`를 남긴다. fixed probe summary에는 `font_identity_ready`, `font_identity_count`, `renderer_input=coretext_shaped_glyph_run_list`, `renderer_shaper=coretext_shaped_records`, `renderer_rasterizer=coretext_glyph_rasterizer`, `renderer_frame_prepared`, `renderer_surface_cols/rows`, `renderer_glyph_raster_*` 통계를 남긴다. `font_identity_count`는 실제 rasterizer가 조회할 drawable glyph face 수다. fixed probe의 surface는 native record bounds에서 만든 probe surface지만, DrawList probe는 terminal cursor/dirty/overlay metadata를 실제 제품 shaper 경계에 태운다. `coretext_probe.zig`, `coretext_shaper.zig`, `coretext_raster.zig` 단위 테스트가 probe record 변환, surface metadata 보존, DrawList shaper bridge, FontId -> PostScript name raster bridge 계약을 검증한다. 이 단계는 설정 파일/설정 UI/runtime reload, Metal texture upload, 실제 화면 text draw 검증은 아니지만, text renderer 전에 config/font stack/frame-prep/raster 실패를 분리하는 검증이다. 단, native CoreText raster 구현은 아직 smoke bridge에 있다. 제품 CoreText backend에서도 이 registry identity를 shaping과 rasterizer 양쪽에서 같은 값으로 사용해야 한다.
- macOS glyph texture smoke: `mise run test-macos-glyph-texture-smoke`로 summary 계약을 검증하고, `mise run macos-glyph-texture-smoke`로 창 없이 CoreText CPU bitmap을 Metal texture에 업로드한 뒤 blit readback 결과가 source bitmap과 같은지 확인한다. 이 단계는 shader sampling이나 실제 화면 text draw 검증은 아니지만, raster 결과가 GPU texture로 보존되는지 분리하는 검증이다.
- macOS glyph text smoke: `mise run test-macos-glyph-text-smoke`로 summary 계약을 검증하고, `mise run macos-glyph-text-smoke`로 실제 AppKit 창 위 CAMetalLayer에서 CoreText glyph texture를 fragment shader로 샘플링한다. source glyph의 ink 위치를 drawable 좌표로 매핑해 blit readback하고, 선택한 모든 샘플이 clear 색이 아니며 PPM screenshot artifact가 쓰였을 때만 `glyph_text=true`로 본다. 또한 같은 smoke에서 Zig 제품 경로인 `TerminalCore -> RendererState -> RenderFrame` probe를 만들어 `renderer_frame_prepared=true`, `renderer_glyph_uv_ready=true`, `renderer_glyph_raster_ready=true`, glyph/atlas/raster 통계를 summary에 남긴다. 이 probe는 아직 실제 CoreText shaper가 아니라 `FakeFontBackend`를 쓰므로 summary에 `renderer_shaper=fake_font_backend`로 한계를 남긴다. 이 단계는 "화면에 glyph texture가 그려짐"과 "제품 renderer frame 준비가 됨"을 함께 증명하고, gate를 통과한 검증 프레임을 PPM screenshot artifact로 남겨 사람이 픽셀을 직접 확인하게 하지만, 아직 제품 terminal renderer가 그 `GlyphQuadFrame`/`GlyphRasterFrame`을 직접 화면에 그리는 검증은 아니다.
- 제품 renderer screenshot artifact: macOS Metal smoke가 `zig-out/maru-macos-metal-smoke/metal-frame.ppm`으로 제품 atlas sampling frame을 남긴다. 향후 실제 app loop가 붙으면 같은 artifact 정책을 제품 app smoke로 확장한다.

macOS bridge 언어 선택:

- 현재 `*.m` bridge는 제품 UI가 아니라 window/Metal/CoreText smoke를 위한 얇은 C ABI 경계다.
- 이 smoke bridge는 Objective-C로 유지한다. Zig와 C ABI로 직접 붙고, Swift module/build/runtime/actor/lifecycle 복잡도를 초기 smoke에 끌어들이지 않기 위해서다.
- Swift는 실제 macOS app host를 시작할 때 도입한다. 대상은 지속 실행되는 `NSApplication`, window/tab/split lifecycle, menu/command, preferences, IME, accessibility, focus/input routing 같은 제품 UX 영역이다. Swift/Zig 소유권과 C ABI는 [macOS 앱 호스트 경계](macos-app-host-boundary.md)를 따른다.
- Swift app host를 도입하더라도 기존 Objective-C smoke는 삭제하지 않는다. 제품 UI 회귀와 low-level AppKit/Metal/CoreText 경계 회귀를 분리해 보기 위한 regression smoke로 남긴다.
- Swift 도입의 첫 PR은 제품 앱 loop를 바로 만들지 않고, `src/platform/macos/app_host_abi.h`, `app_host_abi.zig`, `MaruAppHost.swift`로 ABI version/layout, ownership capability, Swift type-check skeleton만 고정했다.
- 그 다음 PR은 `mise run macos-app-dev-build`, `mise run macos-app-dev-smoke`, `mise run macos-app-dev`로 실제 Swift `NSApplication` executable과 placeholder window lifecycle을 검증했다. 이 단계는 summary에 `terminal_surface=false`를 명시하고, shell/FrameLoop/render surface 연결은 하지 않았다.
- 그 다음 PR은 Swift host가 opaque Zig dev session handle을 만들고, Zig가 shell 1개 surface와 `LivePtySession -> SurfaceRuntime -> FrameLoop -> RendererState`를 소유하도록 연결한다. summary에는 `terminal_surface=true`와 frame/output/exit 통계를 남기지만, Swift window 안에 Metal terminal view는 아직 붙이지 않는다.
- 그 다음 PR은 placeholder view의 `keyDown`, window resize, window close를 같은 opaque dev session ABI로 내려보낸다. 자동 smoke는 scripted key events와 scripted resize를 보내 `key_events=2`, `terminal_input_events=2`, `resize_events=1`, `close_events=1`을 남긴다. resize cell 수는 아직 실제 renderer font metrics가 아니라 placeholder dev 추정값이다.
- 실제 Swift window에 terminal glyph를 그리는 제품 앱은 다음 단계들로 나눠 시작한다.
  - 먼저 dev session이 fake font backend 대신 실제 CoreText shaper/rasterizer로 frame을 만든다(`FrameLoop.tickWithFrameBuilder` + `CoreTextFrameBuilder`). 그래서 `macos-app-dev-smoke` summary의 `glyph_count`/`atlas_entries`/`glyph_raster_ready`가 실제 rasterized glyph를 반영한다. CoreText 브리지는 macOS 정적 라이브러리·계약 테스트·Swift 링크에만 들어가고, Linux CI는 tick의 macOS 분기를 comptime으로 제외해 fake backend 계약만 유지한다. 화면은 아직 placeholder다.
  - 그 다음 단계는 이 RenderFrame을 Swift가 가져갈 수 있는 Metal-frame ABI를 추가한다(완료). RenderFrame을 native Metal DTO(cells/atlas uploads/raster pixels)로 투영하는 책임은 순수 모듈 `metal_frame.zig`가 단일 출처로 소유하고, visible Metal smoke와 제품 app host가 같은 표현을 쓴다. dev session은 새 output이나 resize로 frame이 바뀐 tick에만 RenderFrame을 DTO로 투영해 retain하고(idle tick은 buildDrawList/CoreText shape/투영을 건너뛰어 출력 없는 셸이 CPU를 태우지 않는다), `maru_macos_app_dev_session_metal_frame`이 그 retained 배열을 가리키는 view를 돌려준다(포인터는 다음 변경 tick까지 유효, ABI v5). 투영은 CoreText에 의존하지 않아 cross-platform이다.
  - 그 다음 단계는 검증 계측 없는 lean 제품 Metal renderer(`maru_metal_renderer.{h,m}`)를 추가한다(완료). visible Metal smoke와 GPU 셰이더(`maru_metal_shader.h`)를 공유하고, app host ABI의 cell/upload DTO를 그대로 받는다. smoke의 draw는 readback/screenshot 검증과 융합돼 재사용 불가라 별도 lean 런타임 경로로 둔다.
  - 그 다음 PR은 Swift placeholder view를 `MaruMetalTerminalView`(CAMetalLayer)로 바꿔, metal generation이 바뀐 tick에 `maru_macos_app_dev_session_metal_frame`을 lean renderer로 그린다(완료, idle tick은 generation이 그대로라 재드로우도 생략). 여기서 dev session의 shell glyph가 Swift 창에 처음 보인다. `macos-app-dev-smoke`가 `metal_renderer_created=true`/`metal_frames_drawn>0`로 렌더 경로를 gate한다. resize cell 수는 실제 CoreText font metrics(advance×line-height)와 분수 backing scale에서 Zig가 계산하고, 렌더는 **fixed-cell pixel layout**이다(#162에서 NDC inset grid를 제거 — 각 cell을 고정 픽셀 사각형에 두고 drawable 크기로 NDC 투영해, 창을 키우면 글자가 늘어나는 대신 더 많은 cell이 보인다). 스크롤백은 그 뒤 구현됐다(휠/Shift+PageUp으로 뷰포트 스크롤, 입력하면 live로 복귀 — 스크롤 변환은 Zig가 함, ABI v11). 탭·선택/클립보드 같은 제품 UX는 이후 단계다.
  - 그 다음 PR은 커서를 Metal frame에 그린다(완료). DrawList의 `CursorOverlay`(도메인+dirty 계약은 이미 완료)를 `metal_frame.zig`가 **반전 블록 cell**로 투영한다 — 커서 칸 배경을 `theme.cursor`로 채우고 그 자리 glyph를 `theme.background`로 다시 그려 글자가 가려지지 않게 반전한다(빈 칸이면 sentinel UV의 솔리드 블록). 커서 투영은 제품 dev session만 켜는 opt-in(`CellColors.cursor`)이고, glyph-atlas readback을 픽셀 단위로 검증하는 visible Metal smoke는 `cursor=null`로 꺼 readback에 영향을 주지 않는다. 커서 색은 `ResolvedTheme.cursor`에서 와 테마 설정으로 커스텀된다. 커서 shape(bar/underline)·blink와 underline overlay 렌더는 다음 단계다.

완료 기준:

- renderer는 PTY나 parser를 모른다.
- app host는 terminal storage를 직접 수정하지 않는다.
- Swift 제품 host가 들어와도 Swift는 fixed-width C ABI record만 Zig에 넘기고, `PtySession`/`SurfaceRuntime`/`FrameLoop`/renderer resource를 직접 소유하지 않는다.
- 실제 AppKit/Metal UI가 아직 없으면 smoke summary에 `visible_ui=false`를 명시하고, UI로 확인 가능한 단계가 오면 사용자에게 보고한다.
- `mise run macos-app-dev-smoke`가 실제 Swift `NSApplication` window를 띄우고 `app-dev.summary.txt`에 `visible_ui=true`, `swift_host=true`, `abi_ready=true`, `terminal_surface=true`, `terminal_surface_note=zig_runtime_rendered_to_swift_cametal_layer`, `metal_renderer_created=true`, `metal_frames_drawn>0`, `frame_loop_ticks`, `output_events>0`, `exit_events=1`, `key_events=2`, `terminal_input_events=2`, `resize_events=1`, `close_events=1`, `frame_prepared=true`, `final_frame_ended=true`를 남긴다. 이 명령은 Swift/Zig ABI 링크, 앱 lifecycle, Zig-owned shell surface/frame loop, key/resize/close event ABI를 검증하고, dev session의 shell glyph와 반전 블록 커서를 Swift window의 `MaruMetalTerminalView`(CAMetalLayer)에 그린다.
- `mise run macos-window-smoke`가 macOS에서 실제 창을 띄우고, 아직 Metal/terminal grid가 없다는 한계를 summary에 적는다.
- `mise run macos-metal-smoke`가 macOS에서 실제 Metal drawable을 한 frame 이상 present하고, `TerminalCore -> DrawList -> CoreTextDrawListShaper -> RendererState -> GlyphFrame -> GlyphQuadFrame/GlyphRasterFrame -> coretext_raster.zig` source ink 위치가 drawable readback에서도 같은 texel 값으로 보이는지 확인한다. native bridge가 atlas slot id뿐 아니라 `x_px/y_px/width_px/height_px` placement 후보도 받으면 summary에 `renderer_atlas_slot_placement=true`를 남기고, slot pixel rect가 shader UV로 변환됐으면 `renderer_glyph_uv_ready=true`를 남기며, renderer upload byte와 skip 회계 계약이 준비됐으면 `renderer_glyph_raster_ready=true`와 skip count를 남긴다. 같은 smoke에서 `GlyphRasterFrame.uploads/pixels`를 Metal atlas texture에 업로드하고 readback byte 비교가 성공하면 `product_atlas_uploaded=true`, fragment shader가 그 atlas를 샘플링해 drawable readback이 source texel과 일치하고 `atlas_sample_missing_cells=0`이면 `product_atlas_sampled=true`를 남긴다. `glyph_text`는 `product_atlas_sampled`이고 그 frame이 실제 CoreText glyph bytes를 쓴 경우에만 참이므로, 샘플링 증거 없이 라벨만으로 true가 되지 않는다. 같은 검증 프레임을 `metal-frame.ppm` screenshot artifact로 남겼을 때만 `screenshot_artifact=true`로 본다. upload가 0개인 all-skip frame은 `atlas_readback_failures`나 `readback_failures`가 아니라 `atlas_sample_missing_cells`로 원인을 분리한다. `mise run macos-app-pty-metal-smoke`는 같은 visible path에 controlled PTY output과 AppKit keyDown event에서 app host keybinding resolver를 통과한 scripted key events roundtrip을 연결한다. `mise run macos-app-pty-interactive-metal-smoke`는 같은 visible path에 실제 `$SHELL -i` startup과 marker command를 태운다. 기본은 자동 synthetic event이고, `MARU_APP_PTY_METAL_KEYDOWN_SOURCE=manual`은 사용자가 누른 물리 `Cmd+B` 한 번을 같은 path로 검증한다. 다만 물리 키보드 입력을 지속적으로 받는 제품 interactive shell loop는 아직 별도 한계로 summary와 PR 설명에 적는다.
- `mise run macos-coretext-smoke`가 macOS에서 창/GPU 없이 default `ResolvedAppearance` font 요청 전달, CoreText font resolve, drawable font identity의 `coretext_probe.zig -> coretext_font.zig -> FontIdentityRegistry -> ShapedGlyphRecord -> GlyphRunList -> RendererState -> RenderFrame` 준비, 같은 PostScript name을 쓰는 `coretext_raster.zig -> smoke native bridge -> GlyphRasterFrame` bytes, CPU bitmap rasterization을 확인한다. 추가로 실제 `TerminalCore -> DrawList` fixture가 `CoreTextDrawListShaper -> FontIdentityRegistry -> GlyphRunList -> RendererState -> RenderFrame -> coretext_raster.zig` 경로를 통과하는지 `drawlist_*` summary로 확인한다. 아직 설정 파일/설정 UI/runtime reload가 없고, native CoreText raster 구현은 smoke bridge에 있다.
- `RendererState`는 fake per-cell shaper 경로와 already-shaped `GlyphRunList` 경로를 모두 같은 atlas/UV/raster 준비 pipeline으로 보낸다. 후자는 CoreText 제품 shaper가 실제로 붙을 때 사용할 진입점이다.
- raw font/theme/cursor config는 `ResolvedAppearance` 계약으로 검증된다. 아직 설정 파일 로딩, 설정 UI, runtime reload는 없다는 한계는 PR 설명에 적는다.
- `mise run macos-glyph-texture-smoke`가 macOS에서 창 없이 CoreText CPU bitmap을 Metal texture에 업로드하고 readback한다. 아직 shader sampling과 실제 화면 text draw가 없다는 한계는 summary와 PR 설명에 적는다.
- `mise run macos-glyph-text-smoke`가 macOS에서 실제 창을 띄워 shader sampling된 glyph texture와 PPM screenshot artifact를 남기고, 동시에 제품 renderer frame probe 통계를 summary에 남긴다. probe의 shaper와 rasterizer는 아직 fake 경로이므로 `renderer_shaper=fake_font_backend`와 `renderer_glyph_raster_ready=true`를 함께 해석해야 한다. 아직 제품 `GlyphQuadFrame`/`GlyphRasterFrame`을 Metal backend가 직접 소비해 terminal cell text를 그리는 단계는 아니므로 이 한계도 summary와 PR 설명에 적는다.
- 성능 예산에 startup, first drawable, frame budget 초안을 추가한다.

아직 하지 않는다:

- 고급 glyph atlas 최적화.
- 복잡한 tab/split UI.
- plugin UI hook.

## 8단계: 탭, quick terminal, global shortcut

목표:

- 최소 탭 기능과 scratch/quick terminal UX를 app action으로 얹는다.
- global shortcut은 platform/app layer에서 처리하고, PTY input과 섞지 않는다.
- `KeyBindingResolver` 자체는 1단계에서 최소 계약을 만든다. 이 단계에서는 실제 탭/quick/global shortcut 동작을 연결한다.

TDD 방식:

- config validation test: 위험한 terminal 조합을 app/global shortcut으로 등록하면 경고한다.
- resolver test: focused app keybinding의 `send_control("b")`는 `0x02` terminal input으로 내려간다.
- resolver test: exact-match global shortcut만 소비한다.
- resolver test: 등록하지 않은 `Ctrl+B`는 PTY input으로 내려간다.
- app smoke test: global shortcut 등록 성공/실패를 artifact로 남긴다.

완료 기준:

- 세부 규칙은 [키 입력과 단축키 경계](key-input-and-shortcuts.md)를 따른다.
- app/global shortcut으로 소비된 key event는 PTY로 전달하지 않는다.
- terminal input macro는 focused surface가 명확할 때만 PTY로 bytes를 보낸다.
- OS가 선점한 global shortcut 등록 실패를 조용히 무시하지 않는다.

아직 하지 않는다:

- workspace restore 전체.
- plugin ABI.

이 단계에서 다루지 않고 별도로 확장하는 입력 영역:

- 기본 terminal input 인코더는 `Ctrl+letter` → C0 control, `Alt/Option` → meta-ESC까지 처리한다. 이 계약은 `src/terminal/input.zig`와 `src/config/keybinding.zig`의 단위 테스트가 지킨다.
- **application-cursor-key 모드(DECCKM)를 구현했다(완료)**: TerminalCore가 `CSI ?1h/l`로 모드를 추적하고, `input.encodeKey`가 `EncodeOptions`로 받아 화살표를 SS3(`\x1bOA`)/CSI(`\x1b[A`)로 전환한다. app host의 `handleKeyEvent`가 매 키마다 active surface core의 현재 모드를 읽어 resolver에 넘기므로(인코더는 터미널 상태를 직접 들지 않음), vim/less가 모드를 켜고 끄는 대로 즉시 따라간다. unit + host E2E(`?1h` 후 같은 키가 SS3로 PTY에 쓰임)로 검증.
- CSI-u/Kitty 키 인코딩과 function key terminal encoding은 아직 하지 않는다. 키 버퍼는 `encoded_key_buffer_len`으로 확장되어 있으므로, 다음 입력 확장은 같은 상수와 테스트를 갱신하면서 진행한다.
- AppKit native key event에서 function key, keypad, dead key, IME 조합을 `TerminalKeyEvent`로 옮기는 일은 아직 하지 않는다. 이번 단계는 그 앞의 config/resolver 계약만 고정한다.

## 9단계: Workspace restore

목표:

- 프로젝트별 workspace 저장.
- 탭/분할 layout restore.
- 각 surface의 cwd/env/shell_entry/startup_recipe restore.
- `last_observed_command`는 최근 작업 표시 후보일 뿐 자동 재실행 대상이 아님을 검증한다.
- 최근 workspace 빠른 복구.
- repo별 기본 레이아웃과 scratch terminal 정책.
- 저장 대상, env redaction, command restore 정책은 [Workspace Restore 전략](workspace-restore.md)을 따른다.
- command 자동 재실행 금지와 shell integration opt-in 정책은 [터미널 호환성/보안 정책](terminal-compatibility-policy.md)을 따른다.

TDD 방식:

- serialized workspace fixture round-trip.
- restore E2E: 저장된 layout -> surface 생성 -> shell_entry/startup_recipe/cwd/env 확인.
- 민감정보 test: env/token/path가 fixture에 그대로 들어가지 않는지 확인.
- 안전 test: `last_observed_command`가 startup_recipe처럼 자동 실행되지 않는다.

완료 기준:

- live PTY handle은 저장하지 않는다.
- 저장 포맷은 선언적 상태만 담는다.
- 복구 실패 시 어떤 surface가 왜 실패했는지 artifact가 남는다.

## 10단계: Plugin/Wasm

목표:

- plugin은 domain event와 action facade로만 상호작용한다.
- plugin이 `TerminalCore` private storage, PTY handle, renderer resource를 직접 만지지 못하게 한다.
- v1에는 Wasm runtime을 넣지 않고, 장기 permission model 경계만 유지한다.

TDD 방식:

- fixture plugin.
- permission failure test.
- plugin panic/failure isolation test.

완료 기준:

- plugin ABI와 권한 모델은 [터미널 호환성/보안 정책](terminal-compatibility-policy.md#plugin--wasm)의 capability 방향을 기준으로 하되, 구현 전에 사용자와 별도 논의한다.
- plugin 실패가 surface/window 전체를 죽이지 않는다.

## 개발 순서 단일 출처

개발 순서의 단일 출처는 이 문서다. [초기 아키텍처](architecture.md)는 이전에 parser를 너무 앞에 둔 표현이었지만, 지금은 본문에서 그 parser-first 표현을 철회하고 큰 구조 설명만 유지하며 구체적인 순서는 이 문서에 위임한다.

## PR마다 확인할 질문

- 이번 PR은 위 단계 중 어디에 속하는가?
- 그 단계의 TDD 방식으로 구현 전에 실패하는 테스트를 만들 수 있는가?
- 만들 수 없다면 contract test, smoke test, 수동 artifact 중 무엇으로 대체하는가?
- 새 코드가 이전 단계의 facade 계약을 깨지 않는가?
- 자동화할 수 없는 한계를 PR 설명에 보고했는가?
