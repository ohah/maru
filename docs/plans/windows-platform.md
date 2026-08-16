# Windows 플랫폼 구현 계획

계약은 [Windows 플랫폼](../windows-platform.md)이 단일 출처다. 이 문서는 **진행 상태**만 소유한다.

## 배경

중립 레이어(L1~L3)는 이미 Windows 호스트에서 컴파일되고 테스트가 **exit 0으로** 돈다(수치는
[layering-and-portability.md](../layering-and-portability.md) §4.1의 실측 기록이 단일 출처다 — 여기서
복제하지 않는다). 빠진 것은 L4 전부다: ConPTY 백엔드 0줄, Win32 호스트 0줄, 렌더러 0줄.

순서의 기준은 [초기 세로 슬라이스](../initial-vertical-slice.md)가 macOS에서 쓴 것과 같다 —
**GUI 전에 헤드리스 경로를 먼저 증명한다.** W1~W5가 전부 헤드리스라 창·GPU 결정과 독립적으로 진행되고,
그 사이에 남은 결정(백엔드·웹뷰 합성)이 익는다.

## 슬라이스

| | 내용 | 상태 |
|---|---|---|
| W0 | 계약 문서(`windows-platform.md`) + 이 계획. 코드 0 | 완료 |
| W1 | **OSC 9;9 cwd** — `dispatchNotify9`에 `9;` 갈래를 더한다. **9;9은 host를 건드리지 않는다**(계약 §3.2a의 C — 최소 메커니즘은 정해졌다). L1이라 Windows와 독립이고 헤드리스로 검증된다. 잔여 위험은 §3.2a "받아들인 위험"으로 수용 확정 | 완료 |
| W1.5 | **절대경로 판정을 `[0]=='/'`에서 떼어낸다** — 새 최상위 유틸 `src/path_shape.zig`가 술어 둘을 낸다. **가드**(`isAbsolute`, OS 무관 거부): `normalizeAssetPath`·`repo_path`·`git_write_command`·`pathWithin`·`validateName`/`validBasename`. **감지**(`isDetectableAbsoluteFor`, OS를 **인자로**): `terminal/selection.zig`. 왜 갈리는지와 실측은 계약 §5.1. 계약 §5의 순서 제약상 **경로 정규화 도입보다 먼저** 해야 한다 | 완료 |
| W5.5 | **Windows 상대 경로 링크 감지** — `filePathSpan`의 `home_path`·`dot_relative`·`bare_relative` 세 갈래도 `\`를 받게 한다(`.\x`·`..\x`·`src\x`·`~\x`). 절대 갈래만 고친 W1.5의 후속이고 **더 흔한 형태**다. 선행 작업은 오탐 실측 — `bare_relative`의 억제 규칙이 이스케이프 출력(`\n`·`\t`)과 충돌하는지 먼저 잰다(계약 §5.2 ⒜) | 미착수 |
| W2 | **`main.zig` Windows 컴파일·실행** — 실제로 링크를 막던 심볼은 셋(`socket`·`environ`·`symlink`)이었다. 전부 **호스트 게이트**(`hostGateReason(os_tag, feature)`)로 접는다: 컨트롤 소켓 → "인스턴스 없음"(계약 §8), `maru ssh` → W9 안내, `install-cli` → W10 안내. `publishBrowserResult`의 `fromMode(0o600)`은 Windows에 `Permissions.fromMode`가 없어 **`error.UnsupportedOnWindows`로 명시 차단**한다 — `.default_file`로 조용히 넘기면 ACL 결정(계약 §8)을 잊은 채 넓은 권한으로 쓰이기 때문이다. 게이트가 comptime이라 POSIX 본문이 의미 분석되지 않는 것이 링크를 뚫는 원리다. `src/main.zig` 테스트를 **모든 호스트**에서 걸도록 `build.zig` 게이트를 뗐다. 적대적 검증 후속: PTY 없는 호스트에서 `demo`·`app-pty-*`가 19줄 스택 트레이스를 뱉던 것을 `error.UnsupportedPlatform`을 잡아 2줄 안내로 바꾸고(`error.UnknownCommand` 선례와 같은 자리), bare `maru`가 `pty.backend_available`을 보고 미리 알리게 했다 | 완료 |
| W2.5 | **Windows 기본 셸 + config OS 분기** — `resolveInteractiveShellFor(kind)`가 OS 갈래를 갖는다(`MARU_INTERACTIVE_SHELL` → pwsh 7 → 5.1 → `%COMSPEC%` → cmd; 계약 §3.1a). 후보 목록은 **OS와 `%COMSPEC%`을 인자로 받는 순수 함수**라 테스트가 두 갈래를 모두 돈다. config에 **일반 OS 접미 메커니즘**(`shell.command.windows`·`font.size.macos` — 아무 키에나)과 **`shell.windows-shell`**(`powershell` 또는 `cmd` — 종류 선택)을 넣었다. 이로써 계약 §8의 "셸 설정의 OS 분기"가 닫혔다. **config 값을 실제 spawn에 배선하는 것은 W7**(Windows 호스트) — 지금은 `main.zig`가 config를 읽지 않는다 | 완료 |
| W3 | **`SpawnRequest` 중립화 + 입구 경로 정규화** — `zdotdir` → `shell_integration_dir`로 일반화하고 `login`은 의도로·`term`은 백엔드 위임으로 재문서화한다. `command`+`args`는 **그대로**. **wire 키 `"zdotdir"`는 불변** — 직렬화가 익명 구조체 리터럴이라 **그 리터럴의 필드 이름이 곧 JSON 키**이고, 한 줄 안에서 왼쪽(wire)과 오른쪽(Zig 필드)이 갈린다(계약 §4.2). 정규화는 `path_shape.normalizeSeparatorsFor(os_tag, …)`를 `$HOME`·`$XDG_CACHE_HOME` 입구에 건다 — 실측으로 terminfo 캐시 경로의 혼합 구분자가 사라진다. POSIX에선 무동작이라 macOS 동작 변화 0. **`trace anonymize`의 `$HOME`은 정규화하지 않는다** — 그것은 트레이스에서 홈 경로를 지우는 매칭 키라, 바꾸면 native 경로와 안 맞아 오히려 덜 지워진다 | 완료 |
| W4 | **ConPTY 백엔드** — `src/pty/windows.zig`. 필수 13 표면. 파이프는 `CreatePipe`가 아니라 **overlapped named pipe**(계약 §4.1). OS 무관한 조립 규칙은 `src/pty/windows_spawn.zig`로 갈라 **모든 타깃에서** 테스트가 돌게 했다. 계약이 W4에 남긴 두 결정을 실측으로 닫았다 — **쓰기 의미론**은 ①(미결 write 한 건)+스테이징 버퍼(§4.1), **EOF·종료**는 "배수한 뒤에 닫는다"와 "`ClosePseudoConsole`은 분리 스레드"(§4.1b). 자식 트리 종료는 job(`KILL_ON_JOB_CLOSE`) | 완료 |
| W5 | **셸 통합 주입** — cmd `PROMPT`, PowerShell `prompt` 오버라이드(계약 §3.3). 사용자 프롬프트 보존 | 미착수 |
| W6 | **헤드리스 세로 슬라이스** — `zig build demo`가 Windows에서 산출물을 낸다. 여기까지가 아키텍처 증명. **W4에서 함께 닫았다**: 백엔드를 켜는 순간 데모·스모크 fixture가 `/bin/sh`에 걸려 W2가 없앤 스택 트레이스가 되살아났으므로, 그 자리를 남겨 둘 수 없었다. fixture 명령의 OS 갈래는 `src/app/fixture_script.zig`가 단일 출처이고 **OS를 인자로** 받아 두 갈래가 모든 타깃에서 테스트된다. `demo`·`app-pty-smoke`·`app-pty-loop-smoke`·`app-pty-interactive-loop-smoke`(pwsh 7) 넷 다 Windows에서 산출물을 낸다(계약 §6) | 완료 |
| W7 | **Win32 호스트 + 렌더 백엔드** — 창·입력·IME·클립보드. **선행 결정 2건**(GPU 백엔드, 웹뷰 합성 모델)이 계약 §8에 있다. 파일 트리 백엔드를 이식할 때 **루트 스트라이핑 두 곳**(`parent_path[root.len + 1 ..]`)을 `endsWithSep`로 함께 고친다 — 루트가 `/`나 `C:/`면 첫 세그먼트가 잘린다(계약 §5.2 ⒝, 이 커밋 이전부터 있던 버그) **config에서 온 경로를 정규화하는 자리도 여기서 정한다** — 로더가 파싱하며 할지 소비처마다 할지가 결정 사항이고, 지금은 `workspace.root = C:\proj` 같은 값이 역슬래시를 단 채 통과한다(계약 §5의 알려진 공백) | 미착수 |
| W8 | **ADE 표면** — 파일 패널·에디터·소스 컨트롤·에이전트 도크. 웹 패널은 WebView2 + DirectComposition | 미착수 |
| W8.5 | **Windows의 홈·캐시 위치** — `src/main.zig`가 다섯 자리에서 `$HOME`를 요구한다(terminfo 캐시, 컨트롤 소켓 디렉터리, ssh control path, install 경로, 사용자 이름). Windows는 `HOME`을 안 주고 `USERPROFILE`을 쓰므로 **cmd.exe에서는 `maru terminfo`가 항상 실패한다**(실측 — graceful 안내로 끝나지만 기능이 죽는다. git-bash는 `HOME`을 넣어 줘서 가려져 있었다). **선행 결정**: 폴백을 `USERPROFILE`로 둘지, 캐시를 Windows 관례대로 `%LOCALAPPDATA%`에 둘지(그러면 `cli.sessions.controlDir`·`cli.install`의 순수 경로 계약도 함께 바뀐다) | 미착수 |
| W9 | **`maru ssh` Windows 지원** — W2가 미지원 안내로 접어 둔 것을 되살린다. 지금은 `/bin/sh -c <래퍼 스크립트>`를 execve하는데 Windows엔 `/bin/sh`도 `environ`도 없다. **선행 결정**(계약 §3.5a에 없다): 래퍼 스크립트를 ⑴ `ssh.exe` 직접 exec로 대체하고 terminfo bootstrap을 포기할지 ⑵ Git for Windows의 `sh.exe`를 탐지해 쓸지(외부 의존) ⑶ PowerShell로 재작성할지. Windows 내장 OpenSSH **클라이언트**는 있다(§6 실측 — `sshd` 서버는 기본 Stopped) | 미착수 |
| W10 | **`maru install-cli` Windows 지원** — 마찬가지로 W2가 접어 뒀다. 지금은 `~/.local/bin/maru`에 symlink를 거는데 Windows엔 그 관례가 없고 `symlink` 심볼도 msvcrt에 없다. **선행 결정 3건**: 설치 위치(`%LOCALAPPDATA%\Programs`?), shim 방식(symlink는 개발자 모드·관리자 권한 필요 → `.cmd` shim이 단순), PATH 등록(안내만 vs 레지스트리 수정) | 미착수 |
| 후속 | **영속 세션 호스트** — named pipe 기반 재설계. 계약 범위 밖 | 미착수 |

## 검증

- W1~W6은 전부 헤드리스라 `zig build test`·`check-boundaries`가 그물이다. Windows 호스트에서 이미 초록이므로
  회귀가 보인다.
- W4의 선행조건은 **해제됐다**(2026-08-16). ConPTY 자식 attach를 이 환경에서 실측으로 닫았다 — 자식 안의
  `mode con`이 넘긴 COORD를 그대로 보고했고, 대화형 왕복·resize·pwsh·"부모에 콘솔 있음"까지 확인했다.
  이전에 "샌드박스 탓"으로 적었던 것은 오판이었고 원인은 우리 spawn 절차였다(계약 §4.1a·§6).
- **W4 백엔드는 `zig build test`가 진짜 자식을 띄워 검증한다** — 크기 일치(attach의 유일한 증거), 대화형
  왕복 2회, resize, 종료 코드 수거, close. 마커 왕복만으로는 부족하다: 자식이 pty에 안 붙어도 마커는
  어딘가로 나오기 때문에, **자식이 본 콘솔 크기 == spawn에 준 크기**가 판정식이다(계약 §6).
- 이 테스트들은 Windows 호스트에서만 컴파일된다. OS 무관한 규칙(커맨드라인 인용·환경 블록·fixture 명령)은
  전부 **OS를 인자로 받는 순수 함수**로 갈라 두어 macOS·Linux CI에서도 두 갈래가 돈다.
- W7 이후의 시각 검증은 macOS와 같은 골든 이미지 경로를 쓰되, Windows는 **WARP 소프트웨어 래스터라이저**가
  있어 GPU 없는 CI 러너에서도 렌더 스모크를 돌릴 여지가 있다(macOS는 실제 window server가 필요해 못 한다).
