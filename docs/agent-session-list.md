# 에이전트 세션 기록 도크 (Codex·Claude)

우측 도크의 `agent_sessions` 뷰가 보이는 **로컬 과거 세션 기록**의 단일 출처다. 진행·검증 상태는 [검증 매트릭스](verification-matrix.md)의 "에이전트 세션 기록 도크" 행, 구현 순서는 [실제 구현 계획](implementation-plan.md)의 AS1~AS4가 소유한다.

## 1. 목표와 경계

목표는 첨부된 레퍼런스처럼 제목·요약·provider·메시지 수·갱신 시각을 가진, 검색 가능한 최근 세션 목록이다. v1 provider는 **Codex와 Claude Code만**이다. 둘 다 사용자가 이미 자신의 Mac에서 만든 JSONL 이력을 읽을 뿐, provider API·계정·네트워크를 사용하지 않는다. **열려 있는지, Maru가 만든 것인지와 무관하게** 검증된 사용자 세션은 모두 같은 목록 후보이며, 기본 범위는 `전체`다.

이 목록은 다음과 엄격히 다르다.

| 구분 | 권위 | 용도 |
| --- | --- | --- |
| live agent | 열린 `Term`과 child PID의 환경 변수 | 현재 pane의 상태·마지막 교환·사이드바 표시; archive 행의 optional `열린 세션으로 이동` 표식 |
| `SessionArchive` | provider가 쓴 닫힌/과거 JSONL의 불변 스냅샷 | 도크 이력 검색·선택·명시적 재개 |

따라서 `agent_transcript.zig`의 256 KiB tail cache나 사이드바의 현재 Term 매핑을 archive index로 재사용하지 않는다. 그것들은 빠른 현재 상태용이며, 역사 목록의 완전성·중복 제거·보안 경계가 아니다. 파일 내용 편집, 원문 대화 뷰어, 다른 provider, 자동 재개, provider hook 설치와 원격/SSH 이력은 v1 범위 밖이다.

아래 계약은 Maru의 `SessionArchive`에 독립적으로 적용한다. 외부 레퍼런스 정책은 [references.md](references.md)를 따른다.

## 2. 화면과 상호작용

```text
Agent 세션 기록                              로컬   [새로 고침]
N개 표시                                      [최신순 ⇄ 오래된순]
[현재 작업공간] [현재 프로젝트] [전체]
[⌕ 세션 검색]
────────────────────────────────────────────────────────────────
⌄ project-or-workspace                                      12
  제목                                                     Codex
  마지막 사용자 요청의 안전한 짧은 요약
  메시지 140개 · 22시간 전 · gpt-…
  ────────────────────────────────────────────────────────────
  제목                                                   Claude
  마지막 사용자 요청의 안전한 짧은 요약
  메시지 94개 · 3분 전 · claude-… · 서브에이전트 4
```

### 2.3 카드가 싣는 값과 정렬

카드의 `메시지 N개`는 전체 transcript를 세어 얻는다. 목록 스캔이 파일 전체를 읽으므로(§4) 정확하며,
이 값을 근사치로 낮추는 대가로 읽기를 줄이지 않는다 — 요약이 **마지막** 메시지에서 나오기 때문에
앞뒤 일부만 읽는 방식은 목록의 30%가 틀린 요약을 보이게 한다(실측 2026-08-08).

`서브에이전트 N`은 Claude 세션 파일과 같은 이름의 디렉터리 아래 `subagents/`의 transcript 개수다.
**파일을 열지 않고 디렉터리 항목만 센다** — 순회 비용은 이미 지불한 것이고 read budget과 무관하다.
0이면 그리지 않는다. 값은 스캔 시점 기준이므로 다음 refresh까지 갱신되지 않는다. Codex는 worker가 별도
파일이 아니라 같은 rollout 트리에 섞여 있어 부모 세션과 연결할 규칙이 없으므로 이 표시의 대상이 아니다.

