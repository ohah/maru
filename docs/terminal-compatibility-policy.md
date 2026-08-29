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
TERMINFO=${XDG_CACHE_HOME:-~/.cache}/maru/terminfo   # embed 소스를 자동 컴파일한 위치(자식 셸에만 주입)
COLORTERM=truecolor
```

**전환의 핵심은 "로컬을 안 깨지게" 하는 것**이다. 단순히 기본 `TERM`을 `xterm-maru`로 바꾸면, 로컬
terminfo DB에 항목이 없는 사용자의 `vim`/`tmux`/`less`가 `unknown terminal type`으로 깨진다. 그래서
Ghostty와 같은 방식을 쓴다(`src/termio/Exec.zig` 동작 비교): terminfo 소스를 바이너리에 **embed**하고,
자식 셸을 띄울 때 maru 자기 캐시(`${XDG_CACHE_HOME:-~/.cache}/maru/terminfo` — 다른 maru 캐시와 같은 base)에
**자동 컴파일**(`tic`)해 `TERMINFO`를 거기로 가리킨다(`pty/macos.zig`의 `resolveTerm`). `~/.terminfo`나
시스템을 안 건드리는 **비침습** 방식이고,
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

**남는 위험은 원격(SSH)이다.** `TERMINFO`는 로컬 env라 ssh가 전달하지 않으므로, **평범한 `ssh`**로 `TERM=xterm-maru`를
항목 없는 원격에 보내면 mux/TUI가 자기 터미널 설명을 못 찾아 커서·레이아웃이 깨진다(2026-06-20 회귀로 실측 — ssh 너머
tmux/mux 선택 화면 커서가 엉뚱한 위치에 그려짐). 이걸 **기본값으로** 막는다 — 두 갈래(zsh 통합 한정. bash/fish는 셸
통합 자체가 미구현이라 아래 보호가 안 닿는다. 그쪽은 `term = "xterm-256color"`로 되돌리거나 원격에 직접 설치해야 한다):

1. **기본 다운그레이드(항상 켜짐, 권장)** — 통합 zsh가 `ssh`를 가리는 함수로, `TERM`이 maru 고유 `xterm-maru`일 때
   **그 `ssh` 호출에 한해** `TERM=xterm-256color`(모든 원격이 가진 표준값)로 낮춰 `command ssh`를 부른다. 원격이 깨지지
   않는다(Ghostty `ssh-env`와 같은 결). `TERM`이 이미 폴백/override로 `xterm-256color` 등이면 함수를 안 만들어 평범한
   `ssh`가 그대로 동작한다(graceful). xterm-maru의 이점(Sync 등)은 ssh 너머에선 포기하는 절충 — "안 깨짐"이 우선.
2. **opt-in 전파(`shell-integration.ssh = true`)** — 원격에서도 xterm-maru 이점을 살리려면 켠다. 통합 zsh가 `ssh`를
   `maru ssh`로 라우팅해 원격에 terminfo를 심고 exec한다(env `MARU_BIN`/`MARU_SSH_INTEGRATION` 주입 시에만 — graceful;
   설치 실패 시 `maru ssh`가 `xterm-256color` 폴백). 기본 off인 건 원격 설치가 침습적이라 동의가 필요해서다. 이 토글이
   켜지면 (1)의 다운그레이드보다 우선해 라우팅이 이긴다. 직접 `maru ssh <host>`를 입력해도 같다.

설정은 [설정 파일](configuration.md)의 `term`·`shell-integration.ssh` 절. (Ghostty는 `xterm-ghostty`가 upstream
terminfo DB에 병합돼 원격이 대체로 이미 갖고 있고 `ssh-env`/`ssh-terminfo`도 제공한다 — 동작 비교. maru `xterm-maru`는
신규라 원격에 없으므로 기본 다운그레이드가 더 중요하다.)

### 런처 색-강제 override 제거 (`CLICOLOR_FORCE` / `FORCE_COLOR`)

Maru는 자식 셸 env에서 부모 `TERM`/`COLORTERM`을 위 값으로 덮을 뿐 아니라, 런처(빌드 도구·CI·부모 셸)가 남긴 **색-강제 override**(`CLICOLOR_FORCE`, `FORCE_COLOR`)도 **제거**한다. Maru가 터미널이므로 색 capability는 `COLORTERM`/`TERM`으로만 알린다 — 이 force 변수는 그 신호를 덮어써 잘못된 색 레벨을 강제한다.

근거(실측): `zig build`로 Maru를 띄우면 빌드 컨텍스트의 `CLICOLOR_FORCE=1`이 상속돼 자식 셸로 전파됐다. Rust `supports-color`(codex 등이 사용)는 `env_force_color`로 `CLICOLOR_FORCE!=0`·`FORCE_COLOR`을 **가장 먼저** 평가해 색 레벨을 강제(보통 basic 16색)하므로 `COLORTERM=truecolor`를 무시한다 → codex가 truecolor를 못 보고 입력창 회색 컴포저(pill 배경)를 끈다. GUI(Finder) 실행 시엔 이 변수가 없어 정상이라, 개발 중 `zig build`로 띄울 때만 나타나는 함정이었다. `NO_COLOR`/`CLICOLOR`는 사용자 의도(색 끄기 선호)일 수 있어 건드리지 않는다.

### 데스크톱 알림 식별 (`TERM_PROGRAM=ghostty`)

Maru는 자식 셸 env에 `TERM_PROGRAM=ghostty`를 주입한다(부모가 남긴 `TERM_PROGRAM`/`TERM_PROGRAM_VERSION`은 제거 후 덮어쓴다). Claude Code·Codex 같은 TUI는 데스크톱 알림을 보낼 터미널을 `TERM_PROGRAM` 화이트리스트(`iTerm.app`/`ghostty`/`kitty`/`WezTerm`)로 식별하는데, Maru는 그 명단에 없어 기본값에선 OSC 9 알림을 못 받기 때문이다(Claude의 `preferredNotifChannel`은 환경변수로 못 바꿔 우회 불가). `ghostty`를 고른 건 Maru가 kitty graphics·OSC 9/133/777을 Ghostty와 같은 셋으로 지원해, 식별 후 기대되는 기능과 어긋나지 않아서다(`iTerm.app`은 inline-image OSC 1337을 기대해 부적합).

**⚠️ 이 식별값은 ssh 를 못 건넌다**(2026-08-29 실측). ssh 가 전달하는 환경변수는 `TERM` 뿐이라 원격 셸에는
`TERM_PROGRAM` 이 없고, 그래서 **원격에서 도는 claude/codex 는 알림을 하나도 못 보낸다** — 화이트리스트
판정이 `no_method_available` 로 떨어지기 때문이다. 위 «환경변수로 못 바꿔 우회 불가» 는 그 자리에서도
그대로지만, **설정 파일로는 바꿀 수 있다**: 원격 provider 설정에 채널을 명시하면 된다(계약과 값은
[agent-hooks.md](agent-hooks.md) §11).

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
osc52.read  = deny    # 클립보드 탈취 방지 — 기본값에서는 `?` 쿼리에 응답이 나가지 않는다
osc52.write = allow   # 로컬 데스크톱 단일 사용자 — 트래킹 앱의 드래그 복사를 시스템 클립보드에 반영
```

