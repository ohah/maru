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
  Win32 host)를 브랜치로 뺄지는 **그 시점에 판단한다.** [모바일](mobile-platform.md)이 선례다 — 장수 브랜치에서
  spike한 뒤 `main`으로 합류했다. 같은 L4 신규 타깃이라 같은 모양이 될 수 있다.
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
때문이고, 그래서 `app_host_abi.zig`(212개 `export fn`)라는 C ABI 경계가 필요했다. Windows에는 그 강제가
없으므로 **Zig 한 언어로 간다** — 언어 경계도, 그 경계를 넘기는 marshaling 레이어도 필요 없다. 두 L4의
모양이 달라지지만 L4는 정의상 타깃별 신규다. **ABI는 이식 이음매가 아니다** — 이음매는 renderer 중립 계약이다.

> **다만 "Win32는 다 C API"는 아니다.** 창·입력·IME(`user32`·`imm32`)는 평범한 C지만, **DirectWrite·
> D3D11/DXGI·DirectComposition은 COM**이다. Zig에서 COM은 vtable을 `extern struct`로 직접 놓으면 되지만
> 편의 계층이 없어 평범한 C 호출보다 손이 더 간다. **제2 언어가 필요하다는 뜻은 아니고**(C++ 불필요),
> W7의 비용을 "C 함수만 부르면 된다"로 과소평가하지 않기 위한 단서다.

## 3. 셸과 셸 통합

### 3.1 셸 티어

| 셸 | cwd | 프롬프트 마크 | 비고 |
|---|---|---|---|
| **PowerShell** (pwsh 7 / Windows PowerShell 5.1) | ✅ | ✅ (exit code 포함) | 네이티브 기본 |
| **cmd** | ✅ | 부분 — **exit code 불가** | §3.4 |
| **WSL** | ✅ (OSC 7) | ✅ | 터미널·통합은 그대로 오지만 **ADE 축 셋이 안 온다** — 아래 |
| git-bash · nu 등 | 통합 없으면 2단(§3.5)에 의존 | — | 뜨긴 뜬다 |

**WSL은 "공짜로 따라오지" 않는다(적대적 검증에서 드러남).** ConPTY 입장에서 `wsl.exe`는 그냥 자식이라
**터미널과 셸 통합(OSC 7·133)은 그대로 온다.** 그런데 **WSL2는 경량 VM**이라 그 안의 프로세스가 Windows
프로세스 목록에 나타나지 않는다(보이는 것은 중계 `wsl.exe` 하나뿐). 그래서 Windows 쪽에서 프로세스를 보는
축이 전부 무너진다:

| 축 | WSL2에서 |
|---|---|
| **에이전트 탐지**(§3.6) | ❌ `claude`·`codex`가 VM 안이라 안 보인다. maru는 이 판정을 **proc_name 폴링**으로 한다(`session_model.AgentKind` — *"pollAgentKinds가 ≈0.5s마다 proc_name으로 갱신"*)이므로, 사이드바 에이전트 목록·세션 도크·에이전트 상태가 **동작하지 않는다** |
| **cwd 2단**(§3.5) | ❌ PEB로 보이는 것은 `wsl.exe`의 **Windows 쪽 cwd**라 Linux 쪽 실제 cwd와 다르다. 1단(OSC 7)만 유효하다 |
| **경로 소비** | ⚠️ OSC 7이 주는 `/home/user/x`는 **Linux 경로**라 Windows 파일 API로 못 연다. 파일 탐색기·소스 컨트롤이 쓰려면 `\\wsl$\<distro>\…` 변환이 필요하다 |

ADE의 핵심이 에이전트 축이므로 이것은 작은 결함이 아니다. **해법은 아직 정하지 않았다**(§8).

### 3.1a 어떤 셸을 띄우는가 — 선택과 기본값

**사용자가 고르는 수단은 이미 있다.** `shell.command`/`shell.args`([configuration-shell.md](configuration-shell.md))가
그 자리이고, Windows에서도 같은 키가 그대로 동작한다(아래 "OS 분기" 논의는 그 키를 **대체**하는 것이 아니라
같은 파일을 두 OS에서 공유할 때의 override를 더할지의 문제다).

```conf
shell.command = C:\Program Files\PowerShell\7\pwsh.exe
shell.args    = -NoLogo
```

**없는 것은 기본값 결정 규칙이다.** `pty.resolveInteractiveShell()`(`src/pty/types.zig`)은 중립 파일에 있으면서
`MARU_INTERACTIVE_SHELL` → `SHELL` → `/bin/sh` 순으로 **POSIX만** 안다. Windows에는 `$SHELL`이 없고 `/bin/sh`도
없다. **이 함수가 OS별 갈래를 가져야 한다** — 중립 파일에 POSIX 기본값이 박혀 있는 것은 방금 고친
`monotonicMs`(§4.1 계열)와 같은 종류의 누수다.

**Windows 기본값은 PowerShell이다(사용자 확정).** `%COMSPEC%`(=거의 항상 `cmd.exe`)를 따르지 않는다 —
cmd는 `OSC 133 D`를 원리적으로 못 내고(§3.4) 통합이 가장 약한 셸이라, 그것이 기본이 되면 ADE 기능이 기본
상태에서 반쯤 꺼진 채 시작한다. 해석 순서:

```text
MARU_INTERACTIVE_SHELL  →  shell.command(config)  →  pwsh 7  →  Windows PowerShell 5.1  →  cmd
```

`MARU_INTERACTIVE_SHELL`은 maru 자체 변수라 OS 무관하게 1순위로 유지한다. 마지막 `cmd` 폴백은 PowerShell이
없는 기기에서도 터미널이 뜨게 하기 위한 것이다(§3.1의 cmd 티어 그대로 동작한다).

**config로 바꿀 수 있어야 한다(사용자 확정).** 수단이 셋이고, 구체적인 것이 이긴다.

```conf
# ① 종류만 고른다(Windows 전용 키)
shell.windows-shell   = cmd
# ② 경로를 못 박는다(OS별 override)
shell.command.windows = C:\Program Files\PowerShell\7\pwsh.exe
# ③ 모든 OS 공통(Windows에선 ②가 이긴다)
shell.command         = /bin/zsh
```

**OS 분기는 일반 메커니즘으로 넣었다(§8에서 결정 완료).** 한때 "셸만 일회성 키로 둘지, 일반 메커니즘으로
만들지"가 미결이었는데, 일반 메커니즘 쪽이 **오히려 코드가 적다** — 로더가 키에서 접미를 떼고 호스트가 아니면
그 줄을 건너뛰는 것이 전부다(값 파싱·검증·GUI는 기본 키와 완전히 같은 경로를 탄다). 일회성 키였다면 셸에만
해법이 생기고 `font.size`·`workspace.root` 같은 다음 충돌마다 키를 하나씩 더 파야 했다.

동작 규칙과 예시는 [configuration.md](configuration.md) "OS별 값"이 소유한다. 요점만: **OS 접미 키가 기본 키를
파일 순서와 무관하게 이기고**, 다른 OS 줄은 조용히 무시되며, 모르는 접미(`.freebsd`·오타 `.window`)는 접미가
아니라 키 이름의 일부라 "알 수 없는 키"로 잡힌다. VS Code가 같은 문제를
`terminal.integrated.defaultProfile.windows`/`.osx`/`.linux`로 푸는 것과 같은 모양이다.

**`shell.windows-shell`은 경로가 아니라 종류를 고른다**(`powershell`|`cmd`, 기본 `powershell`). 실제 경로가
기기마다 다르기 때문이다 — pwsh 7은 설치 여부가 갈리고 5.1은 `%SystemRoot%`에 매여 있다. 종류만 고르면 해석은
아래 티어가 하고, 경로를 못 박고 싶으면 `shell.command`(+`.windows`)를 쓴다. 다른 OS에서는 읽히되 쓰이지
않는다 — 키를 OS별로 숨기면 dotfiles를 공유하는 사용자가 macOS에서 "알 수 없는 키" 경고를 받는다.

**탭별로 다른 셸을 여는 "프로필"은 이 계약 밖이다.** 지금 maru에는 그 개념이 없고(전역 `shell.command` 하나),
macOS도 마찬가지다. 즉 **Windows 고유 요구가 아니라 제품 기능**이므로 별도 이니셔티브로 둔다 — 다만 Windows는
한 기기에 cmd·PowerShell·WSL이 공존하는 것이 정상이라 **수요가 macOS보다 크다**는 점은 기록해 둔다.

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

**따옴표 유무 두 형태가 모두 실재한다(W1 구현 중 확인).** ConEmu 원본 스펙은 경로를 감싸고, Microsoft가
안내하는 `PROMPT`는 감싸지 않는다. **둘 다 실제 셸에서 캡처했다**:

```text
ConEmu 스펙 (pwsh)   ESC ] 9 ; 9 ; "C:\Users\…\scratchpad" ESC \
Microsoft PROMPT     ESC ] 9 ; 9 ;  C:\Users\…\scratchpad  ESC \
```

그래서 파서는 **양끝이 짝일 때만** 따옴표를 벗긴다. Windows 파일명에 `"`가 올 수 없으므로 이 판정은
모호하지 않고, 한쪽만 있는 비정상 입력은 그대로 둔다.

**percent-decode하지 않는다.** OSC 7의 path는 URI라 디코드가 맞지만 9;9은 네이티브 경로라, 디코드하면
`C:\temp\100%done` 같은 정상 경로가 깨진다.

**구분자도 정규화하지 않는다.** 받은 그대로 보관한다 — §5의 순서 제약(절대경로 판정을 `[0]=='/'`에서 먼저
떼어낸 뒤에 정규화한다)을 지키기 위해서다.

### 3.2a OSC 9;9엔 authority가 없다 — **9;9은 host를 건드리지 않는다**

**결정(사용자 확정).** `OSC 9;9`은 **cwd만 갱신하고 `cwd_host`는 그대로 둔다**(아래 후보 C).

```zig
// 개념
dispatchCwd(body)      // OSC 7  — (host, path) 쌍을 함께 세운다
dispatchConEmuCwd(p)   // OSC 9;9 — path만 세운다. host는 손대지 않는다
```

이유는 셋이다.

1. **A(무조건 로컬)보다 엄격히 낫다.** 원격 Unix가 OSC 7으로 host를 세운 뒤 어떤 프로그램이 9;9을 보내는
   혼합 케이스에서, A는 host를 지워 **원격 세션을 로컬로 뒤집는다.** C는 원격을 유지한다.
2. **비용이 0이다.** 새 상태도, wire 변경도 없다.
3. **뒤를 막지 않는다.** 나중에 B(원격 세션에서 무시)나 E(3상)를 얹을 수 있다.

#### 받아들인 위험 (명시)

**"ssh 서버를 켜고 프롬프트 통합까지 설정한 원격 Windows"에 맨 `ssh`로 접속하면, 그 세션의 cwd가 로컬로
오인된다.** 그러면 [§9.4의 안전장치](ssh-integration.md)가 발동하지 않아 로컬에 같은 경로가 있을 경우
**남의 저장소를 보여 주고 stage/discard가 그 로컬 파일을 바꾼다.**

이 위험을 안고 가는 근거:

- **발생 조건이 좁다.** 원격 Windows에서 `sshd`를 켜야 하고(실측 n=1에서 `Stopped`/`Manual`), Microsoft가
  안내하는 `PROMPT` 통합을 **사용자가 직접 설정**해야 한다. 기본 상태의 원격 PowerShell은 9;9을 보내지 않는다.
- **새로 만든 구멍이 아니다.** 맨 `ssh`에서 원격을 알 수 없다는 것은 OSC 7에 대해 **이미 문서화된 한계**다
  (§9.4). 9;9은 그 한계의 실패 모드를 바꿀 뿐이다.
- **완전한 대안이 비싸다.** 유일하게 이걸 막는 E는 `handoff_codec`의 `tag = 90` **wire 스키마 변경**이라
  명시적 converter와 version bump가 따라온다([session-host-upgrade.md](session-host-upgrade.md)).

**재검토 트리거**: 이 오인이 **실제로 보고되면** E로 올라간다. 가설을 막으려고 검증된 코드에 미검증 동작을
더하지 않는다는 [ssh-integration.md](ssh-integration.md) §9.2의 판단과 같은 형태다.

**위험의 범위는 "원격이 Windows일 때"로 한정된다.** 원격이 macOS·Linux면 그 셸은 ConEmu 9;9을 보내지 않고
OSC 7(host 포함)을 보내거나 아무것도 안 보낸다 — 둘 다 기존 경로 그대로다. 즉 **Windows에서 macOS/Linux로
접속하는 흔한 경우는 이 결정으로 나빠지지 않는다.**

