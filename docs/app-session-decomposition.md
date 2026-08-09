# app_session.zig 분해 — 실행 플랜

> L4 macOS 어댑터의 거대 단일 파일(`src/platform/macos/app_session.zig`)을 목적별 파일로 가르는 **실행 플랜**이다. 위상 골격의 단일 출처는 [레이어링과 이식성](layering-and-portability.md)이고, 분해 패턴의 검증된 선례는 [terminal core 분해](terminal-core-decomposition.md)다(`core.zig` 9962→6166, 방향 A, 누적 `/code-review max` 정확성 버그 0). 이 문서는 그 패턴을 `app_session`에 적용하는 단계·선결을 담는다.

## 1. 배경 (측정 — 2026-08-08)

`src/platform/macos/app_session.zig`는 **72,317줄·`AppSession` 단일 struct**다. 실측 구성:

| 구획 | 라인 | 비고 |
|---|---|---|
| **test 블록(파일 레벨)** | **32,762 (45%)** | 755개. private 메서드를 광범위 호출(아래 §2-c) |
| `AppSession` struct 메서드 | 27,729 (1,244개) | 그룹 분산 대상 |
| 나머지(파일 레벨 free 헬퍼·struct 정의) | ~11,800 | `spawnRequest`·`normalizeConfig`·`sidebarBandCell` 등(이미 free) |

**성장 이력** — 분해 판단 기준을 다시 잡게 된 실측 근거다(§4 (c)):

| 시점 | 라인 | 비고 |
|---|---|---|
| 2026-06 | 20,183 | 이 문서 최초 측정 · (b) 결정 시점 |
| 2026-07 | 35,134 | (b) "일단락" 이후 |
| 2026-08-08 | **72,317** | (b) 결정 대비 3.6배 |

**거대 메서드 top(2026-08-08)**: `tick`(1,484)·`mouse`(978)·`maybeDebugOpenSettings`(568)·`handleKeyEvent`(401)·`buildSidebarTitleDrawList`(363)·`deinit`(322)·`rebuildSidebar`(320)·`hoverCursor`(256)·`updateFileTree`(217)·`init`(205). `tick`/`mouse`/`handleKeyEvent`는 **오케스트레이션 허브**(프레임 루프·입력 라우터)다 — `tick`은 멀티 페인 통합 빌드(`collectShaped`→`placeMultiPane`→`placeAndDistribute`, 활성 panel `shapeOnlyBuild` 합류)를 품는다. (`buildSidebarTitleFrame`/`buildChromeOverlayFrame`/`buildFloatingTabFrame`은 통합 후 production 미사용이라 test 전용 free 헬퍼로 분리했다.)

## 2. 성격 규정 (정직 — 선결)

- **이식성 직접 기여는 없다.** `app_session`은 **L4 macOS 어댑터**라, 다른 OS로 포팅 시 **재작성 대상**이다(`layering` §2 "L4 = 재작성"). 따라서 이 분해의 1차 목적은 **가독성·테스트 격리·유지보수**이지 이식이 아니다. 이 점을 먼저 못박는다([[prefer-policy-over-codebase-mimicry]]는 정책 우선이지, 없는 이식 효과를 만들지 않는다).
- **단, 섞여 있는 OS-중립 순수 로직은 session(L2)으로 빼면 이식 기여 + 헤드리스 테스트가 따라온다.** 후보(측정): 레이아웃 기하(`gridFromBacking`·`pointInRect`·`paneDropZone` 등 — **b1로 `session/layout_math.zig` 완료**)·`pxToCell`(**b2로 인자 분리 완료** — self/surface에서 cell·grid 뽑아 위임)·sidebar 레이아웃 수학(실측 순수 극소)·workspace 트리 변환. **순수는 `src/session`으로, macOS orchestration은 `src/platform/macos/app_session/<group>.zig`로** 가른다.
  > **실측 정정(E1 착수):** Explore 사전조사가 "find 매치선택 순수 90%"로 추정했으나, 실제 Find(⌘F)는 `chrome_host.find`(UI 상태)·`activeSurface().core`(검색 락)·`runtime`(뷰 스크롤)·`metal_dirty`에 전부 결합한 **orchestration이라 순수분 0**(매치 선택조차 chrome 컴포넌트의 `next`/`prev` 소관)이다. 따라서 E1은 session 이동이 아니라 `app_session/find.zig` 가독성 분리다. 사전 추정 순수도는 착수 시 코드로 재검증한다([[roadmap-docs-stale-verify-with-code]]).
