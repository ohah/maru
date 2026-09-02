# 설정 — 입력과 키바인딩

키 입력 관련 설정의 배경이다. `input.page-keys`·`input.shift-enter`·`input.ime-enter`의 선택지와 `keybind` 줄 형식을 적는다. 단축키 체계 전반은 [키 입력과 단축키](key-input-and-shortcuts.md)가 소유한다.

> 키 표와 파일 형식은 [설정(config) 파일](configuration.md)이 소유한다. 키별 배경은 [텍스트·테마](configuration-text.md) · [입력·키바인딩](configuration-input.md) · [셸·환경](configuration-shell.md)로 나뉜다.

### PageUp/PageDown (`input.page-keys`)

메인 화면(셸 프롬프트)에서 PageUp/PageDown를 어떻게 다룰지 정한다. **alt 화면(vim·less 등)에선
어느 값이든 항상 `\e[5~`/`\e[6~`를 앱으로 보내** 앱이 자체 페이징한다.

- `scroll` (기본): Terminal.app/iTerm2처럼 메인 화면에서 Maru 스크롤백을 한 페이지씩 스크롤한다.
  셸로 `\e[5~`를 보내지 않아 **셸 keymap(vi/emacs)·프레임워크와 무관하게 입력줄이 안 깨진다** —
  Mac 관례이자 가장 견고하다. 메인 화면 앱(드물게 PageUp을 쓰는 TUI)에는 키가 전달되지 않는다.
- `passthrough` (opt-in): xterm/Ghostty처럼 메인 화면에서도 `\e[5~`/`\e[6~`를 PTY로 보낸다.
  레퍼런스와 일치하지만 셸 프롬프트에서 깨진다 — emacs keymap은 BEL+`~`를 입력줄에 박고, **vi
  keymap은 끝 `~`를 vi-swap-case로 해석해 대소문자를 토글한다**(실측 확인). xterm 순정이 필요할 때만.

> `Shift+PageUp`/`Shift+PageDown`은 이 설정과 무관하게 항상 스크롤백을 스크롤한다.

### Shift+Enter (`input.shift-enter`)

Shift+Enter를 어떻게 인코딩할지 정한다. macOS 터미널의 키 인코딩은 Shift를 Enter에 반영하지 않아, 기본 동작이면
Shift+Enter가 일반 Enter와 똑같은 `\r` 한 바이트를 보낸다 — 그래서 셸/CLI가 둘을 **구분하지 못해** 줄바꿈이 아니라
명령 실행이 된다. Option(Alt)+Enter는 `\x1b\r`(ESC+CR)이라 앱이 별도 키로 인식해 멀티라인 줄바꿈으로 처리한다.

- `newline` (기본): Shift+Enter를 **Option+Enter와 같은 바이트**로 보낸다 — kitty 키보드 프로토콜이 꺼진 일반
  셸에선 `\x1b\r`(ESC+CR), 켜진 앱에선 `\x1b[13;3u`(Alt+Enter via CSI u). 어느 쪽이든 Option+Enter와 **항상 같은**
  시퀀스라(내부적으로 Meta 수정자로 바꿔 인코딩한다), Claude Code 등 CLI/TUI가 줄바꿈(전송 없이 다음 줄)으로
  인식한다 — 모던 에디터/브라우저의 Shift+Enter 기대치와 일치한다.
- `native` (opt-out): Shift를 인코딩에 반영하지 않는 기존 터미널 동작. 일반 셸에선 `\r`(일반 Enter와 동일),
  kitty 키보드 프로토콜이 켜진 앱에선 `\x1b[13;2u`(CSI u). xterm/Ghostty 순정 동작이 필요할 때만.

> Shift는 chord modifier가 아니라 IME 키 트랜잭션을 거쳐 들어오므로, 이 변환은 **모달(Find의 Shift+Enter=이전
> 매치 등)이 키를 소비하지 않고 PTY로 내려보내는 경우**에만 적용된다. IME 조합 중 Shift+Enter도 같은 규칙을 따른다.

> 변환은 keybind 해석 **앞에서** 일어난다(Shift+Enter를 Option+Enter로 바꾼 뒤 resolver가 본다). 그래서
> `keybind = Opt+Enter = <action>`을 두면 Shift+Enter도 그 action을 발동하고, `keybind = Shift+Enter = <action>`은
> `newline`에선 닿지 않는다(변환이 먼저 적용됨). Shift+Enter에 직접 바인딩을 걸려면 `native`로 둔다.