| Windows maru → | 원격이 보내는 것 | 판정 |
|---|---|---|
| `maru ssh` → macOS/Linux | OSC 7 + `${HOST}`(원격 rc 스니펫, [§9.5](ssh-integration.md)) | 원격 — 맞다 |
| 맨 `ssh` → macOS/Linux (원격에 자체 OSC 7 보고자 있음) | OSC 7 + host | 원격 — 맞다 |
| 맨 `ssh` → macOS/Linux (보고자 없음) | 없음 | cwd가 **ssh 이전 로컬 경로**에 머문다 — 오래됐지만 실재하는 로컬 경로라 데이터 위험은 없다(기존 한계) |
| 맨 `ssh` → **원격 Windows(통합 설정됨)** | **OSC 9;9** | **로컬로 오인** ← 위에서 받아들인 위험 |

**C가 host를 보존한다는 것의 부작용도 적어 둔다.** `ssh-end`(OSC 5379)는 `ssh_remote_dest`만 지우고
**`cwd_host`는 지우지 않는다** — 로컬 셸이 다음 프롬프트에서 보내는 OSC 7(host 비움)이 그 자리를 덮는다.
그 사이에 9;9이 오면 C는 옛 원격 host를 유지하므로 **원격으로 판정**된다. 이는 **보수적인 쪽**이라(도크가
잠깐 안 붙을 뿐 잘못된 저장소를 열지 않는다) 받아들인다. 다만 통합이 아예 없는 셸에서는 그 host를 지워 줄
OSC 7이 영영 오지 않아 **그 Term이 계속 원격으로 남을 수 있다** — 실제로 겪으면 `ssh-end`가 `cwd_host`도
지우도록 넓히는 것이 후속 수정이다.

---

아래는 이 결정에 이르는 검토 과정이다 — 결론만 적으면 다음 사람이 같은 오답을 다시 거친다.

#### 무엇이 걸려 있나

OSC 7은 `file://<host>/<path>`라 **host를 함께 나른다.** maru는 그것으로 로컬/원격을 가르고
(`TerminalCore.hostIsLocal`), 원격이면 [§9.4의 소비처를 전수로 닫는다](ssh-integration.md) — 새 탭 cwd 상속,
tombstone 복원 spawn, 링크 resolve, git 조회. 문서가 위험을 직설적으로 적어 뒀다:

> *"로컬에 같은 경로가 있으면 **남의 저장소를 원격인 척 보여 주고**, 거기서 **stage/discard 하면 보고 있지도
> 않은 로컬 파일이 바뀐다**"* — [editor-surface-dock.md](editor-surface-dock.md)

**OSC 9;9엔 그 필드가 없다.** 경로만 온다.

#### 빈 host는 "미상"이 아니다 — **"로컬이다"라는 주장**이다

이것이 검토에서 가장 중요한 사실이다. `hostIsLocal`의 첫 줄이 `if (host.len == 0) return true;`인데, 이는
소극적 기본값이 아니라 **maru 자기 셸 통합이 의도적으로 쓰는 신호**다. `_maru_osc7`은 **일부러 host를 비워
보낸다** — `${HOST}`를 실었더니 셸 시작 시점과 앱 조회 시점의 hostname 스냅샷이 갈려 **자기 세션을 원격으로
단정**했고, 로컬 저장소에서 소스 컨트롤이 "git 저장소가 아닙니다"를 띄웠다(2026-08-13 사용자 보고,
[ssh-integration.md](ssh-integration.md) §9.2).

따라서 **"빈 host = 미상"으로 재해석하는 안은 maru 자신의 로컬 통합을 깨뜨린다.**

#### 실제로 위험해지는 조합

기존 한계는 **안전하게** 실패한다:

```
맨 ssh → 원격 Unix, OSC 7 없음     cwd = ""          도크 비활성        안전
```

9;9이 그 실패를 **위험한 쪽으로** 뒤집는다:

```
맨 ssh → 원격 Windows, OSC 9;9      cwd = "C:\proj"   로컬 C:\proj 판정   위험
                                     host = (필드 없음)
```

**다만 이 조합의 빈도는 낮아 보인다(실측으로 낮춰 잡았다).** 처음에 "Windows엔 OpenSSH 서버가 기본
탑재"라고 적었으나 그것은 **클라이언트** 얘기다. 서버는 별개이고, 측정한 기기(n=1)에서 capability는
설치돼 있었지만 **`sshd` 서비스가 `Stopped`/`StartType=Manual`** 이었다 — 즉 ssh로 들어갈 수 있는 Windows
기기는 **누군가 명시적으로 켠** 기기다. 게다가 Microsoft가 안내하는 `PROMPT`는 **사용자가 직접 설정**하는
형태라, 기본 상태의 원격 PowerShell은 9;9을 보내지 않는다.

정리하면 위험은 **"ssh 서버를 켜고, 프롬프트 통합까지 설정한 원격 Windows"** 에서만 발생한다. 확률은 낮지만
**발생하면 결과가 데이터 손상**이라는 비대칭이 남는다.

#### 후보와 각각이 못 막는 것

| | 내용 | 못 막는 것 |
|---|---|---|
| **A** | 9;9을 항상 로컬로 본다(= 아무것도 안 함) | 위 위험 전부. **고르는 게 아니라 기본으로 그렇게 된다** |
| **B** | 알려진 원격 세션(`sshRemoteDest()`)에서 9;9을 무시 | **맨 `ssh`** — `shell-integration.ssh`가 **기본 `false`**라 평범한 `ssh`는 OSC 5379를 안 만든다. 즉 위험을 만드는 바로 그 경우를 못 막는다 |
| **C** | 9;9은 authority를 만들지 않는다(기존 host를 그대로 둔다) | **원격 Windows** 케이스. 그 셸은 OSC 7을 안 보내므로 보존할 원격 host가 애초에 없다. 다만 **원격 Unix가 OSC 7으로 host를 세운 뒤 어떤 프로그램이 9;9을 보내는** 혼합 케이스는 C가 옳게 막는다(A는 그때 host를 지워 로컬로 뒤집는다) — 즉 C는 불충분하지만 A보다 엄격히 낫고, **어느 안을 택하든 "9;9이 host를 지우지 않는다"는 규칙은 함께 가야 한다** |
| **D** | 빈 host를 "미상"으로 재해석 | **자기 통합을 깨뜨린다**(위) |
| **E** | 3상(로컬/원격/미상)을 새로 도입 | 비용 — `cwd_host`는 `handoff_codec.zig`에 **`tag = 90` wire 필드**라 스키마 변경이고, 명시적 converter + version bump가 따라온다([session-host-upgrade.md](session-host-upgrade.md)) |

**정직한 상태**: 값싸면서 완전한 안이 없다. 맨 `ssh` 세션에는 그 정보가 애초에 없다 — 그것은 OSC 7에 대해
이미 문서화된 한계이고, 9;9은 그 한계의 **실패 모드를 안전에서 위험으로** 바꾼다.

#### 구현자가 밟을 함정 둘

**① C는 "원자적 쌍" 불변식을 깨는 것이 아니다.** `dispatchCwd`의 주석이 경고하는 것은 *부분 실패*
(host 할당에 실패했는데 path만 갱신)이고, C는 **프로토콜이 path만 나르는 경우**를 다루는 별개 경로다.
그래도 결과적으로 "새 path + 옛 host" 쌍이 생기므로, 그 조합이 안전한지 확인해 두면:

| 직전 상태 | 9;9 도착 후 (C) | 판정 |
|---|---|---|
| host 없음(로컬) | host 없음 + 새 path | 로컬 — 맞다 |
| host=원격(OSC 7로 세워짐) | host=원격 + 새 path | 원격 — 맞다(A는 여기서 host를 지워 **로컬로 뒤집는다**) |
| host 없음 + 원격 Windows | host 없음 + 원격 path | **로컬로 오판** — 위에서 말한 잔여 위험 |

즉 C는 어떤 경우에도 A보다 나쁘지 않고, 두 번째 행에서 **엄격히 낫다**.

**② `title_generation` bump를 빠뜨리면 안 된다.** `dispatchCwd`는 cwd나 host가 바뀔 때만 bump하는데, 이
generation은 창 제목 재sync만이 아니라 **runtime observation refresh의 게이트**다. 9;9 경로에서 bump를 빼면
경로가 바뀌어도 관측이 갱신되지 않아 **폴더줄이 옛 값을 계속 그리고 cwd 상속·링크 스코프도 옛 판정에
머문다** — 같은 결함이 host 축에서 실제로 발생해 적대적 검증으로 잡힌 적이 있다(`osc.zig` 주석).

#### 검토에서 폐기한 논거

- ~~"`maru ssh`가 원격 접속의 주 경로라 B로 충분하다"~~ — **틀렸다.** `shell-integration.ssh`가 기본 `false`라
  라우팅이 안 걸린다. B가 커버하는 것은 `maru ssh`를 **직접 친** 세션과 opt-in을 켠 사용자뿐이다.
- ~~"D가 가장 정확하다"~~ — **틀렸다.** 빈 host에 이미 의미가 있다(위).

#### 남은 축 — 아직 재지 않은 것

결정 전에 재야 할 것이 있다: **원격 Windows 셸이 실제로 9;9을 얼마나 보내는가.** Microsoft 문서는 사용자가
`PROMPT`를 직접 설정하는 형태로 안내하므로, 기본 상태의 원격 Windows 서버가 9;9을 보낼지는 별개다. 이 값이
작으면 A + 문서화된 한계로 충분할 수 있고, 크면 E의 비용을 치를 근거가 된다.

> **코어가 이미 절반 알고 있다.** `src/terminal/osc.zig`의 `dispatchNotify9`는 OSC 9를 iTerm2 알림으로
> 처리하면서 ConEmu 서브커맨드(`<숫자>;…`)를 알림 오발사 방지용으로 **소비만** 한다. 주석이 `9;9`(cwd)를
> 이름으로 나열하고 `9;4`(progress)는 실제로 `agent_progress`에 보관하는데, **`9;9`만 분기가 없어 조용히
> 버려진다.** 이 계약은 `4;` 옆에 `9;` 갈래를 더해 기존 cwd 경로로 넘기는 것을 뜻한다. 이는 L1 터미널 코어
> 변경이라 **Windows와 독립적**이다 — ConEmu 시퀀스를 쓰는 프로그램은 macOS·WSL에도 있다.

### 3.3 통합 주입 — 환경변수로 한다

macOS가 zsh 통합을 `ZDOTDIR`로 주입하는 것과 같은 결이다. **레지스트리를 쓰지 않는다** — cmd의 유일한
전역 훅인 `HKCU\...\Command Processor\AutoRun`은 maru 밖에서 뜨는 모든 cmd에 걸려 침습적이다.

- **cmd**: `PROMPT` 환경변수에 OSC를 심는다. `$E`가 ESC로, `$P`가 현재 경로로 확장된다.
- **PowerShell**: `prompt` 함수를 **인라인 `-Command`로** 정의한다. **스크립트 파일(`.ps1`)로 하지 않는다** —
  `ExecutionPolicy`가 `AllSigned`·`Restricted`면 서명 없는 파일이 막혀 통합이 통째로 죽는다. **인라인
  `-Command`는 정책 적용 대상이 아니다**(실측으로 확인: 정책과 무관하게 OSC가 나왔다).
  - **`-NoExit`이 함께 있어야 한다.** `-Command`만 주면 그 명령을 실행하고 **셸이 곧바로 끝난다**(실측:
    ConPTY로 띄운 pwsh가 스스로 종료). 대화형 셸을 원하면 `-NoLogo -NoExit -Command <정의>` 형태다.
  - **사용자 프로필이 `prompt`를 정의해도 우리가 이긴다.** pwsh는 프로필을 먼저 로드하고 `-Command`를
    나중에 실행한다 — 임시 홈에 `function prompt { … }`를 심은 프로필을 두고 실측했다: 프로필이 실제로
    실행됐는데도(마커 출력 확인) 우리 프롬프트가 살아남고 OSC가 나왔다. macOS zsh 통합이 사용자 rc를
    `MARU_ZDOTDIR_PREV`로 이어 주는 것과 달리, 여기서는 **순서가 그 역할을 한다.**

> **실측 주의**: §6의 PowerShell 항목을 처음 잴 때 프로세스 스코프 정책이 `Bypass`였다(도구 환경 탓).
> 즉 그 측정은 **파일 방식이 기본 정책에서 된다는 것을 증명하지 않는다.** 인라인 방식만 정책 무관으로
> 확인됐고, 그래서 계약이 인라인을 요구한다.

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
실패하면 조용히 1단만 쓴다.

