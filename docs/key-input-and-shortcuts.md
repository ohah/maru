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

### 입력 대상 라우팅 통합 (후속 — 계획)

평문/IME 확정 텍스트·조합(preedit)을 **어느 입력이 받나**는 `AppSession.inputFocus()`(단일 출처 enum: `terminal`·`confirm`·`notice`·`settings`·`rename`·`sidebar_search`·`find`·`palette`·`addr_edit`)가 판정하고, 그 판정을 **exhaustive switch 여러 곳**(`imeSetPreedit`·`imeComposingActive`·`commitComposition`·`overlayCaretRect`·`routeCommittedText`)이 소비한다. 컴파일러가 케이스 누락을 잡아 **안전**하지만, 새 입력 대상 하나를 추가하면 **각 switch에 케이스**를 넣어야 하고(주소창 7e-2 추가 시 실제로 5곳 — 그 중 `routeCommittedText`를 놓쳐 "조합 아닌 평문이 터미널로 새는" IME 버그가 났었다), 같은 디스패치("활성 입력의 메서드 호출")가 여러 곳에 복제되는 냄새가 있다.

**장기 방향**: 텍스트 입력 프리미티브는 `OverlayInput`(query/preedit·caret·가로 스크롤·EAW 단일 출처) **하나로 수렴**한다 — `find`/`palette`/`rename`/`sidebar_search`/`addr_edit`는 이미 그것이고, **`settings`의 고정 버퍼 편집(마지막 중복)을 OverlayInput으로 이주**한다. 그러면 "활성 OverlayInput"이 동종이므로 `activeTextInput() ?*OverlayInput` 하나로 뽑아, 위 switch들을 `if (activeTextInput()) |in| in.method(...) else <터미널>` 형태로 **접을 수 있다**("누가 활성인가"를 한 곳에서만 판정, 각 호출부는 스위치 없이 메서드만). **터미널은 정당한 예외**(버퍼가 아니라 PTY로 확정 전송·preedit이 core에 있음)라 명시적 단일 특수 케이스로 남긴다. 각 기능(주소창 URL 검증·네비, find 검색 등)의 **행동**은 프리미티브가 아니라 그 위에 얹는다(공유 프리미티브 + 개별 기능 분리).

**순서**: IME·키 경로(민감)를 건드리는 회귀 위험이 있어 Phase 7(인앱 브라우저) 안정 후 **별도 슬라이스**로 한다(주소창 addr_edit 추가가 동기 증거). 지금은 프리미티브를 더 늘리지 않는 것(신규 텍스트 입력은 OverlayInput 재사용)만으로 충분하다.

## 설정 범주

config는 다음 범주를 분리한다. 실제 형식은 `keybind = <chord> = <action>` 한 줄이며, 전역은 chord 앞 `global:` 접두사로 구분한다(형식·키는 [설정(config) 파일](configuration.md)이 단일 출처).