정책:

- read는 정식 config 키 `osc52.read`(`deny`|`allow`, 기본 `deny`)로 구현됐다(`config/theme.zig`, 세팅 GUI 포함). `ask`까지 세 값을 지원할 수 있게 설계한다(`ask`는 후속).
- write 기본 `allow`: 로컬 단일 사용자 데스크톱 터미널이라 편의를 택했다(iTerm2/Ghostty도 유사). 트래킹 앱
  (예: Claude Code)의 드래그 복사가 그대로 시스템 클립보드에 반영된다.
- read 기본 `deny`: 원격/내부 프로그램이 로컬 clipboard를 탈취하지 못하게 한다. core는 `?` 쿼리를 버리는 게 아니라
  read 대상(target)과 `clipboard_read_pending`만 기억하고, 응답 생성은 platform이 정책을 보고 결정한다 —
  `osc52.read = allow`일 때만 클립보드를 읽어 응답하고, `deny`면 응답이 나가지 않는다.
- ask(요청별 확인 UI)는 후속 작업이다. 구현되면 write 기본을 `ask`로 올릴지 다시 논의한다.
- clipboard 요청은 trace fixture에 원문을 저장하지 않는다. 필요하면 redaction된 event만 남긴다.
- 크기 상한: 디코드 결과 16MB(`osc.max_clipboard_bytes`), 파서 수집도 그 base64(4/3×)가 통과하게
  `parser.max_osc_bytes`를 여기서 파생한다. **OSC 52만** 이 대용량 수집을 허용하고 다른 OSC(title/cwd/
  OSC 8 URI 등)는 기존 2048B 방어선(`max_osc_small_bytes`)을 유지한다 — 한 문단(원문 ~1.5KB)만 돼도
  base64가 2KB를 넘어, 고정 2048 버퍼 시절 ssh+tmux/nvim 원격 복사가 조용히 통째로 버려졌다.
  이 상한은 **홍수 방어선이지 목표가 아니며**, 파일 업로드 상한(`cli/ssh.zig max_upload_bytes`)과는 별개
  상수다(우연히 둘 다 ~16MB일 뿐). 텍스트 클립보드 전용으로 더 낮출지는 정책 결정으로 열려 있다.