정렬은 **최신순**이 기본이고 토글로 **오래된순**을 고른다. 정렬 키는 transcript의 마지막 활동 시각이며,
그 값을 얻지 못하면 파일 mtime으로 폴백한다 — mtime은 대화 외의 이유(복사·도구의 메타 갱신)로도 밀리기
때문에 내부 시각이 있으면 그쪽이 정확하다. 토글은 **표시 계층에서만** 방향을 바꾸고 스캔 순서는 항상
최신 우선이다(부분 publish가 최신부터 차오르는 것과 같은 근거).

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
[Metal UI 레이아웃·컴포넌트 시스템](metal-ui-layout.md#logical-spacing과-component-metric)이 소유한다.
이 visual slice는 실제 사용자 Claude/Codex resume을 자동 실행하지 않는다.

이 독립성은 카드 내부에만 한정하지 않는다. 도크를 고르는 상단 switcher는 `DockMetrics`의
40pt이고, right dock의 시작선은 terminal title strip이 아니라 28pt native-title safety band다.
따라서 terminal font family/line spacing은 terminal grid/title icon에는 영향을 줄 수 있어도 Session Dock의
header, scope, search, card, expanded card, resume/reveal border rect의 backing 좌표를 바꾸지 않는다. 반면
명시적 `Cmd` font-size zoom은 동일한 Dock tree 전체를 함께 확대·축소한다.

**이 둘은 `agent_sessions`만의 예외가 아니라 도크 전체의 규칙이다.** view bar와 도크 시작선은 도크가
소유한 chrome이므로 `explorer`·`source_control`도 같은 값을 쓴다. 예전에는 그 둘만 pane tab bar와
높이를 맞췄는데(`terminal cell 높이 + padding`, 시작선은 `max(cell 높이, 28pt)`), 그러면 같은 아이콘
세 개가 뷰를 바꿀 때마다 오르내리고(실측 53px ↔ 80px) terminal font 크기가 도크 기하를 정하게 된다 —
[레이어링과 이식성](layering-and-portability.md)이 막으려는 방향이다. 그 대가로 도크 view bar와 terminal
tab bar의 높이는 더 이상 일치하지 않는다. 이것은 의도된 선택이며, 정렬이 필요하면 terminal 쪽이 아니라
두 chrome이 공유하는 logical token을 새로 만든다.

#### 2.1.4 B1-button 이관 순서

기존 action은 등록 SVG icon과 한글 label을 한 terminal-cell run으로 합쳐 `wide_icons=true`로 낮췄다.
그 결과 icon이 아닌 label까지 CoreText worker를 우회해 CJK advance·ellipsis·line box를 잃었다. B1-button은
이 결합을 다음 순서로 해체한다.

1. **B1-button-a (완료)** — component는 icon과 label을 별도 semantic draw op로 낸다. icon은 기존
   등록 SVG glyph path를 유지하고, label은 `wide_icons=false`인 measured system-text artifact로만 shape한다.
   action rect 안의 보수적 icon-slot·gap 예약은 그대로 두며, label의 CJK ellipsis와 vertical line box는
   platform artifact가 결정한다. 이 단계는 label이 terminal cell/fallback font 폭으로 다시 lower되는 회귀를
   막는 데 목적이 있고, 전체 icon+label group의 수평 중심이 final-pixel이라는 주장은 하지 않는다.
2. **B1-button-b (완료)** — component는 button border box에서 양쪽 content inset만 선언하고, platform
   text request에는 `center-in-content` 또는 `leading-icon-group` 정책을 함께 싣는다. worker는 같은
   immutable result에서 (a) native primary/fallback shaping 뒤의 실제 label advance, (b) truncation 뒤 label의
   final-pixel origin, (c) registered SVG icon의 optical box·gap·final-pixel origin을 산출한다. main actor는
   font identity를 renderer record로 resolve할 뿐 CoreText를 다시 부르지 않으며, SVG record는 `glyph_id=0`
   합성 경로와 동일 shared atlas를 통해 그 placement를 소비한다. 그때만 group의 수평/수직 중심과 overflow clip을
   실제 measured content rect로 완료 처리한다. `leading-icon-group`의 icon extent와 gap은 `ButtonMetrics`
   logical spacing과 current backing scale에서 정해지며 terminal cell height·사용자 terminal font는 입력이 아니다. 매 frame
   main actor CoreText 호출, font별 nudge, cell-column으로 worker 결과를 역산하는 구현은 금지한다.

   - `leading-icon-group`은 `content_width - icon_extent - gap`을 label의 최대 width로 넘긴다. worker가 만든
     ellipsis의 advance를 다시 읽어 `icon + gap + label` 전체를 content rect의 정확한 가운데에 놓는다. label이
     비어 있거나 shape에 실패하면 icon-only action을 추측해 활성화하지 않고 해당 artifact를 publish하지 않는다.
   - `center-in-content`는 leading icon 없는 action에 쓰며, 동일하게 measured label advance 하나만으로 수평
     중심을 결정한다. pointer/key hit box와 disabled state는 변하지 않는다.
   - artifact의 icon record는 ordinary CoreText glyph인 척하지 않는다. 등록 codepoint, mono foreground, 목표
     raster extent, final placement만 전달하며, renderer의 registered-SVG coverage gate가 이를 검증한다.

- `SessionDockLayout`이 header, scope, search, scroll-area, group header,
  card, scrollbar의 pixel rect를 **한 번만** 계산한다. `view`, pointer
  hit-test, virtualized visible-row 범위, keyboard scroll이 이 결과를 함께
  소비한다. 그러므로 카드가 보이는 곳과 클릭 영역, scroll origin은 서로 다른
  행/문자열 계산으로 갈라질 수 없다. fixed chrome과 scroll-area는 같은 bounded content rect를
  공유하고, group disclosure만 그 안의 8pt local slot을 쓴다. 그러므로 `tmp` 같은 workspace group의
  chevron은 root padding을 다시 더한 위치가 아니라 shared content edge 기준 local slot의 가운데에 놓이고,
  header의 `로컬`/refresh utility와도 서로 다른 baseline·hit rect를 공유하지 않는다.
- virtualization의 세로 평행이동은 scroll-area **subtree 전체**에 적용한다. expanded card는 header/detail/action을
  가진 container이므로, 직계 자식만 옮기면 펼쳐진 detail이 스크롤 전 y에 남아 지나간 카드 위에 겹쳐 그려지고
  그 action의 hit rect도 보이는 곳과 어긋난다. 각 entry는 평행이동한 자기 clip을 이미 평행이동한 부모 clip과
  다시 교차해, paint·clip·hit-test가 계속 같은 completed tree 하나만 소비하게 한다.
- **목록 아이템은 viewport에 맞춰 축소되지 않는다.** scroll-area는 `fill` container이고 아이템은 그 flex 자식이라,
  총합이 viewport를 넘으면 일반 flex 규칙은 자식을 균등 축소한다. 그런데 virtualization은 마지막 아이템이 항상
  viewport를 넘도록 창을 잡으므로 그 축소가 상시 상태가 되고, published rect가 `DockMetrics`와 갈라진다. 그러면
  scroll projection과 view의 텍스트 offset(둘 다 축소 전 metric을 읽는다)이 보이는 위치와 어긋나고, 축소된 action
  rect 안에서는 label line box가 들어가지 못해 버튼이 배경만 남은 빈 상자가 된다. 스크롤 목록은 넘치면 **잘려야**
  하고 줄어들어서는 안 된다.
- **클리핑은 emit 시점 판정이 아니라 backend의 픽셀 연산이다.** component는 자기 op이 스크롤 영역에 속하는지만
  표시하고, 뷰포트 사각형은 backend가 프레임마다 published tree에서 읽어 GPU 경로로 넘긴다. text는 glyph quad를
  뷰포트와 교차시키며 잘린 비율만큼 atlas UV를 함께 좁혀 **픽셀 단위로** 자르므로, 반쯤 걸친 카드·그룹의 글자도
  잘린 그대로 보인다. component가 "이 줄이 clip 안에 통째로 들어가는가"를 미리 판정해 통째로 버리는 방식은
  금지한다 — 1px만 벗어나도 그 줄 전체가 사라지고, 판정 기준이 카드(줄 단위)와 그룹(행 단위)처럼 갈라지면 어느
  한쪽만 고정 chrome 위로 새는 결함이 생긴다. 카드/버튼 배경 quad는 generic paint가 이미 같은 published clip과
  교차시키며, component가 직접 만드는 장식 quad(그룹 count pill 등)도 같은 규율을 따른다.
- `SessionDockHeader`는 title, displayed/recent count, host SVG와 `로컬`
  provenance, refresh affordance만 소유한다. host+label은 72pt box 안에서 실제 glyph advance로
  함께 중앙 정렬하고, refresh는 그 오른쪽 12pt gap 뒤의 24pt trailing slot에 둔다. refresh가 실행 중이면 같은 위치의
  control은 muted·disabled registered refresh SVG로 바뀌며 다시 누른다고 worker를 더 만들지 않는다. 현재
  Chrome component에는 SVG transform/rotation 계약이 없으므로 terminal Unicode clock을 대체 spinner로
  쓰지 않는다. 그것은 1-cell ink라 클릭 순간 control이 작아 보이는 회귀를 만든다. refresh는
  group body가 아니고 항상 고정 chrome이다. idle/busy 모두 같은 registered SVG와 trailing slot을 유지하며,
  header 오른쪽 외곽이 아니라 20pt logical safe inset 안에 정렬해
  fallback font 또는 icon ink가 rounded-card clip에 닿지 않게 한다. Header의 bottom divider는 카드
  외곽선이 아니라 fixed chrome과 아래 control을 구분하는 1px rule이다. provider·원격 source 선택기 같은
  별도 filter control은 v1에 추가하지 않는다.
- Header refresh와 search affordance는 일반 Unicode/fallback font glyph를 쓰지 않고 등록된
  SVG coverage icon을 쓴다. idle refresh는 `surface_fg`, disabled busy refresh는 `muted_fg`라서
  theme accent가 어두운 경우에도 utility icon의 대비가 사라지지 않는다. idle refresh와 group
  expand/collapse affordance는 `icon_in_rect`의 명시 logical slot으로만 lower한다. 즉 terminal
  cell origin·glyph baseline·source viewBox ink가 아니라 component가 소유한 24pt slot의 정확한
  중심이 최종 SVG 위치를 결정한다. icon의 코드포인트·slot·hit rect는 component가 함께 소유하며,
  raw provider 문자열에는 `wide_icons`를 절대 적용하지 않는다.
- 한 줄 control(`작업공간`/`프로젝트`/`전체`, search, group)은 completed rect의 정확한 세로 중앙에
  그 role의 line box를 놓고, 두 줄 header는 **heading/supporting role의 실제 line-height 합**으로 만든
  전체 stack을 rect 중앙에 놓는다. virtualized card는 partial clip에서 보이는 line을 없애지 않도록 기존
  top-origin line stack을 유지한다. paint·clip·hit-test는 계속 같은 completed tree만 소비하며,
  font의 ink/baseline 보정은 `TextLayoutArtifact`가 맡는다. 따라서 이 slice는 font advance를 추측해
  개별 label을 nudge하지 않는다.
- AS4-f-b 뒤 기본 목록의 `SessionCard`는 title·summary·metadata **3행**을 유지하는 full-width divider
  목록이다. 각 행의 높이·내부 inset·행 사이 규칙은 Chrome type/spacing token으로 정하며, 반복된 외곽
  card나 카드별 임의 margin으로 목록을 성기게 만들지 않는다. 요약을 임의로 여러 줄로 reflow하거나
  card마다 가변 높이를 만드는 변경은 아니다. scroll projection·paint·clip·hit-test는 같은 `DockMetrics`를
  읽으므로 밀도 변경 뒤에도 보이는 위치와 눌리는 위치가 갈라지지 않는다.
- `SegmentedScopeControl`은 세 개의 동일 폭 segment와 selected/disabled/focused
  state를 각각 그린다. pipe-separated text label이나 group처럼 보이는 제목줄로
  대체하지 않는다. `SessionSearchField`는 search icon, placeholder, query,
  focus ring/caret를 별도 surface로 그린다. 검색은 이미 publish된 snapshot을
  필터할 뿐 worker를 시작하지 않는다.
- `SessionDockScrollArea`만 목록을 scroll한다. header/scope/search는 scroll과
  무관하게 상단에 남고, workspace group만 독립적으로 접힌다. `CollapsibleWorkspaceGroup`
  header는 chevron·이름·count와 full-width hit target을 가지며, selected
  scope가 아니라 각 group의 collapse state만 바꾼다.
- scroll-area는 목록이 **실제로 넘칠 때만** 우측에 scrollbar를 낸다. 스크롤 컨테이너의 일반 계약
  (발행 위치와 clip, thumb 비율·최소 높이·색, track/thumb의 drag 선언, tick이 소비 지점이라는 것)은
  [ScrollArea](scroll-area.md)가 단일 출처다. 도크에 고유한 것은 둘뿐이다: 스크롤바는 도크의 20pt
  root inset **여백 안**에 놓여 카드·버튼과 겹치지 않으며(나타나고 사라져도 목록 폭이 reflow하지 않는다),
  그 기하는 published `content` rect에서 유도해 두 번째 기하 출처를 만들지 않는다.
- 우측 도크는 하나이며 outer divider의 수동 폭도 모든 뷰가 공유한다. 다만 workspace에
  저장된 `dock.size == 0`은 **자동 폭** sentinel이므로, `agent_sessions`는 제목·세그먼트·검색·카드
  metadata가 같은 줄에서 읽히고 긴 한글 제목도 불필요하게 잘리지 않는 기본 **640pt**를 사용한다. `explorer`와 `source_control`의 자동 폭은
  기존 **180pt**를 유지한다. 사용자가 divider를 드래그해 0이 아닌 값을 저장하면 view 전환은 그 값을
  바꾸거나 640pt를 다시 저장하지 않는다. 작은 창에서는 공통 terminal floor와 outer-divider clamp가
  최종 폭을 결정한다. 자동 폭이 다른 view로 전환되면 같은 input event에서 모든 terminal pane grid와
  active pane rect를 재계산한다. 즉 별도 세션 도크·뷰별 영속 폭을 만들지 않고, 자동 상태에서만
  consumer의 가독성 요구를 반영한다.
- `SessionCard`는 `provider badge`, title, summary, metadata라는 **명시적
  slot**을 가진다. title/provider를 같은 raw text run으로, 또는 전체 카드를
  terminal guidance 문자열로 만들지 않는다. 선택/hover/focus background는 카드
  rect 전체에 적용하고 provider badge에는 provider를 나타내는 색 이외의 명령
  의미를 부여하지 않는다. summary와 metadata는 overflow에서 line clamp/ellipsis만
  허용하며 다른 카드나 카드 hit target으로 넘치지 않는다.
- initial scan은 `SessionDockLoadingState`로 header spinner와 3-line skeleton
  cards를 보인다. 완료 snapshot이 하나라도 있으면 같은 loading state가 header
  spinner와 작은 진행 문구만 덧그리며 **기존 cards·선택·scroll을 유지**한다.
  spinner는 이미 frame loop가 제공하는 animation phase만 읽고 I/O·parse·worker
  wait를 하지 않는다. empty·partial·error는 skeleton을 완료 목록처럼 보이게
  하지 않고 각각의 truthful notice를 scroll-area 안에 낸다.

`ExpandedSessionCard`는 선택한 카드 **하나만** 우측 도크 목록 안에서 여는 Metal GPU
inline disclosure다. card click/Enter는 새 archive tab이나 terminal surface를 만들지 않고
같은 stable identity를 다시 누르면 닫는다. 이것도 terminal에 ANSI guidance를 write하는 방식이
아니라 같은 Metal component/layout/lowering 경로를 쓴다.

```text
┌ SessionDockScrollArea ─────────────────────────────────────────┐
│ ⌄ selected session title                                  […] │
│   provider · model · relative age                                │
│   ┌ ExpandedSessionCard ──────────────────────────────────────┐ │
│   │ 최근 대화 (선택된 세션만)                                  │ │
│   │ [사용자/에이전트] 안전하게 정규화한 최근 turn 최대 3개     │ │
│   │ 도구/권한 관련 기록 n건 (payload 원문 없음)                │ │
│   ├ actions ─────────────────────────────────────────────────┤ │
│   │ [▶ 터미널에서 이어하기] [로그 보기]                        │ │
│   │ [열린 세션으로 이동] (exact live identity가 있을 때만)     │ │
│   └───────────────────────────────────────────────────────────┘ │
│ ⌄ ordinary session title                                   […] │
└─────────────────────────────────────────────────────────────────┘
```

- inline expansion은 `closed/loading/stale/unavailable/ready` state를 자체적으로 표현한다.
  `closed`는 기본 세 줄 행이며, 다른 card를 열면 이전 identity는 atomically `closed`가 된다.
  loading은 Metal-rendered spinner와 skeleton turn으로, stale/unavailable은 이유와
  disabled action으로 보인다. 이전 안전한 detail을 다른 identity에 재사용하지
  않는다.
- ready expansion은 bounded detail worker가 만든 최근 turn과 `도구/권한 관련 기록
  n건`만 보여 준다. 권한·도구 payload, 환경 변수, 명령 출력, raw JSONL은
  expansion·tooltip·trace 어느 곳에도 표시하지 않는다. `로그 보기`는 source reveal만
  하며, `터미널에서 이어하기`는 exact
  argv 새 local Term을 즉시 연다. action 앞에는 기존 Chrome 합성 벡터 아이콘을 **명시적으로 opt-in한 2-cell slot**으로 써,
  terminal font의 작은 Unicode 기호에 의존하지 않는다. 하나의 detail card 안에서 논리적으로 개행된
  text line은 cell height의 1/4(최소 3px) 여백을 둬 제목·role·본문이 붙어 보이지
  않으며, 그 여백은 expansion height/clip과 함께 계산한다. 별도의 raw transcript, 실행 전 preview, 자동
  resume, `새 세션에서 계속` action은 이 계약 밖이다.
- exact provider/session identity의 live Term을 다시 검증했을 때만 `열린 세션으로
  이동` 보조 action을 expansion action row에 추가한다. 이 action의 존재 여부가 card 순서,
  archive 후보, resume/reveal identity를 바꾸지 않으며, path·mtime 유사성만으로
  버튼을 보이게 하지 않는다.
- `SessionDockHeader`, `SegmentedScopeControl`, `SessionSearchField`,
  `CollapsibleWorkspaceGroup`, `SessionCard`, `SessionDockScrollArea`,
  `ExpandedSessionCard`는 각각 props/state/layout/view/hit-test/action을
  노출하는 Metal UI primitive다. component는 `AppSession`, provider file, PTY,
  `NativeMetalCell`을 import하지 않는다. host가 stable archive identity를 action에
  붙이고 backend만 semantic draw를 glyph/cell/GPU primitive로 lower한다.

### 2.2 선택·확장·geometry 계약

- `SessionDockProps`는 `expanded_identity: ?ArchiveIdentity`와 그 identity에만 결합된
  immutable `ExpandedSessionProps`를 받는다. `selected` boolean만으로 expanded를
  추측하거나 row index를 persistent identity로 쓰지 않는다. snapshot generation 또는
  `(provider, session_id, device, inode)`가 달라지면 expansion/capture/focus/action table을
  함께 폐기한다.
- `SessionDockLayout`은 기본 card와 expanded card의 높이, 내부 recent-turn card,
  tool/permission summary, action row, divider, scrollbar을 **한 번** 계산한다. view, clip, pointer hit-test,
  keyboard focus, visible row window, scroll anchor가 같은 completed tree를 쓴다. 선택 행의
  content만 host가 별도 y-offset으로 덧그리거나 click rect를 재계산해서는 안 된다.
- expanded height는 최대 3 recent-turn slot, summary slot, action row의 **고정된 예약 높이**에서
  결정한다. ready content가 짧으면 turn slot 안에서만 빈 영역을 줄이고, loading/stale/unavailable도
  같은 outer rect와 action slots를 유지해 pointer target이 frame마다 점프하지 않게 한다.
  recent turn은 최대 3개이며, tool/permission summary가 없으면 그 section을 숨기되 action row와
  outer padding은 남긴다. nested subagent transcript/목록은 provider 입력 정책과 개인정보 범위 밖이므로
  expansion에 투영하지 않는다. 따라서 모든 세션을 미리 detail parse하거나
  모든 행을 항상 큰 card로 만들지 않는다.
- anchor가 expanded card보다 위이면 open/close가 같은 anchor의 screen y를 보존한다. anchor가
  선택 card 자신이면 title row가 content clip 안에 남도록 최소 scroll만 보정한다. group collapse,
  filter/scope 변경, snapshot identity 교체는 expansion을 닫고 기존 AS3-c identity-first fallback을
  적용한다. 숫자 offset만으로 이전 expanded row를 추측해 다시 열지 않는다.
- title/summary/metadata는 기본 행의 기존 typography role을 유지하되, selected title row는
  title·chevron·more action의 visual center를 같은 baseline artifact로 정렬한다. expansion의
  role label, body, pill, button은 비례 font의 measured advance와 line-height를 사용한다.
  terminal cell count나 fallback glyph ink에 맞추어 label별 nudge를 두지 않는다.
- pointer/Enter는 card disclosure만 toggle하며 provider를 실행하지 않는다. `터미널에서 이어하기`,
  `로그 보기`, `열린 세션으로 이동`은 expanded action table의 distinct enabled intent여야 한다.
  `⌘↵`/`⌘L`은 expanded ready state에서만 같은 intents를 호출하며, closed/loading/stale state에서는
  no-op이다. Escape는 search를 먼저 닫고, 그 다음 expanded card를 닫는다.

- header의 `로컬`은 현재 사용자 홈 아래 provider log만 읽는다는 provenance label이며 host 선택기가 아니다. v1 정렬은 mtime 내림차순 하나로 고정한다. 탭 재진입은 현재 앱 실행 중의 snapshot을 즉시 보이고, 마지막 완료 scan 뒤 **15초** 안이면 새 refresh를 시작하지 않는다. `SessionDockHeader`의 refresh control은 이 TTL을 우회한다. worker가 실행 중이면 동일 rect의 muted registered refresh/disabled state로 바뀌고 추가 job을 만들지 않는다.
- 도크 view bar의 `AI 세션`을 누르면 archive refresh를 요청한다. **refresh 중에는 직전 완료 snapshot과 current scroll/selection을 그대로 paint하고, 새 bounded scan 전체가 끝난 뒤에만 새 immutable snapshot으로 한 번에 교체한다.** AS3-c부터 교체 commit은 first partially-visible card의 exact identity와 intra-card pixel offset을 restore하고, identity가 없으면 기존 numeric offset만 새 상한에 clamp한다. 결과 큐의 OOM 등 새 snapshot을 publish할 수 없는 완료는 spinner만 끝내고 기존 목록과 scroll/selection을 유지하며 notice를 보인다. 따라서 새로 고침이 기존 목록을 비우거나 첫 record/중간 batch로 목록을 흔들지 않는다. 첫 진입처럼 이전 snapshot이 없을 때만 skeleton/진행 문구를 보이며, frame tick에서 파일 I/O를 하지 않는다. 창 재포커스와 새 provider session identity 감지는 같은 refresh를 요청하되, forced refresh는 5초 전역 throttle로 합친다. filesystem polling/watcher는 v1에 없다.
- scope는 `현재 작업공간`, `현재 프로젝트`, `전체`다. 기본값은 `전체`이며 마지막 선택만 창 UI 상태로 보존한다. **`현재 작업공간`은 활성 워크스페이스 탭의 활성 local Term이 마지막으로 보고한 CWD를 worker가 canonicalize한 단일 root snapshot 아래에 `cwd`가 있는 기록**이다. 창 전역 탐색기 root와 다른 권위이므로, 다른 워크스페이스 탭의 폴더가 섞이지 않는다. `현재 프로젝트`는 같은 active Term CWD에서 worker가 찾은 canonical git root 아래 `cwd`가 있는 기록이며, local CWD 또는 git root가 없으면 각각 비활성화한다. `전체`는 모든 provider의 검증된 사용자 세션이다. remote/불명 `cwd`는 전체에서만 보인다. 도크 진입, scope click, 활성 workspace/pane/Term 전환 **및 같은 활성 pane의 CWD 보고 변경**에서 root snapshot을 갱신하며, 결과가 오기 전에는 이전 tab 또는 이전 CWD의 범위를 재사용하지 않는다. CWD 비교는 main actor의 메모리 observation만 사용하고 canonicalize·git walk는 worker만 수행한다. 이후 scope/search/scroll/frame은 그 메모리 snapshot만 읽는다.
- 이 필터는 접근 제어가 아닌 표시 범위다. 경로는 provider log의 `cwd`를 canonicalize할 수 있을 때만 containment 비교하며, 실패·삭제·비로컬 값은 workspace/project에 억지로 넣지 않는다.
- 검색은 이미 publish된 snapshot만 대상으로 한다. search field click 또는 `/`가 `query + IME preedit` 입력 owner를
  활성화한다. marked text는 field와 native IME 후보창에만 즉시 보이고, commit된 query만 목록 필터를 바꾼다.
  Esc는 query/preedit를 함께 지우고 닫으며, Backspace는 UTF-8 codepoint 경계를 지킨다. UTF-8 byte substring
  (ASCII만 case-insensitive)으로 제목·요약·cwd leaf·branch·model을 찾고 입력은 256 byte로 자른다. 검색 키·IME
  입력은 재스캔·파일 stat·정렬을 일으키지 않으며 terminal PTY로 새지 않는다. 한국어처럼 case가 없는 문자열은 정확 byte
  match로 검색된다.
- 최근 window는 provider를 합쳐 mtime 내림차순 최대 500 **검증 완료** 세션이다. 후보 탐색 상한 또는 parser byte budget 때문에 더 오래된 항목을 보장하지 않으므로 header와 empty state는 항상 `최근`이라고 말하고 `전체 이력`이라고 주장하지 않는다.
- fixed chrome은 header·scope segmented control·검색뿐이다. scope control은 **그룹 헤더가 아니며**, 목록 본문을 밀거나 선택된 세션의 detail/action으로 대체하지 않는다. 목록의 workspace/project 그룹만 본문에서 독립적으로 접고 펼친다.
- 기본 그룹은 canonical `cwd`의 프로젝트/폴더 이름이다. cwd가 없거나 project 밖이면 `알 수 없는 위치` 한 그룹으로 낸다. 각 그룹 header는 chevron·이름·표시 개수를 갖고 click/Left/Right로 접고 편다. 접힌 그룹은 header만 남기며 다른 그룹과 고정 chrome의 위치는 바꾸지 않는다. 그룹 접힘은 현재 view 수명 안에서만 유지하며 JSONL이나 workspace에 저장하지 않는다.
- 세션 행은 **세 줄 카드**다: 제목과 provider badge, 마지막 사용자 요청의 안전한 짧은 요약, 메시지 수·상대 시각·model metadata. 카드 내부의 provider/title/summary를 한 줄 label로 합치거나 raw JSONL line을 그대로 표시하지 않는다. 행 제목은 provider 고유 제목이 있으면 그것, 없으면 첫 신뢰 가능한 사용자 요청의 single-line prefix(최대 120 display bytes), 끝내 없으면 `제목 없는 세션`이다. 요약은 마지막 사용자 요청 우선, 없으면 마지막 assistant text의 single-line prefix(최대 240 display bytes)다. raw escape/control byte·경로 외 홈 사용자명은 렌더 전에 제거/일반화하며 Markdown/ANSI를 해석하지 않는다.
- `메시지 n개`는 전체 파일을 budget 안에서 끝까지 분석한 경우만 정확한 수다. cap에 걸리면 `메시지 ≥n개`, 아직 분석하지 않았으면 메시지 수를 생략한다. 숫자를 추정치처럼 표시하지 않는다.
- 한 번 클릭/Enter는 provider를 실행하지 않고 **도크 안의 해당 card를 확장**한다. 도크 목록의 fixed header/scope/search는 움직이지 않으며, expanded detail/action은 선택 row 바로 아래 같은 scroll area 안에만 나타난다. expansion은 PTY 없는 Metal-rendered read-only component이고, 먼저 `세션 분석 중` 상태가 되어도 UI를 막지 않는다. detail worker가 source를 no-follow로 다시 열어 `(device,inode)`를 대조한 뒤 마지막 **512 KiB** 안의 완결 JSONL record만 해석해, 안전하게 정규화한 최근 세 user/assistant turn과 `도구/권한 관련 record n건`처럼 원문을 숨긴 action 요약만 publish한다. raw JSONL·tool payload·환경 변수·명령 출력의 전체 원문은 expansion에 넣지 않는다. tail 밖의 더 오래된 대화·불완전 마지막 JSON line은 의도적으로 표시하지 않는다.
- expansion의 `터미널에서 이어하기`와 `로그 보기`는 명시 action이다. 각각 `⌘↵`, `⌘L`로 실행하고 ready action row에 shortcut을 보조 정보로 표시한다. `로그 보기`는 source-reveal만 수행하고, raw JSONL을 terminal에 paste하거나 WebView에 trusted content로 넣지 않는다. 같은 identity를 다시 선택하면 expansion을 닫고, 다른 identity를 선택하면 먼저 이전 expansion의 detail request/action capture를 폐기한 뒤 새 하나를 연다. snapshot 교체 뒤 source identity가 달라지거나 detail worker가 재검증에 실패하면 expansion은 stale 상태로 남기고 resume/reveal을 비활성화한다.
- `터미널에서 이어하기`는 사용자가 그 명시 버튼을 누르는 즉시 새 local Term 탭을 만들고 활성화한다(추가 확인 dialog 없음). shell 없이 정확한 argv로 실행한다: Claude는 `claude --resume <session-id>`, Codex는 `codex resume <session-id>`. 실행 cwd는 archive record의 canonical local cwd가 아직 directory일 때만 쓰며, 아니면 새 Term의 기본 cwd와 함께 "원래 cwd를 찾지 못함"을 보여 준다. 기존 Term에 키를 주입하지 않는다. 이 action은 worktree를 생성·선택·변경하지 않는다.
- open live Term과 provider+session id가 정확히 일치하면 expansion에 **부가 동작**으로 `열린 세션으로 이동`을 제공한다. 이것은 archive 후보 선정·정렬·표시를 바꾸지 않으며, 일치하지 않는 과거 세션도 완전히 같은 행으로 보인다. mapping은 live session identity가 다시 검증된 경우만 만들며 path/mtime 유사성으로 추정하지 않는다.
- 새 focus owner `agent_session_list`가 선택 identity `{ provider, session_id, source_file_identity }`를 소유한다. Up/Down, PageUp/PageDown, Home/End는 보이는 카드를 움직이고, Right/Left는 그룹을 펼치고 접으며, Enter는 selected card expansion을 toggle한다. Escape는 search focus를 먼저 해제하고 그 다음 expansion을 닫는다. 도크를 떠나거나 snapshot 교체 뒤 identity가 사라지면 선택과 expansion을 해제한다. `⌘⇧E`는 기존대로 탐색기로 돌아간다.
  이 키들은 **도크가 실제로 키보드를 갖고 있을 때만** 도크 동작이다. 소유권은 도크 안 primary down이 주고,
  도크 밖 primary click·view 전환·도크 접기/펴기가 놓는다(선택·expansion·scroll 위치는 유지). 도크가 보이는
  것만으로는 부족하다 — 선택된 카드가 남아 있다는 이유로 터미널에서 친 Enter를 도크가 가져가면 셸의 명령
  실행이 조용히 사라진다. 수식키 없는 `/`(도크 검색 열기)와 `Escape`(expansion 닫기)도 같은 게이트를 쓴다 —
  전자는 경로·정규식 타이핑의 첫 글자를, 후자는 vim의 Esc를 삼킨다. 반면 `⌘↵`/`⌘L`은 어떤 경우에도 PTY
  바이트가 아니라 앱 명령이므로 이 focus 게이트를 쓰지 않는다. 대신 **소비는 실행의 결과여야 한다**:
  published ready expansion이 없어 실행할 것이 없으면 키를 삼키지 않고 keybind resolver로 흘려보낸다.
  삼키면 메뉴 항목이 없는 액션 바인딩과 터미널 매크로(`keybind = Cmd+L = text:…`)가 조용히 죽는다
  (메뉴 항목이 있는 액션은 AppKit keyEquivalent가 먼저 가져가 이 경로에 오지 않는다).
  도크 검색은 **소유권을 놓을 때 함께 blur**한다(사이드바 검색의 blur와 같은 규율 — 비활성만 하고 검색어는
  보존, 조합 중이던 IME preedit는 확정). 검색은 활성인 동안 모든 키를 소비하므로, blur가 없으면 터미널로
  돌아온 뒤의 타이핑 **전체**가 도크 검색으로 들어간다. 완전히 비우는 것은 Esc의 몫으로 남는다.
  이 소유권은 **session-level 상태**여야 한다. 도크의 component-local `InteractionState.focused`는 published
  node id라, 카드를 여는 바로 그 클릭이 snapshot을 무효화하면서(그리고 action이 `item` → `card_header`로
  옮겨가면서) 지워진다 — 그 값으로 판정하면 카드를 연 직후 Enter로 다시 접을 수 없다.
  view bar로 `AI 세션`을 켜는 것은 소유권을 주지 않는다(도크 **내용**을 누른 게 아니다). 따라서 도크를 막
  연 뒤의 `/`는 터미널 입력이며, 도크 검색은 한 번 클릭한 뒤에 연다.

## 3. provider 입력과 신뢰 등급

| provider | discovery root | 사용자 세션 확정 | title/summary 신호 |
| --- | --- | --- | --- |
| Claude Code | `~/.claude/projects/*/*.jsonl`의 **직속** 파일만 | 직속 JSONL만; 하위 `subagents` 계층은 절대 재귀하지 않음 | `custom-title`, `ai-title`, first/last user message 순 |
| Codex | `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` | `session_meta`의 worker 판정(§3.1)이 사용자 세션일 것 | `session_index.jsonl` title(검증 가능한 경우), 없으면 user event |

### 3.1 Codex worker 판정

`thread_source`는 최근 Codex가 추가한 필드다. 판정은 신호 순서로 한다.

| 신호 | 판정 |
| --- | --- |
| `thread_source`(또는 `threadSource`)가 있음 | `"user"`면 사용자 세션, 그 외 값은 worker |
| 없고 `payload.source.subagent`가 객체 | worker |
| 둘 다 없음 | **사용자 세션**(목록에 포함) |

기본을 "제외"가 아니라 **"포함"** 으로 둔다. 목록에서 조용히 사라진 세션은 사용자가 알아챌 방법이 없지만,
worker가 섞이면 보고 무시할 수 있다. 실측(2026-08-08, 개발자 머신): `thread_source`가 없는 구버전 Codex
파일 67개가 전부 실제 사용자 대화였고 모두 `payload.id`를 갖고 있어 식별에도 문제가 없었다. 이 67개는
제외 규칙 때문에 목록에서 통째로 빠져 있었다.

**한 파일에 `session_meta`가 여러 번 나온다.** 실측상 Codex 파일 256개 중 123개가 그렇고, 그중 118개는
첫 메타가 `subagent`이지만 마지막 메타가 `user`인 정상 세션이다. 따라서 **판정은 파일 안에서 마지막으로
관측한 `session_meta`를 따른다.** 첫 메타로 확정하면 그 118개가 사라진다.

읽기를 조기에 끊어 비용을 아끼는 경우에도 같은 규율을 지킨다 — worker 확정은 **앞 512 KiB를 다 읽고도
`user` 신호를 한 번도 보지 못했을 때만** 한다(실측 `user` 메타 최대 위치 18.6 KiB의 27배 여유). 판정에
필요한 메타를 못 본 파일은 제외하지 않고 끝까지 읽는다. 제외는 확신할 때만 한다.

Claude의 nested subagent transcript는 discovery 단계에서 재귀하지 않으므로 애초에 후보가 아니다(§3 표).
다만 그 존재는 부모 세션의 정보이므로 개수를 세어 카드에 보인다(§2.3).

각 record의 안정 identity는 provider의 session id와 source file `(device,inode)`다. 같은 provider/session id가 여러 source에 있으면 newest verified source 하나만 표시하고, id 또는 file identity가 충돌/변경되면 둘 다 불신하고 다음 refresh까지 publish하지 않는다. title index는 보조 정보이며 session transcript의 provider/id와 맞을 때만 적용한다.

## 4. 스캔·성능·수명

`SessionArchiveScanner`는 worker에서만 directory enumerate·open·stat·JSONL parse를 하고, main actor에는 immutable `SessionArchiveSnapshot`만 건넨다. **이전 완료본이 있으면 새 완료본 하나로만 교체**하며, 첫 진입처럼 이전 완료본이 없을 때만 부분 snapshot을 점진 publish한다(§4.1). main actor는 마지막 snapshot을 메모리에 보존해 재진입 즉시 렌더하며, file I/O·JSON parse·정렬·worker wait를 하지 않는다. 대기 중 refresh는 하나로 coalesce하며 old worker completion은 request generation이 맞을 때만 publish한다. dock을 닫거나 앱을 종료하면 cancel을 요청하고, 이미 열린 fd와 staged allocation은 worker가 회수한다.

`SessionDock`의 비례 system-UI text는 이와 **다른** 규율을 따른다. provider JSONL은 worker의 일이지만
텍스트 셰이핑은 아니다. render tick은 rich-text artifact cache가 miss하면 **그 자리에서 CoreText로 셰이핑해
이번 frame에 그린다**. host는 `{ fingerprint, scale, text role, origin, max-width, foreground, UTF-8 bytes }`를
deep-copy한 불변 request 하나를 만들어 같은 tick 안에서 소비하며, 결과를 fingerprint와 함께 cache한다. 즉
cache는 CoreText 호출을 건너뛰기 위한 **순수 최적화**이지, 텍스트 없는 frame을 정당화하는 장치가 아니다.
다른 geometry/content의 이전 artifact를 새 frame에 재사용하지 않는 것은 그대로다.

이 결정에는 근거가 있다. 도크의 **모든** 텍스트와 등록 SVG 아이콘이 이 artifact 하나에 실리므로
(`shapesTextOp`가 `wide_icons`가 아닌 op 전부를 담는다), 셰이핑을 다음 tick으로 미루면 그 frame의 도크는
카드 배경만 남은 빈 상자가 된다. 게다가 detached worker 시절에는 in-flight가 하나로 coalesce돼 있어, 스크롤처럼
매 frame 내용이 바뀌는 동안에는 도착한 결과가 계속 fingerprint 불일치로 폐기되어 한 frame 깜빡임이 아니라
**스크롤하는 내내** 빈 상태가 유지됐다. 비동기의 근거였던 "render tick에서 `CTLine`을 만들지 않는다"는 이
코드베이스에서 성립하지 않는다 — 같은 tick의 터미널 본문 셰이핑이 이미 **셀마다** `CTLine`을 하나씩 만든다.
사이드바·탭바도 `CoreTextFrameBuilder.shapeOnly`로 같은 tick에 CoreText를 부른다.

동기 셰이핑이 frame 예산 안에 있으려면 브리지가 **face를 run마다 다시 만들지 않아야 한다**. chrome 텍스트의
role은 아홉 종뿐이고 그 (point size, weight) 조합은 frame마다 반복되므로, native bridge가 그 face와 PostScript
이름을 잡아 두고 재사용한다(터미널 draw list가 style별 face를 재사용하는 것과 같은 규율). 이 재사용이 없으면
같은 frame이 3배 이상 비싸진다. 그 비용 구조는 [성능 예산](performance-budget.md)의 도크 절이 소유한다.
이 face cache는 lock이 없으므로 chrome 텍스트 셰이핑은 **main actor 전용**이다.

**단, 스크롤은 이 무효화의 대상이 아니다.** CoreText 셰이핑 결과(글리프 id·advance·선택된 face)는 위치의
함수가 아니므로, 목록이 통째로 위아래로 움직인 프레임은 **같은 artifact를 그대로 재사용해야 한다**. 이것은 위
문단이 금지하는 "다른 geometry의 artifact 재사용"이 아니라, 같은 artifact를 올바른 위치에 놓는 일이다.
그래서 fingerprint는 스크롤 목록에 속한 op의 y를 **스크롤 기준 상대값**으로 섞어 평행이동에 불변인 키를 만들고,
host는 셰이핑 당시의 스크롤 원점을 cache와 함께 보관해 재사용할 때 그 차이만큼 스크롤 소속 glyph만 옮긴다.
고정 chrome(header·scope·search)은 스크롤해도 제자리이므로 절대 y를 유지한다 — 전체가 같은 delta로 움직이지
않으므로 단일 평행이동으로는 보정할 수 없다. 스크롤 뷰포트 사각형이나 스크롤 오프셋 자체를 semantic op에
실어서는 안 된다. 그러면 스크롤 1px마다 op이 달라져 cache가 통째로 무효화되고, cache가 빗나간 프레임은 measured
텍스트를 하나도 그리지 않으므로(§아래 all-or-cell-fallback) 스크롤이 끝날 때까지 글자가 사라진다. op이 싣는 것은
**"이 op이 스크롤 영역에 속한다"는 소속 표시뿐**이며, 그 사실은 스크롤해도 바뀌지 않는다.

가상화로 카드가 실제로 교체되면 텍스트 바이트가 달라져 fingerprint가 정상적으로 바뀐다. 그 경우에만 새 셰이핑을
기다리며, 이전 카드의 artifact를 새 카드 자리에 재사용하지 않는다.

이 text worker는 CoreText의 scalar 결과와 postscript font name을 **소유한 DTO**로만 반환한다. CoreText는 macOS
SDK의 `CoreText.h` thread-safety 계약에 따라 worker에서 호출할 수 있지만, `FontIdentityRegistry`, atlas,
`RenderFrame`, Metal/AppKit handle은 worker가 import하거나 소유하지 않는다. main actor는 완료 DTO를 poll한 뒤에만
현재 registry에 font identity를 intern하고 renderer-neutral `ShapedGlyphRecord`·placement cache로 변환한다. 이
변환은 파일 I/O·native text shaping·wait 없이 bounded DTO를 순회하는 작업이다. 종료 시 host는 새 request를 막고
worker completion을 폐기하며 worker가 자신의 request/result allocation을 회수한다. 따라서 stale completion, app
teardown, 연속 resize에서도 main actor가 native shaping이나 join으로 멈추지 않는다.

AS2는 한 PR에 병렬 parser까지 억지로 섞지 않는다. **AS2-a**는 backend-owned monotonic request generation, dock 이탈/종료 cancel, candidate/file 경계의 cooperative cancel, cancelled generation의 publish 폐기와 재진입 latest-wins 재요청을 닫는다. **AS2-b**가 그 동일 cancellation token과 총 byte reservation을 소비하는 최대 4개 parse worker pool 및 actual peak-concurrency metric/fixture gate를 추가한다. 따라서 AS2-a가 끝나기 전에는 현재 단일 scanner thread를 “동시 parse≤4 구현”이라고 주장하지 않는다.

1. trusted discovery root에서 no-follow directory traversal로 regular file만 수집한다. symlink, socket, FIFO, device, nested Claude directory, 예상 밖 파일명은 skip하며 debug artifact에는 raw 제목/프롬프트/경로를 남기지 않는다.
2. 후보 metadata는 디렉터리 순회와 `stat`만으로 모으므로 개수 상한을 두지 않는다. 실측(2026-08-08) 351개
   후보 수집이 **2.4 ms**다 — 여기에 상한을 두면 목록의 완전성만 잃고 아끼는 비용이 없다.
3. worker는 후보를 최근 순으로 분석한다. 파일은 **streaming JSONL parser**로 읽는다: 고정 크기 버퍼로
   순차 읽고 줄 단위로 소비하며, 청크 경계에 걸친 줄만 이어 붙인다. **파일 전체를 메모리에 올리지
   않는다** — 그래야 파일 크기와 무관하게 메모리가 일정하고, 아래 4의 상한들이 필요 없어진다.
   손상 JSON line은 그 line만 버리고 record를 추측해 만들지 않는다. 한 줄이 16 MiB를 넘으면 그 줄을
   버리고 `partial`에 기록한다(손상 파일이 줄 버퍼를 무한히 키우는 것만 막는 방어이며, 정상 파일은
   전부 통과한다 — 실측 최장 줄 6.85 MB).
4. **read budget을 두지 않는다.** 예전에는 파일당 128 MiB·refresh당 512 MiB 상한이 있었는데, 그 둘은
   "파일 전체를 메모리에 올린다"를 방어하려고 존재했다. streaming으로 그 전제가 사라지면 상한도 함께
   사라진다. 남는 상한은 한 refresh가 무한히 돌지 않게 하는 **시간 상한 하나**이며, 그 상한에 걸려
   끊긴 refresh는 `partial`로 표시한다.

   read budget이 목록을 자르면 **캐시 상태가 결과를 바꾼다.** 캐시 히트는 budget을 쓰지 않으므로, 같은
   데이터·같은 코드인데 몇 번째 refresh냐에 따라 보이는 세션 수가 달라진다. 실측(2026-08-08)에서 첫
   refresh 69개가 12번 반복 뒤 272개가 됐고 그래도 완성되지 않았다. **캐시는 순수 최적화여야 하며
   관측 가능한 결과를 바꿔서는 안 된다.** budget 제거가 그 조건을 회복시킨다.
5. first guard는 앱 실행 중의 완료 snapshot TTL 15초다. TTL hit는 filesystem I/O 없이 현재 snapshot만
   보이고, force refresh만 이를 우회한다. worker는 다음 guard로 `(device,inode,mtime,size)`가 같은 파일의
   verified parse 결과를 재사용한다. cache miss/identity 변경 파일만 다시 분석하며, cache 결과와 새 parse
   결과를 정렬해 합친 snapshot을 publish한다. `(device,inode)`는 캐시를 위해서가 아니라 **스캔 시점과
   열기 시점 사이의 파일 교체를 막기 위한 identity**이며(§5), 캐시 키는 그것을 재사용한다.
   memory-only snapshot과 parse cache이므로 앱 종료 후 title/prompt metadata와 source path를 디스크에
   남기지 않는다. persistent cache는 개인정보 보존·삭제 정책을 별도로 승인하기 전 비목표다.

### 4.1 첫 진입의 점진 publish

read budget을 없애면 첫 진입이 사용자 이력 전체를 한 번에 분석한다. 실측(2026-08-08, 351개/8.1 GB,
`ReleaseSafe`·제품 allocator): 전체 완료까지 **약 16초**이고 두 번째 refresh부터는 캐시로 **약 1초**다.
비용의 97.5%는 JSON parse이며 I/O는 1.2초다.

그래서 **이전 snapshot이 없을 때만** 완료를 기다리지 않고 부분 snapshot을 주기적으로 publish한다.

- **이전 완료 snapshot이 있으면**: 지금과 같다. 완료본 하나로 원자 교체하고 scroll/selection anchor를
  보존한다. refresh가 목록을 흔들지 않는다는 계약은 그대로다.
- **없으면**(첫 진입): 정렬 순서대로 분석하며 부분 snapshot을 발행해 목록이 위에서부터 찬다.
  실측 채움 속도는 첫 카드 6 ms, 20개 약 2초, 100개 8.4초, 전체 15.7초다. 즉 **첫 화면은 budget이
  있던 때보다 빠르고, 최종 목록은 완전하다.**
- 부분 snapshot은 **완료로 취급하지 않는다.** TTL 갱신에 쓰지 않으며(쓰면 재스캔이 막혀 목록이
  불완전한 채 고정된다), "이전 snapshot이 있다"는 판정에도 쓰지 않는다(취소로 남은 부분 목록을
  완성본으로 오인하면 다음 진입이 점진 경로를 타지 않는다).
- 발행 간격은 초반을 촘촘히 하고 이후 넓힌다. main actor가 발행마다 filter/projection/anchor 복원을
  다시 하므로 너무 잦으면 그 자체가 비용이다.

**budget이 없어도 UI는 여전히 불완전을 말해야 한다.** 시간 상한, 16 MiB 초과 줄, 읽기·parse 실패는
`partial`로 남고, UI는 `228개 표시 · 분석 중`처럼 현재 snapshot과 scan 상태를 분리해 말한다.
search/scope가 부분 snapshot을 완전한 결과처럼 보이게 해서는 안 된다. 이미 완료 snapshot이 있으면 같은
문구를 overlay로만 보이고 카드 목록은 유지한다. **정책적 제외(worker)는 이 경고에 포함하지 않는다** —
정상 동작이 상시 경고로 보이면 경고가 무의미해진다.

## 5. 보안·개인정보·관측

- provider log는 민감한 개인 데이터다. 원문·prompt·token·절대 home path를 trace, crash artifact, fixture, analytics, config에 쓰지 않는다. fixture는 synthetic·redacted JSONL만 허용하며 [project-rules.md](project-rules.md)의 redaction 기준을 공유한다.
- scanner는 no-follow로 열고 fstat identity를 discovery snapshot과 다시 대조한다. parse 중 교체되거나 permission이 바뀐 파일은 stale로 버린다. published record는 앱 실행 중에만 absolute source path와 `(device,inode)`를 함께 보존하며, `로그 보기`는 사용자가 누른 때에만 그 identity를 다시 검사해 OS file reveal API에 넘긴다. 교체·삭제·비정규 파일이면 reveal을 거부한다.
- resume은 **사용자 로그인 셸을 거쳐** provider를 실행한다. `/usr/bin/env <provider>`를 직접 exec하면
  provider를 **부모 프로세스의 PATH에서만** 찾으므로, Dock/Finder에서 띄운 앱은 실패한다 — GUI 앱이
  물려받는 PATH에는 `~/.local/bin`이나 버전 매니저 shim이 없다(실측 2026-08-08: `launchctl getenv PATH`
  미설정, `env -i … zsh -lc 'command -v claude'` 실패, `-lic`는 성공). 터미널에서 띄웠을 때만 우연히
  동작하던 것이라 재현이 갈렸다.
  - 셸을 `-l -i -c "exec <provider> --resume <id>"` 형태로 부른다. `-i`가 필요한 이유는 PATH를
    `.zshrc`에 두는 환경이 흔하고 zsh는 `-l`만으로는 그 파일을 읽지 않기 때문이다. 일반 새 탭은 이미
    대화형 로그인 셸이므로 이 경로가 오히려 나머지 탭과 동작을 일치시킨다.
  - 셸 basename이 `zsh`·`bash`·`sh`일 때만 이 형태를 쓰고, 그 외(fish·nushell 등)는 문법이 다르므로
    직접 exec으로 폴백한다.
  - 명령 문자열에 들어가는 각 인자는 예외 없이 single-quote escape한다. **cwd는 명령 문자열에 넣지
    않고 spawn request의 작업 디렉터리로만 전달한다.** parse한 prompt는 실행 인자로 절대 넣지 않는다.
  - session id/provider는 UI text나 log에서 명령으로 재해석되지 않는다.
- metrics는 candidate/verified/partial/rejected 개수와 scan duration/bytes만 남긴다. title·요약·cwd·session id는 observability event의 payload가 될 수 없다.

## 6. 구현 순서와 완료 조건

### AS3-a — SessionDockLayout 첫 제품 surface 단위

AS3의 첫 PR은 목록을 다시 ANSI 문자열로 조립하는 것이 아니라, `src/chrome/components/session_dock.zig`
facade와 그 하위 `session_dock/{types,ids,build,view}.zig`만이 session-dock Chrome component를
소유하게 한다. 파일별 책임은 다음처럼 고정한다.

- `types.zig`는 worker 완료 snapshot에서 이미 안전하게 정규화된 immutable `Props`와 header/scope/search/group/card의
  표시 상태만 받는다. `AppSession`, provider 파일, PTY, CoreText/Metal handle 및 raw JSONL을 import하지 않는다.
- `ids.zig`는 frame-local `UiActionId`와 semantic intent(`refresh`, `scope`, `focus_search`, `toggle_group`, `select_card`)의
  table을 만든다. 카드 intent는 화면 행 번호만 신뢰하지 않고 snapshot generation과 stable archive identity를
  platform으로 돌려준다. 새 snapshot을 publish하기 전 interaction capture를 버리고, platform은 generation/identity가
  일치할 때만 intent를 적용한다.
- `build.zig`는 caller-owned bounded buffer로 fixed header, segmented scope, 독립 search field, scroll clip,
  group, card의 `UiNode`/`UiRectTree`를 한 번 만든다. 같은 tree가 `view`, pointer hit, visible-row window와
  keyboard scroll origin의 유일한 geometry다.
- `view.zig`는 tree와 props만 읽어 background/border/hover/selected/skeleton/spinner의 typed paint와 text
  semantic draw를 낸다. 문자열 폭·한 줄 clip/ellipsis는 `chrome.text_layout`의 기존 단일 출처를 사용하며,
  text node가 layout 밖에서 두 번째 x/y/width를 계산하지 않는다.

이 slice에서 `ui.paint`가 여전히 일반 `UiNode.text`를 GPU glyph로 직접 rasterize하지 않는 한계는
`ChromeDraw.text` bridge로 닫는다. 즉 component `view.zig`가 backing-pixel origin과 clipped run을 가진
semantic text op를 만들고, macOS의 `platform/macos/chrome/chrome_draw_lowering.zig`가 그 run을 **한 번만**
기존 CoreText `DrawList`/atlas 경로로 옮긴다. 같은 adapter는 card quad를 renderer layer 2로 낮춰 text보다 먼저
그린다. 이것은 `app_session.zig`의 `buildDockNoticeDrawList`나 pipe scope 문자열을 재사용하는 legacy direct draw가
아니다. component가 text 내용·rect·tone을 모두 소유하고 platform은 공통 backend lowering만 한다. generic GPU text
shaping은 이후 별도 ML slice이며, 이 bridge의 문자열/geometry contract와 artifact를 깨지 않고 교체해야 한다.

`AppSession`은 완료된 archive projection을 한 frame의 `Props`로 투영하고, component가 돌려준 action table과
`UiRectTree`의 완료 snapshot을 함께 publish한다. pointer는 다음 frame에 tree를 재계산하지 않고 **직전에 실제로
paint한** action table만 선택하며, 새 snapshot publish는 기존 capture를 취소한다. card action은 같은 도크 안의
expanded disclosure를 toggle할 수 있지만 provider 실행은 절대 하지 않는다. refresh/scope/group/selection은 기존
memory-only state만 바꾸며, 검색 keypress/hover/frame은 filesystem I/O, JSONL parse, worker wait를 하지 않는다.
AS3 base slice는 `ExpandedSessionCard` detail 및 resume/reveal action을 포함하지 않는다.
AS4-d가 이 base tree에 disclosure rect와 generation-bound action을 추가한다. 즉 action은 별도
archive-tab tree나 host 좌표 계산으로 재구성하지 않고, expanded card를 포함한 같은 published tree에서만
pointer/shortcut capability를 얻는다.

Lab product capture는 최소한 `empty`, initial `loading`, retained list를 포함한다. Lab은 실제 `SessionDock`
component를 거쳐 card/scope/header/search와 semantic text op를 만들고, 그 op를
`chrome_draw_lowering.buildTextDrawList` → CoreText atlas → 제품 `maru_metal_renderer_draw`로 전달한다. 따라서
480×720 fixed dark PNG/JSON에는 `text_rasterized=true`, glyph cell 수와 readback 성공을 함께 남긴다. 이 artifact는
회색 quad만 있는 fixture가 아니라 카드와 텍스트가 함께 합성된 visual renderer evidence다.

Lab은 제품 Session Dock과 **같은 두 텍스트 경로**를 탄다(2026-08-06 이관). 제품 `AppSession`이 그렇듯
등록 SVG/PUA 아이콘은 셀 draw list(`chrome_draw_lowering.buildIconTextDrawList`)로, 나머지 라벨은
`system_text.Artifact`(`shapeOps` → `shapeFromRecords` → `appendGpuGlyphs`)로 내린다. 두 필터는
`shapesTextOp`(= `!wide_icons`)와 `only_wide_icons = true`로 정확히 상보라 어떤 op도 두 번 그려지거나
빠지지 않는다. 스크롤 뷰포트도 제품과 같은 출처(published tree의 `content` 사각형)를 넘긴다.

그래서 Lab capture는 이제 텍스트의 픽셀 정렬과 **텍스트 클리핑**까지 증거가 된다 — 반쯤 걸친 카드의 글자가
잘린 그대로 캡처된다. 시각 골든(`test-dock-visual-golden`)이 그 계약을 `group-pill-clipped-edge`로 고정한다
(예전에는 Lab이 `chrome_draw_lowering.RichTextArtifact`(셀 격자 + 오프셋, clip 없음)를 써서 글자가 격자로
스냅되고 잘리지도 않았고, 그 때문에 이 case를 넣었다가 제거해야 했다).

이관에서 바뀐 대조의 의미: `richGlyphsMatchArtifact`는 **클리핑 전** 좌표로 본다. `appendGpuGlyphs`가 부분
가시 glyph의 좌표·크기를 잘라내고 완전히 밖인 glyph는 버리므로 캡처용 목록과 placement를 1:1로 맞출 수 없는데,
이 대조가 지키려는 계약("placement가 GPU 좌표로 그대로 옮겨졌는가")은 클립과 직교하기 때문이다. 클립 경로는
골든이 본다.

남는 한계는 pane 합성이다. Lab은 dock을 프레임 원점에 단독으로 그리므로 터미널과의 레이어 순서·pane 오프셋은
보지 않는다.

다만 Lab 입력은 redacted fixture이고 `AppSession`의 실제 archive worker/snapshot publish를 만들지는 않는다. 그러므로
active `agent_sessions` host screenshot E2E와 precise scroll gesture, refresh 중 selection·scroll 보존은
여전히 별도 gate다. component text/ellipsis와 scope width는 pure test로, primary card click은 published tree/action
table을 소비하는 host path로 고정한다.

Lab의 font matrix는 앱 번들의 `ATSApplicationFontsPath` 등록을 우회해서는 안 된다. Lab executable은
독립 실행 파일이므로 단순 `font.family` override만으로 `assets/fonts/`의 번들 face를 증명할 수 없다.
각 번들 family(`JetBrains Mono`, `Jetendard`, `Fira Code`, `Cascadia Code`, `Hack`)는 test-only 등록 seam 또는
실제 app bundle capture를 통해 CoreText가 **요청한 face와 일치한 PostScript font**를 선택했음을 JSON artifact에
기록하고, 같은 retained-list 제품 Metal PNG를 남겨야 한다. family가 없거나 fallback만 선택되면 캡처 성공으로
표시하지 않는다. 이 matrix는 icon color/size와 scope label 세로 중심 visual gate를 함께 검사한다.

### AS3-b — published-tree pointer lifecycle

AS3-a 다음 작은 product slice는 새 hit-test나 archive 행 산술을 추가하지 않고, 직전에 paint한
`UiRectTree`/action table로 `move → down → up` lifecycle을 끝까지 소비한다. `hoverCursor`는 agent-session
tree 영역에서 component-local backing px로 한 번 변환해 `.move`를 dispatch하고, 도크 밖·창 밖 sentinel에서는
동일 dispatch로 stale hover를 지운다. pointer down은 capture/focus만 만들며 provider/archive action을 실행하지
않는다. primary up은 capture가 있으면 도크 밖에서 일어나도 같은 tree의 action id를 한 번만 resolve하고, generation이
일치할 때에만 refresh/scope/search/group/card intent를 적용한다. 그러므로 down 뒤 refresh가 새 snapshot을 publish하면
reconcile이 capture를 취소해 늦은 up이 옛 record를 열 수 없다.

도크 content 안의 drag/up은 terminal selection·PTY mouse reporting으로 새지 않고 component lifecycle에서 소비한다.
이 slice의 test는 hover enter/leave, down이 side effect를 내지 않음, up 1회 action, outside-up capture, snapshot
replace 뒤 stale-up 무효를 고정한다. 카드 중간 픽셀을 보존하는 scroll offset/clip과 refresh 중 scroll·selection E2E는
다음 AS3-c이며, AS3-b가 행 수 기반 scroll을 정밀 스크롤이라고 주장하지 않는다.

### AS3-c — pixel scroll projection과 refresh anchor

AS3-c는 기존 `agent_session_archive_scroll_rows`를 늘리는 보정 PR이 아니다. 도크 목록의 스크롤 권위는
active `ChromeHost` adapter인 `AppSession`이 소유하는 `SessionDockScrollState`의 **backing-pixel `offset_y_px`**
하나로 바꾼다. offset은 목록의 첫 item top을
`SessionDockScrollArea` clip top에서 얼마나 위로 옮겼는지를 뜻하고, 범위는 정확히
`0..max(0, content_height_px - scroll_area_height_px)`다. header·scope·search는 이 좌표계 밖의 fixed chrome이며
어떤 scroll offset에도 이동하지 않는다. retained `offset_y_px`는 항상 integer이며, **wheel ingress에만**
`agent_session_archive_wheel_residue_px`가 fractional backing px를 보관한다. 매 wheel event는 residue에 delta를 더하고
trunc한 integral px만 offset에 적용한 뒤 residue만 남긴다. paint/hit-test에는 같은 integer backing-pixel offset만
publish한다. 이 규칙은 2x Retina에서 0.5pt 입력도 1px 단위로 누적되어 보이되, draw와 hit-test의 subpixel/rounding 결과가
갈라지는 것을 막는다.

`src/chrome/ui/scroll_area.zig`의 pure `project`가 항목 높이 함수(도크는 그룹 헤더·카드·펼친 카드를 구분한다)와 viewport, offset을 받아
다음을 **한 번에** 산출한다: total content height, clamped offset, 첫 partially-visible item index, 그 item의 negative local
origin, visible item range, 각 item의 rect와 content clip. host는 이 결과가 가리키는 item만 `build.zig`에 전달하며 별도의
visual-row→entry, cell-row, fixed-header y 산술을 하지 않는다. `view.zig`, `chrome_draw_lowering`, published
`UiRectTree`, pointer hit-test, scrollbar track/thumb는 이 same projection의 integer rect/clip을 소비한다. 따라서 카드가
clip top에서 반쯤 보이면 그 보이는 반쪽만 draw/hit 가능하고, header 아래로 bleed하거나 다음 card의 action rect가 앞 card를
가로채지 않는다. content height는 item 간 gap만 포함하고 마지막 item 뒤 trailing gap은 넣지 않는다. scrollbar도
`project`의 total/viewport/clamped offset만으로 visual rect를 만들고, thumb drag는 그 rect를 역으로 읽어
같은 offset 좌표계로 돌아온다 — 기하 출처가 둘로 갈리지 않는다. 최대 500개 record와 그에 대응하는 bounded group header의 projection은 O(n) scan 하나이며 frame/hover에는
I/O, worker, JSON parse, allocation을 추가하지 않는다.

Card background와 pointer rect만 clip에 맞추고 텍스트를 넘기면 partial card가 header/search 영역을 침범한다. 현재
CoreText lowering은 semantic text origin을 terminal cell grid로 내리므로 per-glyph scissor를 따로 만들지 않는다. 따라서
vertical partial item의 텍스트는 **원점이 아니라 실제 lowering될 한 cell-height band 전체**가 `effective_clip` 안에 있을
때만 emit한다. 부분적으로 걸친 glyph를 잘라 보이게 하거나, clip 밖 row를 반올림으로 되살리는 것은 금지한다. 이 조건은
component의 `cell_height_px`와 lowering의 같은 floor division을 사용해 card background·text·hit-test의 가시 경계가
어긋나지 않게 한다.

wheel의 owner는 published `SessionDockScrollArea` rect 하나다. `delta_y > 0`(위)는 offset을 줄이고 `< 0`(아래)은
offset을 늘린다. mouse wheel은 기존 line delta를 card 높이 기반의 bounded pixel step으로 변환하고, precise trackpad는
AppKit point delta를 scale로 backing px로 바꾼다. `scroll.multiplier`는 둘에 같이 적용한다. `AppSession`은
terminal·sidebar·notification과 공유하는 `wheel_accum`을 쓰지 않고 dock 전용
`agent_session_archive_wheel_residue_px`를 둔다. 방향 반전, dock leave, snapshot replace, scope/search/group change,
surface deactivate 때 residue를 0으로 비워 이전 owner의 미세 잔여가 첫 반대 scroll을 상쇄하지 않게 한다. target이
scroll-area 밖이면 agent list state는 바꾸지 않고, scroll-area 안이면 clamp로 실제 offset이 변하지 않아도 terminal/PTy에는
절대 전달하지 않는다. horizontal delta, momentum/animation, rubber-band overscroll, scrollbar drag는 이 slice의 비목표다.

`agent_session_list` focus가 search field를 소유하지 않을 때 PageUp/PageDown, Home/End도 같은
`SessionDockScrollState.scrollByPx`/`scrollToBoundary`만 호출한다. page step은 `scroll_area_height_px - one_card_h`로
정해 0/음수 viewport에서는 no-op이고, Home/End는 각각 0/max offset으로 간다. keyboard scroll은 dock 밖이나 search
focus에서 terminal로 새지 않으며 wheel residue를 0으로 비운다. Up/Down의 selection 이동과 선택 card를 viewport에
reveal하는 정책은 기존 focus-owner slice의 계약을 소비할 뿐 이 slice에서 새 semantic selection rule을 만들지 않는다.

refresh는 old completed snapshot을 paint하는 동안 current offset과 selection을 절대 바꾸지 않는다. worker 완료 직전에
`ArchiveScrollAnchor`를 capture한다: 현재 offset에서 **첫 partially-visible card**의 exact archive identity
`{provider, session_id, device, inode}`와 그 card top에 대한 `intra_card_y_px`다. group header는 anchor가 될 수 없고,
첫 보이는 card가 없으면 numeric offset만 보존한다. 새 immutable snapshot과 filtered/collapsed projection이 완료된 뒤에만
selection을 기존 exact identity로 restore하고, 같은 card identity가 새 projection에 있으면
`new_card_top_px + intra_card_y_px`를 새 offset으로 clamp한다. identity가 사라졌거나 group이 접혀 card가 materialize되지
않으면 **추측으로 이웃·path·mtime을 매칭하지 않고** 기존 numeric offset만 새 range에 clamp한다. 이전 목록을 비우지 않는
refresh와 함께 이 restore는 한 main-actor commit에서만 일어나며, new snapshot OOM/retain-previous는 spinner만 끝내고
offset·residue·selection·published tree를 그대로 둔다.

`toggle_group`, scope/search query, active CWD scope change처럼 사용자가 목록 의미를 바꾸는 action은 anchor restore가
아니라 offset=0과 residue=0을 명시적으로 선택한다. 반대로 resize는 old viewport에서 같은 `ArchiveScrollAnchor`를 먼저
capture한 뒤 새 viewport projection에 exact identity가 있으면 restore하고, 없으면 old numeric offset을 새 range로 clamp한다.
새 tree/action mapping이 바뀌면 AS3-b의 reconcile 규칙대로 pointer capture를 취소한다. scroll 자체는 card action을 만들지
않고, scroll 중에는 hover를 current published rect로 재평가한다.

구현 전 pure test는 (1) partial first/last card clip과 half-open hit bounds, (2) 1px offset과 max/cap clamp, (3) precise
delta의 Retina scale·residue·direction reset, (4) fixed header 불변, (5) 500 item bounded visible range, (6) exact
anchor reorder restore와 identity-missing no-guess fallback, (7) retain-previous/OOM의 state byte-for-byte 보존을 고정한다.
제품 test는 scroll-area 안/밖 wheel ownership, scroll 중 PTY mouse/terminal scrollback=0, resize/group/snapshot replace의
capture cancel, same renderer Lab의 `partial-scroll` PNG/JSON(clip과 text rasterized evidence)을 추가한다. active AppKit
host wheel screenshot은 `expanded-scroll-anchor` isolated fixture가 실제 `NSView.scrollWheel`·refresh·새 published generation과
전후 Metal capture로 검증한다.

1. **AS1 — 순수 모델·parser:** provider-neutral record, Claude/Codex streaming parser, trust grade, dedup/title/summary/redaction/filter/sort pure tests. 실제 사용자 log는 fixture로 넣지 않는다.
2. **AS2 — bounded scanner:** no-follow discovery, candidate/file/total caps, cancellation/generation, in-memory identity parse cache, 최신순 bounded worker pool과 완료 snapshot atomic publish, metrics. refresh는 직전 완료 snapshot을 유지하고 새 scan이 끝날 때만 교체한다. main tick filesystem I/O=0·JSON parse=0·worker wait=0을 counter와 source boundary test로 고정한다.
3. **AS3 — 도크 Metal component vertical slice:** `SessionDockLayout`과 header/scope/search/group/card/scroll-area primitive를 순수 props/state/layout/view/hit-test/action으로 만든 뒤 host/backend의 semantic draw → Metal GPU lowering에 연결한다. 기존 direct text draw와 pipe scope label은 이 slice에서 제거한다. layout 공유 test가 view rect=hit rect=visible-row origin을, search keypress I/O=0·row 한 번 클릭 provider 실행=0·main thread JSONL I/O=0을 고정한다. loading spinner는 snapshot 유무별로 skeleton 또는 기존 목록 유지인지도 integration test로 고정한다. **AS3-a는 component→CoreText/Metal card background, AS3-b는 published-tree hover/down/up lifecycle, AS3-c는 pixel scroll projection·refresh identity anchor·partial-scroll Lab artifact와 `expanded-scroll-anchor` active AppKit screenshot E2E를 연결한다.**
4. **AS4 — inline expanded session·explicit actions·제품 gate:** `ExpandedSessionCard`를 `SessionDockScrollArea` 안의 PTY 없는 Metal-rendered component로 연결하고 bounded recent/permission summary, loading/stale identity disable, exact live mapping, source reveal, `터미널에서 이어하기`의 argv-only immediate new-Term activation을 닫는다. 기본/expanded row의 action·clip·scroll anchor는 하나의 completed tree를 소비한다. action label은 각 clickable card 안에서 실제 ellipsis/CJK glyph 폭 기준으로 수평 중앙 정렬한다. resume/log의 click rect와 `⌘↵`/`⌘L` shortcut은 같은 action identity를 소비한다. `열린 세션으로 이동`은 exact live identity가 있을 때만 별도 pointer/Enter action으로 제공한다. macOS fixture E2E는 dock card hover/selection/inline-expand/collapse/scroll, refresh 중 snapshot 보존, detail loading→ready/stale, disabled action, resume/reveal을 확인한다. 실제 provider 계정/개인 이력에 대한 재개는 사용자가 직접 승인한 수동 gate일 뿐 CI 증거가 아니다.

### AS4-c — 실제 AppKit host archive fixture

AS4-a/AS4-b의 component/Lab 및 `AppSession` test만으로는 실제 Swift `NSApplication`의 frame loop,
`MaruMetalTerminalView` 입력 경로와 source-reveal consumer를 증명하지 못한다. 그래서 별도
`mise run macos-agent-session-archive-smoke`는 기존 일반 `macos-app-smoke`에 얹지 않고, 격리 HOME과
synthetic·redacted Codex JSONL을 쓰는 전용 AppKit/CAMetalLayer process로 실행한다. 이 command와
`zig-out/maru-agent-session-archive-smoke/` fixture root를 쓴다. fixture는 synthetic Codex record 하나로 cold-start
titlebar dock launcher→view-switcher→card 실제 pointer, loading publish, worker gate release 뒤 ready action을 자동 검증한다.
ready 뒤 `resume`·`로그 보기`는 각각 pointer와 `⌘↵`·`⌘L`을 **서로 다른 cold AppKit process**로 보내 결과가 섞이지 않게 한다.
Codex action fixture와 별도로, Claude fixture는 직속 `~/.claude/projects/<project>/<session>.jsonl` 하나만
격리 HOME에 두고 assistant `message.model`을 포함한다. 이 scenario는 scanner가 nested `subagents`가 아닌 직속
Claude transcript를 고르고, parser의 model metadata가 세 줄 카드의 model line으로 투영되며, 명시적 재개가
`claude --resume <session-id>`의 provider-native argv로 향하는 것을 함께 고정한다. summary에는 모델명·세션 id·경로·원문을
남기지 않고 fake-exec verdict만 남긴다. stale replace와 multi-state capture는 동일 command의 별도 scenario다.

이 fixture는 일반 controlled-smoke의 80×24 zero-backing 시작을 재사용하지 않는다. 첫 paint 전에 실제
Metal view의 backing metric을 session에 전달해, probe가 존재하지 않는 가상 좌표가 아니라 사용자도 누를 수 있는
titlebar launcher와 dock slot만 관측하도록 한다.

- fixture는 실제 archive scanner와 detail worker를 통해 목록→inline expanded card를 연다. `AppSession` private method를
  직접 호출하거나 provider transcript를 terminal에 write하는 우회는 금지한다. Swift는 `MaruMetalTerminalView`가
  평소 쓰는 mouse/key ABI 경로로만 down/up 및 `⌘↵`/`⌘L`을 보낸다.
- 입력 좌표는 상수/창 크기 추측이 아니라 **직전에 paint·publish된** cold-start titlebar dock launcher, dock view-switcher, session-dock card tree와 detail action tree의
  smoke 전용 읽기 probe에서 얻는다. probe는 request generation, stable identity, enabled bit, backing-pixel rect와
  관측 counter만 읽으며 intent를 실행하거나 worker/state를 변경하지 않는다. 따라서 probe 자체가 테스트의 두 번째
  action path가 되지 않고, stale frame/rect이면 fixture는 실패한다.
- loading capture는 sleep race로 만들지 않는다. detail worker는 fixture에서만 닫힌 test gate를 만나고, card action 뒤
  loading frame·spinner/skeleton·disabled action tree가 present된 것을 먼저 capture한다. gate release 뒤 동일 identity의
  ready frame을 기다린다. 이 gate와 fixture input은 일반 앱, 일반 refresh, 실제 provider log에서 완전히 비활성이다.
- resume과 reveal은 각각 pointer·keyboard의 clean process scenario를 하나씩 가져야 한다. resume 두 scenario는
  fake `codex`/`claude` executable이 남긴 provider-kind·argument count·argument position verdict가 같고
  `codex resume <synthetic-id>` 또는 `claude --resume <synthetic-id>` 외의 shell wrapper·prompt text·추가 인자가
  없음을 확인한다. reveal 두 scenario도 allow/reject count와 source-identity verdict가 같아야 한다. 실제 provider
  binary, 계정, 네트워크, 사용자 이력은 실행하지 않는다.
- **exact-live는 현재 미구현/차단 상태다.** 2026-08-03 macOS POC에서 일반 PTY child의
  `KERN_PROCARGS2` 조회가 argv-only payload(29 bytes)를 돌려 provider가 tool child에 둔
  `CODEX_THREAD_ID`/`CLAUDE_CODE_SESSION_ID`를 읽지 못했다. 따라서 path·mtime·활동시각 추측이나 test-only mapping
  주입으로 `focus_live`를 보이게 해서는 안 된다. Codex는 provider 공식 hook payload를 `MARU_PANE_ID`에 묶은
  명시 mapping으로, Claude는 현재 statusline mapping과 공통 lifecycle/사용자 설정 보존 정책으로 재설계·승인한 뒤에만
  다시 연다. 그 전에는 action을 materialize하거나 success fixture를 추가하지 않는다.
- stale scenario는 detail gate가 열린 뒤 worker가 source를 다시 검사하기 **전** fixture가 source를 atomic replace해
  만든다. 그러면 worker의 no-follow `(device,inode)` 재검증 실패가 stale DTO와 disabled action tree를 publish해야 한다.
  별도 reveal-recheck scenario는 ready 뒤 source를 replace하고 `로그 보기`를 실행해 external-open count 0만 요구한다.
  이는 ready frame을 즉시 stale이라고 오인하지 않으며, replacement 뒤 refresh/detail publish가 action table과 pointer
  capture를 폐기하는지는 stale scenario에서 별도로 검증한다.
- `detail-close-reopen` scenario는 ready inline card의 **같은 published card rect**를 다시 pointer click해 disclosure를
  닫고, 새 request gate를 arm한 뒤 같은 rect를 다시 click해 재연다. 첫 request와 재열기 request id는 달라야 하며,
  닫힌 동안 resume/reveal capability는 present되지 않아야 한다. 재열기 loading→ready와 전 과정의 active terminal
  surface id·전체 Term 수 불변을 한 cold AppKit process에서 확인한다. 이 scenario는 provider action을 실행하지 않으며,
  `same card toggle`이 별도 tab/surface를 만들지 않고 detail capability와 worker request만 정확히 폐기·재발급하는지
  증명한다.
- **snapshot-replace stale-up scenario**는 detail이 ready인 기존 completed tree에서만 시작한다. fixture는 일반
  refresh slot을 실제 pointer click해 archive scan을 요청하고, fixture 전용 scan gate가 worker discovery 전에 도달한
  것을 기다린다. 그동안 old snapshot·ready action은 그대로 paint된다. fixture는 그 published resume rect에
  `mouseDown`만 보낸 뒤 source를 같은 디렉터리에서 atomic replace하고 gate를 푼다. 새 immutable snapshot이
  publish되면 exact `{provider, session_id, device, inode}`가 달라진 disclosure는 stale이 되고, replacement card에는
  old detail capability를 materialize하지 않으며 old pointer capture와 action table을 먼저 폐기해야 한다. 그 다음
  **old backing rect에** 일반 `mouseUp`을 보내도
  fake provider argv·새 Term·external-open이 하나도 생기지 않고 active terminal surface id·전체 Term 수가
  baseline과 같아야 한다. source/ID/path/원문이나 callable action identity는 fixture ABI를 통과하지 않는다.
  scan gate와 refresh probe는 이 named isolated smoke scenario에서만 host가 명시적으로 사용하며 일반 refresh,
  provider history, 제품 설정에는 도달하지 않는다.
- **expanded-scroll-anchor scenario**는 ready inline detail을 연 뒤 실제 `MaruMetalTerminalView.scrollWheel`의
  precise backing-pixel gesture로 그 **동일 expanded card**가 content clip top을 부분적으로 가로지를 때까지 내린다.
  fixture는 일반 refresh pointer와 scan gate로 scan을 멈추고, 같은 inode를 보존한 별도 fixture record의 mtime만 바꿔
  replacement projection의 순서를 바꾼다. publish 뒤에는 원시 provider/session/path 대신 기존 detail request id와
  read-only raw card-rect probe만 비교한다: request id가 유지되고, anchor card의 raw top(따라서 intra-card pixel)이
  refresh 전과 정확히 같아야 한다. clip된 visible rect나 화면 행 번호를 비교하면 top edge가 항상 같은 값으로
  포화되어 anchor 결함을 숨길 수 있으므로 금지한다. worker 완료 전에는 retained snapshot의 raw rect가 유지돼야 하고,
  완료 뒤 새 published tree generation이 아니거나 새 card가 materialize되지 않았거나 raw top이 달라지면 실패한다. 이 gesture와 refresh는 모두 일반 AppKit
  event route를 타며, probe는 읽기 전용이고 scan/detail/action/scroll state를 변경하지 않는다. summary에는 opaque
  request id나 source metadata를 쓰지 않고 `scroll_dispatched`, `anchor_before/after_present`,
  `anchor_raw_top_preserved`, `anchor_snapshot_reordered` 같은 boolean verdict만 남긴다.
- reveal 성공 scenario도 host의 외부 앱 열기를 호출하지 않는다. Swift가 smoke 모드에서 same
  `take_file_tree_external_open` consumer를 drain해 allowlisted fixture token과 횟수만 summary에 기록한다.
- artifact는 ready session **목록**, loading/ready/stale inline expansion의 **1920×960 backing-pixel fixture 창** 제품 Metal PPM·PNG와 redacted key/value summary다. 목록 capture는 published card/action tree만 확인한 첫 frame이 아니라 detached rich-text artifact가 poll·atlas 연결된 뒤의 다음 ordinary frame에서만 요청한다. 한 프레임 뒤 종료하는
  일반 `MARU_SCREENSHOT` 훅은 쓰지 않고, smoke process 안에서만 여러 completed Metal frame을 readback하는 capture
  sink를 쓴다. sink는 이미 paint·publish된 probe가 증명한 상태에서만 **다음 동일 frame**의 renderer output 복사를 요청한다.
  `resume-pointer` scenario는 card click 전의 ready 목록(서로 다른 synthetic record 세 개)·loading·ready, `detail-stale` scenario는 loading·stale를 각각 한 장씩 남긴다. `expanded-scroll-anchor`는 refresh 전·후의
  scrolled expanded-card frame을 각각 남긴다. 두 장은 layout goldens가 아니라 raw-top boolean verdict의 사람 검토
  보조이며, 동일 card가 clip top을 가로지른 상태와 refresh 뒤 보존된 상태를 보여준다.
  request는 fixture root 아래의 고정 상대 artifact 이름만 받을 수 있고, 일반 실행·Chrome Lab·provider 입력에는
  도달하지 않는다. capture 요청·copy 완료는 frame/action/worker state를 바꾸지 않으며, pending request는 한 장을 쓴 뒤 즉시
  사라진다. summary에는 frame request id,
  input source(pointer/keyboard), enabled/disabled action count, fake argv verdict, reveal success/rejected/stale-identity count,
  actual worker scan/detail completion 및 screenshot path만 남긴다. session id·title·prompt·absolute path·raw JSONL은
  artifact·stderr·PR image에 남기지 않는다.

이 fixture는 provider-native binary가 실제 계정 세션을 재개한다는 보장은 아니다. 그 수동 검증은 사용자가 명시적으로
승인한 실제 이력에서만 하며, CI evidence와 섞지 않는다.

## 7. 설계 검토 기록 — 적대적 5회

| 회차 | 공격 관점 | 발견한 결함 | 반영한 방어 |
| --- | --- | --- | --- |
| A1 | live 목록을 archive로 오인 | 열린 Term cache만 쓰면 앱 밖/과거 세션과 screenshot UX를 만들 수 없음 | §1의 두 authority와 별도 scanner/snapshot |
| A2 | Codex worker 오염 | 같은 날짜 계층에 subagent가 섞이고 legacy record는 판별 불가 | §3 verified-user만 표시, legacy unknown 기본 제외 |
| A3 | 성능·UI freeze | 500개의 큰 JSONL을 main tick에서 전량 parse하면 입력/렌더가 멎음 | §4 worker, streaming, 4,096/128MiB/512MiB cap, partial truthfulness |
| A4 | 클릭이 명령 실행 | 행 선택/유사 mtime mapping이 잘못된 session에 입력·resume할 수 있음 | §2 row click은 detail만, 명시 ▶/resume만 new Term/exact provider+id/argv-only |
| A5 | 개인정보·TOCTOU | 기록 제목·prompt가 trace에 새고 symlink 교체 파일을 읽을 수 있음 | §5 redaction/no-follow/fstat recheck/metadata-only metrics |

## 8. 설계 누락 탐색 — 5회

| 회차 | 점검한 빈칸 | 결정 |
| --- | --- | --- |
| M1 | workspace/project의 의미 | active workspace의 active local Term canonical CWD와 그 git root로 각각 고정; 없으면 비활성화 (§2) |
| M2 | 정확하지 않은 count/검색 | partial 상태·`≥n` 표기와 snapshot-only search를 명시 (§2, §4) |
| M3 | resume cwd·실행 경계 | 삭제 cwd fallback, shell 미사용, 명시 ▶/resume 버튼의 즉시 새 탭 실행을 명시 (§2, §5) |
| M4 | 중복·변경·손상 log | provider/id+file identity, conflict discard, line-level corruption 정책을 명시 (§3, §4) |
| M5 | 키보드·취소·영속 | dedicated focus, generation cancel, memory-only metadata와 nonpersistent query를 명시 (§2, §4) |

이 10회 검토 뒤에도 **정책적으로 남긴 비목표**는 원문 대화 뷰어, legacy-unknown opt-in, remote history, 다른 provider, persistent archive cache다. 이들은 데이터 보존·개인정보·성능 범위를 바꾸므로 별도 사용자 결정 없이 AS1~AS4에 넣지 않는다.
