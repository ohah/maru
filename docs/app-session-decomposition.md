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
| 2026-08-09 (F10까지) | **59,124** | 이름 기준 F 시리즈 전부. 그룹 파일 10개 합계 15,989줄 |
| 2026-08-09 (F11) | **58,479** | web panel·인앱 브라우저. 그룹 파일 11개 |
| 2026-08-09 (F12) | **57,701** | 키 입력·IME·키바인딩. 그룹 파일 12개 |
| 2026-08-09 (F13) | **57,169** | 알림·벨. 그룹 파일 13개 |
| 2026-08-09 (F14) | **56,455** | 에이전트 관측. 그룹 파일 14개 |
| 2026-08-09 (F15) | **56,131** | git·SCM. 그룹 파일 15개 |
| 2026-08-10 (F16) | **55,324** | term·surface. 그룹 파일 16개 |

> F 시리즈가 옮기는 것은 **메서드뿐**이다(test는 잔류 — §2-c-3). F10으로 이름 기준 그룹은 전부
> 끝났고 `app_session.zig`는 **59,124줄**이다. 예측했던 56,000줄대에 닿지 못한 이유는 F8·F10에서
> 드러났다 — 늦은 그룹일수록 앞선 그룹이 몫을 가져가 실제 이동이 추정보다 작고(F8 1,440→861,
> F10 810→491), ABI가 직접 부르는 진입은 facade로 허브에 남는다(F9 8개, F10 12개).
>
> 여기서 더 줄이려면 남은 것은 셋이다: test 33,000줄대(§2-c-3 — pub화 6배), 허브
> (`tick` 1,400 + `mouse` 801 + `handleKeyEvent` 340), 그리고 아직 그룹이 없는 도메인
> (web-panel·notification·agent 관측 등). 앞의 둘은 의도적으로 남긴 것이다.

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
| **F5** ✅ | 도크 일반(view·레이아웃·스크롤바) | 484(메서드) | 낮음 | 2026-08-09 완료 → `app_session/dock.zig`, pub화 4(예측과 일치) |
| **F6** ✅ | tab(생성·전환·이동·고정·그룹·제목) | 1,254(메서드) | 낮음 | 2026-08-09 완료 → `app_session/tab.zig`, pub화 41 |
| **F7** ✅ | 사이드바(행 모델·스크롤·드래그 프리뷰·카드·헤더) | 1,812(메서드) | 중 | 2026-08-09 완료 → `app_session/sidebar.zig`, pub화 44 |
| **F8** ✅ | 스크롤(휠·페이지 라우팅, 스크롤바 위젯, 오버레이) | 861(메서드) | 낮음 | 2026-08-09 완료 → `app_session/scroll.zig`. 표면별 스크롤은 이미 각 그룹이 가져가 예상보다 작다 |
| **F9** ✅ | 세팅 · 컨텍스트 메뉴 · 이름 변경 · config 적용 | 1,850(메서드) | 낮음 | 2026-08-09 완료 → `app_session/settings.zig`, ABI facade 8 |
| **F10** ✅ | workspace · window(캡처/복원/이동, 창 속성) | 491(메서드) | 중 | 2026-08-09 완료 → `app_session/workspace.zig`. **ABI facade 12개**로 비중 최고 |
| **F11** ✅ | web panel · 인앱 브라우저(surface 수명·주소창·내비·web term) | 843(메서드) | 낮음 | 2026-08-09 완료 → `app_session/web.zig`. **pub 순증 1개**로 F 시리즈 최저, ABI facade 20 |
| **F12** ✅ | 키 입력 · IME · 키바인딩(라우팅·조합 수명·커밋 텍스트·키 힌트·전역 핫키) | 745(메서드) | 낮음 | 2026-08-09 완료 → `app_session/input.zig`, pub 순증 6, ABI facade 11 |
| **F13** ✅ | 알림 · 벨(OSC 9/777·이력·패널·배지·벨 플래시·원격 폴링) | 434(메서드) | 낮음 | 2026-08-09 완료 → `app_session/notification.zig`, pub 순증 8, ABI facade 5. **이름 함정이 없던 첫 그룹** |
| **F14** ✅ | 에이전트 관측(상태·종류·트랜스크립트 폴링, 상태줄, 스피너, 사이드바 행, 세션 재개) | 620(메서드) | 낮음 | 2026-08-09 완료 → `app_session/agent.zig`, pub 순증 24, **ABI facade 0** |
| **F15** ✅ | git · SCM(저장소 탐지·브랜치/상태 갱신·SCM 뷰 행·diff term) | 292(메서드) | 낮음 | 2026-08-09 완료 → `app_session/git.zig`, pub 순증 3, ABI facade 0 |
| **F16** ✅ | term · surface(생성/파괴·등록·조회·포커스·종료) | 654(메서드) | 중 | 2026-08-10 완료 → `app_session/term.zig`, pub 순증 6, ABI facade 8. **후보 55개 중 18개를 걸렀다** |

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

