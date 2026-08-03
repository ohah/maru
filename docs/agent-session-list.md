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
Agent 세션 기록                           Local Mac   [새로 고침]
N개 표시 · 최근 500개
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
  메시지 94개 · 3분 전 · claude-…
```

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
│ Local Mac                                  [refresh/spinner] │
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
아래 bullet은 **AS4-f-b 완료 뒤의 목표 상태**다. 현재 AS4-f-a는 확장 action의 content
metric만 이관했으며, 단계별 실제 완료 범위는 [2.1.3](#213-logical-spacingdock-metric-계약-as4-f)을 따른다.

- dock의 자동 폭 640pt 안에서 outer padding, header, segmented scope, search, group header의
  기하는 **terminal cell**이 아니라 Chrome의 logical spacing/type token과 backing scale에서만
  결정한다. header·scope·search는 scroll하지 않고, group부터만 scroll한다. terminal font·line
  spacing을 바꿔도 도크의 버튼 여백·목록 밀도·hit rect가 바뀌어서는 안 된다.
- header는 title(강조) → count(secondary)의 좌측 두 줄과 `Local Mac`/refresh의 우측 utility
  cluster를 서로 독립 slot으로 둔다. title/count/utility가 한 baseline 또는 terminal prompt처럼
  보이지 않아야 한다.
- scope는 하나의 rounded outlined control이며 selected segment만 lifted background를 갖는다. search는
  같은 radius 계열의 별도 filled field이고 icon·placeholder/query 사이에 최소 1ch 간격을 둔다.
- group은 위아래 rule과 chevron·workspace name·count pill을 갖는 독립 header다. 기본 session row는
  반복된 외곽 card 대신 full-width divider 목록이고, title은 bold, summary는 muted, provider와
  metadata는 마지막 baseline의 두 slot으로 분리한다. 각 row는 최소 6행을 써 title과 summary,
  metadata가 붙어 보이지 않게 한다.
- 선택/expanded session은 card header와 dark raised detail surface를 한 disclosure 안에 묶는다.
  detail은 outer padding을 가진 inset surface, recent-turn은 role/body 사이 여백, action은 최소
  3행 높이의 같은 baseline 버튼으로 보인다. sibling action에는 최소 `0.5ch` gap을 두고, 각 button은
  그 gap을 제외한 남은 row 폭을 동등하게 나눈다. action의 hit rect·clip·scroll height는 이 여백을 포함한
  동일 tree rect다.
- rich Chrome은 radius/border/shadow token을 사용하고, tui legacy lowering은 같은 rect/spacing을
  직각 fill로만 lower한다. component가 `if (rich)` 또는 font별 좌표 nudge를 두지 않는다.

`ChromeTextRole`은 role별 line box와 final-pixel glyph placement를 전달한다. B1-button-b는 확장
action의 measured label/SVG group centre를 완료했지만, 기본 목록·header utility의 남은 width reservation과
전체 row geometry는 아직 terminal cell metric을 쓴다. AS4-f가 이 기하를 logical spacing/type metric으로
옮기기 전에는 레퍼런스의 padding/density parity를 주장하지 않는다. 이를 cell 수를 억지로 키우거나
fallback font별 nudge로 흉내 내지 않는다.

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

AS4-f는 레퍼런스와의 여백·밀도 차이를 고치는 시각 slice다. **AS4-f-a(현재)**는 action의 icon/text
content inset, icon extent/gap, 48pt minimum height만 Chrome logical spacing metric으로 옮긴다.
**AS4-f-b(후속)**가 outer inset, fixed chrome/card/detail/action 높이, scroll unit까지 같은 metric으로
옮긴다. AS4-f-b가 끝나야 terminal font·line spacing을 바꾸어도 dock 전체 geometry·pointer hit rect가
유지되고 backing scale에만 비례한다고 말할 수 있다. typed layout과 spacing SSOT, 48pt action target·
1×/2×/terminal-font capture 판정은
[Metal UI 레이아웃·컴포넌트 시스템](metal-ui-layout.md#logical-spacing과-component-metric)이 소유한다.
이 visual slice는 실제 사용자 Claude/Codex resume을 자동 실행하지 않는다.

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
  행/문자열 계산으로 갈라질 수 없다.
- `SessionDockHeader`는 title, displayed/recent count, `Local Mac`
  provenance, refresh affordance만 소유한다. refresh가 실행 중이면 같은 위치의
  control이 spinner로 바뀌며 다시 누른다고 worker를 더 만들지 않는다. refresh는
  group body가 아니고 항상 고정 chrome이다. idle refresh는 registered SVG icon의 two-cell
  slot을 쓰고, spinner는 같은 trailing slot을 유지한다. 둘 다 header 오른쪽 외곽이 아니라
  한 text-cell 안쪽 inset에 정렬해 fallback font 또는 icon ink가 rounded-card clip에
  닿지 않게 한다. provider·원격 source 선택기 같은
  별도 filter control은 v1에 추가하지 않는다.
- Header refresh와 search affordance는 일반 Unicode/fallback font glyph를 쓰지 않고 등록된
  SVG coverage icon을 쓴다. idle refresh는 `surface_fg`, disabled spinner는 `muted_fg`라서
  theme accent가 어두운 경우에도 utility icon의 대비가 사라지지 않는다. group expand/collapse
  affordance도 같은 registry의 명시 icon slot으로만 그린다. icon의 코드포인트·two-cell slot·hit
  rect는 component가 함께 소유하며, raw provider 문자열에는 `wide_icons`를 절대 적용하지 않는다.
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

- header의 `Local Mac`은 현재 사용자 홈 아래 provider log만 읽는다는 provenance label이며 host 선택기가 아니다. v1 정렬은 mtime 내림차순 하나로 고정한다. 탭 재진입은 현재 앱 실행 중의 snapshot을 즉시 보이고, 마지막 완료 scan 뒤 **15초** 안이면 새 refresh를 시작하지 않는다. `SessionDockHeader`의 refresh control은 이 TTL을 우회한다. worker가 실행 중이면 동일 rect의 spinner/disabled state로 바뀌고 추가 job을 만들지 않는다.
- 도크 view bar의 `AI 세션`을 누르면 archive refresh를 요청한다. **refresh 중에는 직전 완료 snapshot과 current scroll/selection을 그대로 paint하고, 새 bounded scan 전체가 끝난 뒤에만 새 immutable snapshot으로 한 번에 교체한다.** AS3-c부터 교체 commit은 first partially-visible card의 exact identity와 intra-card pixel offset을 restore하고, identity가 없으면 기존 numeric offset만 새 상한에 clamp한다. 결과 큐의 OOM 등 새 snapshot을 publish할 수 없는 완료는 spinner만 끝내고 기존 목록과 scroll/selection을 유지하며 notice를 보인다. 따라서 새로 고침이 기존 목록을 비우거나 첫 record/중간 batch로 목록을 흔들지 않는다. 첫 진입처럼 이전 snapshot이 없을 때만 skeleton/진행 문구를 보이며, frame tick에서 파일 I/O를 하지 않는다. 창 재포커스와 새 provider session identity 감지는 같은 refresh를 요청하되, forced refresh는 5초 전역 throttle로 합친다. filesystem polling/watcher는 v1에 없다.
- scope는 `현재 작업공간`, `현재 프로젝트`, `전체`다. 기본값은 `전체`이며 마지막 선택만 창 UI 상태로 보존한다. **`현재 작업공간`은 활성 워크스페이스 탭의 활성 local Term이 마지막으로 보고한 CWD를 worker가 canonicalize한 단일 root snapshot 아래에 `cwd`가 있는 기록**이다. 창 전역 탐색기 root와 다른 권위이므로, 다른 워크스페이스 탭의 폴더가 섞이지 않는다. `현재 프로젝트`는 같은 active Term CWD에서 worker가 찾은 canonical git root 아래 `cwd`가 있는 기록이며, local CWD 또는 git root가 없으면 각각 비활성화한다. `전체`는 모든 provider의 검증된 사용자 세션이다. remote/불명 `cwd`는 전체에서만 보인다. 도크 진입, scope click, 활성 workspace/pane/Term 전환 **및 같은 활성 pane의 CWD 보고 변경**에서 root snapshot을 갱신하며, 결과가 오기 전에는 이전 tab 또는 이전 CWD의 범위를 재사용하지 않는다. CWD 비교는 main actor의 메모리 observation만 사용하고 canonicalize·git walk는 worker만 수행한다. 이후 scope/search/scroll/frame은 그 메모리 snapshot만 읽는다.
- 이 필터는 접근 제어가 아닌 표시 범위다. 경로는 provider log의 `cwd`를 canonicalize할 수 있을 때만 containment 비교하며, 실패·삭제·비로컬 값은 workspace/project에 억지로 넣지 않는다.
- 검색은 이미 publish된 snapshot만 대상으로 한다. `/`로 시작한 입력은 header에 표시되고 Esc는 query를 지우고 닫으며, UTF-8 byte substring(ASCII만 case-insensitive)으로 제목·요약·cwd leaf·branch·model을 찾고 입력은 256 byte로 자른다. 검색 키 입력은 재스캔·파일 stat·정렬을 일으키지 않는다. 한국어처럼 case가 없는 문자열은 정확 byte match로 검색된다.
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

## 3. provider 입력과 신뢰 등급

| provider | discovery root | 사용자 세션 확정 | title/summary 신호 |
| --- | --- | --- | --- |
| Claude Code | `~/.claude/projects/*/*.jsonl`의 **직속** 파일만 | 직속 JSONL만; 하위 `subagents` 계층은 절대 재귀하지 않음 | `custom-title`, `ai-title`, first/last user message 순 |
| Codex | `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` | `session_meta.payload.thread_source == "user"`가 있어야 함 | `session_index.jsonl` title(검증 가능한 경우), 없으면 user event |

Codex의 과거 파일에는 `thread_source`가 없을 수 있다. 이 경우 user/subagent를 구별할 근거가 없으므로 v1 기본 목록에서 **제외**하고 `검증할 수 없는 이전 Codex 기록 n개`로만 알린다. 사용자가 토글 하나로 섞어 보게 하는 방식은 잘못된 worker 재개와 목록 오염을 정상화하므로 v1에 넣지 않는다. Claude의 nested subagent transcript도 같은 이유로 제외한다.

각 record의 안정 identity는 provider의 session id와 source file `(device,inode)`다. 같은 provider/session id가 여러 source에 있으면 newest verified source 하나만 표시하고, id 또는 file identity가 충돌/변경되면 둘 다 불신하고 다음 refresh까지 publish하지 않는다. title index는 보조 정보이며 session transcript의 provider/id와 맞을 때만 적용한다.

## 4. 스캔·성능·수명

`SessionArchiveScanner`는 worker에서만 directory enumerate·open·stat·JSONL parse를 하고, main actor에는 immutable `SessionArchiveSnapshot` **완료본 하나**만 건넨다. main actor는 마지막 snapshot을 메모리에 보존해 재진입 즉시 렌더하며, file I/O·JSON parse·정렬·worker wait를 하지 않는다. 대기 중 refresh는 하나로 coalesce하며 old worker completion은 request generation이 맞을 때만 publish한다. dock을 닫거나 앱을 종료하면 cancel을 요청하고, 이미 열린 fd와 staged allocation은 worker가 회수한다.

`SessionDock`의 비례 system-UI text도 같은 frame-path 규율을 따른다. semantic draw op이 바뀌어 rich-text
artifact cache가 miss하더라도 render tick은 `CTLine`/`CTRun`을 만들거나 worker를 기다리지 않는다. host는
`{ fingerprint, scale, text role, origin, max-width, foreground, UTF-8 bytes }`를 deep-copy한 불변 request 하나만
제출한다. 같은 fingerprint의 cache는 계속 paint한다. 새 fingerprint가 필요한 경우에도 목록의 카드·선택·scroll
상태는 유지하되, 다른 geometry/content의 이전 text artifact를 새 frame에 재사용하지 않는다. 아직 artifact가 없는
그 짧은 구간에는 목록의 기존 loading/skeleton 상태만 보인다. request는 하나만 inflight로 coalesce하며, 이후 layout·font scale·theme·snapshot이
다시 바뀌면 결과의 fingerprint가 현재 semantic draw fingerprint와 정확히 일치할 때만 publish한다.

이 text worker는 CoreText의 scalar 결과와 postscript font name을 **소유한 DTO**로만 반환한다. CoreText는 macOS
SDK의 `CoreText.h` thread-safety 계약에 따라 worker에서 호출할 수 있지만, `FontIdentityRegistry`, atlas,
`RenderFrame`, Metal/AppKit handle은 worker가 import하거나 소유하지 않는다. main actor는 완료 DTO를 poll한 뒤에만
현재 registry에 font identity를 intern하고 renderer-neutral `ShapedGlyphRecord`·placement cache로 변환한다. 이
변환은 파일 I/O·native text shaping·wait 없이 bounded DTO를 순회하는 작업이다. 종료 시 host는 새 request를 막고
worker completion을 폐기하며 worker가 자신의 request/result allocation을 회수한다. 따라서 stale completion, app
teardown, 연속 resize에서도 main actor가 native shaping이나 join으로 멈추지 않는다.

AS2는 한 PR에 병렬 parser까지 억지로 섞지 않는다. **AS2-a**는 backend-owned monotonic request generation, dock 이탈/종료 cancel, candidate/file 경계의 cooperative cancel, cancelled generation의 publish 폐기와 재진입 latest-wins 재요청을 닫는다. **AS2-b**가 그 동일 cancellation token과 총 byte reservation을 소비하는 최대 4개 parse worker pool 및 actual peak-concurrency metric/fixture gate를 추가한다. 따라서 AS2-a가 끝나기 전에는 현재 단일 scanner thread를 “동시 parse≤4 구현”이라고 주장하지 않는다.

1. trusted discovery root에서 no-follow directory traversal로 regular file만 수집한다. symlink, socket, FIFO, device, nested Claude directory, 예상 밖 파일명은 skip하며 debug artifact에는 raw 제목/프롬프트/경로를 남기지 않는다.
2. provider별 최대 4,096개 후보 metadata를 mtime 순으로 고르고, 합쳐 최근 순으로 분석한다. 이 상한을 넘으면 header에 `일부 최근 후보만 검사함`을 표시한다.
3. worker는 최근 후보를 제한된 worker pool(동시 parse 최대 4)로 분석한다. 파일은 streaming JSONL parser로 읽고 파일당 128 MiB, refresh당 512 MiB budget을 둔다. worker는 새 **완료** immutable snapshot만 publish하며 main actor는 그것을 한 번에 swap한다. 손상 JSON line은 그 line만 버리고 record를 추측해 만들지 않는다. cap/cancel/OOM이면 완성된 record만 포함한 partial snapshot을 publish한다.
4. first guard는 앱 실행 중의 완료 snapshot TTL 15초다. TTL hit는 filesystem I/O 없이 현재 snapshot만 보이고, force refresh만 이를 우회한다. worker는 다음 guard로 `(device,inode,mtime,size)`가 같은 파일의 verified parse 결과를 재사용한다. cache miss/identity 변경 파일만 다시 분석하며, cache 결과와 새 parse 결과를 mtime 순으로 합친 **완료 snapshot**을 publish한다. 500개 verified record가 완성되면 더 오래된 후보는 v1 refresh에서 분석하지 않는다. memory-only snapshot과 parse cache이므로 앱 종료 후 title/prompt metadata, source path, session id를 디스크에 남기지 않는다. persistent cache는 개인정보 보존·삭제 정책을 별도로 승인하기 전 비목표다.

따라서 첫 진입이 즉시 500개를 완성한다는 보장은 없다. UI는 `228개 표시 · 최근 500개 중 분석 중`처럼 현재 snapshot과 scan 상태를 분리해 말해야 하며, search/scope가 partial snapshot을 완전한 결과인 것처럼 보이게 해서는 안 된다. 이미 완료 snapshot이 있으면 같은 문구를 overlay로만 보이고 카드 목록은 유지한다.

## 5. 보안·개인정보·관측

- provider log는 민감한 개인 데이터다. 원문·prompt·token·절대 home path를 trace, crash artifact, fixture, analytics, config에 쓰지 않는다. fixture는 synthetic·redacted JSONL만 허용하며 [project-rules.md](project-rules.md)의 redaction 기준을 공유한다.
- scanner는 no-follow로 열고 fstat identity를 discovery snapshot과 다시 대조한다. parse 중 교체되거나 permission이 바뀐 파일은 stale로 버린다. published record는 앱 실행 중에만 absolute source path와 `(device,inode)`를 함께 보존하며, `로그 보기`는 사용자가 누른 때에만 그 identity를 다시 검사해 OS file reveal API에 넘긴다. 교체·삭제·비정규 파일이면 reveal을 거부한다.
- resume command는 shell string concat이 아니라 argv array다. session id/provider/cwd는 UI text나 log에서 명령으로 재해석되지 않는다. parse한 prompt는 실행 인자로 절대 넣지 않는다.
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

`src/chrome/components/session_dock/scroll.zig`의 pure `project`가 `Item` kind와 `Metrics`, viewport, offset을 받아
다음을 **한 번에** 산출한다: total content height, clamped offset, 첫 partially-visible item index, 그 item의 negative local
origin, visible item range, 각 item의 rect와 content clip. host는 이 결과가 가리키는 item만 `build.zig`에 전달하며 별도의
visual-row→entry, cell-row, fixed-header y 산술을 하지 않는다. `view.zig`, `chrome_draw_lowering`, published
`UiRectTree`, pointer hit-test, future scrollbar thumb는 이 same projection의 integer rect/clip을 소비한다. 따라서 카드가
clip top에서 반쯤 보이면 그 보이는 반쪽만 draw/hit 가능하고, header 아래로 bleed하거나 다음 card의 action rect가 앞 card를
가로채지 않는다. content height는 item 간 gap만 포함하고 마지막 item 뒤 trailing gap은 넣지 않는다. scroll thumb가
필요한 경우에도 `project`의 total/viewport/clamped offset만 사용해 visual rect를 만들며, thumb drag는 이 slice의
비목표다. 최대 500개 record와 그에 대응하는 bounded group header의 projection은 O(n) scan 하나이며 frame/hover에는
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
host wheel screenshot은 AS3-c 뒤에도 별도 manual/automation gate로 남긴다.

1. **AS1 — 순수 모델·parser:** provider-neutral record, Claude/Codex streaming parser, trust grade, dedup/title/summary/redaction/filter/sort pure tests. 실제 사용자 log는 fixture로 넣지 않는다.
2. **AS2 — bounded scanner:** no-follow discovery, candidate/file/total caps, cancellation/generation, in-memory identity parse cache, 최신순 bounded worker pool과 완료 snapshot atomic publish, metrics. refresh는 직전 완료 snapshot을 유지하고 새 scan이 끝날 때만 교체한다. main tick filesystem I/O=0·JSON parse=0·worker wait=0을 counter와 source boundary test로 고정한다.
3. **AS3 — 도크 Metal component vertical slice:** `SessionDockLayout`과 header/scope/search/group/card/scroll-area primitive를 순수 props/state/layout/view/hit-test/action으로 만든 뒤 host/backend의 semantic draw → Metal GPU lowering에 연결한다. 기존 direct text draw와 pipe scope label은 이 slice에서 제거한다. layout 공유 test가 view rect=hit rect=visible-row origin을, search keypress I/O=0·row 한 번 클릭 provider 실행=0·main thread JSONL I/O=0을 고정한다. loading spinner는 snapshot 유무별로 skeleton 또는 기존 목록 유지인지도 integration test로 고정한다. **AS3-a는 component→CoreText/Metal card background, AS3-b는 published-tree hover/down/up lifecycle, AS3-c는 pixel scroll projection·refresh identity anchor·partial-scroll Lab artifact를 연결한다. active host screenshot E2E는 AS3의 남은 gate다.**
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
- reveal 성공 scenario도 host의 외부 앱 열기를 호출하지 않는다. Swift가 smoke 모드에서 same
  `take_file_tree_external_open` consumer를 drain해 allowlisted fixture token과 횟수만 summary에 기록한다.
- artifact는 ready session **목록**, loading/ready/stale inline expansion의 **1920×960 backing-pixel fixture 창** 제품 Metal PPM·PNG와 redacted key/value summary다. 목록 capture는 published card/action tree만 확인한 첫 frame이 아니라 detached rich-text artifact가 poll·atlas 연결된 뒤의 다음 ordinary frame에서만 요청한다. 한 프레임 뒤 종료하는
  일반 `MARU_SCREENSHOT` 훅은 쓰지 않고, smoke process 안에서만 여러 completed Metal frame을 readback하는 capture
  sink를 쓴다. sink는 이미 paint·publish된 probe가 증명한 상태에서만 **다음 동일 frame**의 renderer output 복사를 요청한다.
  `resume-pointer` scenario는 card click 전의 ready 목록(서로 다른 synthetic record 세 개)·loading·ready, `detail-stale` scenario는 loading·stale를 각각 한 장씩 남긴다.
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
