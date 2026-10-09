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

**원격(SSH) 세션의 에이전트 알림도 이 OSC 행으로 들어온다.** 머리말의 «에이전트 완료 알림은 제공하지
않는다» 와 어긋나지 않는다 — 그것은 **maru 가 관측으로 완료를 판정해 만들지 않는다**는 뜻이고, 여기서는
**provider 가 스스로 쏜 OSC 를 받는 것**이다(발신 판정이 provider 안에 있다). 원격 pane 은 `agent_kind` 가 `none` 이라 훅 모드가
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
  완료다. runner가 없으면 수동 클릭으로 대체하지 않고 P4 notification 제품 gate를 미완료로 둔다. 기본값 전환은
  이 판정과 별개인 G3 release 백로그다.

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

- **host-backed 식별자**: GUI 유무와 관계없이 `userInfo`에
  `{host_id,runtime_id,event_id}`를 필수로 싣는다. GUI가 살아 있으면
  `{app_instance_epoch,token,surface_id}`를 fast-path hint로 추가한다. epoch가 현재 launch와 같고 surface의
  runtime handle도 일치할 때만 즉시 활성화하며, 아니면 stable handle로 attach해 manifest binding을 찾고 없으면
  `Recovered Sessions`에 둔다. `event_id`는 host-lifetime monotonic u64이고 재사용하지 않으며
  `{host_id,event_id}`가 dedup key다.
- **local/quick 식별자**: in-process runtime은 stable host handle이 없으므로
  `{app_instance_epoch,token,surface_id}`만 쓴다(OS `userInfo` 키는 `ae/wt/sid`). `ae`는 실행마다 새 UUID이며 현재 실행과 정확히 일치해야 한다. 누락된 레거시 알림과 다른 실행의 알림은 이동 없이 exact 정리만 한다. `wt/sid`는 양의 정수만 허용한다. 앱 종료와 함께 route도 끝나며 cold attach 대상이 아니다.
  `wt`는 발화 당시 위치 힌트다. 먼저 힌트 창을 조회하고, 없거나 surface가 이동했으면 같은 실행의 다른 일반 창과 quick에서 현재 소유자를 찾는다. 정확한 surface 활성화가 성공한 뒤에만 그 창을 전면으로 올린다. 닫힌 surface는 창 포커스도 바꾸지 않는다.
- **역조회·활성화(Zig)**: `activateSurfaceById(id)` — `findTermWhere`로 `(tab, pane, term)`을 찾아
  **`switchTab → focusPaneByPtr → focusTerm`** 순서로 활성화(focusPaneByPtr는 활성 탭의 panes만, focusTerm은 활성
  pane만 보므로 순서가 강제된다 — 이 계약을 한 메서드에 가둔다). id는 재사용하지 않으므로(단조 증가) stale id가 다른
  surface로 오인 활성화될 위험이 없다(닫힌 Term이면 못 찾아 false = 무동작). 배너를 클릭했으면 그 surface를 본
  것이므로, `activate_surface` export가 `markNotificationsReadBySurface(surface_id)`로 인앱 센터의 같은 surface
  안읽음 알림도 읽음 처리한다(배너↔센터 읽음 동기화 — 닫힌 surface여도 읽음).
- **delegate 타이밍**: `UNUserNotificationCenterDelegate`는 `applicationDidFinishLaunching`에서 **launch 완료 전**
  등록한다(Apple 요구사항 — 앱이 꺼진 상태에서 알림 클릭으로 켜진 콜드 런치의 첫 `didReceive`를 놓치지 않게).
- **exact OS 정리**: `didReceive`는 전달받은 request identifier 하나만 pending·delivered store 양쪽에서 제거한다.
  목록을 열거하거나 `removeAll*`을 쓰지 않는다. 릴리스 검증도 `NotificationExactCleanup` 제품 leaf를 재사용해야 하며,
  별도의 테스트 전용 삭제 정책을 만들지 않는다.
