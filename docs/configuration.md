# 설정(config) 파일

Maru는 시작 시 사용자 설정 파일을 읽어 폰트·색·커서를 적용한다. 이 문서는 파일 위치, 형식, 키,
검증 동작을 정한다. 설정은 **선언적**이고 **forgiving**하다 — 설정 파일이 없거나 일부 줄이 틀려도
터미널은 정상 동작한다.

> 이 문서는 config 토대의 appearance(폰트/테마/커서) + 키바인딩 파싱을 다룬다. 동작 토글
> (이모지 grapheme 기본값 등)·파일 변경 자동 감지 reload·설정 UI는 후속 단계다(아래 "범위와
> 후속" 참조). 메뉴의 수동 Reload Config·Reset to Defaults는 구현됨.

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
font.line-height = 1.0
font.letter-spacing = 0.0

# 컬러 테마 프리셋(선택). 한 줄로 색 세트를 고른다.
# maru(기본)·ghostty·gruvbox-dark·solarized-dark·solarized-light·dracula·catppuccin-mocha·catppuccin-latte.
# 프리셋은 base다 — 아래 개별 theme.* 키를 프리셋 줄 *뒤에* 두면 그 색만 덮어쓴다.
theme.preset = maru

theme.background = #101010
theme.foreground = #e8e8e8
theme.cursor     = #ffffff
theme.selection  = #334455
# ANSI 16색 override(선택, 인덱스 0~15). 적은 인덱스만 덮으면 나머지는 xterm 표준색.
theme.palette.0  = #1c1c1c
theme.palette.1  = #d35f5f

cursor.shape = block
cursor.blink = true

window.padding-top    = 4
window.padding-right  = 8
window.padding-bottom = 4
window.padding-left   = 8
# 또는 대칭 alias: window.padding-x = 8 (좌우 동시), window.padding-y = 4 (상하 동시)
```

## 키

| 키 | 타입 | 기본값 | 비고 |
|---|---|---|---|
| `font.family` | 문자열 | `JetBrains Mono` | 내부 공백 보존. 비어 있으면 무시(기본 유지) |
| `font.size` | 숫자 | `14` | 1~512 범위. 범위 밖/비숫자는 무시 |
| `font.size-step` | 숫자 | `1` | ⌘+/⌘-(Bigger/Smaller)가 한 번에 바꾸는 증분(pt). 0.1~32 범위. ⌘0(Actual Size)은 step과 무관하게 `font.size`로 복귀 |
| `font.line-height` | 숫자 | `1.0` | 행간 배수. 1.0=CoreText 자동 cell 높이, 1.5=50% 더 큰 줄 간격. 0.5~3.0 범위. 범위 밖/비숫자는 무시. 늘어난 높이는 글자를 셀 안 세로 가운데로 그려 위아래 여백이 된다 |
| `font.letter-spacing` | 숫자 | `0.0` | 자간(논리 pt). 0=advance 그대로, 양수=칸 넓힘, 음수=칸 좁힘. -8~32 범위(음수 허용). 범위 밖/비숫자는 무시. 늘어난 폭은 글자를 셀 안 가로 가운데로 그려 좌우 여백이 된다 |
| `theme.preset` | 프리셋 이름 | `maru` | 이름 붙은 컬러 테마 **base**. 색 세트(배경/전경/커서/선택 + ANSI 16색)를 한 번에 고른다. `maru`·`ghostty`·`gruvbox-dark`·`solarized-dark`·`solarized-light`·`dracula`·`catppuccin-mocha`·`catppuccin-latte`. 개별 `theme.*` 키를 **이 줄 뒤에** 두면 그 색만 override(순차 적용, 나중 줄 우선). 그 외 값은 무시. 아래 [컬러 테마 프리셋](#컬러-테마-프리셋-themepreset) 참조 |
| `theme.background` | `#RRGGBB` | `#101010` | 16진 색. 형식 오류는 무시 |
| `theme.foreground` | `#RRGGBB` | `#e8e8e8` | |
| `theme.cursor` | `#RRGGBB` | `#ffffff` | |
| `theme.selection` | `#RRGGBB` | `#334455` | 선택 하이라이트 배경 |
| `theme.palette.0`~`theme.palette.15` | `#RRGGBB` | xterm 표준색 | ANSI 16색(0~15) override — `ls`/`vim`/프롬프트 색 테마 완성용. 적은 인덱스만 덮어도 됨(나머지는 xterm 표준 폴백). 우선순위는 **OSC 4(앱 동적 설정) > config > xterm256**: 앱이 OSC 4로 색을 바꾸면 그게 우선이고, RIS·OSC 104(리셋) 후엔 다시 이 config 값으로 돌아온다. 범위 밖 인덱스(16+)·비정수 인덱스·형식 오류 색은 무시(그 인덱스는 기본 유지) |
| `cursor.shape` | `block`\|`bar`\|`underline` | `block` | 그 외 값은 무시 |
| `cursor.blink` | `true`\|`false` | `true` | |
| `window.padding-top` | 정수(0~256) | `4` | 셀 그리드와 pane 가장자리 사이 **위** 여백(논리 pt, DPI 스케일). 탭 바·split divider·pane 배경 등 chrome은 사이드바 경계/창 가장자리까지 꽉 차고 셀 그리드만 들인다. 0이면 셀이 가장자리에 붙음. 범위 밖/비정수는 무시(기본 유지) |
| `window.padding-right` | 정수(0~256) | `8` | 위와 같되 **오른쪽** 여백 |
| `window.padding-bottom` | 정수(0~256) | `4` | 위와 같되 **아래** 여백 |
| `window.padding-left` | 정수(0~256) | `8` | 위와 같되 **왼쪽** 여백 |
| `window.padding-x` | 정수(0~256) | `8` | **left+right alias** — `padding-left`·`padding-right`를 같은 값으로 동시에 설정(대칭 좌우 여백). 개별 키와 혼용 시 파일에서 **나중에 나온 줄이 우선**(예: `padding-x=10` 다음 `padding-left=20` → left=20, right=10). 범위 밖/비정수는 무시(기본 유지) |
| `window.padding-y` | 정수(0~256) | `4` | **top+bottom alias** — `padding-top`·`padding-bottom`을 같은 값으로 동시에 설정(대칭 상하 여백). 우선순위 규칙은 `padding-x`와 동일(나중 줄 우선) |
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
| `sidebar.show-branch` | `true`\|`false` | `true` | 세로 사이드바 세션 카드에 git 브랜치명을 표시할지. 카드 이름줄은 식별용이라 항상 표시. 그 외 값은 무시 |
| `sidebar.show-folder` | `true`\|`false` | `true` | 위와 같되 폴더(cwd) 경로 줄 |
| `term` | 문자열 | `xterm-256color` | 셸에 줄 `$TERM`. 아래 참조 |
| `keybind` | `<조합> = <action>` | (없음) | 여러 줄 가능. 아래 참조 |

### 컬러 테마 프리셋 (`theme.preset`)

한 줄로 색 세트의 **base**를 고른다. 프리셋이 배경/전경/커서/선택과 ANSI 16색 팔레트를 한 번에 채우고,
그 뒤에 오는 개별 `theme.*` 키가 일부만 덮어쓴다(loader 순차 적용 — 나중 줄 우선). **프리셋 줄을 개별 색
키보다 위에 두라** — 프리셋이 개별 색 키보다 뒤에 오면 앞 설정을 리셋한다(Ghostty `theme` 시맨틱과 동일).

사용 가능한 프리셋:

| 값 | 설명 | 배경 |
|---|---|---|
| `maru` (기본) | Maru 기본 테마(무채색 다크, ANSI 16색은 xterm 표준) | `#101010` |
| `ghostty` | Ghostty 기본 테마(청회색 다크) | `#282c34` |
| `gruvbox-dark` | Gruvbox Dark(웜 레트로 — 갈색·주황·올리브) | `#282828` |
| `solarized-dark` | Solarized Dark(청록 다크) | `#002b36` |
| `solarized-light` | Solarized Light(**라이트** — 베이지) | `#fdf6e3` |
| `dracula` | Dracula(보라·핑크 다크) | `#282a36` |
| `catppuccin-mocha` | Catppuccin Mocha(파스텔 다크) | `#1e1e2e` |
| `catppuccin-latte` | Catppuccin Latte(**라이트** — 파스텔) | `#eff1f5` |

> **베이스/결정**: `maru`는 Maru 기본값. `ghostty`는 Ghostty 기본값(배경/전경은 Ghostty `Config.zig`, ANSI 16색은
> `terminal/color.zig`의 기본 팔레트)을 베이스로 하되, Ghostty가 정의하지 않는 `cursor`/`selection`은 Maru 기본을 쓴다.
> 나머지(`gruvbox-dark`·`solarized-*`·`dracula`·`catppuccin-*`)는 **iTerm2-Color-Schemes**의 표준 색 값(배경/전경/커서/
> 선택/팔레트)을 그대로 가져왔다 — 색 **값만** 인용했고 코드 표현은 옮기지 않았다(clean-room). 정확한 팔레트 16색은
> `src/config/theme.zig`의 프리셋 상수가 단일 출처다.
>
> - **검색 매치색**(스크롤백 Find 하이라이트)은 Maru 고유라 전 프리셋에서 Maru 기본을 유지한다. 사이드바 활성 좌측
>   앰버 막대(rich 룩)도 Maru 브랜드 고정이라 프리셋과 무관하다.
> - **라이트 테마**(`solarized-light`·`catppuccin-latte`)는 사이드바 색을 명시한다 — 사이드바 기본 파생은 배경을 *밝게*
>   하는데, 라이트 배경에선 거의 흰색이 돼 구분이 사라지므로 배경보다 *어두운* 표면색을 직접 준다.
> - `catppuccin-*`의 선택색은 스킴 원값(rosewater, 밝은색)이 selection-foreground와 함께 쓰는 전제라, Maru(선택 글자색을
>   안 바꿈)에선 글자 가독성을 위해 어두운/중간 표면색으로 바꿨다.
>
> 색 룩만 정하며, chrome **디자인 룩**(`chrome.theme` = tui|rich)과는 직교다.

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

셸에 줄 `$TERM` 값이다. 기본은 **`xterm-maru`** — Maru 자체 terminfo 항목이다(짧은 alias `maru`).
Maru가 이 terminfo 소스를 바이너리에 내장하고, 자식 셸을 띄울 때 자기 캐시(`${XDG_CACHE_HOME:-~/.cache}/maru/terminfo`
— 다른 maru 캐시와 같은 base)에 자동 컴파일(`tic`)해 자식 env에 `TERMINFO=<그 캐시>`를 실어준다. 그래서 **로컬은 별도 설치 없이**
`xterm-maru`가 동작한다(비침습 — `~/.terminfo`나 시스템을 안 건드림). `tic`이 없거나 컴파일이 실패하면
**`xterm-256color`로 자동 폴백**해 로컬이 절대 깨지지 않는다(Ghostty의 번들 terminfo + `TERMINFO` env
방식과 같은 결 — `pty/macos.zig`의 `resolveTerm`).

> **캐시 자동 갱신**: 캐시 디렉터리에 내장 terminfo의 버전 지문(`.maru-version`)을 함께 둔다. maru를 업데이트해
> terminfo 캡이 바뀌면 지문이 달라져 **다음 셸 spawn이 stale 캐시를 자동 재컴파일**한다(예전엔 한 번 컴파일하면
> 안 바꿔, 캡을 늘려도 기존 캐시에 반영되지 않았다). 보통은 손댈 일이 없지만, 강제·진단용으로 `maru terminfo`
> 서브커맨드를 둔다:
>
> ```sh
> maru terminfo            # 상태(캐시 경로 + xterm-maru 해석 여부)
> maru terminfo --refresh  # 캐시를 강제로 비우고 다시 컴파일
> maru terminfo --clear    # 캐시 삭제(다음 실행이 자동 재컴파일)
> maru terminfo --path     # 캐시 경로만 출력(스크립트용)
> ```

`xterm-maru`가 알리는 캡(Maru가 실제 지원하는 것만 정직하게 — 없는 걸 광고하면 원격 프로그램이 오작동):
- **동기화 출력(`Sync`, DECSET 2026)** — tmux가 재그리기를 한 프레임으로 묶어 **tmux 레이아웃 플리커가 사라진다**.
- **truecolor(`Tc`)** — 24-bit 색.
- **bracketed paste(`BE`/`BD`, DECSET 2004)** — nvim/vim의 안전한 붙여넣기.
- **OSC 52 클립보드 set(`Ms`)** — tmux `set-clipboard` 등이 시스템 클립보드에 쓴다(`osc52.write=allow`라 정직; read는 deny).
- **커서 스타일(`Ss`/`Se`, DECSCUSR)** — vim이 모드별 bar/underline/block 커서를 전환한다(원격에서도).
- **focus 이벤트(`fe`/`fd`+`kxIN`/`kxOUT`, DECSET 1004)** — 창 포커스 in/out 보고(vim FocusGained/Lost).

`use=xterm-256color`를 토대로 위 캡을 더한다. 적합성은 `mise run terminfo-check`가 컴파일 + 각 캡의 실제 바이트 round-trip으로 검증한다("추측 말고 캡처").

드물게 셸 설정/프레임워크가 특정 `$TERM`을 기대하면 바꿀 수 있다:

```conf
term = xterm-256color   # 표준값으로 되돌리기
term = xterm-ghostty    # 다른 값(그 terminfo가 설치돼 있어야 함)
```

> 시스템 전역이나 **Maru 밖의 셸**(예: 다른 터미널에서 Maru에 붙는 경우)에서도 `xterm-maru`를 쓰려면
> `mise run install-terminfo`로 `~/.terminfo`에 설치한다(Maru 안에서는 위 자동 캐시로 충분해 불필요).

> **원격(SSH) 주의**: terminfo는 프로그램이 읽는 머신에 있어야 한다. 기본이 `xterm-maru`라 **평범한
> `ssh`로 원격에** 접속하면(maru의 `TERMINFO`는 로컬 env라 안 따라간다) 원격에 항목이 없어
> `vim`/`tmux`/`less` 등이 `unknown terminal type`으로 깨질 수 있다. 이를 푸는 게 **`maru ssh`** 다 —
> 원격에 terminfo를 먼저 심고 평범한
> `ssh`로 넘어간다(당신의 평소 `ssh`는 건드리지 않는다):
>
> ```sh
> maru install-cli              # maru 바이너리를 ~/.local/bin/maru에 symlink(셸에서 maru를 쓰려면 한 번)
> maru ssh <host>               # 원격에 xterm-maru 설치 후 exec ssh
> maru ssh --terminfo-only <host>   # 설치만(세션 없음) — ssh 래핑을 원치 않을 때
> ```
>
> (`maru install-cli`는 현재 maru 바이너리를 `~/.local/bin/maru`에 링크해 PATH에서 `maru`를 쓸 수 있게
> 한다 — sudo 불필요. `~/.local/bin`이 PATH에 없으면 추가 방법을 안내한다.)
>
> `maru ssh`는 terminfo 소스를 바이너리에 내장해 **로컬 설치 없이도** 동작한다(자기완결 — `install-terminfo`는
> 로컬 셸에서 `term = "xterm-maru"`를 쓸 때만 필요하다). 원격에 `tic`이 없거나
> 설치가 실패하면 자동으로 `TERM=xterm-256color`로 폴백해 세션이 깨지지 않는다. 키/agent 인증이면
> ControlMaster로 **단일 연결**(인증 1회)에서 설치와 세션을 함께 처리한다. `maru ssh`는 **대화형
> 세션용**이다 — `maru ssh host cmd`처럼 원격 command를 붙이면 terminfo 설치를 건너뛰고(설치 스크립트가
> command와 충돌해 이중 실행되는 것을 막는다) `xterm-256color`로 연결한다.
>
> **설치 캐시**: 한 번 설치에 성공한 목적지는 `${XDG_CACHE_HOME:-~/.cache}/maru/ssh-terminfo-hosts`에
> 기록돼, 다음 접속부터 설치 단계를 건너뛴다(매 접속 설치 round-trip 제거). 원격 `~/.terminfo`를 비웠다면
> (스테일) `maru ssh --terminfo-only <host>`로 **강제 재설치**하거나 캐시 파일을 지운다(`rm
> ~/.cache/maru/ssh-terminfo-hosts`). 수동으로 한 줄로 설치하려면:
>
> ```sh
> infocmp -x xterm-maru | ssh <host> 'mkdir -p ~/.terminfo && tic -x -o ~/.terminfo -'
> ```

> Maru는 대화형 셸을 macOS `login(1)`로 감싸 띄운다(Terminal.app·Ghostty와 동일) — 전체 로그인
> 세션(getlogin·SHELL·utmp·hushlogin)을 셋업하고 `.zprofile`/`.zlogin`까지 source한다. 그래서
> PATH·EDITOR·키바인딩(예: `bindkey -e`로 `Cmd+←/→`=줄 시작/끝)이 사용자 환경대로 잡혀, 대개 `term`을
> 안 건드려도 정상 동작한다. 키바인딩 해석은 터미널이 아니라 셸의 책임이다 — 터미널은 `\x01` 같은
> 바이트만 보낸다.

> 빈 값(`term =`)은 무시하고 기본값을 유지한다. env를 명시로 주는 테스트 경로에선 이 값이 무시된다.

### 셸 통합 ssh 라우팅 (`shell-integration.ssh`)

```
shell-integration.ssh = true    # 평범한 ssh를 maru ssh로 자동 라우팅 (기본 false)
```

위 `maru ssh`는 직접 입력할 때만 terminfo를 전파한다. 이 옵션을 켜면 **통합 zsh에서 평범한 `ssh`를
입력해도** maru가 그 호출을 `maru ssh`로 라우팅해 자동으로 `xterm-maru`를 원격에 심는다 — 매번 `maru`를
앞에 붙이지 않아도 된다.

> **동작**: maru가 자식 셸 env에 현재 실행 파일 경로(`MARU_BIN`)와 플래그(`MARU_SSH_INTEGRATION`)를
> 주입하고, Maru 통합 `.zshenv`가 이 둘이 모두 있을 때만 `ssh`를 가리는 함수를 정의해 `maru ssh`로
> 위임한다. 같은 maru 바이너리가 `maru ssh`를 처리하므로 `install-cli` 없이도 동작한다.
>
> **기본 off인 이유**(opt-in): `ssh`를 함수로 가리는 건 침습적이라 사용자 동의가 필요하다(Ghostty도
> `ssh-*`를 기본 off로 둔다). 끄면(기본) 평범한 `ssh`가 그대로 동작한다.
>
> **범위/우회**: zsh 통합이 켜진 대화형 셸에서만 적용된다(통합이 없으면 함수가 정의되지 않는다). 한 번만
> 평범한 ssh로 가려면 `command ssh ...` 또는 `\ssh ...`. `maru ssh`와 동일하게 **대화형 세션용**이라
> `ssh host cmd`(원격 command)는 terminfo 설치를 건너뛰고 `xterm-256color`로 연결한다.

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
  Term `new_term`·`close_term`·`next_term`·`previous_term`, 분할 `split_horizontal`·`split_vertical`,
  pane 포커스 `focus_pane_left`·`focus_pane_right`·`focus_pane_up`·`focus_pane_down`, split 순환 `next_pane`·`previous_pane`,
  폰트 크기 `increase_font_size`·`decrease_font_size`(증분은 `font.size-step`)·`reset_font_size`·`set_font_size:N`
  (N=절대 pt, 6~72로 클램프 — 예: `Ctrl+Cmd+1 = set_font_size:14`로 크기 프리셋), 그리고 `select_all`·
  `clear_screen`(화면+스크롤백 비우기, 빌트인 ⌘K — alt 화면 무동작, 셸 프롬프트면 ^L로 재그림. 자세히는
  [키 입력과 단축키](key-input-and-shortcuts.md))·`toggle_find`·`find_next`·
  `find_previous`·`toggle_command_palette`.
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
- `font.line-height`가 숫자가 아니거나 0.5~3.0 밖 → 기본 1.0 유지.
- `font.letter-spacing`이 숫자가 아니거나 -8~32 밖 → 기본 0.0 유지(음수는 허용).
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
- **동작 토글**: paste 보호, 이모지 grapheme 기본값(DEC mode 2027 강제) 등.
- **terminal 입력 remap**: `<조합> → 바이트` 매크로(TerminalBinding) config.
- **파일 변경 자동 감지 reload**: 파일 watcher로 변경을 감지해 자동 재-resolve(자동 감지만 후속). 메뉴의 수동 **Reload Config**(파일 재로드해 재시작 없이 적용)·**Reset to Defaults**(런타임 줌·여백 변경을 프로그램 처음 실행 설정으로 복원)는 구현됨.
- **다른 셸(bash/fish) 통합·ssh 라우팅**(보류, 2026-06): 셸 통합(macOS 편집키·OSC 133/7·`shell-integration.ssh` ssh 라우팅)은 **현재 zsh 전용**(`ZDOTDIR`+`.zshenv` 주입)이다. fish는 vendor `conf.d`로 깔끔히 주입할 수 있으나, bash는 maru가 **login 셸**로 띄워(`login=true`) `--rcfile`이 무시되고 `~/.bash_profile`만 읽어 사용자 설정을 안 깨는 주입이 까다롭다(레퍼런스 동작 비교 + 신중한 검증 필요). 그래서 별도 후속으로 둔다 — bash/fish 사용자는 그때까지 직접 `maru ssh`를 쓴다.
- **설정 UI**: v1 범위 밖일 수 있음([터미널 호환성/보안 정책](terminal-compatibility-policy.md)).