### IME 조합 중 Enter (`input.ime-enter`)

한글 등 IME 조합 중에 Enter를 눌렀을 때의 동작이다. macOS 입력기는 이 Enter를 **조합 확정**에만 쓰고 개행은
소비하므로(Terminal.app/Ghostty 기본), 기본 동작이면 Enter를 한 번 더 눌러야 줄바꿈/실행이 된다. 웹 브라우저의
터미널은 확정과 개행을 한 번에 처리한다 — 그 동작을 기본값으로 둔다.

- `newline` (기본): 조합을 확정하면서 그 Enter의 **개행도 함께 보낸다**(엔터 한 번에 확정+실행 — 브라우저 동작).
  확정 텍스트 전송 뒤 Enter를 replay하며, 입력기가 Enter를 이미 소비했으므로 중복 개행은 생기지 않는다.
- `commit-only` (opt-out): 조합만 확정하고 개행은 보내지 않는다(macOS 네이티브 입력기 기본). 확정 후 Enter를
  한 번 더 눌러야 개행된다.

> `input.shift-enter`와 직교한다 — IME 조합 중 Shift+Enter를 확정하면, replay되는 Enter가 `input.shift-enter`
> 규칙대로 인코딩된다(`newline`이면 `\x1b\r`).

### 키바인딩 (`keybind`)

`keybind = <조합> = <action>` 한 줄에 하나씩, 여러 줄을 둘 수 있다(값 안에 `=`가 한 번 더 있는
형태다 — config의 첫 `=`는 `keybind` key를, 두 번째 `=`는 조합과 action을 가른다).

```conf
keybind = Cmd+T = new_tab
keybind = Cmd+W = close_tab
keybind = Cmd+Shift+Right = next_tab
keybind = Cmd+Shift+Left = previous_tab
keybind = Ctrl+Cmd+1 = select_tab:0
keybind = Cmd+D = unbind
keybind = F2 = text:hello
keybind = Cmd+E = ctrl:[
keybind = F4 = esc:[2J
```

- **조합**: `Cmd`/`Ctrl`/`Alt`/`Shift`(대소문자 무관)를 `+`로 잇고 마지막에 키. 키는 글자 한 자,
  숫자, `Esc`/`Tab`/`Enter`/`Space`/`Backspace`/`Up`/`Down`/`Left`/`Right`/`F1`~`F24`, 그리고 `+`
  자체는 `Plus`로 쓴다(예: `Cmd+Plus`).
- **action**: 워크스페이스 `new_tab`·`close_tab`·`next_tab`·`previous_tab`·`select_tab:N`(N=0부터),
  포커스 기반 닫기 `close_focused`, Term 전용 `new_term`·`close_term`·`next_term`·`previous_term`, 분할 `split_horizontal`·`split_vertical`,
  pane 포커스 `focus_pane_left`·`focus_pane_right`·`focus_pane_up`·`focus_pane_down`, split 순환 `next_pane`·`previous_pane`,
  폰트 크기 `increase_font_size`·`decrease_font_size`(보폭 고정 1pt)·`reset_font_size`·`set_font_size:N`
  (N=절대 pt, 6~72로 클램프 — 예: `Ctrl+Cmd+1 = set_font_size:14`로 크기 프리셋), 그리고 `select_all`·
  `clear_screen`(화면+스크롤백 비우기, 빌트인 ⌘K — alt 화면 무동작, 셸 프롬프트면 ^L로 재그림. 자세히는
  [키 입력과 단축키](key-input-and-shortcuts.md))·`toggle_find`·`toggle_find_replace`
  ·`toggle_find_match_case`(빌트인 `⌥⌘C`)·`toggle_find_whole_word`(빌트인 `⌥⌘W`)
  ·`toggle_find_in_selection`(빌트인 `⌥⌘L`)·`toggle_find_diff_side`(빌트인 `⌥⌘D` — 비교 뷰에서
  검색할 열을 왼쪽↔오른쪽으로 넘긴다. 비교 Term 이 아니면 무동작이고, 안 넘긴 동안은 「선택이 있는
  열, 없으면 왼쪽」이 답한다) — **넷 다 편집기 문서를 검색 중일 때만 뜻이 있다**
  (스크롤백·웹은 이 값을 안 읽는다. 웹은 WebKit 에 낱말 경계가 없어 셋에 다 걸면 거기서만 조용히
  무시된다 — [visual-mapping §5.1](native-editor-visual-mapping.md)). 켠 규칙은 카운터 앞에
  `Aa`·`W`·`Sel` 로 뜨고, 비교 뷰에서는 검색 중인 열이 `L`·`R` 로 함께 뜬다 — **왼쪽은 언제나 옛
  판이라**, 그 표시가 없으면 방금 추가한 이름을 찾다 만난 0을 설명할 길이 없다. **찾기가 떠 있는 동안 눌러야 한다** — 오버레이가 열리면 키를 전부
  소비하므로 그 chord 들은 사전 가로채기로 처리되고, 닫혀 있으면 무동작이다.
  「선택 영역 내에서만」의 범위는 **찾기를 여는 순간**의 선택 사본이라 그 뒤 선택이 움직여도
  안 흔들린다(현재 일치가 선택을 옮기는 계약과 같은 필드를 두 뜻으로 쓰지 않기 위해서다)
  (찾기를 **바꾸기 줄과 함께** 연다 — 빌트인 `⌥⌘F`. 이미 열려 있으면 닫지 않고 바꾸기 줄만 켜므로
  `⌘F`로 친 검색어가 살아 있다. 바꾸기는 **편집기 문서에서만** 동작한다 — 스크롤백·웹 페이지는
  읽기 전용이라 그 대상에서는 줄이 뜨지 않는다)·`find_next`·
  `find_previous`·`toggle_command_palette`·`toggle_settings`(세팅 화면 ⌘,)·`reset_settings`
  (설정을 기본값으로 되돌리는 통합 리셋 — 커맨드 팝업 "Reset All Settings to Defaults". 단
  `session.keep-alive-after-quit`은 위 소유권 예외대로 현재 값을 보존·materialize하고, 나머지 config 파일의
  schema·특수 키·주석은 내장 기본 상태로 돌린다).
