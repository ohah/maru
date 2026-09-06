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

### 입력 대상 라우팅 통합 — 이 계약 밖(별도 슬라이스)

평문/IME 확정 텍스트·조합(preedit)을 **어느 입력이 받나**는 `AppSession.inputFocus()`(단일 출처 enum: `terminal`·`confirm`·`notice`·`settings`·`rename`·`sidebar_search`·`find`·`palette`·`addr_edit`)가 판정하고, 그 판정을 **exhaustive switch 여러 곳**(`imeSetPreedit`·`imeComposingActive`·`commitComposition`·`overlayCaretRect`·`routeCommittedText`)이 소비한다. 컴파일러가 케이스 누락을 잡아 **안전**하지만, 새 입력 대상 하나를 추가하면 **각 switch에 케이스**를 넣어야 하고(주소창 7e-2 추가 시 실제로 5곳 — 그 중 `routeCommittedText`를 놓쳐 "조합 아닌 평문이 터미널로 새는" IME 버그가 났었다), 같은 디스패치("활성 입력의 메서드 호출")가 여러 곳에 복제되는 냄새가 있다.

**장기 방향(정정 — [text-field-editor.md] 결정 반영)**: 프리미티브는 **둘**이다. ⑴ `OverlayInput` — 끝-caret 검색형(`find`/`palette`/`rename`/`sidebar_search`)의 lean 모델, ⑵ `TextField`(`chrome/components/text_field.zig`) — mid-string caret·선택·마우스 편집이 필요한 곳(현재 소비자는 `addr_edit` 하나). 초판은 "`OverlayInput` 하나로 수렴"이었으나, caret 편집 상태를 검색 모델에 욱여넣으면 추상이 흐려지고 find/palette는 ←/→를 오버레이 닫기에 써 caret 편집을 명시 거부하므로 **이관 0**으로 결정했다([text-field-editor.md] §2.2). 남은 중복은 **`settings`의 고정 버퍼 편집**(현재도 `OverlayInput.displayCols`만 빌려 쓰는 자체 버퍼)이고, 이주 대상은 그 하나다. 두 프리미티브 각각은 동종이므로 `activeTextInput()`류로 뽑아 위 switch들을 접는 방향은 유효하다("누가 활성인가"를 한 곳에서만 판정). **터미널은 정당한 예외**다. 확정 텍스트는 PTY로 보내고 marked text는 각 GUI attachment의 `Surface`가 소유하는 client-local overlay에 둔다. 각 기능(주소창 URL 검증·네비, find 검색 등)의 **행동**은 프리미티브가 아니라 그 위에 얹는다(공유 프리미티브 + 개별 기능 분리).

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
  - new_web_tab (기본 ⌘⌥T — 활성 pane에 브라우저 Term)
  - close_tab (워크스페이스 cascade, 기본 없음)
  - close_focused (기본 Cmd+W — 입력 포커스 기준 파일 entry 또는 Term close cascade)
  - close_term (기본 없음 — 명시적 사용자 바인딩 호환용 terminal 전용)
  - toggle_file_panel_focus (기본 Cmd+Shift+E — workspace와 파일 도크 왕복)
  - focus_file_tree (기본 chord 없음 — one-way tree focus action)
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
- `Option/Alt`(Meta) ESC prefix는 plain-byte 키(문자/Enter/Tab/Backspace)에만 붙인다. 화살표·Esc처럼 base 인코딩이 이미 ESC로 시작하는 키에는 붙이지 않는다(`Option+Up`이 `\x1b\x1b[A` 같은 double-ESC가 되지 않게). 화살표류의 modifier 인코딩은 **CSI 파라미터로 구현됐다** — ESC prefix 대신 `CSI 1;{mod}<letter>`가 나가므로 double-ESC 문제가 애초에 안 생긴다.
- `send_control` 매크로의 codepoint는 config validation 단계에서 C0 매핑 가능 여부를 검사한다. 잘못된 codepoint는 키를 누를 때가 아니라 설정 로드 시점에 오류로 보고한다.
- 기능키(Home/End/Insert/Delete/PageUp/PageDown/F1~F12)는 `terminal.Key` 변형 + `encodeKey`의 xterm legacy 인코딩(편집키 `CSI ~`, Home/End는 DECCKM, F1~F4 SS3·F5~F12 `CSI ~`) + 키바인딩 매핑(`keyNameFromTerminalKey`, KeyName/parseKey)으로 구현돼 설정 바인딩이 실제 이벤트와 매칭된다(순수 Zig, Linux CI 단위 테스트). AppKit bridge도 연결됐다 — ABI KeyCode enum(home~f12) + Swift `normalizedKeyEvent`의 keyCode 매핑(NSEvent.keyCode 캡처만 Swift, 인코딩·바인딩은 Zig)으로 물리 키가 vim/less/셸에 전달된다(계약/매핑 단위 테스트). 특수 비-텍스트 키(Home/End/PageUp/PageDown/ForwardDelete/Insert/F1~F12)와 단축키 조합(Cmd/Ctrl/Option)은 keyDown에서 IME 트랜잭션을 거치지 않고 바로 인코딩 경로(handleKeyDown)로 보낸다 — 이들은 텍스트 합성이 아니라 편집/스크롤 selector라 `interpretKeyEvents`에 맡기면 안정적으로 인코딩되지 않기 때문이다. **단 조합(marked text) 중이면 먼저 그 조합을 확정한 뒤 보낸다**(Swift `imeCommit` → ABI `commit_composition` + `discardMarkedText`) — 안 그러면 Swift marked text와 Surface preedit가 안 비워진 채 PageUp이 화면을 옮겨, 이후 입력이 stale한 marked range에 박혀 위치가 어긋나거나 안 먹거나 안 지워진다. 화살표만 한글 확정 후 커서 이동 replay 때문에 IME 경로에 남는다. PageUp/PageDown는 설정(`input.page-keys`)으로 가른다 — **기본 `scroll`**은 Terminal.app/iTerm2처럼 메인 화면에서 Maru 스크롤백을 페이지 스크롤한다(셸로 `\e[5~`를 안 보내 셸 keymap·프레임워크와 무관하게 입력줄이 안 깨짐 — Mac 관례). `passthrough`(opt-in)는 xterm/Ghostty처럼 `\e[5~`/`\e[6~`를 PTY로 보내는데, 셸 프롬프트에선 깨진다 — emacs keymap은 BEL+`~`를 입력줄에 박고, vi keymap은 끝 `~`를 vi-swap-case로 해석해 대소문자를 토글한다(실측 캡처 확인). alt 화면(vim/less)에선 수정자 없는 PageUp/Down을 어느 설정값이든 항상 `\e[5~`/`\e[6~`를 앱에 보낸다(alt 여부와 모드는 Zig가 판정 — native 최소). Home/End/F1~F12는 화면·설정과 무관하게 시퀀스를 그대로 보낸다(readline/앱이 바인딩). Shift+PageUp/Down 스크롤백은 handleKeyDown에서 먼저 소비돼 plain PageUp만 PTY로 간다. modifier 조합은 **구현됐다** — `Ctrl+←`·`Ctrl+Delete` 등이 xterm legacy 형식(`CSI 1;{mod}<letter>`·`CSI {n};{mod}~`)으로 나가고, 수식자가 붙으면 DECCKM 을 무시하고 CSI 를 쓴다(SS3 에는 파라미터 자리가 없다). `Shift+Tab`은 전용 final `CSI Z`(backtab)다. **`Ctrl+←`가 평범한 `←`로 나가 셸이 단어 이동을 못 하던 것이 이 자리였다**(사용자 제보 2026-08-22). CSI-u/Kitty도 구현됐다(opt-in). F13~F24와 legacy `modifyOtherKeys`는 후속.
- 위 DECCKM/kitty/기능키 인코딩의 mode 단일 출처는 in-process runtime은 active core, **host-backed는 runtime observation**이다.
  host-backed 일반 key는 attachment placeholder(빈 core, host 모드를 모름)가 아니라 관측의 `app_cursor_keys`·`app_keypad`·
  `kitty_flags`로 만든 `EncodeOptions` override(`AppSession.hostBackedEncodeOptions` → `host.handleKeyEvent`의
  `encode_options_override`)를 넘겨 host가 켠 DECCKM/DECKPAM/kitty mode대로 인코딩한다. 구 host(관측에 필드 없음)는
  기본값(numeric·legacy)으로 폴백한다.
- config 파일 parser(`src/config/loader.zig` — `key = value` 줄 형식, TOML 아님)와 수동 runtime reload(메뉴 **Reload Config**, ABI v56)는 구현됐다. 형식·키·검증·reload 동작은 [설정(config) 파일](configuration.md)이 단일 출처다. schema 기반 설정 GUI는 진행 중이고 파일 변경 자동 감지와 남은 bespoke 위젯은 후속이다.

## 수식자 붙은 특수 키 — 무엇을 베이스로 골랐나 (실측 2026-08-22)

**베이스는 이 저장소가 광고하는 terminfo 다.** maru 의 terminfo 는 `use=xterm-256color` 로 그 항목을
상속하므로(`terminfo/maru.terminfo`), **인코더가 보내는 바이트는 그 항목이 선언한 것과 같아야 한다** —
readline·ncurses 앱은 terminfo 를 읽어 키를 인식하기 때문이다. 추측하지 않고 **이 기계의 terminfo
데이터베이스에서 뽑아** 맞췄다:

```text
$ infocmp xterm-256color
  kcbt = \E[Z        Shift+Tab (back-tab)
  kLFT = \E[1;2D     Shift+←
  kRIT = \E[1;2C     Shift+→
  kf3  = \EOR        F3 (수식자 없음)
  kf15 = \E[1;2R     Shift+F3
  kf27 = \E[1;5R     Ctrl+F3
```

`encodeKey` 의 legacy 갈래가 위와 **바이트 단위로 같다.** 수식자 정수는 `1 + shift + alt*2 + ctrl*4` 이고,
이것은 xterm 이 두 번째 CSI 파라미터에 쓰는 1+비트마스크 표현이다.

