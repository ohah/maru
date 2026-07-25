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

**web Term(4e)은 저장하지 않는다.** `workspace.Surface`에 kind 필드가 없어 web 패널을 표현할 수 없고(포맷에 kind 추가는 Phase 5), sentinel core를 일반 surface로 직렬화하면 복원 시 셸로 오spawn되므로 `captureWorkspaceTab`이 web Term을 **스킵**한다. 한 pane이 web Term만 가진 경우(모든 terminal Term을 닫음) surfaces가 비면 복원이 `error.EmptyPane`으로 전체를 중단하므로, 그 pane엔 **기본 셸 placeholder 하나**를 넣어 기본 로그인 셸로 복원한다(브라우저 콘텐츠·URL은 어차피 미영속). web 콘텐츠 영속은 Phase 5(콘텐츠·브리지)와 함께 포맷에 kind를 더해 다룬다. **구현 완료(2026-07-20, ABI v137)**: Explorer UX 보강은 기존 window line에 열린 빈 도크용 `dock-presented=1`과 explicit root의 단일 length-framed `dock-tree-roots` field를 추가했다. root field가 없으면 inferred이고 `0:` payload는 explicit-empty다. 유효한 `0:`만으로는 도크 표시를 파생하지 않지만, 손상된 root field는 explicit-empty로 강등하면서 field 존재가 나타낸 표시 의도를 보존하며 terminal과 dock entry를 폐기하지 않는다. 복원은 root를 canonical/no-follow identity로 검증하고 missing/invalid root만 버린 뒤 rows와 safety watcher를 함께 stage하며, root validation이 pending이면 restore를 거부한다. 전체 apply의 fail-index OOM 검증은 기존 tab/dock/root/rows/watch를 원자적으로 보존한다(상세 단일 출처=[file-panel.md](file-panel.md) §5·§7). Markdown entry mode와 dirty content 미영속 계약은 그대로다.

## 영속 session host와의 관계 (부분 구현)

workspace restore와 persistent-session attach는 서로 대체하지 않는다.

| 상태 | 시작 동작 |
| --- | --- |
| 같은 `host_id/runtime_id`가 살아 있음 | 새 shell을 spawn하지 않고 기존 runtime attach (**구현**) |
| manifest에는 있으나 runtime이 없음 | 자동 fresh spawn 금지. **그 Term만 종료 placeholder로 두고 나머지 surface·split·탭은 정상 복원한다(구현)**. 영구 부재(`PersistentRuntimeGone`)로 분류된 경우에만이며, 일시 실패는 계속 window apply를 실패시킨다. placeholder는 마지막 제목·위치와 `⏎` 안내를 화면에 남기고, `⏎`가 그 슬롯을 제자리 교체해 저장된 cwd에서 새 셸을 시작한다 |
| host가 없음·종료됨·재부팅됨 | 기존 handle은 ended. 새 shell을 열 수는 있지만 동일 session continuation 아님 |
| host에만 runtime이 남음 | 삭제하지 않음. `Recovered Sessions` 노출은 P4 계획 |

현재 `maru.workspace.v1`의 terminal `runtime-handle`은 구현됐다. writer는
`<host-id>:<runtime-id>`를 함께 쓰고 reader는 길이·lowercase hex·구분자를 fail-closed 검증한다. 옛
`runtime-id` 단독 파일은 한 번의 attach migration을 위해 읽지만 새 live capture는 bare ID를 만들지 않는다.
반면 `workspace-binding-id`, quick layout, 전역 binding 중복 검증, ended placeholder, incremental checkpoint는 아직
구현되지 않았다. 정상 종료 한 번에만 저장하는 현재 방식이라 GUI crash 직전 layout은 잃을 수 있으므로 이 항목들은
영속 session 기본 전환 전 gate다. 세부 소유권·ID·접속 실패 행렬은 persistent-session 문서를 따른다.