- **편집기 전용 action**: `toggle_editor_wrap`(그 뷰의 줄 바꿈 토글)·`fold_all`·`unfold_all`·
  `fold_level_1`·`fold_level_2`·`fold_level_3`·`toggle_symbol_picker`. 레벨은 중첩 **겹수**다(1이 문서
  맨 바깥이고, 레벨끼리는 합치지 않고 갈아 끼운다 —
  [visual-mapping §4.1f](native-editor-visual-mapping.md)).
  `toggle_symbol_picker`는 **파일 안 심볼을 필터해 그 자리로 간다**(VSCode `⇧⌘O`. 찾기가 모든 글자에서
  문자열을 보는 것과 달리 **심볼 이름만** 본다 — [native-editor-ui.md §7.5](native-editor-ui.md)).
  **`toggle_symbol_picker`만 빌트인 chord가 있다 — `⇧⌘O`**(2026-08-31). 나머지 여섯은 아직 없고,
  **이유는 하나가 아니다**:

  | 이유 | 해당 action | 무엇이 막고 있나 |
  |---|---|---|
  | **뺏을 것이 없다** | `toggle_symbol_picker` | `⇧⌘O`가 기본 표 어디에도 없다. 배선 전에는 `resolve`의 fallthrough에서 `.ignored`라 **누르면 아무 일도 안 일어나는** 상태였다 |
  | **Option 단독은 터미널 입력이다** | `toggle_editor_wrap` | VSCode는 `⌥Z`인데, 기본 표에 **Option만 쓰는 chord가 하나도 없다**(모든 `⌥`가 `⌘`과 함께다). 첫 Option 단독 바인딩은 터미널의 Meta/ESC 입력을 뺏는다 |
  | **한 chord로 못 적는다** | `fold_all`·`unfold_all`·`fold_level_1..3` | VSCode가 `⌘K ⌘0`처럼 **두 키 시퀀스**를 쓰는데 `KeyChord`는 수식자+키 **하나**다. 게다가 `⌘K`는 `clear_screen`이 갖고 있다. VSCode의 커서 접기 `⌥⌘[`·`⌥⌘]`는 `previous_term`·`next_term`이 쓴다 |

  **컨텍스트가 필요한 부류와 섞지 않는다.** 「편집기 Term 컨텍스트가 서야 한다」는 조건은
  **이미 남이 쓰는 chord를 양보받을 때**의 것이고(`⌘C` — 터미널 선택이 쓴다, native-editor §9.1),
  비어 있는 chord에는 해당하지 않는다. **컨텍스트 게이트는 액션 쪽이 이미 갖고 있다** —
  `toggle_symbol_picker`는 `symbolPickerReadiness`가 `.not_editor`를 먼저 답하므로 터미널 Term에서
  눌러도 전과 같다. 이 구분을 2026-08-27에 `⌘Z`·`⌘⇧Z`·`⌘S`가 먼저 세웠다
  (docs/plans/native-editor.md "키 chord").

  나머지 여섯은 그때까지 커맨드 팝업과 이 키바인딩으로 쓴다.
  편집기가 아닌 Term에서는 **무동작**이다(눌러도 아무 일이 없다).
