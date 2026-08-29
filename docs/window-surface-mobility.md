# 윈도우와 Surface 이동성(detach/reattach)

이 문서는 Maru의 terminal/web surface, Pane, Workspace를 OS 윈도우 사이에서 분리(detach)하고 다시 합치는(reattach/merge) 기능의 단일 출처다. 브라우저 탭 분리 UX를 위한 전용 기능이 아니라, 멀티윈도우 workspace restore, control-plane ID, 권한 scope, 알림 라우팅, WKWebView reparent의 공통 토대다.

하위 버전 호환은 고려하지 않는다. 기존 저장 파일이나 외부 ID 계약을 유지하려고 복잡도를 늘리지 않고, 새 모델에 맞지 않는 옛 상태는 조용히 기본 창으로 시작한다.

## 1. 확정 결정

- **ID foundation(M0 = M0a/M0b)은 control-plane Phase 1 live collector 전에 끝낸다.** `SurfaceIdAllocator`가 앱 인스턴스 전역 opaque u64를 단조 발급하고, `WindowMembershipSnapshot`이 `metadata:window` scope를 임시 window token 복합키 없이 판정한다.
- **소유권 foundation(M1–M2)은 웹 패널 Phase 4가 WKWebView hosting을 짓기 전에 끝낸다.** `WindowGraph`·`LiveSurfaceRegistry`가 여기 해당한다. Phase 4를 Phase 1보다 먼저 착수하면 M0a/M0b도 먼저 끝낸다. command·드래그 이동 UX와 cross-window·web reparent(M3–M6)는 Phase 4 이후에 따라와도 된다. 단일 창 web panel·markdown 뷰어는 이 refactor 없이도 동작하지만, WKWebView를 붙인 뒤 창 소유권을 바꾸면 hosting 코드 재작업이 커지므로 foundation을 먼저 둔다.
- **live surface의 소유자는 창이 아니라 AppRuntime이다.** OS 창은 surface를 소유하지 않고, `WindowGraph`가 가리키는 surface를 표시·배치한다.
- **`surface_id`는 앱 인스턴스 전역 unique opaque u64 + generation이다.** ID 값에는 window/session/local index 의미를 넣지 않는다. `window_id`/`window_token`은 현재 위치 메타데이터다. surface가 창을 이동해도 surface capability와 trace 상관키가 흔들리지 않는다.
- **부분 이동과 전체 윈도우 merge를 둘 다 지원한다.** 기본 primitive는 surface/pane/workspace 이동이고, 전체 window merge는 source window의 workspace들을 target window로 반복 이동한 뒤 빈 source window를 닫는 bulk operation이다.
- **Maru-owned browser/web panel은 기본적으로 다시 합칠 수 있어야 한다.** "단독 브라우저 창"은 합쳐지지 않는 별도 타입이 아니라 browser surface 하나만 들어 있는 Maru window다. 외부 Safari/Chrome으로 여는 `Open in External Browser`만 Maru로 reattach할 수 없는 별도 앱 경로다.
- **OS 타이틀바 드래그로 merge하지 않는다.** 창 이동 gesture와 충돌하므로, cross-window 이동은 Maru 내부 요소(surface tab, pane grip, workspace card)를 드래그하는 UX로 제공한다. 전체 window merge는 우선 command/menu/palette로 제공한다.
- **사이드바 그룹은 v1에서 이동 단위가 아니다.** workspace card는 단독으로만 창을 이동하고, 이동 시 소속 그룹에서 암묵 이탈한다 — 그룹 소속이 별도 필드가 아니라 탭 순서 파생(`group_start` 마커, [sidebar-groups.md](sidebar-groups.md))이기 때문이다. `group_start` 마커 workspace의 이동은 closeTab/removeFromGroup과 **동형**으로 처리한다 — source 창에서는 마커 속성을 다음 소속 카드로 **승계**(`inheritGroupMarker`)해 그룹을 살리고(마지막 멤버였으면 그룹 소멸), 이동된 workspace 자신은 target 창에서 그룹 이탈(최상위)로 들어간다. "해체"가 아니라 승계다(기존 마커 자리비움 규칙과 동일). 그룹 통째 cross-window 이동과 `local_pinned`/`top_level` 보존 여부는 후속 결정이다. 상세 케이스는 §4. 이 승계 계약 자체는 유지하되, 그 **red test는 M3(command 이동)에서 고정한다** — M1 `WindowGraph` 골격은 group-agnostic이라 그룹 필드를 pass-through로 보존만 하고, 승계·정규화 로직(L4 `app_session`의 `inheritGroupMarker`)의 L2 리프트 여부는 M3이 실제 그룹 workspace를 옮길 때 결정한다(§8 M1·M3).
- **native drag는 운반만, 정책은 Zig가 소유한다.** AppKit은 cross-window drag lifecycle, 좌표 변환, NSWindow 생성/focus, WKWebView reparent만 맡는다. drop 가능 여부, target 계산, WindowGraph 변경, capability 재평가는 Zig/AppRuntime이 결정한다.

## 2. 현재 코드 기준 영향

현재 macOS host의 `TerminalSurface`는 `window + appSession + metalRenderer`를 함께 들고, `New Window`는 새 `AppSession`을 만든다. 즉 실제 코드는 "한 OS 창 = 한 AppSession = live surface 소유자" 구조다. 같은 창 안에서 Pane을 새 워크스페이스로 분리하거나 기존 워크스페이스에 합치는 기능은 이미 있지만, 그 수술은 한 `AppSession` 내부 트리에서만 일어난다.

따라서 cross-window detach/reattach는 단순 UX 추가가 아니라 소유권 refactor다. 새 코드는 per-window `AppSession`에 live PTY/WKWebView를 가두지 않고, 앱 인스턴스 전역 `AppRuntime`이 live surface를 소유하게 해야 한다.

용어 주의: 이 문서의 "surface"(=`surface_id` 단위)는 pane 안의 terminal/web view **하나**다. 현재 코드의 Swift `TerminalSurface`(창 1개의 per-session 상태)나 기존 ABI `FrameSummary.surface_id`(활성 표면 1개)와 이름이 겹치지만 더 작은 단위이며 같은 것이 아니다. `surface_id`는 그 view마다 앱 전역으로 채번한다.

## 3. 목표 구조

이 절은 **최종형(target)**이다. M2b 완료 시점의 **실제 코드는 이 절반**이다(Surface·core는 아직 `Term`에 inline, registry는 `LivePtySession`만 소유, `SurfaceRuntime`은 per-window, `AppRuntime` 부재, `WindowGraph`/registry generic은 production 미배선) — M3 시작점의 정확한 코드 현실과 그 위 분해는 **§8A.0·§8A**를 단일 출처로 둔다.

```text
Identity/scope foundation (M0)
  SurfaceIdAllocator
    next opaque u64, app-instance global, no encoded window/session bits
  WindowMembershipSnapshot
    window_id/window_kind -> surface_id list

AppRuntime
  LiveSurfaceRegistry
    surface_id + generation -> terminal runtime | web panel runtime

  WindowGraph
    window_id -> workspace list -> pane tree -> surface refs

macOS Host
  NSWindow / Metal view / WKWebView
  AppRuntime diff를 받아 생성, 닫기, reparent, resize, focus만 수행
```

역할:

- `SurfaceIdAllocator`: surface 생성 시 opaque app-global ID를 발급한다. ID는 location이나 allocation origin을 설명하지 않는다.
- `WindowMembershipSnapshot`: full `WindowGraph` 전 Phase 1에서 `metadata:window`와 2-window+quick ID 비충돌을 검증하기 위한 최소 DTO다. `WindowGraph` 도입 후 같은 membership 정보의 읽기 출처만 바뀐다.
- `LiveSurfaceRegistry`: PTY reader/pump, TerminalCore, web panel state, WKWebView handle의 생명주기를 소유한다. surface는 창 이동 중에도 재시작하지 않는다.
- `WindowGraph`: 어떤 window/workspace/pane/tab 위치에 어떤 surface ref가 보이는지의 순수 모델이다.
- `AppRuntime`: registry와 graph를 함께 갱신하는 단일 정책 소유자다. 빈 source window 처리, active focus, capability scope 재평가를 여기서 결정한다.
- macOS host: NSWindow, responder, native drag session, WKWebView subview reparent, Metal renderer 연결을 수행한다.

레이어 배치([세션 컨트롤 플레인](control-plane-implementation.md) §11 코드 배치 게이트와 일치): `SurfaceIdAllocator`, `WindowMembershipSnapshot`, `WindowGraph`와 move/merge·capability 재평가 **정책 판정**은 L2 중립 코드(`src/session/`)에 두고 `app`/`pty`/`platform` import 0을 유지한다. allocator instance와 live membership 수집은 L4 coordinator가 소유한다. `LiveSurfaceRegistry`는 **L2 generic 골격**(`src/session/live_surface_registry.zig`, `LiveSurfaceRegistry(comptime Rt)` — 핸들을 모르는 순수 소유 컨테이너, M2a 완료)이고, 실제 `LivePtySession`/WKWebView 핸들로 **인스턴스화**한 registry만 L4 platform이다(`session_model.Model`이 L2 generic이고 platform이 `TermRuntime`을 넣어 인스턴스화하는 것과 같은 분리 — §8 M2a). `AppRuntime`은 L4 coordinator로, 핸들 수명은 직접 들되 이동 가부·drop target·capability scope 같은 정책은 L2 함수를 호출해 결정한다 — 정책과 플랫폼 핸들을 한 god object에 섞지 않는다.

## 4. 이동 단위와 UX

지원 단위:

| 단위 | 시작 affordance | drop 대상 | 동작 |
|---|---|---|---|
| Surface | Term/web surface tab | 같은/다른 pane tabbar | surface를 그 pane으로 이동 |
| Surface | Term/web surface tab | pane 본문 drop-zone | target pane을 split하고 surface를 새 pane에 배치 |
| Surface | Term/web surface tab | 창 밖 빈 공간 | 새 OS window 생성 후 surface 배치 |
| Pane | pane tabbar 좌측 grip | 같은/다른 window sidebar 또는 workspace | pane 통째 이동/merge |
| Pane | pane tabbar 좌측 grip | 창 밖 빈 공간 | 새 OS window 생성 후 pane 단독 배치 |
| Workspace | sidebar workspace card | 같은 sidebar | reorder |
| Workspace | sidebar workspace card | 다른 window sidebar | workspace를 target window로 이동 |
| Workspace | sidebar workspace card | 창 밖 빈 공간 | 새 OS window 생성 후 workspace 단독 배치 |
| Window all | menu/palette/action | target window | 모든 workspace를 target window로 이동 후 source window close |

전체 window merge는 우선 다음 action으로 제공한다.

```text
merge_window_into_active_window
merge_all_windows
move_all_workspaces_to_window:N
```

기본 단축키는 두지 않는다. 단일 macOS 관례가 없고, 실수 시 큰 레이아웃 변형이므로 command palette, window menu, context menu로 노출한다.

quick terminal은 이동 단위·대상에서 제외한다 — 싱글톤 dropdown이라 detach/reattach·merge·split drop의 출발지도 도착지도 아니다. `merge_all_windows`/`merge_window_into_active_window`도 quick window를 포함하지 않는다. quick 안의 surface를 일반 창으로 빼내는 별도 UX가 필요하면 추후 명시 결정한다.

