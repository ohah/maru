# 알림(Notifications) 전략

> 단일 출처(design). Maru의 알림은 **두 면**을 가진다 — ① OS 데스크톱 배너(macOS 알림 센터), ② 앱 안 알림 센터
> (maru chrome 오버레이). OSC 알림은 두 면에 함께 나타나고 업데이트 안내는 인앱 센터에만 나타난다.
> "정책·데이터·역조회는 Zig, OS 표시·창 활성화는 Swift" 경계를 따른다. 에이전트 상태는
> [agent-session.md](agent-session.md)가 단일 출처이며, terminal observer만으로 완료와
> ESC 중단을 구분할 수 없으므로 에이전트 완료 알림은 제공하지 않는다.

## 1. 알림 소스

| 소스 | 트리거 | 발신 surface | 단일 출처 |
|---|---|---|---|
| **OSC 9 / OSC 777** | 셸/TUI가 `ESC ] 9 ; … ST`(iTerm2) 또는 `ESC ] 777 ; notify ; … ST`(rxvt)를 출력 | **시퀀스를 출력한 그 surface**(background split pane·가로탭 포함) — 코어가 각 surface에서 파싱 | `src/terminal/osc.zig` `dispatchNotify9/777` + `app_session.zig` `drainOscNotificationFrom` |
| **업데이트 안내** | 시작 시 새 버전을 확인하고 새 버전이 있을 때 인앱 히스토리에 추가 | 해당 없음 | `app_session.zig` `drainUpdateCheck` + [배포 전략](distribution.md) |

OSC는 `AppSession.pendingNotification()`이 `{ title, body, surface_id, foreground_banner }`(`PendingNotification`)로
드레인해 Swift에 넘기고 동시에 인앱 히스토리에 보관한다. 업데이트 안내는 OS 배너로 보내지 않고 인앱 히스토리에 직접 추가한다.

**원격(SSH) 세션의 에이전트 알림도 이 OSC 행으로 들어온다.** 원격 pane 은 `agent_kind` 가 `none` 이라 훅 모드가
안 서고, 그래서 훅 모드였다면 버렸을 OSC 가 그대로 산다 — 접속 방법(`maru ssh` 인지 그냥 `ssh` 인지)과도
무관하다. provider 별 설정과 실측 근거는 [agent-hooks.md](agent-hooks.md) §11 이 단일 출처다.

### 영속 session host와 GUI 종료 상태

GUI-local funnel은 `AppSession`/Swift가 살아 있을 때 동작한다. 앱이 완전히 종료된 동안의 전달은
[영속 터미널 세션 호스트](persistent-session-host.md) P4의 host-owned 경계가 담당하며, 그 gate 전에는
`session.keep-alive-after-quit=true`를 기본값으로 바꾸지 않는다.

- OSC 9/777 parsing과 bounded pending event는 `TerminalCore`와 함께 `maru-sessiond`가 소유한다.
- 모든 host-backed OSC event는 GUI 유무와 관계없이 source에서 `{host_id,runtime_id,event_id}`를 발급·보존한다.
  GUI가 붙어 있으면 현재 `PendingNotification` funnel로 변환하고 process-local route는 fast-path hint로만 추가한다.
- GUI가 없으면 signed app bundle의 macOS notification sink가 OS 배너를 게시하고, 다음 GUI가 host의 bounded pending
  history를 인앱 알림 이력으로 가져간다.
- 배너 클릭 cold launch는 tmux/provider ID나 process-local surface ID가 아니라
  `{host_id,runtime_id,event_id}`로 attach한다. exact runtime이 manifest의 canonical Term에 bind돼 있으면 그
  Window/Workspace/Pane/Term을 열고, binding이 없지만 runtime이 살아 있으면 `Recovered Sessions`에 노출한다.
- 구조화된 완료 신호가 없는 agent completion은 emit하지 않는다. host가 `running → idle`을 완료로 추측하지 않는다.
- pre-authorized macOS runner에서 실제 signed `.app`의 GUI 0 OSC 발화→배너→클릭과
  GUI 연결 중 발화→Quit→기존 배너 클릭이 모두 정확한 runtime에 attach한다는 **무인 자동 artifact**가 있어야 P4
  완료다. runner가 없으면 수동 클릭으로 대체하지 않고 P4와 기본값 전환을 미완료로 둔다.

**모든 pane·Term을 본다(핵심)**: OSC는 활성 surface만이 아니라 **모든 탭의 모든 split pane·모든 가로탭(Term)**을 본다.
`pendingNotification`이 각 Term 코어를 훑어 첫 pending을 발신 `surface.id`와 함께 보내므로 클릭이 탭뿐 아니라 해당 split
pane·가로탭까지 정확히 점프한다(`activateSurfaceById`, §2 클릭 절). reader 스레드가 `core_mutex` 아래 OSC pending을 쓰므로,
main은 `lockCore` 아래에서 읽어 owned 버퍼로 복사한다(torn read/UAF 방지). agent observer는 상태 표시 전용이며 알림 소스가 아니다.

종류별 표시는 config `notifications.*`가 각 발화 지점에서 게이트한다. `osc`(OSC 9/777, `pendingNotification`)를 끄면
데스크톱 배너·인앱 센터 둘 다 안 만든다. 인앱 센터 보관 개수는
`history-limit`(8~512, 기본 64). 단일 출처는 [config 스키마](configuration.md)다(스키마-주도라 세팅 화면에도 자동 노출).