> **도크 안에 사는 것은 도크가 아니다(F1·F4·F5에서 세 번 반복).** `dock` 이름을 가졌지만 본문이 다른
> 도메인을 만지는 함수가 매번 나왔다 — F1의 `dockHasContent`(`fileEntryCount`), F4의
> `fillTabDragSmokeProbe`(`dividerSmokeProbe`가 채운다), F5의 `assignDockSurfaceIds`·`dockHasLiveSurface`·
> `refreshDockListScrollbar`·`requeuePendingDockFocus`(전부 `fileEntries`·`file_tree_perf_counters`).
> 파일 패널·에이전트 아카이브가 도크 **안에** 살기 때문에 생긴 이름이다. F5에서는 이 넷을 `dock.zig`가
> 아니라 `file_panel.zig`로 보냈다 — 그러지 않았으면 나중에 되돌려야 한다.
>
> 그 결과 F5는 **pub화 4개가 예측과 정확히 일치**한 첫 그룹이 됐다(F2 26→50, F4 35→43). 그룹이 작고
> 경계가 깨끗하면 추정이 맞는다는 뜻이지, 추정 방법이 나아진 것은 아니다 — §2-c-2의 규칙은 그대로다.

> ## pub 표면은 닫히지 않았다 — F10 실측으로 정정한다
>
> F1~F9의 PR마다 "pub 증가는 분해가 끝날 때까지의 과도기 비용이고 같은 도메인이 한 파일로 모이면
> 다시 닫힌다"고 적었다. **F10에서 실측하니 사실이 아니다.**
>
> | 시점 | `app_session.zig`의 pub 수 | 증감 |
> |---|---|---|
> | E1(`find.zig`) 직후 | 93 | |
> | F1 agent_dock | 274 | +181 |
> | F2 file_panel | 343 | +69 |
> | F4 pane | 407 | +64 |
> | F5 dock | 415 | +8 |
> | F6 tab | 446 | +31 |
> | F7 sidebar | 483 | +37 |
> | F8 scroll | 497 | +14 |
> | F9 settings | 557 | +60 |
> | F10 workspace | **572** | +15 |
>
> **열 개 그룹 동안 한 번도 줄지 않았다.** F9가 연 65개 중 F10이 닫은 것은 **1개**(`workspaceHasStatusLine`)뿐이다.
>
> | F11 web | 573 | +1 |
> | F12 input | 579 | +6 |
> | F13 notification | 587 | +8 |
> | F14 agent | 611 | +24 |
> | F15 git | 614 | +3 |
> | F16 term | 620 | +6 |
>
> **원인은 test 잔류가 아니다(2026-08-09 시범 이동으로 기각).** 한때 "test가 허브에 남아 비공개
> 헬퍼를 부르니 pub이 못 닫힌다"고 적었으나, `pane` test 101개(3,833줄)를 실제로 `pane.zig`로 옮겨
> 컴파일·`test-macos-app-host-abi` 통과까지 확인하고 재니 pub이 **+35 늘고 0개 닫혔다**(예측 12 —
> 3배 빗나갔다. `extern "c" fn usleep`·`mkfifo` 같은 C interop 선언과 `AppSession` 내부 선언을
> 놓쳤고, 되돌릴 수 없는 `pub var`가 둘 포함됐다). 시범 이동은 되돌렸다.
>
> **비대칭이 원인이다.** test가 허브에 있으면 그룹 코드 접근은 공짜다 — 그룹 파일은 허브가 부를 수
> 있도록 어차피 전부 `pub fn`으로 내보낸다. test가 그룹 파일에 있으면 허브 코드 접근이 전부 파일
> 경계를 넘는다. test는 양쪽을 다 만지므로 어디에 두든 한쪽은 경계를 넘고 **허브에 두는 쪽이 항상 싸다.**
> 따라서 §2-c-3의 결론(분해 시 test는 원본에 남긴다)은 `core.zig` 선례와도, 이 실측과도 일치한다.
>
> **같은 이유로 test 전용 헬퍼도 빼지 않는다.** `app_session/test_support.zig`로 47개(705줄)를 빼
> 보았으나, 그 헬퍼를 쓰는 것은 `app_session.zig`의 test뿐이라 **쓰는 쪽과 쓰이는 쪽을 파일로 가른 같은
> 안티패턴**이었다(pub +22, 그중 되돌릴 수 없는 `pub var` 하나). 되돌렸다. `session_host`의 test
> support 모듈들과는 다르다 — 그쪽은 자기 test를 함께 가진 자족 모듈이다.
>
> 그러면 진짜 원인은 무엇인가. **파일을 가르면 경계를 넘는 참조가 생기고, Zig의 privacy는 파일 경계
> 단위다.** 그룹 파일이 존재하는 것 자체의 비용이다. 다만 그 비용은 그룹마다 크게 다르다 — F9
> settings는 +60, F11 web은 **+1**이다. 차이는 **도메인 상태가 자기 필드 안에서 닫혀 있는가**다.
> web은 `web_panel_*`·`addr_*` 필드로 닫혀 있고, settings는 거의 모든 도메인의 값을 읽고 쓴다.
>
> **소유권 게이트가 파일 경계를 고정한다(F16에서 처음 부딪혔다).** `tests/boundary/imports.zig`의
> "CR3a-1 ownership capabilities stay in their exact production boundaries"는
> `RemoteSessionAdapter.initInPlace(`가 **`app_session.zig`에 정확히 2회** 나타나야 한다고 못박는다.
> F16이 `ensureRestoreHostAdapter`를 옮기자 그 게이트가 깨졌다.
>
> **게이트를 느슨하게 하지 않고 함수를 허브에 남기는 쪽을 골랐다.** 그 게이트는 원격 세션 어댑터의
> 초기화 권한이 어디서 행사되는지를 파일 단위로 잠그는 것이고, refactor의 부수 효과로 완화할 성질이
> 아니다. `ensureRestoreHostAdapter`·`logRestoreAdapterInitFailure`·`backendForNew` 셋을 제외했다.
>
> **F16에서 자동 제외 규칙이 값을 했다.** term·surface는 `Term`·`Surface`가 거의 모든 도메인이
> 참조하는 핵심 타입이라 이름으로 잡으면 다른 그룹의 진입점이 대량으로 딸려온다. 후보 55개 중
> **18개**를 걸렀다 — 얇은 facade **9개는 F15에서 넣은 규칙이 손대지 않고** 잡았고(web 4·notification 1·
> workspace 1·dock 1 등), 내용이 남의 도메인인 6개(file_panel 5·dock 1)와 소유권 게이트가 고정한
> 3개만 사람이 판단했다.
>
> 그 결과 pub 순증이 **6개**다. 가장 결합이 심할 것으로 보였던 그룹이 중간 수준으로 끝났다 —
> **경계를 정확히 잡으면 핵심 타입 도메인도 비싸지 않다.**
>
> 부수로 `@constCast(self).activeSurface()` 형태를 만났다. 리시버가 식별자가 아니라 **표현식**이라
> 일반 치환이 못 잡고 컴파일 오류로 드러났다 — 치환 규칙에 `@constCast(...)` 패턴을 더했다.
>
> **"남의 facade" 함정이 네 번 반복됐다** — F8 `scrollToCurrentMatch`(→`find.zig`), F12 `webKeyRoute`
> (→`web.zig`), F14 `agentSessionArchive*` 10개(→`agent_dock.zig`), F15 `scmDrawWindow`(→`dock.zig`).
> 전부 본문이 `<group>_ops.X(self)` 위임 한두 줄인 **이미 분리된 그룹의 ABI 진입점**이다. 이름만 보면
> 새 그룹 소유처럼 보이지만 옮기면 facade가 원본에서 멀어진다.
>
> 그래서 F15부터는 경계 계산에 **얇은 facade 자동 제외**를 넣었다 — 본문의 유효 코드가 3줄 이하이고
> `<name>_ops.`를 부르면 후보에서 뺀다. F15에서 `scmDrawWindow` 하나를, term/surface 후보 조사에서
> 9개를 자동으로 걸러 냈다.
>
> ## 디버그 픽스처 하네스 분리(2026-08-10)
>
> F9에서 등록한 후속을 처리했다. `maybeDebugOpenSettings`(586줄)와 `maybeDebugOpenFilePanel`(12줄)을
> `app_session/debug_fixtures.zig`로 뺐다. ABI가 둘 다 직접 부르므로 진입점은 얇은 facade로 남는다.
>
> | | |
> |---|---|
> | `app_session.zig` | 54,989 → **54,394** (−595) |
> | `debug_fixtures.zig` | 631줄 |
> | 허브 pub | 553 → **550** |
>
> **크기보다 성격이 이유다.** 이름은 "세팅을 연다"이지만 지금은 사이드바 접힘·가짜 브랜치·그룹 상태·
> 드래그 고스트·알림 배지를 **40개가 넘는 `MARU_*` 환경변수 게이트**로 강제하는 시나리오 하네스다.
> 제품 경로를 읽는 사람이 이 분량의 디버그 스캐폴딩을 지나야 했다.
>
> 실측으로 범위를 정했다 — `MARU_*` 문자열을 읽는 `AppSession` 메서드는 넷인데, `init`(env 2개)과
> `runFramePreHousekeeping`(env 2개)은 제품 함수라 두고 왔다. 환경변수를 읽는다고 전부 디버그가 아니다.
>
> 부수로 `tab.zig`가 **자기 모듈을 `tab_ops.`로 부르는** 자리를 넷 발견해 정리했다(F6 보정에서 허브 쪽
> 접두 치환이 그룹 파일까지 번진 잔재다). 컴파일러가 `'tab_ops' is not marked 'pub'`으로 잡았다.
>
> ## F6 보정 — 탭 그룹 모델을 `tab.zig`로(2026-08-10)
>
> F7에서 등록한 후속을 처리했다. `moveGroupSibling`·`moveGroupRange`·`relevelBlock`·`relevelBlockCore`·
> `groupSubtreeEnd`·`effectiveDepthAt`·`enclosingGroupMarkerIndex`·`pinBoundariesAlignGroups`·
> `stablePartitionPinned`·`stablePartitionSubtree`·`assertPinnedPrefixRuntime`·`pinRegionBounds`·
> `moveGroupNesting`·`simulateGroupMove`와 F9에서 더한 `togglePin`·`cardPinRole` **16개(341줄)**다.
>
> 이들은 **이름에 `tab`이 없어 F6가 못 가져갔고**, 사이드바 드래그·컨텍스트 메뉴에서만 불려 F7·F9에
> 잘못 흡수될 뻔했다. 본문은 탭 그룹 마커와 depth를 수술하므로 소유는 `tab.zig`다.
>
> | | |
> |---|---|
> | `app_session.zig` | 55,435 → **54,989** (−446) |
> | 허브 pub | 557 → **553** (−4) |
> | `tab.zig` | 1,571 → 2,054 |
>
> **F6가 열었던 pub이 실제로 닫혔다.** F7 PR에서 "옮기면 F6에서 연 pub 여럿이 다시 닫힌다"고 적었고
> 그대로 됐다 — 제거 10개, 신규 6개다.
>
> 이 작업으로 "이름에 도메인 단어가 없어 이름 기준으로 못 잡는 코드"의 첫 사례가 정리됐다. 나머지는
> 호출 그래프 클러스터링이 필요하고 별개 작업이다.
>
> ## 파일 레벨 헬퍼 동반 이동 — pub이 처음으로 줄었다(2026-08-10)
>
> F14에서 "흡수 규칙이 `self.X(` 메서드 호출만 봐서 파일 레벨 자유 함수·상수가 전부 pub이 된다"고
> 실측했고, 그 부채를 여기서 갚았다. **한 그룹만 쓰고 허브 제품 경로는 쓰지 않는 파일 레벨 선언 65개**를
> 각 그룹 파일로 함께 옮겼다.
>
> | | |
> |---|---|
> | 허브 pub | **621 → 557** (제거 66·신규 2) |
> | `app_session.zig` | 55,324 → 55,435(*) |
> | 그룹별 | sidebar 17 · agent 13 · file_panel 9 · scroll 8 · notification 6 · agent_dock 5 · tab 4 · workspace 4 · git 3 · pane 2 · input 1 |
>
> (*) 줄 수는 오히려 늘었다 — 옮긴 405줄보다 허브에서 `<group>_ops.` 접두가 붙어 늘어난 분량이 크다.
> **이 작업의 목적은 줄 수가 아니라 pub 표면이다.** F1~F16에서 93 → 621로 늘기만 하던 것이 처음으로
> 줄었고, 그 원인이 "파일을 가르는 것 자체"가 아니라 **"헬퍼를 쓰는 쪽과 떼어 놓은 것"**이었음을 보여 준다.
>
> ### 전이 폐포가 필요하다
>
> 헬퍼 A를 옮기면 A가 부르는 B가 새로 "그 그룹만 쓰는" 상태가 된다. 한 번의 스캔으로는 안 되고
> **수렴할 때까지 반복**해야 한다(git 3회, agent 3회, sidebar 2회).
>
> ### 정확한 경계 파서를 먼저 만들었다
>
> 이 문서가 파일 레벨 선언의 경계를 **네 번** 틀렸다(test 마스크·struct const·참조 범위·인접 선언 흡수).
> 그래서 이번에는 휴리스틱 대신 **문자열·문자 리터럴·주석을 지운 뒤 괄호 depth를 세는** 파서를 만들고,
> 443개 선언에 대해 **경계 겹침 0건**과 끝맺음 검사를 통과시킨 뒤에 썼다(`scratchpad/zigdecl.py`).
>
> ### 그래도 함정이 셋 더 나왔다
>
>   1. **Zig 범위 문법 `0..N`.** `(?<![.\w])` 가드가 `0..spinner_bar_count`의 앞 `.`를 필드 접근으로 보고
>      치환을 막았다. `(?<!\w)(?<!(?<!\.)\.)`로 단일 `.`만 막도록 고쳤다.
>   2. **`pub`을 지역 변수에 붙였다.** "not marked 'pub'" 오류를 따라가는 자동 수정이
>      `const capture = self.divider_interaction.capture orelse ...`(함수 안 지역 변수)에 `pub`을 붙여
>      구문 오류가 났다. 파일 레벨·struct 멤버만 대상으로 좁혀야 한다.
>   3. **`extern "c" fn`은 선언 스캔에 안 잡힌다.** `setenv`·`mkfifo`가 그랬다.
>
> **pub 예측이 크게 빗나가는 이유를 찾았다(F14).** 하한 3을 예측했는데 실제는 **24**였다. 원인은
> 흡수 규칙이 **`self.X(` 메서드 호출만** 보기 때문이다 — 그룹이 부르는 **파일 레벨 자유 함수·상수**
> (`readFileAlloc`·`classifyAgentProcesses`·`buildResumeShellCommand`·`agent_poll_interval_ms` 등)는
> 흡수 후보에 들어오지 않아 전부 pub이 된다.
>
> 실측: F14가 연 pub 30개 중 **22개가 `agent.zig`만 쓰고 허브 제품 경로는 쓰지 않는다.** 이들을 함께
> 옮기면 pub 비용이 24 → 2 수준으로 내려간다. **다음 그룹부터는 흡수 규칙에 파일 레벨 선언을 포함한다.**
>
> 이번 그룹에서는 적용하지 않았다 — 시도했다가 파일 레벨 선언의 경계 계산이 인접 선언(`sync_timeout_ms`)을
> 삼켜 되돌렸다. 경계 계산은 이 문서가 이미 세 번 틀린 곳이므로(위 "경계 계산에서 결함 셋") 서둘러
> 얹지 않고 별도 작업으로 뺀다.
>
> **이름 함정이 없는 도메인도 있다(F13).** `notification`·`bell`·`badge`는 이 저장소에서 다른 뜻으로
> 쓰이지 않아 걸러 낼 것이 하나도 없었다 — F4 `pane`↔`filePanel`, F6 `tab`↔`stable`, F12 `ime`↔`Time`과
> 대비된다. 함정은 **단어가 짧거나 다른 단어의 부분 문자열일 때** 생긴다. 긴 복합어(`notification`)나
> 이 저장소 고유어는 안전하다.
>
> 부수로 `formatRelativeTime`이 제 자리를 찾았다 — F12에서 `ime` 부분 문자열로 잘못 딸려왔던 함수인데,
> 실제 호출자는 알림 목록의 상대 시각 표시뿐이라 F13 소유다. **함정을 걸러 내면 다음 그룹이 주워 간다.**
>
> **익명 struct 반환은 facade로 감쌀 수 없다(F11·F12에서 각각 한 건).** `takeWebNavAction`(F11)과
> `imeCursorRect`(F12)는 `?struct { ... }`를 반환한다. 허브에 facade를 두면 `AppSession`이 만든 타입과
> 그룹 파일이 만든 타입이 **서로 다른 타입**이 되어 컴파일이 깨진다. 이름 있는 타입으로 바꾸면 옮길 수
> 있으나 순수 이동의 범위 밖이라 둘 다 허브에 남겼다. 그룹 경계를 잡을 때 미리 걸러야 한다.
>
> **`&` 자동 보정이 수렴하지 않을 수 있다(F11).** 값 리시버에 `&`를 붙이는 보정이 25라운드 동안
> 라운드당 1건씩만 진행했다 — Zig가 이 오류 종류를 한 번에 하나씩만 보고하기 때문이다. test 블록 안의
> 값 세션 식별자를 **선언에서 찾아** 일괄 적용한 뒤 과잉분을 양방향으로 되감는 편이 빠르다(F12는 이
> 방식으로 102건을 한 번에 처리하고 8라운드에 끝났다).
>
> **경계 계산에서 결함 셋을 잡았다(2026-08-09).** 이 문서의 실측치를 다시 잴 때 반복하지 않도록 남긴다.
>   1. test 블록을 중괄호 균형으로 잡으면 문자열·주석 속 `{`에 깨져 **제품 코드를 test로 오분류**한다.
>      컬럼 0의 `}`를 종료로 삼아야 한다.
>   2. struct 값을 가진 `const`를 첫 `;`에서 자르면 선언이 반토막 난다. 컬럼 0의 `};`까지 봐야 한다.
>   3. 참조를 `app_session.zig` 안에서만 세면 그룹 파일이 쓰는 선언이 "test 전용"으로 오판된다.
>
> 이것을 감추지 않고 남긴다 — 이후 누가 "분해했는데 왜 캡슐화가 나아지지 않았나"를 물으면 답은
> **"줄 수는 목표였고 pub 표면은 목표가 아니었다"**이다. pub까지 줄이려면 파일을 가르는 대신 도메인
> 상태를 별도 struct로 캡슐화해야 하고(그러면 필드 접근이 메서드가 된다), 그건 F 시리즈와 다른 작업이다.