현재 정상 종료 checkpoint는 **모든 일반 Window 직렬화 성공 또는 write 0회**다. Window 하나라도 session handle이 없거나
직렬화에 실패하면 성공한 일부 Window만으로 기존 `workspace.v1`을 덮지 않고 마지막 완전본을 보존한다. restore도 Window
모델 publish 전에 surface들을 stage하며, 기존 persistent runtime attach 뒤 후속 surface가 실패하면 앞 runtime은
terminate하지 않고 controller subscription만 detach해 rollback한다. saved Window 하나라도 apply하지 못하면 그 추가 창은
default shell로 위장하지 않고 teardown하며, 이번 실행은 `restore incomplete`로 남는다. **apply가 성공했어도 복원이 조용히
버린 항목이 있으면 같은 래치를 세운다**(v144): capability 검증에서 버린 파일 패널 entry, 그 결과로 비워져 제거된 dock 그룹,
접근 불가로 강등한 explorer root, 그리고 **영구 부재로 분류돼 종료 placeholder가 된 Term**(저장된 `runtime-handle`을 잃는다 —
[persistent-session-host.md](persistent-session-host.md) "접속 실패 행렬")은 apply를 실패시키지 않지만 복원된 모델이 저장
파일을 표현하지 못한다는 뜻이므로, Zig가 그 개수를 `take_workspace_restore_dropped`로 노출한다. 개수는 정확한 회계가
아니라 판정용 신호다 — 한 원인이 entry와 빈 그룹 둘로 세어질 수 있다.

**checkpoint 보호(단일 출처).** 이 래치가 선 실행의 종료 저장은 **덮어쓰기 직전에 마지막 완전본을 `workspace.v1.bak`으로
한 번 남기고 정상 진행**한다(이미 `.bak`이 있으면 덮지 않는다 — 연속 불완전 실행이 가장 완전한 첫 사본을 밀어내지 않게).
처음 도입 때는 저장을 통째로 막았는데(v144), 그 래치에는 해제 경로가 없고 저장을 막으면 stale 파일이 그대로 남아 **다음
실행이 같은 drop을 다시 만든다** — 자기영속 루프다. 그동안 사용자가 만든 창·탭·split·pane rename·창 위치는 매 종료마다
조용히 사라져, 무기한 차단이 데이터 손실 방지가 아니라 데이터 손실 그 자체가 됐다(code-review max). 백업 후 저장은 잃을
뻔한 상태를 파일로 남기면서 루프를 끊는다. 복구는 사용자가 `.bak`을 `workspace.v1`로 되돌리면 된다.

quick은 아직 checkpoint 대상이 아니며 host orphan을 막기 위해 in-process backend로만 생성되어 앱 Quit 때 종료한다.

시작 host는 workspace 텍스트를 **AppSession 생성 전** Zig parser로 preflight한다(ABI v142,
`workspace_window_count(session=NULL)`). 복원할 Window가 하나 이상이면 각 AppSession을
`defer_initial_surface=1`로 만들어 기본 tab/PTY/renderer/frame loop를 만들지 않고, 저장 모델의 모든 Term을 stage한 뒤
첫 publish에서만 surface와 frame loop를 연다. 따라서 정상적인 persistent attach 복원은 임시 default shell이나
throwaway host runtime을 하나도 spawn하지 않는다. primary Window 적용 실패 때만 빈 deferred session을 폐기하고 명시적인
새 default-shell session으로 fallback하며, 이 실행은 위 `restore incomplete` 보호를 그대로 적용한다.

## 영속 session binding wire (runtime-handle 구현, 나머지 계획)

새 DB나 창별 파일을 만들지 않고 기존 `~/Library/Application Support/maru/workspace.v1` 하나가 Window/Workspace 배치의
단일 출처다. 현재 직렬화 모델에서 `Window`=OS 창, `Tab`=Workspace, `Pane`=split leaf, `Surface`=terminal Term이므로
일반 layout에는 optional quoted scalar를 추가하고, 현재 저장에서 빠지는 quick singleton은 normal window 뒤의 tail로 붙인다.