- **(c) core.zig보다 어려운 3가지 난점:**
  1. **허브 횡단**: `tick`/`mouse`/`handleKeyEvent`가 모든 그룹을 횡단한다 → **잔류**(분해 대상 아님, 내부 가독성은 소함수·주석으로).
  2. **가시성(pub) 표면 확대**: 그룹을 free fn 파일로 빼면, 그 함수가 **파일 경계를 넘어 이름으로 참조하는 모든 선언**이 pub이어야 한다. Zig의 privacy는 필드가 아니라 **선언 단위 + 파일 경계**이므로 대상이 accessor에 그치지 않는다 — 메서드(`^    fn ` 1,042개 vs `^    pub fn ` 185개, **84%가 non-pub**), 시그니처·지역에서 이름을 쓰는 타입(`Model`/`Term`/`Pane`/`PaneTree`/`Tab` 등 파일 스코프 `const`), 모듈 전역 `var`(`app_runtime` — 한 번 `pub var`가 되면 다시 좁힐 수단이 없다)가 모두 포함된다. core.zig의 accessor 분리(`absRow` 등, [[core-zig-decomposition-initiative]])와 동형이나 **규모가 다르다**. 실측 예: F1(archive) 하나가 그룹 밖 non-pub 메서드 19개 pub화를 강제하고 그중 12개는 F3(agent dock) 소유다 → 단계 순서가 pub화 소유권과 어긋나면 되돌리는 PR이 생긴다.

     **pub화 개수는 사전 추정으로 못 맞춘다(3회 연속 실패).** F1 test 이동 예측 0 → 실제 78, F2 pub화 예측 26 → 실제 50이었다. 원인은 같다 — 호출을 정규식으로 세면 receiver 형태(`session.`·`s.`·`dst.`)와 **타입 메서드**(`entry.path()`·`map.insert()`·`store()`·`hit()`)를 놓친다. **착수 전 추정치는 하한으로만 쓰고, 실제 값은 옮긴 뒤 컴파일러에게 묻는다.** 그래서 각 그룹 PR은 pub화 목록을 본문에 싣는다.
  3. **test는 잔류가 기본값이다(2026-08-09 실측으로 정정).** 파일 레벨 test 32,762줄(755개)이 `splitActivePane`·`mouse`·`handleKeyEvent`·`tick` 등 **private 메서드를 직접 호출**한다.

     원래 이 항목은 "test는 자신이 검증하는 그룹 함수와 동반 이동한다"였다. 그룹 함수가 pub free fn이 되므로 test도 따라가야 캡슐화가 지켜진다는 논리였다. **F1+F3를 실제로 실행해 두 방식을 모두 돌려 보니 정반대였다:**

     | 방식 | 강제되는 pub화 |
     |---|---|
     | test **동반 이동** | **78개** — `splitActivePane`·`newTab`·`dispatchAppAction`·`deinit`까지 열린다 |
     | test **잔류** | **13개** — 그룹이 밖으로 부르는 공용 accessor뿐 |

     이유는 비대칭이다. 그룹 test가 그룹 함수를 부르는 것(잔류 시 비용)보다, 그 test가 **그룹과 무관한 app_session 메서드를 부르는 것**(이동 시 비용)이 훨씬 많다. 판정자는 세션을 세우고(`initSmokeSessionSized`) 탭을 만들고 입력을 흘려보낸 뒤 그룹 동작을 확인하므로, 본문보다 훨씬 넓은 표면에 닿는다. **그러므로 test는 `app_session.zig`에 남기고 그룹 함수만 pub으로 노출한다.**

     사전 추정으로는 이 결론을 얻을 수 없었다 — 호출 패턴을 정규식으로 세면 receiver 형태(`session.`·`s.`·`dst.`)와 간접 호출을 놓쳐 3개로 나왔다. **두 방식을 다 실행해 컴파일러가 요구하는 pub 개수를 센 뒤에야 갈렸다.** 다음 그룹도 같은 방식으로 확인한다([[roadmap-docs-stale-verify-with-code]]).

     **그리고 이것이 이 저장소의 일관된 방식이다.** 선례인 [terminal core 분해](terminal-core-decomposition.md) §1.7이 같은 결론을 이미 적어 두었다 — *"테스트는 core.zig에 남아 public API로 동작을 보존한다 … 테스트는 facade를 검증하므로 core.zig에 둔다"*. 실제 배치도 그렇다: `core.zig` test 358개인데 갈라져 나간 `parser.zig`·`osc.zig`·`kitty.zig`·`types.zig`는 **0개**, `screen.zig`·`selection.zig`는 1개씩이다. 즉 **기존 파일을 분해할 때는 test를 원본에 남기고**(동작-보존 그물 유지), **새 파일을 처음 작성할 때만 그 파일에 test를 쓴다**(`session_host/*`가 그 경우). F 시리즈는 전자다. 원래 이 항목의 "동반 이동" 지침만 그 선례와 어긋나 있었다.

     남는 문제: 파일 스코프 test 헬퍼 63개가 전부 non-pub이고 그룹을 횡단한다(`initSmokeSessionSized` 184회). test가 잔류하면 이 문제는 **당장은 터지지 않지만**, 그룹 파일이 자체 test를 갖게 되는 날 다시 온다. 공용 헬퍼 소유처는 그때 정한다.

