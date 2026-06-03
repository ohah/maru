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
  - split_pane
  - focus_next_pane

terminal_key_overrides:
  - send_text
  - send_escape_sequence
```

이렇게 나누는 이유는 충돌을 사람이 이해할 수 있게 만들기 위해서다. 같은 `Cmd-Space`라도 OS 전역 핫키인지, 앱이 focus 되었을 때만 쓰는 단축키인지, shell로 보낼 문자열인지가 다르다.

## 충돌 규칙

- global shortcut은 정확히 등록한 key chord만 소비한다. 예를 들어 `Ctrl+Cmd+,`를 등록해도 `Ctrl+B`, `Ctrl+C`, `Esc`에는 영향을 주지 않는다.
- global shortcut과 terminal input이 같은 조합이면 global shortcut이 이긴다. 전역으로 등록한 키는 사용자가 앱 밖에서도 Maru 명령으로 쓰겠다고 선택한 것이기 때문이다.
- app keybinding과 terminal input override가 같은 조합이면 config validation에서 오류로 보고한다.
- OS나 다른 앱이 이미 선점한 global shortcut은 등록 실패로 보고하고, 조용히 무시하지 않는다.
- 사용자가 명시적으로 `send_text` 또는 `send_escape_sequence`를 설정한 조합은 app action과 동시에 사용할 수 없다.

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

## v0 범위

v0에서는 글로벌 핫키를 구현하지 않는다. 지금은 다음 경계만 유지한다.

- `Action`/keybinding config가 terminal input과 분리될 수 있어야 한다.
- `PtySession`은 이미 해석된 terminal input bytes만 받는다.
- macOS global shortcut 구현은 `src/platform/macos/` 아래 platform bridge 책임으로 둔다.

## 검증 계획

- config parser test: 같은 key 조합이 app action과 terminal override에 동시에 있으면 실패한다.
- config validation test: terminal 관용 조합을 app/global shortcut으로 등록하면 경고한다.
- resolver unit test: app action으로 소비된 key는 terminal input으로 내려가지 않는다.
- resolver unit test: 등록하지 않은 `Ctrl+B` 같은 조합은 global shortcut 때문에 소비되지 않는다.
- PTY E2E: terminal input으로 분류된 key만 shell에 전달된다.
- macOS app E2E: global shortcut registration 실패/성공을 artifact로 남긴다.

macOS 전역 핫키는 window server와 권한 상태에 영향을 받을 수 있다. 자동 E2E가 안정적이지 않으면 opt-in app smoke test와 수동 검증 산출물을 먼저 둔다.