### 제목 구성 — 위치(`탭 › 팬`) 접두

OSC 알림 제목에는 **발신 위치**(워크스페이스=탭, Term=surface/pane)를 실어, 여러 탭·split·가로탭을 띄운 채
받은 알림이 **어느 터미널에서 왔는지** 제목에서 바로 식별된다(사용자 요청 — 배너엔 앱 아이콘만 떠 소스 구분이 안 됐다).

- **위치 라벨(단일 출처: `app_session.zig` `notificationLocation`)**: `workspaceLabel(탭) › termLabel(Term)`.
  두 라벨이 **같으면**(단일 Term 탭·custom_name 없음 등 `workspaceLabel`이 그 Term 라벨로 폴백) 중복이라 **하나만**
  쓴다 — 단일 워크스페이스·단일 Term 사용자는 예전 제목과 동일하게 보인다. `›`(U+203A)는 계층(탭⊃팬), `·`(U+00B7)는
  상위 구분자로 알림 전체에서 일관되게 쓴다. 라벨은 borrowed(auto_title=메인 스레드 캐시·custom_name=세션 소유·
  surface.title=정적, reader 미접근)라 즉시 소비하고, OSC 경로는 `lockCore` 밖 메인 스레드 상태만 읽어 코어 락과 무관하다.
- **OSC 9/777**: `{위치} · {앱 title}`(앱이 준 title이 있을 때, 예: `배포 › 작업1 · Build finished`), title이 없으면
  (OSC 9은 title 없음) `{위치}`만. body는 앱이 보낸 메시지 그대로 둔다. 위치를 **접두**해 앱 제목/메시지를 보존한다.

**베이스/결정**: macOS 알림은 왼쪽 큰 아이콘이 앱 아이콘 고정이라(iTerm2/Terminal.app도 동일) 소스 구분을 못 하므로,
탭·Term 라벨을 **제목 접두**로 실어 구분한다(macOS `UNMutableNotificationContent`의 subtitle을 쓸 수도 있으나 ABI에
셋째 문자열 추가가 필요해, 기존 title/body funnel 안에서 접두로 해결). 라벨 해석은 사이드바·탭바와 같은 `app.pickLabel`
단일 규칙(custom_name 우선·없으면 자동 제목)을 재사용해 제목이 화면 라벨과 어긋나지 않는다.

## 2. 데스크톱 배너 (OS, 1단계)

`pendingNotification()` → Swift `drainNotification()` → `UNUserNotificationCenter`. 배너는 OS 리소스라 native(Swift)만
띄우고, 코어/Zig는 데이터만 넘긴다(클립보드·벨과 같은 경계). 번들 ID가 없으면(dev shell) 알림 API를 못 써 조용히
건너뛴다 — **배너는 `.app` 번들에서만 뜬다**.

세팅 GUI에서 `notifications.osc`를 켜면 Zig가
`take_notification_authorization_request` 1회성 신호를 세우고, Swift가 다음 tick에 drain해 **현재 권한 상태를 보고
분기**한다(`getNotificationSettings`) — 단순히 `requestAuthorization`을 재호출하면 안 되기 때문이다. 아직 결정 전
(`notDetermined`)이면 `requestAuthorization`으로 macOS 권한 팝업을 띄우고, 이미 허용된 상태면 무동작이다. **거부 상태
(`denied`)면 `requestAuthorization` 재호출이 무력하다** — macOS는 설치당 권한 팝업을 한 번만 띄우고, 게다가 시작 시
`drainNotification`이 매 tick `ensureNotificationAuthorization`로 그 1회성 팝업을 이미 소비하므로(프로그램이 OSC를 한
번도 안 보내도 팝업이 뜨게 하려는 선요청) 토글 시점엔 재팝업이 **절대** 안 뜬다. 그래서 거부 상태에선 시스템 알림 설정
창(`x-apple.systempreferences:com.apple.Notification-Settings.extension`)을 `NSWorkspace`로 열어, 거부했던 사용자가
직접 알림을 다시 켤 **유일한 경로**를 준다(이 분기가 없으면 한 번 거부한 사용자는 앱 안에서 영영 알림을 못 켠다).

### 클릭 → 발신 터미널 자동 활성화

알림을 클릭하면 그 알림을 보낸 터미널의 **창 + 탭 + split panel + 가로탭(Term)까지** 정확히 포커스한다.

- **host-backed 식별자(P4 계획)**: GUI 유무와 관계없이 `userInfo`에
  `{host_id,runtime_id,event_id}`를 필수로 싣는다. GUI가 살아 있으면
  `{app_instance_epoch,token,surface_id}`를 fast-path hint로 추가한다. epoch가 현재 launch와 같고 surface의
  runtime handle도 일치할 때만 즉시 활성화하며, 아니면 stable handle로 attach해 manifest binding을 찾고 없으면
  `Recovered Sessions`에 둔다. `event_id`는 host-lifetime monotonic u64이고 재사용하지 않으며
  `{host_id,event_id}`가 dedup key다.
- **local/quick 식별자**: in-process runtime은 stable host handle이 없으므로
  `{app_instance_epoch,token,surface_id}`만 쓴다. 앱 종료와 함께 route도 끝나며 cold attach 대상이 아니다.
