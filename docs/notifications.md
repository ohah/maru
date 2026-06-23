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
  move되므로 히스토리는 **다시 dupe**). 상한은 config `notifications.history-limit`(기본 64, 8~512 — §1과 같은 단일 출처)이고,
  push마다 다시 읽어 초과 시 가장 오래된 것을 버린다(cap-drop은 `pushNotificationHistory` 안). `notification_unread`는
  안 읽은 개수 캐시(아래 "읽음/지우기 액션"의 5곳 — push/markRead/delete/markAll/clear 헬퍼에서만 증감, 단일 출처).
- **사이드바 헤더 종 + 배지**: 헤더 우측 아이콘 줄에 4개 아이콘이 3칸 간격으로 우측 정렬된다 — 종(🔔)·접기(◧)·
  view options(⚙)·새 워크스페이스(+)가 각각 `cols-11`·`cols-8`·`cols-5`·`cols-2`. 종은 EAW 2칸이라 `cols-11·cols-10`을
  점유하는데, 정수 col 슬롯 중심이 `(cols-10)*cw`로 1칸 아이콘(중심 `col+0.5`)과 2.5칸이 되므로(좌우 패딩 어긋남)
  렌더러(`maru_metal_renderer.m`)가 종 글리프만 가로로 0.5칸 왼쪽으로 미는 px nudge를 줘 중심을 `(cols-10.5)*cw`
  (=균일 3칸 + hover quad 중앙·말풍선 caret과 동심)에 맞춘다(py_nudge와 동형 — 2칸 글리프는 정수 col로 반칸에 못 옴).
  안 읽은 개수 배지(coral)는 **종 한 칸 왼쪽**부터 — 1~9는 숫자 1칸(`cols-12`), 10개 이상은 "9+" 2칸(`cols-13·cols-12`).
  `HeaderRegion.notifications` zone은 `headerHit`(렌더 `buildSidebarHeaderFrame`과 같은 col)이 단일 출처 — 종 글리프
  (`cols-11·cols-10`)+배지(`cols-12`)를 포함하는 3칸 zone `[cols-12, cols-9)`. 안 그리면 hit-test도 none(`cols < 13`
  좁은 사이드바, 우측 아이콘 4개가 안 들어감). 사이드바 **최소 폭**(`sidebarMinPt`)은 신호등 클리어런스 + **13칸**으로,
  알림 그룹 좌단("9+" 배지 `cols-13`)까지 신호등과 안 겹치게 둔다(예전 10칸은 ◧까지만 잡아 종+배지가 겹쳤다).
- **접힘에도 알림 종 유지**: 사이드바 접힘(`sidebar_collapsed`, 폭 0)이면 좌상단 타이틀바 띠에 ◧ 펼치기 토글만 떴는데,
  이제 그 오른쪽(`collapsedBellCol()` = `collapsedToggleCol()+3`)에 **종 + 배지**도 그린다(`buildCollapsedToggleFrame`).
  렌더러는 접힘(terminal_origin_x_px==0) 헤더 줄0 글리프(◧·종·배지)를 모두 타이틀바 띠 세로 중앙에 정렬한다(예전 ◧
  전용 `is_collapsed_toggle`을 헤더 줄0 전체 `is_collapsed_header`로 일반화). 종 클릭(`collapsedNotificationRect`)은
  `openNotificationPanel`이 접힘 분기로 띠 아래에 패널을 띄우고(`is_window_drag_region`·hover 커서도 이 영역 제외/포인터),
  ◧ 클릭은 펼치기(별개 영역, 클릭 우선순위 종→◧).
- **떠 있는 카드 패널**: `src/chrome/components/notifications.zig`(context_menu를 본뜸). 한 항목 = **2줄 카드**
  (제목 + 본문), 안읽음 점(●), 우측 상대시간("N분 전"), 닫힌 surface는 회색(`muted_fg` role). `layout`(폭·높이·스크롤
  윈도우·위치 clamp)을 view·hitTest·panelRect가 공유(보이는 카드 == 클릭되는 카드). 카드 구분선은 `.fill`(1px)로 —
  `.rule` op은 macOS lowering에서 no-op이라. 빈 목록도 패널 + "알림 없음"을 그린다. 항목은 platform이 매 프레임
  arena로 주입(palette `Row` 선례) — chrome은 중립(surface_id·라이브 포인터 모름).
