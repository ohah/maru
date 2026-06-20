# 터미널 호환성/보안 정책

이 문서는 Maru가 터미널 호환성, clipboard, paste, shell integration, workspace restore, plugin, update/telemetry를 어떤 기본값으로 가져갈지 정한다. 사용자 설정 파일의 위치/형식/키는 [설정(config) 파일](configuration.md)을 본다(현재 appearance: 폰트/테마/커서).

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
| `TERM` / terminfo | 자체 terminfo와 `xterm-ghostty` 기본값을 사용하고, 필요하면 `xterm-256color`로 fallback한다. | 자체 `xterm-maru` terminfo를 **기본값**으로 둔다(embed→자기 캐시 자동 컴파일 + `TERMINFO` env). 컴파일 실패 시 `xterm-256color` 자동 폴백 — Ghostty와 같은 방식. |
| OSC52 clipboard | OSC52를 지원한다. 읽기는 사용자 확인, 쓰기는 기본 허용에 가깝다. | OSC52를 지원한다. 쓰기는 기본 `allow`(로컬 단일 사용자 데스크톱), 읽기는 기본 `deny`(클립보드 탈취 방지)로 둔다. |
| bracketed paste | bracketed paste를 지원하고 paste protection을 기본 ON으로 둔다. bracketed paste는 기본적으로 safe로 본다. | bracketed paste와 paste protection은 v1 필수다. bracketed paste를 safe로 보되, 더 엄격한 설정을 열 수 있게 한다. |
| shell integration | 기본 detect로 자동 주입하고 OSC 133/OSC 7, cwd 보고, ssh/sudo 보조 기능까지 제공한다. | 자동 주입하지 않는다. v1은 명시 opt-in zsh hook부터 시작한다. |
| command restore | window/tab/split 복원은 있지만 임의의 command 자동 재실행에는 보수적이다. | layout/cwd/env/shell restore까지만 기본 지원한다. 마지막 foreground command 자동 재실행은 금지한다. |
| plugin | 일반 사용자 Wasm plugin 권한 모델은 제품 중심 기능으로 보이지 않는다. | Wasm plugin은 Maru의 장기 차별화다. v1에는 runtime을 넣지 않고 권한/경계 계약만 유지한다. |
| update/telemetry | macOS update는 Sparkle을 사용한다. crash report는 로컬 저장 중심이다. | v1에는 updater와 telemetry를 넣지 않는다. crash/log/trace는 로컬 전용으로 설계한다. |
| global shortcut | macOS global key event와 앱 내부 key event를 분리한다. | platform/app layer에서 처리한다. terminal input과 같은 경로로 섞지 않는다. |

## `TERM` / terminfo

기본값:

```text
TERM=xterm-maru          # 자체 terminfo. 컴파일 실패 시 xterm-256color로 자동 폴백
TERMINFO=~/.cache/maru/terminfo   # embed 소스를 자동 컴파일한 위치(자식 셸에만 주입)
COLORTERM=truecolor
```

**전환의 핵심은 "로컬을 안 깨지게" 하는 것**이다. 단순히 기본 `TERM`을 `xterm-maru`로 바꾸면, 로컬
terminfo DB에 항목이 없는 사용자의 `vim`/`tmux`/`less`가 `unknown terminal type`으로 깨진다. 그래서
Ghostty와 같은 방식을 쓴다(`src/termio/Exec.zig` 동작 비교): terminfo 소스를 바이너리에 **embed**하고,
자식 셸을 띄울 때 maru 자기 캐시(`~/.cache/maru/terminfo`)에 **자동 컴파일**(`tic`)해 `TERMINFO`를 거기로
가리킨다(`pty/macos.zig`의 `resolveTerm`). `~/.terminfo`나 시스템을 안 건드리는 **비침습** 방식이고,
`tic`이 없거나 컴파일이 실패하면 `xterm-256color`로 **자동 폴백**해 로컬이 절대 안 깨진다. 프로세스당
1회만 컴파일해 캐시한다.