**F3 은 형식이 튀는데, 그것이 xterm 의 선택이다.** `kf3` 은 SS3(`\EOR`)인데 `kf15`·`kf27` 은
`CSI 1;{mod}R` 이다 — 즉 수식자가 붙는 순간 계열이 바뀐다. 처음에는 kitty 표를 그대로 재사용해
`CSI 13;{mod}~` 를 보냈는데, **그러면 `kf27` 과 안 맞아 앱이 `Ctrl+F3` 을 인식하지 못한다.**

> **받아들인 대가: `CSI ... R` 은 커서 위치 응답(CPR)과 형식이 같다.** 앱이 `CSI 6n` 을 보내 놓고 답을
> 기다리는 중에 사용자가 `Ctrl+F3` 을 누르면 그것을 좌표로 오해할 수 있다. **kitty 는 이 충돌 때문에
> 자기 프로토콜에서 F3 을 `CSI 13~` 으로 바꿨다** — 그 논의에서 관리자가 "there is a conflict with CPR
> for press events which I didn't realize since I never use CPR ... I will change kitty to produce
> `CSI 13 ~` instead for F3" 이라고 적었다([kitty#5813](https://github.com/kovidgoyal/kitty/discussions/5813)).
>
> **그럼에도 legacy 경로는 `CSI 1;{mod}R` 을 쓴다.** 그 경로의 존재 이유가 *기존 소비자와의 호환*이고,
> 그 소비자들이 읽는 terminfo 가 `kf27=\E[1;5R` 이기 때문이다. 다른 것을 보내면 충돌은 피하지만 키가
> **아예 안 먹는다**. `Ctrl+F3` 은 드물고 CPR 대기 중에 눌릴 확률은 더 낮다.
>
> **kitty 경로는 반대로 간다** — 거기서는 앱이 프로토콜을 명시적으로 켰으므로 `CSI 13~` 이 맞다.
> 두 경로가 F3 에서 갈리는 이유가 이것이고, `legacyEntry` 의 doc 이 그 예외를 소유한다.

**수식자가 붙으면 DECCKM(application cursor)을 무시하고 CSI 를 쓴다.** SS3 에는 파라미터 자리가 없다 —
`kLFT`(`\E[1;2D`)가 CSI 인 것이 그 증거다. vim/less 가 켠 모드와 무관하게 같은 바이트가 나간다.

**`⌘` 는 legacy 수식자에 안 싣는다.** xterm 의 비트 8 은 **Meta** 이고 macOS 에서 Meta 는 Option(이미
비트 2)이다. ⌘ 를 8 로 실으면 `Cmd+←` 가 `CSI 1;9D` 라는, terminfo 에 없는 시퀀스가 된다 — 그러면
**오늘 동작(평범한 `←` 로 나가 커서가 움직인다)보다 나빠진다.** kitty 는 8 을 쓰는 것이 맞다(그 프로토콜이
`super` 를 명시하고 앱이 켰다는 뜻이라 모호하지 않다).

**범위 밖 기능키(F13+)는 수식자가 붙어도 오류다.** `functionKeySequence` 가 이미 그렇게 막고 있는데
수식자 경로만 통과시키면 `Ctrl+F13` 이 `Ctrl+F12` 와 **같은 시퀀스**로 나간다 — 오류가 조용한 오답이
된다(적대적 검증이 잡았다).

## 충돌 규칙

- global shortcut은 정확히 등록한 key chord만 소비한다. 예를 들어 `Ctrl+Cmd+,`를 등록해도 `Ctrl+B`, `Ctrl+C`, `Esc`에는 영향을 주지 않는다.
- global shortcut과 terminal input이 같은 조합이면 global shortcut이 이긴다. 전역으로 등록한 키는 사용자가 앱 밖에서도 Maru 명령으로 쓰겠다고 선택한 것이기 때문이다.
- app keybinding과 terminal input override가 같은 조합이면 config validation에서 오류로 보고한다.
- OS나 다른 앱이 이미 선점한 global shortcut은 등록 실패로 보고하고, 조용히 무시하지 않는다.
- 사용자가 명시적으로 `send_text` 또는 `send_escape_sequence`를 설정한 조합은 app action과 동시에 사용할 수 없다.

### 목록 스크롤 키(`PageUp`/`PageDown`/`Home`/`End`)의 주인 — 그리고 notice 비대칭

같은 넷을 여러 소비처가 노린다. `handleKeyEvent` 의 **순차 판정 순서**가 곧 정책이고(responder chain
이 아니라 한 함수의 if 체인이다), 그 순서는 이렇다:

| 순서 | 누가 | 조건 | 그 키로 무엇을 |
| --- | --- | --- | --- |
| 1 | rename · 주소창 · **사이드바 검색** · 커밋 상자 | 각자 활성 + `!anyModalOverlayOpen()` | 사이드바 검색만 목록을 굴린다(나머지 셋은 이 넷을 안 쓴다) |
| 2 | **오버레이 일괄**(`anyOverlayOpen()`) | 모달 또는 **notice** 가 열림 | 모든 키를 소비 — notice 는 아무 키로나 닫힌다 |
| 3 | **소스 컨트롤 도크** | 도크 보임 + 그 뷰 + `dockKeyFocus()` | 목록을 굴린다 |
| 4 | **에이전트 세션 도크** | 〃 | 목록을 굴린다 |
| 5 | **파일 탐색기** | `file_tree_focus` | **선택 이동**이다(스크롤이 아니다 — 위 표) |
| 6 | 터미널 | `input.page-keys = scroll` | 스크롤백 |

**탐색기가 스크롤 대상이 아닌 이유**는 5번이다 — 그 넷이 이미 선택 이동의 주인이라, 스크롤을 얹으면
그 축을 뺏는다([ScrollArea](scroll-area.md) §4.5 가 그 정정을 소유한다).

**알려진 비대칭 — 사이드바만 notice 를 앞지른다(고치지 않는다).** 1번은 `anyModalOverlayOpen()`
(notice **제외**)을 보고 2번은 `anyOverlayOpen()`(notice **포함**)을 본다. 그래서 notice 토스트가 떠
있을 때 도크 둘은 키를 못 먹고 notice 가 닫히는데, **사이드바 검색 중에는 목록이 굴러가고 notice 는
안 닫힌다**(클릭·휠로는 닫힌다 — mouse/scrollWheel 이 같은 규율을 건다).

**순서를 바꾸는 것은 답이 아니다.** ⑴ 1번의 넷이 **같은 게이트를 공유**하므로 사이드바만 뒤로 옮기면
지금 비대칭을 다른 비대칭으로 바꾼다. ⑵ 그 게이트가 notice 를 제외하는 것은 의도다 — *"지나가는
토스트가 활성 편집을 끊으면 안 된다"* 이고, Swift focus-sync override(`terminalOwnsInput`)도 같은
판정을 써서 **둘이 어긋나면 웹 포커스 동기가 깨진다**. ⑶ 스크롤 핸들러만 물러나도 검색 블록 자체가
2번보다 앞이라 notice 는 여전히 안 닫히고, 스크롤만 사라져 **더 나빠진다**.

**근본 해법은 notice 쪽에 있다.** 표준 토스트는 몇 초 뒤 스스로 사라지는데(ARIA live region ·
Material snackbar — 포커스도 키도 뺏지 않는다) 이 notice 에는 **자동 타임아웃이 없어서** 「아무 키로나
닫는다」는 규율로 그 자리를 메웠다. 타임아웃이 생기면 notice 가 키 라우팅에서 통째로 빠지고 이
비대칭도 함께 사라진다. 다만 *어떤 notice 는 사용자가 반드시 읽어야 하는가*는 [알림 전략](notifications.md)
의 결정이라 여기서 정하지 않는다.

### 파일 도크·트리 키 소유권과 우선순위

Zig의 `FocusOwner` tagged union은 구조 입력 축인 `.workspace`(terminal·browser·파일 Term 공통), `.dock_pending { EntryId }`(파일 WebView publish를 기다리는 짧은 fail-closed barrier), `.file_tree { restore_surface }` 셋이다. FP16(2026-07-28)에서 `.dock_surface { surface_id }`와 `.dock_group { runtime_id }`는 사라졌다 — 파일이 워크스페이스 pane 탭이 되면서 "어느 파일 WebView가 native focus인가"는 별도 축이 아니라 **활성 pane의 활성 Term**에서 파생된다(docs/file-panel-dock-ui.md §3.4).