- **말풍선 팝오버(형태)**: `openNotificationPanel`이 content top을 `anchor_y = 2*cell_h + modal_padding_px`로 둔다(단일 출처).
  rich 모달 배경 quad는 lowering(`rasterizeOverlayCells`)이 content rect를 사방 `modal_padding_px`만큼 **outset**하므로
  **보이는** 패널 상단 = `anchor_y − mp` = 줄2(=2ch) — mp를 더해 보이는 상단을 줄2에 맞춘다(안 더하면 보이는 패널이
  `2ch−12`로 종에 거의 붙어 caret 틈이 없다). 종 글리프는 py_nudge(0.30ch)로 줄0에서 ~1.30ch까지 내려오므로, 줄1(빈
  버퍼 행)이 종↔패널 간격이자 **말풍선 caret**(위로 뾰족한 삼각형) 자리가 된다 — **팝업이 종을 안 가린다**(예전 `anchor_y=1ch`는
  종 하단을 덮었다). caret은 chrome 모달 lowering이 셀 그리드(픽셀 정밀 도형은 둥근 quad뿐)라, platform `appendNotificationCaret`이
  `self.gpu_quads`에 `GpuQuad{gradient_kind=3}`(셰이더가 rect 내접 삼각형 + fwidth edge AA로 그림 — 별도 파이프라인/ABI 없이
  quad 채널 재활용) 2개(focus_accent 외곽선 + surface_bg 채움)를 종 중심(`(cols-10.5)*cw`)·**보이는** 패널 상단(`panel.y − mp`)에
  append한다. 패널 배경 quad **'뒤'**라 상단 테두리를 caret 폭만큼 덮어 bubble을 연다. 패널이 세로 clamp로 밀렸거나
  종이 보이는 패널 가로 밖이면 caret 생략(어긋남 방지).
- **최소 높이**: 항목이 적어도 팝업이 납작하지 않게 `min_panel_rows`(8) baseline을 보장한다 — 카드는 상단, 액션
  행(footer)은 박스 하단 고정, 사이 여백은 패널 배경(클릭 무시 = `Hit.background`; 박스 '밖'만 닫기). 카드가 그보다
  많으면 자연 높이(화면 cap)로 커지므로 무영향(`layout` 단일 출처 — view·hitTest 공유).
- **스크롤(화면 넘으면)**: 카드가 화면 가용 높이를 넘으면 **카드 단위 스크롤**(`draw.Op`에 scissor가 없어 부분 카드를
  못 자르므로 통째 카드만 보인다). `State.scroll_offset`(보이는 첫 카드, 0=최신)으로 `items[first..first+visible]`만
  렌더한다. 마우스 휠(패널 열림 시 `scrollWheel`이 가로채 터미널/스크롤백으로 안 흘림)·키보드 ↑↓(선택이 viewport
  밖이면 `ensureSelectedVisible`가 따라 스크롤)로 움직인다. **액션 행("모두 읽음/지우기")은 viewport 하단 sticky**라
  스크롤해도 안 잘린다. 스크롤 가능하면 우측에 얇은 스크롤바 thumb(보이는 비율). 보이는 카드 수·상한은 `scrollWindow`
  (개수·화면 높이만 — 휠/키 경로가 Item을 안 빌드하게)가, 선택 끝맞춤 윈도잉은 `overlay_input.windowStart`(palette·
  settings와 공유)가 단일 출처. 다른 오버레이가 열렸을 땐 휠을 소비만 한다(터미널로 안 흘림 — `mouse()` 클릭 게이트와 짝).
- **클릭 → 점프 + 읽음**: 카드 본문 클릭/Enter → `acceptNotification`이 selected(역순: 0=최신)를 히스토리 인덱스로
  되돌려 그 카드의 surface를 봤다는 의미로 **같은 surface의 안읽음을 모두** 읽음 처리(`markNotificationsReadBySurface`
  — 2단계 배너 클릭과 **동일 정책**)하고, `activateSurfaceById(surface_id)`(1단계 재사용)로 점프한 뒤 패널을 닫는다.
  닫힌 surface면 점프 없이 닫기만(카드는 이미 회색). 배너든 카드든 "그 터미널을 봤다"는 한 가지 읽음 정책으로 통일.
- **읽음/지우기 액션**: 마우스 hit-test는 `Hit` union(`card`/`close`/`mark_all_read`/`clear_all`/`background`)으로 가른다 — 카드
  우측 ✕(본문줄)=개별 삭제(`deleteNotification`), 키보드 Backspace=선택 카드 삭제. 패널 하단 액션 행 좌/우 절반=
  "모두 읽음"(`markAllNotificationsRead` — 점/배지만 끄고 항목 유지) / "모두 지우기"(`clearNotifications` — 전체 삭제).
  unread 캐시는 push/markRead/delete/markAll/clear 헬퍼에서만 증감(단일 출처).

