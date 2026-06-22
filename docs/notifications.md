# 알림(Notifications) 전략

> 단일 출처(design). Maru의 알림은 **두 면**을 가진다 — ① OS 데스크톱 배너(macOS 알림 센터), ② 앱 안 알림 센터
> (maru chrome 오버레이). 둘은 같은 알림 소스를 공유하고, "정책·데이터·역조회는 Zig, OS 표시·창 활성화는 Swift"
> 경계를 따른다. 에이전트 완료 알림의 신호원·트리거는 [agent-session.md](agent-session.md) "알림" 절이 단일 출처다.

## 1. 알림 소스

| 소스 | 트리거 | 발신 surface | 단일 출처 |
|---|---|---|---|
| **OSC 9 / OSC 777** | 셸/TUI가 `ESC ] 9 ; … ST`(iTerm2) 또는 `ESC ] 777 ; notify ; … ST`(rxvt)를 출력 | 활성(보이는) surface — 코어가 그 surface에서 파싱 | `src/terminal/core.zig` `dispatchOscNotify9/777` |
| **에이전트 완료** | claude/codex 세션이 `running → idle` 전환, 그리고 **지금 보고 있는 탭이 아님**(`!is_current`) | 완료한 Term의 surface | `app_session.zig` `enqueueAgentCompletion` |

두 소스는 `AppSession.pendingNotification()` 한 funnel로 합류한다(에이전트 큐를 OSC보다 먼저 드레인). 반환은
`{ title, body, surface_id, foreground_banner }` — Swift가 tick마다 poll한다.

종류별 표시는 config `notifications.*`가 각 발화 지점에서 게이트한다 — `agent-complete`(에이전트 완료, `enqueueAgentCompletion`)·
`osc`(OSC 9/777, `pendingNotification`)를 끄면 데스크톱 배너·인앱 센터 둘 다 안 만든다. 인앱 센터 보관 개수는
`history-limit`(8~512, 기본 64). 단일 출처는 [config 스키마](configuration.md)다(스키마-주도라 세팅 화면에도 자동 노출).

## 2. 데스크톱 배너 (OS, 1단계)

`pendingNotification()` → Swift `drainNotification()` → `UNUserNotificationCenter`. 배너는 OS 리소스라 native(Swift)만
띄우고, 코어/Zig는 데이터만 넘긴다(클립보드·벨과 같은 경계). 번들 ID가 없으면(dev shell) 알림 API를 못 써 조용히
건너뛴다 — **배너는 `.app` 번들에서만 뜬다**.

### 클릭 → 발신 터미널 자동 활성화

알림을 클릭하면 그 알림을 보낸 터미널의 **창 + 탭 + split panel + 가로탭(Term)까지** 정확히 포커스한다.

- **식별자**: `surface.id`는 `AppSession.next_id`로 발급되는 **세션(창)-로컬** 카운터라 창이 여러 개면 중복될 수 있다.
  그래서 알림 `userInfo`에 **`(token, surface_id)` 쌍**을 싣는다 — Swift `TerminalSurface.token`(창마다 유일,
  `makeTerminalSurface` 채번)으로 정확한 창/세션을 먼저 고르고, 그 세션 안에서 `surface_id`로 Term을 찾는다.
  `identifier`는 dedup용 UUID를 유지한다(라우팅 정보를 identifier에 쓰면 연속 알림이 서로 덮어쓴다).
- **역조회·활성화(Zig)**: `activateSurfaceById(id)` — `findTermWhere`로 `(tab, pane, term)`을 찾아
  **`switchTab → focusPaneByPtr → focusTerm`** 순서로 활성화(focusPaneByPtr는 활성 탭의 panes만, focusTerm은 활성
  pane만 보므로 순서가 강제된다 — 이 계약을 한 메서드에 가둔다). id는 재사용하지 않으므로(단조 증가) stale id가 다른
  surface로 오인 활성화될 위험이 없다(닫힌 Term이면 못 찾아 false = 무동작). 배너를 클릭했으면 그 surface를 본
  것이므로, `activate_surface` export가 `markNotificationsReadBySurface(surface_id)`로 인앱 센터의 같은 surface
  안읽음 알림도 읽음 처리한다(배너↔센터 읽음 동기화 — 닫힌 surface여도 읽음).
- **delegate 타이밍**: `UNUserNotificationCenterDelegate`는 `applicationDidFinishLaunching`에서 **launch 완료 전**
  등록한다(Apple 요구사항 — 앱이 꺼진 상태에서 알림 클릭으로 켜진 콜드 런치의 첫 `didReceive`를 놓치지 않게).
- **quick 패널**: 알림 대상이 quick 터미널이고 숨김이면 `showQuickTerminalAnimated`로 띄운다(화면 밖에 있는 패널을
  그냥 `makeKeyAndOrderFront`하면 보이지 않는 창이 키를 가져간다).

### 전면 배너 게이트

앱이 전면일 때 OS는 `willPresent`를 부른다. `foreground_banner`(Zig 결정)로 표시 스타일을 가른다:
- **에이전트 완료(=1)**: "지금 안 보는 탭"이 대상이라 전면에서도 `[.banner, .sound]`로 알린다.
- **OSC 9/777(=0)**: 활성(보이는) surface가 보내 사용자가 이미 그 화면을 볼 가능성이 커, 전면이면 `[.list]`로 알림
  센터 목록에만 남긴다(자기 화면 알림 배너 노이즈 억제).

## 3. 인앱 알림 센터 (maru chrome, 2단계)

데스크톱 배너는 드레인되면 사라진다. 인앱 알림 센터는 알림을 **보관·열람**한다 — `.app` 번들이 아니어도, 놓친
알림도 다시 볼 수 있다.