## 3. 패턴 (core.zig 방향 A)

```zig
// src/platform/macos/app_session/find.zig
const AppSession = @import("../app_session.zig").AppSession; // 순환 import OK(Zig, core↔screen 선례)
pub fn nextMatch(self: *AppSession) void { ... }   // *AppSession 받는 free fn(필드 직접 접근)
test "nextMatch wraps" { ... }                     // 검증 대상과 동반

// src/platform/macos/app_session.zig
const find = @import("app_session/find.zig");
// 외부(ABI)·허브가 부르는 진입만 얇은 facade로 잔류, 본문은 위임:
pub fn findNext(self: *AppSession) void { find.nextMatch(self); }
```

- 순수 OS-중립 그룹은 `src/platform/macos/app_session/`가 아니라 **`src/session/`**으로(이식 + `check-boundaries`가 OS 타입 0 강제 + fake 헤드리스 테스트).
- 외부 점-호출(ABI 72개 pub)·허브 호출 진입만 `app_session.zig`에 facade로 남기고 본문만 이동.

## 4. 단계 (쉬운 응집 그룹 → 허브 잔류)

점진 스택 PR. 각 단계 green(`zig build test`·`check-boundaries`·`macos-app-build`) + 머지 전 실앱(`zig build macos-app`, [[run-macos-app-before-merge]]) + 누적 `/code-review max`(순수 이동이라 정확성 버그 0 기대, [[cumulative-review-branch-false-compile-findings]] 유의).

