# Windows 플랫폼

Windows에서 maru를 띄우기 위한 계약의 단일 출처다. 레이어 경계는 [레이어링과 이식성](layering-and-portability.md),
PTY 계약은 [PTY 운영 모델](pty-operating-model.md), 셸 설정 키는 [셸과 환경](configuration-shell.md),
cwd 축의 2단 모델은 [소스 컨트롤 도크](editor-surface-dock.md) §3.5를 단일 출처로 둔다. 단계 진행은
[구현 계획](plans/windows-platform.md)이 소유한다(이 문서는 상태를 쓰지 않는다).

## 1. 확정 결정

- **Windows는 지원 대상이다.** macOS가 여전히 주 타깃이고, Windows는 그 다음이다.
- **어디서 작업하는지는 슬라이스에 따라 다르다.** 중립 레이어를 정리하는 앞 슬라이스(`SpawnRequest` 중립화,
  `main.zig` 컴파일)는 **`main`에서** 한다 — 이미 Windows 호스트에서 중립 테스트가 초록이라
  ([layering-and-portability.md](layering-and-portability.md) §4.1) 회귀가 보이고, 그 정리는 **Windows와
  무관하게 가치가 있다**(예: `zdotdir` 일반화는 zsh 전용 형태 때문에 막혀 있던 **fish** 통합을 푼다 —
  [configuration.md](configuration.md)가 "fish는 vendor `conf.d`로 깔끔히 주입할 수 있으나"라고 진단해 뒀다.
  **bash는 별개다** — 거기서 막힌 것은 필드 모양이 아니라 `login=true`로 띄워 `--rcfile`이 무시되는 것이라
  `login` 쪽 결정이 필요하다). L4를 통째로 새로 만드는 뒤 슬라이스(ConPTY·
  Win32 host)를 브랜치로 뺄지는 **그 시점에 판단한다** — 모바일이 브랜치로 간 것과 같은 성격이다.
- **네이티브 Windows 셸이 1급이다.** WSL만 지원하는 것은 답이 아니다. PowerShell과 cmd에서도 동작해야 한다.
- **셸 통합은 비공개 API 없이 한다.** 자식 프로세스 환경에 통합을 주입하는 방식이며, 레지스트리·`AutoRun`·
  관리자 권한을 쓰지 않는다(§3).
- **GPU 백엔드는 이 문서가 정하지 않는다.** 4단계(창·렌더)에 가서 웹뷰 합성 모델과 **함께** 정한다 —
  둘이 사실상 같은 결정이기 때문이다([layering-and-portability.md](layering-and-portability.md) §4).
- **영속 세션 호스트는 범위 밖이다.** unix domain socket·fd 상속·동일 PID exec migration에 직결돼 있어
  Windows에서는 named pipe 기반 재설계가 선행이다. 별도 이니셔티브로 둔다.

## 2. 폴더 구조

```text
src/pty/
  windows.zig          ConPTY 백엔드 — session.zig의 PtySession 계약을 구현
src/platform/windows/
  (4단계에서) Win32 host — 창·입력·IME·클립보드
```

`src/pty/session.zig`가 이미 자리를 비워 두고 있다 — `PtySession`은 `builtin.os.tag` switch이고,
`UnsupportedPtySession`이 백엔드가 지켜야 할 표면을 시그니처로 들고 있다. Windows 백엔드는 그 switch에
`.windows` 갈래를 더한다.

**호스트에 제2 언어를 두지 않는다.** macOS가 Swift를 쓰는 이유는 AppKit이 Objective-C/Swift 전용이기
때문이고, 그래서 `app_host_abi.zig`(212개 `export fn`)라는 C ABI 경계가 필요했다. **Win32는 C API라 Zig가
직접 부른다** — 언어 경계도, 그 경계를 넘기는 marshaling 레이어도 필요 없다. 두 L4의 모양이 달라지지만
L4는 정의상 타깃별 신규다. **ABI는 이식 이음매가 아니다** — 이음매는 renderer 중립 계약이다.