- **히스토리(ring buffer)**: `NotificationHistoryItem { title, body, surface_id, timestamp_ns, is_read, is_agent }`.
  `pendingNotification()`이 드레인하는 단일 funnel에서 `pushNotificationHistory`로 보관한다(에이전트 큐 버퍼는 OS 배너로
  move되므로 히스토리는 **다시 dupe**). 상한(`notification_history_cap=64`) 초과 시 가장 오래된 것을 버린다.
  `notification_unread`는 안 읽은 개수 캐시(push/markRead/cap-drop 3곳에서만 증감).
- **사이드바 헤더 종 + 배지**: 헤더 우측 아이콘 줄에 종(🔔, `cols-12`) + 안 읽은 개수 배지(coral) — 1~9는 숫자
  1칸(`cols-10`), 10개 이상은 "9+" 2칸(`cols-10·cols-9`).
  `HeaderRegion.notifications` zone은 `headerHit`(렌더 `buildSidebarHeaderFrame`과 같은 col)이 단일 출처 —
  안 그리면 hit-test도 none(`cols < 13` 좁은 사이드바). 아이콘 4개(종·◧·⚙·+)가 3칸 간격으로 우측 정렬.
- **떠 있는 카드 패널**: `src/chrome/components/notifications.zig`(context_menu를 본뜸). 한 항목 = **2줄 카드**
  (제목 + 본문), 안읽음 점(●), 우측 상대시간("N분 전"), 닫힌 surface는 회색(`muted_fg` role). `panelRect`를 view·itemAt이
  공유(보이는 카드 == 클릭되는 카드). 카드 구분선은 `.fill`(1px)로 — `.rule` op은 macOS lowering에서 no-op이라.
  빈 목록도 패널 + "알림 없음"을 그린다. 항목은 platform이 매 프레임 arena로 주입(palette `Row` 선례) — chrome은
  중립(surface_id·라이브 포인터 모름).
- **클릭 → 점프 + 읽음**: 카드 본문 클릭/Enter → `acceptNotification`이 selected(역순: 0=최신)를 히스토리 인덱스로
  되돌려 **그 항목만** 읽음 처리(점/배지 갱신)하고, `activateSurfaceById(surface_id)`(1단계 재사용)로 점프한 뒤 패널을
  닫는다. 닫힌 surface면 점프 없이 닫기만(카드는 이미 회색).
- **읽음/지우기 액션**: 마우스 hit-test는 `Hit` union(`card`/`close`/`mark_all_read`/`clear_all`)으로 가른다 — 카드
  우측 ✕(본문줄)=개별 삭제(`deleteNotification`), 키보드 Backspace=선택 카드 삭제. 패널 하단 액션 행 좌/우 절반=
  "모두 읽음"(`markAllNotificationsRead` — 점/배지만 끄고 항목 유지) / "모두 지우기"(`clearNotifications` — 전체 삭제).
  unread 캐시는 push/markRead/delete/markAll/clear 헬퍼에서만 증감(단일 출처).

## 4. 경계 분담 (단일 출처)

- **Zig**: 알림 파싱·합류(`pendingNotification`), 전면 배너 여부(`foreground_banner`), surface 역조회·활성화 순서
  (`activateSurfaceById`), 히스토리 모델·정렬·상대시간 포맷, chrome 컴포넌트(state·hit-test·draw ops), 헤더 zone.
- **Swift**: `UNUserNotificationCenter` 표시/권한/delegate, 창 키 활성화(`makeKeyAndOrderFront`/`NSApp.activate`),
  알림 `userInfo`에 정수 2개(`wt`/`sid`) 싣기·꺼내기, 전면 표시 스타일 적용(`willPresent`). 정책 결정은 안 한다.
- **ABI**: `MARU_MACOS_APP_HOST_ABI_VERSION`(현재 v78) 주석이 ABI 함수의 단일 출처다 — `pending_notification`
  (`surface_id`/`foreground` out) + `activate_surface(session, surface_id) → found`. 인앱 알림 센터는 chrome 오버레이라
  추가 ABI가 없다(Swift 무변경).

## 5. 검증

- **단위(Zig 헤드리스)**: `notifications.zig`(state·handle·itemAt 2행·view ops·panelRect clamp), 히스토리 ring buffer
  (push 상한·unread 증감·markRead·formatRelativeTime), `acceptNotification` 역순 매핑, `activateSurfaceById` 역조회,
  `headerHit` 4-아이콘 zone.
- **렌더 1회**: op 방출만으론 부족(modal_box 회귀 전례) — `buildSidebarHeaderFrame` 종/배지 cell + 오버레이 lowering으로
  2줄 카드가 cell 그리드에 들어가고 한글 본문이 안 잘리는지(EAW). **종 글리프(🔔)는 실제 렌더로 fallback 확인** —
  깨지면 BMP 기호로 교체(`agentSymbolCodepoint` 규율: JetBrains Mono 보유 글리프만).
- **수동 E2E**(`.app` 번들): OSC/에이전트 알림 → 배너 클릭 → 발신 터미널 점프 / 멀티 윈도우 토큰 라우팅 / 종 클릭 →
  카드 패널 → 항목 클릭 점프 / 안읽음 배지·점.

## 6. 범위 밖 (후속)

핵심 알림 기능(클릭→활성화·인앱 센터·읽음/지우기·config·배너↔센터 읽음 동기화·배지 9+)은 완결됐다. 추가 알림 채널
(OSC 99 등)이나 알림 그룹화는 필요해지면 후속으로 둔다.