> **방향 재확정(사용자 합의 2026-08-08): (c) 판단 기준에 "읽기·편집 비용"을 추가하고 (b)의 "일단락"을 해제한다.**
>
> (b)는 분해 여부를 **이식 기여** 하나로 판정했다. 그 기준에서는 순수分이 `layout_math`뿐이라 "일단락"이 정확한 결론이었다. 그러나 그 뒤 파일이 35,134 → 72,317줄로 커지면서, **이식과 무관한 비용이 실측으로 드러났다**:
>
> - **다른 기능의 설계 상한을 밀어 올렸다.** [editor-surface.md](editor-surface.md) §6이 파일 뷰어의 바이트 상한을 1 MiB → 8 MiB로 올린 직접 원인이 이 파일이다("이 저장소의 `app_session.zig`가 4.0 MB(60,965줄)라 못 열렸다"). 즉 한 파일의 크기가 이미 제품 다른 축의 결정을 바꿨다.
> - **한 번에 볼 수 없다.** 72,317줄은 사람도 에이전트도 통독 대상이 아니다(2,000줄 단위로 36회). 한 그룹의 버그를 고치려 무관한 그룹을 계속 지나치고, 도메인 하나를 파악하는 데 파일 전체가 후보가 된다.
> - **(b) 자신의 ROI 판정이 뒤집혔다.** §6 "그룹당 100~400줄이라 감소폭이 작다"는 20,183줄 시점 관측이다. 실측 그룹은 수백~4,000줄이고, 동반 test까지 합치면 그 2배다.
>
> 따라서 **(b)의 이식 기준은 그대로 유지하고**(순수分은 여전히 `src/session`(L2)으로), **읽기·편집 비용을 두 번째 기준으로 추가**한다. orchestration 그룹도 `app_session/<group>.zig`로 분해한다 — **이식 기여는 여전히 0**이며(§2 첫 항목은 정정 대상이 아니다), 얻는 것은 가독성·리뷰 가능성·도구 접근성이다. 이 점을 부풀리지 않는다.
>
> 아래는 그 이전 (b) 결정의 기록이며, 근거로 보존한다.

> **방향 확정(사용자 합의 2026-06): (b) 순수→session 이식 기여分만.** E1(find) 착수로 app_session 대부분이 orchestration(이식 무관 가독성)임이 실측돼, **orchestration 가독성 분리(E2 ime·E3 tab UI·E6 scroll 등)는 스킵**하고 **OS-중립 순수 로직을 `src/session`(L2)으로 빼는 그룹만** 진행한다(이식 기여 + 헤드리스 단위 test). E1은 이미 완료(orchestration이었으나 패턴 확립). **순수分은 `layout_math`(b1·b2 — grid·hit-test·drop-zone·pt→px·px↔cell)가 전부였고, (b)는 이로써 일단락한다.** E4 sidebar(`metal_frame`·색·렌더 결합)·E5 workspace(캡처=agent PTY·복원=`createPane` spawn·직렬화=이미 session) 모두 실측 결과 orchestration 결합이라 순수分이 미미해 (b) 대상이 아니다.

| 단계 | 그룹 | 목적지 | 성격 | 대략 라인 | 위험 |
|---|---|---|---|---|---|
| **E0** ✅ | 이 문서(doc-first) | — | — | 0 | 없음 |
| **E1** ✅ | 스크롤백 Find(⌘F): 토글·재검색·네비·뷰스크롤 | `app_session/find.zig` | orchestration(순수 0) — 패턴 확립용 | ~67(본문) | 낮음 |
| **b1** ✅ | 레이아웃 기하: grid·pt→px·hit-test·drop-zone(`gridFromBacking`·`gridFromRectPx`·`ptToPx`·`pointInRect`·`halfRect`·`paneDropZone` + `PaddingPx`·`PaneDropZone`) | **`session/layout_math.zig`** | **순수(이식 기여)** | ~110(+단위 test 4) | 낮음 |
| **b2** ✅ | 픽셀↔셀 hit-test 기하(`pxToCell`+`CellHit`) — self/surface에서 cell·grid 크기만 뽑아 위임 | **`session/layout_math.zig`** | **순수(이식 기여)** | ~35(+단위 test) | 낮음 |
| ~~E4~~ | sidebar 레이아웃 수학 — 실측 결과 **순수 극소**(`sidebarMinPt` 4줄·self 의존, 나머지는 `metal_frame` 셀·색·hit-test·렌더 orchestration) → (b)서 **축소/스킵** | — | 거의 orchestration | — | 낮음 |
| ~~E5~~ | workspace — 실측 결과 캡처=`captureAgentForRestore`(`term.rt.live_pty` PTY)·복원=`buildWorkspaceTab`(`createPane` spawn)·직렬화=이미 `session.workspace.serializeWindow`. 순수分 미미(surface 메타뿐, agent 콜백 필요) → (b)서 **축소/스킵** | — | 거의 orchestration | — | — |
| ~~E2 ime·E3 tab UI·E6 scroll·clipboard·command·notification~~ | (b)서 스킵했으나 **(c)에서 부활** — 아래 F 시리즈에 흡수 | — | orchestration | — | — |