1. confirm·notice·palette·rename 같은 modal/overlay input owner가 자신의 Enter/Esc/편집 키를 먼저 소비한다.
2. context-aware resolver가 사용자 app action rebind, explicit unbind, context default, terminal/global fallback의 provenance를 보존해 판정한다. `resolveFileTree`는 사용자 action을 먼저 반환하고 explicit unbind면 그 chord를 소비하되 tree default를 실행하지 않으며, 둘 다 없을 때만 tree default를 적용한다. terminal macro와 global-only action은 tree context에서 실행하지 않는다.
3. `file_tree_focus`가 켜져 있으면 modifier 없는 `↑/↓/←/→`, `Enter`, `Home/End`, `PageUp/PageDown`, `Esc`, `F2`와 `⌘Backspace`를 트리가 소비한다. 이때 terminal key encoding과 CM6/WebKit에는 전달하지 않는다. 단 app action resolver가 확정한 `toggle_file_panel_focus`는 이 tree-local 기본키보다 먼저 실행돼 workspace로 돌아갈 수 있다.
4. 도크 WKWebView가 first responder이면 ABI v132 `WebKeyRoute(u32)`가 Bool `key_is_app_action`을 대체한다: `0=pass_through`, `1=app_action`, `2=consume_unbound`, `3=web_editor`; unknown은 fail-closed consume, null/변환 실패는 pass-through다. resolver는 사용자 app rebind → explicit unbind → Markdown editable context default → 기존 app default/terminal fallback 순서로 provenance를 보존한다. `live-preview`/`source-edit`의 `web_editor`는 `⌘S/F/A/C/V/X/Z/⇧Z`와 텍스트 탐색·선택·삭제를 WebKit에 양보하고, `consume_unbound`는 WebKit/PTY 어디에도 보내지 않는다. live-preview에서 caret이 task marker 또는 link label 안에 있을 때 `⌘Enter`는 WebKit-local `LivePreviewIntent`로 task toggle 또는 link keyboard activation을 수행한다. 사용자 app rebind·terminal macro·explicit unbind가 계속 먼저이고 이 로컬 chord를 새 전역 action/config default로 중복 등록하지 않는다. 라이브 표의 cell selection이 활성일 때 modifier 없는 `Tab`/`Shift-Tab`/`Enter`는 WebKit 안의 `LivePreviewIntent`가 소유하고 최대 한 번의 CM6 transaction만 만든다. 표가 source-preserving fallback이거나 cell selection이 아니면 같은 키는 CM6 기본 편집 의미를 유지한다. 이 표 로컬 키에는 전역 action이나 config 기본 binding을 새로 만들지 않는다. `app_action`은 같은 이벤트 루프에서 `maru_macos_app_session_dispatch_web_app_action`이 **같은 resolver를 다시 평가해 얻은 `Action`만 직접 dispatch**하며 범용 `handleKeyDown`의 terminal copy/paste·scroll·macro 전처리와 PTY write를 타지 않는다. route와 dispatch 사이 config/mode가 달라져 더는 app action이 아니면 action 0회로 fail-close하고 Swift는 이미 가로챈 이벤트를 consume한다. 두 호출은 AppKit main actor의 한 이벤트 처리 안에 있고 Web surface 제거는 그 사이 끼어들 수 없다. `read`와 HTML은 편집기 소유가 아니며 `⌘S`를 저장으로 오인해 소비하지 않는다. C header 상수·Zig `enum(u32)` compile-time test·Swift exhaustive switch가 raw 값 하나를 공유하고 Swift의 별도 key/mode 목록은 제거한다. 앱 메뉴바의 편집 항목 `Copy(⌘C)`·`Paste(⌘V)`·`Select All(⌘A)`는 `WebKeyRoute`와 별개로 keyEquivalent가 first responder와 무관하게 발화하므로, 도크·브라우저 웹 패널이 first responder이면 표준 `copy:`/`paste:`/`selectAll:`을 responder chain으로 넘겨 WebKit이 처리하고(`read`·`html`은 선택 텍스트 복사·전체 선택만, `live`/`source`는 CM6 편집 복붙), 그 외에는 터미널 선택 복사/PTY 붙여넣기다 — 이 focus 분기가 `web_editor`/`pass_through`의 'WebKit에 양보'를 메뉴바 축에서 성립시킨다(단일 출처: [web-panel.md §4.2](web-panel.md)).
5. **활성 Term이 네이티브 편집기면 `resolveEditor`가 판정한다**(2026-09-03 — 아래 「편집기 Term 컨텍스트」). 파일 트리·웹과 같은 provenance 순서를 쓰되, **편집기 전용 기본키**를 그 컨텍스트 안에서만 적용한다.
6. 나머지는 활성 terminal/browser pane의 기존 app-action/browser-nav/terminal encoding 경로로 간다.

### 편집기 Term 컨텍스트 (2026-09-03)

**막혀 있던 것은 기능이 아니라 「그 기능을 어떤 키가 부르는가」였다.** 편집기 액션 여럿이 **chord 없이**
커맨드 팔레트로만 닿는다 — [입력 설정](configuration-input.md)의 「무엇이 막고 있나」 표가 그 부류를
소유하고, 그중 하나가 *"`⌥Z`는 Option 단독이라 터미널의 Meta/ESC 입력을 전역으로 뺏는다"* 다.