> **F9는 config 재적용을 함께 가진다.** 세팅 UI가 값을 바꾸고 `applyLoadedConfig`·`reapplyConfigPalette`·
> `reapplyScrollback`·`reapplyAmbiguousWidth`·`reapplyEmojiWidth`·`reapplyDefaultCursorShape`·
> `applyThemePreset`이 그것을 살아 있는 세션에 반영한다. 편집과 적용이 한 덩어리라 나누면 pub화만 는다.
> F8이 `reapplyScrollback`을 여기로 미룬 것도 같은 이유다(이름은 scroll이지만 하는 일은 config 재적용이다).
>
> **`palette`는 두 도메인이 같은 이름을 쓴다(F9).** `theme.palette`(색 팔레트)와 명령 팔레트(⌘K)가 그렇다.
> F9는 색 팔레트 쪽(`reapplyConfigPalette`·`paletteCellHex`)만 가져오고 `togglePalette`·`acceptPalette`·
> `buildPaletteRows`는 두고 왔다. 부분 문자열 함정이 아니라 **동음이의 함정**이다.
>
> **디버그 픽스처 하네스를 별도로 뺐다(F9 → 후속).** `maybeDebugOpenSettings`는 568줄로 이 파일에서
> 손꼽히게 큰데, 이름만 settings이고 본문은 `MARU_*` 환경변수 게이트 **39개**로 사이드바 접힘·가짜
> 브랜치·그룹 상태·드래그 고스트를 강제하는 **디버그/스모크 픽스처**다. 세팅 로직이 아니므로 F9가 갖지
> 않는다. `app_session/debug_fixtures.zig`로 빼는 것을 후속으로 등록한다 — 제품 코드와 섞여 있는 것이
> 그 자체로 문제이기도 하다.
>
> **F6 보정 목록에 둘을 더한다.** `togglePin`·`cardPinRole`은 컨텍스트 메뉴가 부르지만 본문은
> `self.tabs`의 고정 구획을 수술하므로 소유가 tab이다. 같은 이유로 `webSurfaceRect`(web-panel 기하)와
> `termBarLocation`(chrome/pane 기하)도 F9가 갖지 않았다.
>
> 실제 결과(F9): `app_session.zig` 61,726 → 59,617(−2,109), `settings.zig` 2,225줄(메서드 68 + 인자만
> 보는 순수 판정 10). ABI가 직접 부르는 8개(`configPath`·`keyHintConfig`·`openFileContentMenu`·
> `quickTerminalConfig`·`reloadConfig`·`serializeConfig`·`takeConfigDirty`·`takeFileMenuAction`)는 얇은
> facade로 남겼다 — F 시리즈 중 facade가 가장 많다. test 776개 전원 잔류,
> `test-macos-app-host-abi` 2,849 passed / 0 failed.
>
> **pub 순증 60개로 F 시리즈 최대다**(65 신설 − 5 소멸, 그중 함수 35개). 세팅이 거의 모든 도메인의
> 값을 읽고 쓰기 때문이다 — 색 상수·키바인딩 카탈로그·컨텍스트 메뉴 문자열 상수(`ctx_menu_*` 등)가
> 대량으로 열렸다. F8(+14)과 정반대다. 이 비용은 §7대로 분해가 끝날 때까지의 과도기이고, 열린 것
> 상당수가 상수라 F10 이후 그룹이 가져가면 다시 닫힌다.
>
> **분류 함정(F9).** 첫 인자가 `_: *AppSession`인 메서드(`themePresetVariants`)를 "메서드가 아니다"로
> 분류해 호출부를 잘못 바꿨다. 인자 이름이 `self`/`session`이 아니어도 메서드다 — 타입으로 판정해야 한다.