캐시 staleness는 버전 마커로 자동 처리한다: 캐시에 embed 내용의 지문(`.maru-version`)을 함께 적고, spawn
때 지문이 일치하고 xterm-maru가 해석될 때만 재컴파일을 건너뛴다 — maru 업데이트로 terminfo 캡이 바뀌면
지문이 달라져 다음 spawn이 **자동 재컴파일**한다(예전엔 한 번 컴파일하면 영영 안 바꿔, 캡을 늘려도 기존
캐시에 반영되지 않는 footgun이 있었다). 경로·버전·컴파일 명령은 `terminfo_cache.zig`가 단일 출처로 갖고,
강제·진단용 `maru terminfo`(`--status`/`--refresh`/`--clear`/`--path`) 서브커맨드(`cli/terminfo.zig`)가 같은
캐시를 공유한다.

이로써 Maru 고유 기능(`Sync`·truecolor)을 terminfo로만 감지하는 프로그램도 무설정으로 인식한다(특히
tmux가 `Sync`를 읽어 레이아웃 플리커가 사라진다). 사용자는 `term = "xterm-256color"`로 언제든 되돌릴 수
있다.

**남는 위험은 원격(SSH)뿐이다.** `TERMINFO`는 로컬 env라 ssh가 전달하지 않으므로, **평범한 `ssh`**로
항목 없는 원격에 접속하면 깨질 수 있다. 이건 `maru ssh`(원격에 terminfo를 심고 exec)가 푼다. 직접 `maru
ssh`를 입력하지 않고 **평범한 `ssh`까지 자동으로** 덮으려면 shell-integration `ssh` 라우팅
(`shell-integration.ssh`, **기본 off** opt-in)을 켠다 — 통합 zsh가 `ssh`를 가리는 함수로 `maru ssh`에
위임한다(env `MARU_BIN`/`MARU_SSH_INTEGRATION` 주입 시에만, 없으면 평범한 ssh 그대로 — graceful). 기본
off인 건 `ssh`를 가리는 게 침습적이라 사용자 동의가 필요해서다(Ghostty도 plain ssh 깨짐을 감수하고
`ssh-env`/`ssh-terminfo`를 기본 off로 둔다 — 동작 비교). 설정은 [설정 파일](configuration.md)의
`shell-integration.ssh` 절.

### 런처 색-강제 override 제거 (`CLICOLOR_FORCE` / `FORCE_COLOR`)

Maru는 자식 셸 env에서 부모 `TERM`/`COLORTERM`을 위 값으로 덮을 뿐 아니라, 런처(빌드 도구·CI·부모 셸)가 남긴 **색-강제 override**(`CLICOLOR_FORCE`, `FORCE_COLOR`)도 **제거**한다. Maru가 터미널이므로 색 capability는 `COLORTERM`/`TERM`으로만 알린다 — 이 force 변수는 그 신호를 덮어써 잘못된 색 레벨을 강제한다.

근거(실측): `zig build`로 Maru를 띄우면 빌드 컨텍스트의 `CLICOLOR_FORCE=1`이 상속돼 자식 셸로 전파됐다. Rust `supports-color`(codex 등이 사용)는 `env_force_color`로 `CLICOLOR_FORCE!=0`·`FORCE_COLOR`을 **가장 먼저** 평가해 색 레벨을 강제(보통 basic 16색)하므로 `COLORTERM=truecolor`를 무시한다 → codex가 truecolor를 못 보고 입력창 회색 컴포저(pill 배경)를 끈다. GUI(Finder) 실행 시엔 이 변수가 없어 정상이라, 개발 중 `zig build`로 띄울 때만 나타나는 함정이었다. `NO_COLOR`/`CLICOLOR`는 사용자 의도(색 끄기 선호)일 수 있어 건드리지 않는다.

### 데스크톱 알림 식별 (`TERM_PROGRAM=ghostty`)

Maru는 자식 셸 env에 `TERM_PROGRAM=ghostty`를 주입한다(부모가 남긴 `TERM_PROGRAM`/`TERM_PROGRAM_VERSION`은 제거 후 덮어쓴다). Claude Code·Codex 같은 TUI는 데스크톱 알림을 보낼 터미널을 `TERM_PROGRAM` 화이트리스트(`iTerm.app`/`ghostty`/`kitty`/`WezTerm`)로 식별하는데, Maru는 그 명단에 없어 기본값에선 OSC 9 알림을 못 받기 때문이다(Claude의 `preferredNotifChannel`은 환경변수로 못 바꿔 우회 불가). `ghostty`를 고른 건 Maru가 kitty graphics·OSC 9/133/777을 Ghostty와 같은 셋으로 지원해, 식별 후 기대되는 기능과 어긋나지 않아서다(`iTerm.app`은 inline-image OSC 1337을 기대해 부적합).