```text
maru.workspace.v1
window tabs=1 active-tab=0 active-window=1
tab panes=1 active-pane=0 custom-name="work" pinned=0 background-color=0 accent-color=0 workspace-binding-id="8b5f36a0f56d4a479ecb6077a87ac41c"
tree-node leaf pane=0
pane surfaces=1 active-term=0 custom-name=""
surface custom-name="" title="shell" cwd="/repo" command="/bin/zsh" cols=120 rows=40 runtime-handle="f16fe6b415c84f1a9c0df52448852955:3020a9d49cef45adb9fe56f25dad4f18"
quick-window tabs=1 active-tab=0
tab panes=1 active-pane=0 custom-name="quick" pinned=0 background-color=0 accent-color=0 workspace-binding-id="e47de1e44a60495aa48f02e939b5fc81"
tree-node leaf pane=0
pane surfaces=1 active-term=0 custom-name=""
surface custom-name="" title="scratch" cwd="/repo" command="/bin/zsh" cols=100 rows=30 runtime-handle="f16fe6b415c84f1a9c0df52448852955:b616db544aca443bab267404e15fb777"
```

| 필드 | 위치 | 형식·수명 | 키가 없을 때 |
| --- | --- | --- | --- |
| `workspace-binding-id` (계획) | `tab` line | Workspace 생성 때 발급한 opaque 128-bit random ID의 lowercase 32 hex. cross-window 이동 중 유지 | 옛/ephemeral Workspace. restore가 새 ID를 발급하되 동일 live workspace라고 주장하지 않음 |
| `runtime-handle` (**구현**) | terminal `surface` line | `<host-id>:<runtime-id>`, 양쪽 모두 lowercase 32 hex. 한 quoted scalar로 all-or-none | 선언적 surface. 설정에 맞는 새 runtime 생성 후보이며 기존 process continuation 아님 |
| `quick-window` (계획) | 모든 normal `window` 뒤의 optional tail | 0개 또는 1개. `tabs`/`active-tab` 뒤에 일반 tab/tree/pane/surface subtree 재사용 | quick을 아직 만들지 않았거나 옛 파일. 첫 toggle이 새 persistent quick runtime 생성 |

규칙:

- binding 필드는 기존 `LineFields`의 순서 무관 optional scalar다. 옛 reader는 미지 키로 skip하고 새 reader는 부재를
  legacy/default로 읽으므로 header는 `maru.workspace.v1`을 유지한다. 현재 구현된 `runtime-handle` reader는 옛
  `runtime-id` 단독 키도 엄격한 32 lowercase hex일 때만 migration 입력으로 허용하며 두 키가 함께 있으면 거부한다.
- `quick-window`는 기존 normal `window` loop가 끝난 뒤에만 오는 self-delimiting tail이다. 옛 reader는 첫 미지 trailing line에서
  정상 종료해 전체 quick subtree를 무시하므로 이를 일반 Window로 잘못 열지 않는다. 새 reader는 최대 1개만 인식하고 subtree를
  끝까지 검증한다. 이 증명이 깨지는 위치/형식으로 옮기면 v1 변경으로 허용하지 않는다.
- 키가 있는데 quoted 형식, 길이, lowercase hex, `:` 구분이 깨졌으면 `BadLine`이며 기존 "존재하는 optional 손상은 숨기지
  않는다" 규칙대로 checkpoint 전체를 거부한다. `runtime-handle`을 두 키로 나눠 partial state를 만들지 않는다.
- writer는 ID를 의미 있는 숫자나 path로 인코딩하지 않고, 같은 값의 재사용·자동 재발급으로 손상을 숨기지 않는다.
- **계획:** publish 전 전체 모델을 검증한다. `workspace-binding-id`는 manifest 전체에서 유일해야 하고, 하나의 `runtime-handle`은
  canonical owner terminal surface 하나에만 나타나야 한다. v1 manifest에는 같은 handle의 read-only mirror도 저장하지 않는다.
  중복이면 현재 live 모델과 마지막 완전 파일을 보존하고 새 checkpoint를 쓰지 않는다.
- **계획:** reader도 어떤 runtime attach/spawn이나 Window publish보다 먼저 전역 중복을 검사한다. 검증 실패 때 일부 창만 attach하는
  side effect를 만들지 않는다.
- **계획:** 올바른 handle인데 현재 host/runtime 목록에 없으면 파일 손상이 아니라 ended 상태다. 해당 surface만 종료 placeholder로 두고
  나머지는 attach한다. host에는 있지만 manifest에 없는 runtime은 `Recovered Sessions`에 둔다.
