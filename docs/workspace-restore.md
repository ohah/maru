# Workspace Restore 전략

이 문서는 Maru의 workspace restore가 무엇을 저장하고, 무엇을 저장하지 않는지 정한다.

## 초보자용 설명

workspace restore는 "실행 중이던 shell process를 그대로 냉동했다가 다시 살리는 기능"이 아니다.

운영체제의 process, PTY file descriptor, foreground job은 앱을 끄면 사라진다. 이것을 그대로 저장할 수 없다.

> 이 설명은 선언적 restore의 기본 계약이다. 현재 opt-in
> [영속 터미널 세션 호스트](persistent-session-host.md)는 별도 `maru-sessiond`가 live PTY·child·`TerminalCore`를
> 계속 소유하고 새 GUI가 `runtime-handle`로 attach하는 경로까지 구현했다. 이때도 GUI가 process를 직렬화하는 것은 아니며
> 연속성은 host와 runtime이 살아 있을 때만 성립한다. host/runtime 종료 뒤 provider resume/fork나 동일 세션 복구는
> 제공하지 않으며, 새 shell을 여는 동작을 기존 실행 세션의 연속으로 설명하지 않는다.

Maru가 저장하는 것은 다시 시작하기 위한 **설명서**다.

```text
저장하는 것:
  repo root
  tab/surface layout
  각 surface의 cwd
  각 surface의 shell_entry
  사용자가 명시한 startup_recipe
  사용자가 명시한 safe env overrides

저장하지 않는 것:
  live PTY handle
  child process id
  임의의 전체 env dump
  임의 명령의 last_observed_command 자동 재실행 정보
  web Term(인앱 브라우저/마크다운 패널) — 아래 절
```

**web Term(4e)은 원칙적으로 저장하지 않는다**(예외 둘: 파일 Term은 §FP16, 브라우저 URL은 §WP-P — 아래). `workspace.Surface`에 kind 필드가 없어 web 패널을 표현할 수 없고(포맷에 kind 추가는 Phase 5), sentinel core를 일반 surface로 직렬화하면 복원 시 셸로 오spawn되므로 `captureWorkspaceTab`이 web Term을 **스킵**한다. 한 pane이 web Term만 가진 경우(모든 terminal Term을 닫음) surfaces가 비면 복원이 `error.EmptyPane`으로 전체를 중단하므로, 그 pane엔 **기본 셸 placeholder 하나**를 넣어 기본 로그인 셸로 복원한다(브라우저 콘텐츠·URL은 어차피 미영속). web 콘텐츠 영속은 Phase 5(콘텐츠·브리지)와 함께 포맷에 kind를 더해 다룬다. **구현 완료(2026-07-20, ABI v137)**: Explorer UX 보강은 기존 window line에 열린 빈 도크용 `dock-presented=1`과 explicit root의 단일 length-framed `dock-tree-roots` field를 추가했다. root field가 없으면 inferred이고 `0:` payload는 explicit-empty다. 유효한 `0:`만으로는 도크 표시를 파생하지 않지만, 손상된 root field는 explicit-empty로 강등하면서 field 존재가 나타낸 표시 의도를 보존하며 terminal과 dock entry를 폐기하지 않는다. 복원은 root를 canonical/no-follow identity로 검증하고 missing/invalid root만 버린 뒤 rows와 safety watcher를 함께 stage하며, root validation이 pending이면 restore를 거부한다. 전체 apply의 fail-index OOM 검증은 기존 tab/dock/root/rows/watch를 원자적으로 보존한다(상세 단일 출처=[file-panel.md](file-panel.md) §5·§7). Markdown entry mode와 dirty content 미영속 계약은 그대로다.

**FP16 목표(계획 — [file-panel.md](file-panel.md) §5.0이 단일 출처)**: 파일 패널이 전역 도크에서 워크스페이스 Term으로 옮겨오면 "web Term은 저장하지 않는다"는 위 규칙에 예외가 하나 생긴다 — **파일 Term은 저장한다**(현재 `dock-entry`로 저장되던 것을 잃지 않기 위해). 단 위 문단이 밝힌 이유("`workspace.Surface`에 kind 필드가 없고, sentinel core를 일반 surface로 직렬화하면 복원 시 셸로 오spawn된다") 때문에 **`Surface` 레코드에 넣지 않고** pane 줄의 별도 반복 키 `file-term=`으로 저장한다. 그래서 `captureWorkspaceTab`의 web Term 스킵과 `restoreSpawn`의 PTY attach 경로, host-backed identity(`runtime_host_id:runtime_id`) 검증은 **한 줄도 바뀌지 않는다**. 브라우저 web Term은 계속 미영속이다(URL 영속은 별도 보안 판단 필요). 그 결과 FP16에서 **두 곳이 "비-web"에서 "persisted(터미널 + 파일)" 기준으로 넓어져야 한다** — ⑴ `active_term` remap(현행: 앞의 비-web Term 수), ⑵ web-only 셸 placeholder 조건(현행: `surfaces.items.len == 0`, PTY 목록만 본다). ⑵를 안 넓히면 **파일 Term만 있는 pane에 엉뚱한 셸 placeholder가 삽입**되고, ⑴을 안 넓히면 복원 활성 탭이 어긋난다. 브라우저 Term만 있는 pane은 여전히 persisted 0이라 placeholder를 받는다(현행 동작 유지).

