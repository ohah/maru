# 에이전트 세션 도크 — 카드 레이아웃 (§2.1~§2.1.3)

Metal GPU 카드 레이아웃과 컴포넌트 경계, 레퍼런스 정렬 시각 계약, 측정형 Button·action text, logical spacing·dock metric의 계약이다. 어느 슬라이스가 이것을 구현했는지는 [구현 계획](plans/agent-session-list.md)이 소유한다.

> **절 번호는 파일을 넘어 이어진다.** 본문이 `§2.1.3`처럼 절만 가리키면 아래에서 소유 파일을 찾는다 — §1~§2·§2.3·§3~§5·§7~§8 [agent-session-list.md](agent-session-list.md) · §2.1~§2.1.3 [카드 레이아웃](agent-session-list-layout.md) · §2.2 [선택·확장·geometry](agent-session-list-interaction.md) · §2.1.4·§6 [구현 계획](plans/agent-session-list.md)

### 2.1 Metal GPU card layout와 컴포넌트 경계

이 화면은 React·WebView·외부 UI kit을 추가하지 않는다. `agent_sessions`는 다른
chrome과 같은 Zig semantic draw → Metal GPU lowering 경로를 쓰는 custom dock이다. 다만
조합 방식은 작은 독립 primitive를 쌓는 design-system 패턴을 따른다. 즉
`app_session.zig`가 header 문장·scope 문장·카드 문장을 직접 이어 붙여 그리는 것은
금지한다. platform host는 archive snapshot을 immutable props로 투영하고, 순수
컴포넌트가 같은 layout model로 `view`와 `hitTest`를 만든다. 이 경계는
[Chrome 전략](chrome-strategy.md)의 `State + view + hitTest + Action` 계약을 따른다.

```text
┌ SessionDockHeader ───────────────────────────────────────────┐
│ Agent 세션 기록                 N개 표시 · 최근 500개        │
│ [host] 로컬                                [refresh/spinner] │
├ SegmentedScopeControl ────────────────────────────────────────┤
│ [현재 작업공간] [현재 프로젝트] [전체]                        │
├ SessionSearchField ───────────────────────────────────────────┤
│ ⌕ 세션 검색                                                   │
├ SessionDockScrollArea ────────────────────────────────────────┤
│ ⌄ workspace-name                                         228 │
│   ┌ SessionCard ────────────────────────────────────────────┐ │
│   │ Codex badge                         제목                │ │
│   │ 마지막 사용자 요청의 안전한 짧은 요약                   │ │
│   │ 메시지 140개 · 22시간 전 · gpt-…                        │ │
│   └────────────────────────────────────────────────────────┘ │
│   ┌ SessionCard …                                            │ │
└───────────────────────────────────────────────────────────────┘
```

#### 2.1.1 레퍼런스 정렬 시각 계약 (AS4-e)

AS4-d의 inline disclosure는 동작 이관이다. 이 절은 첨부 레퍼런스와 비교했을 때 남아 있던
"작은 terminal 행들의 집합" 인상을 없애기 위한 **별도 시각 계약**이다. 데이터·action·scroll
identity는 바꾸지 않으며, `SessionDock`의 같은 completed `UiRectTree`에서만 기하와 paint를 바꾼다.
아래 contract의 pixel geometry는 `DockMetrics` snapshot 하나가 결정한다. 진행·검증 상태는
[검증 매트릭스](verification-matrix.md)의 해당 행을 따른다.