- runtime이 살아 있는 attach는 saved `cwd`/`command`로 새 shell을 spawn하지 않는다. `cwd`/`title`은 초기 표시 fallback이고
  host snapshot/metadata가 도착하면 live 값을 따른다.
- `runtime-handle`은 secret/capability가 아니다. workspace 파일을 읽은 client도 별도 session-host 인증 없이는 output/input을
  얻지 못한다.

### 멀티윈도우 저장·이동·동시 쓰기

> **P4 목표 계약:** 현재 구현은 정상 종료 시 모든 일반 Window를 한 번에 checkpoint하고, 실패 시 마지막 완전본을
> 보존한다. 아래 writer lease, dirty debounce incremental checkpoint, workspace binding/move transaction, 외부 observer
> 연동은 아직 구현되지 않았다.

- 기존 한 header 아래 `window` block N개가 모든 OS Window를 저장한다. 각 Window가 같은 host connection을 공유하지만 layout은
  계속 자기 `tab`/`pane`/`surface` block에 인라인으로 저장한다.
- Workspace cross-window 이동은 source `window`에서 같은 `tab` subtree를 제거해 target `window`에 삽입한다.
  `workspace-binding-id`와 그 아래 `runtime-handle`은 byte-identical로 유지되고 runtime/PTY를 재시작하지 않는다.
- Term/Panes 이동도 handle을 유지한 채 위치만 바꾼다. Workspace 복제는 새 `workspace-binding-id`를 발급하며 writable
  `runtime-handle`을 복제하지 않는다. 복제 UI가 필요하면 새 runtime을 만들거나 explicit placeholder로 둔다.
- GUI/CLI/SSH observer N개가 같은 runtime에 붙는 것은 host의 client subscription이며 manifest 중복이 아니다. Maru 내부
  Mirror Term은 owner close/terminate·알림 위치·독립 viewport 계약이 필요한 별도 non-owning surface이므로 v1에는 넣지 않는다.
- app-wide Quit은 모든 Window를 한 checkpoint로 publish한 뒤 GUI client를 detach한다. 비마지막 Window/Workspace/Term의
  명시적 close는 기존 close 의미대로 소속 runtime 종료 확인을 먼저 거친다.
- manifest writer는 `Maru.app` process 하나다. 비정상적으로 두 GUI process가 같은 파일을 열면 파일 writer lease를 얻은
  process만 restore mutation/checkpoint를 수행한다. 다른 process와 `maru attach` CLI는 observer/개별 attach만 가능하고
  manifest를 쓰지 않는다.
- workspace 생성/삭제, split, rename/group/pin, Term 이동/닫기, cross-window 이동, binding 변경은 dirty를 만들고 짧은
  debounce 뒤 같은 디렉터리 temp write·file sync·atomic rename으로 전체 manifest를 교체한다. crash는 이전 또는 새 완전본
  중 하나만 남겨야 하며, 창별로 따로 publish하지 않는다.

### quick terminal 저장·재연결

> **P4 계획:** 이 절은 아직 구현되지 않았다. 현재 quick은 workspace 파일에 쓰지 않고 persistent backend도 사용하지 않는다.

- quick은 app-global singleton `AppSession`이며 normal Window count, active-window, frame, dock/explorer에 포함하지 않는다.
  `quick-window`는 Workspace/Pane/terminal Term layout과 binding만 저장한다. panel position/size/screen/chrome/minimal-tabs는
  config, visible/hidden 상태는 transient라 앱 시작 시 항상 숨김이다.
- quick이 한 번도 생성되지 않았으면 tail이 없다. 생성된 quick을 hide/auto-hide/Esc로 숨겨도 tail과 runtime은 유지한다.
  첫 toggle 때 dormant layout을 materialize하고 live handle에 attach하며 새 shell을 중복 spawn하지 않는다.
- quick runtime의 notification click으로 cold launch하면 normal Window가 아니라 quick panel을 lazy 생성하고 발신
  Workspace/Pane/Term을 활성화해 보여 준다.
- quick은 cross-window move/merge의 source/target이 아니다. quick Term을 normal Window로 이동하거나 그 반대의 UX는 별도
  trust-boundary 설계 전 비범위다.