## 브라우저 Term URL 영속 (WP-P)

**결정(2026-07-28 사용자 승인)**: 브라우저 web Term은 **현재 URL 하나만** 저장하고 재시작 시 그 URL을 자동 로드한다. 히스토리(뒤로/앞으로)는 복원하지 않는다 — 스톡 WKWebView에서 세션 복원은 `interactionState`(macOS 12+) **바이너리 blob**이 필요하고, 그건 OS 버전에 묶인 값이라 사람이 읽는 텍스트 포맷에 담을 것이 아니다(사용자가 히스토리 미복원을 명시 수용).

### 포맷 — 인덱스 공간을 **건드리지 않는다**

`pane` 줄의 반복 필드 `browser-term="<insert-after>:<url-byte-len>:<url>"`. `insert-after`는 그 브라우저 **앞에 있는 persisted(터미널+파일) Term 수**다.

**왜 `file-term`처럼 persisted 시퀀스에 합류시키지 않는가 — 이게 이 절의 핵심 제약이다.** 브라우저를 시퀀스에 넣으면 인덱스가 재번호되고, 그 파일을 **구버전 Maru가 읽으면 창이 통째로 폴백한다**: 구버전은 `browser-term`을 모르는 필드로 건너뛰므로 `total = surfaces + file-term`으로 계산하는데, 재번호된 `file-term` 인덱스가 그 total을 넘어 `validatePaneFileTerms`의 범위 검사에 걸린다([file-panel.md](file-panel.md) §5.0). 즉 브라우저를 추가하는 대가로 **downgrade 시 파일 탭까지** 잃는다. `insert-after`는 기존 인덱스 값을 하나도 바꾸지 않으므로 구버전은 브라우저만 잃고 나머지는 그대로 복원한다(§5 downgrade 계약의 기존 범위 유지).

- **URL이 없거나 상한을 넘으면 그 브라우저는 저장하지 않는다.** 아직 아무것도 안 띄운 빈 패널은 복원할 값이 없고(빈 탭만 남아 무의미), 큰 `data:` URI는 한 줄 길이·512 필드 cap을 위협한다. 상한은 주소창 navigate가 쓰는 `addr_nav_url_cap`을 그대로 공유한다(별도 상수 금지 — 같은 값이 두 곳에 생기면 갈린다).
- **활성 탭이 브라우저면** 추가 필드 `active-browser="<record-index>"`로 몇 번째 `browser-term`이 활성인지 적는다. 구버전은 이 필드를 무시하고 `active-term`(비-브라우저 공간·clamp된 값)을 쓰므로 포커스만 이웃으로 떨어진다.
- **placeholder 조건**: "persisted Term 수 0"의 정의에 브라우저 record를 **포함한다**. URL 있는 브라우저만 있는 pane은 이제 복원할 것이 있으므로 셸 placeholder를 받지 않는다(URL 없는 브라우저만 있으면 종전대로 placeholder).

### 복원 시 로드 시점

브라우저 Term의 WKWebView는 복원 즉시 존재하지 않는다 — `computeWebSurfaceTransitions`가 `created`를 내고 Swift가 붙인 **뒤**에야 navigate할 수 있다. 그래서 복원은 URL을 **Term에 pending으로 달아 두고**, 그 surface가 생성된 tick에 기존 주소창 navigate 경로(`takeWebAddrNavigate` 계열)로 흘려보낸다. 주소창 commit이 쓰는 단일 슬롯은 복원(여러 개 동시)에 못 쓰므로, pending은 **Term이 소유**하고 tick당 하나씩 빠진다.

### 남는 한계

- 스크롤 위치·폼 입력·로그인 세션 이후 상태는 복원하지 않는다(URL 재요청이므로 서버가 주는 대로).
- **시작 시 네트워크 요청이 나간다**(사용자 승인). 사용자가 직접 열어 둔 탭이므로 복원이 자연스럽고, 안 하면 빈 탭만 남아 의미가 없다는 판단이다.
- 브라우저가 여럿이면 tick당 하나씩 로드된다(동시 N개 로드로 시작 프레임을 굶기지 않게).

## 영속 session host와의 관계 (부분 구현)

실행 중 shared host connection이 unusable이 된 뒤의 reconnect는 workspace restore가 아니다. 성공/일시 실패 모두
`runtime-handle={host_id,runtime_id}`와 `runtime-state=live`를 바꾸거나 checkpoint를 dirty로 만들지 않는다. 이 경로는
saved cwd/command로 shell/runtime을 spawn하지 않으며 창별 `restore_gone_host_id` negative memo를 재사용하지 않는다.
durable ended tombstone은 fresh `runtime_not_found`, stale host identity, dead owner lease처럼 runtime 부재의 긍정적 증거가
기존 Gone 분류를 통과한 경우에만 쓴다. transport poison·timeout·upgrade busy·지원 adapter 부재는 unavailable이다.