**그 문장이 맞았던 이유는 기본 표가 전역이라서다.** `default_app_bindings`에 `⌥Z`를 넣으면 **터미널
Term에서도** 그 chord가 소비된다. 그런데 **편집기 Term에는 PTY가 없다**(`term.zig`가 *"PTY가 없는 갈래가
셋이다: web·**편집기**·종료 placeholder"*로 못박는다) — 즉 그 Term에서 Meta/ESC 입력은 **보낼 곳이
없다**. 컨텍스트가 서면 뺏을 것이 없어진다.

- **`resolveEditor`는 파일 트리·웹과 같은 provenance 순서를 쓴다.** 사용자 app rebind → terminal macro
  (소비) → explicit unbind(소비) → **편집기 컨텍스트 기본키** → 전역 기본 app action → 편집기가 처리.
  자리는 `resolveFileTree`가 tree default를 두는 **그 자리**이고, 근거도 같다 — 컨텍스트가 자기 기본키를
  전역보다 먼저 보는 것이 이 저장소의 선례다.
  - ~~**다만 「전역을 양보받는다」가 이 컨텍스트의 목적은 아니다.** 실측하면 기본 표에 **`⌘` 없는 `⌥`
    chord가 하나도 없어서**(2026-09-03) 여기서 넣을 컨텍스트 기본키와 **겹칠 전역 chord가 없다**.~~
    → **그 문장은 2026-09-04 부터 거짓이다**(2026-09-06 실측). 그날 `⌘D`(`add_next_occurrence`)가,
    이어서 `⌥⌘↑`·`⌥⌘↓`(`add_cursor_above`·`_below`)가 들어오면서 **전역 chord 를 편집기에서 가로채는
    항목이 셋** 생겼다 — 이 절이 *"그렇게 하려면 그 chord 마다 근거를 따로 적는다"* 고 한 그것인데,
    **아무도 적지 않았다.** 근거는 아래 「메뉴 keyEquivalent 층」이 든다.

#### 충돌 전수 대조 (2026-09-07)

[diff·떠 있는 UI·설정](native-editor-ui.md) §9.1 이 *"충돌 목록은 구현 슬라이스에서 전수 조사한다"*,
*"`default_app_bindings` 를 §3.9 액션 목록과 전수 대조하고 **그 결과를 이 문서가 소유한다**"* 로 남긴
숙제다. 손으로 세지 않고 **resolver·카탈로그·Swift 소스를 프로그램으로 훑어** 뽑았다.

**가로채는 층이 셋이다 — 앞의 둘은 resolver 를 안 지난다.**

| 층 | 무엇 | resolver 가 보이나 |
|---|---|---|
| ① 뷰 `performKeyEquivalent` | 메뉴 keyEquivalent 양보 판정 | **안 보인다** |
| ①ʹ **Swift `handleKeyDown` 선-가로채기** | `⌘C`·`⌘V`·`⇧PageUp/Down`·`⌘↑`·`⌘↓` | **안 보인다** |
| ② 메뉴바 keyEquivalent | `Split Right` 등 | **안 보인다** |
| ③ `resolveEditor` | 컨텍스트·전역 표 | 이것이 전부다 |

**resolver 만 물으면 「충돌 없음」이라는 거짓 답이 나온다**(실측 — §3.9 이동 키 열을
`resolveEditorDetailed` 로 재니 **열 개 전부 `.editor`** 였다. 그런데 아래 표대로 넷은 편집기에 오지도
않는다). §9.1 이 예고한 `⌘↑`/`⌘↓` 충돌이 **살아 있고**, 그것을 못 본 이유가 정확히 이것이다.

**①ʹ 의 여섯을 전수했다**(`handleKeyDown` 의 `if !anyOverlayOpen` 블록):

| chord | keyCode | 하는 일 | 편집기를 아나 | 편집기에서 실제 결과 |
|---|---|---|---|---|
| `⌘C` | 8 | 선택 복사 | **안다** — `copyText` 에 편집기 갈래(2026-08-26 적대적 검증이 넣었다) | 편집기 선택이 복사된다 |
| `⌘V` | 9 | 붙여넣기 | **안다** — `pasteText` 에 편집기 갈래 | 편집기에 삽입된다 |
| `⌘↑` | 126 | 프롬프트 점프(이전) | **모른다** | **프롬프트로 튄다** — §3.9 는 **문서 처음** |
| `⌘↓` | 125 | 프롬프트 점프(다음) | **모른다** | **프롬프트로 튄다** — §3.9 는 **문서 끝** |
| `⇧PageUp` | 116 | 스크롤백 한 화면 | **모른다** | **아무 일도 안 난다** — `scrollPage` 가 `activeTermIsTerminal` 로 거절하고, Swift 는 이미 `return` 했다. §3.9 는 **페이지 단위 선택 확장** |
| `⇧PageDown` | 121 | 스크롤백 한 화면 | **모른다** | 같다 |

**남은 충돌은 넷이다**(`⌘↑`·`⌘↓`·`⇧PageUp`·`⇧PageDown`). 셋 다 §9.1 의 경계 기준 — *"그 키가
**문서에** 작용하는가"* — 으로 **편집기 것**이고, 지금은 터미널 동작이 이기고 있다.

**chord 가 없는 편집기 액션은 열이다**(실측): `fold_all`·`unfold_all`·`fold_level_1..3` ·
`copy_editor_selection` · `transform_to_uppercase`/`_lowercase` · `indent_lines`/`outdent_lines`.
뒤의 다섯은 [입력 설정](configuration-input.md) 의 「무엇이 막고 있나」 표가 이유를 소유한다(다른 키가
이미 닿거나, 레퍼런스도 안 준다). **접기 다섯만 남는다.**

**접기에 줄 자리도 실측했다.**

| 후보 | 임자 |
|---|---|
| `⌥⌘[` · `⌥⌘]` | `previous_term`·`next_term` — **메뉴 항목이다** |
| `⌥⌘0` · `⌥⌘1` · `⌥⌘2` · `⌥⌘3` · `⌥⌘J` | **빔** |
| `⌥0` · `⌥J` · `⌥[` · `⌥]` | **빔** |

**`⌥⌘[`·`⌥⌘]` 를 쓰려면 §9.1 의 경계 표에 예외를 적어야 한다** — 그 표가 *"창·탭·앱 관리는 앱이 계속
먹는다"* 고 정했고 `previous_term`/`next_term` 이 그쪽이다. 빈 자리가 다섯이나 있으므로 **예외를 만들
필요가 없다.**

#### 선-가로채기는 터미널 것일 때만 먹는다 (2026-09-07)

위 전수 대조가 찾은 **남은 충돌 넷**(`⌘↑`·`⌘↓`·`⇧PageUp`·`⇧PageDown`)을 닫는 규칙이다.

**그 넷은 터미널 기능이다** — 프롬프트 점프는 OSC 133 블록을, 페이지 스크롤은 스크롤백 뷰포트를
움직인다. **편집기 Term 에는 둘 다 없다**(PTY 가 없고 스크롤백도 없다). 그런데 지금은 활성 Term 이
무엇이든 Swift 가 먼저 먹고 `return` 한다.

**규칙: 터미널 전용 선-가로채기는 활성 Term 이 터미널일 때만 돈다.**

- **`⌘C`·`⌘V` 는 이 규칙 밖이다.** 클립보드는 Term 종류와 무관한 사용자 의도이고, **Zig 쪽이 이미
  갈래를 갖고 있다**(실측 — `copyText` 와 `pasteText` 에 편집기 갈래가 있다). 여기서 함께 막으면
  **편집기 복사·붙여넣기가 죽는다** — 그 둘을 받아 줄 chord 가 편집기 표에 없기 때문이다
  (`copy_editor_selection` 은 chord 가 없다 — 위 전수 대조).
- **판정은 Zig 가 한다.** `term_ops.activeTermIsTerminal` 이 이미 그 답을 들고 있다(`scrollPage` 가
  그것으로 거절한다). ABI 로 열어 Swift 가 **묻기만** 한다 — `any_overlay_open`·`editor_owns_chord` 와
  같은 부류의 부작용 없는 질의다.
- **Zig 쪽에도 가드를 둔다 — 지금 비대칭이다**(실측). `scrollPage` 는 `activeTermIsTerminal` 로
  거절하는데 **`jumpToPrompt` 는 아무 가드가 없어** 편집기 Term 의 surface 에 `jump_to_prompt` 를
  큐에 넣는다. 대칭으로 맞춘다 — **심층 방어**이고, Swift 를 안 거치는 경로(팔레트·메뉴)가 생기는
  날에도 답이 같다.
  - **다만 Zig 가드만으로는 안 고쳐진다.** Swift 가 이미 `return` 해서 **키가 편집기에 오지를 않는다**
    — 가드는 「엉뚱한 일을 막는 것」이고, Swift 게이트가 「편집기에 닿게 하는 것」이다. **둘 다** 있어야
    `⌘↑` 가 문서 처음으로 간다.
- **고쳐지면 §3.9 가 그 키들을 받는다**(실측 — 편집 키 갈래가 `⌘↑ → .doc_start`, `⌘↓ → .doc_end`,
  `PageUp/Down → .page_up/.page_down` 을 이미 갖고 있고 `⇧` 가 `extend` 다). 즉 **새 동작을 만들지
  않는다** — 이미 있는 것이 닿게만 한다.
- **터미널은 안 바뀐다.** 활성 Term 이 터미널이면 넷 다 지금 그대로다.
- **웹·파일 Term 에서는 안 돈다.** 그것도 터미널이 아니므로 같은 게이트에 걸린다 — 지금은
  `scrollPage` 가 조용히 거절하고 `jumpToPrompt` 는 엉뚱한 큐를 넣는 **갈린 상태**인데, 그 갈림이
  사라진다.

#### 메뉴 keyEquivalent 층 — resolver 위에 층이 하나 더 있다 (2026-09-06)

**이 절의 추론은 `resolveEditor` 안에서만 이뤄졌고, 그 위의 AppKit 층을 안 봤다.** 그래서 위 순서를
아무리 옳게 적어도 **그 함수가 아예 안 불린다**.

**실측(사용자 확인, GUI):** 편집기 pane 에서 `⌘D` 를 누르면 커서가 아니라 **pane 이 좌우로 나뉜다.**
메뉴바의 `Split Right`(`⌘D`) keyEquivalent 가 `keyDown` 보다 먼저 발화하기 때문이다 — 이 문서가 이미
다른 자리에서 *"메뉴바 keyEquivalent 는 first responder 와 무관하게 발화한다"* 고 적어 둔 그 성질이다.

**순번은 셋이고, 고칠 자리는 첫째다**(2026-09-06 적대적 검증 2회차 — 이 앱에 **작동하는 선례**가 있다):

| 순번 | 누가 | 이 앱의 실물 |
|---|---|---|
| ① | **뷰의 `performKeyEquivalent`** | 웹 패널이 `⌘←`·`⌘→`·`⌘R` 을 여기서 가로채 `true` 로 소비한다 — **메뉴가 못 본다** |
| ①ʹ | 그 위의 `RegisterEventHotKey` 전역 핫키 | 앱 밖에서 먹는다. **사용자가 등록한 것만**이라 이 규칙의 밖이다 |
| ② | 메뉴바 keyEquivalent | `Split Right`(`⌘D`) 가 여기서 먹는다 |
| ③ | `keyDown` → `handleKeyEvent` → `resolveEditor` | **여기까지 안 온다** |

즉 터미널 뷰의 `performKeyEquivalent` 는 오버레이가 아닐 때 `super`(= `false`)를 내어 ②로 넘긴다.
그 뷰는 `MaruMetalTerminalView` 이고 **편집기 pane 도 그 뷰가 그린다** — 즉 편집기에 포커스가 있어도
그 오버라이드는 계층 안에 있다(4회차 확인. 다른 뷰였다면 ①에 답할 자리 자체가 없다).
**①에서 답하면 ②가 아예 안 돈다** — 웹 패널이 그렇게 하고 있고, 오버레이 갈래도 그렇게 하고 있다.

**즉 `⌘D`·`⌥⌘↑`·`⌥⌘↓` 는 계약대로 배선됐지만 제품에서 죽어 있다.** `resolveEditor` 판정자는 초록이고
캡처도 초록이었다 — 판정자는 그 함수를 **직접** 부르고, 캡처 훅은 `handleKeyEvent` 를 **직접** 부른다.
**둘 다 AppKit 을 안 지난다.**

**Zig 경로는 끝까지 옳다 — 가설 셋을 하나씩 죽였다**(2026-09-06 적대적 검증 16·21·23회차).

| 가설 | 결말 |
|---|---|
| ⑴ resolver 가 틀렸다 | **반증**(16회차) — 기존 판정자가 `resolveEditor(⌘D, false) == add_next_occurrence` 를 단언하고 초록이다 |
| ⑵ 편집기 분기에 안 들어갔다 | **반증**(24·25·26회차 — 아래) |
| ⑶ 분기에 들어갔지만 `.app_action` 을 버렸다 | **반증**(23회차) — 그 분기가 `.app_action` 을 **실제로 디스패치한다**(*"안 부르면 `⌥Z` 가 아무 일도 안 하고 조용히 사라진다"*) |

**⑵는 실험 없이 죽었다** — 처음엔 *"`⌥Z` 로 랩이 토글되는지 사용자에게 물어야 한다"* 고 적었는데,
그 조건을 코드로 잴 수 있었다(24~26회차):

- **본문 클릭이 그 pane 을 활성으로 만든다**(24회차). 편집기 본문 down 갈래가 `beginBodySelection`
  **직후** `focusPaneByPtr(self, pane)` 을 부른다 — 즉 본문을 클릭하고 키를 누르면
  `activePane().activeTerm().kind == .editor` 는 **참일 수밖에 없다**.
- **`surface_initialized` 도 참일 수밖에 없다**(25회차). 거짓이면 `handleKeyEvent` 가 **맨 앞에서
  돌아가** 어떤 키도 안 먹는다 — 앱이 쓰이고 있다는 사실 자체가 그 가드를 통과했다는 증거다.
- **메뉴 항목은 반드시 발화한다**(26회차). `validateMenuItem` 이 **0건**이고 `autoenablesItems = false`
  는 브라우저 권한 서브메뉴 하나뿐이라, 카탈로그 항목은 **자동 활성**이고 target 이 액션을 구현하고
  있다.

**셋을 죽이고 나면 ②만 남는다.** 그것이 이 절이 세우는 규칙의 근거다.

(`⌥Z` 확인은 여전히 값싼 교차 검증이다 — 전제는 `input.option-as-meta` 가 기본값 `true` 인 것이고,
거짓이면 Option 단독 chord 는 애초에 여기까지 안 온다.)

**resolver 는 옳다 — 반증을 시도해 확인했다**(2026-09-06 적대적 검증 16회차). 기존 판정자가 이미
`resolveEditor(⌘D, is_diff=false) == add_next_occurrence` 와 `… (true) == split_horizontal` 을 단언하고
**둘 다 초록**이다. 원인이 resolver 였다면 그 줄이 빨갰을 것이다. 그리고 **그 판정자가 거짓 안심의
실물**이다: 제품이 깨진 채로 초록이고, 위 「provenance 가 없다」도 그 두 줄에 그대로 드러나 있다 —
컨텍스트가 이긴 답과 전역으로 떨어진 답이 **같은 `.app_action`** 이다.

**표준 메뉴 항목도 「산다」 넷을 안 건드린다**(15회차). 카탈로그 밖에서 `nativeMenuItem` 이 다는 키는
`?`·`c`·`⌃⌘f`·`h`·`⌥⌘h`·`m`·`n`·`q`·`⇧⌘r`·`v`·`x` 뿐이고 **Option 단독이 없다**. 그리고
`focus_pane_up`·`focus_pane_down`·`split_horizontal` 이 메뉴 항목인 것은 실측이다(17회차).

**피해 범위는 셋이다**(2026-09-06 전수 실측 — 컨텍스트 표 일곱 중):

| 컨텍스트 기본키 | chord | 가로채는 전역 | 메뉴 항목인가 |
|---|---|---|---|
| `add_next_occurrence` | `⌘D` | `split_horizontal` | **그렇다 — 죽는다** |
| `add_cursor_above` | `⌥⌘↑` | `focus_pane_up` | **그렇다 — 죽는다** |
| `add_cursor_below` | `⌥⌘↓` | `focus_pane_down` | **그렇다 — 죽는다** |
| `toggle_editor_wrap` | `⌥Z` | (없음) | 산다 |
| `duplicate_lines` | `⇧⌥↓` | (없음) | 산다 |
| `move_lines_up`·`_down` | `⌥↑`·`⌥↓` | (없음) | 산다 |

**살아 있는 넷이 사는 이유는 컨텍스트가 이겨서가 아니다 — 전역에 임자가 없어서다.** 즉 이 컨텍스트는
지금껏 **한 번도 전역을 이겨 본 적이 없다.** 위 취소선 문장이 참이던 동안에는 그것으로 충분했고,
거짓이 되는 순간 세 chord 가 조용히 죽었다.

- **메뉴는 컨텍스트를 모른다**(실측). `chordForAction` 이 `resolver.app_bindings` 와
  `default_app_bindings` 만 훑고 `editor_context_bindings` 를 **안 본다**. 그래서 ⑴ 메뉴가
  `split_horizontal` 에 `⌘D` 를 달고, ⑵ 팔레트는 `add_next_occurrence` 를 **「단축키 없음」**으로
  보여 준다 — 배선된 키가 발견조차 안 된다.
- **Swift 는 컨텍스트를 모른다**(실측). `runCatalogAction` 은 `select_all` 만 특별 취급하고,
  `performKeyEquivalent` 는 **오버레이가 열렸을 때만** 양보한다.

**규칙: 편집기 컨텍스트가 소유하는 chord 는 메뉴 keyEquivalent 보다 먼저다.**

- **판정은 Zig 가 한다.** `performKeyEquivalent` 에서 부작용 없는 질의로 묻고, 참이면 기존 오버레이
  갈래와 **같은 모양으로** `keyDown` 으로 돌린다 — `maru_macos_app_session_any_overlay_open` 이 이미
  그 선례다(*"1이면 메뉴바 keyEquivalent 를 양보해 키를 keyDown 으로 보낸다"*).
  - **Swift 를 못 재서가 아니다**(2026-09-06 적대적 검증 1회차가 그 근거를 깼다 — 처음엔 *"이 저장소에
    Swift 테스트가 없다"* 고 적었는데 **거짓**이다: `tests/macos_termination_window_policy.swift` 등
    셋이 있다). **관례가 그렇게 생겼다**: 순수 판정을 `TerminationWindowPolicy.swift` 같은 **작은 파일로
    떼어** 그것만 테스트한다. 이 판정은 그렇게 뗄 수 없다 — 필요한 것이 **활성 Term 의 종류와
    resolver 상태**이고 그 둘 다 Zig 에 있다. 떼면 Swift 로 그 상태를 복제해야 하고 **출처가 둘**이 된다.
  - **그래서 Swift 쪽은 「부르는가」만 남고, 그것은 정적 판정자가 잰다** — 이 저장소에 `MaruAppHost.swift`
    를 읽어 심볼을 단언하는 선례가 있다(`tests/session_host_signed_app_quit_evidence_boundary.zig`).
- **참이 되는 조건은 좁다.** 활성 Term 이 편집기이고, 그 chord 가 `editor_context_bindings` 에 있고,
  **`needs_editable` 게이트를 통과할 때**만이다. 넓히면 편집기에서 메뉴 단축키가 통째로 죽는다.
- **「`resolveEditor` 가 `.app_action` 을 내나」로 물으면 안 된다**(2026-09-06 적대적 검증 7회차).
  `EditorResolution` 에는 **provenance 가 없다** — 컨텍스트 표가 이겼을 때도, 전역으로 떨어졌을 때도
  똑같이 `.app_action` 이다. 그렇게 물으면 **비교 뷰에서 `⌘D` 를 편집기에 양보**해 위 표가 정한
  *"비교 뷰에서 그 키는 앱의 것"* 이 깨진다(좌우 분할이 죽는다).
  - **사용자 rebind 도 같은 함정이다**(8회차). `resolveEditor` 는 `app_bindings` 를 **맨 먼저** 보므로,
    사용자가 `⌘D` 를 다른 앱 액션에 묶으면 그것이 이긴다 — 그때 컨텍스트는 진 것이라 **양보하면 안
    된다**. 카탈로그도 같은 순서로 사용자 바인딩을 먼저 보므로 메뉴 표시와도 어긋나지 않는다.
  - **답은 컨텍스트의 승리를 열거형에서 구별하는 것이다.** 웹 컨텍스트가 **똑같은 문제를 그렇게
    풀었다**: `.web_editor` 가 `.app_action` 에 뭉개지지 않고 **처음부터 별도 variant** 다. ABI 주석이
    *"app-action/consume-unbound/web-editor/pass-through provenance 를 보존한다"* 고 적는 그 네 갈래가
    바로 그것이다.
    - **다만 `resolveWeb`/`resolveWebDetailed` 짝은 provenance 장치가 아니다**(2026-09-06 적대적 검증
      9·10회차 — 처음엔 그렇게 인용했는데 **틀렸다**). 실제로 읽으면 `WebResolution` 과 `WebKeyRoute` 는
      **1:1 이고 `route()` 는 항등 사상**이다. 짝이 있는 이유는 **내부 타입과 ABI 안정 타입을 가르기
      위해서**다.
    - **그럼에도 그 짝 모양을 쓴다 — 여기서는 투영이 실제로 손실적이라 이유가 더 분명하다.**
      `resolveEditorDetailed` 하나가 순서를 구현하고, `resolveEditor` 는 컨텍스트 승리와 전역 승리를
      **둘 다 `.app_action` 으로 뭉개** 돌려준다. 그래야 **호출자 열여덟(판정자)을 안 건드린다** —
      실측으로 `resolveEditor` 호출자 스무 곳 중 **제품은 둘**(편집 키 경로·찾기)이고 나머지는 판정자다
      (11회차).
    - **뭉개는 것이 손실인 줄 알면서 두는 이유**는 그 열여덟이 *"이 chord 가 앱 액션인가"* 만 묻기
      때문이다. 그중 **어느 표가 이겼는지**를 묻는 판정자가 없었다는 것이 이 결함이 오래 산 이유이므로,
      새 판정자는 **그것을 묻는다**.
- **선례에는 판정자가 없다**(6회차 — 이 조각이 되풀이하지 말 것). `anyOverlayOpen` 을 Swift 가 부르는
  그 줄을 **아무도 안 잰다**: 지워도 초록이다. 그래서 이 조각은 ⑴ Zig 질의의 답을 재는 판정자와
  ⑵ Swift 가 그것을 **부르는지** 재는 정적 판정자를 **둘 다** 세운다.
  - **정적 판정자는 약하다 — 그것을 알고 쓴다**(18회차). 선례가 하는 일은 `indexOf(swift, "심볼")
    != null`, 즉 **부분 문자열 존재 확인**뿐이라 **극성을 뒤집은 변이**(`if !editorOwnsChord`)도, 엉뚱한
    함수 안으로 옮긴 변이도 못 잡는다. 그래서 이 조각은 심볼이 아니라 **그 세 줄 블록을 통째로**
    단언한다 — 극성이 뒤집히면 문자열이 안 맞아 죽는다. 남는 한계(들여쓰기·줄바꿈 변경에 깨진다)는
    받아들인다: 그 대가로 **Swift 에 판정을 복제하지 않는다**. (`MaruAppHost.swift` 는 783KB 라 선례가
    쓰는 2MiB 한도 안이다 — 이 저장소가 그 한도에 한 번 걸린 적이 있어 재 두었다.)
- **명시적 unbind 는 이미 옳다**(19회차 — 고칠 것이 없다). `chordForAction` 이 `unbinds` 를 보므로
  사용자가 `⌘D` 를 풀면 카탈로그가 `null` 을 내고 **메뉴에 키가 안 달려** `keyDown` 으로 떨어진다.
  다만 **terminal macro 는 그 함수가 안 본다** — 매크로를 `⌘D` 에 걸면 메뉴가 계속 이긴다. 이 조각의
  밖이고, 편집기와 무관한 전역 문제라 여기서 고치지 않는다.
- **양보한 뒤에도 Swift 가 삼키는 키가 있다**(20회차). `handleKeyDown` 은 오버레이가 없을 때
  `⌘C`(keyCode 8)·`⌘V`(9) 등을 **코어보다 먼저** 가로챈다. 즉 컨텍스트 기본키를 그 집합과 겹치게
  두면 ①이 양보해도 **거기서 또 죽는다**. 지금 셋(`⌘D`·`⌥⌘↑`·`⌥⌘↓`)은 안 겹치고, 이 문서가 이미
  *"`⌘C` 는 이 컨텍스트가 필요 없다"* 고 적어 둔 것과 같은 경계다. **새 컨텍스트 기본키를 고를 때
  이 집합을 함께 본다.**
- **비교 뷰에서 `⌘D` 는 양보하면 안 된다.** 위 표가 *"비교 뷰에서 「다음 일치 추가」는 의미가 없으므로
  그 키는 앱의 것"* 이라고 정했다 — 그러려면 그 상황에서는 **메뉴가 그대로 먹어야** 한다. 즉 질의는
  `resolveEditor` 와 **같은 `is_diff` 판정**을 써야 하고, 다른 판정을 쓰면 두 층이 갈린다.
- **오버레이가 먼저다.** 오버레이가 열렸으면 그 갈래가 이긴다(모달 중 단축키 누수·chord 녹음 가로채기를
  막는 근거가 이 규칙보다 앞선다).
- **표시도 함께 고친다.** `chordForAction` 이 컨텍스트 표를 보게 하지 않으면 키는 살아나도 **팔레트가
  계속 「없음」이라고 말한다.** 다만 그러면 `Split Right` 와 `Add Next Occurrence` 가 **둘 다 `⌘D` 로
  보인다** — 실제로 문맥에 따라 둘 다 맞으므로 그 표시가 거짓은 아니다.
  - **그 수정이 메뉴에 `⌘D` 를 둘 만들지는 않는다**(2026-09-06 적대적 검증 12·13회차 — 위험해 보여서
    열어 봤다). 네 편집기 액션은 **팔레트 카탈로그에만 있고 메뉴 항목이 없다**(`catalogMenuItem` 호출
    0건). 그리고 메뉴는 **카탈로그를 통째로 도는 자리가 없다** — 항목을 이름으로 하나씩 건다(호출
    스무 번). 그래서 카탈로그의 chord 를 고쳐도 **바뀌는 것은 팔레트 표시뿐**이다.
- **오버레이가 열린 동안에는 이 문제가 안 난다**(14회차). `anyOverlayOpen` 이 `find`·`palette`·`settings`
  등을 포함하므로 그때는 ①이 이미 `keyDown` 으로 돌린다 — 즉 **②가 아예 안 돈다**. 그래서 이 결함은
  **편집기 본문에 포커스가 있고 아무 오버레이도 없을 때**만 나타난다. 제보를 받으면 그 조건부터 묻는다.
- **편집기 문맥에서 resolver를 묻는 자리는 전부 이 함수를 탄다.** ~~실측으로 **둘**이다~~ →
  **셋이다**(2026-09-06 — 아래 「메뉴 keyEquivalent 층」이 `performKeyEquivalent` 질의를 더한다). 편집 키
  경로(`app_session.zig`의 *"이게 앱 액션이냐"* 분기)와 찾기 규칙 chord 가로채기(`find.zig`). 둘이
  갈리면 **같은 키가 자리에 따라 다르게 풀린다**: 찾기가 떠 있을 때와 아닐 때 `⌥Z`가 다른 일을 한다.
- **PTY 바이트로 떨어지지 않는다.** 파일 트리 컨텍스트가 *"셸 바이트를 절대 내보내지 않는다"*고 적은
  것과 같은 근거이고, 여기서는 **보낼 PTY 자체가 없다**.
- **비교 뷰에서는 「편집 가능한 문서를 요구하는」 컨텍스트 기본키가 서지 않는다**(2026-09-04 정정).
  갈림은 **Term 이 아니라 액션 단위**다.

  | 컨텍스트 기본키 | 편집 가능한 문서를 요구하나 | 비교 뷰에서 |
  |---|---|---|
  | `toggle_editor_wrap`(`⌥Z`) | **아니다** — 랩은 뷰 속성이고 비교도 랩을 쓴다 | **선다** |
  | `duplicate_lines`·`move_lines_up`/`_down` | 그렇다(`lineOpDoc`이 거절) | 안 선다 |
  | `add_next_occurrence`(`⌘D`) | 그렇다(읽기 전용에서 뜻이 없다) | 안 선다 — **전역으로 떨어져 `⌘D`가 좌우 분할이다** |

  **이 갈림이 필요한 이유는 대가가 서로 다르기 때문이다.** 「안 선다」를 Term 단위로 처리하면 둘 중
  하나가 반드시 깨진다 — 컨텍스트를 통째로 끄면 `⌥Z`가 비교 뷰에서 **죽고**(실측으로 그랬다), 통째로
  켜면 `⌘D`가 컨텍스트에 잡혀 **비교 뷰에서 화면을 못 나눈다**(액션이 거절해 아무 일도 안 일어난다).
  [diff·떠 있는 UI·설정](native-editor-ui.md) §9.1의 원칙이 그 답을 이미 든다 — *"편집 의미가 있는
  키는 편집기 우선, 창·탭·앱 관리는 앱이 계속 먹는다"*. 비교 뷰에서 「다음 일치 추가」는 **의미가
  없으므로** 그 키는 앱의 것이다.

  **거절은 액션도 한다**(각 함수가 `editor_diff != null`을 거절한다). resolver 쪽 판정은 그것을
  대신하는 것이 아니라 **chord 를 전역에 돌려주기 위한** 것이다 — 액션만 거절하면 chord 는 이미
  소비된 뒤라 `⌘D`가 조용히 죽는다.
- **이 컨텍스트로 풀리는 것과 안 풀리는 것을 가른다.**

  | chord 없는 편집기 액션 | 이 컨텍스트가 푸나 |
  |---|---|
  | `toggle_editor_wrap`(VSCode `⌥Z`) | **푼다** — Option 단독이 터미널 입력을 뺏는다는 근거가 이 Term에서는 성립하지 않는다 |
  | `duplicate_lines`·`move_lines_up`/`_down`(VSCode `⇧⌥↓`·`⌥↑↓`) | **푼다** — 같은 근거다 |
  | `fold_all`·`unfold_all`·`fold_level_1..3` | **안 푼다** — 막는 것이 *"한 chord로 못 적는다"*(VSCode는 `⌘K ⌘0` 두 키 시퀀스이고 `KeyChord`는 수식자+키 하나)라, **다른 선행**이다 |
  | `add_next_occurrence`(멀티커서 「다음 일치 추가」) | **푼다 — `⌘D`로 옮겼다**(2026-09-04). [diff·떠 있는 UI·설정](native-editor-ui.md) §9.1이 *"`⌘D`는 편집기 포커스에서 「다음 일치 추가」다"*로 **확정**해 두고 *"편집기 Term 칸이 서기 전에 가져가면 터미널에서 pane split이 사라진다"*는 이유로 `⌘⌃D`를 임시로 썼다. 그 칸이 이 컨텍스트다 |

- **`⌘C`는 이 컨텍스트가 필요 없다.** 계획 문서는 오래 *"⌘C 기본 chord(터미널 선택이 쓰는 키라 편집기
  Term 컨텍스트가 있어야 양보할 수 있다)"*로 남겨 뒀지만, **기능은 2026-08-26에 Swift 진입점으로
  섰다**(`copy_editor_selection` 디스패치). 기본 표에 chord가 없는 것은 사실이나 **복사가 안 되는 것은
  아니다** — 그 두 문장이 한 문서 안에서 서로를 가리고 있었다.

