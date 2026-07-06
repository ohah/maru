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
- **사이드바 그룹은 v1에서 이동 단위가 아니다.** workspace card는 단독으로만 창을 이동하고, 이동 시 소속 그룹에서 암묵 이탈한다 — 그룹 소속이 별도 필드가 아니라 탭 순서 파생(`group_start` 마커, [sidebar-groups.md](sidebar-groups.md))이기 때문이다. `group_start` 마커 workspace의 이동은 그룹 해체로 처리하고, 잔여 멤버·핀은 기존 위치 파생·핀 정규화 규칙으로 재정규화한다. 그룹 통째 cross-window 이동과 `local_pinned`/`top_level` 보존 여부는 후속 결정이다. 상세 케이스는 §4, red test는 M1(§8).
- **native drag는 운반만, 정책은 Zig가 소유한다.** AppKit은 cross-window drag lifecycle, 좌표 변환, NSWindow 생성/focus, WKWebView reparent만 맡는다. drop 가능 여부, target 계산, WindowGraph 변경, capability 재평가는 Zig/AppRuntime이 결정한다.

## 2. 현재 코드 기준 영향

현재 macOS host의 `TerminalSurface`는 `window + appSession + metalRenderer`를 함께 들고, `New Window`는 새 `AppSession`을 만든다. 즉 실제 코드는 "한 OS 창 = 한 AppSession = live surface 소유자" 구조다. 같은 창 안에서 Pane을 새 워크스페이스로 분리하거나 기존 워크스페이스에 합치는 기능은 이미 있지만, 그 수술은 한 `AppSession` 내부 트리에서만 일어난다.

따라서 cross-window detach/reattach는 단순 UX 추가가 아니라 소유권 refactor다. 새 코드는 per-window `AppSession`에 live PTY/WKWebView를 가두지 않고, 앱 인스턴스 전역 `AppRuntime`이 live surface를 소유하게 해야 한다.

용어 주의: 이 문서의 "surface"(=`surface_id` 단위)는 pane 안의 terminal/web view **하나**다. 현재 코드의 Swift `TerminalSurface`(창 1개의 per-session 상태)나 기존 ABI `FrameSummary.surface_id`(활성 표면 1개)와 이름이 겹치지만 더 작은 단위이며 같은 것이 아니다. `surface_id`는 그 view마다 앱 전역으로 채번한다.

## 3. 목표 구조

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

레이어 배치([세션 컨트롤 플레인](control-plane.md) §11 코드 배치 게이트와 일치): `SurfaceIdAllocator`, `WindowMembershipSnapshot`, `WindowGraph`와 move/merge·capability 재평가 **정책 판정**은 L2 중립 코드(`src/session/`)에 두고 `app`/`pty`/`platform` import 0을 유지한다. allocator instance와 live membership 수집은 L4 coordinator가 소유한다. `LiveSurfaceRegistry`는 PTY/WKWebView 핸들을 들므로 L4 플랫폼(`src/platform/macos/`)이다. `AppRuntime`은 L4 coordinator로, 핸들 수명은 직접 들되 이동 가부·drop target·capability scope 같은 정책은 L2 함수를 호출해 결정한다 — 정책과 플랫폼 핸들을 한 god object에 섞지 않는다.

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

사이드바 그룹과의 상호작용(§1 결정의 상세): workspace card 이동은 사이드바 그룹 모델([sidebar-groups.md](sidebar-groups.md))과 직접 상호작용한다 — 소속이 탭 순서 파생이라 창을 떠나는 순간 소속·핀 리전이 바뀐다. v1 케이스: (a) 그룹 멤버 이동 = 그룹 암묵 이탈 + source 창 재정규화, (b) `group_start` 마커 이동 = 그룹 해체 + 잔여 멤버 재정규화, (c) 전역 `pinned` workspace 이동 = target 창의 핀 리전 정책("고정 요소 흡수 불가" 포함)을 그대로 따름, (d) `local_pinned`/`top_level`은 이탈 시 의미를 잃으므로 리셋. 같은 sidebar 안 드래그에는 이미 Cmd=그룹 중첩 제스처가 있으므로, cross-window 드래그가 이 제스처와 충돌하지 않게 M5에서 modifier 의미를 재확인한다.

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

`window_token`은 bearer token이 아니며 현재 위치를 설명하는 메타데이터다. control-plane selector는 최소 `{instance_nonce, surface_id, generation}`을 핵심으로 하고, 응답 메타데이터에 현재 `{window_id, window_token, window_kind}`를 싣는다.

## 7. Workspace restore

restore의 단일 출처는 [Workspace Restore 전략](workspace-restore.md)이다. 이 절은 그 문서에 중복 정의하지 않고, 이동성 모델이 요구하는 변경만 적는다(상세 저장/미저장 목록은 거기서 갱신).

- 저장 모델을 단일 창 기준에서 `WindowGraph` 기준(windows, active window, workspace order, pane tree, surface refs)으로 확장한다. **이 확장은 M3의 종료 gate다**(§8) — cross-window 배치가 처음 생기는 단계이므로, "이동은 되는데 재시작하면 사라짐" 상태로 M3를 닫지 않는다.
- live PTY fd·child pid·WKWebView process handle·JS heap snapshot은 계속 저장하지 않는다(기존 정책 유지).
- 복원 시 live surface는 새 generation으로 생성된다. agent session resume처럼 별도 영속 상관키가 있는 항목만 재연결을 시도한다.
- 하위 호환은 없으므로 옛 저장 파일은 workspace-restore.md의 "조용한 기본 창 폴백"을 따른다.