- dock의 자동 폭 640pt 안에서 fixed chrome(header·segmented scope·search)와 scroll-area는 같은
  20pt 좌우 content inset·clip rect를 공유한다. 따라서 refresh의 trailing slot과 목록 divider가
  dock 밖으로 overflow하거나 서로 다른 경계에 놓이지 않는다. group disclosure는 이 content rect
  안에서 별도의 8pt leading slot만 쓴다. 즉 root inset을 다시 20pt 더하지 않아 chevron·목록을
  불필요하게 안쪽으로 밀지 않는다. 이 기하는 **terminal cell**이
  아니라 Chrome의 logical spacing/type token과 `SessionDockUiZoom`을 합성한 dock scale에서만 결정한다.
  header·scope·search는 scroll하지 않고, group부터만 scroll한다. terminal font family·line spacing을
  바꿔도 도크의 버튼 여백·목록 밀도·hit rect가 바뀌어서는 안 된다. 단, `Cmd`+`+`/`-`/`0`의 font-size
  비율은 750–1500 milli로 clamp된 `SessionDockUiZoom`이므로, 이 명시적 zoom에는 모든 dock rect와 hit rect가
  함께 확대·축소된다.

  **이 불변식은 기하에만 걸린다 — face는 명시적으로 예외다.** 도크 텍스트는 `font.family`(+`font.fallback`
  cascade)로 그린다. 같은 화면의 사이드바가 사용자 monospace인데 도크만 시스템 UI face면 앱이 사용자
  폰트 설정을 절반만 따르기 때문이다(사용자 결정 2026-08-08). 규칙과 폴백은 [폰트 전략](font-strategy.md)의
  "Chrome 텍스트 face"가 단일 출처다. face가 바뀌어도 위 기하는 불변이다 — 카드 높이·여백·hit rect는
  `lineHeightPx(role)` 파생이고 role 토큰은 `font.size`와 독립이다. 바뀌는 것은 같은 rect 안에 들어가는
  **글자 수**뿐이다(monospace는 덜 들어가므로 `…` 잘림이 는다).

  다만 이 불변식에는 **알려진 예외**가 하나 더 있다: `Writer.textInsetStyled`가 텍스트 폭 예산을
  `floor(available_px / cell_width_px)` cols로 양자화하고 `opMaxWidthPx`가 그것을 다시 px로 되돌린다.
  그래서 터미널 폰트 **크기**를 바꾸면 잘림 경계가 최대 1 cell 폭만큼 움직인다. rect·여백·hit rect는
  영향을 받지 않으므로 위 계약의 핵심(밀도·hit rect 불변)은 유지되지만, "terminal font를 바꿔도 아무것도
  안 움직인다"는 아니다. 폭 예산을 logical pt로 옮기는 것은 별도 작업이다.
- header는 title(강조) → count(secondary)의 좌측 두 줄과 Maru 등록 host SVG + `로컬`/refresh의 우측
  utility cluster를 서로 독립 logical slot으로 둔다. title/count/utility가 한 baseline 또는 terminal
  prompt처럼 보이지 않아야 한다. host+label은 72pt content box, refresh는 **24pt trailing slot**,
  둘 사이는 12pt gap이며 이 x 좌표는 terminal cell 폭에서 계산하지 않는다. refresh slot의 trailing
  edge에는 **20pt logical safe inset**을 더 둔다. 이 inset은 backing scale에서만 resolve하며 idle·busy
  refresh SVG의 ink·hit rect가 dock clip 또는 우측 edge에 닿지 않게 한다. Header 자체는 reference처럼
  외곽 card border를 그리지 않되, header의 **bottom 1px divider**는 `divider` token으로 반드시
  lower한다. 이것이 scope/search/group/list의 경계가 사라져도 된다는 뜻은 아니다: refresh SVG의
  전체 ink box는 24pt slot 안에 있어야 하고, 1× readback에서 slot의 우측 끝과 dock content edge
  사이에는 20 logical pt가 남아야 하며 header·group·row 구획선도 읽혀야 한다.
- scope는 하나의 rounded outlined control이며 selected segment만 lifted background를 갖는다. search는
  같은 radius 계열의 별도 filled field이며 16pt content inset, 18pt registered SVG, 8pt gap 뒤에
  measured placeholder/query/preedit/caret을 둔다. icon·텍스트는 terminal cell baseline을 공유하지 않고
  각각의 logical rect 중앙에 lower한다.