**그리고 후행 구분자를 순진하게 자르면 안 된다.** PEB의 `CurrentDirectory.DosPath`는 **항상 후행 `\`를
포함**하는데, 드라이브 루트에서는 값 자체가 `C:\`(3바이트)라 그냥 자르면 **`C:`** 가 된다. Windows에서 `C:`는
"C 드라이브의 **현재** 디렉터리"라는 **다른 뜻의 드라이브 상대 경로**다(실측 확인). 트림은 **결과가 드라이브
루트가 되는 경우를 예외로** 둬야 한다. 비공개 API 사용의 선례는 있다 — macOS의 창 블러가
`CGSSetWindowBackgroundBlurRadius`(비공개 CGS)를 쓴다.

### 3.5a `maru ssh`는 이미 컴파일된다

Windows에서 `maru ssh`가 도는지는 별개 축이라 짚어 둔다. **제품 경로는 이미 Windows에서 컴파일된다** —
`src/maru.zig`가 `cli`를 포함하고 `zig build test`가 Windows에서 통과하므로(§6), `cli/ssh.zig`의 POSIX 사용은
테스트 헬퍼(`fork`/`pipe`/`dup2`)에 갇혀 있다는 뜻이다. 실행에 필요한 `ssh.exe`도 Windows에 기본 탑재된다
(OpenSSH **클라이언트**는 기본, 서버는 별개 — §3.2a).

**다만 런타임은 미검증이다.** 원격에 terminfo를 심는 경로는 원격 쪽 `tic`을 쓰므로 원격이 Unix면 그대로
동작할 것으로 보이지만, ControlMaster 옵션·경로 인용 등 Windows `ssh.exe`와의 세부는 재지 않았다. W4 이후에
실기로 확인한다.

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

구현은 `src/pty/windows.zig`이고, **OS 무관한 조립 규칙**(커맨드라인 인용·환경 블록 내용)은
`src/pty/windows_spawn.zig`가 따로 가진다. 가른 이유는 후자가 모든 타깃에서 컴파일되어 **macOS·Linux CI에서도
그 테스트가 돌기** 때문이다 — Windows 러너가 없는 이 저장소에서 그 규칙이 공허참이 되지 않게 하는 유일한
그물이다.

**`currentSize`는 커널에 되묻지 않는다.** macOS는 `TIOCGWINSZ`를 쓰지만 ConPTY에는 크기를 되묻는 공개 API가
없다. 되물을 이유도 없다 — pseudoconsole 크기를 바꾸는 주체는 우리뿐이고(자식은 `mode con`으로 읽기만 한다),
우리가 넘긴 COORD가 자식에게 그대로 간다는 것은 §6에서 확인했다. 그래서 마지막으로 세운 값을 돌려준다.

**W7이 먼저 풀어야 할 표면 두 가지가 남아 있다.** `UnsupportedPtySession`이 "표면 명세"이지만, app 레이어는
그보다 **넓은 집합**을 부른다 — 그 차이가 지금은 Windows에서 컴파일되지 않아 조용히 잠복해 있다.

| 무엇 | 지금 상태 | W7이 정할 것 |
|---|---|---|
| `live_pty.childPid()`가 `std.c.pid_t`를 낸다 | Windows에서 그 타입은 **`*anyopaque`**(HANDLE)인데 백엔드는 `u32`(DWORD pid)를 낸다 | 중립 레이어가 POSIX 타입을 노출하는 것 자체가 누수다. 백엔드 중립 pid 타입을 정한다 |
| `PreparedAdoption`·`upgradeEligible`·`revalidatePreparedOwnership`·`commitPreparedOwnership` | Windows 백엔드에 **없다**. exec-restore(영속 세션 호스트) 표면이라 macOS 전용 호출자만 있다 | 세션 호스트를 Windows로 옮길 때(계획 "후속") 함께 정한다 |

둘 다 **`UnsupportedPtySession`과의 대조로는 잡히지 않는다** — 그 스텁에도 같은 멤버가 없기 때문이다.
표면 대조는 "스텁"이 아니라 **app 레이어가 실제로 부르는 것의 합집합**을 기준으로 해야 한다.

**`writeInputNonBlocking`의 반환값 의미가 fence 계약과 어긋난다.** `pty_reader`의 `drainedAtFence()`는
`enqueued_total == consumed_total`을 "admitted outbound가 **실제로 PTY에 써졌다**"는 경계로 쓰는데, 이
백엔드에서 그 경계는 최대 한 청크가 미결 write로 남아 있는 상태에서도 성립한다(§4.1의 "인수한 양"). 지금은
그 경계를 쓰는 것이 exec-upgrade 안전점뿐이고 그것은 macOS 전용이라 도달하지 않는다. `deinit`은 취소 전에
미결 write의 완료를 짧게 기다려 **조용한 입력 유실**만은 막는다. 세션 호스트가 Windows로 올 때 이 경계의
뜻을 다시 정해야 한다.

**`.signaled`는 이 백엔드에서 나오지 않는다.** Windows에 시그널이 없다. 255를 넘는 종료 코드(예: Ctrl+C의
`0xC000013A`)는 `.exited: u8`에 담기지 않으므로 `.unknown`으로 원값을 보존한다 — `u8`로 자르면 `0x3A`(58)라는
엉뚱한 "정상 종료"가 된다.

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

자식의 출력이 실제로 그 파이프로 흐르는 end-to-end도 실측으로 닫혔다(§6).

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
하나를 골라 그 차이를 메워야 했다 — ① 미결 write를 한 건만 두고 완료 전까지 `writable`을 보고하지 않기,
② 파이프 버퍼 이하로 잘라 쓰기, ③ writer 스레드 + 큐.

**W4의 결정: ① + 백엔드 스테이징 버퍼.** `writeInputNonBlocking`은 받은 바이트를 **자기 버퍼로 복사**한 뒤
그만큼을 반환하고, `waitIo`는 미결 write가 없을 때만 `writable`을 보고한다. 그래서 미결 write는 언제나
최대 한 건이고, 반환값의 뜻은 *"파이프로 나간 양"*이 아니라 **"백엔드가 책임을 넘겨받은 양"**이다.

**복사가 선택이 아닌 이유**: 호출자는 반환값만큼 head를 전진시킨 뒤 자기 버퍼를 압축(`copyForwards`)하거나
비운다. 미결 overlapped write가 그 버퍼를 가리키고 있으면 커널이 이미 재사용된 메모리를 읽는다. ②를 버린
것도 같은 이유다 — 크기를 줄여도 "완료 전"이라는 창은 남는다. ③은 스레드와 큐를 더할 뿐 이 복사를 없애
주지 않는다. **대가**는 미결 write의 실패를 다음 호출에서 본다는 것이고, 그 상황은 파이프가 끊긴 때라
어차피 세션이 끝난다.

**그 복사가 새 위험을 만든다 — writer가 둘이다.** 리더 루프의 `writeInputNonBlocking`과 **메인 스레드**의
`writeInput`(예: `app_session.zig`가 프롬프트에 form feed를 보내는 자리)이 함께 있다. macOS는 둘 다 같은 fd에
써서 커널이 직렬화하지만, Windows 백엔드는 스테이징 버퍼와 `OVERLAPPED`를 **하나** 공유하므로 겹치면 커널
자료구조가 깨진다. 그래서 쓰기 쪽만 `SRWLOCK`으로 잠그고 **대기하는 동안에는 잠금을 잡지 않는다**(수거와
발행만 한 임계 구역). 읽기 쪽은 리더 전용이라 잠글 것이 없다.

### 4.1b EOF와 `ClosePseudoConsole` — POSIX와 가장 크게 갈리는 자리 (실측, 2026-08-16)

POSIX에서는 자식이 죽으면 슬레이브가 닫혀 master가 EOF를 본다. **ConPTY는 그렇지 않다.**

| 잰 것 | 결과 |
|---|---|
| 자식 종료 후 파이프가 끊기는가 | **아니다.** 3초를 더 기다려도 EOF가 없다 — conhost가 pseudoconsole이 살아 있는 동안 쓰기 끝을 붙든다 |
| 그러면 EOF를 내는 것은 | `ClosePseudoConsole`. 닫은 직후 읽으면 곧바로 EOF다 |
| 밀린 출력을 **안 읽은 채** 닫으면 | `ClosePseudoConsole`이 **106,891 ms** 막힌다 |
| 우리 읽기 끝을 **먼저 닫고** 나서 닫으면 | 더 나쁘다 — **379,922 ms** |
| **다 배수한 뒤** 닫으면 | **15 ms**, 유실 0 |
| 배수와 닫기를 **동시에** 하면 | 출력을 잃는다 — 142,949 바이트 중 65,573만 도착 |

여기서 두 규율이 나온다.

1. **배수한 뒤에 닫는다.** `waitIo`가 자식 프로세스 핸들도 함께 기다린다. 자식이 죽으면 계속 배수하다가
   무입력 창(`drain_quiet_ms`)만큼 조용해지면 그때 pty를 닫고, 그 결과로 오는 **진짜 파이프 끊김**을 EOF로
   낸다. 조용해질 때까지 기다리므로 출력을 잃지 않고, 다 배수한 뒤라 닫기가 15 ms다.
2. **`ClosePseudoConsole`을 인라인으로 부르지 않는다.** 최악이 분 단위라 UI 스레드에서든 리더 스레드에서든
   부르면 그만큼 멈춘다. 항상 **분리된 짧은 스레드**에 넘기고, 그 스레드는 `hpc` 하나만 소유해 세션 수명과
   얽히지 않는다.

**"배수한 뒤에 닫는다"는 뒷정리에도 적용된다.** `deinit`은 파이프 두 끝을 직접 닫지 않고 **배수 스레드에
넘긴다** — 그 스레드가 남은 출력을 버리며 읽어 conhost를 풀어 준 뒤에 닫는다. 그냥 닫으면 위 표의 379 s
경로를 그대로 만든다(`close`가 이미 시작한 닫기가 아직 도는 중이기 때문이다). 실측으로 확인했다:

| 상황 | `close()` | `deinit()` |
|---|---|---|
| 대화형 셸, 출력을 배수함 | 0 ms | 0 ms |
| 대화형 셸, 배수 안 함 | 0 ms | 0 ms |
| **3,000줄 덤프를 하나도 안 읽음** | **250 ms**(유예 창) | **0 ms** |

즉 최악이 앱 스레드에서 사라지고 분리 스레드로만 남는다.

**`close()`는 pty를 직접 닫지 않는다.** POSIX의 `SIGHUP → SIGKILL(-pid)`에 대응하는 것은 ⑴ 위 규율대로 pty
닫기를 넘기고 ⑵ 유예 뒤 **job을 닫는 것**이다. Windows에는 프로세스 그룹이 없어 `kill(-pid)`에 대응하는
것이 `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`뿐이다 — 이게 없으면 팬을 닫아도 셸의 손자들이 남는다. 그래서
자식은 `CREATE_SUSPENDED`로 만들어 job에 넣은 뒤 깨운다(먼저 달리게 두면 job에 들어가기 전에 손자를 만든다).

### 4.1a spawn 절차 — 순서가 계약이다 (실측, 2026-08-16)

ConPTY spawn은 API 호출 목록이 아니라 **순서**가 본질이다. 두 자리를 틀리면 자식이 pty에 붙지 않고 조용히
부모의 콘솔로 출력한다 — 실패가 에러 코드로 오지 않고 **잘못된 성공**으로 오므로 여기에 못박는다.

```text
1  CreatePipe(in_read, in_write) ; CreatePipe(out_read, out_write)
2  CreatePseudoConsole(size, in_read, out_write, 0, &hpc)      → hr must be S_OK
3  CloseHandle(in_read) ; CloseHandle(out_write)               ← ★ 반드시 4보다 먼저
4  InitializeProcThreadAttributeList(1) → UpdateProcThreadAttribute(0x20016, hpc)
5  si.StartupInfo.dwFlags   = STARTF_USESTDHANDLES             ← ★ 세 핸들 전부 NULL
   si.StartupInfo.hStdInput = hStdOutput = hStdError = NULL