#### `input.option-as-meta` 가 이 컨텍스트보다 위에 있다 (2026-09-03 사용자 결정)

**Option 단독 chord는 이 컨텍스트만으로 성립하지 않는다.** macOS에서 `⌥`+글자는 **특수문자를 만드는
조합**이기도 하고([설정](configuration.md) `input.option-as-meta`가 그 갈림을 소유한다), **그 판정은
Swift의 `keyDown`에서 앱 단위로 끝난다** — 그 시점에는 **어느 Term이 활성인지 모른다**.

| `input.option-as-meta` | `⌥Z` 가 가는 곳 | resolver 가 보나 | 편집기에서 누르면 |
|---|---|---|---|
| **`true`**(기본) | IME 우회 → 단축키 경로 | **본다** | 컨텍스트 기본키가 **작동한다** |
| `false` | macOS 입력기(조합) | **못 본다** | 특수문자가 **문서에 들어간다** |

**설정이 이긴다.** `false`로 둔 사용자는 *"특수문자를 치겠다"*는 뜻으로 그렇게 둔 것이고, 편집기가 그
의도를 뒤집지 않는다. 그 설정에서 Option 단독 편집기 기본키는 **없는 것으로 친다** — 커맨드 팔레트와
**설정 창의 키바인딩 편집**으로 닿는다(그 목록은 커맨드 카탈로그를 그대로 쓰므로 이 액션들이 이미 든다).