## 3. 셸과 셸 통합

### 3.1 셸 티어

| 셸 | cwd | 프롬프트 마크 | 비고 |
|---|---|---|---|
| **PowerShell** (pwsh 7 / Windows PowerShell 5.1) | ✅ | ✅ (exit code 포함) | 네이티브 기본 |
| **cmd** | ✅ | 부분 — **exit code 불가** | §3.4 |
| **WSL** | ✅ | ✅ | 기존 zsh/bash 통합을 그대로 쓴다. ConPTY 입장에선 `wsl.exe`도 그냥 자식이다 |
| git-bash · nu 등 | 통합 없으면 2단(§3.3)에 의존 | — | 뜨긴 뜬다 |

### 3.2 cwd 보고 — Windows의 사실상 표준은 OSC 9;9다

**네이티브 Windows 셸에는 OSC 7이 아니라 `OSC 9 ; 9 ; <경로> ST`를 쓴다.** ConEmu가 정의하고 Windows
Terminal이 채택했으며, Microsoft가 셸 통합 문서에서 cmd·PowerShell용으로 직접 안내하는 형태다.

```text
OSC 7     ESC ] 7 ; file:///C:\Users\...  ESC \     URI인데 구분자가 백슬래시 — 어색하다
OSC 9;9   ESC ] 9 ; 9 ; C:\Users\...      ESC \     네이티브 경로를 그대로 나른다
```

OSC 7은 `file://` URI를 요구하는데 Windows 경로를 URI에 넣으면 구분자·드라이브 문자가 어색해진다. OSC 9;9는
설계상 네이티브 경로를 나르므로 그 모호성이 없다. **둘 다 지원한다** — WSL·유닉스 셸은 OSC 7, 네이티브
Windows 셸은 OSC 9;9다.