- config의 chrome 변경은 GUI session만 다시 만들고 같은 handles에 reattach한다. `minimal-tabs=false`로 바뀌어도 기존 여러
  Workspace/Term/split을 삭제하지 않고 이후 생성 command만 막는다.
- manifest의 normal windows와 quick tail 전체가 한 writer lease·한 atomic checkpoint다. quick만 별도 파일/DB에 쓰지 않는다.

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
  구조 변경은 원칙적으로 스키마 버전을 올리거나 통째 폴백+self-heal한다. 유일하게 허용한 예외는 모든 normal Window 뒤에
  위치해 옛 reader가 통째로 무시하는 self-delimiting `quick-window` tail이다(위 binding wire 절). 다른 새 block/tree/count는
  이 예외를 일반화하지 않는다.

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

**범위 밖(하위호환 안 되는 변경).** 위에서 명시한 마지막 `quick-window` tail 외 새 블록 타입 추가·`tree-node` 인코딩 변경·
카운트 의미 변경은 구조 파괴라 스키마 버전 bump(`maru.workspace.v1`→`.v2`) 또는 통째 폴백+self-heal 대상이다
("[저장 파일을 통째로 파싱 못 할 때](#저장-파일을-통째로-파싱-못-할-때)"). additive 스칼라 필드는 버전을 안 올린다.

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

## 자동 테스트

- workspace fixture round-trip.
- live PTY fd·child pid가 저장 모델에 들어가지 않고 opaque `runtime-handle`만 들어가는지 테스트.
- 민감 env key가 저장되면 실패하는 테스트.
- `shell_entry`와 `startup_recipe argv`가 round-trip되는 테스트.
- `last_observed_command`가 자동 실행 후보로 저장되지 않는 테스트.
- cwd가 없을 때 surface별 restore failure artifact를 남기는 테스트.
- 구버전 provider scalar를 일반 미지 키로 무시한 채 두 창을 실제 적용하는 테스트.
- 새 저장에는 provider scalar가 없고 shell/cwd/layout/active round-trip만 유지되는 테스트.
- binding 필드가 없는 기존 fixture의 byte-stable parse/serialize와 옛 reader의 미지 binding key skip.
- `workspace-binding-id`와 `runtime-handle` exact length/lowercase hex/구분자, 부재, 손상, duplicate exact-cap/cap+1.
- writer가 duplicate workspace/runtime binding에서 새 파일을 publish하지 않고 기존 완전본을 보존하는 fail-before-effect 테스트.
- 같은 runtime의 canonical owner Term 중복과 read-only mirror 표기를 모두 거부하되 host의 observer subscription N개는 허용하는
  layout-vs-client 경계 테스트.
- reader가 전체 semantic validation 전 host attach/spawn/Window publish를 정확히 0회 수행하는 fake backend 테스트.
- 2 Window+3 Workspace의 cross-window Workspace/Pane/Term 이동에서 binding byte identity, child/runtime 재생성 0, source/target
  원자 publish를 검증하는 headless transaction 테스트.
- temp write/file sync/atomic rename 각 fail-index와 GUI SIGKILL에서 이전 또는 새 완전 manifest만 읽히는 process 테스트.
- writer lease를 동시에 경쟁한 두 GUI test process 중 하나만 checkpoint하고 loser/CLI write가 0인 통합 테스트.
- 실제 signed app을 종료·재실행해 같은 `runtime-handle`이 같은 child/scrollback에 붙는 무인 macOS E2E.
- quick tail 0/1/2개, normal window 앞/사이/뒤 위치, truncated subtree, 옛 reader가 quick 전체를 무시하고 normal windows를
  byte-identical하게 복원하는 호환 테스트.
- quick hide/show/app quit/relaunch/config chrome 변경에서 runtime ID·child pid·scrollback 불변, 새 spawn 0, panel 시작 hidden,
  notification click이 exact quick Term을 여는 무인 macOS E2E.

이 목록은 [영속 터미널 세션 호스트](persistent-session-host.md#14-무인-tdde2e성능-gate)의 TDD 층과 함께 적용한다.
수동 창 조작만 가능한 항목은 구현 완료로 세지 않으며 자동 runner가 없으면 해당 phase를 미완료로 둔다.