- **역조회·활성화(Zig)**: `activateSurfaceById(id)` — `findTermWhere`로 `(tab, pane, term)`을 찾아
  **`switchTab → focusPaneByPtr → focusTerm`** 순서로 활성화(focusPaneByPtr는 활성 탭의 panes만, focusTerm은 활성
  pane만 보므로 순서가 강제된다 — 이 계약을 한 메서드에 가둔다). id는 재사용하지 않으므로(단조 증가) stale id가 다른
  surface로 오인 활성화될 위험이 없다(닫힌 Term이면 못 찾아 false = 무동작). 배너를 클릭했으면 그 surface를 본
  것이므로, `activate_surface` export가 `markNotificationsReadBySurface(surface_id)`로 인앱 센터의 같은 surface
  안읽음 알림도 읽음 처리한다(배너↔센터 읽음 동기화 — 닫힌 surface여도 읽음).
- **delegate 타이밍**: `UNUserNotificationCenterDelegate`는 `applicationDidFinishLaunching`에서 **launch 완료 전**
  등록한다(Apple 요구사항 — 앱이 꺼진 상태에서 알림 클릭으로 켜진 콜드 런치의 첫 `didReceive`를 놓치지 않게).
- **quick 패널**: 알림 대상이 quick 터미널이고 숨김이면 `showQuickTerminalAnimated`로 띄운다(화면 밖에 있는 패널을
  그냥 `makeKeyAndOrderFront`하면 보이지 않는 창이 키를 가져간다). quick은 확정적으로 in-process이며 앱 Quit 때
  runtime과 알림 route가 함께 끝난다. workspace manifest·persistent notification journal·cold-launch attach에는 넣지
  않는다. 앱이 종료된 동안 살아 있는 일반 persistent runtime의 배너 클릭만 `runtime_handle`로 exact normal Term을 연다.

### 전면 배너 게이트

앱이 전면일 때 OS는 `willPresent`를 부른다. `foreground_banner`(Zig 결정)로 표시 스타일을 가른다:
- **OSC 9/777**: 발신 Term이 **지금 보고 있는 그 Term이면 =0** — 사용자가 그 화면을 보고 있어 전면이면 `[.list]`로 알림
  센터 목록에만 남긴다(자기 화면 배너 노이즈 억제). **그 외(background split pane·가로탭·비활성 탭)면 =1** — 안 보는
  곳이라 전면에서도 배너로 알린다(`drainOscNotificationFrom`이 `focused_term` 비교로 결정).

## 3. 인앱 알림 센터 (maru chrome, 2단계)

데스크톱 배너는 드레인되면 사라진다. 인앱 알림 센터는 알림을 **보관·열람**한다 — `.app` 번들이 아니어도, 놓친
알림도 다시 볼 수 있다.

- **히스토리(ring buffer)**: `NotificationHistoryItem { title, body, surface_id, timestamp_ns, is_read }`.
  OSC drain과 업데이트 확인이 `pushNotificationHistory`로 owned 사본을 보관한다. 상한은 config
  `notifications.history-limit`(기본 64, 8~512 — §1과 같은 단일 출처)이고,
  push마다 다시 읽어 초과 시 가장 오래된 것을 버린다(cap-drop은 `pushNotificationHistory` 안). `notification_unread`는
  안 읽은 개수 캐시(아래 "읽음/지우기 액션"의 5곳 — push/markRead/delete/markAll/clear 헬퍼에서만 증감, 단일 출처).
- **사이드바 헤더 종 + 배지**: 헤더 우측 아이콘 줄에 종(🔔)·접기(◧)·view options(⚙)·새 워크스페이스(+)를 우측
  정렬한다 — ◧·⚙·+는 3칸 간격(`cols-8`·`cols-5`·`cols-2`)이고, 종은 우상단 배지(아래) 자리를 비우려 한 칸 더 왼쪽
  `cols-12`(EAW 2칸이라 `cols-12·cols-11` 점유)에 둔다(종↔◧ 4칸: 그 사이 `cols-10`=배지·`cols-9`=간격). 종은 2칸
  글리프라 정수 col 슬롯 중심이 `(cols-11)*cw`로 1칸 아이콘(중심 `col+0.5`)과 반칸 어긋나므로, 렌더러
  (`maru_metal_renderer.m`)가 종 글리프만 가로로 0.5칸 왼쪽으로 미는 px nudge를 줘 중심을 `(cols-11.5)*cw`
  (hover quad 중앙·말풍선 caret과 동심)에 맞춘다(py_nudge와 동형 — 2칸 글리프는 정수 col로 반칸에 못 옴).