```text
전역(OS) 단축키 — keybind = global:<chord> = <action>:
  - toggle_window
  - show_window
  - toggle_quick_terminal

앱 단축키 — keybind = <chord> = <action>:
  - new_tab
  - close_tab
  - split_horizontal / split_vertical
  - next_pane / focus_pane_left …

터미널 입력 매크로 — keybind = <chord> = send_*:
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

- modifier 순서는 항상 `Cmd`, `Ctrl`, `Alt`, `Shift` 순서로 저장한다(`KeyChord.toConfigString`이 config 파일에 write-back하는 순서). 단 메뉴/표시 경로(`command_catalog.formatChord`)는 다른 시각 순서 `⌃⌥⇧⌘`(Ctrl, Option, Shift, Cmd)로 렌더한다 — 즉 config 파일 write-back 순서와 메뉴 표시 순서는 다르며, 여기서는 영속(persisted) config 파일 형식을 기술한다. parsing은 순서 무관이라 이는 동작이 아니라 저장 철자(canonical spelling) 계약이다.
- key 이름은 대소문자를 구분하지 않고 canonical name으로 바꾼다.
- `Command` 같은 alias는 초기에는 허용하지 않는다. alias가 필요하면 별도 PR에서 추가한다.
- 같은 modifier를 두 번 쓰면 오류다.
- key가 없으면 오류다.
- 알 수 없는 key 이름은 오류다.
- `+`는 chord part 구분자라 키 이름으로 직접 쓸 수 없다. 리터럴 `+` 키는 `Plus`로 표기한다(예: `Cmd+Plus`). `Cmd++`처럼 빈 part가 생기는 표기는 오류다.

예시:

```text
Cmd+B          -> Cmd+B
ctrl+cmd+,     -> Cmd+Ctrl+,
Shift+Alt+F13  -> Alt+Shift+F13
Cmd+Cmd+B      -> 오류
Command+B      -> 초기에는 오류
```

이 parser 계약은 config 파일 parser와 독립으로 단위 테스트할 수 있다. `KeyChord.parse("Ctrl+Cmd+,")` 같은 작은 단위 테스트로 검증하고, config 파일 parser(`src/config/loader.zig`)가 이 함수를 호출해 `keybind` 줄을 해석한다. config 파일의 위치·형식·키는 [설정(config) 파일](configuration.md)이 단일 출처다.

현재 구현 상태:

- `src/config/keybinding.zig`가 `KeyChord.parse`와 `KeyBindingResolver`의 최소 계약을 구현한다.
- `Cmd+B`, `ctrl+cmd+,`, `Shift+Alt+F13` 같은 key chord 문자열은 parser 단위 테스트로 검증한다.
- `mise run macos-app-pty-metal-smoke`는 기본적으로 AppKit synthetic `keyDown:`에서 얻은 `Cmd+B` payload가 `FrameLoop.handleKeyEvent -> KeyBindingResolver -> SurfaceRuntime.writeInput`을 거쳐 PTY와 visible Metal frame까지 도달하는지 검증한다.
- `MARU_APP_PTY_METAL_KEYDOWN_SOURCE=manual MARU_APP_PTY_METAL_KEYDOWN_MS=15000 mise run macos-app-pty-metal-smoke`는 사용자가 Metal terminal window에서 직접 누른 `Cmd+B`를 같은 경로에 태운다. 이 smoke는 물리 키 한 번의 AppKit 경계를 검증하지만, 아직 지속 interactive shell loop는 아니다.
- `mise run macos-app-pty-interactive-metal-smoke`는 실제 `$MARU_INTERACTIVE_SHELL` 또는 `$SHELL -i`에도 같은 keybinding input 경계를 사용한다. 이 smoke는 shell startup과 marker command가 visible renderer까지 도달하는지 검증하지만, 사람이 계속 입력하는 제품 loop는 아니다.
- `Ctrl+<key>` 인코딩은 `a-z`/`A-Z`뿐 아니라 전체 C0 테이블을 다룬다: `Ctrl+@`=0x00, `Ctrl+A..Z`=0x01..0x1a, `Ctrl+[`=0x1b(ESC), `Ctrl+\`=0x1c, `Ctrl+]`=0x1d, `Ctrl+^`=0x1e, `Ctrl+_`=0x1f, `Ctrl+Space`=NUL, `Ctrl+?`=DEL. C0 매핑이 없는 `Ctrl+1` 같은 조합은 키 이벤트를 실패시키지 않고 그냥 문자를 보낸다.
- `Option/Alt`(Meta) ESC prefix는 plain-byte 키(문자/Enter/Tab/Backspace)에만 붙인다. 화살표·Esc처럼 base 인코딩이 이미 ESC로 시작하는 키에는 붙이지 않는다(`Option+Up`이 `\x1b\x1b[A` 같은 double-ESC가 되지 않게). 화살표류의 modifier 인코딩(CSI 파라미터)은 이후 계약이다.
- `send_control` 매크로의 codepoint는 config validation 단계에서 C0 매핑 가능 여부를 검사한다. 잘못된 codepoint는 키를 누를 때가 아니라 설정 로드 시점에 오류로 보고한다.
- 기능키(Home/End/Insert/Delete/PageUp/PageDown/F1~F12)는 `terminal.Key` 변형 + `encodeKey`의 xterm legacy 인코딩(편집키 `CSI ~`, Home/End는 DECCKM, F1~F4 SS3·F5~F12 `CSI ~`) + 키바인딩 매핑(`keyNameFromTerminalKey`, KeyName/parseKey)으로 구현돼 설정 바인딩이 실제 이벤트와 매칭된다(순수 Zig, Linux CI 단위 테스트). AppKit bridge도 연결됐다 — ABI KeyCode enum(home~f12) + Swift `normalizedKeyEvent`의 keyCode 매핑(NSEvent.keyCode 캡처만 Swift, 인코딩·바인딩은 Zig)으로 물리 키가 vim/less/셸에 전달된다(계약/매핑 단위 테스트). 특수 비-텍스트 키(Home/End/PageUp/PageDown/ForwardDelete/Insert/F1~F12)와 단축키 조합(Cmd/Ctrl/Option)은 keyDown에서 IME 트랜잭션을 거치지 않고 바로 인코딩 경로(handleKeyDown)로 보낸다 — 이들은 텍스트 합성이 아니라 편집/스크롤 selector라 `interpretKeyEvents`에 맡기면 안정적으로 인코딩되지 않기 때문이다. **단 조합(marked text) 중이면 먼저 그 조합을 확정한 뒤 보낸다**(Swift `imeCommit` → ABI `commit_composition` + `discardMarkedText`) — 안 그러면 Swift marked text와 core preedit가 안 비워진 채 PageUp이 화면을 옮겨, 이후 입력이 stale한 marked range에 박혀 위치가 어긋나거나 안 먹거나 안 지워진다. 화살표만 한글 확정 후 커서 이동 replay 때문에 IME 경로에 남는다. PageUp/PageDown는 설정(`input.page-keys`)으로 가른다 — **기본 `scroll`**은 Terminal.app/iTerm2처럼 메인 화면에서 Maru 스크롤백을 페이지 스크롤한다(셸로 `\e[5~`를 안 보내 셸 keymap·프레임워크와 무관하게 입력줄이 안 깨짐 — Mac 관례). `passthrough`(opt-in)는 xterm/Ghostty처럼 `\e[5~`/`\e[6~`를 PTY로 보내는데, 셸 프롬프트에선 깨진다 — emacs keymap은 BEL+`~`를 입력줄에 박고, vi keymap은 끝 `~`를 vi-swap-case로 해석해 대소문자를 토글한다(실측 캡처 확인). alt 화면(vim/less)에선 어느 값이든 항상 `\e[5~`/`\e[6~`를 앱에 보낸다(alt 여부와 모드는 Zig가 판정 — native 최소). Home/End/F1~F12는 화면·설정과 무관하게 시퀀스를 그대로 보낸다(readline/앱이 바인딩). Shift+PageUp/Down 스크롤백은 handleKeyDown에서 먼저 소비돼 plain PageUp만 PTY로 간다. F13~F24와 modifier 조합(`CSI 1;{mod}~`)·CSI-u/Kitty는 후속.
- config 파일 parser(`src/config/loader.zig` — `key = value` 줄 형식, TOML 아님)와 수동 runtime reload(메뉴 **Reload Config**, ABI v56)는 구현됐다. 형식·키·검증·reload 동작은 [설정(config) 파일](configuration.md)이 단일 출처다. 파일 변경 자동 감지 reload와 설정 GUI는 후속이다.

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
- global shortcut에서 terminal bytes를 보내야 한다면 대상 surface를 명시하는 action chain(창 포커스 → 대상 surface 선택 → send_control)이어야 한다. action chain 자체는 미구현 설계이고, 현재 `GlobalAction`은 창 가시성 동작 3종만 지원한다.

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

## 글로벌 핫키 현황 (구현됨)

글로벌 핫키는 구현되어 있다. 제품 정책은 [터미널 호환성/보안 정책](terminal-compatibility-policy.md#global-shortcut)을 따른다.

- config: `keybind = global:<chord> = <action>` 한 줄 형식(`config/loader.zig`가 `global:` 접두사로 분기해 `global_bindings`로 파싱).
- 동작: `GlobalAction` enum — `toggle_window`/`show_window`/`toggle_quick_terminal`(`config/action.zig`). 앱이 비활성이어도 OS가 잡아 Swift가 수행하는 NSWindow 동작이라, in-app `Action`과 별도 enum으로 분리했다(dispatch exhaustive switch 오염 방지).
- OS 등록: 설계대로 `src/platform/macos/` platform bridge 책임 — `global_hotkey.zig`가 KeyChord를 Carbon `RegisterEventHotKey` 인자(가상 키코드 + Carbon modifier mask)로 변환(순수 매핑, OS 무관 단위 테스트)하고, `MaruAppHost.swift`가 시작·config reload 시 등록/재등록하고 `drainGlobalHotkeys`로 이벤트를 Zig에 전달한다.

구현과 무관하게 유지하는 경계:

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

같은 분류로 **sticky command(sticky scroll)** 도 동작한다 — 스크롤백을 위로 올리면(view_offset>0) 지금 뷰포트 최상단 출력이 속한 명령의 **명령줄(.input)을 뷰포트 최상단 한 줄에 고정 표시**한다(VSCode sticky scroll의 터미널판). `core.stickyCommand()`(탐지 단일 출처, headless 단위)가 최상단(스크롤백 인덱스 `count−view_offset`)에서 위로 거슬러 가장 가까운 `.input` 행을 찾고(이미 보이면 null), 종료코드는 OSC 133 `D`가 프롬프트 시작 행에 스탬프한 값을 프롬프트 블록에서 읽는다. platform(`buildStickyDrawListAndPlacement`)은 그 행 텍스트를 추출해 **✓(0)/✗(≠0) 종료상태 + 명령줄**을 불투명 배너로 만들어(`buildStickyCommandDrawList`) 활성 pane 터미널 영역 최상단에 **활성 터미널 위·floating ghost 아래**(`.sticky` collect dest → `placeMultiPane` 한 atlas 세대)로 그리고, 배너 아래 경계에 구분선 quad를 둔다. config `scrollback.sticky-command`(기본 true)로 끄고 켠다. **베이스/결정**: ① 표시 대상은 `.input`(사용자가 친 명령줄) — `.prompt`(프롬프트 텍스트)·`.command`(출력)와 구분해 "지금 보는 출력을 만든 명령"을 보인다. ② 명령줄이 이미 최상단에 보이면(최상단 kind가 input/prompt) 중복이라 안 띄운다. ③ **활성 pane만**(MVP) — split 비활성 pane을 휠로 스크롤해도 배너는 활성 pane 기준이다(per-pane sticky는 후속). ④ 셸 통합(OSC 133)이 없으면 마커가 전부 unknown이라 `.input`을 못 찾아 자연히 안 뜬다(graceful no-op) — 현재 zsh 전용.

같은 통합 `.zshenv`는 **잔류 입력 모드도 매 프롬프트에서 자동 복구**한다 — `precmd` 훅(`_maru_reset_input_modes`)이 focus reporting(`\e[?1004l`)·mouse tracking(`\e[?1000l\e[?1002l\e[?1003l`)·kitty keyboard 스택(`\e[<16u`)을 끈다. ssh 너머 TUI(claude/vim/tmux 등)가 이 모드를 켠 채 **SIGKILL로 비정상 종료**하면 정리 시퀀스(`\e[?1004l`)가 전달되지 못해, raw 셸로 돌아온 뒤 **창 포커스마다 `^[[I`/`^[[O`가 입력줄에 쌓이고 비프음**이 나는 잔류 증상이 생긴다(모든 터미널 공통 문제 — 터미널은 ssh 끊김을 알 수 없어 자동 감지가 불가능하다). precmd는 **프롬프트가 그려질 때(=풀스크린 TUI가 없을 때)만** 돌아 정상 앱을 깨지 않으므로, 다음 프롬프트에서 사용자 개입 없이 회복된다. `bracketed paste(2004)`·application cursor keys(1)는 zsh `zle`이 매 줄 직접 켜고 끄므로 제외한다(충돌 회피). 셸 통합이 안 닿는 비zsh 셸·hang 복구 직후엔 수동 `⌘⇧R`(아래 "터미널 입력 모드 리셋")로 회복한다.

clean-room: 통합 스크립트는 **zsh 매뉴얼의 ZDOTDIR/스타트업·precmd/preexec·PS1 `%{%}` 동작과 semantic-prompts.md 명세에서 직접 작성**했다. Ghostty·kitty의 통합 스크립트는 GPLv3라 차용하지 않았다(메커니즘 자체는 zsh 공개 동작/공개 명세). **거터 마크(✓/✗)도 구현했다** — 프롬프트 시작 행 왼쪽 가장자리에 명령 성공(초록)/실패(빨강) 세로 색 바(`D;<code>`의 종료코드를 그 프롬프트 행에 스탬프; 렌더는 커서 bar와 같은 부분 사각형 재사용, 그리드/PTY 폭 불변). 현재 zsh 전용이고, bash/fish 마커 emit·OSC 7 cwd는 후속이다.

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

## 화면 비우기 (⌘K, clear_screen)

`⌘K`는 활성 터미널의 화면과 스크롤백을 비운다(빌트인 app 바인딩 → `Action.clear_screen` →
`TerminalCore.clearScreen`). iTerm2·Terminal.app·Ghostty가 공통으로 이 키에 화면 비우기를 두는 Mac 관례다.
셸 줄-삭제는 `Ctrl+K`(C0)라 안 겹친다.

**베이스/결정**: Ghostty `clear_screen`(키바인딩을 수렴시키는 1차 레퍼런스)을 베이스로 하고, 동작 비교로만
참고했다(코드 표현은 옮기지 않았다 — clean-room). 단일 표준이 없는 동작이라 레퍼런스 간 차이에서 택한 바를
명시한다: iTerm2 `Clear Buffer`는 셸 통합 없이 버퍼만 지우고, Terminal.app `Clear to Start`는 스크롤백만
지운다. Maru는 셸 readline 모델과 어긋나지 않게 Ghostty식 3분기를 택했다.

| 상황 | 판정 근거 | 동작 | form-feed(^L) |
|---|---|---|---|
| alt 화면(vim/less/htop) | `alt_active` | 무동작 — 그 화면은 앱이 소유하므로 에뮬레이터가 지우면 앱 커서 모델과 어긋난다 | 안 보냄 |
| 셸 프롬프트 | OSC 133 분류 `prompt`/`input`(`semantic_state`) | 화면+스크롤백 비우고 커서 홈 | **보냄** — 셸 `clear-screen` 위젯이 프롬프트를 맨 위에 다시 그린다(셸이 커서를 다시 잡아 desync 없음) |
| 그 외(통합 없음/명령 실행 중) | 위 둘 다 아님 | 스크롤백 + 커서 위 행만 비우고 현재 줄·커서 보존 | 안 보냄 — 커서를 안 옮겨 비통합 셸·실행 중 프로그램과 어긋나지 않게 한다 |

경계: `TerminalCore.clearScreen`은 코어 상태(셀·스크롤백·커서)만 바꾸고 PTY로는 쓰지 않는다(L1 경계 —
docs/io-render-threading.md). 대신 "form-feed를 보낼지"를 bool로 돌려주고, `app_session.dispatchAppAction`이
코어 락 **밖**에서 `0x0C`를 PTY로 쓴다(블로킹 PTY 쓰기를 락 밖으로 — PR1/PR3 패턴). 프롬프트 분류는 셸
통합(OSC 133)이 있을 때만 생기고, 그때만 셸 `^L`이 정상 동작하므로 프롬프트 분기와 form-feed가 일관된다.

**config**: 빌트인이라 사용자 config로 끄거나(`keybind = Cmd+K = unbind`) 다른 키로 옮길 수 있고
(`keybind = Cmd+L = clear_screen`), `clear_screen`은 `parseAction`이 인식하므로 임의 chord에 묶을 수 있다.

## 터미널 입력 모드 리셋 (⌘⇧R, Reset Terminal)

`⌘⇧R`(maru 메뉴 **Reset Terminal**)은 활성 터미널의 **잔류 입력 모드만** 끈다: focus reporting(1004)·mouse
tracking(1000/1002/1003)·mouse format(1006)·kitty keyboard 스택·bracketed paste(2004)·application cursor
keys(1)·keypad. **화면·스크롤백·커서는 보존**한다(`TerminalCore.resetInputModes` — `fullReset`/RIS의 비파괴 변형).

용도: ssh 너머 TUI가 SIGKILL로 죽어 정리 시퀀스를 못 보낸 탓에 포커스/마우스마다 `^[[I`·좌표가 흘러나오는
증상의 **수동 회복 경로**다. 위 셸 통합 자동 복구(precmd)가 주력이고, 이 메뉴는 **셸 통합이 안 닿는 경우**
(bash/fish 등 비zsh, 또는 ssh가 hang해 프롬프트가 아직 안 그려진 직후)를 위한 백업이다. 표준 `reset`은 화면·
스크롤백까지 지우지만, Maru는 증상 원인(잔류 모드)만 끊어 작업 맥락을 보존한다.

경계: Swift 메뉴 액션 → ABI `maru_macos_app_session_reset_input_modes` → `app_session.resetInputModes`(활성
surface 코어 락 아래 `core.resetInputModes`). 입력 인코딩 상태만 바꿔 렌더에 영향이 없다(focusChanged와 같은
PR3 패턴 — 코어 변경을 `core_mutex` 아래서 한다).

## 검증 계획

- key chord parser test: modifier 중복, 알 수 없는 alias, key 누락, key 중복, F-key 범위 오류를 실패로 보고한다.
- config/keybinding resolver test: 같은 key 조합이 app action과 terminal override에 동시에 있으면 실패한다.
- keybinding resolver test: `Cmd+K`가 빌트인 `clear_screen` app action으로 resolve된다(사용자 config 없이).
- core clearScreen test: 프롬프트(화면+스크롤백 비움·커서 홈·form-feed 요청)·alt 화면(무동작)·비프롬프트(커서 위만 비움) 세 경로.
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
- 조합 중(preedit) 글자는 커서 위치부터 반전 스타일로 합성 표시된다(`TerminalCore.snapshotWithPreedit`). **삽입형 미리보기**라, 줄 가운데에서 조합하면 커서 뒤 글자를 조합 폭만큼 오른쪽으로 밀어 확정 후 셸이 그릴 모습을 조합 중에도 보여준다(`가나다`의 `나` 앞 조합 → `가[라]나다`). 합성 버퍼(`viewport_cells`)에만 그리는 것이라 실제 셀 그리드·셸 상태는 불변이고, 확정 순간 셸/앱이 다시 그려 화면이 자연스럽게 이어진다. **단 예외 하나**: 커서에서 시작하는 후행 콘텐츠 run이 전부 faint(SGR 2 → `Cell.style.dim`)면 앱이 그린 인라인 자동완성 고스트로 보고 밀지 않고 오버레이로 덮는다. **베이스/결정**: 삽입형은 셸 insert-mode 편집 결과와 시각적으로 일치한다(줄 중간 삽입을 조합 중에도 보여준다 — 사용자 요청). 순수 삽입형의 유일한 부작용은, 앱이 커서 뒤에 그린 인라인 자동완성 고스트까지 '보존할 뒤 글자'로 오인해 옆으로 밀어 잔상을 남기는 것이었다 — 조합 중 텍스트는 확정 전까지 앱에 미전송이라 앱이 고스트를 안 지운다(영문은 키 즉시 commit으로 앱이 고스트를 지워 잔상이 없다). 한때 이 때문에 통째 오버레이로 뒀으나 그러면 줄 중간 삽입이 "덮어쓰기"처럼 보였다(실측 제보). 정공법으로 **딱 고스트 케이스만** 예외 처리한다: Claude Code 등은 인라인 고스트를 Ink `dimColor`(=chalk dim=**SGR 2 faint**)로 그리므로(Claude Code 바이너리 문자열 확인 — `dimColor:!0` 렌더 + `→`/Tab accept의 fish 스타일 인라인 제안), 후행 run이 전부 dim이면 고스트로 판정한다. 실제 편집 텍스트는 일반 intensity라 dim이 아니어서 삽입형으로 밀린다 — **dim 한 플래그가 오버레이(고스트) vs 삽입(실 텍스트)을 정확히 가른다**. 고스트를 **색**(예: zsh-autosuggestions 기본 `fg=8`, fish `fish_color_autosuggestion` 기본 `555`)으로 그리는 셸 자동완성은 `dim` 플래그가 아니라 전경색이라 이 예외에 안 걸려 밀리며(그쪽은 조합 중 잔상이 잠깐 남았다 확정 시 사라짐), 그건 **의도된 범위**다. **색 기반 감지를 안 넣는 근거**: `fg=8`(밝은 검정)은 고스트뿐 아니라 진짜 dim 콘텐츠(프롬프트 타임스탬프·git 상태·구분자, syntax-highlight 주석)에도 흔히 쓰여 **고스트와 실 텍스트가 같은 색**이 된다 — 색만으론 원리적으로 구분 불가. "회색 fg=고스트" 규칙은 실 텍스트를 고스트로 오인해 덮어 **삽입 미리보기 기능 자체를 실 텍스트에서 깬다**(핵심 기능 회귀 > 색 고스트가 조합 중 잠깐 밀리는 가벼운 글리치, 확정 시 정상). 그래서 의미 신호인 `dim`(SGR 2 = de-emphasized, 실 명령줄 텍스트엔 거의 안 쓰임)만 신뢰한다. dim 휴리스틱의 양방향 한계(앱이 SGR 2로 그린 실 텍스트를 고스트로 오판해 가림)는 셸 입력줄에선 드문 경우다. 정 색 고스트까지 잡아야 하면 config opt-in(기본 꺼짐)으로 "회색 후행도 고스트 간주"를 둘 수 있으나, 기본은 dim만. 참고: 앱의 별도-줄 자동완성 메뉴(`/`·`@` 팝업)는 커서 뒤 같은 줄이 아니라 다른 줄이라 삽입형이 애초에 안 건드린다. 조합 중 블록 커서는 숨긴다(반전 preedit이 커서 역할 — 안 숨기면 preedit 끝에 블록 커서가 또 그려져 커서가 둘로 보인다). 깜빡임도 멈춘다(보이는 위상 고정 — Terminal.app/Ghostty 동일). 포커스 이탈(view resign + 창 key 상실 — 앱 전환 포함)에는 조합 중 텍스트를 버리지 않고 확정(커밋)해 입력기 상태와 화면이 어긋나지 않게 한다. 아직: 입력기 후보창의 커서 위치 정밀 배치, preedit 밑줄 스타일(현재 반전).
