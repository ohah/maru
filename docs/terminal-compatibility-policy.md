# 터미널 호환성/보안 정책

이 문서는 Maru가 터미널 호환성, clipboard, paste, shell integration, workspace restore, plugin, update/telemetry를 어떤 기본값으로 가져갈지 정한다.

초보자 관점에서 중요한 이유는 간단하다. 터미널은 "글자를 보여주는 앱"처럼 보이지만, 실제로는 shell과 로컬 시스템 권한 사이에 있는 프로그램이다. `TERM`, clipboard, paste, shell hook, 자동 command 실행 정책을 잘못 정하면 앱이 조금 불편한 수준을 넘어 사용자 shell, 원격 서버, 비밀 토큰, destructive command에 영향을 줄 수 있다.

## 원칙

Maru v1은 Ghostty보다 더 많은 터미널 기능을 제공하는 것이 목표가 아니다. 목표는 Ghostty급 기본기를 참고하되, 더 작은 기능 표면으로 가벼운 native shell 경험을 만드는 것이다.

따라서 기본 전략은 다음과 같다.

- 호환성은 보수적으로 시작한다.
- 보안 표면은 기본적으로 사용자 확인을 요구한다.
- shell 환경을 자동으로 바꾸는 기능은 opt-in으로 시작한다.
- 자동 복구는 process를 되살리는 기능이 아니라 선언적 workspace를 다시 여는 기능으로 제한한다.
- plugin은 core를 직접 만지지 않고 domain event와 action facade를 통해서만 동작한다.

## Ghostty 비교 요약

이 표는 Ghostty를 구현 소스로 삼자는 뜻이 아니다. Maru는 [레퍼런스와 공개 명세](references.md)의 clean-room 규칙을 따른다. Ghostty 비교는 제품 정책을 정하기 위한 second opinion이다.

| 영역 | Ghostty가 취한 방향 | Maru v1 기본 정책 |
| --- | --- | --- |
| `TERM` / terminfo | 자체 terminfo와 `xterm-ghostty` 기본값을 사용하고, 필요하면 `xterm-256color`로 fallback한다. | `xterm-256color`를 기본값으로 둔다. 자체 `xterm-maru`/`maru` terminfo는 opt-in 실험으로 시작한다. |
| OSC52 clipboard | OSC52를 지원한다. 읽기는 사용자 확인, 쓰기는 기본 허용에 가깝다. | OSC52는 지원하되 읽기와 쓰기 모두 기본 `ask`로 둔다. |
| bracketed paste | bracketed paste를 지원하고 paste protection을 기본 ON으로 둔다. bracketed paste는 기본적으로 safe로 본다. | bracketed paste와 paste protection은 v1 필수다. bracketed paste를 safe로 보되, 더 엄격한 설정을 열 수 있게 한다. |
| shell integration | 기본 detect로 자동 주입하고 OSC 133/OSC 7, cwd 보고, ssh/sudo 보조 기능까지 제공한다. | 자동 주입하지 않는다. v1은 명시 opt-in zsh hook부터 시작한다. |
| command restore | window/tab/split 복원은 있지만 임의의 command 자동 재실행에는 보수적이다. | layout/cwd/env/shell restore까지만 기본 지원한다. 마지막 foreground command 자동 재실행은 금지한다. |
| plugin | 일반 사용자 Wasm plugin 권한 모델은 제품 중심 기능으로 보이지 않는다. | Wasm plugin은 Maru의 장기 차별화다. v1에는 runtime을 넣지 않고 권한/경계 계약만 유지한다. |
| update/telemetry | macOS update는 Sparkle을 사용한다. crash report는 로컬 저장 중심이다. | v1에는 updater와 telemetry를 넣지 않는다. crash/log/trace는 로컬 전용으로 설계한다. |
| global shortcut | macOS global key event와 앱 내부 key event를 분리한다. | platform/app layer에서 처리한다. terminal input과 같은 경로로 섞지 않는다. |

## `TERM` / terminfo

v1 기본값:

```text
TERM=xterm-256color
COLORTERM=truecolor
```

이 선택은 멋은 덜하지만 실사용 위험이 작다. 많은 CLI와 원격 서버는 `xterm-256color`를 이미 알고 있다. 반대로 `xterm-maru`나 `maru`를 기본값으로 두면 원격 서버에 terminfo가 없을 때 `vim`, `tmux`, `less`, `htop` 같은 프로그램이 색상, 키 입력, alternate screen을 잘못 처리할 수 있다.

자체 terminfo는 다음 조건이 갖춰진 뒤 opt-in 실험으로 추가한다.

- `tests/oracle/` fixture로 주요 CSI/OSC/alternate screen 동작을 비교할 수 있다.
- `tests/integration/ssh/` 또는 opt-in SSH smoke에서 원격 fallback 손해를 볼 수 있다.
- terminfo 설치/배포/원격 fallback 정책을 사용자가 이해할 수 있게 문서화한다.

기본값 전환은 별도 PR에서 사용자와 다시 논의한다.

## OSC52 clipboard

OSC52는 터미널 내부 프로그램이 system clipboard를 읽거나 쓰는 escape sequence다. 편하지만 보안 표면이 크다. 예를 들어 원격 SSH 세션 안의 프로그램이 로컬 clipboard에 값을 쓰거나 읽으려 할 수 있다.

v1 기본값:

```text
osc52.read = ask
osc52.write = ask
```

정책:

- `deny`, `ask`, `allow` 세 값을 지원할 수 있게 설계한다.
- 기본값은 읽기/쓰기 모두 `ask`다.
- 사용자가 `allow`로 바꾸기 전까지 background clipboard 변경은 하지 않는다.
- clipboard 요청은 trace fixture에 원문을 저장하지 않는다. 필요하면 redaction된 event만 남긴다.