6  CreateProcessW(…, bInheritHandles=FALSE, EXTENDED_STARTUPINFO_PRESENT, &si, &pi)
7  자식이 사는 동안: out_read를 읽고, in_write에 쓰고, ResizePseudoConsole(hpc, …)
8  ClosePseudoConsole(hpc) → 자식에게 EOF가 간다
```

- **★ 3번(닫기를 spawn 앞에)**: pseudoconsole이 이미 자기 사본을 갖고 있다. 우리 사본을 남긴 채 spawn하면
  자식이 붙지 않는다.
- **★ 5번(표준 핸들 비우기)**: `bInheritHandles=FALSE`만으로는 부족하다. 명시하지 않으면 자식이 부모의 표준
  핸들을 물려받아 pty를 무시한다(실측 — §6).
- **8번(닫는 순서)**: `ClosePseudoConsole`을 먼저 하면 밀린 출력이 버려질 수 있고, `ResizePseudoConsole`은
  그 뒤로 `0x80070006`이 된다. 배수 → 종료 확인 → 닫기 순으로 간다.

### 4.2 `SpawnRequest`에서 실제로 바꿀 것

**`command` + `args`는 그대로 둔다.** 중립 계약은 *"무엇을 어떤 인자로 띄울 것인가"*(의도)를 표현하고,
그것을 OS 형식으로 인코딩하는 것은 백엔드의 일이다 — macOS 백엔드가 `execve`의 `argv[]`로 바꾸듯,
Windows 백엔드가 `CreateProcessW`의 `lpCommandLine` 문자열로 조립한다. 계약을 문자열로 바꾸면 Windows의
인코딩 디테일이 중립 레이어로 새고, argv quoting(백슬래시-따옴표 규칙)이 계약에 얹힌다.

> `cmd.exe`가 표준 CRT argv 파싱을 쓰지 않는다는 점은 **백엔드가 조립할 때** 지켜야 할 사항이지 계약을
> 바꿀 이유가 아니다. config는 이미 따옴표를 지원하지 않는다([configuration-shell.md](configuration-shell.md)).

| 필드 | 어떻게 | 상태 |
|---|---|---|
| `command` + `args` | **그대로.** 조립은 백엔드 | 변경 없음 |
| `login: bool` | **중립 유지.** 이름이 메커니즘(`login(1)`)을 가리키므로 **의도**("사용자의 대화형 로그인 세션인가")로 재문서화하고, 메커니즘만 백엔드가 정한다 — macOS는 `login(1)` 래핑, Windows는 무동작 | 재문서화 완료 |
| `zdotdir` → **`shell_integration_dir`** → **`shell_integration`** | **일반화.** zsh라는 셸 이름이 새고 있었다 → "통합 자산 디렉터리"로, 다시 **메커니즘 축의 union**으로(§4.2a). 백엔드가 매핑한다(zsh·bash·WSL=`ZDOTDIR` 등 파일, PowerShell=인라인 `-Command`, cmd=`PROMPT`) | 이름 변경 완료. union 전환은 **W5** — **wire 키 `"zdotdir"`는 파일 갈래에 그대로 남는다**(§4.2a) |
| `term` | 백엔드가 의미를 정한다. 네이티브 Windows 셸엔 무의미하고 WSL·msys 프로그램에만 쓰인다 | 재문서화 완료 |

### 4.2a 통합 주입 seam — 갈리는 축은 OS가 아니라 **메커니즘**이다 (2026-08-16 결정)

`shell_integration_dir`은 *"통합 자산 파일이 놓인 디렉터리"*다. macOS에서 그것이 `ZDOTDIR`이 되고, zsh가
거기서 `.zshenv`(8,385바이트)를 읽어 OSC 133·OSC 7·편집키·`ssh` 래핑을 켠다. **파일이 있어야 성립하는
모양**이다.

그런데 §3.3이 정한 Windows 두 메커니즘은 파일을 만들지 않는다 — PowerShell은 인라인 `-Command`(파일을
쓰면 `ExecutionPolicy`가 막는다), cmd는 `PROMPT` 환경변수 값이다. **가리킬 디렉터리가 없다.**

**그래서 "Windows는 이 필드를 안 쓴다"로 가르면 틀린다.** Windows 호스트가 띄우는 셸에는 세 부류가 있다:

| 셸 | 메커니즘 | 자산 디렉터리 |
|---|---|---|
| PowerShell | 인라인 `-Command` | 없음 |
| cmd | `PROMPT` 환경변수 | 없음 |
| **WSL·git-bash·msys의 bash/zsh** | **rc 파일**(`ZDOTDIR` 등) | **있다** — 게스트 네임스페이스 경로 |

WSL은 ConPTY 입장에서 그냥 자식이라 **셸 통합이 그대로 온다**(§3.1). 즉 같은 Windows 백엔드가 파일 기반과
비-파일 기반을 **둘 다** 다룬다. 갈리는 축은 OS가 아니라 메커니즘이다.

**결정: 중립 계약이 그 축을 그대로 표현한다.**

```zig
pub const ShellIntegration = union(enum) {
    /// 파일 기반 — 이 디렉터리에 통합 자산이 있다(zsh `ZDOTDIR`, bash rc). WSL·git-bash도 여기다.
    assets_dir: []const u8,
    /// 파일 없는 주입 — 메커니즘은 백엔드가 고른다(PowerShell 인라인 `-Command`, cmd `PROMPT`).
    inline_injection,
};
```

**wire는 깨지지 않는다.** `assets_dir`은 기존 `"zdotdir"` 키를 **그대로** 쓰고, `inline_injection`만 새 키를
더한다. 그리고 세션 호스트 파서는 **모르는 키를 거부하지 않는다** — `spawnOptionalStringField`/`spawnBoolField`가
`obj.get(key) orelse <기본값>` 모양이라 없는 키는 기본값이 된다(코드로 확인). 그래서:

| 방향 | 결과 |
|---|---|
| 새 앱 → **옛 호스트** | 새 키를 못 보고 무시한다. Windows 네이티브 통합만 조용히 꺼지고 셸은 정상 기동(graceful) |
| 옛 앱 → 새 호스트 | 새 키가 없으니 기본값. macOS·WSL 경로는 **한 글자도 안 바뀐다** |

**버린 두 갈래와 이유**:

- **"non-null을 켜짐 신호로 재해석"** — 값의 **뜻을 바꾸는** 것이라, 위 표에서 유일하게 옛 호스트가 오해할
  수 있는 갈래다([session-host-upgrade.md](session-host-upgrade.md)가 tag를 자동 생성하지 않기로 한 이유와
  같은 자리). 게다가 "경로가 의미 없다"는 전제가 WSL에서 거짓이다.
- **"Windows는 이 필드를 안 쓴다"** — 같은 이유로 불가. WSL·git-bash가 Windows 호스트인데 파일 기반이다.

**나중에 PowerShell이 파일로 옮겨 가도** `assets_dir` 갈래로 바꾸기만 하면 된다 — 재해석을 택했다면 그때 필드
의미를 **또** 바꿔야 했다. macOS 스크립트가 8 KB인 것을 보면 그 날이 올 수 있다.

> **구현 시점**: 이 결정을 코드로 옮기려면 `SpawnRequest`와 그 RPC 짝(`server.zig`·`remote_runtime.zig`·
> `runtime_manager.zig`)을 함께 바꿔야 한다. **W5가 그 일을 한다.**

**wire tag가 필드 이름과 어떻게 갈리는지 실물로 확인해 둔다.** 직렬화는 익명 구조체 리터럴이라 **그 리터럴의
필드 이름이 곧 JSON 키**다 — 한 줄 안에서 왼쪽은 wire, 오른쪽은 Zig 필드다.

```zig
js.write(.{ … .zdotdir = request.shell_integration_dir, … });
//             ^^^^^^^^ wire tag(고정)   ^^^^^^^^^^^^^^^^^^^^ Zig 필드(바뀌었다)
```

일괄 치환하면 여기서 wire가 조용히 깨진다. 파싱 쪽도 같다 — `spawnOptionalStringField(p, "zdotdir")`가
문자열을 직접 쓴다.

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

**그런데 정규화만 하면 안 된다 — 중립 레이어가 "선두가 `/`인가"로 절대경로를 판정하고 있었다.** 적대적 검증과
후속 코드 리뷰에서 **여섯 자리**가 나왔고, 성격이 갈린다. 전부 W1.5에서 `src/path_shape.zig`로 옮겨 닫았다:

| 위치 | 옛 판정 | Windows 경로에서 | 성격 |
|---|---|---|---|
| `session/file_panel_bridge.zig` `normalizeAssetPath` | `raw[0]=='/'`→Absolute, 역슬래시→InvalidCharacter | **가드가 무력화된다** — 아래 | 가드 |
| `session/repo_path.zig` `isSafeRelative` | `path[0]=='/'`이면 절대로 보고 거부 | `C:/x`가 **상대 경로로 통과**했다 | 가드 |
| `session/git_write_command.zig` `validatePath` | 위와 같은 판정, `/`로만 세그먼트 분할 | `..\..\secret`이 `git add --` argv에 실렸다 — **읽기 쪽 쌍둥이만 고쳐 비대칭이 남아 있었다** | 가드 |
| `session/file_tree.zig`·`file_tree_mutation.zig` `pathWithin` | root 포함 판정이 `root=="/"` 특수 케이스를 둠 | 드라이브 루트(`C:/`)에 대응이 없었다 | 가드 |
| `file_tree_mutation.validateName`·`file_tree.validBasename` | 이름 한 칸에서 `/`와 NUL만 거부 | `..\..\evil.txt`가 **통째로 한 이름**이라 `..` 비교를 통과, join되면 루트 밖에 파일이 생겼다 | 가드 |
| `terminal/selection.zig` `filePathSpan` | 링크 감지가 `word[0]=='/'`로 절대경로 판정 | `C:\…`를 절대경로 링크로 못 잡았다(기능 결손) | **감지** |

**`normalizeAssetPath`가 특히 위험했다.** Windows 절대경로를 막고 있던 것은 `raw[0]=='/'`가 아니라
**역슬래시 거부**였다. 입구에서 `\`→`/`로 바꾸면 `C:\Windows\x`가 `C:/Windows/x`가 되어 세 검사(절대·역슬래시·
`..`)를 **전부 통과**하고 "상대 경로"로 받아들여진다. 자산 루트에 이어 붙어 존재하지 않는 경로가 되므로
당장 뚫리지는 않지만, **가드의 의도가 깨진다.**

**따라서 규칙을 둘로 나눈다.**

1. **구분자 정규화는 입구에서** 한다(`\`→`/`). L2가 받는 경로는 POSIX다
   ([layering-and-portability.md](layering-and-portability.md) §4.1). 도구는
   `path_shape.normalizeSeparatorsFor(os_tag, …)`이고 **Windows 기준일 때만 바꾼다** — POSIX에서 `\`는
   파일 이름 글자라 거기서 바꾸면 다른 파일을 가리킨다(W1.5에서 그 부류의 회귀를 한 번 냈다).
   실측: `$HOME`이 `C:\Users\me`일 때 terminfo 캐시가 `C:\Users\me/.cache/…`였고 정규화 후
   `C:/Users/me/.cache/…`가 된다.

   **입구는 셋이고 지금 걸린 것은 하나다.** ⓐ **환경변수**(`$HOME`·`$XDG_CACHE_HOME`) — W3에서 걸었다.
   ⓑ **OS API**(OSC 9;9 cwd·PEB `CurrentDirectory`·프로세스 열거) — 그 소비자가 W4·W7에서 생기므로 그때
   건다. ⓒ **config 파일** — **아직 안 걸렸다**(아래).

   > **알려진 공백 — config에서 온 경로는 정규화되지 않는다.** Windows 사용자는 `workspace.root = C:\proj`나
   > `shell.command = C:\…\pwsh.exe`처럼 자연스럽게 native로 적고, 로더는 그것을 **경고 없이 받아들인다**
   > (실측: `isValidWorkspaceRoot("C:\proj")`가 참, 값에 역슬래시가 그대로 남는다). 지금 문제가 안 되는 것은
   > 그 값을 소비하는 자리(`app_session`의 spawn·workspace)가 Windows에 아직 없기 때문이라, **W7에서 그
   > 소비자가 생기는 순간 살아난다.**
   >
   > 어디서 정규화할지가 결정 사항이다 — ⑴ 로더가 파싱하며(모든 소비자가 한 번에 덮이지만 중립 L2가
   > 자기 입력을 고치는 모양) ⑵ 플랫폼이 config를 소비할 때(계약의 "입구" 정의에 맞지만 소비처마다 걸어야
   > 한다). 어느 쪽이든 **경로 값 키만** 골라야 한다(`workspace.root`·`shell.command`·`window.background-image`
   > — 스키마에 `abs_path` 표식이 이미 있다).
2. **"절대경로인가" 판정은 `[0]=='/'`를 쓰지 않는다.** 드라이브 절대(`X:`)와 UNC(`//`)를 명시적으로 함께
   판정한다. 정규화 이전에 역슬래시로 거르던 가드는 **정규화 이후에도 같은 것을 막도록 다시 쓴다.**

이 여섯 자리를 고치는 것은 W3와 별개 슬라이스(**W1.5**, 완료)였고, 순서상 **정규화를 도입하기 전에** 했다 —
반대로 했으면 `normalizeAssetPath`가 잠깐 느슨해진 창이 생겼다. 이제 W3가 정규화를 도입할 수 있다.

### 5.1 가드와 감지는 술어가 다르다 (W1.5 결정, 2026-08-15)

네 자리가 같은 증상을 보였지만 **묻는 질문이 다르다.** 그래서 `src/path_shape.zig`가 술어를 **둘** 내놓는다.

| | 가드 (`isAbsolute`) | 감지 (`isDetectableAbsoluteFor`) |
|---|---|---|
| 질문 | "이 문자열이 **어떤 OS에서든** 위험한가" | "이 문자열이 **그 OS에서** 실제로 열리는 경로인가" |
| 문자열을 고르는 쪽 | 공격자(적대적 저장소·이상한 git 출력·사용자 입력) | 그 OS의 파일시스템 |
| 틀렸을 때 | 루트 밖 파일이 읽히거나 쓰인다 | 열리지 않는 밑줄이 뜬다 |
| 그래서 | **OS 무관하게 넓게 거부** | **주어진 OS 기준으로 좁게 감지** |
| 쓰는 곳 | `repo_path`·`git_write_command`·`pathWithin`·`validateName`·`normalizeAssetPath` | `terminal/selection.zig` |