## 8. 구현 순서

이 기능은 full drag UX부터 만들지 않는다. 먼저 command path와 순수 모델을 고정한다.

1. **M0a SurfaceIdAllocator**: 앱 인스턴스 전역 opaque u64 발급, 비재사용, generation mismatch 단위 테스트. 기존 per-session `next_id`는 외부 ID로 노출하지 않는다.
2. **M0b WindowMembershipSnapshot**: full `WindowGraph` 전 2-window+quick membership DTO, `metadata:self/window/all` scope 필터 테스트. `window_kind` 판별자는 현재 코드에 없으므로(quick은 Swift 전용 `quick` 참조·`QuickTerminalPanel`·`chrome_minimal` 플래그로 분산) M0b가 신규 도입한다.
3. **M1 WindowGraph TDD**: `moveSurface`, `movePane`, `moveWorkspace`, `mergeWindow`, no-op/empty-source/focus 보정 단위 테스트. `moveWorkspace`는 사이드바 그룹 상호작용(§4)을 red test로 고정한다: 그룹 멤버 이탈 재정규화, `group_start` 마커 이동=그룹 해체, 전역 `pinned` 이동 시 target 핀 리전 정규화, `local_pinned`/`top_level` 리셋.
4. **M2 LiveSurfaceRegistry 분리**: terminal live runtime을 window 밖 owner로 이동. surface 이동 시 PTY/TerminalCore를 재시작하지 않음을 테스트. web panel state/WKWebView handle은 이 시점에 아직 없으므로 terminal runtime만 옮기고, web surface runtime은 Phase 4 이후 같은 registry에 합류한다.
5. **M3 command 기반 이동**: palette/menu action으로 surface/pane/workspace/window_all 이동. Swift는 window create/focus만 수행. 종료 gate에 workspace restore의 `WindowGraph` 포맷 확장(§7)을 포함한다.
6. **M4 same-window drag 재연결**: 기존 drag 경로가 WindowGraph move API를 쓰게 정리.
7. **M5 cross-window native drag**: AppKit drag session/destination을 붙이고 Zig drop target API에 연결.
8. **M6 web surface reparent**: WKWebView를 destroy/recreate하지 않고 target window/container로 reparent. focus/IME/z-order artifact로 검증.

기존 Phase 계획 영향:

- **Phase 1 영향 있음**: live collector 전에 M0a/M0b가 선행된다. 이 때문에 1c가 단순 fake DTO가 아니라 allocator와 membership scope red test를 포함한다.
- **Phase 2~3 순서 영향 없음**: write/event/stream은 이미 `surface_id + generation`을 쓰므로 Phase 1의 전역 ID 계약을 소비하면 된다. 단 Phase 3의 background 세션 이벤트 소스(3b)는 per-window AppSession 순회 전제라, M1/M2가 먼저 끝나 있으면 AppRuntime graph를 직접 읽어 재배선을 아낀다(권장이지 차단 아님 — [control-plane.md] §7).
- **Phase 4 영향 있음**: WKWebView hosting 전에는 M0 완료를 확인하고 M1/M2가 선행된다. Phase 4가 Phase 1보다 먼저면 M0a/M0b를 먼저 닫는다. M3(command move/merge)까지 Phase 4 전에 끝낼 필요는 없다.
- **Phase 5~7 순서 영향 없음**: bridge, WebDriver adapter, markdown content는 새 ID와 WindowGraph membership을 소비한다. 하위호환 bridge/API adapter를 만들지 않는다.
- **Workspace restore 영향 있음**: 새 graph 포맷을 직접 저장하고, 옛 파일은 조용한 기본 창 폴백으로 둔다. 구버전 reader를 추가하지 않는다.

각 단계는 [세션 컨트롤 플레인](control-plane.md) §11의 Phase 시작 gate와 같은 방식으로, 시작 전에 사용자에게 scope·파일 후보·권한 변화·검증 gate를 설명하고 직전 단계 regression gate를 재실행한다.

## 9. 검증

- `WindowGraph` 순수 단위: 모든 move/merge/no-op/focus/empty-source 정책.
- registry 수명: 이동 전후 `surface_id`/generation, PTY reader/pump, TerminalCore scrollback이 유지되는지.
- control-plane: 이동 후 `sessions.list`, `metadata:self`, `metadata:window`, 알림 클릭 라우팅, capability revoke/re-eval.
- workspace restore: multi-window graph round-trip, 하위 포맷 조용한 fallback.
- macOS integration: 새 window 생성, cross-window drop target, source window auto-close, focus/firstResponder.
- web panel: WKWebView reparent, bridge trust 유지, untrusted browser panel에 `window.maru` 미주입, IME/focus 복귀.

성능 gate:

- 이동은 surface runtime을 재시작하지 않는다.
- bulk window merge는 workspace 단위로 bounded하게 처리하고, frame tick을 오래 점유하면 chunk/yield한다.
- drag hover는 매 frame 대량 capture/evaluate/snapshot을 호출하지 않고, target 변경 시에만 highlight를 갱신한다.