- **scope는 action button이 아니라 필터 세그먼트다.** 높이 하한은 48pt action 최소치가 아니라 30pt이며,
  그래서 검색 필드(48pt)보다 확실히 낮은 얇은 필터 줄로 읽힌다. 48pt를 같이 쓰면 도크 상단이 같은 덩치의
  컨트롤 두 줄로 꽉 찬다(사용자 보고 2026-08-11). pointer target 최소치(그룹 행 48pt)보다 낮은 것은
  의도다 — 세그먼트는 가로로 도크 1/3폭(자동 폭 640pt에서 약 200pt)을 차지해 타깃 **면적**은 그 행보다
  넓다. 한때 26pt까지 내렸다가 되돌린 값이다(사용자 2026-08-12: "너무 줄였다") — 계산상 바닥은 control
  line box 17pt이지만, 실제로 얇아 보이는 한계는 그보다 높다.
- **세그먼트 label과 정렬 토글 label은 measured `center_in_rect`로 자기 slot 중앙에 놓고, 폭 예산으로는
  slot 폭을 `max_width_px`에 그대로 싣는다.** lowering은 예산을 `max_width_px orelse max_cols *
  cell_width`로 푼다(`chrome_draw_lowering.zig`의 `textWidthBudget`). 예전 cell 격자 경로
  (`textInsetStyled`)는 `max_width_px`를 안 실어서 예산이 `floor(available/cell_width)` cell 배수로
  깎였고, 그래서 slot에 실제로 들어가는 글자까지 worker가 보기 전에 잘렸다 — `오래된순`이 잘려 보인
  사용자 보고가 그것이다. 같은 경로가 x도 `rect.x + cell_width`로 잡아 label을 slot 왼쪽에 붙였다.

  **정렬 토글을 발행할 폭인지는 utility 폭만으로 정하지 않는다.** 판정에는 제목 최소 폭(48pt,
  `header_title_min_w`)이 함께 들어간다. utility 폭만 보면 제목 폭 0을 허용하게 되고, 그러면
  `view.headerStack`의 `available_px <= 0`에 걸려 **토글은 떠 있는데 제목도 개수도 없는 헤더**가 나온다 —
  "그 구간에서는 토글보다 무엇을 보고 있는지가 먼저다"라는 원래 의도가 정확히 뒤집힌 상태다.

  **slot 폭을 키우는 것은 잘림 결함의 해법이 아니다**(양자화는 그대로다). 단일 출처는 `max_width_px`이고,
  `max_cols`는 legacy cell 백엔드(Lab·폴백) 전용 상한으로만 남으므로 **보수적인 `floor`**여야 한다 —
  `ceil`이면 그 경로에서 라벨이 slot을 최대 1 cell 넘겨 이웃 세그먼트를 침범한다. 정렬 slot 84pt는
  그와 별개로 한글 4자에 좌우 여백을 주기 위한 값이다(72pt는 도크 텍스트가 사용자 monospace face일 때
  빠듯했다).
- group은 위아래 rule과 20pt disclosure slot·8pt label gap·workspace name·count pill을 갖는 독립
  header다. count pill의 치수·자리(최소 폭 44pt, 최대 높이 32pt, 반지름 = 높이/2, 행 세로 중앙,
  라벨 상자 중앙, 안 들어가면 안 그림)는 `chrome/ui/badge.zig`가 소유한다 — 컴포넌트 view가 그
  산수를 다시 풀면 갈린다(pill이 행 밖으로 내려가 아래 카드에 걸친 회귀가 그 산수였다). 기본 session row는
  반복된 외곽 card 대신 full-width divider 목록이고, title은 bold, summary는 muted, provider와
  metadata는 마지막 baseline의 두 slot으로 분리한다. 각 row는 최소 6행을 써 title과 summary,
  metadata가 붙어 보이지 않게 한다. divider는 interactive active 색이 아니라 panel background에서
  명암 반대 방향으로 파생한 semantic color를 쓴다. dark/light theme 모두에서 surface background와
  정확히 같은 RGB가 될 수 없고, 1px rule은 panel의 각 RGB channel에서 최소 24 step 차이를 가져
  축소된 PNG에서도 scope/search 외곽과 group/row rule이 읽혀야 한다. row는 card별 외곽선을 추가하지
  않지만, group 상·하단과 각 row bottom rule을 생략해서는 안 된다.
