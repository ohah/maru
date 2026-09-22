# 터미널 입력 인코딩과 VT 프로토콜 구현 이력

8단계에서 다루지 않고 따로 확장한 입력 영역(키 인코딩·OSC 133 semantic prompt·OSC 7·IME·focus/mouse/synchronized output/kitty 프로토콜)과 VT 호환성 갭(G1~G14)·kitty graphics·한글 grapheme 렌더링의 구현 이력이다. 계약의 단일 출처는 [키 입력과 단축키 경계](../key-input-and-shortcuts.md)·[터미널 호환성/보안 정책](../terminal-compatibility-policy.md)·[Grapheme Cluster 저장·렌더링 전략](../grapheme-clustering.md)이다.

이 단계에서 다루지 않고 별도로 확장하는 입력 영역:

- 기본 terminal input 인코더는 `Ctrl+letter` → C0 control, `Alt/Option` → meta-ESC까지 처리한다. 이 계약은 `src/terminal/input.zig`와 `src/config/keybinding.zig`의 단위 테스트가 지킨다.
- **application-cursor-key 모드(DECCKM)를 구현했다(완료)**: TerminalCore가 `CSI ?1h/l`로 모드를 추적하고, `input.encodeKey`가 `EncodeOptions`로 받아 화살표를 SS3(`\x1bOA`)/CSI(`\x1b[A`)로 전환한다. app host의 `handleKeyEvent`가 매 키마다 active surface core의 현재 모드를 읽어 resolver에 넘기므로(인코더는 터미널 상태를 직접 들지 않음), vim/less가 모드를 켜고 끄는 대로 즉시 따라간다. unit + host E2E(`?1h` 후 같은 키가 SS3로 PTY에 쓰임)로 검증.
- function key terminal encoding(Home/End/Insert/Delete/PageUp/PageDown/F1~F12)의 xterm legacy 인코딩·키바인딩 매핑을 구현했다(터미널측, Linux CI). AppKit ABI KeyCode(home~f12) + Swift normalizedKeyEvent 매핑으로 물리 키도 연결했다(Swift는 keyCode 캡처만, 인코딩·바인딩은 Zig — native 최소). 특수 비-텍스트 키(Home/End/PageUp/PageDown/ForwardDelete/Insert/F1~F12)는 IME 트랜잭션을 우회해 바로 인코딩 경로로 보낸다(편집/스크롤 selector라 `interpretKeyEvents`에 맡기면 안정적으로 인코딩 안 됨). PageUp/PageDown는 `input.page-keys` 설정으로 가른다(기본 `scroll`=Terminal.app/iTerm2식 스크롤백 페이지 스크롤, `passthrough`=xterm/Ghostty식 `\e[5~`/`\e[6~`를 PTY로 보내는 opt-in; alt 화면에선 항상 앱에 전달). **kitty keyboard protocol(CSI u)을 구현했다(완료, #526/#527)**: 앱이 `CSI > flags u`로 켜면 flag 스택(push `>`/pop `<`/set `=`/query `?`)을 따라 `encodeKey`가 disambiguate 인코딩(escape·Ctrl+key·화살표/기능키 modifier→`CSI {code};{mods}{final}`)으로 분기한다(미활성이면 legacy 그대로 — progressive enhancement). 키 버퍼는 `encoded_key_buffer_len`(8→32)으로 확장. report_events/alternates/associated(release·대체키·연관텍스트)와 F13~F24·legacy `modifyOtherKeys`는 후속이다.
- **macOS 줄 편집 단축키 빌트인 바인딩을 구현했다(완료)**: Cmd+←/→→`\x01`/`\x05`(Ctrl+A/E=줄 시작/끝), Cmd+⌫→`\x15`(Ctrl+U), Option+←/→→`\eb`/`\ef`(단어 이동)를 `keybinding.default_terminal_bindings` 한 데이터 테이블로 셸 시퀀스에 매핑한다(흩어진 특수 케이스가 아니라 테이블). `resolve`는 **사용자 config 바인딩 → 이 빌트인 → (안 묶인 Cmd면) `.ignored` → 아니면 encodeKey** 순으로 본다(`Cmd+S`가 셸에 `s`를 안 박게 하면서 Mac 사용자가 기대하는 줄 편집은 살림 — Ghostty 기본 keybind와 동작 비교). unit 검증.
- **zsh 편집키 셸 통합을 구현했다(완료)**: `$EDITOR`가 vi류(예: nvim)면 zsh가 vi-keymap을 기본 선택해 위 시퀀스(Ctrl+A/E 등)가 self-insert가 되고 사용자 설정이 그걸 조건부로만 emacs로 바꾸면 터미널마다 동작이 갈리는 문제를, 셸 통합으로 메운다(Ghostty·iTerm2·kitty가 하는 정식 기능). 대화형 셸이 zsh면 `ZDOTDIR`을 Maru 통합 디렉터리로 두고, 그 `.zshenv`가 ① 사용자 `ZDOTDIR`을 복원해 설정을 정상 로드한 뒤 ② `.zshrc` 후 첫 프롬프트(precmd 1회 훅)에서 macOS 편집키만 표준 라인 위젯에 바인딩한다(`bindkey -e` 전체 강제가 아니라 **보내는 키만** — 나머지 vi 바인딩 보존). 통합 스크립트는 **zsh 매뉴얼의 ZDOTDIR/스타트업 동작에서 직접 작성**(Ghostty·kitty 스크립트는 GPLv3라 미차용 — ZDOTDIR로 가리키는 메커니즘 자체는 zsh 공개 동작). 현재 **zsh 전용** — bash/fish는 기본이 emacs 편집모드라 위 4단계 login(1) 로그인 셸만으로 편집키가 동작하므로(실측 확인) 명시적 vi 사용자용 통합은 선택적 후속이다. 자세한 정책은 [키 입력과 단축키 경계](../key-input-and-shortcuts.md).
- **OSC 133(semantic prompt) 파싱·행 분류 저장 토대를 구현했다(완료, 터미널측 Linux CI)**: 셸이 보내는 `OSC 133 ; A|B|C|D`를 파싱해 각 행을 prompt/input/command로 분류한다(`SemanticPrompt` 병렬 배열 — `wrapped`와 같은 패턴이되 **glyph 쓰기로 리셋되지 않는다**, 셸이 프롬프트를 redraw해도 분류 유지). lineFeed가 영역을 다음 행에 전파(여러 줄 프롬프트/출력 태깅)하고, 스크롤백 ring으로 carry하며, 종료코드(`D;<code>`)를 기록해 `RenderSnapshot.prompt_marks`/`last_command_exit`로 노출한다. RIS·ED2 리셋, alt screen 격리(복귀 시 primary 분류 복원), resize 재할당 처리. 이것은 6-PR OSC 133 작업의 **1번(토대)**이다.
- **② zsh 통합 스크립트가 OSC 133 마커를 emit한다(완료)**: 위 zsh 통합 `.zshenv`가 `precmd`로 직전 명령 끝(`D;$?`)+새 프롬프트 시작(`A`)을, `preexec`로 출력 시작(`C`)을, PS1 끝에 입력 시작(`B`)을 emit한다(`print -rn`·`%{%}`). 두 precmd 훅으로 나눠 — `$?`/D/A는 '맨 앞' 훅(.zshenv가 사용자 .zshrc보다 먼저 실행돼 `precmd_functions` 선두 → 직전 `$?` 정확 캡처, 편집키 one-shot precmd가 뒤에 와도 종료코드 안 틀어짐), 입력 시작 B(PS1 끝)는 '맨 뒤' 훅이 처리한다. **B 훅은 p10k/starship/oh-my-zsh가 자기 precmd에서 PS1을 통째로 재생성해도 살아남도록 매 프롬프트 자신을 `precmd_functions` 맨 뒤로 재정렬(`${(@)…:#…}`)한 뒤 append한다**(코드리뷰 #3 — 안 그러면 프레임워크가 B를 매 프롬프트 제거; Ghostty도 같은 재정렬 방식). **실측 검증**: 실제 `/bin/zsh -i`(프레임워크식 PS1 재생성 + vi-mode .zshrc)를 PTY로 띄워 `A→B→C→D;0`/`D;1` 순서·종료코드·B 생존·편집키(`^A`=beginning-of-line) 공존을 캡처로 확인. core 측 end-to-end 단위 테스트(zsh emit 형태 → 행 분류)도 추가. `MARU_DEBUG=1`이면 app session 화면 덤프가 행별 분류(P/I/C/·)+`last_exit`를 찍어 거터 PR 전에 눈으로 확인 가능. clean-room: zsh 매뉴얼 + semantic-prompts.md에서 직접 작성(Ghostty·kitty GPL 스크립트 미참조).

- **③ reflow가 OSC 133 태그를 carry한다(완료)**: resize의 활성 화면 reflow(`reflow_prompt_marks` 스크래치)와 스크롤백 재-wrap이 산출 행마다 소스 옛 행의 태그를 옮긴다 — 논리 줄은 단일 분류라(lineFeed 전파) 어느 옛 행에서 나왔든 그 태그를 물려받고, 커서 줄(verbatim 보존)은 1:1로 carry된다. PR1의 "reflow 후 `.unknown`" 한계를 제거했고, PR1이 스크롤백 재-wrap에서 `sb_prompt_marks`를 갱신하지 않던 잠재 misalignment(재-wrap 후 태그가 내용과 어긋남)도 함께 고쳤다. **커서 줄 reflow workaround(`reflowCursorLine=false`)는 그대로 둔다** — OSC 133가 있어도 zsh는 SIGWINCH에서 프롬프트를 직접 redraw하므로 그 줄을 안 건드리는 게 여전히 옳다(태그만 verbatim carry). `redraw=0`(셸이 redraw 안 함) 옵션 기반의 능동 reflow는 그 옵션을 보내는 셸이 생기면 후속. unit 검증(넓힘 재-wrap·커서 줄 verbatim·스크롤백 push·스크롤백 재-wrap 정렬), perf 게이트 `core_resize_loop`/`scrollback_rewrap` budget 내.

- **④ 프롬프트 점프 네비게이션을 구현했다(완료)**: Cmd+↑/↓로 이전/다음 프롬프트 블록으로 뷰포트를 점프한다(iTerm2·VSCode식). `core.jumpToPrompt(dir)`가 OSC 133 분류로 "프롬프트 블록 시작"(`isPromptStart` — prompt/input run의 첫 행, 직전이 비-프롬프트)을 절대 행 좌표로 찾아 그 행을 뷰포트 맨 위에 둔다(활성 행이면 바닥). 셸 통합이 없으면 분류가 전부 unknown이라 false(무동작). Swift는 Cmd+↑/↓ keyCode만 감지해 `maru_macos_app_session_jump_prompt(dir)` ABI로 방향만 넘기고(native 최소, scroll_page와 같은 규율), 분류·이동·뷰포트 계산은 전부 Zig가 한다. unit 검증(isPromptStart 블록 경계·스크롤백 프롬프트로 점프·분류 없으면 false). **거터 마크(✓/✗)는 후속(PR5)** — 렌더러 레이아웃(거터 strip vs margin overlay) 설계가 필요해 분리한다.

- **⑤ 거터 마크(✓/✗)를 구현했다(완료)**: 프롬프트 시작 행 왼쪽 가장자리에 명령 성공(초록)/실패(빨강) 세로 색 바. 종료코드를 **프롬프트별로** 저장하려고 행 단위 `SemanticPrompt`를 `RowPrompt{kind, exit}`(분류+종료코드)로 묶었다 — 분류와 한 묶음이라 기존 스크롤/reflow carry가 종료코드도 함께 옮긴다(별도 배열 불필요). OSC 133 `D`가 그 명령의 프롬프트 시작 행(커서에서 위로 가장 가까운 isPromptStart, 스크롤백까지 스캔)에 종료코드를 스탬프한다. 렌더는 **native 최소**: `draw_list`가 exit≠null인 행마다 `GutterMark{row,success}` overlay를 내고, `metal_frame`이 **커서 bar(좌측 세로 부분 사각형, kind=3)를 col 0에 재사용**해 초록/빨강 바로 투영(셰이더 변경 0). 레이아웃 A안(overlay, 그리드/PTY 폭 불변). unit 검증(D 스탬프·스크롤백 carry·거터 overlay emit 성공/실패). 거터 strip 예약 없이 첫 칸 가장자리에 그린다.

- **⑥ OSC 7 cwd 보고를 구현했다(완료, 창 제목 소비는 후속 PR)**: 셸이 매 프롬프트 현재 작업 디렉터리를 `OSC 7 ; file://<host>/<percent-encoded path> ST`로 보고하고, core가 path를 percent-decode해 보관한다(`TerminalCore.cwd`, getter `currentCwd`, ABI `maru_macos_app_session_cwd`로 노출). **베이스(사실상 표준)**: OSC 7은 ECMA-48이 아니라 **VTE(GNOME)가 정의**한 형식으로 iTerm2·Terminal.app·kitty·WezTerm이 채택했다. **의사결정**: (1) host(authority)는 무시하고 첫 '/'부터의 path만 저장한다 — 현재 소비처(창 제목)는 경로만 필요하고, 로컬 단일 호스트를 가정한다(SSH/원격 cwd 구분은 host를 따로 보관해 후속). (2) `file://` 스킴만 받고, 형식 불일치·빈 path·OOM이면 **기존 cwd를 유지**한다(부분/깨진 갱신으로 이전 값을 잃지 않게). (3) percent-decoding은 관대하게 — 잘린/비-hex `%escape`는 '%'를 리터럴로 두고 계속한다. (4) cwd는 셸 상태라 화면 clear엔 안 지우고 **RIS(ESC c)에서만** 공장 초기화한다. (5) zsh emit은 `nomultibyte`로 **바이트 단위** percent-encoding해 UTF-8 path(한글 등)도 디코더가 정확히 복원한다 — `vte.sh`(GPL)는 열람하지 않고 OSC 7 공개 형식에서 직접 작성. **실측 검증**: zsh가 `/Users/me/a b/가`를 `\e]7;file://h/Users/me/a%20b/%EA%B0%80\e\\`로 emit함을 캡처로 확인(공백 `%20`·한글 `가`=`%EA%B0%80` 바이트별), core 파서가 그 역(디코드)을 단위 테스트로 고정. `MARU_DEBUG=1`이면 화면 덤프 헤더에 `cwd=`를 찍는다. **창 제목 반영은 후속 PR에서 완료(아래 ⑥-b).** 탭이 아직 없어 "같은 폴더 새 탭"은 탭 기능 후속.
- **⑥-b 창 제목을 OSC 0/2 제목·cwd로 반영했다(완료)**: 비-`MARU_DEBUG`일 때 `window.title`을 셸/앱 상태에서 갱신한다(frame-loop tick, 변할 때만 set). **베이스**: OSC 0/2 창 제목은 **xterm ctlseqs**(OSC 0=아이콘+제목, OSC 1=아이콘만, OSC 2=제목)로 사실상 모든 터미널이 채택. **의사결정**: (1) **우선순위 `OSC 0/2 제목 > OSC 7 cwd basename > 앱 이름("Maru")`** — 우선순위 로직은 Zig(`core.windowTitle`)가 소유하고 Swift는 빈값 폴백만 한다(native 최소). (2) OSC 1(아이콘만)은 창 제목과 무관하므로 무시. (3) 빈 제목(`OSC 2 ; ST`)은 해제 → cwd basename 폴백. (4) cwd는 **basename**만(전체 경로 아님 — 제목줄 간결, Terminal.app 관례). (5) RIS는 제목·cwd 모두 리셋. `core`: `TerminalCore.title`(소유) + `dispatchOsc`의 `0;`/`2;` 분기 + `setWindowTitle` + `windowTitle` getter, ABI `maru_macos_app_session_window_title`. 기존 `MARU_DEBUG` 진단 제목(`updateDiagnosticTitle`)과 상호 배타(디버그면 진단 제목, 아니면 cwd/제목). unit 검증(OSC 2 설정·OSC 1 무시·빈값 해제→cwd basename 폴백·RIS 리셋). 시각 반영은 GUI라 수동 검증.
- **⑦-B 셸 의미 이벤트 채널(관측/테스트 인프라)을 구현했다(B1 완료)**: 사용자가 방향 B(관측/테스트 인프라)를 택했다. `TerminalCore`가 OSC 133/7을 파싱하며 `types.ShellEvent`(`prompt_start`·`input_start`·`command_start`·`command_end{row,exit}`·`cwd_changed`)를 시간순 스트림으로 기록하고 소비자가 `shellEvents()`/`clearShellEvents()`로 drain한다. **설계 결정**: 이벤트는 POD(소유 문자열 없음) — 행은 발생 시점 커서 행, exit는 D의 값, `cwd_changed`는 경계만 표시하고 cwd 값은 `currentCwd()`가 권위(소유권 단순화, trace는 순서가 정답). 누구도 drain 안 해도 cap(4096)에서 멈추고 overflow 플래그를 세운다(조용한 손실 방지). app session이 프레임마다 drain — `MARU_DEBUG`면 `shell.*` scoped 로그로 찍고 항상 비운다(같은 도메인 데이터를 테스트·디버그 로그·후속 trace writer가 공유 — 관측 가능성 원칙). **검증**: 한 명령 사이클(A→B→C→OSC7→D)이 정확한 경계 이벤트 순서를 내는지, exit 코드(0/130/null)·clear를 결정적 unit으로 단언(= E2E가 명령 경계를 상태가 아니라 이벤트로 단언). 바이트→이벤트는 unit, zsh가 그 OSC 바이트를 emit함은 #287(133)·#296(7)에서 캡처. app session 디버그 로그 투영은 GUI라 수동. clean-room: freedesktop semantic-prompts.md·OSC 7(VTE) 공개 형식 + Ghostty 동작 비교(코드 미복사).
- **⑦-B2 trace 직렬화(writer)를 구현했다(완료)**: B1 이벤트 스트림을 `maru.trace.v1` 텍스트로 굳히는 writer(`observability/trace.zig`의 `renderShellEvents`/`writeEvent`). snapshot 직렬화와 같은 규칙(첫 줄 bare 토큰, `event <i> <kind> surface=<id> [payload]` 라인). 토큰은 ShellEvent와 1:1(`shell.prompt-start`/`shell.prompt-end`/`shell.command-start`/`shell.command-end row=N exit=N|none`/`shell.cwd-changed cwd="..."`). `cwd`는 POD 이벤트가 안 들어 직렬화 시점의 `currentCwd()`를 따옴표·escape(`\` `"`·개행/CR/Tab)해 기록. **검증**: 실제 OSC 133/7을 먹인 core의 이벤트가 정확한 trace 라인으로 직렬화되는지(exit 0/130/none·cwd escape 포함) 결정적 unit. **reader/replay는 두지 않는다** — snapshot.zig처럼 writer만, reader/ReplayRunner는 trace를 재생할 필요(첫 회귀 trace·workspace restore)가 생길 때(⑦-B3). 후속: ⑦-B2b live `MARU_TRACE` 레코딩(실 세션→파일), ⑦-B3 reader/ReplayRunner + replay용 output/input/resize 이벤트.
- **IME 1단계를 구현했다(완료, 제품 경계 gate 잔여)**: `MaruMetalTerminalView`가 `NSTextInputClient`를 채택해 수정자 없는 타이핑을 입력기에 위임한다(한글 조합 동작, 터미널 확정 UTF-8은 surface별 ordered input queue로 전송하며 replay key만 현재 입력 모드로 인코딩). Ctrl/Cmd 조합은 입력기를 우회하고 **물리 키코드 기준으로 레이아웃 독립 매칭**한다(ABI v18 raw_key_code + Zig keycode.zig — 한글 모드에서도 Ctrl+B=0x02·Cmd+C/V 동작, 라틴 배열 결과는 보존). 자세한 정책은 [키 입력과 단축키 경계](../key-input-and-shortcuts.md). preedit은 `Surface`의 client-local overlay가 로컬/host-backed base snapshot에 공통 합성하고, 조합 폭은 `RenderSnapshot.ambiguous_wide`를 단일 출처로 쓴다. current host의 scrolled snapshot은 canonical live cursor를 보존하며 `screen_viewport_scrolled_v1` capability가 mode bit 의미를 협상한다. capability 없는 구 v2 host는 visible cursor가 해당 snapshot의 live bottom을 증명할 때만 preedit/candidate를 허용하고, hidden/ambiguous snapshot은 fail-closed한다. 이 증거는 snapshot별로 계산해 latch하지 않는다. IME 판정 상태 머신은 Zig app session이 소유하고, 확정 UTF-8과 replay key를 같은 ordered queue에 확정→replay 순서로 예약한다. cross-window workspace move는 source/destination terminal admission과 moved queue transfer allocation을 all-or-none 선예약하고 pending queue를 함께 이전한다. 원격 nonblocking submit은 bounded preframed frame을 소유한 뒤 전송 구간에 `O_NONBLOCK`을 적용한 `MSG_DONTWAIT` write만 시도하고, remainder는 frame-loop pump가 이어 보낸다. host-backed scrolled `imeBegin`도 `async_scroll_to_bottom_v1` fire-and-forget frame과 stream-local sticky intent를 써 AppKit callback에서 동기 RPC를 기다리지 않으며, 64 KiB direct-key FIFO와 barrier offset이 cap 안의 일반 키를 backpressure/frame encode OOM에도 소유·재시도해 추월/유실을 막는다. FIFO admission 뒤 encode OOM은 retryable이고 pending+new가 64 KiB를 넘는 admission은 효과 0으로 fail-closed한다. blocking mouse/core/resize RPC는 FIFO/barrier를 먼저 flush한다. OOM은 partial/duplicate 대신 0회 전송을 허용한다. exactly-once는 예약 성공 뒤 application admission/submit 범위이며 PTY 소비·원격 durable delivery ACK는 아니다. unit/controlled host-backed 검증은 있지만 실제 구 host binary·AppKit 후보창 픽셀은 남은 제품 gate다. stalled socket은 deterministic socketpair backpressure로 callback이 쓰는 outbound admission의 무블록·wire ordering·direct-key ownership·exact-cap/cap+1·후속 mouse RPC 순서를 자동 검증하지만 실제 AppKit run-loop deadline 계측은 수동/후속이다. 아직: keypad/dead key(function key는 IME 우회로, CSI-u/kitty keyboard 인코딩은 #526/#527로 구현 완료).

- **미구현 프로토콜 audit을 진행했다(focus/mouse/synchronized output/kitty keyboard/kitty graphics)**: Ghostty 레퍼런스와 대조해 빠진 VT 프로토콜을 순서대로 메웠다(전부 머지·`verification-matrix.md` 반영). 각 프로토콜은 progressive enhancement(앱이 DECSET/CSI로 켤 때만 동작, legacy 공존)이고, 거짓 지원을 피하려 "지원 응답 + 실제 동작"을 한 PR로 묶었다.
  - **focus events(DECSET 1004)**: 창 포커스 in/out을 `CSI I`(gained)/`CSI O`(lost)로 PTY 리포트(Swift window key/resign→ABI focus_changed→활성 surface reportFocus). vim FocusGained/Lost가 동작.
  - **mouse reporting(DECSET 1000/1002/1003 트래킹 + 1006 SGR/1016 pixels/x10 인코딩)**: 클릭/드래그/휠을 `CSI < Cb;Px;Py M/m`(SGR) 또는 `CSI M`(x10)으로 PTY 리포트. Swift `buttonNumber`→xterm 0/1/2·`modifierFlags`→mods 비트 변환, shift+click은 셀렉션 override, 휠=버튼 64/65.
  - **synchronized output(DECSET 2026)**: sync 중 metal frame 투영을 hold하고 ESU에 누적 출력을 한 frame으로 그려 tearing/깜빡임을 막는다. DECRQM `?2026$p`로 지원 감지(Ghostty render-skip 동형). **후속(sync-2026 ESU edge)**: per-tick 폴링이 `sync_output`을 샘플하는 순간 이미 다음 BSU가 시작돼 있으면(flush 창<tick) 완성 프레임(ESU)을 못 보고 timeout까지 막던 **MISS**가 있었다 — `MARU_DEBUG` 계측으로 연속 프레임 워크로드에서 sync 막힘의 **약 절반이 MISS**임을 실측(before 14·15 → after 0·0). 리더의 ESU 누적 카운트(`core.sync_esu_count`)를 edge로 소비해(`shouldProjectFrame`의 `esu_advanced`, view_offset 안전판과 동형) 완성 프레임을 즉시 flush한다. Ghostty는 리더가 ESU에서 렌더를 트리거해 회피하지만 maru는 tick 폴링이라 카운트 edge로 동형 효과를 낸다. 정당한 막힘(프레임 미완성, BSU 진행 중)은 그대로 유지(tearing 방지).
  - **kitty keyboard protocol(CSI u, #526/#527)**: 위 키 인코딩 문단 참조 — FlagStack(push `>`/pop `<`/set `=`/query `?`) + disambiguate 인코딩, Shift+Tab backtab fix(code review 발견). **다섯 flag 를 모두 인코딩한다**(2026-09-09): disambiguate(1)·report_events(2)·report_alternates(4)·report_all(8)·report_associated(16). 전체 형식은 `CSI code:shifted:layout ; mods:event ; text u` 이고 **뒤쪽 빈 자리는 생략한다** — 그래서 flag 를 안 켠 앱이 받는 바이트는 켜기 전과 같다(가운데만 비고 뒤가 차면 `CSI 97;;97u` 처럼 자리를 비워 남긴다). `report_alternates` 의 «base layout key» 는 물리 키코드의 US 배열 글자다 — `keycode.usAsciiForKeyCode(raw_key_code)` 가 단일 출처이고, 이미 레이아웃 독립 단축키가 쓰던 표라 ABI 를 넓히지 않았다. `report_all` 은 legacy 예외(Enter/Tab/Backspace·평문 문자를 raw 바이트로 보내는 것)를 끄고, 그와 함께 그 키들의 **release 침묵도 푼다**(명세가 그 조건을 그대로 적는다). `report_associated` 는 ctrl/alt/cmd 가 걸린 키와 release 에는 텍스트를 안 싣는다 — 제어 의미이거나, 뗄 때 글자가 또 들어가면 두 번 입력된다. **flag 스택은 화면(main/alt)마다 따로다**(2026-09-10): alt 진입 시 primary 스택을 `saved_kitty_flags` 로 치워 두고 빈 스택에서 시작하며, 이탈 시 되돌린다 — grid·스크롤백·커서·pen 을 통째로 되돌리는 것과 같은 결이고, 키보드 모드도 그 화면의 상태다. 전역으로 두면 TUI 가 alt 에서 flag 를 켠 채 **pop 없이 죽었을 때**(크래시·SIGKILL) 그것이 셸로 샌다. 대가가 크다 — 실측: flag 1(disambiguate)만 새어도 셸의 Ctrl+C 가 `0x03` 이 아니라 7바이트 `CSI 99;5u` 로 나가 tty 가 SIGINT 로 못 읽는다(사용자는 아무것도 중단할 수 없고, 무엇이 잘못됐는지 알 방법도 없다). flag 8 은 거기에 Enter/Tab/Backspace 까지 얹는다. 이 누수는 flag 스택이 생긴 2026-06-16(`46b9ee357`)부터 있었다. 대가로 **앱은 alt 에 들어간 뒤에 flag 를 켜야 한다** — 들어가기 전에 켠 것은 alt 에 안 따라간다. 정상 경로(진입 후 push)와 일치한다.

  - **광고(`kittyFlagsFromParam`)와 인코딩(`input.encodeKitty`)은 같은 상태여야 한다** — 비트를 더할 때 인코더가 그 자리를 싣는지 먼저 확인하고, 명세에 없는 비트(32 이상)는 계속 떨군다.
  - **OSC 66(kitty 텍스트 사이징) / OSC 5522(kitty 클립보드) — Ghostty 패리티 후속(미착수, 로드맵)**: Ghostty는 이 둘도 지원(동적 버퍼 사용)하지만 maru는 아직 구현하지 않았다. maru가 목표하는 kitty는 **graphics(APC)·keyboard(CSI u)**이고 이 둘은 완료다 — 66/5522는 별개의 kitty 확장이다. **접두 충돌 없음**을 확인(`"5522;"`는 `"52;"`로 오배치 안 됨). 미지원이라 지금은 `oscMayGrow` 대용량 허용 목록에 안 넣는다(핸들러 없는 OSC 버퍼를 키우면 megabyte를 받아 버릴 뿐 — 낭비). 판단:
    - **OSC 5522(kitty 클립보드) — 낮음**: OSC 52(범용 표준)를 이미 지원하고 프로그램이 폴백하므로 실기능 공백이 아니다. 스트리밍 싱크(아래) 위에서 청크가 거의 공짜로 따라오는 **부산물**로 취급.
    - **OSC 66(텍스트 사이징) — 진짜 후보(큰 렌더러 작업)**: 글자를 셀 배수/분수로 그리는 렌더 기능이라 파싱이 아니라 **fixed-cell 렌더러 확장**(kitty graphics급)이 본체다. 착수 시 파서를 **번호-인식 + 스트리밍 싱크**로 전환하는 트리거로 삼는다(단일 트리거 — [terminal-compatibility-policy.md §OSC52 "장기 방향"](../terminal-compatibility-policy.md) 단일 출처). ⚠️ 이 리팩터링 대부분은 **사용자에게 안 보이는 유지보수·미래 대비**다(피크 메모리·파서 내부 불가시) — UX 명분으로 팔지 않는다. 사용자에게 실제 나은 건 이미 구현한 "가시적 상한"(무음 폐기 제거)뿐이다.
  - **OSC 52 클립보드 버퍼(#1201/#1204/후속) — 완료**: 고정 2048 OSC 버퍼가 한 문단(base64 >2KB) 복사를 통째로 버리던 루트커즈를 동적 버퍼로 수정(#1201), 대용량 회수 갭 5건(clipboard_write/osc_buffer 반납·OOM storm·접두 latch·공허 테스트) 수정(#1204), **상한 초과를 notice로 표면화**해 무음 실패 제거(후속). Ghostty와 같은 구조(2048 고정 + 클립보드만 동적 + 오버플로 discard)에 **상한·즉시 반납·가시적 실패로 앞선다**(Ghostty는 상한 없음·무음 폐기). 스트리밍 싱크는 위 OSC 66 트리거로 이연.
  - **kitty graphics protocol(APC, #528/#530/#531 + K1)**: ① 파서+command 토대(`ESC _ G ...` 수집 + control `k=v` 파싱, #528) ② 이미지 디코드+저장(transmit RGBA/RGB base64→`KittyImageStorage`, 같은 id 교체·320MB 총량 한계·`a=d` delete·RIS 비움, #530; 치수 곱 오버플로 crash fix #531) ③ **K1 placement(코어)**: display(`a=p`/`a=T`)를 현재 커서 셀에 placement로 걸어 `(image_id, placement_id)`로 저장(같은 키 교체)하고 `RenderSnapshot.placements`로 노출까지 완료. **베이스**: kitty graphics protocol display data(`p`/`x`/`y`/`w`/`h`/`X`/`Y`/`c`/`r`/`z`/`C` 키). **의사결정**: (1) anchor는 **절대 행**(스크롤백 0..sb_count-1, 이어서 활성 화면)이라 selection/find와 같은 좌표계로 스크롤·eviction과 함께 움직인다(`shiftPlacementsForEviction`이 eviction마다 보정, 화면 밖이면 제거 — `shiftSelectionForEviction`과 동형). (2) **셀 단위 크기(span)는 코어가 계산하지 않는다** — 코어는 셀 픽셀 크기를 모르므로(`Size`는 rows/cols, 마우스 1016도 platform이 픽셀을 주입) source rect(픽셀)와 명시 `c`/`r`만 담고, 픽셀→셀 환산·클립은 셀 메트릭을 가진 **렌더러(K2) 책임**이다(마우스 1016 경계와 정합). `RenderSnapshot.placements`의 `row`는 뷰포트 상대 i32(화면 위로 벗어난 앵커는 음수 — 렌더러가 span으로 가시성/클립 판정). (3) 커서 이동 정책(`C`): 기본은 이미지 아래로 내리되 행 수(`r`)가 명시됐을 때만(자동 크기는 span 미상이라 미이동 — K1 한계), 화면 끝 초과는 스크롤 없이 마지막 행 clamp. (4) placement 상한(`max_kitty_placements`=1024)으로 placement_id 폭주 차단(이미지 320MB·APC 버퍼 한계와 같은 결의 방어선). **검증**: 생성·모든 display 키 파싱·뷰포트 매핑·`a=T` 합성·없는 이미지/`i=0` graceful·같은 키 교체·다른 p 별개·커서 이동(C/r/clamp)·delete가 이미지+placement 동시 제거·RIS 비움·eviction anchor 보정/제거·위 스크롤 시 뷰포트 row 환산을 결정적 unit으로 단언. K1은 화면 렌더 없이 노출까지다. ④ **K2 렌더(완료)**: GpuImage 환산 + per-image 텍스처 + Metal 파이프라인 + ABI v48 — 아래 "kitty graphics K2 렌더" 절. ⑤ **K3 디코드 확장(완료)**: K3a chunked(`m=1`)(여러 APC 누적·480MB 상한·RIS 폐기), K3b zlib(`o=z`)(`std.compress.flate(.zlib)` inflate, zlib bomb 바운드), K3c PNG(`f=100`) — **전 color type·bit depth·인터레이스**를 디코드한다(palette·grayscale·truecolor, 1/2/4/8/16-bit, tRNS, Adam7). 출력은 언제나 RGBA 8-bit. 디코드는 **wuffs**(lazy dep) 가 하고 `src/terminal/png.zig` 는 총량 회계·버퍼 소유·에러 환산만 한다 — 아래 "kitty graphics PNG" 절. 프레임 PNG(`a=f`+`f=100`)와 PNG+`o=z` 도 받는다(2026-09-14). ⑥ **K4 저장 관리**: K4a 세분화된 delete(`a=d` + `d=` 타깃) **완료** — 기본 `d='a'`(전체), 소문자=placement만/대문자=이미지 데이터까지 free, `a/A`(전체)·`i/I`(image_id[+placement_id])·`z/Z`(z-index)·**`n/N`(이미지 번호 `I=`)**·**`c/C`(커서를 덮는 placement)** 지원, **`d=a` 는 「화면에 보이는 배치」만 지운다**(2026-09-14): 명세가 "Delete all placements **visible on screen**" 이고, 두 레퍼런스 원본이 같은 규칙이다 — kitty 는 `clear_all_filter_func` 에서 `if (ref->is_virtual_ref) return false;` 로 가상 배치를 빼고, Ghostty 는 `.all` 을 `deleteVisiblePlacements`("Delete only non-virtual placements that intersect the active screen")로 보낸다. 예전 maru 는 목록을 통째로 비워서 **스크롤백으로 밀려난 이미지까지** 지웠다(프로그램이 화면을 정리할 때마다 사용자의 과거 이미지가 깎였다). 앵커가 활성 영역 안이면 계산 없이 「보인다」이고, 스크롤백에 있을 때만 셀 span 으로 아래 끝이 걸치는지 본다(Ghostty 의 최적화 힌트와 같다). **가상 배치(U=1)는 대상이 아니다** — 코어는 placeholder 셀 위치를 모르므로 「보이는가」를 물을 수조차 없고, 두 레퍼런스가 같은 답을 갖고 있다. 대문자 `d=A` 는 그 위에 조건부 free 를 더할 뿐이라 **배치가 하나도 없는 이미지는 안 걸린다**(그건 `d=I,i=` 가 하는 일이다).

**자리로 겨누는 delete 는 화면을 넘지 않는다**(2026-09-14 적대적 검증): `a`/`c`/`p`/`q`/`x`/`y`/`z` 는 전부 **자리**로 겨누는데, 자리는 화면마다 좌표계가 다르다(`anchor_row` 는 그 화면의 절대 행이고 alt 엔 스크롤백이 없다). 걸러 주지 않아 **alt 의 TUI 가 보낸 delete 가 셸 화면의 이미지를 지우고 있었다**(실측: 넷 다 primary 배치를 지웠다 — #3631/#3677 이 세운 화면 격리를 delete 가 뚫었다). 공유 몸통(`deletePlacementsWhere`)에서 `on_alt` 를 본다. kitty 는 화면마다 graphics 상태가 따로라 구조적으로 이 문제가 없다. **id 로 겨누는 타깃(`i`/`n`/`r`)은 그대로 세션 전역**이다 — 그쪽 대상은 이미지이고 이미지는 화면이 아니라 세션에 속한다.

**나머지 여섯도 완료**(2026-09-14): `p/P`(셀 교차)·`q/Q`(셀+z-index)·`x/X`(열)·`y/Y`(행)·`r/R`(id 범위)·`f/F`(애니메이션 프레임). 셀 좌표는 **1-based** 다(명세: "x=1, y=1 is the top left cell") — 0 이나 미지정은 좌표가 아니므로 `EINVAL` 로 거부한다(0-based 로 읽으면 엉뚱한 셀을 지우는 조용한 오작동이 된다). `r` 은 다른 타깃과 달리 대상이 **placement 가 아니라 이미지**라(명세: "all images whose id is ...") 화면에 안 걸린 이미지도 걸리고, `x`/`y` 키가 id 범위다. `f` 는 프레임(2..N)만 놓아주고 루트는 남긴다 — 그림은 계속 보이고 애니메이션만 멈춘다(재생 상태·총량 회계도 함께 되돌린다). 이로써 **delete 타깃 11/11**. `n`은 `I=`가 배정한 표를 **조회만** 한다 — delete 가 `resolveImageNumber`를 부르면 «없는 번호를 지워라»가 새 id 를 배정해 표를 늘린다(지우는 명령이 상태를 만든다). `c`는 셀 span 이 필요해 `c`/`r` 이 없으면 `setCellMetrics` 값으로 픽셀→셀을 **올림** 환산하고, 메트릭이 없으면(헤드리스) 1×1 로 본다 — 「덜 지우는」 쪽 폴백이다. **relative placement 의 부모 검증은 성능 방어선이기도 하다**(2026-09-10): 부모가 없는 `a=p`(`P=`/`Q=`)를 `ENOENT` 로 거부하는 것은 명세 준수이면서 동시에 `removeOrphanedRelatives` 의 비용 상한을 지탱한다 — 부모가 언제나 자식보다 먼저 등록되므로 배열에서도 앞에 오고, 그래서 고아 연쇄가 **한 패스에** 다 걷힌다. 관대해지면 자식이 앞에 놓여 패스마다 하나씩만 걷히고 세제곱이 된다. 실측(사슬 1024): 거부하면 3 ms, 거부를 빼면 **1094 ms** — 몇 KB 의 escape 로 터미널이 1초 넘게 멈춘다. 코드만 봐서는 안 보이는 결합이라 양쪽에 주석을 달고 판정자로 고정했다. **원격 parity 판정자는 픽스처가 그 축을 실제로 만들어야 뜻이 있다**(2026-09-10): `RenderSnapshot` 필드 목록은 comptime 으로 소진 검사되지만, 픽스처가 가상 placement(`U=1`)를 하나도 안 만들면 그 비교는 「0 == 0」 으로 헛통과한다 — 실측으로 그 상태였다. 이제 픽스처가 24비트를 넘는 id(0x0100_0007)의 가상 placement 와 **결합 문자 셋을 단** placeholder 셀을 만들고, `virtual_placements.len > 0`·`extras >= 3` 을 먼저 단언한다. 돌연변이로 확인: wire 에서 `image_virtual` 레코드를 안 실으면 `expected 1, found 0` 으로 빨개진다(확장 전에는 조용히 통과했다). 같은 함정을 kitty 판정자 전체에서 훑었다(2026-09-10): 런타임 컬렉션을 훑는 한 줄 루프 다섯 곳을 계측해 **한 곳이 빈 목록을 돌고 있었고**(그 자리의 뜻은 바로 다음 줄의 「0개」 단언이 지고 있었다), 「없는 이미지·`i=0`은 placement 를 안 만든다」 판정자에는 **양성 대조가 없어** `a=p` 를 통째로 무력화해도 초록이었다. 부정 판정자는 그 기능이 **살아 있음**을 같은 자리에서 함께 증명해야 뜻이 있다 — 둘 다 보강하고 돌연변이로 확인했다. 이어서 **「문서가 약속했는데 판정자가 없는 갈래」**를 훑었다(2026-09-10): 가상 부모를 가진 relative placement(`ParentKind.virtual_parent`)는 **판정자가 아예 없었고**, 애니메이션은 셋(`a=f`·`a=a`·`a=c`) 중 하나만, 전송 매체는 셋(`t=f`·`t=t`·`t=s`) 중 하나만 덮여 있었으며, OSC 99 질의(`p=?`) 침묵도 재는 곳이 없었다. 넷 다 실제 동작은 문서대로였다 — 없던 것은 그물이다. 셋을 더하고 각각 돌연변이로 확인했다(가상 부모를 `(0,0)` 으로 풀면 `expected 0, found 1`, `a=f` 를 조용히 `.ok` 로 만들면 응답 불일치, 질의에 아무 바이트나 답하면 `expected 0, found 13`). K4b LRU evict **완료** — 320MB 한도(이제 settable 필드) 초과 시 거부가 아니라 **placement 없는 것·오래된(generation 작은) 것 우선**으로 evict해 자리를 만든다(kitty 명세 권장; Ghostty `evictImage` 동작 비교). 한 장이 한도보다 크면 거부. K4c 텍스처 eviction **완료**(ABI v49) — 코어가 매 frame **살아있는 image_id 집합**(활성 surface 저장소 키)을 `MetalFrame.live_image_ids`로 노출하고, Swift/Metal이 그 집합에 없는 캐시 `MTLTexture`를 evict해 GPU 메모리를 회수한다(delete/evict/RIS 반영). AppSession이 `kitty_uploaded` dedup 상태도 같은 집합으로 prune해 재진입 시 재업로드를 보장(Swift 캐시와 동기). **K4 완료 → kitty graphics 전 단계(K1~K4) 완성.** sixel(DCS 기반)은 별개이고 Ghostty도 미지원이라 후순위. ⑦ **K5 query(`a=q`) 응답 + 자기능력 보고(완료, 2026-09-08)**: 예측대로였다 — 응답이 없어 앱들이 maru를 "이미지 못 그리는 터미널"로 판정했다(실측: terminal-browser `graphics.ts`가 `\x1b_Gi=4207,a=q,t=d,f=24,s=1,v=1;AAAA` + DA1 을 보내고 APC 응답이 없어 unsupported로 갈렸다). 이제 `execKittyGraphics`가 모든 갈래의 결과를 `KittyStatus`로 모아 `kittyReply`가 `ESC _ G i=<id>[,p=<pid>];OK|<CODE>:<msg> ESC \\`로 회신한다. **`a=q`는 픽셀을 끝까지 디코드해 검증하되 저장하지 않는다**(명세). `q`(quiet)를 존중한다(0=전부·1=에러만·2=침묵). `i=`가 없으면 응답하지 않는다(어느 명령의 응답인지 못 가리므로 명세가 금지). 함께 메운 것 둘: **`t=`(전송 매체) 파싱** — 안 읽으면 `t=f`/`t=s`의 경로 문자열을 픽셀로 오인해 무음 폐기했다. 이제 direct(`t=d`)만 받고 나머지는 `ENOTSUPP`로 **명시 거부**해 앱이 즉시 inline으로 폴백한다(terminal-browser는 shm→file→inline 순으로 묻는다). **`q=` 파싱** — 없으면 `q=2`를 쓴 앱에 응답을 뱉어 그 바이트가 앱 입력에 섞인다. **대가(문서화)**: `q=`를 안 주고 응답도 안 읽는 쓰기(수동 `printf` 실험 등)는 회신이 셸 입력으로 새어 프롬프트에 `Gi=1;OK`가 찍힌다 — kitty·Ghostty와 같은 표준 동작이고, `q=2`를 주는 정상 앱 경로는 누출 0으로 확인했다(적대적 검증 R4/R5). 베이스: Ghostty `graphics_exec.zig`(query는 load를 시도해 검증한 뒤 `OK`/에러를 APC로 회신하되 실제 저장은 안 함). 동작: `a=q`면 픽셀을 저장하지 않고 control 파싱·검증만 해 `ESC _ G i=<id>;OK ESC \` (또는 에러코드)로 회신. 난이도: 중(transmit 경로에서 "저장"과 "응답"을 분리). **애니메이션(`a=f`/`a=a`/`a=c`) 구현 완료**(2026-09-10). 모델: 이미지 하나가 프레임 1..N 을 갖고 프레임 1 은 루트(`data`), 2..N 은 `frames` 다. **각 프레임은 완전한 픽셀을 굳혀 담는다** — 「베이스+델타」로 두면 합성이 렌더 경로에 들어온다. **렌더러는 손대지 않았다**: `buildImageViews` 가 현재 프레임 픽셀을 노출하고 프레임이 넘어갈 때 `generation` 을 올리면, 기존 텍스처 캐시 무효화(generation 키)가 그대로 애니메이션이 된다. 시간은 **코어가 갖지 않는다**(판정자가 결정적이어야 한다) — platform tick 이 실경과 ms 를 `advanceAnimations` 로 넣어 준다(커서 깜빡임과 같은 결). 그 자리에 **상한(1초)**을 둔다: 기계가 오래 잠들었다 깨면 수천 프레임을 순간에 감고, 필드가 `undefined` 인 세션(판정자)에서는 `@intCast` 가 패닉한다(실측으로 둘 다 겪었다). 방어선 둘: 프레임 수 상한(`max_animation_frames`=512)과 **총량 회계가 프레임을 센다** — 안 세면 애니메이션 하나가 320MB 상한을 우회한다. 남은 것: PNG 프레임(`a=f` + `f=100`)은 `ENOTSUPP`(루트 이미지는 지원). ~~그리고 **애니메이션은 로컬 전용이다**(2026-09-10): host tick 이 `advanceAnimations` 를 부르지 않아 원격 세션에서는 첫 프레임만 보인다.~~ **개정(2026-09-12, `7a1546ae7`)**: 시계를 host 의 poll cadence(20 ms)에 꽂아 **세션호스트에서도 돈다** — 코어가 사는 곳이 host 라 app tick 에 꽂았던 전진은 죽은 코드였다(`poll_owner.scheduleCadence` → `runtime_manager.advanceAnimations` → 넘어간 runtime 만 `publishScreenChange`). **대가는 그대로 지불 중이다**: 원격 delta 의 `image_blob` 은 `generation` 이 바뀐 이미지 **전체**를 다시 실으므로 프레임마다 blob 이 나간다(64×64 RGBA 프레임 1회 = 16,441 B; 400×300 이면 최대 24 MB/s — 단일 출처 [persistent-session-host.md](../persistent-session-host.md) «`image_blob`의 단위»). 「프레임을 미리 보내고 delta 는 프레임 번호만」 레코드는 **미구현**이고, 세션호스트 이미지 경로의 제로카피(호스트 CPU 29%·인플라이트 267–430 MB, 2026-09-14 실측)가 겨누는 자리와 같다. **화면에 없는 이미지는 진행하지 않는다**: 아무도 못 보는 프레임에 CPU 를 쓰지 않고, evict 가 최저 `generation` 을 고르므로 숨은 애니메이션이 「가장 새것」이 되어 **LRU 를 뒤집는** 것도 함께 막는다. **프레임도 총량 한도를 지킨다** — 회계만 하고 강제를 안 하면 프레임 수 상한(512)으로는 못 막는다(프레임 크기가 이미지 크기를 따라가므로 큰 이미지면 512장이 수십 GB다). 프레임은 evict 하지 않고 `ENOMEM` 으로 거부한다 — 한 애니메이션의 프레임을 골라 버리면 그 애니메이션이 조용히 이상해진다. **handoff 코덱의 독립 회계도 프레임을 세야 한다**(2026-09-11 적대적 검증): 코덱은 저장소와 따로 합계를 다시 세어 대조하는데 그 계산이 `data.len` 만 보고 있었다 — 애니메이션이 있는 세션의 handoff 가 합계 불일치로 **통째로 거부됐다**(`InvalidValue`). 프레임 하나만 있어도 세션 호스트 exec 가 실패한다. 같은 자리의 `errdefer` 도 `data` 만 놓아주고 있어 프레임이 샜다. **「reflection 코덱이 중첩 슬라이스를 그대로 나른다」는 서술은 맞았지만, 그 옆의 독립 회계가 틀렸다** — 같은 결로 **「렌더러를 안 건드려도 된다」도 이음매가 비어 있었다**(2026-09-11): 코어 판정자는 「generation 이 오른다」를, 렌더러 판정자는 「generation 이 바뀌면 재업로드한다」를 각각 재고 있었는데, **그 둘을 잇는 자리**(렌더 뷰가 바뀐 generation 과 새 프레임 픽셀을 싣는가)는 아무도 안 쟀다. 거기가 끊기면 코어는 프레임을 넘기는데 화면은 첫 프레임에 멈춘 채 **양쪽 판정자가 모두 초록**이다. 끝에서 끝까지 꿰는 판정자를 넣었다. (주의: 이미지는 `snapshot()` 이 아니라 `renderSnapshot()` 이 싣는다 — 앞의 것으로 재면 빈 목록을 보고 헛통과한다.) 이어서 **합성 경로 넷**(x/y 오프셋·알파 블렌드·베이스 프레임·`Y` 배경색)과 **`z<0` 건너뛰기**, **루트 재전송이 프레임을 놓아주는지**도 판정자가 한 번도 안 타고 있어 고정했다(2026-09-11). 넷 다 동작은 맞았다 — 알파는 source-over 정수 산술이고(빨강 위 반투명 초록 → `127,128,0,255`), `X=1` 은 덮어쓴다. 합성 산술은 틀어져도 「색이 이상하다」로만 보여 회귀를 알아채기 어렵다는 점에서 그물의 값이 크다. **무작위 fuzz 는 문법을 알아야 한다**(2026-09-11): kitty APC 를 완전 무작위로 4000 개 먹였더니 이미지가 **한 장도 안 만들어졌다**(`images=0 frames=0`) — 무작위 조합은 `f`/`s`/`v`/`i`/payload 가 동시에 들어맞는 유효 전송을 거의 못 만들어서 전부 **거부 경로**만 밟았고, 합성·재생 코드는 한 번도 안 돌았다. 유효 상태를 먼저 심고 「유효 골격 + 한두 필드 교란」을 절반 섞어야 실제 코드를 밟는다. 그리고 **fuzz 가 그 코드를 밟았다는 것 자체를 단언**해야 한다 — 안 그러면 「4000 개를 먹였다」가 「거부를 4000 번 했다」와 구분되지 않는다. fuzz 는 **버그 사냥 도구로도 쓴다**: `MARU_FUZZ_SEED=<n>` 으로 seed 를 바꿔 수백 개를 훑는다. 생성기를 큰 프레임(4×4)·RGB(f=24)·잘린 base64·chunked(`m=1`) 까지 넓혀 **400 개 seed 를 훑었고 전부 통과했다**(2026-09-11) — 결함 없음이라는 음성 결과다. CI 는 기본 seed 하나만 돌려 결정적이고 빠르게 두고, 탐색은 손으로 돌린다. **그 다음 회차에 fuzz 자체의 탐지력을 쟀다**(2026-09-11, 제품 코드를 돌연변이시켜 fuzz 만으로 잡히는지): 세 돌연변이 중 **셋 다 안 잡혔다**. 이유를 파 보니 fuzz 가 도달한 자원 최대치가 한도의 **3%**(240B / 8192B)였다 — `total_bytes <= limit` 단언이 **한 번도 시험되지 않은 채** 초록이었고, #3510 이 고친 그 방어선을 되돌려도 20 개 seed 가 전부 통과했다. 한도를 프레임 몇 장 크기(160B)로 낮추고 유효 `a=f` 비중을 높여 거부 경로를 반복해 밟게 했다. 이제 같은 돌연변이가 곧바로 잡힌다. **그리고 「fuzz 가 한도를 실제로 밀었는가」를 단언한다** — 커버리지 단언과 같은 이유다. 자원 단언은 한도 근처에 가지 않으면 공허하다. 그 다음 회차에는 **kitty 의 방어선을 전수로 훑었다**(2026-09-11): 상한·검증 가드 여덟 개를 하나씩 지워 전체 판정자가 잡는지 쟀더니 **여섯이 안 잡혔다** — placement 상한(1024)·virtual 상한·프레임 수 상한(512)·compose 자기합성 금지·compose 크기 검증·프레임 bpp 일치. 코드에는 방어선이 있는데 **그것을 겨눈 판정자가 없었다**. 여섯 다 판정자를 달고 같은 돌연변이로 재시험해 전부 잡히는 것을 확인했다. 잡힌 둘(compose 대상 검증·relative 열 범위)은 기존 판정자가 이미 그 자리를 지나고 있었다. **「방어선이 있다」와 「그것을 지키는 판정자가 있다」는 다르다** — 전자는 코드를 읽으면 보이고 후자는 지워 봐야 안다. 같은 스윕을 **OSC 영역**으로 넓혔다(2026-09-11): 가드 여섯 중 **넷이 잡혔다** — kitty(여덟 중 둘)보다 훨씬 나은데, OSC 는 오래된 코드라 판정자가 이미 두껍게 깔려 있기 때문이다. 안 잡힌 둘은 **OSC 52 클립보드**(상한 초과·빈 데이터)였고 판정자를 달았다. 그중 빈 데이터 가드는 **중복 방어선**이었다 — 하나만 지우면 바로 다음 줄의 `decoded_len == 0` 이 막아서 안 잡히고, **둘 다 지워야** 판정자가 빨개진다. 돌연변이가 안 잡혔을 때 「그물이 없다」와 「방어가 두 겹이다」를 가르려면 **이웃 가드까지 함께 지워 봐야 한다** — 스윕 결과를 읽을 때 필요한 한 단계다. 세 번째 스윕은 **키보드 flag 인코더**(`input.zig`)였다(2026-09-12): 조건 여섯 중 **다섯이 잡혔다** — 지금까지 중 가장 두꺼운 그물이다(바이트 단위 계약이라 판정자가 출력을 통째로 대조해서다). 안 잡힌 하나는 `shifted` 의 **shift 조건**이었다: 기존 픽스처는 「글자가 base 와 다르다」와 「shift 를 눌렀다」가 언제나 함께라, 그 조건을 지워도 아무도 몰랐다. 그 조합은 실재한다 — **Caps Lock** 이면 `A` 가 오는데 shift modifier 는 없다. 그때 `CSI 97:65u` 를 보내면 앱은 「shift 를 눌렀다」고 읽는다. 판정자를 달아 고정했다. **두 조건이 픽스처에서 언제나 함께면, 그중 하나를 지워도 안 잡힌다** — 조건이 `and` 로 묶여 있을수록 그 둘을 갈라 놓는 픽스처가 따로 필요하다. 네 번째 스윕은 **마우스·붙여넣기 리포트**였다(2026-09-12): 가드 여섯 중 **넷이 잡혔다**. 안 잡힌 둘은 **마우스 모드 필터**(motion 은 button·any 에서만, x10 은 release 를 안 보낸다)였다 — 이유가 한 갈래 더 있다: 판정자들이 **켠 모드에서 나가는 바이트**만 재고 있었고 **안 나가야 하는 것이 안 나가는지**는 아무도 안 봤다. 걸러지지 않으면 앱은 요청하지 않은 이벤트를 받는다(normal 앱이 drag 마다 보고를 받아 선택이 늘어나고, x10 앱은 release 를 press 로 오해한다). **「무엇을 보내는가」만 재는 판정자는 「무엇을 거르는가」를 못 지킨다** — 모드·정책처럼 거르는 것이 본질인 코드에는 침묵 자체를 재는 판정자가 따로 필요하다. **스윕은 「이미 있는 가드」만 시험한다 — 「빠진 가드」는 못 찾는다**(2026-09-12). 그 사각을 직접 읽어 결함 하나를 찾았다: `advanceAnimations` 가 **함수 전역 `changed` 하나로** generation 상승을 판정해서, 앞의 이미지가 한 번 넘어가면 그 뒤로 **안 움직인 이미지까지** generation 이 올라갔다. generation 은 렌더러의 텍스처 재업로드 키라, 픽셀은 그대로인데 GPU 업로드만 늘고 애니메이션이 여럿이면 그만큼 곱해진다(실측: 안 움직인 이미지가 매 tick +2). 이미지별 플래그로 갈랐다. 같은 모양(`var changed` 를 루프 밖에 두는 것)을 다른 곳에서도 찾아봤는데 `removeOrphanedRelatives` 뿐이었고 그쪽은 패스마다 리셋하는 **고정점 루프**라 정상이다. — 구조가 되는 것과 계약이 지켜지는 것은 다르고, 왕복 판정자 없이는 그 차이가 안 보인다.

## 한글 Grapheme Cluster 렌더링 (HG1~HG4 — NFD 자모 정공법)

목표:
- macOS 파일명 NFD(분해형)로 들어온 한글 conjoining 자모(초성 L+중성 V+종성 T)를 UAX#29 grapheme cluster로 묶어 한 셀에 저장하고 음절로 셰이핑·렌더한다. `ls` 출력의 한글 자모 분리·폭 2배 깨짐을 고친다.
- 상세·설계 결정·검증은 [Grapheme Cluster 저장·렌더링 전략](../grapheme-clustering.md)을 단일 출처로 둔다.

배경(현황 — "계획에 있었나/구현 안 됐나/누락인가"): 전략([폰트 전략](../font-strategy.md))은 "grapheme cluster는 UAX#29로 분절"을 적었으나 구현은 **combining 1개 저장**(`types.Cell.combining: ?u21`)에서 멈춘 알려진 후속이고, **한글 NFD 케이스는 계획에서 누락**됐다(다중 코드포인트 예시가 ZWJ 이모지·국기·skin-tone에 한정, docs 전체에 NFC/NFD/자모 0건). `width.zig`의 `isKeycapCombining` 주석도 "다중-combining 저장이 근본 해법"이라 자인.

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

각 단계는 작은 PR(progressive enhancement, legacy 공존). **현황: HG1~HG4 + HG-후속(ZWJ GB11)까지 구현 완료**(2026-08-29 재확인 — 이 줄이 그때까지 「미착수」로 남아 있었다). 코어에 `Cell.grapheme_id` + `TerminalCore.grapheme_store`, 분절기 `src/grapheme.zig`(UAX#29 GB6/7/8 · Hangul L/V/T · `clusterEnd` · `composeHangul`), recorded oracle `nfd_hangul`, chrome cluster 경계 가드가 모두 서 있다. **남은 것과 보류는 [grapheme-clustering.md](../grapheme-clustering.md) §7 이 단일 출처다** — 옛한글 Extended-A/B(`hangulClass` 범위 밖), chrome 의 ZWJ/RI/skin-tone, page-local 회수(보류).

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

## 터미널 「대답하는 쪽」 감사 (2026-09-08)

터미널 앱은 거의 다 **물어보고 켠다**(progressive enhancement). 그래서 **대답을 안 하면 구현해 둔 기능이
통째로 안 쓰인다.** maru는 「말하는 쪽」(모드 set·렌더)은 구현했는데 「대답하는 쪽」(query/report)을
체계적으로 빠뜨리고 있었고, terminal-browser(kitty graphics로 브라우저를 그리는 TUI)가 그 셋을 한 번에
밟아 드러났다.

| 기능 | 말하기 | 대답하기(수정 전) | 수정 |
| --- | --- | --- | --- |
| SGR-pixels 1016 등 사적 모드 | 구현됨 | DECRQM이 0(미인식) | `reportPrivateMode`를 `setPrivateModes`와 1:1로 |
| 셀·창 픽셀 크기 | 렌더러가 앎 | XTWINOPS 미구현 + winsize 픽셀 0 | `CSI 14/16/18 t` + `ws_xpixel`/`ws_ypixel` |
| kitty graphics | K1~K4 완료 | APC 응답 없음 | K5(위 ⑦) |

**셀 픽셀은 두 경로로 나간다**(앱마다 보는 곳이 다르다): `CSI 16t` 응답과 PTY winsize의 픽셀 필드.
후자는 `setCellPixels`가 값이 바뀔 때만 `TIOCSWINSZ`를 쏜다 — 이 ioctl은 자식에게 `SIGWINCH`를 보내므로
매 frame 주입되는 셀 메트릭을 그대로 흘리면 시그널 폭풍이 된다. 라이브 실측(오프스크린 캡처 하네스,
`font.size` 8→22 A/B): 셀 8×18 → 13×29 로 두 경로가 **같은 값으로 함께** 움직였다.

**남은 것**: in-band resize(`?2048`)는 여전히 미구현이고 DECRQM이 0으로 정직하게 답한다. color-scheme 통지(`?2031`)는
아래 절(2026-09-22)에서 구현했다.

### 색 구성 통지 `?2031` / `?996n` (구현 2026-09-22)

**재실측(터미널 코어 축, 2026-09-22)**: 이 터미널의 워크로드는 사실상 Claude Code·Codex(zsh 히스토리 최근 5,000줄: claude 103 ·
codex 44, 살아 있는 pane 11개 전부 claude). claude 2.1.278 을 pty 에서 띄워 8초 캡처하니 시작마다 `?2031h`×2 · `?2004h` · `?1004h` ·
`?1049h` · `CSI ? u` · `OSC 11;?`×2 · `CSI c`×4 를 보내고, 입력 파서(바이너리의 정규식)에 `\?997;[12]n` 분기가 있다 — **앱은 양쪽이 다
되어 있고 maru 만 0(모름)으로 답해** 라이브 테마 전환 뒤 claude 화면이 옛 테마로 남았다(`theme.follow-system` — 사용자 결정: 테마를
따라가는 것이 당연하다). `?2048` 은 바이너리에 참조만 있고 시작 8초 안엔 안 보냈다 — 보류.

**프로토콜**(xterm/contour DEC 사적 모드 2031): `CSI ? 2031 h/l` 구독·해지, DECRQM `CSI ? 2031 $ p` → `CSI ? 2031 ; 1|2 $ y`,
`CSI ? 996 n` 질의 → `CSI ? 997 ; 1 n`(다크)/`; 2 n`(라이트), 구독 중 등급이 바뀌면 같은 바이트를 스스로 보낸다.

**구현**: 코어에 `color_scheme_notify`(모드)·`color_scheme_dark_seen`(마지막으로 본 등급, `null` = 첫 주입 전)·`color_scheme_reports`
(만든 수 — 진단). 등급은 `isDarkBackground`(sRGB 상대 휘도 < 0.5 — 프리셋 실측: maru·gruvbox-dark·dracula 다크, solarized-light·
one-light 라이트, 경계 #808080 라이트·#7f7f7f 다크). **통지의 출처는 `setDefaultColors`** 다 — 그 함수는 이미 (1) 활성 surface 의 프레임
빌드가 매 tick, (2) reload·follow-system 전환이 `reapplyConfigPalette` → `set_default_colors` 명령으로 **모든 Term**(원격은 host wire) 에
부른다. 등급이 바뀌었고 구독 중일 때만 만든다 — 같은 색 재주입·첫 주입은 조용. RIS 가 모드를 끈다(`resetInputModes`). handoff codec
tag 100~102(optional — 구 host 호환) + inventory. 픽스처 `MARU_FORCE_SYS_APPEARANCE_LATER=<light|dark>@<ms>`.

**판정자**: 코어 3(구독·등급 전환·재주입·해지·DECRQM / `?996n` 주입 전·경계 / RIS) + 배선 1(`test-terminal-gate` «터미널 2031»:
`theme.follow-system` 으로 라이트→다크→(같은 값)→라이트 — 통지 1·1·2, 응답 버퍼는 리더가 비움). **자식 에코로는 못 본다** — `controlled_smoke`
자식이 `printf '%s'` 로 되돌린 ESC 시퀀스를 코어가 명령으로 삼킨다.

**실기 검증 ✅ (2026-09-22)** — 번들 앱을 헤드리스로 띄우고 pane 셸이 `cat -v` 로 받은 바이트를 화면에 보이게 해서 스크린샷으로 판정했다:
`^[[4;1R`(CPR) · `^[[?2031;2$y`(DECRQM 미구독) · `^[[?997;1n`(996 질의) 가 전부 자식에 도착하고, `?2031h` 로 구독한 셸은 외관 전환 순간
**질의 없이** `^[[?997;2n` 을 받는다(배경도 크림색으로 바뀐 상태).

⚠️ **처음엔 «통지가 안 온다»고 봤는데 둘 다 내 검증 도구의 결함이었다.** ⑴ 파일·`dd` 로 받아 적던 첫 프로브는 0 바이트였다 — 화면
(`cat -v`)으로 바꾸니 전부 보였다. ⑵ 그 뒤에도 통지만 안 왔는데, 코어 로그(`setDefaultColors` 의 seen/notify/changed + 모드 설정 지점)를
찍어 보니 **전환이 먼저, 구독이 나중**이었다 — 픽스처가 `awakeMs()`(부팅 기준 단조 시계)를 지연과 직접 비교해 첫 tick 에 발사됐다.
기준 시각을 잡아 고친 뒤 통지가 보인다. 「제품 결함처럼 보이는 것」이 두 번 연속 도구 결함이었다는 기록으로 남긴다.

**적대적 3회 (2026-09-22, PR 전)** — 1회차 코어 뮤턴트 9(C1 `changed` 반전 · C2 첫 주입도 통지 · C3 경계 `<=` · C4 996 극성 반전 · C5 RIS 가 안 끔 ·
C6 DECRQM 0 · C7 휘도 R 만 · C8 구독 무시 · C10 996 무응답) **전부 잡힘** — 이를 위해 판정자 하나를 더했다(구독이 첫 주입보다 앞선 경우·
해지 중 전환의 비소급·alt 화면 무관·순수 초록/빨강 채널 가중치)와 전용 step `test-color-scheme-notify`(변이 한 개에 전체 test 6 분을 안 쓴다).
2회차 배선 뮤턴트 3(W1 `reapplyConfigPalette` 가 `set_default_colors` 안 밈 · W3 카운터 안 올림 · W5 명령 적용 무동작) 잡힘 + `test-macos-only`
의 handoff 「모든 안정 필드가 non-default 로 한 번은 fixture 에 든다」 판정자가 **tag 100~102 누락을 잡아** fixture 를 더했다(구독 → 라이트
→ 다크). 3회차 실데이터: 프리셋 16개 전부 이름(light/latte/dawn)과 등급이 맞는다(판정자 «터미널 2031 실데이터»); 구독하지 않은 두 번째
Term 은 전환을 겪어도 통지 0; 사용자 config 는 지금 `theme.follow-system = false`·`preset = ghostty`(다크) — 켜야 값이 난다.

kitty graphics의 unicode placeholder(`U=1`)는 이제 **파싱해 virtual placement로 등록만 하고**, 실제
위치는 화면에 찍힌 U+10EEEE 셀이 정한다(렌더러 `placeholderAt`/`appendPlaceholderQuads`).

그 셀의 **id 인코딩은 24비트가 아니라 32비트다**: 전경색 RGB가 하위 24비트, **셋째 diacritic이
최상위 바이트**다(명세). 셋째를 안 읽으면 24비트를 넘는 id가 통째로 어긋나 **이미지가 아예 안 뜬다**.
이 자리는 `I=`(image number)와 정면으로 얽힌다 — 번호로 배정하는 id는 위에서부터 내려오므로, 배정
천장이 `0xFFFF_FFFE`이던 동안은 **언제나** 24비트를 넘었다. 두 기능은 각각 초록이었고 **조합에서만**
깨졌다. 지금은 (1) 셋째 diacritic을 읽고, (2) 배정 천장을 `core.kitty_auto_id_top`(0x00FF_FFFE)로
낮춰 셋째를 안 쓰는 앱까지 동작하게 한다 — 둘 다 판정자로 고정했다.

## kitty graphics PNG — 전 변종 지원 (해결, 2026-09-14)

`f=100` PNG 는 이제 **전 color type·bit depth·인터레이스**를 받는다: palette(3, tRNS 포함)·
grayscale(0/4)·truecolor(2/6), bit depth 1/2/4/8/16, Adam7. 출력은 **언제나 RGBA 8-bit** 라
코어에 색 종류 분기가 없다. 디코드는 **wuffs** 가 하고 `png.zig` 는 총량 회계·버퍼 소유·에러
환산만 한다.

### 어떻게 여기까지 왔나

- **예전(K3c)**: 8-bit truecolor(RGB/RGBA, non-interlaced)만 자체 clean-room 디코더로 풀고 나머지는
  `error.Unsupported` 로 거절했다. 사용자에게 보이는 증상은 **이미지가 그냥 안 뜨는 것**이었다.
- **현황 조사(2026-06-16)**: Ghostty 는 PNG 를 손으로 안 짜고 wuffs(벤더링 C 라이브러리, lazy dep)로
  디코드한다. kitty 는 libpng 를 쓴다. 즉 "풀 PNG 를 손코덱으로" 는 어느 레퍼런스도 안 간 길이다.
- **결정(2026-09-14, 사용자 논의)**: wuffs 를 lazy dependency 로 받는다. 판단의 축은 크기가 아니라
  **신뢰 경계**였다 — 이 코드가 다루는 것은 PTY·원격이 보내는 바이너리이고, 손코덱은 그 안전을
  앞으로 계속 우리가 지키겠다는 약속이다. 크기는 한 번 내는 비용이다.

### 무엇을 얼마나 치렀나 (실측)

| 자리 | 전 | 후 |
| --- | --- | --- |
| `packages/core/wasm/maru-vt.wasm` (brotli) | 53,112 B | 88,388 B (+66%) |
| 같은 것 (raw) | 160,619 B | 238,278 B |
| 같은 것 (gzip) | 62,249 B | 101,737 B |
| `png_wuffs.c` object (`-O2`, 네이티브) | — | 410,480 B |

크기를 이만큼에서 멈춘 것은 컴파일 플래그 둘이다(둘 다 `build.zig` 의 `attachPngCodec` 에 있다).
wuffs 는 **전 코덱이 한 파일**(3.6 MB C)이라 그냥 컴파일하면 안 쓰는 것까지 다 들어온다.

- `WUFFS_CONFIG__STATIC_FUNCTIONS` — 모든 함수가 내부 링크가 돼 안 쓰는 코덱이 죽은 코드로 걷힌다.
- `WUFFS_CONFIG__DST_PIXEL_FORMAT__ENABLE_ALLOWLIST` + `..._ALLOW_RGBA_NONPREMUL` — 우리가 요청하는
  출력 포맷 하나만 남긴다. 이 둘로 object 가 **1,096,368 → 410,480 B** 로 줄었다(실측, `-O2`).

### 배선에서 걸렸던 자리들

- **libc 할당자가 필요 없다.** 디코더 구조체(실측 44,632 B — 스택에 두기엔 크다)까지 **Zig 가**
  할당해 넘긴다. 그래서 `calloc`/`free` 가 링크에 안 남고 wasm32-freestanding 이 선다. wuffs 의
  `..._alloc()` 편의 생성자들이 유일한 호출처인데, 이름을 스텁으로 바꿔치기해 그 가지를 컴파일
  시점에 끊었다(`png_wuffs.c`) — 최적화 모드에 따라 심볼이 살아남고 죽는 것을 막는다.
- **`<stdlib.h>`·`<string.h>` 셰임**(`src/terminal/wuffs_cshim/`). freestanding 에는 libc 헤더가
  없다. 셰임은 **모든 타깃이 함께** 쓴다 — 타깃마다 다른 헤더를 보면 wasm 에서만 터지는 결함이
  생기고, 그 빌드가 CI 에서 제일 늦게 돈다.
- **C 를 `maru` 모듈에 직접 안 매단다.** 같은 모듈에 붙는 ObjC 어댑터들이 셰임 헤더를 보게 된다.
  전용 모듈(`png_codec.zig`)로 갈라 include 경로가 `png_wuffs.c` 하나에만 닿게 했다.
- **maru 루트 모듈을 세우는 자리가 열이다**(`src/maru.zig` 아홉 + `src/cross_target_surface.zig`).
  그 수는 **늘어난다** — 이 트랙 도중에도 다른 PR 이 하나를 더했고, 판정자가 그것을 잡았다.
  한 자리라도 빼먹으면 그 타깃만 링크가 깨진다 — 실측으로 `check-targets` 세 타깃이 다 빨개졌다.
  `tests/png_codec_wiring.zig` 가 그 자리 수를 센다.

### 거절선은 그대로다

- **머리를 먼저 읽고 총량 한계(320MB)를 넘으면 버퍼를 잡기 전에 거절한다.** 68 바이트짜리 PNG 가
  65535×65535 RGBA 라고 말하면 픽셀로는 17.2 GB 다. `png.zig` 의 판정자가 **결과가 아니라 동작을**
  잰다 — 요청된 가장 큰 할당을 기록해 45 KB(디코더 구조체) 넘게 안 잡는지 본다. 결과만 보는 판정자는
  「17 GB 를 요청해 실패했다」도 초록으로 읽는다(적대적 검증에서 실제로 그랬다).
- malformed·잘린 PNG 는 graceful 거부다(저장 안 됨, panic 없음).

### 프레임 PNG 와 `o=z` (2026-09-14)

둘 다 **명세가 요구하는 것**이라 함께 열었다. 예전의 `ENOTSUPP` 는 우리 한계였지 명세가 아니었다.

- **`o=z` + PNG**: *"You can specify compression for **any format**. The terminal emulator will
  decompress it before interpreting the pixel data."* PNG 는 이미 zlib 을 품으므로 이중 압축이지만,
  **전송을 일괄 압축하는 클라이언트**가 실제로 그렇게 보낸다.
- **프레임 PNG**(`a=f` + `f=100`): *"Transferring animation frame data is very similar to Transferring
  pixel data above"* — 프레임도 **같은 escape code** 를 쓰므로 `f=100` 이 합법이다.

**바운드의 근거가 바뀐다.** 픽셀 경로는 `w*h*bpp` 라는 **정확한 길이**가 곧 zlib bomb 바운드였다
(`inflateExact`). PNG 는 푼 것이 **또 PNG 파일**이라 길이를 미리 모르므로, 바운드를 길이가 아니라
**상한**으로 옮겼다(`inflateBounded`, 64 MiB). 그 상한은 **용량까지 묶는다** — 그냥 `appendSlice` 하면
ArrayList 가 1.5배씩 늘려 상한보다 더 잡는다(실측: 64 MiB 상한에서 최대 요청이 69,697,664 B 였다.
지금은 정확히 67,108,864 B). 판정자가 **결과가 아니라 그 최대 할당량**을 잰다.

**PNG 프레임은 루트의 픽셀 형식을 따른다.** 디코더는 언제나 RGBA 를 내지만 합성 대상은 루트 프레임
버퍼다. 루트가 `f=24` 로 만들어졌으면 bpp 3 이므로 알파를 떨군다 — 거절하지 않는 이유는 「RGB 루트 +
PNG 프레임」이 명세상 합법인 조합이기 때문이다. `s`/`v` 는 루트 전송과 같이 **무시한다**(PNG 가
자기기술한다).

### 아직 아닌 것

- `N`(사용 힌트, `N=1` = transient) 미파싱 — 힌트라 무시가 합법이고, 섞어 보내도 명령은 `OK` 다.

## kitty graphics 전송 매체 — `t=f`/`t=t`/`t=s` (구현 완료 2026-09-20; 아래는 결정 기록)

**구현됐다(2026-09-20).** `kitten icat --detect-support` 가 maru 에서 `memory` 를 답하고, `--transfer-mode=file`·
`memory` 로 보낸 이미지가 in-process·세션호스트 양쪽에서 뜬다(실측 — 호스트 로그 `img=57706` = 120×60 RGBA 두 장).
설계는 아래 (B) 비동기이되 **파서가 매체 job 뒤에서 멈춘다**는 조각이 붙었다:

- 코어(`kitty.kittyTransmitMedia`)는 경로를 읽지 않는다 — `KittyPendingJob{medium, query}` 를 큐에 넣고
  `.deferred` 다. 리더가 없는 코어(`kitty_defer_decode` 꺼짐 — 헤드리스·wasm·메인 스레드 인라인)는 그대로
  `ENOTSUPP` 라 앱이 direct 로 폴백한다.
- **파서는 매체 job 이 큐에 남는 순간 멈춘다**(`parser.feedUntil` → `core.writeUntilMediaJob`, 소비한 바이트 수를
  돌려준다). 리더(`pty_reader.applyToCore`)가 그 job 을 락 밖에서 읽어(`app/kitty_media_io.zig`) 완료·응답한 뒤
  나머지를 다시 넣는다. **이유는 응답 순서다** — 명세 «질의에는 다른 입력을 처리하기 전에 즉시 답하라», 그리고
  icat 은 `a=q`(inline)·`a=q`(t=t)·`a=q`(t=s)·DA1 을 **한 write** 로 보낸다(실측). DA1 응답이 먼저 나가면 그
  매체는 «미지원» 이다. 아래 (B) 서술이 이 순서 문제를 못 보고 있었다 — 9/14 의 실측은 «전송 뒤 표시» 순서만
  봤지 «질의 뒤 DA1» 순서는 안 봤다. direct job 은 멈추지 않는다(큰 이미지마다 파서가 끊기면 안 된다).
- 읽기 규칙(`kitty_media_io`): 일반 파일만(장치·소켓·디렉터리 거부, 심링크는 따라감). `t=t` 는 읽은 뒤 **정규화된**
  경로가 `/tmp`·`/var/tmp`·`/dev/shm`·`TMPDIR` 안이고 `tty-graphics-protocol` 을 품을 때만 지운다(macOS 의
  `/tmp`→`/private/tmp` 심링크라 루트도 정규화한다). `t=s` 는 열렸으면 언제나 `shm_unlink`(mmap 복사). 이름은
  `/` 없이도 받는다 — kitten 이 macOS 에서 `icat-<랜덤>` 을 보낸다. 크기 상한은 코어 이미지 총량 한도.
- **`S` 는 상한이지 정확한 길이가 아니다.** icat 의 탐침은 3 바이트 픽셀을 두고 `S=` 에 **경로 길이**(159)·**shm
  이름 길이**(18)를 싣고, shm 은 페이지(16 KiB)로 올라와 있다 — kitty 는 그것에 OK 로 답한다. 그래서 `S` 는 있는
  데까지로 잘리고, raw 픽셀은 **모자라면 EINVAL, 넘치면 버린다**(`decodeKittyRaw`). `O` 가 자원 밖이면 `EBADF`.
- **패딩 없는 base64.** kitten 은 경로·이름을 `=` 없이 보낸다(160 바이트 경로가 214 자). 표준 코덱만 쓰면 길이가
  3 의 배수인 경로만 되는 결함이 된다 — `kitty.base64Decoder` 가 꼬리 `=` 유무로 코덱을 고른다(direct payload 도).
- **id 없는 `a=T`.** `--transfer-mode=file` 은 `i=` 도 `I=` 도 없이 보낸다. 명세대로 터미널이 내부 id 를 배정하고
  (`allocateInternalImageId`, 자동 대역) 표시하되 **응답하지 않는다**(`internal_id`). 전에는 EINVAL 로 조용히 버려
  이미지가 안 떴다 — 매체와 무관하게 있던 구멍이다.
- **DA1 이 `?6c` 에서 `?62;22c` 로 바뀌었다.** kitten 은 `CSI ?6c`(VT102)를 DA1 응답으로 **안 알아봐**
  `--detect-support` 가 타임아웃했다(`?62c`·`?1;2c`·`?6;0c` 는 통과, `?6c` 만 두 번 다 멈춤 — 하네스 실측). Ghostty
  와 같은 값(VT220 + ANSI 색)으로 답한다. 그 앞의 OK 셋은 DA1 을 못 알아보면 전부 헛것이다.
- 응답 코드 하나가 늘었다: `EBADF:transmission medium unreadable`(없음·특수 파일·`O` 범위 밖·상한 초과).
- 판정자: 코어 8(멈춤·EBADF/EINVAL·질의 순서·direct 는 안 멈춤·프레임·S/O·패딩 없는 base64·id 없는 전송) ·
  `kitty_media_io` 6(범위·`t=f`·`t=t` 삭제 규칙·정규화 비교·`t=s` unlink·PNG) · 리더 2(한 청크 질의 셋+DA1 의 응답
  순서와 임시 파일 소비 · id 없는 `a=T`). 돌연변이 10 종 빨강(파서 멈춤·direct 멈춤·리더 없어도 미룸·질의가
  자리 만듦·S/O 무시·표식 검사·shm unlink·리더가 안 멈춤·내부 id 침묵·내부 id 배정).

### 이전 현황(2026-09-14, 참고)

`t=d`(inline base64)만 받고 나머지 셋은 **명시 ENOTSUPP** 였다. 앱은 그 응답을 보고 곧바로 inline
으로 폴백한다(terminal-browser 는 shm→file→inline 순으로 묻는다 — 실측 기록은 위 K5 절).

**함께 빠져 있는 키 둘**(2026-09-14 명세 대조에서 발견): `S`(파일에서 읽을 **크기**)와 `O`(읽기 시작
**오프셋**)는 파서가 **아예 안 읽는다**(`else => {}` 로 무시). 둘 다 `t=f/t/s` 전용이라 지금은 무해하지만
**매체 전송의 일부**다 — 구현할 때 함께 해야 한다. 안 그러면 「파일 앞부분 N 바이트만 픽셀」인 전송
(앱이 헤더를 붙여 쓰는 경우)이 조용히 깨진다. 같은 자리에서 `N`(클라이언트→터미널 **사용 힌트**
비트마스크)도 미파싱인 것을 확인했다 — 힌트라 무시가 합법이고, 섞어 보내도 명령은 `OK` 다(실측).

### 이 프로토콜이 왜 있나

`t=` 는 「무엇을 그릴까」가 아니라 **「픽셀을 어떻게 나를까」** 다. PTY 가 텍스트 통로라 바이너리를
base64 로 감싸야 하고(+33%), 4096B 씩 쪼개야 한다(`m=1`). 보내는 쪽과 터미널이 **같은 기계**면 픽셀을
그 좁은 통로로 밀 이유가 없고 **주소만** 건네면 된다. 셋으로 나뉜 이유는 청소 책임이다 — `t=f` 는
기존 파일(터미널이 안 지움), `t=t` 는 앱이 만든 임시 파일(**터미널이 읽고 지움** — 앱은 터미널이 언제
다 읽었는지 알 수 없어 자기가 지우면 경합), `t=s` 는 파일시스템을 아예 안 타는 POSIX 공유메모리
(읽고 `shm_unlink`). `t=d` 는 없앨 수 없다 — ssh 로 붙으면 터미널이 다른 기계라 경로도 shm 도 없다.

### 실측(같은 기계, 400x300 RGBA 한 장 = 픽셀 468 KiB)

| 구간 | inline(`t=d`) | 경로(`t=f`/`t=s`) |
|---|---|---|
| PTY 통과 | base64 625 KiB → **2.64 ms** (232 MB/s) | 경로 48 B → **0.10 ms** |
| 코어 파싱+디코드+저장 | **2.12 ms** | base64 없음 + 파일 읽기 |
| 합계 | **약 4.7 ms/장** | 약 0.5 ms/장 |

**한 장이면 안 보인다.** 값이 나오는 건 연속 전송이다 — 30fps 이미지 스트림이면 141 ms/s =
**코어의 약 14%** vs 경로 방식 1.5%. 그리고 **기능이 없어서 못 하는 일은 없다**(폴백이 동작한다).
즉 이건 능력이 아니라 **최적화**다.

원격 session-host 에서도 이득은 같다 — 프로그램과 코어가 **둘 다 원격 기계에 있어** 파일·shm 을
공유한다(애니메이션과 달리 전송로가 이 최적화를 무력화하지 않는다).

### 실제 클라이언트가 무엇을 보내나 (실측 2026-09-14, PTY 하네스로 바이트 캡처)

**방법**: 클라이언트를 PTY 안에서 돌리고 그 프로그램이 **쓰는 바이트**를 그대로 떴다. 하네스가
질의(OSC 10/11·CSI 18t/14t/16t·DA1·kitty `a=q`)에 답하는 **가짜 터미널** 노릇을 한다 — 안 답하면
클라이언트가 「능력 없음」으로 판정하고 폴백해서 정작 보고 싶은 경로가 안 나온다.
kitty 는 **소스를 읽지 않고 바이너리의 출력만** 관측했다(copyleft — [레퍼런스](../references.md) 규칙).

| 클라이언트 | 보내는 전송 명령 |
| --- | --- |
| chafa 1.18.2 | `a=T,U=1,q=2,f=32,s=130,v=80,c=13,r=4,i=1,m=1` + 청크 83 개 — `t=` 없음(inline) |
| timg | `a=T,i=…,q=2,f=100,m=0` — **PNG inline** |
| kitten icat 0.48.2 `--transfer-mode=memory` | `a=T,q=2,f=100,**t=s**,C=1,U=1,s=13,v=7,**S=879**,X=3,c=2,r=1,i=…` · payload = `icat-CVTN4NH4YKOZW` |
| 같은 것 `--transfer-mode=file` | `a=T,q=2,f=100,**t=f**,C=1,U=1,…` · payload = 파일 절대경로 |

`detect` 모드는 전송 전에 **세 매체를 `a=q` 로 물어본다**:

```
a=q,f=24,s=1,v=1,S=3,i=1         payload "123"          ← inline
a=q,f=24,t=t,s=1,v=1,S=87,i=2    payload <임시파일 경로>  ← temp file
a=q,f=24,t=s,s=1,v=1,S=18,i=3    payload <shm 이름>      ← shared memory
```

**여기서 나온 사실 셋.**

1. **아무도 전송과 표시를 나누지 않는다.** 셋 다 `a=T`(전송+표시 한 명령)다. `a=t` 뒤에 따로 `a=p`
   를 보내는 클라이언트가 캡처에 **하나도 없었다**. 아래 설계 갈림길이 이 사실로 갈린다.
2. **`S=`(크기)는 첫 바이트부터 온다.** 탐침에도 `S=3`·`S=87`·`S=18` 이 실려 있다. 위에서 「미파싱」
   으로 적어 둔 키가 선택 사항이 아니라는 뜻이다.
3. **`OK` 라고 답하는 것만으로는 안 된다.** 하네스가 탐침에 OK 를 줬는데도 icat 이 전송으로 넘어가지
   않았다 — 터미널이 **자원을 실제로 먹었는지**(임시 파일 삭제·shm unlink) 확인하기 때문이다.
   즉 `t=t` 의 삭제는 예의가 아니라 **계약**이다.

그리고 icat 은 shm·파일에 **PNG 를 넣는다**(`f=100`) — 전 변종 PNG 디코드가 이 경로의 전제다(완료).

**tmux 안에서는 `detect` 가 inline 을 고른다**(실측). 래핑된 통로로는 파일·shm 을 못 믿기 때문이다 —
즉 tmux 사용자에게는 이 최적화가 애초에 안 걸린다.

### 설계 갈림길: 코어는 I/O 를 하지 않는다

`TerminalCore` 는 파일을 열지 않는다(경로 **문자열** 조작만 한다 — `std.fs.path.*`). 부수효과는
「코어가 pending 을 기록하고 플랫폼이 나중에 처리」로 빼 왔고, **그 선례가 둘 있다**:
OSC 52 클립보드 읽기(`clipboard_read_pending`)와 파일 선택창(`take_file_pick_request` →
`provide_picked_file`). 코어 순수성을 **강제하는 판정자는 없다** — 관례이지 잠긴 계약이 아니다.

- **(A) 동기 reader 이음매** — 코어에 nullable 콜백(`ctx` + `read fn`)을 두고 host 가 주입한다.
  wasm·헤드리스는 null 이라 지금처럼 ENOTSUPP. 구현이 작다. 대가는 **코어에 I/O 능력이 생기는
  첫 선례**다.
- **(B) 비동기 2단계** — 코어가 요청만 기록하고 플랫폼이 읽어 되먹인다. 순수성을 지킨다.
  **예전에는 「`a=t` 직후 `a=p` 가 오면 ENOENT」라는 순서 위험 때문에 이쪽을 꺼렸는데, 위 실측이
  그 근거를 없앴다** — 아무도 둘을 나눠 보내지 않는다.
  남는 것은 **배치 맥락**이다: `a=T` 는 커서 위치에 의존할 수 있으므로(timg 는 `U=1` 이 없다)
  pending 에 **그때의 커서와 display 키를 함께 박아** 둬야 한다. 큐가 아니라 스냅샷이고,
  OSC 52·파일 선택창이 이미 쓰는 모양이다. icat·chafa 는 `U=1`(placeholder 기준)이라 그것조차
  필요 없다.
- **(C) 현행 유지** — 폴백이 동작하므로 기능은 멀쩡하고, 비용은 위 4.7 ms/장뿐이다.

### 보안: 소유자 검사는 연극이다

이스케이프는 신뢰 경계 밖에서 온다(ssh 세션, `cat` 한 악성 파일). 처음에 「`st_uid == geteuid()` 검사」를
방어로 생각했는데 위협 모델을 따라가면 **아무것도 막지 못한다**: 터미널은 사용자 권한으로 돌므로
터미널이 읽을 수 있는 파일은 사용자도 읽을 수 있고, 원격이 보낸 이스케이프가 겨누는 파일도 **내
소유**라 검사를 그냥 통과한다.

하중을 받는 방어선은 **`t=t` 의 삭제 경로 제한**이다. 제한이 없으면 원격이 보낸 한 줄로 내 파일을
**지울 수 있다**(정보 누출이 아니라 파괴). kitty 가 임시 경로로 제한하는 이유가 이것이다. 나머지
누출(응답 코드로 파일 존재·크기 탐지)은 이 기능에 **내재**하며 kitty 도 같다 — 없애려면 기능을
안 하는 수밖에 없다.

### 곁가지: 미지원을 **알 수 없는** delete 타깃이 있었다 (그 뒤 구현됨)

명세 대조 중 실측한 것(이 절의 주제는 아니지만 같은 그물에 걸렸다). **아래는 2026-09-14 에 여섯
타깃을 구현하기 전의 기록이다** — 지금은 `a=d` 11/11 이라 「미지원이라 침묵한다」는 상태가 없다.
다만 **관측 가능성이 타깃마다 다르다**는 사실 자체는 남아 있어, 새 타깃을 더할 때 다시 부딪힌다.
`a=d` 의 미지원 타깃은 대부분
`ENOTSUPP` 로 답하지만, **`d=r`/`d=x`/`d=y` 는 `i=` 없이 오면 무응답**이다. 「`i=` 가 없으면 응답하지
않는다」는 명세 규칙(어느 명령의 응답인지 못 가리므로) 때문이고, 그런데 `d=r` 은 명세상 `x`/`y` 로
**id 범위**를 주는 형태라 `i=` 를 안 쓰는 것이 자연스럽다. 그래서 그 타깃을 쓰는 앱은 지원 여부를
알 수 없이 침묵만 받는다(`i=` 를 붙이면 `ENOTSUPP` 가 온다 — 실측으로 확인).

kitty 도 같은 구조라 우리 쪽 결함은 아니지만, **「미지원인데 침묵한다」는 갈래가 실재한다**는 사실은
기록해 둔다 — delete 타깃을 구현할 때 이 셋의 관측 가능성이 다르다는 점을 알고 시작해야 한다.

### 결정 이력(사용자 합의 2026-09-14 → 착수 2026-09-19)

~~**C(현행 유지) — 보류.** 최적화이고 폴백이 동작하므로 급하지 않다.~~ 2026-09-19 사용자 결정으로 «kitty 100%»
를 닫기 위해 착수했고 2026-09-20 위와 같이 구현됐다.

**(B) 비동기다** — 2026-09-14 실측으로 결정을 (A)에서 (B)로 바꿨다. (A)를 기울게 했던
유일한 근거가 「`a=t` 직후 `a=p` 순서 위험」이었는데 **그런 클라이언트가 없다**(위 캡처). 코어 순수성을
깨는 선례를 만들 이유가 사라졌다. 함께 갈 것:

- `S`/`O` 파싱 — **선택이 아니다**. 탐침에도 `S=` 가 실려 온다.
- `t=t` 삭제는 **임시 경로로만** — 삭제는 예의가 아니라 계약이다(안 지우면 클라이언트가 그 매체를
  버린다). 경로 제한이 없으면 원격이 보낸 한 줄로 내 파일이 지워진다.
- 크기 한도를 기존 이미지 총량 한계에 합산.
- pending 에 **배치 맥락(커서·display 키)을 함께 기록** — 비동기의 유일한 추가 부담이다.
- 소유자 검사는 **넣지 않는다**(아래 근거 — 연극이다).

판정자는 삭제 경로 제한·크기 한도·`S`/`O` 경계(파일보다 큰 `S`, 파일 끝을 넘는 `O`)·**비동기 완료
전에 온 명령**을 겨눈다.

착수 신호: 이미지가 **연속으로** 흐르는 워크플로(icat 애니메이션·이미지 뷰어 스크롤·terminal-browser
같은 TUI)에서 CPU 가 실제로 아픈 것이 관측될 때. 그때 위 4.7 ms/장을 그 워크플로의 프레임률로 곱해
재확인하고 시작한다. **tmux 안이면 애초에 안 걸린다**(실측 — `detect` 가 inline 을 고른다).

**실측을 다시 하려면**: `kitten` 은 `/Applications/kitty.app/Contents/MacOS/kitten` 에 있고,
PTY 캡처 하네스는 질의에 답하고 **자원을 실제로 소비해야** 한다(그러지 않으면 탐침에서 멈춘다).
`TMUX` 환경변수를 지우지 않으면 `detect` 가 inline 으로 새 버린다.

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