**이 사실을 계약에 적는 이유는 「왜 안 먹지」를 막기 위해서다.** 컨텍스트를 세워도 그 설정에서는 안
먹는데, 적어 두지 않으면 다음 사람이 컨텍스트의 결함으로 오해하고 같은 자리를 다시 판다.

#### 전역 chord를 편집기가 가져가는 경우 — `⌘D` 가 첫 자리다

위에서 *"전역 chord를 편집기에서 가로채는 것은 이 절이 허락하지 않는다 — 그렇게 하려면 그 chord마다
근거를 따로 적는다"*고 했다. **`⌘D`가 그 첫 자리이고, 근거는 이렇다.**

- **다른 문서가 이미 확정했다.** [diff·떠 있는 UI·설정](native-editor-ui.md) §9.1이 *"`⌘D`는 편집기
  포커스에서 「다음 일치 추가」다(확정)"*로 정했고, 이 절은 그 결정을 **실행할 자리**를 열 뿐이다.
  판정 원칙도 그 문서가 든다 — *"편집기가 포커스일 때는 편집 액션이 앱 액션보다 우선한다"*, 그리고
  그것은 웹 편집기 라우팅(`web_editor`가 `⌘A`·`C`·`V`·`X`·`Z`·`S`를 WebKit에 양보)이 **이미 쓰는
  규율**이다.
- **대가가 갚아진다.** §9.1이 *"편집기에서도 split 수단을 잃지 않아야 한다"*를 조건으로 걸었고,
  실측하면 셋이 서 있다 — `⌘⇧D`(상하 분할)는 전역 표에 그대로, 커맨드 팔레트에 `Split Right`·
  `Split Down`, 앱 메뉴에 같은 액션. **잃는 것은 좌우 분할의 chord 하나이고 수단이 아니다.**
- **전역은 안 바뀐다.** `⌘D`는 `default_app_bindings`에 `split_horizontal`로 **그대로 남는다** —
  터미널·브라우저·파일 Term에서는 종전대로다. 컨텍스트 표가 편집기 Term 안에서만 그 앞에 선다.

**이것이 「전역 가로채기」의 유일한 예외이고, 늘리려면 같은 세 줄(다른 문서의 확정 · 대가의 대체 경로 ·
전역 불변)을 그 chord마다 적는다.**

**어떤 chord를 실제로 넣는가는 이 절이 정하지 않는다.** 컨텍스트가 서면 각 액션의 chord는
[입력 설정](configuration-input.md)이 소유하는 결정이고, 그 표의 「무엇이 막고 있나」 행들이 그때
갱신된다. 이 절이 정하는 것은 **판정 순서와 그 근거**다.

기본 바인딩과 의미:기본 바인딩과 의미:

| 키 | action/소유자 | 의미 |
|---|---|---|
| `⌘W` | `close_focused` | 도크 WebView가 이벤트를 받으면 그 surface의 파일 탭, 트리 포커스면 포커스 group의 active 파일 탭, terminal/browser pane이면 기존 Term close cascade. Metal terminal key entry와 stale dock owner가 충돌하면 interactive overlay·tree·surface-publish 대기를 보존한 뒤 terminal provenance가 이긴다. browser WebView가 source이면 stale dock owner를 버리고 workspace owner와 Metal responder intent를 먼저 세우므로 확인창을 취소하거나 승인한 뒤 다음 `⌘W`도 눈앞의 workspace cascade를 따른다. **publish 대기 barrier(`.dock_pending`)는 닫기를 삼키지 않는다**(2026-08-21) — barrier가 소유 중이면 그 entry가 곧 활성 pane의 활성 Term이라 대상이 확정돼 있으므로 `.workspace`와 같은 cascade를 탄다. 안 그러면 파일 탭을 닫아 승계된 탭도 파일일 때 다음 `⌘W`가 ack가 올 때까지 사라진다([file-panel-dock-ui.md](file-panel-dock-ui.md) §3.4). barrier가 계속 fail-close하는 것은 PTY write·paste·drop이다. dirty close는 [file-panel-dock-ui.md](file-panel-dock-ui.md) §3.2를 따른다. |
| `⌘⇧E` | `toggle_file_panel_focus` | workspace terminal/browser에서 project tree로 들어가고, 파일 도크 본문/트리에서는 활성 workspace pane으로 돌아간다. 완전히 빈 도크는 picker를 열지 않고 no-op notice. 사용자 rebind/unbind 우선. |
| `⌘S` | Markdown CM6 | 라이브·소스에서 현재 revision을 pathless atomic write로 저장한다. 성공한 같은 revision에서만 dirty를 내리며 autosave는 없다. |
| `⌘F` | Markdown CM6 | 라이브·소스에서는 Maru의 작은 CM6 search extension이 문서 검색을 연다. 검색은 explicit 사용자 동작에서만 source 문자열을 만들 수 있으며 새 runtime package는 추가하지 않는다. read/HTML/terminal에서는 기존 context resolver 의미를 유지한다. |
| `↑/↓` | file tree | 이전/다음 조작 가능한 row. |
| `←/→` | file tree | 접기/부모 또는 펼치기/첫 자식. |
| `Enter` | file tree | directory toggle 또는 파일 열기. |
| `Home/End` | file tree | 첫/마지막 조작 가능한 row. |
| `PageUp/PageDown` | file tree | tree viewport 단위 이동. tree focus가 아니면 기존 terminal/browser 의미를 유지한다. |
| `Esc` | file tree | 진입 전 도크 WebView, 없으면 활성 terminal/browser pane으로 복귀. |
| `F2` | file tree | 허용된 project row의 inline rename 시작. |
| `⌘Backspace` | file tree | 허용된 project row를 확인 뒤 macOS 휴지통으로 이동. |

`⌘Backspace`는 tree focus에서만 `delete_file_tree_entry`가 이기며, 그 밖의 terminal focus에서는 기존 빌트인 `Ctrl+U` 바이트를 유지한다. `close_term`은 명시적 사용자 binding 호환을 위해 남지만 기본 `⌘W`는 `close_focused` 하나만 소유한다. `focus_file_tree`는 하위버전 adapter가 아니라 one-way tree 진입용 action으로 남고 FP9부터 기본 chord는 `toggle_file_panel_focus`가 소유한다. **FP16 목표**: 파일이 워크스페이스 Term이 되면 도크에 트리밖에 없어 두 action의 대상이 같아지므로 `focus_file_tree`를 제거하고 `toggle_file_panel_focus` 하나만 남긴다(shim 없이 완전 제거 — [file-panel-dock-ui.md](file-panel-dock-ui.md) §3.4·[file-panel.md](file-panel.md) §8). Esc 복원은 저장된 `{surface_id, generation}`을 재검증하고 stale이면 활성 terminal/browser pane으로 fallback한다. selection과 focus는 transient라 workspace restore 입력이 아니다. focus border의 시각 계약은 [file-panel-dock-ui.md §3.4](file-panel-dock-ui.md#34-terminal파일-도크-입력-포커스-표시왕복)가 소유한다.

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

## 글로벌 핫키

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

## 파일 패널 열기 (⌘O, open_file_panel)

`⌘O`는 `open_file_panel` 앱 액션의 기본 바인딩이다. 현재 창에서 macOS 파일 선택창을 열고 `.md` 또는 `.html`
정규 파일 하나를 선택해 전역 파일 도크에 연다. 이미 열린 경로면 새 탭을 만들지 않고 기존 탭을 활성화한다. 메뉴와
커맨드 팔릿도 같은 액션을 쓰며, 사용자 `keybind`로 이동하거나 `unbind`할 수 있다. 파일 형식·경로 판정은 Zig가,
`NSOpenPanel` 표시만 Swift가 맡는다([file-panel.md](file-panel.md) §6).

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
docs/io-render-threading.md). 대신 "form-feed를 보낼지"를 bool로 돌려준다. in-process runtime은 reader가 코어
락 아래 이 결정을 얻고, 락 밖의 reader-owned PTY 출력 버퍼에 `0x0C`를 붙인다. host-backed runtime도 같은
`clear_screen` core command를 host reader에 보내 **권위 core의 판정과 PTY 주입을 한 reader 순서축**에서 수행한다.
GUI가 attachment placeholder를 지우거나 별도 `writeInput`을 보내면 host 화면이 다음 observation에 되살아나고
명령과 `^L` 사이에 사용자 입력이 끼므로 금지한다. 프롬프트 분류는 셸 통합(OSC 133)이 있을 때만 생기고,
그때만 셸 `^L`이 정상 동작하므로 프롬프트 분기와 form-feed가 일관된다. `runtime_clear_screen_v1`을 별도
협상해 이 op를 모르는 N-1 host에는 보내지 않는다(그 연결에서는 안전한 degraded no-op; 재시작해 current host로
올라오면 활성화). 기존 `runtime_core_command_v1` 집합을 암묵 확장해 구 host 연결을 끊지 않는다.

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

경계: Swift 메뉴 액션 → ABI `maru_macos_app_session_reset_input_modes` → `app_session.resetInputModes`로 들어간다.
in-process runtime은 활성 surface reader queue에, host-backed runtime은 `reset_input_modes` core command를 host
reader queue에 넣어 각각 **권위 core**의 `resetInputModes`를 적용한다. 입력 인코딩 상태만 바꿔 렌더에 영향이
없다. capability `runtime_core_command_v1`을 협상한 host에서는 응답 없는 stream frame이며, client control
barrier와 host input-byte fence가 `기존 입력 → reset → 새 입력` 순서를 보존한다. AppKit main thread는 RPC
response를 기다리지 않는다. 구 host가 capability를 광고하지 않으면 명령을 조용히 성공 처리하지 않고 해당
세션을 host-backed로 여는 spawn 계약 자체가 거절돼 in-process fallback을 사용한다.

## 텍스트 선택의 해제 경계 (`⌘A` 이후)

`⌘A`(`Action.select_all` → `TerminalCore.selectAll`)는 스크롤백을 포함한 전체를 선택한다. 문제는 **그 선택을
언제 푸느냐**였다 — 해제 전이가 정의돼 있지 않으면 하이라이트가 영구히 남는다. 실제로 그런 결함이 있었다:
해제에 닿는 경로가 ⑴ 트래킹이 꺼진 상태의 "이동 없는 클릭"(`select_extend_or_collapse`), ⑵ 새 선택 시작(앵커
덮어쓰기), ⑶ 좌표가 무효가 되는 화면 재배치(`invalidateSelection` — resize reflow·alt 화면 전환·ED3)뿐이라,
`selectAll`이 만든 선택은 사용자가 창 크기를 바꾸기 전까지 남았다. **마우스 트래킹을 켠 TUI**(vim·tmux·
Claude Code 등 DECSET 1000~1003) pane에서는 클릭이 리포팅으로 빠져 ⑴마저 막히므로 지울 방법이 아예 없었다.

그래서 "선택을 만든 주체가 아닌 쪽이 그 선택을 무효로 만드는" 지점을 명시적 전이로 둔다. 해제는 코어 mutate라
`CoreCommand.select_clear`로 reader에 위임하고(선택 위임 규율 — [io-render-threading.md](io-render-threading.md)
§9 P3-4), 호출은 `app_session.clearSurfaceSelection` 한 곳으로 모은다. host-backed에서는 하이라이트가 attachment
placeholder에 있으므로 해제도 placeholder에 적용한다(host 왕복 없음).

| 지점 | 해제 이유 | config |
|---|---|---|
| 마우스 리포팅 중 **버튼 이벤트**(누름/뗌/더블/트리플) | 그 pane의 마우스는 앱이 소유한다 — 클릭으로 지울 수 없는 선택은 유령이 된다. shift·option 클릭은 선택 override라 애초에 리포팅으로 안 간다. 드래그 motion은 버튼 이벤트가 아니라 제외 | 없음(항상) |
| 마우스 리포팅 중 **휠** | 앱이 휠을 소비해 화면을 굴린다 — 선택 좌표가 어긋난다 | 없음(항상) |
| alt 화면 + alternate scroll(1007)의 **휠→화살표 변환** | 프로그램이 화면을 다시 그린다 | 없음(항상) |
| **타이핑** | 입력을 시작하면 선택은 관심 밖이다. 실제 글자는 macOS IME 확정 경로(`routeCommittedText`)로 오므로 키 경로와 확정 경로 **둘 다**에 건다 — 키 경로에만 걸면 평범한 타이핑에 반응하지 않는다(`mouse-hide-while-typing`과 같은 사정) | `input.selection-clear-on-typing`(기본 `true`) |
| **Esc** | "선택 취소"의 관용 키 | 없음(항상 — config가 `false`여도) |