reconnect 중 close의 checkpoint 규칙은 다음과 같다. Term close는 positive terminate confirmation 전 pane/binding을
`termination_pending|termination_unconfirmed`으로 살아 있는 Window model에 유지한다. 사용자가 non-last Window 또는
Workspace를 닫으면 그 model과 binding은 일반 close처럼 checkpoint에서 제거하고, coordinator는 layout snapshot을 따로
소유하지 않는다. terminate confirmation이 없으므로 host runtime은 건드리지 않고 다음 실행의 Recovered Sessions에서 찾는다.
Window model이 남은 채 app Quit/crash가 일어나면 마지막 binding을 복원하므로 Term이 원래 위치에 다시 보일 수 있다.
positive termination 뒤에는 기존 close transaction이 pane/binding 제거 checkpoint를 정확히 한 번 쓴다.

workspace restore와 persistent-session attach는 서로 대체하지 않는다.

| 상태 | 시작 동작 |
| --- | --- |
| 같은 `host_id/runtime_id`가 살아 있음 | 새 shell을 spawn하지 않고 기존 runtime attach (**구현**) |
| host가 runtime 부재를 긍정 응답하거나 dead owner lease로 host 종료를 검증함 | 자동 fresh spawn 금지. **그 Term만 종료 placeholder로 두고 나머지 surface·split·탭은 정상 복원한다(첫 복원 구현)**. 영구 부재(`PersistentRuntimeGone`)로 분류된 경우에만이며 placeholder는 마지막 제목·위치와 `⏎` 안내를 화면에 남긴다 |
| endpoint 미발견·지원 범위 밖 protocol·timeout | runtime이 살아 있을 수 있으므로 unavailable로 fail-close. ended로 저장하거나 새 shell로 위장하지 않음 |
| host 종료·재부팅이 긍정적으로 검증됨 | 기존 handle은 ended. 사용자가 새 shell을 열 수는 있지만 동일 session continuation 아님 |
| host에만 runtime이 남음 | 삭제하지 않음. `Recovered Sessions` 노출은 P4 계획 |

현재 `maru.workspace.v1`의 terminal `runtime-handle`은 구현됐다. writer는
`<host-id>:<runtime-id>`를 함께 쓰고 reader는 길이·lowercase hex·구분자를 fail-closed 검증한다. 옛
`runtime-id` 단독 파일은 한 번의 attach migration을 위해 읽지만 새 live capture는 bare ID를 만들지 않는다.
첫 복원의 ended placeholder와 `⏎` 제자리 재생성은 구현됐다. **P4 R1 구현 슬라이스는**
positive-Gone의 정확한 handle을 `runtime-state="ended"`와 함께 owned 상태로 보존하고, 다음 restore가 host
probe·attach·새 shell spawn 없이 placeholder를 직접 만드는 durable tombstone까지를 한 gate로 묶는다. Enter로 새
runtime 생성이 성공한 때만 구 handle/state를 버린다. **P4 R2a의 전역 runtime binding 중복 검증도 core/ABI/source-order
fixture까지 구현됐다.** R2b의 host inventory core/wire와 secure discovery/ephemeral collector 모듈은 구현됐지만
제품 restore coordinator에 아직 연결되지 않았다. `Recovered Sessions` projection/adopt와 incremental checkpoint는
여전히 미구현이다. 정상 종료 한 번에만
저장하는 현재 방식이라 GUI 비정상 종료 직전 layout은 잃을 수 있으므로 이 항목들은 opt-in 영속 session의 P4 gate다.
`workspace-binding-id`와 persistent quick layout은 default-on 범위에서 제거했다. 세부 소유권·ID·접속 실패 행렬은
persistent-session 문서를 따른다.

현재 정상 종료 checkpoint는 **모든 일반 Window 직렬화 성공 또는 write 0회**다. Window 하나라도 session handle이 없거나
직렬화에 실패하면 성공한 일부 Window만으로 기존 `workspace.v1`을 덮지 않고 마지막 완전본을 보존한다. restore도 Window
모델 publish 전에 surface들을 stage하며, 기존 persistent runtime attach 뒤 후속 surface가 실패하면 앞 runtime은
terminate하지 않고 controller subscription만 detach해 rollback한다. saved Window 하나라도 apply하지 못하면 그 추가 창은
default shell로 위장하지 않고 teardown하며, 이번 실행은 `restore incomplete`로 남는다. **apply가 성공했어도 복원이 조용히
버린 항목이 있으면 같은 래치를 세운다**(v144): capability 검증에서 버린 파일 패널 entry, 그 결과로 비워져 제거된 dock 그룹,
접근 불가로 강등한 explorer root, 그리고 **이번 restore에서 live handle을 영구 부재로 새로 분류한 Term**은 apply를
실패시키지 않는다. 앞 세 범주는 입력을 온전히 표현하지 못했고, 마지막 범주는 오분류 때 마지막 완전본으로 돌아갈
backup 신호가 필요하므로 Zig가 모두 `take_workspace_restore_dropped`로 노출한다. 개수는 정확한 회계가
아니라 판정용 신호다 — 한 원인이 entry와 빈 그룹 둘로 세어질 수 있다.