- **안 읽은 개수 배지(종 우상단 빨강 원형, 펼침)**: 종을 `cols-12`(점유 `cols-12·cols-11`)에 두고 **우측 한 칸**
  (`cols-10` = `notificationBadgeCol`)에 **빨강 원형 quad + 흰 숫자**를 겹쳐 그린다(iOS/macOS 배지식 — 예전 종 좌측 coral
  텍스트는 대비가 낮아 안 읽혔다). 종을 한 칸 왼쪽(`cols-12`)에 둬 배지(`cols-10`)와 ◧(`cols-8`) 사이에 `cols-9` 한 칸
  간격을 둔다(◧가 1.7×라 `cols-9`로 번져 배지와 닿던 것을 뗌). **빨강 원**은 `appendNotificationBadge`가 GpuQuad(layer 4)로,
  **흰 숫자**는 `appendBellAndBadge`가 헤더 frame 셀(같은 `cols-10`)로 둔다 — cell↔quad가 같은 col에서 만나 어긋나지 않는
  단일 출처. **세로도 같은 원점을 쓴다**: 헤더 아이콘 줄은 `row × ch`가 **아니라** 신호등 띠 `[0, titlebar_strip_px]` 안
  세로 중앙에 놓이므로(`maru_metal_renderer.m`의 `py_top = (strip - ch) * 0.5`), 원도 `sidebarHeaderIconRowTopPx`를
  원점으로 삼고 그 위에서 `notification_badge_center_in_cell`(0.46ch, digit 시각 중심)만큼 내린다. 원이 이 원점을 빼고
  `ch*0.46`만 쓰면 띠가 셀보다 높은 창에서 `(strip-ch)/2`만큼 위로 떠 숫자가 원 밖으로 나간다 — **셀 세로 위치는
  렌더러가, quad 세로 위치는 host가 정하므로 이 함수가 두 축의 유일한 접점**이다. 원형 1칸 제약상 **1~9는 숫자, 10개 이상은 "9"로 cap**한다(2칸 "9+"는 자리가 없음). **렌더 레이어 4**는 사이드바 bg strip
  '뒤' / 헤더 글리프(터미널 셀 패스) '앞'에 끼우는 전용 quad 패스다(`maru_metal_renderer.m`) — 0/1/3 레이어는 헤더 글리프
  '뒤'가 안 돼 흰 숫자를 덮으므로(헤더 hover quad 한계와 동형), 빨강 원이 숫자 아래·사이드바 배경 위에 오게 한 칸 신설.
- **접힘 배지(종 좌측 텍스트, 유지)**: 접힘 타이틀바 헤더는 터미널 위에 그려져 layer 4 quad가 터미널 셀에 가리므로(원형
  부적합), 종 **좌측** coral 텍스트 배지를 유지한다 — 1~9 숫자 1칸(`cols-12`), 10+ "9+" 2칸(`cols-13·cols-12`).
- **hit-test/최소 폭**: `HeaderRegion.notifications` zone은 `headerHit`(렌더 `buildSidebarHeaderFrame`과 같은 col)이 단일 출처 —
  펼침 종 글리프(`cols-12·cols-11`)+배지(`cols-10`)를 모두 포함하는 zone `[cols-12, cols-9)`(접힘은 `collapsedNotificationRect`가
  따로 hit-test). 안 그리면 hit-test도 none(`cols < 13` 좁은
  사이드바). 사이드바 **최소 폭**(`sidebarMinPt`)은 신호등 클리어런스 + **13칸**으로 신호등과 안 겹치게 둔다.
- **접힘에도 알림 종 유지**: 사이드바 접힘(`sidebar_collapsed`, 폭 0)이면 좌상단 타이틀바 띠에 ◧ 펼치기 토글만 떴는데,
  이제 종+배지를 ◧ **왼쪽**(가장 왼쪽; `collapsedToggleCol()` = `collapsedBellCol()+3`)에 그려 펼침 헤더와 같은 종→◧
  순서로 둔다(`buildCollapsedToggleFrame`) — 토글로 접힘↔펼침을 오가도 종/◧ 위치가 안 바뀐다(사용자 피드백). 종 base는
  `클리어런스 + 여백 + 배지폭`(`collapsed_badge_max_cells`)이라 "9+" 배지도 신호등을 침범 안 한다(anchor도 같은 폭으로 묶음 좌단).
  렌더러는 접힘(terminal_origin_x_px==0) 헤더 줄0 글리프(종·배지·◧)를 모두 타이틀바 띠 세로 중앙에 정렬한다(예전 ◧
  전용 `is_collapsed_toggle`을 헤더 줄0 전체 `is_collapsed_header`로 일반화). 종 클릭(`collapsedNotificationRect`)은
  `openNotificationPanel`이 접힘 분기로 띠 아래에 패널을 띄우고(`is_window_drag_region`·hover 커서도 이 영역 제외/포인터),
  ◧ 클릭은 펼치기(별개 영역, 클릭 우선순위 종→◧).
- **떠 있는 카드 패널**: `src/chrome/components/notifications.zig`(Maru 독립 설계). **상단 헤더 밴드**("알림" 제목 +
  우측 액션 **버튼** "모두 읽음"/"모두 지우기" — 아래 "읽음/지우기 액션 버튼" 참조)와 그 아래 본문(카드 목록 또는 빈 상태
  일러스트)으로 구성된다 — 헤더는 viewport
  상단 sticky, 카드는 그 아래에서 스크롤한다. 한 항목 = **2줄 카드**(제목 + 본문), 안읽음 점(●), 우측 상대시간
  ("N분 전"), 닫힌 surface는 회색(`muted_fg` role). `layout`(폭·높이·스크롤 윈도우·위치 clamp)을 view·hitTest·panelRect가
  공유(보이는 카드 == 클릭되는 카드). 헤더 구분선·카드 구분선은 `.fill`(1px)로 — `.rule` op은 macOS lowering에서 no-op이라.
  **카드 구분선은 보이는 카드마다 아래에** 긋는다(마지막 카드 포함) — 항목 경계를 분명히 보이게 한다. 안읽음 점(●, col 1)과
  텍스트(col 3) 사이엔 빈 칸(col 2)을 두어 점이 텍스트에 바짝 붙지 않게 한다(`text_indent_cols`).
  항목은 platform이 매 프레임 arena로 주입(palette `Row` 선례) — chrome은 중립(surface_id·라이브 포인터 모름).