- row의 trailing disclosure chevron은 카드의 **logical content inset** 안에 놓이며(터미널 cell 폭이
  아니다), title·summary·provider·metadata의 폭 예산은 그 slot과 최소 gap을 함께 뺀 값이다. 최종
  ellipsis는 measured advance가 정하지만 예산 자체가 slot을 덮고 있으면 잘린 텍스트가 아이콘에 그대로
  맞닿아 둘이 한 덩어리로 읽힌다. slot 위치와 텍스트 예산은 `DockMetrics`의 같은 항에서 나와야 한다.
- 선택/expanded session은 card header와 dark raised detail surface를 한 disclosure 안에 묶는다.
  detail은 outer padding을 가진 inset surface, recent-turn은 role/body 사이 여백, action은 최소
  3행 높이의 같은 baseline 버튼으로 보인다. sibling action에는 최소 `0.5ch` gap을 두고, 각 button은
  그 gap을 제외한 남은 row 폭을 동등하게 나눈다. 여기서 "남은 row 폭"의 기준은 **dock content rect**이며
  detail의 inset이 아니다 — action row는 detail surface의 형제이지 그 자식이 아니기 때문이다. action의
  hit rect·clip·scroll height는 이 여백을 포함한 동일 tree rect다. action row 높이는 축소 대상이 아니다:
  button content 높이가 label line box보다 작아지면 label과 icon이 함께 사라져 **활성처럼 보이는 빈 상자**가
  남는데, 이는 §2.1.2가 금지한 상태다. disclosure는 도크가 소유하므로 선택·확장·닫기는 새 `Term`, tab, surface 또는
  pane body를 만들지 않는다. 따라서 archive detail 때문에 terminal focus·workspace persistence·PTY
  lifecycle에 별도 예외가 생기지 않는다.
- rich Chrome은 radius/border/shadow token을 사용하고, tui legacy lowering은 같은 rect/spacing을
  직각 fill로만 lower한다. component가 `if (rich)` 또는 font별 좌표 nudge를 두지 않는다.

`ChromeTextRole`은 role별 line box와 final-pixel glyph placement를 전달한다. 기본 목록은 compact
Chrome scale(`card title` 14pt, `summary`/`body` 13pt, `metadata` 12pt, `dock heading` 16pt)을 사용한다.
이 절대값은 terminal `font.*`와 **독립**이지만(그 독립성이 위 계약이다) 값 자체는 조정 가능한 결정이며,
같은 화면의 터미널 글자보다 도크가 커 보인다는 사용자 보고로 한 차례 낮춘 결과다. 단일 출처는
`src/chrome/ui/typography.zig`의 role 토큰이고, 이 문단은 그 값을 서술한다 — 한쪽만 바꾸지 않는다. B1-button-b는 확장
action의 measured label/SVG group centre를 완료했고, AS4-f-b는 기본 목록·header utility·detail·action의
고정 기하와 scroll unit을 같은 `DockMetrics` snapshot으로 옮겼다. terminal cell은 텍스트의 보수적
수평 truncate fallback에만 남고, padding·height·pointer hit rect는 입력으로 쓰지 않는다. 이를 cell 수를
억지로 키우거나 fallback font별 nudge로 흉내 내지 않는다.

#### 2.1.2 측정형 Button·action text 계약 (B1-button)