**checkpoint 보호(단일 출처).** 이 래치가 선 실행의 종료 저장은 **덮어쓰기 직전에 마지막 완전본을 `workspace.v1.bak`으로
한 번 남기고 정상 진행**한다(이미 `.bak`이 있으면 덮지 않는다 — 연속 불완전 실행이 가장 완전한 첫 사본을 밀어내지 않게).
처음 도입 때는 저장을 통째로 막았는데(v144), 그 래치에는 해제 경로가 없고 저장을 막으면 stale 파일이 그대로 남아 **다음
실행이 같은 drop을 다시 만든다** — 자기영속 루프다. 그동안 사용자가 만든 창·탭·split·pane rename·창 위치는 매 종료마다
조용히 사라져, 무기한 차단이 데이터 손실 방지가 아니라 데이터 손실 그 자체가 됐다(code-review max). 백업 후 저장은 잃을
뻔한 상태를 파일로 남기면서 루프를 끊는다. 복구는 사용자가 `.bak`을 `workspace.v1`로 되돌리면 된다.

quick은 영구히 checkpoint 대상이 아니며 host orphan을 막기 위해 in-process backend로만 생성되어 앱 Quit 때 종료한다.
live→ended로 **처음** 전이한 실행은 exact `runtime-handle + runtime-state="ended"`를 저장하면서도 오분류 대비
`dropped` backup 신호를 한 번 유지한다. 이미 durable ended로 저장된 다음 실행부터는 완전히 표현된 상태이므로 dropped
0이며 정상 checkpoint로 반복 보존한다.

시작 host는 workspace 텍스트를 **AppSession 생성 전** Zig parser로 preflight한다(ABI v142,
`workspace_window_count(session=NULL)`). 복원할 Window가 하나 이상이면 각 AppSession을
`defer_initial_surface=1`로 만들어 기본 tab/PTY/renderer/frame loop를 만들지 않고, 저장 모델의 모든 Term을 stage한 뒤
첫 publish에서만 surface와 frame loop를 연다. 따라서 정상적인 persistent attach 복원은 임시 default shell이나
throwaway host runtime을 하나도 spawn하지 않는다. primary Window 적용 실패 때만 빈 deferred session을 폐기하고 명시적인
새 default-shell session으로 fallback하며, 이 실행은 위 `restore incomplete` 보호를 그대로 적용한다.

## 영속 session binding wire (runtime-handle 구현, durable tombstone R1)

새 DB나 창별 파일을 만들지 않고 기존 `~/Library/Application Support/maru/workspace.v1` 하나가 Window/Workspace 배치의
단일 출처다. 현재 직렬화 모델에서 `Window`=OS 창, `Tab`=Workspace, `Pane`=split leaf, `Surface`=terminal Term이므로
일반 layout에는 optional scalar만 추가한다.

```text
maru.workspace.v1
window tabs=1 active-tab=0 active-window=1
tab panes=1 active-pane=0 custom-name="work" pinned=0 background-color=0 accent-color=0
tree-node leaf pane=0
pane surfaces=2 active-term=0 custom-name=""
surface custom-name="" title="shell" cwd="/repo" command="/bin/zsh" cols=120 rows=40 runtime-handle="f16fe6b415c84f1a9c0df52448852955:3020a9d49cef45adb9fe56f25dad4f18"
surface custom-name="" title="ended" cwd="/repo" command="/bin/zsh" cols=100 rows=30 runtime-handle="f16fe6b415c84f1a9c0df52448852955:b616db544aca443bab267404e15fb777" runtime-state="ended"
```

| 필드 | 위치 | 형식·수명 | 키가 없을 때 |
| --- | --- | --- | --- |
| `runtime-handle` (**구현**) | terminal `surface` line | `<host-id>:<runtime-id>`, 양쪽 모두 lowercase 32 hex. 한 quoted scalar로 all-or-none | 선언적 surface. 설정에 맞는 새 runtime 생성 후보이며 기존 process continuation 아님 |
| `runtime-state` (**P4 R1 구현**) | terminal `surface` line | 키 부재=`live`, 유일한 명시 값 `ended`. ended는 정확한 handle과 함께 마지막 runtime의 묘비로 유지 | live/legacy surface |

규칙:

- binding 필드는 기존 `LineFields`의 순서 무관 optional scalar다. 옛 reader는 미지 키로 skip하고 새 reader는 부재를
  legacy/default로 읽으므로 header는 `maru.workspace.v1`을 유지한다. 현재 구현된 `runtime-handle` reader는 옛
  `runtime-id` 단독 키도 엄격한 32 lowercase hex일 때만 migration 입력으로 허용하며 두 키가 함께 있으면 거부한다.
- `runtime-id`·`runtime-handle`·`runtime-state`는 각각 한 surface에 최대 한 번만 올 수 있다. valid 앞값 뒤에 손상·모순
  값을 숨기는 first-wins 해석은 하지 않는다. legacy bare ID가 Gone이어도 exact host namespace를 확정할 수 없으므로
  host 없는 tombstone을 만들지 않고 unavailable로 fail-close한다.
- 키가 있는데 quoted 형식, 길이, lowercase hex, `:` 구분이 깨졌으면 `BadLine`이며 기존 "존재하는 optional 손상은 숨기지
  않는다" 규칙대로 checkpoint 전체를 거부한다. `runtime-handle`을 두 키로 나눠 partial state를 만들지 않는다.