**미해결 — OSC 9;9엔 authority가 없다.** OSC 7은 `file://<host>/<path>`라 **host를 함께 나르고**, maru는 그
host로 로컬/원격을 가른다(`dispatchCwd`가 `(host, path)`를 **원자적 쌍**으로 저장하고, 코드 주석이 *"host
확보에 실패했는데 path만 새 값으로 바꾸면 새 경로에 옛 host가 붙어 짝이 어긋난다"* 고 경고한다). **OSC 9;9엔
그 필드가 없다.** 무조건 로컬로 접으면 원격 셸이 보낸 9;9이 로컬 경로로 보이고, 이는 OSC 7 경로가 막으려던
것과 같은 계열의 오표시다. 셋 중 하나를 정해야 하며 **아직 정하지 않았다**(§8):

1. 9;9은 항상 로컬로 본다 — 원격에서 9;9을 보내는 셸이 실제로 있는지 먼저 재야 한다
2. 알려진 원격 세션(OSC 5379 등)에서는 9;9을 무시한다
3. 9;9을 받은 Term의 host를 "미상"으로 두고 소비자가 그걸 로컬로 가정하지 않게 한다

> **코어가 이미 절반 알고 있다.** `src/terminal/osc.zig`의 `dispatchNotify9`는 OSC 9를 iTerm2 알림으로
> 처리하면서 ConEmu 서브커맨드(`<숫자>;…`)를 알림 오발사 방지용으로 **소비만** 한다. 주석이 `9;9`(cwd)를
> 이름으로 나열하고 `9;4`(progress)는 실제로 `agent_progress`에 보관하는데, **`9;9`만 분기가 없어 조용히
> 버려진다.** 이 계약은 `4;` 옆에 `9;` 갈래를 더해 기존 cwd 경로로 넘기는 것을 뜻한다. 이는 L1 터미널 코어
> 변경이라 **Windows와 독립적**이다 — ConEmu 시퀀스를 쓰는 프로그램은 macOS·WSL에도 있다.

### 3.3 통합 주입 — 환경변수로 한다

macOS가 zsh 통합을 `ZDOTDIR`로 주입하는 것과 같은 결이다. **레지스트리를 쓰지 않는다** — cmd의 유일한
전역 훅인 `HKCU\...\Command Processor\AutoRun`은 maru 밖에서 뜨는 모든 cmd에 걸려 침습적이다.

- **cmd**: `PROMPT` 환경변수에 OSC를 심는다. `$E`가 ESC로, `$P`가 현재 경로로 확장된다.
- **PowerShell**: `prompt` 함수를 오버라이드하는 스크립트를 주입한다.

**사용자 프롬프트를 덮지 않는다.** 부모의 `PROMPT`(없으면 `$P$G`)를 읽어 그 **앞에 OSC만 덧붙인다.**
`SpawnRequest.zdotdir`는 zsh 전용 이름이라, 셸 중립적인 "통합 주입 지점"으로 일반화한다(§4).

### 3.4 cmd의 한계 — exit code는 원리적으로 불가하다

cmd의 `PROMPT` 확장 코드에는 **직전 명령의 종료 코드가 없다.** 따라서 `OSC 133 D`에 실을 값이 없고,
sticky command(`scrollback.sticky-command`)처럼 종료 상태에 기대는 기능은 cmd에서 동작하지 않는다.
Microsoft 문서도 같은 한계를 명시한다. **우회하지 않고 문서화한다.**

### 3.5 cwd 2단 — 물어볼 공개 API가 없다

macOS는 OSC 7이 없을 때 `proc_pidinfo(PROC_PIDVNODEPATHINFO)`로 커널에 묻는다(2단). 그 함수는 **공개
문서화 API**(libproc)다. **Windows에는 대응하는 공개 API가 없다** — WMI `Win32_Process`에도 현재
디렉터리 속성이 없다. 유일한 경로는 `NtQueryInformationProcess`로 PEB를 얻어 `ReadProcessMemory`로
`RTL_USER_PROCESS_PARAMETERS.CurrentDirectory`를 읽는 것이고, 이는 **비문서화**다(Process Explorer가 쓰는 경로).

**그래서 2단은 선택이다.** §3.2·§3.3으로 네이티브 셸이 모두 1단을 갖게 되므로, 2단은 macOS에서와 같은
**보조 위상**(통합 없는 셸·재개 Term)으로 내려간다. 2단을 둘지는 아직 정하지 않았다(§8) — 레퍼런스도
갈린다: Ghostty는 커널을 전혀 묻지 않고 "모른다"를 표현 가능하게 두는 반면([editor-surface-dock.md](editor-surface-dock.md) §3.5),
Orca는 4단까지 내려간다.

**둔다면 반드시 fail-soft여야 한다.** 구조체 오프셋이 비문서화라 Windows 버전·WOW64에 따라 달라질 수 있다.
실패하면 조용히 1단만 쓴다. 비공개 API 사용의 선례는 있다 — macOS의 창 블러가
`CGSSetWindowBackgroundBlurRadius`(비공개 CGS)를 쓴다.

### 3.6 에이전트 탐지

ADE의 핵심인 "이 pane에서 claude/codex가 도는가" 판정이다. macOS는 `proc_listpgrppids`로 포그라운드
프로세스 그룹을 훑는다. Windows에는 프로세스 그룹이 없으므로 **`CreateToolhelp32Snapshot`으로 전체
스냅샷을 뜨고 `th32ParentProcessID`로 자식 체인을 따라간다.** 공개 API다.

## 4. ConPTY 백엔드

`src/pty/session.zig`의 `UnsupportedPtySession`이 명세다. 17개 표면 중 **13개가 필수**이고, 4개는 초기에
빈 값으로 두어도 제품이 선다.

| 필수 | `spawn` `close` `deinit` `readEvent` `readChunk` `waitIo` `writeInput` `writeInputNonBlocking` `signalWrite` `resize` `currentSize` `reapAfterEof` `reapIfExited` |
|---|---|
| **보류 가능** | `resourceSamples` `foregroundProcessGroup` — Windows에 프로세스 그룹 개념이 없다 |
| **§3.5·§3.6이 결정** | `processCwd` `foregroundProcessNames` |

### 4.1 `waitIo`는 계약을 바꾸지 않는다 — 파이프를 바꾼다

`waitIo(want_write) !IoReady`는 macOS에서 `std.posix.poll(master_fd, wake_read_fd)`다. 파일 디스크립터를
poll하는 모양이라 Windows로 그대로 오지 않아 보이지만, **계약은 그대로 두고 파이프 종류만 바꾸면 된다.**

**`CreatePipe`를 쓰지 않는다.** 익명 파이프는 동기 전용이라 "데이터가 왔는지"를 기다릴 방법이 없다. 대신
**`CreateNamedPipeW` + `FILE_FLAG_OVERLAPPED`** 로 만들고 비동기 read를 걸어 두면 그 완료 이벤트를 기다릴 수 있다.

```text
macOS    poll(master_fd, wake_read_fd)
Windows  WaitForMultipleObjects(read_overlapped_event, wake_event)
```

**실측으로 확인했다**(§6): 비동기 `ReadFile`이 `ERROR_IO_PENDING`으로 등록되고, 상대가 쓰면 read 이벤트로,
`SetEvent`로는 wake 이벤트로 깨어나며, 조용하면 스핀 없이 timeout한다. **`CreatePseudoConsole`이 named pipe
핸들을 그대로 받는다**(`hr=S_OK`)는 것도 함께 확인했다.

> **범위 주의**: 위 실측은 **대기 메커니즘과 핸들 수용**까지다. 자식의 출력이 실제로 그 파이프로 흐르는
> end-to-end는 §6의 ConPTY 항목대로 **아직 미확인**이다.

따라서 `waitIo`·`IoReady`·`readChunk`·`writeInputNonBlocking`의 **시그니처는 바뀌지 않는다.** 호출자도
하나뿐이다(`src/app/pty_reader.zig`의 reader 루프).

**다만 write 쪽은 의미가 그대로 오지 않는다 — 백엔드가 흡수해야 한다.** 적대적 검증에서 드러났다:

| | POSIX | overlapped |
|---|---|---|
| 뜻 | `POLLOUT` = "지금 쓰면 안 막힌다" | "내가 건 write가 끝났다" |
| 부분 진행 | `write()`가 나간 바이트 수를 준다 | **없다** — 전량이 나갈 때까지 하나의 미완료 작업 |

실측(4 KiB 파이프 버퍼에 512 KiB write): 즉시 반환은 `ERROR_IO_PENDING`에 `written=0`이고, 완료 전
`GetOverlappedResult`는 `ERROR_IO_INCOMPLETE`에 `bytes=0`이라 **부분 진행을 볼 수 없다.** 상대가 8 KiB를
읽어도 미완료이고, 전량을 읽어야 완료된다.

reader 루프는 `out_head += writeInputNonBlocking(...)`으로 **부분 진행을 기록**하므로, Windows 백엔드는 셋 중
하나를 골라 그 차이를 메워야 한다 — ① 미결 write를 한 건만 두고 완료 전까지 `writable`을 보고하지 않기,
② 파이프 버퍼 이하로 잘라 쓰기, ③ writer 스레드 + 큐. **어느 쪽이든 계약 밖의 구현 규약이므로 W4에서
정하고 여기에 기록한다.**

### 4.2 `SpawnRequest`에서 실제로 바꿀 것

**`command` + `args`는 그대로 둔다.** 중립 계약은 *"무엇을 어떤 인자로 띄울 것인가"*(의도)를 표현하고,
그것을 OS 형식으로 인코딩하는 것은 백엔드의 일이다 — macOS 백엔드가 `execve`의 `argv[]`로 바꾸듯,
Windows 백엔드가 `CreateProcessW`의 `lpCommandLine` 문자열로 조립한다. 계약을 문자열로 바꾸면 Windows의
인코딩 디테일이 중립 레이어로 새고, argv quoting(백슬래시-따옴표 규칙)이 계약에 얹힌다.

> `cmd.exe`가 표준 CRT argv 파싱을 쓰지 않는다는 점은 **백엔드가 조립할 때** 지켜야 할 사항이지 계약을
> 바꿀 이유가 아니다. config는 이미 따옴표를 지원하지 않는다([configuration-shell.md](configuration-shell.md)).

| 필드 | 어떻게 |
|---|---|
| `command` + `args` | **그대로.** 조립은 백엔드 |
| `login: bool` | **중립 유지.** 이름이 메커니즘(`login(1)`)을 가리키므로 **의도**("사용자의 대화형 로그인 세션인가")로 재문서화하고, 메커니즘만 백엔드가 정한다 — macOS는 `login(1)` 래핑, Windows는 무동작 |
| `zdotdir` | **일반화.** zsh라는 셸 이름까지 새고 있다 → "셸 통합 자산 디렉터리"로. 백엔드가 매핑한다(zsh=`ZDOTDIR`, PowerShell=프로필 스크립트, cmd=`PROMPT`) |
| `term` | 백엔드가 의미를 정한다. 네이티브 Windows 셸엔 무의미하고 WSL·msys 프로그램에만 쓰인다 |

**`login`을 지우면 안 되는 이유**: 호출자가 정하는 정책이고(`agent.zig`가 비대화형에 `false`, 대화형에 `true`),
**세션 호스트 RPC를 건너간다**(`server.zig`→`runtime_manager.zig`→`remote_runtime.zig`). 지우면 백엔드가
"사용자의 대화형 셸"과 "통제된 자식 프로세스"를 구별할 수 없고 프로토콜에서도 필드가 사라진다.

**제약 — wire tag는 건드리지 않는다.** `SpawnRequest`의 필드는 `RuntimeSpawnParams`를 거쳐 세션 호스트
RPC를 건너간다. 그 JSON 키(`"zdotdir"`·`"term"`·`"login"`)는 **손으로 적힌 wire tag**라 Zig 필드 이름과
독립이다([session-host-upgrade.md](session-host-upgrade.md)가 "tag를 자동 생성하지 않는다"로 못박은 이유가
이것이다 — 영속 호스트라 새 앱이 **옛 호스트**와 대화한다). **native 필드만 바꾸고 tag는 그대로 둔다.**
tag를 바꿔야 한다면 명시적 converter와 version bump가 따로 필요하다.

## 5. 경로 구분자 — 입구에서 정규화한다

Windows에서 경로는 **모든 출처가 백슬래시로** 들어온다: OSC 9;9의 cwd, PEB의 `CurrentDirectory`(후행
구분자까지 붙는다), 프로세스 열거 결과.

[layering-and-portability.md](layering-and-portability.md) §4.1이 세운 규칙 — *"L2에서 구분자를 만들어
내는 자리는 항상 POSIX 구분자를 쓴다"* — 을 Windows에서는 **입구까지 확장한다**: 플랫폼이 코어로 넘기는
경로는 `/`로 정규화된 상태여야 한다. 안 하면 `file_tree`·`git_ops`·소스 컨트롤이 `/repo\docs` 문제를
그대로 다시 겪는다(그 버그는 이미 한 번 고쳤다).

## 6. 실측 (2026-08-15, Windows 10.0.19045, zig 0.16.0)

계약을 쓰기 전에 PoC로 확인한 것과 확인하지 못한 것을 정직하게 남긴다.

| 항목 | 결과 |
|---|---|
| cmd `PROMPT` 주입 | ✅ `ESC]9;9;C:\...ESC\` + `OSC 133 A/B/D` 캡처 |
| PowerShell `prompt` 오버라이드 | ✅ OSC 7 + `OSC 133 A/B/D`(exit code 포함) 캡처 |
| PEB cwd(2단) | ✅ 자기 프로세스 대조 일치(후행 `\` 트림 필요), 남의 셸 프로세스도 읽힘 |
| 프로세스 열거 | ✅ 5,328개 열거, `ppid` 체인으로 부모-자식 확인 |
| **`waitIo` 대응**(§4.1) | ✅ overlapped named pipe 비동기 read가 `ERROR_IO_PENDING`으로 등록되고, 상대 write는 read 이벤트로·`SetEvent`는 wake 이벤트로 깨우며, 조용하면 스핀 없이 `WAIT_TIMEOUT`. **`CreatePseudoConsole`이 named pipe 핸들을 받는다**(`hr=S_OK`) |
| ConPTY | ⚠️ `CreatePseudoConsole`·`ResizePseudoConsole` S_OK, conhost가 VT init 방출, `UpdateProcThreadAttribute`가 잘못된 attribute를 거부하고 `0x20016`은 수락. **자식이 pty에 붙는 것만 미확인** |

**ConPTY 미확인의 성격**: 같은 로직을 C로 다시 써서 숫자까지 동일하게 실패했다(`attrSize=48`,
`sizeof(STARTUPINFOEXW)=112`, `flags=0x80000`). 즉 바인딩 문제가 아니라 **실행 환경**(에이전트 샌드박스가
conhost 세션을 못 띄움)이다. 부모 프로세스에 콘솔이 없음도 확인했다. **실제 대화형 Windows 세션에서 한 번
돌려 닫아야 한다** — 그전까지 ConPTY 동작을 완료로 계상하지 않는다.

## 7. 베이스

- **ConPTY**: Win32 공개 API(`CreatePseudoConsole`·`ResizePseudoConsole`·`PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE`).
- **OSC 9;9**: ConEmu가 정의한 공개 시퀀스. Windows Terminal이 채택하고 Microsoft가 셸 통합 문서로 안내한다.
  **동작만 비교했고 레퍼런스 코드 표현은 옮기지 않았다**([project-rules.md](project-rules.md) clean-room).
- **PEB cwd**: 비문서화 구조체. Process Explorer 계열이 같은 경로를 쓴다는 사실만 근거이고, 구현은 공개
  문서(`NtQueryInformationProcess`·`ReadProcessMemory`)와 자체 측정으로 만든다.
- **셸 티어와 통합 주입 형태**: macOS의 `ZDOTDIR` 주입을 Windows 셸에 옮긴 maru 독립 설계다.

## 8. 아직 정하지 않은 것

- **OSC 9;9의 host를 어떻게 볼 것인가**(§3.2). authority 필드가 없어 로컬/원격 판정에 구멍이 난다.
- **cwd 2단(PEB)을 둘 것인가**(§3.5). Ghostty는 안 두고 "모른다"를 표현하며, macOS maru는 둔다. Windows에서는
  비문서화 비용이 더해지므로 별도 판단이 필요하다.
- **GPU 백엔드와 웹뷰 합성 모델**. WebView2는 별도 HWND라 macOS의 `CALayer` subview 3겹 합성이 그대로
  오지 않는다. 둘은 같은 결정이므로 4단계에서 함께 정한다.
- **`main.zig`의 컨트롤 플레인 transport**. unix domain socket을 named pipe로 옮기는 설계. 초기에는
  "인스턴스 없음"으로 graceful하게 빠지는 것으로 충분하다.
- **배포**. 코드 서명·인스톨러·업데이트 경로는 [배포·업데이트 전략](distribution.md)이 macOS 기준으로
  쓰여 있다.