> **파서 함정(F10에서 처음 잡았다).** `app_session.zig`에는 `AppSession` 말고도 최상위 struct가 있고
> 그 메서드도 4칸 들여쓰기다 — `ProviderEnvGuard.capture`·`MeasuredTextCache.store`·`FakeLinkScreen.render`
> 등 **12개**다. 이름만 보고 그룹을 잡는 스크립트는 이들을 `AppSession` 메서드로 착각한다. F1~F9에서
> 사고가 없었던 것은 이름이 도메인 키워드와 겹치지 않았기 때문이고(실측 0건) 설계가 막아 준 것이
> 아니다. F10부터는 struct 소유를 보고 거른다.
>
> 실제 결과(F10): `app_session.zig` 59,617 → 59,124(−493), `workspace.zig` 595줄(메서드 22 + 순수 2).
> **24개 중 12개를 Swift 호스트가 직접 부른다** — 창은 호스트가 소유하고 Zig는 캡처·복원·질의하는
> 쪽이라 그렇다. 그 12개는 얇은 facade로 허브에 남으므로 실제 감소는 옮긴 491줄보다 작다.
> test 776개 전원 잔류, `test-macos-app-host-abi` 2,849 passed / 0 failed.

> **F8은 예상보다 작다 — 앞선 그룹이 이미 가져갔기 때문이다.** 문서 추정은 1,440줄이었는데 실제
> 이동은 **861줄**이다. 표면별 스크롤 상태가 이미 각자의 그룹으로 갔기 때문이다 — 사이드바 스크롤은
> F7, 도크 리스트는 F5, 파일 트리는 F2, pane 스크롤바 배치는 F4다. `scroll.zig`에 남은 것은
> **표면에 종속되지 않는 스크롤 기구**(휠·페이지 라우팅, 썸 기하, 드래그 캡처, 페이드, 오버레이)다.
> 이름 기준 추정이 하한이라는 §2-c-2의 반대 사례이므로, 남은 F9·F10도 착수 시 재측정해야 한다.
>
> **이름 함정의 네 번째 유형: 다른 그룹의 facade(F8).** `scrollToCurrentMatch`는 본문이
> `find_ops.scrollToCurrentMatch(self)` 한 줄인 **E1 facade**다. 이름만 scroll이고 소유는 `find.zig`다.
> 함께 걸러낸 것이 둘 더 있다 — `reapplyScrollback`은 `scrollback.lines` config를 터미널에 재적용하므로
> 소유가 config/settings(F9)이고(터미널 스크롤백이지 스크롤 UI가 아니다), `msPerTick`은 프레임 타이밍
> 유틸리티(`frameRateHz` 기반, 바로 옆이 `bellFlashTotalTicks`)로 스크롤바 페이드가 유일한 호출자일
> 뿐이다. 함정 목록이 넷이 됐다: 부분 문자열 / 호출 근접성 / 다른 이름을 쓰는 같은 도메인 / 남의 facade.
>
> 실제 결과(F8): `app_session.zig` 62,678 → 61,726(−952), `scroll.zig` 1,017줄(메서드 33 + 인자만 보는
> 순수 계산 6). ABI가 직접 부르는 `scrollPage`·`scrollWheel` 둘은 얇은 facade로 남겼다. pub화 25개
> (함수 9) / 제거 11개 → 순증 14개로, F 시리즈 중 pub 비용이 가장 싸다. test 776개 전원 잔류,
> `test-macos-app-host-abi` 2,849 passed / 0 failed.