`Button`은 click 가능한 `Card`의 별칭이 아니다. 최종 `Button` 계약은 `primary`/`secondary` visual,
enabled/disabled state, 한 개의 published `UiAction`, `label`과 선택적 leading icon slot을 가진 독립
semantic leaf다. 현재 `UiNode.button` 구조 slice는 visual·action·border box까지 소유하고 label/icon은
component view의 immutable draw op로 분리해 둔다. label/content DTO를 tree leaf로 승격하기 전까지 이
경계를 완료라고 부르지 않는다. `Card`는 정보 표면과 disclosure container를, `Button`은 명시 command
target을 표현한다. generic tree/paint/interaction은 둘의 rect·clip·pointer capture·disabled inertness를
같은 completed snapshot에서 소비하되, action의 색·border·focus/pressed feedback을 card variant에서
추론하지 않는다.

- Button content는 fallback cell 수가 아니라 platform text artifact가 반환한 **actual glyph advance**로
  button content rect의 수평 중심을 계산한다. label이 너무 길면 leading icon slot·양쪽 inset을 먼저
  보존하고 같은 artifact가 CJK/fallback glyph까지 포함해 ellipsis를 만든다. hit rect는 줄어든 text rect가
  아니라 원래 button border box다.
- Button의 line box와 icon optical box는 button content rect의 세로 중앙에 정렬한다. 이 정렬은
  `font.family`/terminal cell height를 입력으로 삼지 않고 Chrome primary/fallback face와 scale의 measured
  artifact만 따른다. 임의의 font별 y offset이나 fixture 전용 좌표 보정은 금지한다.
- SessionDock의 `터미널에서 이어하기`는 primary Button, `로그 보기`와 정확한 live mapping이 생긴 뒤의
  `열린 세션으로 이동`은 secondary Button으로 render한다. loading/stale/unavailable은 같은 button rect를
  유지하되 disabled이며 action table에서 실행 불가다. `⌘↵`/`⌘L`은 pointer와 동일한 published action identity를
  resolve한다.
- Button semantic node는 text artifact/renderer를 소유하거나 provider/PTY를 import하지 않는다. component는
  immutable label·icon·intent만, platform text adapter는 measured placement DTO만, host는 explicit effect
  dispatch만 소유한다. 따라서 다른 Chrome component가 동일 Button을 재사용해도 archive 권한이나 session
  identity가 섞이지 않는다.
- B1 capture는 system UI primary와 Jetendard에서 1×/2× 각각 action의 ink box가 border box 안에 있고,
  두 sibling label의 visual center가 같은 action-row center에서 1 backing pixel 이내임을 PNG/JSON으로 남긴다.
  text artifact가 없거나 fallback만 선택되면 캡처 성공으로 표시하지 않는다.

#### 2.1.3 logical spacing·dock metric 계약 (AS4-f)

