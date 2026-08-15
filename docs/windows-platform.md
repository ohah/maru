# Windows 플랫폼

Windows에서 maru를 띄우기 위한 계약의 단일 출처다. 레이어 경계는 [레이어링과 이식성](layering-and-portability.md),
PTY 계약은 [PTY 운영 모델](pty-operating-model.md), 셸 설정 키는 [셸과 환경](configuration-shell.md),
cwd 축의 2단 모델은 [소스 컨트롤 도크](editor-surface-dock.md) §3.5를 단일 출처로 둔다. 단계 진행은
[구현 계획](plans/windows-platform.md)이 소유한다(이 문서는 상태를 쓰지 않는다).

## 1. 확정 결정

- **Windows는 지원 대상이다.** macOS가 여전히 주 타깃이고, Windows는 그 다음이다. 모바일과 달리 별도 장수
  브랜치를 두지 않고 `main`에서 간다 — 중립 레이어(L1~L3)가 이미 Windows 호스트에서 초록이라
  ([layering-and-portability.md](layering-and-portability.md) §4.1) 회귀를 CI로 잡을 수 있다.
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

**`SpawnRequest`가 POSIX 모양이라 먼저 중립화한다**(`src/pty/types.zig`):

| 필드 | 지금 | Windows |
|---|---|---|
| `command` + `args` | `execve`용 절대경로 + argv 배열 | `CreateProcessW`는 **단일 command line 문자열**이고 quoting 규칙이 다르다 |
| `login: bool` | macOS `login(1)` 래핑 | 대응 개념 없음 |
| `zdotdir` | zsh 전용 | 셸 중립 "통합 주입 지점"으로 일반화(§3.3) |
| `term` | terminfo | 네이티브 셸엔 무의미. WSL·msys 프로그램에만 의미 있다 |

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

- **cwd 2단(PEB)을 둘 것인가**(§3.5). Ghostty는 안 두고 "모른다"를 표현하며, macOS maru는 둔다. Windows에서는
  비문서화 비용이 더해지므로 별도 판단이 필요하다.
- **GPU 백엔드와 웹뷰 합성 모델**. WebView2는 별도 HWND라 macOS의 `CALayer` subview 3겹 합성이 그대로
  오지 않는다. 둘은 같은 결정이므로 4단계에서 함께 정한다.
- **`main.zig`의 컨트롤 플레인 transport**. unix domain socket을 named pipe로 옮기는 설계. 초기에는
  "인스턴스 없음"으로 graceful하게 빠지는 것으로 충분하다.
- **배포**. 코드 서명·인스톨러·업데이트 경로는 [배포·업데이트 전략](distribution.md)이 macOS 기준으로
  쓰여 있다.