이건 알림 호환을 위한 **식별값**이며 `TERM`(터미널 capability)과는 별개다 — `TERM`은 `config.term`으로 사용자가 바꿀 수 있지만 `TERM_PROGRAM`은 알림 식별용 고정값이다. 트레이드오프: Maru가 진짜 Ghostty는 아니므로 Ghostty 특화 시퀀스를 가정하는 프로그램과 미세한 차이가 날 수 있으나, Maru가 미지원하는 시퀀스는 무시하므로 무해하다. `TERM_PROGRAM_VERSION`은 주입하지 않는다(현재 식별 whitelist는 키 이름만 보므로 불요).

**현재 상태 — 기본값 `xterm-maru`로 전환됨**: 자체 terminfo 항목 `terminfo/maru.terminfo`(primary
`xterm-maru`, alias `maru`)를 바이너리에 embed해, 자식 셸마다 자기 캐시에 자동 컴파일하고 `TERMINFO`로
가리킨다(위 본문). `use=xterm-256color` 토대에, maru가 실제 지원하는 캡만 정직하게 더한다: 동기화 출력
(`Sync`, 2026), truecolor(`Tc`), bracketed paste(`BE`/`BD`, 2004), OSC 52 클립보드 set(`Ms` — write=allow),
커서 스타일(`Ss`/`Se`, DECSCUSR), focus 이벤트(`fe`/`fd`+`kxIN`/`kxOUT`, 1004). 캡 이름은 Ghostty terminfo를
second-opinion으로 비교하되 문자열은 maru 코어가 실제 처리하는 공개 escape에서 유도한다(코드 차용 아님 —
clean-room). 적합성 검증은 `mise run terminfo-check`(`tic` 클린 컴파일 + `Sync` round-trip + `Tc` 선언 +
확장 캡 9개의 실제 바이트 `tput` round-trip — "추측 말고 캡처"). `mise run install-terminfo`는 **Maru 밖
셸**에서 쓸 때만 필요하다(Maru 안에선 자동 캐시로 충분).

전환은 다음 선행 조건을 모두 채운 뒤 했다:

- [x] **로컬을 안 깨지게** — embed + 자동 캐시 컴파일 + `TERMINFO` env + `tic` 실패 시 `xterm-256color`
  폴백(`pty/macos.zig` `resolveTerm`). 비침습(`~/.terminfo` 미변경).
- [x] terminfo 설치/배포/원격 fallback 정책 문서화 — [설정 파일](configuration.md)의 `term` 절과 이 문서.
- [x] 원격 자동 전파 `maru ssh`(embed·ControlMaster·캐시·command 안전) + opt-in SSH smoke. 순수 로직
  (`src/cli/ssh.zig`)은 단위 테스트, e2e는 `mise run ssh-smoke`. 레퍼런스: Ghostty `ghostty +ssh`(동작 비교).
- [x] `tests/oracle/` CSI/OSC/alternate screen 비교 — 기존 스위트(`alt_screen`·`scroll_region`·
  `insert_delete_lines`·`cursor_save_restore` 등 + libvterm/Alacritty/Ghostty 3-way)로 충족. 전환의 두 캡은
  `Sync`(렌더 타이밍 — 화면 골든 비관찰, 전용 단위 테스트가 검증)·`Tc`(색 — 문자 골든 비검증)라 새 골든 픽스쳐 실익이 없다.

남는 위험은 **원격 plain-ssh**뿐이다(위 본문) — `maru ssh`로 덮고, 평범한 `ssh`까지의 자동화는
shell-integration `ssh` 라우팅(`shell-integration.ssh`, opt-in)으로 덮는다(기본 off라 켜야 적용). Ghostty도
plain ssh 깨짐 자체는 감수하고 `ssh-*`를 기본 off로 둔다.

## OSC52 clipboard

OSC52는 터미널 내부 프로그램이 system clipboard를 읽거나 쓰는 escape sequence다. 편하지만 보안 표면이 크다. 예를 들어 원격 SSH 세션 안의 프로그램이 로컬 clipboard에 값을 쓰거나 읽으려 할 수 있다.

v1 기본값(사용자 결정 2026-06-20):

