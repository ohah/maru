# 9·10단계 — Workspace restore와 Plugin/Wasm 구현 계획

workspace 복원과 plugin/Wasm 단계의 구현 계획이다. 복원 계약의 단일 출처는 [Workspace Restore 전략](../workspace-restore.md)이고, plugin 경계는 [터미널 호환성/보안 정책](../terminal-compatibility-policy.md#plugin--wasm)이 소유한다.

## 9단계: Workspace restore

목표:

- 프로젝트별 workspace 저장.
- 탭/분할 layout restore.
- 각 surface의 cwd/env/shell_entry/startup_recipe restore.
- `last_observed_command`는 최근 작업 표시 후보일 뿐 자동 재실행 대상이 아님을 검증한다.
- 최근 workspace 빠른 복구.
- repo별 기본 레이아웃과 scratch terminal 정책.
- 저장 대상, env redaction, command restore 정책은 [Workspace Restore 전략](../workspace-restore.md)을 따른다.
- command 자동 재실행 금지와 shell integration opt-in 정책은 [터미널 호환성/보안 정책](../terminal-compatibility-policy.md)을 따른다.

TDD 방식:

- serialized workspace fixture round-trip.
- restore E2E: 저장된 layout -> surface 생성 -> shell_entry/startup_recipe/cwd/env 확인.
- 민감정보 test: env/token/path가 fixture에 그대로 들어가지 않는지 확인.
- 안전 test: `last_observed_command`가 startup_recipe처럼 자동 실행되지 않는다.

완료 기준:

- live PTY handle은 저장하지 않는다.
- 저장 포맷은 선언적 상태만 담는다.
- 복구 실패 시 어떤 surface가 왜 실패했는지 artifact가 남는다.

### 설계·결정 (window-aware, 사용자 결정 2026-06-14)

확정 순서(New Window → restore → chrome)의 하드 제약대로 **window-aware**다(workspace-restore.md 초안은 cmux 풀 모델·멀티 창 이전이라 surface/tab만 — 현재 모델 windows→tabs→pane split 트리→Term에 맞춰 확장). 토대는 이미 상당: `app.surface.RestorableSurfaceMetadata`(id·title·cwd·command·size), `core.currentCwd()`(OSC 7)·`windowTitle()`(OSC 0/2)·`Surface.command`, `split_tree`(dir/ratio), snapshot/trace 직렬화 컨벤션.

- **D-범위 = 최근 세션 1개**(사용자 결정): 앱을 닫을 때의 전체 상태(모든 창·탭·split·cwd)를 전역 1개로 저장·복원("끄던 그대로 다시 열기"). repo별 workspace는 후속(이 위에 얹는 레이어).
- **D-트리거 = 자동 복원, 기본 ON + config 토글, 정상 종료분만**(사용자 결정): 앱 시작 시 마지막 세션을 자동으로 다시 연다(layout·cwd·shell 시작까지만 — **명령 자동실행 없음**이라 안전). config로 끌 수 있고, **크래시 후엔 복원 안 함**(정상 종료 때 저장한 것만). 첫 실행·저장 없음·복원 off면 기본 빈 창 1개.
- **보안(정책 그대로)**: live PTY/process/grid 내용 저장 안 함, `last_observed_command` 자동 재실행 안 함, redaction deny-by-default([project-rules.md] 단일 출처). **env override·startup_recipe 자동실행은 구현 전 재확인 필요(정책)라 v1 제외** — v1은 layout·cwd·shell_entry(command)만.

### 분해 (R1~R6)

- **R1 직렬화(writer) — 완료**: `src/app/workspace.zig`에 값-타입 모델(Workspace→Window→Tab→{TreeNode preorder + Pane}→Surface)과 `serialize`(`maru.workspace.v1`). snapshot/trace 규칙(첫 줄 bare 토큰·`<kind> <fields>`·`\"`/`\\`/개행 escape) 따름. split 트리는 preorder TreeNode(split는 뒤 두 subtree 소비, full binary tree라 self-delimiting). 모델에 PTY/process 필드 없음(선언적). 검증: 헤드리스 writer 테스트(단일 창/탭/pane/surface·중첩 split·멀티 창·cwd/title escape) + fmt + boundaries + swift-check + 스모크. **순수 Zig, 라이브 AppSession 미접촉**(R3 캡처가 모델을 채운다).
- **R2 파서(reader) — 완료**: `workspace.zig`에 `parse`(텍스트 → `ParsedWorkspace`, arena가 모든 슬라이스·escape 해제 문자열 소유 → deinit 한 번). 라인 단위 dispatch + 순차 `FieldReader`(word/key/uint/quoted — 따옴표 값이 다른 key를 흉내내도 sequential read라 안전), split 트리는 writer와 같은 preorder를 재귀로 재구성(split→두 subtree 소비, self-delimiting). 알 수 없는 trailing 라인은 forgiving 종료, 잘못된 헤더는 error. 검증: round-trip(중첩 split·멀티 창·escape를 serialize→parse→serialize 고정점) + parse 단위(구조·ratio·escape 해제·forgiving·BadHeader) + 게이트 전부. **writer↔reader 일치 고정.**
- **R3 캡처(한 창) — 완료**: `AppSession.captureWorkspaceWindow(arena)`가 라이브 탭→pane split 트리→Term→surface를 걸어 `app.workspace.Window` 모델로(선언적만 — live PTY/grid 제외). cwd/title=OSC 권위 소스(`core.currentCwd`/`windowTitle`), command=`surface.command`(argv[0]), size=core size. split 트리는 `*Pane` leaf를 tab.panes 인덱스로 환원해 preorder TreeNode로 평탄화(`flattenPaneTree` — 직렬화 모델과 같은 형태). arena가 모든 슬라이스·문자열 소유. 검증: macOS 통합(split+새 탭+OSC 7 cwd → 캡처 → 탭 2·tab0 pane 2·tree preorder(split,leaf,leaf)·cwd 잡힘·유효 size → serialize가 기대 라인). **멀티 창 전체 모델·ABI·Swift 합치기는 R5(영속화)** — 각 세션의 Window를 헤더 하나 아래로 모은다.
- **R5 저장(영속화·저장 side) — 완료**: 정상 종료 시 멀티 창 workspace를 디스크에 저장한다. ABI `maru_macos_app_session_serialize_workspace`(버전 36→37 — 세션마다 헤더 없는 `window …` 블록을 캡처+직렬화해 세션-소유 버퍼로, `app.workspace.serializeWindow` + R3 캡처). Swift `saveWorkspace()`가 `applicationWillTerminate`에서 shutdown '전에'(세션 살아 있을 때) 각 일반 창의 블록을 ABI로 받아 `maru.workspace.v1` 헤더 하나 아래로 모아 `~/Library/Application Support/maru/workspace.v1`에 atomic write. quick 패널 제외, smoke·빈 창·쓰기 실패는 best-effort 건너뜀. **크래시 가드는 자동** — applicationWillTerminate가 정상 종료에만 불려, 크래시 세션이 마지막 저장을 안 덮는다. 검증: 헤드리스(serializeWorkspaceWindow가 헤더 없는 `window` 블록·cwd 포함·재호출 시 이전 버퍼 해제[leak 없음], serializeWindow 집계 round-trip[헤더+블록들 → parse 2창]) + ABI 계약(37) + swift-check + app-smoke. 실제 파일 저장은 앱 수동(정상 종료 후 파일 확인).
- **R4a 복원 apply(한 창, Zig) — 완료**: `AppSession.applyWorkspaceWindow(model)`가 한 창 모델을 라이브 트리로 재생성한다 — 새 탭들을 먼저 다 빌드(각 pane을 첫 surface로 spawn + 나머지 Term 추가, split 트리는 모델 preorder대로 `PaneTree.Split` 직접 할당)한 뒤 기존 기본 탭을 teardown하고 swap(빌드 실패면 새 것만 정리, 기존 세션 보존). 각 Term은 저장된 **cwd에서 새 셸 spawn**(`SpawnRequest.cwd` — chdir; 빈 cwd면 기본). title/command는 정적 기본(셸이 OSC로 곧 재설정), size는 모델값(이후 resize 보정). 메모리: capacity 예약으로 swap 무실패, split 추적 리스트로 에러 시 해제. 검증: macOS round-trip(모델 → `applyWorkspaceWindow` → `captureWorkspaceWindow`가 탭/split dir·ratio/pane/Term·active 인덱스 일치) + 전체 게이트 + app-smoke. cwd는 OSC-side라 capture로 round-trip 안 함(spawn chdir은 앱 수동). **ABI 무변경.**
- **R4b 로드 + 멀티 창(Swift) — 완료**: 시작 시 저장된 workspace를 복원해 restore가 end-to-end로 닫힌다(저장 R5 → 로드 R4b). ABI `maru_macos_app_session_apply_workspace`(버전 37→38 — 헤더+한 창 텍스트를 parse[R2]해 세션에 `applyWorkspaceWindow`[R4a] 적용; parse 실패=invalid_config·apply 실패=create_failed·best-effort). Swift `restoreWorkspace()`가 `applicationDidFinishLaunching`에서 startAppSession '뒤'에: `loadWorkspaceBlocks`(파일 읽어 헤더 검증 후 `window ` 라인 경계로 창 블록 분할) → 첫 블록은 primary에 `applyWorkspaceBlock`(헤더 붙여 ABI), 나머지 블록마다 `createTerminalWindow(applyingBlock:)`(W2 팩토리를 블록 적용 가능하게 리팩터). 저장 없음·헤더 불일치·복원 off(`MARU_NO_WORKSPACE_RESTORE` env — config 토글은 후속)·smoke·빈 블록이면 기본 단일 창 유지. 검증: 헤드리스(복원 text → `parse` → `applyWorkspaceWindow` → capture가 단일 탭·split vertical ratio 300·pane 2·active 일치) + ABI 계약(38) + swift-check + app-smoke(smoke는 복원·저장 둘 다 끔) + 전체 게이트. 실제 복원(⌘Q 후 재실행에 레이아웃·cwd 되살아남)은 앱 수동.
- **R6 보안 가드 + 없는 cwd graceful — 완료**: ① **민감 데이터 미저장 가드**: serialize 텍스트에 `env=`/`fd=`/`pid=`/`last-observed` 라인이 없음을 단언 — 모델이 그런 필드를 안 가져 live 핸들·env·last_observed_command가 저장 텍스트에 절대 안 샌다(workspace-restore.md 정책; 누가 그런 필드를 추가하면 깨져서 위반을 잡는 회귀 가드). cwd는 path라 정상 저장(redaction 대상은 env, path 아님). ② **없는 cwd graceful**: `usableRestoreCwd`가 존재하는 절대 디렉터리(libc `access` X_OK = chdir 가능)일 때만 그 cwd를 spawn에 쓰고, 없으면 null → 기본 cwd로 spawn해 **surface를 잃지 않는다**(잘못된 cwd면 자식 chdir이 `_exit(126)`이라 미리 확인 안 하면 복원 셸이 즉시 죽어 reap된다). 검증: `usableRestoreCwd` 단위(존재/없음/빈값/상대경로 — 크로스플랫폼) + macOS 통합(없는 cwd 모델 apply → 실패 없이 탭·surface 복원) + 민감 데이터 가드 + 전체 게이트. **이로써 9단계 Workspace restore(R1~R6)가 닫힌다.** 후속: config 토글(env disable 현재 env-var), 부분 복구 artifact(한 surface 실패 시 이유 기록), startup_recipe/env allowlist(정책 재확인 후), repo별 workspace.

### incremental checkpoint (R7 — 계약은 [persistent-session-host.md](../persistent-session-host.md) §P4)

R5 는 **정상 종료 시점 한 번**만 저장한다(`saveWorkspace()` 호출부가 하나다). 그래서 강제 종료·크래시면
배치가 마지막 정상 종료 때 것으로 남고, keep-alive 를 켠 경우엔 그 사이 만든 runtime 이 manifest 에 안 실린다.
「incremental manifest checkpoint 가 없어 최신 layout 자동 재연결은 아직 완료 계약이 아니다」(§2)가 이 상태다.

순수 층은 이미 둘 다 있다 — P4 C1 coordinator(dirty 세대·debounce/retry·final Quit)와 C2 원자적 발행 leaf.

**✅ 구동까지 구현돼 있다(2026-08-28 확인). 아래 R7-0~R7-3 은 「할 일」이 아니라 「이미 되어 있는 것」이다.**

이 절은 원래 R7-0~R7-3 을 남은 작업으로 적고 있었다. **틀렸다** — 계획 문서와 백로그만 보고 세운 것이고,
착수 시점에 `MaruAppHost.swift`·`app_host_abi.zig` 의 현재 상태를 다시 확인하지 않았다. 실제로는 신호부터
구동·완료 보고·최종 발행까지 전부 있다. 같은 실수를 막으려고 **어디에 있는지**를 적어 둔다.

| 원래 적었던 「할 일」 | 실제 구현 |
|---|---|
| **R7-0 게이트**(복원 중엔 저장 금지) | `armWorkspaceCheckpoint(initialDirty:)` 가 `windows.allSatisfy { $0.appSession != nil }` 로 막는다 — 「staged Window 가 하나라도 남아 있으면 아무 세션도 publish 하지 않는다」. 세션마다는 `workspace_checkpoint_mutations_enabled` 가 arm 될 때 켜지므로, 복원·빌드 단계의 변경은 애초에 coordinator 에 닿지 않는다. |
| **R7-1 `TerminationWindowPolicy` 전제** | 넓힐 것이 없다. 파라미터 문서가 `currentKeyIndex` 를 「종료가 아닌 경로의 판정 근거」로 이미 적고, `tests/macos_termination_window_policy.swift` 가 그 경로를 고정한다(`capturedKeyIndex: nil, currentKeyIndex: 3` → 3). |
| **R7-2 구동 + 완료 보고** | ABI `maru_macos_workspace_checkpoint_{arm,tick,quit_requested,capture_completed,write_completed,mark_*}` 와 Swift 의 effect 루프. 저장은 `captureWorkspaceSnapshot(useTerminationKeyWindow:publishedOnly:)` 가 하고, 성패가 `capture_completed`/`write_completed` 로 coordinator 에 되돌아간다 — 걱정했던 「`Void` 라 성패를 못 넘긴다」는 해소돼 있다. |
| **R7-3 디바운스 주기** | `arm` 이 `debounce_ns = 500ms`, `retry_initial_ns = 1s`, `retry_max_ns = 30s` 로 정한다. |

신호는 `AppSession.workspaceChanged(kind)` 하나로 들어가고, `kind` 가 무엇이 바뀌었는지 구분한다
(`topology`/`selection`/`ordering`/`appearance`/`dock`/`naming`/`scm_base`/`runtime_binding`/`persisted_surface`/
`explorer_roots`). 호출부는 **manifest 에 보이는 transaction 의 성공 꼬리에서만** 부른다 — 진행 중에 부르면
반쯤 바뀐 배치가 발행된다.

⚠️ **P4 C3-1(`noteWorkspaceMutation`)은 되돌렸다.** 위 체계와 별개로 앱 전역 coordinator 를 하나 더 만들고
5 개 호출부를 달았는데, 그 두 번째 coordinator 는 아무도 `tick` 을 몰지 않아 dirty 만 세우고 끝났다. 게다가
호출 지점이 `createTab`/`closeTab`/`moveTab` 은 이미 `workspaceChanged` 가 덮는 자리였고,
`detachTabForMove`/`moveWorkspaceToSession` 은 **transaction 진행 중**이라 위 규율을 어겼다.

- **후속(지금 아님)**: 정책·쓰기를 Zig 로 이관(플랫폼마다 다시 짜면 아까운 것은 「조립」이 아니라 **정책** —
  전체 포기·검증 순서·`.bak`), 원자적 교체 seam(POSIX `rename` vs Windows `ReplaceFile`)은 **Windows 가 실제로
  필요할 때**. 지금 옮기면 POSIX 전용 «공용» 모듈이 된다.

## 10단계: Plugin/Wasm

목표:

- plugin은 domain event와 action facade로만 상호작용한다.
- plugin이 `TerminalCore` private storage, PTY handle, renderer resource를 직접 만지지 못하게 한다.
- v1에는 Wasm runtime을 넣지 않고, 장기 permission model 경계만 유지한다.

TDD 방식:

- fixture plugin.
- permission failure test.
- plugin panic/failure isolation test.

완료 기준:

- plugin ABI와 권한 모델은 [터미널 호환성/보안 정책](../terminal-compatibility-policy.md#plugin--wasm)의 capability 방향을 기준으로 하되, 구현 전에 사용자와 별도 논의한다.
- plugin 실패가 surface/window 전체를 죽이지 않는다.