> **이름이 도메인을 숨기는 세 번째 유형(F7에서 발견).** F4·F6의 함정은 *부분 문자열*이었고 F6에서
> *호출 근접성*을 하나 더 봤다. F7에서 셋째가 나왔다 — **도메인 개념이 다른 이름을 쓴다.**
> `moveGroupSibling`·`moveGroupRange`·`relevelBlock`·`groupSubtreeEnd`·`effectiveDepthAt`·
> `stablePartitionPinned` 등 240줄은 이름에 `tab`이 없어 F6가 못 가져갔고, 사이드바 드래그에서만
> 불리므로 F7의 흡수 조건에는 걸린다. 그러나 본문은 **탭 그룹 마커와 depth를 수술한다** — 사이드바는
> 그 모델을 *표시*할 뿐이다. F7로 보내면 잘못된 소유가 굳으므로 제외했고, `tab.zig`로 보내는 것은
> **F6 보정**으로 아래에 등록한다.
>
> **후속: F6 보정(탭 그룹 모델 240줄).** `moveGroupRange`·`relevelBlock`·`relevelBlockCore`·
> `groupSubtreeEnd`·`effectiveDepthAt`·`enclosingGroupMarkerIndex`·`pinBoundariesAlignGroups`·
> `stablePartitionPinned`·`stablePartitionSubtree`·`assertPinnedPrefixRuntime`·`pinRegionBounds`·
> `moveGroupSibling`·`moveGroupNesting`·`simulateGroupMove`를 `tab.zig`로 옮긴다. F6에서 pub으로 연
> 것들이 여기 다수 포함되므로 옮기면 다시 닫힌다.
>
> 실제 결과(F7): `app_session.zig` 64,497 → 62,335(−2,162), `sidebar.zig` 2,240줄(메서드 71 + 인자만
> 보는 순수 기하·판정 7), pub화 44개(함수 24) / 제거 7개 → 순증 37개, test 771개 전원 잔류,
> `test-macos-app-host-abi` 2,844 passed / 0 failed.
>
> **값 리시버 함정(F7).** `*const AppSession`을 받는 함수를 `var session: AppSession = undefined`인
> test에서 부르면, 메서드 호출 문법은 자동으로 주소를 잡지만 free 함수 호출은 `&session`이 필요하다.
> 2건이 컴파일 오류로 잡혔다. 앞으로의 그룹에서도 나온다.

