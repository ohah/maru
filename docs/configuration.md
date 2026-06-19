# 설정(config) 파일

Maru는 시작 시 사용자 설정 파일을 읽어 폰트·색·커서를 적용한다. 이 문서는 파일 위치, 형식, 키,
검증 동작을 정한다. 설정은 **선언적**이고 **forgiving**하다 — 설정 파일이 없거나 일부 줄이 틀려도
터미널은 정상 동작한다.

> 이 문서는 config 토대의 appearance(폰트/테마/커서) + 키바인딩 파싱을 다룬다. 동작 토글
> (스크롤백 크기, 이모지 grapheme 기본값 등)·런타임 reload·설정 UI는 후속 단계다(아래 "범위와
> 후속" 참조).

## 위치

다음 순서로 경로를 정한다.

1. 환경변수 `$MARU_CONFIG`가 있으면 그 경로.
2. 없으면 `$HOME/.config/maru/config`.
3. `$HOME`도 없으면 설정 없이 기본값으로 시작한다.

파일이 없으면 **에러가 아니라** 전부 기본값으로 시작한다(Ghostty와 같은 위치/관례).

## 형식

`key = value` 한 줄에 하나. `#`로 시작하는 줄과 빈 줄은 무시한다(Ghostty식). 값은 양끝 공백을
다듬되 **내부 공백은 보존**한다(예: 폰트명 `JetBrains Mono`). 따옴표는 쓰지 않는다.

```conf
# ~/.config/maru/config — 예시
font.family = JetBrains Mono
font.size = 14
font.size-step = 1

theme.background = #101010
theme.foreground = #e8e8e8
theme.cursor     = #ffffff
theme.selection  = #334455

cursor.shape = block
cursor.blink = true

window.padding-x = 8
window.padding-y = 4
```

## 키

| 키 | 타입 | 기본값 | 비고 |
|---|---|---|---|
| `font.family` | 문자열 | `JetBrains Mono` | 내부 공백 보존. 비어 있으면 무시(기본 유지) |
| `font.size` | 숫자 | `14` | 1~512 범위. 범위 밖/비숫자는 무시 |
| `font.size-step` | 숫자 | `1` | ⌘+/⌘-(Bigger/Smaller)가 한 번에 바꾸는 증분(pt). 0.1~32 범위. ⌘0(Actual Size)은 step과 무관하게 `font.size`로 복귀 |
| `theme.background` | `#RRGGBB` | `#101010` | 16진 색. 형식 오류는 무시 |
| `theme.foreground` | `#RRGGBB` | `#e8e8e8` | |
| `theme.cursor` | `#RRGGBB` | `#ffffff` | |
| `theme.selection` | `#RRGGBB` | `#334455` | 선택 하이라이트 배경 |
| `cursor.shape` | `block`\|`bar`\|`underline` | `block` | 그 외 값은 무시 |
| `cursor.blink` | `true`\|`false` | `true` | |
| `window.padding-x` | 정수(0~256) | `8` | 셀 그리드와 pane 가장자리 사이 **좌우** 여백(논리 pt, DPI 스케일). 탭 바·split divider·pane 배경 등 chrome은 사이드바 경계/창 가장자리까지 꽉 차고 셀 그리드만 들인다. 0이면 셀이 가장자리에 붙음. 범위 밖/비정수는 무시(기본 유지) |
| `window.padding-y` | 정수(0~256) | `4` | 위와 같되 **상하** 여백 |
| `scrollback.lines` | 정수(0~100000) | `1000` | 가시 화면 위로 보관할 과거 줄 수. `0`이면 스크롤백 비활성(과거 줄 안 보관). 범위 밖/비정수는 무시(기본 유지) |
| `bell.audible` | `true`\|`false` | `true` | BEL(0x07) 수신 시 시스템 소리(NSSound.beep)를 낼지. `false`면 음소거(코어 플래그는 정상 소비) |
| `input.page-keys` | `passthrough`\|`scroll` | `scroll` | 메인 화면 PageUp/Down 동작. 아래 참조 |
| `quick-terminal.height` | 숫자(0.1~1.0) | `0.45` | 가장자리에 수직인 '두께' 비율(화면 대비). `top`/`bottom`=높이, `left`/`right`=폭, `center`=세로 비율. 범위 밖/비숫자는 무시 |
| `quick-terminal.width` | 숫자(0.1~1.0) | (`height` 따라감) | **`center` 전용** 가로 비율(화면 대비). 미설정이면 `height`와 같게(정사각). `top`/`bottom`(전폭)·`left`/`right`(`height`로 두께)에선 무시. 범위 밖/비숫자는 무시 |
| `quick-terminal.auto-hide` | `true`\|`false` | `true` | 포커스 잃으면(다른 창/앱 클릭) 자동 숨김. `false`면 토글로만 |
| `quick-terminal.screen` | `main`\|`mouse` | `main` | 어느 화면에 띄울지(`mouse`=마우스가 있는 화면). 그 외 값은 무시 |
| `quick-terminal.position` | `top`\|`bottom`\|`left`\|`right`\|`center` | `top` | 어느 가장자리에서 슬라이드해 나올지. `center`=화면 중앙(세로=`height`·가로=`width`, 슬라이드 대신 페이드 인). 그 외 값은 무시 |
| `quick-terminal.chrome` | `full`\|`minimal` | `full` | 패널 chrome 수준. `minimal`=세로 사이드바·pane 탭 바 없이 터미널 그리드만(드롭다운 스크래치 터미널 모습). `full`=메인 창처럼 다 보임. 그 외 값은 무시. 메인 창엔 영향 없음(quick terminal 전용) |
| `quick-terminal.minimal-tabs` | `true`\|`false` | `false` | `chrome=minimal`일 때 탭(워크스페이스·pane Term) 생성 허용 여부. `false`(기본)=단일 스크래치 — `⌘T`/`⌘⇧T` 무동작(사이드바·탭 바가 없어 안 보이는 탭 생성을 막음; split `⌘D`은 divider로 보이므로 유지). `true`=탭 허용(`⌘1..9`/`⌘]`로 전환). 탭이 2개 이상이면 **우상단에 작은 탭 점 인디케이터**가 떠 활성 탭을 보여준다(워크스페이스가 여러 개면 워크스페이스, 아니면 활성 pane의 Term). `chrome=full`이면 이 값과 무관하게 탭이 항상 동작. 그 외 값은 무시 |
| `term` | 문자열 | `xterm-256color` | 셸에 줄 `$TERM`. 아래 참조 |
| `keybind` | `<조합> = <action>` | (없음) | 여러 줄 가능. 아래 참조 |

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

### `$TERM` (`term`)

셸에 줄 `$TERM` 값이다(기본 `xterm-256color`, Maru의 xterm식 동작과 맞는 표준값). 보통 바꿀
필요 없다. 드물게 셸 설정/프레임워크가 `$TERM`에 따라 다르게 동작하는 경우, 셸이 기대하는 값으로
맞출 수 있다:

```conf
term = xterm-ghostty   # 그 terminfo가 설치돼 있어야 한다
```

> Maru는 대화형 셸을 macOS `login(1)`로 감싸 띄운다(Terminal.app·Ghostty와 동일) — 전체 로그인
> 세션(getlogin·SHELL·utmp·hushlogin)을 셋업하고 `.zprofile`/`.zlogin`까지 source한다. 그래서
> PATH·EDITOR·키바인딩(예: `bindkey -e`로 `Cmd+←/→`=줄 시작/끝)이 사용자 환경대로 잡혀, 대개 `term`을
> 안 건드려도 정상 동작한다. 키바인딩 해석은 터미널이 아니라 셸의 책임이다 — 터미널은 `\x01` 같은
> 바이트만 보낸다.

> 빈 값(`term =`)은 무시하고 기본값을 유지한다. env를 명시로 주는 테스트 경로에선 이 값이 무시된다.

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
keybind = Cmd+K = esc:[2J
```

- **조합**: `Cmd`/`Ctrl`/`Alt`/`Shift`(대소문자 무관)를 `+`로 잇고 마지막에 키. 키는 글자 한 자,
  숫자, `Esc`/`Tab`/`Enter`/`Space`/`Backspace`/`Up`/`Down`/`Left`/`Right`/`F1`~`F24`, 그리고 `+`
  자체는 `Plus`로 쓴다(예: `Cmd+Plus`).
- **action**: 워크스페이스 `new_tab`·`close_tab`·`next_tab`·`previous_tab`·`select_tab:N`(N=0부터),
  Term `new_term`·`close_term`·`next_term`·`previous_term`, 분할 `split_horizontal`·`split_vertical`,
  pane 포커스 `focus_pane_left`·`focus_pane_right`·`focus_pane_up`·`focus_pane_down`,
  폰트 크기 `increase_font_size`·`decrease_font_size`(증분은 `font.size-step`)·`reset_font_size`·`set_font_size:N`
  (N=절대 pt, 6~72로 클램프 — 예: `Ctrl+Cmd+1 = set_font_size:14`로 크기 프리셋), 그리고 `select_all`·
  `toggle_find`·`find_next`·`find_previous`·`toggle_command_palette`.
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
> 발화). quick terminal의 슬라이드 애니메이션·Esc 숨김·포커스 폴리시는 후속이다.

## 검증 동작 (forgiving)

한 줄의 오타가 전체 설정을 깨지 않게, **치명적 오류는 메모리 부족뿐**이다. 그 외는 모두 해당
필드의 기본값을 유지하고 diagnostic(무시된 줄 번호 + 이유)으로 남긴다:

- 알 수 없는 key → 무시.
- `=` 없는 줄 → 무시.
- `font.size`가 숫자가 아니거나 1~512 밖 → 기본 14 유지.
- `font.size-step`이 숫자가 아니거나 0.1~32 밖 → 기본 1 유지.
- `cursor.shape`/`cursor.blink`가 허용 값이 아님 → 기본 유지.
- 색이 `#RRGGBB` 형식이 아님 → 기본 색 유지.

`MARU_DEBUG=1`로 실행하면 무시된 줄이 `config line N: ...` 경고로 보인다. (값 의미 검증은
`appearance.resolve`와 `appearance.parseHexColor` 단일 출처를 재사용하므로, 로더가 통과시킨 값은
resolve 단계에서 다시 실패하지 않는다.)

## 구현 경계

- **순수 파서** `config.parseConfig`(`src/config/loader.zig`)는 파일시스템 없이 텍스트 →
  `theme.Config`로 파싱한다(단위 테스트로 고정, Linux CI 포함). I/O 래퍼 `config.loadConfigDefault`
  /`loadConfigFile`이 경로 해석과 파일 읽기를 감싼다.
- **소유권**: 파싱된 문자열(`font.family`)은 `Parsed.arena`가 소유한다. `appearance.resolve`가 그
  family 슬라이스를 빌리므로(복사 안 함), 호출자(app session)는 `Parsed`를 세션 동안 보관하고
  종료 시 `deinit`한다. 색은 resolve가 `Rgb` 값으로 변환하므로 수명 의존이 없다.
- app session은 시작 시 `config.loadConfigDefault(io, allocator)`로 로드해 `resolveAppearance`에
  넘긴다. resolve가 (방어적으로) 실패하면 기본 appearance로 떨어진다.

## 범위와 후속

appearance(폰트/테마/커서)와 키바인딩 **파싱**까지 구현됐다. 의존성 순서상 config가 먼저 와야
뒤따르는 설정형 기능이 하드코딩 후 재작업되지 않는다([구현 계획](implementation-plan.md) 참조).
후속:

- **키바인딩 dispatch**: 파싱된 `KeyBindingResolver`로 실제 app action(탭 열기 등)을 실행한다 —
  8단계 탭/quick terminal/global shortcut에서.
- **동작 토글**: 스크롤백 크기, paste 보호, 이모지 grapheme 기본값(DEC mode 2027 강제) 등.
- **terminal 입력 remap**: `<조합> → 바이트` 매크로(TerminalBinding) config.
- **런타임 reload**: 파일 변경 감지 후 재-resolve(소유권은 이미 reload를 염두에 둔 arena 구조).
- **설정 UI**: v1 범위 밖일 수 있음([터미널 호환성/보안 정책](terminal-compatibility-policy.md)).