- **quick 패널**: 숨겨진 상태에서도 세션 tick과 알림 drain·셸 종료 처리는 계속한다. Metal 표시만 보일 때 수행하며 숨김 중 generation은 표시 완료로 기록하지 않는다. 알림 대상이 quick 터미널이고 숨김이면 `showQuickTerminalAnimated`로 띄운다(화면 밖에 있는 패널을
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
- **다른 오버레이와의 관계**: 예전 lowering 은 프레임의 오버레이를 raster 하나(bounding box 하나)에 올려 둘을 함께 그리면 겹쳤다 —
  먼저 모인 쪽 글자가 패널 빈 칸으로 비치고, 패널이 넘쳐 프레임 `.clip`(셀 scissor)을 내면 그것이 그리드 **전체**에 걸려 상대 글자가
  잘리며, 첫 둥근 상자만 모달 배경(패딩·그림자)이 되므로 먼저 온 쪽이 그 자리를 가져가 패널이 패딩·그림자 없는 상자가 됐다. 셋 다 그 뒤
  풀렸다 — 첫째는 #4228(뒤 패널이 앞 글자를 가린다), 셋째는 2026-10-07(오버레이마다 첫 둥근 quad 가 패널 — `metal_lowering.lower`),
  둘째는 2026-10-10(`.clip` 을 내는 draw 는 늘 자기 묶음 — `chrome-strategy.md` §5.3). 아래 규율은 **정책**으로 남는다:
  - **notice·confirm 과는 공존하되 같이 그리지 않는다.** 패널을 본 채 비동기 notice(host 연결 실패 재통지·업로드 결과·원격
    감시 포기 등)나 confirm(종료 확인 등)이 뜰 수 있고, 입력은 메시지가 먼저 받는다(notice 는 닫히고 패널은 유지 —
    판정자 「notice 토스트와 알림 패널 공존 …」). 메시지가 떠 있는 프레임엔 패널·스크롤바·말풍선 caret 을 **안 그리고**
    (`notificationPanelDrawn`), 상태는 둬서 메시지가 닫히면 다시 보인다 — 편집기 선택 헬퍼가 쓰는 것과 같은 규율이다.
    안 그리는 패널은 호버도 받지 않고 강조도 비운다(`hoverCursor`). 판정자 「notice·confirm 이 떠 있는 프레임엔 알림
    패널을 안 그리고 …」.
  - **패널을 열 때 다른 오버레이를 단일-오버레이 불변식(`dismissMessageOverlays`)으로 내린다**(심볼·참조 피커를 열 때와 같은
    함수). 포커스 없는 찾기 바·참조 피커는 모달이 아니라 종 클릭을 막지 않으므로, 안 내리면 패널과 겹친다. 팔레트를 열 때처럼
    ⌘G 로 이어 가던 검색도 함께 끝난다. 모달(메뉴·팔레트·세팅·메시지)은 열려 있으면 클릭을 먼저 가져가 종에 닿지 않고,
    메뉴 경로 액션은 `runAction` 의 `anyOverlayOpen` 가드가 막는다. 판정자 「알림 패널을 열면 모달이 아닌 다른 오버레이
    (찾기 바·참조 피커)를 내린다 …」.
  - 이 계약 밖: 마커 이미지 프리뷰의 테두리·안내 상자(`collectMarkerPreviewDraws`)는 이 불변식에 들지 않아 패널과 함께
    그려질 수 있다.
- **최소 높이**: 항목이 적어도 팝업이 납작하지 않게 `min_panel_rows`(8, 헤더 포함) baseline을 보장한다 — 헤더+카드는
  상단, 사이 여백은 패널 배경(클릭 무시 = `Hit.background`; 박스 '밖'만 닫기). 카드가 그보다 많으면 자연 높이(화면 cap)로
  커지므로 무영향(`layout` 단일 출처 — view·hitTest 공유). `scrollWindow`는 상단 sticky 헤더(`header_rows`)를 늘 예약하고
  남은 높이로 보이는 카드 수를 정한다.
- **스크롤(화면 넘으면)**: 카드가 화면 가용 높이를 넘으면 카드 영역이 **픽셀 offset**(`State.scroll.offset_y_px`,
  SV5a)으로 흐른다. `layout`이 offset을 `first`(보이는 첫 카드)와 `origin_shift_px`(그 카드가 위로 밀린 px)로 나누고
  `items[first..first+visible]`만 렌더한다. 마우스 휠·트랙패드(패널 열림 시 `scrollWheel`이 가로채 터미널/스크롤백으로 안
  흘림)는 **카드 단위**로, 키보드 ↑↓는 선택이 viewport 밖이면 `ensureSelectedVisible`가 선택 카드를 맞춰 움직인다. 그래서
  카드가 경계에 **걸친** 상태(offset이 카드 높이의 배수가 아님)는 목록 끝의 상한 clamp·바닥 맞춤·창 크기·폰트 크기·배율
  변경에서 생긴다. **헤더 밴드(제목+액션)는 viewport 상단 sticky**라 스크롤해도 안 잘리고, 카드 영역만 스크롤한다.
  스크롤 가능하면 카드 영역(헤더 아래) 우측에 스크롤바(공용 경로, SV5a-2).

  **자르는 채널이 둘이고 경계가 서로 다르다** — 섞으면 헤더가 사라진다.
  - `Op.Text.clip` **필드**(`card_clip`) = **카드 뷰포트**. 셀 격자 lowering(`metal_lowering.placeText`)이
    글자를 버리는 판정은 이것이고, 셀 단위라 origin이 밖인 행을 통째로 버린다. 놓인 글자는 셀 행에 **내림**
    (`trunc((y − 격자 원점)/ch)`)으로 붙는다.
  - `.clip` **op**(프레임 scissor, `OverlayRaster.clip_rect` → `PaneFrame.clip_rect`) = **패널 전체**. 오버레이
    **셀 전체**에 걸리므로 카드 뷰포트로 주면 그 위의 헤더 셀이 통째로 잘려 "알림"·버튼 라벨이 사라진다(헤더
    배경·구분선은 GPU quad라 scissor를 안 받아 상자만 남는다). 이 op이 하는 일은 뷰포트 바닥에 걸친 마지막
    행의 **픽셀 잘림**이다 — `Text.clip`은 행 단위라 그걸 못 한다. 그래서 지우지 않고 경계만 패널로 둔다.
  - **카드 강조 배경(선택·호버 `.fill`)은 자르는 채널이 없다**(`Op.Fill`에 clip 필드가 없고, 셀 행 단위
    `trunc`로 내려간다). 그래서 컴포넌트가 **글자와 같은 규칙으로 행마다** 낸다 — 제목줄·본문줄 각각, 그 줄의
    origin y가 `card_clip` 안일 때만 한 행. 칠한 행 == 그 카드 글자가 놓인 행이다. 카드 하나를 통째로 내면 위로 걸친
    카드의 첫 행이 헤더 행으로 내림돼 헤더 한 줄이 카드색이 되고(버튼 배경까지 덮는다), 뷰포트 사각형으로 자르면 아래로
    걸친 줄은 글자가 남는데 잘린 배경의 `trunc` 끝이 그 행을 뺀다.
  - **카드 구분선(1px)은 GPU quad라 셀 scissor를 안 받고 셀 행에 붙지도 않는다**(헤어라인 lowering). 그래서 스크롤이
    있으면 컴포넌트가 선을 **두 카드의 글자 줄 사이**에 둔다 — 다음 카드 제목줄이 놓일 행을 글자와 같은 식으로 구해 그
    바로 위 픽셀(= 이 카드 본문줄 행의 바닥)이다. 카드의 픽셀 바닥에 그으면 걸친 만큼 다음 카드 제목줄 안을 가로지른다
    (「● Maru … 방금」 위 취소선). 긋는 조건은 **선 위아래 두 줄이 다 놓일 때**다: 아래 줄(다음 카드 제목줄)이 뷰포트
    밖인데 그으면 선이 패널 밖이나 내용 맨 아래 픽셀(바닥 테두리와 이중선)에 그어지고, 위 줄이 지나간 카드의 선은 헤더
    구분선 자리로 떨어진다. 스크롤이 없으면 카드가 행 경계에서 시작하므로 픽셀 바닥 = 행 바닥이다.
  - **프레임 `.clip`이 있으면 셀 격자 lowering이 bbox 행 수를 올림한다**(`metal_lowering.lower`). 위 `.clip` op의 계약
    (뷰포트 바닥에 걸친 마지막 행을 픽셀로 잘라 보인다)이 그래야 성립한다 — 내림이면 그 행이 격자에 없어 글자가 통째로
    사라진다. 넘친 몫은 같은 clip이 자른다. `.clip`을 내는 overlay는 알림 패널뿐이다.
  - 위 규칙들은 **격자 원점 = 패널 y** 를 전제한다 — 패널은 `.clip` 을 내므로 2026-10-10 부터 lowering 이 늘 자기 묶음(자기 격자)으로
    둬 늘 참이다(`chrome-strategy.md` §5.3; 그 전에는 패널 혼자 오버레이 raster 를 쓰는 프레임에서만 참이었다). 판정자 「알림 패널: 걸친
    카드의 강조 배경은 헤더·뷰포트 밖을 칠하지 않고 …」(`metal_lowering.zig`)가 제품과 같은 lowering으로 위·아래 경계 ×
    걸침 전 구간 × 선택/호버/강조 없음 × 셀 높이·패널 y·뷰포트 높이 조합을 돌려, 강조 행 == 글자 행, 걸친 줄이 실제로
    그려짐, 구분선 집합 == 「본문줄과 다음 제목줄이 둘 다 놓인 카드 쌍마다 그 사이 하나」(출력 셀에서 따로 구한다)를 본다.
  - **줄이 놓이는 행은 `placedRow` 하나가 정한다** — 콘텐츠 기준 줄 L(= 카드 × `card_rows` + 줄)의 origin 은 카드 영역
    위끝에서 `L·ch − O`(O = 상한으로 깎인 픽셀 offset)이고, 그것이 뷰포트 안이면 행 `⌊(header_h + L·ch − O)/ch⌋`(패널 y
    기준)에 놓인다(`placeText` 규칙을 옮긴 유일한 사본). 강조 배경·카드 구분선·클릭/호버가 모두 이것을 부른다.
  - **클릭·호버(`hitTest`)도 그 행으로 푼다** — 보이는 줄 == 눌리는 줄. 포인터가 있는 셀 행에 놓인 줄의 카드를 잡고,
    줄이 안 놓인 행(바닥에 걸쳐 글자를 안 그린 줄 — 아래)은 `background` 다. 본문줄 우측의 ✕ 칸과 그 오른쪽 여백
    1칸(카드 폭 끝까지)이 ✕(삭제)이고, 그 오른쪽 스크롤바 gutter 는 카드가 아니라 `background` 다. 픽셀 카드 경계로 풀면
    `offset mod ch ≠ 0` 인 동안 **줄마다** 위쪽 띠(최대 `ch − 1` px)가 한 줄 위로 잡혀, 호버 강조가 틀린 카드에 뜨고 다음
    카드 제목줄 위쪽의 ✕ 칸 클릭이 **앞 카드 삭제**로 풀린다. 같은 판정자가 패널 x·y·셀 높이·뷰포트 조합과 걸침 전 구간에서
    뷰포트 안 모든 픽셀 행(정수·반 픽셀)·여섯 열(본문·✕ 왼쪽·✕·카드 끝·gutter·패널 끝)의 `hitTest` 가 출력된 줄과 같은지 본다.
    패널 안 동작은 좌클릭만 한다(우클릭·중클릭은 ✕ 위에서도 아무것도 안 한다 — 되돌릴 수 없는 삭제라서).
  - **이 계약 밖(남은 어긋남)**: 스크롤은 픽셀이고 글자·강조·구분선·클릭은 행에 내림으로 붙는다. 그래서 걸친 상태(`offset mod ch
    ≠ 0`)에서 뷰포트 바닥에 걸친 줄은 origin이 뷰포트 밖이면 글자가 없다(그 띠는 클릭도 안 잡힌다). 근본 해법은 offset을
    셀 높이의 배수로 두는 것이다(아래 §6). 또 `Op.Fill`에는 clip 필드가 없어(`Op.Text.clip`과 달리) 다음에 픽셀 스크롤하는
    셀 격자 컴포넌트도 같은 함정을 만난다 — lowering이 텍스트와 같은 행 규칙으로 fill을 자르는 일반 해법은 그때 연다.
  - **재현**: 디버그 훅을 묶어 실제 앱 화면을 찍는다 — `MARU_OPEN_NOTIFICATIONS=40 MARU_NOTIF_SCROLL_PX=<P>
    MARU_NOTIF_HOVER=<K> MARU_SCREENSHOT=/tmp/n.ppm MARU_SCREENSHOT_DELAY_MS=2500`. P 는 backing px 이고, 맨 위에 걸친 카드
    번호 K = ⌊P ÷ 카드 높이⌋, 카드 높이 = `card_rows`(2) × 셀 높이(backing px)다. 격리 `HOME`·`MARU_SESSION_HOST_ROOT`와
    함께 쓰고, 격리 config 에 `session.keep-alive-after-quit = false`를 둬 host 연결 실패 notice가 끼지 않게 한다.

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
- **host-backed 경로**: 배포물의 `maru-sessiond`는 별도 unsigned helper가 아니라 **서명된 Maru 실행 파일의
  숨김 subcommand**다. 이 process 안의 macOS platform adapter가 host-owned bounded journal을 읽고
  `UNUserNotificationCenter`에 직접 게시한다. 별도 MRSH client/connection이나 GUI `AppSession`을 만들지 않는다.
  stable route는 `userInfo`의 `hid`(32-hex host ID), `rid`(32-hex runtime ID), `eid`(u64 decimal/`NSNumber`)에
  항상 싣고, GUI-live fast hint가 있을 때만 `ae`(app epoch), `wt`, `sid`를 추가한다.
- **cold route**: App delegate는 Zig `AppRuntime`/`AppSession`이 아직 없을 수 있는 notification response에서
  `{hid,rid,eid}`를 앱 전역 pending route로 보관한다. manifest load와 host attach가 준비된 뒤
  `activate_runtime_notification` AppRuntime entry point로 정확히 한 번 넘겨 canonical binding 또는
  `Recovered Sessions`를 연다. ABI 번호와 C 서명은 Zig/Swift cross-check로 고정한다.
  permission 요청/거부 시 시스템 설정 열기는 계속 GUI 설정 경계가 소유하며, daemon adapter는 현재 권한을 존중하고
  거부를 session 실패가 아닌 degraded notification 상태로 기록한다.
- **현재 ABI**: `app_host_abi.h`의 `MARU_MACOS_APP_HOST_ABI_VERSION` 매크로(+ `app_session.zig` `abi_version` 상수, Zig
  크로스체크가 동기 강제)가 ABI 버전의 단일 출처다. 현재 형태의 알림 함수는 **v76에서 확정**됐다 — `pending_notification`
  (v52 도입 원형에 v76에서 `surface_id` out 추가; `foreground` out 포함) + `activate_surface(session, surface_id) → found`(v76 신설). **v92**에서 세팅 GUI 알림 토글을
  macOS 권한 요청으로 잇는 `take_notification_authorization_request` 1회성 신호를 추가했다. 인앱 알림 센터는 chrome
  오버레이라 추가 ABI가 없다. host-backed cold route의 검증 상태와 provisioned 배포 gate는 [검증 매트릭스](verification-matrix.md)가 소유한다.

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

핵심 알림 기능(클릭→활성화·인앱 센터·읽음/지우기·config·배너↔센터 읽음 동기화·배지 9+·스크롤)은
완결됐다. 추가 알림 채널(OSC 99 등)이나 알림 그룹화는 필요해지면 후속으로 둔다.

**알림 패널 행 단위 스크롤(백로그)**: 스크롤 상태는 픽셀(`scroll_area.State`, SV5a)이고 셀 클리핑(`NativeMetalCell.clip_index`,
ABI v169 — `docs/layering-and-portability.md` §7)과 `Op.Text.clip`으로 걸친 카드를 자른다(위 §「자르는 채널」). 오버레이
텍스트는 셀 격자라 진짜 픽셀-부드러운 스크롤은 텍스트에 불가하고, 그 차이가 위 「이 계약 밖」 어긋남으로 남는다. 필요해지면
offset을 셀 높이의 배수로 두는 **행 단위 스크롤**로 정리한다 — 상한 clamp·바닥 맞춤의 결과를 행에 붙이는 동작 결정이 따르므로
따로 정한다. 진짜 부드러운 px 스크롤은 텍스트 셀 그리드를 px 렌더로 바꾸는 근본 작업이라 비권장.

## 훅 완료 알림 유예 (2026-10-02)

훅 완료 알림은 해당 pane의 lead와 추적한 자식이 모두 끝난 뒤 1.5초 동안 종료 상태를 유지해야 발송한다.
그 사이 작업 재개·입력 대기·취소·턴 또는 세션 전환이 오면 예약을 버린다. 발송 직전에 pane의 상태와 턴 세대를
확인하고 턴당 한 번만 보낸다. 다른 pane이 작업 중이어도 종료된 pane은 알릴 수 있다.
오류 알림의 즉시 발송과 주의 알림의 기존 디바운스는 유지한다. 세부 계약과 참고 근거는
[에이전트 훅 §6](agent-hooks.md#6-알림-정책)을 따른다.