- **선택·호버 강조**: 키보드 `selected`(↑↓·열 때 0=최신)는 `tab_active_bg`로, 마우스 `hovered`(카드 위 포인터)는
  `tab_hover_bg`(선택과 다른 톤)로 카드 2행을 칠한다 — 마우스가 가리키는 항목을 구분 인식하게 한다. 둘은 별개 상태고
  (사이드바 `hovered_slot`↔active와 동형) 같은 카드면 선택이 우선(hover 생략). `hovered`는 `notifications.State`가 들고,
  platform `hoverCursor`가 패널 열림 시 `hitTest`로 매 마우스 이동마다 갱신한다(카드/✕=그 카드 + pointingHand, 그 외 해제).
  알림 패널은 최상위 모달이라 열려 있는 동안 뒤 사이드바/탭/스크롤바 호버는 끈다(클릭 라우팅과 같은 게이트). **뒤
  콘텐츠의 포커스 테두리(focus border)도 억제한다** — 알림 패널·컨텍스트 메뉴는 키를 잡지만 `InputFocus`(텍스트/IME
  소유자) enum엔 없어, `appendFocusOwnerBorder`가 `inputFocus()`만 봐선 이 둘을 못 걸러 테두리가 **모달 위로** 떴다
  (사용자 리포트). 커서 unfocus와 **같은 단일 판정**(`anyOverlayOpen()`)을 공유하는 가드로 닫아 두 시각 cue를 일치시킨다.
- **빈 상태 일러스트**: 알림이 없으면 헤더 아래 본문에 **종-슬래시 아이콘(🔕) + 굵은 제목("아직 알림이 없습니다") +
  부제("알림이 여기에 표시됩니다.")**를 가로 가운데로 그린다(예전 좌상단 "알림 없음" 한 줄을 대체). 아이콘은
  이모지라 CoreText fallback에 의존 — 실제 렌더로 확인하고 깨지면 BMP 기호로 교체한다(종 글리프와 같은 규율, §5).
- **폭 cap·말줄임**: 패널 폭은 최소~`max_panel_cols`로 cap한다(내용이 길어도 패널이 화면을 가로지를
  만큼 넓어지지 않게 — 사용자 피드백 "maxwidth가 있어서 적당한 크기"). **최소 폭은 상수가 아니라 `minPanelCols()`가
  헤더 라벨(제목 + 두 버튼)에서 잰다** — 언어가 바뀌면 필요한 폭도 바뀌므로 상수로 박으면 영어에서 제목과 버튼이 조용히
  겹친다(i18n 계약 §6.1, `plans/i18n.md` I3c에서 실물로 나온 자리). `min_panel_cols_floor`는 "카드가 답답하지 않은"
  하한으로만 남는다. cap을 넘는 제목/본문은 `overlay_input.truncateToCols`(EAW 폭 기준, 끝에 `…`)로 말줄임한다.
  빈 상태는 제목/부제 폭으로 폭을 잡되 같은 cap을 따른다.
- **말풍선 팝오버(형태)**: `openNotificationPanel`이 content top을 `anchor_y = 2*cell_h + modal_padding_px`로 둔다(단일 출처).
  rich 모달 배경 quad는 lowering(`rasterizeOverlayCells`)이 content rect를 사방 `modal_padding_px`만큼 **outset**하므로
  **보이는** 패널 상단 = `anchor_y − mp` = 줄2(=2ch) — mp를 더해 보이는 상단을 줄2에 맞춘다(안 더하면 보이는 패널이
  `2ch−12`로 종에 거의 붙어 caret 틈이 없다). 종 글리프는 py_nudge(0.30ch)로 줄0에서 ~1.30ch까지 내려오므로, 줄1(빈
  버퍼 행)이 종↔패널 간격이자 **말풍선 caret**(위로 뾰족한 삼각형) 자리가 된다 — **팝업이 종을 안 가린다**(예전 `anchor_y=1ch`는
  종 하단을 덮었다). caret은 chrome 모달 lowering이 셀 그리드(픽셀 정밀 도형은 둥근 quad뿐)라, platform `appendNotificationCaret`이
  `self.gpu_quads`에 `GpuQuad{gradient_kind=3}`(셰이더가 rect 내접 삼각형 + fwidth edge AA로 그림 — 별도 파이프라인/ABI 없이
  quad 채널 재활용) **1개**(surface_bg 채움만)를 종 중심(`(cols-11.5)*cw`)·**보이는** 패널 상단(`panel.y − mp`)에
  append한다(예전 2개[focus_accent 외곽선 + 채움]는 채움 삼각형 빗변의 fwidth edge-AA가 내부까지 부분 커버리지를 줘
  외곽선과 블렌딩, 내부가 패널색 아닌 중간톤으로 떴다 — 단일 채움으로 패널과 같은 색). caret 채움(surface_bg)이 패널
  배경과 **픽셀값까지 같은** 건 rich quad 셰이더의 sRGB 역감마가 표준 2.4라 round-trip이 identity이기 때문(예전 3.0
  지수 버그면 패널만 어둡게 렌더돼 caret과 안 맞았다 — `maru_metal_shader.h srgb_to_linear`). 패널 배경 quad **'뒤'**라
  상단 테두리를 caret 폭만큼 덮어 bubble을 연다. 패널이 세로 clamp로 밀렸거나 종이 보이는 패널 가로 밖이면 caret 생략(어긋남 방지).