- 상한 초과는 **우아하게 표면화**한다(무음 폐기 금지). 크기 상한을 넘어 거부된 OSC 52 쓰기는
  `TerminalCore.clipboard_write_rejected`(1회성)를 세우고, app이 매 tick `takeClipboardWriteRejected`로
  drain해 notice 토스트("클립보드 복사가 너무 커서 취소되었습니다")로 알린다 — 사용자가 "왜 복사가 안 됐는지"
  알게 한다(값싼 UX 우위: Ghostty·xterm은 상한 초과를 조용히 버린다). 불청 이벤트라 인터랙티브 모달
  (`anyModalOverlayOpen`)이 열려 있으면 억제해 사용자를 끊지 않는다(정보는 비필수라 유실 무해).

요청 흐름(poll/drain 모델 — 별도 이벤트 큐 없이 코어가 pending 상태를 들고 platform이 tick마다 회수한다):

```text
PTY output
-> TerminalCore parses OSC52
-> TerminalCore가 pending 상태를 남긴다
   (write: pendingClipboardWrite, read: clipboard_read_pending + target)
-> platform이 매 tick ABI로 drain (pending_clipboard / take_clipboard_read_request)
-> app/platform이 정책 적용 (write=allow 즉시 반영, read는 osc52.read=allow일 때만; 요청별 ask UI는 후속)
-> 완료 (write: OS pasteboard 반영, read: allow면 base64 응답을 PTY 입력 경로로 회신)
```

중요한 경계:

- `TerminalCore`는 macOS pasteboard나 system clipboard API를 직접 호출하지 않는다.
- 코어는 pending 상태 보관까지만 하고, 정책 판정·drain 주기는 app/platform이 소유한다. read 응답 바이트는 `SurfaceRuntime`의 PTY 입력 경로(비차단 write)를 재사용해 PTY로 돌아간다.
- app/platform layer만 사용자 확인 UI와 실제 clipboard read/write를 안다.
- write는 사용자 결정(2026-06-20)으로 `allow`다. read는 ask 구현 전까지 `deny`로 둔다(read를 `allow`로 shortcut하지 않는다).

### 장기 방향(북극성) — 스트리밍 싱크

현재 모델은 **평평한 수집 + 접두 라우팅**이다: `osc_buffer`에 본문을 다 모으고 dispatch 시점에 `"52;"` 접두로
가른다. 대용량 OSC가 **52 하나뿐인 지금은 이게 가장 단순해서 정답**이고(추가 리팩터링은 조기 최적화), Ghostty와
같은 구조에 상한·반납·가시적 실패로 오히려 앞선다(Ghostty는 상한 없음·무음 폐기). 다만 대용량 OSC가 **2~3개로
늘면**(예: OSC 5522 kitty 클립보드) 이 모델이 나빠진다 — "어떤 OSC가 커질 수 있나"(`oscMayGrow` 허용 목록)와
"어떻게 처리하나"(`dispatchOsc` 라우팅)가 두 곳으로 갈려 동기화 부담이 생긴다.

그때 향할 **더 나은 모델**(Ghostty를 넘어서는 지점):

1. **번호-인식 파서**(Ghostty에서 채택) — OSC 번호를 상태로 먼저 인식해 `;` 순간에 버퍼 정책을 한 번에 정한다
   (접두 soup 제거). "OSC N 인식"과 "N의 버퍼 정책"이 한 곳에 모인다.
2. **스트리밍 싱크**(Ghostty를 넘어섬) — 대용량 페이로드를 통째로 모으지 않고 도착하는 대로 디코드해 상한 있는
   타깃에 흘린다. 상한을 스트림 중간에 강제(조기 거부·피크=디코드 크기만). Ghostty의 "모았다가 디코드"보다 낫다.
3. **우아한 가시적 상한**(이미 구현 — 위 참조) — 무음 폐기 대신 notice.

