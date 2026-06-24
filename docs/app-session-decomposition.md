# app_session.zig 분해 — 실행 플랜

> L4 macOS 어댑터의 거대 단일 파일(`src/platform/macos/app_session.zig`)을 목적별 파일로 가르는 **실행 플랜**이다. 위상 골격의 단일 출처는 [레이어링과 이식성](layering-and-portability.md)이고, 분해 패턴의 검증된 선례는 [terminal core 분해](terminal-core-decomposition.md)다(`core.zig` 9962→6166, 방향 A, 누적 `/code-review max` 정확성 버그 0). 이 문서는 그 패턴을 `app_session`에 적용하는 단계·선결을 담는다.

## 1. 배경 (측정 — 2026-06)

`src/platform/macos/app_session.zig`는 **20,183줄·`AppSession` 단일 struct**다. 실측 구성:

| 구획 | 라인 | 비고 |
|---|---|---|
| **test 블록(파일 레벨)** | **7,958 (39%)** | private 메서드를 광범위 호출(아래 §2-c) |
| `AppSession` struct 메서드 | ~10,900 (403개) | 그룹 분산 대상 |
| 파일 레벨 free 헬퍼 | ~300 | `spawnRequest`·`normalizeConfig`·`sidebarBandCell` 등(이미 free) |

**거대 메서드 top**: `tick`(590)·`mouse`(524)·`rasterizeOverlayCells`(201)·`handleKeyEvent`(145)·`init`(144)·`deinit`(136)·`buildSidebarTitleFrame`(130)·`hoverCursor`(129)·`rebuildSidebar`(123). `tick`/`mouse`/`handleKeyEvent`는 **오케스트레이션 허브**(프레임 루프·입력 라우터)다.

## 2. 성격 규정 (정직 — 선결)

- **이식성 직접 기여는 없다.** `app_session`은 **L4 macOS 어댑터**라, 다른 OS로 포팅 시 **재작성 대상**이다(`layering` §2 "L4 = 재작성"). 따라서 이 분해의 1차 목적은 **가독성·테스트 격리·유지보수**이지 이식이 아니다. 이 점을 먼저 못박는다([[prefer-policy-over-codebase-mimicry]]는 정책 우선이지, 없는 이식 효과를 만들지 않는다).
- **단, 섞여 있는 OS-중립 순수 로직은 session(L2)으로 빼면 이식 기여 + 헤드리스 테스트가 따라온다.** 후보(측정): `pxToCell`/`gridFromBacking`(픽셀↔셀 기하)·sidebar 레이아웃 수학·workspace 트리 변환. **순수는 `src/session`으로, macOS orchestration은 `src/platform/macos/app_session/<group>.zig`로** 가른다.
  > **실측 정정(E1 착수):** Explore 사전조사가 "find 매치선택 순수 90%"로 추정했으나, 실제 Find(⌘F)는 `chrome_host.find`(UI 상태)·`activeSurface().core`(검색 락)·`runtime`(뷰 스크롤)·`metal_dirty`에 전부 결합한 **orchestration이라 순수분 0**(매치 선택조차 chrome 컴포넌트의 `next`/`prev` 소관)이다. 따라서 E1은 session 이동이 아니라 `app_session/find.zig` 가독성 분리다. 사전 추정 순수도는 착수 시 코드로 재검증한다([[roadmap-docs-stale-verify-with-code]]).