- **최소 높이**: 항목이 적어도 팝업이 납작하지 않게 `min_panel_rows`(8, 헤더 포함) baseline을 보장한다 — 헤더+카드는
  상단, 사이 여백은 패널 배경(클릭 무시 = `Hit.background`; 박스 '밖'만 닫기). 카드가 그보다 많으면 자연 높이(화면 cap)로
  커지므로 무영향(`layout` 단일 출처 — view·hitTest 공유). `scrollWindow`는 상단 sticky 헤더(`header_rows`)를 늘 예약하고
  남은 높이로 보이는 카드 수를 정한다.
- **스크롤(화면 넘으면)**: 카드가 화면 가용 높이를 넘으면 **카드 단위 스크롤**(`draw.Op`에 scissor가 없어 부분 카드를
  못 자르므로 통째 카드만 보인다). `State.scroll_offset`(보이는 첫 카드, 0=최신)으로 `items[first..first+visible]`만
  렌더한다. 마우스 휠(패널 열림 시 `scrollWheel`이 가로채 터미널/스크롤백으로 안 흘림)·키보드 ↑↓(선택이 viewport
  밖이면 `ensureSelectedVisible`가 따라 스크롤)로 움직인다. **헤더 밴드(제목+액션)는 viewport 상단 sticky**라 스크롤해도
  안 잘리고, 카드 영역만 스크롤한다. 스크롤 가능하면 카드 영역(헤더 아래) 우측에 얇은 스크롤바 thumb(보이는 비율).

  **자르는 채널이 둘이고 경계가 서로 다르다** — 섞으면 헤더가 사라진다.
  - `Op.Text.clip` **필드**(`card_clip`) = **카드 뷰포트**. 셀 격자 lowering(`metal_lowering.placeText`)이
    글자를 버리는 판정은 이것이고, 셀 단위라 origin이 밖인 행을 통째로 버린다.
  - `.clip` **op**(프레임 scissor, `OverlayRaster.clip_rect` → `PaneFrame.clip_rect`) = **패널 전체**. 오버레이
    **셀 전체**에 걸리므로 카드 뷰포트로 주면 그 위의 헤더 셀이 통째로 잘려 "알림"·버튼 라벨이 사라진다(헤더
    배경·구분선은 GPU quad라 scissor를 안 받아 상자만 남는다). 이 op이 하는 일은 뷰포트 바닥에 걸친 마지막
    행의 **픽셀 잘림**이다 — `Text.clip`은 행 단위라 그걸 못 한다. 그래서 지우지 않고 경계만 패널로 둔다.

  **구분선·카드 배경 폭은 `Layout.card_cols`** (패널 폭 − 스크롤바 gutter, 칸 단위 올림) 하나가 정한다. 텍스트·✕
  배치와 hit-test도 같은 값을 본다. 예전엔 gutter를 배경에만 반영해 막대가 우측 시간·✕를 덮었고, 구분선만 패널
  전폭이라 gutter를 가로질러 스크롤바 뒤로 선이 지나갔다. 보이는 카드 수·상한은 `scrollWindow`
  (개수·화면 높이만 — 휠/키 경로가 Item을 안 빌드하게)가, 선택 끝맞춤 윈도잉은 `overlay_input.windowStart`(palette·
  settings와 공유)가 단일 출처. 다른 오버레이가 열렸을 땐 휠을 소비만 한다(터미널로 안 흘림 — `mouse()` 클릭 게이트와 짝).
- **클릭 → 점프 + 읽음**: 카드 본문 클릭/Enter → `acceptNotification`이 selected(역순: 0=최신)를 히스토리 인덱스로
  되돌려 그 카드의 surface를 봤다는 의미로 **같은 surface의 안읽음을 모두** 읽음 처리(`markNotificationsReadBySurface`
  — 2단계 배너 클릭과 **동일 정책**)하고, `activateSurfaceById(surface_id)`(1단계 재사용)로 점프한 뒤 패널을 닫는다.
  닫힌 surface면 점프 없이 닫기만(카드는 이미 회색). 배너든 카드든 "그 터미널을 봤다"는 한 가지 읽음 정책으로 통일.
- **읽음/지우기 액션 버튼**: 마우스 hit-test는 `Hit` union(`card`/`close`/`mark_all_read`/`clear_all`/`background`)으로 가른다 —
  카드 우측 ✕(본문줄)=개별 삭제(`deleteNotification`), 키보드 Backspace=선택 카드 삭제. **상단 헤더 우측**의 "모두 읽음"
  (`markAllNotificationsRead` — 점/배지만 끄고 항목 유지) / "모두 지우기"(`clearNotifications` — 전체 삭제)를 **버튼**으로 그린다 —
  `confirm` 다이얼로그와 같은 관용구(셀 fill 배경 + 라벨 좌우 패딩 `btn_pad`, 토큰 색; GPU quad 아닌 `.fill`이라 tui/rich 양립).
  **항목이 있으면 활성**(`tab_hover_bg` 배경 + `surface_fg` 라벨, 클릭 가능함이 드러남), **빈 상태면 비활성**(배경 없이 `muted_fg`).
  버튼 [x0,x1) 칸 범위는 `headerActions`가 view(배경 fill)·hitTest(클릭 zone) 단일 출처. 헤더 좌측 제목·버튼 사이 여백·빈 상태
  본문은 `background`(클릭해도 안 닫힘 — 박스 밖만 닫기). unread 캐시는 push/markRead/delete/markAll/clear 헬퍼에서만 증감(단일 출처).
  > 후속: 세 번째 버튼 소비처(예: 세팅 액션)가 나오면 `modal_box`처럼 공유 `button` 프리미티브로 추출해 confirm·notifications·settings가 공유한다.

