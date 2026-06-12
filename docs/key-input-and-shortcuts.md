# 키 입력과 단축키 경계

Maru는 글로벌 핫키를 장기 UX 목표로 둔다. Warp에서 유용한 "어디서든 터미널 열기" 경험은 Maru의 scratch/quick terminal 방향과 잘 맞는다.

다만 글로벌 핫키를 terminal key event와 같은 경로로 처리하면 안 된다. 사용자가 `Ctrl-C`, `Esc`, `Cmd-K` 같은 키를 눌렀을 때 이것이 shell로 가야 하는지, 앱 명령인지, OS 전역 명령인지 구분할 수 없게 되기 때문이다.

## 입력 레이어

```text
OS global shortcut
-> PlatformGlobalShortcut
-> AppAction

Focused app key event
-> KeyBindingResolver
-> AppAction 또는 TerminalInput

TerminalInput
-> SurfaceRuntime
-> PtySession.writeInput
```

핵심 규칙:

- 글로벌 핫키는 `TerminalCore`나 `PtySession`이 아니라 platform/app layer에서 처리한다.
- app shortcut은 terminal focused 상태에서도 먼저 해석할 수 있다.
- app shortcut으로 소비된 key event는 PTY로 보내지 않는다.
- app shortcut이 아닌 key event만 terminal input encoding을 거쳐 PTY로 간다.
- `TerminalCore`는 글로벌 핫키 존재를 몰라야 한다.

## 설정 범주

초기 config는 다음 범주를 분리한다.

```text
global_shortcuts:
  - toggle_quick_terminal
  - focus_or_create_window

app_keybindings:
  - new_tab
  - close_tab
  - split_surface
  - focus_next_surface

terminal_key_overrides:
  - send_control
  - send_text
  - send_escape_sequence
```

이렇게 나누는 이유는 충돌을 사람이 이해할 수 있게 만들기 위해서다. 같은 `Cmd-Space`라도 OS 전역 핫키인지, 앱이 focus 되었을 때만 쓰는 단축키인지, shell로 보낼 문자열인지가 다르다.

## Key chord parser 계약

최종 config parser는 코드로 구현해야 한다. 하지만 구현 전에 계약을 먼저 정해야 한다. 그렇지 않으면 `Cmd+B`, `Command+b`, `ctrl-cmd-,` 같은 표기가 제각각 들어오고, 나중에 충돌 판정이 흔들린다.

초기 key chord 문자열은 다음 형태만 허용한다.

```text
Modifier+Modifier+Key
```

허용 modifier:

```text
Cmd
Ctrl
Alt
Shift
```

허용 key:

```text
A-Z
0-9
,
.
/
;
'
[
]
-
=
`
Esc
Tab
Enter
Space
Backspace
Delete
Up
Down
Left
Right
F1..F24
```

정규화 규칙:

- modifier 순서는 항상 `Ctrl`, `Alt`, `Shift`, `Cmd` 순서로 저장한다.
- key 이름은 대소문자를 구분하지 않고 canonical name으로 바꾼다.
- `Command` 같은 alias는 초기에는 허용하지 않는다. alias가 필요하면 별도 PR에서 추가한다.
- 같은 modifier를 두 번 쓰면 오류다.
- key가 없으면 오류다.
- 알 수 없는 key 이름은 오류다.
- `+`는 chord part 구분자라 키 이름으로 직접 쓸 수 없다. 리터럴 `+` 키는 `Plus`로 표기한다(예: `Cmd+Plus`). `Cmd++`처럼 빈 part가 생기는 표기는 오류다.

예시:

```text
Cmd+B          -> Cmd+B
ctrl+cmd+,     -> Ctrl+Cmd+,
Shift+Alt+F13  -> Alt+Shift+F13
Cmd+Cmd+B      -> 오류
Command+B      -> 초기에는 오류
```

이 parser 계약은 실제 TOML parser보다 먼저 구현할 수 있다. `KeyChord.parse("Ctrl+Cmd+,")` 같은 작은 단위 테스트로 시작하고, 나중에 config 파일 parser가 이 함수를 호출하게 만든다.

현재 구현 상태:

- `src/config/keybinding.zig`가 `KeyChord.parse`와 `KeyBindingResolver`의 최소 계약을 구현한다.
- `Cmd+B`, `ctrl+cmd+,`, `Shift+Alt+F13` 같은 key chord 문자열은 parser 단위 테스트로 검증한다.
- `mise run macos-app-pty-metal-smoke`는 기본적으로 AppKit synthetic `keyDown:`에서 얻은 `Cmd+B` payload가 `FrameLoop.handleKeyEvent -> KeyBindingResolver -> SurfaceRuntime.writeInput`을 거쳐 PTY와 visible Metal frame까지 도달하는지 검증한다.
- `MARU_APP_PTY_METAL_KEYDOWN_SOURCE=manual MARU_APP_PTY_METAL_KEYDOWN_MS=15000 mise run macos-app-pty-metal-smoke`는 사용자가 Metal terminal window에서 직접 누른 `Cmd+B`를 같은 경로에 태운다. 이 smoke는 물리 키 한 번의 AppKit 경계를 검증하지만, 아직 지속 interactive shell loop는 아니다.
- `mise run macos-app-pty-interactive-metal-smoke`는 실제 `$MARU_INTERACTIVE_SHELL` 또는 `$SHELL -i`에도 같은 keybinding input 경계를 사용한다. 이 smoke는 shell startup과 marker command가 visible renderer까지 도달하는지 검증하지만, 사람이 계속 입력하는 제품 loop는 아니다.
- `Ctrl+<key>` 인코딩은 `a-z`/`A-Z`뿐 아니라 전체 C0 테이블을 다룬다: `Ctrl+@`=0x00, `Ctrl+A..Z`=0x01..0x1a, `Ctrl+[`=0x1b(ESC), `Ctrl+\`=0x1c, `Ctrl+]`=0x1d, `Ctrl+^`=0x1e, `Ctrl+_`=0x1f, `Ctrl+Space`=NUL, `Ctrl+?`=DEL. C0 매핑이 없는 `Ctrl+1` 같은 조합은 키 이벤트를 실패시키지 않고 그냥 문자를 보낸다.
- `Option/Alt`(Meta) ESC prefix는 plain-byte 키(문자/Enter/Tab/Backspace)에만 붙인다. 화살표·Esc처럼 base 인코딩이 이미 ESC로 시작하는 키에는 붙이지 않는다(`Option+Up`이 `\x1b\x1b[A` 같은 double-ESC가 되지 않게). 화살표류의 modifier 인코딩(CSI 파라미터)은 이후 계약이다.
- `send_control` 매크로의 codepoint는 config validation 단계에서 C0 매핑 가능 여부를 검사한다. 잘못된 codepoint는 키를 누를 때가 아니라 설정 로드 시점에 오류로 보고한다.
- 기능키(Home/End/Insert/Delete/PageUp/PageDown/F1~F12)는 `terminal.Key` 변형 + `encodeKey`의 xterm legacy 인코딩(편집키 `CSI ~`, Home/End는 DECCKM, F1~F4 SS3·F5~F12 `CSI ~`) + 키바인딩 매핑(`keyNameFromTerminalKey`, KeyName/parseKey)으로 구현돼 설정 바인딩이 실제 이벤트와 매칭된다(순수 Zig, Linux CI 단위 테스트). AppKit bridge도 연결됐다 — ABI KeyCode enum(home~f12) + Swift `normalizedKeyEvent`의 keyCode 매핑(NSEvent.keyCode 캡처만 Swift, 인코딩·바인딩은 Zig)으로 물리 키가 vim/less/셸에 전달된다(계약/매핑 단위 테스트). 특수 비-텍스트 키(Home/End/PageUp/PageDown/ForwardDelete/Insert/F1~F12)는 keyDown에서 IME 트랜잭션을 거치지 않고 바로 인코딩 경로(handleKeyDown)로 보낸다 — 이들은 텍스트 합성이 아니라 편집/스크롤 selector라 `interpretKeyEvents`에 맡기면 안정적으로 인코딩되지 않기 때문이다. 화살표만 한글 확정 후 커서 이동 replay 때문에 IME 경로에 남는다. PageUp/PageDown는 설정(`input.page-keys`)으로 가른다 — 기본 `passthrough`는 xterm/Ghostty처럼 메인 화면에서도 `\e[5~`/`\e[6~`를 PTY로 보내고(셸 기본 keymap이 unbound면 BEL+`~`가 박힐 수 있어 `bindkey`로 해결), `scroll`은 Terminal.app/iTerm2처럼 메인 화면에서 Maru 스크롤백을 페이지 스크롤한다(PTY 캡처로 `\e[6~`→`0x07 '~'` 확인). alt 화면(vim/less)에선 어느 값이든 항상 `\e[5~`/`\e[6~`를 앱에 보낸다(alt 여부와 모드는 Zig가 판정 — native 최소). Home/End/F1~F12는 화면·설정과 무관하게 시퀀스를 그대로 보낸다(readline/앱이 바인딩). Shift+PageUp/Down 스크롤백은 handleKeyDown에서 먼저 소비돼 plain PageUp만 PTY로 간다. F13~F24와 modifier 조합(`CSI 1;{mod}~`)·CSI-u/Kitty는 후속.
- 실제 TOML 파일 parser, runtime reload, 설정 UI는 아직 없다.

## 충돌 규칙

- global shortcut은 정확히 등록한 key chord만 소비한다. 예를 들어 `Ctrl+Cmd+,`를 등록해도 `Ctrl+B`, `Ctrl+C`, `Esc`에는 영향을 주지 않는다.
- global shortcut과 terminal input이 같은 조합이면 global shortcut이 이긴다. 전역으로 등록한 키는 사용자가 앱 밖에서도 Maru 명령으로 쓰겠다고 선택한 것이기 때문이다.
- app keybinding과 terminal input override가 같은 조합이면 config validation에서 오류로 보고한다.
- OS나 다른 앱이 이미 선점한 global shortcut은 등록 실패로 보고하고, 조용히 무시하지 않는다.
- 사용자가 명시적으로 `send_text` 또는 `send_escape_sequence`를 설정한 조합은 app action과 동시에 사용할 수 없다.

## 터미널 입력 매크로

Maru는 앱이 focus된 상태에서 특정 key chord를 terminal input bytes로 바꾸는 매핑을 지원할 수 있다.

예시:

```text
Cmd+B -> send_control("b") -> PTY bytes 0x02
```

이 기능은 `Ctrl+B`를 Maru가 빼앗는 것과 다르다. 사용자는 `Cmd+B`를 누르지만, shell/tmux/vim에는 `Ctrl+B`가 들어간다. `Ctrl+B` 자체를 app/global shortcut으로 등록하는 것과, 다른 key chord가 `Ctrl+B` bytes를 보내도록 매핑하는 것은 완전히 다른 동작이다.

권장 설정 형태:

```text
app_keybindings:
  Cmd+B:
    send_control: b

terminal_key_overrides:
  F13:
    send_escape_sequence: "\\e[25~"
```

규칙:

- terminal input macro는 기본적으로 focused app key event에서만 동작한다.
- macro가 만든 bytes는 `TerminalInput`으로 분류된 뒤 `PtySession.writeInput`으로 간다.
- macro가 app action으로 소비된 key event와 같은 key chord를 쓰면 config validation 오류다.
- `Ctrl+B -> send_control("b")`처럼 동일 입력을 동일 bytes로 다시 매핑하는 설정은 보통 필요 없다. 기본 terminal input encoding이 이미 처리하기 때문이다.
- global shortcut이 직접 `send_control("b")`를 실행하는 것은 기본 허용하지 않는다. 앱 밖에서 눌렀을 때 어느 surface에 보낼지 불명확하기 때문이다.
- global shortcut에서 terminal bytes를 보내야 한다면 `focus_or_create_window -> select_target_surface -> send_control("b")`처럼 대상 surface를 명시하는 action chain이어야 한다.

## 위험한 터미널 조합

Maru는 기본 global shortcut이나 app keybinding에 전통적인 terminal 조합을 사용하지 않는다.

대표적으로 피해야 하는 조합:

```text
Ctrl+B   tmux prefix로 자주 사용된다.
Ctrl+C   foreground process interrupt다.
Ctrl+D   EOF/logout으로 쓰인다.
Ctrl+R   shell history search로 쓰인다.
Ctrl+Z   suspend로 쓰인다.
Esc      vim, readline, shell mode 전환에 자주 쓰인다.
```

사용자가 이런 조합을 global shortcut이나 app keybinding으로 직접 설정할 수는 있다. 다만 이 경우 shell, tmux, vim으로 내려가야 할 입력을 Maru가 소비하게 되므로 config validation은 경고를 보여야 한다.

오류와 경고의 기준:

- 같은 key chord가 app action과 terminal override에 동시에 있으면 오류다.
- OS 전역 등록에 실패한 global shortcut은 오류다.
- `Ctrl+B`, `Ctrl+C`, `Ctrl+D`, `Ctrl+R`, `Ctrl+Z`, `Esc` 같은 terminal 관용 조합을 app/global shortcut으로 등록하면 경고다.
- 사용자가 경고를 명시적으로 허용하지 않으면 기본 설정 파일 생성이나 GUI 설정 화면에서 저장하지 않는다.

## 초기 범위

초기 구현에서는 글로벌 핫키를 구현하지 않는다. 제품 정책은 [터미널 호환성/보안 정책](terminal-compatibility-policy.md#global-shortcut)을 따른다. 지금은 다음 경계만 유지한다.

- `Action`/keybinding config가 terminal input과 분리될 수 있어야 한다.
- `PtySession`은 이미 해석된 terminal input bytes만 받는다.
- macOS global shortcut 구현은 `src/platform/macos/` 아래 platform bridge 책임으로 둔다.

## 셸 통합 (zsh)

빌트인 키바인딩(`Cmd+←`→`\x01` 등)은 *터미널이 보내는 바이트*다. 그걸 줄-시작/끝으로 해석하는 건
셸의 keymap 책임인데, `$EDITOR`가 vi류(예: nvim)면 zsh가 vi-keymap을 기본 선택해 `Ctrl+A/E`가
self-insert가 되고, 사용자 설정이 그걸 조건부로만 emacs로 바꾸면 터미널마다 동작이 갈린다.

Maru는 **셸 통합**으로 이를 메운다(Ghostty·iTerm2·kitty가 하는 정식 기능). 대화형 셸이 zsh면 Maru가
`ZDOTDIR`을 Maru 통합 디렉터리로 설정하고, 그 디렉터리의 `.zshenv`가 ① 사용자 `ZDOTDIR`을 복원해
사용자 설정을 정상 로드한 뒤 ② `.zshrc` 로드가 끝난 첫 프롬프트(precmd 1회 훅)에서 macOS 편집키를
표준 라인 위젯에 바인딩한다 — keymap이 vi여도 동작한다. `bindkey -e`(전체 emacs 강제)가 아니라
**Maru가 보내는 키만** 바인딩해 사용자의 나머지 vi 바인딩을 보존한다:

| 키 | 바이트 | zsh 위젯 |
|---|---|---|
| `Cmd+←` | `^A` | `beginning-of-line` |
| `Cmd+→` | `^E` | `end-of-line` |
| `Cmd+⌫` | `^U` | `backward-kill-line` |
| `Option+←` | `^[b` | `backward-word` |
| `Option+→` | `^[f` | `forward-word` |
| `Option+⌫` | `^[^?` | `backward-kill-word` |

같은 통합 `.zshenv`는 **OSC 133(semantic prompt) 마커도 emit**한다 — `precmd`가 직전 명령 끝(`\e]133;D;$?`)과 새 프롬프트 시작(`\e]133;A`)을, `preexec`가 출력 시작(`\e]133;C`)을, PS1 끝이 입력 시작(`\e]133;B`)을 보낸다. 이걸로 `TerminalCore`가 행을 프롬프트/입력/출력으로 분류해(아래 표 참고) 이후 거터 ✓/✗·프롬프트 점프·reflow 정확화·cwd 추적의 토대가 된다. osc133 precmd를 사용자 .zshrc 훅 전에 등록해 직전 `$?`를 정확히 캡처한다(편집키 precmd가 뒤에 와도 종료코드 보존 — PTY 캡처로 검증). 명세: freedesktop semantic-prompts.md.

| OSC 133 | 의미 | 행 분류(`prompt_marks`) |
|---|---|---|
| `\e]133;A` (precmd) | 프롬프트 시작 | `prompt` |
| `\e]133;B` (PS1 끝) | 입력 시작 | `input` |
| `\e]133;C` (preexec) | 출력 시작 | `command` |
| `\e]133;D;<code>` (precmd) | 명령 끝(종료코드) | `last_command_exit` 기록 |

이 분류로 **프롬프트 점프 네비게이션**이 동작한다 — `Cmd+↑`/`Cmd+↓`로 이전/다음 명령의 프롬프트로 뷰포트를 점프한다(iTerm2·VSCode식). `core.jumpToPrompt(dir)`가 "프롬프트 블록 시작"(prompt/input run의 첫 행)을 절대 행 좌표로 찾아 뷰포트 맨 위에 둔다. Swift는 Cmd+↑/↓ keyCode만 감지해 `jump_prompt` ABI로 방향을 넘기고(native 최소, scroll_page와 같은 규율), 분류·이동은 Zig가 한다. 셸 통합이 없으면 분류가 전부 unknown이라 무동작.

clean-room: 통합 스크립트는 **zsh 매뉴얼의 ZDOTDIR/스타트업·precmd/preexec·PS1 `%{%}` 동작과 semantic-prompts.md 명세에서 직접 작성**했다. Ghostty·kitty의 통합 스크립트는 GPLv3라 차용하지 않았다(메커니즘 자체는 zsh 공개 동작/공개 명세). 현재 zsh 전용이고, bash/fish 마커 emit·거터 ✓/✗ 렌더는 후속이다.

## 기본 제공 macOS 줄 편집 단축키 (빌트인)

macOS Cmd 조합은 보통 앱 단축키 영역이라, 안 묶인 Cmd 조합은 셸로 보내지 않는다(`Cmd+S`가 셸에
`s`를 타이핑하지 않게 — `KeyBindingResolver.resolve`의 `.ignored`). 하지만 Mac 사용자가 셸 입력줄에서
기대하는 편집 동작 몇 가지는 **빌트인 기본 terminal 바인딩**(`keybinding.default_terminal_bindings`)으로
셸 시퀀스에 매핑한다. 흩어진 특수 케이스가 아니라 한 테이블(데이터)로 두고, resolve가
**사용자 config 바인딩 → 이 빌트인 → (안 묶인 Cmd면) `.ignored` → 아니면 encodeKey** 순으로 본다.
Ghostty 기본 keybind와 동작이 같다.

| 키 | 바이트 | 동작 |
|---|---|---|
| `Cmd+Backspace` | `\x15` (Ctrl+U) | 커서~줄 시작 삭제 |
| `Cmd+Left` | `\x01` (Ctrl+A) | 줄 시작으로 |
| `Cmd+Right` | `\x05` (Ctrl+E) | 줄 끝으로 |
| `Option+Left` | `\eb` (Meta-b) | 단어 왼쪽 |
| `Option+Right` | `\ef` (Meta-f) | 단어 오른쪽 |
| `Option+Backspace` | `\e\x7f` (Meta-DEL) | 단어 삭제 (encodeKey meta-ESC가 처리) |

`KeyChord.eql`이 modifier를 정확히 비교하므로 `Cmd+Backspace`만 매칭한다(`Cmd+Shift+Backspace`는
빌트인이 아니라 `.ignored`). 사용자가 `keybind`로 같은 조합을 다시 묶으면 그게 우선한다.

## 검증 계획

- key chord parser test: modifier 중복, 알 수 없는 alias, key 누락, key 중복, F-key 범위 오류를 실패로 보고한다.
- config/keybinding resolver test: 같은 key 조합이 app action과 terminal override에 동시에 있으면 실패한다.
- config validation test: terminal 관용 조합을 app/global shortcut으로 등록하면 경고한다.
- resolver unit test: `Cmd+B -> send_control("b")`는 `0x02` terminal input으로 변환된다.
- resolver unit test: app action과 terminal input macro가 같은 key chord를 쓰면 오류다.
- resolver unit test: app action으로 소비된 key는 terminal input으로 내려가지 않는다.
- resolver unit test: 등록하지 않은 `Ctrl+B` 같은 조합은 global shortcut 때문에 소비되지 않는다.
- terminal input encoder test: `Ctrl+<key>`는 전체 C0 테이블(`@`, `A-Z`, `[ \ ] ^ _`, `Space`, `?`)로, C0 매핑이 없는 조합은 문자 그대로, `Alt/Option`은 ESC prefix(화살표·Esc 제외)로 변환된다.
- config validation test: `send_control` codepoint가 C0로 매핑되지 않으면 설정 로드 시점에 오류로 보고한다.
- PTY E2E: terminal input으로 분류된 key만 shell에 전달된다.
- macOS app E2E: global shortcut registration 실패/성공을 artifact로 남긴다.

macOS 전역 핫키는 window server와 권한 상태에 영향을 받을 수 있다. 자동 E2E가 안정적이지 않으면 opt-in app smoke test와 수동 검증 산출물을 먼저 둔다.


## 레이아웃 독립 단축키와 IME

- Ctrl/Cmd가 눌린 키는 입력기(IME)에 보내지 않고 바로 단축키/인코딩 경로로 간다. 매칭은 글자가 아니라 **물리 키코드** 기준이다: 한글 입력 모드에서 Ctrl+B를 누르면 AppKit 글자는 'ㅂ'이지만 물리 키는 B이므로 0x02(tmux prefix)가 PTY로 간다. Cmd+C/V도 동일하다(kVK_ANSI_C/V).
- 변환 규칙은 Zig(`src/platform/macos/keycode.zig`)가 소유한다: Ctrl/Cmd 조합에서 현재 레이아웃의 글자가 라틴이 아니면(>= 0x80) 물리 키코드를 US 배열 라틴으로 되돌린다. 라틴 레이아웃(영어/Dvorak)의 결과는 그대로 둔다 — 사용자가 고른 라틴 배열의 글자 배치를 존중한다. Swift는 `NSEvent.keyCode`를 ABI(`raw_key_code`, v18)로 전달만 한다.
- 수정자 없는 일반 타이핑(Shift 포함)은 `NSTextInputClient`/`interpretKeyEvents`로 입력기를 거친다 — 한글 조합이 여기서 일어난다. **IME 판정은 전부 Zig의 키 트랜잭션이 소유한다**(ABI v20: `ime_begin` → 입력기 콜백이 `ime_insert`(확정 누적)/`ime_marked`(조합 표시)로 쌓음 → `ime_end`가 일괄 판정 — Ghostty의 keyTextAccumulator와 같은 구조). Swift에는 IME 분기 로직이 없다(전달만). 판정 규칙(위에서부터 첫 일치, 전부 unit 검증):
  1. 확정 텍스트가 쌓였으면 그것만 코드포인트 단위로 기존 encodeKey 경로에 보낸다(키 자체는 입력기가 소비 — 조합 확정 Enter는 확정만, 개행 없음). 단 조합 중 단일 C0(조합 조작용 Ctrl+H류)는 입력기 소유라 버린다.
  2. 텍스트는 없지만 조합이 변했으면(자모 삭제 등) 키를 보내지 않는다.
  3. 둘 다 아니면 일반 키 — 기존 인코딩 경로(Enter/Backspace/기능키).
  ime_end는 정규화 불가 키(codepoint/keyCode 없음)에도 반드시 호출돼 트랜잭션을 닫는다(안 닫으면 누적 텍스트 유실·ime_active 박힘). 확정 텍스트와 함께 온 화살표는 확정 후 다시 보낸다(위/오른/아래 항상, 왼쪽은 수정자 있을 때만 — 한글 후보를 화살표로 확정 시 커서 이동 보존). imeInsert가 OOM이면 그 커밋을 통째로 버린다(반쪽 문자열 방지).
  추가로, 한글 마지막 자모 백스페이스에서 입력기는 `insertText`(조합 글자) + `deleteBackward`를 같은 keyDown에 보내는데(커밋 후 삭제 = net 0, 실측 확인), `deleteBackward`가 같이 오면 확정 텍스트의 마지막 코드포인트를 그 삭제가 상쇄한다 — 글자가 PTY에 박혔다가 다음 백스페이스로 지워야 하는 문제를 없앤다(ABI v21 ime_delete_backward).
  Option+글자는 입력기를 우회해 기존 meta-ESC 인코딩을 유지한다(특수문자 입력이 아님). Control+Command+Space(이모지 & 기호 피커)는 Ctrl/Cmd 가로채기보다 우선해 시스템 character palette를 연다 — 고른 이모지/기호는 입력기 insertText로 들어와 PTY로 전송된다. 조합 시작(imeBegin)은 타이핑처럼 뷰포트를 바닥으로 스냅해 스크롤백을 본 채 조합해도 preedit이 보인다. 입력기 후보창은 커서 셀 위치에 뜬다(ABI v22 ime_cursor_rect — Zig가 커서 셀의 backing px 사각형을 주고 Swift firstRect가 화면 좌표로 변환). 확정 텍스트의 개행은 \r로 정규화한다(멀티라인 insertText 안전). 포커스 변화도 Zig가 소유한다(`set_focus`) — 잃으면 조합 중 텍스트를 버리지 않고 확정 커밋한다(Terminal.app/Ghostty 의미론, unit 검증).
- 조합 중(preedit) 글자는 커서 위치에 반전 스타일로 합성 표시되고, 그동안 블록 커서는 숨긴다(반전 preedit이 커서 역할 — 안 숨기면 preedit 끝에 블록 커서가 또 그려져 커서가 둘로 보인다). 깜빡임도 멈춘다(보이는 위상 고정 — Terminal.app/Ghostty 동일). 포커스 이탈(view resign + 창 key 상실 — 앱 전환 포함)에는 조합 중 텍스트를 버리지 않고 확정(커밋)해 입력기 상태와 화면이 어긋나지 않게 한다. 아직: 입력기 후보창의 커서 위치 정밀 배치, preedit 밑줄 스타일(현재 반전).