## Bracketed Paste

bracketed paste는 paste 시작과 끝을 shell/program에 알려주는 기능이다. 이 기능이 있으면 `vim`, shell, REPL이 사용자가 타이핑한 텍스트와 붙여넣은 텍스트를 구분할 수 있다.

v1 기본값:

```text
bracketed_paste = true
paste_protection = true
bracketed_paste_is_safe = true
```

정책:

- bracketed paste mode `2004`는 v1 필수 호환성으로 본다.
- newline이 포함된 일반 paste는 unsafe 후보로 보고 사용자 확인을 요구한다.
- bracketed paste는 기본적으로 safe로 보되, 사용자가 더 엄격한 정책으로 바꿀 수 있게 한다.

## Shell Integration

shell integration은 shell 시작 스크립트에 코드를 넣어 prompt 시작/끝, 현재 cwd, command 시작/끝 같은 정보를 터미널에 알려주는 기능이다. Maru의 workspace restore와 최근 작업 세션에는 장기적으로 필요하지만, 자동 주입은 위험하다.

v1 기본값:

```text
shell_integration = off
```

정책:

- v1은 명시적으로 켠 zsh hook만 실험적으로 지원한다.
- 자동 detect/주입은 하지 않는다.
- hook이 내보내는 event는 문서화된 OSC/domain event만 허용한다.
- shell integration이 없어도 기본 터미널 사용이 가능해야 한다.
- bash/fish/nushell 지원은 zsh hook이 안정화된 뒤 별도 PR에서 논의한다.

이렇게 하는 이유는 사용자의 dotfiles, prompt theme, oh-my-zsh plugin이 다양하기 때문이다. 자동 주입이 깨지면 사용자는 Maru가 아니라 자신의 shell 환경이 망가졌다고 느낀다.

## Workspace Restore와 Command Restore

workspace restore는 live process를 저장하는 기능이 아니다. 저장하는 것은 다시 열기 위한 선언적 설명서다. 자세한 저장 모델은 [Workspace Restore 전략](workspace-restore.md)을 따른다.

v1 기본 정책:

- 복구한다: workspace, tab/split layout, surface cwd, safe env override, shell 시작 정보.
- 기본 자동 재실행하지 않는다: 마지막 foreground command, 임의 shell string, destructive 가능 command.
- 사용자가 repo별 startup command를 명시한 경우에만 실행 후보가 된다.
- command 실행은 `argv` 형태를 우선한다. shell string은 별도 UX와 경고가 필요하다.

자동 command restore는 구현 전에 다시 논의한다. 이 결정은 UX가 아니라 안전 문제다.

## Plugin / Wasm

Wasm plugin은 Maru의 장기 차별화지만 v1 범위가 아니다. v1에서 할 일은 runtime을 넣는 것이 아니라, plugin이 들어와도 core를 직접 만질 수 없게 경계를 유지하는 것이다.

초기 경계:

- plugin은 domain event를 읽고 action facade로 요청한다.
- plugin은 `TerminalCore` private storage, PTY handle, renderer resource를 직접 받지 않는다.
- plugin failure는 surface/window 전체를 죽이지 않는다.
- clipboard, filesystem, network, process 실행, workspace 읽기/쓰기 권한은 capability로 분리한다.

Plugin ABI와 permission model을 확정해야 하는 순간이 오면, 구현 전에 별도 설계 문서를 만들고 사용자와 다시 논의한다.

## Update, Crash, Telemetry

v1 기본 정책:

```text
auto_update = off
telemetry = off
crash_report_upload = off
```

정책:

- v1에는 updater를 넣지 않는다.
- telemetry는 넣지 않는다.
- crash/log/trace는 로컬 전용으로 둔다.
- crash report나 trace fixture를 git에 넣을 때는 [필수 프로젝트 규칙](project-rules.md)의 redaction 기준을 따른다.

배포 단계에서 macOS signing, notarization, update feed가 필요해지면 별도 PR에서 논의한다.

## Global Shortcut

global shortcut은 quick terminal/scratch terminal UX에 필요하다. 하지만 terminal input과 같은 경로로 섞으면 안 된다.

정책:

- global shortcut은 platform/app layer 책임이다.
- `TerminalCore`, `PtySession`은 global shortcut 존재를 몰라야 한다.
- 앱이 focus된 상태에서는 local key resolver가 우선한다.
- 등록되지 않은 `Ctrl+B`, `Ctrl+C` 같은 terminal 관용 조합은 global shortcut 때문에 소비되면 안 된다.

세부 key grammar와 충돌 규칙은 [키 입력과 단축키 경계](key-input-and-shortcuts.md)를 따른다.

## 검증 계획

각 정책은 구현될 때 다음 검증 경로를 가져야 한다.

| 정책 | 최소 검증 |
| --- | --- |
| `TERM` / terminfo | PTY env unit/integration test, SSH opt-in smoke, oracle fixture |
| OSC52 | read/write ask/deny/allow unit test, redacted trace artifact |
| bracketed paste | mode 2004 fixture, unsafe paste confirmation path, bracketed safe path |
| shell integration | opt-in zsh hook fixture, cwd event parsing, hook disabled smoke |
| workspace restore | serialized workspace round-trip, no live PTY handle, no automatic last command |
| plugin/Wasm | fixture plugin, permission denial, panic/failure isolation |
| update/telemetry | config default test proving off/local-only behavior |
| global shortcut | key resolver collision test, macOS opt-in smoke artifact |

자동 E2E가 불가능한 영역은 [검증 매트릭스](verification-matrix.md)에 한계와 수동 검증 산출물을 남긴다.