## 4. 경계 분담 (단일 출처)

### 실행 중 session-host reconnect 안내

reconnect 상태의 원본은 Window별 알림 history가 아니라 app-global notice store의 retained
`{runtime_id,shell_generation,notice_seq}` record다. `SessionHostCoordinator`는 store를 orchestrate할 뿐 reducer나 storage를
직접 구현하지 않는다. Window/AppSession은 자기 Term membership을 확인한 뒤 projection cursor를 ack하며 non-owner poll은
record를 consume하지 않는다. app-global summary cursor와 pane cursor는 별도다. dedup key는
`{incident_id,runtime_id,notice_kind}`다. 250ms 안의
무영향 복구는 조용히 끝내고, 그 이상은 pane 상태줄 `reconnecting`을 표시한다. `recovered`는 paused/rejected input이 있을
때만 incident·runtime당 banner 1회다. raw host 오류와 input/paste 본문은 알림 history나 OS notification에 넣지 않는다.

`paused_paste`, `controller_conflict`, `termination_pending`은 단순 토스트가 아니라 coordinator의 상태에 묶인 in-app action
surface다. paste action은 유효한 완전본에만 `Discard`/`Review Details and Send Full Paste`를 제공하되 본문은 표시하지 않고
길이/hash prefix/시각만 보여 준다. controller conflict는 `Retry`/single-use
`Take Control`을 제공한다. pane 이동은 action authority를 옮기지 않고 새 Window가 같은 ledger를 투영한다. pane close는 action을
revoke하고 paste를 zeroize한다. 이 reconnect 안내는 host-owned OSC notification journal이나 `UNUserNotificationCenter`로
전달하지 않는다.

일반 resolved notice store는 app-global 256 records/256 KiB, TTL 10분이며 oldest resolved부터 evict한다. 죽은 Window의
projection cursor는 Window unregister와 함께 revoke한다. unresolved `PausedPaste`/Take Control/termination action은 일반
notice와 분리된 bounded action ledger가 소유하고 각 기능의 더 작은 item/byte cap을 따른다. 일반 notice overflow는 새 raw
record를 버리고 app-global aggregate count 하나만 갱신하며 modal/banner 폭주를 만들지 않는다.
Take Control은 runtime당 1개/app-global 64개/TTL 60초, termination은 runtime당 1개/app-global 64개/30초 attempt이며
PausedPaste는 session-host 문서의 1 MiB/item·runtime 1개·app 8 MiB·10분 TTL을 따른다.

- **현재 GUI-local 경로**: Zig `AppSession`이 OSC 알림 drain(`pendingNotification`), 업데이트 안내,
  **제목 위치 접두**(`notificationLocation` — `탭 › 팬`), 전면 배너 여부(`foreground_banner`), surface 역조회·
  활성화 순서(`activateSurfaceById`), 히스토리 모델·정렬·상대시간 포맷과 chrome을 소유한다. Swift는
  `UNUserNotificationCenter` 표시/권한/delegate, 창 활성화(`makeKeyAndOrderFront`/`NSApp.activate`),
  legacy `userInfo` 정수 `wt`/`sid`, 전면 표시 스타일(`willPresent`)만 담당하고 정책은 결정하지 않는다.
- **host-backed 경로 — 이 계약 밖**(별도 이니셔티브: [영속 터미널 세션 호스트](persistent-session-host.md)의 P4가 소유하고, 진행은 [검증 매트릭스](verification-matrix.md)가 적는다): 배포물의 `maru-sessiond`는 별도 unsigned helper가 아니라 **서명된 Maru 실행 파일의
  숨김 subcommand**다. 이 process 안의 macOS platform adapter가 host-owned bounded journal을 읽고
  `UNUserNotificationCenter`에 직접 게시한다. 별도 MRSH client/connection이나 GUI `AppSession`을 만들지 않는다.
  stable route는 `userInfo`의 `hid`(32-hex host ID), `rid`(32-hex runtime ID), `eid`(u64 decimal/`NSNumber`)에
  항상 싣고, GUI-live fast hint가 있을 때만 `ae`(app epoch), `wt`, `sid`를 추가한다.
- **cold route — 같은 별도 이니셔티브**: App delegate는 Zig `AppRuntime`/`AppSession`이 아직 없을 수 있는 notification response에서
  `{hid,rid,eid}`를 앱 전역 pending route로 보관한다. manifest load와 host attach가 준비된 뒤
  `activate_runtime_notification` AppRuntime entry point로 정확히 한 번 넘겨 canonical binding 또는
  `Recovered Sessions`를 연다. ABI 번호와 C 서명은 구현 slice N3에서 정하고 Zig/Swift cross-check로 고정한다.
  permission 요청/거부 시 시스템 설정 열기는 계속 GUI 설정 경계가 소유하며, daemon adapter는 현재 권한을 존중하고
  거부를 session 실패가 아닌 degraded notification 상태로 기록한다.
