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
- `F1..F24`와 `Delete`는 설정 문자열로는 파싱·validate되지만, 현재 `terminal.Key`(정규화된 런타임 키 이벤트)에는 function/delete variant가 없어 실제 키 이벤트와 절대 매칭되지 않는 죽은 설정이다. AppKit bridge가 실제 function/delete event를 넘기는 PR에서 `terminal.Key` 타입과 byte 인코딩을 함께 확장한다.
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