AS4-f는 레퍼런스와의 여백·밀도 차이를 Chrome logical metric으로 고친다. `ButtonMetrics`는 action의
icon/text content inset, icon extent/gap, 48pt minimum target을 소유한다. `DockMetrics`는 outer inset,
fixed chrome/card/detail/action 높이와 scroll unit을 같은 immutable snapshot으로 resolve한다. terminal
font family·line spacing은 dock geometry·pointer hit rect의 입력이 아니며, backing scale과
`SessionDockUiZoom`만 비례한다. `SessionDockUiZoom`은 현재 font size / `Cmd`+`0` 기준 font size를
750–1500 milli로 clamp한 값이며, layout·worker text scale·fingerprint·paint·hit-test·scroll projection이
반드시 같은 resolved value를 사용한다. zoom 전 viewport top을 가로지르는 card identity는 old metric에서
capture해 새 metric projection으로 restore하며, card가 없거나 materialize되지 않으면 기존 bounded numeric
offset만 새 상한으로 clamp한다. typed layout과 spacing SSOT, 48pt action target·1×/2×/terminal-font
capture 판정은
[Metal UI 레이아웃·컴포넌트 시스템](metal-ui-layout-button.md#logical-spacing과-component-metric)이 소유한다.
이 visual slice는 실제 사용자 Claude/Codex resume을 자동 실행하지 않는다.

이 독립성은 카드 내부에만 한정하지 않는다. terminal font family/line spacing은 terminal grid/title icon에는
영향을 줄 수 있어도 Session Dock의 header, scope, search, card, expanded card, resume/reveal border rect의
backing 좌표를 바꾸지 않는다. 반면 명시적 `Cmd` font-size zoom은 동일한 Dock tree 전체를 함께 확대·축소한다.

**이 규칙은 `agent_sessions`만의 예외가 아니라 도크 전체의 것이다.** `explorer`·`source_control`도 같은 값을
쓰며, 뷰를 바꾼다고 어떤 rect도 움직이지 않는다.

**이 두 밴드는 창 전폭 계약이다.** 왼쪽 사이드바 헤더의 아이콘 줄·검색 줄도 같은 띠와 바를 쓴다 — 창 상단은 좌우가
한 줄로 읽혀야 하고, 사이드바만 `cell_height` 배수에 묶여 있던 동안 검색 줄이 탭 바와 어긋났다(사용자 보고
2026-08-09). 밴드 정의와 헤더 glyph의 밴드-중앙 배치는 [file-explorer.md](file-explorer.md) §3.5가 소유한다.

**단, 상단 view switcher와 도크 시작선은 여기서 빠진다.** 둘 다 terminal 쪽과 한 줄로 맞아야 하기 때문이다.
시작선은 terminal과 **같은 상단 띠**(`titlebar_strip_px` = 펼침 28pt / 접힘 30pt)를 쓴다 — 예전에는 도크만
28pt 고정 band를 따로 받았는데, 그러면 사이드바를 접을 때 두 상단 바의 시작선이 갈려 아래 경계선을 맞춰
놔도 어긋나 보인다(사용자 보고). **그 띠는 terminal 폰트에 무관하다** — 한때 `max(cell 높이, 28pt)`였으나
그러면 큰 폰트에서 도크 rect가 통째로 밀려 아래 계약이 깨진다(실측: 14pt↔24pt에서 12px 이동).

그 바의 **높이**도 같은 이유로 여기서 빠진다. 그 바는 terminal tab bar와 아래 경계선을 맞춰야 하는
유일한 도크 chrome이라(사용자 보고: 두 바가 어긋나 보인다), `DockMetrics`의 40pt를 혼자 쓰지 않고 두
chrome이 공유하는 logical token(`chrome.tokens`의 `space.bar_height_pt`)을 본다 — 이 문서가 예전에
"정렬이 필요하면 terminal 쪽이 아니라 두 chrome이 공유하는 logical token을 새로 만든다"고 적어 둔 그
해법이다. 방향이 반대라는 점이 핵심이다: 도크가 terminal 식을 물려받는 게 아니라 terminal 쪽이 도크의
40pt를 함께 본다.

**그 token에 terminal cell을 `@max`로도 섞지 않는다.** 한때 `@max(pt, cell + 2*pad)`였는데, 그러면 도크
기하가 terminal 폰트에서 나와 위 계약이 깨진다 — 실제로 깨졌고(14pt↔24pt 도크 rect 12px 이동,
`tab_bar_pad_y_px`가 backing px 고정이라 1x↔2x 비례도 이탈) `font-scale-rects` fixture가 잡아냈다. 셀 항이
막으려던 것(큰 폰트에서 탭 제목이 바 밖으로 넘침)의 원인은 탭 제목이 terminal 셀 그리드로 렌더된다는
점이며, 해법은 그 텍스트를 chrome 폰트로 옮기는 것이지 chrome을 폰트에 묶는 것이 아니다. 높이의 단일
출처와 그 아래 텍스트 세로 정렬 규칙은
[file-explorer.md](file-explorer.md) §3.5가 소유한다. `DockMetrics`의 나머지 필드는 그 바 **아래** 도크
본문의 치수라 계속 Dock UI zoom에만 비례한다.