- writer는 ID를 의미 있는 숫자나 path로 인코딩하지 않고, 같은 값의 재사용·자동 재발급으로 손상을 숨기지 않는다.
- **P4 R1 gate:** `runtime-state="ended"`는 `runtime-handle`과 함께 있을 때만 유효하다. reader는 host probe·attach·새 shell
  spawn 없이 placeholder를 만들고, writer는 Enter로 새 runtime 생성에 성공할 때만 구 handle/state를 새 live handle로
  교체한다. 알 수 없는 state, ended인데 handle 부재, live와 ended의 모순은 checkpoint 전체를 거부한다.
- **P4 R2a 구현 슬라이스:** publish 전 전체 모델을 검증한다. 하나의 `runtime-handle`은
  canonical owner terminal surface 하나에만 나타나야 한다. v1 manifest에는 같은 handle의 read-only mirror도 저장하지 않는다.
  중복이면 현재 live 모델과 마지막 완전 파일을 보존하고 새 checkpoint를 쓰지 않는다.
- legacy bare `runtime-id`도 current host에서 같은 runtime을 가리킬 수 있으므로 같은 bare ID끼리, 또는 같은
  `runtime_id`를 가진 full handle과 함께 나타나면 보수적으로 중복으로 거부한다. host namespace를 증명할 수 없는 입력을
  두 writable owner로 attach하는 것보다 fail-close를 택한다.
- semantic validator는 persistent binding을 최대 4,096개로 제한한다. exact cap은 허용하고 cap+1은 checkpoint 전체를
  거부해 launch preflight의 hash-table 작업·메모리를 손상 manifest로 무한히 늘릴 수 없게 한다.
- **P4 R2a 구현 슬라이스:** reader도 어떤 runtime attach/spawn이나 Window publish보다 먼저 전역 중복을 검사한다. 검증 실패 때 일부 창만 attach하는
  side effect를 만들지 않는다.
- **계획:** live handle인데 host가 runtime 부재를 긍정적으로 확인하면 해당 surface를 ended로 전이시킨다. endpoint를
  찾지 못했거나 protocol 지원 범위 밖인 것만으로는 영구 부재를 단정하지 않는다. host에는 있지만 manifest에 없는 runtime은
  `Recovered Sessions`에 둔다.
- **P4 R2b 목표:** R2a가 승인한 manifest와 exact host별 bounded/paginated ID-only inventory를 attach/spawn 전에
  대조하되, inventory는 derived recovery projection일 뿐 canonical restore의 성공 조건이 아니다. ended exact handle과
  다시 일치한 live runtime은 generic orphan으로 새 탭을 만들지 않고 tombstone 제자리 복구 후보로 둔다.
  inventory-only orphan은 삭제·자동 attach하지 않고 primary Window의 typed virtual `Recovered Sessions` group에
  inert row로만 표시하며, 사용자의 개별 adopt가 authority를 fresh revalidate한 뒤에만 exact handle 하나를 publish한다.
  inventory 실패는 빈 목록으로 간주하지 않고 그 host recovery projection만 unavailable로 두며 quick과 다른 Window에는
  중복 투영하지 않는다. 상세 pagination/generation·legacy bare·redaction·rollback 계약은
  [영속 터미널 세션 호스트](persistent-session-host.md)의
  "R2b inventory reconciliation과 Recovered Sessions 계약"을 단일 출처로 둔다.
- runtime이 살아 있는 attach는 saved `cwd`/`command`로 새 shell을 spawn하지 않는다. `cwd`/`title`은 초기 표시 fallback이고
  host snapshot/metadata가 도착하면 live 값을 따른다.
- `runtime-handle`은 secret/capability가 아니다. workspace 파일을 읽은 client도 별도 session-host 인증 없이는 output/input을
  얻지 못한다.
- `LineFields`가 첫 unknown top-level trailing line에서 성공 종료하는 현재 동작은 legacy 관용성이지 구조 확장점이 아니다.
  새 block/tree/count가 필요하면 `maru.workspace.v2` reader→current model migration을 설계한다.
- v1의 하위호환 약속은 새 reader가 옛 파일을 읽는 방향이다. 옛 writer는 미지 scalar를 보존하지 않으므로 새 파일을 구 앱에서
  열고 다시 저장하는 downgrade round-trip은 지원하지 않으며 완료 증거로 사용하지 않는다.

### 멀티윈도우 저장·이동·동시 쓰기

> **P4 목표 계약:** 현재 구현은 정상 종료 시 모든 일반 Window를 한 번에 checkpoint하고, 실패 시 마지막 완전본을
> 보존한다. 아래 dirty debounce incremental checkpoint와 이동 transaction은 아직 구현되지 않았다.

- 기존 한 header 아래 `window` block N개가 모든 OS Window를 저장한다. 각 Window가 같은 host connection을 공유하지만 layout은
  계속 자기 `tab`/`pane`/`surface` block에 인라인으로 저장한다.
- Workspace cross-window 이동은 source `window`에서 같은 `tab` subtree를 제거해 target `window`에 삽입한다.
  그 아래 `runtime-handle`은 byte-identical로 유지되고 runtime/PTY를 재시작하지 않는다.
- Term/Panes 이동도 handle을 유지한 채 위치만 바꾼다. Workspace 복제는 writable `runtime-handle`을 복제하지 않는다.
  복제 UI가 필요하면 새 runtime을 만들거나 explicit placeholder로 둔다.