사이드바 그룹과의 상호작용(§1 결정의 상세): workspace card 이동은 사이드바 그룹 모델([sidebar-groups.md](sidebar-groups.md))과 직접 상호작용한다 — 소속이 탭 순서 파생이라 창을 떠나는 순간 소속·핀 리전이 바뀐다. v1 케이스: (a) 그룹 멤버 이동 = 그룹 암묵 이탈 + source 창 재정규화, (b) `group_start` 마커 이동 = source에서 마커 승계(그룹 잔존, 마지막 멤버면 소멸) + 이동분은 target 최상위 — closeTab/removeFromGroup과 동형(`inheritGroupMarker`), (c) 전역 `pinned` workspace 이동 = target 창의 핀 리전 정책("고정 요소 흡수 불가" 포함)을 그대로 따름, (d) `local_pinned`/`top_level`은 이탈 시 의미를 잃으므로 리셋. **이 정규화 케이스 (a)~(d)는 M3c에서 구현·red test 완료**(정규화 권위를 L2 순수 함수로 리프트) — M1 `WindowGraph` 골격은 group-agnostic이라 그룹 필드를 pass-through로 보존만 했으나, **M3c부터 `WindowGraph.moveWorkspace`가 L2 `group_normalize`로 실제 정규화**한다. 정규화 코어(`inheritGroupMarker`·`normalizePinnedFromGroups`·`effectiveDepthAt`·`clearStaleLocalPins`·`enclosingGroupMarkerIndex`)를 `src/session/group_normalize.zig`에 generic 순수 함수로 올렸고, L4 `app_session`의 그 다섯 메서드는 본문을 L2 위임으로 교체해 `closeTab`/`removeFromGroupForTab`이 같은 코어를 재사용한다(재구현 금지, drag-preview 게이트는 L4 유지). **(d) `top_level`은 명시 `true` set으로 확정**(목적지 append-to-end라 위치-암묵 top-level 불성립 — §8A.4)·pinned-멤버 unpin 포함. 같은 sidebar 안 드래그에는 이미 Cmd=그룹 중첩 제스처가 있으므로, cross-window 드래그가 이 제스처와 충돌하지 않게 M5에서 modifier 의미를 재확인한다.

## 5. Native 이벤트 사용 범위

같은 window 내부 이동은 기존 Zig mouse/hit-test 경로를 유지한다. 다른 OS window로 넘어가거나 창 밖 빈 공간에 drop하는 순간부터 AppKit drag-and-drop lifecycle을 사용한다.

AppKit이 맡는 것:

- `NSDraggingSession` 시작/종료.
- 각 Maru window의 `NSDraggingDestination` enter/update/drop.
- drag image 또는 floating preview를 OS window 밖에서도 보이게 하는 native transport.
- screen/window/backing px 좌표 변환.
- 새 NSWindow 생성·focus.
- WKWebView subview reparent와 frame 적용.

Zig/AppRuntime이 맡는 것:

- drag payload가 surface/pane/workspace/window_all 중 무엇인지 판정.
- drop target이 유효한지 계산.
- same-window/cross-window highlight와 drop-zone 의미 결정.
- WindowGraph 변경.
- source window가 비었을 때 닫을지 정책.
- `metadata:window` 같은 권한 scope 재평가.
- trace/event 기록과 replay 가능한 domain event 생성.

## 6. 권한과 ID

`surface_id`는 이동해도 유지된다. 따라서 surface 기준 capability(`read-output:self`, `write:self` 등)는 generation이 유지되는 한 그대로 유효할 수 있다. 반면 window 기준 capability(`metadata:window`)는 이동 후 현재 window membership을 기준으로 다시 평가한다.

**trust boundary 교차 시 surface-scope cap 재평가(적대적 리뷰 반영)**: surface-scope cap이 이동 중 generation 불변으로 유지되면, 저신뢰 창에서 (capability fd 상속 등으로, [control-plane-security.md] §8.5) 새어나간 `read-output`/`write` nonce가 그 surface를 "secure" 창이나 main 작업 창으로 detach/merge한 뒤에도 살아 있다. 따라서 surface가 **trust boundary를 넘으면**(예: quick↔일반, 신뢰 등급이 다른 창) surface-scope cap을 re-mint/revoke한다. 최소한, 이동이 이전에 새어나간 capability를 **격리하지 못한다**는 점을 명시한다.

**이동 이벤트는 원자 트랜잭션**: cross-window move는 `WindowGraph` 변경과 **영향받은 모든 구독의 scope 재평가를 같은 main-thread 트랜잭션 안에서 동기 수행**한다(lazy 재평가면 이동 직후 옛-창 구독자가 떠난 surface 이벤트를 계속 받거나 새 창 surface를 잠깐 엿본다). 트랜잭션 경계를 넘는 이벤트가 stale scope로 새지 않게 한다. 구독 유지/해제/`removed` 이벤트 중 무엇인지는 [control-plane.md] §13 열린 질문이었고 **§8A.3에서 확정**: window-scope 구독은 **유지**하고 옮겨진 surface에 대해 `session.movedOut`/`movedIn`(membership-changed) notification을 방출한다(`removed`/`closed` 아님 — surface는 살아 있음). `metadata:self`는 surface_id 불변이라 무영향(응답 메타 window 필드만 갱신).

`window_token`은 bearer token이 아니며 현재 위치를 설명하는 메타데이터다. control-plane selector는 최소 `{instance_nonce, surface_id, generation}`을 핵심으로 하고, 응답 메타데이터에 현재 `{window_id, window_token, window_kind}`를 싣는다.

## 7. Workspace restore

restore의 단일 출처는 [Workspace Restore 전략](workspace-restore.md)이다. 이 절은 그 문서에 중복 정의하지 않고, 이동성 모델이 요구하는 변경만 적는다(상세 저장/미저장 목록은 거기서 갱신).

- 저장 모델의 **권위 출처**를 바꾼다. 현재 `saveWorkspace`/`restoreWorkspace`는 이미 멀티 창을 창별 per-session `Model` 블록(`maru.workspace.v1`)으로 저장·복원한다(첫 블록 primary + 나머지 블록마다 새 창) — 즉 멀티 창 저장은 stale 미구현이 아니라 현재형이다. **정정(drift)**: M1/M2는 배치 권위를 아직 올리지 **않았다** — `WindowGraph`(M1)·registry generic(M2a)은 순수 L2 골격 + 헤드리스 테스트만이고 production 라이브 트리(per-window `AppSession`)가 여전히 배치 권위다. **§8A.6 설계 결정**: `WindowGraph`는 **라이브 미러가 아니라** (1) 순수 move 알고리즘/테스트 오라클 + (2) 직렬화 포맷이고, 라이브 배치 권위는 per-window 트리로 유지한다. **M3e 정정(사용자 리뷰 — v2 하드 브레이크 기각·과설계)**: cross-window 이동 배치는 **이미 v1으로 재시작 후 유지된다**(각 세션이 자기 라이브 트리를 창별 블록으로 저장·복원 — M3 핵심 목표 충족). 유일한 유용 델타인 **활성(key) 창 보존**만 `maru.workspace.v1`에 **옵션 additive 필드 `active-window`**로 더한다(헤더 bump 없음·`window_id`/`window_kind` 없음 — dead 필드라 미도입). `group-collapsed`와 동일한 옵션-키 패턴(false=writer 생략=round-trip 고정점, reader 없으면 기본값, 옛 리더 미지 키 skip)이라 **완전 하위호환**: 옛 파일은 마커 없이 정상 로드(현행 동작 유지), 새 파일은 옛 리더가 `active-window`를 skip. 복원 loop가 `activeWindowIndex`로 활성 창을 `makeKeyAndOrderFront`한다. NO 헤더 bump·NO v1 reject·NO 마이그레이션.
- live PTY fd·child pid·WKWebView process handle·JS heap snapshot은 계속 저장하지 않는다(기존 정책 유지).
- 현재 복원 시 live surface는 새 generation으로 생성된다. persistent-session P4 이후 terminal Term만 Maru
  `runtime_handle`이 살아 있을 때 재연결하며, provider session resume/fork는 시도하지 않는다.
- 하위 호환은 없으므로 옛 저장 파일은 workspace-restore.md의 "조용한 기본 창 폴백"을 따른다.

## 8. 구현 순서

이 기능은 full drag UX부터 만들지 않는다. 먼저 command path와 순수 모델을 고정한다.

1. **M0a SurfaceIdAllocator**: 앱 인스턴스 전역 opaque u64 발급, 단조·비재사용 단위 테스트. 기존 per-session `next_id`(app_session.zig)는 외부 ID로 노출하지 않는다. 착수 결정(코드 대조로 확정):
   - **스레드: plain `u64`, 메인 스레드 전용(atomic 불필요)**. `createTerm` 호출처(`createTab`·`createPane`·`createTermFromSurface`/restore)는 전부 메인 이벤트이고, 리더 스레드는 `core_mutex` 아래 ring/scrollback만 만지고 세션 트리는 건드리지 않는다. `assert(main-thread)` 주석으로 계약을 고정한다.
   - **주입: `AppSession.surface_ids: *SurfaceIdAllocator` 필드가 코디네이터 소유 allocator를 참조**하고 `createTerm`이 거기서 발급받는다. 코디네이터 seam은 `app_session.zig`의 모듈-로컬 `var app_surface_ids`(L4 인스턴스 소유, 모든 창이 공유하는 앱 전역 하나)이고, 필드 기본값이 그 주소(`&app_surface_ids`)라 `init`의 `self.* = .{...}`·reset 경로가 자동으로 같은 allocator를 가리킨다. **`init`에 파라미터로 주입하지 않은 이유**: 실제 코드의 `session.init(...)` 호출처가 333곳(대부분 테스트)이라 필수 파라미터 추가는 M0a 범위를 크게 넘는 기계적 대량 변경이 된다 — 필드 기본값이 zero-churn이면서 계약(창 공유·앱 전역 하나)을 그대로 만족한다. M1 AppRuntime이 생기면 이 모듈-로컬 소유를 AppRuntime으로 옮기고 필드 주입 경로만 바꾼다. **`var session: AppSession = undefined` 테스트**는 실제로 22곳이며(문서의 옛 "3곳"은 stale), 그중 `createTerm`을 타는 것(발급 경로)은 전부 `session.init(...)`을 먼저 부르므로 필드 기본값으로 안전하다 — `init` 없이 필드를 수기로 세팅하면서 `createTerm`까지 도달하는 기존 테스트는 0곳이다. 따라서 명시 초기화가 필요한 건 신규 발급-경로 테스트뿐이고, 그 테스트도 `init`을 쓰면 자동 충족된다([[devsession-undefined-test-field-trap]]는 `init` 없이 발급 경로를 타는 신규 테스트를 만들 때 여전히 적용).
   - **generation은 M0a 범위 밖**. surface_id 비재사용(단조)이 주 방어이고([control-plane.md] §3 defense-in-depth), generation은 보조 키다. **정책 소유자(정정, 적대적 리뷰 반영)**: M1(WindowGraph)·M2a(LiveSurfaceRegistry)는 generation을 **보존만** 하고 증가시키지 않는다(둘 다 완료). generation이 증가하는 유일 경로(crash-respawn으로 surface_id 유지+generation++, 새 런타임 인스턴스)는 어느 slice에도 배정되지 않았었다 — production `Term.live_pty` 소유를 옮기는 **M2b**가 그 정책을 정하기로 했고(M1이 아니다), **M2b가 결정**했다: registry는 `create(id, 0)`으로 발급·**보존만** 하고, generation++는 crash-respawn 연산이 도입될 때 그 연산과 함께 실현한다(현재 respawn 경로 없음 → 불변, §8 M2b "generation" 결정). **타입**: generation은 `u64`다(`SurfaceDto.generation`·`LiveSurfaceRegistry.Entry.generation` 정합).