- **현재 ABI**: `app_host_abi.h`의 `MARU_MACOS_APP_HOST_ABI_VERSION` 매크로(+ `app_session.zig` `abi_version` 상수, Zig
  크로스체크가 동기 강제)가 ABI 버전의 단일 출처다. 현재 형태의 알림 함수는 **v76에서 확정**됐다 — `pending_notification`
  (v52 도입 원형에 v76에서 `surface_id` out 추가; `foreground` out 포함) + `activate_surface(session, surface_id) → found`(v76 신설). **v92**에서 세팅 GUI 알림 토글을
  macOS 권한 요청으로 잇는 `take_notification_authorization_request` 1회성 신호를 추가했다. 인앱 알림 센터는 chrome
  오버레이라 추가 ABI가 없다. 이 문단의 ABI는 현재 GUI-local 경로이고 P4 cold-route ABI를 이미 구현했다는 뜻이 아니다.

## 5. 검증

- **단위(Zig 헤드리스)**: `notifications.zig`(state·handle·itemAt 2행·view ops·panelRect clamp), 히스토리 ring buffer
  (push 상한·unread 증감·markRead·formatRelativeTime), `acceptNotification` 역순 매핑, `activateSurfaceById` 역조회,
  **제목 위치 접두**(OSC title=`{탭 › 팬} · {앱 title}`;
  탭 라벨==Term 라벨이면 dedup으로 하나만),
  **비활성 pane/Term OSC drain**(`pendingNotification`이 background split pane Term에 먹인 OSC 9를 그 surface_id로 돌려주고
  그 id로 점프가 비활성 pane을 포커스 — 모든 surface를 훑는지),
  `headerHit` 4-아이콘 zone, **접힘 종 hit-test**(`collapsedNotificationRect` 종 글리프 동심·◧ rect 비겹침·클릭→패널 열림).
- **렌더 1회**: op 방출만으론 부족(modal_box 회귀 전례) — `buildSidebarHeaderFrame`(펼침)·`buildCollapsedToggleFrame`(접힘)이
  공유하는 `appendBellAndBadge` 종/배지 cell + 오버레이 lowering으로 2줄 카드가 cell 그리드에 들어가고 한글 본문이 안
  잘리는지(EAW). **종 글리프(🔔)·빈 상태 종-슬래시(🔕)는 실제 렌더로 fallback 확인** — 깨지면 BMP 기호로 교체
  (`agentSymbolCodepoint` 규율: JetBrains Mono 보유 글리프만). **펼침 원형 배지**는 `MARU_OPEN_NOTIFICATIONS=N`(N개 시드+
  패널 열림) 헤드리스 스크린샷으로 종 우상단 빨강 원 + 흰 숫자(1~9)·10+ "9" cap·◧ 비침범을 확인하고, **빈 상태 패널**은
  `MARU_OPEN_NOTIFICATIONS_EMPTY=1`로 헤더 밴드 + 일러스트(아이콘·제목·부제)를 확인한다. 접힘 종은 `MARU_COLLAPSE_SIDEBAR`로
  ◧↔종 띠 세로 정렬·좌측 텍스트 배지 확인. 빨강 원은 GpuQuad **layer 4**(bg strip 뒤·헤더 글리프 앞)로 흰 숫자 아래에 그려진다.
- **수동 E2E**(`.app` 번들): OSC 알림 → 배너 클릭 → 발신 터미널 점프 / 멀티 윈도우 토큰 라우팅 / 종 클릭 →
  카드 패널 → 항목 클릭 점프 / 안읽음 배지·점. background split pane·가로탭의 OSC 알림 클릭이 탭뿐 아니라 그
  pane/Term까지 포커스하는지 확인한다.

## 6. 범위 밖 (후속)

핵심 알림 기능(클릭→활성화·인앱 센터·읽음/지우기·config·배너↔센터 읽음 동기화·배지 9+·카드 단위 스크롤)은
완결됐다. 추가 알림 채널(OSC 99 등)이나 알림 그룹화는 필요해지면 후속으로 둔다.

**알림 패널 행 단위/픽셀 스크롤(백로그·보류)**: 현재 스크롤은 **카드 단위**(`card_rows`=2행을 통째로 넘긴다). 셀
클리핑(`NativeMetalCell.clip_index`, ABI v169 — `docs/layering-and-portability.md` §7)은 동작하지만 **알림 적용은
보류**한다. 이유: 오버레이 텍스트는 `placeText`가 `@divTrunc`로 셀 행에 스냅하고 viewport(`rows`) 밖이면 자동
skip하므로, 진짜 픽셀-부드러운 스크롤이 텍스트엔 불가하다(셀 그리드 제약). clip의 실익은 배경 quad와 행 단위 부분
카드 정리 정도라 card-unit 대비 이득(마지막 카드 반쯤 보임)이 작고 재작성 복잡도가 크다 — 지금은 card-unit으로 충분.
**필요해지면 "행 단위 스크롤"**(`scroll_offset` 행 기반 + clip으로 viewport 정리; `scrollWindow`·`overlay_input.
windowStart`·스크롤바·휠 게이트는 재사용)로 적용한다. 진짜 부드러운 px 스크롤은 텍스트 셀 그리드를 px 렌더로 바꾸는
근본 작업이라 비권장.