## 4. 경계 분담 (단일 출처)

- **Zig**: 알림 파싱·합류(`pendingNotification`), 전면 배너 여부(`foreground_banner`), surface 역조회·활성화 순서
  (`activateSurfaceById`), 히스토리 모델·정렬·상대시간 포맷, chrome 컴포넌트(state·hit-test·draw ops), 헤더 zone.
- **Swift**: `UNUserNotificationCenter` 표시/권한/delegate, 창 키 활성화(`makeKeyAndOrderFront`/`NSApp.activate`),
  알림 `userInfo`에 정수 2개(`wt`/`sid`) 싣기·꺼내기, 전면 표시 스타일 적용(`willPresent`). 정책 결정은 안 한다.
- **ABI**: `app_host_abi.h`의 `MARU_MACOS_APP_HOST_ABI_VERSION` 매크로(+ `app_session.zig` `abi_version` 상수, Zig
  크로스체크가 동기 강제)가 ABI 버전의 단일 출처다. 알림 함수는 **v78에서 도입**됐다 — `pending_notification`
  (`surface_id`/`foreground` out) + `activate_surface(session, surface_id) → found`. 인앱 알림 센터는 chrome 오버레이라
  추가 ABI가 없다(Swift 무변경).

## 5. 검증

- **단위(Zig 헤드리스)**: `notifications.zig`(state·handle·itemAt 2행·view ops·panelRect clamp), 히스토리 ring buffer
  (push 상한·unread 증감·markRead·formatRelativeTime), `acceptNotification` 역순 매핑, `activateSurfaceById` 역조회,
  `headerHit` 4-아이콘 zone, **접힘 종 hit-test**(`collapsedNotificationRect` 종 글리프 동심·◧ rect 비겹침·클릭→패널 열림).
- **렌더 1회**: op 방출만으론 부족(modal_box 회귀 전례) — `buildSidebarHeaderFrame`(펼침)·`buildCollapsedToggleFrame`(접힘)이
  공유하는 `appendBellAndBadge` 종/배지 cell + 오버레이 lowering으로 2줄 카드가 cell 그리드에 들어가고 한글 본문이 안
  잘리는지(EAW). **종 글리프(🔔)는 실제 렌더로 fallback 확인** — 깨지면 BMP 기호로 교체(`agentSymbolCodepoint` 규율:
  JetBrains Mono 보유 글리프만). 접힘 종은 `MARU_COLLAPSE_SIDEBAR` 헤드리스 스크린샷으로 ◧↔종 띠 세로 정렬 확인.
- **수동 E2E**(`.app` 번들): OSC/에이전트 알림 → 배너 클릭 → 발신 터미널 점프 / 멀티 윈도우 토큰 라우팅 / 종 클릭 →
  카드 패널 → 항목 클릭 점프 / 안읽음 배지·점.

## 6. 범위 밖 (후속)

핵심 알림 기능(클릭→활성화·인앱 센터·읽음/지우기·config·배너↔센터 읽음 동기화·배지 9+·카드 단위 스크롤)은
완결됐다. 추가 알림 채널(OSC 99 등)이나 알림 그룹화는 필요해지면 후속으로 둔다.

**알림 패널 행 단위/픽셀 스크롤(백로그·보류)**: 현재 스크롤은 **카드 단위**(`card_rows`=2행을 통째로 넘긴다). 모달
px 클리핑 인프라(`MetalFrame.modal_clip`, ABI v84 — `docs/layering-and-portability.md` §7)는 머지됐으나 **알림 적용은
보류**한다. 이유: 오버레이 텍스트는 `placeText`가 `@divTrunc`로 셀 행에 스냅하고 viewport(`rows`) 밖이면 자동
skip하므로, 진짜 픽셀-부드러운 스크롤이 텍스트엔 불가하다(셀 그리드 제약). clip의 실익은 배경 quad와 행 단위 부분
카드 정리 정도라 card-unit 대비 이득(마지막 카드 반쯤 보임)이 작고 재작성 복잡도가 크다 — 지금은 card-unit으로 충분.
**필요해지면 "행 단위 스크롤"**(`scroll_offset` 행 기반 + clip으로 viewport 정리; `scrollWindow`·`overlay_input.
windowStart`·스크롤바·휠 게이트는 재사용)로 적용한다. 진짜 부드러운 px 스크롤은 텍스트 셀 그리드를 px 렌더로 바꾸는
근본 작업이라 비권장.