- **`unbind`**: action 자리에 `unbind`를 적으면 그 조합의 **빌트인 기본 동작을 끈다**(예:
  `keybind = Cmd+T = unbind` → Cmd+T가 새 Term을 안 연다). 끈 조합은 빌트인 테이블을 건너뛰어
  `Cmd`+키는 아무 동작도 안 하고, 그 외 조합은 셸로 입력이 전달된다. 다른 action을 지정하면(덮어쓰기)
  그게 우선이라, `unbind`는 "끄기" 전용이다.
- **터미널 매크로**: action 자리에 아래 접두사를 쓰면 그 조합이 **셸로 바이트를 보낸다**(앱 동작 대신):
  - `text:<문자열>` — 문자열을 그대로 입력(예: `text:hello`).
  - `esc:<payload>` — `ESC`(0x1b)를 앞에 붙인 시퀀스(예: `esc:[2J` → 화면 지우기 `ESC [2J`).
  - `ctrl:<글자 한 자>` — 그 글자의 컨트롤 바이트(예: `ctrl:[` → `ESC`, `ctrl:c` → `Ctrl+C`).
    매핑 가능한 글자는 `@`, `A`~`Z`, `[`, `\`, `]`, `^`, `_`, `Space`, `?`다(C0 컨트롤).
  접두사인데 payload가 비었거나(`text:`) `ctrl:`이 글자 한 자가 아니거나 매핑 안 되면 그 줄만 무시(forgiving).
- **전역 단축키 (`global:`)**: 조합 앞에 `global:`을 붙이면 그 단축키를 **OS 레벨에 등록**해, Maru가
  활성 창이 아니어도 동작한다(`keybind = global:<조합> = <전역 action>`). 전역 action은:
  - `toggle_window` — 창이 숨김/비활성이면 보이고 앞으로(show + 활성화), 이미 활성+보임이면 숨긴다(토글).
  - `show_window` — 항상 창을 보이고 앞으로 가져온다(숨기지 않음).
  - `toggle_quick_terminal` — quick terminal(별도 세션 오버레이 패널, 화면 상단 드롭다운)을 토글한다.
    첫 호출에서 두 번째 셸 세션을 띄우고, 다시 누르면 숨긴다. 화면 위에서 슬라이드해 내려오고/올라가며,
    포커스를 잃으면(다른 창/앱 클릭) 자동으로 숨는다.

  예: `keybind = global:Cmd+Alt+Space = toggle_window`. 전역 단축키는 **별도 네임스페이스**라 같은 조합을
  in-app 바인딩으로도 둘 수 있고(충돌 아님), 전역끼리만 중복을 막는다(첫 줄 우선). 매핑 가능한 키는 글자/
  숫자/`Space`/방향/`F1`~`F20` 등이며, `+`(Plus)·`Insert`처럼 macOS 가상 키코드가 없는 키는 등록에서 제외된다.
- 같은 조합을 두 번 바인딩하면 **첫 줄이 이긴다**(in-app은 action·`unbind`·매크로 통틀어 조합당 한 줄, 전역은
  전역끼리 — 중복은 무시 + diagnostic). 한 조합을 in-app 앱 동작과 매크로에 동시에 못 묶는다(첫 줄 우선이라
  충돌이 안 생긴다). 조합/action을 못 읽으면 그 줄만 무시(forgiving).

> **현재 범위**: in-app 키바인딩(앱 액션·`unbind`·터미널 매크로)은 `KeyBindingResolver`로 동작에
> 연결된다. 전역 단축키(`global:`)는 config 파싱 → OS 등록용 키코드 매핑 → macOS Carbon
> `RegisterEventHotKey` 등록 → 동작(창 토글/표시, quick terminal 토글)까지 동작한다(앱이 비활성이어도
> 발화). quick terminal의 슬라이드 애니메이션과 `auto-hide` 포커스 정책은 구현됐다. Esc 숨김은 vim 등 terminal
> 입력과 충돌하므로 의도적으로 채택하지 않는다.