2. **M0b WindowMembershipSnapshot**: full `WindowGraph` 전 2-window+quick membership DTO, `metadata:self/window/all` scope 필터 테스트. `window_kind` 판별자가 코드에 없던 것을(quick은 Swift 전용 `quick` 참조·`QuickTerminalPanel`·`chrome_minimal` 플래그로 분산) M0b가 중립 L2 enum(`WindowKind`, `src/session/window_membership.zig`)으로 도입한다. 실제 창 분류 배선(`chrome_minimal`→`window_kind`)은 Phase 1 collector 몫이다.
3. **M1 WindowGraph TDD**: `moveSurface`, `movePane`, `moveWorkspace`, `mergeWindow`, no-op/empty-source/focus 보정 단위 테스트. **M1은 group-agnostic 골격이다** — `moveWorkspace`의 그룹 필드(`group_start`·`top_level`·`local_pinned`·`pinned`)는 workspace 메타데이터로 이동 시 **pass-through 보존만**(값 유지, 정규화 없음) 하고, 그 보존을 단언으로 고정한다. 그룹 정규화(마커 승계·핀 리전 재정규화)는 M3이 실제로 그룹 workspace를 창 간 이동할 때 `inheritGroupMarker`의 L2 리프트 여부와 함께 red test로 고정한다. **정규화를 M1의 L2에 재구현하지 않는 이유**: 정규화 로직(`inheritGroupMarker`·`normalizePinnedFromGroups`)은 지금 L4 `app_session.zig`에만 있고 L2 순수 버전이 없다 — M1이 L2에 재구현하면 L4와 발산하고 M3보다 조기 구현이 된다. 그래서 M1 `WindowGraph`는 그룹 필드를 불투명 메타데이터로 실어 나르기만 하고, 승계·정규화의 권위와 L2 리프트 결정은 M3으로 미룬다(§4 케이스 (a)~(d)의 실현 시점 = M3).
4. **M2 LiveSurfaceRegistry 분리**: terminal live runtime을 window 밖 owner로 이동. surface 이동 시 PTY/TerminalCore를 재시작하지 않음을 테스트. web panel state/WKWebView handle은 이 시점에 아직 없으므로 terminal runtime만 옮기고, web surface runtime은 Phase 4 이후 같은 registry에 합류한다.
   - **M2a(완료, 골격 + TDD)**: M1 `WindowGraph`가 순수 배치 골격을 L2에 먼저 못박은 것과 **동형**으로, `LiveSurfaceRegistry`도 **런타임 소유 골격**을 L2(`src/session/live_surface_registry.zig`)에 먼저 못박는다 — `session_model.Model(Rt)`/`SplitTree(Leaf)` 선례처럼 런타임 부착 타입 `Rt`로 generic화한다. registry는 각 런타임을 **heap로 개별 할당해 소유**(`allocator.create(Rt)` → 주소 안정 슬롯)하므로, reader thread가 잡는 embedded `&rt.<reader>` 주소 안정성이 Term heap-pin과 **같은 메커니즘으로** 보존된다(§57의 "L4 platform"은 실제 `LivePtySession`/WKWebView 핸들로 **인스턴스화**한 registry를 가리킨다 — generic 골격 자체는 핸들을 모르는 L2다. `session_model.Model`이 L2 generic이고 platform이 `TermRuntime`을 넣어 인스턴스화하는 것과 같은 분리다). red→green TDD로 (a) 재배치 후 `findBySurface(surface_id)` **동일 포인터**·스크롤백 상태 보존·재시작 0회, (b) ArrayList realloc에도 `*Rt` 주소 불변(주소 안정성 = reader 계약), (c) 중복 등록 거부·없는 surface 제거·close 제거·빈 registry·다중 등록·중간 제거 시 타 엔트리 불변·`WindowGraph` 이동(왕복 포함)과의 결합 정합을 못박는다. 이 골격은 M1 `window_graph.zig`가 그렇듯 아직 production `app_session`에 배선되지 않는다(다음 단계에서 배선).
   - **M2b(완료, production 마이그레이션)**: 옛 `TermRuntime.live_pty: LivePtySession`은 heap-pin `*Term` 안에 **inline value**로 소유되고(`createTerm` init → `destroyTerm`/창 close/`AppSession.deinit`가 직접 teardown), 앱 전역 `LivePtyRegistry`(비소유 close-index, 현재 smoke/test 전용)와는 별개였다. M2b가 이 inline 소유를 `LiveSurfaceRegistry`(앱 전역 owner)로 올리고 `Term`은 그 **안정 heap 슬롯 포인터**(`live_pty: *LivePtySession`)로 참조하게 바꿨다. **주의(범위 판정 근거)**: (1) `TerminalCore`는 `LivePtySession`이 아니라 `Surface`(=`Term.surface`) 안에 있고 SplitTree leaf·렌더러·수백 곳의 `term.surface` 접근과 얽혀 있어, §3이 말하는 "registry가 TerminalCore를 소유"의 완성은 `Surface`를 `Term` 밖으로 빼는 대수술(M3+)을 요구한다 — M2b는 `live_pty` 소유만 옮기므로 §3의 절반(런타임 소유 이전)만 이루고, **실제 cross-window 이동은 아직 못 한다**(surface/TerminalCore가 Term에 남아 reader가 `&term.surface.core`에 교차 바인딩 — 이동하려면 M3+에서 Surface도 함께 옮겨야 함). 즉 M2b는 사용자 가시 변화 0인 **소유 위치 이전(디딤돌)**이다. reader-불변식이 걸린 대형 파일이라 churn 최소화가 핵심: `live_pty`를 값→포인터로 바꾸면 Zig auto-deref로 대부분의 `live_pty.X` 접근이 그대로 유효하고, 소유/수명(create·remove)만 registry를 거친다(변경 site ≈ createTerm 1 + teardown 2). (2) reader thread가 `&live_pty.reader`(이제 registry 슬롯)와 `&surface.core`/`&surface.core_mutex`(여전히 Term)를 **교차 바인딩**하므로 teardown은 detach-before-deinit 순서를 지킨다. **확정 결정(M2b가 정한 것)**:
     - **소유 seam**: 앱 전역 모듈-로컬 `var app_live_registry: LiveSurfaceRegistry(LivePtySession)`(app_session.zig) + `AppSession.live_registry: *… = &app_live_registry` 필드 주입 — M0a `app_surface_ids`/`surface_ids`와 **동형**(모든 창 공유, `init`의 `self.* = .{...}`이 자동으로 같은 registry를 가리킴, M1 AppRuntime 도입 시 소유만 이관). surface_id가 앱 전역 유일(M0a)이라 멀티 창에서도 키가 안 겹친다.
     - **allocator 분리**: registry **자체의 bookkeeping**(entries + 각 런타임 heap 슬롯)은 창보다 오래 사는 앱 전역 수명이라 프로세스 전역 `smp_allocator`(app_host_abi가 AppSession을 만들 때 쓰는 것과 동일)로 소유하고, 각 `LivePtySession` **내부**(session/queue)는 그 런타임을 만든 창의 allocator가 소유한다(createTerm이 init에 주입). `remove`가 `deinit`(창 allocator로 내부 해제) 후 슬롯을 smp로 destroy하므로 두 allocator가 각자 짝이 맞는다(프로덕션은 창도 smp라 사실상 동일; 테스트만 창=testing.allocator라 분리 — 그래도 testing.allocator는 내부만 보므로 균형).
     - **teardown 계약**: **coordinator(`app_session`)가 `live_pty.closeAndDetach(&runtime)` 선행 → `registry.remove(surface_id)`**(= `Rt.deinit`=reader join + 슬롯 해제) 순서. registry는 L2 generic이라 runtime/detach를 모른 채 `deinit`만 부른다("coordinator closeAndDetach 선행" 옵션 채택). init-실패 errdefer는 `removeUninitialized`(uninit 슬롯을 deinit 없이 해제 — `create`/errdefer 계약의 짝)로 닫는다.
     - **generation**: `create(id, 0)`으로 0에서 시작하고 **보존만** 한다(M2a와 동일). generation++는 **crash-respawn 연산과 함께** 도입하는데 그 연산 자체가 아직 없어(현재 exit는 reap→close로 Term teardown, 같은 surface_id 재생성 경로 없음) **미도입/후속으로 결정**한다 — respawn 기능이 생기면 그때 old entry remove + `create(id, gen+1)`로 새 슬롯을 만든다(surface_id 유지, generation 증가). §8 M0a의 "M2b가 generation 증가 정책을 정한다"는 이로써 닫힌다(정책=respawn 시 증가, 현재 respawn 없음→불변).
     - **비소유 close-index(`app/live_pty_registry.zig`)**: 여전히 별개(smoke/test 전용). M2b는 새 소유 registry만 배선하고 옛 비소유 index 통합/재배선은 손대지 않았다(범위 밖 — control_* 병렬 작업과 충돌 회피).
5. **M3 command 기반 이동**: palette/menu action으로 surface/pane/workspace/window_all 이동. Swift는 window create/focus만 수행. 종료 gate에 workspace restore의 `WindowGraph` 포맷 확장(§7)을 포함한다. **이 단계는 대수술이라 한 슬라이스로 하지 않는다 — §8A가 M3a(Surface 소유권 lift)→M3b(AppRuntime+앱-전역 라우팅)→M3c(그룹 정규화 L2 리프트, 병렬)→M3d(command 이동)→M3e(활성 창 보존 — v1 호환 `active-window` 필드)로 분해하고, 여섯 어려운 문제의 구체 해법을 못박는다. 첫 슬라이스=M3a.**
6. **M4 same-window drag 재연결**: 기존 drag 경로가 WindowGraph move API를 쓰게 정리.
7. **M5 cross-window native drag**: AppKit drag session/destination을 붙이고 Zig drop target API에 연결.
8. **M6 web surface reparent (착수 2026-07-15 = plans/web-panel.md §10 4e-4)**: WKWebView를 destroy/recreate하지 않고 target window/container로 reparent. focus/IME/z-order artifact로 검증. **구현 접근(사용자 승인)**: WKWebView는 Swift/AppKit 객체라 단일 `MaruAppHostController`가 전역 조율한다 — 대상 창 `create`가 다른 창의 기존 WKWebView를 훔쳐 재부모화(`surfaceOwning` 전역 스캔), 원본 `destroy`는 그 surface가 다른 창 모델에 live면(신규 ABI `has_web_surface`) 파괴·`browser.closed` 억제. §3 목표형 `LiveSurfaceRegistry`(WKWebView 핸들을 Zig registry가 소유)로의 이관은 **직교하는 구조 후속**이고, 올바른 재부모화 자체는 컨트롤러 조율로 충분(§8A.1 registry lift는 web 미합류 상태 그대로 둠 — 상세·근거는 plans/web-panel.md §10 4e-4).