**감지가 OS를 인자로 받는 근거**: 밑줄 span은 **콘텐츠를 가진 쪽**이 만든다. 원격 세션도 host가
`selection.collectViewportLinks`로 span을 모아 client에 보낸다(로컬 hover와 같은 분류기). 지금 호출자는
호스트 OS만 넘기지만, 그 값이 **파라미터**라서 두 가지가 따라온다. ⑴ 테스트가 두 OS를 모두 돌 수 있다 —
CI에 Windows 러너가 없으므로(ubuntu-latest·macos-15), 컴파일 타임 분기였다면 Windows 단언이 통째로
**공허참**이 된다. ⑵ ssh 원격 OS를 반영할 때 소비자를 다시 배선하지 않아도 된다(아래).

VS Code도 같은 규칙을 런타임 값으로 구현한다 — `terminalLocalLinkDetector.ts`의
`detectLinks(text, this._processManager.os || OS)`는 클라이언트가 아니라 **백엔드/PTY의 OS**를 쓴다.

**호스트 OS ≠ 콘텐츠 OS인 경우(알려진 한계)**: `maru ssh`는 ssh를 **로컬 pty**에서 돌리므로 화면 내용은
원격 OS의 것인데 감지는 로컬 OS 기준으로 돈다. `TerminalCore.sshRemoteDest()`(OSC 5379)가 그 사실을 이미
추적하고 있으니 seam은 있다. 지금 그 값을 쓰지 않는 이유는 **plain ssh에서는 어차피 링크가 열리지 않기**
때문이다 — 파일이 로컬에 없어 존재 게이트가 막는다. 감지해 봐야 밑줄만 늘어난다. 반대로 host-backed 원격
세션(`runtime.link_at`)은 host가 자기 core로 resolve하므로 지금 구조가 맞다. 그러므로 이건 **결손이 아니라
비용-편익 판단**이었다. hover 존재검증이 들어온 지금(§5.1a) 그 판단은 **더 강해졌다** — plain ssh는 경로
scope가 애초에 꺼져 있고(`linkScopesForTerm`), 켠다 해도 로컬에 없는 파일이라 밑줄조차 뜨지 않는다.

**감지 술어가 `isAbsolute`보다 좁은 이유**(실측). 감지된 토큰은 `TerminalCore.resolveClickedPath`로 가고,
거기서 `std.fs.path.isAbsolute`가 거짓이면 **cwd에 join**된다. 감지가 그보다 넓으면 "밑줄은 뜨는데 엉뚱한
파일을 연다"가 된다. Windows에서 잰 불일치:

| 토큰 | `path_shape.isAbsolute` (가드) | `std.fs.path.isAbsolute` | 감지하는가 |
|---|---|---|---|
| `C:\x`·`C:/x` | true | true | **예** |
| `C:relative` | true | **false** | 아니오 — join되면 엉뚱한 경로 |
| `a:b` | true | **false** | 아니오 — 흔한 토큰이라 오탐 |
| `\foo\bar` | true | true지만 `resolve`가 **드라이브 없는** `\foo\bar` 산출 | 아니오 |
| `\\server\share`·`//server/share` (UNC) | true | true | **아니오 — 알려진 공백**(이스케이프 출력 오탐 위험, 터미널에서 드묾. VS Code도 `\\?\C:` 확장형만 다룬다) |

