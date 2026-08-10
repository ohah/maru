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
- GUI inspector — 관전형(read-only) HTML 스텝 뷰어를 [웹 패널](web-panel.md)에 띄우는 방향으로 확정(네이티브 패널·개입형 아님). replay 엔진 재사용, 단일 출처. 상세는 [trace-replay.md](trace-replay.md) "GUI inspector 설계 방향".

## 3단계: 초기 shell 경로에 필요한 parser/core 동작만 작게 확장

목표:

- 완전한 VT parser가 아니라, 초기 shell smoke에 필요한 최소 terminal core 동작만 TDD로 추가한다.
- CR/LF, printable text, resize, cursor 위치 같은 기본기를 먼저 안정화한다.

진행 상태:

- CR/LF/Tab/backspace, printable text -> cell은 초기부터 동작한다.
- resize는 화면을 비우지 않고 겹치는 영역(min(old,new) 좌상단)을 보존하고 커서를 새 크기로 clamp한다(완료). 이전에는 resize가 매번 화면을 `@memset`으로 지워, 창을 줄이면 셸이 SIGWINCH로 다시 그리기 전까지 빈 화면이 보였다. cols가 줄어 wide glyph(width=2)의 continuation이 잘리면 짝 없는 base를 blank로 정리한다.
- printable 출력이 마지막 열을 넘으면 다음 줄로 넘어가는 **autowrap(DECAWM deferred/pending wrap)**을 구현했다(완료). 마지막 칸을 채운 직후 커서는 그 칸에 머물고 pending_wrap만 서며, 다음 printable 글자가 먼저 다음 줄로 넘어간 뒤 그려진다(끝 글자마다 빈 줄이 끼지 않게). 명시적 커서 이동(CR/LF/backspace/커서 위치 지정/resize)은 pending_wrap을 무효화하고, wide glyph가 줄 끝에 1칸만 남으면 통째로 다음 줄로 넘긴다. autowrap은 zsh PROMPT_SP 등 거의 모든 셸/프로그램이 의존하는 기본 동작이라 우선 구현했다. 그 위에 행별 soft-wrap 플래그(wrapped)를 추적해 **resize reflow를 스크롤백 위에서 구현했다(완료)**: 논리 줄을 합쳐 새 폭에 다시 wrap하고 넘치는 위쪽 행은 스크롤백으로 민다. **단, 커서가 있는 논리 줄은 reflow하지 않고 그대로 둔다**(xterm.js의 `reflowCursorLine=false` 기본 동작). 이유: zsh는 SIGWINCH 때 이전 폭 기준으로 커서를 상대 이동(`\e[A`)해 프롬프트를 지우고 다시 그리는데, 커서가 있는 줄을 재배치해 커서가 옮겨지면 그 상대 이동이 어긋나(프롬프트에 못 닿아) 프롬프트가 중복된다. 그 줄은 셸이 새 폭으로 직접 다시 그리므로 터미널이 건드리지 않는 게 안전하다. 활성 화면의 다른(커서 없는) 줄과 스크롤백으로 가는 내용은 정상 reflow한다. (한 번은 커서 줄까지 reflow해 라이브에서 프롬프트가 중복됐다 — 단일 resize는 Ghostty 오라클과 일치했지만, 같은 reflow라도 zsh의 상대 redraw와 라이브에서 충돌했다. Ghostty는 셸 통합(OSC 133 semantic_prompt)으로, xterm.js는 커서 줄을 안 건드리는 방식으로 푸는데, 후자가 셸 통합 없이도 되는 더 단순한 길이라 채택했다. perf는 활성 화면만 즉시 reflow해 O(활성 행)으로 유지하고, **기존 스크롤백 행의 재-wrap도 구현했다(완료)** — 단 비용(cap 1000행 재구성, 회당 ~30ms)이 커서 resize마다 즉시 하지 않고 지연 마크만 남긴 뒤, 사용자가 실제로 과거를 보는 순간(scrollViewport/renderSnapshot)에 현재 폭으로 1회 수행한다(연속 드래그 resize도 마지막 폭으로 한 번). 과거를 보는 중에 resize가 오면 즉시 재-wrap하면서 보던 행을 앵커로 view_offset을 재계산해 스크롤 위치가 유지된다 — Ghostty가 viewport를 tracked pin으로 들고 reflow가 pin을 재매핑하는 것(PageList.zig)과 같은 의미론을 행 단위로 구현한 것이다(동작 비교, 코드 미복사). sb_wrapped로 논리 줄을 복원해 활성 reflow와 같은 규칙(hard 끝 trim·soft 전체 폭·wide glyph 경계)으로 다시 자르고, cap을 넘으면 오래된 행부터 버린다. perf 게이트 `scrollback_rewrap`(50회 2s)이 1회 비용을 고정한다. 셸 통합(OSC 133) 파싱·행 분류·reflow 태그 carry는 구현했다(아래 OSC 133 항목). 단 이 커서-줄 reflow workaround 자체는 유지한다 — OSC 133가 있어도 zsh가 SIGWINCH에서 프롬프트를 직접 redraw하는 한 그 줄을 안 건드리는 게 옳기 때문이다(태그만 verbatim carry).)
- `TerminalCore.write`에 VT escape 상태기계(ground/escape/CSI/OSC)를 붙였다(완료). 실제 shell prompt가 내보내는 escape를 글자로 찍지 않고 해석한다: SGR(`m` — bold/italic/underline, 16색·256색·rgb 전경/배경, reset)을 pen으로 적용하고, cursor 이동/위치(CUU/CUD/CUF/CUB, CUP, CHA, VPA), erase(EL `K`, ED `J`)를 처리하고, DSR/CPR(`CSI 6n`→커서 위치 `CSI row;col R`, `CSI 5n`→`CSI 0n`)·DA1(`CSI c`→VT102 식별 `CSI ?6c`)에는 PTY write-back으로 응답하고, DECSC/DECRC(`ESC 7`/`ESC 8` — 커서+pen+pending_wrap 저장/복원, DECSET 1048과 같은 슬롯)를 처리하며(claude CLI가 시작 시 `ESC 7, CSI r, ESC 8`로 region을 리셋하는데 복원이 없으면 커서가 home에 남아 UI가 기존 화면 맨 위를 덮는다), OSC(title 등)와 **미지원** private(`CSI ? ...`) 시퀀스는 소비만 한다(DECOM `?6`·DECAWM `?7`·alt screen `?1049`·sync `?2026` 등 지원 모드는 실제 동작 — 아래 진행 상태 참조). 시퀀스가 PTY read 경계로 쪼개져도 파서 상태가 write() 호출 사이에 유지된다. CSI 안의 ESC는 시퀀스를 취소하고 새 escape로 재시작하며, C0 control은 실행하고 CSI를 계속한다. 파라미터가 16개를 넘으면 이후는 버린다(마지막 파라미터 오염 방지). erase/eraseInDisplay는 dirty를 덮어쓰지 않고 markDirty로 병합하고, 경계에 걸친 wide glyph 짝을 정리하며, last_print를 비운다.
- SGR 38/48 확장색은 세미콜론(`38;2;r;g;b`, `38;5;n`)과 colon sub-parameter(`38:2:colorspace:r:g:b`, `38:5:n`) 형식을 모두 정확히 처리한다. 파라미터마다 `:`로 들어왔는지(sub-parameter) 추적해, colon mode 2의 colorspace 컴포넌트를 건너뛰고 r/g/b를 읽는다.
- SGR가 정한 cell 배경색은 Metal renderer가 칠한다. 투영이 glyph cell엔 배경색을 같이 싣고, glyph 없는 공백 중 non-default 배경은 배경 전용 cell(sentinel UV)로 내며, 공유 셰이더가 `mix(bg, fg, coverage)`로 배경 위에 glyph를 blend한다(기본 배경은 a=0이라 기존 전경 전용 경로와 동일).
- **scroll region(DECSTBM)을 구현했다(완료)**: `CSI Pt;Pb r`로 상/하단 margin(1-indexed, 기본 전체)을 정하면 LF/IND(`ESC D`)는 하단 margin에서, RI(`ESC M`)는 상단 margin에서 그 구간 안에서만 스크롤한다(less/vim이 상태줄을 고정하고 본문만 스크롤하는 데 쓴다). margin이 화면 최상단(top==0)일 때만 밀려난 줄을 스크롤백에 보관하고, 부분 region(top>0)이나 아래로 스크롤되는 줄은 history가 아니라 버린다. 2행 미만 region은 무시하고, resize는 margin을 전체 화면으로 리셋한다. unit + libvterm·Alacritty 오라클(활성 화면 골든 일치)로 검증.
- **alternate screen(DECSET 1049/47/1047/1048)을 구현했다(완료)**: vim·less 같은 TUI가 보조 버퍼에서 전체 화면을 쓰고 종료 시 원래 셸 화면과 커서를 복원한다. 1049는 들어가며 커서 저장(DECSC)+빈 alt 화면, 나오며 primary+커서 복원(DECRC). 47/1047은 전환만, 1048은 커서 저장/복원만. alt 출력은 스크롤백에 쌓이지 않고(top==0 스크롤도 history 아님) 스크롤백 뷰포트도 잠긴다. alt 중 resize는 reflow/스크롤백 없이 활성 alt와 저장된 primary 그리드를 함께 clip/pad한다(TUI는 SIGWINCH로 전체를 다시 그리고, primary는 복귀 시 크기가 맞아야 한다). unit + libvterm·Alacritty 오라클로 검증(libvterm 오라클은 `vterm_screen_enable_altscreen`을 켜야 실제 터미널과 같다). **alternate scroll(xterm DECSET 1007, 기본 on)**도 구현했다: alt screen에서는 스크롤백이 잠기므로 휠/트랙패드 스크롤을 화살표 키로 변환해 프로그램(less/vim)에 보내 자체 스크롤하게 한다(iTerm2/Terminal.app 기본 동작, DECCKM이면 SS3 형식). 트랙패드의 1줄 미만 정밀 델타는 누적해(`wheel_accum`) 천천히 굴려도 줄이 소실되지 않는다.
- **IL/DL(CSI L/M), 커서 표시(DECTCEM ?25), reverse(SGR 7/27)를 구현했다(완료)**: IL은 커서 행에 빈 줄 n개를 삽입(커서 행~region 하단이 내려가고 넘치는 줄은 버림), DL은 커서 행부터 n줄 삭제(아래가 올라옴) — 둘 다 scroll region 안에서만 동작하고 커서가 밖이면 무시하며, 편집 연산이라 history(스크롤백)에 넣지 않고, 후처리로 커서를 행 첫 칸으로 옮긴다(CR). vim이 줄 열기/삭제를 전체 redraw 없이 하는 핵심 시퀀스다. unit + libvterm·Alacritty 오라클(골든 일치)로 검증. DECTCEM(?25 h/l)은 core가 cursor_visible로 추적하고 snapshot/renderSnapshot이 내보내는 cursor.visible에 합성한다(렌더 overlay 경로는 이미 visible을 따름). reverse(SGR 7/27, SGR 0도 리셋)는 Style.reverse로 추적하고 Metal 투영(packForeground/packBackground)이 전경/배경을 스왑한다 — default 색은 theme 값(default_fg/default_bg)으로 풀어 실제로 칠한다(안 풀면 default 배경이 A=0이라 반전이 안 보인다).
- **커서 모양(DECSCUSR `CSI Ps SP q`)을 구현했다(완료)**: vim이 모드별로 커서를 바꾸는 표준 수단. core가 shape(block/underline/bar)와 blink 여부를 추적하고(0/1=깜빡 block … 6=고정 bar, 모르는 값 무시), CSI intermediate를 바이트로 기억해 (intermediate, final) 튜플로 dispatch한다(`SP q`만 인식, `$r` 등 미지원 조합은 소비). 렌더는 block=기존 반전 블록, underline/bar=글리프를 가리지 않는 부분 사각형(cell의 하단/좌측 ~15%, 최소 2px) — NativeMetalCell.reserved를 overlay 종류로 사용(ABI v12). 깜빡임 렌더도 구현했다 — app session이 host frame-loop cadence 기반 tick으로 위상을 토글(500ms 반주기)하고, off 위상은 frame rebuild 없이 metal buffer가 커서 suffix 노출 길이만 줄인다(buildNativeCellsSplit + setCursorVisible — 커서 cell이 항상 배열 끝에 emit되는 계약을 이용, idle 절전을 깨지 않음). steady(2/4/6)·?25l은 무토글 고정(idle 재투영 없음), 입력/출력 시 보이는 위상으로 리셋해 타이핑 중 커서가 사라지지 않는다.
- **선택/클립보드를 구현했다(완료)**: 마우스 드래그 선택(Swift는 raw backing-px 좌표만 전달, 셀 변환·선택 모델은 Zig — 절대 행 좌표라 스크롤해도 내용을 따라가고 ring eviction 시 보정/해제, 재-wrap·clear 시 해제) + Cmd+C 복사(Zig가 추출한 UTF-8을 Swift가 NSPasteboard에 — 클립보드만 OS 소유). 추출은 soft-wrap 행을 줄바꿈 없이 잇고 hard 줄끝에 \n, 뒤 빈칸 trim. 하이라이트는 theme.selection 배경으로 Metal 투영. Cmd+V 붙여넣기는 core.encodePaste가 개행을 \r로 정규화하고 bracketed paste(DECSET 2004)면 ESC[200~..201~로 감싸 한 번에 쓴다. Cmd+클릭은 그 위치의 URL을 기본 브라우저로 연다(core.extractUrlAt — 단어 경계에서 http(s) 인식, soft-wrap 너머 이어 붙임, 끝 문장부호 다듬기·괄호 균형; 열기만 NSWorkspace=Swift). OSC 8 명시적 하이퍼링크(`ESC ] 8 ; params ; URI ST`)도 지원한다 — URI는 link_store에 intern(중복 제거)하고 셀에는 id만 찍어, 클릭/hover가 보이는 텍스트와 무관하게 지정 URI를 쓴다(휴리스틱보다 우선, 링크 안 공백 포함 run 전체 밑줄, params는 무시, 2KB 초과 OSC는 통째로 무시). Cmd+hover는 URL 단어에 전경색 밑줄(커서 underline과 같은 부분-사각형 kind 재사용)을 긋고 Swift가 마우스 커서를 pointingHand로 바꾼다(mouseMoved/flagsChanged 추적 — Cmd를 누르는 순간에도 재평가). ABI v17(mouse/copy_text/paste_text/url_at/hover). 더블클릭=단어 선택(비공백 run, soft-wrap 경계 너머 URL까지), 트리플클릭=논리 줄 선택. 드래그 자동 스크롤도 구현했다(드래그가 grid 밖에 머무는 동안 **경과 ms로 게이트**(msPerTick 누적 ≥ 33ms마다 한 줄)해 frame rate 무관 ≈30줄/s로 스크롤하며 선택을 가장자리 행으로 확장 — Swift 변경 없이 기존 tick 재사용, 옛 tick당 한 줄은 기본이 30→60Hz로 오르며 과속). 블록(직사각형) 선택도 구현했다(완료) — Option+드래그로 행마다 같은 열 범위를 추출(`core.setSelectionBlock`/`extractBlockSelection`).
- **스크롤백 Find(⌘F)를 구현했다(완료, ABI 무변경)**: 베이스 = Ghostty 스크롤백 검색의 증분·대소문자 무시·N/M 네비게이션 모델(같은 Zig 1차 레퍼런스). **검색은 코어(단일 출처)**: `core.findMatches`가 **논리 줄(soft-wrap 이음) 단위**로 스캔해 절대-좌표 `Match{start,end}`를 채운다 — primary면 스크롤백+화면 전체, alt screen이면 현재 화면(`[sb_count,total)`)만 스캔한다(primary 스크롤백 매치는 scrollToAbs가 잠겨 갈 수 없고 alt는 화면 밖을 스크롤백에 안 쌓으므로) — 코드포인트 시퀀스로 비교(대소문자 무시 ASCII fold, 멀티바이트 오프셋 매핑 회피), wrap 경계를 넘는 매치도 잡고 같은 줄 안에선 비겹침. 줄마다 cps/coords 버퍼를 재사용해 메모리는 가장 긴 논리 줄 하나. `core.scrollToAbs`가 현재 매치를 뷰포트 세로 중앙쯤에 둔다(상단 오버레이에 안 가림, alt screen이면 무동작). **UI 상태 = `find_overlay.FindState`**(command_palette 미러, 순수 로직): open/query/matches/current + show/hide/appendChar/backspace/next/prev/currentMatch. **AppSession wiring**: `Action.toggle_find` + 기본 바인딩 `Cmd+F`(셸 Ctrl+F와 안 겹침), `handleKeyEvent`가 `find.open`이면 resolver보다 먼저 `handleFindKey`로 모달 라우팅(Enter=다음·Shift+Enter=이전·↑↓·Esc=닫기·Backspace/평문=증분 재검색), `recomputeFind`가 타이핑마다 코어 재검색+첫 매치로 스크롤, 출력이 들어오면 tick이 재검색(좌표 stale 방지, 스크롤 없이 clamp). **렌더(전부 Zig, ABI 무변경)**: `CellColors`에 `search_matches`(span 리스트)·`current_match` 추가, `metal_frame`의 배경 칠을 `highlightBg`(현재 매치 > 다른 매치 > 선택 우선)로 일원화 — 활성 surface 셀에만 적용(비활성 pane은 inactive_colors). 매치 색은 테마(`search_match`/`search_match_current`, 앰버 계열 기본·현재가 더 밝음, #RRGGBB config). 입력창은 `buildFindFrame`이 상단-중앙 한 줄("Find: <query>" + 우측 "현재/전체" 카운터)로, 커맨드 팝업과 같은 최상위 오버레이 경로(`metal_frame.replace`의 `overlay_frame` — palette_frame을 일반화)로 그린다(모달 중 커서 정적). 검증: 코어(findMatches 대소문자/비겹침/절대좌표·soft-wrap 경계·scrollToAbs) + FindState(show/backspace UTF-8 경계·next/prev wrap) + macOS 통합(토글→증분 검색 2매치→Enter/Shift+Enter 네비→Backspace 부분일치 유지→오버레이 셀>0→Find 열린 채 runAction 무시→tick cursor_cells=0→Esc) + boundaries + swift-check + coretext/metal 스모크. 한계: regex/fuzzy 없음(부분일치만). 유니코드 케이스폴딩·⌘G·팝업 Find·alt screen Find는 이후 완료(아래 "완료된 기능의 잔여 항목" 절이 단일 출처).
  - **C1a 갱신(chrome 이주, ABI 무변경)**: 위 Find UI(`find_overlay.FindState`·`buildFindFrame`·`handleFindKey`·`metal_frame`의 find_overlay 분기)는 chrome 컴포넌트로 이주·**제거**됐다. 지금은 `src/chrome/components/find.zig`(neutral State+view+handle, 헤드리스 테스트)를 `ChromeHost`가 라우팅(`handleInput`)하고, platform(`app_session`)이 검색·EAW-폭 lowering(`rasterizeOverlayCells`)·caret 깜빡임 재활용을 맡는다. 한글 2칸 폭·IME 조합 표시는 터미널과 같은 경로를 공유한다. 상세·근거 = docs/chrome-strategy.md 현황 노트, docs/layering-and-portability.md §5.
- **런타임 폰트 크기(⌘+/⌘-/⌘0)를 구현했다(완료, ABI·Swift 무변경)**: 베이스 = Ghostty `increase/decrease/reset_font_size`(step 1pt, ⌘=·⌘+·⌘-·⌘0, 콘텐츠 reflow 없음). `Action.increase_font_size`/`decrease_font_size`/`reset_font_size` + 기본 바인딩 `Cmd+=`/`Cmd++`/`Cmd+-`/`Cmd+_`/`Cmd+0`(키캡 +/- 와 실제 글자 =/- 양쪽을 묶음, 숫자/기호라 normalizeEventChar 통과, 셸과 안 겹침). `AppSession.setFontSize`가 단일 경로: ① `appearance.font.size` 갱신(클램프 [6,72]pt — 단축키 UX 범위, config 파일은 [1,512] 그대로) → ② `refreshCellMetrics`로 cell 픽셀·사이드바 재계산 → ③ `renderer_state.atlas.invalidate(.font_size_changed)`로 새 크기 재래스터·옛 슬롯 회수(글리프 cache key가 `font_size_px`+cell 크기라 어차피 miss지만 명시 무효화로 stale 슬롯 즉시 회수) → ④ 같은 backing px에서 새 cell 크기로 grid 재산출 + `resizeActiveTabPanes`/`recomputeActivePaneRect`(코어 resize의 reflow 경로 공유 — PTY winsize/SIGWINCH 포함). 콘텐츠 reflow는 없다(셀 크기·grid 차원만, Ghostty 동일). reset은 `base_font_size`(init에서 config 기본값 보관)로 복원. 전부 Zig — Swift는 키 전달만(메뉴 항목은 후속), atlas는 cache key가 폰트 크기를 포함하므로 ABI/렌더러 구조 무변경. 검증: macOS 통합(⌘+ → 폰트 +1·cell 픽셀 커짐·grid cols 줄거나 같음, ⌘0 → 폰트·cell 원복, ⌘- 100회 → 하한 6pt 클램프, ⌘+ 200회 → 상한 72pt 클램프) + action/keybinding 파싱 + 전체 테스트 + boundaries + swift-check + coretext/metal 스모크. **보폭(step)·View 메뉴 완료**: ⌘+/⌘- 보폭은 **고정 1pt**(`font_size_step` 상수, dispatch가 사용 — 설정 항목 아님, Terminal.app·iTerm2·Ghostty 관례). View 메뉴 Bigger/Smaller/Actual Size(command 카탈로그에 등재해 `catalogMenuItem`이 ⌘+/⌘-/⌘0 chord 표시·runAction dispatch, 팝업에도 노출). **`set_font_size` 절대 지정 완료**: `Action.set_font_size: f32`(파라미터 액션 — `select_tab`과 같은 결), parseAction이 `set_font_size:N`(비유한 거부), dispatch가 `setFontSize`로([6,72] 클램프). config 바인딩 전용(절대값이라 메뉴/카탈로그 제외) — 사용자가 크기 프리셋 키를 직접 묶는다(예: `Ctrl+Cmd+1 = set_font_size:14`). **이로써 런타임 폰트 크기 후속(step·View 메뉴·절대 지정)이 전부 완료.**
- **배경색 erase(BCE)를 구현했다(완료, 코어 전용)**: erase·스크롤로 비워지는 셀을 default가 아니라 **현재 pen의 배경**으로 채운다. EL(`K`)·ED(`J`)·repairWideGlyphEdges는 이미 `.style = self.pen`이었고, 빠져 있던 **스크롤-인 빈 줄**(scrollRangeUp/Down → LF 스크롤·IND/RI·IL/DL 공통 경로)도 `.style = self.pen`으로 채워 색 배경 화면이 스크롤될 때 빈 줄이 그 색을 잇게 했다. 속성 carry는 **full pen**(베이스: xterm.js `getNullCell`이 erase 속성 fg+bg carry — 우리는 EL/ED와 내부 일관성을 위해 full pen 통일; Ghostty는 `bgCell()`로 배경만 좁힘 — bg-only 정제는 후속). default pen이면 기존 default blank와 동일이라 회귀 없음. 검증: 코어(SGR 44 bg → LF 스크롤 새 빈 줄·ED가 pen 배경을 잇는지) + 전체 테스트. (이 BCE 작업 시점엔 ICH/DCH가 미구현이었으나 이후 구현 완료 — 아래 줄 참조.) ECH(`CSI Ps X`)도 이 BCE 규칙으로 구현했다 — nvim이 모드 라벨(`-- INSERT --`)을 EL이 아니라 `CSI Ps X`로 지운다(커서부터 N칸 제자리 blank, 커서 유지, DCH처럼 당기지 않음 — xterm ECH).
- **DECOM(origin mode)·ICH(`CSI @`)·DCH(`CSI P`)·ECH(`CSI Ps X`)를 구현했다(완료)**: DECOM은 CUP/HVP origin을 scroll region 상단으로 옮기고 커서를 home으로(parser `?6`→`screen.setOriginMode`), ICH는 커서에 N칸 blank 삽입·오른쪽 밀기(`screen.insertChars`), DCH는 N칸 삭제·왼쪽 당기기(`screen.deleteChars`), ECH는 커서부터 N칸 제자리 blank(nvim 모드 라벨 clear).

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
- Kitty graphics protocol 잔여: K5 query(`a=q`) 응답·sixel(DCS 기반)·풀 PNG(전 color type/16-bit). K1~K4는 완료(APC 파서·디코드·저장·placement·K2 Metal 렌더·K3 chunked/zlib/PNG·K4 delete/LRU evict/텍스처 evict) — 아래 "kitty graphics K2 렌더" 절·K3~K5 항목 참조. sixel은 Ghostty도 미지원이라 후순위.
- OSC/clipboard/advanced mouse mode 전체.
- 합자(ligatures, line-level shaping)·`isExtendedPictographic`의 완전한 Extended_Pictographic 속성표는 후속이다. ambiguous width 설정(`text.ambiguous-width`)·ZWJ emoji(GB11, mode 2027)·box drawing 합성/정렬·grapheme 다중 저장(`grapheme_id`+`grapheme_store`, `Cell.combining` 폐지)은 완료 — 위 "한글 Grapheme Cluster" 절·[grapheme-clustering](grapheme-clustering.md) 참조.
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
- **대화형 셸을 `login(1)`으로 감싸 전체 로그인 세션을 셋업한 뒤 login shell로 exec한다(완료, macOS)**: `/usr/bin/login -flp <user> /bin/bash --noprofile --norc -c "exec -l <셸> <args>"` 형태로 getlogin·SHELL·utmp·hushlogin을 잡는다(Terminal.app·Ghostty와 동작 비교, Apple 공개 `login.c` 동작 참조 — 코드 미복사). 단순 dash-argv0(`-zsh`)는 `.zprofile`만 읽고 세션 env가 안 잡혀 그에 의존하는 셸 설정이 어긋나므로(실측: Cmd+Right만 안 됨) login(1)을 택했다. `MacosLogin.build` 단위 테스트가 `-flp <user> … exec -l` 구조를 고정하고, getpwuid 실패 시 비-login 셸로 fallback한다(Ghostty와 동일). 셸에 줄 `TERM`도 configurable로 분리(기본 xterm-256color — 셸 설정/통합이 `$TERM`에 따라 키바인딩을 다르게 잡으므로). 편집키 바인딩·zsh 통합은 8단계 입력 영역 참조.

아직 하지 않는다:

- SSH.
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
- glyph atlas test: GPU texture 없이 `GlyphCacheKey -> AtlasSlot` cache, row-packed slot 좌표 후보, upload byte 후보, eviction, invalidation reason을 검증한다. **row packer 좌표가 텍스처를 소진하면 전체 invalidate(`atlas_full`) 후 (0,0)부터 재배치하고, clean repack으로도 한 프레임의 고유 글리프가 안 들어가면 `GlyphAtlas.grow()`로 텍스처를 max(8192²)까지 2배씩 키운 뒤 다시 재배치한다(Ghostty식 grow on full)**. eviction은 슬롯 수만 줄이고 좌표를 재활용하지 않아(좌표 회수 packer는 **보류** — 정확성엔 grow로 충분하고, 안전히 켜려면 한 렌더 프레임의 모든 빌드를 덮는 frame-epoch 경계 설계가 필요해 correctness 회귀 위험이 있다; 측정된 끊김 시에만 착수, 그땐 atlas sizing이 1순위 레버 — 근거·재검토 조건은 [폰트 전략](font-strategy.md) "좌표 회수 — 보류"), 고유 글리프가 많은 출력(예: claude CLI의 스피너/박스/이모지)을 스크롤하면 y가 텍스처 높이를 넘는다. **옛 동작은 재시작이 1회뿐이라, 한 프레임의 고유 글리프가 텍스처 용량을 초과하면 좌표 두 세대가 한 프레임에 섞여 서로 다른 글리프가 같은 아틀라스 좌표를 받았다 — GPU 업로드가 앞 글리프 텍셀을 덮어써 보더라인 `─`가 나중 글리프 `?`의 비트맵을 샘플하는 간헐적 TUI 깨짐(ZWJ 무관, 글리프 아틀라스 버그)이 났다.** grow로 자리를 늘려 한 프레임의 모든 distinct 글리프가 고유 좌표를 받게 해 이 충돌을 구조적으로 차단한다. "한 프레임 안에서 서로 다른 글리프는 같은 좌표를 공유하지 않는다"는 불변식과 모든 슬롯의 아래 끝이 텍스처 안임을 회귀 테스트로 고정한다.
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
- 그 다음 PR은 `mise run macos-app-build`, `mise run macos-app-smoke`, `mise run macos-app`로 실제 Swift `NSApplication` executable과 placeholder window lifecycle을 검증했다. 이 단계는 summary에 `terminal_surface=false`를 명시하고, shell/FrameLoop/render surface 연결은 하지 않았다.
- 그 다음 PR은 Swift host가 opaque Zig app session handle을 만들고, Zig가 shell 1개 surface와 `LivePtySession -> SurfaceRuntime -> FrameLoop -> RendererState`를 소유하도록 연결한다. summary에는 `terminal_surface=true`와 frame/output/exit 통계를 남기지만, Swift window 안에 Metal terminal view는 아직 붙이지 않는다.
- 그 다음 PR은 placeholder view의 `keyDown`, window resize, window close를 같은 opaque app session ABI로 내려보낸다. 자동 smoke는 scripted key events와 scripted resize를 보내 `key_events=2`, `terminal_input_events=2`, `resize_events=1`, `close_events=1`을 남긴다. resize cell 수는 아직 실제 renderer font metrics가 아니라 placeholder 추정값이다.
- 실제 Swift window에 terminal glyph를 그리는 제품 앱은 다음 단계들로 나눠 시작한다.
  - 먼저 app session이 fake font backend 대신 실제 CoreText shaper/rasterizer로 frame을 만든다(`FrameLoop.tickWithFrameBuilder` + `CoreTextFrameBuilder`). 그래서 `macos-app-smoke` summary의 `glyph_count`/`atlas_entries`/`glyph_raster_ready`가 실제 rasterized glyph를 반영한다. CoreText 브리지는 macOS 정적 라이브러리·계약 테스트·Swift 링크에만 들어가고, Linux CI는 tick의 macOS 분기를 comptime으로 제외해 fake backend 계약만 유지한다. 화면은 아직 placeholder다.
  - 그 다음 단계는 이 RenderFrame을 Swift가 가져갈 수 있는 Metal-frame ABI를 추가한다(완료). RenderFrame을 native Metal DTO(cells/atlas uploads/raster pixels)로 투영하는 책임은 순수 모듈 `metal_frame.zig`가 단일 출처로 소유하고, visible Metal smoke와 제품 app host가 같은 표현을 쓴다. app session은 새 output이나 resize로 frame이 바뀐 tick에만 RenderFrame을 DTO로 투영해 retain하고(idle tick은 buildDrawList/CoreText shape/투영을 건너뛰어 출력 없는 셸이 CPU를 태우지 않는다), `maru_macos_app_session_metal_frame`이 그 retained 배열을 가리키는 view를 돌려준다(포인터는 다음 변경 tick까지 유효, ABI v5). 투영은 CoreText에 의존하지 않아 cross-platform이다.
  - 그 다음 단계는 검증 계측 없는 lean 제품 Metal renderer(`maru_metal_renderer.{h,m}`)를 추가한다(완료). visible Metal smoke와 GPU 셰이더(`maru_metal_shader.h`)를 공유하고, app host ABI의 cell/upload DTO를 그대로 받는다. smoke의 draw는 readback/screenshot 검증과 융합돼 재사용 불가라 별도 lean 런타임 경로로 둔다.
  - 그 다음 PR은 Swift placeholder view를 `MaruMetalTerminalView`(CAMetalLayer)로 바꿔, metal generation이 바뀐 tick에 `maru_macos_app_session_metal_frame`을 lean renderer로 그린다(완료, idle tick은 generation이 그대로라 재드로우도 생략). 여기서 app session의 shell glyph가 Swift 창에 처음 보인다. `macos-app-smoke`가 `metal_renderer_created=true`/`metal_frames_drawn>0`로 렌더 경로를 gate한다. resize cell 수는 실제 CoreText font metrics(advance×line-height)와 분수 backing scale에서 Zig가 계산하고, 렌더는 **fixed-cell pixel layout**이다(#162에서 NDC inset grid를 제거 — 각 cell을 고정 픽셀 사각형에 두고 drawable 크기로 NDC 투영해, 창을 키우면 글자가 늘어나는 대신 더 많은 cell이 보인다). 스크롤백은 그 뒤 구현됐다(휠/Shift+PageUp으로 뷰포트 스크롤, 입력하면 live로 복귀 — 스크롤 변환은 Zig가 함, ABI v11). 탭·선택/클립보드 같은 제품 UX는 이후 단계다.
  - 그 다음 PR은 커서를 Metal frame에 그린다(완료). DrawList의 `CursorOverlay`(도메인+dirty 계약은 이미 완료)를 `metal_frame.zig`가 **반전 블록 cell**로 투영한다 — 커서 칸 배경을 `theme.cursor`로 채우고 그 자리 glyph를 `theme.background`로 다시 그려 글자가 가려지지 않게 반전한다(빈 칸이면 sentinel UV의 솔리드 블록). 커서 투영은 제품 app session만 켜는 opt-in(`CellColors.cursor`)이고, glyph-atlas readback을 픽셀 단위로 검증하는 visible Metal smoke는 `cursor=null`로 꺼 readback에 영향을 주지 않는다. 커서 색은 `ResolvedTheme.cursor`에서 와 테마 설정으로 커스텀된다. 커서 shape(bar/underline)·blink, SGR 4 밑줄, 컬러 이모지 렌더(셰이더 UV sentinel로 atlas RGBA 직접), 이모지 grapheme 1단계(VS16/VS15·스킨톤·국기를 single-combining으로 클러스터)까지 구현했다. ZWJ 결합 시퀀스(가족 등 다중 codepoint)는 overflow store가 필요해 후속. 이모지 너비는 EAW per-codepoint(zsh wcwidth와 합의 — 붙여넣기 redraw 안 깨짐), 셀보다 큰 글리프는 래스터에서 축소-맞춤(Ghostty 모델). cluster 너비(❤️=2 풀사이즈)는 DEC mode 2027로 구현 — 앱이 DECSET 2027을 켜면 grapheme(VS16·스킨톤·국기)을 한 셀로 묶고, DECRQM으로 지원을 알린다. 기본 off는 EAW(레거시 호환). ZWJ 결합(가족)은 overflow store 후속.

완료 기준:

- renderer는 PTY나 parser를 모른다.
- app host는 terminal storage를 직접 수정하지 않는다.
- Swift 제품 host가 들어와도 Swift는 fixed-width C ABI record만 Zig에 넘기고, `PtySession`/`SurfaceRuntime`/`FrameLoop`/renderer resource를 직접 소유하지 않는다.
- 실제 AppKit/Metal UI가 아직 없으면 smoke summary에 `visible_ui=false`를 명시하고, UI로 확인 가능한 단계가 오면 사용자에게 보고한다.
- `mise run macos-app-smoke`가 실제 Swift `NSApplication` window를 띄우고 `app.summary.txt`에 `visible_ui=true`, `swift_host=true`, `abi_ready=true`, `terminal_surface=true`, `terminal_surface_note=zig_runtime_rendered_to_swift_cametal_layer`, `metal_renderer_created=true`, `metal_frames_drawn>0`, `frame_loop_ticks`, `output_events>0`, `exit_events=1`, `key_events=2`, `terminal_input_events=2`, `resize_events=1`, `close_events=1`, `frame_prepared=true`, `final_frame_ended=true`를 남긴다. 이 명령은 Swift/Zig ABI 링크, 앱 lifecycle, Zig-owned shell surface/frame loop, key/resize/close event ABI를 검증하고, app session의 shell glyph와 반전 블록 커서를 Swift window의 `MaruMetalTerminalView`(CAMetalLayer)에 그린다.
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

## config 토대(8단계 선행): 설정 파일 로딩

8단계(탭/global shortcut)·테마·동작 토글이 모두 사용자 설정을 읽으므로, 하드코딩 후 재작업을
막기 위해 config 파일 로더를 먼저 깐다. 1단계로 **appearance(폰트/테마/커서)**와 **키바인딩 파싱**을 구현했다 —
`~/.config/maru/config`(또는 `$MARU_CONFIG`)의 `key = value` 형식을 순수 파서(`config/loader.zig`,
Linux CI 포함 단위 테스트)로 `theme.Config`에 담고 `resolveAppearance`에 넘긴다. forgiving(알 수
없는 key·잘못된 값은 기본값 유지 + diagnostic), 문자열 소유권은 arena(세션 동안 보관). 키바인딩(`keybind = <조합> = <action>`)은 KeyChord.parse·parseAction으로 파싱하고 중복을 걸러 검증된 KeyBindingResolver로 준비한다 — 실제 dispatch는 8단계(탭 액션)에서 이 resolver를 그대로 쓴다. 자세한 형식/키는 [설정(config) 파일](configuration.md). 후속: 동작 토글, terminal 입력 remap, 런타임 reload, 설정 UI.

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

현재 진행 상태:

- app 레이어(`AppWindow`/`host`/`FrameLoop`/`SurfaceRuntime`/`LivePtyRegistry`/`config.Action`/`KeyBindingResolver`)는 **이미 다중 surface**다(`AppWindow.tabs`/`active_tab`/`selectTab`, registry가 surface_id로 라우팅, `new_tab`/`close_tab`/`select_tab`/`next_tab`/`previous_tab` 액션 파싱·테스트 완료). 병목은 macOS 앱의 `AppSession`이 `surfaces:[1]`·단일 `LivePtySession`을 하드코딩한 것뿐이다.
- **PR1a 완료(순수 라우팅 seam)**: `AppSession`의 모든 입력/IME/스크롤/마우스/렌더 경로가 `surfaces[0]` 대신 `activeSurface()`/`activeSurfaceConst()` 헬퍼를 거치게 했다(동작 불변 — 아직 단일 surface). 멀티-탭은 이 seam만 `app_window.active()`로 바꾸면 활성 탭으로 라우팅된다.
- **PR1b 완료(`AppWindow.tabs`를 `[]*Surface`로 — heap-pin 토대)**: surface 본체는 한번 만들면 못 움직인다(SurfaceRuntime이 routing link에 `*Surface`를 보관하고 `LivePtySession` reader thread가 `&reader`를 잡으므로, 이동하면 dangling=UAF). `AppWindow.tabs`를 surface '값' 배열 `[]Surface`에서 surface '포인터' 배열 `[]*Surface`로 바꿔(각 surface를 heap-pin) 탭 추가/삭제/재정렬이 본체를 안 옮기게 했다(close/split도 포인터 조작만으로 깔끔 — 고정-cap+repoint 대안보다 장기 유리). 순수 리팩터(동작 불변): `active()`가 `tabs[i]` 반환, app-layer fixture 23곳을 `[_]*Surface{&s,...}` 포인터 배열로 마이그레이션(빈 window·2탭 포함), `AppSession`은 `tab_ptrs:[1]*Surface`로 `surfaces[0]` 주소를 들고 `app_window.tabs`에 넘긴다. 기존 테스트 전부 통과가 불변을 증명.
- **PR1c 완료(seam을 active로 라우팅)**: `AppSession.activeSurface()`/`activeSurfaceConst()`가 `&surfaces[0]` 대신 `app_window.active()`/`activeConst()`를 읽는다(`AppWindow`에 `activeConst` 추가). 이제 모든 입력/IME/스크롤/마우스/렌더 경로가 `active_tab`을 따라가므로, 동적 컨테이너가 탭을 전환하면 자동으로 활성 탭에 라우팅된다. 순수 plumbing(동작 불변 — 단일 탭이라 active_tab=0): init에서 title/command 설정 전에 `app_window`를 먼저 세우고, AppSession 단위 테스트 6곳에 `app_window` 셋업을 추가. 기존 테스트 전부 통과.
- **PR1d-1 완료(per-tab 상태를 `Tab` 단위로 추출)**: AppSession의 `surfaces[0]`·`live_pty`·`pump`·`live_initialized`를 `Tab{surface, live_pty, pump, live_initialized}` 한 묶음으로 모았다(현재 단일 인라인 `tab: Tab` 필드 — AppSession이 heap-pin이라 안정). `LivePtySession` reader가 `&reader`를 잡고 `pump`는 안정 `*queue`만 들므로, Tab을 안 옮기면 안전하다(멀티-탭에서 각 Tab을 `ArrayList(*Tab)`로 heap-pin). 순수 리팩터(동작 불변): 모든 `self.surfaces[0]`/`self.live_pty`/`self.pump`/`self.live_initialized`를 `self.tab.*`로 라우팅, 테스트 6곳도 `session.tab.surface`로. **검증**: 헤드리스 단위 전부 통과 + **실 macOS app smoke**(셸 spawn→`tab.live_pty.pump`→`tab.surface` 렌더→resize→close 전체 라이프사이클, `terminal_surface=true output_events>0 exit_events=1 close_events=1`).
- **PR1d-2a 완료(`tab: Tab` 단일 → `tabs: ArrayList(*Tab)` 동적 컨테이너)**: per-tab 상태를 동적 컨테이너로 전환했다. `createTab`(Tab을 `allocator.create`로 heap-pin → 셸 PTY spawn → surface → runtime attach → pump → `tabs`/`surface_ptrs` append → `app_window.tabs` 재바인딩 → 새 탭 활성; 부분 실패 errdefer 정리), `activeTab()`(`tabs.items[active_tab]`), `next_id`로 surface_id·pty_id 유일 발급. init은 `runtime`를 먼저 세우고 `createTab`을 1회 호출. tick drain은 `activeTab().pump`, close/deinit은 `tabs.items` 순회(closeAndDetach는 runtime.deinit 전, surface.deinit+Tab destroy+ArrayList 해제는 runtime.deinit 후 — 원래 순서 보존). 단일 탭이라 **동작 불변**. 단위 테스트 6곳은 로컬 surface로 마이그레이션(partial 세션은 `session.tabs` 미사용 — surface-읽기 메서드는 `activeSurface()`=app_window 경로). **검증**: 헤드리스 단위 전부 통과 + 실 macOS app smoke(createTab→drain→렌더→resize→close→deinit 전체, `output_events=4 close_events=1 ended=true`, `real_exit=0`). `createTab`은 PR1d-2b가 2번째 탭에 그대로 호출한다.
- **PR1d-2b 완료(멀티-탭 drain + create/switch — 반-E2E)**: 실제로 2번째 탭이 동작한다. tick이 **모든 탭의 pump를 순회 drain**(백그라운드 탭도 자기 surface로 출력 수신, 누적 summary를 frame builder에 보고), `Tab.terminated` per-tab 종료 추적 + 세션(창) 종료는 `allTabsTerminated()`(live 탭 전부 종료 시 — 단일 탭이면 기존 동작 보존), `switchTab`(`app_window.selectTab` + metal_dirty). **검증(반-E2E, 실 PTY macOS 게이트)**: `init`(탭0) 후 `createTab`으로 controlled 셸(탭1) spawn → tick이 둘 다 drain → **탭1 surface가 자기 출력(`TAB_TWO_MARK`)을 받음**을 결정적 단언(`expect(saw)` 반전 시 실패 3건으로 실행 증명), `switchTab(0)`이 `activeSurface`를 탭0으로 라우팅·범위 밖은 false. 헤드리스 단위 전부 통과(단일탭 동작 불변) + app smoke `real_exit=0`. ABI 불변.
- **PR2 완료(Cmd+T → 새 탭, 키 경로로 native 최소)**: ABI create 함수를 새로 안 만들고 **기존 keyDown 경로**로 Cmd+T가 탭을 연다. `keybinding.zig`에 빌트인 `default_app_bindings`(Cmd+T=`new_tab`; 'T'는 글자라 `normalizeEventChar` 대문자 fold로 Shift 무관 매칭, layout 안전)를 `resolve`가 사용자 바인딩·빌트인 terminal 다음, Cmd-무시 fallthrough 전에 본다. `AppSession.handleKeyEvent`의 `.app_action`이 `dispatchAppAction`으로 → `new_tab`→`newTab`(첫 탭과 같은 종류 셸을 '현재 창 크기'로; spawn 파라미터 `new_tab_config`/`new_tab_zdotdir`를 init에서 보관해 deinit에서 해제), `next_tab`/`previous_tab`/`select_tab`→`switchTab`. Swift는 키만 보내고 판정·실행은 Zig(native 최소). **검증**: 헤드리스 keybinding 단위(빈 resolver가 Cmd+T→`new_tab`, Cmd+S→`ignored`) + macOS 키-경로 테스트(Cmd+T → `tabs.len` 1→2·새 탭 활성·app_key 회계, Cmd+S는 무동작). 전 게이트 green + app smoke `real_exit=0`. `macos-app`에서 Cmd+T를 누르면 새 셸로 전환(탭바 전이라도 인터랙티브 동작). Cmd+Shift+]/[(다음/이전 탭)은 Shift+문자 layout 이슈로 탭바와 함께(PR3).
- **UI 방향 결정(문서화)**: 탭/split UI는 cmux식 — **세로 탭 사이드바 + 탭마다 split(panel) + 드래그**. 탭바·split을 **Maru가 Metal 프레임에 직접 그린다**(native 최소, AppKit 탭 위젯 안 씀). Window→Workspace→SplitTree→Pane→Term 레이아웃 모델은 Maru 하나가 소유하고, terminal runtime 수명만 backend seam으로 분리한다(현재 in-process, 후속 `maru-sessiond`). tmux-CC 양방향 layout driver는 기본 계획에서 제외하고 외부 tmux import 수요가 생길 때만 별도 adapter로 재검토한다. 단일 출처는 [탭·split·레이아웃 전략](tabs-splits-layout.md)과 [영속 터미널 세션 호스트](persistent-session-host.md). → 앞서 "Swift NSWindow 탭 UI"는 폐기(네이티브 창 탭이 아니라 커스텀 세로 사이드바).
- **PR3a 완료(세로 사이드바 레이아웃 + "surface→rect" 렌더 메커니즘)**: 드로어블 왼쪽에 사이드바 strip을 예약하고 터미널을 그 폭만큼 오른쪽 사각형에 그린다 — split이 그대로 확장할 **"surface를 (origin+size) 사각형에 그린다"** 메커니즘을 깔고 사이드바를 첫 적용으로 썼다. `gridFromBacking(...,sidebar_width_px)`가 터미널 폭에서 사이드바를 빼고(언더플로 saturate), `sidebar_width_px = sidebar_width_pt(180)×scale`은 `refreshCellMetrics`가 메트릭과 같은 단일 출처로 환산. `MetalFrame` DTO에 `terminal_origin_x_px`+`sidebar_bg` 추가(`metalFrame()`이 세팅, 사이드바색=테마 배경+24로 코히어런트·가시), 렌더러(`maru_metal_renderer_draw`)가 셀을 `origin_x+col*cw`로 offset + 왼쪽 strip에 배경 quad(UV(-1) sentinel=배경만)를 그린다. **검증**: 헤드리스 `gridFromBacking` 단위(사이드바만큼 cols 감소·과대 사이드바 saturate) + ABI 계약(DTO .h↔.zig) + swift-check + 실 macOS app smoke(`surface_cols` 150→127로 축소, 셀 offset+사이드바 quad가 크래시 없이 렌더, `real_exit=0`). 사이드바가 실제로 '보이는지'(밝은 strip·터미널 우측 이동)는 `macos-app` 수동.
- **PR3b 분해(텍스트 렌더 위험 격리)**: 사이드바 탭 엔트리는 "메커니즘(두 번째 cell 배열)"과 "glyph 텍스트(공유 atlas 두 번째 패스)"의 위험도가 달라 둘로 나눈다. **PR3b-1 = 렌더 메커니즘 + 활성 하이라이트(이번)**, **PR3b-2 = 탭 번호·제목 glyph**.
- **PR3b-1 완료(사이드바 두 번째 cell 배열 + 활성 탭 하이라이트 밴드)**: `MetalFrame`/ABI(.h, abi_version 22→23)에 `sidebar_cells`+`sidebar_cell_count`를 더해 **사이드바 rect(x:0..origin_x)에 origin 0으로 그리는 두 번째 셀 배열**을 만들었다 — "surface→rect"의 두 번째 surface(사이드바)로, split이 rect별 cell 배열로 그대로 확장한다. 렌더러(`maru_metal_renderer_draw`)는 셀→quad 채우기를 `maru_fill_cell_quad` 헬퍼로 추출해 터미널(origin_x)·사이드바(origin 0)가 공유하고, quad 순서 `[터미널 cells][사이드바 배경 quad][사이드바 cells]`로 밴드가 배경 위에 블렌딩되게 한다. `rebuildSidebar`는 순수 `sidebarBandCell`(사이드바 폭/cell 폭을 floor해 칸 수 환산 — origin_x 침범 방지 — sentinel-UV 배경 셀)로 **활성 탭 행에 하이라이트 밴드 1개**(테마 배경+48)를 만들어 owned ArrayList에 담고, `metalFrame()`이 그걸 가리키는 view를 노출한다. 탭 추가(createTab)·전환(switchTab)·메트릭 변경(refreshCellMetrics)마다 다시 만든다(탭 i=행 i). **검증**: 헤드리스 `sidebarBandCell` 단위(폭 floor·sentinel UV·0칸 null) + macOS-게이트 통합(실 init이 사이드바 밴드 1개 emit, createTab→row 1·switchTab→row 0 추적) + ABI 계약(.h↔.zig sizeOf) + swift-check + 앱 빌드(렌더러 .m 링크). 텍스트 없음 — PR3b-2가 제목 glyph를 더한다. 한계: 한 줄 높이 밴드라 탭 수가 행 수 초과 시 화면 밖(슬롯 패딩/스크롤은 후속).
- **사이드바 색 테마 설정화(베이스)**: 사이드바 색을 `ThemeConfig`/`ResolvedTheme`의 1급 필드(`sidebar_background`/`sidebar_active`)로 올렸다. 선택(`?[]const u8`, #RRGGBB)이라 **명시하면 그 색, null이면 background에서 파생**(`resolveTheme`의 `lighten`: +24/+48). +24/+48 파생을 플랫폼 렌더에서 config resolver **단일 출처로 이동** — `app_session.sidebarBg/sidebarActiveBg`는 이제 resolved 색을 `packOpaqueRgb`로 packing만 한다. PR3b-2의 탭 제목 텍스트 색도 같은 방식으로(`sidebar_foreground` 추가) 붙인다. 검증: appearance resolver 단위(기본 파생 #101010→+24/+48, light 배경 saturate, override, 깨진 색 거부) + 기존 사이드바/렌더 테스트 불변.
- **사이드바 좌표 회귀 수정**: 사이드바가 터미널을 origin_x만큼 미는데 스크린↔셀 좌표 변환(`pxToCell`/`urlAt`/`imeCursorRect`)이 그 offset을 안 따라가 클릭/선택 블록이 사이드바 폭만큼 어긋났다(라이브 제보 "블록 밀림"). `pxToCell`은 x에서 사이드바 폭 차감(`urlAt`도 이걸 재사용해 통일), `imeCursorRect`는 가산(역변환). 헤드리스 단위로 가드.
- **PR(픽셀 슬롯 2.5×) 완료**: 사이드바 밴드를 cell 한 줄 높이에서 **탭 슬롯 픽셀 높이(≈2.5×cell_height, cmux식)**로 키웠다. `MetalFrame`/ABI(.h, abi_version 23→24)에 `sidebar_slot_height_px` 추가, `refreshCellMetrics`가 `cell_height_px × sidebar_slot_height_ratio_milli(2500)/1000`로 메트릭 단일 출처에서 파생, 렌더러는 사이드바 셀을 그릴 때 `maru_fill_cell_quad`에 cell 높이 대신 슬롯 높이를 넘겨 `row → py=row×slot_h, 높이 slot_h`로 배치(0이면 cell 높이 폴백). 이 픽셀 슬롯 높이가 이후 **호버/X hit-test의 기준 높이**도 된다. 검증: macOS-게이트 통합(`sidebar_slot_height_px == cell_height_px×2.5 > cell_height_px`) + ABI sizeOf + swift-check + 앱 빌드.
- **PR3b-2 분해(두 번째 glyph 패스 위험 격리)**: 탭 제목 렌더는 "공유 atlas 두 번째 패스 + 업로드 머지"가 가장 위험해 둘로 나눈다. **PR3b-2a = glyph 파이프라인 seam(이번)**, **PR3b-2b = 라이브 머지 + 렌더 + 화면 제목(다음)**.
- **PR3b-2a 완료(사이드바 glyph seam + 제목 DrawList 합성기)**: `CoreTextFrameBuilder.build`에서 `buildFromDrawList(draw_list, renderer_state)`를 추출해 — 터미널 snapshot 경로와 사이드바 탭-제목 경로가 **같은 shaper/rasterizer/renderer_state(atlas)** 를 공유하게 했다(제목 glyph도 터미널과 같은 slot 재사용, 새 glyph만 추가 업로드). `buildSidebarDrawList(titles, cols, fg)`는 텍스트 줄들을 한 줄=한 탭(row=탭 인덱스)의 `DrawList`로 합성한다 — UTF-8을 패닉 없이 디코드(깨진 시퀀스는 U+FFFD), `terminal.width.cellWidth`로 와이드 글자 2칸 전진, `cols` 초과분 자름, 커서/overlay 없는 UI 텍스트. 검증: 헤드리스 단위(제목→per-row 셀·자름·와이드 2칸 + fake bridge로 합성 DrawList가 glyph 2개까지 shape). 아직 화면엔 안 뜸 — PR3b-2b가 tick 통합·머지·렌더로 띄운다.
- **PR3b-2b 완료(라이브 탭 제목 렌더)**: tick이 매 frame `buildSidebarTitleFrame`(macOS — "{n} {title}" 라벨 → `buildSidebarDrawList` → `buildFromDrawList`, 터미널과 같은 atlas)으로 사이드바 제목 RenderFrame을 만들고, `MetalFrameBuffer.replace`가 터미널+사이드바를 머지한다: 셀 = 밴드(`self.sidebar_cells`) ++ 제목 glyph 투영, uploads/pixels = [터미널 ++ 사이드바]이며 **사이드바 upload의 bytes_offset += 터미널 pixels 길이**(합쳐진 pixels suffix를 가리키게). 사이드바 셀 소유가 app→`metal_buffer`로 옮겨져 `view()`가 노출(metalFrame은 슬롯 높이만 더함). 렌더러는 `maru_fill_cell_quad`를 `py_top`/`cell_h` 받게 리팩터하고, 사이드바 셀을 `slot_id`로 구분해 **밴드(slot_id 0)=슬롯 전체, 제목 glyph(slot_id≠0)=슬롯 안 세로 중앙 ch-높이 + 좌측 여백(cw×0.5)**으로 그린다. 제목 재-shape는 매 frame이지만 짧아 싸고 atlas dedup이 새 glyph만 업로드. 검증: 헤드리스(`buildMergedUploads` pixels 이어붙임·offset 시프트·null 경로, `buildMergedSidebarCells` 밴드 우선) + macOS 통합(tick 후 `sidebar_cell_count≥1`·슬롯 높이) + ABI/swift/앱 빌드. **이로써 탭 슬롯에 번호+제목 텍스트가 뜬다.**
- **PR3c 완료(사이드바 클릭/호버 hit-test)**: 순수 Zig 로직(ABI/렌더러 무변경, Swift는 clearHover sentinel 1줄). 마우스 좌표(backing px)를 사이드바 영역·슬롯으로 hit-test하는 순수 함수 `xInSidebar(x, width)`·`sidebarSlot(y, slot_h, tab_count)`를 추가하고, `mouse`(down=1, 사이드바 영역이면 슬롯→`switchTab`, 터미널 선택 경로 안 탐)·`hoverUrl`(사이드바 영역이면 `setHoveredSlot`, 터미널 URL 호버 해제)에서 래핑한다. `hovered_slot` 필드 + `rebuildSidebar`가 활성과 다른 호버 슬롯에 (활성 +48과 배경 +24의 중간 색) 호버 밴드를 더한다. 마우스가 창을 벗어날 때 Swift `clearHover`가 `(0,0)`(슬롯 0 오인) 대신 음수 sentinel `(-1,-1)`을 보내 호버를 해제한다. 검증: 헤드리스(`xInSidebar`/`sidebarSlot` 경계·범위 밖 null) + macOS 통합(슬롯 클릭→탭 전환, 슬롯 밖/터미널 클릭은 불변, 호버 밴드 추가/활성 위 억제/터미널로 나가면 해제) + swift/앱 빌드. 기존 터미널 드래그 테스트에 `sidebar_width_px=0` 명시(undefined 세션의 garbage 회피).
- **PR4 완료(탭 close + active_tab clamp)**: `closeTab(index)` — **마지막 한 개**면 창 닫기(종료 latch `ended_seen` + 활성 surface `process_state=.exited`, 탭은 안 헐고 deinit이 정리 → 빈 tabs로 `activeSurface` 패닉 회피), **그 외**면 deinit과 같은 순서로 teardown(`closeAndDetach(runtime)` → `live_pty.deinit`(reader join) → `surface.deinit` → Tab heap 해제) 후 `tabs`/`surface_ptrs`에서 `orderedRemove`하고 `app_window.tabs` 재바인딩, 순수 `reselectAfterClose(closed, active, new_len)`로 active clamp(앞을 닫으면 -1, active/마지막이면 last로). `frame_loop.pump`를 새 active로 방어적 갱신(AppSession tick 경로엔 미사용이나 active 탭을 닫으면 옛 포인터가 dangling). 트리거 **Cmd+W**(`default_app_bindings`에 추가, `dispatchAppAction.close_tab` → `closeTab(active)`). 호버 무효화(`hovered_slot=null`). 검증: 헤드리스(`reselectAfterClose` 앞/active/뒤/마지막·Cmd+W→close_tab 바인딩 resolve) + macOS 통합(실 PTY 3탭 → 백그라운드 닫기 active 2→1 → active 닫기 clamp 0 → 마지막 닫기 `ended_seen`) + 앱 빌드.
- **호버 X 닫기 아이콘 완료**: PR3c의 hover 슬롯 추적 + PR3b-2b의 제목 glyph 경로 + PR4의 `closeTab`을 합쳐 cmux식 호버-닫기를 완성. `buildSidebarDrawList`에 `close_row: ?usize` 추가 → 호버 슬롯 우측 col(cols-2)에 ✕(U+2715, `sidebar_close_glyph`) glyph 1개를 제목과 같은 파이프라인으로 그린다(렌더러/ABI 무변경). `buildSidebarTitleFrame`이 `close_row=hovered_slot` 전달. 클릭: 순수 `inSidebarCloseButton(x, width, cw)`(우측 2칸 zone)으로, `mouse` down이 ✕ zone이고 그 슬롯이 호버 중(`hovered_slot==slot`, ✕가 보임)이면 `closeTab(slot)`, 아니면 `switchTab(slot)`. 검증: 헤드리스(`buildSidebarDrawList` close_row→✕ 위치·null·범위 밖 무시, `inSidebarCloseButton` zone 경계) + macOS 통합(✕ zone 밖 클릭=전환, 호버 후 ✕ zone 클릭=실 PTY 탭 닫힘). 한계: 긴 제목이 ✕ col과 겹치면 ✕가 위에 그려짐(자름은 후속), ✕ 색은 글자색과 동일(hover 강조색은 후속).
- **Cmd+Shift+]/[ 탭 전환 키 완료**: `default_app_bindings`에 `{Cmd+Shift+] → next_tab}`·`{Cmd+Shift+[ → previous_tab}`를 추가(둘 다 wrap). Swift가 `charactersIgnoringModifiers`로 char를 보내는데 Cmd 조합에서 Shift가 적용돼 `}`/`{`로 올 수도, `]`/`[`가 그대로 올 수도 있어(OS/레이아웃 차이) **두 char 변형을 모두 묶었다**(모디파이어 정확 비교라 `shift=true` 필수). `next_tab`/`previous_tab` 액션 dispatch(wrap)는 이미 있었다. 검증: 헤드리스(resolve가 `]/}`→next·`[/{`→previous, Shift 없는 Cmd+]는 ignored) + macOS 통합(키 경로로 2탭 ]→1→0·[→0→1·}변형 동일).
- **PR3d 완료(탭 드래그 재정렬)**: cmux/Chrome식 live 재정렬. 순수 Zig(ABI/렌더러/Swift 무변경). down(사이드바 슬롯, ✕ 아님)이 `switchTab`+드래그 시작(`sidebar_drag_active`, `sidebar_drag_index=slot`), drag(kind 2)가 `sidebarDragTargetSlot(y)`(슬롯 아래 빈 영역도 마지막으로 clamp)로 타겟을 구해 `moveTab(index→target)`로 즉시 재정렬(드래그 탭=활성이 따라감), up(kind 3)이 종료. `moveTab`은 `std.mem.rotate`로 tabs/surface_ptrs를 무할당 in-place 회전(Tab heap-pin이라 포인터만 셔플 — surface/PTY/reader 안정, `app_window.tabs`는 같은 backing이라 재바인딩 불요)하고 순수 `adjustActiveForMove`로 active 보정. 드래그 캡처는 `drag_active && (kind 2|3)`만(새 down은 일반 처리로 흘려 재시작 — 다중 클릭 테스트도 안전). 드래그 시작 시 `hovered_slot=null`(stale 호버/✕ 숨김). 검증: 헤드리스(`sidebarDragTargetSlot` clamp, `adjustActiveForMove` 4케이스, `rotateMove` 정/역방향) + macOS 통합(down슬롯0→drag슬롯2→up: [Maru,t2,t3]→[t2,t3,Maru], 활성 드래그 탭 따라 2).
- **split 단계 시작**. 큰 다단계라 탭처럼 분해: **PR1 SplitTree 모델+레이아웃(헤드리스)** → **PR2a Tab→tree seam(단일 leaf, 동작 불변)** → PR2b 멀티-panel 렌더(N surface를 sub-rect에 합성 — 사이드바 머지의 일반화) → PR3 split 키(Cmd+D 등, 새 surface spawn + Pane 추출) → PR4 pane 포커스/입력 라우팅·마우스 pane 선택 → PR5 pane close/트리 collapse → PR6 divider 렌더+드래그 리사이즈. 무거운 **Pane 추출**(surface/pty/pump 다중화)은 실 소비자(2번째 pane)가 생기는 PR3에서 — 다중-pane 경로를 실제로 exercise해 테스트 가능하게.
- **split PR1 완료(SplitTree 모델 + 레이아웃)**: `src/app/split_tree.zig` 신설(app.zig re-export). `Node = leaf(*Surface) | split(*Split{direction, ratio, a, b})` 재귀 트리(Ghostty SplitTree **개념만** 참고, Zig 독립 구현, 드라이버 무관). `layout(node, rect, out)`가 rect를 sub-rect로 재귀 분할해 각 leaf의 (surface, rect)를 트리 순서로 채운다(horizontal=폭, vertical=높이를 ratio로; 두 자식 합=부모, 틈 없음; ratio는 [0.05,0.95] clamp로 0-panel 방지). `leafCount`·`deinit`(split 노드만 해제, leaf surface는 Tab/session 소유라 불관여). 멀티-panel 렌더(PR2)가 이 `LeafRect`들을 surface→rect로 그린다(사이드바 2-surface 머지의 일반화). 검증: 헤드리스 단위(단일 leaf=전체, h/v 분할 합=부모, 중첩 재귀, 극단 ratio clamp, deinit leak 없음). 아직 Tab은 단일 surface(모델만; Tab=트리 루트 전환은 PR2a).
- **split PR2a 완료(Tab→tree seam)**: `Tab`에 `tree: app.SplitNode` 필드 추가, `createTab`이 단일 leaf(`.{ .leaf = &tab.surface }`)로 초기화 — panel 1개 = 풀 탭 영역이라 **동작 불변**(Tab이 heap-pin이라 `&tab.surface` 안정 → leaf 포인터 안전). `activeTabLeafRects(allocator, term_rect, out)` 헬퍼가 활성 탭 tree를 터미널 영역 rect에서 leaf-rect로 편다(PR2b 렌더가 소비; 지금은 단일 rect). 무거운 Pane 추출(surface/pty/pump 다중화)은 PR3로 미뤄 다중-pane 경로를 실 소비자와 테스트한다. 검증: macOS 통합(`leafCount`=1, `activeTabLeafRects`가 활성 surface를 입력 rect 전체로) + 기존 탭 테스트 전부 불변.
- **split PR2b 완료(per-cell panel origin 렌더 프리미티브)**: 렌더러가 셀을 panel별 픽셀 origin에 그릴 수 있게 한다. `NativeMetalCell`/ABI 셀(.h, abi_version 24→25)에 `origin_x`/`origin_y` 추가 — 렌더러가 셀을 `origin_x + col*cw, origin_y + row*ch`에 둔다(per-cell이라 커서 suffix 길이 변화에도 각 셀이 자기 위치를 안다). `MetalFrameBuffer.replace`가 `terminal_origin_x/y`를 받아 `setCellsPaneOrigin`으로 터미널 셀에 박는다; tick은 단일 panel이라 `(사이드바 폭, 0)`을 넘겨 **동작 불변**(전부 같은 origin = 기존 terminal_origin_x 렌더와 동일). 사이드바 셀은 자체 위치 로직(origin 0/슬롯 높이)이라 이 필드 무시. 스모크 `MaruMetalSmokeCell`·sizeOf 단언(56→64)도 동기화. split(PR3)이 panel별로 다른 origin과 frame을 줘 N개 surface를 합성한다. 검증: 헤드리스(`setCellsPaneOrigin`이 모든 셀에 origin 박음) + ABI sizeOf 계약(.h↔.zig, 스모크 cell offset) + metal/app-pty 스모크(origin 0/사이드바폭 = 기존 렌더) + swift/앱 빌드. 화면 변화 없음(단일 panel) — 다중 origin 소비는 PR3.
- **split PR3a 완료(Pane 추출)**: 미뤄둔 침습적 리팩터 — 동작 불변. `Tab`의 per-surface 상태(surface/live_pty/pump/live_initialized/terminated)를 **`Pane` 구조체로 추출**하고, `Tab`은 `panes: ArrayList(*Pane)` + `active_pane: usize` + `tree`(leaf가 `&pane.surface`를 가리킴)를 든다(`Tab.activePane()`=`panes[active_pane]`). `createPane`(heap-pin Pane spawn)·`destroyPane`(closeAndDetach→reader join→surface deinit→free) 추출; `createTab`이 Tab+첫 Pane을 만들고 단일-leaf 트리를 세운다. 라우팅 전체 마이그레이션: tick drain(탭→**모든 panel** pump), `close`/`closeTab`/`deinit`(panel별 teardown), `allTabsTerminated`(모든 panel), `buildSidebarTitleFrame`(활성 panel 제목), `frame_loop.pump`(`activePane().pump`), `surface_ptrs`(탭 대표=활성 panel surface). 지금은 탭당 panel 1개(active_pane 0)라 기존과 동일. 검증: 기존 탭 테스트 전부 불변(생성/전환/닫기/드래그/Cmd 키/사이드바) + macOS 통합(`panes.len`=1·`active_pane`=0·`activeSurface`==`&activePane().surface`) + 앱 빌드. **다음 PR3b**(가시화). core 렌더 경로 위험을 줄여 둘로: PR3b-1a(N-frame 머지 머신리·동작 불변) → PR3b-1b(split 키+pane resize·가시화) → PR3b-2(활성 pane 입력/커서 라우팅).
- **split PR3b-1a 완료(N-frame 렌더 머지 머신리)**: `MetalFrameBuffer.replace`가 단일 터미널 frame 대신 **`[]PaneFrame`**(`{frame, origin_x, origin_y, colors}`)을 받아 N개를 합성한다 — 각 panel 셀을 자기 origin에 박고(`setCellsPaneOrigin`), uploads/pixels를 모든 panel + 사이드바로 머지(`buildMergedUploadsN`/`appendRaster`: 조각별 base offset 시프트). **활성 panel은 맨 뒤**(커서 cell이 합쳐진 cells 끝 → blink suffix 동작; 비활성은 `colors.cursor=null`이라 커서 없음). cols/rows는 가드용이라 활성 panel grid 사용. tick은 단일 panel이라 `[1]PaneFrame`(활성, origin=(사이드바폭,0))을 넘겨 **동작 불변**. 검증: 헤드리스(`appendRaster` pixels 이어붙임·base offset 시프트가 N-머지 핵심) + 기존 렌더/탭/스모크 전부 불변 + ABI/swift/app. 화면 변화 없음(N=1) — leaf별 frame 빌드·split 키는 PR3b-1b.
- **split PR3b-1b 완료(split 키 + 가시화 분할)**: 화면이 처음으로 나뉜다. `split_tree`에 `splitRect(rect, dir, ratio)`(생성용 — `layout`과 같은 분할 규칙으로 a/b rect)·`replaceLeaf(node, target, replacement)`(트리에서 활성 leaf를 split 노드로 in-place 교체) 추가. `Action`에 `split_horizontal`/`split_vertical`, 기본 바인딩 **Cmd+D=좌우·Cmd+Shift+D=상하**(normalizeEventChar가 'd'→'D' fold라 shift만으로 갈림). `splitActivePane(dir)`: 활성 panel의 현재 leaf rect를 `splitRect`로 a(기존)·b(새)로 나눠 **b 크기로 새 셸 panel을 spawn**(`createPane`)하고, 트리에서 활성 leaf를 `split{a: 기존, b: 새}`로 교체하고, 기존 panel을 a 크기로 `runtime.resize`(PTY winsize 포함)한 뒤 **새 panel로 포커스 이동**(`active_pane`·`surface_ptrs[active_tab]`·`frame_loop.pump` 재바인딩) — 실패는 errdefer로 트리/탭 원복. tick은 활성 탭 leaf rect를 펴 **비활성 panel은 각자 snapshot으로 frame을 빌드**(plain 색, 커서 없음) 후 **활성 panel을 맨 뒤**(커서 suffix)로 PR3b-1a의 N-머지에 넘긴다(비활성 frame은 여기서 소유·replace 뒤 해제 — 이중 free 방지). resize는 backing 픽셀을 보관하고 `resizeActiveTabPanes`로 **활성 탭의 모든 panel을 자기 leaf rect grid로 재배치**(단일 leaf면 기존 `resizeActiveSurface`와 동일). `closeTab`/`deinit`이 `split_tree.deinit`로 heap split 노드를 해제. 방향 규칙·베이스는 [탭·split·레이아웃 전략](tabs-splits-layout.md). 검증: 헤드리스(`splitRect`=`layout` 일치·`replaceLeaf` 루트/중첩/미발견, action/keybinding 파싱·해석) + macOS 통합(split 후 panel 2개·새 panel 활성·tree=horizontal split{기존,새}·leaf rect 합=폭·tick N-panel 렌더 무크래시) + 전체 테스트 558 통과 + ABI/swift/boundaries/metal·pty 스모크/앱 빌드. ABI 무변경(렌더 머신리는 PR3b-1a, 키/포커스는 native). 한계: 활성 pane만 입력/커서를 받는다(분할 직후 새 pane 포커스는 맞지만 마우스/키로 **다른 pane 선택**은 PR3b-2), divider 선·드래그 리사이즈 없음(고정 0.5, PR6), 비활성 panel은 dirty마다 재-shape(프레임 캐시는 후속).
- **split PR3b-2a 완료(pane 포커스 + pane-rect 좌표 라우팅 + 마우스 클릭 포커스)**: split된 활성 panel은 사이드바를 뺀 터미널 영역 '전체'가 아니라 **서브-rect**에 있는데, 좌표 변환(`pxToCell`/`imeCursorRect`/드래그 autoscroll)이 활성 surface가 전체를 채운다고 가정해 split이면 마우스/커서/IME가 어긋났다. 이를 **활성 panel의 픽셀 rect 기준**으로 고친다. 새 필드 `active_pane_rect`(활성 panel leaf rect 캐시)를 두고 `recomputeActivePaneRect`가 레이아웃/포커스/리사이즈 변경 때(init 끝·resize·switchTab·createTab·closeTab·focusPane·splitActivePane) 갱신한다 — 매 마우스 이벤트마다 재레이아웃(할당)하지 않게 캐시. `pxToCell`는 스크린 (x,y)에서 `active_pane_rect.x/y`를 빼고(기존엔 x만 사이드바 폭, y는 0 가정), `imeCursorRect`는 origin을 더한다(단일 panel이면 origin = (사이드바 폭, 0)이라 동작 불변). 드래그 autoscroll 경계도 `active_pane_rect.y` 기준. **포커스 전환**: `focusPane(index)`가 활성 panel surface를 탭 대표(`surface_ptrs[active_tab]` = `app_window.active()`)·`frame_loop.pump`에 재바인딩 + rect 재계산(splitActivePane도 이걸 호출 — DRY). **마우스 클릭 포커스**: 순수 `paneAtPoint(leaf_rects, x, y)`(반열린 구간 hit-test)로 down(1) 클릭이 떨어진 panel을 찾아, split일 때(`activeTabHasSplit` 가드, `kind==1` 단락 평가로 단일 panel·최소-셋업 테스트는 무영향) 다른 panel이면 `focusPaneBySurface`로 포커스를 옮기고 클릭을 소비한다(선택은 새 활성 panel에서 다음부터). 검증: 헤드리스(`paneAtPoint` 경계/밖/비유한, `pxToCell`/`imeCursorRect`가 x·y origin 둘 다 처리) + macOS 통합(split 후 왼쪽 panel 클릭→포커스 이동·origin 갱신, 활성 panel 재클릭→불변, 오른쪽 클릭→복귀) + 전체 600 테스트 통과 + swift/abi/boundaries/metal·pty 스모크. ABI 무변경. 한계: **키보드 pane 이동 없음**(방향키 포커스 전환은 PR3b-2b), divider 없음(PR6), pane close 없음(PR5), 마우스 휠 스크롤은 활성 panel만(비활성 panel 위 휠은 후속).
- **split PR3b-2b 완료(키보드 pane 이동)**: `Cmd+Option+화살표`로 split 탭에서 방향 인접 panel로 포커스를 옮긴다(iTerm2식). `Action`에 `focus_pane_left/right/up/down` 4개 + 기본 바인딩 `Cmd+Option+arrow_*`(모디파이어 정확 비교라 `Cmd+화살표`=줄 처음/끝·`Option+화살표`=단어 이동과 안 겹침). 순수 `paneInDirection(leaf_rects, active_surface, dir)`가 각 panel rect '중심'을 비교해 방향 반평면 안 후보 중 **주축 거리 + 부축 어긋남×2(정렬 페널티)** 최소를 고른다 — 좌우 split이면 상/하는 후보가 없어 null(무동작), 격자면 같은 행/열 정렬 panel 우선. `focusPaneInDirection`이 활성 탭 leaf rect를 펴 대상을 찾아 PR3b-2a의 `focusPaneBySurface`로 포커스를 옮긴다(split 없거나 그 방향 없으면 무동작, OOM은 best-effort 무시). dispatchAppAction이 4개 액션을 매핑. 베이스(iTerm2 키)·방향 기하는 [탭·split·레이아웃 전략](tabs-splits-layout.md). 검증: 헤드리스(`paneInDirection` 좌우 2-panel·2×2 격자 방향 선택·잘못된 축 null·미발견, action/keybinding 파싱·해석·`Cmd+화살표`는 터미널 바인딩으로 안 겹침) + macOS 통합(split 후 Cmd+Opt+Left→기존·Right→새·Up→불변, 키 경로 전체) + 전체 테스트 통과 + swift/abi/boundaries/metal·pty 스모크. ABI 무변경. 이로써 split을 마우스·키보드 둘 다로 오갈 수 있다(PR3b-2 완료).
- **split PR5a 완료(pane close + 트리 collapse)**: `Cmd+W`가 Warp/cmux식으로 split이 있으면 활성 panel을 하나 닫고(트리 collapse), 단일 panel이면 탭(마지막이면 창)을 닫는다 — Cmd+W를 반복하면 pane이 하나씩 닫히다 마지막에 탭이 닫힌다. `split_tree.removeLeaf(allocator, node, target)`: split{target_leaf, sibling}을 형제 subtree로 교체하고 split 노드만 heap 해제(`replaceLeaf`의 역연산, 형제의 *Split·leaf surface는 안 건드림; 루트 단일 leaf는 형제가 없어 false → 탭 close가 처리). `closeActivePane`: removeLeaf로 트리 collapse → `orderedRemove`+`destroyPane`(closeAndDetach→reader join→surface deinit→free) → `active_pane` 보정 → 대표 surface·`frame_loop.pump` 재바인딩 → `resizeActiveTabPanes`로 남은 panel이 빈자리 차지 → `recomputeActivePaneRect`. `Cmd+W`(`close_tab` 액션)를 split 유무로 라우팅(당시 `closeActivePaneOrTab`; 이후 닫기 확인 PR에서 `resolveCloseScope`/`executeClose` 단일 출처로 통합돼 그 래퍼는 제거됨). 검증: 헤드리스(`removeLeaf` collapse·중첩·형제 보존·heap 해제 leak 없음·루트 leaf false·미발견 false) + macOS 통합(split 후 Cmd+W→활성 panel 닫힘·형제로 collapse·1 panel·남은 panel 전체 폭 resize·세션 유지·tick 무크래시) + 전체 테스트 통과 + swift/abi/boundaries/metal·pty 스모크. ABI 무변경. 한계: **셸 exit 시 자동 close 없음**(터미네이트된 pane이 트리에 남는다 — 자동 collapse는 PR5b), divider 없음(PR6).
- **split PR5b 완료(Term/pane exit 자동 collapse)**: 셸이 `exit`한 개별 Term을 자동으로 닫고 cmux/Warp식 cascade로 정리한다 — cmux 풀 모델이라 PR5a 설계(pane 단위)를 **Term→pane→워크스페이스**로 일반화했다. tick의 drain 루프가 모든 탭/panel/Term의 PTY를 비우며 종료를 관측(`term.terminated`)한 직후, **이번 tick에 새 종료가 있으면**(`drain_summary.ended != null`) `reapTerminatedTerms`를 부른다: 살아있는 Term이 하나라도 있으면 죽은 Term을 한 번에 하나씩 닫고 다시 스캔한다(`findTerminatedTerm`→`closeTermAt`, 구조 변화로 인덱스/포인터가 stale 되지 않게). `closeTermAt(tab_index, pane, term_index)`(활성/배경 탭 공용, `closeActiveTerm`의 위치-인자 일반화): destroyTerm 후 **pane에 Term 남으면** `active_term` clamp, **비면** split이면 `collapsePaneIn`(활성 탭 전용 `collapsePane`을 임의 탭 `collapsePaneIn(tab, pane)`으로 일반화)·단일 pane이면 `closeTab`(워크스페이스 close). `refreshAfterReap`이 그 탭 대표 surface를 현재 활성 Term으로 재바인딩(닫힌 Term을 가리키던 dangling 방지)하고 `resizeTabPanes(tab)`(임의 탭 best-effort resize 신설)로 collapse 형제를 확장하며, 활성 탭이면 좌표 origin 재계산·redraw. **전부 죽었으면 reap 안 함** — 기존 단일 탭 exit→창 닫힘 동작 보존(`allTabsTerminated` latch가 마지막을 맡아 reap이 빈 세션을 만들지 않는다). reap은 살아있는 Term이 있을 때만 close하므로 closeTab이 '마지막 탭'(세션 종료)을 치는 일은 없다(다른 live Term = 다른 탭 보장). 검증: 헤드리스 결정적 단위(term.terminated 세팅 후 reapTerminatedTerms 직접 호출 — 비동기 PTY 폴링 flakiness 회피) ① pane 내 형제 Term 유지 ② split pane collapse(형제 전체 폭) ③ 배경 워크스페이스 close·active 보정 ④ 마지막 Term은 reap 안 함(latch 소유) + 전체 테스트 통과 + swift/abi/boundaries/metal·pty 스모크. ABI 무변경(25). 한계: 비동기 실 exit→reap의 end-to-end는 앱/visible smoke 수동 확인(단위는 관측 상태를 시뮬레이션).
- **cmux 풀 모델 채택(사용자 결정)**: cmux 화면 비교(동작/레이아웃만, GPL 코드 미참고) 결과, cmux는 각 **pane(=split leaf)이 자기 가로 탭 바 + 여러 터미널(surface)을 담는 탭 컨테이너**다(⌘T=활성 pane에 새 탭, ⌘W=활성 surface 닫기, 탭을 pane↔pane 드래그, divider 드래그 리사이즈). 사용자가 이 풀 모델을 그대로 구현하기로 결정("기존 설계 아끼지 말고 엎어서 진행"). 분해: **PR-A 모델 리팩터(이번)** → PR-B(⌘T 새 surface 탭·⌘W surface 닫기·⌘[/⌘] 탭 이동) → PR-C(per-pane 상단 탭 바 렌더) → PR-D(호버 ✕·활성 하이라이트·클릭) → PR-E(탭 드래그 pane 내/간) → PR-F("+" 버튼). PR5b(exit 자동 collapse)·PR6(divider 드래그)는 이 흐름에 합류.
- **split PR-A 완료(Pane = 멀티-surface 탭 컨테이너 모델 리팩터)**: 동작 불변. `split_tree`를 **leaf 타입에 generic**(`SplitTree(comptime Leaf)`)으로 바꿔 — app 레이어가 platform의 Pane 타입에 의존하지 않으면서 트리가 panel을 leaf로 들 수 있게 했다(트리는 leaf를 pointer-identity로만 다루고 deref 안 함). leaf-독립(Rect·SplitDirection·splitRect)은 top-level, leaf-의존(Node·Split·LeafRect·layout·leafCount·deinit·replaceLeaf·removeLeaf)은 generic 안으로. 헤드리스 테스트는 `SplitTree(*u32)`로 인스턴스화(Surface 의존 제거). platform은 `const PaneTree = app.SplitTree(*Pane)`. 모델: 기존 `Pane`(surface+live_pty+pump 묶음)을 **`Term`으로 rename**하고, 새 **`Pane = { terms: []*Term, active_term }`**(가로 탭 컨테이너, activeTerm()=보이는 터미널)을 도입. **트리 leaf = `*Pane`**(surface 아님) — 렌더/hit-test/포커스가 surface→pane 매핑 없이 Pane을 바로 얻는다. `createTerm`/`destroyTerm`(per-surface)·`createPane`/`destroyPane`(컨테이너, 1 Term으로 시작) 분리. tick은 모든 탭→모든 pane→모든 Term을 drain; 비활성 pane은 자기 활성 Term surface를 렌더; resize는 각 pane의 모든 Term을 그 rect로; deinit/close는 Term까지 내려가 정리. paneAtPoint/paneInDirection은 `*Pane` 반환(focusPaneByPtr). **죽은 방어 코드 제거**: AppSession이 `frame_loop.pump`를 절대 읽지 않음을 확인하고(`tickAfterDrainWithFrameBuilder`만 씀) 포커스/닫기/이동의 `frame_loop.pump` 재바인딩을 전부 삭제, init 바인딩에만 이유 주석. 검증: 헤드리스(generic split_tree 전 연산을 `*u32` leaf로, paneAtPoint/paneInDirection을 빈 Pane 더미로) + macOS 통합(단일 leaf=활성 pane·split tree=split{기존 pane, 새 pane}·Cmd+W collapse·클릭/키 포커스, 전부 leaf=*Pane로 갱신) + 전체 테스트 통과 + swift/abi/boundaries/metal·pty 스모크. ABI 무변경. 아직 Pane당 Term 1개라 화면 동작 불변 — ⌘T로 여러 Term은 PR-B.
- **split PR-B 완료(Term 생명주기 + 키바인딩 재배치)**: cmux 모델대로 한 pane이 여러 Term(가로 탭)을 들고, 키로 추가/순환/닫기 한다(아직 탭 바 렌더는 없음 — PR-C). `Action`에 `new_term`/`close_term`/`next_term`/`previous_term` 추가, 기본 바인딩 재배치: **⌘T=`new_term`**(활성 pane에 새 Term), **⌘⇧T=`new_tab`**(새 워크스페이스 — 사이드바 "+" 생기기 전 임시), **⌘]/⌘[=`next/previous_term`**(활성 pane 안 wrap), **⌘W=`close_term`**(cascade), ⌘⇧]/⌘⇧[=워크스페이스 전환 유지. modifier(shift 유무) 정확 비교로 Term↔워크스페이스가 갈린다. AppSession: `focusTerm(index)`(활성 pane 안 Term 전환 — surface 재바인딩·rect 재계산)·`focusTermRelative(±1)`(wrap)·`newTermInActivePane`(활성 pane rect 크기로 새 셸 spawn → terms append → focus)·`closeActiveTerm`(Term≥2일 때 활성 Term teardown+active_term 보정)·`closeActiveTermOrPane`(**계층 cascade**: Term≥2면 Term 닫기, 아니면 PR5a의 pane/워크스페이스 close). tree leaf는 pane이라 Term 추가/닫기엔 트리 무변(대표 surface만 활성 Term으로 재바인딩). 베이스(cmux ⌘T/⌘[]·계층 cascade)는 [탭·split·레이아웃 전략](tabs-splits-layout.md). 검증: 헤드리스(action/keybinding 파싱·해석) + macOS 통합(⌘T로 Term 3개·⌘]/⌘[ wrap·⌘W가 Term→pane→워크스페이스 cascade로 닫혀 마지막에 세션 종료 latch) + 전체 테스트 통과 + swift/abi/boundaries/metal·pty 스모크. ABI 무변경. 다음 PR-C가 per-pane 상단 탭 바를 그려 이 Term들을 화면에 보이게 한다.
- **split PR-C1 완료(per-pane 상단 탭 바 strip 예약 + 바 배경)**: 각 panel(leaf rect) 상단에 cmux식 가로 탭 바를 위한 strip(높이 = cell 1칸)을 예약하고 그 아래를 터미널 영역으로 쓴다. `paneBarHeightPx`(= cell 높이)·`paneTermRect(rect)`(바 아래 영역)·`paneBarRect(rect)`(상단 바, 너무 작으면 null)을 단일 출처로, 좌표(`recomputeActivePaneRect` → active_pane_rect = 바 아래)·resize(각 Term을 paneTermRect grid로)·split(자식 a/b 각자 paneTermRect grid)·렌더(각 pane surface frame origin = 바 아래)가 모두 이 영역을 쓴다. 바 배경은 순수 `paneBarBgCell(bar, cw, bg)`(sentinel-UV 배경 셀, origin 박힌, 폭=cols라 아래 터미널과 정렬)로 만들어 — 활성 panel 바는 강조색(`sidebarActiveBg`), 비활성은 chrome 색(`sidebarBg`) — **터미널 셀 스트림에 prepend**(`metal_frame.replace`에 `pane_chrome_cells` 인자 추가, 커서 suffix는 맨 뒤 유지). 렌더러 .m·ABI 무변경(chrome 셀이 origin_x/origin_y로 기존 `maru_fill_cell_quad` 경로를 그대로 탄다). 검증: 헤드리스(`paneBarBgCell` origin/폭/sentinel·작으면 null, `paneTermRect`/`paneBarRect` 바 예약·작은 rect는 바 없음) + macOS 통합(resize 후 active_pane_rect.y = 바 높이·높이 감소, tick이 cells 맨 앞에 바 chrome 셀을 냄) + 전체 테스트 통과 + swift/abi/boundaries/metal·pty 스모크. **이로써 각 pane 상단에 바가 보인다(아직 배경만 — 제목·✕·드래그는 PR-C2/D/E)**.
- **split PR-C2 완료(per-pane 탭 바 제목 + 활성 Term 하이라이트 + 바 높이 버그 수정)**: 각 pane 상단 바에 그 pane의 **Term 제목들을 가로 등폭 탭**으로 그린다(드디어 ⌘T로 만든 Term들이 탭으로 보인다). `coretext_frame_builder.buildPaneTabBarDrawList(titles, cols, fg)`(사이드바의 세로 버전과 달리 **행 0에 가로**로, 탭 i는 col [i*tab_w, (i+1)*tab_w) 세그먼트에 1칸 좌패딩 뒤 제목, 넘치면 자름)·`paneTabWidth(cols, n)`(= cols/n, min 1) 추가. tick이 pane마다 이 DrawList → `buildFromDrawList`로 RenderFrame을 만들어 **터미널 frame들 앞**(활성 panel 커서 suffix 보존)에 `PaneFrame{origin = 바, colors = 글자색}`로 넣는다(같은 atlas 머지). 활성 Term 탭은 순수 `paneTabHighlightCell`(같은 `paneTabWidth`로 정렬된 세그먼트 강조 밴드)로 강조 — 바 base = `sidebarBg`, 활성 Term 세그먼트 = `sidebarActiveBg`. **버그 수정**: `paneBarHeightPx`를 `cell_width_px`(advance) → **`cell_height_px`(line height)**로 — 렌더러가 바 배경 셀을 다른 셀처럼 `ch` 높이로 그리므로, 폰트가 정사각이 아니면(보통 line height > advance) 바가 예약 높이보다 크게 그려져 터미널 첫 줄("Last login…")이 바와 겹치던 사용자 제보 수정. 검증: 헤드리스(`buildPaneTabBarDrawList` 가로 등폭·세그먼트 자름, `paneTabWidth` 분배, `paneTabHighlightCell` 세그먼트 정렬·밖이면 null) + macOS 통합(⌘T로 Term 2개 후 tick이 바 배경+활성 탭 하이라이트 chrome을 냄) + 전체 테스트 통과 + swift/abi/coretext·metal·pty 스모크. ABI 무변경. 다음 PR-D가 호버 ✕·탭 클릭 전환/닫기를 더한다.
- **config 키바인딩 연결 완료(버그 수정)**: `handleKeyEvent`가 빈 resolver(`KeyBindingResolver{}`)를 넘겨 사용자 config의 `keybind = <조합> = <action>`이 무시되던 것을 `loaded_config.keyBindingResolver()`로 연결 — 사용자 바인딩이 default_app_bindings보다 먼저 매치돼 override/추가가 된다(빈 config면 폴백). 인프라(loader 파싱·모든 앱 액션 parseAction)는 이미 있었고 연결만 빠져 있었다. **앱 액션만** config 대상(터미널 레벨 키는 후속 — keyBindingResolver가 app_bindings만 채움). 검증: macOS 통합(사용자 keybind Cmd+E=new_term 주입 → 동작, 기본 Cmd+T 폴백).
- **split PR-D1 완료(탭 바 클릭 → Term 전환)**: per-pane 탭 바의 탭을 클릭하면 그 pane을 포커스하고 클릭한 Term으로 전환한다(cmux). 순수 `pointInRect(x,y,rect)`·`tabIndexInBar(bar, cw, term_count, x)`(보이는 탭과 같은 `paneTabWidth` 등폭 분할로 x→탭, 끝은 clamp) 추가. `mouse` down(1) hit-test를 재구성 — 활성 탭 leaf rect를 한 번 펴 ① **탭 바 클릭**(`paneBarRect`에 점이 들면 `tabIndexInBar`로 탭을 골라 `focusPaneByPtr`+`focusTerm`, 단일 panel도 Term 여럿이면 전환) ② **다른 panel 터미널 영역 클릭**(`paneAtPoint`로 pane 포커스, 기존)을 차례로 본다. 둘 다 클릭을 소비(터미널 선택은 '바 아래'에서만 시작). 검증: 헤드리스(`tabIndexInBar` x→탭·끝 clamp·cell/탭 0, `pointInRect` 반열린 경계·비유한) + macOS 통합(⌘T로 Term 2개 후 탭 0 클릭→Term 0·탭 1 클릭→Term 1·선택 안 시작) + 기존 pane-클릭 테스트를 '바 아래' 클릭으로 갱신 + 전체 테스트 통과 + swift/abi/boundaries/metal·pty 스모크. ABI 무변경. 다음 PR-D2가 호버 ✕ 닫기를, PR-E가 탭 드래그를 더한다.
- **split 활성 pane 표시 추가(제보 대응)**: split에서 모든 pane의 탭 바가 활성 Term을 같은 강조색으로 칠해 어느 pane이 포커스됐는지 안 보이던 것을(세로 분할 시 "탭 활성화 UI가 안 바뀐다"는 제보) 고친다 — **활성 pane** 탭은 밝은 `sidebarActiveBg`, **비활성 pane** 탭은 dim `sidebarHoverBg`(bg/active 중간 톤). pane 포커스를 옮기면(클릭·`⌘⌥화살표`) 어느 bar가 활성인지 시각적으로 갱신된다. 검증: macOS 통합(세로 분할 후 아래(활성) 바는 origin_y>0·밝은 강조, 위(비활성) 바는 dim 강조 — 두 색이 다름; 아래 바 탭 클릭 hit-test도 정상). 렌더 위치·클릭 자체는 가로/세로 동일하게 정상임을 헤드리스로 확인(제보의 시각 차이는 활성 pane 미구분 때문).
- **split PR-D2 완료(탭 호버 ✕ → Term 닫기)**: per-pane 탭에 마우스를 올리면 그 탭에 ✕(닫기)가 뜨고, ✕를 클릭하면 그 Term을 닫는다(사이드바 호버-✕의 Term 버전). 새 필드 `hovered_tab: ?TabRef{pane, tab}` + `setHoveredTab`/`updateHoveredTab`(hoverUrl이 마우스 이동마다 어느 pane 바 위면 (pane, `tabIndexInBar`)로 갱신). `buildPaneTabBarDrawList`에 `close_tab: ?usize` 추가 → 호버 탭 우측 안쪽(seg_end-2)에 ✕ glyph(제목은 ✕ 앞까지만). 렌더 루프가 `hovered_tab.pane == lr.leaf`면 그 탭 index를 close_tab으로 넘긴다. 순수 `xInTabCloseZone(bar, cw, tab, term_count, x)`(세그먼트 우측 2칸, ✕ glyph col과 정렬). `mouse` down(1) 탭 바 클릭이 **호버된 탭의 ✕ zone**이면 `focusPaneByPtr`+`focusTerm`으로 그 탭을 활성화한 뒤 `closeActiveTermOrPane`(cascade)로 닫는다(아니면 전환). 닫기는 Pane을 해제할 수 있어 `closeActivePane`/`closeTab`·✕ 클릭에서 `hovered_tab`을 null로 비운다(닫힌 Pane 포인터 stale 방지). 검증: 헤드리스(`xInTabCloseZone` 우측 2칸·좁은 바 false, `buildPaneTabBarDrawList` close_tab→✕ col=seg_end-2·null이면 ✕ 없음) + macOS 통합(⌘T로 Term 3개·탭 1 ✕ 호버→hovered_tab 설정·✕ 클릭→Term 2개·호버 비움) + 전체 테스트 통과 + swift/abi/coretext·metal·pty 스모크. ABI 무변경. 다음 PR-E가 탭 드래그(pane 내/간)를 더한다.
- **split PR-E1 완료(pane 안에서 Term 탭 드래그 재정렬)**: 탭을 드래그하면 그 pane 안에서 순서가 바뀐다(사이드바 워크스페이스 드래그의 Term 버전). 새 필드 `tab_drag_active`/`tab_drag_pane: ?*Pane`/`tab_drag_index`. `mouse` 최상단에 사이드바 드래그 캡처처럼 **Term 탭 드래그 캡처**(`tab_drag_active and (kind 2 or 3)`): drag(2)면 `dragTabTo(x)`, up(3)이면 종료. down(1) 탭 클릭(✕ 아니면)에서 `focusTerm` 뒤 드래그를 arm(소스 pane·탭 index). `dragTabTo`: 소스 pane의 바를 찾아 x→타겟 탭(`tabIndexInBar`, x clamp)을 잡고 현재 인덱스와 다르면 `rotateMove(*Term, pane.terms.items, from, to)` + `active_term`=타겟 + `tab_drag_index`=타겟(드래그 탭이 활성으로 따라간다 — 같은 Term이라 대표 surface는 안 바뀜). 탭 1개·소스 pane 미발견이면 무동작. 검증: macOS 통합(⌘T로 Term 3개 → 탭 0을 탭 2로 down→drag→up → terms [T1,T2,T0] 회전·드래그 탭 활성) + 전체 테스트 통과 + swift/abi/boundaries/metal·pty 스모크. ABI 무변경. 다음 PR-E2가 탭을 다른 pane으로 이동(+ 비면 collapse)을, PR-F가 "+" 버튼을 더한다.
- **split PR-E2 완료(탭을 다른 pane으로 드래그 이동 + 소스 비면 collapse)**: 탭을 드래그해 **다른 pane의 바에 drop**하면 그 pane으로 Term이 옮겨가고, 소스 pane의 마지막 Term이 나가면 그 pane이 collapse된다(cmux식). 이동은 thrash 방지로 **up(drop) 시점**에 한다(pane 내 재정렬은 drag(2) live, PR-E1). `dropTabAt(x, y)`: 마우스가 소스 아닌 pane의 바 위면 `moveTermToPane(src, tab_drag_index, dst, tabIndexInBar(dst_bar, x))`. `moveTermToPane`: `src.terms.orderedRemove` → `dst.terms.insert`(insert 실패는 src로 원복) → src active_term 보정·dst active_term=삽입 위치 → src 비면 `collapsePane` → dst를 활성 pane으로(collapse로 인덱스 밀림 다시 찾음)·대표 surface 재바인딩 → `resizeActiveTabPanes`(옮긴 Term을 dst term rect grid로, src 형제가 빈자리 확장)·`recomputeActivePaneRect`. `collapsePane`: `removeLeaf`(형제로)·panes에서 빼기·`destroyPane`(빈 terms라 리스트·Pane만). Term은 heap-pin(`*Term`)이라 pane 사이를 포인터로 옮겨도 surface/reader·runtime link 주소가 안 움직인다. 검증: macOS 통합(좌우 split·우 pane Term 2개 → 우 탭을 좌 바에 drop → 좌 2·우 1·좌 활성·collapse 없음 → 우 마지막 탭을 좌에 drop → 우 collapse·단일 pane·좌 3개) + 전체 테스트 통과 + swift/abi/boundaries/metal·pty 스모크. ABI 무변경. 다음 PR-F가 탭 바 "+" 버튼(새 Term/split)을 더한다.
- **split PR-F 완료(per-pane 탭 바 "+" 버튼 — 새 Term)**: 각 pane 탭 바 우측에 "+"를 그려, 클릭하면 그 pane에 새 Term이 뜬다(⌘T의 마우스 버전). `coretext_frame_builder`: `pane_tab_plus_cols: u16 = 3` + `paneTabAreaCols(bar_cols)`(바가 충분히 넓으면 `bar_cols - 3`, 아니면 전체 — 좁은 바는 "+" 생략)로 **탭 영역과 "+" 영역을 분리**한다. `buildPaneTabBarDrawList`가 탭을 `paneTabAreaCols` 안에만 등폭으로 깔고, 남으면 `tab_cols + 1` col에 '+' glyph를 그린다(✕는 그대로 호버 탭 `seg_end-2`). 탭 hit-test(`tabIndexInBar`/`xInTabCloseZone`)도 같은 `paneTabAreaCols`를 써 **보이는 탭 == 클릭되는 탭**을 유지(탭 영역으로 col clamp, x가 "+" zone이면 마지막 탭이 아니라 "+"로). 새 순수 `xInPlusZone(bar, cw, x)`: x가 `[tab_cols, cols)`면 true(좁아 "+" 없으면 false). `mouse` down(1) 탭 바 분기에서 ✕/탭 전환보다 **먼저** "+" zone을 검사 — 맞으면 `focusPaneByPtr(lr.leaf)` + `newTermInActivePane`(PR-B 재사용). 검증: 헤드리스(`xInPlusZone` zone 판정·좁은 바 없음, `buildPaneTabBarDrawList`가 '+'를 `tab_cols+1`에 그리고 ✕는 새 `seg_end-2`로·좁은 바엔 '+' 없음) + macOS 통합(단일 pane → 바 "+" zone 클릭 → terms 2개·세션 유지) + 전체 테스트 통과 + swift/abi/boundaries/coretext·metal·pty 스모크. ABI 무변경(25). "+"가 split이 아니라 새 Term을 띄우는 건 cmux 동작 비교 기준(탭 추가). split은 ⌘D/⌘⇧D·divider(PR6)로 유지. 이로써 8단계 탭 토대(PR-A~PR-F)가 닫힌다.
- **split PR-G 완료(탭 바 hit-test 단일 출처 `BarMetrics` + "+" 호버 ✕ 오표시 수정)**: `/code-review max`로 발견한 PR-F 회귀를 고치고, 흩어진 탭 바 메트릭 계산을 한 구조로 모은다. **(버그)** PR-F 후 "+" 버튼 위에 호버하면 `updateHoveredTab`이 "+" zone을 제외하지 않아 `tabIndexInBar`의 우측 clamp가 **마지막 탭**을 반환 → 렌더가 그 탭에 ✕를 그렸다(클릭은 "+"가 먼저 먹어 무해하나 시각 오표시). **(구조)** `cols → paneTabAreaCols → paneTabWidth` + 픽셀↔컬럼 변환이 `tabIndexInBar`·`xInTabCloseZone`·`xInPlusZone`·`paneTabHighlightCell` 4곳에 복제돼 있던 걸 단일 `BarMetrics{cols, tab_cols, tab_w}` 구조로 통합한다(`init(bar, cw, term_count) ?BarMetrics` 한 번 + 순수 메서드 `tabIndex`/`inCloseZone`/`inPlusZone`/`hasPlusZone`/`highlightCell`). 4개 순수 함수를 메서드로 대체하고, 호출처(mouse down(1)·dragTabTo·dropTabAt·render 하이라이트·updateHoveredTab)가 `BarMetrics`를 한 번 만들어 재사용 — "보이는 탭/✕/+ == 클릭·호버되는 것"을 한 곳에서 보장한다. sentinel-UV chrome 셀 보일러플레이트도 `sentinelBgCell` 헬퍼로 모음(`paneBarBgCell`·`highlightCell` 공유). 수정: `updateHoveredTab`이 `inPlusZone`을 **먼저** 검사해 "+" 위면 호버 탭을 안 잡는다. 검증: 헤드리스(`BarMetrics` init/tabIndex/inCloseZone/inPlusZone/highlightCell + `pointInRect`) + macOS 통합(**"+" 호버 → hovered_tab null**, 마지막 탭 호버 → 탭 1) + 전체 테스트 통과 + swift/abi/boundaries/coretext·metal·pty 스모크. ABI 무변경(25). 단일 파일(app_session) refactor라 동작 불변(버그 수정분 제외).
- **split PR6 완료(divider 렌더 + 드래그 리사이즈)**: 두 panel 사이 경계에 divider 선을 그리고 끌어서 비율(`split.ratio`, 지금까지 0.5 고정)을 조절한다. **layout은 안 바꾼다**(틈 없이 abut — split_tree 주석 "divider 간격은 렌더 단계의 후속"대로): `split_tree`에 `layoutDividers`(generic)가 각 split 노드의 `DividerSeg{split: *Split, direction, bounds(부모 영역), pos(경계 픽셀)}`를 layout과 같은 분할 규칙·순서로 emit하고, `clampRatio`/`ratio_min`/`ratio_max`를 노출해 layout(ratioPx)과 드래그가 같은 한도를 쓴다(app.zig 재노출). **렌더**: divider는 seam(경계) 중심에 cell 1칸 두께 overlay 셀로 그린다 — chrome(맨 아래, 터미널에 가림)이 아니라 `metal_frame.replace`의 새 `pane_overlay_cells`로 넘겨 **터미널 frame 뒤·활성 panel 커서 suffix 앞**에 insert(터미널 위에 보이되 커서 blink 노출 길이 안 깨짐). horizontal split=세로선(경계 x, 행마다 셀), vertical split=가로선(경계 y, bounds 폭 셀). 색은 `sidebarActiveBg`. **hit-test/드래그**: 순수 `dividerHit(seg, cw, ch, x, y)`(경계 pos ± cell 절반+2px, 교차축 bounds 안)으로 `dividerAtPoint`가 seg를 찾고, mouse down(1)이 그 split을 `divider_drag`에 잡는다 — **탭 바(①) 다음·pane 선택(②) 앞** 순서라 seam에 붙은 탭 바 클릭을 안 가로챈다. drag(2)는 mouse 최상단 캡처가 `dragDividerTo`로 `ratio = (mouse - bounds.origin)/bounds.size`(clampRatio)를 매핑→`resizeActiveTabPanes`+`recomputeActivePaneRect`로 live 재배치, up(3)이 끝낸다. 구조 변경(collapsePaneIn·closeTab이 split 노드 해제) 시 `divider_drag`를 null로 비워 dangling 방지(hovered_tab과 같은 stale 정리 패턴). 검증: 헤드리스(`layoutDividers` 단일/중첩/leaf·pos·bounds, `clampRatio` 한도, 순수 `dividerHit` 밴드/교차축/cell 0·비유한) + macOS 통합(좌우 split → divider down→drag(좌 200px)→ratio 0.25·활성 pane 폭 증가→up→divider_drag null, 비-divider 클릭은 드래그 미시작) + 전체 테스트 통과 + swift/abi/boundaries/coretext·metal·pty 스모크. **ABI 무변경**(25 — overlay 셀도 origin 박은 `maru_fill_cell_quad` 경로). 이로써 8단계 split 토대(SplitTree~divider)가 닫힌다(divider 굵기·hover 커서는 후속 항목에서 보강).
- **split PR6 후속 완료(divider 얇은 선 — 굵기/가림 수정)**: 사용자 제보("탭 경계선 너무 굵다 + 터미널 레이아웃이 가려짐") 대응. PR6은 divider를 full-cell(세로 cell_width≈8px·가로 cell_height≈16px) overlay로 그려 터미널 내용을 가렸다. 렌더러 `maru_fill_cell_quad`가 **이미 가진** 부분 사각형(커서 DECSCUSR용: `reserved=3` bar=cell 좌측 ~2px, `reserved=2` underline=cell 하단 ~2px)을 재사용해 divider를 **얇은 선**으로 바꾼다 — `appendActiveTabDividers`가 horizontal split=세로선이면 행마다 `reserved=3`(경계 x에 −1 센터), vertical split=가로선이면 `reserved=2` 한 칸(폭=cols, 경계 y에 센터). 굵기 8/16px → ~2px, 가림 최소(2px 오버레이). ABI/layout/hit-test 무변경(같은 overlay 셀 경로, `reserved`만 세팅). 검증: 헤드리스(좌우 split 셀 전부 reserved=3·width 1·경계 x 센터, 상하 split reserved=2·폭>1) + 전체 테스트/스모크.
- **호버 커서 모양 완료(영역별 NSCursor, ABI 26)**: 사용자 제보("호버 시 드래그/클릭 가능한 형태로 커서가 바뀌어야 하는데 다 I-beam") 대응. 지금까지 hover ABI는 URL 여부(`out_is_url`)만 줘 Swift가 URL이면 pointingHand·아니면 **무조건 iBeam**이라 사이드바·탭 바·divider까지 전부 I-beam이었다. hover ABI out을 **`CursorKind`**(0=arrow, 1=iBeam, 2=pointingHand, 3=resizeLeftRight, 4=resizeUpDown)로 일반화하고(`out_is_url`→`out_cursor_kind`, **abi_version 25→26**), Zig가 위치를 판정한다(`hoverUrl`→`hoverCursor`): 클릭과 같은 우선순위(사이드바→탭 바→divider→터미널)로 **사이드바·탭 바=arrow, divider=resize(좌우 split=↔ resize_h, 상하 split=↕ resize_v), 터미널=iBeam, Cmd+hover URL=pointingHand**. divider 판정은 클릭과 같은 `dividerAtPoint`라 "보이는 = 호버 커서". Swift는 `cursor(for:)`로 `CursorKind`→`NSCursor` 매핑만(native 최소). 검증: 헤드리스(`hoverCursor` 영역별 반환 — 터미널 text·탭 바/사이드바 default·좌우 divider resize_h·상하 divider resize_v) + 전체 테스트/스모크 + ABI 계약(헤더 26 일치). 한계: 드래그 중(mouseDragged)엔 직전 hover 커서가 유지된다(macOS 기본). 다음 사용자 요청: 사이드바 폭 조절·"+"·split pane 드래그 재배치.
- **③a 사이드바 폭 조절 완료(우측 경계 드래그)**: 사용자 요청("왼쪽 사이드탭도 크기 조절 가능해야 함") 대응. 사이드바 우측 경계를 드래그해 폭을 바꾼다(divider 드래그와 같은 패턴). 폭은 **pt로 저장**(`sidebar_width_pt` 필드, 기본 `default_sidebar_width_pt=180`, [`sidebar_min_pt`=120, `sidebar_max_pt`=480]) — `refreshCellMetrics`가 `sidebar_width_px = sidebar_width_pt × scale/1000`로 파생해 **DPI 변경에도 사용자 폭이 유지**된다. 순수 `xOnSidebarEdge(x, width, cw)`: 경계에서 **터미널 쪽으로만** `[width, width + cell/2+2)` — 사이드바 슬롯/✕(우측)와 안 겹친다(✕가 사이드바 우측에 있어, 경계 안쪽으로 넣으면 충돌). `mouse` down(1)이 경계 밴드면 `sidebar_resize_active`로 잡고(사이드바 슬롯·터미널보다 먼저), 최상단 캡처의 drag(2)가 `setSidebarWidthPx(x)`(px→pt 환산·[min,max] clamp·같은 폭이면 무동작 → SIGWINCH storm 방지·**모든 탭** panel을 새 term 폭으로 resize·`recomputeActivePaneRect`·`rebuildSidebar`), up(3)이 끝낸다. `hoverCursor`가 경계 위면 `resize_h`(↔, ②의 커서 경로 재사용 — 사이드바/터미널보다 먼저). 검증: 헤드리스(순수 `xOnSidebarEdge` 터미널 쪽 밴드·사이드바 안쪽 false·폭 0·비유한) + macOS 통합(경계 호버=resize_h·down→drag(+60)→폭 증가·pt 증가→up, setSidebarWidthPx 극단값 → max/min clamp) + 전체 테스트/스모크. **ABI 무변경**(26 — 새 함수 없이 기존 mouse/hover 경로 재사용). 경계 근처를 클릭하던 탭/사이드바 테스트는 안쪽(+30/+50)으로 옮겨 충돌 회피(밴드가 터미널 쪽이라 슬롯/✕는 무영향). 다음: ③b 사이드바 "+" 버튼.
- **③b 사이드바 "+" 버튼 완료(새 워크스페이스 생성)**: 사용자 요청("사이드바 '+' 버튼으로 워크스페이스 생성") 대응. 사이드바 탭 목록 **바로 아래** 슬롯에 "+" 버튼을 그려, 클릭하면 새 워크스페이스(탭)가 열린다 — ⌘⇧T의 마우스 버전(이제 ⌘⇧T는 "임시"가 아니라 정식 단축키). 렌더: `buildSidebarDrawList`에 `plus_row: ?usize` 추가 — 그 행(= 탭 개수)에 '+' glyph를 가로 중앙에 그리고 `size.rows`를 그만큼 늘려, 렌더러의 행×슬롯 높이 배치가 마지막 탭 슬롯 아래에 놓는다. `buildSidebarTitleFrame`이 `plus_row = tabs.len`을 넘긴다. hit-test: 순수 `sidebarPlusSlot(y, slot_h, tab_count)`(y in `[tab_count×slot_h, (tab_count+1)×slot_h)`) — `mouse` down(1) 사이드바 분기에서 슬롯 hit-test보다 먼저 검사해 `newTab()`(createTab이 활성으로). `hoverCursor`가 "+" 슬롯 위면 `link`(pointingHand) affordance(탭 슬롯은 arrow). 검증: 헤드리스(순수 `sidebarPlusSlot`, `buildSidebarDrawList`가 '+'를 plus_row 중앙에·rows +1·null이면 없음) + macOS 통합("+" 슬롯 호버=link·클릭→탭 2개·새 탭 활성) + 전체 테스트/스모크. **ABI 무변경**(26).
- **"+" 슬롯 hover 밴드 완료(시각 강조)**: 사용자 요청. ③b의 후속 — "+"(새 워크스페이스) 슬롯에 마우스를 올리면 글리프+커서(link)뿐 아니라 **호버 하이라이트 밴드**(탭 슬롯 호버와 동형)를 그려 클릭 가능함을 시각적으로도 보인다. `hovered_plus: bool` 상태 추가(탭 슬롯 `hovered_slot`과 직교 — "+"는 탭 범위 밖이라 `sidebarSlot`이 null) + `setHoveredPlus`(setHoveredSlot 동형, 변경 시 rebuildSidebar+redraw). `hoverCursor`가 사이드바 분기에서 `sidebarPlusSlot` 결과로 `hovered_plus`를 갱신(경계/터미널 분기는 false로). `rebuildSidebar`가 `hovered_plus`면 row=탭 개수(plus_row와 같은 위치)에 기존 `sidebarBandCell`+`sidebarHoverBg()`로 밴드 1개를 더한다. "+" 클릭(newTab) 직후·closeTab(탭 수 변경) 때 `hovered_plus`를 비워 "+"가 행 이동 시 밴드가 엉뚱한 행에 남지 않게(다음 이동이 재설정). 검증: 헤드리스 macOS 게이트("+" 슬롯 호버=link·hovered_plus·밴드 2개[활성+"+"]·밴드 row=탭 개수, 탭 슬롯으로 이동 시 hovered_plus 해제) + 전체 테스트/스모크. **ABI 무변경**(27, 순수 chrome 셀 추가).
- **④ split pane 드래그 재배치 완료(Term 탭 → pane 본문 drop-zone)**: 사용자 요청("나눈 탭도 드래그로 위치 변경") 대응. 사용자가 고른 방식 — **Term 탭을 다른 pane '본문'의 상/하/좌/우 절반(drop zone)에 드롭하면 거기에 새 split이 생긴다**(PR-E2 cross-pane 이동의 본문 버전). 단일 Term pane이면 소스가 비어 collapse돼 사실상 pane이 그 자리로 이동·재배치된다. 순수 `paneDropZone(rect, x, y)`: rect를 중앙에서 X자 4등분해 가장 가까운 가장자리(left/right/top/bottom). `dropTabAt`(up)이 탭 바 hit-test(→ `moveTermToPane`, PR-E2) 다음에 **본문 drop-zone**을 보고 `moveTermToNewSplit(src, idx, target, zone)`을 부른다: left/right=좌우(horizontal)·top/bottom=상하(vertical), left/top은 새 pane이 앞(a). 구현은 **모든 alloc(빈 새 pane·terms capacity·panes append·Split 노드)을 먼저** 해 실패 시 트리/terms를 안 건드리고(Term은 src에 남음), 그 뒤 infallible하게 src에서 Term을 빼 새 pane으로 옮기고 `replaceLeaf(target → split{...})`로 트리를 바꾼다. Term은 heap-pin이라 pane 사이 포인터 이동에도 surface/reader가 안 움직인다. src가 비면 `collapsePaneIn`, 새 pane으로 포커스·전 panel resize·좌표 재계산. `target==src`인데 src Term 1개뿐이면 무동작(자기를 자기로 split 무의미). 검증: 헤드리스(순수 `paneDropZone` 4방향·밖·0크기·비유한) + macOS 통합(좌우 split → 우 pane 탭을 좌 pane 본문 좌측 절반에 drop → 우 collapse·새 split 좌우·옮긴 Term이 새(활성) pane·가장 왼쪽·leafCount 2) + 전체 테스트/스모크. **ABI 무변경**(26 — 기존 tab-drag/`replaceLeaf` 재사용). drop-zone 시각 하이라이트는 ④b에서 더한다.
- **④b drop-zone 하이라이트 완료(드래그 중 타겟 zone 반투명 강조)**: 탭 드래그 중 마우스가 올라간 **드롭 타겟 zone**을 반투명으로 칠해 "어디에 떨어질지"를 미리 보인다. `DropTarget{pane, zone}`(zone null=탭 바=이동, set=본문 절반=그 방향 split) + 필드 `tab_drop_target`. drag(2)가 `computeDropTarget`(dropTabAt와 같은 우선순위 hit-test)로 `setDropTarget`(바뀔 때만 metal_dirty), up/취소가 null. 렌더 `appendDropTargetHighlight`가 타겟 zone(`halfRect`로 자른 절반, 또는 바)을 행마다 폭만큼 sentinel-bg 셀로 칠한다 — **`premultipliedRgba`로 미리 곱한 반투명**(sidebarActiveBg, alpha≈0x55) 색이라 셰이더의 premultiplied-alpha over로 터미널이 비쳐 보인다. divider와 같은 overlay 레이어(터미널 위·커서 아래), divider보다 먼저 넣어 그 아래. 검증: 헤드리스(순수 `halfRect` 4방향·`premultipliedRgba` alpha 곱) + macOS 통합(좌우 split → 우 탭 down→drag로 좌 본문 상단 절반 → `tab_drop_target={좌,top}`·하이라이트 셀 emit(alpha 0x55·reserved 0)→drag로 좌 바 → `{좌,null}`→up → null·하이라이트 0개) + 전체 테스트/스모크. **ABI 무변경**(26).
- **floating 탭 미리보기 완료(드래그 중 끌리는 탭이 커서를 따라감)**: 사용자 요청. 탭 드래그 중 끌리는 Term의 제목을 담은 작은 '탭'(박스+제목)을 **커서 위치**에 그려, 무엇을 끌고 있는지 보인다(④b 드롭 타겟 하이라이트와 짝). `coretext_frame_builder.buildFloatingTabDrawList(title, cols, fg, bg)`: 한 행 박스 — col마다 셀 하나(중복 없음)에 `bg`를 줘 솔리드 박스로, 1칸 좌패딩 뒤에 제목(cols 한도 자름). drag(2)가 `tab_drag_x/y`(마우스 위치)를 갱신하고 매 이동 `metal_dirty`(ghost가 따라가게). 렌더 `buildFloatingTabFrame`이 끌리는 Term(`tab_drag_pane.terms[tab_drag_index]`) 제목으로 frame을 만들어 **활성 터미널·커서보다 뒤(맨 위 frame)**에 넣는다 — 커서 중심에 박스(폭 [8,24] cols, 활성 강조색 bg). 검증: 헤드리스(`buildFloatingTabDrawList`가 col마다 bg 셀·제목·자름) + macOS 통합(드래그 전 null → 탭 down·drag로 `tab_drag_x/y` 갱신·frame non-null·박스가 커서 좌측 센터 → up → null) + 전체 테스트/스모크. **ABI 무변경**(26 — 기존 PaneFrame 경로 재사용). 한계: floating 탭이 맨 위 frame이라 그 frame의 cursor suffix가 0 → 드래그 중 커서 blink 최적화만 꺼진다(커서는 그대로 그려짐, transient).
- **긴 제목 말줄임 완료(하드 컷 → "…")**: 사용자 요청. 칸을 넘치는 제목을 그냥 잘라내던 걸 마지막 칸에 **"…"(U+2026)**를 둬 잘렸음을 표시한다. 사이드바 제목·pane 탭 바 제목이 각자 하던 디코드/잘림 루프를 공유 `appendEllipsizedTitle(cells, title, row, start_col, end_col, style)`로 통합(단일 출처라 잘림 규칙 일관) — `titleDisplayWidth`(현 `text_layout.displayCols`)로 안 들어가는지 먼저 재고, 안 들어가면 `end_col-1`까지만 글자를 깔고 마지막 칸에 `title_ellipsis_glyph`(현 `text_layout.ellipsis_glyph`). 딱 맞으면 "…" 없음. pane 탭 바는 호버 ✕가 있으면 `title_end`(✕ 앞)를 한도로 줘 ✕와 안 겹친다. 검증: 헤드리스(긴 제목 → 마지막 셀 U+2026·앞은 글자, 딱 맞으면 없음, pane 탭 바 세그먼트 한도에서 …; 기존 truncate 테스트는 셀 수 동일이라 그대로 통과) + 전체 테스트/스모크. **ABI 무변경**(26).
- **floating 탭 말줄임 완료(드래그 ghost 하드 컷 → "…")**: 사용자 요청. 드래그 중 커서를 따라다니는 floating 탭(미리보기 박스)의 제목 폭이 `clamp(title.len+2, 8, 24)`라 **24칸 캡**에서 긴 제목이 하드 컷됐다 — 이제 사이드바·pane 탭 바와 같은 공유 규칙으로 마지막 칸을 **"…"**로 말줄임한다. `appendEllipsizedTitle`이 **다음 빈 col**(제목/말줄임 뒤)을 반환하게 해(기존 2개 호출처는 `_ =`로 무시), floating 빌더가 자체 디코드/잘림 루프를 버리고 그 헬퍼로 제목을 깐 뒤 **반환 col부터 박스 끝까지만 bg로 채운다**(솔리드 박스 유지, col당 1셀 — 중복 없음). 잘림 규칙이 세 곳(사이드바·pane 탭 바·floating) 단일 출처로 합쳐졌다. 검증: 헤드리스(긴 제목 → 우측 끝 셀 U+2026·박스 bg 유지, 딱 맞는 제목은 "…" 없이 박스 채움; 기존 "sh"/narrow 셀 수 동일) + 전체 테스트/스모크. **ABI 무변경**(27).
- **활성 탭 글자 강조 완료(비활성 muted · 활성 full)**: 사용자 요청. 지금까지 모든 탭 제목이 같은 색(theme.foreground)이고 활성 탭은 배경 밴드로만 구분됐다. **비활성 탭 글자를 muted(흐림), 활성 탭은 full foreground**로 그려 대비로 도드라지게 한다. `mutedForeground()` = `theme.foreground`를 `background` 쪽으로 45% 섞은 흐린 색(사이드바·pane 탭 바 공유). `buildSidebarDrawList`에 `active_row`/`active_fg` 추가 — 활성 워크스페이스(=`app_window.active_tab`) 행만 active_fg(full), 나머지 muted. `buildPaneTabBarDrawList`에 `active_tab`/`active_fg` 추가 — **각 pane**의 활성 Term(`active_term`) 탭만 full, 나머지 muted(pane이 활성이든 비활성이든 자기 현재 Term을 밝게). 색 선택만 바뀌고 레이아웃/말줄임은 그대로(같은 `appendEllipsizedTitle`, per-행/탭 style만 다름). 검증: 헤드리스(active_row/active_tab의 셀만 active_fg·나머지 fg) + 전체 테스트/스모크(기존 test 호출처는 `active=null,.default`로 무강조 = 기존 동작). **ABI 무변경**(26).
- **사이드바 글자색 테마화 완료(`sidebar_foreground`)**: 사용자 요청. 사이드바·pane 탭 바 제목 글자색을 config로 정할 수 있게 한다. `ThemeConfig.sidebar_foreground: ?[]const u8`(선택 #RRGGBB) + resolved `ResolvedTheme.sidebar_foreground: color.Rgb` — `resolveTheme`가 명시하면 그 색, 없으면 **`foreground`(터미널 글자색)와 같게**(기존 동작 보존). 렌더의 활성 탭 글자 = `theme.sidebar_foreground`(full), 비활성 = `mutedForeground()`(이제 `sidebar_foreground`를 background 쪽으로 45% 섞음). 색 파생/검증은 resolveTheme 단일 출처(sidebar_background/active와 같은 패턴, 깨진 색은 여기서 막힘). 검증: 헤드리스(resolver 기본=foreground·명시 override·깨진 색 에러) + 전체 테스트/스모크. **ABI 무변경**(26).
- **⌘1~9 워크스페이스 번호 단축키 완료**: 사용자 요청("⌘1, ⌘2로 왼쪽 탭 전환"). `select_tab` 액션·dispatch(`switchTab`)는 이미 있었지만 **기본 바인딩이 없어** config로만 묶을 수 있었다 — `default_app_bindings`에 ⌘1~9 → `select_tab(N-1)` 9개를 추가했다(Safari/Terminal.app/iTerm2식). 범위 밖(탭보다 큰 번호)은 `switchTab`이 no-op. 숫자 키는 normalizeEventChar가 안 fold하고 Swift가 char로 그대로 줘 매칭, 모디파이어 정확 비교(⌘만, shift/option 아님). 검증: 헤드리스(resolver Cmd+1~9 → select_tab(i)) + macOS 통합(워크스페이스 3개 → ⌘1/⌘3/⌘2 전환·⌘9 범위 밖 no-op) + 전체 테스트/스모크. **ABI 무변경**(26).
- **비활성 panel 위 마우스 휠 라우팅 완료(ABI 27)**: 사용자 요청. split에서 휠 스크롤이 **커서 아래 panel**로 가게 한다(지금까지 활성 panel로만). scroll-wheel ABI에 마우스 위치(`x_px`/`y_px`)를 추가(`abi_version 26→27`, 헤더 동기화). Swift `handleScroll`이 `mouseMoved`처럼 backing px를 환산해 넘긴다(scrollWheel override가 view를 전달). Zig `scrollWheel(delta_y, precise, x, y)`: `surfaceAt(x, y)`(활성 탭 leaf rect를 펴 `paneAtPoint` → 그 pane의 활성 Term surface, 사이드바/밖이면 null)로 타겟을 고르고 없으면 활성 fallback. `scrollLines`를 `scrollSurfaceLines(surface, lines)`로 일반화(키보드 PageUp/Down은 활성 surface로 위임) — alt-screen+alternate_scroll이면 그 surface PTY로 화살표, 아니면 그 surface 뷰포트 스크롤. **포커스는 안 바꾼다**(hover-scroll). 검증: macOS 통합(좌우 split, 양쪽 100줄 스크롤백 → 왼쪽(비활성) 위 휠 → 왼쪽 view_offset만 증가·오른쪽 0·active_pane 불변 → 오른쪽 위 휠 → 오른쪽 view_offset 증가) + 전체 테스트/스모크 + ABI 계약(27). **단일 panel/사이드바/밖이면 기존 동작**(활성).
- **pane Term 탭 제목 번호 prefix 완료**: 사용자 요청. per-pane 탭 바의 Term 탭 제목을 사이드바 워크스페이스처럼 **"{n} {title}"**(1-based)로 표시한다(지금까지 제목만). 사이드바와 pane이 각자 하던 `allocPrint("{d} {s}", …)`를 공유 `tabNumberLabel(allocator, index, title)`로 묶어 번호 prefix 형식을 단일 출처로(둘 다 1부터). 렌더 루프가 Term마다 라벨을 만들어 `buildPaneTabBarDrawList`에 넘기고(말줄임은 `appendEllipsizedTitle`가 처리) defer로 해제. 검증: 헤드리스(`tabNumberLabel`이 "1 sh"/"5 vim") + 전체 테스트/스모크. **ABI 무변경**(27). **(이후 U-tab2에서 되돌림 — pane Term 탭 제목의 번호 prefix는 제거됐다(브라우저/VSCode/Warp식 제목만; `tabNumberLabel`·`numberPrefixCols` 폐기). 단일 출처: [chrome-strategy.md](chrome-strategy.md) U-tab2.)**
- **U-tab2 완료(탭 연결형 cutout + 앰버 언더바 · 번호 prefix 제거)**: 사용자 요청("탭이 TUI처럼 흐릿, 모던하게"). rich 활성 탭을 strip(`sidebarBg`)에서 도려낸 듯한 **터미널 본문색(`theme.background`) cutout**으로 바꿔 아래 본문과 이어져 보이게 한다(깊이: strip↔본문). **포커스 구분은 배경이 아니라 하단 언더바 색으로 일원화** — 포커스 pane=maru 앰버(`accent_bar`), 비포커스=`muted_fg`(모든 활성 탭 배경은 본문색 통일). 언더바 두께는 탭바 하단 하이라인(`line_thickness_px`)과 분리한 전용 토큰 **`tab_underbar_px`**(rich 3px, 하이라인보다 굵게)로 또렷하게. 본문색 cutout quad가 layer 2에서 활성 탭 구간 하이라인을 덮어 '연결'이 끊기지 않는다(`appendActiveTabHighlight` 단일 출처). 또 Term 탭 제목의 **번호 prefix(`N `)를 제거**(브라우저/VSCode/Warp식 — Term 번호는 단축키에 매핑되지 않아 시각 군더더기였다; `tabNumberLabel`·`numberPrefixCols` 폐기, rename in-place caret prefix 0). **tui 룩(셀 밴드 + `sidebarActiveBg`/`HoverBg`)은 보존**(cutout/언더바는 rich 경로 `tab_corner > 0`에서만). 검증: 헤드리스 회귀 2건 — rich cutout(세로 분할 후 layer-2 `gpu_quads`에서 본문색·앰버(포커스)·muted(비포커스) quad 방출 + cutout≠옛 `sidebarActiveBg` 고정) · 번호 prefix 부재(단일 Term rename caret이 `tabs.x + cw` — 번호였다면 `+3·cw`) + `mise run check` 전부 green. **ABI 무변경**. 단일 출처: [chrome-strategy.md](chrome-strategy.md) U-tab2 · [탭·split·레이아웃 전략](tabs-splits-layout.md). 후속: pill·underline 탭 스타일을 `chrome.tab-style` 직교 축으로 노출(아래 **탭 스타일 축** 플랜).
- **탭 스타일 축(`chrome.tab-style`) — TS1·TS2 완료(U-tab2 후속)**: U-tab2의 connected(본문색 cutout + 앰버 언더바)를 **강한 기본**으로 두고, `chrome.tab-style = connected|underline|pill` **직교 축**을 추가해 사용자가 활성 탭 룩을 고른다. **TS1**=connected·underline(언더바만), **TS2**=pill(실제 Warp 벤치마킹 — strip보다 밝은 lifted 회색 fill로 채운 둥근 캡슐 + 옅은 밝은 테두리, 포커스=fill 밝기). 스타일은 `appendActiveTabHighlight`의 세그먼트 안 fill만 바꾸고 탭 세그먼트 기하(`tabbar.segOf`)는 불변 → hit-test/드래그/✕/‹›는 그대로. 검증: 헤드리스 — 스타일별 `gpu_quads`(underline=cutout 없이 언더바만 · pill=둥근 corner_radii>0 + lifted(sidebarActiveBg) fill·cutout 없음) + config→토큰 매핑; `MARU_CONFIG`로 underline·pill 실물 캡처 확인 + `mise run check` green. **ABI 무변경**. **TS3**=`chrome.preset`(여러 축 묶음 레이아웃 프리셋) 후속. `chrome.theme`(룩 tui\|rich)·`theme.preset`(색)과 **직교**로 공존(메가 enum 금지 — 조합 폭발 회피). 설계 단일 출처는 [chrome-strategy.md](chrome-strategy.md) **§7(탭 스타일 축)**. 요지: ① chrome `Spacing`에 `tab_active_style` enum 토큰 추가(neutral), platform `buildChromeTokens`가 `appearance.chrome_tab_style`→토큰으로 매핑. ② `appendActiveTabHighlight`가 스타일로 분기(connected=cutout+언더바 / underline=언더바만(bg fill 없음) / pill=둥근 inset quad). **탭 세그먼트 기하(`segOf`/`tab_width_cols`)는 세 스타일 불변** → hit-test(`tabbar.Metrics`)·드래그·✕·‹›는 그대로(§5.4 정합 유지, 스타일은 세그먼트 *안의 fill*만 바꿈). ③ config `chrome.tab-style`은 `chrome.theme`처럼 `Config.schema`+`Meta{.widget=.dropdown,.section=.theme}`(CS-2b 패턴)라 **세팅 GUI 드롭다운 자동**, `configuration.md` 키 표에 행 추가(CS-3 drift 가드). ABI 무변경(Zig 렌더가 소유). 검증: 헤드리스(스타일별 `gpu_quads` 방출 — connected=cutout+언더바·underline=언더바만·pill=둥근 quad). 더 가면 여러 축을 묶은 `chrome.preset`(레이아웃 프리셋, `theme.preset` 동형)으로 큐레이션.
- **상단 탭바 Warp 폴리시 1단계 완료(바 높이; grip은 항상 표시 — 피드백 반영)**: 사용자 요청("상단 탭부터 Warp 벤치마킹"). Warp 제품 스크린샷을 직접 보고(룩만, clean-room) maru pane 탭바를 다듬는다. (a) **바 세로 패딩** `tab_bar_pad_y_px` rich 6→**8px**(Warp식 넉넉한 바 높이). (b) grip ⠿를 처음엔 Warp식 **hover-only**로 숨겼으나, **사용자 피드백으로 항상 표시로 되돌렸다** — pane→워크스페이스 분리 드래그는 Warp에 없는 maru 기능이라 손잡이를 늘 보여야 발견성이 유지된다(Warp는 grip 없는 모델이라 부적합). hover-only용 `last_mouse_x/y`·`pointInRect` 게이트·전용 테스트는 제거. 검증: connected/underline/pill 실물 캡처(grip 보임·바 높아짐) + `mise run check` green. **ABI 무변경**. 단일 출처: [탭·split·레이아웃 전략](tabs-splits-layout.md) 드래그 손잡이 절.
- **탭 스타일 기본값 underline로 변경(사용자 요청)**: `chrome.tab-style` 기본을 connected → **underline**(미니멀 — 언더바만)으로 바꿨다(`Config.chrome_tab_style`·`appearance.chrome_tab_style` 기본값). connected(본문색 cutout)·pill(Warp lifted 캡슐)은 그대로 선택 가능. `configuration.md` 기본값 열·U-tab2 cutout 테스트(이제 `chrome_tab_style=.connected` 명시)도 갱신. **ABI 무변경**.
- **모달 그림자 옅게(사용자 피드백 "너무 크고 짙어요")**: rich 모달 `GpuShadow` 토큰을 줄였다 — `shadow_blur_px` 14→9, `shadow_offset_y_px` 6→4, `shadow_alpha` 0x70(≈44%)→0x38(≈22%). 모달이 은은히 떠 보이되 무겁지 않게. `chrome/tokens.zig` `Tokens.rich`만 변경(컴포넌트·lowering 불변), 세팅 모달 실물 캡처로 옅어짐 확인. **ABI 무변경**.
- **TS3 완료(`chrome.preset` 묶음 레이아웃 프리셋)**: 여러 chrome 축(룩 `chrome.theme` + 탭 `chrome.tab-style`)을 한 노브로 묶은 큐레이션 — `theme.preset`이 색 세트에 쓰는 패턴 동형. `theme.ChromePreset` enum(`minimal`=rich+underline·`cutout`=rich+connected·`capsule`=rich+pill[Warp]·`cell`=tui) + `chromePresetValues()` 단일 출처 + **loader-special 키**(`chrome.preset` — `theme.preset`과 같은 자리에서 두 축을 깔고, 개별 `chrome.theme`/`chrome.tab-style`가 그 *뒤* 줄에서 그 축만 override; 미지값 forgiving + diagnostic). 메가 enum 금지 — 묶음일 뿐 직교 축은 그대로(색 `theme.preset`과도 직교). 검증: 헤드리스(loader가 capsule→rich+pill·뒤따르는 chrome.tab-style=underline가 tab만 override·cell→tui·미지값 기본 유지+diag) + `mise run check` green. `configuration.md` 행 추가. **ABI 무변경**. **code-review high 후속**: `cell`이 `chrome_tab_style`을 임의값(underline)으로 덮어 앞서 둔 `chrome.tab-style=pill`을 조용히 리셋하던 함정 수정 — `ChromePresetValues.chrome_tab_style`을 `?ChromeTabStyle`로(cell=null=축 안 건드림, loader가 `if (v.chrome_tab_style) |ts|`로 제어 축만 적용). + loader stale 인벤토리 주석에 `parseChromePreset` 추가. **Chrome 전용 전환:** 세팅 GUI와 검색에는 `chrome.theme` 또는 `chrome.preset = cell`을 새로 선택·변경하는 진입점을 두지 않는다. 기존 파일의 `tui`/`cell`은 자동 변경 없이 읽기 호환과 회귀 fixture에만 남기며, parser/lowering 제거와 migration은 별도 결정 전까지 하지 않는다. 단일 출처: [Chrome 전략](chrome-strategy.md#chrome-전용-전환-정책).
- **에이전트 아이콘 볼드화(사용자 피드백 — 클로드 인지 어려움)**: 사이드바 gutter의 claude 아이콘(합성 sparkle `0xF0007`)이 코덱스 diamond(`0xF0008`)에 비해 작고 흐려 "동작 중인지/클로드인지" 한눈에 안 들어온다는 피드백. sparkle가 **얇은 4갈래 별**(coverage 잉크 ≈157k)이라 **솔리드 볼록 diamond**(≈226k)보다 mass가 적은 게 원인. `assets/icons/sparkle.svg`를 **두꺼운 4갈래 별**(arms를 두껍게, R_in↑)로 바꾸고 `tools/svg_to_coverage.py`로 `icon_coverage_data.zig` 재생성 → 잉크 ≈236k(diamond와 동등). 브랜드(스파클)·구분(모양+색 coral/teal)·gscale 1.1× 불변. 솔리드 아이콘이라 running 펄스(`dimRgb` 밝기 변조)도 더 또렷. 검증: old/new/diamond coverage 렌더 비교(잉크 parity) + 전체 테스트. **ABI 무변경**(커밋된 coverage 데이터만). 단일 출처: [tabs-splits-layout.md](tabs-splits-layout.md) 에이전트 아이콘 절.
- **에이전트 running 스피너 + 색상(사용자 피드백 — 작업 중 표시·색)**: 옛 running 표시는 아이콘 밝기 펄스(`dimRgb`, `blink_visible` 500ms)뿐이라 작은 아이콘에서 "작업 중인지" 안 보였다(피드백: "동작 점이 너무 작다"·"진행중에 색 표현"). (a) **상태줄 스피너**: `● 진행중` → **`⠋ 진행중`** 회전 브라유(8프레임 ⠋⠙⠹⠸⠼⠴⠦⠧). `agent_spin_frame`을 running일 때 약 133ms마다 +1·사이드바 재투영. (b) **스피너 브랜드색**: 색칠 루프가 아이콘(✶/◆)과 같은 패턴으로 braille codepoint도 브랜드색(코랄/청록)으로 → "진행중"에 색. (c) **아이콘 펄스 폐기 → 솔리드**: 아이콘은 항상 솔리드 브랜드색(큰 별/다이아로 종류·presence), 작업 애니메이션은 스피너가 담당. 검증: 전체 테스트(`agent_spinner_frames`/`isAgentSpinnerCp` + advance 위상) + `mise run check`. **ABI 무변경**. 라이브 에이전트 렌더는 앱 수동(claude/codex 실행). 단일 출처: [agent-session.md](agent-session.md) · [tabs-splits-layout.md](tabs-splits-layout.md).
- **running 스피너 브라유 → codex식 이퀄라이저 파형(사용자 피드백)**: 옛 running 스피너는 회전 브라유(`⠋⠙⠹⠸⠼⠴⠦⠧`)였는데 "작은 점 왔다갔다 말고 codex 스피너처럼"이라는 피드백. 실측(codex v0.142.4 바이너리 strings)으로 확인한 사실: codex의 **인라인 글리프 스피너 자체는 같은 브라유**(10프레임)이고, 눈에 띄는 애니메이션은 **블록 문자 이퀄라이저/파형**(폭 20칸+)이다. 그래서 그 파형을 좁은 사이드바 카드 폭에 맞춰 **4칸 바운싱 바로 축소**한다. (a) `agent_spinner_frames`(브라유) → `spinner_wave`(삼각 파형 1~8, 주기 14) + `spinner_bar_phase=[0,4,8,12]` + `spinnerBarCp(frame,bar)`가 블록 codepoint(`▁~█`, U+2581~2588 = `renderer/block_glyph.zig` 절차 합성)를 돌려준다. `agentStatusLine` running 분기가 4칸을 이어 붙여 `▁▅▇▃ 진행중`. (b) `isAgentSpinnerCp`는 이제 블록 범위(U+2581~2588)를 본다 — 색칠 루프는 그대로 상태줄 row로 좁혀 브랜드색(코랄/청록). (c) `agent_spin_frame` advance를 `+%=1` → `%14`(파형 길이)로 wrap해 u8 경계(256%14≠0)에서 파형이 튀지 않게. 검증: 단위 테스트(`spinnerBarCp` 전 프레임이 블록 글리프·위상차로 파도·프레임0=승인 모양 `▁▅▇▃`·`isAgentSpinnerCp` 블록 게이트) + `test-macos-app-host-abi` 324 pass + `macos-app-build`. **ABI 무변경**. 라이브 에이전트 렌더는 앱 수동(claude/codex 실행 — 헤드리스 running-카드 시드 훅 없음). **`/code-review high` 후속**: (1) 넓힌 블록 게이트가 상태줄의 일반 블록 문자까지 브랜드색으로 칠할 수 있던 오염 → 색칠을 **running일 때만**으로 좁힘(아이콘은 상태 무관). (2) `spinner_bar_count`를 `spinner_bar_phase.len`에서 파생 + `spinner_block_base`(U+2580) 공유 + 게이트 상한 `comptime max(spinner_wave)` 파생(단일 출처, emit↔게이트·count↔phase 어긋남·OOB 방지). (3) 위상 주석 과장(`고르게 분산`·`인접 바 안 뭉침`) 및 stale `braille`·`회전` 주석 정정. **수용된 트레이드오프(폭)**: running 상태줄 1칸→4칸이라 아주 좁은 사이드바(~12–14칸)에선 `진행중` 라벨이 끝에서 말줄임될 수 있으나(옛 1칸은 붙었음), 기본 폭엔 무영향인 엣지라 사용자 결정으로 4칸 유지(단일 출처 [agent-session.md](agent-session.md) "트레이드오프(폭)"). 단일 출처: [agent-session.md](agent-session.md) · [tabs-splits-layout.md](tabs-splits-layout.md).
- **스피너 범위 확장(워크스페이스 단위) + 상단 탭바 파형(사용자 요청)**: 옛 카드 스피너는 **활성 Term**만 봐서, 에이전트를 백그라운드 pane/split·비활성 가로탭에서 돌리면 사이드바 카드에 아무것도 안 떴다(사용자: "커스텀 이름일 때 텍스트가 안 나온다"의 실제 원인). 그리고 상단 탭바엔 running 표시가 아예 없었다("여기도 바꿔달라"). (a) **탭 단위 판정**: `paneHasRunningAgent`/`tabHasRunningAgent`(기존 `*HasRunningJob` 미러) + `tabAgentKind`/`paneAgentKind`(running Term 우선, 없으면 활성 폴백). 카드 상태줄은 `workspaceStatusLine`(탭 단위 — 어느 Term이든 running이면 파형, 아니면 활성 Term의 idle/none 폴백), gutter 아이콘·색칠 루프도 `tabAgentKind`로. (b) **탭바**: pane 라벨·running Term 탭 앞에 `spinnerPrefixedLabel`로 `▁▅▇▃ ` prefix + `recolorSpinnerCells`로 바 셀을 브랜드색(pane 대표 kind) — 사이드바 색칠 루프와 달리 그 draw list 셀을 직접 재색칠. rename 편집 중엔 prefix 없음. (c) **위상 게이트** `anyAgentRunning`: 탭바 스피너는 접힘·필터 무관하게 활성 워크스페이스 상단에 보이므로 **활성 탭 running이면 늘 true**(사이드바 카드는 종전대로 접힘·필터 시 제외). 공용 바 문자열은 `spinnerBarsUtf8`로 단일화(`agentStatusLine`·탭바 공유). 검증: 단위 테스트 + `test-macos-app-host-abi` + `macos-app-build` + `zig fmt`. **ABI 무변경**. 다중 pane/Term에서 백그라운드 Term running 경로·탭바 라이브 렌더는 앱 수동(claude/codex 실행 — 헤드리스 running-카드 시드 훅 없음). 단일 출처: [agent-session.md](agent-session.md) · [tabs-splits-layout.md](tabs-splits-layout.md).
- **`/code-review max` 후속 — 탭바 파형→1칸 플래그 + perf/게이트 정정**: max 리뷰(검증 9건)로 드러난 correctness/perf. (1) **탭바 파형→정적 플래그 ●**: 탭 바가 등폭이라 `▁▅▇▃ `(5칸) prefix가 running pane/Term **이름을 잘랐다**(#1 CONFIRMED). 멀티플렉서 관례(tmux/screen 창-플래그 1글자·zellij/iTerm2 활동 점)를 조사해 **1칸 정적 플래그 `● `**(`flagPrefixedLabel`+`recolorAgentFlagCells`)로 교체 — 폭 부담 최소, 애니메이션 없음. 사이드바 카드는 전용 상태줄이라 애니메이션 파형 유지. (2) **정적 플래그라 위상 게이트 원복**: `anyAgentRunning`을 탭바 포함(활성 탭 running이면 늘 true)에서 **사이드바 카드 전용**으로 되돌림 — chrome_minimal(표시면 없음)에서 130ms 재투영하던 회귀(#2 CONFIRMED, high #1 재발) 해소. (3) **dirty 게이트 확장 `agentDisplayVisible`**: 정적 플래그가 백그라운드 Term에서 제때 뜨도록, `pollAgentKinds`/`pollAgentState`의 `metal_dirty` 게이트를 "활성 Term만"에서 **탭 단위**(보이는 카드 or 활성 탭 탭바)로 확장(over-dirty=안전 방향). (4) **cleanup**: `agentBrandColor`(브랜드색 2곳 통합)·`runningStatusLine`(파형 문자열 2곳 통합)·사이드바 색칠 루프 슬롯당 1회 스캔(옛 셀당 O(panes×terms) 재스캔). **혼재 kind 플래그 색·무관 title-● 재색칠은 드문 트레이드오프로 문서화**(#4·#5). 검증: `flagPrefixedLabel`·`agentDisplayVisible`·`workspaceStatusLine`·`anyAgentRunning`(사이드바 전용) 단위 테스트 + `test-macos-app-host-abi` 327 pass + `macos-app-build` + `zig fmt`. **ABI 무변경**.
- **리네임 편집 중에도 running 파형 표시(사용자 피드백)**: 옛 사이드바는 워크스페이스 rename 편집 중(`renamingWorkspace`) 상태줄을 숨겨(`""`) running 파형이 안 보였다(사용자: "이름 리네임하면 클로드 돌아가는 애니메이션이 안 보인다"). 편집 중에도 `workspaceStatusLine(tab, running)`을 그려 파형을 유지한다 — **아이콘만** rename 중 숨긴다(gutter col 0이라 편집 텍스트를 밀어 `renameCaretRect`/IME 후보창과 어긋나기 때문; 상태줄은 별도 line이라 캐럿 간섭 없음). "편집 이름 + 상태줄" 레이아웃은 non-git 에이전트 워크스페이스(브랜치/경로 없이 상태줄만)와 동형이라 안전. 브랜치/경로는 편집 집중 위해 계속 숨김. **주의(별개 이슈)**: 사용자가 본 "running인데 그대로"는 `.app` 번들이 stale(재빌드 전)이던 것 — `zig build macos-app-bundle`/`mise run macos-app`로 새로 빌드해야 반영된다. 검증: `test-macos-app-host-abi` 329 pass + `macos-app-build` + `zig fmt`. **ABI 무변경**.
- **에이전트 상태 감지 전환(현재 계약)**: foreground process group + live screen tail + OSC title/progress + PTY activity로
  `running/blocked/idle/unknown`을 판정한다. provider 설정·트랜스크립트는 읽지 않고 외부 provider 파일도 수정하지 않는다.
  명시 blocker/idle 화면이 activity보다 우선해 ESC 뒤 stale running을 해소한다. 답변 미리보기와 완료 알림은 제공하지 않는다.
  구 workspace의 provider scalar는 일반 미지 필드로 건너뛰고 새 저장에는 쓰지 않는다. 단일 출처:
  [agent-session.md](agent-session.md).
- **에이전트 종류 감지 — version comm과 런처 대응**: claude가 실행 중 `process.title`을 버전 문자열로 바꾸거나 node/bun 런처 아래 있는 경우에도 foreground process group의 argv[0]/스크립트 basename으로 종류를 판정한다. 상태는 transcript가 아니라 현재 화면·OSC·PTY activity를 쓰며, 검증은 `parseArgv0Basename` 단위 테스트와 PTY/app-host 빌드가 담당한다. 단일 출처: [agent-session.md](agent-session.md).
- **사이드바 4줄 카드 하단 여백 확대(사용자 피드백)**: 에이전트 상태줄이 붙은 4줄 카드(이름·브랜치·경로·상태)의 상·하 여백이 빡빡하다는 피드백. 카드 슬롯은 **균일 높이**(hit-test `slotAt`·스크롤·드래그 `dragTargetSlot`이 `i*slot_h` 가정)라 4줄 카드만 개별로 못 키우고, 내용은 **블록 세로 중앙 정렬**이라, 슬롯 비율 `sidebar_slot_height_ratio_milli`를 **4.6×→5.2×**로 키웠다(4줄 상·하 여백 각 `0.3×→0.6×cell`로 배증). 균일 슬롯이라 1~3줄 카드도 함께 여유가 늘고(중앙 정렬), 화면당 카드 수는 소폭 감소하는 트레이드오프. 슬롯 높이를 심볼(`sidebar_slot_height_ratio_milli`)로 참조하는 파생·테스트(`frame.sidebar_slot_height_px` 단언)는 자동으로 따라간다(하드코딩 없음). chrome tokens의 `sidebar_slot_height_ratio_milli=2.5×`는 미래 C2/C3 컴포넌트 계획값이라 별개(무변경). 검증: `test-macos-app-host-abi` + `macos-app-build` + `zig fmt`. **ABI 무변경**.
- **에이전트 스피너 code-review high 후속(6건)**: `/code-review high`(아이콘 볼드+스피너+공식색 합본) 지적 반영. **#1(성능)** running 스피너가 사이드바 접힘/필터아웃에도 130ms마다 full-grid 재셰이프하던 ~4× 회귀 — `anyAgentRunning`을 `tabs` 전체 스캔 → **`sidebar_visible_tabs`(보이는 카드)만 + 접힘이면 false**로(스피너가 화면에 있을 때만 위상·재투영). **#2(정확성)** 스피너 색칠 게이트에 col/row 제한이 없어 이름/브랜치/경로의 braille가 브랜드색 오염 → **상태줄 row(카드 마지막 줄, line_index==line_count-1)로 좁힘**. **#3** 펄스 폐기 후 `agent_pulsing`이 500ms blink-dirty에 남아 byte-identical 재투영 → 제거(스피너 자기 위상이 dirty). **#4** `isAgentSpinnerCp` → `std.mem.indexOfScalar`(파일 관용). **#5/#6** 색칠 루프 헤더·`dimRgb` 테스트 제목 stale("펄스") 정리. 검증: 헤드리스 회귀(`anyAgentRunning` 접힘·필터아웃 false) + `mise run check`. ABI 무변경.
- **사이드바 폴리시(카드 여백 — Warp 벤치마킹)**: Warp 세로 탭 사이드바를 직접 보고(룩만, clean-room) — Warp는 행 사이 여백이 넉넉하고 활성 행이 또렷한 카드다. maru 사이드바는 개념(이름/브랜치/cwd/에이전트·활성 카드·비활성 무채움)은 이미 Warp와 가까워, **카드 여백**을 키워 "떠 있는 카드" 분리감을 강화한다 — `card_gap_px`(밴드 사방 inset) rich 4→**8px**. `chrome/tokens.zig` `Tokens.rich`만 변경(`tk.space.card_gap_px`가 사이드바 lowering shape로 흘러 밴드/accent 막대·텍스트 indent를 함께 inset). before/after 실물 캡처로 카드 분리감 확인 + `mise run check` green. **ABI 무변경**. 후속(선택): 원형 아이콘 컨테이너·diff 배지·컴팩트(콘텐츠-맞춤) 카드 높이는 Warp의 추가 요소(별도).
- **상단 탭바 Warp 폴리시 2단계 완료(인라인 "+")**: Warp는 "+"가 탭 바로 옆(좌측 묶음)인데 maru는 far-right에 외따로 떨어져 큰 빈 갭이 있었다. "+"를 **마지막 탭 바로 뒤**로 옮긴다. `tabbar.Metrics.plusZoneStart`가 `has_scroll`이면 옛 far-right(‹·gap·› 뒤), 아니면 `tabsEndCol`(=`min(tab_count*tab_w, tab_cols)`)을 돌려주고 렌더(`coretext` `plus_start`)가 같은 값을 써 **단일 정합**("보이는 + = 클릭되는 +" 시임 유지 — `tab_count`를 `Metrics`에 추가, `barMetrics`가 채움). **`inPlusZone`을 cols까지가 아니라 버튼 폭(`plus_button_cols=2`)으로 한정** — "+" 오른쪽 빈 바 클릭은 새 Term을 안 만든다(빈 영역 무동작, 사용자 결정 ①). 탭 넘침(`has_scroll`)이면 far-right 폴백. **상태 dot는 생략**(maru는 에이전트 상태를 이미 사이드바에 풍부히 표시 — 중복, 사용자 동의). 검증: 헤드리스(인라인 plusZoneStart·`inPlusZone` 버튼 폭 한정·빈 영역 false·넘침 far-right; 옛 +위치 테스트는 tui 고정으로 정합) + connected 실물 캡처(+ 탭 옆) + `mise run check` green. **ABI 무변경**. 단일 출처: [탭·split·레이아웃 전략](tabs-splits-layout.md) "+" 버튼 절.
- **활성 탭 글자 bold 완료(셰이퍼 bold 폰트 face)**: 사용자 요청. 활성 탭/워크스페이스 제목을 active_fg(색) + **bold(무게)**로 그려 색만으로는 약한 강조를 굵기로 보강한다. 핵심은 셰이퍼가 실제 bold 폰트 face를 고르게 한 것 — 지금까지 `Style.bold`는 끝까지 흘렀지만 native 셰이퍼로는 전달되지 않아(`NativeDrawCell`에 style이 없었다) **시각 효과가 전무**했다(SGR 1 bold 포함). `NativeDrawCell`의 패딩(`reserved`)을 `style_flags`(bit0=bold)로 의미화해 16바이트 레이아웃을 유지한 채 bold를 native로 흘리고, `maru_macos_coretext_shape_draw_list`가 `CTFontCreateCopyWithSymbolicTraits(…, kCTFontTraitBold)`로 bold variant를 한 번 만들어 bold cell만 그 attributes로 셰이핑한다 → bold variant의 PostScript name(예: "Menlo-Bold")이 record로 흘러 rasterizer가 그 이름으로 **굵은 glyph**를 그린다(기존 fallback-by-name plumbing 재사용, cache_key가 이미 `style.bold`를 구분해 regular/bold 슬롯이 분리됨). family에 bold variant가 없으면 NULL→regular 폴백(없는 굵기를 합성하지 않음). 빌더(`buildSidebarDrawList`/`buildPaneTabBarDrawList`)는 활성 행/세그먼트 style에 `.bold = true`를 더한다. **부수 효과(의도)**: 터미널 SGR 1 bold도 이제 실제 bold로 렌더된다(이전엔 무효과) — 탭만 특수 처리하지 않고 bold를 올바른 깊이(셰이퍼)에서 일반화한 결과. 베이스: bold=별도 폰트 face는 CoreText의 표준 동작(bold=bright color 매핑은 안 씀 — Maru는 bold 매핑이 없었으니 가장 표준적인 face 선택을 택함). 검증: 헤드리스(`nativeDrawCellFromDrawCell`이 style.bold→style_flags bit0; 빌더 활성 셀이 active_fg+bold·비활성은 fg+regular) + coretext/metal 스모크(실 CoreText 셰이핑 경로 컴파일·구동) + 전체 테스트. **ABI 무변경**(27, native-내부 struct만 패딩 의미화). 한계: 실제 굵기 시각 확인은 앱 수동. floating 탭은 bold 미적용(드래그 ghost).
- **기본 바인딩 unbind 완료(`keybind = <chord> = unbind`)**: 사용자 요청. 지금까지 config로 빌트인 단축키를 *다른 action으로 덮어쓰기*만 됐고 "끄기/패스스루"는 불가했다 — 이제 `unbind`로 빌트인 기본을 끈다(예: `keybind = Cmd+T = unbind` → Cmd+T가 새 Term 안 엶). `KeyBindingResolver`에 `unbinds: []const KeyChord` 필드 추가 — resolve가 사용자 바인딩 다음·빌트인 테이블 앞에서 chord가 unbind 목록에 있으면 빌트인 terminal/app 테이블을 **건너뛴다**(`isUnbound`). 그러면 Cmd 조합은 fallthrough로 `.ignored`(아무 동작 안 함), 그 외는 `encodeKey`로 셸 입력이 된다. **설계 결정**: unbind는 app action이 아니라 "기본 끄기"라 `Action` union에 넣지 않고 별도 chord 목록으로 둔다 — `dispatchAppAction`의 exhaustive switch에 무의미한 분기를 강제하지 않는다(특수 케이스를 공유 인프라에 안 얹음). loader가 `keybind = <chord> = unbind`를 파싱해 `Parsed.unbinds`로(app 바인딩과 같은 dedup 풀 — chord당 한 줄, 첫 줄 우선), `keyBindingResolver()`가 app_bindings+unbinds를 함께 넘긴다. 사용자가 같은 chord를 bind도 하면 그게 우선(unbind는 빌트인만 끈다). 베이스: Ghostty의 `keybind = … = unbind`(MIT 동작 비교). 검증: 헤드리스(resolver — unbind된 Cmd+T/Cmd+Left가 ignored·Cmd+W는 그대로 close_term; 사용자 바인딩이 unbind보다 우선 / loader — unbind 수집·bind/unbind 교차 dedup·diagnostic) + 전체 테스트/스모크. 문서: `docs/configuration.md` keybind 절에 `unbind` 추가. **ABI 무변경**(27, 순수 config/resolver). 터미널 매크로(config로 `terminal_bindings` 정의 — `text:`/`esc:`/`ctrl:` 셸 바이트)는 **후속 PR**.
- **터미널 매크로 config 완료(`keybind = <chord> = text:|esc:|ctrl:<payload>`)**: 사용자 요청(unbind의 후속). config로 키에 셸로 보낼 바이트를 묶는다 — 지금까지 `terminal_bindings`는 빌트인(Cmd+←=Ctrl+A 등)만 있고 config로는 못 만들었다(로더 "후속"). resolver는 이미 사용자 `terminal_bindings`를 resolve 2단계(사용자 app 다음, 빌트인 앞)에서 처리하므로 **loader만 채웠다**. 문법(Ghostty식): `text:<문자열>`→`send_text`(그대로), `esc:<payload>`→`send_escape_sequence`(ESC 0x1b를 앞에 붙임. 예 `esc:[2J`→화면 지우기), `ctrl:<글자 한 자>`→`send_control`(그 글자의 C0 컨트롤 바이트. 예 `ctrl:[`=ESC). `parseTerminalMacro`가 접두사로 분기하고 payload(text/esc)는 arena에 복사(binding 소유 — handleKeyEvent가 `runtime.writeInput`로 그 자리에서 동기 소비, 반환엔 `bytes_len`만 담아 슬라이스를 안 잡음). `ctrl:`은 로드 시 `terminal.input.controlByte`로 미리 검증해(C0 매핑 없는 글자·여러 글자·빈 payload는 diagnostic) resolve가 키 누를 때 InvalidControlKey로 안 터지게 한다. dedup을 app/unbind/terminal **세 풀 공통**으로 묶어, 한 chord가 앱 동작과 매크로에 동시에 안 묶이고(첫 줄 우선) resolver의 app↔terminal 충돌 검사가 통과한다. 매크로 접두사인데 파싱 실패하면 app action으로 재해석하지 않고 그 줄을 버린다. 베이스: Ghostty의 `text:`/`esc:`/`ctrl:`(MIT 동작 비교). 검증: 헤드리스(loader — text/esc/ctrl 매크로 생성·ESC prepend·잘못된 payload forgiving·app↔terminal 충돌 첫 줄 우선·실 resolve로 Cmd+E→ctrl:[→ESC 1바이트) + 전체 테스트/스모크. 문서: `docs/configuration.md` keybind 절에 매크로 문법. **ABI 무변경**(27, 순수 config — resolver는 기존 terminal_bindings 경로 재사용).
- **리뷰 후속 정리 완료(`/code-review max` 결과 #356~361)**: 정확성 버그는 0건이었고, 효율/DRY 3건을 손봤다(동작 불변). ① `coretext_smoke.m`: bold variant 폰트(`CTFontCreateCopyWithSymbolicTraits`+`CopyPostScriptName`+`CFDictionaryCreate`)를 shape마다 무조건 만들던 걸 **첫 bold cell에서 lazy 생성**(`bold_attempted` 가드)으로 — bold cell이 없는 흔한 프레임은 CoreText 변형 호출 0. ② `loader.zig`: 매크로 접두사 목록을 `isTerminalMacroPrefix`와 `parseTerminalMacro`가 중복하던 걸 제거 — `parseTerminalMacro`가 `MacroParse{.not_macro/.invalid/.macro}` 3-상태를 반환해 접두사 단일 출처. ③ `loader.zig`: 동일한 dedup `for` 3개를 순수 `chordAlreadyBound(binds, unbinds, term_binds, chord)` 헬퍼로 통합. (tabNumberLabel allocPrint는 builder가 번호를 직접 그리거나 제목 캐싱이 필요해 복잡도↑ > 이득이라 보류.) 검증: 전체 테스트 + coretext/metal 스모크(실 CoreText bold lazy 경로). **ABI 무변경**(27).
- **전역 단축키 a1 완료(Zig 기반 — 파싱·매핑, 헤드리스)**: 사용자 요청(a→b 중 a, 둘로 나눔). `keybind = global:<chord> = toggle_window|show_window` 문법을 파싱하고 OS 등록용 키코드 매핑까지 — **ABI·Swift 무변경**(a2가 소비). `global:` 접두사를 `applyKeybind`가 떼고 `applyGlobalKeybind`로 보내 `Parsed.global_bindings`(4번째 목록)에 모은다. **별도 네임스페이스**라 in-app 3-풀(app/unbind/terminal)과 dedup하지 않고 전역끼리만(같은 조합을 in-app·전역 둘 다 둘 수 있음 — OS 핫키 vs 앱 키 경로). `GlobalAction{toggle_window, show_window}`는 NSWindow 동작이라 in-app `Action`과 **분리**(별도 enum — `dispatchAppAction` switch 무관, unbind와 같은 altitude). `toggle_window` 동작은 진짜 토글(show+activate / orderOut, a2에서 Swift 수행). keycode.zig에 `macVirtualKeyCodeForAscii`(`usAsciiForKeyCode` 역방향, 대문자 fold) 추가. 새 `platform/macos/global_hotkey.zig`가 `GlobalBinding → Descriptor{virtual_key_code, carbon_modifiers, action}`로 변환(Space=0x31·명명 키·F1~F20 keycode, Carbon modifier mask) — a2의 Swift가 ABI로 받아 `RegisterEventHotKey`로 등록. 매핑 없는 키(`+`/Insert)는 null(등록 제외). 등록 API는 Carbon `RegisterEventHotKey`(Accessibility 권한 불필요, 특정 chord만 등록·소비). 검증: 헤드리스(loader — `global:` 수집·전역 dedup·in-app과 분리·bogus forgiving; keycode 정방향 왕복; global_hotkey descriptor — Space/대문자 fold/F5/Plus·Insert null; GlobalAction 파싱) + 전체 테스트/스모크. 문서: `docs/configuration.md` `global:` 절. **ABI 무변경**(27). a2: ABI bump + getter + Swift Carbon 등록·창 토글.
- **전역 단축키 a2 완료(Swift Carbon 등록 + 창 토글, ABI 28)**: 사용자 요청(a→b 중 a 마무리). a1을 OS에 연결해 `global:` 단축키가 실제로 동작한다(앱 비활성에도). **ABI 28**: `MaruAppHostGlobalHotkey{virtual_key_code, carbon_modifiers, action}` struct + `MaruAppHostGlobalAction` enum + getter `maru_macos_app_session_global_hotkeys`(Zig-owned ptr+count, `copy_text` 패턴). `AppSession`이 init에서 `loaded_config.global_bindings`를 `global_hotkey.descriptorFor`로 매핑해 owned `global_hotkeys`(매핑 불가 chord 제외)에 담고 getter로 노출. Swift는 OS 글루만: `registerGlobalHotkeys`가 getter로 descriptor를 받아 Carbon 핸들러 1개 설치(`InstallEventHandler`, userData=self) + 각 descriptor를 `RegisterEventHotKey`로 등록(id=인덱스), 비캡처 C 핸들러가 `EventHotKeyID`로 controller를 되찾아 메인 스레드에서 action 수행(`toggle_window`=보임+활성이면 orderOut·아니면 makeKeyAndOrderFront+activate, `show_window`=항상 앞으로), `shutdownAppSession`이 `UnregisterEventHotKey`+`RemoveEventHandler`로 정리. **Swift 최소 준수**: 키 매핑·dedup·action 결정은 a1의 Zig가 소유하고, Swift는 descriptor 등록과 NSWindow/Carbon 호출만(정책 0). 베이스: Carbon `RegisterEventHotKey`(Ghostty/iTerm2 동작 비교, 권한 불필요). 검증: swift-check가 Carbon 코드 컴파일 검증 + Zig getter는 a1 descriptor 단위 테스트·ABI 28 cross-check + 전체 테스트/스모크. 실제 등록·토글은 앱 수동. 문서: `docs/configuration.md` `global:` 현재 범위 갱신. 이로써 **a(전역 단축키) 완료**.
- **quick terminal b1a 완료(per-session 상태 추출 — `TerminalSurface`)**: 사용자 요청(b를 "별도 전용 세션"으로, 단계 분할). quick terminal(두 번째 독립 세션 오버레이)을 얹기 전, 단일 세션 가정으로 짜인 `MaruAppHostController`에서 **세션별 상태를 `TerminalSurface` 클래스로 추출**했다(동작 보존 리팩터). `TerminalSurface`(@MainActor)가 `window`/`appSession`/`metalRenderer` + 렌더 캐시 메트릭 11개(`lastDrawnGeneration`·`lastSeenMetalGeneration`·`lastCellWidthPx/HeightPx`·`lastSentBackingScale`·`metalNeedsRedraw`·`metalFramesDrawn`·`metalRendererCreated`·`latestFrameSummary`·`appSessionStatus`·`lastWindowTitle`)를 들고, `view`는 `window.contentView` 계산값. 컨트롤러는 `primary: TerminalSurface?`를 보유하고, 기존 세션별 stored 프로퍼티들을 **primary로 forwarding하는 계산 프로퍼티**로 바꿨다 — 이래서 ~25개 세션별 메서드(틱·그리기·입력·IME·resize)와 뷰가 **코드 변경 없이** primary의 상태를 읽고 쓴다(상태만 분리, 로직 불변). `applicationDidFinishLaunching`이 창 생성 전에 `primary`를 만들어 forwarder 대입이 유실되지 않게 한다. **설계 의도**: 메서드를 물리적으로 옮기는 대신 forwarder로 두면(저위험), b1b가 두 번째 surface + 라우팅만 더하고 메서드를 그대로 재사용(중복 0)할 수 있다. 검증: swift-check(forwarder/타입 컴파일) + coretext/metal 스모크(앱을 실제 실행 — primary surface end-to-end 동작 동일) + 전체 테스트. **ABI·Zig 무변경**(28). b1b: `toggle_quick_terminal` + 두 번째 세션·NSPanel + 입력 라우팅. b2: 슬라이드 애니메이션·Esc·포커스.
- **quick terminal b1b 완료(두 번째 세션·오버레이 패널·토글, ABI 29)**: 사용자 요청. b1a의 `TerminalSurface` 위에 quick terminal을 얹었다 — `keybind = global:<chord> = toggle_quick_terminal`로 화면 상단 드롭다운 오버레이에 **독립된 두 번째 셸 세션**을 띄운다. Zig: `toggle_quick_terminal` GlobalAction + ABI 29(`.h` enum `ToggleQuickTerminal=2`). Swift: ① 라우팅 — 컨트롤러 forwarder를 `primary` → `activeSurface`로 바꿨다(`explicitSurface`(tick이 surface 지정) ?? key 창의 surface(이벤트는 key 창 first responder로 전달) ?? primary). 입력/IME/hover는 key 창 기준 자동 라우팅(뷰 변경 0), tick은 각 surface를 explicitSurface로 지정해 돈다. ② `quick: TerminalSurface?` lazy 생성(첫 토글) — 두 번째 `app_session_create`(대화형 셸) + borderless `QuickTerminalPanel`(NSPanel, `canBecomeKey=true`로 타이핑 가능, floating·전체화면 위) + 자체 Metal 뷰/렌더러. ③ tick이 primary(셸 종료→앱 종료) 다음 quick(보일 때만; 셸 종료→quick만 teardown, 앱 계속)을 돈다(`renderTick` 추출). ④ `toggleQuickTerminal`(보이면 orderOut / 아니면 생성·상단 전폭 45% 배치·key+activate·resize), `performGlobalAction`의 window 동작은 `primary` 명시. ⑤ `shutdownAppSession`이 quick+primary 둘 다 닫는다. **Swift 최소**: 세션별 로직은 b1a 메서드를 그대로 재사용(중복 0), 추가 Swift는 OS 글루(NSPanel·세션 create/destroy·라우팅)뿐. 검증: swift-check(컴파일) + coretext/metal 스모크(앱 실행 — quick은 비-smoke에서만 생성되므로 primary 경로 불변) + 전체 테스트. 실제 토글·타이핑은 앱 수동. 한계: 슬라이드 애니메이션·Esc 숨김·포커스 폴리시는 b2.
- **quick terminal b1b 후속 수정(toggle_window 숨김 시 앱 종료 버그)**: 앱 수동 테스트에서 `toggle_window`(메인 창 토글)를 누르면 앱이 종료됐다(`/`=quick terminal은 정상). 원인: `toggle_window`가 메인 창을 `orderOut`(숨김)하는데 `applicationShouldTerminateAfterLastWindowClosed`가 `true`라, 마지막 창이 화면에서 사라지면 AppKit이 앱을 종료시킨다(quick terminal은 메인 창을 안 숨겨 무사). 크래시가 아니라 깨끗한 종료(crash report 없음). 수정: 그 델리게이트를 **`false`**로 — "숨김"이 종료로 이어지지 않게. 명시적 창 닫기(빨간 버튼) 종료는 기존대로 `windowWillClose`의 `NSApp.terminate`가 단일 출처로 담당. 스모크는 자체 timer/SessionEnded로 종료해 무영향. **ABI·Zig 무변경**.
- **quick terminal b2 완료(슬라이드 애니메이션 + 포커스 잃음 자동 숨김)**: 사용자 요청. quick terminal 폴리시. ① 슬라이드 인/아웃 — 패널이 화면 위(숨김 위치)에서 상단(보임 위치)으로 `NSAnimationContext`로 y만 애니메이션(보임/숨김 사각형은 폭·높이 동일·y만 달라 슬라이드 중 콘텐츠 크기 불변 → drawable/grid 재계산 불요; makeKey 직후 한 번만 resize). 숨김은 위로 올린 뒤 완료 시 orderOut. ② 포커스 잃음 자동 숨김 — 패널 전용 `didResignKeyNotification` 관찰(컨트롤러를 패널 delegate로 안 잡아 primary windowWillClose/Resize와 안 섞임)로 다른 창/앱 클릭 시 슬라이드 숨김. `quickAnimating` 가드 + `panel.isVisible` 체크로 애니메이션 중·orderOut의 resignKey 재진입(이중 숨김) 방지. teardown이 관찰 해제. ③ **Esc 숨김은 의도적으로 제외** — Esc는 터미널 키(vim 등)라 가로채면 quick terminal 안에서 깨진다(iTerm2/Ghostty도 기본 미적용). 토글 핫키로 이미 숨길 수 있다. 검증: swift-check + coretext/metal 스모크(quick은 비-smoke에서만 생성 — animation/observer 미실행, primary 불변) + 전체 테스트. 실제 슬라이드·자동 숨김은 앱 수동. **ABI·Zig 무변경**. 한계: 고정 크기(상단 전폭 45%) 옵션화·다중 모니터 선택은 후속.
- **quick terminal 옵션화 완료(config로 높이·자동 숨김·화면, ABI 30)**: 사용자 요청. config로 quick terminal 표시를 설정한다 — `quick-terminal.height`(화면 대비 비율 0.1~1.0, 기본 0.45), `quick-terminal.auto-hide`(true/false, 포커스 잃음 자동 숨김; false면 토글로만), `quick-terminal.screen`(main/mouse, 어느 화면에 띄울지). Zig: `theme.QuickTerminalConfig`(+QuickTerminalScreen enum)를 `Config`에 추가, loader가 3개 키를 forgiving 파싱(범위 밖/오타는 기본값+diagnostic). ABI 30: `MaruAppHostQuickTerminalConfig{height_milli, auto_hide, screen}` struct + `maru_macos_app_session_quick_terminal_config` getter(global_hotkeys와 같은 패턴 — POD 복사). Swift: `ensureQuickTerminal`이 getter로 옵션을 읽어 `quickHeightFraction`/`quickAutoHide`/`quickScreenMode`에 저장, `quickPanelFrames`가 설정 높이 + `quickTargetScreen`(mouse면 show마다 현재 마우스 화면 해석)으로 사각형 계산, `quickTerminalLostKey`가 `quickAutoHide`로 게이트. 검증: 헤드리스(loader — 3키 기본/설정/forgiving) + swift-check + coretext/metal 스모크(quick 비-smoke 전용) + 전체 테스트 + ABI 30 cross-check. 실제 높이·화면·자동숨김 끄기는 앱 수동. 문서: `docs/configuration.md` 키 표.
- **호버 탭 hit-test 할당 churn 제거(재사용 scratch 버퍼)**: 마우스 이동마다 도는 hover hit-test(`updateHoveredTab`의 leaf rect, `dividerAtPoint`의 divider seg)가 매번 `ArrayList`를 새로 할당·해제하던 걸, AppSession의 재사용 scratch 버퍼(`hover_leaf_scratch`/`hover_divider_scratch`)로 바꿨다 — `clearRetainingCapacity` 후 레이아웃을 **매번 다시 계산**(작은 트리라 cheap)하므로 결과는 항상 최신이라 **stale 캐시(클릭 오타깃) 위험이 없고**, capacity만 재사용해 per-move malloc/free churn만 없앤다. hover/divider hit-test는 메인 스레드 순차 실행 + 서로 다른 버퍼라 aliasing 없음. (드래그-경로 dragTabTo/dropTabAt은 per-drop이라 그대로 둠.) 검증: 동작 불변(macOS hoverCursor 통합 테스트가 실 세션에서 scratch 경로 구동) + 전체 테스트/스모크. **ABI·Zig 무변경**(순수 내부 최적화).
- **quick terminal 위치 옵션 완료(top/bottom/left/right, ABI 31)**: 사용자 요청(quick terminal 추가 옵션). `quick-terminal.position`(top/bottom/left/right, 기본 top)으로 패널이 어느 가장자리에서 슬라이드해 나올지 정한다 — top/bottom은 전폭 + `height` 비율 높이, left/right는 전고 + `height` 비율 폭(가장자리에 수직인 '두께'에 비율 적용). Zig: `theme.QuickTerminalPosition` enum + `Config` 필드, loader가 `quick-terminal.position` forgiving 파싱. ABI 30→31: `MaruAppHostQuickTerminalConfig`에 `position: u32` 추가(+`MaruAppHostQuickTerminalPosition` enum). Swift: `quickPosition` 저장, `quickPanelFrames`가 위치별로 보임/숨김 사각형 계산(슬라이드 축만 다르고 폭·높이는 같아 콘텐츠 크기 불변 — grid 재계산 불요). show/hide 애니메이션은 frames만 쓰므로 edge-무관(변경 없음). 검증: 헤드리스(loader position 기본/설정/forgiving) + swift-check + 스모크 + 전체 테스트 + ABI 31 cross-check. 실제 4방향 슬라이드는 앱 수동. 문서: `docs/configuration.md`(height 의미를 '두께'로 명확화).
- **리뷰 후속 수정(primary 창 이벤트가 quick 세션으로 오라우팅)**: `/code-review max`(aa2543f..HEAD)가 routing seam의 정확성 결함 1건을 찾았다 — `windowDidResize`/`windowDidEndLiveResize`(컨트롤러는 primary 창의 delegate)와 `handleBackingScaleChange`(뷰 발) 그리고 종료/닫기 `writeSummary`가 `window`/`metalTerminalView`/메트릭 forwarder(=activeSurface)를 쓰는데, 그 순간 quick 패널이 key면 primary가 아닌 **quick 세션이 리사이즈/요약**된다(포커스를 안 옮기는 프로그램/디스플레이 resize 시). 수정: `withSurface(_:_:)` 헬퍼(tick의 explicitSurface 메커니즘 재사용)로 primary-delegate 콜백·종료 요약을 **primary 명시 대상**으로 감싸고, `handleBackingScaleChange(in view:)`는 `surfaceForView`로 **fire한 뷰의** surface를 대상으로 한다(quick 뷰가 fire하면 quick). 런치 경로는 quick이 아직 없어 무영향. 검증: swift-check + coretext/metal 스모크(quick 비-smoke 전용 → 무영향, primary 경로 동일) + 전체 테스트. **ABI·Zig 무변경**. (그 외 리뷰 후보 — bold lazy CF 누수·ABI 정합·MainActor 스레드·두 세션 전역상태 — 전부 반증.)
- **quick terminal chrome 옵션 완료(full/minimal, ABI 32)**: 사용자 요청(config로 full/minimal 고르게). `quick-terminal.chrome`(full/minimal, 기본 full)으로 quick terminal 패널의 chrome 수준을 정한다 — `minimal`이면 세로 사이드바·pane 탭 바 없이 **터미널 그리드만**(드롭다운 스크래치 터미널의 보편 모습), `full`이면 메인 창처럼 다 보임. 메인 창엔 영향 없음(quick terminal 전용). 설계: chrome 억제는 **세션별 플래그**로 — primary·quick이 같은 config 파일을 읽으므로, "이 세션이 minimal인가"를 `SessionConfig.chrome_minimal`(기존 `reserved` 패딩 자리를 의미화 — 크기 불변)로 세션 생성 시 박는다. quick 세션만 1, 메인 창은 0. Zig: `theme.QuickTerminalChrome` enum + `Config` 필드, loader forgiving 파싱. `AppSession.chrome_minimal`이 `paneBarHeightPx`(=0 → `paneTermRect`/`paneBarRect`가 탭 바 통째 끔)·`sidebar_width_px`(refreshCellMetrics·setSidebarWidthPx에서 0 고정)를 게이트. `QuickTerminalConfig` getter에 `chrome` 필드 추가해 Swift가 quick 세션 생성 전에 읽는다. ABI 31→32: `MaruAppHostSessionConfig.reserved`→`chrome_minimal`(크기 불변), `MaruAppHostQuickTerminalConfig`에 `chrome: u32`(+`MaruAppHostQuickTerminalChrome` enum) 추가. Swift: `ensureQuickTerminal`이 config의 `chrome`을 **세션 생성 전에** 읽어 `chrome_minimal`로 넘긴다(메인 `startAppSession`은 항상 0). 검증: 헤드리스(loader chrome 기본/설정/forgiving, normalizeConfig가 chrome_minimal 운반, minimal 세션이 탭 바 높이 0·사이드바 0·드래그 무동작) + swift-check + coretext/metal 스모크(quick 비-smoke 전용 → 메인은 항상 full로 불변) + 전체 테스트 + ABI 32 cross-check(QuickTerminalConfig 크기·chrome enum 정합). 실제 minimal 렌더는 앱 수동. 문서: `docs/configuration.md` 키 표.
- **chrome 옵션 리뷰 후속 수정(테스트 UB + dead 방어 코드 제거)**: chrome PR을 `/code-review max`(33f0999..HEAD)로 훑어 결함 2건을 고쳤다(production 정확성 버그는 0). ① `paneTermRect reserves a top tab-bar strip` 테스트가 `var session: AppSession = undefined`로 `cell_*_px`만 세팅했는데, chrome PR이 `paneBarHeightPx`에 `if (chrome_minimal) return 0`를 추가해 **초기화 안 된 `chrome_minimal`을 읽는 UB**가 됐다(0xaa 채움이 우연히 false라 통과 중) → 테스트에 `chrome_minimal = false` 명시 + 옛 `cell_width_px` 주석을 `cell_height_px`로 정정. ② `setSidebarWidthPx`의 `if (chrome_minimal) return` 가드는 **production 도달 불가**(유일 호출처인 드래그가 `xOnSidebarEdge` → `sidebar_width_px == 0`이면 false라 minimal에선 드래그가 시작조차 못 함)였다 — 규칙(`방어 코드는 정말 불가피할 때만`) 위반이라 가드와 그걸 검증하던 테스트 단언을 제거하고, 필드 주석에 "사이드바 폭 0이면 hit-test도 false라 드래그 자체가 안 시작 → 별도 게이트 불요"를 명시. 억제는 `paneBarHeightPx`+`refreshCellMetrics` 두 지점으로 완결. 검증: 전체 테스트 + swift-check + boundaries + coretext/metal 스모크. **ABI·동작 무변경**(production 경로 불변 — dead 코드·테스트 UB만 제거).
- **quick terminal center 위치 완료(화면 중앙 + 페이드)**: 사용자 요청. `quick-terminal.position = center`로 패널을 가장자리가 아닌 **화면 중앙**에 띄운다 — width·height 둘 다 `height` 비율(예 0.45면 화면의 45%×45%)로 잡아 visibleFrame 중앙에 배치. 가장자리가 없어 슬라이드할 방향이 없으므로 **알파 페이드 인/아웃**으로 보임/숨김을 애니메이션한다(top/bottom/left/right는 기존대로 위치 슬라이드). Zig: `theme.QuickTerminalPosition`에 `center` 추가, loader가 파싱. Swift: `quickPanelFrames`가 center면 보임=숨김(같은 중앙 사각형)을 반환하고, `showQuickTerminalAnimated`/`hideQuickTerminalAnimated`가 `quickIsCentered`면 `setFrame` 대신 `alphaValue`(0↔1)를 애니메이션(숨김 완료 후 alpha 1 복구). 크기는 보임=숨김이라 grid 한 번만 맞추면 됨(슬라이드와 동일 불변). ABI 무변경(32) — `position` u32 필드에 enum 값 `center=4`만 추가(구조체 레이아웃 불변), `MaruAppHostQuickTerminalPositionCenter` + cross-check 추가. 검증: 헤드리스(loader center 파싱) + swift-check + coretext/metal 스모크(quick 비-smoke 전용) + 전체 테스트 + ABI cross-check(Center enum 값 정합). 실제 중앙 페이드는 앱 수동. 문서: `docs/configuration.md` position 행에 center. 한계: show가 hide 애니메이션(0.12s) 중간에 끼는 sub-프레임 더블 토글 race는 가장자리와 동일하게 미해결(별도).
- **quick terminal minimal 탭 옵션 완료(minimal-tabs, ABI 33)**: 사용자 요청(옵션으로, 기본 A=스크래치). minimal 모드에선 사이드바(워크스페이스 탭)와 pane 탭 바(Term)가 둘 다 꺼져 ⌘T(new_term)·⌘⇧T(new_tab)로 만든 탭이 **안 보인다**(⌘1..9로만 전환 가능 — 보이지 않는 탭이 쌓이는 footgun). `quick-terminal.minimal-tabs`(기본 false)로 처리: false면 chrome_minimal 세션에서 `dispatchAppAction`이 new_tab/new_term을 **무동작**으로 막아 단일 스크래치 터미널이 된다(split ⌘D은 divider로 보이므로 유지 — 다중 뷰는 split으로). true면 탭을 허용(파워유저, ⌘1..9/⌘]로 전환). full 세션은 `tabsBlocked()`가 항상 false라 이 값과 무관하게 탭이 동작. 생성 액션만 게이트하고 네비게이션(select_tab/next_term 등)은 탭이 1개뿐이라 자연 no-op(별도 게이트 없음 — dead 코드 회피). 게이트는 keybind→action 디스패치가 Zig라 `dispatchAppAction`에 둔다(마우스 "+"는 minimal에 chrome이 없어 이미 도달 불가). ABI 32→33: `SessionConfig`·`QuickTerminalConfig`에 `minimal_tabs: u32` 추가(chrome_minimal과 같은 dual-path). Swift: `ensureQuickTerminal`이 `cfg.minimal_tabs`를 quick 세션 생성 시 넘김(메인은 0). 검증: 헤드리스(loader minimal-tabs 기본/설정/forgiving, normalizeConfig 운반, minimal 스크래치에서 new_tab/new_term이 tabs·terms 카운트 불변·minimal_tabs=1이면 +1) + swift-check + boundaries + coretext/metal 스모크 + 전체 테스트 + ABI 33 size cross-check(24→28). 실제 동작은 앱 수동. 문서: `docs/configuration.md` 키 표.
- **quick terminal minimal 탭 인디케이터 완료(우상단 적응형 점)**: 사용자 요청·결정(적응형 점). minimal에서 `minimal-tabs=true`로 탭을 허용하면 사이드바·탭 바가 없어 탭이 안 보이던 걸, **우상단에 작은 탭 점**으로 보여준다. 적응형: 워크스페이스가 여러 개면 워크스페이스(⌘1..9), 아니면 활성 pane의 Term(⌘])을 점으로 — 한 줄로 가장 관련 있는 차원만(둘 다 1개면 무동작). 점은 기존 sentinel-bg 셀 재사용(폰트·새 렌더 경로·ABI 불요): strip(`sidebarBg`) 한 칸 위에 활성=`sidebarActiveBg`(밝게)·나머지=`sidebarHoverBg`(중간 톤), append 순서로 점이 strip 위에 그려진다. `appendMinimalTabIndicator`가 tick의 `pane_overlay`(터미널 위·커서 아래 레이어)에 append하며 `chrome_minimal`이 아니거나 단일이면 무동작(full은 사이드바/탭 바가 이미 보여줌). 레이아웃은 격자 정렬 우상단(row 0), band 폭 2*count+1칸, 화면보다 넓으면 좌측 잘림(극단적 탭 수). 검증: 헤드리스(macOS — 단일이면 0셀, Term 2개면 strip+점2개·활성 점이 우측·색 정합, 워크스페이스 우선 전환, full이면 0셀) + boundaries + swift-check + coretext/metal 스모크 + 전체 테스트. **ABI 무변경**(33 — 순수 렌더, 기존 chrome_minimal/minimal_tabs 플래그 재사용). 실제 점 렌더는 앱 수동. 문서: `docs/configuration.md`.
- **minimal 활성 pane 테두리 완료(focus accent 4변, FP9에서 대체됨)**: 초기 구현은 minimal split에서 `appendActivePaneBorder`가 cell grid 둘레에 4변 reserved 띠를 그렸다. FP9의 공용 `FocusOwner` border가 도입된 뒤에는 이 ring이 같은 의미를 padding 안쪽에 중복 표시하므로 pane-body 경계 보정 PR에서 제거하고 `PaneGeometry.body` 기반 focus border 하나로 대체했다. reserved 4/5 renderer 값은 다른 기존 표현과 ABI 호환을 위해 유지한다.
- **quick terminal center 독립 가로 비율 완료(quick-terminal.width, ABI 34)**: 사용자 요청(center 후속). center가 width·height 둘 다 `height` 비율을 쓰던 걸, `quick-terminal.width`(0.1~1.0)로 **가로를 세로와 독립**시킨다 — center 가로=`width`, 세로=`height`. 기본은 미설정(0)이라 가로가 `height`를 따라가 **기존 center 동작(정사각 비율) 보존**(backward compat). center 외 위치는 무시(top/bottom=전폭, left/right=`height`로 두께). Zig: `theme.QuickTerminalConfig.width_fraction`(기본 0=미설정) + loader forgiving 파싱. ABI 33→34: `QuickTerminalConfig` getter에 `width_milli: u32` 추가(0이면 미설정). Swift: `quickWidthFraction` 저장, `quickPanelFrames` center 케이스가 `width>0 ? width : height`로 가로 비율을 정한다. 검증: 헤드리스(loader width 기본 0/설정 0.8/forgiving 1.5→0) + swift-check + boundaries + coretext/metal 스모크 + 전체 테스트 + ABI 34 size cross-check. 실제 비대칭 center는 앱 수동. 문서: `docs/configuration.md` width 행.
- **quick terminal 묶음 리뷰 후속 수정(50db1ab..HEAD, 당시 구현 기록)**: 6개 커밋(center·minimal-tabs·인디케이터·테두리·center width)을 `/code-review max`로 훑었다 — **correctness 버그 0건**, 다음 3건 처리(나머지 altitude/문서화 한계는 백로그). ① **stale 진단 메시지**: `quick-terminal.position` 오류 안내가 `center` 추가 후에도 `top|bottom|left|right`만 나열 → `…|center`로 정정. ② **인디케이터 fit 가드**: 점 band(`2*count+1`)가 화면 폭에 안 들어가면 `band_start`가 0으로 saturate돼 좌상단에 전폭으로 그려지던 걸, `band_width+margin > cols`면 아예 안 그리게 가드(우상단 의도 보존). ③ **당시 테두리/divider 리팩터**: `appendActivePaneBorder`와 `appendActiveTabDividers`가 공유 헬퍼를 소비했다. 이후 `appendActivePaneBorder`는 위 FP9 대체 기록대로 제거됐고 divider helper만 유지한다.
- **quick terminal 토글 더블-토글 race 수정(quickAnimating 가드)**: 리뷰 백로그 항목. `toggleQuickTerminal`이 `isVisible`로만 분기하고 `quickAnimating` 가드가 없어, 슬라이드/페이드(0.12~0.16s) 중 재토글하면 애니메이션이 겹쳐 — 먼저 시작한 hide의 완료 핸들러(`orderOut`)가 그 사이 새로 show한 패널을 닫아 버리는 race가 있었다. `toggleQuickTerminal` 맨 앞에 `if quickAnimating { return }`를 더해 애니메이션 중 토글을 무시한다(겹침 자체가 없어져 stale 완료 핸들러가 새 패널을 못 닫는다; 짧은 애니메이션 후 다시 토글하면 된다). `quickTerminalLostKey`(자동 숨김)의 기존 `!quickAnimating` 가드와 같은 패턴이라 일관. show/hide 양 경로(슬라이드·center 페이드) 공통. 검증: swift-check + coretext/metal 스모크 + 전체 테스트(Swift 애니메이션은 헤드리스 테스트 불가 — 실제 더블 토글은 앱 수동). **ABI·Zig 무변경**.
- **quick terminal 인디케이터+테두리 코너 겹침 수정(z-order, 당시 구현 기록)**: 옛 minimal grid ring과 탭 점 인디케이터가 겹칠 때 인디케이터를 뒤에 append해 위로 올렸다. 현재 grid ring은 위 FP9 대체에 따라 제거됐으므로 이 z-order 예외도 제품 경로에는 남지 않는다.
- **영속 terminal runtime 후속(부분 구현, 상세 상태는 검증 매트릭스가 단일 출처)**: tmux-CC layout driver 대신 `TermRuntimeBackend` seam →
  `maru-sessiond` → 다중 workspace GUI-process-crash-consistent checkpoint → 개별 `maru attach` 순서로 진행한다. 앱 종료 후 PTY 유지,
  기존 `maru.workspace.v1`의 `runtime-handle`과 durable `runtime-state` optional scalar,
  `runtime_handle`/`surface_id` 분리, `MRSH` framed JSON-control/binary-stream protocol,
  `maru host status`·`runtime list/get/end`·`attach`, same-login-UID SSH, controller 1+observer N capability, signal-safe
  `SIGWINCH`→`runtime.resize` ACK/broadcast, canonical Term owner 1개와 무인 TDD/E2E gate는
  [영속 터미널 세션 호스트](persistent-session-host.md)를 단일 출처로 둔다. quick terminal의 현재
  UI/config는 유지하지만 항상 in-process이며 앱 Quit 때 종료한다.

이 단계에서 다루지 않고 별도로 확장하는 입력 영역:

- 기본 terminal input 인코더는 `Ctrl+letter` → C0 control, `Alt/Option` → meta-ESC까지 처리한다. 이 계약은 `src/terminal/input.zig`와 `src/config/keybinding.zig`의 단위 테스트가 지킨다.
- **application-cursor-key 모드(DECCKM)를 구현했다(완료)**: TerminalCore가 `CSI ?1h/l`로 모드를 추적하고, `input.encodeKey`가 `EncodeOptions`로 받아 화살표를 SS3(`\x1bOA`)/CSI(`\x1b[A`)로 전환한다. app host의 `handleKeyEvent`가 매 키마다 active surface core의 현재 모드를 읽어 resolver에 넘기므로(인코더는 터미널 상태를 직접 들지 않음), vim/less가 모드를 켜고 끄는 대로 즉시 따라간다. unit + host E2E(`?1h` 후 같은 키가 SS3로 PTY에 쓰임)로 검증.
- function key terminal encoding(Home/End/Insert/Delete/PageUp/PageDown/F1~F12)의 xterm legacy 인코딩·키바인딩 매핑을 구현했다(터미널측, Linux CI). AppKit ABI KeyCode(home~f12) + Swift normalizedKeyEvent 매핑으로 물리 키도 연결했다(Swift는 keyCode 캡처만, 인코딩·바인딩은 Zig — native 최소). 특수 비-텍스트 키(Home/End/PageUp/PageDown/ForwardDelete/Insert/F1~F12)는 IME 트랜잭션을 우회해 바로 인코딩 경로로 보낸다(편집/스크롤 selector라 `interpretKeyEvents`에 맡기면 안정적으로 인코딩 안 됨). PageUp/PageDown는 `input.page-keys` 설정으로 가른다(기본 `scroll`=Terminal.app/iTerm2식 스크롤백 페이지 스크롤, `passthrough`=xterm/Ghostty식 `\e[5~`/`\e[6~`를 PTY로 보내는 opt-in; alt 화면에선 항상 앱에 전달). **kitty keyboard protocol(CSI u)을 구현했다(완료, #526/#527)**: 앱이 `CSI > flags u`로 켜면 flag 스택(push `>`/pop `<`/set `=`/query `?`)을 따라 `encodeKey`가 disambiguate 인코딩(escape·Ctrl+key·화살표/기능키 modifier→`CSI {code};{mods}{final}`)으로 분기한다(미활성이면 legacy 그대로 — progressive enhancement). 키 버퍼는 `encoded_key_buffer_len`(8→32)으로 확장. report_events/alternates/associated(release·대체키·연관텍스트)와 F13~F24·legacy `modifyOtherKeys`는 후속이다.
- **macOS 줄 편집 단축키 빌트인 바인딩을 구현했다(완료)**: Cmd+←/→→`\x01`/`\x05`(Ctrl+A/E=줄 시작/끝), Cmd+⌫→`\x15`(Ctrl+U), Option+←/→→`\eb`/`\ef`(단어 이동)를 `keybinding.default_terminal_bindings` 한 데이터 테이블로 셸 시퀀스에 매핑한다(흩어진 특수 케이스가 아니라 테이블). `resolve`는 **사용자 config 바인딩 → 이 빌트인 → (안 묶인 Cmd면) `.ignored` → 아니면 encodeKey** 순으로 본다(`Cmd+S`가 셸에 `s`를 안 박게 하면서 Mac 사용자가 기대하는 줄 편집은 살림 — Ghostty 기본 keybind와 동작 비교). unit 검증.
- **zsh 편집키 셸 통합을 구현했다(완료)**: `$EDITOR`가 vi류(예: nvim)면 zsh가 vi-keymap을 기본 선택해 위 시퀀스(Ctrl+A/E 등)가 self-insert가 되고 사용자 설정이 그걸 조건부로만 emacs로 바꾸면 터미널마다 동작이 갈리는 문제를, 셸 통합으로 메운다(Ghostty·iTerm2·kitty가 하는 정식 기능). 대화형 셸이 zsh면 `ZDOTDIR`을 Maru 통합 디렉터리로 두고, 그 `.zshenv`가 ① 사용자 `ZDOTDIR`을 복원해 설정을 정상 로드한 뒤 ② `.zshrc` 후 첫 프롬프트(precmd 1회 훅)에서 macOS 편집키만 표준 라인 위젯에 바인딩한다(`bindkey -e` 전체 강제가 아니라 **보내는 키만** — 나머지 vi 바인딩 보존). 통합 스크립트는 **zsh 매뉴얼의 ZDOTDIR/스타트업 동작에서 직접 작성**(Ghostty·kitty 스크립트는 GPLv3라 미차용 — ZDOTDIR로 가리키는 메커니즘 자체는 zsh 공개 동작). 현재 **zsh 전용** — bash/fish는 기본이 emacs 편집모드라 위 4단계 login(1) 로그인 셸만으로 편집키가 동작하므로(실측 확인) 명시적 vi 사용자용 통합은 선택적 후속이다. 자세한 정책은 [키 입력과 단축키 경계](key-input-and-shortcuts.md).
- **OSC 133(semantic prompt) 파싱·행 분류 저장 토대를 구현했다(완료, 터미널측 Linux CI)**: 셸이 보내는 `OSC 133 ; A|B|C|D`를 파싱해 각 행을 prompt/input/command로 분류한다(`SemanticPrompt` 병렬 배열 — `wrapped`와 같은 패턴이되 **glyph 쓰기로 리셋되지 않는다**, 셸이 프롬프트를 redraw해도 분류 유지). lineFeed가 영역을 다음 행에 전파(여러 줄 프롬프트/출력 태깅)하고, 스크롤백 ring으로 carry하며, 종료코드(`D;<code>`)를 기록해 `RenderSnapshot.prompt_marks`/`last_command_exit`로 노출한다. RIS·ED2 리셋, alt screen 격리(복귀 시 primary 분류 복원), resize 재할당 처리. 이것은 6-PR OSC 133 작업의 **1번(토대)**이다.
- **② zsh 통합 스크립트가 OSC 133 마커를 emit한다(완료)**: 위 zsh 통합 `.zshenv`가 `precmd`로 직전 명령 끝(`D;$?`)+새 프롬프트 시작(`A`)을, `preexec`로 출력 시작(`C`)을, PS1 끝에 입력 시작(`B`)을 emit한다(`print -rn`·`%{%}`). 두 precmd 훅으로 나눠 — `$?`/D/A는 '맨 앞' 훅(.zshenv가 사용자 .zshrc보다 먼저 실행돼 `precmd_functions` 선두 → 직전 `$?` 정확 캡처, 편집키 one-shot precmd가 뒤에 와도 종료코드 안 틀어짐), 입력 시작 B(PS1 끝)는 '맨 뒤' 훅이 처리한다. **B 훅은 p10k/starship/oh-my-zsh가 자기 precmd에서 PS1을 통째로 재생성해도 살아남도록 매 프롬프트 자신을 `precmd_functions` 맨 뒤로 재정렬(`${(@)…:#…}`)한 뒤 append한다**(코드리뷰 #3 — 안 그러면 프레임워크가 B를 매 프롬프트 제거; Ghostty도 같은 재정렬 방식). **실측 검증**: 실제 `/bin/zsh -i`(프레임워크식 PS1 재생성 + vi-mode .zshrc)를 PTY로 띄워 `A→B→C→D;0`/`D;1` 순서·종료코드·B 생존·편집키(`^A`=beginning-of-line) 공존을 캡처로 확인. core 측 end-to-end 단위 테스트(zsh emit 형태 → 행 분류)도 추가. `MARU_DEBUG=1`이면 app session 화면 덤프가 행별 분류(P/I/C/·)+`last_exit`를 찍어 거터 PR 전에 눈으로 확인 가능. clean-room: zsh 매뉴얼 + semantic-prompts.md에서 직접 작성(Ghostty·kitty GPL 스크립트 미참조).

- **③ reflow가 OSC 133 태그를 carry한다(완료)**: resize의 활성 화면 reflow(`reflow_prompt_marks` 스크래치)와 스크롤백 재-wrap이 산출 행마다 소스 옛 행의 태그를 옮긴다 — 논리 줄은 단일 분류라(lineFeed 전파) 어느 옛 행에서 나왔든 그 태그를 물려받고, 커서 줄(verbatim 보존)은 1:1로 carry된다. PR1의 "reflow 후 `.unknown`" 한계를 제거했고, PR1이 스크롤백 재-wrap에서 `sb_prompt_marks`를 갱신하지 않던 잠재 misalignment(재-wrap 후 태그가 내용과 어긋남)도 함께 고쳤다. **커서 줄 reflow workaround(`reflowCursorLine=false`)는 그대로 둔다** — OSC 133가 있어도 zsh는 SIGWINCH에서 프롬프트를 직접 redraw하므로 그 줄을 안 건드리는 게 여전히 옳다(태그만 verbatim carry). `redraw=0`(셸이 redraw 안 함) 옵션 기반의 능동 reflow는 그 옵션을 보내는 셸이 생기면 후속. unit 검증(넓힘 재-wrap·커서 줄 verbatim·스크롤백 push·스크롤백 재-wrap 정렬), perf 게이트 `core_resize_loop`/`scrollback_rewrap` budget 내.

- **④ 프롬프트 점프 네비게이션을 구현했다(완료)**: Cmd+↑/↓로 이전/다음 프롬프트 블록으로 뷰포트를 점프한다(iTerm2·VSCode식). `core.jumpToPrompt(dir)`가 OSC 133 분류로 "프롬프트 블록 시작"(`isPromptStart` — prompt/input run의 첫 행, 직전이 비-프롬프트)을 절대 행 좌표로 찾아 그 행을 뷰포트 맨 위에 둔다(활성 행이면 바닥). 셸 통합이 없으면 분류가 전부 unknown이라 false(무동작). Swift는 Cmd+↑/↓ keyCode만 감지해 `maru_macos_app_session_jump_prompt(dir)` ABI로 방향만 넘기고(native 최소, scroll_page와 같은 규율), 분류·이동·뷰포트 계산은 전부 Zig가 한다. unit 검증(isPromptStart 블록 경계·스크롤백 프롬프트로 점프·분류 없으면 false). **거터 마크(✓/✗)는 후속(PR5)** — 렌더러 레이아웃(거터 strip vs margin overlay) 설계가 필요해 분리한다.

- **⑤ 거터 마크(✓/✗)를 구현했다(완료)**: 프롬프트 시작 행 왼쪽 가장자리에 명령 성공(초록)/실패(빨강) 세로 색 바. 종료코드를 **프롬프트별로** 저장하려고 행 단위 `SemanticPrompt`를 `RowPrompt{kind, exit}`(분류+종료코드)로 묶었다 — 분류와 한 묶음이라 기존 스크롤/reflow carry가 종료코드도 함께 옮긴다(별도 배열 불필요). OSC 133 `D`가 그 명령의 프롬프트 시작 행(커서에서 위로 가장 가까운 isPromptStart, 스크롤백까지 스캔)에 종료코드를 스탬프한다. 렌더는 **native 최소**: `draw_list`가 exit≠null인 행마다 `GutterMark{row,success}` overlay를 내고, `metal_frame`이 **커서 bar(좌측 세로 부분 사각형, kind=3)를 col 0에 재사용**해 초록/빨강 바로 투영(셰이더 변경 0). 레이아웃 A안(overlay, 그리드/PTY 폭 불변). unit 검증(D 스탬프·스크롤백 carry·거터 overlay emit 성공/실패). 거터 strip 예약 없이 첫 칸 가장자리에 그린다.

- **⑥ OSC 7 cwd 보고를 구현했다(완료, 창 제목 소비는 후속 PR)**: 셸이 매 프롬프트 현재 작업 디렉터리를 `OSC 7 ; file://<host>/<percent-encoded path> ST`로 보고하고, core가 path를 percent-decode해 보관한다(`TerminalCore.cwd`, getter `currentCwd`, ABI `maru_macos_app_session_cwd`로 노출). **베이스(사실상 표준)**: OSC 7은 ECMA-48이 아니라 **VTE(GNOME)가 정의**한 형식으로 iTerm2·Terminal.app·kitty·WezTerm이 채택했다. **의사결정**: (1) host(authority)는 무시하고 첫 '/'부터의 path만 저장한다 — 현재 소비처(창 제목)는 경로만 필요하고, 로컬 단일 호스트를 가정한다(SSH/원격 cwd 구분은 host를 따로 보관해 후속). (2) `file://` 스킴만 받고, 형식 불일치·빈 path·OOM이면 **기존 cwd를 유지**한다(부분/깨진 갱신으로 이전 값을 잃지 않게). (3) percent-decoding은 관대하게 — 잘린/비-hex `%escape`는 '%'를 리터럴로 두고 계속한다. (4) cwd는 셸 상태라 화면 clear엔 안 지우고 **RIS(ESC c)에서만** 공장 초기화한다. (5) zsh emit은 `nomultibyte`로 **바이트 단위** percent-encoding해 UTF-8 path(한글 등)도 디코더가 정확히 복원한다 — `vte.sh`(GPL)는 열람하지 않고 OSC 7 공개 형식에서 직접 작성. **실측 검증**: zsh가 `/Users/me/a b/가`를 `\e]7;file://h/Users/me/a%20b/%EA%B0%80\e\\`로 emit함을 캡처로 확인(공백 `%20`·한글 `가`=`%EA%B0%80` 바이트별), core 파서가 그 역(디코드)을 단위 테스트로 고정. `MARU_DEBUG=1`이면 화면 덤프 헤더에 `cwd=`를 찍는다. **창 제목 반영은 후속 PR에서 완료(아래 ⑥-b).** 탭이 아직 없어 "같은 폴더 새 탭"은 탭 기능 후속.
- **⑥-b 창 제목을 OSC 0/2 제목·cwd로 반영했다(완료)**: 비-`MARU_DEBUG`일 때 `window.title`을 셸/앱 상태에서 갱신한다(frame-loop tick, 변할 때만 set). **베이스**: OSC 0/2 창 제목은 **xterm ctlseqs**(OSC 0=아이콘+제목, OSC 1=아이콘만, OSC 2=제목)로 사실상 모든 터미널이 채택. **의사결정**: (1) **우선순위 `OSC 0/2 제목 > OSC 7 cwd basename > 앱 이름("Maru")`** — 우선순위 로직은 Zig(`core.windowTitle`)가 소유하고 Swift는 빈값 폴백만 한다(native 최소). (2) OSC 1(아이콘만)은 창 제목과 무관하므로 무시. (3) 빈 제목(`OSC 2 ; ST`)은 해제 → cwd basename 폴백. (4) cwd는 **basename**만(전체 경로 아님 — 제목줄 간결, Terminal.app 관례). (5) RIS는 제목·cwd 모두 리셋. `core`: `TerminalCore.title`(소유) + `dispatchOsc`의 `0;`/`2;` 분기 + `setWindowTitle` + `windowTitle` getter, ABI `maru_macos_app_session_window_title`. 기존 `MARU_DEBUG` 진단 제목(`updateDiagnosticTitle`)과 상호 배타(디버그면 진단 제목, 아니면 cwd/제목). unit 검증(OSC 2 설정·OSC 1 무시·빈값 해제→cwd basename 폴백·RIS 리셋). 시각 반영은 GUI라 수동 검증.
- **⑦-B 셸 의미 이벤트 채널(관측/테스트 인프라)을 구현했다(B1 완료)**: 사용자가 방향 B(관측/테스트 인프라)를 택했다. `TerminalCore`가 OSC 133/7을 파싱하며 `types.ShellEvent`(`prompt_start`·`input_start`·`command_start`·`command_end{row,exit}`·`cwd_changed`)를 시간순 스트림으로 기록하고 소비자가 `shellEvents()`/`clearShellEvents()`로 drain한다. **설계 결정**: 이벤트는 POD(소유 문자열 없음) — 행은 발생 시점 커서 행, exit는 D의 값, `cwd_changed`는 경계만 표시하고 cwd 값은 `currentCwd()`가 권위(소유권 단순화, trace는 순서가 정답). 누구도 drain 안 해도 cap(4096)에서 멈추고 overflow 플래그를 세운다(조용한 손실 방지). app session이 프레임마다 drain — `MARU_DEBUG`면 `shell.*` scoped 로그로 찍고 항상 비운다(같은 도메인 데이터를 테스트·디버그 로그·후속 trace writer가 공유 — 관측 가능성 원칙). **검증**: 한 명령 사이클(A→B→C→OSC7→D)이 정확한 경계 이벤트 순서를 내는지, exit 코드(0/130/null)·clear를 결정적 unit으로 단언(= E2E가 명령 경계를 상태가 아니라 이벤트로 단언). 바이트→이벤트는 unit, zsh가 그 OSC 바이트를 emit함은 #287(133)·#296(7)에서 캡처. app session 디버그 로그 투영은 GUI라 수동. clean-room: freedesktop semantic-prompts.md·OSC 7(VTE) 공개 형식 + Ghostty 동작 비교(코드 미복사).
- **⑦-B2 trace 직렬화(writer)를 구현했다(완료)**: B1 이벤트 스트림을 `maru.trace.v1` 텍스트로 굳히는 writer(`observability/trace.zig`의 `renderShellEvents`/`writeEvent`). snapshot 직렬화와 같은 규칙(첫 줄 bare 토큰, `event <i> <kind> surface=<id> [payload]` 라인). 토큰은 ShellEvent와 1:1(`shell.prompt-start`/`shell.prompt-end`/`shell.command-start`/`shell.command-end row=N exit=N|none`/`shell.cwd-changed cwd="..."`). `cwd`는 POD 이벤트가 안 들어 직렬화 시점의 `currentCwd()`를 따옴표·escape(`\` `"`·개행/CR/Tab)해 기록. **검증**: 실제 OSC 133/7을 먹인 core의 이벤트가 정확한 trace 라인으로 직렬화되는지(exit 0/130/none·cwd escape 포함) 결정적 unit. **reader/replay는 두지 않는다** — snapshot.zig처럼 writer만, reader/ReplayRunner는 trace를 재생할 필요(첫 회귀 trace·workspace restore)가 생길 때(⑦-B3). 후속: ⑦-B2b live `MARU_TRACE` 레코딩(실 세션→파일), ⑦-B3 reader/ReplayRunner + replay용 output/input/resize 이벤트.
- **IME 1단계를 구현했다(완료, 제품 경계 gate 잔여)**: `MaruMetalTerminalView`가 `NSTextInputClient`를 채택해 수정자 없는 타이핑을 입력기에 위임한다(한글 조합 동작, 터미널 확정 UTF-8은 surface별 ordered input queue로 전송하며 replay key만 현재 입력 모드로 인코딩). Ctrl/Cmd 조합은 입력기를 우회하고 **물리 키코드 기준으로 레이아웃 독립 매칭**한다(ABI v18 raw_key_code + Zig keycode.zig — 한글 모드에서도 Ctrl+B=0x02·Cmd+C/V 동작, 라틴 배열 결과는 보존). 자세한 정책은 [키 입력과 단축키 경계](key-input-and-shortcuts.md). preedit은 `Surface`의 client-local overlay가 로컬/host-backed base snapshot에 공통 합성하고, 조합 폭은 `RenderSnapshot.ambiguous_wide`를 단일 출처로 쓴다. current host의 scrolled snapshot은 canonical live cursor를 보존하며 `screen_viewport_scrolled_v1` capability가 mode bit 의미를 협상한다. capability 없는 구 v2 host는 visible cursor가 해당 snapshot의 live bottom을 증명할 때만 preedit/candidate를 허용하고, hidden/ambiguous snapshot은 fail-closed한다. 이 증거는 snapshot별로 계산해 latch하지 않는다. IME 판정 상태 머신은 Zig app session이 소유하고, 확정 UTF-8과 replay key를 같은 ordered queue에 확정→replay 순서로 예약한다. cross-window workspace move는 source/destination terminal admission과 moved queue transfer allocation을 all-or-none 선예약하고 pending queue를 함께 이전한다. 원격 nonblocking submit은 bounded preframed frame을 소유한 뒤 전송 구간에 `O_NONBLOCK`을 적용한 `MSG_DONTWAIT` write만 시도하고, remainder는 frame-loop pump가 이어 보낸다. host-backed scrolled `imeBegin`도 `async_scroll_to_bottom_v1` fire-and-forget frame과 stream-local sticky intent를 써 AppKit callback에서 동기 RPC를 기다리지 않으며, 64 KiB direct-key FIFO와 barrier offset이 cap 안의 일반 키를 backpressure/frame encode OOM에도 소유·재시도해 추월/유실을 막는다. FIFO admission 뒤 encode OOM은 retryable이고 pending+new가 64 KiB를 넘는 admission은 효과 0으로 fail-closed한다. blocking mouse/core/resize RPC는 FIFO/barrier를 먼저 flush한다. OOM은 partial/duplicate 대신 0회 전송을 허용한다. exactly-once는 예약 성공 뒤 application admission/submit 범위이며 PTY 소비·원격 durable delivery ACK는 아니다. unit/controlled host-backed 검증은 있지만 실제 구 host binary·AppKit 후보창 픽셀은 남은 제품 gate다. stalled socket은 deterministic socketpair backpressure로 callback이 쓰는 outbound admission의 무블록·wire ordering·direct-key ownership·exact-cap/cap+1·후속 mouse RPC 순서를 자동 검증하지만 실제 AppKit run-loop deadline 계측은 수동/후속이다. 아직: keypad/dead key(function key는 IME 우회로, CSI-u/kitty keyboard 인코딩은 #526/#527로 구현 완료).

- **미구현 프로토콜 audit을 진행했다(focus/mouse/synchronized output/kitty keyboard/kitty graphics)**: Ghostty 레퍼런스와 대조해 빠진 VT 프로토콜을 순서대로 메웠다(전부 머지·`verification-matrix.md` 반영). 각 프로토콜은 progressive enhancement(앱이 DECSET/CSI로 켤 때만 동작, legacy 공존)이고, 거짓 지원을 피하려 "지원 응답 + 실제 동작"을 한 PR로 묶었다.
  - **focus events(DECSET 1004)**: 창 포커스 in/out을 `CSI I`(gained)/`CSI O`(lost)로 PTY 리포트(Swift window key/resign→ABI focus_changed→활성 surface reportFocus). vim FocusGained/Lost가 동작.
  - **mouse reporting(DECSET 1000/1002/1003 트래킹 + 1006 SGR/1016 pixels/x10 인코딩)**: 클릭/드래그/휠을 `CSI < Cb;Px;Py M/m`(SGR) 또는 `CSI M`(x10)으로 PTY 리포트. Swift `buttonNumber`→xterm 0/1/2·`modifierFlags`→mods 비트 변환, shift+click은 셀렉션 override, 휠=버튼 64/65.
  - **synchronized output(DECSET 2026)**: sync 중 metal frame 투영을 hold하고 ESU에 누적 출력을 한 frame으로 그려 tearing/깜빡임을 막는다. DECRQM `?2026$p`로 지원 감지(Ghostty render-skip 동형). **후속(sync-2026 ESU edge)**: per-tick 폴링이 `sync_output`을 샘플하는 순간 이미 다음 BSU가 시작돼 있으면(flush 창<tick) 완성 프레임(ESU)을 못 보고 timeout까지 막던 **MISS**가 있었다 — `MARU_DEBUG` 계측으로 연속 프레임 워크로드에서 sync 막힘의 **약 절반이 MISS**임을 실측(before 14·15 → after 0·0). 리더의 ESU 누적 카운트(`core.sync_esu_count`)를 edge로 소비해(`shouldProjectFrame`의 `esu_advanced`, view_offset 안전판과 동형) 완성 프레임을 즉시 flush한다. Ghostty는 리더가 ESU에서 렌더를 트리거해 회피하지만 maru는 tick 폴링이라 카운트 edge로 동형 효과를 낸다. 정당한 막힘(프레임 미완성, BSU 진행 중)은 그대로 유지(tearing 방지).
  - **kitty keyboard protocol(CSI u, #526/#527)**: 위 키 인코딩 문단 참조 — FlagStack(push `>`/pop `<`/set `=`/query `?`) + disambiguate 인코딩, Shift+Tab backtab fix(code review 발견).
  - **OSC 66(kitty 텍스트 사이징) / OSC 5522(kitty 클립보드) — Ghostty 패리티 후속(미착수, 로드맵)**: Ghostty는 이 둘도 지원(동적 버퍼 사용)하지만 maru는 아직 구현하지 않았다. maru가 목표하는 kitty는 **graphics(APC)·keyboard(CSI u)**이고 이 둘은 완료다 — 66/5522는 별개의 kitty 확장이다. **접두 충돌 없음**을 확인(`"5522;"`는 `"52;"`로 오배치 안 됨). 미지원이라 지금은 `oscMayGrow` 대용량 허용 목록에 안 넣는다(핸들러 없는 OSC 버퍼를 키우면 megabyte를 받아 버릴 뿐 — 낭비). 판단:
    - **OSC 5522(kitty 클립보드) — 낮음**: OSC 52(범용 표준)를 이미 지원하고 프로그램이 폴백하므로 실기능 공백이 아니다. 스트리밍 싱크(아래) 위에서 청크가 거의 공짜로 따라오는 **부산물**로 취급.
    - **OSC 66(텍스트 사이징) — 진짜 후보(큰 렌더러 작업)**: 글자를 셀 배수/분수로 그리는 렌더 기능이라 파싱이 아니라 **fixed-cell 렌더러 확장**(kitty graphics급)이 본체다. 착수 시 파서를 **번호-인식 + 스트리밍 싱크**로 전환하는 트리거로 삼는다(단일 트리거 — [terminal-compatibility-policy.md §OSC52 "장기 방향"](terminal-compatibility-policy.md) 단일 출처). ⚠️ 이 리팩터링 대부분은 **사용자에게 안 보이는 유지보수·미래 대비**다(피크 메모리·파서 내부 불가시) — UX 명분으로 팔지 않는다. 사용자에게 실제 나은 건 이미 구현한 "가시적 상한"(무음 폐기 제거)뿐이다.
  - **OSC 52 클립보드 버퍼(#1201/#1204/후속) — 완료**: 고정 2048 OSC 버퍼가 한 문단(base64 >2KB) 복사를 통째로 버리던 루트커즈를 동적 버퍼로 수정(#1201), 대용량 회수 갭 5건(clipboard_write/osc_buffer 반납·OOM storm·접두 latch·공허 테스트) 수정(#1204), **상한 초과를 notice로 표면화**해 무음 실패 제거(후속). Ghostty와 같은 구조(2048 고정 + 클립보드만 동적 + 오버플로 discard)에 **상한·즉시 반납·가시적 실패로 앞선다**(Ghostty는 상한 없음·무음 폐기). 스트리밍 싱크는 위 OSC 66 트리거로 이연.
  - **kitty graphics protocol(APC, #528/#530/#531 + K1)**: ① 파서+command 토대(`ESC _ G ...` 수집 + control `k=v` 파싱, #528) ② 이미지 디코드+저장(transmit RGBA/RGB base64→`KittyImageStorage`, 같은 id 교체·320MB 총량 한계·`a=d` delete·RIS 비움, #530; 치수 곱 오버플로 crash fix #531) ③ **K1 placement(코어)**: display(`a=p`/`a=T`)를 현재 커서 셀에 placement로 걸어 `(image_id, placement_id)`로 저장(같은 키 교체)하고 `RenderSnapshot.placements`로 노출까지 완료. **베이스**: kitty graphics protocol display data(`p`/`x`/`y`/`w`/`h`/`X`/`Y`/`c`/`r`/`z`/`C` 키). **의사결정**: (1) anchor는 **절대 행**(스크롤백 0..sb_count-1, 이어서 활성 화면)이라 selection/find와 같은 좌표계로 스크롤·eviction과 함께 움직인다(`shiftPlacementsForEviction`이 eviction마다 보정, 화면 밖이면 제거 — `shiftSelectionForEviction`과 동형). (2) **셀 단위 크기(span)는 코어가 계산하지 않는다** — 코어는 셀 픽셀 크기를 모르므로(`Size`는 rows/cols, 마우스 1016도 platform이 픽셀을 주입) source rect(픽셀)와 명시 `c`/`r`만 담고, 픽셀→셀 환산·클립은 셀 메트릭을 가진 **렌더러(K2) 책임**이다(마우스 1016 경계와 정합). `RenderSnapshot.placements`의 `row`는 뷰포트 상대 i32(화면 위로 벗어난 앵커는 음수 — 렌더러가 span으로 가시성/클립 판정). (3) 커서 이동 정책(`C`): 기본은 이미지 아래로 내리되 행 수(`r`)가 명시됐을 때만(자동 크기는 span 미상이라 미이동 — K1 한계), 화면 끝 초과는 스크롤 없이 마지막 행 clamp. (4) placement 상한(`max_kitty_placements`=1024)으로 placement_id 폭주 차단(이미지 320MB·APC 버퍼 한계와 같은 결의 방어선). **검증**: 생성·모든 display 키 파싱·뷰포트 매핑·`a=T` 합성·없는 이미지/`i=0` graceful·같은 키 교체·다른 p 별개·커서 이동(C/r/clamp)·delete가 이미지+placement 동시 제거·RIS 비움·eviction anchor 보정/제거·위 스크롤 시 뷰포트 row 환산을 결정적 unit으로 단언. K1은 화면 렌더 없이 노출까지다. ④ **K2 렌더(완료)**: GpuImage 환산 + per-image 텍스처 + Metal 파이프라인 + ABI v48 — 아래 "kitty graphics K2 렌더" 절. ⑤ **K3 디코드 확장(완료)**: K3a chunked(`m=1`)(여러 APC 누적·480MB 상한·RIS 폐기), K3b zlib(`o=z`)(`std.compress.flate(.zlib)` inflate, zlib bomb 바운드), K3c PNG(`f=100`) — `src/terminal/png.zig` clean-room 디코더로 **8-bit truecolor(color type 2 RGB·6 RGBA, non-interlaced)** 만 디코드(청크 파싱·IDAT zlib inflate·스캔라인 필터 None/Sub/Up/Average/Paeth), grayscale(0/4)·palette(3)·16-bit·Adam7은 graceful 거부. **풀 PNG(전 color type·16-bit)는 라이브러리 벤더링 백로그** — 아래 "kitty graphics PNG 백로그" 절. ⑥ **K4 저장 관리**: K4a 세분화된 delete(`a=d` + `d=` 타깃) **완료** — 기본 `d='a'`(전체), 소문자=placement만/대문자=이미지 데이터까지 free, `a/A`(전체)·`i/I`(image_id[+placement_id])·`z/Z`(z-index) 지원, 나머지(c 커서·n 이미지번호·p/q/x/y/r 위치·f 애니메이션)는 셀 span/이미지번호 필요라 graceful 무시. K4b LRU evict **완료** — 320MB 한도(이제 settable 필드) 초과 시 거부가 아니라 **placement 없는 것·오래된(generation 작은) 것 우선**으로 evict해 자리를 만든다(kitty 명세 권장; Ghostty `evictImage` 동작 비교). 한 장이 한도보다 크면 거부. K4c 텍스처 eviction **완료**(ABI v49) — 코어가 매 frame **살아있는 image_id 집합**(활성 surface 저장소 키)을 `MetalFrame.live_image_ids`로 노출하고, Swift/Metal이 그 집합에 없는 캐시 `MTLTexture`를 evict해 GPU 메모리를 회수한다(delete/evict/RIS 반영). AppSession이 `kitty_uploaded` dedup 상태도 같은 집합으로 prune해 재진입 시 재업로드를 보장(Swift 캐시와 동기). **K4 완료 → kitty graphics 전 단계(K1~K4) 완성.** sixel(DCS 기반)은 별개이고 Ghostty도 미지원이라 후순위. ⑦ **K5 query(`a=q`) 응답 + 자기능력 보고(후속, 미착수)**: 현재 `execKittyGraphics`가 `q`(query)를 `else => {}`로 무시해, kitty graphics 지원 여부·transmit 결과를 묻는 앱(`timg`·`chafa --format=kitty`·kitty `icat`)에 APC 응답을 주지 않는다 → 앱이 미지원으로 판단해 폴백하거나 transmit 후 멈출 수 있다. 베이스: Ghostty `graphics_exec.zig`(query는 load를 시도해 검증한 뒤 `OK`/에러를 APC로 회신하되 실제 저장은 안 함). 동작: `a=q`면 픽셀을 저장하지 않고 control 파싱·검증만 해 `ESC _ G i=<id>;OK ESC \` (또는 에러코드)로 회신. 난이도: 중(transmit 경로에서 "저장"과 "응답"을 분리). 애니메이션(`a=a/c/f`)은 Ghostty도 미구현이라 계속 보류(위 VT 갭 절 "갭 아님" 노트와 동일 결).

## 한글 Grapheme Cluster 렌더링 (HG1~HG4 — NFD 자모 정공법)

목표:
- macOS 파일명 NFD(분해형)로 들어온 한글 conjoining 자모(초성 L+중성 V+종성 T)를 UAX#29 grapheme cluster로 묶어 한 셀에 저장하고 음절로 셰이핑·렌더한다. `ls` 출력의 한글 자모 분리·폭 2배 깨짐을 고친다.
- 상세·설계 결정·검증은 [Grapheme Cluster 저장·렌더링 전략](grapheme-clustering.md)을 단일 출처로 둔다.

배경(현황 — "계획에 있었나/구현 안 됐나/누락인가"): 전략([폰트 전략](font-strategy.md))은 "grapheme cluster는 UAX#29로 분절"을 적었으나 구현은 **combining 1개 저장**(`types.Cell.combining: ?u21`)에서 멈춘 알려진 후속이고, **한글 NFD 케이스는 계획에서 누락**됐다(다중 코드포인트 예시가 ZWJ 이모지·국기·skin-tone에 한정, docs 전체에 NFC/NFD/자모 0건). `width.zig`의 `isKeycapCombining` 주석도 "다중-combining 저장이 근본 해법"이라 자인.

결정: NFC 정규화로 때우지 않는다(옛한글은 NFC로도 안 합쳐짐 + 터미널은 원본 코드포인트 보존 — selection/커서/재그리기 정합). **베이스 = UAX#29 GB6/GB7/GB8**(공개 명세). Ghostty식 grapheme side-storage는 **동작/설계 개념만 비교(clean-room — 자료구조·코드 미복사)**. 저장은 **B 방식 — `Cell.grapheme_id: u32` + `TerminalCore.grapheme_store`**로 maru의 `link`/`link_store` 패턴을 재사용한다(무손실 — 긴 ZWJ cluster도 안 잘림, id라 셀 이동에 키 안정, combining 없는 셀은 0 비용).

완료 기준:
- NFD 한글(초성+중성+종성)을 한 cluster로 묶어 cell width 2칸·음절 글리프 렌더(완성형 NFC와 동일 결과).
- 셀이 다중 코드포인트 grapheme을 저장(단일 combining 모델 해소).
- 옛한글·ZWJ 이모지·국기(RI)·skin-tone가 같은 cluster 경로를 탄다.
- fixture-oracle + 실제 `ls` 렌더 캡처.

분해 (HG1~HG4 — 상세는 설계 문서 §5):
- **HG1 — 코어 grapheme 분절**: UAX#29 cluster boundary + Hangul L/V/T(GB6/7/8) 분류·묶기, cluster 단위 폭(base 초성 2칸·후속 V/T 0폭 흡수). 순수 Zig 단위(NFD "한글"→음절 2개·각 2칸, 옛한글).
- **HG2a — 셀 다중 코드포인트 저장(B)**: `Cell.grapheme_id: u32` + `TerminalCore.grapheme_store`(link 패턴), `RowCodepoints`·`appendRowUtf8`·trace/snapshot 직렬화 확장(무손실), eviction·clear·덮어쓰기 시 id 회수(수명 관리).
- **HG2b — 기존 combining 경로 통합**: VS16·키캡·skin-tone·국기를 새 모델로 이전 + 단일-combining hack 3곳(`isKeycapCombining` 경유) 제거. 동작 변경 아님(모델 이전) — 기존 이모지/키캡 테스트 green 유지가 합격선.
- **HG3 — 렌더·셰이핑 통합**: `coretext_smoke.m`/`coretext_shaper.zig`가 cluster 전체를 CTLine으로 셰이핑(글리프 합성은 CoreText), atlas cache key 정합.
- **HG4 — 검증·fixture**: NFD `ls`·옛한글·정렬(vim/tmux/htop) fixture-oracle + 렌더 캡처.

각 단계는 작은 PR(progressive enhancement, legacy 공존). **현황: 설계 완료([grapheme-clustering.md](grapheme-clustering.md)) — 미착수. HG1부터 진행.**

## VT 호환성 갭 (G1~G14 — ✅ 전부 구현 완료; 아래는 각 갭의 근거·구현 노트)

확정 순서(아래 "의존성·확정 순서")의 1번 "BCE + 작은 VT 갭" 중 **BCE는 완료**(EL/ED/ECH/DCH/스크롤이 pen 배경을 carry — `core.zig`의 eraseInLine/eraseInDisplay/eraseCharacters/scrollRange)이고, 여기 모은 것이 남은 "작은 VT 갭"이다.

**방법론**: 2026-06-16 `references/ghostty/src/terminal/`(sgr.zig·stream.zig·modes.zig·osc.zig·Tabstops.zig·charsets.zig·dcs.zig)와 `src/terminal/core.zig`를 1:1 대조해 추출했다. 아래 G1~G14는 **Ghostty가 구현하고 Maru가 미구현**인 진짜 갭이다(레퍼런스도 미구현인 항목은 맨 아래 "갭 아님" 노트로 분리). **베이스 = Ghostty 동작 비교(clean-room — 자료구조·코드 미복사, 동작/의미만)** + 각 시퀀스의 1차 명세(ECMA-48·xterm ctlseqs). 진행은 우선순위 순으로 각자 작은 PR(progressive enhancement, legacy 공존), 위 "미구현 프로토콜 audit"과 같은 규율로 "지원 응답 + 실제 동작"을 한 PR로 묶어 거짓 지원을 피한다. G 번호는 우선순위 순(재조정되면 라벨이 단일 출처).

### 높음 (실사용 타격 큼)

- **G1 — SGR 확장 속성 — 완료**: 초기 G1a/b/c(strikethrough 9/29·overline 53/55·dim 2/22)에 더해 잔여를 채움. **blink(5/6/25)**: `Style.blink` + **실제 점멸 렌더(config 게이트)** — `CellColors.blink_on`(app이 커서 점멸과 같은 `blink_visible` 500ms 위상 wiring)을 off 위상에 `packForeground`가 전경=배경색으로 숨긴다(conceal과 같은 결). 위상 전환 시 `viewportHasBlink()`면 full rebuild(blink 셀은 suffix-trim 불가). **config `text.blink`(기본 false=정적 — WCAG 발작 위험 우려, iTerm2 등도 기본 끔)**으로 켜야 깜빡인다(꺼지면 blink_on 항상 true → 정적, idle 재투영 없음). **conceal(8/28)**: `Style.conceal` + `packForeground`가 전경을 그 셀 배경색으로 풀어 글자를 invisible(비밀번호 프롬프트). **double underline(21)**: `Style.underline_double`(SGR 21·`4:2` colon이 set, 4·24가 clear) + `draw_list`가 하단 텍스트 선(reserved 9)과 둘째 선(`LineKind.double_underline`→reserved 7, .m이 gap 띄워 그림) 2개 overlay를 낸다(셀당 한 띠 .m 구조라 2 overlay — overlay capacity 4*cols로 상향). **2중선으로 실제 렌더(다듬기 완료)**. **underline color(58/59)**: `Style.underline_color: Color`(58;2;r;g;b·58;5;n·59=default), `applyExtendedColor`를 `target: *Color`로 일반화해 38/48/58 공용. 렌더: `draw_list.lineOverlay`가 underline kind면 `underline_color`(없으면 전경)로 — **LineOverlay.color 채널로 흘러 ABI/.m 무변경**. nvim/helix LSP 진단 색 밑줄이 이제 정상. 베이스: ECMA-48 SGR·xterm ctlseqs(58 direct/256·4:2 colon 동작 비교, Ghostty `sgr.zig`). 검증: 코어(5/8/21/58 파싱·25/28/24/59 끄기·58;5 indexed) + 렌더러(conceal fg=bg) + draw_list(underline이 underline_color·strikethrough는 전경) + 전체 게이트. blink 애니메이션·double underline 2중선 렌더 모두 완료(blink는 config `text.blink`로 opt-in, 기본 정적).
  - **G1a strikethrough(9/29) — 완료**: `Style.strikethrough` 비트 + `applySgr` 9/29(SGR 0 리셋 포함) + `draw_list.StrikethroughOverlay`(underline과 독립 비트라 같은 셀이 둘 다 방출, 전경색 캐리) + `metal_frame` 2.7 pass `reserved=6`(셀 세로 중앙 가로선 — underline/커서 부분-사각형 경로 재사용, **ABI 무변경**) + Metal `maru_fill_cell_quad`의 `reserved==6`(중앙 ~15% 띠). 베이스: ECMA-48 SGR 9(crossed-out)·xterm ctlseqs. 검증: 코어(SGR 9/29/0 리셋)·draw_list(overlay 방출, underline과 동시)·metal_frame(reserved=6 투영) 단위 + 전체 `check` + swift-check + ABI 계약 + app-build(.m 컴파일). 화면 육안은 GUI 수동. 나머지(blink·dim·conceal·double-underline·underline-color)는 각자 후속 PR(같은 수직 슬라이스 패턴: Style 비트 → applySgr → overlay → reserved kind → Metal).
  - **G1b overline(53/55) — 완료**: `Style.overline` 비트 + `applySgr` 53/55 + `draw_list.OverlineOverlay`(underline·strikethrough와 독립 비트라 한 셀이 셋을 다 방출) + `metal_frame` 2.8 pass `reserved=10`(셀 상단의 가는 텍스트 장식선, hollow cursor 상단 `reserved=4`와 분리) + Metal `maru_fill_cell_quad`의 `reserved==10`. 베이스: ECMA-48 SGR 53(overlined)·xterm ctlseqs. 검증: G1a와 동일 게이트(코어·draw_list·metal_frame 단위 + 전체 `check` + swift-check + ABI 계약 + app-build). 화면 육안은 GUI 수동.
  - **G1c dim/faint(2) — 완료**: `Style.dim` 비트 + `applySgr` 2(+ SGR 22가 bold·dim 둘 다 off — ECMA-48 normal intensity) + `metal_frame.packForeground`가 전경을 셀 배경 쪽으로 0.5 보간(`lerpHalf`). strikethrough/overline과 달리 "선"이 아니라 reverse처럼 **전경색 변형**이라 draw_list·host·ABI·Metal `.m` 전부 무변경(packForeground만 손댐). 베이스: ECMA-48 SGR 2(faint) + Ghostty `faint-opacity` 기본 0.5 동작 비교(maru 전경색엔 alpha가 없어 alpha 0.5 over bg와 같은 효과를 RGB 보간으로). 검증: 코어(2/22/0 리셋)·metal_frame(packForeground 보간) 단위 + 전체 게이트. 화면 육안은 GUI 수동. 남은 SGR 속성: blink·conceal·double-underline·underline-color.
- **G2 — OSC 색/클립보드/알림**: `OSC 10/11`(fg/bg 색 질의·설정)·`OSC 4`+`104`(팔레트 설정/reset)·`OSC 52`(클립보드)·`OSC 9`/`777`(데스크톱 알림)·`OSC 110/111`(색 reset). 베이스: Ghostty `osc.zig`·xterm ctlseqs. 영향: **OSC 10/11 무응답이 가장 실질적** — nvim 등이 배경 밝기를 못 읽어 light/dark 오판; OSC 52는 SSH에서 tmux/nvim 클립보드 복사 결손. 난이도: 10/11 질의응답 하, 4/104 중, 52 중(base64+`clipboard-write` 권한 — 호환성/보안 정책 참조), 9/777 중(platform 알림 연동).
  - **G2a OSC 10/11 질의 응답 — 완료**: `dispatchOsc`에 `10;`/`11;` 분기 + `dispatchOscColorQuery`. spec이 `?`면 현재 전경/배경색을 xterm 형식 `OSC <code> ; rgb:rrrr/gggg/bbbb ST`(8-bit를 16-bit로 복제)로 `appendResponse`. 색은 코어가 `Color.default` 추상만 알아, platform이 `setDefaultColors(theme.fg, theme.bg)`로 주입(셀 메트릭 `setCellMetrics`와 같은 platform→core 주입 패턴, renderFrame 매 tick). 색 **설정**(`OSC 10;<spec>`)은 렌더 반영이 필요해 후속(지금은 질의만, 설정 spec은 소비). 베이스: xterm ctlseqs OSC 10/11. 검증: 코어(OSC 10/11 `?` → rgb 응답, 설정 spec 무응답) 단위 + 전체 게이트 + swift-check + app-build. 나머지(설정·OSC 4/104·9/777·110/111)는 후속.
  - **G2b OSC 52 클립보드 코어 파싱 — 완료(platform wiring 후속)**: `dispatchOsc`에 `52;` 분기 + `dispatchOscClipboard`. `52;<targets>;<base64>` 쓰기를 base64 디코드해 `clipboard_write` pending에 둔다(`pendingClipboardWrite`/`clearClipboardWrite` getter, 16MB 상한). **코어는 파싱만** — 실제 clipboard 쓰기·정책(`osc52.write`)은 app/platform 책임(클립보드는 OS 리소스라 native 소유 — terminal-compatibility-policy.md §OSC52 "TerminalCore parses OSC52, app/platform layer만 실제 read/write"). 읽기(`?`)는 원격 세션의 clipboard 탈취 방지로 코어가 무시(platform ask UI는 후속). 베이스: xterm/iTerm2 OSC 52(사실상 표준). 검증: 코어(write base64 디코드·read/빈 데이터 무시) 단위 + 전체 게이트.
  - **G2b-w OSC 52 platform wiring — 완료**: 코어 pending을 OS clipboard에 실제로 반영. `AppSession.pendingClipboard()`가 코어 `pendingClipboardWrite()`를 dupe해 Zig 소유 `clipboard_out_buffer`로 돌려주고 코어 pending을 비운다(한 번 쓰고 소비). ABI v50 `maru_macos_app_session_pending_clipboard`(copy_text와 동형 pull 패턴 — Swift가 Zig 버퍼를 받아 `NSPasteboard.setString`, 클립보드는 OS 소유). Swift `drainOsc52Clipboard()`를 `renderTick` tick 직후 호출(활성 surface 매 tick). **정책 gate**: write는 기본 **allow**(사용자 결정 2026-06-20 — 로컬 단일 사용자 데스크톱 터미널이라 트래킹 앱의 드래그 복사를 시스템 클립보드에 반영; iTerm2/Ghostty도 유사). 정식 config 키 `osc52.write`·요청별 ask UI는 후속. 읽기(`?`)는 코어가 계속 무시(원격 clipboard 탈취 방지, read=deny). 검증: ABI 계약 테스트(v50) + swift-check + app-build + 전체 게이트.
  - **G2c OSC 4/104 팔레트 set/reset/query — 완료**: 앱이 256색 팔레트 엔트리를 재정의(`OSC 4 ; <index> ; <spec>` — 쌍 반복)·질의(`spec == ?` → `OSC 4 ; idx ; rgb:rrrr/gggg/bbbb ST`)·리셋(`OSC 104 [ ; <index> ]*` — 인덱스 없으면 전부). 코어 상태 `palette_override: [256]?Rgb`(null = 기본 xterm256), RIS에서 전부 null. 색 명세 파서 `color.parseSpec`(`rgb:r/g/b` 채널당 1..4 hex 스케일·`#rgb`/`#rrggbb`)는 backend-neutral `color.zig`에 둬 후속 OSC 10/11 set이 재사용(`types.xterm256`/`types.parseSpec`로 재노출 — core가 `color`를 지역 변수명으로 써 파일 import가 충돌). **렌더러 소비**: `CellColors.palette`(코어 `paletteOverride()`를 가리키는 포인터)를 `resolveColor`/`packBackground`가 `.indexed` 풀 때 먼저 본다 — app이 활성·비활성 pane 각각 자기 core 팔레트로 wiring(팔레트는 per-터미널 상태). 코어는 표만 보관(셀 픽셀/렌더 모름 — K1 경계). 베이스: xterm ctlseqs OSC 4/104. 검증: 코어(set/query/multi-pair/104 one·all/잘못된 spec 무시/RIS) + 렌더러(override가 xterm256보다 우선·폴백) 단위 + 전체 게이트 + swift-check + app-build.
  - **G2d OSC 10/11 set + 110/111 reset — 완료**: `OSC 10`(전경)·`OSC 11`(배경) 색 설정(`color spec` → override)·질의(`?` → override 또는 주입 theme 회신)·리셋(`OSC 110`/`111` → override null). 코어 상태 `default_fg_override`/`default_bg_override`(null = theme 기본), `setDefaultColors`(theme 매 tick 주입)와 별개라 주입이 set 값을 안 지운다. `dispatchOscColorQuery` → `dispatchOscDefaultColor`(set+query 통합), `defaultFgOverride()`/`defaultBgOverride()` getter, RIS에서 null. 색 명세는 G2c의 `types.parseSpec` 재사용. **렌더러 소비**: app이 `CellColors.default_fg/bg = override orelse theme`로 wiring(활성·비활성 pane 각자 자기 core) — default 전경 텍스트·SGR reverse 스왑·default 배경 셀에 반영. **화면 clear color(빈 영역)**: `MetalFrame.terminal_bg`(ABI v51 — 구조체 끝에 추가해 기존 offset 불변) = `default_bg_override orelse theme.background`를 Swift가 render pass clearColor로 쓴다(기존 하드코딩 clear가 theme도 무시하던 갭도 동시 수정 — 기본은 theme.background로). 베이스: xterm ctlseqs OSC 10/11/110/111. 검증: 코어(set/query가 override 반영/110·111 reset/RIS) 단위 + ABI 계약(v51) + 전체 게이트 + swift-check + app-build.
  - **G2e OSC 9/777 데스크톱 알림 코어 파싱 — 완료(platform wiring 후속)**: `OSC 9 ; <message>`(iTerm2 — title 없음·body=message)·`OSC 777 ; notify ; <title> ; <body>`(rxvt)를 파싱해 `notification_title`/`notification_body` pending에 둔다(`pendingNotification()` → `?{title,body}` getter, `clearNotification()`). **OSC 9 ConEmu 충돌 가드**: OSC 9는 ConEmu가 `9;1`(sleep)·`9;2`(msgbox)·**`9;4`(progress)**·`9;9`(cwd) 등으로도 써서, `<숫자>;...` 형태면 ConEmu 서브커맨드로 보고 소비만 한다(알림 안 함) — 특히 `9;4` progress가 진행바마다 알림 폭탄이 되는 걸 막는다. **베이스/결정**: iTerm2 OSC 9(body=전체) 기준, ConEmu 분기는 Ghostty `osc/parsers/osc9.zig` 직독해 동작 비교(Ghostty는 미완성 ConEmu를 알림으로 폴백하나, maru는 `<숫자>;` 패턴 전체를 보수적으로 소비해 오발사 확실 차단 — 순수 텍스트·단일 숫자 알림만 발사). **코어는 파싱만** — 실제 네이티브 알림(UNUserNotificationCenter)은 platform 책임(알림은 OS 리소스 — OSC 52 클립보드와 같은 경계). 알림은 transient라 RIS 대상 아님(매 tick drain). 검증: 코어(iTerm2/rxvt 파싱·body 내 `;`·ConEmu 9;4/9;1 무시·notify 외 777 무시) 단위 + 전체 게이트.
  - **G2e-w OSC 9/777 platform wiring — 완료**: 코어 pending 알림을 실제 네이티브 알림으로 띄운다. `AppSession.pendingNotification()`이 코어 `pendingNotification()`(title/body)을 Zig 소유 버퍼로 dupe해 돌려주고 코어 pending을 비운다(한 번 쓰고 소비). ABI v52 `maru_macos_app_session_pending_notification`(has + title/body 2-문자열 pull — copy_text/pending_clipboard와 동형). Swift `drainNotification()`을 `renderTick` tick 직후 호출(활성 surface 매 tick) → `UNUserNotificationCenter`로 표시(OSC 9는 title 없어 앱 이름 "maru"로 폴백). **권한**: 최초 1회 `requestAuthorization`(번들 ID 있을 때만 — bare app shell은 graceful skip). 클립보드와 달리 **env 게이트 없음** — 알림은 OS authorization이 게이트하는 저위험 표면(iTerm2/Ghostty도 기본 허용). 검증: ABI 계약(v52) + swift-check + app-build + 전체 게이트. **이로써 G2(OSC 색/클립보드/알림) 전체 완료** — OSC 10/11 query·set·reset, OSC 4/104 팔레트, OSC 52 클립보드, OSC 9/777 알림.
- **G3 — charset 지정 (DEC 라인드로잉) — 완료(SS2/SS3 제외)**: `ESC ( <f>`(G0)·`ESC ) <f>`(G1) 지정(`f`='0'=dec_special·'B'=ascii)·SI/SO(0x0e/0x0f)로 G0/G1을 GL에 호출·print 시 `translateCharset`로 변환(dec_special: 0x60..0x7e→box `┌─┐│` 등 30자). `escape_intermediate`가 intermediate 바이트(`escape_intermediate_byte`)를 기억해 final과 함께 `designateCharset`로 해석(전엔 final만 소비). 상태 `charset_g0`/`charset_g1`/`charset_gl`, RIS에서 ascii·GL=G0 초기화. **베이스/결정**: VT100 special graphics·xterm ctlseqs, 변환표는 Ghostty `charsets.zig` dec_special 직독해 동작 비교(코드 미복사). **SS2/SS3·G2/G3 지정(`ESC */+`)·british(`ESC ( A`)는 제외** — box drawing은 G0/G1+SI/SO가 사실상 전부고 SS2/SS3는 드물어 후속. 검증: 코어(ESC ( 0 박스·SO/SI G1/G0 호출·ESC ( B 복귀·RIS 초기화, dump 정확 단언) + 전체 게이트. 영향: `dialog`·`mc`·구형 ncurses 보더가 이제 `qx lk` 대신 `─│ ┌┐`로 정상.
- **G4 — 동적 탭스톱 — 완료**: `CBT`(`CSI Ps Z` backtab)·`HTS`(`ESC H` set)·`TBC`(`CSI Ps g` clear: 0=커서 열·3=전체). `tabstops: []bool`(cols 길이, 기본 col%8==0)로 교체 — `writeTab`/`cursorBackTab`이 `isTabstop`으로 다음/이전 스톱을 찾는다(전엔 8칸 하드코딩). resize는 `rebuildTabstops`로 새 cols에 맞추되 겹침 보존·새 열 8칸 기본(OOM이면 isTabstop이 8칸 폴백 — best-effort라 resize 불실패). RIS에서 8칸 기본 복원, deinit에서 해제. 베이스: VT100 HTS/TBC·ECMA-48 CBT(Ghostty `Tabstops.zig` 동적 set/unset 동작 비교). 검증: 코어(기본 8·HTS 커스텀·CBT 역이동·TBC 0/3·RIS·resize 후 기본 유지) + perf(core_resize_loop 예산 내) + 전체 게이트. 영향: **Shift+Tab backtab**이 TUI 폼 역방향 이동에서 동작, `tput`·비표준 탭폭 정렬 정상.

### 중간

- **G5 — REP 글자 반복 (`CSI Ps b`) — 완료**: `last_printed_cp`(putCell이 추적)를 N회(기본 1) `writeCodepoint`로 반복(wrap·IRM·DECAWM·charset 적용). 출력 없으면 무동작, RIS에서 0. 베이스: ECMA-48 REP(Ghostty `printRepeat` 동작 비교). 검증: `a` + `CSI 3 b` → `aaaa`.
- **G6 — IRM insert mode (`CSI 4h/l`) + 비-private ANSI 모드 — 완료**: 비-private `h`/`l`을 `setAnsiModes`로 디스패치(현재 IRM=4만, 그 외 소비). IRM on이면 putCell이 쓰기 전 `insertChars(cell_width)`로 삽입(오른쪽 밀기). RIS off. 베이스: ECMA-48 IRM(Ghostty `modes.zig` insert=4). 검증: `Xb` home `CSI 4h` `A` → `AXb`.
- **G7 — SU/SD 스크롤 (`CSI S`/`CSI T`) — 완료**: `CSI Ps S`=scroll region N줄 위로(`scrollRangeUp`, history 미보관 — 명시 스크롤이라 IL/DL처럼 편집 취급), `CSI Ps T`=아래로(`scrollRangeDown`). 기존 `scrollRange` 재사용. 베이스: ECMA-48 SU/SD(Ghostty `scrollUp`/`scrollDown`). 검증: 3줄 채우고 `CSI S` → 위로 팬.
- **G8 — DECAWM autowrap off (`?7l`) — 완료**: `autowrap: bool`(기본 on) 필드 + `setPrivateModes`에 7. putCell이 마지막 칸을 채울 때 autowrap on이면 `pending_wrap`(deferred wrap), off면 wrap 없이 마지막 칸에 머물러 덮어쓴다. RIS on. 베이스: DEC DECAWM(Ghostty `modes.zig` wraparound=7). 검증: `?7l` 후 6칸 채우고 7번째 글자가 마지막 칸 덮어씀.
- **G9 — DECSCNM 화면 반전 (`?5`) — 완료**: 코어 `reverse_screen` 플래그(`setPrivateModes` 5, 바뀌면 fullDirty) + getter `reverseScreen()`, RIS off. **렌더러**: `CellColors.screen_reverse`를 app이 wiring, `packForeground`/`packBackground`가 `style.reverse != screen_reverse`(XOR)로 전경/배경을 전역 스왑(SGR reverse와 XOR라 둘 다 켜지면 상쇄). 화면 clear color도 반전 시 전경색으로(빈 영역도 반전). app이 활성·비활성 pane 각자 wiring. 코어는 셀 색을 안 바꾸고 플래그만(K1 경계). ABI 무변경(기존 terminal_bg 재사용). 베이스: DEC DECSCNM(Ghostty `modes.zig` reverse_colors=5 + render 동작 비교). 검증: 코어(?5 h/l·RIS) + 렌더러(screen_reverse가 fg/bg 스왑·SGR reverse와 XOR 상쇄) + swift-check + app-build + 전체 게이트.

### 낮음

- **G10 — DECKPAM/DECKPNM (`ESC =`/`ESC >`) — 완료(numpad SS3 인코딩 포함)**: `application_keypad` 플래그 + `handleEscapeByte`의 `'='`(DECKPAM on)·`'>'`(DECKPNM off), RIS off. **numpad SS3 인코딩**: `input.KeyEvent.keypad`(platform이 `keycode.isKeypad(raw_key_code)` macOS keypad keyCode로 판정 — keycode 지식은 platform) + `EncodeOptions.application_keypad`(core가 전달). `encodeKey`가 keypad+app 모드면 SS3(`ESC O p`..`y`=0..9·`ESC O n`=.·`ESC O M`=Enter·연산자 j/k/m/o·`ESC O X`==)로, numeric 모드(또는 비-keypad)면 일반 char/CR. **새 Key 변종·ABI 구조체 변경 없음**(기존 raw_key_code 사용 → 버전 불변). 베이스: VT220 application keypad·DEC DECKPAM/DECKPNM(Ghostty `modes.zig` 동작 비교). 검증: input(numpad 0-9/연산자/Enter SS3·numeric char/CR·비-keypad 무영향) + ABI 계약 + app-build + 전체 게이트.
- **G11 — DECALN (`ESC # 8`) — 완료**: `escape_intermediate`가 `#`+`8`을 `decAlign`으로(화면 전체 'E' 기본 attr + 커서 home). 그 외 intermediate는 기존 charset 경로. 베이스: DEC DECALN(Ghostty `decaln`). 검증: `ESC # 8` → 화면 전체 'E', 커서 (0,0).
- **G12 — BEL·NEL·VT/FF — 완료(ABI v53)**: BEL(0x07)→시스템 벨, NEL(`ESC E`)→CR+LF(다음 줄 0열), VT(0x0b)/FF(0x0c)→LF(col 유지). 전엔 BEL/VT/FF는 `<0x20 return`으로 폐기·NEL은 ESC else 소비. **BEL platform**: 코어 `bell_pending`(bool — 한 tick 1회로 합쳐 벨 폭주 방지) + `takeBell()` getter, ABI v53 `take_bell`(1/0 반환), Swift `drainBell()`이 `renderTick`마다 `NSSound.beep()`(벨은 OS 소유 — OSC 52/9·777과 같은 경계). NEL은 `markCursorMoveDirty`+`lineFeed`로 CR+LF, VT/FF는 `lineFeed`로 col 유지 줄내림. 베이스: ECMA-48 BEL/NEL·VT100(Ghostty `stream.zig` bell/next_line/linefeed 동작 비교). 검증: 코어(BEL pending 1회 소비·NEL=CR+LF·VT/FF=LF col 유지) + ABI 계약(v53) + swift-check + app-build + 전체 게이트. 영향: ctrl-G·셸 에러 벨이 울리고, `printf '\f'`/`\v`/`ESC E`가 줄을 내린다.
- **G13 — 마우스 1015 (urxvt 인코딩) — 완료**: `MouseFormat.urxvt` + `setPrivateModes` 1015. 인코딩은 x10 Cb(32 offset)·1-based 셀 좌표를 바이트 대신 십진 `CSI Cb;Px;Py M`(release Cb=3)로 — 좌표 무제한. 베이스: urxvt 1015(Ghostty `mouse_format_urxvt`). 검증: `?1015h` → mouse_format=urxvt.
- **G14 — DECRQSS + DCS 상태기계 — 완료**: 파서에 **DCS 상태 신설**(`dcs`/`dcs_escape` — `ESC P ... ST`, OSC와 동형이되 ST 종료만). `handleEscapeByte`의 `'P'`가 진입, `dcs_buffer`(64B, overflow 폐기)에 모아 `dispatchDcs`로. **DECRQSS**(`DCS $ q <req> ST`): `m`=현재 pen을 SGR로 재구성(`DCS 1 $ r 0;1;4;38;5;n;58;2;… m ST` — appendResponse 조각 누적, `applyExtendedColor` 역방향), `r`=DECSTBM scroll region(top;bottom 1-based), ` q`=DECSCUSR 커서 스타일(shape+blink 역매핑 1..6), 그 외=`DCS 0 $ r ST`(invalid). 미지원 DCS(Sixel/DECDLD)는 소비만 — **이 상태기계가 그 토대**. 베이스: VT420/xterm DECRQSS(Ghostty `dcs.zig` hook/put/unhook 동작 비교). 검증: 코어(SGR 재구성 m·DECSTBM r·커서 q·invalid Z) + 전체 게이트. 영향: SGR 상태 질의·tmux 능력 협상에 응답, `$q`가 화면에 새지 않음.

### 갭 아님 (레퍼런스도 미구현 — 보류)

- **DECSTR soft reset (`CSI ! p`)**: **Ghostty도 미구현**(repo 0건, `CSI p`는 DECRQM만 처리). vim/tmux가 종료 시 보내지만 Ghostty가 무시하고도 동작 → 우선순위 낮음. 한다면 베이스는 ECMA-48/xterm ctlseqs 직접(1차 레퍼런스 없음).
- **Sixel 그래픽 (DCS 기반)**: Ghostty 미구현, kitty graphics(K1~K4 완료)로 대체되는 흐름. G14의 DCS 상태기계가 생기면 토대만 공유. 보류.
- **kitty graphics 애니메이션 (`a=a/c/f`)**: Ghostty도 파싱만 하고 실행은 "unimplemented" 에러 반환. 보류(아래 kitty 절 K5 참조).

## kitty graphics PNG 백로그 (고민 거리 — 미결정)

K3c는 `f=100` PNG를 **8-bit truecolor(RGB/RGBA, non-interlaced)** 만 maru 자체 디코더(`png.zig`)로 처리하고, 나머지 변종은 graceful 거부한다. "풀 PNG(전 color type·16-bit·인터레이스)"로 넓힐지는 **미결정 백로그**다.

- **현황 조사(2026-06-16)**: Ghostty는 PNG를 손으로 안 짜고 **wuffs(벤더링 C 라이브러리, lazy dep)** 로 디코드한다(`references/ghostty` 확인). wuffs는 PNG·JPEG·전 color type·bit depth·인터레이스를 덮는 방대한 메모리-안전 코덱이다. 즉 "Ghostty 수준 풀 PNG"는 손코덱으로 재현하기엔 비현실적.
- **직접 짜기 리스크**: 신뢰 불가 바이너리 파싱의 메모리 안전(OOB/overflow), 스캔라인 필터 재구성 버그, 미지원 변종 조용한 실패, 인터레이스/16-bit 추가 복잡도. (그래서 풀 범위는 손코덱 비권장.)
- **선택지(결정 시)**: (A) stb_image(단일 헤더 C) 또는 wuffs 벤더링 — 풀 PNG 즉시, 의존성 1개(현재 maru는 std+OS 프레임워크만이라 정책·이식성[Linux/Win/web] 영향 합의 필요). (B) 손코덱 점진 확장(palette→grayscale→16-bit) — 의존성 0, 코드/테스트 부담↑. (C) 현행 유지(8-bit truecolor + graceful 거부).
- **현재 결정(사용자 합의)**: C — 8-bit truecolor만, 풀 PNG는 실제 필요(미지원 PNG를 보내는 워크플로 발생) 시 A/B를 그때 합의해 진행.

## kitty graphics K2 렌더 (완료 — 화면 육안 확인은 GUI 수동)

K1(placement 코어)에 이어 **실제로 이미지 픽셀을 화면에 그리는** 단계다. kitty graphics의 가장 큰 단계로, 코어 노출 → 렌더러 환산 → ABI → Swift Metal 4층을 모두 건드렸다. 작은 PR(K2a~K2d)로 쪼개 각 층을 TDD로 검증했다(화면 픽셀 출력은 GUI라 육안 수동 검증).

**베이스**: kitty graphics protocol(display data·z-index 의미). **레퍼런스 동작 비교**: Ghostty(`src/renderer/image.zig`)가 같은 프로토콜을 어떻게 렌더하는지 **동작만** 확인했고(이미지당 개별 텍스처·3-pass z·CPU 뷰포트 클립·premultiplied alpha), 자료구조 레이아웃·함수 분해는 옮기지 않는다(clean-room). 렌더 프리미티브 추가는 maru의 chrome **GPU quad(C4b)** 선례(draw_list→metal_frame→ABI→Swift + AppSession ArrayList 수집 + dupe 소유 + `layer`로 패스 분리)를 그대로 따른다.

설계 결정(사용자 합의):

- **이미지 GPU 저장 = 이미지당 개별 텍스처**(atlas 패킹 아님). image_id별 `MTLTexture`를 Swift가 캐시하고, per-image **upload generation**이 바뀔 때만 업로드한다(매 frame 픽셀 전송 X). 근거: 이미지는 글리프보다 훨씬 크고 가변이라 glyph atlas에 패킹하면 atlas 크기·eviction과 충돌하고, 동적 추가/제거가 번거롭다. Ghostty도 같은 선택(검증). glyph atlas의 contiguous `raster_pixels` 스트림과는 **별도 채널**이다.
- **z-index = 3-pass**(Ghostty 동등). `z < bg_limit`(=`minInt(i32)/2`)는 셀 배경보다 뒤, `bg_limit <= z < 0`은 셀 배경과 텍스트 사이, `z >= 0`은 텍스트 앞. 정렬된 placement를 두 경계 인덱스로 세 구간으로 나눠 셀배경/텍스트 패스 사이에 끼워 그린다. (chrome GpuQuad의 `layer` 3-pass와 같은 규율.)
- **placement→픽셀 환산은 렌더러 소유**(K1 결정의 귀결). 셀 메트릭(`cell_width_px`/`cell_height_px`, 이미 `MetalFrame`에 있음)으로 dest rect = `grid_pos*cell_size + cell_offset`, dest 크기 = `columns/rows*cell_size`(0이면 source/이미지 크기), source rect는 텍스처 크기로 [0,1] 정규화. 뷰포트 밖(row 음수 등)은 CPU에서 클립/제외.
- **블렌딩 = premultiplied alpha over composite**(컬러 이모지 atlas 경로와 동일 합성 규율, 셰이더만 textured-quad로 분리).

단계(각자 PR, 전부 완료):

- **K2a — 이미지 픽셀 노출 + upload generation(코어, 순수 Zig, 완료)**: `KittyImageStorage`의 이미지(image_id·width·height·bpp·픽셀)를 `RenderSnapshot.images`로 노출하고, transmit/delete마다 per-image generation을 bump해 "업로드 필요" 신호를 만든다(clear/RIS는 카운터 비리셋). 노출/generation 단조/RIS·delete 반영 unit 검증.
- **K2b — placement→GpuImage 환산(렌더러, Zig, 완료)**: `metal_frame.buildGpuImages`가 셀 메트릭으로 `GpuImage`(dest rect·source UV·z-pass)를 만든다. dest/source 기하·3-pass 분류·뷰포트 cull·종횡비를 unit 검증(GPU 없이).
- **K2c — ABI bump 48(완료)**: `MaruAppHostMetalFrame`에 `gpu_images`/`image_uploads`/`image_pixels` 채널 추가, `GpuImageUpload` + `planImageUploads`(generation dedup), C 헤더·버전 동기, `@sizeOf/@offsetOf` 가드 + macOS ABI 계약 테스트.
- **K2d — Swift/ObjC Metal 렌더(완료)**: `maru_metal_renderer.m`가 image_id→`MTLTexture` 캐시(generation 바뀐 것만 업로드, RGB→RGBA 확장), `maru_image_*` 셰이더로 textured-quad, z-pass(maru는 기본 셀 배경 alpha=0이라 셀 패스 전=텍스트 뒤·후=텍스트 앞)로 그린다. AppSession이 매 frame 활성 surface placement를 수집해 ABI로 전달. 컴파일/계약/단위 전부 green, 화면 픽셀은 GUI 육안 수동.

후속(K2 밖): 텍스처 eviction(삭제 이미지 GPU 메모리 해제, 현재 안 그려질 뿐)·비활성 panel 이미지·reflow 정밀 재배치는 K4/별도. K3 디코드 확장(PNG/zlib/chunked).

한계(설계 시점에 알려진): 자동 크기(`r` 미지정) 커서 advance는 **셀 메트릭 주입(접근 B, `setCellMetrics`)으로 구현 완료**(code review #2) — 코어가 셀 픽셀 1쌍을 보관해 이미지 픽셀 높이를 행 span으로 환산하고(렌더러 `buildGpuImages`와 `PlacementGeometry` 공유 — 화면 행 수와 일치), 메트릭 없는 헤드리스만 미이동(K1 fallback). platform→core 메트릭 주입은 마우스 1016 선례와 같은 결이고, 그 외 픽셀↔셀 환산은 여전히 렌더러 책임이다. reflow 후 정밀 재배치·세분화된 `d` 타깃·query 응답·애니메이션은 K3/K4 또는 별도. 멀티 윈도우에서 이미지 텍스처 캐시 소유권은 glyph atlas의 per-session 소유권 재검토와 함께 본다(현재 단일 윈도우 기준).

## 메뉴바 + 커맨드 팝업 (Action 카탈로그, 8단계 후속 — ✅ Stage 0~2 구현 완료)

목표:

- (착수 전 상태) maru는 `NSMenu`를 아예 세팅하지 않아 표준 macOS 메뉴바(maru/File/Edit/View/Window/Help)가 없었다(copy/paste·quit 등은 keybind/`NSApp.terminate`로 동작했지만 메뉴 발견성·접근성이 빠졌다). Ghostty식으로 **메뉴바**와 **커맨드 팝업(Cmd+Shift+P)**을 얹되, 둘 다 같은 **Action 카탈로그**의 두 표면으로 만든다. 베이스: Ghostty `toggle_command_palette`(actions + 바인딩 + 검색 + 실행) / 네이티브 NSMenu·xib. UI는 네이티브(SwiftUI/AppKit), 카탈로그·실행은 Zig 코어(경계 일관 — quick terminal·global hotkey와 같은 규율).

설계 결정(사용자 합의):

- **카탈로그 ABI 형태 = 구조체 배열 + `const char*`**(Ghostty `ghostty_command_s` 형). `MaruCommand{action_key, title, key_display}[]` + count, 문자열은 세션 arena 소유(destroy까지 유효). 근거: maru가 이미 쓰는 두 패턴의 합집합 — `global_hotkeys`의 "배열+count"(세션-불변, 한 번 빌드) + `cwd`/`window_title`의 "Zig-소유 문자열 버퍼". packed-blob(offset/len)은 Swift에 슬라이싱 마샬링을 새로 들여 "네이티브 최소"에 어긋나 기각.
- **clipboard 책임 분리(Q2 재검토 — 경계 정책 반영)**: 처음엔 "copy/paste를 Action으로 승격"으로 합의했으나, **clipboard(NSPasteboard)는 OS 리소스라 네이티브(Swift) 소유**이고 `run_action`→`dispatchAppAction`은 순수 Zig라 NSPasteboard를 못 만진다 → `copy_to_clipboard`를 Zig Action으로 만들면 경계 위반. 정책-정합 버전으로 재구성: **`select_all`만 Zig Action**(코어 selection 상태 → 카탈로그 자동 포함), **copy/paste는 네이티브 유지** — 메뉴(Stage 1)에서 Swift가 기존 `copySelectionToPasteboard`/`pastePasteboardText`에 직접 연결하고, 팝업(Stage 2)엔 Ghostty식 Swift-추가 엔트리로 얹는다(Ghostty도 코어 카탈로그 위에 네이티브 명령을 더한다). 즉 메뉴/팝업 = Zig 카탈로그(run_action) + Swift-네이티브 명령.
- **메뉴 범위 = 5메뉴 다 채우기**. 단, 칸을 채우는 데 maru에 없는 기능이 필요한 항목이 있다(아래 단계에서 분리).
- **순서 = Stage 0(카탈로그 ABI) → 1(메뉴바) → 2(팝업)**.

단계(각자 PR):

- **Stage 0 — Action 카탈로그 ABI(토대) 완료(ABI 35)**: 새 `command_catalog.zig`가 단일 출처 — `entries`(action+action_key+title 정적 테이블, select_tab은 0..8로 펼침), `chordForAction`(resolver 역스캔: 사용자 우선·unbind 존중), `formatChord`(macOS 표시: ⌃⌥⇧⌘ 순 + 키 심볼). `AppSession.buildCommandCatalog`가 init에서 한 번 빌드해 `CommandEntry{action_key, title, key_display}`(extern, 문자열은 세션 arena 소유) 배열로 보관. ABI 34→35: `maru_macos_app_session_command_catalog`(global_hotkeys 패턴) + `maru_macos_app_session_run_action(bytes,len)`(parseAction → dispatchAppAction, 모르는 키 InvalidConfig). `.h` `MaruAppHostCommand`. Swift는 문자열만 왕복(미연결 — Stage 1/2가 소비). 검증: 헤드리스(catalog round-trip[전 action_key가 parseAction으로 복원]·formatChord[⌘T/⇧⌘T/⌥⌘←/⌘1/F5]·chordForAction[빌트인·사용자·unbind]·select_tab ⌘1..9 + 실 세션 catalog 엔트리/바인딩 표시/runAction 디스패치) + boundaries + swift-check + coretext/metal 스모크 + ABI 35 size cross-check.
- **Stage 0.5 — `select_all` Zig Action 완료(ABI 무변경)**: clipboard 분리 결정에 따라 코어 소유인 `select_all`만 Action으로. `core.selectAll`(스크롤백 abs 0 ~ 마지막 화면 행, view_offset 무관 — extractSelection이 trailing 공백 trim) + `Action.select_all`/`parseAction` + `dispatchAppAction`(`activeSurface().core.selectAll()`) + 기본 바인딩 `Cmd+A`(macOS 관례, 셸 Ctrl+A와 무관) + 카탈로그 엔트리 "Select All". ABI 무변경(35 — Stage 0 카탈로그 ABI에 엔트리 1개 추가, 구조 불변). 검증: 코어(selectAll이 스크롤백+화면 전체 선택·스크롤 위치 무관·extractSelection 전체) + parseAction round-trip + 전체 테스트 + boundaries + swift-check + 스모크. copy/paste는 네이티브 유지(Stage 1에서 Swift 연결).
- **Stage 1 — 메뉴바(NSMenu, 네이티브) 완료(ABI 36, 단축키 A안)**: 표준 5메뉴(maru/File/Edit/View/Window/Help)를 `applicationDidFinishLaunching`에서 `buildMainMenu`로 프로그래매틱 구성. **단축키는 A안**(NSMenuItem.keyEquivalent 실제 세팅 → 메뉴에서 단축키가 macOS답게 작동·표시). 그러려면 카탈로그를 확장(**Stage 1a**, ABI 35→36): `command_catalog.keyEquivalent`(글자 소문자/화살표 AppKit unichar 0xF700+) + `modifierMask`(shift=1·control=2·option=4·command=8), `CommandEntry`에 `key_equivalent`/`key_modifiers` 추가, `.h` `MaruAppHostCommand` 확장. **Stage 1b**(Swift): `buildMainMenu`이 카탈로그를 `[action_key:(title,keyEquiv,mods)]`로 읽어 — Zig 액션 항목(New Terminal/Workspace·Split·Focus·Select All·Next/Prev Term/Workspace)은 `catalogMenuItem`로 만들고 선택 시 `runCatalogAction`→`run_action`(활성 세션), 네이티브는 직접(copy/paste=`menuCopy`/`menuPaste`, Quit/Hide/About/Minimize/Zoom=표준 셀렉터, Toggle Full Screen=`window.toggleFullScreen`). `NSApp.windowsMenu`/`helpMenu` 연결. smoke에서도 메뉴를 빌드해 구성 경로를 CI가 구동(OS-global 부수효과 없음). 검증: 헤드리스(keyEquivalent/modifierMask[⌘T→"t"+cmd, ⇧⌘T 소문자 유지, ⌘1, ⌥⌘← unichar] + catalog 엔트리에 key_equivalent/modifiers) + swift-check + coretext/metal 스모크(메뉴 빌드 포함) + ABI 36 size cross-check. 실제 메뉴·단축키는 앱 수동. 한계: copy/paste 외 Edit(Cut/Undo)·Services·Open/Reload Config·New Window·Find는 후속(새 기능 또는 N/A).
- **Stage 2 — 커맨드 팝업(Cmd+Shift+P) — 완료 [방향 전환: Zig 오버레이]**: UI 전략 결정(아래 "UI 렌더 전략")에 따라 **네이티브(SwiftUI/NSPanel) 대신 Zig 오버레이**로 간다. 팝업 상태(열림/필터 문자열/선택 index/필터된 카탈로그)·레이아웃을 Zig에 두고, 렌더는 사이드바/인디케이터처럼 **셀 draw-list**로, 키는 팝업 열림 동안 Zig로 라우팅(printable→필터, ↑↓→선택, Enter→`run_action`, Esc→닫기). 네이티브는 토글 키 + 키 전달만(이미 함). 카탈로그·`run_action` 토대는 그대로 재사용. (지금 렌더러로는 cell-grid라 룩이 소박 — 아래 chrome 고급화로 같이 좋아진다.)
  - **Stage 2a 완료(상태머신, ABI 무변경)**: 새 `command_palette.zig`의 `PaletteState`(open/query/filtered/selected) — 순수 로직(렌더·OS·PTY 무관). `show`/`hide`/`appendChar`(UTF-8)/`backspace`(코드포인트 경계)/`moveSelection`(클램프)/`selectedAction` + 필터(title 대소문자 무시 부분일치, 빈 쿼리=전부, 쿼리 변경 시 선택 맨 위). 카탈로그(`command_catalog.entries`)를 필터하고 선택 항목의 Action을 돌려준다(dispatch는 2b의 AppSession이). 헤드리스 검증(containsIgnoreCase·show/필터/이동/selectedAction·매칭 없음·backspace 넓힘). 아직 앱 미연결(2b가 AppSession에 wiring + 모달 키 + 오버레이 렌더).
  - **Stage 2b 완료(라이브 — wiring·모달 키·오버레이 렌더, ABI 무변경)**: 전부 Zig(Swift 무변경 — 키는 이미 Zig로, 렌더는 metal frame). ① **토글**: `Action.toggle_command_palette` + 기본 바인딩 `Cmd+Shift+P`(`dispatchAppAction`→`togglePalette`). 카탈로그엔 안 넣어 자기-재귀 회피. ② **모달 키 라우팅**: `handleKeyEvent`가 `palette.open`이면 resolver/스크롤/PTY보다 먼저 `handlePaletteKey`로 — Esc/모디파이어 조합=닫기, Enter=`selectedAction` 디스패치 후 닫기, ↑↓=이동, Backspace=삭제, 평문 글자=필터. ③ **렌더**: `buildPaletteFrame`이 패널(상단-중앙)을 DrawList로 — row 0 쿼리("> …"), 결과행(제목 + 우측정렬 바인딩 표시, 선택 행 강조 bg), 모든 셀에 불투명 bg. `metal_frame.replace`에 **최상위 `palette_frame` 레이어 추가**(커서 suffix 뒤에 append → 터미널·커서 위, raster는 uploads 머지) — 모달이 아래를 덮는다. 검증: 헤드리스(macOS — 토글 열림·"new t" 필터→1개·Enter가 new_term 디스패치+닫힘·Esc 닫힘·열린 상태 프레임 빌드 셀>0) + boundaries + swift-check + coretext/metal 스모크(replace 새 시그니처·팝업 null 경로). 룩은 cell-grid(고급화로 후속). 한계: 필터=부분일치(fuzzy 후속), IME 필터는 ASCII(한글 후속).
  - **Stage 2 후속(리뷰 수정 4건, ABI 무변경)**: `/code-review max`가 잡은 확정 2건 + 경미 2건을 한 PR로. ① **커서 blink가 팝업 꼬리를 자름(확정)**: `palette_frame`은 커서 suffix '뒤'에 붙는데 `MetalFrameBuffer.view()`의 blink-off chop이 `cells.len - cursor_cells`로 '맨 뒤'를 잘라 — blink가 커서가 아니라 팝업 우하단 셀을 깜빡 지웠다. `replace`가 팝업이 있는 프레임에선 `cursor_cells=0`으로 둬 chop을 끈다(모달 중 커서는 정적, 팝업이 위를 덮음). ② **메뉴 단축키가 모달 우회(확정)**: `run_action`(메뉴바 keyEquivalent → Swift → 이 경로)이 `palette.open`을 안 봐, 팝업이 떠 있어도 메뉴 단축키가 뒤 터미널을 조작했다. `runAction` 첫 줄에 `if (self.palette.open) return false;`(팝업 자신의 Enter는 `handlePaletteKey`가 `dispatchAppAction`을 직접 부르므로 무관). ③ **`show` 순서(경미)**: `PaletteState.show`가 `open=true`를 `recompute` '전에' 세워, recompute OOM 시 filtered가 빈 채로 열릴 수 있었다 → recompute 성공 후에 open. ④ **전체화면 대상(경미)**: `menuToggleFullScreen`이 `NSApp.keyWindow`를 써, 퀵터미널 오버레이 패널(borderless·`.fullScreenAuxiliary`)이 key면 그 패널을 전체화면 토글했다 → `primary?.window`(메인 터미널 창) 고정. 검증: 헤드리스 회귀(팝업 열린 채 `runAction` false·터미널 불변, tick 후 `metal_buffer.cursor_cells==0`) + 기존 팝업/카탈로그 테스트 불변 + boundaries + swift-check + coretext/metal 스모크.
  - **C1b 갱신(chrome 이주, ABI 무변경)**: 위 palette UI(`PaletteState`·`buildPaletteFrame`·`handlePaletteKey`·`palette_frame` 레이어)는 chrome 컴포넌트로 이주·**제거**됐다. 지금은 `src/chrome/components/palette.zig`(neutral State+view+handle)를 `ChromeHost`가 라우팅하고, `command_palette.zig`엔 카탈로그 결합 필터(`filter`/`actionAt`)만 남는다(neutral 컴포넌트는 카탈로그를 import 못 하므로 platform이 `Row{title,binding,selected}`를 주입). 렌더는 find와 같은 일반 오버레이 lowering(`rasterizeOverlayCells`, EAW-폭). 위 ①(blink가 꼬리 자름)은 caret-as-cursor `suffix-trim` 재활용으로, ②(메뉴 단축키 우회)는 `runAction`의 오버레이 가드로 계승된다. 상세 = docs/chrome-strategy.md 현황 노트.
- **UI 렌더 전략(사용자 결정): chrome은 Zig + GPU 렌더러로, OS 의존 최소**: 탭·사이드바·인디케이터·테두리·팝업 등 UI 가구는 네이티브 뷰가 아니라 Zig draw-list + GPU 렌더러로 그린다(이미 사이드바/탭/인디케이터가 그 방식). 근거: 네이티브 최소 정책 + 이식성(**SwiftUI는 Apple 전용**이라 Win/Linux엔 도움 안 됨; Zig draw-list는 각 플랫폼 렌더러가 그려 재사용). 예외는 (1) quick terminal처럼 "별도 세션=별도 OS 창"이 본질인 경우, 그리고 (2) **리치 웹 패널**(콘텐츠가 HTML/JS/CSS라 크로스플랫폼 웹뷰로 이식성 목적을 충족 — SwiftUI와 달리 UI 코드가 Apple 전용이 아님; 2026-06 사용자 결정)이다. **예외의 닫힌 열거(마크다운 WYSIWYG·인앱 브라우저 — diff는 제외, GPU 셀로 그림)·근거·Zig/Swift 분담·의존성 캐비엇은 [docs/control-plane.md] §1을 단일 출처로 둔다**(여기 중복하지 않는다).
- **chrome 고급화(렌더러 프리미티브 확장) [나중 로드맵, 큼]**: 현재 cell-grid chrome("TUI스러운" 룩)은 한계가 아니라 MVP. GPU 렌더러에 **둥근 모서리·그라데이션·그림자·비례 UI 폰트의 measured artifact·아이콘 텍스처·격자 무관 sub-pixel 배치**를 추가하면 사이드바·탭·테두리·팝업이 통째로 프리미엄해진다(사실상 미니 UI 프레임워크 — 선례 Zed/GPUI). rich Chrome glyph는 별도 atlas를 만들지 않고 `GlyphQuadFrame`의 shared atlas와 final pixel placement를 공유한다. draw-list가 풍부한 프리미티브를 담으면 전 플랫폼 렌더러가 같은 고급 chrome을 그린다. 큰 투자라 별도 단계로 분리.

후속(메뉴에 자리만 두고 각자 별도 — 새 기능이라 분리):

- **New Window**(멀티 윈도우 — 큼, 현재 단일 윈도우 — 상세·의존성·권장 순서는 아래 "백로그: 큰 미착수 항목"). ~~**Find**(스크롤백 검색)~~ → 완료(위 "스크롤백 Find(⌘F)"). ~~**Font Size +/−/Reset**~~ → 완료(위 "런타임 폰트 크기"). 후속: Find(regex/fuzzy), 폰트(step 파라미터화·View 메뉴 항목·set_font_size).

완료 기준:

- 카탈로그·실행·바인딩 표시는 Zig 단일 출처(메뉴·팝업·키바인딩이 같은 카탈로그를 본다 — 발산 없음).
- 네이티브는 NSMenu/SwiftUI 그리기 + 액션 문자열 왕복만(정책 0).
- ABI는 구조체 배열 한 형태로 메뉴·팝업이 공유. 스모크는 메뉴 생성이 smokeMode에서 안전(앱 자동 종료 경로 불변).

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

### 설계·결정 (window-aware, 사용자 결정 2026-06-14)

확정 순서(New Window → restore → chrome)의 하드 제약대로 **window-aware**다(workspace-restore.md 초안은 cmux 풀 모델·멀티 창 이전이라 surface/tab만 — 현재 모델 windows→tabs→pane split 트리→Term에 맞춰 확장). 토대는 이미 상당: `app.surface.RestorableSurfaceMetadata`(id·title·cwd·command·size), `core.currentCwd()`(OSC 7)·`windowTitle()`(OSC 0/2)·`Surface.command`, `split_tree`(dir/ratio), snapshot/trace 직렬화 컨벤션.

- **D-범위 = 최근 세션 1개**(사용자 결정): 앱을 닫을 때의 전체 상태(모든 창·탭·split·cwd)를 전역 1개로 저장·복원("끄던 그대로 다시 열기"). repo별 workspace는 후속(이 위에 얹는 레이어).
- **D-트리거 = 자동 복원, 기본 ON + config 토글, 정상 종료분만**(사용자 결정): 앱 시작 시 마지막 세션을 자동으로 다시 연다(layout·cwd·shell 시작까지만 — **명령 자동실행 없음**이라 안전). config로 끌 수 있고, **크래시 후엔 복원 안 함**(정상 종료 때 저장한 것만). 첫 실행·저장 없음·복원 off면 기본 빈 창 1개.
- **보안(정책 그대로)**: live PTY/process/grid 내용 저장 안 함, `last_observed_command` 자동 재실행 안 함, redaction deny-by-default([project-rules.md] 단일 출처). **env override·startup_recipe 자동실행은 구현 전 재확인 필요(정책)라 v1 제외** — v1은 layout·cwd·shell_entry(command)만.

### 분해 (R1~R6)

- **R1 직렬화(writer) — 완료**: `src/app/workspace.zig`에 값-타입 모델(Workspace→Window→Tab→{TreeNode preorder + Pane}→Surface)과 `serialize`(`maru.workspace.v1`). snapshot/trace 규칙(첫 줄 bare 토큰·`<kind> <fields>`·`\"`/`\\`/개행 escape) 따름. split 트리는 preorder TreeNode(split는 뒤 두 subtree 소비, full binary tree라 self-delimiting). 모델에 PTY/process 필드 없음(선언적). 검증: 헤드리스 writer 테스트(단일 창/탭/pane/surface·중첩 split·멀티 창·cwd/title escape) + fmt + boundaries + swift-check + 스모크. **순수 Zig, 라이브 AppSession 미접촉**(R3 캡처가 모델을 채운다).
- **R2 파서(reader) — 완료**: `workspace.zig`에 `parse`(텍스트 → `ParsedWorkspace`, arena가 모든 슬라이스·escape 해제 문자열 소유 → deinit 한 번). 라인 단위 dispatch + 순차 `FieldReader`(word/key/uint/quoted — 따옴표 값이 다른 key를 흉내내도 sequential read라 안전), split 트리는 writer와 같은 preorder를 재귀로 재구성(split→두 subtree 소비, self-delimiting). 알 수 없는 trailing 라인은 forgiving 종료, 잘못된 헤더는 error. 검증: round-trip(중첩 split·멀티 창·escape를 serialize→parse→serialize 고정점) + parse 단위(구조·ratio·escape 해제·forgiving·BadHeader) + 게이트 전부. **writer↔reader 일치 고정.**
- **R3 캡처(한 창) — 완료**: `AppSession.captureWorkspaceWindow(arena)`가 라이브 탭→pane split 트리→Term→surface를 걸어 `app.workspace.Window` 모델로(선언적만 — live PTY/grid 제외). cwd/title=OSC 권위 소스(`core.currentCwd`/`windowTitle`), command=`surface.command`(argv[0]), size=core size. split 트리는 `*Pane` leaf를 tab.panes 인덱스로 환원해 preorder TreeNode로 평탄화(`flattenPaneTree` — 직렬화 모델과 같은 형태). arena가 모든 슬라이스·문자열 소유. 검증: macOS 통합(split+새 탭+OSC 7 cwd → 캡처 → 탭 2·tab0 pane 2·tree preorder(split,leaf,leaf)·cwd 잡힘·유효 size → serialize가 기대 라인). **멀티 창 전체 모델·ABI·Swift 합치기는 R5(영속화)** — 각 세션의 Window를 헤더 하나 아래로 모은다.
- **R5 저장(영속화·저장 side) — 완료**: 정상 종료 시 멀티 창 workspace를 디스크에 저장한다. ABI `maru_macos_app_session_serialize_workspace`(버전 36→37 — 세션마다 헤더 없는 `window …` 블록을 캡처+직렬화해 세션-소유 버퍼로, `app.workspace.serializeWindow` + R3 캡처). Swift `saveWorkspace()`가 `applicationWillTerminate`에서 shutdown '전에'(세션 살아 있을 때) 각 일반 창의 블록을 ABI로 받아 `maru.workspace.v1` 헤더 하나 아래로 모아 `~/Library/Application Support/maru/workspace.v1`에 atomic write. quick 패널 제외, smoke·빈 창·쓰기 실패는 best-effort 건너뜀. **크래시 가드는 자동** — applicationWillTerminate가 정상 종료에만 불려, 크래시 세션이 마지막 저장을 안 덮는다. 검증: 헤드리스(serializeWorkspaceWindow가 헤더 없는 `window` 블록·cwd 포함·재호출 시 이전 버퍼 해제[leak 없음], serializeWindow 집계 round-trip[헤더+블록들 → parse 2창]) + ABI 계약(37) + swift-check + app-smoke. 실제 파일 저장은 앱 수동(정상 종료 후 파일 확인).
- **R4a 복원 apply(한 창, Zig) — 완료**: `AppSession.applyWorkspaceWindow(model)`가 한 창 모델을 라이브 트리로 재생성한다 — 새 탭들을 먼저 다 빌드(각 pane을 첫 surface로 spawn + 나머지 Term 추가, split 트리는 모델 preorder대로 `PaneTree.Split` 직접 할당)한 뒤 기존 기본 탭을 teardown하고 swap(빌드 실패면 새 것만 정리, 기존 세션 보존). 각 Term은 저장된 **cwd에서 새 셸 spawn**(`SpawnRequest.cwd` — chdir; 빈 cwd면 기본). title/command는 정적 기본(셸이 OSC로 곧 재설정), size는 모델값(이후 resize 보정). 메모리: capacity 예약으로 swap 무실패, split 추적 리스트로 에러 시 해제. 검증: macOS round-trip(모델 → `applyWorkspaceWindow` → `captureWorkspaceWindow`가 탭/split dir·ratio/pane/Term·active 인덱스 일치) + 전체 게이트 + app-smoke. cwd는 OSC-side라 capture로 round-trip 안 함(spawn chdir은 앱 수동). **ABI 무변경.**
- **R4b 로드 + 멀티 창(Swift) — 완료**: 시작 시 저장된 workspace를 복원해 restore가 end-to-end로 닫힌다(저장 R5 → 로드 R4b). ABI `maru_macos_app_session_apply_workspace`(버전 37→38 — 헤더+한 창 텍스트를 parse[R2]해 세션에 `applyWorkspaceWindow`[R4a] 적용; parse 실패=invalid_config·apply 실패=create_failed·best-effort). Swift `restoreWorkspace()`가 `applicationDidFinishLaunching`에서 startAppSession '뒤'에: `loadWorkspaceBlocks`(파일 읽어 헤더 검증 후 `window ` 라인 경계로 창 블록 분할) → 첫 블록은 primary에 `applyWorkspaceBlock`(헤더 붙여 ABI), 나머지 블록마다 `createTerminalWindow(applyingBlock:)`(W2 팩토리를 블록 적용 가능하게 리팩터). 저장 없음·헤더 불일치·복원 off(`MARU_NO_WORKSPACE_RESTORE` env — config 토글은 후속)·smoke·빈 블록이면 기본 단일 창 유지. 검증: 헤드리스(복원 text → `parse` → `applyWorkspaceWindow` → capture가 단일 탭·split vertical ratio 300·pane 2·active 일치) + ABI 계약(38) + swift-check + app-smoke(smoke는 복원·저장 둘 다 끔) + 전체 게이트. 실제 복원(⌘Q 후 재실행에 레이아웃·cwd 되살아남)은 앱 수동.
- **R6 보안 가드 + 없는 cwd graceful — 완료**: ① **민감 데이터 미저장 가드**: serialize 텍스트에 `env=`/`fd=`/`pid=`/`last-observed` 라인이 없음을 단언 — 모델이 그런 필드를 안 가져 live 핸들·env·last_observed_command가 저장 텍스트에 절대 안 샌다(workspace-restore.md 정책; 누가 그런 필드를 추가하면 깨져서 위반을 잡는 회귀 가드). cwd는 path라 정상 저장(redaction 대상은 env, path 아님). ② **없는 cwd graceful**: `usableRestoreCwd`가 존재하는 절대 디렉터리(libc `access` X_OK = chdir 가능)일 때만 그 cwd를 spawn에 쓰고, 없으면 null → 기본 cwd로 spawn해 **surface를 잃지 않는다**(잘못된 cwd면 자식 chdir이 `_exit(126)`이라 미리 확인 안 하면 복원 셸이 즉시 죽어 reap된다). 검증: `usableRestoreCwd` 단위(존재/없음/빈값/상대경로 — 크로스플랫폼) + macOS 통합(없는 cwd 모델 apply → 실패 없이 탭·surface 복원) + 민감 데이터 가드 + 전체 게이트. **이로써 9단계 Workspace restore(R1~R6)가 닫힌다.** 후속: config 토글(env disable 현재 env-var), 부분 복구 artifact(한 surface 실패 시 이유 기록), startup_recipe/env allowlist(정책 재확인 후), repo별 workspace.

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

## 완료 기능 잔여 후속 (자투리 모음 — 각 완료 기능의 미착수 후속)

아래는 이미 **완료**된 기능들에 문서 곳곳 "한계/후속"으로 적힌 작은 잔여 항목을 한 곳에 모은 것이다(단일 출처는 여전히 각 기능 절). 새 기능이 아니라 다듬기라 우선순위는 낮고, 필요할 때 각자 작은 PR로 집어간다.

- **스크롤백 Find(⌘F)**: **⌘G/⌘⇧G(오버레이 닫힌 채 다음/이전 매치) — 완료**(`find_next`/`find_previous` 액션 + ⌘G/⌘⇧G 바인딩. `findNavigate`가 보존된 검색어로 재검색해 네비, `find_nav` 플래그로 닫힌 채도 현재 매치 하이라이트·출력 시 재검색 유지, 셸 타이핑이 종료. macOS Find Next 관례). **유니코드 케이스폴딩 — 완료**(`foldCase`: ASCII + Latin-1 À-Þ·Greek Α-Ω·Cyrillic 깔끔한 오프셋 블록까지 대소문자 무시 — café↔CAFÉ·αλφα↔ΑΛΦΑ·привет↔ПРИВЕТ. width.zig와 같은 "small first table" 정책 — Latin Ext-A는 parity flip이라 표 필요해 후속). **팝업에서 Find 띄우기 — 완료**(`toggle_find`/`find_next`/`find_previous`를 command 카탈로그에 등재 → ⌘⇧P 팝업에 Find/Find Next/Find Previous 노출, 선택 시 acceptPalette가 팝업을 닫고 Find를 연다. 자기 토글이라 재귀인 toggle_command_palette와 달리 Find는 별개 모달이라 띄운다). **alt screen에서도 Find — 완료(결정 B 반전)**: 이전엔 alt에서 Find를 껐으나(사용자 결정 B, iTerm2 관례), 자체 검색(`/`)이 없는 TUI(Claude/Codex)에선 검색 수단이 통째로 사라져 다시 켰다. 베이스: Ghostty도 alt에선 active area(현재 화면)만 검색한다(`search/active.zig` ActiveSearch — 동작만 참조, 구조는 maru 독립). `findSuppressed` 게이트(toggleFind/findNavigate/tick-close 3곳) 제거 → alt에서도 Find가 열리고 tick이 닫지 않는다. core `findMatches`는 alt에선 현재 화면(`[sb_count,total)`)만 스캔한다 — primary 스크롤백 매치는 scrollToAbs가 잠겨[무동작] 갈 수 없고 alt는 화면 밖을 스크롤백에 안 쌓으므로. 화면 전환(primary↔alt) 시 render-tick이 현재 매치 인덱스를 리셋한다(`find_was_alt` 비교). 반전은 사용자 재확인 완료. 잔여: regex/fuzzy(현재 부분일치).
- **런타임 폰트 크기(⌘+/⌘-/⌘0)**: **View 메뉴 항목(Bigger/Smaller/Actual Size) — 완료**(`command_catalog`의 `increase_font_size`/`decrease_font_size`/`reset_font_size` 3행을 `buildMainMenu`의 View 메뉴가 `catalogMenuItem`으로 얹어, 바인딩 chord가 keyEquivalent로 표시된다). **`set_font_size` 절대 지정 — 완료**(`Action.set_font_size: f32` — config 바인딩 전용 `set_font_size:18` 형태, `dispatchAppAction`이 `setFontSize`로 [6,72]pt 클램프. 절대값이라 어느 크기인지 고정 못 해 메뉴/팝업엔 안 넣는다). 잔여: **step 파라미터화**(현재 `font_size_step` 1pt 상수 고정 — config 노출 안 됨).
- **메뉴바(NSMenu)**: **Services·Open Config·Find 메뉴 항목 — 완료**. Services(Edit 서브메뉴 `NSApp.servicesMenu`), Open Config(App 메뉴 ⌘, — ABI v54 `config_path`로 경로[Zig loader `defaultConfigPath` 단일 출처]를 받아 Swift가 없으면 생성 후 기본 편집기로 열기), Find 서브메뉴(Find…/Find Next/Find Previous — keyEquivalent 없이 runAction, 단축키 ⌘F/⌘G/⌘⇧G는 Zig 키바인딩 소유라 안 가림). **Reload Config·Reset to Defaults — 완료**(ABI v56 — App 메뉴 "Reload Config"가 `menuReloadConfig`→`maru_macos_app_session_reload_config`로 config 파일을 재로드하고 `reapplyLoadedConfig`가 폰트·여백·테마·palette·scrollback·bell·page-keys를 재시작 없이 재적용한다. "Reset to Defaults"는 확인 모달 뒤 전체 기본값 복원). 잔여: **Cut/Undo**(터미널은 cut/undo 의미가 없어 보류 — 입력 필드 편집은 chrome 오버레이가 자체 처리), **config 파일 변경 자동 감지**(현재는 수동 Reload Config만 — watcher 없음).
- **커맨드 팝업(⌘⇧P)**: fuzzy 필터(현재 부분일치)·한글 IME 필터(현재 ASCII).
- **선택/클립보드**: 블록(직사각형) 선택 — **완료**(Option+드래그 = 직사각형 — iTerm2/Terminal.app 관례). `selection_block` 플래그 + `SelectionSpan.block`로 `extractSelection`(각 행 [lo,hi]·행마다 개행·뒤 빈칸 trim)·`inSelection`(모든 행 동일 열 범위)·`selectionViewportSpan`(col min/max 정렬)이 분기. platform mouse가 Option(mods&8)이면 `setSelectionBlock`하고 mouse-reporting override에 option 포함. `selectionStart` 시그니처는 불변(기존 호출처 보존).
- **New Window(멀티 윈도우)**: W3/W4 잔여 — global hotkey(toggle_window/quick)의 멀티 창 타게팅·창별 독립 config·탭 tear-off(창 간 탭 이동); W5 — atlas 공유(SharedGridSet식 grid-per-size, memory `multi-window-atlas-ownership` — 프로파일 후).
- **Workspace restore**: config 토글(현재 `MARU_NO_WORKSPACE_RESTORE` env-var)·부분 복구 artifact(한 surface 실패 시 이유 기록)·startup_recipe/env allowlist(정책 재확인 후)·repo별 workspace.
- **kitty graphics**: 비활성 panel 이미지 렌더·reflow 후 정밀 재배치·멀티 윈도우 텍스처 캐시 소유권(atlas 소유권 재검토와 함께). query/애니메이션은 위 kitty 절 K5 참조.

## 백로그: 큰 항목 — New Window·chrome 고급화 (둘 다 ✅ 구현 완료; 아래는 설계 근거 보존)

9·10단계(Workspace restore·Plugin)는 위에 목표/완료기준이 있다. 아래 둘(New Window·chrome 고급화)은 **설계 PR(레퍼런스 조사 → 분해 → ABI/경계 영향 → 사용자 합의) 원칙대로(메뉴바·split처럼) 구현 완료**됐다 — New Window는 W1/W2(⌘N·per-window 세션/렌더러·R4b 복원, 아래 상세), chrome 고급화는 C4b(GPU SDF quad/shadow)+U(VSCode 탭·고정폭·가로 스크롤·affordance — `layering-and-portability.md` §5·`chrome-strategy.md` 참조). 아래 설계안은 합의·구현 근거로 보존한다(한 줄 스텁으로 바로 코딩하지 않는 원칙을 그대로 따랐다).

### New Window (멀티 윈도우) — ✅ 구현 완료 (W1·W2·⌘N·R4b 동작; W3/W4 잔여·atlas 공유는 후속)

> **현황(2026-06)**: ⌘N(File > New Window) → `createTerminalWindow`(새 NSWindow + per-window AppSession + Metal 렌더러 + 첫 paint), `tickAppSession`이 `windows` 컬렉션을 매 tick 순회해 **전 창 렌더**, 마지막 일반 창 닫힘 시 앱 종료(D4), 워크스페이스 다중 창 복원(R4b)까지 동작 — 앱에서 확인됨. 아래 설계안(D1~D4·W1·W2)이 그대로 구현됐다. 남은 건 W3/W4 잔여(global hotkey 창 타게팅·창별 config·탭 tear-off)와 atlas 공유(grid-per-size, D2 후속) — 전부 선택적 후속.

**베이스**: Ghostty의 App→Surface 소유 모델 — `App`이 `surfaces: ArrayListUnmanaged(*Surface)`를 소유하고, `new_window`가 새 NSWindow(TerminalController) + 새 surface(`ghostty_surface_new`)를 만들며, `SharedGridSet`이 폰트 grid를 ref-count로 창 간 공유, 마지막 창 닫힘은 apprt별 quit 정책(quit-after-last-window-closed), surface별 독립 렌더/IO 스레드.

**현재 구조 (연구 결과 — 토대가 이미 상당)**:

- **Zig/ABI는 이미 멀티 세션 지원**: `maru_macos_app_session_create`(opaque 핸들 반환)·`_destroy` + 모든 ABI 함수(tick/key/resize/close…)가 세션 포인터를 명시. 전역 싱글턴·고정 슬롯 없음.
- **quick terminal이 이미 "2번째 독립 세션"**: 별도 AppSession(별도 PTY)·별도 NSWindow(borderless panel)·별도 metalRenderer·별도 renderer_state/atlas. `ensureQuickTerminal`이 `session_create`를 2번째로 호출하는 게 정확한 선례.
- **단일 가정은 Swift 호스트에만**: `MaruAppHost`의 `primary`/`quick` 2개 명시 필드(배열 아님), `activeSurface` forwarder(key 창 기준 2갈래), `tickAppSession`(primary→quick 고정 순서), `windowWillClose`가 무조건 `NSApp.terminate`, 메뉴/`runCatalogAction`이 primary 세션 고정.

→ **결론: New Window는 주로 Swift 호스트 리팩터. Zig/ABI는 대부분 그대로(quick = 살아있는 선례).**

**결정 사항 (합의 대상)**:

- **D1 윈도우↔세션 = 1:1**(권장): NSWindow 1개 = AppSession 1개(탭/split은 AppSession 내부, 이미 구현). quick과 동일 패턴 → `primary`/`quick`를 `windows` 컬렉션으로.
- **D2 atlas 소유권 = per-session 유지**(권장, memory `multi-window-atlas-ownership`): v1은 창마다 자기 atlas(quick이 이미 그럼). 공유(SharedGridSet식 grid-per-size)는 프로파일 후 후속.
- **D3 New Window = 네이티브 액션**(권장): NSWindow 생성은 OS 소유라 Zig in-session Action(dispatchAppAction)이 못 만든다 → **File > New Window 메뉴 + ⌘N(NSMenuItem keyEquivalent)** 을 Swift가 처리(quick terminal 토글이 네이티브인 것과 같은 경계). 새 창 config = 기본(interactive shell, chrome full). Zig action.zig/keybinding.zig **무변경**.
- **D4 lifecycle = 앱 종료**(사용자 결정 2026-06-14): 마지막 일반 창이 닫히면 앱을 종료한다 — 현재 동작(primary 닫힘=`NSApp.terminate`)의 자연스러운 일반화, 단순·기존 lifecycle 재사용. quick 패널은 카운트에서 제외(숨김이라 창이 아님). macOS 표준 "앱 유지(메뉴바만)"는 미채택 — 필요하면 config 토글(`quit-after-last-window-closed`)로 후속.

**분해 (Swift 중심)**:

- **W1 세션 컬렉션 — 완료(소유권 seam, 동작 불변)**: `MaruAppHost`의 stored `primary`(단일 필드)를 `windows: [TerminalSurface]`(컬렉션, 단일 출처)로 일반화하고 `primary`를 계산 별칭(`windows.first`)으로. 창 생성이 `windows.append`(launch는 여전히 1개), 창별 라우팅을 컬렉션 경유로 — `surfaceForView`는 view의 창으로 매칭, `activeSurface`는 key인 일반 창(없으면 첫 창)을 고른다. 단일 창에선 둘 다 그 창이라 동작 불변(split PR2a "Tab→tree seam"과 같은 결). `TerminalSurface`가 reference라 `primary?.field = x` 변형은 그대로 동작. 자료구조는 dict 대신 array(순서=생성순, primary=first)로 단순화. 검증: swift-check + 실제 앱 호스트 smoke(`macos-app-smoke` — 창 생성·tick·렌더·정상 종료, frame_consistent=true) + ABI 계약 + 전체 Zig 테스트 + boundaries + coretext/metal 스모크. **ABI 무변경**. quick은 별도(특수) surface 유지. **tickAppSession 순회·NSWindow delegate(per-창)·per-window lifecycle은 W2/W3로** — 2번째 창이 생겨 실제로 exercise·테스트되는 시점에 일반화한다(seam은 구조만).
- **W2 New Window 생성 + per-window tick/lifecycle — 완료(동작하는 멀티 윈도우)**: 2번째 창이 실제로 생기므로 "동작하는 New Window"가 되도록 W3(per-window lifecycle)·W4(포커스 타게팅)의 필요한 부분을 함께 넣었다. ① **팩토리** `newTerminalWindow(_:)`: `makePlaceholderWindow`(titled, full chrome) + `withSurface(새 surface)` 스코프로 렌더러·세션 생성(`createSessionForActiveSurface` — `startAppSession`에서 앱-전역 tick과 분리 추출) + 즉시 `renderTick`. 컬렉션에 append, cascade 위치, 실패 시 정리. **File > New Window + ⌘N**(네이티브 — NSWindow는 OS 소유). ② **tickAppSession 순회**: `windows` snapshot을 돌며 각 창 tick, 셸 종료(SessionEnded)/fault면 그 창을 `closeWindowOrQuit`로 — 마지막 일반 창이면 앱 종료(D4, 타이머 멈춰 재진입 terminate 방지), 아니면 그 창만 닫는다(quick과 같은 per-window). ③ **delegate 타게팅**: `windowWillClose`/`windowDidResize`/`windowDidEndLiveResize`가 `surfaceForWindow(notification.object)`로 그 창을 명시 대상(기존 primary 고정 → 멀티 창 정확). 마지막 창 닫기는 `NSApp.terminate`로 기존 단일 창 경로 보존(정리·요약은 applicationWillTerminate). ④ **teardown**: `teardownWindowSurface`(세션 close+destroy + renderer destroy + 컬렉션 제거, 요약 보존) 공유, `shutdownAppSession`이 남은 모든 창을 snapshot 순회 정리, `applicationWillTerminate`가 요약 기준 surface를 shutdown '전에' 캡처(컬렉션이 비기 전). 검증: swift-check + **단일 창 회귀 smoke**(`macos-app-smoke` — close_events=1·final_frame_ended=true·요약 W2 이전과 동일) + ABI 계약 + 전체 Zig 테스트 + boundaries + coretext/metal 스모크. **ABI 무변경**. 베이스: 2번째 창+렌더러+세션 패턴은 quick terminal이 이미 증명(팩토리는 `ensureQuickTerminal`의 일반 창 버전). 한계: **멀티 창 런타임(⌘N→2번째 창, 각자 입력·resize·닫기, 마지막 창 종료)은 앱 수동**(헤드리스 smoke는 단일 창) — Swift 호스트는 단위 테스트가 없어 기존 quick/메뉴 PR과 같은 검증 경로.
- **W3/W4 잔여**: 위에서 per-window lifecycle·delegate 타게팅·메뉴 Zig-액션 타게팅(W1 `activeSurface`가 key 창)을 흡수했다. 남은 것: global hotkey(toggle_window/quick)가 멀티 창에서 어느 창을 대상으로 할지 정교화, 창별 독립 config, 탭 tear-off — 필요 시 후속.
- **(W5) glyph atlas 공유 + #5~7 kitty 이미지 캐시 정합 — 설계 분해(2026-06 조사·측정, 구현 보류)**:
  - **측정(왜 보류인가)**: glyph atlas는 세션별로 1024² RGBA8Unorm(초기 **창당 4MB GPU 텍스처**)에서 시작하고, 한 프레임의 고유 글리프가 모자라면 max 8192²까지 grow한다([font-strategy.md](font-strategy.md) growable atlas). 멀티 윈도우 중복의 기본 비용은 창 2~3개에 4~8MB·10개여도 36MB 수준이라 GPU/통합 메모리(GB) 대비 작고, grow도 정확성 장치이지 공유의 즉시 근거가 아니다. 따라서 **W5c(GPU 텍스처 공유)의 실질 이득은 측정된 atlas churn/메모리 압박이 나오기 전까지 작아 현재 macOS에선 구현 보류**(#10 이미지 캐시화를 측정으로 기각한 것과 같은 패턴 — 측정 없이 큰 재설계로 들어가지 않는다). 단 **WebGPU 이식** 시 재업로드×256정렬 비용이 곱해져 더 시급해질 수 있고([레이어링](layering-and-portability.md) §5 노트), 그때 grid-per-size/ref-count `GridSet`은 growable atlas를 창 간 공유하는 문제로 재검토한다.
  - **현재 구조**: glyph atlas는 per-AppSession(per-window) 소유(`renderer_state.atlas`). 키(`GlyphCacheKey`)는 device-pixel identity(font+size+scale+cell)에 session id가 없어 **이미 공유 호환**(memory `multi-window-atlas-ownership` 주장이 코드상 맞음). 폰트 크기 변경은 `atlas.invalidate(.font_size_changed)`로 per-session in-place — 공유 시 다른 창 grid를 날리는 충돌점이다.
  - **베이스**: Ghostty `SharedGridSet`(ref-count grid = atlas + glyph cache 묶음, RwLock 보호). 폰트 변경 시 새 key를 ref + 옛 key를 deref(in-place invalidate 안 함). `Surface`가 init에 ref·deinit에 deref.
  - **분해**: **W5a** 소유권 캡슐화 seam(`Grid` 객체로 atlas+glyph cache 묶기, 동작 불변 — W1의 `primary`→`windows`식 seam). **W5b** ref-count `GridSet`(실제 공유 — **font-size 변경을 in-place invalidate에서 ref-new/deref-old로 교체**가 핵심 correctness; in-place invalidate는 eviction/atlas_full 사유에만 남긴다). **W5c** atlas `MTLTexture`를 공유 grid로 이동(실질 GPU 절감, 프로파일/WebGPU 게이트). W5a/b는 CPU raster/packing dedup만이라 단독 이득이 작다.
  - **#5~7 kitty 이미지 캐시(별개 축, 멀티 pane 이미지 렌더 전제)**: `image_id`가 surface-local opaque counter라 두 surface의 `image_id=1`이 다른 픽셀 — 공유 키가 **틀림**(atlas의 content-derived 키와 반대). fix는 ref-count가 아니라 **namespacing**: `(surface_id, image_id)` 복합 키를 4곳(`kitty_uploaded`·`planImageUploads`/`buildGpuImages`·Swift `imageTextures`·evict live-set)에 적용. 현재는 **활성 surface만 이미지 렌더**(`app_session` active-only)라 충돌이 잠재 — 비활성 pane 이미지 렌더(별도 기능)가 충돌을 노출하므로 그 기능과 함께 구현한다.
  - **순서·전제**: W5(atlas)와 #5~7(이미지)은 disjoint 캐시·다른 키 원리(content-shared vs identity-namespaced)라 독립. 공통 토대는 "per-surface id"(#5~7이 도입, W5b가 ref-count에 개념 재사용). W5는 프로파일/WebGPU 게이트, #5~7은 멀티 pane 렌더 게이트 — **둘 다 현재 단일 윈도우/active-only라 미트리거**라 지금은 설계만 고정한다.

**ABI·경계 영향**: ABI **무변경 예상**(create/destroy/tick/key/resize가 이미 세션 명시 — Swift가 opaque 핸들 컬렉션을 들면 Zig는 창 수를 몰라도 됨). 경계: window=OS(Swift 소유), session/terminal=Zig. New Window는 네이티브 액션이라 정책 일관. global_hotkey는 앱-전역 유지.

**검증 전략**: Swift 헤드리스 테스트가 어려우므로 — ① Zig 반-E2E(`session_create` 2회 → 독립 세션 2개가 각자 tick/resize/입력·destroy, quick 테스트 패턴 일반화)로 멀티 세션 격리·leak 없음 고정, ② swift-check 컴파일, ③ 앱 수동(⌘N→2번째 창, 각자 입력·resize·닫기, 마지막 창 D4 정책).

**의존**: tab/split 모델 안정(완료). **9단계 restore가 이걸 window-aware로 전제**(확정 순서의 하드 제약). 한계/후속: atlas 공유(W5), 창별 독립 config, 탭 tear-off·창 간 탭 이동.

### chrome 고급화 (렌더러 프리미티브 확장) — ✅ 구현 완료 (C4b + U)

> **현황(2026-06)**: `layering-and-portability.md` §5의 **C4b**(metal SDF quad/shadow 파이프라인·`ChromeDraw.quad`+모양 토큰·둥근 사이드바 밴드/모달·tabbar 픽셀 retrofit·둥근 탭)와 **U**(사이드바 세로 카드·VSCode식 평평 탭+앰버 언더바·고정폭·가로 스크롤·‹› 사각 버튼/hover/커서/스크롤 방향 강조·트랙패드 가로)로 구현 완료. 아래는 착수 전 설계 근거(atlas 소유권·권장 순서·미채택 대안)로 보존한다.

- **무엇**(위 "chrome 고급화" 항목): 둥근 모서리·그라데이션·그림자·비례 UI 폰트의 measured artifact·아이콘 텍스처·격자 무관 sub-pixel.
- **무엇을 건드리나**: 렌더러 draw-list 프리미티브 + Metal 셰이더 + 셀/프리미티브 ABI, chrome consumer(사이드바·탭·팝업·Find·테두리) 점진 적용, 그리고 `GlyphQuadFrame` shared atlas에 연결되는 UI font glyph placement. 별도 UI atlas는 만들지 않는다.
- **분해 스케치**: C1 SDF rounded-rect(둥근 모서리·테두리) 1개부터 → C2 그림자/그라데이션 → C3 비례 UI text artifact·final pixel placement → C4 아이콘 텍스처. consumer는 단계마다 점진 적용.
- **의존**: 렌더러/ABI 확장. C3는 New Window의 atlas 소유권과 같은 **shared atlas growth·UV renormalization** 축이지만, 제2 atlas의 별도 수명이나 공유 가정을 만들지 않는다.

### 의존성·확정 순서 (사용자 결정 2026-06-14: New Window → restore → chrome)

- **하드 제약(반드시 지킴)**: **9단계 Workspace restore는 window-aware여야 한다.** New Window보다 먼저 하면 단일-창 스키마로 짜여, 멀티 창 도입 때 저장 포맷 migration이 강제된다 → **New Window를 먼저** 하거나, restore 스키마를 처음부터 `windows: […]` 차원으로 설계한다.
- **소프트 결합(규율로 흡수)**: rich Chrome glyph의 shared atlas ⨯ New Window의 atlas 소유권. atlas 소유권을 캡슐화(현재 `renderer_state`가 소유)해 두면 어느 순서든 재작업이 거의 없다 — 새 Chrome text가 "atlas는 싱글턴" 또는 terminal cell 위치를 다시 계산한다는 가정을 박지 않는 게 조건.
- **확정 순서(사용자 결정 — 재작업 최소 = 토대 먼저)**:
  1. **BCE(완료) + 작은 VT 갭(G1~G14 — 위 "VT 호환성 갭" 절)** — 결합 0, 순수 코어, 호환성. 아무 때나(워밍업·가성비, 위 순서와 독립이라 사이사이 끼움 가능). 우선순위 순(G1 SGR 속성·G2 OSC 색/클립보드부터)으로 각자 작은 PR.
  2. **New Window** — 세션·atlas 소유권이라는 가장 큰 가정을 먼저 확정(뒤 항목이 이를 전제).
  3. **9단계 Workspace restore** — 이제 자연히 window-aware.
  4. **chrome 고급화** — 확정된 atlas 소유권 위에서 점진(C1 rounded-rect부터).
  5. **영속 session host / 10단계 Plugin** — 독립 / 먼 미래. session host는 tmux-CC layout driver가 아니라
     Maru runtime backend이며 [영속 터미널 세션 호스트](persistent-session-host.md)의 제품 완료 범위 P1~P5를 따른다.
     앱 업데이트 사이 실행 중 runtime 보존은 [Session host 실행 중 업그레이드](session-host-upgrade.md)의 U0~U5를
     따른다. 현재 U0 inventory와 U1~U5 component seam, 제품 daemon controller 및 caller-attested signed
     N-1→current 하네스와 앱 재실행 orchestration wiring까지 구현되어 있다. 그러나 immutable release manifest provenance,
     실제 제품 rollback activation, 최대치 multi-runtime exact reattach, 전 구간 failure injection, frozen release 기반
     app-relaunch E2E·notice·soak가 남아 있으므로 U5 완료나 기본 자동 migration으로 표시하지 않는다. 정확한 증거 수준은
     [검증 매트릭스](verification-matrix.md#session-host-실행-중-업그레이드-gate)를 단일 출처로 따른다.
     P6 전체 workspace TUI/외부 tmux import adapter와 Plugin은 각각 실제 수요·착수 전 별도 논의.
- **검토했으나 미채택한 대안**(UI 완성도 먼저, 구조 리스크 뒤로): chrome 고급화를 New Window보다 앞에 두는 안. atlas 소유권 캡슐화 + restore 스키마 window-aware면 재작업은 낮으나, 큰 구조 변경을 미루는 대신 나중에 공유 검토할 atlas가 2개가 되는 트레이드오프 — 사용자가 "토대 먼저"를 택해 미채택.

## Session host 실행 중 transport reconnect (CR, CR0a·CR3a-1·2a·2b1·2b2·2c1 완료)

shared `Client`가 실행 중 unusable이 되어도 기존 Term/Surface/runtime handle을 유지한 채 exact host에 다시 붙이는 단계다.
규범 계약은 [영속 터미널 세션 호스트](persistent-session-host.md#실행-중-connection-invalidation과-재연결), 검증 상태와
종료 gate는 [검증 매트릭스](verification-matrix.md#영속-host-cr-실행-중-transport-reconnect-gate)가 소유한다. cold workspace
restore, host spawn, same-PID exec upgrade와는 별도 state machine이다.

1. **CR0a — typed poison taxonomy (완료):** reconnect와 artifact writer 없이 raw `Client.failClosed`와 내부 raw
   `invalidateConnection*` 직접 호출을 typed poison boundary로 모았다. 분류용 `Outcome`과 connection-fatal만 허용하는
   `ConnectionReason`을 타입으로 분리하고 `{scope,disposition,transport_usable,expected}` exhaustive golden table을 고정했다.
   최초 reason은 immutable이며 source/adoption/projection seal에 포함된다. clean EOF·read timeout/transport failure·framing
   truncation/malformed·write progress ambiguous/known partial·queue/OOM·peer contract·attachment cleanup을 구분하고 source
   boundary test가 named terminalization leaf 밖의 raw untyped callsite를 감시한다. semantic `Outcome` 4종은 이 단계에서는
   model-only이며 production semantic decode/dispatch 연결과 scope 축소는 CR1 범위다. reconnect와 artifact writer는 CR0b
   이후 범위다.
2. **CR0b — poison observability:** CR0a DTO만 소비하는 immutable `ConnectionIncident`, 최초 원인 보존, redaction/rate-limit,
   32 KiB emergency ring handoff→bounded disk writer 순서, Debug fail-stop과 Release artifact-before-recovery gate를 구현한다.
3. **CR1 — poison 범위 축소와 scheduler:** semantic stream 오류가 shared connection을 불필요하게 poison하지 않도록 callsite를
   정리하고 partial read/write, sibling stream, artifact 실패를 결정적으로 교차하는 scheduler fixture를 만든다.
4. **CR2 — stable shell 기반:** CR2a는 field inventory를 고정하고 `RemoteGeneration`만 추출한다. CR2b는 기존 Surface API를
   유지하는 stable proxy gate와 shell lifecycle pin을 배선한다. CR2c는 local/remote `InputOwner` facade를 도입하되 입력 의미를
   바꾸지 않는다. transport-neutral facade/ordered policy는 `src/app`의 `TermRuntimeBackend` 계약 옆 중립 모듈이 소유하고
   local/remote backend가 구현한다. CR2d1은 remote paste/IME/OSC52 queue, CR2d2는 key/control ordered merge, CR2d3은 event
   cursor, CR2d4는 cross-Window old transfer 제거/parity를 각각 golden trace로 닫는다. CR2e에서 순수
   `ReconnectReducer`의 exhaustive/illegal-transition model test와 fake `PreparedReconnect` prepare/publish/retire,
   allocator fail-index를 검증한다.
5. **CR3 — shared Client 세대:** CR3a는 두 merge slice로 닫는다. **CR3a-1(완료)**은 현
   Client/external-pump/final-address cleanup ownership inventory를 먼저 고정하고 cleanup lease의 제품 callback이 0인
   transport-neutral `ConnectionLease`와 generation 1 전용 `HostAdapter.ClientSlot` skeleton을 넣는다. `HostAdapter`는
   `initInPlace(out,node_allocator,source)`로만 생성하고 inline slot이 세대별 heap-pinned `ClientNode`를 단독 소유한다.
   process-global atomic `ClientIdentityIssuer`가 한 tagged checked counter에서 burn-on-reserve하는 nonzero
   `slot_incarnation`/`node_incarnation`이 address reuse ABA를 막는다. attachment당
   `ConnectionLease`는 exact node를 pin하는 immutable cleanup-only capability이고 마지막 pin release만 one-shot이다. 각
   drop/release/cancel은 canonical cleanup owner의 reservation을 얻어 `{kind,stream,opaque token digest}`에 결속된 별도
   final-address one-shot `CleanupPermit`으로 실행한다. permit 동안 parent pin release는 busy이며 cleanup result는
   `completed|retryable_preserved|indeterminate_or_partial`의 닫힌 전이다.
   두 타입 모두 raw `*Client`, 임의 callback, request/read/write admission을 노출하지 않는다. **CR3a-2**는 generation 1 compatibility
   wiring을 다섯 vertical merge gate로 닫고 각 gate 끝의 실제 제품 경로에는 canonical cleanup owner를 하나만 둔다.
   **CR3a-2a(구현):** GUI `RemoteRuntime` 안에 final-address `GenerationAttachment`, neutral binding leaf와
   `GenerationTransport` 최소 core(`capabilities|prepareRequest|executePreparedRequest|abortPreparedRequest|poison`)를 넣어 실제 attach/deinit의
   stream-drop reservation·lease release를 배선하고, 외부 CLI의 movable `RemoteAttachment` graph는 바꾸지 않는다.
   node-local cleanup registry의 canonical transport/response seal, opaque prepared RPC storage, response/binding/transport/request
   backing의 wire 전 non-alias preflight, wire 전 captured allocator와 Frame schema를 바꾸지 않는 parser out-parameter가 frame마다
   반환하는 실제 payload allocator를 제품
   타입으로 고정했다. response payload는 GUI parent 전체와 node canonical owner range에 겹치지 않아야 하며, forged alias나
   allocator drift는 connection을 poison하고 해당 bounded payload를 free하지 않는다. copy/ABA/reentry,
   poison-before-free, snapshot EOF rollback과 실제 daemon의 기본 attach/detach/reattach를 자동 검증한다. 이는 최소 core와 GUI
   attachment shell만의 완료이며 raw batch context 제거, 나머지 primitive, typed teardown, 전체 actual-socket parity는 각각
   2b~2e에 남는다.
   CR3a-2b는 `Client` 내부 accounting을 보존한 batch queue→node registry owner transaction을 실제 pump/release에 배선하고 GUI
   `AttachmentTransport.context=*Client`를 node-bound batch/drop adapter로 즉시 교체한다. 이 단계는 다음 두 TDD merge gate를
   순서대로 닫는다. **CR3a-2b1(구현)**은 node-local fixed-cap batch entry와 pointer-free token, `Client`의
   `pending -> transferred -> released` 회계를 도입하고, 이미 buffered된 batch와 방금 parser에서 완성된 requested-stream batch를
   같은 reserve-first all-or-none transaction으로 옮긴다. red test는 0/1/4,096/4,097 entry, 18 MiB exact/cap+1,
   0/1/4,096회 idle 뒤 reservation final-zero, allocator fail-index, direct-parser actual allocator drift·payload alias·partial rollback,
   foreign-stream demux, accounting receipt/counter drift의 free 0, release callback 재진입 중 charge 보존을
   production `ClientNode` 타입으로 고정했다. registry별 incarnation과 checked-monotonic entry generation이 copy·ABA·cross-node·
   stream splice를 거부하고, exact transfer ledger가 duplicate/replay receipt를 차단한다. parser가 실제 사용한 allocator를
   node/slot/source canonical range와 대조하며 batch scope 전후 descriptor 복원과 일반 RPC 재사용을 검증한다. parser의
   guarded allocator alloc/free callback에서는 same/foreign `ClientSlot` read/release/deinit 재진입을 busy로 닫는다.
   모든 batch release callback은 nested release/deinit을 막고, buffered payload callback의 read는 allocation 없는 exact pending
   sibling만 허용하며 miss는 registry reserve·socket/parser 전에 busy로 거부한다. callback 종료 뒤 원래 token·미소비 wire와
   teardown이 정상 진행됨을 production-type unit으로 고정했다. **CR3a-2b2(구현)**는 `GenerationAttachment`가 inline 소유하는
   final-address node-bound batch adapter를 실제 `RemoteAttachment.pumpScreen`/release에 연결한다.
   `AttachmentBatchLease.generation`은 pointer-free node registry token만 보관하고 external recovery ledger의 `.charged`와 섞지
   않는다. adapter callback context는 exact inline adapter이며 raw `*Client`/`*HostAdapter`를 노출하지 않는다.
   `commitAccepted`의 legacy transport 인자를 제거하고 generation payload는 이 adapter를 직접 bind한다. 신규 read admission을
   닫은 뒤에도 pending generation token 전량을 release할 때까지 release-only draining authority를 유지하고, 전량 settle 뒤 기존
   2a canonical `beginAttachmentDrop -> deinitPayloadOnly -> finishActiveAttachmentDrop`이 stream drop과 lease release를 exact once
   수행한다. 별도 transport drop callback은 만들지 않고 기존 canonical drop의 무회귀를 증명한다. 정상 generation release는
   completed-only strict 경로이며 stale/spliced/replay token은 generic `failed_release` 보존이나 sibling 진행 전에 제품 invariant
   fail-stop한다. retryable/indeterminate handoff는 CR3a-2d 전에는 열지 않는다. source boundary는 legacy GUI fallback의 raw
   `attachmentTransport(*Client)`와 initial snapshot/event/input/RPC allowlist를 유지하되 generation commit/pump에서는 raw
   context/cast를 0으로, raw `readGenerationBatch`/`dropBufferedStream`은 `ClientSlot` sole canonical caller로 고정한다. external
   movable `RemoteAttachment`의 outer field 목록, 기존 `untracked|charged` reachable 의미와 `ExternalPumpStorage`/external
   `Prepared|Attached`의 outer owner schema·동작은 바꾸지 않는다. 내부 `AttachmentBatchLease`에는 generation 전용 variant가 추가되므로
   그 union의 state space/layout 불변은 주장하지 않는다. 2b2 끝에 production type GUI attach→post-initial snapshot/delta
   pump→release→deinit, buffered/direct, idle/error/OOM, multi-token FIFO/compaction과 exact-once cleanup을 실행하고
   Debug/ReleaseFast/boundary/전체 check를 재실행한다. initial snapshot의 raw `Client.readSnapshot` 제거와 전체 actual-socket
   failure parity는 각각 2c/2e 범위다. 두 gate 모두 reconnect/current publish, incident/artifact, workspace 및
   host/runtime lifecycle mutation은 0이다. CR3a-2c는 나머지 stream/event primitive를 최소 core에 추가해
   `RemoteRuntime.client` direct escape를 HostAdapter가 발급하는 작은 closed transport facade로 완전히 교체한다. exact
   15-method 집합은 2b2가 별도 소유하는 `readAttachmentBatch`를 중복하지 않고 `purgeEndedStream`을 포함한다. purge는 임의
   stream ID가 아니라 exact binding/runtime/controller generation에 결속된 one-shot ended receipt만 소비하며 조기 demux
   purge와 최종 canonical drop 권한을 분리한다. initial snapshot은 bare slice가 아니라 allocator provenance와
   transport/binding/stream identity를 봉인한 final-address owner로 반환해 apply 성공·OOM·malformed 모두 exact once free한다.
   `RemoteRuntime`은 `legacy|generation` connection union을 유일한 mode SSOT로 쓰며 기존 raw Client entrypoint는 legacy arm에만
   격리하고 generation 실패를 legacy로 fallback하지 않는다. 2c는 review 가능한 네 TDD merge gate로 닫는다.
   **2c1(구현)**은 `InitialSnapshotOwner`와 generation `readInitialSnapshot`을 제품 attach stack에 배선하고 raw snapshot read를 legacy
   arm에만 남긴다. owner/transport stale 복원은 heap-pinned `ClientNode`의 checked-monotonic canonical stream-operation permit으로
   차단하고, allocator free callback 동안 permit을 유지해 attachment/slot teardown 재진입을 `busy`로 고정한다. 이 permit의 exact
   binding seal과 닫힌 외부 error normalization을 2c2~2c4가 공통 admission 기반으로 재사용한다. **2c2**는 sealed ended receipt와
   all-or-none early demux purge를 배선한다. generation arm은 일반 event loop보다 먼저 무인자
   `purgeEndedStream() -> PurgeEndedError!PurgeEndedOutcome`을 호출한다. outcome은 `.not_ended|purged`, error는
   `.busy|invalid_owner|corrupt|terminal`의 닫힌 집합이다. registry/다른 stream operation 충돌은 모든 mutation 0의 `.busy`, moved/copy/thread/binding
   불일치는 모든 mutation 0의 `.invalid_owner`, precommit descriptor/counter/seal 손상은 demux queue/counter·attachment·lease/registry
   mutation 0과 connection terminal poison exact 1의 `.corrupt`로 normalize한다. 이미 committed인 process quarantine latch는 현재
   connection을 추가로 poison하거나 mutate하지 않고 `.terminal`이다.
   transport는 현재 binding의
   `{slot/node/transport, host, connection generation, immutable binding incarnation/runtime, non-reused stream}`과 admission seal이 살아
   있는 target-stream 첫 `runtime.ended` event만 private stack-final-address receipt에 결속해 같은 호출에서 소비한다. ended는 role과
   무관한 lifecycle event이고 mutable current role/controller generation은 binding SSOT에 없으므로 receipt가 추측하거나 봉인하지
   않는다. 작은 allocation-free peek가 ended가 없으면 event take/release와 대형 scratch frame 없이 즉시 `.not_ended`를 반환하고,
   ended가 확인된 때만 별도 noinline transaction helper에 들어가므로 2c3의 일반 event facade를 선취하지 않는다.

   prepare는 Client-owned 미전달 `pending_batches`, optional `partial_batch`, 이미 분류된 `pending_stream`, `pending_events`의 전체
   descriptor·allocator provenance·event seal·byte counter를 fixed inline scratch에 복사해 검증하며 mutation/free/allocation 0이다.
   scratch는 per-item digest 대신 compact target bitset과 queue별 aggregate payload seal을 쓰며, descriptor 배열 cap은 제품 queue cap과
   같고 기존 `ExternalAdoptionCleanupScratch`와 같은 compile-time `<= 512 KiB` 예산을 지킨다. target stream에
   `GenerationBatchRegistry`의 reserved/ingress/live/releasing entry가 하나라도 있으면 mutation 전에 `busy`로 닫는다. transferred
   batch/token/accounting, parser raw RX/framing, attachment pending lease/screen, cleanup registry와 connection lease는 정상 purge와 모든
   precommit failure의 payload cleanup 대상이 아니다. postcommit Client-owned deinit graph drift의 terminal suffix만 owned allocation을
   개별 정리하거나 권위를 넘기지 않고 no-free 상태로 버리며 borrowed ledger/attachment/registry/lease는 그대로 둔다. commit은 receipt
   `EndedPurgePreparation.sealForCommit` 뒤 immutable target descriptor scalar에 대한 cleanup authority를 취득하고 별도 private cursor를 callback 전에 advance한다. descriptor bytes를 overlay하거나 별도
   full-size 배열을 만들지 않고, 네 queue stable compaction과 최종 counter publish를 첫 allocator callback 전에 끝낸다. 이후 fallible
   work는 0이고 callback 중 canonical queue/source reread도 0이다. 마지막 callback 뒤에는 frozen survivor descriptor/range seal과 current
   queue ownership metadata를 비교하는 post-validation을 정확히 한 번 수행하고, 구조가 일치할 때만 sibling aggregate payload seal을 다시 읽는다.
   node permit은 이 post-validation까지 유지한 뒤 node permit→transport receipt 순으로 소비한다. permit이 live인 동안 sibling을
   포함한 Client input/event/RPC/queue mutation과 attachment/slot teardown은 모두 `busy`이며 read-only scalar 관측만 허용한다. public
   Maru API callback 재진입은 같은 규칙으로 sibling을 byte-for-byte 보존한다. blocking generation Client의 `build_id`/`Client.lifecycle`,
   parser backing, optional pending outbound, 네 queue
   backing과 nested owned extent를 포함한 complete Client-owned deinit graph checked sum이
   `max_ended_purge_quarantine_bytes = 64 MiB` 이하임을 검증한다. list/parser/partial은 capacity backing을, slice payload와
   `build_id`/`Client.lifecycle`/pending outbound는 exact owned length를 합산한다. external mode는 mutation 0으로 거부한다. cap 초과의 precommit
   no-cleanup poison은 owner free/tombstone/quarantine 0으로 reason/unusable을 latch하고 validated captured fd만 detach+close해 later ordinary
   deinit이 intact owner를 회수하게 한다. 모든 graph/cap/profile 검증 뒤 commit gate의 마지막 fallible step으로 one-slot reservation을
   잡고, 성공 뒤에는 `EndedPurgePreparation.sealForCommit`과 no-fail suffix만 남긴다. 정상 post-validation은 reservation을 release하되
   node permit→transport receipt paired consume이 끝날 때까지 Client exclusive를 유지하고, 그 뒤에만 exclusive를 clean release한다. 구조 drift에서는
   current pointer·allocator·fd를 역참조하지 않고 canonical Client-owned deinit fields를 empty/null로 tombstone하고 reservation을 exact
   once 영구 commit한 뒤 `quarantined_no_free` absorbing poison을 게시한다. 어떤 postcallback drift에서도 fd는 close하지 않는다. allocator,
   generation accounting ledger, observer, attachment, registry와 lease 같은 borrowed authority는 dereference/release/mutate 0이다. exact 순서는
   `all target cleanup -> Client-owned deinit tombstone -> Registry.commit(+CommitReceipt) ->
   Registry.consumeCommitted(+ConsumedCommitProof) -> no-free poison + PreparedEndedPurgeCommit consumed -> terminal fence -> node permit ->
   EndedPurgePreparation transport receipt`이다. 이 sticky process latch 뒤 새 generation Client/reconnect/ended-purge admission은 terminal로
   거부되어 누적 quarantine은 한 건·64 MiB를 넘지 않는다. replay charge는 0이다. 이후 generic teardown은 변조된 pointer를 다시 읽거나
   free하지 않으며 해당 connection의 남은 Client-owned allocation은 버린다. commit 전 오류는 `.not_ended`와 구별된 typed error이며
   위 error별 허용 mutation만 수행한다. commit 뒤 정상과 drift-poison 모두 target cleanup을
   끝내고 no-fail node permit/transport receipt consume을 실행하며, clean은 그 뒤 Client exclusive clean release를 마지막으로 실행한다.
   public 결과는 `.purged`다. tests는 poison latch를 별도로
   검증한다. early purge는 canonical attachment drop·registry token release·node cleanup
   registry·connection lease를 소비하지 않으며 later teardown의 raw demux 정리는 idempotent no-op이다. **2c2a(구현)**는 2c1의 snapshot
   전용 permit/active tuple/process registry를 kind-tagged `StreamOperationPermit` SSOT로 migration하고 snapshot↔ended-purge 상호 busy와
   copy/splice/replay 거부를 production-type test로 고정했다. `GenerationBatchRegistry.streamIdle(stream_id)`도
   reserved/ingress/live/releasing 전 상태를 target purge blocker로 분류한다. **2c2b1(구현)**은 `pending_events`에서 대상 stream의 첫
   event만 bounded scan하고, admission identity가 보존된 `runtime.ended` 후보의 비권위적 index hint만 allocation·payload hash·queue/counter
   mutation 0으로 반환한다. payload byte와 전체 queue ownership metadata의 권위 검증은 permit 아래 slow transaction이 다시 수행하며,
   hint 자체로 receipt나 purge 권위를 만들지 않는다. **2c2b2(구현)**는 exact binding과 common stream-operation permit 아래 fixed inline
   scratch를 사용해 모든 Client-owned demux queue와 기존 Client owner graph의 descriptor·allocator provenance·counter·event admission
   seal·payload·exact/partial alias를 allocation/free와 Client queue/owner 및 process-global quarantine mutation 0으로 검증한다. target
   bitset·queue별 aggregate seal·checked quarantine capacity는 final-address private preparation에 봉인한다. process-global quarantine은
   이 prepare 단계에서 예약하지 않으며 실제 reservation은 첫
   allocator callback 전에 수행하는 commit gate가 소유한다. 아직 target detach/stable compaction, callback cleanup, post-validation,
   quarantine reservation/commit과 poison suffix, transport/GUI 제품 배선은 구현하지 않았으므로 2c2 완료를 주장하지 않는다.
   **2c2b3a(구현)**는 neutral `ended_purge_transaction.zig`가 target bitset의 stable source/target/survivor ordinal과 b2-provided
   count/byte scalar의 checked survivor 산술만 계산하는 non-owning pure plan이다. pointer-free/copyable `QueueInput`은 source/claimed-target
   count와 source/target bytes만, `QueuePlan={state:u8,scalars:QueueScalars}`는 성공한 source/target/survivor count와 bytes만 가진다.
   raw state 0/1 이외 값은 ReleaseFast에서도 scalar 해석 전에 `InvalidState`로 닫는다.
   empty success도 planned이며 오류에서는 입력 out을 byte-for-byte 보존한다(pristine 실패는 pristine, occupied 실패는 기존 값 유지).
   검증 우선순위는 destination→count→target map→checked arithmetic이고 `max_items<=4,096`, 비용은
   `O(source_count + ceil(max_items / word bits))`다. ephemeral `DispositionCursor`만 bitset을 borrow해 stable
   `{source ordinal,target-or-survivor ordinal}`을 반환하고 위조 ordinal/count는 typed error로 fail-close하며 완주 상태는
   `validateComplete()`가 target map/count/ordinal을 typed 재검증한다. caller의 targets/out non-alias는 b3b actual preflight가 재검증한다. plan/step의
   address·allocator·payload pointer·scratch reference와 seal
   mint/검증은 0이다. `buildQueuePlan` error set은 `InvalidCount|InvalidTargetMap|ArithmeticOverflow|DestinationOccupied|InvalidState`다. Client/allocator callback/quarantine import, scratch·queue·process mutation,
   owner freeze, allocation/free와 permit/receipt consume은 0이다. **2c2b3b(B3b-F·B3b-S·B3b-O 구현 완료)**가 private scratch의 immutable/no-escape 원본 descriptor를
   cleanup authority로 사용해 exact preparation revalidation부터 reservation, `EndedPurgePreparation.sealForCommit`, stable compaction/counter publication,
   모든 target exact-once callback, post-validation, 정상 release 또는 absorbing no-free quarantine을 하나의 vertical transaction으로
   닫는다. revalidation/cap/reservation까지는 typed precommit failure, `EndedPurgePreparation.sealForCommit` 뒤 suffix만 no-fail이다. private scratch의 coherent arbitrary overwrite와 cleanup authority 밖에서 이미 수행된 deallocation의
   탐지·복구는 비목표지만 callback 재진입·canonical descriptor drift·allocator provenance/alias 검증은 유지한다. b3a만으로 target
   final-zero나 2c2 완료를 주장하지 않는다. b3b의 doc-first boundary는 AST canonical
   `(parent,kind,visibility,modifier,name)` production inventory를 사용해 root와 owner container를 함께 검사한다.
   허용 tuple 제외 baseline은 client(root+Client+EndedPurgeScratch+PreparedEndedPurgeInventory)=527/SHA-256
   `594178e6c653e30be0ddc64564d2783922e0c0b4895c3543479f86e5977db6fd`,
   client_slot(root+ClientSlot+EndedPurgePreparation)=126/SHA-256
   `03a92a146dbf8935466d0b9250b09c884d575f15fc148f73c6db8979bc69d968`이다. B3b-F/S 전체 신규 top-level allowlist는 client의
   `ClientOperationFence|generationAllocatorCallbackActive|ended_purge_transaction|ended_purge_quarantine|PreparedEndedPurgeCommit|
   EndedPurgeCommitError|EndedPurgeClientCommitOutcome`, client_slot의
   `ended_purge_quarantine|ended_purge_quarantine_registry|process_runtime_pid`뿐이다. B3b-F/S/O의 신규 nested method/type exact
   allowlist는 `persistent-session-host.md`를 SSOT로 사용하고 executable boundary inventory가 이를 고정하므로 여기서 중복 열거하지 않는다. 별도
   `ended_purge_quarantine.zig`는 std와 scalar identity/bytes만 아는 allocation-free one-slot
   `max_ended_purge_quarantine_bytes|Error|Reservation|CommitReceipt|ConsumedCommitProof|Registry` API를
   소유한다. nested exact allowlist는 `Reservation.Lifecycle`, `CommitReceipt.Lifecycle`, `ConsumedCommitProof.matches`,
   `Registry.State|init|reserve|release|commit|consumeCommitted`뿐이다. proof는 인증 capability가 아니라 pointer-free correlation evidence이며
   semantic-exact 합성의 런타임 방지는 주장하지 않으며 B3b-O exact production caller/source closure가 정상 제품 proof의 provenance와
   consume→finalizer 순서를 소유한다. `pending_outbound`는 nullable 거부가 아니라 `build_id`·`Client.lifecycle`과 함께 각각 독립된
   scratch frozen descriptor, complete-owner cap/alias/seal,
   postvalidation과 tombstone 전 구간에 포함한다. preparation 재검증 뒤 registry reservation이 마지막 fallible step이고,
   `EndedPurgePreparation.sealForCommit` 뒤 Client no-fail commit을 실행한다. drift는 `finalization_pending` preparation과 Client-owned graph tombstone까지만 게시하고,
   ClientSlot이 quarantine commit으로 발급한 exact-once `CommitReceipt`를 trusted Registry로 consume해 pointer-free
   `ConsumedCommitProof`를 만들고, Client finalizer가 proof를 검증한 뒤 poison/terminal을 게시하고,
   prevalidated node permit→`EndedPurgePreparation` transport receipt paired consume을 끝낸다. clean은 paired consume 뒤에만 Client
   exclusive를 clean release하고, drift는 이미 terminal fence가 absorbing 상태를 소유한다. client는 raw owner mutation/direct cleanup과
   scalar proof sealed finalization만, client_slot은 registry receipt consume과 node permit→preparation transport receipt paired consume 순서만 소유한다.
   B3b-O의 red gate는 `EndedPurgePreparation`의 `prepared→committing→consumed` final-address 전이,
   Client prepare/commit/finalize의 test 밖 production callsite exact one, clean의 reservation release→node permit→transport receipt→exclusive release,
   drift의 Registry commit→consume→finalizer→node permit→transport receipt 순서를 먼저 실패로 고정한다. 구현 green 뒤에도 reconnect/current publish는 0이며,
   Debug·ReleaseFast subprocess의 validated suffix mismatch fail-stop, 격리된 drift subprocess의 quarantine commit→proof→finalizer→paired
   consume과 boundary source-order oracle까지 통과해야 B3b-O를 구현으로 승격한다.
   node permit consume은 기존 global mutex unregister를 callback 뒤 재호출하지 않는다. 기존 registry entry에 atomic
   `empty|live|consume_reserved|consumed` state를 추가하고 live `{id,permit}` payload를 immutable하게 유지하며, callback 전 private final-address
   `PreparedStreamOperationPermitConsume`을 준비한다. irreversible suffix는 canonical operation thread를 graph 접근 전에 검증하고
   `consume_reserved→consumed` CAS, node active tuple clear,
   preparation consume, `consumed→empty` reclaim만 수행하고 mutex·scan·allocation·fallible lookup은 0이다. 중간 `consumed`가 transport
   receipt 게시 전 같은 index 재사용을 막는다. multi-thread winner 경쟁은 범위가 아니며 same-thread copy/replay exact-once만
   계약한다. 등록과 empty entry 재사용은 기존 mutex와
   checked-monotonic id를 유지하며 CAS 뒤 payload는 다음 등록 전까지 지우지 않는다.
   **2c3**은 capability/input/control/event/RPC primitive를 exact facade로 옮긴다. **2c3a 구현 완료**:
   exact input/revoke/output-progress facade, raw lifecycle admission, canonical controller authority와
   bound-drop transaction을 Debug·ReleaseFast `test-session-host` 및 boundary gate로 닫았다. 내부 순서는 2c3a
   input/revoke/output-progress+raw lifecycle admission, 2c3b capability+closed RPC, 2c3c control, 2c3d one-shot event,
   2c3e generation 제품 RPC/decoder direct-call source-zero+immediate EOF/unread RX-first socket parity다. event/effect repo-wide
   source-zero와 admitted-event socket parity는 2c3d C3-3c가 소유한다. 2c3a~e가 모두 green일 때만 generation arm의 direct
   `logicalClient()`/`Client` method 사용 0을 주장한다. **2c3b-1 capability facade 구현 완료**: const receiver의 raw-first admission과
   registry-resolved canonical node operation pin 아래 exact `GenerationCapabilities` value projection을 구현했다. untrusted slot 주소는
   registry 비교 전 역참조하지 않고 owner-seal/capability enum의 invalid raw byte를 fail-close하며, facade production callsite 0과
   shared `RemoteRuntime` architecture raw-read exact baseline을 boundary gate로 고정했다.
   **2c3b-2 request-side canonical authority와 2c3b-3의 B3-0a~B3-6 internal aggregate strict completion은
   구현·검증 완료**했으며, public decoder와 legacy/generation observable parity는 2c3e 후속이다. 다음 gate는 2c3c control facade다.
   2c3b-2는 `RuntimeRequestTag -> RequestFamily -> role/phase -> method` 전수표와 닫힌 prepare/abort error,
   같은 binding entry의 node-sealed `PreparedRequestAuthority`가 opaque `PreparedBlockingRpcStorage`의 frame descriptor·allocator
   provenance·incarnation·tag/id/digest를 한 transaction으로 pair-seal하는 경로까지 구현했다. 기존 attach-compatible execute도 이
   authority를 begin/revalidate/settle하도록 hardened했다. request allocation fail-index, scope token·owner/client-backing exact/partial
   alias, cross-splice·same-address ABA, issuer exact-max와 actual socket accepted/uncertain 경계를 Debug/ReleaseFast에서 고정했다.
   legacy/generation 제품 decoder parity는 계획대로 2c3e가 소유한다. `GenerationTransport`의 direct prepared-Client API 호출은 0이 되며 모든
   prepare/abort는 registry scalar lookup 뒤 canonical node operation pin 아래 실행한다. 이 gate는 public RPC destination, 반복 RPC
   response authority·borrow/finish 또는 새 관측 가능 wire/product behavior를 열지 않고 기존 attach 실행 parity를 유지한다. `spawn_full`은
   connection/bootstrap 전용 tag로 union에는 유지하지만 attachment-bound facade의 classifier가 prepare 전에 항상
   `Unauthorized`/wire 0으로 거부한다. union 제거 여부는 2c4 surface cleanup에서 판단하며 그 전까지 허용 의미는 바뀌지 않는다.
   request/execute의 temporary allocator 교체는 final-address scope token을 caller stack에 in-place mint하고 그 exact range를 guarded
   allocator에 포함한다. public token은 pointer-free allocator scalar만 가지며 Client-private identity만 typed allocator를 보유한다.
   prepared request가 executing으로 전이된 뒤의 allocator-scope·response-incarnation issuer 소진은 canonical request backing을
   먼저 exact settle한 뒤 authority terminal+connection poison으로 닫는다. 아직 authority를 publish하지 않은 transport/registry
   issuer의 preflight 소진은 mutation 없는 `IdentityExhausted`다. declared attachment owner range는 transport와 opaque
   prepared storage를 완전히 포함하면서 canonical slot/node/Client/owner-seal range와 겹치지 않아야 한다.

   **2c3b-3은 response-side execution/ownership**을 구현한다. client-slot-internal
   `ResponseDestination = attach:*ExecutedResponse|rpc:void` 전환, 별도 node-sealed
   checked-monotonic RPC epoch authority, Client의 zero-write/ambiguous-write closed progress evidence, canonical `GenerationTransport`
   inline single-slot `RpcExecutedResponse` publish·private lexical borrow·owner-only finish와 strict fail-stop을 한 gate로 닫는다. production
   `RemoteRuntime` decoder 전환과 legacy/generation observable parity는 2c3e가 소유하며, 2c3b-3은 private borrow bridge와 production
   callsite 0 baseline까지만 고정한다. attach는 기존 registry의 one-shot `ExecutedResponse`를 유지하고 반복 RPC는 독립 authority로
   분리한다. 독립 movable payload, 호출 수에 비례하는 one-shot destination collection/fixed response pool과 임의·public reset은 두지 않는다.
   오직 성공한 `.reusable` finish의 같은 registered operation no-fail suffix만 clean terminal을 bytewise pristine single slot으로 rearm한다. red gate는
   2회·64회 순차 RPC, attach/RPC destination tag mismatch wire 0, copy/move/same-address ABA, cross transport/binding/request/
   digest/epoch splice, pre-wire typed reject 뒤 재사용, uncertain·accepted 미소비 뒤 terminal, allocator drift·alias·free callback 재진입,
   node-sealed authority/whole-transport restore, exact safe-free와 ambiguous no-free product fail-stop, epoch 소진,
   teardown busy/fail-close를 production type·subprocess·Darwin socketpair로 고정한다.
   이 aggregate gate는 내부 TDD slice `B3-0a`~`B3-6`을 순서대로 병합했고, 마지막 slice 전까지 상태를
   `2c3b-3 구현 중`으로 유지한 뒤 B3-6 merge로 완료했다. 내부 slice는 공개 RPC surface를 부분 완료로 노출하지 않았으며 generation 제품
   callsite와 정상 observable wire/product behavior는 0이다.

   1. **B3-0a attach ambiguous-free remediation:** 현재 attach accepted tail의 exact-owned safe-free와 owner/allocator/range가
      불명확한 no-free를 먼저 분리한다. alias·overflow·allocator drift는 forged payload를 read/hash/free하지 않고 terminal evidence를
      `client_slot.executeGenerationRequest` production strict wrapper가 즉시 fail-stop으로 소비한다. operation-scoped 단일 in-place
      payload allocation slot의 Frame generation 기반 exact target promotion(ptr/len scan 0), OOB 1/64/누적 cap 초과와 immediate retired-slot
      reuse, observer 밖 parser/pending backing resize/remap parity, ledger heap backing allocate/grow/free 0과 callback 전후 in-place semantic seal,
      sealed forbidden inventory 기반 payload disjoint 검증, zero-length와
      generation wrap을 함께 닫는다.
   2. **B3-0 attach execution transaction seam (완료):** request backing과 `PreparedRequestAuthority`만 함께 정산하는 private final-address
      `PreparedExecutionTxn`의 상태·결정표를 characterization gate로 고정한 뒤 현재 attach-only 실행을 이 owner로 옮긴다. attach
      response owner·payload와 미래 RPC authority는 transaction에 넣지 않는다. 공개 signature, registry layout, frame schema와 정상
      response bytes는 바꾸지 않는다. 내부 순서는 **B3-0.1(완료)** 현재 attach 종료 행의 반환값·storage settlement·exact
      authority lifecycle·최초 poison·canonical guarded-wrapper 진입과 parent physical free golden,
      **B3-0.2(완료)** final-address transaction pure lifecycle/copy·move·duplicate·scope hostile tests. bounded live operation receipt,
      raw-safe phase/settlement, callback 전 canonical snapshot과 descriptor-splice 무역참조, fork child의 inherited mutex 선차단,
      fixed free-stack O(1)과 live receipt를 보유한 동안의 sibling teardown 강제 중첩을 Debug/ReleaseFast 및 boundary oracle로 닫았다.
      **B3-0.3(완료)**은 `executeGenerationRequest`가 valid backing을 확인한 직후 stack final-address transaction을 만들고,
      registry begin·pre-wire rollback·issuer exhaustion·post-execute reusable/terminal 정산을 모두 transaction method로만 수행하게
      이관한다. 공개 response destination은 pointer materialization 전에 두 단계로 검증한다. registry admission 전 caller scalar owner의
      overflow/full-containment를 비역참조 prefilter로 거르고, admission 뒤에는 그 owner가 registry의 canonical owner와 exact-match하는지와
      canonical owner 안 full-containment를 다시 증명한 뒤에만 pointer를 만든다. guard 이후 final-address cleanup coordinator가
      ledger→allocator→guard를 exact once로 닫고, transaction/cleanup 자체 stack authority도 allocator payload alias 금지 inventory에
      포함한다. 별도 보호된 caller-local expected stage가 cleanup transcript drift와 무관하게 실제 획득한 resource suffix를 결정하며,
      caller-local completion byte만 defer의 idempotent no-op를 허가한다. `.settled`/`.finishing` lifecycle 값만으로 완료나 reentry를
      주장할 수 없고, address-bound thread-local active finisher가 일치하는 실제 same-thread reentry만 outer finisher가 남은 suffix를
      닫을 때까지 failure로 latch한다. 각 callback 뒤 final-address transcript를 재검증한다.
      모든 transaction settlement는 cleanup의 typed 결과 뒤에만 authority를 게시하며, cleanup 실패는 reusable publication 없이
      request authority를 terminal fail-stop으로 정산한 뒤 process를 중단한다. 네 settlement method의 공통 precondition은 exact live
      operation/final-address owner를 먼저 mutation 0으로 인증하고 그 뒤 operation guard가 닫혔음을 검사한다. copy/move/foreign
      operation은 canonical guard를 읽거나 바꾸지 않는 typed `ProtocolError`이고, exact owner의 열린 guard만 cleanup 누락 terminal
      fail-stop이다. guard 이후 ordinary exit는 단일 `settleExecutionAfterCleanup` seam만 사용하며 그 함수가
      cleanup→closed intent settlement→transaction finish 순서를 소유한다. 따라서 새 exit가 coordinator 호출을 빠뜨려도
      reusable/terminal publication으로 진행하지 못하고, exit별 복제 순서가 서로 drift하지 않는다. 기존 `ExecuteDisposition`,
      `rollbackExecutingRequest`, `terminalizeExecutingRequest`,
      `terminalizeExecutingRequestWithStorageCleanup`의 product identifier/callsite/declaration은 0이어야 하며 정상 wire/result/최초 poison은
      바뀌지 않는다. issuer exhaustion의 backing abort가 reusable이면 기존 `IdentityExhausted`, 이미 terminal이면 정산 후
      `ProtocolError`라는 기존 error mapping도 transaction method가 보존한다. **B3-0.4/B3-0(완료)**는 test-private
      `B3ExecutionHarness`와 closed 13-row `B3Scenario`/`B3Expected` 표를 단일 출처로 두는 actual socket·fail-index·strict cleanup
      aggregate gate다. Darwin socketpair에서 accepted payload, request 전체 수신 뒤 EOF, partial response 뒤 EOF를 public
      `prepareRequest→executePreparedRequest`로 실행하고 0-byte EOF는 `connection_eof`, partial frame EOF는 `frame_malformed`로
      구분한다. request bytes, result/error, storage settlement, authority idle/terminal,
      first poison, response transcript/bytes와 request/payload alloc/free를 비교한다. request prepare와 execute/response allocation은
      서로 다른 ordinal sweep으로 0부터 최초 성공까지 전수한다. request-prepare OOM은 wire 0/reusable, execute-side OOM은 request
      전체 전송 뒤 terminal uncertain이라는 phase 경계를 고정하며 success sentinel과 guard/allocator scope/ledger/registered operation
      final-zero를 요구한다. txn/cleanup/expected-stage/completion alias와 cleanup transcript·allocator restore·guard-end drift는
      compile-filtered `/usr/bin/env -i` subprocess에서 terminal authority publication-before-SIGABRT와 ambiguous free 0을 증명한다.
      focused B3-0.4 artifact는 exact expected test count와 process-local category sentinel로 zero-test/skip green을 막고 같은 gate를
      Debug·ReleaseFast에서 실행한다. public declaration/callsite/frame/registry layout delta는 0이다.
      현재 `B3ExecutionHarness`는 final-address allocator chain·ClientSlot/binding/transport·actual peer join·response/authority teardown을
      소유하며 actual EOF/partial-frame와 execute alloc/resize sweep이 이 harness를 함께 쓴다. request-prepare ordinal은 같은 focused
      artifact에 포함되고 alloc/resize는 실패가 실제 주입되지 않은 첫 성공 전까지 독립 전수한다. closed 표는 exact error 계열·최초
      poison·response lifecycle·request/payload free·final-zero 필드를 포함하며 admission/local-preflight/pending-flush terminal/uncertain/
      accepted/accepted-alias를 포함한 13행 모두가 제품 실행 또는 strict child와 연결됐다. focused root는 무관한 barrel test 없이
      B3 8개, strict root는 2개를 각 optimize mode에서 exact-count하며 issuer clean/content-drift 4행의 전용 product fixture 1개도
      양 모드 dependency다. strict root는 response owner alias와 cleanup descriptor/stage·ledger end·allocator restore·guard end의
      여섯 격리 실행을 각각 통과해야 focused runner가 시작된다.
      content drift는 exact descriptor free 뒤 `ProtocolError`·terminal authority·local invariant poison이라는 현재 제품 결과를 표에 고정한다.
      fail-index는 호출 ordinal마다 전진해 target 한 번만 실패하며, harness teardown은 ReleaseFast에서도 allocator outstanding byte 0과
      operation-registry의 bounded begin/end receipt transcript가 모든 순차 operation을 exact once로 반환하고 allocator outstanding byte가
      0인지 ReleaseFast에서도 fail-stop으로 강제한다. txn/cleanup/expected-stage/completion exact·left/right partial·overflow alias 행렬도
      focused 제품 모듈에서 실행한다. 10개 일반 행은 실제 call result/error·authority query·response payload free receipt·cleanup 이후
      final-zero로 만든 `B3Observed` 전체를 표와 비교한다. issuer 4-case 제품 fixture와 두 aggregate 행은 중립
      `b3_issuer_oracle`을 공유하며 socket wire byte 0, payload 미관측, cleanup·operation receipt·allocator final-zero를 비교한다.
      response-alias child는 실제 exact request peer와 제품 상태에서 낸 transcript를 표로부터 생성한 문자열과 비교한다. 여섯 strict
      child는 canonical request free exact 1, noncanonical backing free 0, response payload free 0을 독립 marker로 고정하고 cleanup
      5개는 terminal publication marker가 panic보다 앞서는지 검증한다. 이 증거로 B3-0.4와 B3-0을 완료했다.
   3. **B3-1 inert RPC authority (완료):** production execute callsite 0인 node-local `RpcResponseAuthority` leaf와 같은 cleanup-registry
      binding entry의 `rpc_response_authority` field를 넣는다. reserve가 final address에서 exact binding identity로 authority를
      초기화하고 clear 뒤에는 다시 pristine zero가 된다. leaf는 raw-first
      `idle|executing|published|borrowed|releasing|terminal`, checked-monotonic nonzero epoch, exact
      `{authority address,registry incarnation,binding,transport incarnation,request family/tag,id,digest,destination}` receipt를 소유한다. 이 PR에서는
      test/leaf 전이만 존재하고 Client·socket·allocator·payload·decoder·reconnect 제품 callsite는 0이다. production-type unit은
      copy/move, 같은 주소의 entry 재예약 ABA, cross-binding/transport/request/destination splice, epoch 0/max 소진, 모든 invalid raw
      lifecycle을 역참조·I/O 없이 거부하고, registry abort/drop/deinit이 idle/terminal-settled만 허용하며
      executing/published/borrowed/releasing은 busy, incoherent 상태는 corrupt로 분류함을 고정한다.
      authority가 payload를 소유하지 않으므로 coherent terminal이 곧 terminal-settled이며 별도 settlement bit는 두지 않는다.
      authority-owned issuer의 module-public 전이는 `reserveExecuting→rollbackExecuting|settleExecutingTerminal`로 제한한다.
      publish/borrow/release/finish는 leaf test-private이며 B3-4/5 payload-aware capability 전에는 제품에서 호출할 수 없다. 모든
      전이는 registry current binding+exact receipt/final-address를 요구한다. registry만 reserve suffix의 init, settled 확인, zero
      clear를 소유하고 authority pointer accessor/forwarding execute API는 이 단계에 없다.
      same-address 과거 authority 전체 복원은 leaf seal만 신뢰하지 않고 registry의 현재 exact binding identity와 재비교해 clear를
      거부한다. registry incarnation+reservation ID가 재사용되지 않는 freshness anchor다.
      기존 Entry의 exact identity 저장소는 authority binding 하나로 통합하고 active transcript는 binding을 중복 저장하지 않는다.
      `@sizeOf(Authority)<=256`, 4,096-entry registry의 기존 Entry 대비 증가량 `<=512 KiB`를 제품 타입 gate로 고정한다.
      registry incarnation과 Entry의 현재 reservation ID를 authority seal/receipt에 함께 결속해 stale authority+stale identity의
      동시 splice 및 같은 주소 registry reincarnation 뒤 reservation ID 재사용도 거부한다. leaf는 tag-family 구조 일치와 bound RPC family만 canonical로 만들며, role/phase/stream/
      destination admission은 B3-2가 소유한다. Debug·ReleaseFast leaf 4개와 registry 2개, boundary 1개의 exact-count
      focused gate와 전체 session-host gate가 B3-1 완료 증거다.
   4. **B3-2 private destination admission(완료):** classifier SSOT는 private `EntryLifecycle`·`ControllerAuthority`와 canonical
      `PreparedRequestAuthority`를 함께 소유한 `AttachmentCleanupRegistry` 하나다. 기존 prepare admission과 새 execute destination
      admission은 하나의 private closed decision table을 공유하되, prepare는 `RuntimeRequest.decode()`가 만든 tag/family를 소비하고
      execute는 `{Reservation, exact BindingIdentity, transport address/incarnation, PreparedCallReceipt, current bound_stream_id,
      AdmissionContext}`만 받아 registry의 canonical prepared transcript에서 tag/family를 다시 resolve한다. `AdmissionContext`는
      raw-first `prepare|execute_attach|execute_rpc`인 closed enum 하나이며 stage와 destination을 별도 입력으로 두지 않는다. execute caller가
      tag/family/role/phase/controller 상태를 별도 scalar로 주입하거나, registry `Entry` snapshot을 외부로 투영하는 API는 금지한다.
      이 context는 session-host 내부 분류일 뿐 public contract/response union이 아니다.
      `current bound_stream_id`는 authority가 아니라 final-address `GenerationTransport.requestOperation`이 매 호출 투영하는
      drift probe다. lower wrapper에 임의 scalar를 넣어도 canonical entry stream보다 권한을 넓힐 수 없고, source oracle은 제품
      execute callsite가 이 필드를 `self.bound_stream_id`에서만 채우는지 고정한다.
      현재 public `GenerationTransport.executePreparedRequest(receipt,*ExecutedResponse)`와 `client_slot.executeGenerationRequest` signature는
      그대로 두고 public wrapper는 pointer/owner preflight 뒤 내부 `.attach`만 선택한다. `.rpc`는 B3-2 focused test-private caller만
      사용하며 제품 constructor/callsite는 0이다. `attach_only`는 attach destination, 세 bound family는 rpc destination에서만
      허용하고 destination mismatch를 role/phase/stream authorization보다 먼저 판정한다.
      반환은 `Error!Decision`으로 분리한다. `Decision`은 저장·재생 가능한 permit이 아닌 즉시 read-only
      `allowed|unauthorized|busy`, `Error`는 `InvalidOwner|InvalidReceipt|InvalidResponseDestination`의 닫힌 집합이다. public wrapper의
      zero/overflow/response-owner containment 같은 비역참조 structural preflight가 먼저이고, 그 뒤 classifier exact precedence는
      outer operation conflict `Busy` → raw context `InvalidResponseDestination` → registry/reservation/binding 및 raw
      entry/controller/role drift `InvalidOwner` → canonical transcript 부재·transport/receipt 또는 raw tag/family 불일치
      `InvalidReceipt` → structurally denied `spawn_full`의 `Unauthorized` → family/context mismatch `InvalidResponseDestination` →
      semantic `busy|unauthorized|allowed`다. 따라서 structural preflight가 통과했다는 전제에서 invalid context+receipt mismatch는 destination error, invalid tag/family+outer
      conflict는 Busy, spawn_full+wrong execute context는 Unauthorized, revoke-pending detach+wrong execute context는 destination error가 이긴다.
      controller `detach`는 `live|revoked`에서 허용하고 `revoke_pending`은 `beginBoundDrop`과 동시에 진행할 수 없으므로
      `Busy`; observer는 canonical `unavailable`에서 허용한다. `spawn_full`은 모든 stage/destination에서 거부한다.
      invalid raw context/entry/controller/role/tag/family, 14 tag×5 family×3 context×phase `empty|reserved|bound|drop_active`×role×
      controller-state×`entry_stream {0,A,B}`×`current_stream {0,A,B}`, `find(scroll=false|true)`, 모든 identity/receipt/transport/
      context splice와 same-address registry ABA를
      production registry type으로 전수한다. 각 verdict 전후 registry entry, prepared/RPC authority lifecycle·epoch, response owner,
      stream/controller state는 byte-identical이어야 한다. storage는 classifier 입력이 아니므로 접근/callsite 0을 source oracle로
      고정한다. Client·socket·pending flush·wire·allocator·payload·response
      publication과 `RpcResponseAuthority.reserveExecuting` call은 0이며 public facade/signature delta 0 source oracle, Debug·ReleaseFast
      exact-count focused gate와 boundary gate를 통과한다. pure table은 `spawn_full`과 invalid tag-family를 structurally deny하지만 실제
      product prepare는 canonical publication 전에 spawn을 `Unauthorized`로 끝내고, execute fixture에는 그런 canonical receipt가 없어
      `InvalidReceipt|InvalidOwner`에서 닫힘을 별도로 검증한다. B3-2 verdict를 cache/permit화하지 않는다. B3-3은 flush 전
      expected lifecycle `.prepared`, `beginPreparedRequestExecute` 뒤 flush 후 `.executing`으로 같은 receipt의 canonical transcript와
      current entry를 각각 새로 resolve해 동일 classifier를 다시 호출하며 post-flush 결과만 first-byte 권위로 쓴다. Debug·ReleaseFast
      registry 3개와 product 2개, boundary 1개를 합친 exact 11-test focused gate와 전체 session-host 회귀가 완료 증거다.
   5. **B3-3 progress/execute integration (완료):** caller-final storage에 Client가 in-place 초기화·seal하는
      `PreparedRequestExecutionLease`와 closed
      `PreparedRequestWireProgress{request_zero_clean,prior_pending_ambiguous,request_maybe_written}`의 유일한 생산자가
      된다. error/lifecycle에서 progress를 추론하거나 byte count·bool을 caller가 permit처럼 재주입하지 않는다. exact 순서는
      registry `preparedRpcAdmission(.prepared)` → `initPreparedRpcExecutionTxn`+defer 설치 → registry-owned `reserveRpcResponseExecution` →
      `beginPreparedRequestExecute` → Client `beginPreparedRequestExecution`의 pending flush+lease → registry
      `executingRpcAdmission(.executing)` → callback/allocation 없는 lease consume+첫 request write다. post-flush verdict는 저장하지 않고
      first-byte 직전에 같은 classifier로 canonical transcript를 새로 resolve한다. reusable rollback은 오직
      `request_zero_clean && Client usable`에서 request backing abort와 RPC authority `executing→idle`을
      함께 끝낼 때 허용한다. prior pending partial/ambiguous, 첫 request positive write, closed/poisoned Client, epoch 소진은
      RPC authority terminal+connection fail-close로 닫는다. B3-3에서는 correlated response publication을 열지 않고 Darwin
      socketpair peer가 exact request를 관측한 뒤 EOF를 내는 terminal sink로 first-byte/complete-write 경계만 증명한다.
      private pristine `RpcExecutedResponse` destination을 txn이 봉인하되 payload/publication API는 0으로 유지한다. B3-4/5 correction은
      이 fixture-owned destination을 canonical `GenerationTransport` inline slot exact address 하나로 수렴시킨다.
      focused Debug·ReleaseFast gate는 progress raw/monotonic 전수, pre/post classifier와 authority reserve/rollback/terminal,
      pending cleanup callback 재진입을 고정한다. macOS socketpair gate는 pending 0/partial/full, request 0/1/len-1/full,
      actual kernel의 zero/positive-partial/full과 EOF/EPIPE를 관측한다. exact 1/len-1·EINTR/EAGAIN/zero/hard error는 injected write ops가
      결정적으로 전수한다. boundary는 pre/post classifier exact 1회, first-write adjacency,
      legacy writeAll·public RPC destination·response publish/borrow 0을 강제한다. private final-address
      `PreparedRpcExecutionTxn` 하나가 기존 `PreparedExecutionTxn`과 RPC canonical을 합성해
      `pristine→response_reserved→settled`의 닫힌 phase와 request-cleanup 선행 뒤 response rollback/terminal 순서만 소유한다. request
      phase는 내장 txn, wire phase는 lease progress만 조회하며 중복 저장하지 않는다. 합성 txn은 response reserve 전에 mutation 0으로
      초기화되고 즉시 defer 보호를 얻는다. request backing 정리 구현을 복제하지 않는다. B3-3 내부 production 타입/함수는 test
      fixture 3개가 exact private wrapper를 8회 호출해 reserve 뒤 rollback, lease 뒤 rollback, response epoch 소진의 wire 0·fail-close,
      pending ambiguity, request hard failure, frame alias, full-write+EOF, pending-free callback destination 점유를 검증한다. execution
      lease를 얻은 뒤에는 request backing과 두 authority를 모두 정산한 다음 fence를 마지막에 해제한다. 테스트 밖 제품 caller는
      B3-6 전까지 0이다. execution fence는 주소·generation 외 process-local checked-monotonic incarnation을 lease와 Client latch에
      함께 봉인하며 same-address reincarnation은 새 fence를 release하지 않고 fail-closed한다.
   6. **B3-4/5 원자적 publication+borrow/finish (single-slot correction 완료):** published payload 생성·정리 primitive와
      canonical `GenerationTransport` inline single slot correction을 구현·검증했다. actual transport slot의 2회·64회 재사용,
      exact safe-free/ambiguous no-free,
      `published→borrowed→releasing` exact-once lexical borrow와 owner finish, 2회·64회 순차 RPC를 구현한다. `client.zig`는 기존 response
      loop를 request 재전송·request-id 증가 없는 `readPreparedResponseUnderExecutionLease`로 추출하고, 새
      `rpc_executed_response.zig`가 반복 RPC byte owner/borrow receipt를 소유한다. 기존 attach `executed_response.zig`와 owner seal은
      변경하지 않는다. response primitive는 B3-3과 동일한 `.blocking` only이고 새 deadline/clock SSOT는 0이다. socketpair fixture는
      bounded peer response/EOF로 종료하며 deadline mode는 2c3e가 결정한다. authority protocol lifecycle과 byte owner lifecycle은 분리된
      SSOT이며 registry raw authority pointer escape는 0,
      `client_slot.zig`만 product orchestration을 소유하되 `PreparedRpcExecutionTxn`은 publication/정산까지만 소유한다. borrow begin은
      fresh-operation preflight/permit 뒤 종료되고 lifetime은 `RpcResponseBorrow` receipt만 소유하며, final-address
      `RpcResponseFinishTxn`은 finish만 소유한다. 기존 payload ledger의 새
      `transferPromotedRpcResponse`가 publication preflight 뒤 owner를
      in-place seal하면서 promoted entry를 atomically `transferred_response`로 소비하고, 그 다음 authority의 final-address
      `PreparedRpcTransitionPermit`을 `commitPublishedNoFail`로 exact once 소비한다. authority는 named prepare/no-fail consume 쌍만
      module-public으로 열고 registry 외 callsite와 raw pointer escape는 0이다.
      import는 `response_payload_allocation -> rpc_executed_response` 단방향이고 owner는 ledger type 대신 owner-local neutral
      `AllocationProvenance` scalar만 받는다.
      attach `transferPromotedResponse` 의미 변화 0을 differential gate로 고정한다. publish 후 request/backing 정산, ledger operation end,
      마지막 lease release를 고정하고 borrow/finish는 fresh registered operation pin을 callback suffix까지 유지한다. raw bytes는 owner 파일
      내부 `builtin.is_test` lexical helper 1곳에만 노출하고 production raw-byte bridge와 family decoder callsite는 0이다. 실제 cross-module
      decoder API와 default protocol-failure cleanup guard/error·early-return integrated finish는 2c3e doc-first가 소유한다. B3-4/5
      product-shaped test는 begin-borrow/finish를 fresh operation 아래 명시적으로 호출한다. 기존 payload ledger를 재사용하며 1..control cap,
      empty/cap+1/OOM/truncation, 전체 owner-range alias, pre-free terminal-no-free와 `free_committed→terminal_clean|node/txn
      terminal_freed_once` callback drift를 전수한다. begin-borrow는 현재 operation/borrow permit/output receipt, finish는 현재 borrow receipt와
      fresh finish txn/operation/releasing·finish permit 각각에 대해 payload disjoint를 검사하며 종료된 begin stack 주소는 저장·재검사하지
      않는다. finish는 `prepareReleasing→owner free_committed→commitReleasingNoFail` 순서를 지킨다. node-local
      `RpcFreeEvidenceRecord{empty|free_call_committed|terminal_freed_once,response_epoch,digest}`는 정상 callback/authority commit 뒤 operation
      release 전에 exact epoch로 empty retire하고 fail-stop evidence는 재사용하지 않는다. private strict
      wrapper는 byte-owner tombstone/free를 먼저 끝내고 authority terminal을 게시한 뒤 fail-stop outcome을 즉시 소비한다. 원 B3-4/5
      slice는 terminal-before-return source oracle과 private noreturn sink까지만 소유한다. single-slot correction이 internal normal strict
      callsite와 module-public entry의 immediate consumption을 소유하고, B3-6은 dedicated isolated subprocess/source 증거만 소유한다.
      correction boundary는 `fail_stop_required` return/store 0과 private noreturn sink adjacency를 고정한다. Debug·ReleaseFast exact-count leaf/registry/product/
      boundary, actual socketpair fragmented response·OOB-before-response·wrong kind/id·EOF, allocation fail-index, publish/transition permit
      preflight mutation 0·copy/move/replay 거부,
      correction의 정상 suffix는 fresh finish registered operation에서 callback 복귀 뒤 owner/finish/evidence를 재검증하고
      reusable-authority, evidence-retire, owner-rearm permit을 모두 fallible prepare한 다음
      `finishCleanNoFail→commitReusableNoFail→commitEvidenceRetireNoFail→commitReusableRearmNoFail→operation release` 순서다.
      evidence-retire는 `client_slot.zig` 소유 final-address `PreparedRpcFreeEvidenceRetirePermit`이며 record address, epoch/digest,
      `free_call_committed` seal, consumed bit를 봉인하고 authority idle commit 직후 callback/lookup 없이 exact record를 empty로 소비한다.
      owner-rearm은 `rpc_executed_response.zig` 소유 final-address `PreparedReusableRearmPermit`이며 response/self address, old identity/epoch,
      current `free_committed` owner+freed-once finish transcript에서 계산한 expected `terminal_clean` owner seal, expected consumed finish digest,
      consumed bit만 봉인한다. owner leaf는 registry/authority/evidence를 import하거나 caller bool을 받지 않는다. held operation/current binding과
      세 permit의 exact lineage를 `client_slot.zig` private reusable-finish suffix 진입 전에 한 번에 검증하고 이후 commit 사이
      registry lookup/fallible validation 0으로 인접 소비한다. copy/move/replay/wrong-order/drift는
      reset 0 isolated fail-stop이다. prepare/commit rearm leaf의 production direct caller는 그 suffix에서 각각 exact 1이고,
      다른 module과 `generation_transport.zig`의 direct caller, public reset/rearm 노출은 0이다. owner-file test caller는 별도 allowlist다.
      rearm 뒤 recoverable error·callback·allocation·lookup·추가 semantic mutation은 0이고 canonical operation release만 허용한다.
      protocol failure·terminal-no-free·terminal-freed-once·authority terminal은 영구 tombstone이며 rearm 0이다. prepare/abort/pre-wire reject는
      slot bytes·epoch·rearm mutation 0이다. 동일 inline slot exact address의 reusable 2/64회와 매회 fresh epoch·payload free exact 1·finish 반환
      `pristine+authority idle+evidence empty`, stale owner/borrow/finish/permit replay의 read/free/mutation 0, callback reentry Busy와 두 선형화
      순서 source oracle이 correction merge gate다. 이 correction은 import cycle 없이 actual transport slot 2/64회를 증명하도록
      `GenerationTransport.rpc_response` inline field와 generation-transport-file-private `executePreparedRpcSubstrate(receipt)`의
      ownership-only private settlement `.rpc` path exact-one callsite까지 함께 소유한다. payload semantic read와 normal `RemoteRuntime`
      product caller는 0이고 2c3e가 typed decoder path로 교체한다. finish function entry에는 releasing authority, finish reusable|terminal
      authority, evidence-retire, rearm의 네 permit storage를 client-slot-private `FinishPermitRawStorage` 하나가 aligned `undefined` raw
      storage로 먼저 예약한다. sealed response identity와 stored addr/len/digest scalar의 checked-add만으로 typed/payload read·hash·allocator
      access 0 상태에서 allocator capability capture 전에
      payload/finish/borrow/response/operation/node/outer-owner 및 서로 간 exact/partial/overflow alias closed set을 통과한다. alias면
      capability copy·free·permit init/prepare/commit·owner/authority/connection mutation 0이다. 새 recovery facade 없이 parent-minted
      `permit-alias-preflight-rejected` sentinel 뒤 즉시 strict fail-stop하며, disjoint branch만 bytewise pristine init→permit prepare를 진행한다. process가
      종료되는 이 exact local-invariant branch는 terminal-before-panic graph 게시 요구의 명시적 예외다. caller/GUI만 종료하고 daemon/PTY
      direct terminate/kill/control frame은 0이다. fd close에 따른 EOF-driven client detach/revoke는 exact once이며 daemon PID/runtime/PTY
      child는 생존해 fresh reattach와 output 연속성을 유지한다. disjoint 뒤에만 full payload live/digest 검증을 허용하며 이후 generic terminal-no-free
      alias 문구는 raw permit-reservation alias를 제외한다.
      attachment drop은 prepared request와 RPC response readiness를 같은 canonical registry entry에서 확인해 published·borrowed·releasing 동안
      mutation 0의 `AdminBusy`로 닫고, reusable finish의 `authority idle+evidence empty+slot pristine` 뒤에만 다시 허용한다.
      `GenerationTransport` 크기는 Debug·ReleaseFast에서 2048 bytes 이하로 고정한다.
   7. **B3-6 internal aggregate strict completion:** 기존 public attach facade
      `executePreparedRequest(receipt,*ExecutedResponse)`의 signature/behavior를 유지한다. correction에서 연 private
      `executePreparedRpcSubstrate(receipt)` ownership-only private settlement path는 correction부터 client-slot module-public entry에서 `fail_stop_required`를 반환형에
      노출하거나 저장하지 않고 기존 private noreturn sink로 즉시 소비한다. B3-6은 public facade와 semantic decode를 바꾸지 않되,
      peer/resource read 실패를 local invariant fail-stop으로 오분류하던 내부 settlement를 process-alive terminal로 교정하고 나머지 strict behavior를
      dedicated subprocess/source oracle로 증명한 뒤에만 `2c3b-3 완료`로 승격한다. public RPC execute·`*RpcExecutedResponse`·borrow·finish·reset,
      normal `RemoteRuntime` family callsite와 사용자 가시 동작은 0이다. decoder 제품
      전환은 계속 2c3e 소유다.
      기존 B3-0a response-alias count 4 artifact를 이 완료 증거로 재사용하지 않는다. correction은 별도
      `CR3a-2c3b reusable response correction` count 5 artifact로 same-slot 2/64, evidence-retire, rearm permit drift/replay,
      post-rearm 금지 동작을 고정한다. B3-6은 별도 `CR3a-2c3b internal rpc substrate` focused gate의 runtime 2+boundary 1,
      total count 3으로 private wrapper의
      peer-error non-crash actual-socket matrix, local invariant isolated fail-stop matrix, public/private boundary+exact-one callsite를
      고정한다. peer wire frame/header/envelope malformed·wrong-id·truncated·empty·cap+1·OOM은 process alive+connection terminal+
      registry response authority permanent tombstone+payload owner pristine+rearm 0+
      second free 0이고 local seal/allocator/authority/rearm drift만 abnormal exit다. parent-minted stage sentinel은 free exact once,
      authority idle, evidence retire, rearm precondition을 구분하며 reset 전 fail-stop과 rearm 뒤 operation release 외 동작 0을 증명한다.
      bounded nonempty correct-id payload의 JSON/application semantic 오류는 2c3e decoder가 소유한다.

      여기서 `empty`는 response header를 한 byte도 받기 전의 zero-byte EOF다. correct-id response의 payload 길이 0도 canonical
      accepted owner가 아니므로 process-alive protocol terminal로 정산하며 permanent tombstone, semantic read 0, rearm 0이다. peer 행렬은 bad magic, wrong major, invalid kind, wrong request id,
      header cap+1, header truncation, payload truncation, zero-byte EOF, allocation fail-index와 correct-id empty payload를 exact case로
      갖는다. correct response 뒤 같은 write에 붙은 duplicate old-id response는 첫 cycle을 정상 정산한 뒤 다음 cycle에서 correlation
      loss로 terminal된다. 이때 두 번째 RPC-slot publication/owner-free/rearm은 0이고 parser discard payload free는 정확히 1회다.
      host가 미래 request id와 올바른 response frame을 미리 위조하는 경우는 wire만으로 정상 future response와 구분할 수 없는
      compromised-peer 범위이며 이 gate의 local memory-safety 증거가 아니다.
      OOM은 parser frame backing과 payload allocation/promotion까지 observer가 실제로 도달한 모든 ordinal을 최초 성공까지 전수하고,
      publication 이후에는 recoverable allocation 지점을 새로 만들지 않는다.
      isolated child 증거는 단순 panic 문자열을 성공으로 세지 않는다. parent가 별도 capability/stage pipe로 민트한
      `{version,case_id,nonce,stage}` 11-byte record(`nonce` little-endian)의 case별 exact prefix와 final sentinel, 예상 abnormal termination을 함께 검증한다.
      response seal/allocator drift는 `free_once` 뒤, authority drift는 permit 준비 뒤, rearm drift는
      `authority_idle -> evidence_retired -> rearm_precondition` 뒤에만 주입한다. exec 126/127, capability/nonce mismatch, generic panic, stage
      누락·중복·역전은 실패다. parent는 stderr와 stage pipe를 child 종료 전 nonblocking으로 함께 drain하고 capture cap 뒤에도 EOF까지
      discard-drain하며 truncation은 실패 처리한다. absolute timeout은 kill 뒤 waitpid exact once로 닫는다.
   8. **2c3c control facade (C1·C2·C3 완료):** C1은 별도 raw-discriminator-safe `RuntimeControl` DTO와 exact
      `ValidatedRuntimeControl=scroll_to_bottom|core_command`를 두고 `sendControl|sendControlNonBlocking` substrate를
      `ClientSlot` canonical operation 아래 추가한다. unsupported capability는
      `ControlError.Unsupported`, nonblocking `false`는 backpressure만 뜻하며 raw method/JSON/stream ID escape는 0이다. C2는 기존
      `PendingControl.barrier` queue의 generation nonblocking scroll/core 호출을 facade로 전환하고, C3는 blocking flush를 전환한다.
      C2의 encode OOM은 typed queue dequeue와 새 control owner/wire를 0으로 유지하되 prior pending progress만 허용하고 duplicate 없이
      재시도한다. C3 queue flush는 response 없는 stream frame만 써서
      `RuntimeRequest.core_command`로 fallback하지 않는다. outer scroll은 dedicated scroll capability/frame, nested
      `core_command(.scroll_to_bottom)`은 core capability/frame을 유지하며 unsupported wire-kind fallback은 `RemoteRuntime`만 결정한다.
      C3 encode OOM은 prior pending progress만 허용하고 새 control wire 0·queue retain·재시도 duplicate 0을 고정한다.
      facade `Unsupported`는 generation adapter 한 곳에서 consumed no-op으로 normalize해 기존 사용자 가시 동작을 보존하고,
      backpressure만 queue를 유지한다. public raw DTO는 zero-init outer tag+module-private shared `RawCoreCommand` representation을 쓰며
      decode가 검증한 active member만 semantic authority로 삼는다.
      C1은 `test-session-host-2c3c-c1`의 Debug·ReleaseFast runtime 7+boundary 1 exact-count로 구현·검증 완료했다.
      C2는 `RuntimeAttachment`의 generation arm에만 nonblocking control adapter를 두고 `PendingControl`을
      `RuntimeControl`로 투영한다. 이 한 경계가 `Unsupported`만 consumed no-op으로 접고, `false`와
      `ResourceExhausted|Busy`는 queue retain, 나머지 오류는 기존 `ClientError` 의미로 전파한다. legacy arm과 queue/barrier 저장 구조는
      변경하지 않는다.
      C2의 Debug·ReleaseFast gate는 runtime 5+C1 runtime 7+boundary 1의 exact inventory로 모든 15개 command projection,
      canonical frame allocation OOM 뒤 retain·무독성·exact-once retry, zero/partial/full pending progress, peer close의 hard-error retain,
      1/64/65 queue와 allocation fail-close, unsupported wire 0, coalescing과 `input prefix -> control -> input suffix` 순서를 검증한다.
      C3는 같은 closed projection을 재사용해 `flushQueuedInputBlocking`의 generation arm만
      `GenerationAttachment.sendControl`로 전환한다. 성공과 `Unsupported` no-op만 dequeue하고,
      `ResourceExhausted`는 `OutOfMemory`, `Busy`는 `AdminBusy`, authority/protocol/close 오류는 기존 `ClientError` 의미로 전파해
      queue를 유지한다. encode OOM 전 기존 pending frame offset 진전은 허용하지만 새 control wire와 duplicate는 0이며,
      legacy blocking direct Client 두 호출과 recovery resync baseline은 변경하지 않는다.
      일반 RPC는 retained queue를 추월하지 않는다. `terminateBestEffort`만 blocking flush OOM에서 runtime 파괴가 queue를 대체하는
      명시적 예외로 retained mutation을 폐기한 뒤 terminate를 시도한다. `detachBestEffort`는 flush 오류에서 detach RPC 0을 유지하고,
      `ConnectionClosed` 외의 OOM/Busy/authority/protocol 오류는 connection fail-close→host EOF lease 회수로 수렴한다.
      queue·registry authority는 새로 만들지 않고 legacy arm과 recovery-owned resync는 유지한다. 각 slice는 Debug·ReleaseFast focused
      test와 boundary oracle을 통과한다. C3 RemoteRuntime 5+slice-exclusive Client write 1은 blocking drain 단일-owner 재진입 방지, 새 scroll/core frame의
      injected zero/1/len-1/full·EINTR 분류, ambiguous partial fail-close, generation teardown actual RPC를 고정하고 generation scroll/core
      direct Client callsite 0과 recovery resync baseline 1을 유지한다. event는 2c3d,
      response-bearing RPC decoder와 실제 socket parity는 2c3e, `RemoteRuntime.client` 필드 제거는 2c4가 소유한다.
   9. **2c3d one-shot event facade (doc-first):** generation event는 raw `BufferedEvent` 값 반환 대신 caller-final-address
      `EventOwner`의 event-incarnation별 one-shot lifecycle을 사용한다. inline storage는 정상 release 뒤 pristine으로 재사용하고,
      ClientNode binding-registry entry의 checked-monotonic `event_generation`이 canonical SSOT이고 `GenerationAttachment` mirror는
      검증된 projection이므로 owner+attachment bytes의 same-address ABA도 막는다. 짧은 `.event`
      take/release stream-operation permit과 그 사이의 기존 `ConnectionLease` 기반 node/slot cleanup pin을 분리해 revoked-event의
      `fenceRevoke`는 허용한다. attachment teardown은 별도 inline lifecycle/generation mirror로 live owner를 `Busy` 처리한다.
      `takeEvent(out)` 결과는 `idle|ended_pending|taken`, 공통 오류는 `Busy|InvalidOwner|Corrupt|Terminal`이며 무할당이다.
      GUI ingress는 accepted/unknown 모두의 header·verdict·payload·canonical Client allocator identity를 seal한다.
      `releaseEvent(owner)`는 connection poison 뒤에도 canonical cleanup을 허용하고 exact-once free하며 callback 뒤 no-fail suffix로
      permit/reservation/pin/owner를 소비한다. unsafe provenance는 ordinary 후보 검증 뒤 take 때 미리 예약하고 trusted cleanup mirror를
      owner bytes와 독립 봉인한 `max_gui_attachments=4,096`, retained byte 1 GiB bounded no-free quarantine으로 transfer한다.
      별도 issuer 없이 `{node incarnation,event generation,owner address}`를 reservation identity로 쓰며 정상 release는 slot을 empty로
      재사용한다. ended 판정은 예약보다 먼저다.
      generation pump는 purge-first이고 ordinary take도 ended를 반환하지 않는다. C1 admission/allocator seal·node-canonical reusable owner/generation·ordinary take는 구현됐고,
      C2 release/pin/quarantine/callback closure는 public `releaseEvent` exact 1개, std/scalar-only 4,096-slot·1 GiB
      dedicated quarantine leaf, mutex 전 PID/owner-thread gate, binding registry의 one-shot recovery permit과 cleanup-only canonical
      pin projection이 함께 있어야 하는 damaged-lease recovery, callback 전 전수 검증·모든 mutex 해제와 logical registered-node
      operation pin 유지, stack final-address completion receipt에 의한 callback 뒤 lookup 없는 binding settlement와 pin-last no-fail
      suffix를 한 vertical slice로 닫는다. `client_slot`만 transaction을 조정하고 raw Client는
      canonical resource handoff를 알며, owner-local lifecycle은 기존 import 방향대로 `generation_event_contract`가 소유하고
      `GenerationTransport.releaseEvent`가 scalar prepare→owner tombstone→resource commit→owner finalize를 조정한다. C2는
      production-type facade exact 14이고 제품 event callsite는 0이다.
      C3는 세 PR-size gate로 나누며 각 gate가 Debug·ReleaseFast focused sentinel과 boundary를 가진다.
      **C3-1**은 `GenerationAttachment` 안의 exact 512-byte `EventOwner`, 권위 없는
      `event_generation_mirror:u64` projection(0=idle/settled, nonzero=검증된 live generation), attachment-only
      `takeEvent/viewEvent/releaseEvent` wrapper와 teardown `Busy -> explicit release -> success`만 소유한다. canonical
      generation과 cleanup readiness의 SSOT는 계속 ClientNode binding registry이고 mirror는 free/drop/release 권위가 아니다.
      transport가 canonical take 결과에서 generation을 함께 투영한 뒤에만 mirror를 게시하며 public owner bytes나 payload를
      재해석하지 않는다. clean release는 mirror를 0으로 만들고, `Busy|InvalidOwner`는 owner/mirror를 보존하며, corrupt
      release는 C2 trusted no-free handoff와 poison을 끝낸 뒤 owner terminal·mirror 0을 게시하고 `Corrupt`를 반환한다.
      explicit release는 mirror를 cleanup 권위로 쓰지 않으므로 mirror drift가 있어도 C2 canonical cleanup 결과를 우선한다.
      clean/`Corrupt` settlement만 mirror를 0으로 동기화한다. stream-operation identity 소진은 live event를 재시도 불가능한
      `Terminal`로 고립시키지 않고 registered-node operation 아래 C2 trusted no-free handoff로 수렴해 `Corrupt`를 반환한다.
      `Terminal`은 callback 중 live/releasing뿐 아니라 canonical already-settled/terminal을 포함하므로 이 결과만으로 settlement를
      추론하지 않고 mirror를 보존한다. mirror 단독 terminal/idle 값은 teardown 권위가 아니며 release 밖의 registry 불일치는 mutation 0
      `Corrupt`다. `tryDeinit`은 allocator callback이나 release를
      내부 실행하지 않고 canonical owner가 live/releasing이면 `Busy`; explicit `releaseEvent` 뒤 재호출만 기존 drop을 시작한다.
      construction은 binding reserve → transport mint → inline owner exact-address reserve → request prepare 순서이고, 실패는
      transport terminalize → binding abort의 기존 역순 rollback으로 request/pin/queue/quarantine leak 0을 보장한다.
      **C3-2**는 이 wrapper를 소비하는 purge-first 제품 drain과 ended priority를 소유한다. focused gate는
      `test-session-host-2c3d-c3-2`이며 C3-1 전체와 Debug·ReleaseFast attachment runtime sentinel 8+
      actual generation `RemoteRuntime` product drain 1+boundary 1을
      exact-count로 실행한다. C3-3까지의 generation drain은
      `pending settlement -> purge -> take -> immutable snapshot -> classify/prepare -> effect+release settlement -> semantic commit`이며,
      settlement `Busy` 뒤에는 같은 canonical owner와 sealed `PendingEventOwner`를 다음 tick의 purge보다 먼저 재시도한다.
      `event_pending`은 제품 error/ended가 아니라 process-state live인 progress이고, pending 동안 해당 Runtime semantic mutation과
      connection TX/RPC flush를 멈추되 shared RX/demux tail append는 허용한다.
      `.ended_pending`은 `protocol.max_client_pending_events`에서 파생한 유계 budget 안에서 purge로 되돌아간다.
      budget 소진은 입력·출력·화면 진전 0의 `Busy`로 다음 tick에 넘긴다. legacy raw acquisition과 공통 semantic
      classify/apply SSOT는 분리하며 generation 실패의 legacy fallback은 0이다. **C3-3**은 actual socket의
      revoked→borrow/classify→fence→release와 generation raw Client event source-zero를 소유한다. C3-1에는 제품 pump/socket
      consumer가 0이고, C3-3 전에는 2c3d 완료나 generation event source-zero를 주장하지 않는다.
      C3-3은 `applyObservationEvent` generation arm의 raw `self.client.wire_major`, `metadata_support`, `poison`과 raw Client
      revoke-fence 인자, `settlePendingGenerationEvent`의 raw `self.client.poison`을 제거한다. registry/ClientSlot identity와
      `expected_major|metadata_support`만 opaque `EventCorrelation`에 묶고 mutable role/controller generation/tracking은
      `RuntimeSemanticSnapshot`과 final-address pending owner가 소유한다. classify/materialize는 live Runtime mutation 0의 owned
      `PreparedEvent`를 만들고, package-private settlement가 poison/fence/terminal cleanup과 exact release를 한 preflight+no-fail
      transaction으로 닫은 뒤에만 semantic state를 no-fail commit한다. 같은 Client는 수명 전체에서 legacy 또는 generation attachment만 소유하고 mixed-mode mint/adopt는
      ClientSlot/node membership을 canonical proof로 source/product oracle에서 거부한다. generation external mode는 stable Busy가
      아니라 typed invalid-owner다. `busy`는 durable effect mutation 0이고 canonical 검증 shared receipt는 exact begin/end로 정산되며,
      admitted settlement는 guarded cleanup callback을 허용하되 effect 성공 뒤 release Busy가 없는 no-fail suffix로 수렴한다. sealed queue
      latch는 take commit에서 event generation과 connection ordering blocker를 발급하며 exact-receipt in-flight `live` row로 원자 이전되고
      settlement commit에서 consumed된다. 모든 taken event가 settlement까지 blocker를 유지하며 기존 EventAuthority lifecycle과 cleanup
      pin 외 별도 cleanup charge는 만들지 않는다. C3-3은 공통 Client ingress cadence를
      바꾸지 않는 열린-peer actual socket roundtrip까지만 소유한다. 이미 admitted unknown/semantic violation의 typed effect/release는
      C3-3, immediate EOF, admission 뒤 yield 집합, unread RX-first, socket ingress malformed/unknown cadence와 legacy/generation observable
      parity는 2c3e doc-first blocking gate로 남긴다.
      C3-3 첫 runtime slice는 등록된 ClientSlot/node owner-thread admission을 통해 exact-15 poison을 confirmed effect에
      연결한다. blocking deferred fd-open은 외부 owner가 없을 때 같은 effect에서 take/close해 영구 Busy 없이 수렴하고,
      external typed invalid/exclusive Busy는 reason/fd/pending durable mutation 0이다. guarded pending free callback의 poison/input/control과
      foreign teardown 재진입 Busy, effect 뒤 fence 재사용, exact free 1, peer EOF, first-reason/idempotency를
      `test-session-host-2c3d-c3-3` Debug·ReleaseFast에서 고정한다.
      이 slice만으로 기존 `EventAuthority` revoke class/derived cache, 제품 settlement/source-zero, revoked actual-socket roundtrip
      완료를 주장하지 않는다.
      다음 활성화는 **C3-3a revoke ordering gate**이며 세 reviewable gate로 닫는다. **C3-3a1 dormant authority substrate**는 새
      row·generation·RemoteRuntime 단계 복제를 만들지 않고 canonical `AttachmentCleanupRegistry.Entry.event_authority`에 closed
      `none|controller_revoke` class와 node-local checked derived cache를 추가한다. per-entry class/lifecycle가 SSOT이고 cache는
      `reserved|live|releasing` revoke 수의 O(1) projection일 뿐이다. production은 affected row의 exact lifecycle/receipt와 checked
      counter bound/transition만 O(1)으로 검증한다. Debug·ReleaseFast test-only invariant oracle만 bounded full scan으로 cache 일치를 확인한다.
      trusted class 인자는 기존 ClientSlot take가 canonical payload를 재검증해 얻은 preflight 결과에서만 만든다. aggregate query는
      payload를 다시 파싱하지 않는다. 성공한 revoke reserve가 `0 -> 1`, pre-reserve 실패는 `0 -> 0`, reserve 뒤 abort는
      `0 -> 1 -> 0`이다. live publication과 releasing 시작은 delta 0이다. 정상 release는 allocator callback/quarantine settlement 뒤
      `finishEventReleaseNoFail`에서 감소하고, live `StreamOperationPermit`이 그 뒤 permit consume까지 mutation을 계속 막는다. corrupt는
      terminalize 때 감소하지 않고 recovery permit 최종 consume 뒤 감소한다. teardown은 live/releasing owner를 정산하지 않고 explicit
      release까지 `Busy`다. stale/copy/ABA/double consume과 unauthorized underflow는 delta 0으로 fail-stop하며 production은 invalid raw
      lifecycle/receipt나 counter bound 위반을 fail-closed한다. 임의 row/cache bit drift의 전수 복구·탐지는 주장하지 않는다. a1은 product take/release caller exact 0인 dormant component로 구현됐고
      `test-session-host-2c3d-c3-3a1`의 Debug·ReleaseFast registry runtime 7+boundary 1을 통과한다. copied registry, same-address
      generation ABA, typed stale/double settlement까지 a1이 소유하고 no-fail continuation/recovery replay와 unauthorized underflow의
      격리 subprocess는 실제 활성화와 함께 a3가 소유한다. 따라서 이 시점의 제품 동작은 C3-3과 동일하며 revoke ordering 활성화는 주장하지 않는다.
      **C3-3a2 dormant final-admission substrate(구현 완료)**는 `client_slot.zig`의 기존 `RegisteredNodeOperation`/`ClientOperationFence` 아래 사용할
      단일 internal transaction/core predicate를 만들되 product caller를 exact 0으로 유지한다. 새 mutex·fence·aggregate generation은
      만들지 않는다. owner query에서 operation을 여는 wrapper와 이미 operation을 보유한 control/test-harness 경로용 wrapper는
      ownership만 다르고 predicate는 하나다. 후자는 registered operation을 중첩하지 않는다. attach prepared product caller는 a2에서
      0이고 future typed execute가 같은 wrapper를 재사용한다. transaction은 single shared pin을 기존 Client operation execution lease로
      upgrade하고, held-path는 public Client API의 shared pin을 다시 중첩하지 않는 internal leaf를 사용한다. lease는 final 검사부터
      allocation·queue offset·syscall commit까지 유지한다. 정산 순서는 held leaf 완료 또는 blocked 판정 -> single shared로 downgrade ->
      transaction lifecycle consume -> registered operation의 마지막 shared pin release다. canonical owner는 lease-held 상태에서
      lifecycle/receipt 검증과 no-fail settlement plan을 끝낸다. pre-acquire invalid/copy/stale/already-consumed replay와 foreign
      settlement는 canonical lease·transaction·pin mutation 0으로 typed reject하고 canonical active owner만 위 순서를 수행한다.
      active self/ownership/content drift는 raw `u8` tag 선검증, registry-bound ownership mode와 scalar seal로 fail-stop한다.
      held-operation wrapper는 operation exact extent를 pointer로 직접 선검증하고 caller의 추가 control/prepared authority는 최대 4개
      protected range로 받아 output alias·overflow·cap 초과를 pre-acquire 거부한다. transaction은
      `error{InvalidOwner, Busy}!Decision`을 반환하고 `Decision`만 `blocked|admitted`다. invalid/copy/stale/replay는 `InvalidOwner`,
      operation/lease contention은 `Busy`를 재사용한다. a2는 injected closed decision으로 transaction을 검증한다.
      a1 query는 declaration exact 1·production caller exact 0, a2 transaction도 declaration exact 1·production caller exact 0을
      유지하며 실제 queued+a1 query 연결은 a3가 모든 family와 동시에 소유한다.
      현재 존재하는 blocking/nonblocking input, generation control, pending output, 모든 raw `callOrdered` RPC와 두 resync 경로의
      error/progress·owner-retention 표를 Debug·ReleaseFast transaction runtime 7+current-family regression 5+boundary 1로 고정한다. attach prepared request/execute는 기존
      owner/fence 회귀만 상속하며 일반 runtime typed execute가 아니다. `callOrdered`는 read-only처럼 보이는 method도 pending mutation을
      flush할 수 있으므로 현행 queued-revoke 정책처럼 전부 막고, method별 세분화는 2c3e가 소유한다. raw identity/role/corruption,
      capability `Unsupported`, revoke 결과 순서로 현행 결과를 보존한다. generation transport는 typed `Busy`, RemoteRuntime
      nonblocking pump와 pending-output/resync stream은 progress `false`, raw `callOrdered` RPC는 `AdminBusy`, observer resize는 success
      no-op다. owner-retention exact 표의 SSOT는 persistent-session-host.md가 소유한다. future 2c3e RPC execute는 helper signature만 예약하고
      caller 편입은 2c3e gate가 소유한다.
      **C3-3a3 product activation(구현·활성화 완료)**은 기존 take/release에 a1을, 현재 존재하는 모든 generation mutation
      consumer에 a2를 동시에 배선한다. take는 blocker producer이므로 target queued event와 자신이 reserve한 aggregate에 다시 막히는 a2
      consumer predicate를 사용하지 않고 producer 전용 final-address activation transaction을 쓴다. permit→prepare→registered
      operation→direct execution lease→held validate/borrow 뒤에만 payload를 역참조하고 quarantine/pin/a1을 reserve·bind한다. accepted
      preflight의 exact `event == .revoked`만 `EventOrderingClass.controller_revoke`이고 unknown 및 다른 accepted event는 `.none`이다.
      transaction은 canonical receipt lifecycle을 복제하지 않고 final-address seal, closed phase와 live-bit tuple만 rollback orchestration
      SSOT로 소유한다. held commit 뒤 a1 publish→permit no-fail consume→lease downgrade→transaction consume→operation release는
      실패·callback 0 suffix다.
      mutation consumer final gate는 검사부터 allocation·queue offset·syscall commit까지 family별 existing execution lease를 유지한다.
      shared pin만으로는 다른 shared mutation을 배제하지 않으므로 직렬화 근거로 쓰지 않는다. a1/a2 standalone substrate gate의
      역사적 product caller는 0이고, 현재 활성 caller inventory는 C3-3a3 boundary가 단일 출처로 소유한다.
      execution lease mint는 private live-operation row와 neutral TLS thread incarnation을 검증한 final-address receipt만 Client에 넘긴다.
      receipt의 canonical SSOT는 process-global bounded 4,096-slot registry이며 mutex 아래 O(1) free-stack pop과
      `slot_index` direct lookup을 쓴다. receipt의 atomic registry token은 pre-lock locator일 뿐이며 registry row/receipt의 exact key는
      slot generation·monotonic registry key·final address·Client/
      operation·PID/process nonce·thread id/incarnation이다. issue/consume/abort는 mutex 전에 PID/process nonce/TLS를 검사하고 lock 뒤
      PID를 재검사해 fork child가 상속 mutex나 Client graph를 만지기 전에 거부한다. tuple/live는 mutex 안에서만 판정·변경하고
      consume-vs-abort는 한 winner만 slot을 회수한다. Client는 exact registry receipt를 먼저 consume·slot
      generation 증가·free-stack 반환한 뒤에만 fence/graph를 읽고 final-address capability body를 완성해 address·identity·thread tuple을
      release-publish한다. held API는 raw pointer/public digest/local pin 대신 opaque handle
      `{slot index,slot generation,private key,publication identity,operation identity}`만 받는다. receipt registry와 별도인
      process-private bounded 4,096-slot capability registry가 O(1) free-stack/direct-slot으로 active/closing/readers를 소유한다.
      capability registry와 별도인 bounded 4,096-slot O(1) reader-pin registry는 caller-final pin address+
      reader slot/generation/key+capability slot/generation/key row를 먼저 등록한 뒤 readers를 올린다. exact one-shot row
      consume만 unpin/close owner reader를 내리며 copy/move/forge/double-unpin/sibling은 mutation 0이다. capability key는
      settlement pre-lock은 registry PID/nonce+reader-slot bounds만 읽고 public `pin.fields` authority를 쓰지 않는다. mutex 안
      final-address/reader slot-generation-key row exact consume→canonical capability slot-generation-key materialize→owner process/thread/TLS
      compare 후에만 readers--를 수행한다. close drain은 canonical captured capability tuple만 사용한다.
      module-private 256-bit production random secret의 keyed BLAKE3
      `maru.capability.registry-key.v1 || counter || slot || generation` transcript의 64-bit 축약이다. immediate reuse의 exact ABA
      authority는 slot generation이고 key는 probabilistic private discriminator다. runtime test의 old/new key inequality는 관측
      oracle이며 absolute collision-free 계약이 아니다.
      preflight는 registry pin 성공 후에만 capability pointer/fence/body projection을 private guard에 materialize하고,
      require는 마지막 fence/body read까지 guard를 유지한다. publish exhaustion은 body·local identity·fence tuple을
      pristine rollback한다. end는 active→closing, self reader release, readers==0 대기, generation bump+free-slot 반환 후
      body lifetime을 종료한다. 반환 후 same-address reuse/new generation은 허용하며 old handle은 pointer materialization 전
      거부한다. closing 게시 직후 late pin reject+close wait, OOB/foreign/fork fields tamper mutation 0,
      injected reader-capacity exhaustion seam의 out-pristine/readers unchanged와 즉시 reuse, mmap-unmap stale, forged key/fork/replay,
      caller/private-registry closure를 exact-5/boundary가 고정한다. fault/closing hook은 `builtin.is_test` conditional
      private storage/API로 production callable API가 없는 설계이며 nm/symbol-zero gate는 주장하지 않는다.
      consume 전 후속 실패는 두 canonical mint caller의 `errdefer abortMintReceipt`가 exact slot/capacity를 반환하며
      미회수 receipt를 허용하지 않는다. held leaf는
      graph read 전에 reader pin 후 검증한다. exact-5 runtime은 max-terminal issuer,
      copied/forged/foreign/callback/publication-teardown, deterministic end-vs-reader·consume-vs-abort, fork pre-lock reject,
      abort-capacity 원복과 O(1) free-count oracle의 typed reject·mutation 0을 고정한다. Zig build에 TSAN target은 없으며
      Debug·ReleaseFast deterministic interleaving과 atomic ordering review를 검증 경계로 두다.
      `idle|ended_pending`은 payload 역참조와 activation transaction/operation/lease/quarantine/pin/a1이 모두 0이다. `idle`은 prepared
      storage pristine을 유지하고 `ended_pending`만 prepared descriptor를 먼저 tombstone하며 둘 다 permit no-fail consume을 수행한다.
      a3은 Debug·ReleaseFast product runtime 10+actual-socket 2+boundary 1을 실행한다. quarantine reserve→pin reserve→generation
      reserve→quarantine/cleanup bind의 각 precommit fault와 ClientSlot-only held commit wrapper의
      `Terminal|Corrupt|InvalidPrepared`는 reserve 뒤 cache를 exact rollback한다. direct lease 획득 `Busy`는 transaction 생성 전
      public prepared abort/reset→operation release→permit abort로 정산해 reserve 전 mutation 0과
      `(queue=1,prepared=pristine,aggregate=0,permit/pin/quarantine/reserved-authority=0)`으로 수렴한다. queue commit 성공 뒤에는
      `(queue=0,aggregate=1)`만 허용한다. target pending outbound
      offset 0은 exact free 1/wire 0, partial offset은 no-retry fail-close, sibling pending은 offset/owner 보존·flush 0 뒤 aggregate zero에서
      재개한다. activation authority-live 상태의 callback reentry·foreign·teardown은 mutation 전에 거부하고, facade별 blocker gate는
      persistent-session-host.md closed 7-row의 `Busy|AdminBusy|false|observer success no-op`와 queue/pending owner retention을 고정한다.
      public nonblocking input은 `0`,
      public control은 성공 반환+FIFO 유지, internal pump는 progress `false`다. public `GenerationTransport`는 세 gate 모두 exact 15다.
      **C3-3b1 correlation·ordering migration과 C3-3b2a process-seal prerequisite는 구현됐고, C3-3b2b 이후 event settlement와 비동기 close는 미구현**이다. 다음 TDD slice를 닫는다. b2는
      process-domain seal 이전과 immutable preparation을 각각 독립 PR인 **b2a → b2b**로 나누며, 제품 `event_pending` 활성화 전에 async close를 먼저 닫기 위해
      실제 구현 순서는 **b2a → b2b → b3 → b5 → b4 → b6**이다. 각 slice는 앞 slice의 focused
      Debug·ReleaseFast gate와 source boundary를 상속하고, 마지막 slice 전에는 C3-3b 완료나 제품 close parity를 주장하지 않는다.

      1. **C3-3b1 correlation·ordering migration:** canonical take-only opaque `EventCorrelation`, minimal ClientSlot classification context,
         `EventOrderingClass.none|non_revoke_effect|controller_revoke`와 모든 taken event의
         `connection_ordering_blocker_count`를 먼저 red→green으로 만든다. 기존 revoke-only counter/query identifier는 0으로 만들고,
         EventAuthority lifecycle+cleanup pin을 sole cleanup SSOT로 유지한다. `none`은 idle/settled row 전용 inactive sentinel이며,
         모든 live non-revoke/unknown event는 `non_revoke_effect`다. benign도 release까지 blocker를 유지하며 sibling TX/RPC는 wire 0,
         queued revoke 뒤에도 RX/demux tail은 진행하는 actual socket oracle을 포함한다. take 당시 `expected_major|metadata_support`는
         canonical quarantine mirror에 immutable snapshot으로 봉인하고 release는 mutable Client current state를 다시 권위로 사용하지 않는다.
         b1의 RX/correlation projection은 내부 substrate이며 실제 `RemoteRuntime` 제품 pump 연결과 dormant semantic owner handoff는 각각 b4와 b2b가 소유한다.
      2. **C3-3b2a process-seal prerequisite:** dependency-neutral `process_identity.zig`를 macOS/Linux 실제 PID의 sole SSOT로 먼저 두고,
         neutral `process_seal_service.zig`를 별도 PR로 구현하며 기존
         `operation_thread_identity`의 capability key를 원자적으로 이전한다. ClientSlot process bootstrap의 기존 mutex 아래
         `nonce -> unpublished service prepare -> registry/issuer no-fail publication -> service ready release` 순서를 단일 transaction으로
         고정하고, 모든 reader는 PID/process nonce/domain의 ready acquire 검증 전 key·registry mutex를 만지지 않는다. production entropy는
         neutral `secureEntropy` provider가 service private unpublished storage에 직접 쓰며 raw key는 module 밖으로 나오지 않는다.
         non-secret cross-target fallback은 두지 않는다. 모든 byte OR가 0이면
         retry·fallback·`commitReady` 없이 permanent terminal이다. test-only deterministic scalar seed는 local service private seam에서만 내부
         KDF로 확장하고 seed/output 0을 거부하며 non-test import/caller/storage는 0이다. fork child는 inherited key/lock 전에 PID mismatch로
         거부한다. 전용 non-test helper의 public singleton을 두 clean exec에서 초기화해 process 간 derived tag 비재사용과 각 process의 typed derivation
         idempotence를 검증한다. 구 key/storage/lazy initializer/API/callsite는 source 0이며 source-level cutover라 과거 binary의
         storage zeroization이나 live key migration을 주장하지 않는다. b2a domain API는 capability registry key만 제공하며 b2 cleanup
         transcript/progress concrete typed input과 seal method는 b2b가 추가한다. raw key나 arbitrary-byte MAC oracle은 제공하지 않는다.
         service lifecycle은 `uninitialized -> initializing -> ready | terminal`이고 initializing claim 뒤 모든 실패는 terminal release를
         게시한다. package-private `prepare/commitReady/validateReady/capabilityRegistryKey`의 closed errors와 ClientSlot의
         `ProcessDomainMismatch|ProcessSealUnavailable` 정규화는 persistent SSOT를 따른다. focused gate는 기존 capability/reader/fork 전수와 동시 최초
         init·publication boundary pause·entropy/zero·cross-domain/replay를 Debug·ReleaseFast로 고정한다. Client fence, generation transport,
         initial snapshot owner, generation batch allocator-scope registry와 ended-purge quarantine receipt/proof도 같은 PID leaf로 이관하고
         unsupported target PID zero fail-close, Linux sentinel 권위와 fork-child
         inherited-authority acceptance가 0임을 source/process gate로 검증한다.
      3. **C3-3b2b immutable preparation:** final-address pending owner, immutable Runtime snapshot, closed prepared event/effect와
         production full-content seal을 구현한다. 공용 `RuntimeObservation.replace`와 기존 cache admission을 exact-capacity로 먼저 닫는다.
         b2b는 dormant production-source orchestration의 test-mode 호출, 4-part prepare peak,
         3-part published rehash, fixed failure mapping, typed scratch handoff와 proof-loss cleanup을 닫는다. concrete process-seal cleanup
         transcript/progress domain도 이 slice에서 추가한다. 세부 lifecycle·allocation 순서·seal 입력·fatal 경계의 SSOT는
         [persistent-session-host.md의 C3-3b 계약](persistent-session-host.md#c3-3b-event-settlement와-비동기-close-계약)이며 이 계획은
         그 계약을 복제하지 않는다.
      4. **C3-3b3 atomic settlement:** Attachment가 Runtime semantic type을 import하지 않는
         `settlePendingEvent(correlation,effect_request)` transaction을 구현한다. 모든 authority/callback/allocator preflight 뒤
         none·poison·revoke clean/cancel/partial→poison·already-terminal cleanup과 exact release를 같은 no-fail suffix로 닫는다. trusted
         mismatch recovery, sibling exact-own cleanup, first-reason 보존, callback/fork/ABA/proof-loss subprocess를 포함한다.
      5. **C3-3b5 common close progress:** 기존 VTable 메서드 수를 늘리지 않고 close 계열 반환을
         `CloseProgress`, remove를 `RemoveProgress`로 바꾼다. heap-pinned `RemoteRuntime.CloseAuthority`와 backend closing receipt,
         bounded/fair `CloseSweep`, pending lifecycle readiness, handle ABA와 real AppSession synchronous in-process tab/window close parity를
         검증한다. b4가 실제 `event_pending`을 활성화하기 전에 dormant pending 상태 전수를 먼저 닫으며 actual generation
         `event_pending` close E2E는 b4가 소유한다.
      6. **C3-3b4 product semantic commit/pump:** 모든 event kind를 mutation-free prepare→settle→no-fail commit으로 전환하고
         `idle|event_pending|drained|ended` typed progress를 `RemoteTermBackend.drainRemote`까지 연결한다. settlement/observation cleanup callback
         전후 full seal, `committed_cleanup` read/mutation guard, actual product Busy→next-tick success·surface live E2E와
         `RemoteRuntime` generation semantic arm의 raw `Client` event/effect callsite 0 focused allowlist를 고정한다.
      7. **C3-3b6 app-quit/current+N-1 shutdown:** 모든 outcome의 exact target/attempt `ShutdownAttemptKey`, connection-dependent와
         post-connection terminal의 one-shot `ShutdownConnectionReceipt{connection,GUI-local lease generation,operation,inventory_attempt}`,
         pre/post `bounded_unconfirmed` evidence matrix와 closed `ShutdownAdminOutcome`,
         exact-host one-shot admin lease barrier, target당 terminate attempt 3회와 app-quit global 15초 deadline, target별 순차 connection과 ambiguous
         membership/inventory reconciliation, exact artifact/major와 list/terminate/barrier bool을 가진 frozen
         `compatibility.Profile.ShutdownProfile`, runtime-manifest-only endpoint seal, N-1 ambiguous at-most-once bounded 종료,
         non-published noreturn fatal integrity, 5경계 전후 monotonic elapsed bucket과 backend-neutral fixed-64
         `ShutdownDiagnosticSink`→neutral consumer port만 쓰는 sole app-host `ShutdownDiagnosticBridge` value fan-out/reset,
         `terminalizeSharedConnectionNoDestroy`,
         per-owner cleanup→zero assertion→graph-last destroy, host EOF detach/reconnect actual socket을
         닫는다. generation GUI background blocking reader source 0도 boundary로 고정하며 생기면 fd wake-before-join 선행 gate를 요구한다.

      **C3-3c product socket/source-zero**는 열린 peer에서
      revoked/unknown/semantic failure roundtrip과 transport 구현·test fixture를 제외한 `src/**/*.zig` 제품 전체 generation raw `Client`
      event/effect source-zero를 닫는다. RPC/decoder direct-call inventory는 2c3e가 소유한다. immediate EOF·unread RX-first와
      decoder cadence/parity는 계속 2c3e 범위다.
   제품 gate는 RPC family별 legacy/generation decode parity와 input→RPC/revoke ordering을 포함한다. decode와 ordered input policy는
   `RemoteRuntime` 하나만 소유한다. **2c4**는
   `RuntimeConnection` union을 mode SSOT로 전환해 `RemoteRuntime.client`와 `generation_adapter` 병렬 필드를 제거하고 exact
   15-method/signature/source oracle을 닫는다. 제거할 legacy 인자·shim·split helper의 exact 목록은
   persistent-session-host의 CR3a-2c4 계약과 boundary oracle을 단일 출처로 따른다.
   각 gate는 reconnect/current publish와 제품 동작 변화 0을 유지하며 마지막 2c4
   전에는 2c 전체 완료를 주장하지 않는다. CR3a-2d는
   실제 owner의 typed failure/reentry/aggregate handoff를 닫고, CR3a-2e는 actual socket
   parity와 production boundary를 닫는다. HostAdapter는 RPC 전에 neutral binding의 node pin과 빈 cleanup entry를 예약하고 attach
   성공 뒤 stream ID를 무할당으로 결속하므로 post-attach lease mint 실패
   rollback을 만들지 않는다. external-pump의 `ExternalInboxLedger`와 movable attachment graph는 흡수·공유하지 않는다. 이때
   reconnect, current 교체, retired node 생성은 여전히 0이고 cleanup은 typed result만 반환하며 incident/artifact mutation은
   CR0b까지 0이다.
   CR3b는 pool membership과 독립된 connection generation의 checked-monotonic 전이·publish·overflow, main-thread
   `withCurrent` stack borrow, admission close,
   `Client.canRetire()`와 tick-end deferred retirement(동시 retired Client hard cap 2)를 닫는다. CR3c에서 `RemoteGeneration`을
   실제 slot에 연결한다.
6. **CR4 — 단일 host 실제 reconnect:** `connectExistingHost`, bounded snapshot+delta catch-up, mutation lease/seal,
   status/takeover와 lost-reply fail-stop 정책을 실제 socket fixture로 연결한다. observer conflict를 자동 takeover하지 않는다.
7. **CR5 — 멀티윈도우·다중 runtime:** app-global `SessionHostCoordinator`의 host job, runtime별 authority ledger,
   부분 commit forward resolution, Window move/close 경쟁을 자동 검증한다.
8. **CR6 — 제품 gate:** 실제 AppKit render/IME/clipboard, semantic notice/action, 장시간 backoff/soak와 성능 예산을 통과한 뒤에만 자동
   reconnect를 제품 설정에 연결한다.

CR0a~CR3은 사용자 가시 동작이 없는 구조/TDD 단계다. 어느 단계도 workspace를 쓰거나 host/runtime을 spawn·upgrade하지
않는다. 새 transfer receipt RPC는 현재 범위에 포함하지 않으며 seamless lost-reply 복구가 별도 목표가 될 때 다시 결정한다.
각 gate의 증거를 `model-only | production-type unit | real socket | real AppKit`으로 표시하며 CR2/CR3 완료는 `/tmp` PoC가 아니라
실제 production type을 import한 테스트가 필요하다. 최초 구현 순서는 CR0a → CR3a-1 inactive skeleton → CR3a-2
generation 1 compatibility wiring → CR2a → inactive CR2b이며 이
비제품 구조 slice가 green이기 전 CR4 socket reconnect를 시작하지 않는다.

실행 중 connection invalidation이 현재 session-host 제품 사용과 검증을 막으므로 CR은 나머지 제품 polish보다 먼저 닫는
blocking track이다.
단 CR4 admission은 CR0a+CR0b+CR1+CR2a~e+CR3a~c 전체 완료를 요구하며 scaffold 순서를 우회 조건으로 해석하지 않는다.
partial migration 실패의 마지막 screen/scrollback deep-freeze와 `FrozenProjection`은 범위 밖이다. 실패 runtime은 경량
unavailable placeholder로 전환하고 Retry 성공 시 host snapshot으로 재구성한다.
CR6 제품 활성화는 R2b Recovered Sessions projection/adopt 제품 경로가 완료된 뒤에만 가능하다. 그 전에는 unconfirmed Term이
있는 Window close를 제품에서 허용하지 않아 사용자가 찾을 수 없는 orphan runtime을 만들지 않는다.

## Provider session continuity 잔여 제거(persistent-session P1, 완료)

Claude/Codex provider-native resume/fork는 제품 경로로 되살리지 않는다. P1에서 legacy workspace typed field/parser,
restore 설정 alias, 과거 hook/mapping cleanup과 전용 환경변수 차단을 제거했다.

- provider continuity 호환과 같은 loader branch의 dead notification alias를 제거했고 세 설정 key는 일반 unknown-key
  진단으로 돌린다. 구 workspace의 미지 scalar는 일반 key-addressed 규칙으로 무시하되 독립
  `max_line_fields=512`, 512-field 성공과 513번째 거부를 유지한다.
- 과거 source build가 provider config에 설치한 Maru hook은 자동 회수하지 않는다. 잔여 hook/config/mapping은 Maru의
  소유 범위 밖에 두고 읽거나 신뢰하지 않는다. provider가 고아 hook을 계속 실행할 수 있다는 결과는 사용자 문서에 명시하고,
  정리가 필요하면 `agent-session.md` support runbook으로 정확히 식별된 Maru 항목만 제거한다.
- foreground process·screen 기반 live `agent_kind/agent_state` observer는 provider session continuity가 아니므로 유지한다.
- [Workspace Restore 전략](workspace-restore.md), [에이전트 상태 감지](agent-session.md), [알림 전략](notifications.md),
  `configuration.md`, verification matrix는 현재 계약만 남기고 삭제된 구현 역사는 Git/PR로 보낸다.
- host/runtime 종료 뒤 provider ID로 복구하는 fallback은 구현하지 않는다. 영속성은 host가 동일 PTY/process를 계속
  소유하는 동안에만 성립한다.

## 개발 순서 단일 출처

개발 순서의 단일 출처는 이 문서다. [초기 아키텍처](architecture.md)는 이전에 parser를 너무 앞에 둔 표현이었지만, 지금은 본문에서 그 parser-first 표현을 철회하고 큰 구조 설명만 유지하며 구체적인 순서는 이 문서에 위임한다.

## PR마다 확인할 질문

- 이번 PR은 위 단계 중 어디에 속하는가?
- 그 단계의 TDD 방식으로 구현 전에 실패하는 테스트를 만들 수 있는가?
- 만들 수 없다면 contract test, smoke test, 수동 artifact 중 무엇으로 대체하는가?
- 새 코드가 이전 단계의 facade 계약을 깨지 않는가?
- 자동화할 수 없는 한계를 PR 설명에 보고했는가?

## 에이전트 세션 기록 도크 (AS1·AS2·ML1~3b 구현, AS3-a/AS3-b 제품 SessionDock 연결, AS3 잔여 gate·AS4-a 구현)

우측 `agent_sessions`는 현재 열려 있는 Term의 보조 목록이 아니라, Codex·Claude가 로컬에 남긴 **검증된 사용자 세션 전체의 최근 목록**이다. 기본 scope는 전체이며, 살아 있는 세션은 선택적으로 이동할 수 있는 행일 뿐 후보 선정 조건이 아니다. 계약은 [에이전트 세션 기록 도크](agent-session-list.md)가 소유한다.

> **AS4-c 보정(2026-08-03):** Codex·Claude resume/reveal AppKit fixture는 구현·검증됐지만 `exact-live`는 완료가 아니다. 일반 PTY child의 `KERN_PROCARGS2` 관측이 argv-only payload를 반환해 provider child 환경의 session ID를 읽지 못한 macOS POC 결과에 따라, path·mtime·활동시각 추측 또는 fixture-only mapping으로 action을 materialize하지 않는다. provider 공식 payload를 `MARU_PANE_ID`에 묶는 공통 mapping 설계가 승인되기 전까지 이 scenario는 차단 상태다.

1. **AS1** — provider-neutral record와 Claude/Codex parser, title/summary/filter/sort/dedup/redaction의 synthetic fixture TDD. 계약([agent-session-list.md](agent-session-list.md) §4-3)이 요구하는 **streaming** parser는 AS5가 닫았다. 파일 전체를 한 버퍼에 올리던 구현(피크 실측 463 MB)과 그것을 방어하던 read cap들이 함께 사라졌다. 정렬 키의 마지막 갭(mtime 기준)은 AS6가 닫았다.
2. **AS2** — worker-only discovery/parse, no-follow identity recheck, cancel/generation, 앱 실행 중만 유지하는 file-identity parse cache, immutable snapshot publish. no-follow open 후 device·inode 재검사와 memory-only identity cache를 제공하며, refresh 중에는 이전 완료 목록을 보존하고 새 scan 종료 뒤 한 번만 swap한다. **AS2-a는 구현됐다:** backend-owned request generation·cooperative cancel·cancelled publish 폐기와 dock 재진입 latest-wins 재요청을 제공한다. main thread는 cache snapshot render·queue apply만 하며 I/O/parse/정렬/wait=0이다. persistent metadata cache는 개인정보 정책 승인 전 범위 밖이다.

   **AS2-b(동시 parse≤4)는 보류다.** 실측(2026-08-08) 결과 전체 스캔 비용의 97.5%가 JSON parse이고 I/O는 1.2초이므로, 병렬화 이전에 read cap 제거와 점진 publish(AS5)가 사용자 체감을 결정한다. 병렬 pool은 AS5 이후 남은 시간을 재고 판단한다.

   **bootstrap의 candidate/file/total cap은 AS5에서 제거됐다.** 이 cap들은 위 AS1 갭(전체 버퍼)을 방어하려고 존재하며, 그 부작용으로 **캐시 상태가 목록 길이를 바꾼다**(캐시 hit는 budget을 쓰지 않으므로 refresh를 반복할수록 보이는 세션이 늘어난다 — 실측 69→272개, 12회 반복에도 미완).
3. **AS5** — 계약이 이미 정한 것을 이행해 목록의 완전성과 결정성을 회복한다.
   - **AS5-a** streaming parser: 고정 버퍼 순차 읽기 + 줄 단위 소비. 파일 크기와 무관한 메모리.
   - **AS5-b** read cap 제거: candidate/file/total cap을 없애고 시간 상한 하나만 남긴다. cap이 사라지면 캐시가 결과를 바꾸지 않는다.
   - **AS5-c** 첫 진입 점진 publish: 이전 완료 snapshot이 없을 때만 부분 snapshot을 발행한다. 부분은 TTL을 갱신하지 않고 "이전 snapshot 있음" 판정에도 쓰지 않는다.
   - **AS5-d** `partial` 노출: scanner가 이미 세는 불완전 신호를 DTO로 올려 header에 보인다. 계약(§4)이 요구하는데 통로가 없어 미구현이던 항목이다.
   - **AS5-e** worker 판정 개정(§3.1): 구버전 Codex를 포함으로 뒤집고, 판정은 파일 안 마지막 `session_meta`를 따른다.
   - 선행: `Result` 발행 종류를 배타적 union으로 정리해야 AS5-c가 기존 완료 불변식을 깨지 않는다.

   **AS5는 구현됐다.** streaming parser·cap 제거·점진 publish·`partial` 노출·worker 판정 개정이 모두
   들어갔고, 실측으로 목록이 라운드마다 337개로 같아졌다(이전에는 69→272로 늘며 12라운드에도 미완).
   적대적 검증 세 라운드가 상한 분기 둘, `errdefer` 누수 둘, 부분 진행 큐 누적, 점진 발행 판정 오류를
   잡아 함께 고쳤다.
4. **AS6 — 정렬 키와 방향 토글:** 계약([agent-session-list.md](agent-session-list.md) §2.3)이 정한
   정렬을 이행한다.
   - **AS6-a는 구현됐다.** 정렬 키가 transcript의 마지막 활동 시각이다. 두 provider 모두 각 줄
     최상위에 RFC 3339 UTC `timestamp`를 싣고(실측 200,025건이 모두 밀리초 3자리 `Z` 한 형태),
     `Parser`가 그 **최댓값**을 남긴다 — 줄 순서가 시간 순이라는 보장이 없기 때문이다. 얻지 못한
     파일은 mtime으로 폴백한다(실측 40개 중 1개). 카드의 `N분 전`도 같은 `lastActivityNs`를 읽어
     목록 순서와 표시가 갈리지 않는다. **근거:** mtime으로 정렬하면 로컬 이력 362개 중 257개(70%)가
     제자리가 아니고, Claude 쪽 최대 차이가 144시간이다(2026-08-08 실측).
   - **AS6-b는 구현됐다.** header의 `로컬` label과 refresh 사이 trailing slot에 최신순/오래된순
     토글이 있다. 방향은 표시 계층에서만 바꾸고(filtered index를 뒤집는다) 스캔 순서는 최신 우선을
     유지한다. 앱 실행 중에만 유지하고 디스크에 쓰지 않는다. 최소 도크 폭(120pt)에서는 header
     utility가 제목을 밀어내므로 좁은 폭에서는 토글을 발행하지 않는다.
   - **잔여 gate:** 토글의 실제 pointer 왕복 AppKit fixture와 2× backing scale의 header utility
     rect JSON은 아직 없다. 정렬 결과의 실제 이력 대조는 개인 데이터라 CI에 넣을 수 없다.
5. **ML1** — `src/chrome/ui/layout.zig`가 typed `UiLength`와 border-box `UiRect`, measure callback, row/column flex, grow/shrink freeze 재분배, min/max, margin/padding/gap, justify/align-self, overflow clip result를 allocation 없이 계산한다. invalid/indefinite input은 error와 empty rect로 fail-close하며, pure test가 px/percent/auto/fill, tiny content, NaN/범위 오류, clip을 고정한다. 이는 한 parent의 sibling solver일 뿐 `UiTree`·draw/hit-test·제품 UI는 아직 만들지 않는다.
6. **ML2a** — `src/chrome/ui/tree.zig`가 `container`/`card`/`text` value builder, global duplicate-id fail-close, bounded frame-buffer tree build, parent/clip ancestry와 nested rect offset overflow fail-close, successful-only rebuild counter를 pure test로 고정했다. 이 tree는 TUI cell/ANSI path를 읽지 않지만, draw/hit-test/focus/scroll 또는 제품 Session Dock은 아직 소비하지 않는다.
7. **AS3** — scope와 snapshot-only search, 접이식 workspace group, 세 줄 카드의 데이터 투영과 AS3-a/AS3-b의 Metal component·published-tree pointer lifecycle은 구현됐다. AS3-c1은 `ui/scroll_area.zig`의 integer backing-pixel projection으로 partial visible range와 같은 content clip을 만들며, host가 terminal/sidebar/notification과 분리된 dock wheel residue로 이를 소비한다. AS3-c2는 snapshot 교체와 resize에서 first partially-visible card의 exact `{provider, session_id, device, inode}` anchor와 intra-card backing-pixel offset을 복원하고, identity가 없거나 group이 접혀 materialize되지 않으면 numeric offset만 새 상한에 clamp한다. PageUp/PageDown/Home/End는 search 비포커스에서 같은 state를 움직이고 residue를 비운다. `partial-scroll` Lab은 component→CoreText atlas→제품 Metal PPM/PNG/JSON readback을 고정하고, `expanded-scroll-anchor` isolated AppKit fixture는 실제 `NSView.scrollWheel`·refresh·새 published generation·전후 Metal capture를 확인한다. Lab은 fixture input이므로 actual `AppSession` worker/snapshot E2E를 뜻하지 않으며, 시각 결과가 바뀌는 PR은 이 capture를 `gh attach`로 PR 본문에 포함한다.
8. **AS4** — 행 click/Enter가 provider 실행 없이 dock-local archive detail을 열고, detached worker가 no-follow open·device/inode 재검증 뒤 마지막 512 KiB의 recent turn/action summary를 공통 redaction과 함께 publish한다. `SessionDock`의 `ExpandedSessionCard`가 한 stable identity만 dock scroll area 안에서 `closed/loading/ready/stale/unavailable` disclosure로 연다. 기본/expanded row와 action rect·clip·scroll projection은 같은 completed tree를 쓰며, pointer/`⌘↵`/`⌘L`은 그 published ready action capability만 resolve한다. 같은 card toggle, scope/search/group close, stale source reveal 차단, inline ready/loading/stale readback, Codex·Claude pointer/key resume/reveal fixture는 연결됐다. **AS4-d legacy archive-tab 제거도 구현됐다:** row activation은 `agent_session_inline_detail` 하나만 갱신하며, archive 전용 `TermRuntime` state·Term/tab 생성·sentinel surface·pane renderer·body pointer/key routing은 없다. detail backend 결과는 `surface_id == 0` 같은 숨은 소유자 표식 없이 dock-local request identity 하나로만 수신한다. close·scope/search/group 전환·snapshot identity 교체는 published dock action tree를 먼저 폐기한 뒤 DTO를 해제하거나 stale로 전이한다. 전용 AppKit fixture가 card activation 전후 active terminal surface id와 전체 Term 수가 같음을 loading/ready/stale에서 확인한다. **같은 card close/reopen AppKit fixture도 구현됐다:** ready card를 같은 published pointer rect로 닫은 뒤 resume/reveal capability가 사라진 것을 확인하고, 새 gate 뒤 재열기 loading→ready의 request id가 이전 id와 다르며 전 과정의 active terminal surface·Term 수가 불변임을 검증한다. **snapshot-replace stale-up AppKit gate도 구현됐다:** physical refresh → worker scan gate → old ready resume `mouseDown` → atomic source replace → immutable snapshot publish/stale capability → old rect `mouseUp` 순으로, old action capture가 새 provider argv·Term·external open을 만들지 못함을 실제 host input path에서 확인한다. **AS4-e는 구현됐다:** 640pt 자동 도크에서 4행 header·3행 control/group·6행 divider list와 `1.5ch` outer padding, bold title/group, 10행 inset detail, 3행 action 및 `0.5ch` sibling gap을 같은 completed tree로 계산한다. B1-button-b는 action의 measured label/SVG group final-pixel placement를 완료했다. **AS4-f-a는 구현됐다:** logical spacing의 16pt/12pt action inset, 18pt icon, 8pt gap과 48pt minimum action height를 backing scale에서 resolve한다. **AS4-f-b는 구현됐다:** `DockMetrics`가 root/header/scope/search/group/card/detail/action/scroll metric을 단일 snapshot으로 resolve하며 build·view·virtualization·wheel이 이를 함께 읽는다. terminal cell metric은 text의 보수적 수평 truncate fallback만 맡고 dock rect/hit target을 움직이지 않는다. extreme scale은 포화 산술로 fail-close한다. 기본/큰 terminal font와 1×/2×의 actual AppKit rect JSON 비교는 이 구현의 다음 시각 검증 gate로 남긴다. snapshot replacement stale race와 expanded-card scroll anchor의 active AppKit E2E는 완료됐고, exact-live와 기본/큰 terminal font의 1×/2× actual AppKit rect JSON 비교는 별도 잔여 gate다. 실제 사용자 이력 resume은 CI가 아니라 사용자가 승인하는 수동 gate다.

   **AS4 snapshot-replace stale-up 정정(현재):** 위 단락의 “다음 slice” 및 “남은 … stale race” 표기는 과거 계획이다. 현재 fixture는 ordinary `refresh` pointer → detached scan gate → old ready `resume` `mouseDown` → same-directory atomic source replace → immutable snapshot publish → stale/old-capability unmaterialized → old backing rect `mouseUp`을 한 cold AppKit process에서 검증한다. old capture는 provider argv·external open·Term 생성/전환을 전혀 만들지 않으며, scan gate는 worker discovery 전에만 대기하므로 main actor의 retained-list paint를 막지 않는다. expanded-card scroll anchor와 terminal font 14pt/24pt × render scale 1×/2× dock/action rect JSON은 실제 AppKit E2E로 완료됐다. 후자는 published tree의 header/scope/search/first·expanded card/resume/reveal border rect가 font마다 동일하고 2× backing rect가 정확히 두 배인지 확인한다.
9. **B1-text** — 제품 rich Chrome text는 `NativeMetalCell{row,col}`만 쓰지 않고 `GpuGlyph`의 final pixel rect를 별도 전달한다. `chrome_draw_lowering.RichTextArtifact`는 semantic text origin·clip-aware cell span·foreground를 보관하고, 완성된 CoreText/atlas `GlyphQuadFrame`을 shared atlas UV의 GPU glyph pass로 내린다. AppSession은 SessionDock text/style/rect/icon/grid key가 같으면 renderer-neutral shaped record와 placement를 재사용해 CoreText를 다시 호출하지 않으며, `ChromeTypography` token·platform primary/fallback generation·scale 파이프라인만 이 cache를 폐기한다. terminal `font.*` 변경은 Chrome cache 입력이 아니다. ABI v158의 atlas-pixel origin은 multi-pane atlas 성장 뒤에도 UV를 다시 정규화한다. `macos-chrome-lab-smoke`도 반드시 같은 artifact의 `appendGpuGlyphs` 결과만 product Metal readback에 넘긴다. Lab이 `row × cellHeight`로 GPU glyph 위치를 다시 만들거나 fixture용 nudge를 더하면 semantic origin의 sub-cell offset이 사라져 실제 화면과 다른 capture가 되므로 금지한다. readback은 `rich_text_rasterized=true`를 요구한다. **B1-doc은 `ChromeTextRole`의 UI primary-face 분리, 9개 type token, measured line-box alignment, system UI/Jetendard font-review와 AppKit capture gate까지 고정했다. B1-button 구조는 `UiNode.button`·primary/secondary/disabled visual·same-tree pointer/key action까지 구현됐다. B1-button-a는 archive action의 SVG icon과 한글 label을 별도 draw op로 내고 label만 measured artifact/CJK ellipsis로 이관했다. B1-button-b는 worker-owned `center-in-content`/`leading-icon-group` policy로 CJK ellipsis advance, line box, SVG icon optical box와 group centre를 하나의 immutable record+placement artifact에 넣고, cache hit는 `shapeFromRecords`만으로 shared atlas를 재사용한다.** 이 단계는 headline typography 전체 이관을 대신하지 않는다.

## ScrollArea 이관 (설계 완료 — 구현 미착수)

계약 단일 출처는 [ScrollArea](scroll-area.md)다. 이 절은 순서와 상태만 소유한다.

지금 스크롤하는 곳이 일곱(Session Dock·파일 탐색기·소스 컨트롤·사이드바·알림 패널·팔레트/세팅·탭 바)인데
좌표 단위와 발행 경로가 모두 다르고, 같은 규율을 각자 다시 발견하다 매번 다른 것을 빠뜨렸다 — 탐색기는 tick 소비 누락("놓아야 움직이는" 스크롤바), 도크는
tree 교체에서 capture carry 누락(드래그가 첫 move에 죽음)·스크롤바가 목록 위에 겹침·장식 quad clip 누락.
넷 다 사용자 보고로 돌아왔다. ScrollArea는 그 규율을 한 번만 맞게 두는 자리다.

- **SV0 — 판정자 먼저(완료).** 도크 골든 어디에도 스크롤바 픽셀이 없었다 — Lab fixture가
  `scroll_content_height_px`를 채우지 않아 `scrollbarGeometry`가 `null`을 냈다(항목 수 무관). `scrollbar`
  Lab 시나리오와 `scrollbar-track-and-thumb` 골든 case로 닫았고, 스크롤바 발행을 막으면 2970픽셀 차이로
  실패하는 것을 확인했다. 캡처가 한 장만 없을 때 그 case를 건너뛰던 게이트 구멍도 `MARU_REQUIRE_GOLDEN`
  에서 실패하도록 함께 닫았다.
- **SV1 — Session Dock에서 추출.** 가상화·픽셀 offset·스크롤바·드래그·키보드 스크롤을 모두 쓰는
  유일한 소비처라 여기서 뽑으면 계약이 처음부터 전부 드러난다. 한 PR로 리뷰하기에 너무 커서 셋으로
  나눈다. 시각·동작 무변경이 셋 모두의 완료 기준이고, **SV0가 추가한 스크롤바 골든**이 그 판정이다
  (기존 네 장만으로는 판정되지 않는다).
  - **SV1a — 좌표계 추출(완료).** `session_dock/scroll.zig`를 `chrome/ui/scroll_area.zig`로 옮기고 도크
    전용 파일은 지운다(shim 없음). `project`가 도크의 `Kind`/`Metrics` 대신 comptime 높이 함수를 받아,
    그룹 헤더·카드·펼친 카드라는 예외가 host의 `ArchiveScrollItems` 한 자리로 모인다. 변이 검증에서
    드러난 무판정 구간(`withOffset`·`clamp`·무변화 반환값·host가 넘기는 높이/간격/개수/펼침 예약)을
    함께 닫았다.
  - **SV1b — 발행과 clip을 `build`로(완료).** 도크가 손으로 하던 세 단계(컨테이너 build → 자식
    평행이동 → 스크롤바 append)를 `tree.scrollArea` 선언 하나로 접고 그 처리를 `tree.build`로 옮겼다.
    스크롤바가 배열 끝의 `parent_index = null`에서 preorder 안으로 들어와 `UiRectTree`의
    preorder·subtree-range 불변식이 지켜지고 root가 하나로 돌아왔다.
    **clip 예외가 사라졌다**: gutter를 컨테이너가 자기 폭에서 예약하므로(CSS `scrollbar-gutter`,
    taffy `content_box_inset`) 스크롤바가 자기 컨테이너 clip 안이다. 조상 padding을 빌리던 옛 구조는
    조상 clip 예외를 강요했고 그 규칙은 padding 없는 소비처(SV2)에서 무너진다.
    시각은 불변이다 — 골든 다섯 장이 갱신되지 않았다. 고정 chrome이 오른쪽 여백을 `margin.right`로
    직접 갖게 하면서 도크의 `width: percent 1` 아홉 곳을 걷어냈다(percent는 border box 전체 크기라
    margin을 무시한다). 스크롤 자식의 `shrink = 0`을 컨테이너가 소유하는 것은 아직 남았다.
    **clip 경로가 둘이라는 것을 먼저 알고 들어간다.** 도크 텍스트의 실제 자르기는 measured 경로의
    `Artifact.appendGpuGlyphs`가 한다 — glyph마다 clip과 교차시켜 UV까지 줄이는 **부분 잘림**이고,
    적용 여부는 `placement.scroll_clipped`가 정한다. 반면 `Op.text.clip`은 셀 격자로 내리는 경로
    (`metal_lowering.placeText` — 모달)용이라 **도크에는 타지 않는다**(SV1a에서 그 판정을 통째로 막아도
    Lab 캡처가 픽셀 하나 안 바뀌는 것을 확인했다). 그래서 도크의 잘림 픽셀은 골든이 이미 보고 있고,
    SV1b가 지켜야 할 것은 `scroll_clipped` 소속 판정과 그 clip 사각형의 출처다.
  - **SV1c — 측정 pass와 drag 헬퍼(완료).** 뷰포트 높이 복제를 없앴다 — 자식 없는 scroll-area로
    layout을 한 번 돌려 그 값을 layout에게 묻고, `fixedChromeHeight`는 소비처가 사라져 지웠다.
    host의 drag 세 지점은 `scroll_area.Drag`로, 분수 휠 잔여와 그 산술(방향 전환 폐기·정수부 소비·
    overflow 가드)은 `State.scrollByWheel`로 모았다. `Drag`가 `interaction`을 import하지 않는 것이
    계약이다 — 그쪽이 `tree`를 쓰고 `tree`가 `scroll_area`를 쓰므로 순환이 된다. 그래서 이벤트가
    아니라 좌표만 받고 payload 판정은 소비처가 한다.
    **남은 것**: 스크롤 자식의 `shrink = 0` 소유 이관(§4.3), selection follow(§4.5).
- **SV1d — 그룹 헤더 sticky.** 지금은 스크롤하면 그룹 헤더가 밀려 올라가 글자가 반쯤 잘리고 "어느
  그룹인가"가 사라진다. [ScrollArea](scroll-area.md) §4.7이 계약이다 — clamp 산술은 ScrollArea가, 무엇을
  붙일지는 소비처가 정한다(가상화 때문에 그 헤더는 창 밖일 수 있고, 창 밖 항목이 어느 그룹인지는
  domain만 안다). 높이는 그대로 자리를 차지하고 그리는 y만 clamp하므로 `project`의 content 높이·창
  계산·anchor 규칙이 바뀌지 않는다. **SV1b 뒤에 한다** — 발행이 `build`로 옮겨간 뒤라야 sticky 노드를
  preorder 안에서 낼 수 있고, 그 전에는 스크롤바처럼 배열 끝에 붙이는 임시 형태가 하나 더 생긴다.
  판정자: 그룹 둘 이상인 Lab 시나리오를 offset 셋(헤더 앞·지나침·다음 헤더 접근)으로 캡처한 골든.
- **SV2 — 파일 탐색기 이관.** 행 단위 좌표를 backing pixel로 옮기는 것이 실제 변경이다. 부분적으로
  보이는 행이 생기므로 행 기반 hit-test·reveal·follow가 픽셀 좌표를 읽도록 함께 바뀐다. 별도 스크롤바
  tree(`file_tree_scrollbar.publish`)와 전용 capture 경로는 이 단계에서 제거한다.

  **코드를 읽고 확인한 것**(SV1d 직후 조사). 이 셋이 단계 나눔을 정한다.

  1. **탐색기 행 텍스트는 셀 격자 draw list다**(`coretext_frame_builder.buildFileTreeDrawList` → `collectShaped`).
     도크처럼 measured 경로가 아니다. 그런데 **옮길 필요가 없다** — `PanePlacement`는 이미 픽셀
     `origin_y`와 `clip_rect`를 갖는다. 부분 행은 draw list를 `offset / cell_h` 행부터 만들고 pane 원점을
     `offset % cell_h`만큼 올린 뒤 content rect로 자르면 나온다. 행 하이라이트 quad도 이미 픽셀 위치라
     같은 편향만 받는다. 셀 텍스트를 measured로 옮기는 것은 SV2의 범위가 **아니다**.
  2. **탐색기 콘텐츠는 어떤 `UiRectTree`에도 없다.** 스크롤바조차 tree로 그리지 않는다 — 실제 그림은
     host의 GPU quad이고 `file_tree_scrollbar.publish`는 **스모크 probe 전용**이다(rect 두 개를 만들어
     thumb 좌표를 실어 보낸다). 그래서 `tree.scrollArea`는 SV1c가 만든 **자식 없는 measure pass**
     형태로 쓴다 — 컨테이너가 뷰포트와 gutter를 소유하고 track/thumb을 내되, 행은 그 content rect
     안에서 셀 경로가 그린다.

     이관하면 **idle fade가 함께 옮겨진다.** 지금 탐색기 스크롤바는 host가 `file_tree_scrollbar_idle_ticks`
     로 흐리는데 도크 스크롤바에는 그 개념이 없다(§8). 둘 중 하나로 통일할지, ScrollArea가 fade를
     소유할지는 SV2b가 정한다 — 지금 결론을 적지 않는다.
  3. **탐색기에는 시각 골든이 없다.** Chrome Lab은 `session_dock`·`archive_detail`만 그리고, CI의
     "file explorer macOS product path" 잡은 셰이더 스모크와 **도크** 골든을 돌린다. 즉 지금 탐색기
     스크롤을 통째로 망가뜨려도 초록이다 — SV0 직전의 도크와 같은 상태다.

  그래서 **SV2-0이 먼저다**(SV0와 같은 이유). 슬라이스:

  - **SV2-0 — 판정자.** 탐색기 행·스크롤바를 실제로 보는 게이트를 만든다. 판정 기준은 하나다 —
     **부분 행 하나를 없애면 빨개져야 한다.**

     **Lab은 이 소비처의 게이트가 될 수 없다.** 도크에서 Lab이 판정자인 이유는 도크의 기하·페인트가
     `session_dock.build`/`view`라는 **제품 컴포넌트**에 있어서다. 탐색기는 그 로직이 `app_session`에
     있고(행 하이라이트 quad, 스크롤바 quad, fade, reserved 칸 수), Lab이 그것을 다시 쓰면 골든은
     제품이 아니라 그 복제본을 판정한다 — 이미 한 번 밟은 함정이다([ScrollArea](scroll-area.md) §10.1
     "테스트가 제품 경로를 태우는지 본다").

     그래서 **`test-macos-file-explorer-perf`가 쓰는 하네스를 쓴다.** 그 스텝은 `app_host_abi` 모듈에서
     실제 `AppSession`을 헤드리스로 만들어 탐색기 hot path를 돌린다 — 제품 경로 그대로다. 여기에
     기하 판정을 더한다: 주어진 픽셀 offset에서 draw list의 **시작 행**, 만드는 **행 수**(부분 행 몫
     +1), pane **원점 편향**(`offset % cell_h`), **clip rect**. 넷 중 하나만 틀어져도 부분 행이 사라지거나
     겹친다.

     **⚠️ 이 전제는 틀렸다(SV2-0에서 코드로 확인).** `PanePlacement.clip_rect`는 필드로 있지만
     **셀 경로에서는 아무도 읽지 않는다.** `app_session`은 `c.measured_text`가 있을 때만 그 값을
     쓰고(measured 전용), `metal_frame`이 scissor로 만드는 것은 **오버레이(모달) 프레임 하나**뿐이며
     그것도 프레임당 rect 하나다(`modal_clip`). 탐색기는 `collectShaped`(measured_text 없음)라
     `clip_rect`가 통째로 버려진다. 즉 "원점 편향 + clip"만으로는 부분 행이 나오지 않는다.

     **A로 갔고, 그 A가 틀렸다(2026-08-08 정정).** 당시 셋 중 A를 골랐다 — 프레임당 하나인 clip 슬롯을
     pane별로 넓히고, 자를 **구간**은 `PaneFrameRole`로 pane 루프가 찾아 `pane_clip_cells_start/len`으로
     투영하는 안이다. 그렇게 머지된 v147은 **한 번도 동작하지 않았다.**

     이유는 그 설계에 있다. 사각형은 프레임에 실리는데 그것이 가리키는 구간은 **매 프레임 다시
     계산되는 pane 구성**에서 나온다. 도크 목록 pane은 매 프레임 발행되지 않으므로, 그 pane이 없는
     프레임이 슬롯을 지운다 — 실측하니 같은 버퍼에 대해 30프레임 중 6프레임만 값이 실렸고 24프레임이
     null로 덮었으며, 렌더러의 scissor 분기는 **진입 0회**였다. 탐색기는 불투명한 뷰 바가 넘친 행을
     가려 이 실패가 화면에 안 보였고, 소스 컨트롤의 투명한 브랜치 헤더가 드러냈다.

     **v169가 대체했다(C안).** `NativeMetalCell.clip_index` + 프레임 clip 표(`cell_clips`)로 **셀이 자기
     clip을 든다**. 사각형과 대상이 같은 배열에 있으니 둘이 어긋날 수 없고, 구간을 role로 되찾을 필요도
     없다 — quad 경로(`GpuQuad.clip_*`)가 이미 그렇게 하고 있었다. 렌더러는 index가 바뀌는 경계에서
     draw를 쪼갠다. 옛 `pane_clip_*`·`modal_clip_*` 필드와 인자는 제거했다.

     **남길 교훈**: "무엇을 자를지"와 "어떤 사각형으로 자를지"를 **다른 수명의 두 곳**에 두면, 둘이
     어긋나도 컴파일도 헤드리스 단언도 통과한다. 그 조합은 소비자 하나가 우연히 매 프레임 발행될
     때만 동작하고, 그렇지 않은 둘째 소비자에서 조용히 실패한다.

     당시 적었던 선택지 셋(기록):

     - **A(당시 선택, v169가 되돌림). 프레임 단위 clip 슬롯을 pane별로 넓힌다.**
     - **B. 탐색기 텍스트를 measured 경로로 옮긴다**(도크와 같게). 셀 정렬 전제·아이콘 2패스·성능
       예산을 전부 다시 봐야 한다.
     - **C(v169가 채택). 셀이 자기 clip을 든다.** `ClipPx` 주석이 트리거를 미리 적어 뒀다 — "세 번째
       프레임 단위 clip 소비자가 생기면 셀 경로도 per-primitive clip으로 일반화할 때다".

     **픽셀 한 번은 손으로 본다 — 그리고 판정 가능한 화면에서 본다.** 셀 pane을 scissor로 자르는 것은
     이 저장소에서 처음이고(도크는 measured 경로의 per-glyph clip이다), 그것이 GPU에서 실제로 잘리는지는
     기하 단언이 말해 주지 않는다. SV2a에서 캡처를 봤지만 **탐색기는 판정자가 될 수 없었다** — 넘친 행이
     불투명한 뷰 바 뒤에 있어, 잘렸을 때와 안 잘렸을 때의 화면이 같다. 그래서 "캡처로 확인했다"는 SV2a의
     주장은 근거가 없었다. 잘림을 판정하려면 **넘친 내용이 실제로 보이는 화면**이어야 한다(소스 컨트롤의
     투명한 브랜치 헤더). 자동 픽셀 게이트가
     필요할 만큼 이 경로가 자주 바뀌면 그때 앱 스모크 캡처를 골든에 물린다 — 지금 만들면 쓰지 않을
     하네스를 먼저 짓는 것이다.
  - **SV2a — 픽셀 스크롤 상태(완료, clip 부분은 v169가 다시 함).** 셋으로 나눠 들어갔다. **SV2a-1**:
     셀 격자 본문 한 구간을 px 사각으로 자르는 ABI v147 seam(값 0 = 기존 동작). **SV2a-2**: 탐색기 pane이
     `PaneFrameRole.file_tree`로 자기 셀 구간을 표시해 그 seam의 첫 소비자가 된다. **SV2a-3**:
     `file_tree_scroll_rows: usize` → `scroll_area.State`(픽셀). 렌더는 위 ①의 원점 편향 + `clip_rect`이고,
     hit-test·reveal·follow·휠이 픽셀을 읽는다.

     **정정(2026-08-08)**: SV2a-1/2가 깐 v147 seam은 GPU에 한 번도 도달하지 않았다(위 "A로 갔고, 그 A가
     틀렸다"). 픽셀 스크롤 상태·창 계산·hit-test는 그대로 유효하고, **자르는 부분만** v169
     (`NativeMetalCell.clip_index` + 프레임 clip 표)로 다시 했다. 탐색기에서 이것이 안 보였던 이유도
     같은 항목에 적었다.

     **투영은 `scroll_area.project`가 아니라 나눗셈이다**(계획 정정). 탐색기 행은 높이가 균일해
     `offset / cell_h`가 walk와 같은 답을 내고, 행이 수천 개가 될 수 있어 매 프레임 O(n) walk를
     돌릴 이유가 없다. 그 둘이 같은 답이라는 것은 판정자가 `project`와 대조해 고정한다 — 도크는
     카드 높이가 가변이라 walk가 필수이고, 이것은 같은 좌표계의 특수화다.

     **`file_tree_scrollbar`의 도메인도 rows에서 px로 바꿨다.** 상태가 픽셀인데 스크롤바만 행이면
     thumb이 셀 경계로 스냅해 목록과 어긋난다. 비율 산술이라 수식은 그대로이고 이름만 정직해지며,
     SV2b가 `scroll_area.scrollbarGeometry`로 대체할 때 필드가 1:1로 대응한다. 발행·capture 경로는
     아직 `file_tree_scrollbar` 그대로다.

     **사용자에게 보이는 변화 둘.** 트랙패드 스크롤이 행 단위 점프에서 픽셀 스무스로 바뀌고(도크와
     같은 `State.scrollByWheel` 경로), 뷰포트 바닥의 부분 행이 잘린 채로 보인다(예전에는 그 자리에
     배경이 남았다).
  - **SV2b — 스크롤바 이관(완료).** 자식 없는 `tree.scrollArea` 선언이 track/thumb을 내고, 그리기는
     공용 `ui_paint` → `chrome_draw_lowering`이 한다(도크와 같은 경로). `file_tree_scrollbar.publish`와
     전용 capture 경로는 지웠고, **`components/file_tree_scrollbar.zig` 모듈 자체가 사라졌다** — 기하·
     drag·hit 판정이 전부 `ui/scroll_area.zig`에 이미 있었기 때문이다(SV2a-3에서 픽셀 도메인으로 옮겨
     둔 덕에 1:1 대응이었다). 드래그 수명도 host가 들던 세 필드에서 `scroll_area.Drag` 하나로 접혔다.

     `reservedColumns`(텍스트 **셀**을 통째로 빼 track 자리를 만드는 것)는 컨테이너가 소유하는 픽셀
     gutter로 대체됐다. gutter는 스크롤바 유무와 무관하게 상시 예약되므로 목록이 reflow하지 않는다.

     **사용자에게 보이는 변화 둘.** ① track(홈)이 새로 보인다 — 공용 paint가 track도 그리므로 도크와
     같은 모습이 된다. ② 행 오른쪽 여백이 셀 단위 예약에서 픽셀 gutter로 바뀌어 글자가 끝나는 자리가
     달라진다.

     **z가 실제로 움직인 슬라이스다.** 스크롤바가 layer 3(over — 텍스트 **위**)에서 layer 2(bottom —
     텍스트 **아래**)로 건너갔다(§8). 그래서 행 하이라이트 밴드와 같은 버킷이 되고, 밴드 폭을 gutter
     앞에서 끊고 스크롤바를 밴드 **뒤에** append하는 것 둘 다 필요하다 — 판정자가 그 둘을 고정한다.
     남은 z 정리(layer 상수 vs `(layer, z, order)`)는 SV6가 pane·사이드바와 함께 본다.
- **SV3 — 소스 컨트롤 이관.** 탐색기와 같은 행 좌표를 쓰고 스크롤바가 아예 없다. SV2가 만든 픽셀
  경로를 그대로 쓰므로 비용이 가장 작고, 없던 스크롤바가 생기는 것이 사용자에게 보이는 변화다.
  탐색기와 같은 이유로 둘로 나눈다.

  - **SV3a — 픽셀 스크롤 상태(완료).** `scm_scroll_rows: usize` → `scroll_area.State`(픽셀). 창은
     탐색기와 같은 세 값(`start`·`count`·`origin_shift_px`)이고 hit-test·휠이 픽셀을 읽는다.

     **탐색기와 다른 점 하나**: 첫 줄이 **브랜치 헤더**이고 스크롤에서 고정이다. 그래서 뷰포트는
     `tree_content.h`에서 그 한 줄을 뺀 값이고, 헤더는 스크롤 좌표 **밖**이다. 헤더와 목록이 한
     draw list였으므로(`buildDockScmDrawList`가 row 0에 헤더를 그렸다) `head`를 optional로 만들어
     둘로 나눴다 — 그러지 않으면 목록의 픽셀 편향이 헤더까지 끌고 간다.

     clip seam의 role을 `file_tree` → **`dock_list`** 로 일반화했다. 도크 뷰는 한 번에 하나만
     보이므로 프레임당 한 구간인 v147 seam을 탐색기와 소스 컨트롤이 공유한다.
  - **SV3b — 스크롤바 신규(완료).** SV2b가 만든 `scrollArea` 선언을 그대로 써서 없던 track/thumb을
     낸다. 소스 컨트롤은 스크롤바가 **아예 없던** 뷰라, 사용자에게 보이는 변화는 "막대가 생긴 것"이다.

     **두 뷰가 발행 저장소·드래그·interaction을 공유한다.** 도크 뷰는 한 번에 하나만 보이므로 상태를
     뷰마다 두지 않고, `dockListScroll()`이 지금 보이는 목록의 사각형·좌표계·offset을 고른다. 그래서
     이름도 `file_tree_scroll_*` → **`dock_list_scroll_*`** 로 옮겼다 — 두 소비처가 쓰는 상태에
     한쪽 이름을 남겨 두면 다음 소비처(SV4)가 그것을 보고 오해한다.

     **뷰별로 갈리는 것은 셋뿐이다**: 뷰포트 사각형(소스 컨트롤은 헤더 한 줄 아래에서 시작), extent,
     그리고 offset을 적용할 setter. 그 라우팅이 갈리면 **보이지 않는 목록이 스크롤되므로** 판정자가
     "thumb 드래그가 이 목록을 움직이고 탐색기 offset은 그대로"를 본다.
- **SV4 — 사이드바 이관.** 스크롤바가 host의 GPU quad라 발행 경로가 없다. 이관하면 사이드바도
  드래그 가능한 스크롤바를 얻는다(현재 휠 전용).

  **앞의 셋과 성격이 다르다.** 탐색기·소스 컨트롤은 목록 렌더가 `app_session`에 있어 host 안에서
  gutter를 뗄 수 있었다. 사이드바는 이미 제품 컴포넌트(`chrome/components/sidebar.zig`)가 밴드 op을
  내고 그 폭을 `p.metrics.sidebar_width_px` 하나로 정한다 — gutter 예약이 host 안의 산술이 아니라
  **그 컴포넌트의 계약 변경**이 된다. 그래서 둘로 나눈다.

  **layer는 3(over)으로 남는다(2026-08-08 실측 정정).** 처음에는 탐색기처럼 공용 lowering이 내는
  layer 2를 그대로 쓰려 했는데, 그러면 막대가 **화면에서 사라진다** — 렌더러가 layer 2 버킷을 맨 처음
  그리고 그 위에 자기가 소유한 사이드바 배경 strip을 덮기 때문이다(`docs/metal-ui-layout.md` §5의
  승인된 예외). 도크·탐색기 스크롤바가 layer 2로 살아남는 것은 그 자리에 strip이 없어서지 layer 2가
  안전해서가 아니다. 그래서 lowering 뒤에 fade alpha와 함께 layer도 되돌린다. gutter는 그래도
  유지한다 — 막대가 카드 텍스트와 겹치지 않는 것은 별개의 이득이다.

  - **SV4a — 발행 경로(완료).** `appendSidebarScrollbar()`가 손으로 만드는 GpuQuad를 `tree.scrollArea` 선언
    + `ui_paint` + `chrome_draw_lowering`으로 교체하고, `sidebar.view`가 밴드 폭에서 gutter를 예약한다.
    **보이는 변화**: 카드 밴드가 gutter만큼 좁아진다(스크롤바가 나타나고 사라져도 폭은 안 변한다 —
    상시 예약이 [ScrollArea](scroll-area.md) §4의 규율이다).
  - **SV4b — 드래그(완료).** capture를 붙여 잡아 끌 수 있게 한다. **판단**: 사이드바와 도크 목록은 **동시에
    보이므로** 발행 저장소는 각자 둔다. 그러나 한 번에 하나만 잡히므로 capture·`scroll_area.Drag`는
    공유하고 어느 쪽을 잡았는지만 태그한다 — SV3b가 상태까지 합친 근거("도크 뷰는 한 번에 하나만
    보인다")는 여기 적용되지 않는다. 근거가 다르면 결론도 다르게 적는다.
- **SV5 — 알림·팔레트·세팅(흡수하기로 결정, 2026-08-08).** 셋은 이미 `overlay_input.windowStart`로
  item-index windowing을 공유한다. 흡수 여부는 SV1~SV4를 마친 뒤 정하기로 미뤄 뒀고, 이제 정했다 —
  결론과 **반대 근거까지** [ScrollArea](scroll-area.md) §SV5에 적었다(팔레트·세팅은 지금 스크롤 상태가
  0개라 흡수가 상태를 **만드는** 쪽이다. 그럼에도 스크롤바와 일관성을 택했다).

  셋으로 나눈다. 각 슬라이스는 **없던 스크롤바가 생긴다**는 것을 PR에 명시한다 — 순수 refactor가 아니다.

  - **SV5a — 알림 패널.** 셋 중 유일하게 스크롤 상태가 있다(카드 index). 그것을 픽셀로 옮기고
    스크롤바·드래그를 얻는다. 카드 단위로 넘기던 감각이 바뀌므로 **보이는 변화가 가장 크다**.
  - **SV5b — 팔레트. 상태를 만들지 않는다(2026-08-08 정정).** [ScrollArea](scroll-area.md) §SV5는 이
    슬라이스가 "없던 픽셀 offset을 만든다"고 적었는데, 코드를 읽어 보니 **표시만 하는 한 만들 필요가
    없다.** 팔레트는 `win_start`를 selected에서 매번 재파생하므로 스크롤바에 필요한 셋이 전부 그
    파생값으로 나온다 — `offset_px = win_start × ch`, `content = total × ch`, `viewport = visible × ch`.

    **드래그를 붙이는 순간에만 상태가 필요하다.** 막대를 끌면 offset이 selected와 무관하게 움직여야
    하므로 그때는 저장해야 한다. 그 필요가 실제로 확인되기 전까지는 만들지 않는다 — 흡수의 비용으로
    미리 걱정했던 것이 사실은 **선택 가능한 비용**이었다.

    **스크롤바는 host가 `tree.scrollArea`로 발행한다(2026-08-08 결정).** 컴포넌트가 `total`·`offset`을
    받아 자기 막대를 그리는 안도 검토했지만, 그러면 스크롤바 모양·기하가 컴포넌트마다 한 벌씩 남아
    이관의 목적("스크롤바를 한 곳에서 소유한다")과 정반대가 된다 — SV5a의 알림 패널이 지금 그 상태이고,
    거기서 고친 thumb 비율 버그가 그 복제본 때문에 생긴 것이다. 오버레이 셋은 **한 번에 하나만
    열리므로**(모달) SV3b가 탐색기↔소스 컨트롤에서 쓴 것처럼 발행 저장소·drag·interaction을 통째로
    공유하고 어느 오버레이인지만 라우팅한다.

    **선행 확인 결과(코드로 확정, 2026-08-08)**: 공용 lowering이 내는 **layer 2는 안 된다.** 렌더러는
    layer 2를 터미널 pass 맨 처음에 그리고, 오버레이 pass가 그 위에 모달 배경 quad를 통째로 덮는다
    (`maru_metal_renderer.m`의 오버레이 순서: 그림자 → over quad → 모달 텍스트 셀 → caret). 그러니
    SV4와 같이 lowering 뒤에 **layer를 over 버킷으로 되돌린다**. 사이드바에서는 렌더러 소유 배경
    strip이, 여기서는 모달 배경 quad가 덮는다 — 원인은 달라도 처방은 같다. 실제 화면 확인은 구현 후
    한 번 더 한다(코드만 보고 틀린 전례가 이번 묶음에만 넷이다).
    **gutter를 컴포넌트가 손으로 빼는 것은 임시다(2026-08-08 기록).** 팔레트는 `overlay_input.panelLayout`
    으로 레이아웃을 손계산하므로, 스크롤바 gutter를 쓰는 요소(선택 밴드·우측 정렬 단축키)가 각자 그 폭을
    빼야 한다 — 하나라도 빠뜨리면 그 요소만 막대를 덮는다(실제로 두 번 그렇게 나갔다). 그래서 view 안에
    `usable_cols`를 **단일 출처**로 두어 그 파일 범위에서는 빠뜨릴 자리를 없앴다.

    **장기 정답은 오버레이도 `chrome/ui` 레이아웃 트리를 쓰는 것이다.** 레퍼런스 레이아웃 엔진(taffy)은
    `overflow: scroll`인 노드의 가용 공간에서 `scrollbar_width`를 **엔진이** 빼고 그 결과를
    `scrollbar_size`로 실어 준다(CSS `scrollbar-gutter`와 같은 모델) — 컴포넌트는 "내가 비켜야 한다"를
    알 필요가 없다. 우리 `chrome/ui/layout.zig`도 이미 border box·content box를 구분하고 `tree.scrollArea`가
    `gutter_px`를 예약하므로, **메커니즘은 이미 있고 오버레이만 그것을 안 쓰고 있다**(`docs/metal-ui-layout.md`
    ML6가 목표로 적어 둔 그 미완이다).

    `panelLayout`에 `content_cols`를 더하는 중간안도 검토했으나 접었다 — layout 엔진이 이미 가진 개념을
    오버레이용으로 한 벌 더 만드는 것이고, find처럼 스크롤바가 없는 소비처까지 그 필드를 갖게 된다.
    **세팅(SV5c)에서 같은 문제가 재현되면 그때가 세 번째 소비자**이니, 오버레이 레이아웃 이관을 정식
    슬라이스로 올린다(이 저장소가 `ClipPx` 주석에서 쓴 것과 같은 기준).
  - **SV5a-2 — 알림 스크롤바 이관.** SV5a는 스크롤 **좌표**만 픽셀로 옮겼고 막대는 여전히 컴포넌트가
    손수 그린다. SV5b가 만드는 공유 발행 경로에 알림도 얹어 그 복제본을 지운다.
  - **SV5c — 세팅(완료).** 팔레트와 같은 형태이되 뷰포트는 **컴포넌트가 준다**(`settings.scrollView`) —
    폼 폭이 nav·control·↺ 여백에 얽혀 있어 host가 다시 계산하면 두 벌이 갈린다.

    **팔레트의 흩어짐은 여기서 재현되지 않았다(2026-08-08 확인).** 세팅은 폼 폭이 `form_cols` 한 곳에서
    정해지고 `reset_gutter_cols`를 빼는 패턴을 이미 갖고 있어, 스크롤바 gutter를 그 자리에 한 번 더
    얹으니 control·↺ 위치가 자동으로 따라왔다. 그래서 **오버레이 레이아웃 이관(ML6)은 올리지 않는다** —
    "세 번째 소비자에서 재현되면 일반화한다"는 기준을 그대로 따른 결과다. 손계산이 흩어진 곳은 팔레트
    하나뿐이라는 사실만 남긴다.
  - **SV5d — 오버레이 휠·드래그(상태 도입).** 팔레트·세팅은 원래 휠 핸들러가 **없었고**(↑↓ 선택 이동으로만
    창이 움직였다) 막대도 표시 전용이다. 휠과 드래그는 선택과 무관하게 목록을 움직이므로 **offset을
    저장해야 한다** — SV5b가 "필요가 확인되기 전까지 만들지 않는다"고 미뤄 둔 그 상태다. 사용자가
    붙이기로 결정해(2026-08-08) 그 필요가 확인됐다.

    **selection follow는 값 비교다 — 장기 답은 아니다(2026-08-09 기록).** 선택이 바뀌면 창을 당겨야
    하는데, 그 "바뀜"을 `.selection_changed` 액션으로 잡으려다 실패했다. 선택은 그 액션 말고도 **쿼리
    필터**(`recomputePalette`가 `selected = 0`으로 되돌린다)·섹션 전환 등 여러 경로에서 바뀌고, 그
    목록을 host가 열거하면 새 경로가 생길 때 조용히 빠진다(증상이 "휠로 굴린 뒤 검색어를 고치면 창이
    안 따라온다"처럼 좁아 늦게 발견된다). 그래서 렌더 직전 `followed_selected`와 **값을 비교**한다 —
    경로를 묻지 않는다.

    그 비용은 소비처마다 파생 필드가 하나씩 는다는 것이고, "무엇이 바뀌었나"를 값으로 재구성한다는
    점에서 이 저장소가 반복해 밟은 함정(사실과 그 표현이 갈리는 구조)과 같은 계열이다.

    **"setter로 모으면 된다"는 답은 검증에서 무너졌다.** 그 안에서 follow를 부르려면 창을 계산할 재료
    (`sections`·`rows`·`props`·`tokens`)가 그 자리에 있어야 하는데, 세팅의 선택은 컴포넌트 `handle()`
    안에서 바뀌고 그 함수는 재료를 받지 않는다. 결국 setter는 "바뀌었다" 플래그만 세우고 렌더 직전에
    그걸 보게 되는데, 그건 **값 비교와 구조가 같으면서** 세우기/지우기 두 곳이 어긋날 여지가 더 있다.
    값 비교는 값이 곧 진실이라 그 실패 모드가 없다.

    **그래서 값 비교가 지금 구조에서 옳다.** 이를 넘어서려면 선택과 재료가 같은 자리에 있어야 하고,
    그건 오버레이 레이아웃을 `chrome/ui` 트리로 옮기는 것(ML6)이 전제다 — 컴포넌트가 창 계산에 필요한
    것을 스스로 갖게 되는 그때 사건 기반이 성립한다.

    **매 프레임 당기면 안 된다.** 처음에 "키 경로를 안 빠뜨려 견고하다"며 무조건 당기게 했는데, 선택이
    맨 위에 있으면 휠로 굴린 offset이 한 프레임 만에 0으로 되돌아가 **휠이 통째로 무효화됐다**(제품에서
    실측). 팔레트·세팅이 원래 `windowStart(prev=0)`로 매 프레임 창을 재파생하던 구조였고, 상태를
    도입하면서 그 호출 빈도를 검토 없이 이어받은 것이 원인이다.

    상태는 오버레이 셋이 **공유**한다(한 번에 하나만 열린다 — 발행 저장소와 같은 근거). selection follow는
    그대로 남되, offset이 저장되므로 "이미 창 안이면 움직이지 않는다"가 의미를 갖는다(알림이 SV5a에서
    쓰는 규칙과 같아진다).

  **오버레이 layer·clip을 먼저 확인한다.** 셋 다 모달 셀 경로를 지나므로 스크롤바 quad가 공용 lowering의
  layer 2로 살아남는지 **실측**한다. 사이드바에서는 렌더러가 소유한 배경 strip이 그것을 덮어 막대가 아예
  안 보였고, 그 사실은 헤드리스 단언이 전부 green인 채로 화면에서만 드러났다.
- **SV6 — z 축 정리(판단은 이관 중, 변경은 별도 슬라이스).** 정렬 축 변경은 lowering을 지나는 모든 quad
  소비자에 영향을 주므로 "시각 무변경"이 완료 기준인 이관 단계와 같은 PR에 넣지 않는다. 자기 게이트
  (모달·툴팁·스크롤바가 겹치는 화면의 골든)와 비용 측정을 함께 낸다. `GpuQuad.layer`는 닫힌 enum이 아니라 이미
  스크롤바 전용 layer 3이 추가된 상태이고, Session Dock 스크롤바만 layer 2에 나와 같은 역할이 두 층에
  흩어져 있다. 스크롤바 층을 layer 상수로 계속 표현할지, `(layer, z, order)` stable sort로 옮기고
  layer는 합성 패스 의미만 남길지를 이관과 함께 정한다.
  - **SV6a — 공용 lowering이 layer를 받는다(완료).** `appendBackgroundQuads`가 layer 2를 고정 출력해
    소비처 둘이 뒤에서 되돌리던 것을 없앴다. 인자로 받고 호출자가 명시한다(기본값 없음).
  - **SV6b — 오버레이 quad를 프레임 끝에 flush한다(완료).** 계획했던 "발행 순서 규약"은 대상이 없었다
    (이미 한 자리에서 순서대로 나오고 있었다). 실제로 깨져 있던 것은 sticky 배너 구분선(layer 3)이
    오버레이보다 **뒤**에 나와 열린 오버레이 위에 그어지는 것이었고 — find 바 상단과 정확히 같은 행이다 —
    구분선 좌표가 `placeAndDistribute` 뒤라야 나오므로 오버레이를 늦추는 쪽으로 고쳤다. `overlay_quads`
    대기 버퍼가 순서를 규율 아닌 구조로 만든다. 판정자는 `gpu_quads` 꼬리 == `overlay_quads`.
  - **전역 `(layer, z, order)` 정렬은 하지 않는다.** 근거와 재개 조건은 [ScrollArea](scroll-area.md)가 소유한다.

**탭 바(가로 스크롤)는 이 순서에 없다.** 컬럼 좌표·‹› 버튼 affordance·`Pane.tab_scroll_cols` 소유자가
모두 다르므로, 세로 목록을 모으는 것과 가로 축을 여는 것은 별개의 결정이다.

각 단계는 앞 단계의 계약을 넓히기만 하고 바꾸지 않는다. 바꿔야 하면 [ScrollArea](scroll-area.md)를
먼저 고친다.

## 네이티브 편집기 (설계 완료 — 구현 미착수)

계약은 [native-editor.md](native-editor.md)가 소유한다. 여기서는 **순서와 각 단계의 출하 가능 여부만** 정한다.
2026-08-09 사용자 결정으로 `text` kind와 diff 본문을 CM6에서 Zig+Metal로 이관하며, 마크다운 렌더는 웹에 남는다.

- **N0b — 시각 기준 수령(코드 변경 없음).** [file-panel.md](file-panel.md) §1·[editor-surface.md](editor-surface.md)
  §3.5가 목업을 받아 배치를 확정한 것과 같은 절차다(native-editor.md §1.1).
  - **N1 몫은 해소됐다(2026-08-09 사용자 결정 — "VSCode 기준으로 한다").** gutter 요소 순서·폭, 본문 여백,
    상태바 우측 항목 순서를 VSCode 소스에서 확인해 **native-editor.md §4.1에 계약으로 적었다**(glyph margin →
    줄 번호 → decorations → 본문, 줄 번호 최소 5자리, git 마커와 접기 화살표가 같은 영역, 상태바는 커서
    위치 → 들여쓰기 → 인코딩 → 줄바꿈 → 언어). **목업 없이 N1에 들어갈 수 있다.**
  - **남은 것은 셀 환산 하나**다. Monaco는 px와 `ch`(문자 폭 배수)를 함께 지원하는데 우리 gutter는 셀 격자에
    서므로 decorations 폭을 셀 수로 정해야 한다. §4.1이 **2셀**(접기 화살표 + 여백)을 기본 후보로 두었고
    **N1에서 실제 화면을 보고 확정**한다 — 목업 수령이 아니라 구현 중 판단이다. git 마커는 폭을 먹지 않으므로
    (기존 `GutterMark` 세로 바 재사용) 셀 배정 대상이 아니다.
  - **뒤 단계 몫은 그대로 남는다**: diff 좌우 배치는 N1.5 전, 호버 박스와 미니맵 폭은 N4~N5 전. 색은 이미
    확정이라(`syntax_theme.zig` 파생) 목업 대상이 아니다.
- **N0c — 기존 구현 대조(코드 변경 없음).** 각 슬라이스 착수 전에 **그 기능을 이미 만든 CM6 코드를 읽고 계약과 대조**한다.
  설계만으로는 안 보이던 것이 거기 있다 — 실제로 이 단계를 diff에 먼저 해 본 결과 `web/src/diff-view.ts`에서
  **본문 화면의 네 상태**(읽는 중·보여 줄 수 없음·변경 없음·비교)·**무한 재시도 금지**·**내부 값 노출 금지**·
  **"jsdom은 iframe·CSS가 없어 레이아웃 결함을 못 잡는다"**는 교훈이 나왔고 전부 native-editor.md에 반영했다.
  대조 대상: `diff-view.ts`·`diff-layout.ts`·`diff-theme.ts`(diff — **완료**), `editor.ts`(소스 편집 — **완료**:
  문서 가상화 탓에 브라우저 native 선택이 렌더된 줄만 덮어 ⌘A 후 삭제가 일부만 되던 결함을 발견해 §3.2·§10에
  반영), `content-menu.ts`·`file-panel-state.ts`(**완료** — 브리지 소멸·revision 단조 시계가 이미 계약에 반영돼 있음을
  확인). **"옮긴다"가 아니라 "무엇을 이미 풀었는지 확인한다"**가 목적이다 —
  코드 표현을 옮기지 않는다([project-rules.md](project-rules.md) clean-room은 외부 레퍼런스 규율이고 이쪽은
  우리 코드지만, 웹 전제(iframe·CSS·브리지)에 묶인 해법을 그대로 가져오면 네이티브에서 틀린 구조가 된다).
- ~~**N0 — 성능 baseline**~~ **철회(2026-08-09 사용자 결정).** CM6 대비 계측 하니스를 세우는 것이 이 작업 대비
  과하다고 판단해 **단계를 없앤다**. 착수 전 성능 게이트는 없으며 N1이 첫 단계다. 대신 성능을 이관 근거·성과에서
  뺐고(native-editor.md §1.0), "빨라졌다"를 문서·PR에 쓰지 않는다. 큰 파일·초장문 줄의 축소 임계는 baseline 없이도
  서는 장치라 그대로 두되 값은 해당 슬라이스에서 정한다(native-editor.md §10).
- **N1 — 읽기 전용 등폭 뷰.** 화면에 파일이 뜬다.

  **진행 상황(2026-08-10)**: 골격이 섰고 **계약의 절반 이하가 구현됐다.** "N1 완료"가 아니다.

  | 구현됨 | 남음 |
  |---|---|
  | `line_index`(byte↔논리행) · `geometry`(§4.1 영역 분할) · `gutter`(줄 번호) · `content`(본문·탭 전개) · `viewport`(스크롤·컬링) · **`hazard`(§3.8 가시화 — BiDi·제어·폭 0·비표준 공백)** | §3.8의 나머지(초장문 줄 축소·중첩 상한 — 각각 랩·접힘과 함께) · 랩과 랩 토글 · 접힘과 전체 접기/펼치기 · 줄별 폭 합(L2 캐시) · 스크롤바 · 상태바 커서 위치(`ItemId` 확장) · 선택 하이라이트 · 파일 입출력 실제 배선 |

  **§3.8의 가시화는 구현됐다**(2026-08-10). BiDi·제어·폭 0·비표준 공백 문자가 `<U+202E>` 표기로 드러나고 시각 골든이 그것을 고정한다 — 그 절이 "읽기 단계부터 필요하다"고 명시한 Trojan Source 방어가 이것이다. **남은 §3.8 둘**(초장문 줄 축소·깊은 중첩 상한)은 각각 랩·접힘이 있어야 의미가 있으므로 그 슬라이스와 함께 간다(계약도 "임계값은 랩·토큰화를 만드는 슬라이스에서 정한다"고 적었다).

  랩·접힘은 §4가 "단계를 끼울 자리"를 정의해 두었으므로 `Row` 입력이 시각 매핑 결과를 받도록 바꾸면 되고, 그때 `visual_map.zig`가 생긴다.

  - **N1에서 만들되 아직 연결되지 않는 것 둘**: `selection.zig`(§3.2)와 `document.zig`(§3.5)는 계약이
    요구하는 구조라 여기서 세우지만, **읽기 전용 뷰에는 커서도 저장 경로도 없어 소비처가 없다.**
    헤드리스 테스트로만 검증되고 캡처에는 나타나지 않는다 — 실제 연결은 N2(편집)다. 같은 이유로
    §4.1의 진단 마커 자리(`leading_margin`)도 폭만 잡고 그리는 소비자가 없다(N4). **여기까지가 diff 본문의 전제**이고, 편집·IME를 건드리지 않아
  터미널 회귀 위험이 없다. 계약 절과의 대응:
  - **L2 모델**: 버퍼(rope, §3.0)·논리행 인덱스·줄별 폭 합(탭스톱 포함, §4)·byte offset 위치 축(§3.1)·
    읽기 전용 selection(§3.2의 배열 구조는 여기서 이미 선다)
  - **파일 입출력 계약**: 인코딩·줄바꿈·BOM·파일 끝 개행 보존, 읽기 전용 파일(§3.5)
  - **적대적 입력**(§3.8): BiDi 제어 문자 가시화·제어/비출력 문자 가시화·초장문 줄 축소·깊은 중첩 상한.
    **읽기 단계부터 필요하다** — 검토 대상이 에이전트가 만든 코드이므로 "보이는 것과 실제가 다르면 안 된다"가
    N1의 요구다
  - **L3 매핑**(§4): 뷰포트·랩(가로 스크롤 기본, 랩 토글)·**접힘**(들여쓰기 기반이라 lexer 없이 동작)·
    **줄 번호 규칙**(랩된 시각행에 반복 안 함·접힘은 건너뜀)·전체 접기/펼치기
  - **표시**: gutter(줄 번호)·스크롤바·**상태바 커서 위치**(§2.2, `ItemId` 확장 시작)·선택 하이라이트
  - **스레딩**(§2.1): 랩 재계산 분리. **창 리사이즈 중 매 프레임 발생하므로 N1에서 이미 필요하다**
  - **탭 계약**: 파일 Term을 `RenameTarget.term`에서 **제외**(§2.3)
- **N1.5 — git diff 본문(읽기 전용, native-editor.md §7).** 좌우 배치·세로 동기·추가/삭제 배경(`diffFromTheme`)·
  변경 없는 영역 접기(§4 접힘 재사용)·**문자 단위 강조**(줄 단위 차이는 git이 주고 intra-line은 이 단계가 계산)·
  diff Term은 workspace에 저장하지 않음.
  **이 문서의 첫 제품 가치가 여기서 나온다**([editor-surface.md](editor-surface.md) §1: "첫 제품 가치는 에이전트가
  만든 변경을 사용자가 Maru 안에서 검토하는 것"). **편집·IME·토큰이 전혀 필요 없다** — diff는 읽기 전용이고
  syntax 색이 없어도 성립한다(추가/삭제 배경이 diff의 언어다). 목록은 이미 GPU chrome이므로
  ([editor-surface.md](editor-surface.md) §3.5) 이 슬라이스로 **검토 흐름 전체가 네이티브로 닫힌다.**
  - **순서를 이렇게 두는 이유**: diff를 마지막에 두면 제품 가치가 가장 늦게 나오고, 그때까지의 슬라이스는
    전부 "아직 쓸 수 없는 중간물"이 된다. 반대로 여기 두면 **N1.5에서 한 번 멈춰도 제품이 온전하다.**
- **N2 — 편집.** **버퍼 표현은 확정이 아니라 1순위 후보이며, 구현 전에 실측해 다시 고른다**(2026-08-10 사용자 결정 — native-editor.md §3.0). 초판이 "rope 확정"이라 적은 근거가 자기 모순이었고(멀티 커서로 돌렸는데 같은 절이 "piece table이 멀티 커서를 못 해서가 아니다"라고 인정한다), Zed 선례는 그쪽 근거이지 우리 측정이 아니다.
  - **착수 게이트**: rope와 piece table을 최소 둘, 같은 워크로드·빌드 모드에서 재고 기기를 병기한다. 중간 삽입/삭제·스냅샷 생성 비용과 그것을 든 채의 메모리·byte↔논리행 조회·큰 파일 최초 로드. **결과가 rope가 아니면 rope를 버리고 문서를 고친다.**
  - **`line_index.zig`의 운명도 그때 정한다** — 트리에 줄 수를 다는 구조를 고르면 흡수되고, 별도 인덱스를 유지하는 구조면 남는다.
  - **N1에서 buffer를 만들지 않은 이유가 이것이다.** 읽기 전용이라 슬라이스로 충분했고, 표현을 정하기 전에 인터페이스를 지으면 추측이 된다(selection은 VSCode 소스로 구조를 검증하고 지었지만 buffer는 그런 검증이 없다).
  - 위 게이트를 통과한 뒤 undo(delta, §3.3)와 함께 **구현과 프로파일 검증**을 한다.
  계약 절과의 대응:
  - **커서와 선택**(§3.2·§3.9): 멀티 selection 배열·primary 승계·커서 병합·goal column, 그리고
    **이동/삭제 일습** — 문자·단어·줄 처음/끝(smart home)·문서 끝·페이지·괄호 짝 점프, 문자/단어/줄 단위 삭제.
    **"2D caret" 한 줄로 뭉뚱그리지 않는다** — 이것들이 빠진 빌드는 §1.1 기준을 만족하지 못한다
  - **undo/redo**(§3.3): delta·그룹핑·selection 복원
  - **클립보드**(§3.4): 멀티 커서 분배 규칙·줄 단위 복사
  - **타이핑 보조**(§3.7): 괄호/따옴표 자동 닫기·type-over·surround·주석 토글
  - **검색/바꾸기**(§5.1): find 오버레이 `Target` 확장 + **바꾸기 입력 필드 추가** + 스크롤바 결과 마커
  - **컨텍스트 메뉴**(§8.1): 편집기 대상 항목
  - **설정**(§9): 폰트 크기·탭 폭·랩 토글 + **런타임 크기 조절**
  - **렌더 ABI**: 커서 blink 단일 구간 전제를 **배열로 확장**(§1.1의 회귀 이력 주의)
  - **상태바 확장**(§2.2): 선택 크기·들여쓰기·인코딩 항목
  - **미저장 내용 백업**(§3.10): 전체 내용 + fingerprint를 debounce/종료 시 기록, 복원 시 fingerprint 비교.
    **편집·dirty가 서는 이 단계가 자리다** — 그 전에는 백업할 미저장 상태 자체가 없다
  - **같은 파일 두 곳에서 보기**(§2.4): "나눠서 보기" 명시 명령으로 두 번째 Term 생성 + 뷰 상태 분리
    (버퍼·undo·revision·dirty 공유 / selection·스크롤·랩·접힘 독립) + **뷰 하나를 닫을 때 dirty 확인 안 함**.
    `file-panel.md` 불변식 예외 추가가 같은 슬라이스에 든다(아래 표). **여기 두는 이유**: 편집·undo가 서면
    "문서 하나를 두 뷰가 공유한다"를 실제로 검증할 수 있고, 그 전에는 읽기만이라 공유 여부가 드러나지 않는다
  - **키 충돌 전수 조사가 N2 안에 있다**(native-editor.md §9.1). 편집기 액션이 확정되는 시점이라 여기서 기존
    `default_app_bindings`와 교차 대조한다. **확인된 충돌 하나: `⌘D`**(Maru=pane split, VSCode=다음 일치 추가) —
    둘 다 정당한 기능이므로 한쪽을 옮기는 결정이 필요하고, 소유는 `key-input-and-shortcuts.md`다.
  - **검색·타이핑 보조를 N2에 넣는 이유(선행 검토 결과)**: 둘 다 §1.1의 "VSCode 사용자 무회귀" 기준선이라
    뒤로 미루면 그때까지 나온 빌드가 **매일 쓰는 동작이 빠진 상태**가 된다. 검색은 편집 모델만 있으면 되고
    (일치 계산은 L2 순수), 타이핑 보조는 lexer 없이도 저하 동작이 가능하다(§3.7) — 즉 **N4를 기다릴 이유가
    없다.** 검색 결과 위치 표시는 풀 overview 스트립 대신 **스크롤바 마커**로 최소 구현하고, 스트립은 미니맵
    렌더 경로를 재사용할 수 있는 N5에서 올린다.
- **N3 — IME.** `NSTextInputClient`의 `replacementRange`·`markedRange`·`selectedRange`를 실제 위치로 확장한다.
  **터미널이 쓰는 바로 그 경로라 최대 리스크**이며 GUI 손 테스트가 유일 안전망이다. 멀티 커서 × IME 정책도 여기서
  실측으로 정한다(native-editor.md §11).
- **N4 — 토큰과 LSP 표시.** 미니맵이 lexer 층에 의존하므로 N5보다 앞선다. 계약 절과의 대응:
  - **토큰**(§5·§5.3): **tree-sitter 1층**(런타임 배선 + `init`/`onEdit`/`spansForRange` provider) → LSP semantic
    tokens 층(보이는 범위 요청, 부분 덮기). N1.5에서 이미 뜬 diff 본문에 syntax 색이 여기서 얹힌다. 트리가 서면
    §3.7 타이핑 보조·§3.9 괄호 점프·§4 접힘이 문맥/구문 인지로 **정확해진다**(N2의 저하 동작에서 승격)
  - **tree-sitter 도입에 딸린 일**(2026-08-09 사용자 결정): `build.zig` C 컴파일 배선 · **번들 언어 명시 목록
    확정**(grammar마다 `parser.c`가 붙어 배포물이 커진다 — 열린 집합으로 두지 않는다) · grammar별 **라이선스 확인
    후** [third-party-licenses.md](third-party-licenses.md) 표 갱신 · 파싱 상한과 파서 실패 격리(§5.3) ·
    전 문서 파싱을 렌더 루프에서 분리(§2.1)
  - **grammar가 없는 파일은 무색이다**(§5). 자체 lexer fallback을 만들지 않는다
  - **진단**(§5): 물결 밑줄(기존 밑줄 장식 확장)·gutter 마커. 출처가 LSP든 CLI 린터든 한 층
  - **레이아웃을 바꾸는 LSP 결과**: 인레이 힌트·ghost text(§4 가로 축)·code lens(세로 축)·
    LSP `foldingRange`가 들여쓰기 접힘을 덮음(§4)
  - **떠 있는 UI**: 자동완성 팝업(§8.2 — `dropdown` 재사용)·**호버/시그니처 박스**(§8.3 — 신규, 마크다운 최소
    서식 해석)
  - **네비게이션**(§5.2): 정의로 이동·진단 클릭·심볼/줄로 이동을 한 경로로. 되돌아가기 스택. root 밖 URI 권한 판정
  - **외부 편집 적용**(§3.6): 포맷·code action·자동완성 `additionalTextEdits` — undo 하나·커서 보존·revision 검증
  - **상태바 확장**(§2.2): 언어 항목
- **N5 — 미니맵·overview 스트립.** 미니맵(§6 — 전 문서 대상, lexer 층만, L2 폭 합 캐시 직접 읽기, 색 블록 quad)과
  overview 스트립(N2의 스크롤바 마커를 미니맵 렌더 경로로 승격). diff **목록**(도크 소스 컨트롤 뷰)은
  [editor-surface.md](editor-surface.md) §3.5 소유라 이 순서 밖이고, diff **본문**은 N1.5로 앞당겼다.

**모든 단계에 걸치는 축 둘.** 특정 슬라이스에 속하지 않고 각 단계에서 함께 처리한다.

- **관측 가능성**(native-editor.md §10.1): 그 단계가 만든 저하 동작·분리 작업의 event를 함께 낸다. 문서 내용은
  trace에서 제외하고, GPU 프레임 캡처가 소스를 담는다는 점에 기존 redaction 규율을 적용한다.
- **저하 동작의 사용자 표시**(§2.2·§3.0): 각 단계가 도입한 기능 축소(큰 파일·계산 중)를 상태바로 알린다.
  **조용히 줄어드는 것을 그 단계의 완료로 보지 않는다.**

### 네이티브 편집기 후속 (N5 이후 — 계약 밖이거나 다른 문서 소유)

native-editor.md §12가 "이 계약 밖"으로 둔 것들의 **구현 순서와 소유처**다. 선행 여부를 함께 검토했다.

| 항목 | 선행 검토 | 소유 |
|---|---|---|
| **호버·시그니처 힌트의 내용 정책** | **N4에 붙인다** — LSP가 선행이고, 표시 자리는 §8이 이미 계약해 뒀으므로 증분이 작다. VSCode 사용자가 매일 쓰는 축이라 뒤로 밀면 체감이 크다 | native-editor §8 + LSP |
| **overview 스트립**(검색·진단 마커 열) | **N5에 흡수** — 미니맵 quad 렌더를 재사용하면 거의 공짜다. 그 전까지는 N2의 스크롤바 마커가 최소 기능을 덮는다 | native-editor §6 확장 |
| **sticky scroll** | N5 이후. 접힘 매핑(N1) 위에 얹히고 들여쓰기만으로도 1차 구현이 가능하다 | native-editor §4 확장 |
| ~~같은 파일 두 곳 보기~~ | **N2로 이동**(2026-08-09 사용자 결정 — native-editor §2.4). 후속이 아니라 계약 안이다 | — |
| **프로젝트 전체 검색** | 별도 슬라이스. 결과 목록·진행률·취소·바꾸기 미리보기가 필요해 **도크 뷰**가 선행한다(소스 컨트롤 뷰와 같은 컬럼) | editor-surface §3.5 계열 |
| **참조 찾기·심볼 아웃라인** | 별도. LSP + 목록 UI라 위와 같은 도크 배관을 공유한다 | editor-surface + 도크 |
| **저장 시 자동 포맷/린트 fix**(Prettier·oxfmt·`oxlint --fix` 등) | **N4 이후.** N4가 §3.6의 text edits 적용 규칙(undo 하나·커서 보존·revision 검증)을 먼저 세워야 한다 — 그 전에 자동 포맷을 켜면 저장할 때마다 커서가 날아가고 undo가 쪼개진다. **보안 단계가 더 큰 이유다**: PoC가 `Prettier config import가 임의 JS를 실행함`을 실측했고, 자동 실행은 사용자가 명시적으로 부르는 것이 아니라 **저장마다** 도는 것이라 `tool_execute` grant 판정이 선행한다 | editor-surface §8.1(도구 실행) + 저장 경로 |
| **구조 기반 선택 확장** | tree-sitter가 N4에 들어오므로 **기술적 장벽은 없고 소비처만 없다**. 계약 안으로 올릴지는 별도 판단 | native-editor §12 |
| **번들 언어 확대** | grammar 추가마다 배포물이 커지고 라이선스 확인이 붙는다. **언어 하나씩 판단**하며 목록은 이 문서가 소유 | third-party-licenses.md |
| **접근성(VoiceOver)** | 독립이되 **편집기 전용이 아니다** — 터미널도 GPU 렌더라 같은 상태이므로 앱 전체 축으로 다룬다. 완전 신규도 아니다: `chrome-interaction-migration.md`가 "Zig는 semantic descriptor만 내고 Swift가 native accessibility element로 투영"하는 패턴을 이미 정해 뒀다 | chrome-interaction-migration + 별도 |
| **CJK 금칙 처리·UTF-8 외 인코딩·virtual space·modal editing** | 하지 않기로 한 것들 | — |

**선행으로 끌어올린 셋**: 문서 내 검색, 괄호/주석 토글, 스크롤바 검색 마커 → 전부 **N2**로 옮겼다(위 N2 항목). 근거는 "VSCode 사용자 무회귀"가 §1.1의 확정 기준이고, 이 셋은 LSP를 기다릴 필요가 없기 때문이다.

**chrome 이관(CIM)과의 관계 — 선행 조건이 아니다.** [chrome-interaction-migration.md](chrome-interaction-migration.md)의
점진 이관은 이 순서와 **독립**이며, 그 완료를 기다리지 않는다. 근거는 **N1.5까지 레거시 컴포넌트 의존이 사실상
없다는 것**이다(native-editor.md §2.0) — `divider`·`find`는 이주 완료, `scroll_area`·`status_bar`는 신규 세대,
본문·diff 배치는 어차피 신규다. 레거시 접촉(`context_menu`·`dropdown`)은 N2·N4로 밀려 있어, 그 사이 이관이
도착하면 새 형태에 붙고 안 오면 붙였다가 함께 움직인다. **동시 진행 시 편집기 쪽 변경은 확장에 한정**한다.

### 네이티브 편집기 — 함께 갱신해야 하는 다른 문서

`native-editor.md`가 **"저 문서가 소유한다"고 가리키지만 그 문서는 아직 편집기를 모르는** 지점들이다. 각 단계 PR에서
[pr-checklist.md](pr-checklist.md) "문서 정합성"에 걸리므로 미리 적어 둔다.

| 문서 | 필요한 갱신 | 단계 |
|---|---|---|
| [status-bar.md](status-bar.md) | §4 "지금 있는 항목"에 편집기 행 추가 — 커서 위치·선택 크기·인코딩/줄바꿈·언어·읽기 전용·**저하 상태**. 폭 부족 시 버리는 순서에서 저하 상태를 앞쪽에 둔다(native-editor §2.2) | N1(위치)·N2(선택)·N3 이후(나머지) |
| [key-input-and-shortcuts.md](key-input-and-shortcuts.md) | 편집기 포커스 시 키 라우팅과 **`⌘D` 충돌 해소**(native-editor §9.1) | N2 |
| [file-panel.md](file-panel.md) §1 (탭 계약) | **파일 Term을 `RenameTarget.term`에서 제외**한다. 현재 "파일 탭은 터미널 탭 계약을 그대로 쓴다"라 예외가 없어, 파일 탭 라벨을 임의로 바꿀 수 있고 사용자가 **디스크 rename으로 착각**한다(native-editor §2.3) | N1 |
| [link-detection.md](link-detection.md) | 편집기 pane에서의 Cmd+클릭이 터미널 링크 열기와 겹치는 경계 | N4(정의로 이동이 붙을 때) |
| [file-panel.md](file-panel.md) | ⑴ **"파일 1개 = Term 1개" 불변식에 명시 명령 예외 추가**(같은 파일 두 뷰 — native-editor §2.4, **2026-08-09 사용자 결정**). "경로로 열면 기존 Term 활성화"는 유지. ⑵ **미저장 내용의 디스크 백업**(hot exit 상당) 도입 — **2026-08-09 사용자 결정**. 계약은 native-editor §3.10(전체 내용·debounce+종료 시·fingerprint 동봉·백업 존재=비정상 종료·undo는 제외)이고 **파일 경로와 정책은 이 문서가 소유**한다 | ⑴ N2 · ⑵ N2 |
| [workspace-restore.md](workspace-restore.md) | 파일 Term의 커서·스크롤·접힘 복원 범위(native-editor §12) | 후속 |
| [performance-budget.md](performance-budget.md) | 편집기 프레임 예산 항목(native-editor §10). **N0 철회로 선행 baseline은 없어졌지만 이 갱신은 남는다** — 예산은 CM6 측정이 아니라 기존 프레임 예산에서 유도하는 것이라 baseline과 무관하다 | N1(뷰가 프레임에 들어갈 때) |

**중간에 멈춰도 제품이 온전한 지점은 N1.5와 N5다.** N2~N4 사이에서 멈추면 "일부 파일만 네이티브"라는 상태가
사용자에게 노출되므로, 슬라이스 경계를 그 둘에 맞춘다. LSP 클라이언트 자체(프로세스·JSON-RPC·grant)는 이 순서가
아니라 [editor-surface.md](editor-surface.md) §8.2가 소유하며 N4와 독립적으로 진행할 수 있다.

**N3까지는 한국어 입력이 안 된다.** N2에서 편집이 되지만 한글 조합은 N3에서 붙으므로 **그 사이 빌드는 한국어
사용자에게 출하할 수 없다.** 이것이 N1.5를 앞으로 당긴 또 하나의 이유다 — 읽기 전용 검토 흐름은 IME와 무관하게
완결되므로, IME 리스크를 지기 전에 제품 가치를 한 번 낸다.

**N0 철회가 남긴 것**: 성능을 재지 않기로 했으므로 "CM6가 이미 충분히 빨라서 이관 근거가 무너지는" 분기는
아예 열리지 않는다 — 그 대신 **성능을 근거에서 먼저 뺐다**(native-editor.md §1.0). 남은 근거는 룩 일관성과
역량·통제력 둘이고, 이 둘은 측정으로 뒤집히지 않는 종류라 **단계 순서는 그대로다**. 다만 규율 하나는 유지한다:
**성능 개선을 주장하는 서술을 문서·PR·커밋에 쓰지 않는다.** 쓰고 싶어지는 시점이 오면 그때가 측정을 다시
꺼내야 하는 시점이다.