기존 Phase 계획 영향:

- **Phase 1 영향 있음**: live collector 전에 M0a/M0b가 선행된다. 이 때문에 1c가 단순 fake DTO가 아니라 allocator와 membership scope red test를 포함한다.
- **Phase 2~3 순서 영향 없음**: write/event/stream은 이미 `surface_id + generation`을 쓰므로 Phase 1의 전역 ID 계약을 소비하면 된다. 단 Phase 3의 background 세션 이벤트 소스(3b)는 per-window AppSession 순회 전제라, M1/M2가 먼저 끝나 있으면 AppRuntime graph를 직접 읽어 재배선을 아낀다(권장이지 차단 아님 — [control-plane.md] §7).
- **Phase 4 영향 있음**: WKWebView hosting 전에는 M0 완료를 확인하고 M1/M2가 선행된다. Phase 4가 Phase 1보다 먼저면 M0a/M0b를 먼저 닫는다. M3(command move/merge)까지 Phase 4 전에 끝낼 필요는 없다.
- **Phase 5~7 순서 영향 없음**: bridge, WebDriver adapter, markdown content는 새 ID와 WindowGraph membership을 소비한다. 하위호환 bridge/API adapter를 만들지 않는다.
- **Workspace restore 영향 있음**: cross-window 이동 배치는 이미 v1(창별 블록)으로 재시작 후 유지되고, M3e는 활성(key) 창 보존만 `maru.workspace.v1` 옵션 additive 필드 `active-window`로 더한다(하위호환 — 헤더 bump·마이그레이션·구버전 reject 없음, `group-collapsed` 패턴). 손상·미지 파일은 조용한 기본 창 폴백.

각 단계는 [세션 컨트롤 플레인](control-plane-implementation.md) §11의 Phase 시작 gate와 같은 방식으로, 시작 전에 사용자에게 scope·파일 후보·권한 변화·검증 gate를 설명하고 직전 단계 regression gate를 재실행한다.

## 8A. M3 구체 설계 (대수술 — Surface 소유권 이동 + 하위 슬라이스 분해)

§8의 5번 "M3 command 기반 이동"은 한 슬라이스로 하기엔 너무 크다(대수술). 이 절은 코드 현실(drift gate)에 근거해 M3을 **관찰 가능한 한 디딤돌씩** M3a~M3e로 분해하고, 여섯 어려운 문제의 **구체 해법**(추상론 말고 실제 코드 구조)을 못박는다. 착수 전 각 슬라이스는 §8·[control-plane-implementation.md] §11의 drift gate와 직전 슬라이스 regression gate를 재실행한다.

### 8A.0 M2b 후 코드 현실 (drift gate 정정 — §3·§8의 M3 시작점)

**상태(2026-07): M3a·M3b 머지됨, M3c 구현(그룹 정규화 L2 리프트 — §8A.4), M3d-1 구현(cross-window 이동 트랜잭션 헤드리스 코어 — `src/session/surface_move.zig`, §8A.8), M3d-2a-i 구현(비-그룹·비-pinned workspace/window 라이브 이동 — `app_session.moveWorkspaceToSession`/`mergeSessionInto`, 헤드리스 Zig + ABI, §8A.8), M3e 구현(v1 호환 `active-window` 옵션 필드로 활성 창 focus 재시작 유지 — v2 하드 브레이크는 사용자 리뷰로 기각·과설계, 헤더 `maru.workspace.v1` 유지·`window_id`/`window_kind` 미도입, §8A.6/§8A.8), M3f 구현(창 geometry 복원 — `maru.workspace.v1` 옵션 additive 필드 `win-x/y/w/h`로 위치·크기·모니터 재시작 유지, M3e `active-window`와 동일 옵션-키 패턴·완전 하위호환·헤더 유지, §8A.6/§8A.8)** — 아래 bullet들은 **M3 착수 직전(pre-slice) 코드 현실의 역사적 스냅샷**이라 그 시점 기준으로 읽는다(M3a 머지 때도 이 스냅샷은 프리즈로 뒀다). 이후 정정: (M3a) Surface·TerminalCore 소유가 Term-inline → 앱 전역 `app_runtime.live_registry`의 `LiveSurface` 번들 슬롯으로 이전됐고 registry는 `LiveSurfaceRegistry(LiveSurface)`로 인스턴스화된다(bullet 1·2 무효화, §8A.1). (M3b) `SurfaceRuntime`(라우팅)이 per-window → **앱-전역**으로 승격됐고, 흩어져 있던 모듈-로컬 `var app_surface_ids`/`app_live_registry` + per-window `runtime`이 하나의 `AppRuntime` coordinator(`src/app/app_runtime.zig` = {surface_ids, live_registry, routing}, 모듈-로컬 `var app_runtime`이 소유·모든 창 공유)로 정식화됐다. per-Term `pump`는 앱-전역 routing에 바인딩되고, 창 close는 그 창 링크만 detach하며 공유 표를 deinit하지 않는다(창 격리)(bullet 3·4 무효화, §8A.2). **남은 것**: M3d-1이 cross-window 이동 **원자 트랜잭션 헤드리스 코어**(`surface_move.zig` — 순수 오라클 위 트리 수술 + 구독 재평가·trust cap·빈 창 판정, 무재시작 불변식 fake 테스트)를 추가했으나, 라이브 배치 권위는 여전히 per-window 트리이고 **라이브 두-창 트리 수술 + 양-창 렌더 리프레시 + Swift 창 수명 배선은 M3d-2**다(bullet 5 유효 — registry·routing은 배선됐으나 `WindowGraph` 배치 권위 전환·이동 command·live 수술은 M3d-2/M3e).

§3 목표 구조는 최종형이고, M2b 완료 시점(2026-07)의 **실제 코드**는 그 절반이다. M3 설계는 아래 현실에서 출발한다(코드 재확인 완료):

- **Surface는 아직 `Term`에 inline value로 남아 있다.** `session_model.Term`(`src/session/session_model.zig:35`)이 `surface: Surface`를 **값**으로 품고, `Surface`(`src/session/surface.zig:26`)가 `core: TerminalCore` + `core_mutex: std.Io.Mutex`를 **값**으로 든다. `&surface.core`/`&surface.core_mutex`의 주소 안정성은 **오직 `Term`이 heap-pin(`*Term` in `ArrayList(*Term)`)이라서** 성립한다. 즉 §3이 말한 "registry가 TerminalCore를 소유"는 **아직 실현되지 않았다** — registry는 M2b에서 `LivePtySession`만 소유로 올렸다.
- **`LiveSurfaceRegistry`는 런타임 슬롯만 인스턴스화·소유한다.** 앱 전역 `app_runtime.live_registry`이고 창은 그것을 가리킨다(`AppSession.live_registry: *LiveSurfaceRegistry(app.LiveSurface)` — app_session.zig:4176). Term은 그 슬롯을 **참조만** 한다(M2b) — P2 seam 이후로는 `*LivePtySession` 포인터가 아니라 opaque `RuntimeHandle`을 들고 `termBackend()`로 건넨다([persistent-session-host.md](persistent-session-host.md) §13 P2). Surface(=core)는 미포함.
- **`SurfaceRuntime`(입력/resize/명령 라우팅)은 M3b 이후 앱 전역이다.** `AppSession.runtime: *app.SurfaceRuntime = &app_runtime.routing`(app_session.zig:4196) — 창마다 하나가 아니라 **모든 창이 같은 표를 가리킨다**. 라우팅 표 `Link{surface_id, *Surface, pty_id, pty_io}`는 `surface_id`로 keyed라 cross-window 이동이 라우팅을 안 건드리고, 창이 닫혀도 표를 deinit하지 않는다(다른 창 링크가 살아 있다). **M3b 이전에는 per-window였다** — 그 전환은 §8A.2가 소유한다.
- **`AppRuntime`은 아직 없다.** §3이 "registry와 graph를 함께 갱신하는 단일 정책 소유자"라 부른 것은 현재 app_session.zig의 모듈-로컬 `var app_live_registry`/`var app_surface_ids` + per-window `runtime`으로 흩어져 있다.
- **`WindowGraph`(M1)·`LiveSurfaceRegistry` generic(M2a)은 production에 배선되지 않았다.** 순수 L2 골격 + 헤드리스 테스트만 존재하고, 라이브 배치 권위는 여전히 per-window `AppSession` 트리(`SplitTree(*Pane)` + `tabs: []*Tab`)다. 따라서 §7이 말한 "M1/M2가 배치 권위를 WindowGraph로 올림"은 **아직 안 일어났다** — M3이 그 배선을 한다.
- **reader의 교차 바인딩(불변식의 심장)**: `attachSurface`(live_pty.zig:234)가 `reader.setProcessing(&surface.core, &surface.core_mutex, io)`로 **Term-inline `&surface.core`**와 **registry-슬롯 `&live_pty.reader`**를 함께 잡는다. teardown은 `closeAndDetach`(라우팅 detach + reader join) → `live_registry.remove`(deinit=join) → `surface.deinit` 순서를 강제한다(destroyTerm:3573, deinit 2-pass:17698/17724, reap:14730 — 세 곳 동기 유지 필요).

이 현실에서 **cross-window 이동이 아직 불가능한 이유**는 명확하다: surface(core)가 Term에 갇혀 있고 reader가 `&term.surface.core`를 잡고 있어, 다른 창으로 옮기려면 (구현 A) Surface를 registry로 올려 주소를 창 밖에 고정하거나 (구현 C) heap-pin된 `*Term` 자체를 창 간 재부모화해야 한다. 8A.1이 이 선택을 다룬다.

### 8A.1 Surface/TerminalCore 소유권 이동 (문제 1 — M3 대수술의 핵심)

**목표**: cross-window 이동 중에도 `&surface.core`/`&surface.core_mutex`(reader 바인딩)·`Link.surface`(라우팅)·`surface_ptrs[]→app_window.tabs`(렌더 활성 표면)가 가리키는 주소가 안정해야 한다. M2b가 `live_pty`에 쓴 패턴(값→포인터 + heap-pin 슬롯)을 Surface에 어떻게 적용하는가.

두 가지 구조가 가능하다. **채택(A)**과 **대안(C)**을 근거와 함께 제시한다([[document-basis-and-decision]]).

**옵션 A — Surface를 registry로 올려 `LivePtySession`과 **번들**로 소유(채택).** registry 인스턴스화를 `LiveSurfaceRegistry(LivePtySession)` → `LiveSurfaceRegistry(LiveSurface)`로 바꾼다. `LiveSurface`는 한 surface의 라이브 소유 번들이다:

```text
LiveSurface = struct {
    surface: Surface,           // core + core_mutex + 메타(현 Term-inline을 이관)
    live_pty: LivePtySession,   // M2b가 이미 registry로 올린 런타임(inline로 흡수)
    internal_allocator,         // 이 번들 내부(core·session·queue·owned strings)를 만든 창 allocator
    fn deinit: live_pty.deinit()(reader join) → surface.deinit() 순서
}
```

