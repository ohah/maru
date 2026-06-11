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

theme.background = #101010
theme.foreground = #e8e8e8
theme.cursor     = #ffffff
theme.selection  = #334455

cursor.shape = block
cursor.blink = true
```

## 키

| 키 | 타입 | 기본값 | 비고 |
|---|---|---|---|
| `font.family` | 문자열 | `JetBrains Mono` | 내부 공백 보존. 비어 있으면 무시(기본 유지) |
| `font.size` | 숫자 | `14` | 1~512 범위. 범위 밖/비숫자는 무시 |
| `theme.background` | `#RRGGBB` | `#101010` | 16진 색. 형식 오류는 무시 |
| `theme.foreground` | `#RRGGBB` | `#e8e8e8` | |
| `theme.cursor` | `#RRGGBB` | `#ffffff` | |
| `theme.selection` | `#RRGGBB` | `#334455` | 선택 하이라이트 배경 |
| `cursor.shape` | `block`\|`bar`\|`underline` | `block` | 그 외 값은 무시 |
| `cursor.blink` | `true`\|`false` | `true` | |
| `input.page-keys` | `passthrough`\|`scroll` | `passthrough` | 메인 화면 PageUp/Down 동작. 아래 참조 |
| `term` | 문자열 | `xterm-256color` | 셸에 줄 `$TERM`. 아래 참조 |
| `keybind` | `<조합> = <action>` | (없음) | 여러 줄 가능. 아래 참조 |

### PageUp/PageDown (`input.page-keys`)

메인 화면(셸 프롬프트)에서 PageUp/PageDown를 어떻게 다룰지 정한다. **alt 화면(vim·less 등)에선
어느 값이든 항상 `\e[5~`/`\e[6~`를 앱으로 보내** 앱이 자체 페이징한다.

- `passthrough` (기본): xterm/Ghostty처럼 메인 화면에서도 `\e[5~`/`\e[6~`를 PTY로 보낸다. 예측
  가능하고 레퍼런스·원격(SSH)과 일치한다. 단, 셸 기본 keymap에 이 키가 바인딩돼 있지 않으면(zsh
  기본) BEL이 울리고 남은 `~`가 입력줄에 박힌다 — 셸에서 `bindkey`로 바인딩하거나 `scroll`을 쓴다.
- `scroll`: Terminal.app/iTerm2처럼 메인 화면에서 Maru 스크롤백을 한 페이지씩 스크롤한다(`~`가
  박히지 않음). 대신 메인 화면 앱(드물게 PageUp을 쓰는 TUI)에는 키가 전달되지 않는다.

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
```

- **조합**: `Cmd`/`Ctrl`/`Alt`/`Shift`(대소문자 무관)를 `+`로 잇고 마지막에 키. 키는 글자 한 자,
  숫자, `Esc`/`Tab`/`Enter`/`Space`/`Backspace`/`Up`/`Down`/`Left`/`Right`/`F1`~`F24`, 그리고 `+`
  자체는 `Plus`로 쓴다(예: `Cmd+Plus`).
- **action**: `new_tab`, `close_tab`, `next_tab`, `previous_tab`, `select_tab:N`(N=0부터).
- 같은 조합을 두 번 바인딩하면 **첫 줄이 이긴다**(중복은 무시 + diagnostic). 조합/action을 못
  읽으면 그 줄만 무시(forgiving).

> **현재 범위**: 키바인딩은 파싱·검증되어 `KeyBindingResolver`로 준비된다. 실제 동작 연결(탭 열기
> 등)은 8단계(탭/quick terminal)에서 이뤄진다 — config가 먼저 와야 8단계가 하드코딩 없이 이
> resolver를 그대로 쓴다([구현 계획](implementation-plan.md)의 의존성 순서). terminal 입력 remap
> (`<조합> → 바이트`)과 global shortcut도 후속이다.

## 검증 동작 (forgiving)

한 줄의 오타가 전체 설정을 깨지 않게, **치명적 오류는 메모리 부족뿐**이다. 그 외는 모두 해당
필드의 기본값을 유지하고 diagnostic(무시된 줄 번호 + 이유)으로 남긴다:

- 알 수 없는 key → 무시.
- `=` 없는 줄 → 무시.
- `font.size`가 숫자가 아니거나 1~512 밖 → 기본 14 유지.
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
  family 슬라이스를 빌리므로(복사 안 함), 호출자(dev session)는 `Parsed`를 세션 동안 보관하고
  종료 시 `deinit`한다. 색은 resolve가 `Rgb` 값으로 변환하므로 수명 의존이 없다.
- dev session은 시작 시 `config.loadConfigDefault(io, allocator)`로 로드해 `resolveAppearance`에
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