### 4.1 F 시리즈 — (c) orchestration 그룹 분해 (2026-08-08~)

목적지는 전부 `src/platform/macos/app_session/<group>.zig`, 패턴은 §3(E1 `find.zig` 선례)과 동일하다. "메서드 라인"은 `AppSession` 메서드 이름 기준 실측이고, **동반 이동할 test를 합치면 대략 2배**다(§2-c-3).

| 단계 | 그룹 | 메서드 라인 | 위험 | 비고 |
|---|---|---|---|---|
| **F1** ✅ | **에이전트 세션 기록 도크**(archive + agent dock) | 1,595(메서드) | 낮음 | **F3를 흡수해 하나로.** 2026-08-09 완료 → `app_session/agent_dock.zig` |
| **F2** ✅ | 파일 탐색기·파일 패널 | 3,840(메서드) | 중 | **한 파일**(`file_panel.zig`)로 — 분할하면 순환 때문에 pub화가 는다(아래). 2026-08-09 완료, pub화 50 |
| **F4** ✅ | pane · split · divider | 1,570(메서드) | 중 | 2026-08-09 완료 → `app_session/pane.zig`, pub화 43 |
| **F5** | dock | ~1,660 | 낮음 | |
| **F6** | tab | ~1,590 | 낮음 | |
| **F7** | sidebar | ~1,620 | 중 | `metal_frame` 셀·색 결합(옛 E4 실측) |
| **F8** | scroll | ~1,440 | 낮음 | |
| **F9** | settings · context menu · rename | ~1,830 | 낮음 | |
| **F10** | workspace capture/restore | ~810 | 중 | 캡처=agent PTY·복원=`createPane` spawn(옛 E5 실측) |

> **F1과 F3를 합친 이유(2026-08-09 실측).** 문서가 둘을 나눈 기준은 **이름**이었는데 호출 관계는 한 덩어리다.
> archive 메서드가 도크의 스크롤 앵커·인라인 상세·스모크 프로브를 부르므로, F1만 떼면 그룹 밖 non-pub
> **21개** pub화가 강제되고 **그중 14개가 F3 소유**다 — 열었다가 F3에서 도로 닫아야 한다(§7 "스택 순서 역전"이
> 첫 PR부터 발생). 합치면 pub화가 **13개**로 줄고 되돌릴 것이 없다. 다음 그룹도 이름이 아니라 호출 관계로
> 경계를 확인한다.
>
> 실제 결과: `app_session.zig` 73,658 → 71,652(−2,006), `agent_dock.zig` 2,054줄, pub화 13개, test 767개 전원
> 잔류(§2-c-3), `test-macos-app-host-abi` 2,816 passed / 0 failed.

