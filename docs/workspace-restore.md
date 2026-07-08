# Workspace Restore 전략

이 문서는 Maru의 workspace restore가 무엇을 저장하고, 무엇을 저장하지 않는지 정한다.

## 초보자용 설명

workspace restore는 "실행 중이던 shell process를 그대로 냉동했다가 다시 살리는 기능"이 아니다.

운영체제의 process, PTY file descriptor, foreground job은 앱을 끄면 사라진다. 이것을 그대로 저장할 수 없다.

Maru가 저장하는 것은 다시 시작하기 위한 **설명서**다.

```text
저장하는 것:
  repo root
  tab/surface layout
  각 surface의 cwd
  각 surface의 shell_entry
  사용자가 명시한 startup_recipe
  사용자가 명시한 safe env overrides
  claude/codex 세션 resume 정보(opt-in — agent_kind·session_id·보존 argv; 아래 allowlist 절)

저장하지 않는 것:
  live PTY handle
  child process id
  임의의 전체 env dump
  임의 명령의 last_observed_command 자동 재실행 정보(claude/codex는 allowlist 예외 — 아래 절)
```

## 자동 복구와 명령 재실행은 다르다

이 절의 보안 정책은 [터미널 호환성/보안 정책](terminal-compatibility-policy.md#workspace-restore와-command-restore)을 따른다.

가장 위험한 설계는 "마지막으로 실행 중이던 명령을 앱 재시작 시 자동으로 다시 실행"하는 것이다.

예를 들어 사용자가 실수로 다음 명령을 실행 중이었다고 하자.

```sh
rm -rf tmp/build
deploy-prod
```

workspace restore가 이것을 자동 재실행하면 위험하다.

초기 정책:

- 자동 restore는 layout, cwd, shell 시작까지만 한다.
- 임의의 마지막 command나 shell integration으로 관측한 `last_observed_command`는 자동 재실행하지 않는다.
- repo별 기본 command는 사용자가 `startup_recipe`로 명시한 경우에만 실행 후보가 된다.
- destructive할 수 있는 `startup_recipe` 자동 실행은 나중에 confirmation이나 allowlist가 필요하다.

## 에이전트 세션 자동 resume (claude/codex allowlist 예외)

위 "임의 명령 자동 재실행 금지"의 **명시적 예외**다. claude·codex는 자체 resume 기능을 가진 안전한 에이전트라,
opt-in 토글이 켜졌을 때 종료 전 세션을 자동으로 다시 연다. 임의 셸 명령(`rm -rf`·`deploy-prod`) 재실행과 본질이
다르다 — 에이전트 resume은 "직전 대화를 다시 연다"이지 "부수효과 명령을 재실행"이 아니다. claude `--resume <id>` /
codex `resume <id>`는 그 도구가 설계한 정상 재개 경로다.

### 무엇을 저장하나

- `agent_kind`: `claude` | `codex`(그 외는 일반 셸 복원).
- `session_id`: 그 페인 에이전트의 세션 식별자. **새로 만들지 않고 이미 디스크에 있는 값을 읽는다** — 종료 시점에
  **훅 매핑**(`readMapping(surface.id)` → 정확한 `transcript_path`)에서 뽑는다(`sessionIdFromTranscript`): claude는
  파일명 `<uuid>.jsonl`, codex는 첫 줄 `session_meta.payload.id`. 훅이 팬별 경로를 정확히 주므로 cwd+mtime 추측이 없다
  (docs/agent-session.md "세션 파일 찾기 = 훅 매핑"). 매핑이 없으면 빈 값 → 아래 폴백.
- 보존 `argv`: 종료 시점 에이전트의 전체 argv. `--resume`이 권한 모드를 복원하지 않으므로(아래), 직전 플래그를
  재현하려면 argv가 필요하다.

### 다중 세션과 session_id

같은 cwd에 세션이 여럿이면 claude `--continue`·codex `resume --last`는 "가장 최근 1개"만 잡는다. 그 페인들을 모두
`--continue`로 복원하면 여러 프로세스가 한 transcript에 동시에 써서 대화가 뒤섞인다. 그래서 **session_id 단위로
정확히** 복원한다(`--resume <id>` / `resume <id>`). **훅 매핑이 페인마다 정확한 세션 경로를 주므로**, 옛 cwd+mtime
추측(가장 최근 파일을 골라 다중 세션에서 엉뚱한 세션을 잡던 문제)이 사라졌다 — 각 페인이 자기 session_id로 복원된다.
매핑을 못 얻으면(훅 미발화·미설정) session_id가 빈 값이 되어 `--continue` / `resume --last`로 graceful degrade한다
(가장 최근 1개 — 다중 세션이면 부정확하나 세션을 잃지는 않는다).

### 위험모드(권한 플래그) 재현

claude `--resume`은 대화만 복원하고 `--dangerously-skip-permissions` 같은 권한 모드는 복원하지 않는다(런타임
플래그라 세션에 저장되지 않음). 저장한 argv를 재주입해 직전 권한 모드를 그대로 재현한다. 이는 **새 위험을 만드는
게 아니라 직전 상태 복원**이다 — 그래서 토글 기본값을 OFF(opt-in)로 두어 위험모드 자동 재현을 사용자가 명시적으로
켜게 한다.

### redaction 경계

- `session_id`는 자격증명이 아니라 **불투명한 로컬 식별자**이고 이미 `~/.claude`·`~/.codex`에 평문으로 있다. 같은
  사용자 홈의 또 다른 로컬 파일(workspace 저장본)에 둘 뿐 권한 경계가 늘지 않으므로 redaction 대상이 아니다.
- 보존 `argv`는 redact한다. 토큰성 key(`TOKEN`·`SECRET`·`KEY`·`AUTH`·`PASSWORD`·`CREDENTIAL` 등 —
  [프로젝트 규칙](project-rules.md) "민감정보 redaction 기준" 단일 출처)를 가진 `--key=value` 토큰은 **드롭**
  (deny-by-default). `--dangerously-skip-permissions` 같은 무해 플래그만 보존한다.
- env는 여전히 통째로 저장하지 않는다 — session_id는 트랜스크립트 파일에서 얻으므로 자식 env를 덤프하지 않는다.

### config 토글

- `workspace.restore-claude` / `workspace.restore-codex` — 각각 독립, **기본 false(opt-in)**.
- 토글이 꺼지면 그 종류는 캡처·복원 양쪽 다 비활성(일반 셸로 복원).

## command 관련 용어

`shell_entry`:

- pane을 다시 열 때 시작할 기본 shell argv다.
- 예: `["zsh", "-l"]`.
- workspace restore의 기본 동작은 shell_entry 실행까지만이다.

`startup_recipe`:

- 사용자가 config로 명시한 재시작용 command다.
- 예: `["npm", "run", "dev"]`.
- 자동 실행 후보가 될 수 있지만 v1 기본값은 보수적이어야 하며, confirmation/allowlist 정책 없이 destructive할 수 있는 command를 자동 실행하지 않는다.

`last_observed_command`:

- shell integration이 관측한 마지막 command다.
- 최근 작업 세션 UI나 힌트에는 쓸 수 있지만 자동 재실행 대상은 아니다.
- 이 값을 저장할 경우에도 민감정보 redaction과 사용자 동의가 필요하다.
- 단, claude/codex는 위 "에이전트 세션 자동 resume" allowlist 예외로 별도 관리한다(임의 명령이 아니라 도구 자체 resume).

## 저장 모델 초안

```text
maru.workspace.v1
workspace id=<stable-id>
root /path/to/repo

surface 1
  title api-server
  cwd /path/to/repo
  shell-entry argv ["zsh", "-l"]
  startup-recipe none
  last-observed-command none
  env-override PATH=/usr/local/bin:/usr/bin:/bin

layout
  tab 1 surface=1
```

실제 직렬화는 나중에 정한다. 중요한 것은 저장 대상이 live object가 아니라 선언적 상태라는 점이다. 첫 줄 schema 토큰은 snapshot/trace와 같은 규칙으로 bare 토큰(`maru.workspace.v1`)을 쓰고 `schema=` 접두어를 두지 않는다.

멀티윈도우와 live surface 소유권(AppRuntime/WindowGraph) 모델은 [윈도우와 Surface 이동성](window-surface-mobility.md)을 단일 출처로 둔다. 그 모델이 도입되면 저장 대상은 단일 창에서 `WindowGraph` 기준(windows, active window, workspace order, pane tree, surface refs)으로 확장되고, 각 surface는 복원 시 새 generation으로 생성된다. live PTY fd·child pid·WKWebView process handle·JS heap snapshot은 여전히 저장하지 않는다.

## 사용자 지정 이름(custom_name)과 자동 제목

워크스페이스(사이드바 탭)·Pane(분할 영역)·Term(가로 탭)에는 두 종류의 라벨 출처가 있다.

- **자동 제목(auto title)**: 셸/프로그램이 정하는 값. Term은 OSC 0/2(window title)·OSC 7(cwd)에서 매 세션 라이브로 다시 도출된다. 워크스페이스·Pane은 자동 제목 출처가 없다(번호로 식별).
- **사용자 지정 이름(custom_name)**: 사용자가 직접 붙인(rename) 이름. 이것만이 사용자 의도라서 **영속해야 할 유일한 라벨 데이터**다.

표시 규칙(단일):

```text
표시 라벨 = custom_name(비어있지 않으면) → 없으면 auto title → 없으면 기본값("shell"/번호)
```

베이스/결정: "사용자 이름이 있으면 우선, 없으면 자동"은 iTerm2·Terminal.app의 탭 제목 동작을 베이스로 한다(사용자가 이름을 정하면 셸 OSC가 덮어쓰지 않고 고정). 자동 제목은 매 세션 라이브로 재도출되므로 사용자 의도가 아니며, **custom_name과 별도 필드**로 둔다 — 같은 칸에 섞으면 OSC가 들어오는 순간 사용자 이름이 사라진다.

저장 모델(앞 절 직렬화 모델에 필드 추가, 빈 문자열 = 이름 없음):

```text
tab ... custom-name="<workspace custom_name>" pinned=<0|1> background-color=<0xRRGGBB 10진> accent-color=<0xRRGGBB 10진> group-start="<그룹 이름>" group-collapsed=<0|1> group-depth=<n> group-color=<0xRRGGBB 10진> local-pinned=1 top-level=1
                                                 # 워크스페이스 custom_name + 위치 고정(pinned) + 카드 배경 tint + 좌측 accent 막대색
                                                 # + 사이드바 그룹 시작 마커(group-start=이 탭부터 그 이름의 그룹 시작·위치 파생 소속,
                                                 #   null이면 키 생략=그룹 아님) + 접힘 상태(group-collapsed) — docs/sidebar-groups.md
                                                 # + 중첩 그룹 깊이(group-depth — 기본 1이면 키 생략, SG5-3) + 그룹 공통 색(group-color —
                                                 #   0이면 키 생략, SG5-2) + 그룹-로컬 pin(local-pinned — false면 키 생략, §13) +
                                                 #   서브파티션 마커(top-level — false면 키 생략, §14). 기본값 키 생략은 옛 파일과의
                                                 #   round-trip 고정점 유지 목적(additive·key-addressed)
pane ... custom-name="<pane custom_name>"        # pane custom_name (자동 출처 없음)
surface custom-name="<term custom_name>" title="<auto OSC title>" cwd=... ...
                                                 # surface는 custom_name(사용자)과 title(자동) 둘 다 저장
```

세 계층의 사용자 이름은 모두 `custom-name=` 키로 통일한다(Surface만 추가로 auto `title=`를 둔다). 워크스페이스(tab)는
우클릭 컨텍스트 메뉴로 정하는 **위치 고정(`pinned`)·카드 배경색(`background-color`)·좌측 막대색(`accent-color`)**과 **사이드바
그룹 시작 마커(`group-start`/`group-collapsed`)**도 사용자 의도라 영속한다(custom_name과 같은 자리; 배경색·막대색은 직교한
별도 값 — docs/tabs-splits-layout.md, 그룹은 docs/sidebar-groups.md). 직렬화 리더는 각
라인의 **스칼라 `key=value` 필드를 순서 무관·이름으로 조회**한다(key-addressed — 아래 "[직렬화 전략: key-addressed
파싱](#직렬화-전략-스칼라-필드-key-addressed-파싱)"). 구조 키(개수)만 필수, 스칼라 속성은 없으면 기본값이라 **줄 끝에 스칼라 필드를
추가해도 옛 파일이 안 깨진다**(additive 하위호환). 구조 변경(블록/카운트/tree)은 여전히 포맷 변경 사건이다.

- custom_name은 트리 내 위치(인덱스)로 round-trip한다(cwd/title과 같은 식별).
- 자동 제목(surface `title`)은 복원 직후 셸이 OSC를 다시 보내기 전까지의 폴백 표시용으로만 저장·소비한다. custom_name이 있으면 표시 규칙상 자동 제목보다 우선한다.
- **하위 호환**: additive 스칼라 필드는 key-addressed로 하위호환된다(옛 파일이 그 키의 기본값으로 복원 — 폴백 없음). 단
  **구조 변경**(새 블록 타입·tree 인코딩·카운트 의미 변경)은 하위호환 없이 스키마 버전을 올리거나 통째 폴백+self-heal한다(아래 참조).

## 직렬화 전략: 스칼라 필드 key-addressed 파싱

> 상태: **구현됨**(`src/session/workspace.zig`의 `LineFields`). 이 절은 파서의 실패 모델과 하위호환 경계를 정의하는 단일 출처다.

**동기.** per-tab 스칼라 속성(현재 `custom_name`·`pinned`·`background_color`·`accent_color`; 앞으로 아이콘·정렬·메모 등 계속 추가 예정)이
늘 때, strict positional 파서라면 그 키가 없는 옛 파일을 **통째 파싱 실패**로 떨궈 **업데이트마다 워크스페이스 배치가 1회 리셋**된다
(self-heal 전까지). 필드가 지속적으로 느는 방향이라 그 누적 UX 비용을 없애려 스칼라 필드를 key-addressed로 읽는다.

**방식.** 각 스칼라 라인(`window`/`tab`/`pane`/`surface`)의 `key=value` 꼬리를 순서 무관 필드로 토큰화하고(`LineFields.parse`), 이름으로
조회한다. 따옴표 값은 escape(`\"`)를 존중해 경계를 잡으므로 값 안의 `key=` 흉내·공백이 토큰을 안 깬다. 구조 골격(라인 타입
토큰·self-delimiting 카운트·`tree-node` preorder)은 그대로 **positional**로 둔다 — 스칼라가 아니라 구조라 별개다(`FieldReader`, tree-node 전용).

**실패 모델 — required vs optional.** "없는 키=기본값"이 손상 파일을 조용히 그럴듯한-틀린 상태로 만들지 않게, 키를 둘로 나눈다:

- **required(구조 키)** — 없으면 블록 파싱이 불가능한 개수 키(`window.tabs`·`tab.panes`·`pane.surfaces`·`surface.agent-argc`).
  없으면 `BadLine → 통째 폴백`(loud-fail, 손상 탐지 유지). `requireUint`. 값이 비숫자·거대값이어도 BadLine.
- **optional(스칼라 속성)** — 합리적 기본값이 있는 키(`custom-name`=""·`pinned`=0·`background-color`=0·`accent-color`=0·
  `group-collapsed`=0·`group-depth`=1·`group-color`=0·`local-pinned`=0·`top-level`=0·`title`=""·`cols`=80·`rows`=24·
  `window.active-window`=0(활성 창 마커 — M3e)·`window.win-x/win-y/win-w/win-h`(창 픽셀 frame — M3f, 아래 절) 및
  앞으로의 per-tab/surface/window 스칼라). 없으면 기본값. **단 키가 있는데 값이
  깨졌으면 조용히 기본값으로 때우지 않고 BadLine**(존재하는 손상은 숨기지 않는다). `getUint`/`getInt`/`getQuoted`. **예외 —
  `group-start`(사이드바 그룹 시작 마커)**: 값이 아니라 **키 존재 자체가 그룹 시작**을 뜻하므로(없으면 그룹 아님=null, 빈
  문자열도 유효한 '이름 없는 그룹') `find`로 키 유무를 먼저 본 뒤 `getQuoted`한다(위치 파생 — docs/sidebar-groups.md §4).
  **또 하나의 all-or-none 예외 — `window.win-x/win-y/win-w/win-h`(창 frame, M3f)**: 4개가 **넷 다 있어야** frame이고
  하나라도 없으면 null(옛 파일·부분 필드 = cascade 기본 위치). writer는 넷 다 or 아무것도 안 내므로(all-or-none) 부분은
  손상뿐이고 그때도 조용히 null로 graceful 폴백한다. 단 넷 다 **있는데** 값이 깨졌으면(`win-w=abc`) getInt가 BadLine
  (부재≠손상). x/y는 음수 가능(전역 좌표 = main 왼쪽/아래 보조 모니터)이라 `getInt`(signed)로 읽는다. 아래 "창 geometry 복원" 절.

**미지 키.** 조회하지 않는 키는 자연히 skip된다(forward-compat — 옛 바이너리가 새 파일의 모르는 스칼라 키를 무시). 오타 키가
조용히 무시되는 트레이드오프는 optional 속성이라 감수하고, 구조 이상은 required 규칙이 잡는다(미지 키 진단 로그는 후속).

**반복 키.** `surface`의 `agent-arg`는 반복 키라 필드를 나온 순서대로 순회해 수집하고, 개수는 구조 키 `agent-argc`와 일치해야
한다(불일치=손상=BadLine — self-delimiting 정합).

**범위 밖(하위호환 안 되는 변경).** 새 블록 타입 추가·`tree-node` 인코딩 변경·카운트 의미 변경은 구조 파괴라 스키마 버전
bump(`maru.workspace.v1`→`.v2`) 또는 통째 폴백+self-heal 대상이다("[저장 파일을 통째로 파싱 못 할 때](#저장-파일을-통째로-파싱-못-할-때)"). additive 스칼라 필드는 버전을 안 올린다.

**writer.** writer는 항상 전체 키를 `key=value`로 쓴다(불변) → round-trip 고정점 유지. reader만 순서 무관·기본값이라, writer가 낸
최신 포맷은 정확히, 옛 파일은 관대하게 읽는다.

## 창 geometry 복원 (M3f — 위치·크기·모니터)

재시작 시 창이 종료 전 위치·크기·모니터에 뜨게 하는 additive 스칼라 필드다. 단일 출처(슬라이스 표·상태)는
[윈도우와 Surface 이동성](window-surface-mobility.md) §8A.8이고, 이 절은 저장 포맷·좌표계·clamp 동작만 기록한다.
M3e 활성 창(`active-window`)과 **완전 동일한 옵션 additive 패턴**이라 헤더(`maru.workspace.v1`)를 안 올리고 하위호환된다.

**저장 필드(window 라인, 옵션 additive):**

```text
window tabs=<N> active-tab=<i> [active-window=1] [win-x=<X> win-y=<Y> win-w=<W> win-h=<H>]
                                # active-window(M3e)=저장 시점 key 창 마커
                                # win-x/y/w/h(M3f)=창 픽셀(점) frame(전역 스크린 좌표). 넷 다 or 아무것도.
```

- **좌표계 = 전역 스크린 좌표(bottom-left 원점, macOS NSWindow.frame).** 절대 frame이라 **어느 모니터인지 자동
  인코딩**된다(각 모니터가 전역 좌표 공간의 한 영역을 차지) — display ID를 따로 저장하지 않는다. `win-x`/`win-y`는
  **음수 가능**(main 화면 왼쪽/아래에 놓인 보조 모니터). `win-w`/`win-h`는 양수. 저장 단위는 **점(point)**이지 픽셀이
  아니다(HiDPI backing scale 무관). frame은 AppKit NSWindow 영역이라 Swift가 `window.frame`을 읽어 ABI로 넘기고, Zig가
  저장·파싱하며, 복원 시 Swift가 `setFrame`한다.
- **all-or-none·부분=null.** writer는 frame이 있으면 넷을 다 내고 없으면 넷을 다 생략한다(round-trip 고정점). reader는
  넷이 **다 있어야** frame으로 읽고 하나라도 없으면 null → 복원이 **현행 기본(cascade) 위치**를 유지한다. 옛 파일(win-*
  무)·부분 필드(손상/변조로 일부만) 모두 여기로 graceful 폴백한다. 단 넷 다 있는데 값이 깨졌으면 BadLine(부재≠손상).
- **전체화면 창은 frame 저장 스킵.** 저장 시 창이 native 전체화면(`window.styleMask.contains(.fullScreen)`)이면 `window.frame`이
  **화면 전체**라, 그대로 저장하면 복원 시 아래 clamp를 통과해 **타이틀바 달린 거대 windowed 창**으로 떠 전체화면이 아니게
  된다(회귀). 그래서 **전체화면이면 frame 저장을 건너뛴다**(has_frame=0 → win-* 생략 → 복원은 cascade 기본 위치). zoomed
  (green button 최대화)는 frame이 유효한 windowed 크기라 저장 대상이다(전체화면만 예외). 전체화면 상태 자체의 복원
  (window-fullscreen 마커 + `toggleFullScreen`)은 timing 위험이 커 도입하지 않고, 스킵-저장만으로 회귀를 제거한다(최소 안전 —
  후속 검토 여지). 또한 저장 시 `window.frame` 성분을 `Int32`로 굳힐 때 비유한(NaN/inf)이면 그 창 frame을 스킵하고(has_frame=0)
  범위 초과는 clamp한다 — trapping 변환(`Int32(Double)`)이 종료 경로(`applicationWillTerminate`)에서 크래시해 **전체 상태를
  소실**하지 않게 하는 실제 trap 가드다([[no-defensive-code-without-consult]] 예외).
- **복원 clamp(멀티모니터·레이아웃 변경 방어) — 항상 화면 안.** 저장 frame과 **가장 많이 겹치는** `NSScreen`을 고르고(전역
  좌표가 모니터를 인코딩하므로 최대 겹침 = 그 창이 있던 모니터; 어떤 화면과도 안 겹치면 main 화면으로 폴백), **그 화면
  `visibleFrame` 안으로 frame을 clamp**한다: 화면보다 크면 축소하고, 가장자리를 넘으면 이동해 **창이 완전히 화면 안·타이틀바를
  잡을 수 있게** 보장한다(pre-M3f "창은 늘 화면 안" 불변식 복원). frame이 이미 화면 안에 완전히 들어가면 clamp가 그대로
  반환하므로(크기·위치 불변) 맞는 모니터의 사용자 리사이즈 크기는 보존된다. 예전 "가시 면적이 임계 이상이면 저장 frame
  그대로 통과"는 모니터 배치가 바뀌면 창을 구석만 걸친 채 거의 화면 밖으로 복원해(타이틀바가 화면 위에 없어 드래그 불가)
  불변식을 약화시켰다 — 이제 "겹치면 그대로"가 아니라 "항상 사용 가능하게 clamp"다. macOS `constrainFrameRect`(타이틀바를
  화면에 남김)를 참고하되 명시 clamp로 예측 가능하게. 전역 좌표가 모니터를 인코딩하므로 이 최대-겹침 판정 하나로 "그 모니터가
  아직 있나"를 정한다(display ID 불필요).
- **하위호환.** 옛 파일(win-* 키 없음) → frame=null → cascade 기본 위치. 크래시·모달·마이그레이션·헤더 bump·v1 reject
  없음([[serialization-format-change-migration-fallout]]). 새 파일 → 옛 리더가 미지 win-* 키를 skip(forward-compat).

## env 저장 정책

환경변수는 민감정보가 많다.

저장하면 위험한 예:

```text
AWS_SECRET_ACCESS_KEY
GITHUB_TOKEN
NPM_TOKEN
DATABASE_URL
COOKIE
PASSWORD
PRIVATE_KEY
```

초기 정책:

- 현재 process의 전체 env를 자동 저장하지 않는다.
- 사용자가 명시한 env override만 저장한다.
- redaction 키 목록과 allowlist 기준은 [프로젝트 규칙](project-rules.md)의 "민감정보 redaction 기준 (단일 출처)"을 따른다. 이 문서에 키 목록을 따로 복제하지 않는다.

## command 저장 정책

명령은 shell string보다 argv 배열이 안전하다. 이 절에서 말하는 명령은 `startup_recipe`다. `last_observed_command`는 자동 재실행 대상이 아니므로 이 저장 정책에 섞지 않는다.

권장:

```text
argv ["npm", "run", "dev"]
```

주의:

```text
shell "npm run dev && deploy"
```

shell string은 quoting, expansion, injection 문제가 있다. 초기에는 startup_recipe를 `argv` 형태로 제한한다. shell string 지원이 필요하면 별도 UX와 경고가 필요하다.

## 실패 처리

restore가 실패해도 workspace 전체를 버리지 않는다.

예:

- cwd가 사라짐
- command executable이 없음
- env override가 redaction 정책에 걸림
- surface 하나만 복구 실패

이 경우 실패한 surface와 이유를 artifact에 남기고, 가능한 나머지 surface는 복구한다.

### 저장 파일을 통째로 파싱 못 할 때

헤더 불일치·**구조 파괴 포맷 변경**(새 블록·tree 인코딩·카운트 의미 — 위 "직렬화 전략"의 하위호환 범위 밖)·손상으로 저장 파일을 **통째로** 파싱 못 하면, **알림(notice) 없이 조용히 기본 단일 창으로 시작**한다. 복원 불가는 사용자 잘못이 아니고, 특히 구조가 바뀌면 이전 버전 저장 파일이 모두 여기로 떨어지는데 이를 "손상" 모달로 알리면 업데이트 후 첫 실행마다 키를 막는 중앙 팝업이 떠 UX가 나쁘다. 저장본은 다음 정상 종료 때 새 포맷으로 덮어써져 자연히 해소된다(self-heal). 빈 workspace(저장 없음)와 같은 조용한 기본 창 동작이다. **additive 스칼라 필드 추가는 key-addressed 하위호환이라 여기로 안 떨어진다**(옛 파일이 기본값으로 정상 복원). 일부만 복원 실패(파싱은 됐으나 일부 창 적용 실패)는 이와 별개로 안내할 수 있다.

## 초기 테스트

- workspace fixture round-trip.
- live PTY handle이 저장 모델에 들어가지 않는지 테스트.
- 민감 env key가 저장되면 실패하는 테스트.
- `shell_entry`와 `startup_recipe argv`가 round-trip되는 테스트.
- `last_observed_command`가 자동 실행 후보로 저장되지 않는 테스트.
- cwd가 없을 때 surface별 restore failure artifact를 남기는 테스트.
- claude/codex `agent_kind`·`session_id`·보존 `argv`가 round-trip되는 테스트.
- 토큰성 key(`--api-key=…` 등)를 가진 argv 토큰이 redact(드롭)되는 테스트.
- `session_id`를 못 찾을 때 `--continue`/`resume --last` 폴백으로 degrade하는 테스트.