- **(c) core.zig보다 어려운 3가지 난점:**
  1. **허브 횡단**: `tick`/`mouse`/`handleKeyEvent`가 모든 그룹을 횡단한다 → **잔류**(분해 대상 아님, 내부 가독성은 소함수·주석으로).
  2. **cross-group accessor pub화**: 그룹을 free fn 파일로 빼면, 그 함수가 부르는 공용 accessor(`activePane`·`activeTab`·`activeSurface`·`termRect`·`activeTabLeafRects`)가 **다른 파일에서 호출되므로 pub이어야 한다**. core.zig의 accessor 분리(`absRow` 등, [[core-zig-decomposition-initiative]])와 동형이며, 캡슐화를 약간 양보한다(필드는 Zig가 privacy 없어 무관, 메서드만).
  3. **test는 통째 분리 불가**: 파일 레벨 test 7,958줄이 `splitActivePane`·`mouse`·`handleKeyEvent`·`tick` 등 **private 메서드를 직접 호출**한다. 통째 옮기면 수십 개를 pub화해야 해 캡슐화가 깨진다 → test는 **자신이 검증하는 그룹 함수와 동반 이동**(그룹 함수가 pub free fn이 되므로 호출 OK).

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

| 단계 | 그룹 | 목적지 | 성격 | 대략 라인(+test) | 위험 |
|---|---|---|---|---|---|
| **E0** | 이 문서(doc-first) | — | — | 0 | 없음 |
| **E1** ✅ | 스크롤백 Find(⌘F): 토글·재검색·네비·뷰스크롤 | `app_session/find.zig` | **orchestration(순수 0)** | ~67(본문) | 낮음 |
| **E2** | IME 상태기계·커서 rect | `app_session/ime.zig` | 혼합 60% | ~257 | 낮음 |
| **E3** | tab UI 드로잉(탭바 frame·floating glyph) | `app_session/tab_ui.zig` | 순수 85% | ~382 | 낮음 |
| **E4** | sidebar 레이아웃 수학(`sidebarMinPt`·지오메트리) | `session/`(순수부) + `app_session/sidebar.zig`(렌더) | 순수 95% | ~280 | 낮음 |
| **E5** | workspace 캡처/복원 변환 | `session_model` 확장 | 혼합 60% | ~143 | 중 |
| **E6+** | scroll·clipboard 인코딩·command catalog·notification 파싱 | `app_session/<group>.zig` | 혼합 | 그룹별 | 중 |
| (잔류) | `tick`·`mouse`·`handleKeyEvent`·`init`/`deinit`·config apply·split(PTY spawn) | `app_session.zig` | orchestration 허브 | — | — |

E1~E4는 상호 의존이 적고 응집·저위험이라 **먼저**(순수도는 그룹별 상이 — E1 find는 실측 orchestration이었고, E4 sidebar 수학·E5 workspace 변환은 순수분이 있어 session 후보), E5+는 트리 변형·런타임 결합이라 **나중**. 매 단계가 독립 PR이라 어디서 멈춰도 green. accessor pub화 발생분(E1: `activeSurface`)은 각 PR에 기록.

## 5. 검증

- **회귀 그물**: 순수 이동이라 동반 이동한 기존 test가 그대로 그물. `zig build test`·`check-boundaries`(session行 그룹 OS 타입 0)·`macos-app-build`.
- **헤드리스**: 순수 그룹(find 매치선택·sidebar 수학·workspace 변환·`pxToCell`)을 session에서 fake로 단언(이식성 증거 확장).
- **실앱**: 매 단계 `macos-app`로 탭/split/포커스/find/IME/sidebar 동작 보존.

## 6. 리스크 / 한계 (정직)

- **이식 무관(orchestration)**: 허브·런타임 결합 그룹의 분해는 macOS 내부 정리일 뿐 이식 기여 0. **순수 그룹(E1·E4·E5 일부)만** session으로 가 이식에 기여한다 — 그 외는 가독성/테스트 격리 가치로만 정당화한다.
- **cross-group accessor pub화**: 캡슐화 일부 양보(§2-c-2). core.zig 선례가 있고, accessor는 어차피 안정 표면이라 수용.
- **허브 잔류**: `tick`/`mouse`/`handleKeyEvent`는 본질적 횡단이라 파일 분해 비대상. 거대 메서드의 가독성은 소함수 추출·주석으로(별 PR).
- **ROI 분산**: 그룹당 100~400줄 + test라 단일 PR 감소폭은 작다. 누적으로 `app_session.zig`가 그룹 facade + 허브만 남는 게 종착.