> **F2를 나누지 않는 이유 — tree↔panel이 순환한다(2026-08-09 실측).** 문서는 원래 "반드시 2개 이상 분할"이라
> 했다. 크기 때문이었는데, 호출 관계를 재니 **양방향**이다(tree→panel 10건, panel→tree 18건). 두 파일로
> 나누면 서로의 내부 함수를 열어야 해서 pub화가 **26 → 75개**로 늘고, 경계가 이름뿐이 된다.
>
> Zig는 파일 간 순환 import를 허용하므로(함수 본문 lazy 분석 + `*AppSession` 포인터) **컴파일은 된다.**
> 문제는 pub 표면이다.
>
> tree→panel 8개는 조회가 아니라 **명령**이다 — `openFileTreePath`→`openFilePanelPath`(열기),
> `applyFileTreeRename`→`retireFilePanelSurface`(정리), `begin/releaseFileTreeMutationEditorLocks`→
> `queueFilePanelDirtySyncAction`·`queueFilePanelCloseUnlock`(락), `focusFileTree`·`restoreFileTreeFocus`→
> `activateFilePanelDockControl`(포커스), `updateFileTreeMutations`→`openCreatedFilePanel`(생성 후 열기).
> 즉 탐색기가 패널의 **생명주기를 직접 관리**한다.
>
> **이 순환은 분해가 만든 것이 아니라 드러낸 것이다.** 한 파일 안에 있어서 안 보였을 뿐이다.
>
> **후속(별도 PR): 의존 방향 정리.** tree가 panel을 직접 부르지 않고 `?FilePanelOpenRequest` 같은 의도를
> 반환해 호출자가 소비하게 바꾸면 한 방향이 되고, 그때 두 파일로 나눌 수 있다. 다만 그건 8개 지점의
> **부수효과 순서**를 건드리는 구조 변경이라 이 시리즈의 "동작 변경 0" 범위 밖이다. 순서는 [terminal core
> 분해](terminal-core-decomposition.md) §2의 선례를 따른다 — 그 문서도 "연산 추출 우선, 구조 변경(Screen
> struct fold)은 별도 initiative"를 택했고 이유가 같다("고위험 단일 도약"을 피한다). 분리 후에는 같은 변경이
> 3,840줄 파일 안에서 일어나 리뷰 범위가 73,000줄에서 그만큼 좁아진다.

> **F4에서 되돌린 두 번 — 이름 매칭의 함정(2026-08-09).** 그룹 경계와 호출부 치환을 이름으로 다루다가
> 두 번 통째로 되돌렸다. 다음 그룹은 같은 자리에서 멈추지 않도록 기록한다.
>
> 1. **`pane`은 `filePanel`에도 걸린다**(`filepanel`에 부분 문자열로 포함). F2가 가져간 파일 패널 함수
>    **30개**가 seed에 섞여 첫 추출을 폐기했다. 이름으로 좁힐 때는 단어 경계를 쓰고(`(^|[a-z])Pane([A-Z]|s\b|$)`)
>    결과 목록을 반드시 눈으로 확인한다.
> 2. **`<변수>.method(` 일괄 치환은 같은 이름의 다른 타입 메서드를 부순다.** `tab.activePane()`은 `Tab`의
>    메서드인데 `pane_ops.activePane(tab)`으로 바뀌어 **906건**이 잘못 치환됐다. 치환은 그룹 본문 안의
>    `self.`에 한정하고, 그룹 밖 호출부는 **컴파일러가 지목한 줄만** 고친다. 이때 접두어(`pane_ops`)가 다시
>    receiver로 잡히는 이중 치환을 막는 가드가 필요하다(`(?!pane_ops\b)`).

라인 수치는 **메서드 이름 기준 근사치**다. 각 단계 착수 시 실제 응집도(허브 결합·cross-group accessor)를 코드로 재검증하고 그 결과로 범위를 정정한다 — 이 문서의 사전 추정은 E1·E4·E5에서 세 번 빗나갔다([[roadmap-docs-stale-verify-with-code]]).

| 단계 | 그룹 | 목적지 | 성격 | 대략 라인 | 위험 |
|---|---|---|---|---|---|
| (잔류) | `tick`·`mouse`·`handleKeyEvent`·`init`/`deinit`·config apply·ABI 진입 facade | `app_session.zig` | L4 허브·어댑터 | — | — |

**(b) 축(이식 기여)은 b1·b2(`layout_math`)로 일단락된 상태 그대로다** — 좌표 변환 기하(grid·hit-test·drop-zone·pt→px·px↔cell)가 session(L2)으로 가 이식 시 통째 재사용된다. E4 sidebar·E5 workspace는 실측 결과 각각 `metal_frame`·PTY agent·spawn 결합이라 순수分이 미미해 (b) 대상이 아니었고, 그 판정은 유지된다. 새로 열린 건 **(c) 축**이다 — 같은 그룹들을 이번엔 이식이 아니라 읽기·편집 비용을 근거로 `app_session/<group>.zig`로 옮긴다(§4.1 F 시리즈). 순수 그룹은 헤드리스 단위 test 동반(이식성 증거), orchestration 그룹은 동반 test가 그대로 회귀 그물이다. accessor pub화분(E1: `activeSurface`)은 각 PR에 기록.