- GUI/CLI/SSH observer N개가 같은 runtime에 붙는 것은 host의 client subscription이며 manifest 중복이 아니다. Maru 내부
  Mirror Term은 owner close/terminate·알림 위치·독립 viewport 계약이 필요한 별도 non-owning surface이므로 v1에는 넣지 않는다.
- app-wide Quit은 모든 Window를 한 checkpoint로 publish한 뒤 GUI client를 detach한다. 비마지막 Window/Workspace/Term의
  명시적 close는 기존 close 의미대로 소속 runtime 종료 확인을 먼저 거친다.
- manifest writer는 정상 제품 구성의 단일 `Maru.app` process다. 같은 process의 여러 Window는 기존 AppRuntime
  transaction으로 한 파일을 쓴다. P4 L0는 manifest sibling
  `~/Library/Application Support/maru/workspace.v1.lock`을 no-follow로 열고 현재 UID 소유 regular file·mode `0600`을
  검증한 뒤, `FD_CLOEXEC` fd에 process-lifetime exclusive `flock`을 잡는다. 이 lease는 첫
  AppSession/config migration/config write/restore/runtime spawn보다 먼저 획득하며 daemon/child에 상속하지 않는다.
  atomic replace 대상인 `workspace.v1` inode를 직접 잠그거나 정상 실행 중 lock file을 unlink하지 않는다. 두 번째 app
  process는 config·manifest write, restore, runtime 생성이 0인 명시적 unsupported 상태로 종료해 last-writer-wins를
  막는다. collaborative multi-app edit/read-only attach는 P5 이후 별도 범위다. `maru attach` CLI는 manifest를 쓰지 않는다.
  **L0 구현 완료:** lease는 Swift의 workspace URL에서 sibling path를 파생하고 Zig process-global owner가 보유한다.
  `NSApplication.shared`/Dock/controller 생성 전 startup loser는 `second instance unsupported`와 exit 2로 종료해
  termination/save 경로 자체에 진입하지 않는다.
  lock parent/leaf 생성은 fresh profile 획득을 위한 lease artifact로 허용되는 유일한 loser-side filesystem effect다.
  restrictive umask/fresh-create race/exec descendant는 unit gate가, 실제 실행파일 이중 실행의 sentinel 무변경과
  `SIGKILL` 뒤 재획득은 `mise run macos-app-instance-lease-smoke`가 검증한다.
- workspace 생성/삭제, split, rename/group/pin, Term 이동/닫기, cross-window 이동, binding 변경은 dirty를 만들고 짧은
  debounce 뒤 같은 디렉터리 temp write·atomic replace로 전체 manifest를 교체한다. GUI process 비정상 종료와 경합해도
  이전 또는 새 완전본 중 하나만 남겨야 하며, 창별로 따로 publish하지 않는다. 전원 손실 durability와 file/directory
  `fsync`는 비목표다.
- 위 목록은 topology 예시이지 전체 dirty inventory가 아니다. 영속 사용자 의도인 order/color, active tab/pane/Term,
  file/browser persisted state, dock 표시·view, explicit Explorer root, SCM base와 runtime ended tombstone도 포함한다.
  반면 checkpoint 때 최신 값을 함께 캡처하는 OSC title·cwd·prompt·agent·Git 관측 갱신은 자체 dirty를 만들지 않는다.
  창 frame은 move/live-resize 종료/fullscreen 종료에, active Window는 마지막 key normal Window identity가 실제로 바뀔
  때만 dirty다. quick focus나 앱 비활성화로 그 identity를 지우지 않는다.
- background checkpoint 실패는 마지막 완전본을 유지하고 typed notice를 지속한다. 정상 Quit의 마지막 checkpoint가
  실패하면 detach 전에 Quit을 취소한다. runtime을 종료하고 나가는 유일한 예외는 사용자가 명시한
  `Quit and End All Sessions`다.