**베이스/결정**: Ghostty가 같은 세 축(리포팅 버튼·리포팅 스크롤·타이핑/Esc)에서 `setSelection(null)`을 하는 것을
동작 베이스로 삼았고, config 이름·기본값도 `selection-clear-on-typing`(기본 `true`)을 따랐다. maru의 신규 config
키는 보통 "회귀 없음 opt-in"으로 두지만 여기선 **현행이 결함**이라 기본을 `true`로 두는 예외다(`false`로 두면
옛 동작). 코드 표현은 옮기지 않았다(clean-room — 동작 비교만).

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
  1. 확정 텍스트가 쌓였으면 UTF-8 바이트를 surface별 ordered input queue에 넣는다(LF는 CR로 정규화, bracketed paste는 적용하지 않음). 키 자체는 기본적으로 입력기가 소비하되 `input.ime-enter=newline`이면 Enter를 아래 replay 규칙으로 같은 queue 뒤에 붙인다. 단 조합 중 단일 C0(조합 조작용 Ctrl+H류)는 입력기 소유라 버린다.
  2. 텍스트는 없지만 조합이 변했으면(자모 삭제 등) 키를 보내지 않는다.
  3. 둘 다 아니면 일반 키 — 기존 인코딩 경로(Enter/Backspace/기능키).
  ime_end는 정규화 불가 키(codepoint/keyCode 없음)에도 반드시 호출돼 트랜잭션을 닫는다(안 닫으면 누적 텍스트 유실·ime_active 박힘). 확정 텍스트와 함께 온 화살표는 확정 후 다시 보낸다(위/오른/아래 항상, 왼쪽은 수정자 있을 때만 — 한글 후보를 화살표로 확정 시 커서 이동 보존). 확정 UTF-8과 이 replay key는 같은 surface별 ordered input queue에 **확정→replay** 순서로 한 번에 예약한다. 서로 다른 direct-write 경로로 보내 순서가 뒤집히면 안 된다. `imeInsert` 누적이나 ordered queue 예약이 OOM이면 반쪽 문자열·replay만 보내지 않고 그 트랜잭션을 0회 전송으로 닫는다. 따라서 “정확히 한 번”은 queue 예약 성공 뒤의 application admission/submit 계약이다. allocator failure, 이후 PTY 소비, 원격 hard error 뒤 durable delivery까지 보장한다는 뜻은 아니다.
  추가로, 한글 마지막 자모 백스페이스에서 입력기는 `insertText`(조합 글자) + `deleteBackward`를 같은 keyDown에 보내는데(커밋 후 삭제 = net 0, 실측 확인), `deleteBackward`가 같이 오면 확정 텍스트의 마지막 코드포인트를 그 삭제가 상쇄한다 — 글자가 PTY에 박혔다가 다음 백스페이스로 지워야 하는 문제를 없앤다(ABI v21 ime_delete_backward).
  Option+글자는 입력기를 우회해 기존 meta-ESC 인코딩을 유지한다(특수문자 입력이 아님). Control+Command+Space(이모지 & 기호 피커)는 Ctrl/Cmd 가로채기보다 우선해 시스템 character palette를 연다 — 고른 이모지/기호는 입력기 insertText로 들어와 PTY로 전송된다. 조합 시작(imeBegin)은 타이핑처럼 뷰포트를 바닥으로 스냅해 스크롤백을 본 채 조합해도 preedit이 보인다. host-backed 경로는 `async_scroll_to_bottom_v1`을 협상한 응답 없는 stream command를 bounded outbound 슬롯에 nonblocking admission하며, AppKit callback에서 `client.call`/response를 기다리지 않는다. `RemoteRuntime`은 direct key를 64 KiB bounded FIFO로, scroll/focus/config/prompt를 최대 64개 control FIFO로 소유하고 각 control 시점의 input offset을 barrier로 고정한다. 같은 barrier의 반복 scroll intent는 coalesce하며 backpressure 뒤에도 자동 재시도해 `기존 input → control → 새 input` 순서를 보존한다. FIFO admission 뒤 frame encode OOM은 성공한 queue ownership으로 취급해 tick에서 재시도한다. direct input cap 초과 admission은 효과 0으로 거부하고, control cap 초과 또는 control queue allocation 실패는 마지막 상태를 조용히 잃지 않도록 shared connection을 fail-close한다. 각 remote runtime pump는 이 transport 실패를 자기 surface의 one-shot `exited` 상태로 올려 반복 오류와 이후 입력을 막는다. host reader queue가 응답 없는 input/control을 admission하지 못한 경우도 server가 connection을 fail-close한다. 이후 blocking mouse/resize/observation RPC는 두 FIFO를 먼저 flush해 이미 수락한 key/control을 추월하지 않는다. 현재 host의 scrolled snapshot은 활성 커서를 그리지 않도록 `visible=false`로 두되 canonical live `row/col`은 보존한다. 입력기 후보창은 합성으로 이동한 표시 커서가 아니라 이 canonical base cursor의 셀 위치에 뜬다(ABI v22 ime_cursor_rect — Zig가 커서 셀의 backing px 사각형을 주고 Swift firstRect가 화면 좌표로 변환). 살아 있는 구 MRSH v2 host가 `screen_viewport_scrolled_v1` 또는 async scroll capability를 제공하지 않아도 동기 RPC로 fallback하지 않는다. 구 wire에서 `cursor.visible=true`인 snapshot만 live bottom의 안전한 증거로 사용해 marked text와 정밀 후보 anchor를 허용한다. hidden cursor는 scrollback과 DECTCEM-hidden live 화면이 모호하므로 조합 표시를 숨기고 후보창을 neutral pane origin으로 폴백한다. 이 증거는 snapshot마다 다시 계산하며 latch하지 않는다. 확정 텍스트의 개행은 \r로 정규화한다(멀티라인 insertText 안전). 포커스 변화도 Zig가 소유한다(`set_focus`) — 잃으면 조합 중 텍스트를 버리지 않고 확정 커밋한다(Terminal.app/Ghostty 의미론, unit 검증).
- 조합 중(preedit) 글자는 `Surface`가 소유하는 `PreeditOverlay`가 base `RenderSnapshot`의 커서 위치부터 반전 스타일로 합성 표시한다. 로컬 `TerminalCore` snapshot과 host-backed `RemoteScreen` snapshot 모두 같은 합성기를 사용한다. **삽입형 미리보기**라, 줄 가운데에서 조합하면 커서 뒤 글자를 조합 폭만큼 오른쪽으로 밀어 확정 후 셸이 그릴 모습을 조합 중에도 보여준다(`가나다`의 `나` 앞 조합 → `가[라]나다`). 합성용 scratch cell에만 그리므로 실제 로컬 core grid와 원격 host grid·delta base는 불변이고, host delta가 도착할 때마다 최신 base에 다시 합성한다. 조합 폭의 단일 출처는 base `RenderSnapshot.ambiguous_wide`이며 현재 host에서는 mode bit로 원격까지 복원한다. 해당 bit가 없던 구 host의 legacy degraded mode는 한글/CJK 고정 wide 폭은 표시하지만 ambiguous-width 설정 parity는 보장하지 않는다. overlay나 GUI config 사본이 별도 폭 정책을 소유하면 안 된다. `size`·grapheme·prompt mark·command exit·placement·image·base 폭 정책 같은 snapshot 필드는 그대로 보존한다.
- marked text는 해당 GUI attachment에만 존재한다. MRSH wire, `CoreCommand`, workspace manifest, runtime metadata에 저장하거나 전송하지 않는다. 따라서 같은 runtime을 보는 다른 창/클라이언트와 detach 뒤 재접속한 클라이언트에는 조합 중 문자열이 나타나지 않는다. pane/Term/workspace 전환과 포커스 상실은 입력 owner를 바꾸기 전에 조합을 원 surface id의 ordered input queue에 확정한다. workspace를 다른 창으로 옮길 때 아직 전송되지 않은 surface별 queue도 surface와 함께 destination session으로 넘겨 detach 정리에서 버리지 않으며, target이 실제로 사라졌을 때만 새 활성 터미널로 fallback하지 않고 폐기한다. cross-window workspace 이동은 source 이동 대상뿐 아니라 destination의 현재 input owner도 소유권/focus 변경 전에 각 원 surface queue로 확정한다. 두 terminal admission과 moved queue transfer buffer/map은 all-or-none으로 선예약하며 어느 admission/transfer preflight OOM에서도 detach/model surgery 전 전체를 취소해 양쪽 overlay·pin·queue·layout을 그대로 보존한다. same-window는 active owner가 바뀔 때만 확정하고, merge는 destination active owner를 보존하므로 source만 확정한다. 예약 성공한 확정 UTF-8은 application queue에 중복 없이 한 번 admission하지만, 위 OOM fail-closed 경계에서는 0회가 허용되고 transport-level delivery ACK는 제공하지 않는다.
- 커서에서 시작하는 후행 콘텐츠 run이 전부 faint(SGR 2 → `Cell.style.dim`)면 앱이 그린 인라인 자동완성 고스트로 보고 밀지 않고 오버레이로 덮는다. 그 외에는 삽입형으로 합성한다. 색만으로 고스트를 판정하면 실제 회색 텍스트를 오인할 수 있어 사용하지 않는다. 조합 중 블록 커서는 숨기고 깜빡임은 보이는 위상에 고정한다. preedit 밑줄 스타일은 아직 없으며 현재는 반전 스타일이다.


#### 두 번째 자리 — `⌥⌘↑`/`⌥⌘↓`(위/아래로 커서 추가, 2026-09-05)

같은 절차를 밟는다. 근거 셋:

- **다른 문서가 판정 기준을 든다.** [diff·떠 있는 UI·설정](native-editor-ui.md) §9.1의 경계 기준은
  *"그 키가 **문서에** 작용하는가, **창에** 작용하는가"* 이고, 커서 추가는 문서에 작용한다. 같은 절이
  *"같은 키가 포커스에 따라 다른 일을 하는 대가를 수용한다 — 대안(어느 한쪽 사용자가 손에 익은 키를
  영구히 잃는 것)보다 낫다"* 고 **이미 정해 두었다**.
- **수단을 잃지 않는다.** §9.1이 `⌘D`에 건 그 조건이다. `focus_pane_up`/`focus_pane_down`은 커맨드
  팔레트와 **앱 메뉴 둘 다**에 남는다(`MaruAppHost.swift`가 `split_horizontal` 바로 아래에 단다).
- **레퍼런스가 그 chord 를 준다.** VSCode macOS 기본이 `insertCursorAbove`/`insertCursorBelow` =
  `⌥⌘↑`/`⌥⌘↓` 다(기본 keybinding 실측).

**남는 빚은 발견성 하나다.** 갚는 수단은 `⌘D` 때와 사실상 같지만(팔레트 + 앱 메뉴), §9.1이 든 완화책인
**모디파이어 홀드 오버레이가 아직 없다** — 편집기 pane에서 `⌥⌘↑`를 누른 사용자가 pane이 안 옮겨진
이유를 화면에서 알 길이 지금은 없다.

**`⌥⌘←`/`⌥⌘→` 는 안 가져간다** — VSCode에서 그 자리는 「편집기 탭 이동」인데 Maru는 pane 모델이 달라
`focus_pane_left`/`right`가 더 잘 맞는다. 전수 대조에서 나온 다섯 중 이 둘은 **의도적으로 남긴다**.