## 5. 검증

- **회귀 그물**: 순수 이동이라 동반 이동한 기존 test가 그대로 그물. `zig build test`·`check-boundaries`(session行 그룹 OS 타입 0)·`macos-app-build`.
- **헤드리스**: 순수 그룹(레이아웃 기하 `layout_math`(b1·b2 완료)·workspace 변환)을 session에서 OS 없이 단위 test로 단언(이식성 증거 — b1은 `gridFromBacking`·`pointInRect`·`paneDropZone`·`halfRect`, b2는 `pxToCell` test 동반).
- **실앱**: 매 단계 `macos-app`로 탭/split/포커스/find/IME/sidebar 동작 보존.
- **누적 검증(b 완료 후)**: E1·b1·b2를 묶어 누적 `/code-review max`(10 finder·후보 4·verifier 통과 **0**) — 순수 이동이라 정확성 버그 0 확인. facade 위임 동등성·`layout_math` 산술 비트 동일성·accessor pub화·alias·placeholder 승격·session(L2) 경계가 모두 통과([[core-zig-decomposition-initiative]]의 "순수 이동 0버그"와 동일).

## 6. 리스크 / 한계 (정직)

- **이식 무관(orchestration)**: 허브·런타임 결합 그룹의 분해는 macOS 내부 정리일 뿐 **이식 기여 0**이다. (c)로 F 시리즈를 열어도 이 사실은 바뀌지 않는다 — (c)가 사는 것은 이식이 아니라 읽기·편집 비용이며, 이를 이식 성과로 포장하지 않는다. 이식에 기여한 건 **순수 그룹(b1·b2 `layout_math`)뿐**이고 그 축은 일단락 상태다(좌표 변환 기하 = 이식 핵심). E1 find·E4 sidebar·E5 workspace는 실측 결과 모두 orchestration 결합이라 (b) 대상이 아니었다 — Explore 사전 추정(순수 85~95%)은 셋 다 빗나갔고, 착수 코드 재검증이 정정했다([[roadmap-docs-stale-verify-with-code]]).
- **cross-group accessor pub화**: 캡슐화 일부 양보(§2-c-2). core.zig 선례가 있고, accessor는 어차피 안정 표면이라 수용. F 시리즈는 그룹 수가 많아 pub 표면이 E1보다 넓어지므로, **PR마다 pub화한 accessor를 명시**하고 누적 목록을 §5 검증에서 본다.
- **허브 잔류**: `tick`·`mouse`·`handleKeyEvent`는 본질적 횡단이라 **파일 분해** 비대상이다. 가독성은 같은 파일 안 소함수 추출로 다뤘고(2026-08-09 완료 — 아래), **F 시리즈가 끝나도 이 셋은 남으므로 `app_session.zig`가 "작은 파일"이 되지는 않는다.** 종착지는 허브 + 그룹 facade + ABI 진입이다.

  > **허브 소함수 추출(2026-08-09 완료).** `handleKeyEvent` 401→340, `mouse` 978→794, `tick` 1,484→1,367(각 추출 시점 기준). 뺀 것은 **이미 거기 있던 경계**뿐이다 — 21회 반복되던 key-down 종결부(`settleKeyEventSummary`·`keyConsumedByApp`·`keyIgnored`), 저자가 구분선으로 표시해 둔 제스처 라우팅 9블록(`routeActivePointerGesture`), 계측 변수 흐름 밖의 독립 단계 셋(`settleDeferredPointerInput`·`runFramePreHousekeeping`·`collectFindViewSpans`). **파일 총 줄 수는 ±0**(같은 파일 안 이동)이고 pub 표면·test 위치·import 경계는 불변이며, `imports.zig`의 external source digest만 갱신했다. 3라운드 적대적 검증에서 역-인라인 정규화 diff로 동작 동등성을 확인했다(blocker·major 0).
  >
  > **`cell_colors`에서 멈춘 이유**는 락이 아니다(처음엔 그렇게 적었으나 검증에서 반증됐다 — 그 블록의 락은 `if` 블록 안에 갇혀 있고 `unlockCore`가 블록 마지막 문장이라 `defer`와 등가이며, 같은 작업에서 뺀 `collectFindViewSpans`가 정확히 그 모양이다). 실제 이유는 둘이다: ⑴ ROI가 낮다(42줄 대부분이 struct 리터럴, 빼도 tick −2.9%), ⑵ [io-render-threading.md](io-render-threading.md) **P4-3**이 `cell_colors`(F)·활성 build(G)·kitty(I)·sticky(J)를 투영 tick의 **단일 lock 스코프로 수렴**시키는 것을 목표로 잡고 있어, 지금 F를 별 함수로 빼면 그 통합이 함수 경계를 넘어야 한다. 같은 이유로 **이미 뺀 `collectFindViewSpans`(E)가 P4-3의 전제를 흔든다** — 그 문서 §12.2 행 E와 P4-3에 새 함수 경계를 등재해 두었다.
