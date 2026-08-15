# 설정 — 셸과 환경

셸을 띄우는 자리와 그 환경의 배경이다. `workspace.*` 시작 디렉터리, `term` terminfo 폴백, `env.<KEY>` 주입, `shell.command`/`shell.args`, `shell-integration.ssh` 라우팅을 적는다.

> 키 표와 파일 형식은 [설정(config) 파일](configuration.md)이 소유한다. 키별 배경은 [텍스트·테마](configuration-text.md) · [입력·키바인딩](configuration-input.md) · [셸·환경](configuration-shell.md)로 나뉜다.

> **이 문서의 서술은 POSIX 전제다** — `execve` 직접 실행, `login(1)` 래핑, `ZDOTDIR` zsh 통합, terminfo가 그렇다.
> Windows의 셸 결정(ConPTY·`PROMPT`/`prompt` 통합 주입·OSC 9;9·`SpawnRequest` 중립화)은
> [Windows 플랫폼](windows-platform.md)이 단일 출처다.

### 시작 디렉터리 (`workspace.*`)

새로 여는 셸이 어느 디렉터리에서 시작할지 정한다. **Ghostty의 `working-directory` +
`*-inherit-working-directory` 모델**을 그대로 따른다 — 고정 시작 경로 하나(`workspace.root`)에, surface
종류별 cwd 상속 토글(기본 켜짐)을 둔다.

**기본 동작(설정 없음)**: 새 워크스페이스 탭·새 Term·분할 모두 **직전 포커스 Term의 현재 cwd(OSC 7)를
상속**한다. 즉 `cd`로 옮긴 디렉터리에서 ⌘T/⌘⇧T/⌘D를 누르면 그 위치에서 새 셸이 시작한다(tmux·iTerm2·Ghostty
기본과 동일). 셸 통합이 없거나 첫 프롬프트 전이면 상속할 cwd가 없어 `workspace.root`로 폴백한다.

```conf
# 고정 시작 경로(Ghostty working-directory). 첫 창 + 상속이 꺼졌거나 상속할 cwd가 없을 때 쓴다.
workspace.root = ~/projects

# 상속 토글(기본 둘 다 true = 포커스 cwd 상속). false면 그 종류는 항상 root에서 연다.
workspace.tab-inherit-cwd   = true   # 새 워크스페이스 탭(⌘⇧T) + 새 Term(⌘T)
workspace.split-inherit-cwd = true   # 새 분할(⌘D, 팬)

```

- **`workspace.root`** — 고정 시작 디렉터리. **절대경로 또는 `~`/`~/…`만** 받는다 — 상대경로나 `~user`(다른
  사용자)는 설정 로드 시 무시하고 진단을 남긴다(다른 키처럼 forgiving — 잘못된 값이 조용히 무동작하지 않게).
  `~`·`~/…`는 $HOME으로 확장한다(셸을 거치지 않고 `execve`로 띄우므로 tilde 확장을 maru가 직접 한다; $HOME이
  비었거나 절대경로가 아니면 확장을 포기하고 폴백). 형식은 맞지만 **없는 디렉터리**면 자식 셸의 `chdir`이 실패해
  **$HOME으로 graceful 폴백**한다(세션 안 깨짐). 경로에 공백이 있어도 따옴표 없이 그대로 쓴다(값은 양끝 공백만
  다듬는다). **비어 있으면(기본)** maru를 띄운 cwd를 상속하되, 그 cwd가 `/`이면(`.app` 더블클릭·`open`·launchd로
  띄운 흔한 증상) **$HOME으로 올린다** — Ghostty가 launchd/`open` 실행을 `home`으로 보는 것과 같은 결(터미널에서
  `maru`로 띄우면 cwd가 `/`가 아니라 그대로 상속).

- **`workspace.tab-inherit-cwd`** — 새 워크스페이스 탭(`new_tab`)과 새 Term(`new_term`)의 cwd 상속 여부.
  `true`(기본)면 포커스 cwd 상속, `false`면 `root`. Term 탭은 워크스페이스 탭과 같은 '탭'이라 이 토글이 함께
  관할한다.

- **`workspace.split-inherit-cwd`** — 새 분할(`split_*`, 팬)의 cwd 상속 여부. `true`(기본)면 포커스 cwd
  상속, `false`면 `root`.