- **근거**: (1) §3 목표 구조가 문자 그대로 "registry: surface_id → terminal runtime(=PTY reader/pump·**TerminalCore**·…)"라 A가 설계 의도다. (2) **M2a의 `FakeRuntime` 테스트가 이미 이 번들을 모델한다** — `pty_id`(LivePtySession identity) + `scrollback`(TerminalCore 상태)을 한 번들로 흉내내며 "M2 registry가 그 번들을 소유"라고 주석에 못박았다(live_surface_registry.zig:141-169). 즉 A는 이미 red 테스트 스캐폴드가 있다. (3) **web surface(Phase 4/M6)가 같은 registry에 번들로 합류**한다 — `LiveSurface`가 terminal 번들이면 web 번들(WKWebView handle + panel state)도 같은 registry 슬롯 모델로 통합돼 "surface = registry-owned" 추상이 균일해진다. (4) 이동이 **런타임을 전혀 안 건드린다** — registry는 surface_id로 keyed라 배치만 재-포인트하면 되고, 이게 M2a 테스트가 단언하는 불변식(재시작 0회·동일 포인터)이다.
- **Term의 변화(churn)**: `Term.surface: Surface`(값) → `Term.surface: *Surface`(번들 슬롯 참조, borrowed). `Term.rt.live_pty`는 이미 `*LivePtySession`이라 그대로 번들의 `&slot.live_pty`를 가리킨다. **두 포인터가 한 슬롯을 가리킨다**(surface_id 하나 = 번들 하나). `term.surface.core` 등 **읽기 접근(≈83 `term.surface` + 59 `.surface.core` 사이트)은 Zig auto-deref로 그대로 유효**하다(M2b의 `live_pty.X` auto-deref 선례와 동일). 진짜 churn은 **주소 취득 `&term.surface`(30 사이트)**를 `term.surface`(이미 포인터)로 **`&` 제거**하는 것 + teardown 재배선이다.
- **주소 안정성 보존**: reader의 `&surface.core`는 이제 `&slot.surface.core`(registry 슬롯) — `&live_pty.reader`와 **똑같은 heap-pin 메커니즘**(registry가 `allocator.create(LiveSurface)`로 슬롯을 개별 고정, entries realloc는 `*LiveSurface` 포인터만 옮김)으로 안정하다. M2a "주소 안정성" 테스트가 이미 이 불변식을 증명한다.
- **createTerm 재배선**: `registry.create(id)` → `*LiveSurface` 슬롯 확보 → 슬롯의 `surface`·`live_pty`를 **제자리 init**(현 createTerm의 `Surface.init` + `live_pty.init`을 슬롯 필드에 대고) → `term.surface = &slot.surface; term.rt.live_pty = &slot.live_pty`. errdefer는 M2b의 `remove`/`removeUninitialized` 분기를 번들 단위로 확장.
- **teardown 재배선**: `closeAndDetach(&runtime)`(라우팅 detach) → `registry.remove(id)`가 이제 번들 deinit(=`live_pty.deinit` reader join → `surface.deinit`)을 한 번에. 현재 destroyTerm이 `term.surface.custom_name`·git 캐시를 창 allocator로 free하던 것은, **owned string 해제를 번들 `internal_allocator`로 이관**(surface에 allocator 참조를 실어 deinit에서 해제)하거나 remove 직전에 free한다 — "Surface.deinit엔 allocator가 없다"는 현 제약을 번들이 흡수한다. 세 teardown 사본(destroyTerm·deinit 2-pass·reap)을 동기 갱신.
- **allocator 분리**: registry bookkeeping(entries + 각 `LiveSurface` 슬롯)은 앱 전역 `smp_allocator`, 번들 **내부**(core·session·queue·owned strings)는 그 번들을 만든 창 allocator — **M2b의 분리를 그대로 확장**(프로덕션은 창도 smp라 사실상 동일, 테스트만 분리). cross-window 이동은 내부 allocator를 안 바꾼다(번들이 자기 allocator를 들고 다니므로 deinit이 창을 옮겨도 균형).

**옵션 C — Surface는 Term에 두고 heap-pin `*Term`을 창 간 재부모화(대안, 미채택).** `Term`이 이미 heap-pin이라, cross-window 이동을 "Term을 파괴/재생성"이 아니라 "`*Term` 포인터를 창 A 트리에서 떼어 창 B 트리에 붙이기"로 하면 주소가 안 바뀌어 reader 바인딩이 그대로 유효하다. **장점**: Surface 값→포인터 churn·30-사이트 `&` 제거·번들 타입이 전부 불필요(훨씬 적은 churn). **단점(미채택 사유)**: (1) web surface로 **일반화 안 됨** — web surface는 "Surface를 든 Term"이 아니라 registry-owned handle이라, A의 번들 모델이 terminal/web을 통합하는 반면 C는 terminal 전용 경로가 된다(Phase 4/M6에서 별도 메커니즘 필요). (2) **소유와 배치가 Term에 계속 엉킨다** — §3의 분리(WindowGraph=배치, registry=소유)에 어긋난다. (3) Term의 창-specific 상태(git 캐시는 특정 cwd 기준, `rt.pump`는 소스 창 runtime 바인딩)를 함께 옮겨 per-move fixup이 오히려 늘 수 있다. **결론**: churn은 A가 크지만 A를 **전용 no-behavior-change 슬라이스(M3a)로 격리**하면 M2b와 동형의 디딤돌이 되고, 장기 구조(web 통합·소유/배치 분리)가 A로만 닫힌다. **A 채택, C는 A의 리스크가 실측에서 감당 불가로 판명될 때의 후퇴 경로로 문서화**.

### 8A.2 라우팅 앱-전역화 + AppRuntime coordinator (문제 1의 배치 층)