그래서 감지는 **드라이브 + 구분자**(`C:\`·`C:/`)만 본다. VS Code의 `winDrivePrefix`도 같은 모양이다.
UNC 배제는 **술어가 직접** 한다 — 한때 호출자의 `!startsWith("//")`가 `//server/share`를 막고 있어서 술어의
문서와 반환값이 어긋나 있었고, 두 번째 소비자가 문서만 읽고 부르면 규칙이 갈릴 자리였다.

**드라이브 문자를 A–Z로 제한하지 않는다.** Win32는 그런 제한을 두지 않는다 — `RtlDetermineDosPathNameType_U`를
모사하는 `std.fs.path.getWin32PathType`도 아무 코드포인트나 받아서 `1:/x`·`λ:\x`·`::/x`가 전부 절대다(실측).
**가드가 OS 파서보다 좁으면 그 차이가 그대로 우회로다** — 처음 구현은 `isAlphabetic`을 요구해서 `1:/Windows/x`가
`repo_path`를 상대경로로 통과했다. 그래서 문자 종류를 묻지 않고 첫 코드포인트 뒤가 `:`인지만 본다. 감지도 같은
파서를 쓴다(다른 파서를 쓰면 그 간극이 다시 우회로가 된다).

**남은 비대칭(알려진 것)**: Windows에서 `/foo/bar`는 계속 감지하는데, Win32에서 그것은 `\foo\bar`와 **같은
종류**(`.rooted`)라 위에서 `\foo\bar`를 뺀 이유가 그대로 적용된다(실측: 둘 다 `isAbsWin=true`, 둘 다
`resolve`가 드라이브 없는 `\foo\bar`를 낸다). 그럼에도 남긴 것은 Windows 터미널에 git-bash·MSYS·WSL 출력으로
POSIX 모양이 흔히 뜨기 때문이다. 대가는 그 링크의 `access`가 터미널의 cwd 드라이브가 아니라 **프로세스의 현재
드라이브**에 묶인다는 것이다. 좁히는 쪽이 나은지는 실기 Windows 세션에서 그 출력이 얼마나 흔한지를 보고 정한다.

**macOS가 왜 불변이어야 했는가**(당시 근거): hover 밑줄은 매-mouseMove 비용 때문에 **존재검증을 하지 않았고**
(존재검증은 클릭에서만), 그래서 **감지 단계가 유일한 방어선**이었다 — macOS에서 `C:\x`를 감지하면 "밑줄은 뜨는데
클릭하면 아무 일도 없는" 상태가 100% 확정된다. 이후 hover에도 존재검증을 넣었으므로(§5.1a) 방어선은 두 겹이
됐지만, OS 인자 규칙은 그대로 둔다 — 안 그러면 `C:\x` 모양이 실재하는 파일과 우연히 겹칠 때 macOS에서 열린다.

**실측 (2026-08-15, Windows 10.0.19045)** — 같은 PoC를 고치기 전/후로 돌린 결과:

| 화면 문자열 | 전 (hover / click) | 후 (hover / click) |
|---|---|---|
| `C:\…\scratchpad\poc_linkdetect.zig` (**실재**) | ✗ / ✗ | **○ / ○** |
| `C:\…\scratchpad` (**실재 디렉터리**) | ✗ / ✗ | **○ / ○** |
| `C:\Users\me\proj\main.zig` (없음) | ✗ / ✗ | ○ / ✗ |
| `/Users/me/proj/main.zig` (없음) | ○ / ✗ | ○ / ✗ (불변) |

마지막 줄이 중요하다 — **"밑줄 O / 열림 X"는 새 상태가 아니다.** 존재하지 않는 POSIX 절대경로가 오늘도 그렇다.
Windows 경로가 다른 점은 macOS에서 그것이 *우연*이 아니라 *확정*이라는 것뿐이고, 호스트 OS 분기가 그것을 없앤다.

**부수 실측**: `std.c.access(F_OK)`가 Windows에서 정상 동작한다(존재 `0`, 미존재 `-1`). 존재 게이트는 W7에서
그대로 산다.

**알려진 오탐 — 의도적으로 남긴다.** 실제 도구 출력 21종을 훑어 6건이 나왔다: `n:\t`(한 글자 라벨 +
이스케이프 탭), `y:\`·`x:/`·`0:/`(드라이브 루트), `::/x`·`-:/x`(비알파벳 드라이브). 반대로 걸러진 것:
`12:30:45`, `1:30`, `3:15/4`, `a:b`, `ERROR:`, `NOTE:\n`, `C:relative`, `\\.\pipe\maru`, `:\x`, `warning:`,
`-rw-r--r--`, `http://h:8080/p` — **드라이브가 코드포인트 하나여야 하고 뒤에 구분자가 와야 한다**는 제약이
대부분을 막는다.

남긴 이유가 셋이다. ⑴ **대칭** — POSIX 감지도 같은 등급의 오탐을 낸다(`/t`, sed의 `/foo/bar/`). Windows
쪽만 좁히면 "왜 `/t`는 밑줄이 뜨는데 `C:\t`는 안 뜨나"가 설명되지 않는다. ⑵ **이것들은 Win32가 실제로
절대경로로 보는 문자열이다**(실측: `isAbsoluteWindows("::/x") == true`). 감지가 틀린 게 아니라 그 모양이
드물 뿐이다. ⑶ 좁히면 감지가 가드와 다른 파서를 쓰게 되고, 그 간극이 위에서 닫은 우회로를 다시 연다.

실제 피해(엉뚱한 파일 열기)는 두 겹이 막는다 — **부분집합 불변식**(감지 ⊆ `std.fs.path.isAbsolute`, 이제
테스트가 단언한다)이 cwd 오join을 막고, **존재 게이트**가 클릭을 막는다. 밑줄만 뜨고 클릭하면 아무 일도 없다.
**근본 해결은 hover에도 stat을 두는 것**(VS Code 방식)이었고, **그걸 했다**(§5.1a) — 위 오탐 6건은 그 경로가
그 기계에 실제로 있을 때만 밑줄이 뜬다(보통은 `Y:`·`N:` 드라이브가 없어 즉시 떨어진다. `::/x`·`-:/x`는 유효한
드라이브 이름이 아니라 항상 떨어진다). 감지 규칙 자체는 위에 적은 세 이유로 그대로 둔다.

**다른 터미널** (동작만 비교 — clean-room): VS Code는 백엔드 OS로 파싱하고 밑줄 **전에** 존재검증까지 한다.
WezTerm은 맨 파일 경로 링크를 지원하지 않는다(정규식 `hyperlink_rules`만, [issue #6257](https://github.com/wezterm/wezterm/issues/6257) 열림).
iTerm2는 Semantic History가 macOS 전용이라 이 문제가 없다.

### 5.1a hover도 존재검증을 한다 (결정 완료)

밑줄이 뜨는데 클릭하면 아무 일도 없는 상태 — 위 "알려진 오탐"이 남긴 잔여물이자, Windows 이전부터 macOS에
있던 것이다 — 를 닫았다. hover가 `selection.urlAnchorAt`(**분류만**) 대신 `TerminalCore.openableLinkAnchorAt`
(추출 → `resolveClickedPath` → stat, **클릭과 같은 술어**)를 부른다. URL은 그대로 통과하고, 경로만 실재할 때
밑줄이 뜬다.

미루어 뒀던 이유가 "매-mouseMove 비용"이었으므로 그 비용을 쟀다. **처음 잰 것은 stat 한 겹이었고 그 숫자는
제품 비용을 대표하지 않았다** — 적대적 검증에서 잡아 다시 쟀다. 아래는 `openableLinkAnchorAt` **호출 전체**를
잰 값이다(Windows 10.0.19045, D: 로컬 SSD, 400회 평균):

| hover 1회 | 변경 전(`urlAnchorAt`) | 변경 후 | 120Hz 이동 간격(8333 µs) 대비 |
|---|---|---|---|
| 링크 아님 — **대부분의 마우스 이동** | 2.0 µs | **2.0 µs** | 0.02 % |
| URL | 3.8 µs | **38.0 µs** | 0.46 % |
| 실재 경로 | 11.6 µs | **114.7 µs** | 1.38 % |
| 없는 경로 | 14.0 µs | **118.1 µs** | 1.42 % |

**stat 자체는 그중 3 %뿐이다**(`GetFileAttributesW` 3.5 µs). 나머지는 토큰 수집(`extractUrlAt`)과 정규화
(`std.fs.path.resolve` 23.9 µs)다. 즉 이 슬라이스가 더한 비용은 "디스크를 만져서"가 아니라 "분류만 하던 것을
추출까지 하게 해서" 생긴다. 두 겹의 완화가 있다 — ⑴ **링크가 아닌 단어에서는 비용이 0**이다(`urlAnchorAt`이
먼저 null을 내고 할당도 0회), ⑵ **수식키를 누른 동안에만** 돈다(`urlModifierHeld` 게이트).

**느려지는 경우.** UNC 죽은 호스트 **755 ms**, 라우팅 불가 IP **11 s**. 그런데 `isDetectableAbsoluteFor`가
`\\`로 시작하는 토큰을 감지에서 이미 떨어뜨리므로 stat까지 **도달하지 않는다**. 원격 세션은 `linkScopesForTerm`이
네 경로 scope를 전부 끄므로 host 왕복(`collectViewportLinks`)에도 새 비용이 붙지 않는다.

**꼬리 지연(합성 최악).** 화면을 가득 채운 한 토큰(9 KB, 45줄)이 경로 모양이면 hover 1회가 **3.29 ms**다
(변경 전 0.84 ms). `wordBoundsAt`이 공백으로만 토큰을 가르기 때문이다. **실제 출력에서는 재현되지 않았다** —
minified JSON 한 줄(720 B) 137.5 µs·data URI 29.2 µs는 분류에서 걸러져 **변경 전과 차이가 0**이고, `/`를 품어
분류를 통과하는 JWT(155 B)도 131.4 µs다. 그래서 지금은 완화를 두지 않고 이 상한만 기록한다.

**두지 않은 완화(기록).** 같은 anchor 위에서 마우스가 흔들릴 때 매번 전부 다시 계산한다 — 실측상 그 반복의
**89 %**(93.8 µs)가 1-entry 캐시로 사라진다. 절대값이 이동 간격의 1.4 %라 지금은 복잡도를 사지 않았다.
느린 FS가 확인되면 여기가 첫 수단이다.

**남은 미지수**: 매핑돼 있으나 연결이 끊긴 네트워크 드라이브(`Y:` → 죽은 서버)는 재지 못했다. 그 경로는 로컬
드라이브 문자로 보이므로 감지를 통과한다.

**존재검증은 OS마다 다른 API를 쓴다 — 인코딩 계약이 다르기 때문이다.** POSIX는 `std.c.access(F_OK)`,
Windows는 **`GetFileAttributesW`(UTF-16)** 다. CRT의 `_access`는 바이트 경로를 UTF-8이 아니라 **ANSI
코드페이지**로 읽는다. 실측(이 기계 ACP=949) — 이름만 바꾼 디렉터리 넷을 만들어 물었다:

| 디렉터리 이름 | Win32(UTF-16) | CRT `_access` | 고치기 전 제품 밑줄 | 고친 뒤 |
|---|---|---|---|---|
| `maru-ascii-9e1f` | 있음 | 있음 | O | O |
| `maru-café-9e1f` | 있음 | **없음** | **X** | **O** |
| `maru-한글-9e1f` | 있음 | **없음** | **X** | **O** |
| `maru-日本-9e1f` | 있음 | **없음** | **X** | **O** |
| `maru-🙂-9e1f` | 있음 | **없음** | **X** | **O** |

즉 **비-ASCII 이름이 든 경로는 클릭해도 안 열리고 밑줄도 안 떴다.** 이것은 hover 슬라이스가 만든 결함이 아니라
`resolveClickedPath`가 처음부터 갖고 있던 것인데(클릭이 이미 그 경로를 썼다), hover가 같은 술어를 쓰게 되면서
노출이 커져 적대적 검증에서 잡혔다.

**교체가 다른 답을 바꾸지 않았다는 것은 코퍼스로 확인했다.** 일화 몇 개가 아니라 `src/` 아래 실제 경로를 훑어
같은 경로를 두 API에 물었다 — **600건 대조에서 갈린 건수 0**이고(실재 300건·같은 경로에 없는 접미를 붙인 300건),
제품 경로로도 실재 파일 120건 중 밑줄이 안 뜬 것이 0건이다. 손으로 고른 경계 사례(뒤에 붙은 점 `build.zig...`,
대문자 `BUILD.ZIG`, 와일드카드, 예약 장치 이름 `C:\NUL`)에서도 두 API가 같은 답을 낸다 — 그 셋의 동작은
Win32가 정하는 것이라 CRT를 거치든 아니든 같고, 따라서 **이 슬라이스가 바꾼 것이 아니다**(`C:\NUL`이 경로로
resolve되는 것은 이전부터 그랬다). 비용도 같은 자릿수다(3.5 µs 대 3.6 µs).

같은 종류의 노출이 다른 곳에도 있는지 훑었는데, 바이트 경로를 쓰는 `std.c.*` 호출은 전부
`platform/macos/**`(UTF-8이 맞는 곳)이거나 W2가 Windows에서 막아 둔 `install-cli`였다 — 클래스가 닫혔다.

불변식은 테스트 둘이 지킨다 — `src/terminal/core.zig`의 *"hover와 클릭이 같은 답을 낸다 — 존재검증까지"* 가
실재/부재 경로에서 두 답이 어긋나지 않는지 단언하고, *"존재검증은 비-ASCII 이름이 든 경로를 놓치지 않는다"* 가
위 표를 고정한다(뒤엣것은 임시 디렉터리를 실제로 만들어 확인하므로 **두 OS 모두에서 돈다** — Windows 러너가
없어도 macOS/Linux CI가 계약의 절반을 지킨다).

**뒤따르는 효과**: §5.2 ⒜의 `bare_relative`(⑴)를 켤 수 있게 됐다. 스트레스 코퍼스에서 실경로 8건 / 오탐 5건이
나왔는데, 그 5건이 전부 실재하지 않는 토큰이라 이제 밑줄이 뜨지 않는다.

### 5.2 W1.5가 닫지 않은 것 (실측으로 재현됨)

코드 리뷰에서 나와 **재현까지 확인했지만** 이 슬라이스에서 고치지 않은 것들이다. 성격이 달라 따로 다룬다.

**⒜ 상대 경로 링크는 Windows에서 여전히 안 잡힌다.** `filePathSpan`의 네 갈래 중 절대만 OS-인지로 만들었다.
나머지 셋은 `/`를 요구한다 — `home_path`는 `~/`, `dot_relative`는 `./`·`../`, `bare_relative`는 토큰에 `/`가
있을 것. 실측:

| 토큰 | 감지 | (대조) POSIX 형태 | 감지 |
|---|---|---|---|
| `.\build.zig` | ✗ | `./build.zig` | ○ |
| `..\lib\y.rb` | ✗ | `../lib/y.rb` | ○ |
| `src\main.zig` | ✗ | `src/main.zig` | ○ |
| `~\notes.md` | ✗ | `~/notes.md` | ○ |

MSBuild·cmd·PowerShell·zig 자신의 에러 출력이 다 이 모양이라 **절대 경로 하나만 밑줄이 뜨고 옆의 상대 경로는
전부 죽어 있다.** 절대보다 오히려 흔한 형태다.

여기서 멈춘 이유: `bare_relative`의 오탐 억제가 *"슬래시 필수 + 점 필수 + 첫 세그먼트 문자집합"*이라
역슬래시를 넣으면 **이스케이프 출력(`\n`·`\t`)과 정면충돌**한다. **별도 슬라이스(W5.5)**로 둔다.

**그 오탐 스윕을 했다 (2026-08-16). 결론: 갈래마다 답이 다르다.**

후보 규칙을 같은 집합(누적 약 35건 — 실제 msbuild·zig·PowerShell·node 출력 형태 + 정규식·이스케이프 조각)에
차례로 돌렸다. 각 후보는 앞 후보가 깨진 자리를 메우려고 만든 것이다.

| 후보 | 오탐 | 미검출 | 왜 버렸나 |
|---|---|---|---|
| `\`를 그냥 구분자로 | 10 | 0 | `a\nb.txt`·`col\tvalue.csv`·`.\d+\.\d+`가 전부 링크가 된다 |
| `\` 뒤 이스케이프 글자 억제 | 0 | 2 | 억제 목록이 **흔한 디렉터리 이름과 충돌**한다 — `lib\std\…`(`\s`)·`tests\a.…`(`\a`)를 잃는다 |
| 나머지에 점·구분자 필수 | 0 | 3 | **POSIX 회귀** — 지금 잡히는 `./configure`를 잃는다 |
| 역슬래시 접두에만 위 규칙 | 4 | 2 | 점을 품은 정규식(`.\d+\.\d+`)이 뚫는다. 게다가 무확장 형태(`.\src`·`.\build`)를 **9/9 전부** 잃어 POSIX 형태와 비대칭이 생긴다 |
| **세그먼트 규칙**(아래) | **0** | **0** | 채택 후보 |

**채택 규칙 — 오탐의 공통 모양은 하나였다: `\` 뒤가 *알파벳 한 글자*(+선택적 수량자)다.**
`\d`·`\w`·`\s`·`\S`·`\n`·`\d+`·`\s*`·`\d{2,4}`·`\p{L}`가 전부 그 모양이고, 진짜 경로 세그먼트는
`src`·`build`·`Makefile`처럼 두 글자 이상이다. 그래서 규칙은 **"세그먼트가 알파벳 한 글자이거나
알파벳+수량자면 거부"** 하나면 된다. POSIX 접두는 손대지 않아 회귀가 0이고,
`.\src`·`.\Makefile`·`.\file(1).txt`·`.\한글\파일.txt`가 전부 살아남는다.

> **처음엔 "정규식 클래스 글자 목록"이었다.** 구현 뒤 적대적 검증이 그 목록의 구멍을 **11개** 찾았다 —
> 16진(`x`+두 자리)·유니코드(`u`+네 자리)·`e`·`c`+글자·`k`+숫자·`Q`·`h`·`R`·`N`이 전부 통과했다. 목록을
> 늘리는 대신 조건을 "알파벳 한 글자"로 넓혔다: 오탐이 11→4로 줄고, 잃는 것은 한 글자 디렉터리 이름이
> 20자에서 26자로 늘어나는 것뿐이다. **임의로 고른 목록이 규칙으로 바뀐 것**이 진짜 이득이다.
> 남는 구멍(한 글자 뒤에 수량자가 아닌 것이 붙는 모양)은 `path_shape.isEscapeLikeSegment`의 doc에 적었다.

**그런데 이 규칙은 `bare_relative`에는 안 통한다**(실측: 4건 중 3건 오탐). 거기서는 이스케이프가 그럴듯한
첫 세그먼트 **뒤에** 오고(`a\nb.txt`·`col\tvalue.csv`) 나머지가 평범한 파일명 모양이라, 세그먼트만 봐서는
구별할 수 없다. 그래서 W5.5는 이렇게 갈린다:

| 갈래 | 상태 |
|---|---|
| `dot_relative`(`.\x`·`..\x`)·`home_path`(`~\x`) | **닫혔다.** 위 세그먼트 규칙으로 오탐 0·미검출 0, W5.5에서 구현했다 |
| `bare_relative`(`src\main.zig`) | **규칙이 없다 — 구조적으로 없다**(아래). 정책 결정이 남는다 |

**`bare_relative`에 규칙이 없는 이유는 구조다.** 후보를 더 세게 잡아 봐도(확장자 화이트리스트: 오탐 3/4)
안 갈린다. 세그먼트로 갈라 보면 왜인지가 그대로 보인다:

```text
src\main.zig      → [src][main.zig]      ← 잡아야 하는 것
line1\nline2.log  → [line1][nline2.log]  ← 막아야 하는 것
```

**모양이 같다.** 첫 세그먼트 길이도, 마지막 세그먼트의 확장자(`.log`·`.csv`·`.txt`는 전부 진짜 확장자)도
구별에 못 쓴다. 둘을 가르는 것은 "앞 문맥에서 이 `\n`이 이스케이프였는가"인데, 감지는 **토큰 하나만** 본다.
접두 갈래가 되는 이유도 여기서 나온다 — `.\`·`..\`·`~\`는 이스케이프가 만들 수 없는 시작 모양이다.

남은 갈래는 둘이다. **⑴ Windows에서만 받고 오탐을 감수한다**(터미널에 찍힌 이스케이프 문자열이 밑줄 뜨고
클릭 가능해진다) **⑵ 지금처럼 POSIX 철자만 둔다**. W5.5는 ⑵ 상태로 끝냈다 — 규칙이 없는 쪽을 임의로
켜지 않는다.

> **측정의 한계**: 위 수치는 규칙을 **재구현해** 잰 것이다(제품의 `linkSpanInWord`는 현재 동작 확인에만 썼다 —
> 역슬래시 4형태 미검출 4/4, POSIX 4형태 검출 4/4). W5.5를 구현할 때는 **제품 함수를 직접 몰아** 같은 집합을
> 다시 돌려야 한다. 그리고 코퍼스는 손으로 모은 것이라 완전하지 않다 — 실제로 이 스윕에서 두 번, **규칙을
> 만든 뒤에 사례를 고르는 편향** 때문에 "오탐 0"이 나왔다가 다음 라운드에 깨졌다.

**⒝ 루트 스트라이핑 두 곳이 구분자를 정확히 한 바이트로 가정한다.**
`platform/macos/file_tree_mutation_backend.zig:336`의 `parent_path[root.len + 1 ..]`와
`file_tree_backend.zig:354`의 같은 모양이다. 루트가 `/`일 때 `parent_path[2..]`가 되어 첫 세그먼트가 잘린다
(`/Users/x` → `sers/x`). **이 커밋 이전부터 있던 버그**이고 macOS 코드라 W1.5 범위 밖이지만, `pathWithin`이
받아들이는 "구분자로 끝나는 루트"의 집합이 `{/}`에서 `{/, C:/}`로 넓어졌으므로 **백엔드를 이식할 때 반드시
함께 고쳐야 한다**(W7). `endsWithSep`를 그대로 쓰면 된다.

**⒞ 가드가 합법 POSIX 파일명을 거부한다(의도된 대가).** `Q:answers.md`·`a:b.txt`처럼 `<코드포인트>:`로 시작하는
이름은 POSIX에서 합법인데 `isAbsolute`가 절대로 판정해 거부한다. Windows 파일명에는 `:`를 쓸 수 없으므로 이
대가는 POSIX 전용이다. 저장소에 그런 이름이 있으면 그 파일의 diff를 못 연다. 드라이브 상대(`C:x`)를 위험으로
보는 판단과 같은 뿌리이고, **정상 파일을 잃는 쪽보다 루트 밖을 읽는 쪽이 더 나쁘다**고 보아 이 방향을 택했다.
`path_shape.isAbsolute`의 doc 주석이 이 대가를 명시한다.

### 5.3 Windows 경로 레이아웃 — `%LOCALAPPDATA%\maru\` (W8.5 결정)

`src/main.zig`와 config 로더가 **여섯 자리**에서 사용자별 경로를 요구한다 — terminfo 캐시, 컨트롤 소켓
디렉터리, `maru ssh` control path, `install-cli` 위치, `trace anonymize`의 매칭 키, 그리고 config 파일.
전부 각자 `getenv("HOME")`을 불렀고, Windows는 `HOME`을 주지 않는다.

#### 무엇이 깨져 있었나 (실측, Windows 10.0.19045)

`maru terminfo --path`:

| 환경 | `HOME` | 결과 | 판정 |
|---|---|---|---|
| git-bash | MSYS가 넣고 Win32 형태로 변환해 전달 | `C:/Users/<user>/.cache/maru/terminfo` | 정상 — **그래서 이 결함이 가려져 있었다** |
| cmd.exe · PowerShell | 없음 | 안내 후 exit 1 | 기능이 죽는다 |
| `HOME=""` (빈 문자열) | `""` | **`/.cache/maru/terminfo`, exit 0** | **조용히 틀린다** |

세 번째 줄이 계획에 없던 것이다. `getenv`는 빈 값에도 non-null을 주므로 `orelse` 가드가 발화하지 않고,
드라이브 루트의 엉뚱한 경로가 **성공으로** 나간다. `resolveClickedPath`가 `~/` 확장에서 같은 함정을 절대
경로 검사로 이미 막고 있었는데 여기는 아니었다.

#### 결정 — 어느 진영인가

처음에는 "단일 레이아웃 유지(`$HOME/.cache`) + `%USERPROFILE%` 폴백"으로 갔다가, 선례를 조사하고 뒤집었다.

| 터미널 | Windows config | 근거 |
|---|---|---|
| **Warp** | `%LOCALAPPDATA%\warp\Warp\config\` (테마·탭 config만 `%APPDATA%`) | `directories` 크레이트 관례 — *"portable"은 Roaming, "machine-specific"은 Local*. macOS는 `~/.warp/`, Linux는 XDG — **OS마다 그 OS 관례**. `~/.warp/`는 Windows에서 **안 읽는다**고 명시 |
| **Alacritty** | `%APPDATA%lacritty\` **만** | Unix에서는 XDG 5단계를 보지만 Windows에서는 `$HOME/.config`를 아예 안 본다 |
| Windows Terminal | `%LOCALAPPDATA%\…\LocalState` | MSIX 샌드박스가 **강제**한다. Windows 전용 앱이라 이식성 고민이 없어 **선례로 치지 않는다** |
| **WezTerm** | `$HOME/.config/wezterm`·`~/.local/share/wezterm` | appdata를 **의도적으로 거부** — *"it works against the idea that the same configuration layout can be used on multiple operating systems"*, *"bootstrap my dotfiles from git on any OS"* |

**2:1로 플랫폼 네이티브**이고 WezTerm은 소수 입장임을 본인이 밝힌다.

**결정적인 것은 웹뷰다.** WebView2에는 WKWebView의 `nonPersistent()` 같은 인메모리 모드가 **없다** — user
data folder(쿠키·localStorage·IndexedDb·디스크 캐시)를 항상 디스크에 만든다. Microsoft의 Win32 지침은
*"You should specify the same folder where all other app data is stored"* 이고, 기본 위치(`<exe>.WebView2\`)는
설치 디렉터리가 보호돼 **쓰지 말라**고 한다. 즉 **maru의 데이터 base가 곧 수백 MB짜리 Chromium 프로필
위치**가 된다 — 숨은 `~/.cache`가 아니라 사용자가 찾을 수 있는 곳이어야 한다.

**그래서 Windows에서는 `%LOCALAPPDATA%\maru\` 아래로 모은다:**

| | 경로 |
|---|---|
| config | `%LOCALAPPDATA%\maru\config` |
| terminfo 캐시 | `%LOCALAPPDATA%\maru	erminfo` |
| 컨트롤 소켓 디렉터리 | `%LOCALAPPDATA%\maru\control` |
| (W8) WebView2 UDF | 같은 뿌리 아래 — W8이 이름을 정한다 |

Roaming(`%APPDATA%`)은 쓰지 않는다 — Warp도 `settings.toml`을 Local에 둔다(창 크기·경로 등 기계별 값이
섞인다). **탈출구는 남긴다**: `$MARU_CONFIG`와 `$XDG_CACHE_HOME`이 **모든 OS에서 최우선**이라, dotfiles로
설정을 옮기는 사용자는 예전 자리를 그대로 쓸 수 있다.

**지금이 옮기기 유일하게 싼 순간이다** — W7 전이라 Windows 사용자가 0명이다. 나중에 옮기면 실제 사용자
디렉터리를 마이그레이션해야 한다. 그래서 캐시만 먼저 옮기고 config를 미루는 대신 **레이아웃 전체를 한
슬라이스에서** 정했다.

**POSIX 회귀 0**: `os_tag`가 Windows가 아니면 `cacheBaseFor`가 null을 내고 호출자가 예전대로
`<home>/.cache`로 가며, `defaultConfigPathFor`도 `<home>/.config/maru/config`를 그대로 낸다.

#### 구현

판정은 **`src/user_paths.zig`** 하나가 소유한다(순수·`os_tag` 인자 — Windows 러너가 없어도 두 갈래가 모든
타깃에서 테스트된다). 환경변수 읽기는 호출자(`main.zig`·`config/loader.zig`·`cli/control_client.zig`·
`pty/macos.zig`)가 한다.

- `homeDirFor(os_tag, home, userprofile)` — 값이 **절대 경로**여야 홈으로 치고(빈 문자열·상대 경로 차단),
  Windows면 `%USERPROFILE%`로 폴백한다. POSIX에서는 폴백하지 않는다(거기서 `USERPROFILE`은 maru가 정의한
  적 없는 이름이라, 우연히 설정돼 있으면 의도치 않은 위치를 쓴다).
- `cacheBaseFor(os_tag, xdg_cache_home, localappdata)` — `cacheDirZ`·`controlDir`가 받는 base.
- `defaultConfigPathFor(...)` — config 파일 자리.

**해석기를 하나로 만들었다.** `terminfo_cache`의 셸 명령 넷이 예전에는 `${XDG_CACHE_HOME:-$HOME/.cache}`로
경로를 **다시 확장**했다. 규칙이 둘(Zig·셸)이라 base를 OS별로 바꾸는 순간 조용히 갈린다 — 실제로
`pty/macos.zig`가 `cacheDirZ`로 dir을 구해 놓고 셸에는 다시 확장시키는 중복이 있었다. 이제 Zig가 정한 값을
`shSingleQuote`로 인용해 **리터럴로** 넘긴다(경로에 공백·`$`·백틱이 있어도 안전하다).

#### 이 슬라이스가 닫지 않은 것

**`maru terminfo`의 셸 의존 — 무엇이 되고 무엇이 안 되는가.** `system()`은 Windows에서 `%COMSPEC%`
(= cmd.exe)로 간다(msvcrt). **프로세스를 어느 셸에서 띄웠든 그렇다** — 적대적 검증에서 git-bash로 띄워도
같다는 것을 확인했고, 그래서 처음 쓴 *"git-bash에서 실행하세요"* 안내를 지웠다(실측: cmd.exe가 `d='...'`를
명령 이름으로 읽어 `'d' is not recognized`).

| 서브커맨드 | Windows | 이유 |
|---|---|---|
| `--path` | **된다** | 순수 Zig — 셸을 안 쓴다 |
| `--clear` | `rm.exe`가 PATH에 있으면 된다 | 명령이 `rm -rf '<경로>'` **단일 외부 명령**이라 cmd.exe도 실행한다(git 설치본에 `rm.exe`가 있다) |
| `--status` | **판정 불가** | 프로브가 `TERMINFO=<dir> infocmp …` — `VAR=값 명령` 접두는 POSIX 문법이라 cmd.exe가 못 읽는다 |
| `--refresh` | **안 된다** | `d=...; rm -rf "$d"; …` 대입·확장이 POSIX 문법이다. 무엇을 설치해도 안 된다 |

세 번째 줄이 적대적 검증에서 나온 것이다. 프로브가 **항상 실패**하므로 예전 코드는 캐시가 실제로 컴파일돼
있어도 늘 `"아직 컴파일 안 됨"`이라고 **단언**했다 — 모르는 것을 아는 것처럼 말하는 쪽이 더 나쁘다. 지금은
`"상태: 알 수 없음"`이라고 답한다.

이 슬라이스가 한 것은 셋이다 — ⒜ `--refresh` 안내가 `tic`만 가리키던 것을 **원인(POSIX 셸 문법)** 을 짚게
고쳤고, ⒝ `--clear`가 `system()` 반환값을 **버리고** "삭제됨"을 exit 0으로 찍던 것을 고쳤으며(지우지 못했는데
지웠다고 말하고 있었다), ⒞ `--status`가 모르는 것을 단언하던 것을 고쳤다. `--refresh`를 Windows에서 실제로
돌리는 것은 `maru ssh`의 `/bin/sh` 문제와 **같은 결정**이라 W9에서 함께 정한다.

> **셸 명령이 리터럴 경로를 받는 것은 실기로 확인했다.** 공백과 `$`가 든 경로(`/tmp/maru w85$real/…`)로 진짜
> `sh` + 진짜 `tic`을 돌려 exit 0(`xterm-maru` 해석 성공)과 `.maru-version` 생성을 봤다. 주입 시도 8종
> (`'; touch …`, `` `touch …` ``, `$(touch …)`, 개행 삽입 등)은 진짜 `sh`에서 **한 건도 실행되지 않았다.**
> 예전 파라미터 확장 방식에서는 `$`가 든 캐시 경로 자체가 불가능했으므로, 이건 개선이기도 하다.

**§7 격리 결정이 그대로 오지 않는다(W8 항목).** macOS는 비신뢰 브라우저 패널에
`WKWebsiteDataStore.nonPersistent()`를 써서 "쿠키·localStorage·캐시가 디스크에 안 남는다"를 보장하는데,
WebView2에는 대응물이 없다. UDF는 항상 생기고 지울 수 있을 뿐이다(`ClearBrowsingData` 또는 종료 시 UDF
삭제). W8이 그 자리를 정해야 한다.

## 6. 실측 (2026-08-15, Windows 10.0.19045, zig 0.16.0)

계약을 쓰기 전에 PoC로 확인한 것과 확인하지 못한 것을 정직하게 남긴다.

| 항목 | 결과 |
|---|---|
| cmd `PROMPT` 주입 | ✅ `ESC]9;9;C:\...ESC\` + `OSC 133 A/B/D` 캡처 |
| PowerShell `prompt` 오버라이드 | ✅ **pwsh 7.6.3**(전체 `OSC 133 D/A/B` + OSC 7)과 **Windows PowerShell 5.1.19041**(OSC 7) 양쪽에서 **인라인 `-Command`로** 캡처. 파일(`.ps1`) 방식의 정책 내성은 **미증명**이다 — 처음 측정이 프로세스 정책 `Bypass` 환경이었다(§3.3) |
| PEB cwd(2단) | ✅ 자기 프로세스 대조 일치, 남의 셸 프로세스도 읽힘. **드라이브 루트는 `C:\`로 와서 순진한 트림이 `C:`(드라이브 상대)를 만든다**(§3.5) |
| 프로세스 열거 | ✅ 5,328개 열거, `ppid` 체인으로 부모-자식 확인 |
| **`waitIo` 대응**(§4.1) | ✅ overlapped named pipe 비동기 read가 `ERROR_IO_PENDING`으로 등록되고, 상대 write는 read 이벤트로·`SetEvent`는 wake 이벤트로 깨우며, 조용하면 스핀 없이 `WAIT_TIMEOUT`. **`CreatePseudoConsole`이 named pipe 핸들을 받는다**(`hr=S_OK`) |
| **overlapped write 의미**(§4.1) | ⚠️ 4 KiB 버퍼에 512 KiB write → 즉시 `ERROR_IO_PENDING`에 `written=0`, 완료 전 `GetOverlappedResult`는 `ERROR_IO_INCOMPLETE`에 `bytes=0`이라 **부분 진행을 볼 수 없다**. 상대가 8 KiB를 읽어도 미완료, 전량(524,288 bytes)을 읽어야 완료. `POLLOUT`+부분쓰기와 의미가 달라 **백엔드가 흡수해야 한다** |
| **ConPTY 자식 attach**(§4.1) | ✅ **닫혔다**(2026-08-16). 자식 안에서 `cmd /c mode con`이 `줄: 37 / 열: 123` — `CreatePseudoConsole`에 넘긴 COORD 그대로다. 대화형 왕복 2회, `ResizePseudoConsole`은 **자식이 살아 있는 동안** S_OK, pwsh도 동일, 부모가 콘솔을 가진 경우도 동일 |
| **ConPTY EOF**(§4.1b) | ⚠️ 자식이 죽어도 파이프가 **안 끊긴다**. EOF를 내는 것은 `ClosePseudoConsole`이고, 그것은 밀린 출력을 안 읽었으면 **106,891 ms**(읽기 끝을 먼저 닫으면 **379,922 ms**) 막힌다. **다 배수한 뒤** 닫으면 **15 ms**에 유실 0. 동시에 하면 142,949 중 65,573만 도착 |
| **W4 백엔드 end-to-end** | ✅ `maru demo`·`app-pty-smoke`·`app-pty-loop-smoke`가 Windows에서 산출물을 낸다. `app-pty-interactive-loop-smoke`는 **pwsh 7**을 띄워 프레임 루프로 친 입력이 표식으로 돌아오고 셸이 `exited(code=0)`으로 끝난다 |
| **ConPTY의 핸들 누수** | ⚠️ **세션마다 커널 핸들 1개가 영구히 남는다**(30초를 기다려도 회수되지 않고 선형으로 누적). 원인을 순수 Win32로 층별 분리해 확인했다 — 파이프 4개 생성·해제만: **0**, job 생성·해제만: **0**, `CreatePseudoConsole`+`ClosePseudoConsole`을 더하면: **20회에 20개**. 즉 우리 코드가 아니라 **ConPTY API 자체**다. 팬을 여닫을 때마다 1개씩 늘어나므로 장시간 세션에서 서서히 쌓인다 |
| **PowerShell 통합 주입**(§3.3) | ✅ 인라인 `-Command`로 `prompt`를 정의하면 OSC 9;9·133;A가 나오고 `cd` 뒤 새 cwd가 정확히 보고된다. **`-NoExit`이 없으면 셸이 곧바로 끝난다.** 사용자 프로필이 `prompt`를 정의해도 우리가 이긴다(프로필 먼저, `-Command` 나중 — 임시 홈으로 실측) |
| **cmd 통합 주입**(§3.3) | ✅ `PROMPT` 환경변수만으로(인자 0개) 9;9·133;A가 나오고 `cd /d` 뒤 새 cwd가 보고된다. 사용자 프롬프트 뒤에 우리 OSC를 **앞에만** 덧붙이면 둘 다 살아남는다 |
| **셸 통합 주입 end-to-end**(W5) | ✅ 통합을 켜면 cmd가 `OSC 133;A` + `9;9;<cwd>` + `133;B`를, pwsh가 거기에 `133;D;<코드>`까지 낸다. **대조군**(통합 OFF)에서는 OSC가 하나도 안 나온다. 사용자 `PROMPT`도 보존된다 |
| **pwsh의 `$?` 포착 시점** | ⚠️ `prompt` 함수 안에서 `$?`를 **맨 앞에서** 읽어야 한다. 다른 문장 뒤에 읽으면 그 문장의 성공을 보고 `133;D`에 **0**이 실린다(실측: `cmd /c exit 3` 뒤인데 0). 고친 뒤 `exit 3` → `3`, `exit 0` → `0` |
| **한글(비-ASCII) 경로·환경** | ✅ 한글 cwd로 spawn하면 자식이 `D:\…\한글폴더\하위 디렉터리`를 그대로 본다(공백 포함). 한글 환경값도, 커맨드라인의 한글 인자도, pwsh가 내는 OSC 9;9 payload의 한글 경로도 그대로다(ACP·콘솔 CP 둘 다 949인 기기) |
| **`cmd /c <문자열>`의 따옴표** | ⚠️ 우리 인용기는 CRT 규칙대로 `"`를 `\"`로 이스케이프하는데 **cmd는 그 규칙을 모른다** — `cmd /c "type \"파일.txt\""`는 "지정된 경로를 찾을 수 없습니다"로 끝나고 따옴표를 뺀 형태는 정상이다. **제품 경로는 무관하다**(maru는 셸을 인자 없이 직접 띄운다). 데모·스모크 fixture만 이 형태를 쓰므로 "스크립트에 `\"`를 넣지 않는다"를 테스트로 강제한다 |
| **cmd의 한 줄 입력 상한** | ⚠️ 한 줄이 6,000바이트면 실행되고 **9,000바이트면 통째로 무시된다**(콘솔 줄 입력 상한). 백엔드는 20 KiB를 여러 줄로 나눠 주면 전량 전달한다 — 즉 **우리 쪽 한계가 아니라 cmd의 한계**다 |

**ConPTY를 "환경 탓"으로 적었던 것은 오판이었다 — 기록으로 남긴다.** 위 항목은 한때 "자식이 pty에 붙는 것만
미확인, 에이전트 샌드박스가 conhost 세션을 못 띄우기 때문"으로 적혀 있었다. 실제 원인은 **우리 코드 두 곳**이다.

| 무엇이 틀렸나 | 진짜 원인 | 어떻게 고치나 |
|---|---|---|
| 자식 출력이 pty가 아니라 **우리 stdout**으로 나갔다 | `bInheritHandles=FALSE`인데도 자식이 부모의 표준 핸들을 물려받았다. stdout을 파일로 돌리니 마커가 그 파일에 떨어져(16 bytes) 인과가 증명됐다 | `dwFlags`에 `STARTF_USESTDHANDLES`를 세우고 `hStdInput`/`hStdOutput`/`hStdError`를 **전부 NULL**로 둔다 = "물려받을 것이 없다" |
| 읽은 것이 conhost VT init 48바이트뿐이라 "안 붙었다"고 읽었다 | 한 번만 `ReadFile`하고 멈췄다 | `PeekNamedPipe`로 데드라인까지 폴링해 모은다 |
| `ResizePseudoConsole`이 `0x80070006`(잘못된 핸들) | `ClosePseudoConsole` **뒤에** 불렀다 | 자식이 살아 있는 동안 부른다 |

원인을 C로 다시 써서 같은 숫자가 나온 것(`attrSize=48`, `sizeof(STARTUPINFOEXW)=112`, `flags=0x80000`)을
"바인딩이 아니라 환경"의 근거로 삼았는데, **두 구현이 같은 실수를 공유했으므로 그 대조는 아무것도 가르지
못했다.** 교훈: 재현 대상이 같은 저자의 같은 가정을 담고 있으면 대조군이 아니다. 실제 대조군은 나중에 세운
"표준 핸들을 비우지 않은 판"이었고, 그것은 기대대로 실패하며 마커를 우리 stdout으로 흘렸다.

**부모에 콘솔이 있을 때**(=사용자가 터미널에서 `maru`를 띄우는 조건)도 이 환경에서 닫았다. `AllocConsole`과
`AttachConsole(ATTACH_PARENT_PROCESS)`은 둘 다 `err=5`로 막히지만, `CREATE_NEW_CONSOLE`로 자기 자신을 다시
띄우면 그 프로세스는 진짜 콘솔 소유자(`GetConsoleWindow() != null`, 버퍼 120x9001)이고 거기서 attach가
그대로 됐다.

## 7. 베이스

- **ConPTY**: Win32 공개 API(`CreatePseudoConsole`·`ResizePseudoConsole`·`PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE`).
- **OSC 9;9**: ConEmu가 정의한 공개 시퀀스. Windows Terminal이 채택하고 Microsoft가 셸 통합 문서로 안내한다.
  **동작만 비교했고 레퍼런스 코드 표현은 옮기지 않았다**([project-rules.md](project-rules.md) clean-room).
- **PEB cwd**: 비문서화 구조체. Process Explorer 계열이 같은 경로를 쓴다는 사실만 근거이고, 구현은 공개
  문서(`NtQueryInformationProcess`·`ReadProcessMemory`)와 자체 측정으로 만든다.
- **셸 티어와 통합 주입 형태**: macOS의 `ZDOTDIR` 주입을 Windows 셸에 옮긴 maru 독립 설계다.

## 8. 아직 정하지 않은 것

- **WSL 세션의 ADE 축 셋**(§3.1). 에이전트 탐지·cwd 2단·경로 소비가 VM 경계에서 끊긴다. 후보: ① 셸 통합이
  포그라운드 명령을 OSC로 보고하게 해 proc_name 폴링을 대체, ② `wsl.exe -e`로 주기적 조회(폴링마다 프로세스
  생성이라 비싸다), ③ WSL 세션은 에이전트 축을 끈다(degradation 명시). 경로는 `\\wsl$\` 변환이 별도 결정이다.
- **`publishBrowserResult`의 파일 권한.** `src/main.zig`가 `maru browser executeScript --out <경로>`의 결과를
  `Permissions.fromMode(0o600)`(소유자 전용)으로 쓴다. Windows에는 POSIX mode가 없고 **ACL**(누구에게 어떤
  동작을 허용/거부하는지의 항목 목록)이라 그 값을 그대로 옮길 수 없다.

  | | 내용 | 문제 |
  |---|---|---|
  | ① | ACL을 지정하지 않고 **부모 디렉터리 상속**에 맡긴다 | 이 파일은 `Dir.cwd()` 기준 **사용자가 `--out`으로 준 경로**라 어디 놓일지 모른다. 홈 아래면 대개 사용자 전용이지만 공유 폴더·네트워크 드라이브면 그 폴더 권한을 물려받는다 — **보장이 아니다** |
  | ② | 현재 사용자 SID만 허용하는 ACL을 **명시적으로 구성** | POSIX `0600`과 같은 보장(폴더 무관). 대가는 Windows 보안 API(`OpenProcessToken`·`InitializeAcl`·`AddAccessAllowedAce`·`SECURITY_ATTRIBUTES`) 유입 |

  **이 결정은 W2를 막지 않았다.** `publishBrowserResult`는 **컨트롤 소켓 왕복을 마친 뒤에만** 호출되는데,
  W2가 그 소켓을 "인스턴스 없음"으로 빠지게 했으므로 이 코드는 Windows에서 **도달 불가**다. 실제 권한 정책은
  아래 **컨트롤 플레인 transport**를 이식할 때 함께 정한다.

  **W2가 한 것은 "컴파일만 되게"가 아니라 명시적 차단이다.** Windows의 `Permissions`는 POSIX mode가 아니라
  ACL을 나르는 `FILE.ATTRIBUTE` enum이라 `fromMode`가 **아예 없어서**, 컴파일을 통과시키려면 `.default_file`을
  넣는 수밖에 없었다. 그런데 그 값은 "부모 디렉터리 ACL을 상속한다"는 뜻이고 — 이 파일은 사용자가 `--out`으로
  준 임의 경로라 — 위 표의 ①을 **결정한 적 없이 채택**하는 셈이 된다. 그래서 `error.UnsupportedOnWindows`로
  막았다. 컨트롤 플레인을 이식하는 사람이 이 결정을 잊으면 조용히 넓은 권한으로 쓰이는 대신 **여기서 시끄럽게
  실패한다.**
- **cwd 2단(PEB)을 둘 것인가**(§3.5). Ghostty는 안 두고 "모른다"를 표현하며, macOS maru는 둔다. Windows에서는
  비문서화 비용이 더해지므로 별도 판단이 필요하다.
- **GPU 백엔드와 웹뷰 합성 모델**. WebView2는 별도 HWND라 macOS의 `CALayer` subview 3겹 합성이 그대로
  오지 않는다. 둘은 같은 결정이므로 4단계에서 함께 정한다.
- **`main.zig`의 컨트롤 플레인 transport**. unix domain socket을 named pipe로 옮기는 설계. 초기에는
  "인스턴스 없음"으로 graceful하게 빠지는 것으로 충분하다.
- ~~**hover 밑줄에도 존재검증을 둘 것인가**~~ → **둔다(결정 완료, §5.1a).** 재야 할 것으로 적어 둔 두 비용을
  실측했고 둘 다 예산 안이었다. 밑줄과 클릭이 이제 같은 술어를 쓴다.
- **배포**. 코드 서명·인스톨러·업데이트 경로는 [배포·업데이트 전략](distribution.md)이 macOS 기준으로
  쓰여 있다.

> **여기서 빠진 것 = 결정된 것.** `OSC 9;9`의 host는 §3.2a에서 결정됐고(9;9은 host를 건드리지 않는다), 그
> 결정이 안고 가는 잔여 위험과 재검토 트리거는 §3.2a "받아들인 위험"이 소유한다. **셸은 이제 전부 결정됐다** —
> 기본값은 PowerShell(§3.1a), 바꾸는 수단은 `shell.windows-shell`(종류)·`shell.command[.windows]`(경로),
> config의 OS 분기는 **일반 메커니즘**(키 접미)으로 넣었다. 그 셋의 우선순위와 규칙은 §3.1a와
> [configuration.md](configuration.md) "OS별 값"이 소유한다.