```text
osc52.read  = deny    # 클립보드 탈취 방지 — core가 `?` 쿼리에 응답하지 않는다(무동작)
osc52.write = allow   # 로컬 데스크톱 단일 사용자 — 트래킹 앱의 드래그 복사를 시스템 클립보드에 반영
```

정책:

- `deny`, `ask`, `allow` 세 값을 지원할 수 있게 설계한다(정식 config 키는 후속).
- write 기본 `allow`: 로컬 단일 사용자 데스크톱 터미널이라 편의를 택했다(iTerm2/Ghostty도 유사). 트래킹 앱
  (예: Claude Code)의 드래그 복사가 그대로 시스템 클립보드에 반영된다.
- read 기본 `deny`: 원격/내부 프로그램이 로컬 clipboard를 탈취하지 못하게 한다. core가 `?` 쿼리에 응답하지 않는다.
- ask(요청별 확인 UI)는 후속 작업이다. 구현되면 write 기본을 `ask`로 올릴지 다시 논의한다.
- clipboard 요청은 trace fixture에 원문을 저장하지 않는다. 필요하면 redaction된 event만 남긴다.

요청 흐름:

```text
PTY output
-> TerminalCore parses OSC52
-> TerminalCore emits ClipboardRequest domain event
-> SurfaceRuntime queues AppRequest.clipboard
-> app/platform applies policy (현재 write=allow, read=deny; 요청별 ask UI는 후속)
-> app/platform completes the request
```

중요한 경계:

- `TerminalCore`는 macOS pasteboard나 system clipboard API를 직접 호출하지 않는다.
- `SurfaceRuntime`은 clipboard 요청을 app layer로 올리는 큐 역할만 한다.
- app/platform layer만 사용자 확인 UI와 실제 clipboard read/write를 안다.
- write는 사용자 결정(2026-06-20)으로 `allow`다. read는 ask 구현 전까지 `deny`로 둔다(read를 `allow`로 shortcut하지 않는다).

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

초기 shell integration domain event 어휘:

| event | 의미 | 저장/사용 |
| --- | --- | --- |
| `shell.cwd-changed` | shell이 현재 작업 디렉터리를 보고했다. | workspace metadata 갱신 후보. |
| `shell.prompt-start` | prompt 렌더링이 시작됐다. | command 경계 추정, prompt-aware UX 후보. |
| `shell.prompt-end` | prompt 입력 영역이 끝났다. | command 입력 영역 추정 후보. |
| `shell.command-start` | 사용자가 command 실행을 시작했다. | 최근 작업 세션 metadata 후보. |
| `shell.command-end` | command가 종료 상태와 함께 끝났다. | 알림, 최근 작업 세션 metadata 후보. |

이 event들은 shell hook이 출력한 raw escape bytes 자체가 아니다. parser/shell-integration layer가 해석한 domain event다. trace/replay에 이 event를 저장하는 PR은 먼저 [Facade 계약](facade-contracts.md)의 `Trace/Event` 절과 [Trace와 Replay](trace-replay.md)의 schema를 갱신해야 한다.

## Workspace Restore와 Command Restore

workspace restore는 live process를 저장하는 기능이 아니다. 저장하는 것은 다시 열기 위한 선언적 설명서다. 자세한 저장 모델은 [Workspace Restore 전략](workspace-restore.md)을 따른다.

v1 기본 정책:

- 복구한다: workspace, tab/split layout, surface cwd, safe env override, shell 시작 정보.
- 기본 자동 재실행하지 않는다: 마지막 foreground command, shell integration으로 관측한 command, 임의 shell string, destructive 가능 command.
- 사용자가 repo별 `startup_recipe`를 명시한 경우에만 실행 후보가 된다.
- command 실행은 `argv` 형태의 `startup_recipe`를 우선한다. shell string은 별도 UX와 경고가 필요하다.

자동 command restore는 구현 전에 다시 논의한다. 이 결정은 UX가 아니라 안전 문제다.

용어:

- `shell_entry`: pane을 다시 열 때 시작할 기본 shell argv다. 예: `["zsh", "-l"]`.
- `startup_recipe`: 사용자가 config로 명시한 재시작용 command다. 자동 실행 후보가 될 수 있지만 기본 confirm/allowlist 정책이 필요하다.
- `last_observed_command`: shell integration으로 관측한 마지막 command다. 최근 작업 표시에는 쓸 수 있지만 자동 재실행 대상은 아니다.

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