이 토대 위에서 kitty 5522(태생이 청크)는 거의 공짜로 따라온다. **트리거는 "OSC 66/5522(또는 대용량 데이터)를
착수할 때"**이고, 그땐 평평한 모델에 덧대지 말고 이 스트리밍 토대로 짓는다(단일 트리거 — 66 렌더러 작업이 파서
번호-인식 전환을 정당화). 단, **UX 관점에선 이 리팩터링 대부분이 사용자에게 안 보인다**(피크 메모리·파서 내부는
불가시). 사용자에게 실제로 나은 건 위 "가시적 상한" 하나뿐이므로, 이 토대는 **유지보수·미래 대비**로 정당화하지
UX 명분으로 팔지 않는다. 로드맵 항목은 [터미널 입력과 VT 프로토콜 구현 이력](plans/terminal-input-and-protocols.md) "OSC 66/5522"를 단일 출처로 둔다.

## Bracketed Paste

bracketed paste는 paste 시작과 끝을 shell/program에 알려주는 기능이다. 이 기능이 있으면 `vim`, shell, REPL이 사용자가 타이핑한 텍스트와 붙여넣은 텍스트를 구분할 수 있다.

v1 기본값(config 키는 `input.` 네임스페이스):

```text
bracketed_paste          = true    # DECSET 2004 — 프로그램이 켬(터미널 설정 아님)
input.paste-protection   = true    # 위험한 붙여넣기 확인
input.bracketed-paste-is-safe = true
```

정책:

- bracketed paste mode `2004`는 v1 필수 호환성으로 본다.
- newline이 포함된 일반 paste는 unsafe 후보로 보고 사용자 확인을 요구한다.
- bracketed paste는 기본적으로 safe로 보되, 사용자가 더 엄격한 정책으로 바꿀 수 있게 한다.

현황(2026-07): **구현 완료**. 두 겹으로 막는다(Ghostty `clipboard-paste-protection`/`-bracketed-safe` 동형).

- (1) **바이트 sanitize(항상)**: `terminal/input_report.zig`의 `encodePaste`가 개행을 CR로 정규화하고,
  mode 2004면 `ESC[200~…ESC[201~`로 감싸며, 위험 제어 바이트(NUL·BS·ENQ·EOT·ESC·DEL + VINTR/VSUSP 등
  라인 규율 제어키 — xterm/Ghostty strip 목록)를 공백으로 치환한다. 특히 ESC 제거가 본문에 심은 `ESC[201~`
  조기 종료 인젝션을 무력화한다. 이 sanitize는 설정과 무관하게 항상 적용된다.
- (2) **확인 게이트(`input.paste-protection`)**: `core.pasteNeedsConfirmation`(단일 출처)이 붙여넣기가
  위험한지 판정하고, 위험하면 platform(`app_session.submitPaste`)이 PTY로 보내지 않고 **붙여넣을 내용을
  미리보기로 함께 보여주는 확인 모달**(Ghostty식 — 앞 몇 줄 + "…N줄 더" 요약, `buildPastePreview`)을 띄운다
  — 사용자가 숨은 명령을 눈으로 확인하고 [붙여넣기]/[취소]를 고른다. 판정 규칙: bracketed paste면 (a) 본문에 `ESC[201~`가 있으면
  bracketed여도 **항상** 확인, (b) 아니고 `input.bracketed-paste-is-safe`가 true면 확인 생략(괄호가 감싸
  자동 실행 안 됨); 비-bracketed면 개행(`\n`/`\r`) 유무로 확인. IME 확정·OSC 52 응답·키 타이핑은 이 경로를
  타지 않아 영향받지 않는다. config·동작 세부는 [configuration.md](configuration.md) `input.paste-protection`.

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
- **터미널 텍스트의 파일 경로/URL 링크 열기**(수식키+클릭)는 filesystem capability에 해당한다. 명시 제스처에서만 동작하며, **휴리스틱 파일 경로**는 존재를 확인한 경로만 `NSWorkspace.open`(기본 앱으로 열기)으로 연다(셸 명령 자동 실행과 무관). 다만 `file://` URI·OSC 8 명시 링크·`.app`은 `NSWorkspace`의 표준 동작상 앱이 실행될 수 있다(Finder/Ghostty/iTerm2와 동일 — 사용자 명시 클릭 한정, 권한 상승 없음). 자세히는 [링크 감지](link-detection.md).

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

배포·서명·공증·업데이트(update feed) 전략은 [배포·업데이트 전략](distribution.md)을 단일 출처로 둔다.

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