- checkpoint coordinator는 `committed(generation)|stale|capture_failed|write_failed`를 반환한다. background 실패는
  dirty를 유지하고 bounded backoff를 쓰며, final Quit은 AppKit `terminateLater`에서 mutation freeze 또는
  captured generation=current를 확인한 뒤 성공 때만 reply/detach한다.
  순수 reducer의 exact event/effect·세대·재시도·notice coalescing·final Quit 계약과 시간 정책의 소유권은
  [영속 터미널 세션 호스트](persistent-session-host.md#p4--일반-window-default-readinessbackground-알림)의
  「C1 순수 coordinator 계약」을 단일 출처로 둔다. filesystem publication의 parent-descriptor 결속,
  고정 temp/final leaf, `0600`·no-follow, typed failure와 crash/fail-index 규칙은 같은 절의
  「C2 checkpoint file adapter 계약」을 단일 출처로 둔다.

### quick terminal 제외 계약

quick은 app-global singleton `AppSession`이지만 persistent session 범위에서는 영구 비목표다. 항상 in-process backend를
사용하고 workspace 파일에 block/handle을 쓰지 않으며 앱 Quit 때 runtime을 종료한다. 위치·크기·chrome·minimal-tabs 같은
기존 quick UX와 config는 유지한다. 이 불변식은 `is_quick => remote backend 0`, manifest quick record 0,
Quit 뒤 local child 종료 테스트로 고정한다.

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

## 에이전트 세션은 자동 복원하지 않는다

Workspace restore는 provider 세션 id·트랜스크립트·argv를 수집하지 않으며 claude/codex를 자동 resume/fork하지
않는다. 에이전트는 계정·권한·네트워크·외부 세션 상태를 가진 대화형 프로그램이므로, 사용자가 명시하지 않은 재실행은
일반 명령 재실행 금지와 같은 경계를 따른다. 복원되는 것은 해당 Term의 `shell_entry`, cwd, 레이아웃뿐이다.

구버전 workspace의 provider 관련 scalar는 전용 typed model 없이 일반 미지 scalar로 건너뛴다. 새 저장에는 해당 scalar가
나오지 않는 read-old/write-new 방식이므로 한 번 저장하면 자연스럽게 사라진다. 관련 옛 설정 이름도 일반 unknown key다.
상태 표시는 [에이전트 상태 감지](agent-session.md)가 단일 출처이며 host/runtime 종료를 provider 경로로 복구하지 않는다.

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
- claude/codex도 예외가 아니며 사용자가 셸에서 직접 다시 실행한다.

## 저장 모델의 초기 개념

아래 블록은 선언적 restore와 live object의 경계를 설명하기 위해 남긴 초기 개념 모델이며 실제 wire가 아니다. 현재 구현의
실제 line 형식은 뒤의 key-addressed 절과 `src/session/workspace.zig`, 영속 binding의 추가 형식은 위
“영속 session binding wire”를 따른다.

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

중요한 것은 저장 대상이 live object가 아니라 선언적 상태라는 점이다. 첫 줄 schema 토큰은 snapshot/trace와 같은 규칙으로
bare 토큰(`maru.workspace.v1`)을 쓰고 `schema=` 접두어를 두지 않는다.

멀티윈도우와 live surface 소유권은 [윈도우와 Surface 이동성](window-surface-mobility.md)을 단일 출처로 둔다. 현재 v1은 이미
한 header 아래 Window N개, 각 Window의 workspace order·pane tree·surface metadata, active window와 geometry를 저장한다.
GUI `surface_id + generation`은 재실행 때 새로 발급하되, persistent terminal은 저장된 `runtime-handle`에 다시 bind한다.
live PTY fd·child pid·WKWebView process handle·JS heap snapshot은 여전히 저장하지 않는다.

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
- **하위 호환**: additive 스칼라 필드는 key-addressed로 하위호환된다(옛 파일이 그 키의 기본값으로 복원 — 폴백 없음).
  구조 변경은 스키마 버전을 올리거나 통째 폴백+self-heal한다. 현재 unknown trailing line 성공 종료는 legacy 관용성이며
  새 block/tree/count의 확장점으로 일반화하지 않는다.

## 직렬화 전략: 스칼라 필드 key-addressed 파싱

> 상태: **구현됨**(`src/session/workspace.zig`의 `LineFields`). 이 절은 파서의 실패 모델과 하위호환 경계를 정의하는 단일 출처다.

**동기.** per-tab 스칼라 속성(현재 `custom_name`·`pinned`·`background_color`·`accent_color`; 앞으로 아이콘·정렬·메모 등 계속 추가 예정)이
늘 때, strict positional 파서라면 그 키가 없는 옛 파일을 **통째 파싱 실패**로 떨궈 **업데이트마다 워크스페이스 배치가 1회 리셋**된다
(self-heal 전까지). 필드가 지속적으로 느는 방향이라 그 누적 UX 비용을 없애려 스칼라 필드를 key-addressed로 읽는다.

**방식.** 각 스칼라 라인(`window`/`tab`/`pane`/`surface`)의 `key=value` 꼬리를 순서 무관 필드로 토큰화하고(`LineFields.parse`), 이름으로
조회한다. 따옴표 값은 escape(`\"`)를 존중해 경계를 잡으므로 값 안의 `key=` 흉내·공백이 토큰을 안 깬다. 구조 골격(라인 타입
토큰·self-delimiting 카운트·`tree-node` preorder)은 그대로 **positional**로 둔다 — 스칼라가 아니라 구조라 별개다(`FieldReader`, tree-node 전용).

**실패 모델 — required vs optional.** "없는 키=기본값"이 손상 파일을 조용히 그럴듯한-틀린 상태로 만들지 않게, 키를 둘로 나눈다:

- **required(구조 키)** — 없으면 블록 파싱이 불가능한 개수 키(`window.tabs`·`tab.panes`·`pane.surfaces`).
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

**범위 밖(하위호환 안 되는 변경).** 새 블록 타입 추가·`tree-node` 인코딩 변경·카운트 의미 변경은 지원 포맷으로 쓰지
않고 스키마 버전을 올린다(`maru.workspace.v1`→`.v2`). known block 내부에서 실제 parse error가 난 경우에만 통째
fallback/self-heal한다. unknown top-level trailing line은 현 parser가 early-success하므로 뒤 Window를 조용히 잃을 수
있고, 이 관용성을 구조 호환성으로 간주하지 않는다. additive 스칼라 필드는 버전을 안 올린다.

**writer.** writer는 required 필드와 각 optional 필드의 canonical emission 규칙(기본/부재면 생략 포함)을
결정론적으로 적용한다. 같은 모델을 반복 serialize하면 고정점이어야 한다. reader만 순서 무관·기본값이라 writer가 낸
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

헤더 불일치·known block 내부의 구조/tree/count 검증 실패·손상으로 저장 파일을 **실제로 통째로 파싱 못 하면**,
**알림(notice) 없이 조용히 기본 단일 창으로 시작**한다. 복원 불가는 사용자 잘못이 아니므로 중앙 모달로 키 입력을
막지 않는다. 단, v1 parser는 unknown top-level trailing line에서 early-success해 그 뒤 Window를 조용히 버릴 수 있다.
이는 전체 parse failure/self-heal 경로가 아니며 새 구조의 forward compatibility로 사용할 수 없다. 새 구조는 v2
reader/migration을 먼저 설계한다. **additive 스칼라 필드 추가는 key-addressed 하위호환이라 여기로 안 떨어진다**.
일부만 복원 실패(파싱은 됐으나 일부 창 적용 실패)는 이와 별개로 안내할 수 있다.

## 자동 테스트

- workspace fixture round-trip.
- live PTY fd·child pid가 저장 모델에 들어가지 않고 opaque `runtime-handle`만 들어가는지 테스트.
- 민감 env key가 저장되면 실패하는 테스트.
- `shell_entry`와 `startup_recipe argv`가 round-trip되는 테스트.
- `last_observed_command`가 자동 실행 후보로 저장되지 않는 테스트.
- cwd가 없을 때 surface별 restore failure artifact를 남기는 테스트.
- 구버전 provider scalar를 일반 미지 키로 무시한 채 두 창을 실제 적용하는 테스트.
- 새 저장에는 provider scalar가 없고 shell/cwd/layout/active round-trip만 유지되는 테스트.
- binding 필드가 없는 기존 fixture의 byte-stable parse/serialize와 옛 reader의 미지 `runtime-state` skip.
- `runtime-handle` exact length/lowercase hex/구분자와 `runtime-state` 부재/ended/미지 값/handle 없는 ended,
  duplicate exact-cap/cap+1.
- writer가 duplicate runtime binding에서 새 파일을 publish하지 않고 기존 완전본을 보존하는 fail-before-effect 테스트.
- 같은 runtime의 canonical owner Term 중복과 read-only mirror 표기를 모두 거부하되 host의 observer subscription N개는 허용하는
  layout-vs-client 경계 테스트.
- reader가 전체 semantic validation 전 host attach/spawn/Window publish를 정확히 0회 수행하는 deferred-AppSession
  ABI sentinel 테스트.
- 2 Window+3 Workspace의 cross-window Workspace/Pane/Term 이동에서 runtime handle byte identity, child/runtime 재생성 0, source/target
  원자 publish를 검증하는 headless transaction 테스트.
- temp write/atomic replace 각 fail-index와 GUI SIGKILL에서 이전 또는 새 완전 manifest만 읽히는 process 테스트.
- checkpoint generation stale completion, overlapping debounce, background save 실패의 dirty 유지·bounded
  backoff/notice coalesce, final Quit capture/write 실패의 app-quitting 정책 rollback·detach 0·Quit 취소 테스트.
- L0 두 app process의 lifetime lease 경쟁에서 writer 정확히 1, loser의 pre-AppKit exit와 config/workspace/cache
  무변경, winner SIGKILL 뒤 lease release/reacquire를 검증하는 process 테스트.
- P5 `maru attach` CLI가 구현될 때 GUI lease 유무와 무관하게 manifest write 0을 별도 process gate로 고정한다.
  아직 존재하지 않는 P5 CLI 명령을 L0 완료 증거로 세지 않는다.
- 실제 signed app을 종료·재실행해 같은 `runtime-handle`이 같은 child/scrollback에 붙는 무인 macOS E2E.
- ended Term을 Enter 없이 capture/Quit/relaunch하는 과정을 2회 이상 반복해 host probe·attach·새 shell spawn이 모두 0이고,
  Enter 성공 때만 새 live handle로 교체되는 durable tombstone E2E.
- ended Term close가 host probe/terminate 0으로 slot만 제거하고, Enter의 remote spawn 실패→local 성공은 old
  handle/state 제거 + `not preserved`, local spawn도 실패하면 tombstone 유지가 되는 테스트.
- unknown trailing line은 현재 legacy parser 동작을 fixture로 기록하되 새 구조 확장 호환성의 완료 증거로 사용하지 않는 테스트.
- 구 reader가 `runtime-state`를 무시한 뒤 저장하면 이를 잃는 downgrade 동작을 fixture로 고정하고 지원 round-trip으로
  오해하지 않는 release test.
- host 연결 실패로 in-process fallback한 Term에는 runtime handle이 없고 `not preserved` 상태가 Quit까지 남는 테스트.
- quick hide/show/config 변경은 기존 local runtime을 유지하지만 app Quit은 종료하며, remote backend/manifest
  record/notification cold attach가 모두 0인 회귀 테스트.

이 목록은 [영속 터미널 세션 호스트](persistent-session-host.md#14-무인-tdde2e성능-gate)의 TDD 층과 함께 적용한다.
수동 창 조작만 가능한 항목은 구현 완료로 세지 않으며 자동 runner가 없으면 해당 phase를 미완료로 둔다.