> **베이스/결정**: 동작·기본값·키 의미를 모두 **Ghostty**(`working-directory`,
> `window/tab/split-inherit-working-directory`, 모두 기본 `true`)에 맞췄다(레퍼런스는 동작만 비교, 코드
> 미참고). 새 split/탭이 현재 디렉터리를 물려받는 동작은 tmux `split-window`·iTerm2 새 split의 보편 관례이기도
> 하다. Ghostty의 `window-inherit-working-directory`(창 간 상속)는 maru에선 **두지 않는다** — 새 창은 별도
> 세션(AppSession)이라 직전 창의 포커스 cwd를 알 길이 없어 항상 `root`에서 연다(Ghostty도 "`working-directory`는
> 주로 첫 창에 쓰인다"고 한다). 새 Term(`new_term`)은 Ghostty에 없는 maru 고유(pane 내 가로 탭)라 가장 가까운
> '탭'으로 보고 `tab-inherit-cwd`에 묶었다.
>
> **퀵 터미널**(`toggle_quick_terminal`)도 `workspace.root`에서 연다 — 별도 세션(독립 `AppSession`)이라 메인 창의
> 포커스 cwd를 상속하지 않고 항상 고정 `root`(없으면 상속/home 폴백)를 쓴다. 이것도 Ghostty와 같다: Ghostty의
> 퀵 터미널은 부모 surface 없이 **fresh `SurfaceConfiguration`**으로 만들어져 전역 `working-directory`로 떨어지고
> 메인 창 cwd를 상속하지 않는다(`QuickTerminalController` — 메인 창/탭/split만 `ghostty_surface_inherited_config`로
> 상속). 즉 `workspace.root`를 정하면 퀵 터미널 시작 경로도 거기로 바뀐다.
>
> 워크스페이스 **복원**(이전 세션 재시작)은 이 값과 무관하다 — 저장된 surface별 cwd를 그대로 쓴다
> ([Workspace Restore 전략](workspace-restore.md)). `workspace.*`는 새로 여는 창/탭/분할에만 적용된다.

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

> **원격(SSH) 동작**: terminfo는 프로그램이 읽는 머신에 있어야 한다. 기본이 `xterm-maru`인데 maru의 `TERMINFO`는
> 로컬 env라 ssh가 안 따라가므로, 그대로 두면 항목 없는 원격에서 `vim`/`tmux`/`mux`/`less`가 커서·레이아웃이 깨진다
> (`unknown terminal type` 또는 커서가 엉뚱한 위치). **그래서 통합 zsh는 기본적으로** `ssh`를 가리는 함수로, `TERM`이
> `xterm-maru`일 때 **그 `ssh` 호출에 한해** `TERM=xterm-256color`(모든 원격이 가진 표준값)로 낮춰 넘긴다 — 평범한
> `ssh`가 그대로 안 깨진다(Ghostty `ssh-env`와 같은 결). 별도 설정 없이 동작하며, `TERM`을 직접 `xterm-256color` 등으로
> 바꿔 뒀으면 함수를 안 만들어 평범한 `ssh` 그대로다(graceful). **주의**: 이 보호는 **zsh 전용**이다(bash/fish는 셸 통합
> 미구현 — 그 셸을 쓰면 `term = "xterm-256color"`로 두거나 아래처럼 원격에 직접 설치한다).
>
> 원격에서도 `xterm-maru` 이점(Sync 등)을 **그대로 살리려면**(다운그레이드 대신 원격에 항목을 심으려면) **`maru ssh`** 를
> 쓴다 — 원격에 terminfo를 먼저 심고 평범한 `ssh`로 넘어간다. `shell-integration.ssh = true`면 통합 zsh가 평범한 `ssh`를
> 자동으로 `maru ssh`로 라우팅한다(기본 off, opt-in — 이게 켜지면 위 다운그레이드보다 우선한다):
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

### 환경변수 주입 (`env.<KEY>`)

새로 띄우는 셸에 줄 환경변수를 정한다. 여러 줄을 둘 수 있고, 각 줄의 `env.` 뒤가 변수 이름, `=` 뒤가 값이다.

```conf
env.EDITOR = nvim
env.LANG = en_US.UTF-8
env.MY_FLAG = a b c   # 값 내부 공백은 보존(양끝만 다듬는다), 빈 값(env.FOO =)도 허용
```

- **병합 정책**: 부모(maru를 띄운) 환경을 상속한 뒤, maru가 관리하는 변수(`TERM`/`COLORTERM`/`TERM_PROGRAM` 등)를
  덮어쓰고, **그 위에** 이 `env.*` 값을 upsert한다 — 같은 KEY가 이미 있으면 덮어쓰고 없으면 추가한다. 즉 `env.*`가
  일반 변수에는 우선한다(부모 상속을 끊지 않는 "부모 + 사용자" 모델 — Ghostty `env`와 같은 결).
- **내부 예약 키**: control-plane selector `MARU_PANE_ID`는 Term identity의 단일 출처라 `env.*` 적용 뒤 spawn
  request 값으로 최종 upsert한다. 이 키의 사용자 설정은 적용되지 않는다.
- **TERM은 `term` 키로**: `$TERM`은 `term =`이 단일 출처다. `env.TERM = ...`으로도 덮을 수 있으나(마지막 적용이라
  이김) terminfo 해석과 어긋날 수 있어 권장하지 않는다.
- 같은 일반 `env.KEY`를 여러 줄 쓰면 **나중 줄이 이긴다**(spawn 시 순서대로 upsert). 빈 KEY(`env. =`)는 무시(diagnostic).
- **적용 시점**: 새로 여는 셸(첫 창·새 탭/Term·분할)에만 적용된다. 런타임 **Reload Config**는 이미 떠 있는 셸의
  환경을 바꾸지 않는다(프로세스 env는 spawn 후 불변 — 이후 연 셸부터 반영).
- **베이스/결정**: 상속 + override 모델은 Ghostty `env`(부모 상속 위에 사용자 값 추가)를 베이스로 했다. 저장은
  값 보존이 기본이다(config 파일은 사용자 소유) — 민감값 마스킹은 GUI 표시·trace에만 적용한다([필수 프로젝트 규칙]
  redaction 기준, settings-page.md §8).

### 대화형 셸 (`shell.command` / `shell.args`)

기본적으로 maru는 `$MARU_INTERACTIVE_SHELL`→`$SHELL`→`/bin/sh` 순으로 셸을 정하고 `-i`로 띄운다. 이를
사용자가 바꿀 수 있다.

```conf
shell.command = /opt/homebrew/bin/fish
shell.args = -i -l    # 공백으로 토큰 분리(따옴표 미지원). 빈 값이면 인자 없음
```

- **`shell.command`** — 셸 실행 파일 경로. 비어 있으면(기본) 위 자동 결정. maru는 셸을 거치지 않고 `execve`로
  직접 띄우므로 **절대경로**여야 한다(PATH 탐색 없음). 없는 경로면 spawn이 실패한다.
- **`shell.args`** — argv(command 제외). 공백으로 토큰을 나눈다(`-i -l` → `["-i", "-l"]`). 따옴표·이스케이프는
  지원하지 않는다(셸 플래그는 보통 단순). 빈 값이면 인자 없이 띄운다. 미설정 시 기본 `-i`.
- **login 래퍼는 유지**: macOS는 셸을 `login(1)`로 감싸 전체 로그인 세션을 셋업하고(Terminal.app·Ghostty 동일),
  이 `command`/`args`가 그 안의 `exec -l <command> <args>`로 들어가 최종 로그인 셸이 된다. 즉 셸을 바꿔도 로그인
  셸 셋업(PATH·`.zprofile` 등)은 그대로 동작한다.
- **적용 시점**: 새로 여는 셸(첫 창·새 탭/Term·분할)에만. 런타임 Reload Config는 이미 떠 있는 셸을 안 바꾼다.
  퀵 터미널·controlled smoke(테스트용 `/bin/sh -c`)에는 영향 없다(대화형 셸에만 적용).
- **베이스/결정**: Ghostty `command`/`shell`(사용자 지정 셸 프로그램)에 대응한다. Ghostty의 `command`는 `/bin/sh -c`로
  한 문자열을 실행하지만, maru는 `execve` 직접 모델이라 **경로 + argv 토큰 배열**(셸-split 없음)로 둔다 — quoting
  모호성을 피하고 실패 원인을 줄인다.

### 셸 통합 ssh 라우팅 (`shell-integration.ssh`)

```
shell-integration.ssh = true    # 평범한 ssh를 maru ssh로 자동 라우팅 (기본 false)
```

이건 **다운그레이드 대신 원격에 항목을 심는 "업그레이드" 경로**다. 끄면(기본) 통합 zsh는 `TERM=xterm-maru`인 `ssh`를
`xterm-256color`로 **다운그레이드**해 원격이 안 깨지게만 한다(위 `term` 절의 "원격(SSH) 동작"). 켜면 그 다운그레이드 대신
**통합 zsh에서 평범한 `ssh`를 입력해도** maru가 그 호출을 `maru ssh`로 라우팅해 `xterm-maru`를 원격에 심는다 — 매번
`maru`를 앞에 붙이지 않아도 원격에서 xterm-maru 이점(Sync 등)을 그대로 쓴다.

> **동작**: maru가 자식 셸 env에 현재 실행 파일 경로(`MARU_BIN`)와 플래그(`MARU_SSH_INTEGRATION`)를
> 주입하고, Maru 통합 `.zshenv`가 이 둘이 모두 있을 때만 `ssh`를 `maru ssh`로 위임하는 함수를 정의한다(이게
> 기본 다운그레이드 함수보다 우선). 같은 maru 바이너리가 `maru ssh`를 처리하므로 `install-cli` 없이도 동작한다.
>
> **기본 off인 이유**(opt-in): 원격 terminfo 설치는 침습적이라 사용자 동의가 필요하다(Ghostty도 `ssh-*`를 기본
> off로 둔다). 끄면(기본)에도 위 다운그레이드로 원격이 안 깨지므로, 이 옵션은 "원격에서도 xterm-maru를 쓰고 싶을
> 때"만 켜면 된다.
>
> **범위/우회**: zsh 통합이 켜진 대화형 셸에서만 적용된다(통합이 없으면 함수가 정의되지 않는다). 한 번만
> 평범한 ssh로 가려면 `command ssh ...` 또는 `\ssh ...`. `maru ssh`와 동일하게 **대화형 세션용**이라
> `ssh host cmd`(원격 command)는 terminfo 설치를 건너뛰고 `xterm-256color`로 연결한다.