영속 host의 실행 중 reconnect도 이 주소 안정성 계약을 깨지 않는다. Window tree나
Term/Surface/`surface_id`/routing link를 교체하지 않고, heap-pin된 `RemoteRuntime` stable shell 내부의 generation bundle과
stable `HostAdapter`의 Client generation만 prepare/publish/retire한다. `Surface.remote`는 stable proxy를 가리키고 한
render borrow 동안 exact screen generation을 고정하므로 lock과 unlock 사이 교체가 없다. 따라서 cross-window 이동과
reconnect가 겹쳐도 배치 transaction은 기존 Surface만 옮긴다. per-host reconnect 정책/job은 앱 전역
`SessionHostCoordinator`가, canonical runtime membership과 실행 adapter는 `RemoteTermBackend`가 소유한다. Window별
reconnect budget이나 두 번째 global Surface/binding registry는 만들지 않는다. 상세 수명 계약은
[영속 터미널 세션 호스트](persistent-session-host.md#실행-중-connection-invalidation과-재연결)가 소유한다.

M3b 이전에는 `SurfaceRuntime`이 per-window였지만 현재는 앱 전역 `AppRuntime.routing`이 모든 Window의 link를 소유한다.
cross-window 이동 후 목적지 창의 메인 스레드는 이 같은 표를 조회하므로 surface 이동 때 routing을 바꾸지 않는다.

- `AppRuntime`은 `{registry, SurfaceIdAllocator, 앱 전역 SurfaceRuntime}`을 소유한다. reader는 interactive 모드에서 core에
  직접 쓰므로 routing 승격과 무관하고, per-Term pump도 같은 앱 전역 runtime에 바인딩된다.

**레이어**: AppRuntime은 핸들 수명을 직접 들되(L4) 이동 가부·drop target·정규화는 L2 순수 함수를 호출한다(§3 배치 규칙 — 정책과 플랫폼 핸들을 한 god object에 안 섞음).

### 8A.3 이동 이벤트 원자 트랜잭션 + control-plane 구독 재평가 (문제 4, §13 확정)

cross-window move는 AppRuntime가 **한 메인-스레드 트랜잭션**으로 원자 수행한다(§6):

0. **입력 owner 2-phase preflight**: workspace move는 최종 active owner가 바뀌는 source/destination의 terminal
   preedit을 각 원 surface ordered queue에 확정할 capacity와 moved queue remainder를 destination allocator로 옮길
   buffer/map capacity부터 모두 예약한다. 어느 admission/transfer preflight라도 실패하면 어느
   overlay·pin·queue·dock/layout도 바꾸지 않고 종료한다. 두 예약이 모두 성공한 뒤에만 양쪽 commit/take와 tree
   surgery를 진행한다. same-window는 active owner가 실제로 바뀔 때만, window merge는 source owner만 바뀌므로 source만
   이 gate를 거친다.
1. **라이브 트리 수술**: 소스 `AppSession` 트리(`SplitTree(*Pane)`·`tabs`)에서 대상(surface/pane/workspace 서브트리)을 떼어 목적지 트리에 붙이고, 양쪽 `surface_ptrs`/`app_window.tabs`/focus/empty-source 정리를 한다. registry·라우팅은 안 건드린다(surface_id 불변).
2. **그룹 정규화**(workspace 이동일 때 — 8A.4).
3. **control-plane 구독 scope 재평가**(같은 트랜잭션): `metadata:window` 구독은 **창에 바인딩**(개별 surface가 아니라)이므로 **유지**하고, 옮겨진 surface에 대해 소스-창 구독자에게 `session.movedOut`, 목적지-창 구독자에게 `session.movedIn`(= membership-changed notification)을 방출한다. **`closed`/`removed`가 아니다**(surface는 살아 있음). `metadata:self` 구독은 surface_id가 불변이라 영향 없고 응답 메타의 `{window_id, window_token, window_kind}`만 갱신된다. lazy 재평가면 옛-창 구독자가 떠난 surface 이벤트를 계속 받거나 새 창 surface를 엿보므로, 이 재평가를 **트랜잭션 경계 안에서 동기** 수행한다.
4. **trust boundary cap 재평가**(8A.5).

**[control-plane.md] §13 열린 질문 확정**: "surface가 구독 window를 떠날 때 구독 유지/해제/removed 중 무엇인가" → **구독 유지 + `session.movedOut`/`movedIn` membership-changed notification**(neither 해제 nor removed). 근거: window-scope 구독은 window에 거는 것이라 surface가 떠나도 구독 자체는 그 window의 남은 surface를 계속 봐야 하고, `removed`는 surface 종료를 뜻해 살아 있는 이동과 의미가 다르며, silent drop은 클라이언트(세션 리스트 UI 등)가 membership 변화를 못 봐 불충분하기 때문이다. 이벤트 어휘: `session.movedOut{surface_id, from_window, to_window}`·`session.movedIn{surface_id, from_window, to_window}`. **이름·params는 M3d-1에서 확정·구현**(`src/session/surface_move.zig` — `moved_out_method`/`moved_in_method` 상수 + `SurfaceMovedEvent` + `serializeMovedEvent`가 control_plane notification으로 직렬화, red→green 테스트로 왕복 고정). cross-window(from≠to)일 때만 옮겨진 surface마다 movedOut+movedIn 두 개를 방출한다(같은 창 내부 이동은 membership 불변 → 무방출).

### 8A.4 그룹 정규화 §4 (a)~(d)의 L2 리프트 결정 (문제 3)

§4/§8 M1이 "M3이 `inheritGroupMarker`의 L2 리프트 여부를 결정"이라 미룬 것을 **확정**한다. 코드 실측(app_session.zig): `inheritGroupMarker(from)`(5715)은 인접 tab 슬라이스만 읽고/쓰는 **거의 순수** 연산(할당·surface·registry·`sidebar_drag_preview` 미참조)이라 **깔끔히 L2-liftable**. `normalizePinnedFromGroups()`(5310)는 `sidebar_drag_preview` 게이트 + `tabs` + `effectiveDepthAt`만 참조라, `effectiveDepthAt`을 함께 리프트하고 **drag 게이트를 L4 호출 경계에 남기면** L2-liftable.

**결정: L2로 리프트한다(M3c 구현 완료).** `inheritGroupMarker`(마커 승계)·`normalizePinnedFromGroups`(핀 캐시 재동기)·`effectiveDepthAt`(위치 파생 depth)를 `src/session/group_normalize.zig`에 **generic over `*T` 순수 함수**로 올렸다(+ 전이 위생 `clearStaleLocalPins`와 그 의존 `enclosingGroupMarkerIndex`도 함께 — 이 5개가 정규화 코어 프리미티브다). `T`는 그룹 필드를 든 노드(L4 `session_model.Tab`, L2 `window_graph.WorkspaceMeta`)라 두 호출처가 `[]*Tab`/`[]*WorkspaceMeta`를 그대로 넘긴다. `WindowGraph.moveWorkspace`가 이를 호출해 M1 pass-through를 실제 정규화로 전환하고, L4 `app_session`의 다섯 메서드는 **본문을 L2 위임으로 교체**해 `closeTab`/`removeFromGroupForTab`이 자동으로 같은 코어를 재사용한다(재구현·shim 금지 — [[full-removal-no-legacy-shims]]). drag-preview 게이트는 L4 `normalizePinnedFromGroups` wrapper의 `sidebar_drag_preview != null` early return으로 유지(순수 코어엔 없음). `WorkspaceMeta`는 승계·depth 파생에 필요한 `group_collapsed`·`group_depth`·`group_color`를 추가로 미러한다(M1의 4필드로는 inherit/effectiveDepthAt에 부족).

**red test로 §4 케이스 (a)~(d)를 고정**(`window_graph.zig` — M3c, 실측 확인한 뉘앙스 포함):
- **(a) 그룹 멤버 이동 = 암묵 이탈 + 소스 재정규화**: 소속이 tab-순서 파생이라 소스에서 빼면 재-파생되고, 소스 정리 = `normalizePinnedFromGroups` + `clearStaleLocalPins`(= `removeFromGroupForTab`이 도는 것). red test는 잔존 그룹의 sandwich desync 멤버가 마커 pin으로 치유됨을 단언.
- **(b) `group_start` 마커 이동 = 소스 마커 승계(그룹 잔존, 마지막 멤버면 소멸) + 이동분은 목적지 최상위**: `inheritGroupMarker`가 `closeTab`·`removeFromGroupForTab`과 **동형**으로 공유. `false` 반환(다음 카드 없음·다른 핀 리전·top_level leaf) → 그룹 소멸(그래프는 문자열 borrowed라 free 안 하고 이동분 `group_start:=null`). 이동분은 목적지에서 마커 아닌 최상위 카드(group_start·collapsed·color·depth 기본값 복귀).
- **(c) 전역 `pinned` workspace 이동 = 목적지 창의 핀 리전 정책("고정 요소 흡수 불가")**: **그룹 미소속 최상위 pinned 카드**(`enclosingGroupMarkerIndex == null`)는 pinned 유지 + `top_level:=true`로 목적지 그룹에 흡수 안 됨. 핀 리전 내 **프리픽스 위치** 안착은 라이브 트리/M3d 몫(그래프는 라이브 미러가 아니라 순수 오라클+직렬화 포맷 — §8A.6이라 append + 플래그 정규화만).
- **(d) `local_pinned`/`top_level` 이탈 정규화 — 확정**: `local_pinned:=false`(명시 리셋, `clearStaleLocalPins` 대칭)·**`top_level:=true`(명시 set — 확정)**·그룹 멤버(마커 포함, `enclosingGroupMarkerIndex != null`)였으면 `pinned:=false`(§12.7 보강4 unpin, 그룹 고정은 소스 잔존 그룹에 남음). **`top_level` 확정 근거(red test)**: L4 `removeFromGroupForTab`은 같은-창이라 카드를 "리전 첫 마커 앞"으로 **재배치**해 top-level을 위치-암묵으로 만들지만(플래그는 안 지움), cross-window 이동은 목적지 위치 맥락이 없고 `WindowGraph.moveWorkspace`가 **append-to-end**라 이동분이 목적지 **마지막 그룹 뒤**에 붙는다 — 위치-암묵 top-level이 성립 안 하고(위치 파생상 그 그룹에 흡수) 서브파티션 break 플래그가 **필수**다. 그래서 §8A.4 초안이 남겨둔 "재배치-암묵/명시 false" 두 옵션이 아니라 **명시 `top_level:=true`**가 정답이고(§14.9 "고정 탭은 top_level 강제"와도 정합), red test가 목적지에서 `enclosingGroupMarkerIndex(dest, moved) == null`(그룹 밖)로 이를 못박는다.

### 8A.5 trust boundary cap 재평가 (문제 5)

surface-scope cap(`read-output`/`write`)이 이동 중 generation 불변으로 유지되면 저신뢰 창에서 새어나간 nonce가 고신뢰 창으로 따라간다(§6·[control-plane-security.md] §8.5). **정직한 v1 범위**: v1의 유일한 trust boundary는 quick↔normal(`window_kind`)인데 **quick은 이동 단위·대상에서 제외**(§4)라 **지원되는 v1 이동 중 trust boundary를 넘는 경로는 없다**. 따라서 이 문제의 v1 산출물은 **가드 + 훅**이다:

- AppRuntime 이동 트랜잭션(8A.3 4단계)이 `source_window.trust_class`와 `dest_window.trust_class`를 비교한다.
- 다르면 그 surface의 outstanding `read-output`/`write` cap을 **revoke**(cap 저장소에 `revoked` 표시 — §8.5가 dispatch·chunk 경계·outbound 큐에서 이미 재검증·purge)하고, **re-mint는 안 한다**(fresh grant UX 필요). `metadata:self`는 OS-관측 origin이라 per-request 재증명되므로 생존.
- v1에선 도달 불가(quick 제외)이므로, **가상 cross-boundary 이동이 revoke를 트리거하는 단위 테스트**로 훅을 고정하되 UX로는 도달하지 않는다. quick→normal 추출이나 web trust-class 같은 미래 이동 단위가 생기면 이 훅이 이미 자리에 있다. "이동이 이전에 새어나간 capability를 격리하지 못한다"는 §6의 명시 한계는 유지.

### 8A.6 직렬화 권위 → WindowGraph 포맷 (문제 2 — M3 종료 gate)

**현실**(실측): 저장 권위는 두 곳이다 — 각 `AppSession` 라이브 트리(내용, `captureWorkspaceWindow`:12882)와 Swift `MaruAppHost.windows` 배열(창 집합·순서·"index 0 = primary"). 포맷 `maru.workspace.v1`(workspace.zig)엔 **window_id·window_kind가 없다**(M3e는 활성 창 focus만 옵션 필드 `active-window`로 더하고 window_id/window_kind는 dead 필드라 미도입 — 아래 델타). 파싱 권위는 Zig에 집중(app_host_abi, Swift는 `window ` 경계를 안 나눔). 파싱 실패 = 조용한 기본-창 폴백, 부분 실패 = 비-모달 notice.

**설계 결정**: WindowGraph는 **라이브 미러가 아니다**. 두 역할만 한다 — (1) **순수 move 알고리즘 + 테스트 오라클**(M1, 이미 존재; M3c가 그룹 정규화로 확장), (2) **직렬화 포맷**. 라이브 배치 권위는 per-window 트리로 유지하고(분할 기하·focus·그룹을 든다), 저장은 각 세션이 자기 창 블록을 내고 Swift가 헤더 하나로 모은다(기존 R5). 근거: 매 tick 라이브 그래프를 동기화하는 복잡도를 피하고, `window_graph.zig` 헤더가 명시한 "split 기하는 session_model.PaneTree가 계속 소유, AppRuntime가 라이브 모델 쪽에 유지"와 정합. **M3e 정정(사용자 리뷰)**: 저장을 "AppRuntime가 전 창을 하나의 WindowGraph-형태 v2 문서로 조립"으로 바꿀 필요는 없었다 — 기존 R5(창별 블록 + `maru.workspace.v1` 헤더 하나)로 배치가 이미 재시작 후 유지되므로, v2 graph 문서 조립·스키마 브레이크는 **과설계라 기각**한다(아래 델타).

**M3e의 구체 델타 (구현 — v2 하드 브레이크 기각)**: 드리프트 gate에서 확인됐듯 **cross-window 이동 배치는 이미 v1으로 재시작 후 유지된다**(각 `AppSession`이 자기 라이브 트리를 창별 `window …` 블록으로 저장·복원 — M3d-2 라이브 수술 결과가 그대로 굳는다). 따라서 M3 종료 gate의 실질 델타는 **활성(key) 창 보존** 하나뿐이고, 이를 위해 스키마를 깨지 않는다:
- **헤더 `maru.workspace.v1` 유지**(NO `.v2`·NO bump). `Window`에 옵션 additive 필드 `active-window`만 더한다 — `group-collapsed`/`group-color`와 **동일한 옵션-키 패턴**: `active=false`면 writer가 키를 생략(round-trip 고정점·옛 파일 flat 동일), reader는 없으면 false, 옛 리더가 미지 키 `active-window`를 skip(forward-compat). **완전 하위호환**(옛 파일 = 무마커 정상 로드 = 현행 동작, 버림·모달·크래시 없음). `window_id`/`window_kind`는 **dead 필드라 미도입**(라이브 배치 권위가 per-window 트리라 문서 레벨 graph 메타가 불필요 — 위 "라이브 미러 금지"와 정합).
- **capture/복원**: 기존 `captureWorkspaceWindow`/`serializeWorkspaceWindow`에 `is_active` 인자만 더하고(Swift `window.isKeyWindow` 전달), ABI `serialize_workspace(…, is_active)` + getter `workspace_active_window(session, text) i64`(활성 index, 없으면 -1)를 추가. Swift 복원 loop가 그 index의 창을 `makeKeyAndOrderFront`한다(없으면 무동작 = 현행). Term당 새 surface_id/generation 0(현행) 유지.
- **종료 gate**: `active-window` round-trip·생략 고정점·**옛 v1 파일 하위호환**(마커 없이 정상 로드) 테스트(`workspace.zig`) + "이동 후 재시작이 배치와 활성 창을 살림" 실측.

**M3f의 구체 델타 (구현 — 창 geometry 복원)**: M3e와 **동일한 옵션 additive 패턴**을 재사용해 재시작 시 창이 종료 전 위치·크기·모니터에 뜨게 한다. 활성 창 focus(M3e)에 이어 두 번째 유용 델타이고, 역시 스키마를 안 깬다:
- **헤더 `maru.workspace.v1` 유지**(NO bump·NO v2·NO 마이그레이션). `Window`에 옵션 additive 필드 `frame: ?Frame`(`Frame{x,y,w,h: i32}`, 전역 스크린 좌표 점)을 더해 window 라인에 `win-x/y/w/h` 넷을 낸다 — `active-window`와 **동일 옵션-키 패턴**이되 **all-or-none**: frame=null이면 writer가 넷을 다 생략(round-trip 고정점·옛 파일 flat 동일), reader는 넷이 **다 있어야** frame이고 하나라도 없으면 null(옛 파일·부분 필드 = cascade 기본 위치). 넷 다 있는데 값이 깨졌으면 BadLine(부재≠손상). x/y는 음수 가능(보조 모니터)이라 signed `getInt`. **완전 하위호환**(옛 파일·M3e만 있는 중간 버전 파일 모두 win-* 없이 정상 로드 = cascade).
- **좌표계·모니터**: NSWindow.frame은 **전역 스크린 좌표(bottom-left 원점)**라 절대 frame이 **어느 모니터인지 자동 인코딩**한다(display ID 불필요 — 각 모니터가 전역 좌표 영역을 차지). 저장 단위는 점(HiDPI backing scale 무관).
- **복원 clamp(항상 화면 안)**: 저장 frame과 **가장 많이 겹치는** `NSScreen`을 고르고(최대 겹침 = 그 창이 있던 모니터; 안 겹치면 main 폴백), **그 화면 `visibleFrame` 안으로 frame을 clamp**한다(화면보다 크면 축소·가장자리 넘으면 이동 → 창이 완전히 화면 안·타이틀바 잡힘, pre-M3f 불변식 복원). 이미 화면 안이면 그대로(크기 보존). Swift `clampFrameToVisibleScreens`. `constrainFrameRect` 참고하되 명시 clamp. **정정(6차 리뷰)**: 예전 "가시 면적 임계 이상이면 저장 frame 그대로 통과"는 모니터 배치 변경 시 창을 거의 화면 밖(구석만 걸침)으로 복원해 드래그 불가였다 — "겹치면 그대로"가 아니라 "항상 사용 가능하게 clamp"로 강화.
- **전체화면 저장 스킵**: 저장 시 native 전체화면(`styleMask.contains(.fullScreen)`) 창은 frame이 화면 전체라, 저장하면 복원 시 타이틀바 달린 거대 windowed 창(회귀)이 된다 → 전체화면이면 frame 저장을 스킵(has_frame=0 → cascade). zoomed는 유효 windowed 크기라 저장. 전체화면 상태 복원(마커+`toggleFullScreen`)은 timing 위험으로 미도입(최소 안전). 저장 시 `Int32(Double)` trapping 변환은 비유한이면 그 창 frame 스킵·범위초과 clamp(종료 경로 크래시=전체 상태 소실 방지).
- **capture/복원**: `captureWorkspaceWindow`/`serializeWorkspaceWindow`에 `frame: ?Frame` 인자를 더하고, ABI `serialize_workspace(…, has_frame, frame_x/y/w/h)` + 창별 getter `workspace_window_frame(session, text, window_index, *out_x/y/w/h) i32`(1=있음/0=없음/-1=parse실패)를 추가. Swift `saveWorkspace`가 `window.frame`→점 정수로 저장(전체화면·비유한 스킵), `restoreWorkspace`/`createTerminalWindow`가 창마다 getter→clamp→`setFrame`(없으면 현행 cascade 유지). primary(창0)·추가 창 둘 다. **활성 창 focus(M3e)는 블록 인덱스→실제 창 매핑으로 착지**한다(라이브 `windows` 배열에 직접 인덱싱하지 않음 — 중간 창 spawn 실패로 배열이 compact돼 블록 인덱스와 발산하는 것을 방지). 단일 출처 저장 포맷·clamp 상세는 [workspace-restore.md](workspace-restore.md) "창 geometry 복원(M3f)".
- **종료 gate**: `win-x/y/w/h` round-trip(음수 포함)·생략 고정점·**옛 v1 파일 하위호환**(win-* 없이 정상 로드)·부분 필드 방어·값 손상 BadLine 테스트(`workspace.zig`) + "창 이동/리사이즈/다른 모니터 → ⌘Q → 재실행이 위치·크기·모니터를 살림" GUI 손 테스트.

### 8A.7 드래그 detach/reattach UX (문제 6 — M4/M5가 M3 이동 API 위에 얹음)

**설계 원칙**: 정책은 Zig(AppRuntime/L2), 운반만 AppKit(§1·§5). 드래그는 **M3d의 command 이동 API를 그대로 소비**한다 — 드래그는 "어느 이동을 호출할지"를 포인터로 고르는 얇은 UX 층일 뿐, 이동 로직을 재구현하지 않는다.

- **시작 affordance**(§4 표, OS 타이틀바 아님): surface tab·pane grip(pane tabbar 좌측)·workspace card. 같은-창 드래그는 기존 Zig hit-test 경로(M4가 WindowGraph move API로 정리), 다른 창/창 밖은 AppKit `NSDraggingSession`(M5).
- **고스트 피드백**: 드래그 payload(surface/pane/workspace 판정은 Zig)의 floating preview를 AppKit drag image로. hover는 매 frame 대량 snapshot 금지, **target 변경 시에만** highlight 갱신(§9 성능 gate).
- **drop target 계산**: Zig가 유효성·target(같은/다른 pane tabbar, pane 본문 split drop-zone, sidebar, 창 밖 빈 공간)·의미를 결정하고, AppKit은 좌표 변환·NSWindow 생성/focus·(M6) WKWebView reparent만. drop이 확정되면 AppRuntime의 해당 move 트랜잭션(8A.3) 호출.
- **modifier 충돌**(§4 마지막 줄): 같은 sidebar 안 Cmd=그룹 중첩 제스처와 cross-window 드래그가 안 충돌하게 M5에서 modifier 의미 재확인(기존 결정 유지).
- **GUI 손 테스트 슬라이스**: M4(same-window drag 재연결), M5(cross-window native drag). 스크린샷 하니스로 자동화 못 하는 AppKit drag lifecycle은 spike → 수동 artifact → 최소 회귀([control-plane-implementation.md] §11 TDD gate).

### 8A.8 M3 하위 슬라이스 분해 (M3a~M3e — 의존·관찰가능·리스크·GUI 손 테스트·종료 gate)

각 슬라이스는 M2b처럼 "한 디딤돌"이다(하나의 관찰 가능한 동작 또는 하나의 불변식). 순서: **M3a → M3b → M3d(= M3d-1 헤드리스 트랜잭션 코어 → M3d-2 라이브 배선+Swift) → M3e**, **M3c는 순수 L2라 병렬/선행 가능**. M3d는 "살아 있는 surface의 실제 트리 수술 + Swift 창 수명"이라 한 슬라이스로 하기엔 커, **M3d-1(헤드리스 Zig 코어 — 순수 오라클 위 트랜잭션·정책·무재시작 불변식)**과 **M3d-2(라이브 두-창 트리 수술 + 양-창 렌더 리프레시 + Swift NSWindow 생성/focus/close·command/드래그)**로 다시 쪼갠다 — M3a가 M3의 대수술을 격리한 것과 동형으로, 가장 위험한 라이브 창 수술을 Swift 소비자와 함께 착지시켜(half-integration 방지·`macos-app` 실측 가능) 검증한다. **M3d-2도 다시 쪼갠다**: **M3d-2a(헤드리스 Zig 라이브 수술 + ABI — Swift/GUI 없음)**와 **M3d-2b(Swift NSWindow 생성/focus/close·command/드래그)**. M3d-2a는 다시 **M3d-2a-i(비-그룹·비-pinned workspace/window 라이브 이동)**·**M3d-2a-ii(그룹 마커 문자열 free-on-false·pinned 정규화)**로 나뉘어, 가장 위험한 두-`AppSession` 트리 재부모화를 Swift 창 수명과 **분리해** 헤드리스로 먼저 검증한다(두 controlled_smoke 세션이 `app_runtime` 모듈-var를 공유하므로 registry/routing 무재시작을 fake 없이 실측).

| 슬라이스 | 무엇 | 의존 | 관찰가능/불변식 | 리스크 | GUI 손 테스트 | 종료 gate |
|---|---|---|---|---|---|---|
| **M3a Surface 소유권 lift** | `LiveSurfaceRegistry(LivePtySession)`→`(LiveSurface 번들)`; `Term.surface` 값→`*Surface`; createTerm/destroyTerm/deinit 2-pass/reap 재배선; 30 `&term.surface`→`term.surface`; owned-string 해제 번들 이관 | M2b(완료) | **사용자 가시 변화 0**(순수 소유 이전). reader가 여전히 안정 `&slot.surface.core` 바인딩; 단일·멀티창 무변경; 스크롤백 보존·재시작 0 | **높음**(reader 불변식·teardown 순서·140-사이트 churn·allocator 페어링) | **예** — 타이핑·⌘D split·⌘T 탭·⌘W 닫기·focus 전환·resize·⌘Q; 크래시/회귀 0, 스크롤백 보존 | 전체 테스트 green + `zig build macos-app` 실행 + `/code-review max` |
| **M3b AppRuntime + 앱-전역 라우팅** | `SurfaceRuntime` per-window→앱-전역; `AppRuntime`(L4)가 {registry, SurfaceIdAllocator, routing} 소유(모듈-로컬 `var` 정식화); pump 재바인딩 | M3a | **변화 0**. 입력/resize/명령이 surface_id로 한 표를 통해 라우팅; 두 창은 여전히 자기 surface만 참조(격리) | 중(공유 표 aliasing·pump 재바인딩) | **예** — 창 2개서 각 입력/resize/닫기, 격리 확인 | 멀티창 smoke green + `/code-review max` |
| **M3c 그룹 정규화 L2 리프트 + move 알고리즘 (구현)** | `inheritGroupMarker`·`normalizePinnedFromGroups`·`effectiveDepthAt`(+`clearStaleLocalPins`·`enclosingGroupMarkerIndex`) → `src/session/group_normalize.zig` generic 순수화; `WorkspaceMeta`에 group_collapsed/depth/color 미러; `moveWorkspace`가 정규화 호출; §4 (a)~(d) red test; L4 `app_session` 5메서드 본문 L2 위임(closeTab/removeFromGroup 자동 재사용) | M1(완료) | 순수 모델 정확성(승계·핀-정규화·(d) `top_level:=true` 확정). **병렬 가능** | 중(그룹 로직 뉘앙스·(d)·pinned-unpin) | 아니오(순수 L2 테스트) | red→green non-vacuous ✅ + boundary green ✅ + 기존 sidebar 테스트 green ✅ |
| **M3d-1 이동-ops 트랜잭션 코어 (헤드리스, 구현)** | `src/session/surface_move.zig`(L2) = cross-window 이동 **원자 트랜잭션**을 순수 오라클 `WindowGraph` 위에서: ① 트리 수술(moveSurface/movePane/moveWorkspace/mergeWindow) ② M3c 그룹 정규화(moveWorkspace가 적용) ③ 구독 재평가(`session.movedOut`/`movedIn` membership-changed 이벤트 + control_plane 직렬화) ④ trust boundary cap 재평가(§8A.5 guard+hook) + 빈 source auto-close 판정 → `MoveOutcome`. AppRuntime이 `cross_window_move`로 re-export(coordinator seam). **registry/routing 무변경**(무재시작) | M3a·M3b·M3c | 순수 정확성 + **무재시작 불변식**(fake registry로 이동 전후 동일 포인터·스크롤백·재시작 0); 트리 정합·빈 창 판정·M3c 정규화·movedOut/movedIn·trust cap·**원자성**(OOM 시 source 불변·outcome 무생성) | 중(순수 오라클 + 정책; 라이브 트리 아님) | 아니오(헤드리스 L2 테스트 — fake 2-window) | red→green non-vacuous ✅ + 전체 test·boundary·fmt·macos-app-build·smoke green ✅ |
| **M3d-2a-i 라이브 workspace/window 이동 (헤드리스 Zig + ABI, 구현)** | **라이브 수술 = 트리 위상 변경의 단일 구현**(§1.3 재사용 확정). 신설 `detachTabForMove`(closeTab tail을 destroy 없이 재사용 → `*Tab` 반환)·`adoptTab`(createTab tail을 createPane 없이 재사용, 위치 insert + §8A.4(d) top_level:=true·local_pinned:=false 정규화 + dst cell metric resize)를 조합해 `moveWorkspaceToSession(src,dst,idx)`·`mergeSessionInto(src,dst)`를 만든다. `surface_move.zig`(+`app_runtime.cross_window_move`)에서 **정책 어휘만 재사용**(`MoveOutcome`·`crossesTrustBoundary`·`membershipChangeEvents`/`serializeMovedEvent`·`WindowKind`) — **매 이동 transient `WindowGraph`를 조립하지 않고**(§8A.6 라이브 미러 금지), outcome 필드를 라이브 수술 결과에서 **직접** 채운다(cross_window=src!=dst·source_window_closed=detach 후 src 0탭·moved_surfaces=서브트리 수집·revoke_caps=cross_window && crossesTrustBoundary). 빈 source는 `ended_seen:=true` **직접 latch**(§1.6 — `latchSessionClose`는 activeSurface 접근이라 0탭 UB, 실제 close는 M3d-2b). per-link `trace_recorder` 재지정(`setSurfaceTraceRecorder`/신설 `clearSurfaceTraceRecorder`). ABI `move_workspace_to`·`merge_window` + `MoveResult{status,source_window_closed,moved_count}`(Swift 미호출 — plan-link). **registry/routing 무변경**(무재시작) | M3d-1 | 두 `AppSession` 트리 재부모화가 surface를 재시작 안 함(동일 `*LiveSurface`·live_pty 포인터·스크롤백·재시작 0); 양-창 정합(src 빠짐/dst 추가·surface_ptrs==app_window.tabs); 빈 source latch; outcome | **높음**(양 트리 수술·teardown 순서·빈 source UB·양-창 리프레시) | 아니오(헤드리스 — 두 controlled_smoke 세션) | red→green non-vacuous + 전체 test·boundary·fmt·macos-app-build·swift-check·smoke green |
| **M3d-2a-ii 그룹·pinned workspace 라이브 이동** | 그룹 마커 workspace 이동(마커 승계 false → 문자열 free 소유 이전)·pinned workspace 이동(핀 리전 정규화·목적지 흡수 불가) | M3d-2a-i | 그룹 잔존/소멸·pin 리전 정확 | 중(문자열 소유·핀 정규화) | 아니오(헤드리스) | red→green + gate green |
| **M3d-2b Swift 창 수명 + 드래그 (범위 밖 — 손 테스트)** | M3d-2a 이동 API에 Swift 배선: NSWindow **생성**(창 밖 drop)·**focus** 착지·빈 source **close**(`source_window_closed` 신호 → 직접 teardown+`close`; **`request_window_close`가 아니다** — 그건 라이브 창의 빨간버튼/⌘W 확인 게이트라 `activeSurface`를 만져 emptied source(0탭)에서 UB, `AppSession.close()`는 `active()` 가드로 0탭 안전); palette/menu action; 드래그. control-plane 라이브 구독 재평가(movedOut/movedIn dispatch). **부분 착지(M3d-2b-menu, 구현)**: menu 배선 두 갈래 — ① Window 메뉴의 동적 "Merge Window Into ▸ <창>"(menuNeedsUpdate로 대상 창 열거, quick 제외)이 키 창의 **모든** 워크스페이스를 대상 창으로 `merge_window`한 뒤 dst focus·비워진 src `closeWindowOrQuit`. ② "Move Workspace to Window ▸ <창>"(같은 대상 열거)이 키 창의 **활성** 워크스페이스 하나만 `move_workspace_to`한다 — read-only ABI getter `active_workspace_index`(session→`app_window.active_tab`, sentinel=UINT32_MAX면 무동작; take_bell류 u32)를 더해 Swift가 src 활성 index를 읽고, dst focus 뒤 `source_window_closed`이면 src close·아니면 src 유지+repaint(활성 재선택은 Zig가 함). `.h`에 `MoveResult`·getter 포함 세 함수·`MoveFailed=10` 미러 + ABI 계약 테스트. **미착지**: "새 창으로"·NSWindow 드래그(M4/M5)·구독 fan-out(Track 3) | M3d-2a | cross-window 이동이 command/드래그로 동작; focus 착지·empty-source 창 close | **높음**(창 수명·control-plane 라이브 구독·AppKit 드래그) | **예** — 메뉴로 창 간 window merge; dst focus·소스 창 auto-close(무재시작·스크롤백 보존) | macos-app 실측 + `/code-review max` |
| **M3e 활성 창 보존 (v1 호환 `active-window` — 구현)** | 배치는 이미 v1(창별 블록)으로 재시작 유지 — 델타는 활성 창만. `maru.workspace.v1` **헤더 유지**, `Window.active` 옵션 additive 필드(group-collapsed 패턴: false=생략) + `activeWindowIndex`; `captureWorkspaceWindow`/`serializeWorkspaceWindow(is_active)`·ABI `serialize_workspace(…,is_active)`·getter `workspace_active_window`; Swift `isKeyWindow`→저장, 복원 후 `makeKeyAndOrderFront`. **v2·window_id·window_kind 미도입(사용자 리뷰 기각·과설계)** | M3d-2 | **활성 창이 재시작 후 focus**; 배치 유지 회귀 0; **옛 v1 파일 무문제 하위호환** | 낮음(옵션 additive 필드·하위호환) | **예** — 창 간 이동 후 특정 창 활성화→⌘Q·재실행→그 창이 focus·옛 파일 무문제 | round-trip·생략 고정점·하위호환 테스트 + move-then-restart 실측 |
| **M3f 창 geometry 복원 (v1 호환 `win-x/y/w/h` — 구현)** | M3e와 동일 옵션 additive 패턴 재사용 — 재시작 시 창을 종료 전 위치·크기·모니터에. `maru.workspace.v1` **헤더 유지**, `Window.frame: ?Frame`(전역 스크린 좌표 점, all-or-none: null=넷 다 생략) + `windowFrame`·signed `getInt`; `captureWorkspaceWindow`/`serializeWorkspaceWindow(…, frame)`·ABI `serialize_workspace(…, has_frame, frame_x/y/w/h)`·창별 getter `workspace_window_frame(…, window_index, *out_x/y/w/h) i32`(1/0/-1); Swift `saveWorkspace`가 `window.frame`→점 정수, `restoreWorkspace`/`createTerminalWindow`가 창마다 getter→`clampFrameToVisibleScreens`→`setFrame`(없으면 cascade). **전역 좌표가 모니터 자동 인코딩(display ID 불필요)·clamp로 모니터 분리 방어·v2 미도입** | M3e | **위치·크기·모니터 재시작 후 복원**; 배치·활성 창 회귀 0; **옛 v1·M3e-only 파일 무문제 하위호환**(win-* 없이 cascade) | 낮음(옵션 additive 필드·하위호환; clamp만 멀티모니터 주의) | **예** — 창 이동/리사이즈/다른 모니터로→⌘Q·재실행→그 위치·크기·모니터·옛 파일 무문제 | round-trip(음수)·생략 고정점·하위호환·부분 필드·값 손상 테스트 + move/resize-then-restart 실측 |

M3 완료 후 **M4~M6은 §8 그대로**(same-window drag 재연결·cross-window native drag·web reparent)이며, 전부 M3d의 이동 API(M3d-1 트랜잭션 코어를 M3d-2가 라이브 배선한 것)를 소비한다(8A.7). M4/M5가 문제 6(드래그 UX)의 GUI 손 테스트 슬라이스다.

**첫 슬라이스 권장 = M3a.** 이유: (1) M3의 대수술 핵심(Surface 소유권)이고 나머지(M3b~e)가 전부 그 위에 서므로 **가장 큰 리스크를 가장 먼저 격리**한다. (2) 사용자 가시 변화 0인 순수 소유 이전이라 M2b와 **동형의 안전한 디딤돌**이고, red→green + macos-app 실측으로 reader 불변식을 단독 검증할 수 있다. (3) M2a `FakeRuntime` 번들 테스트가 이미 스캐폴드라 red test 표면이 준비돼 있다. **주의**: M3a는 churn이 커 [[stale-build-before-gpu-deepdive]](풀 재빌드)·[[run-macos-app-before-merge]](머지 전 실행)·[[run-fmt-check-before-push]]를 엄수하고, teardown 3사본 동기·allocator 페어링을 /code-review max로 재확인한다.

## 9. 검증

- `WindowGraph` 순수 단위: 모든 move/merge/no-op/focus/empty-source 정책.
- registry 수명: 이동 전후 `surface_id`/generation, PTY reader/pump, TerminalCore scrollback이 유지되는지.
- control-plane: 이동 후 `sessions.list`, `metadata:self`, `metadata:window`, 알림 클릭 라우팅, capability revoke/re-eval.
- workspace restore: multi-window graph round-trip, 하위 포맷 조용한 fallback.
- macOS integration: 새 window 생성, cross-window drop target, source window auto-close, focus/firstResponder.
- IME 구조 원자성: cross-window move의 source/destination admission 성공 시 각 원 surface FIFO로 정확히 한 번
  확정되고, 각 side reservation 및 moved-queue transfer preflight OOM에서는 양쪽 overlay·pin·queue·tab/layout이
  detach 전에 그대로인지. same-window
  active/background와 merge의 destination owner 보존도 분리해 검증한다.
- web panel: WKWebView reparent, bridge trust 유지, untrusted browser panel에 `window.maru` 미주입, IME/focus 복귀.

성능 gate:

- 이동은 surface runtime을 재시작하지 않는다.
- bulk window merge는 frame tick을 오래 점유하면 chunk/yield하되, **chunk 단위는 "workspace"가 아니라 tick 예산 기준 surface/reparent 건수**다. workspace 하나가 web Term(=WKWebView) 수십 개를 가질 수 있어([web-panel.md] §6), "workspace 단위 bounded"는 workspace 수만 bound하고 한 chunk 안 reparent 수십 건(각각 AppKit 레이아웃+컴포지팅+WebKit IPC)이 tick을 넘길 수 있다. tick당 WKWebView reparent ≤ k로 제한한다. 중간 chunk에서 reparent가 실패하면 관측 가능한 부분-완료 상태와 재개/중단 정책을 남긴다.
- drag hover는 매 frame 대량 capture/evaluate/snapshot을 호출하지 않고, target 변경 시에만 highlight를 갱신한다.