- **파일 수 증가**: 그룹 10개 + 동반 test가 새 파일로 늘어난다. 총 읽을 양이 주는 게 아니라 **무관한 것까지 읽는 비용**이 주는 것이므로, 그룹 경계가 도메인과 어긋나면 이득이 사라진다. 그래서 각 단계 착수 시 응집도를 코드로 재검증한다(§4.1).
- **ROI**: (b) 시점의 "그룹당 100~400줄이라 감소폭이 작다"는 20,183줄 시점 관측이라 **폐기**한다. F 시리즈 실측은 그룹당 570~4,090줄(메서드) + 동반 test로 그 2배다. 누적으로 `app_session.zig`가 그룹 facade + 허브만 남는 게 종착.

## 7. 다른 문서와의 경계 (단일 출처)

`app_session.zig`의 **크기와 분해**는 이 문서가 단일 출처다. 인접 문서는 각자 다른 축을 소유하며, 이 파일의 감소 목표·단계를 따로 정하지 않는다.

| 문서 | 소유하는 축 | 이 문서와의 관계 |
|---|---|---|
| [chrome-strategy.md](chrome-strategy.md) · [metal-ui-layout.md](metal-ui-layout.md) §8 ML6 | chrome 컴포넌트의 **형태**(rect 직접 계산 + 짝 `hitTest` → `chrome/ui/` typed tree 이주) | app_session 축소는 그 이주의 **부수효과**다. 무엇을 언제 얼마나 줄일지는 이 문서가 정한다 |
| [layering-and-portability.md](layering-and-portability.md) §3.3 | L1~L3 **이식** 위상 | L4 내부 분해는 위상 밖이라 이 문서로 위임(원래부터 그렇게 서술) |
| [app-layer-decomposition.md](app-layer-decomposition.md) | `src/app`(L4 공통 런타임)의 분해 | 대상 파일이 다르다 |

### 두 경로는 배타적이지 않다

- **경로 A (이 문서 §4.1 F 시리즈)** — orchestration을 `app_session/<group>.zig`로. 즉시 착수 가능, 이식 기여 0, 감소폭 큼.
- **경로 B (chrome ML6)** — 순수 chrome 부분을 `src/chrome/`로. 이미 승인된 전략이고 이득이 구조적이다(hit-test가 published rect에서 파생돼 "보이는 것 ≠ 눌리는 것" 드리프트가 불가능해진다). 다만 ML6가 코드로 확인한 **선행 블로커**가 있다 — 텍스트 모델 전환(셀 격자 ↔ measured 비례), ScrollArea 프리미티브, sticky 헤더 밴드, 부분 행 클리핑용 `draw.Op.clip` 경계 screenshot gate.

**순서는 A 먼저**다. B는 지금 블로커에 막혀 있고, A로 orchestration을 걷어낸 뒤 남는 순수 chrome分을 B로 보내면 같은 그룹을 두 번 만지지 않는다. A가 B를 막지도 않는다 — F5 dock·F6 tab·F7 sidebar가 옮겨 가도 chrome 컴포넌트의 형태는 그대로이므로 ML6는 그 위에서 계속 진행할 수 있다.