> **부분 문자열 함정(F6).** `tab`은 `stable`·`established`·`editable`·`executable`의 부분 문자열이라
> 이름 일치만으로 `stablePartitionPinned`·`stablePartitionSubtree`·`reestablishTopLevelBoundaryOnMove`·
> `stableOpenedFileHash`·`webContextIsEditable`·`writeExecutableFile` 여섯이 딸려온다. 단어 경계
> (`(^|[a-z])[Tt]ab([A-Z]|s\b|bar|Bar|$)`)로 걸러 제외했다 — F4의 `pane`↔`filePanel`과 같은 유형이고,
> 이름으로 경계를 잡는 이상 그룹마다 먼저 확인해야 한다.
>
> **반대 방향도 있다(F6).** 호출 관계로만 딸려오는 `projectRowsFrom`(사이드바 행 투영)·`setHoveredScroll`
> (스크롤 hover)은 유일한 호출자가 탭 함수일 뿐 내용은 각각 F7·F8 소유다. 지금 `tab.zig`로 옮기면 다음
> 그룹에서 도로 옮겨야 하고, 남겨서 치르는 값은 pub화 1개뿐이라 제외했다. **소유는 호출 근접성이 아니라
> 내용으로 정한다** — 이름 함정과 같은 규칙을 반대 방향으로 적용한 것이다.
>
> 실제 결과: `app_session.zig` 65,907 → 64,497(−1,410), `tab.zig` 1,567줄(메서드 48 + `*Tab`만 보는 순수
> 판정 10), pub화 41개(그중 **함수는 26개**, 나머지 15개는 타입·색 상수 등
> 함수 아닌 선언이라 예측 하한 18의 대상 밖이었다 — §2-c-2 "추정치는 하한이다"의 네 번째 사례).
> 반대로 `app_session.zig`의 pub 10개는 **사라졌다**(탭 함수 9개가 옮겨 갔고 `file_panel_ops` 재수출을
> 없앴다) — 허브의 pub 표면 순증은 31개다, test 771개 전원 잔류, `test-macos-app-host-abi` 2,840 passed / 0 failed.
>
> 이 그룹에서 그룹 파일끼리의 참조를 `app_session.zig`의 재수출(`pub const pane_ops = ...`) 경유에서
> **직접 `@import`**로 바로잡았다(`pane.zig`의 `file_panel_ops` 포함). 허브를 경유할 이유가 없고,
> 경유하면 허브의 pub 표면이 그룹 수만큼 늘어난다.

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
