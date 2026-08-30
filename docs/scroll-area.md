# ScrollArea — 스크롤 컨테이너 컴포넌트

스크롤되는 chrome 목록의 **단일 출처**다. viewport, content 높이, offset, 가상화 창, 스크롤바, 드래그,
clip, 그리고 선택 따라가기·키보드 스크롤을 한 컴포넌트가 함께 소유한다. 진행·검증 상태는 [ScrollArea 이관 구현 계획](plans/scroll-area.md)과
[검증 매트릭스](verification-matrix.md)가 소유하고, 이 문서는 계약만 서술한다.

레이아웃 primitive와 typed style은 [Metal UI 레이아웃·컴포넌트 시스템](metal-ui-layout.md)이,
pointer capture·drag 수명은 [Chrome 상호작용 이관](chrome-interaction-migration.md)이 계속 소유한다.
이 문서는 그 둘 위에 "스크롤"이라는 한 책임을 얹는다.

## 1. 왜 필요한가 — 같은 문제를 여러 번 풀고 매번 다르게 틀렸다

스크롤하는 곳은 일곱이고, 좌표 단위·발행 경로·affordance가 모두 다르다.

| | 스크롤 단위 | 가상화 | 스크롤바 발행 | 드래그 | tick 소비 |
| --- | --- | --- | --- | --- | --- |
| Session Dock | backing px | `ui/scroll_area.zig`의 item window | 도크 published tree | dock interaction capture | 있음 |
| 파일 탐색기 | backing px | 없음(행 슬라이스) | 같은 tree(`scrollArea` 선언) | `scroll_area.Drag` | 있음 |
| 소스 컨트롤 | backing px | 없음 | 같은 tree(`scrollArea` 선언, 탐색기와 공유) | `scroll_area.Drag` | 있음 |
| 사이드바 | backing px | 없음 | 같은 tree(`scrollArea` 선언) | `scroll_area.Drag`(도크와 공유, 대상 태그) | 있음 |
| 알림 패널 | **item index** | 없음 | 컴포넌트가 직접 | 없음(휠·키만) | 해당 없음 |
| 팔레트·세팅 | **item index** | 없음 | 없음 | 없음(선택 이동만) | 해당 없음 |
| 탭 바 | **컬럼(가로)** | 없음 | ‹› 버튼 | 없음 | 해당 없음 |
| **네이티브 편집기** | **세로=(논리 줄, 조각) · 가로=열** | 없음(뷰포트 컬링) | 같은 tree(세로·가로 각각) | `scroll_area.Drag`(세로)·`HorizontalDrag`(가로), 도크와 **대상 태그로 공유** | 있음 |

**공유가 아주 없지는 않다.** 알림·팔레트·세팅은 이미 `overlay_input.windowStart`라는 공용 item-window
헬퍼를 쓴다. 그 헬퍼가 푸는 것은 "선택된 항목이 보이도록 창을 최소로 움직이되 이전 위치를 존중한다"
하나이며, 픽셀 좌표·스크롤바·드래그·가상화는 다루지 않는다. ScrollArea는 그것을 대체하는 것이 아니라
**그 위의 층**이고, `windowStart`가 이미 맞게 푼 selection-follow 규칙은 그대로 흡수한다.

각 구현이 풀어야 했던 것은 동일하다: offset clamp, max offset, thumb 비율과 최소 높이, grab 지점을
유지하는 drag 매핑, tick coalescing, tree 교체를 견디는 capture, 분수 휠 residue, thumb fade,
선택 항목 따라가기, 목록 교체 뒤 위치 복원. 그런데 **매번 다른 곳을 빠뜨렸고, 그 누락이 전부 사용자
보고로 돌아왔다.**

- 파일 탐색기 스크롤바는 tick이 좌표를 소비하지 않아 **손을 떼야 목록이 움직였다.**
- Session Dock 스크롤바는 tree 교체에서 capture를 carry하지 않아 **드래그가 첫 move에 죽었다.**
  thumb을 끌면 thumb rect가 바뀌어 tree가 매 프레임 새로 발행되므로 기본 `reconcile`이 매번 취소했다.
- Session Dock 스크롤바를 content rect **안쪽**에 놓아 카드·버튼 위에 겹쳤다.
- Session Dock의 로딩 스켈레톤 quad가 clip을 안 실어 스크롤 영역 밖까지 그려졌다.
- Session Dock에서 펼친 카드를 스크롤로 목록 위까지 올리면 그 배경이 **고정 header/scope 위에 통째로**
  그려졌다. clip은 정확히 실렸지만 그 값이 면적 0이었고, backend quad 규약은 폭 0을 **"클립 없음"**으로
  읽는다(`maru_metal_shader.h`의 `clip.z == 0`). 즉 "한 픽셀도 안 보인다"가 "전부 보인다"로 뒤집혔다.
  → **면적 0 clip을 든 quad는 발행하지 않는다.** `ui.paint`가 published entry에서 한 번 거르고,
  `chrome_draw_lowering.appendBackgroundQuads`가 component 직접 발행 quad까지 마지막으로 거른다.
  셀 텍스트 경로는 이미 맞게 처리하고 있었다(`maru_draw_cells_clipped`가 빈 scissor run을 건너뛴다) —
  그래서 글자는 안 새고 배경만 샜다.

  **왜 골든이 이것을 못 잡았나**: Chrome Lab은 같은 도크를 렌더하면서도 제품과 **다른 lowerer**를 탄다
  (`metal_lowering.lower`). 그 경로의 `appendQuad`는 `Op.Quad.clip`을 통째로 버리고 있어서, Lab 캡처는
  이 결함을 재현조차 할 수 없었다 — 자를 것이 애초에 없으니 "안 잘려 새는" 그림도 안 나온다. 두 host가
  같은 값을 보게 고쳤다(clip 전달 + 면적 0 skip). 이 갈라짐은 §"scrollTextViewport"가 "host마다 다시
  계산하지 않는다 — 제품 host와 Lab이 갈리면 골든이 제품과 다른 그림을 증명한다"고 경고한 그 자리다.

다섯 다 "스크롤 컨테이너라면 당연히 지켜야 하는 것"인데, 소유자가 없어서 소비처마다 다시 발견해야 했다.
`ScrollArea`는 그 규율을 **한 번만** 맞게 구현해 두는 자리다.

## 2. 경계 — ScrollArea가 소유하는 것과 소유하지 않는 것

**소유한다**

- 스크롤 좌표: offset과 그 legal range, clamp, 분수 휠 입력의 residue.
- content 높이와 max offset의 산출.
- 가상화: 지금 그려야 하는 item 창(`first_index`, `end_exclusive`)과 첫 item의 local origin.
- 스크롤바 track/thumb의 기하·발행·drag 선언, 그리고 pointer 좌표 → offset 매핑. **세로와 가로 둘 다**
  (아래 "가로 축을 언제 열었나").
- sticky 헤더의 **위치 clamp**(§4.7). 원래 자리·상단 고정·다음 헤더가 밀어냄이라는 세 상태는 offset의
  함수라 offset을 아는 쪽만 계산할 수 있다. 그 헤더가 가리는 밴드를 **스크롤 텍스트 뷰포트에서 빼는
  것**도 여기다 — quad는 이미 그린 글자를 덮지 못하므로, 밴드를 host마다 다시 계산하면 갈린다.
- 자기 viewport의 clip. 그 안의 **장식 op**은 호출처가 기억하지 않아도 이 clip을 받는다(§5).
  스크롤바도 예외가 아니다 — gutter를 자기 폭에서 예약하므로 그 clip 안에 있다(§4).
- gutter, 즉 스크롤바가 놓일 자리를 자기 폭에서 떼어 놓는 것(§4). 조상의 여백을 빌리지 않는다.
- 자식이 축소되지 않는다는 것(§4.3). 목록은 넘치면 잘려야 하고 줄어들어서는 안 된다.
- selection follow와 키보드 스크롤(§4.5). 선택이 창 밖으로 나가면 최소로 움직이고, PageUp/Home 등이
  같은 offset을 움직인다.
- **viewport 높이를 소비처가 예측하지 않아도 되게 하는 것**(§4.2). 그 값은 layout이 알려 준다.

**소유하지 않는다**

- item의 내용·높이 정책. 높이는 소비처가 준 metric snapshot이 정한다(도크는 `DockMetrics`,
  탐색기는 행 높이). ScrollArea는 그 값을 읽을 뿐 만들지 않는다.
- **무엇이 sticky인지**(§4.7). 어느 항목이 어느 그룹에 속하는지는 domain 지식이고, 가상화 때문에 그
  헤더는 창 밖에 있을 수도 있다. ScrollArea는 받은 선언을 clamp할 뿐 그것을 고르지 않는다 — 라벨·개수도
  선언에 실려 온다(창 밖 항목은 컴포넌트가 볼 수 없다).
- domain 상태. archive record, 파일 트리 노드, 워크스페이스 카드를 모른다.
- effect 실행 시점. drag 좌표를 언제 소비할지는 host의 tick이 정하고, ScrollArea는 그 소비 함수를 제공한다.
- **목록 교체 뒤 위치 복원**(§4.5). 무엇이 "같은 항목"인지는 domain이 알므로 seam만 제공한다.
- 휠 소유자 판정(§4.6). 포인터가 어느 스크롤 영역 위인지는 host의 rect 라우팅이 정한다.
- **가로 스크롤의 좌표·affordance 정책**. 축 자체는 열려 있지만(아래), 어떤 소비처가 어떤 단위로 무엇을
  보여 줄지는 그 소비처가 정한다 — 탭 바가 그 예다.

**편집기는 스크롤 좌표를 px로 들지 않는다.** 세로는 `(논리 줄, 조각)`이고(§4.1d — 랩·접힘 때문에 시각
행과 논리 줄이 비선형이다) 가로는 **열**이다. 그래서 이 소비처는 ScrollArea가 소유하는 것 중 **"스크롤
좌표의 legal range와 clamp"를 자기가 든다** — 공유하는 것은 capture 수명·tree 발행·`pointer → offset_px`
매핑이고, 그 `offset_px`를 무엇으로 해석할지는 편집기가 정한다(도크·사이드바가 같은 `offset_px`를 각자
setter로 받는 구조와 같다). 터미널 viewport를 이 컴포넌트 밖으로 둔 것과 달리, 여기서는 **막대의 기하와
드래그 매핑이 같아** 그 부분만 공유하는 편이 낫다.

### 2.0 가로 축을 언제, 왜 열었나 (2026-08-18 사용자 결정)

**초판은 "v1은 세로 전용"이었고 그 시점을 "탭 바를 실제로 이관할 때"로 정했다.** 근거는 셋이었다 —
탭 바는 좌표 단위(컬럼)도, affordance(스크롤바가 아니라 ‹› 버튼)도, 소유자(`Pane.tab_scroll_cols`)도
세로 목록과 다르다는 것.

**편집기 가로 스크롤바가 그 셋 중 하나를 깬다.** 그 막대는 **affordance가 스크롤바 그 자체**다(§4.1a —
본문 아래 여백에 서고 자리를 먹는다). 즉 "가로는 성격이 달라 나중에"의 근거가 이 소비처에는 해당하지
않는다. 그리고 **세로만 여는 것이 사용자에게 반만 된 상태를 남긴다** — `editor.wrap` 기본이 꺼짐이라
기본 사용자에게는 막대가 둘인데 하나만 잡히는 화면이 된다.

**그래서 축을 연다. 다만 탭 바는 그대로 별개다** — 컬럼 좌표와 ‹› 버튼이라는 나머지 두 근거는 살아
있고, 그 이관은 여전히 자기 시점에 자기 요구를 보고 한다. 이 절이 여는 것은 **"ScrollArea가 가로 축의
기하·drag·매핑을 소유할 수 있다"**까지이고, 어떤 소비처가 그것을 쓸지는 소비처가 정한다.

**축마다 타입을 나눈다.** 세로 `ScrollbarGeometry`/`Drag`와 가로 `HorizontalGeometry`/`HorizontalDrag`는
같은 식의 축 뒤집힌 짝이지만 **한 타입에 담지 않는다** — 담으면 `thumb_y`가 사실은 x라는 식이 되어 읽는
쪽이 매번 축을 되짚어야 한다. 계산식이 같다는 이유로 합치면 그 혼동이 코드 전체로 번진다.

### 2.1 "그냥 `div { overflow-y: auto }` 아닌가"

개념은 그렇다. 자르는 상자 + 스크롤 위치 + 스크롤바다. 하지만 여기서 그것이 **스타일 플래그 하나가 될
수 없는** 이유가 셋 있고, 그 셋이 이 문서가 존재하는 이유다.

`overflow: clip`은 **이미 노드 속성으로 있다.** 그게 주는 것은 자르기 하나뿐이다. ScrollArea가 더하는 것은
offset 상태, 가상화 창, 스크롤바 발행, drag 수명 — 넷이다.

1. **스크롤바를 자식으로 놓을 수 없다.** 브라우저는 절대 위치와 UA paint 순서가 있어서 스크롤바를 상자의
   gutter에 그린다. 우리 flex 엔진에는 절대 위치가 없다. 선언은 한 줄로 유지하되 그 처리는 `build` 안에
   있어야 하는 이유가 이것이다(§4.1).
2. **가상화가 자동이 아니다.** div는 자식을 전부 들고 브라우저가 paint 때 컬링한다. 여기서는 컴포넌트가
   **보일 수 있는 item만** 받으므로, 스크롤 컨테이너가 "무엇을 그릴지"를 빌더에게 **먼저 알려 줘야** 한다.
   방향이 반대다 — div는 만들어진 자식을 자르지만, ScrollArea는 자식을 만들기 전에 창을 정한다.
3. **스크롤 위치가 UA 상태가 아니다.** 브라우저에서는 스크롤 위치가 layout을 넘어 알아서 유지된다.
   여기서는 host 상태이고, 목록이 통째로 교체될 때 무엇을 기준으로 되돌릴지 누군가 정해야 한다(§4.5).
   clamp·tick coalescing·capture carry도 같은 이유로 명시적이다.

그리고 div가 주는 것 중 **v1이 주지 않는 것**도 분명히 해 둔다: momentum/rubber-band 스크롤, 중첩의 가변 높이와 그 스크롤
체이닝(안쪽이 끝에 닿으면 바깥으로 넘기기), `scroll-behavior: smooth`, `overflow: auto`와 `scroll`의 구분
(우리는 넘칠 때만 발행하므로 `auto` 하나다). 필요해지면 그때 각각을 이 문서에 근거와 함께 연다.

### 2.2 이름과 범위 — 컴포넌트 **하나**이고, 이름은 `ScrollArea`다

[Chrome 상호작용 이관](chrome-interaction-migration.md)은 공개 component 후보로 `ScrollArea`와
`Scrollbar`를 **둘로** 나열해 왔다. 이 문서는 그것을 **하나**로 합친다. §4.1의 결론 때문이다 —
스크롤바는 flex로 배치할 수 없어 독립적으로 선언 가능한 component가 될 수 없다. 별도 public
`Scrollbar`를 두면 소비처가 그것을 어딘가에 놓아야 하는데 놓을 방법이 없고, 결국 지금처럼 컨테이너 밖에서
손으로 붙이게 된다. 스크롤바는 스크롤 컨테이너의 **일부**이고, 그래서 선언도 하나다.

이름은 `ScrollArea`다. 코드가 이미 그렇게 부르고 있었고(도크 주석의 "scroll-area content rect",
[에이전트 세션 기록 도크](agent-session-list.md)에 열 곳 넘게), 이 디자인 시스템의 어휘가 그 계보다
(`Card`·`Button`·`Badge` — `tree.zig`가 "shadcn식 의미 component"라고 적은 그것). 그리고 우리 것은
"뷰"라기보다 **영역**이다 — 자체 뷰 계층이 아니라 flex tree 안의 한 컨테이너이고, 스크롤바를 자기
gutter에 두는 영역이다. `ScrollView`는 뷰가 뷰를 감싸는 모델(SwiftUI·React Native)에서 온 이름인데
여기 구조는 그렇지 않다.

**컴포넌트인 것 자체**도 취향이 아니다. 단순히 자르고 스크롤만 하면 속성으로 두는 곳이 많지만
(CSS `overflow: auto`, taffy `Overflow::Scroll`+`scrollbar_width`, GPUI `div().overflow_y_scroll()`),
**가상화가 들어가면 별도 컴포넌트가 된다** — GPUI는 속성 방식을 가지고도 긴 목록을 위해 `uniform_list`를
따로 만들었고, 높이가 섞이자 `VirtualList`를 또 만들었다. Qt는 "전체 내용을 위젯 하나에 그리기
부적합하면 `QAbstractScrollArea`를 직접 상속하라"고 안내한다. 여기가 하는 일이 정확히 그것이다 —
가상화이고 높이가 섞인다(그룹 행·카드·펼친 카드).

그래서 `overflow`는 그대로 남는다. `container`·`card`·`button`의 `.visible`/`.clip`이 CSS의
`visible`/`hidden`이고, `ScrollArea`가 대체하는 것은 `auto` 하나다.

**터미널 스크롤바는 이 문서의 범위 밖이다.** 그것은 chrome 목록이 아니라 terminal viewport의 스크롤백을
움직이며, 입력 우선순위도 terminal의 selection·mouse reporting 모드와 얽힌다(같은 문서의 inventory가 그
보존 조건을 이미 소유한다). 세로 목록 여섯을 하나로 모은 뒤에도 터미널은 별도 판단으로 남는다.

## 3. 좌표계 — backing pixel 하나로 통일한다

좌표 단위가 셋으로 갈라져 있었다 — 픽셀(도크·사이드바), **행**(파일 탐색기·소스 컨트롤 — 둘 다 SV2a·SV3a에서 픽셀로 옮겼다), **item index**
(알림·팔레트·세팅). 행과 item index는 부분 스크롤을 표현하지 못하므로 픽셀 정밀 스크롤·부분적으로 보이는
행·정확한 thumb 위치를 만들 수 없다. 반대로 픽셀 좌표에서 행 인덱스와 item 창은 언제든 파생된다.

그래서 ScrollArea의 좌표는 **backing pixel**이고, 행이나 item 창은 그 좌표에서 파생된다. **나눗셈으로는
아니다** — item 높이는 균일하지 않다(그룹 행, 카드, 펼친 카드가 각각 다르다). 파생은 `project`가 이미
하는 누적 walk의 결과(`first_index`·첫 item의 local origin)이고, 소비처는 그 값을 읽는다. 높이가 균일한
목록에서만 나눗셈이 같은 답을 준다.

**균일한 목록은 나눗셈을 쓴다 — 단, 같은 답이라는 것을 판정으로 고정한 채로.** 파일 탐색기가 그 경우다
(행 높이 = 셀 높이). 행이 수천 개가 될 수 있어 매 프레임 walk를 도는 것은 비용이고, `offset / cell_h`가
정확히 같은 창을 낸다. 그 등가는 말로 두지 않고 `project`와 대조하는 판정자가 지킨다 — 갈라지면 두
소비처가 다른 스크롤 의미를 갖게 되고, 그것은 이 문서가 없애려는 상태 그 자체다.
분수 값은 offset에 넣지 않는다 — tree rect와 GPU draw rect가 정수로 유지되어야 하므로, 트랙패드의 분수
delta는 residue로 따로 누적하고 정수 픽셀만 offset에 반영한다(현재 도크 구현과 같은 규율).

## 4. 발행 모델 — 같은 completed tree 안, 그러나 스크롤 자식이 아니다

스크롤바는 도크·탐색기가 서로 다르게 처리했다(도크는 같은 tree, 탐색기는 별도 tree). 별도 tree는 paint와
hit-test가 다른 출처를 읽게 하므로 "보이는 곳과 눌리는 곳"이 갈라질 여지를 만든다. ScrollArea는 **하나의
completed tree**에 track과 thumb을 함께 싣는다.

동시에 스크롤바는 **스크롤되는 자식이 아니다.** flex 자식이면 가상화의 세로 평행이동을 함께 받아
스크롤할 때 목록과 같이 흘러내린다. 그래서 flex layout의 대상이 아니라, 그 컨테이너의 **자식 entry들이
나온 직후**에 이어서 나오는 viewport 고정 entry다.

**맨 뒤에 append하지 않는다.** `UiRectTree`는 두 불변식을 문서화한다 — entries는 preorder이고(parent가
항상 child보다 먼저), subtree는 다음 sibling boundary까지의 range다. 스크롤바를 배열 끝에
`parent_index = null`로 붙이면 둘 다 깨지고 root가 여럿이 된다. 대신 build의 preorder emit 안에서
"자식들을 낸 뒤, 부모로 돌아가기 전"에 낸다. `parent_index`는 그 스크롤 컨테이너이고, 그러면 두 불변식이
그대로 유지되면서 z도 저절로 맞는다 — 자식들보다 뒤(위)이고, 컨테이너의 다음 sibling보다는 앞(아래)이다.

**clip에는 예외가 없다.** 스크롤바는 자기 컨테이너의 clip을 그대로 받는다. gutter를 **컨테이너가 자기
폭에서** 예약하기 때문이다 — `overflow`가 자르는 컨테이너는 자식이 놓일 영역을 gutter만큼 안쪽으로
밀고, 스크롤바는 그렇게 비운 자리에 놓인다. CSS `scrollbar-gutter`와 taffy의
`content_box_inset.right += scrollbar_gutter`가 같은 일을 한다.

**gutter는 잡는 폭이기도 하다 — 그리는 폭과 다르다.** `ScrollbarGeometry`는 `track_*`(그리는 막대)와
`hit_*`(잡는 자리)를 따로 든다. 막대는 gutter 안에 가운데로 뜨고, 포인터 판정(`trackContains`)은
**gutter 전체**를 본다. 한때 `track_w` 하나가 둘을 겸했는데 막대가 8 backing px(2× 화면에서 4pt ≈ 1mm)라
보이는 띠를 정확히 찍어야만 집혔다 — 얇게 보이는 것은 의도한 디자인이지만 조준 난이도까지 그 값에
묶인 것은 의도가 아니었다.

베이스: xterm.js(VS Code scrollable element)가 `verticalScrollbarSize`(포인터를 받는 트랙)와
`verticalSliderSize`(보이는 thumb)를 나누고 slider를 트랙 안에 가운데 정렬한다
(`verticalScrollbar.ts`). 같은 모델을 쓰되 **hit은 gutter 밖으로 나가지 않는다** — gutter는 컨테이너가
상시 비워 둔 자리라 그 안에는 뺏을 콘텐츠가 없지만, 안쪽으로 넓히면 목록 행 클릭을 가져간다(탐색기는
스크롤바를 행보다 **먼저** 판정한다). 조준을 더 키우려면 소비처가 gutter를 넓힌다 — 그래서
`inset_x_px`를 3에서 8로 올려 gutter를 16px(8pt)로 뒀다.

발행된 tree에는 **그린 rect만** 실리므로(그것이 "보이는 것 = 눌리는 것"의 단일 출처인 이유다), tree에서
기하를 되읽는 경로는 `withHitSpan(gutter)`로 hit을 역산한다. gutter 자체는 `ScrollbarMetrics.gutterPx()`
하나가 답한다 — 예약하는 폭과 잡는 폭이 갈라지지 않게.

여기서 한 가지를 손으로 맞춰야 한다. `layoutFlex`의 clip은 padding을 **제외한** content box라
(CSS의 padding box와 다르다) 방금 예약한 gutter까지 잘라 낸다. 그래서 `build`가 그 폭만큼 clip을
되돌린다 — CSS에서 스크롤바가 padding box 안이라 자기 컨테이너에 잘리지 않는 것과 같은 자리를
만드는 한 줄이다. 그 뒤로는 보통 자식과 규칙이 같고, 중첩에서 안쪽 스크롤바가 바깥 뷰포트에 잘리는
것도 자동으로 나온다.

> **조상의 여백을 빌리지 않는다.** 이전 도크 구현은 스크롤바를 root의 padding 영역에 놓았고, 그러면
> 컨테이너 clip 밖이라 "조상 clip을 쓴다"는 예외가 필요했다. 그 규칙은 padding이 없는 소비처(파일
> 탐색기)에서 곧바로 무너진다 — 빌릴 여백이 없다. gutter가 컨테이너 소유이면 조상이 어떻게 생겼든
> 같게 동작한다.

track이 먼저, thumb이 나중이다 — `interaction.hitAction`이 reverse z-order라 마지막 entry가 이기고,
순서가 뒤집히면 thumb 위 down이 track click으로 판정돼 드래그 대신 점프가 일어난다.

스크롤바는 **목록 위에 겹치지 않는다.** 컨테이너가 자기 오른쪽에 확보한 gutter 안에 놓이며, 나타나고
사라져도 목록 폭을 reflow하지 않는다. gutter가 track 폭을 못 담으면 스크롤바를 아예 그리지 않는다 —
목록 위에 겹쳐 그리는 대안은 두지 않는다.

### 4.1 선언은 한 줄, 두 번째 조각은 `build` 안에 있다

flex 엔진에는 **절대 위치가 없다**(`UiStyle`은 축의 크기·여백·gap만 가진다). 그래서 스크롤바는 목록의
형제 자식이 될 수 없다 — 겹쳐야 하는데 flex는 그것을 표현하지 못한다. 여기까지는 엔진의 사실이다.

그러나 그 사실이 **소비처에게 두 번 호출하게 만들 이유는 아니다.** 스크롤 컨테이너를 tree 노드로
선언하면, 나머지(가상화 평행이동과 track/thumb entry 추가)는 `tree.build`가 그 선언을 보고 한다.
`build`는 이미 노드 props를 entry로 옮기는 자리이며(`visualFor`·`actionFor`), rect와 `effective_clip`을
그 시점에 갖고 있다. 필요한 나머지 입력(offset, content 높이, gutter)은 선언에 실린다.

```zig
tree.scrollArea(.{
    .id = NodeIds.content,
    // 폭을 지정하지 않는다 — `align_items = .stretch`가 margin을 빼고 채운다. `percent = 1`은
    // border box 전체 크기라 margin을 무시한다(CSS `width: 100%`가 넘치는 것과 같다).
    .style = .{ .height = .{ .fill = 1 } },
    .scroll = .{
        .offset_px = state.offset_px,
        .content_h_px = window.content_height_px,
        .first_item_origin_y_px = window.first_origin_y_px, // 가상화 평행이동
        .gutter_px = m.root_inset,                          // 자기 폭에서 떼어 놓는다
        .metrics = m.scrollbarMetrics(),
        .track = .{ .id = ..., .action = ..., .paint = ... },
        .thumb = .{ .id = ..., .action = ..., .paint = ... },
        .drag = .{ .payload = ..., .axis = .vertical, .threshold_px = 0 },
    },
}, item_nodes)
```

`track`/`thumb`은 선택이다 — 없으면 가상화 평행이동만 하고 스크롤바를 내지 않는다(휠 전용 목록).
있으면 발행 여부는 `build`가 기하를 보고 정하므로, 소비처는 action을 미리 만들어 둔다.

이 한 선언에서 `build`가 만드는 것은 셋이다: `overflow: clip` 컨테이너 rect, 그 자식들의 평행이동,
그리고 뷰포트에 고정된 track/thumb entry. 소비처는 `publish`를 따로 부르지 않는다.

`build` 안에서의 순서가 계약이다: **자식 layout → 자식 entry emit → 그 범위만 평행이동 → 스크롤바 emit.**
스크롤바를 평행이동 뒤에 내야 그 이동을 받지 않고, preorder 안에서 내야 §4의 불변식이 유지된다.

세 가지가 이 선언에 함께 따라온다.

- **buffer 상한**이 커진다. `max_entries`는 노드 수 + 1이 아니라 **+ 2 × 스크롤 컨테이너 수**다. 소비처의
  버퍼 산정식이 바뀌므로 이관 시 함께 고친다.
- **스크롤바의 색은 선언이 든다.** `tree.build`는 레이아웃 모듈이므로 track/thumb의 color role을 그 안에
  하드코딩하지 않는다. 기본값은 있되 선언이 덮을 수 있어야 한다.
- **fade 정책**도 같은 자리에 실린다(§7).

지금 Session Dock이 하는 방식 — 컨테이너를 만들고, `build` 뒤에 자식을 손으로 평행이동하고, 그 뒤에
스크롤바를 append하는 것 — 은 **이 계약이 없어서 소비처가 대신 하고 있는 것**이다. 이관의 실질은 그
세 단계를 선언 하나로 접는 일이다.

### 4.2 뷰포트 높이는 예측하지 않는다 — layout이 알려 준다

창(`project`)의 입력에는 뷰포트 높이가 있고, 그 출력이 무엇을 build할지 정한다. 그래서 "layout 전에
뷰포트를 알아야 한다"는 순서 문제가 생긴다. 지금 Session Dock은 그것을 **예측**으로 푼다.

```zig
// host: flex가 할 일을 손으로 베낀 식
return content.h -| m.fixedChromeHeight();
// fixedChromeHeight = root_inset*2 + header_h + scope_h + search_h + control_gap*3
```

한편 tree는 같은 영역을 `height = .fill`로 선언하고 flex solver가 **같은 값을 독립적으로** 구한다.
**한 값의 출처가 둘**이라는 뜻이고, 고정 chrome 노드가 하나 늘거나 margin·root padding이 바뀌면 조용히
어긋난다. 어긋나면 창이 실제 뷰포트와 다른 높이로 계산되어 마지막 행이 잘리거나 빈 띠가 남는다.
이것은 이 저장소가 이미 여러 번 겪은 "같은 수를 두 곳에서 구한다" 결함이다.

ScrollArea는 이 예측을 **요구하지 않는다.** 대신 layout을 두 번 돈다.

1. **측정 pass** — 고정 chrome과 자식 없는 스크롤 컨테이너만으로 layout한다. 이때 각 스크롤 컨테이너의
   viewport rect가 확정된다. item 노드를 만들지 않으므로 비싸지 않다.
2. **본 pass** — 그 viewport로 `project`해 창을 정하고, 그 창의 item만 만들어 최종 layout한다.

두 pass의 비용은 작은 tree 하나를 flex로 한 번 더 푸는 것뿐이다(도크는 노드 수십 개). 그 대가로
"뷰포트를 손으로 예측하는 식"이 사라지고, `fixedChromeHeight` 같은 복제 계산도 함께 없어진다.

이 순서는 **중첩 제약도 완화한다.** 측정 pass가 layout을 한 번 돌기 때문에 바깥에 있든 안쪽에 있든
고정 chrome 안의 스크롤 컨테이너는 viewport를 얻는다. 남는 어려운 경우는 하나다 — **가상화된 item 안에
들어 있는 스크롤 컨테이너**. 그 컨테이너는 어떤 item이 존재하는지가 정해져야 layout되고, 그것은 바깥의
`project` 결과에 달렸다. 이 경우만 안쪽을 고정 높이로 두거나 pass를 한 번 더 돈다.

### 4.3 스크롤 자식은 축소되지 않는다

flex 컨테이너가 `fill`이고 자식 총합이 컨테이너를 넘으면 solver는 기본 `shrink = 1`로 **자식을 균등
축소**한다. 그런데 가상화는 마지막 item이 항상 뷰포트를 넘도록 창을 잡으므로, 그 축소는 예외가 아니라
**상시 상태**가 된다.

축소되면 published rect가 `project`·paint·hit-test가 읽는 metric과 갈라진다. 실제로 이 결함은 사용자
보고로 돌아왔다 — 카드 글자가 자기 카드 밖으로 새고, 펼친 카드의 버튼이 label이 들어가지 못해 배경만
남은 빈 상자가 됐다. 지금은 도크가 자기 item에 `shrink = 0`을 손으로 붙여 막고 있다.

**그 규율은 소비처가 아니라 ScrollArea가 소유한다.** 스크롤 컨테이너의 자식은 축소 대상이 아니다 —
목록은 넘치면 **잘려야** 하고 줄어들어서는 안 된다. 소비처가 매번 `shrink = 0`을 기억해야 한다면 새
소비처마다 같은 결함을 다시 발견하게 된다.

### 4.4 중첩

위처럼 선언이 tree 안에 있으면 **중첩은 대부분 저절로 된다.** `build`는 스크롤 컨테이너를 몇 개 만나든
같은 일을 반복할 뿐이고, drag payload의 identity는 그 노드의 `UiId`다. 목록 자식의 자르기는 이미 중첩된다
(`effective_clip = 부모 ∩ 자기`).

스크롤바도 같은 규칙을 쓰고, 그래서 중첩이 **자동으로** 맞는다 — §4가 정한 대로 gutter는 컨테이너가 자기
폭에서 예약하므로 스크롤바는 그 컨테이너의 clip 안이다. 안쪽 컨테이너의 clip은 이미 바깥 뷰포트와
접혀 있으므로, 안쪽 스크롤바는 바깥이 스크롤될 때 그 뷰포트로 정확히 잘린다. 예외를 만들지 않은 것이
중첩을 공짜로 얻은 이유다.

**소비처가 clip으로 실어야 하는 값은 `effective_clip`이지 `entry.rect`가 아니다.** 가상화는 창의 첫
항목을 음수 origin으로 올려 두므로 그 행의 rect는 뷰포트 밖까지 이어진다 — 그 rect를 clip으로 실으면
clip이 뷰포트보다 커져 **아무것도 자르지 않고**, 그 행의 칠과 글자가 위쪽 고정 chrome 위에 그려진다.
소스 컨트롤 도크가 실제로 그 형태로 깨져 있었다(사용자 캡처 2026-08-21: 목록을 스크롤하면 탭 줄·요약
줄과 겹쳤다). 행마다 clip을 좁히는 소비처는 그 좁힌 값을 컨테이너 clip과 **교차**시켜야 하는데, tree가
이미 접어 둔 `effective_clip`이 정확히 그 값이다.

`Writer`의 컨테이너 clip은 단일 값이 아니라 **스택**이어야 한다. 지금도 펼친 카드의 detail surface를
그리는 동안 clip을 좁혔다 되돌리는 1단 스택을 쓰므로, 중첩은 그 깊이가 늘어난 것뿐이다.

남는 것은 둘인데 성격이 다르다 — 하나는 순서에서 오는 구조적 제약이고, 하나는 정해야 할 정책이다.

1. **가상화된 item 안의 중첩만 어렵다.** §4.2의 측정 pass가 layout을 한 번 돌므로 고정 chrome 안의
   스크롤 컨테이너는 안쪽이든 바깥이든 viewport를 얻는다. 남는 경우는 **바깥의 창 결과에 따라 존재
   여부가 달라지는 item 안에 스크롤 컨테이너가 있는** 경우뿐이다. 그때만 안쪽을 고정 높이로 두거나
   pass를 한 번 더 돈다.
2. **휠 chaining을 정해야 한다.** 안쪽이 끝에 닿은 뒤 바깥으로 넘길 것인가. 브라우저는 넘긴다. 넘기지
   않으면 안쪽이 휠을 가둬 바깥이 멈춘 것처럼 보인다. 이건 ScrollArea 혼자 정할 수 없고 host의 소유자
   판정(§4.6)과 함께 정한다.

**지금 중첩이 필요한 소비처는 없다**(도크의 펼친 카드 detail은 고정 높이라 스크롤하지 않는다). 그래서
v1은 한 겹으로 시작하되, 선언을 tree에 두는 형태를 처음부터 택해 나중에 중첩을 열 때 **발행 경로를 다시
쓰지 않아도 되게** 한다.

### 4.5 selection follow와 위치 복원

목록은 포인터로만 움직이지 않는다. 키보드 내비게이션이 선택을 옮기면 뷰포트가 따라가야 하고, 목록이
통째로 교체되면 보던 위치를 되찾아야 한다. 지금 이 둘은 서로 다른 두 곳에 있다 —
`overlay_input.windowStart`(선택이 창 밖으로 나가면 최소로 이동, 이전 위치 존중)와 Session Dock의
identity anchor 복원이다.

ScrollArea는 **전자를 흡수하고 후자에는 seam만 준다.**

- **selection follow**는 ScrollArea가 소유한다. 입력은 선택 index와 item 높이 metric이고, 출력은 새
  offset이다. `windowStart`의 규칙(선택이 창 안이면 움직이지 않는다, 밖이면 최소로 민다, 이전 위치를
  최대한 존중한다)을 픽셀 좌표로 옮긴 것이다.
- **목록 교체 뒤 복원**은 소유하지 않는다. 무엇이 "같은 항목"인지는 domain이 안다(도크는
  `{provider, session_id, device, inode}`). ScrollArea는 "이 item의 content-space top"과 "그 안에서의
  intra-item offset"을 주고받는 자리만 제공하고, 어떤 item으로 되돌릴지는 소비처가 정한다. 되돌릴
  item이 없으면 기존 숫자 offset을 새 상한으로 clamp한다.

키보드 스크롤(PageUp/PageDown/Home/End)도 같은 offset을 움직이는 동작이므로 ScrollArea가 제공한다.
Session Dock에 이어 **소스 컨트롤**이 같은 넷을 얻었다(2026-08-30). **동작이 늘어나는 변경**이므로 각
이관 단계에서 그 사실을 적는다.

**⚠️ 「탐색기도 함께 얻는다」던 초판 문장은 틀렸다(2026-08-30 실측 정정).** 탐색기는 그 넷을 **이미
쓰고 있고 의미가 다르다** — `file_panel.fileTreeNavigationIntent` 가 `home → .first` · `end → .last` ·
`page_up`/`page_down` 을 **선택 이동**으로 매핑한다(선택이 옮겨 가고 화면은 그것을 따라간다). 거기에
스크롤을 얹으면 그 축을 뺏는다. 실제로 얹어 보니 「file tree keyboard focus preserves identity
navigates scrolls」 판정자가 곧바로 빨개졌다 — **그 테스트가 없었으면 쓰던 기능을 조용히 죽였다.**
그러므로 이 절이 말하는 대상은 **「목록을 굴리는 것 말고 그 키에 다른 주인이 없는」 소비처**다.

**사이드바도 얻었다(2026-08-30) — 단 조건이 하나 붙는다.** 스크롤 상태가 `scroll_area.State` 가 아니라
세션의 `sidebar_scroll_offset_px` 단독이라는 점은 그대로이고, 갈린 것은 **키를 언제 갖느냐**다. 사이드바는
늘 보이지만 그것이 소유권은 아니다 — 터미널에서 친 Page 가 카드 목록을 굴리면 안 된다. 사이드바가 키를
드는 상태는 **검색이 열린 동안** 하나뿐이라(`sidebar_search_active`), 그 안에서만 넷을 가져간다.

그 자리는 원래 **키가 사라지던 곳**이었다 — 검색 라우팅이 모든 키를 소비하는데 `handleSidebarSearchKey`
는 escape·enter·글자만 다루고 나머지를 버려서, 검색 중 PageDown 은 목록도 안 굴리고 터미널로도 안 갔다.
그래서 이 변경은 잃는 것이 없다. 검색 입력이 Home/End 를 caret 으로 쓰지 않는 것도 확인했다 —
`OverlayInput` 은 caret 이 문자열 끝에 고정이다(가로 스크롤만 따라간다).

### 4.6 소유자 판정은 ScrollArea 밖이다

포인터가 어느 스크롤 영역 위인지, 그래서 휠을 누가 먹는지는 host의 rect 라우팅이 정한다. ScrollArea는
"내 offset을 이만큼 움직여라"만 받는다. 한 pointer stream에 capture owner가 하나라는 규칙은
[Chrome 상호작용 이관](chrome-interaction-migration.md) §4.2가 계속 소유한다.

### 4.7 sticky — 스크롤해도 상단에 남는 노드

목록을 스크롤하면 그룹 헤더가 위로 밀려 글자가 반쯤 잘리고, "지금 어느 그룹을 보고 있는가"가 사라진다.
macOS 사이드바·iOS 목록은 그 헤더를 상단에 고정한다. 도크도 그렇게 한다(2026-08-06 결정 — 그 전까지는
sticky를 한다/안 한다는 결정 자체가 없었다).

**경계.** clamp 산술은 ScrollArea가, 무엇을 붙일지는 소비처가 정한다. 가상화가 그 분리를 강제한다 —
스크롤을 내리면 그 그룹의 헤더는 **창에서 빠져 있는데도** 상단에 있어야 하는데, 창 밖 항목이 어느
그룹인지는 domain만 안다.

```zig
// 소비처: 전체 목록에서 상단에 걸린 그룹을 찾아 선언에 싣는다. 그 그룹은 창 밖일 수 있으므로
// 라벨/개수도 함께 넘어온다 — 컴포넌트는 창 안 항목만 보기 때문이다.
tree.scrollArea(.{ .id = ..., .scroll = .{ ..., .sticky = head } }, window_items);
```

걸린 그룹은 **top이 offset 이하인 마지막 그룹**이다. 그 그룹의 흐름 행은 이미 위로 나갔거나 막 상단에
닿았으므로, 같은 rect를 덮는 고정 헤더가 그것을 두 번 그려 보이게 하지 않는다.

**clamp는 한 줄이고 세 상태가 거기서 나온다.** 스크롤 영역 로컬 좌표(0 = viewport top)에서:

```zig
const natural_y = head.top_px - offset;            // 원래 자리
const next_y    = head.next_top_px - offset;       // 다음 그룹 헤더 자리
const sticky_y  = @min(@max(natural_y, 0), next_y - header_h);
```

| 스크롤 상태 | `natural_y` | 결과 |
|---|---|---|
| 아직 헤더를 안 지남 | 양수 | `natural_y` — 흐름 그대로 |
| 헤더를 지나침 | 음수 | `0` — 상단 고정 |
| 다음 헤더가 올라옴 | 음수 | `next_y - header_h` — 밀려 나감(두 헤더가 겹치지 않는다) |

**높이는 그대로 자리를 차지한다.** sticky는 그리는 y만 clamp하고 스크롤 좌표계에서는 원래 높이를
유지한다. 그래서 `project`의 content 높이·창 계산·anchor 규칙이 하나도 바뀌지 않는다 — 흐름에서 빼는
방식을 골랐다면 그 셋을 전부 다시 정해야 했다.

**발행은 스크롤바와 같다.** 가상화 평행이동을 받지 않고(받으면 같이 흘러내린다), 컨테이너 clip 안에
머문다. 폭은 gutter를 뺀 content 폭이다 — 컨테이너 clip은 gutter를 되돌려 포함하므로(§4) clip만으로는
헤더가 스크롤바 밑으로 깔리는 것을 못 막는다.

clip은 흐름 위의 그룹 행과 같은 규율(`overflow = .clip`)이다: 밀려 나가는 동안 컨테이너 clip이 위를
자르고 자기 rect가 아래를 자른다. 그래야 소비처가 흐름 행과 같은 방식으로 잘림을 읽는다.

**그래서 자식 슬롯에 넣을 수 없다.** `build`는 스크롤 컨테이너의 **모든 자식**을 평행이동하므로, 자식으로
선언하면 sticky 헤더가 목록과 함께 흘러내린다. 스크롤바와 같은 자리(자식들을 낸 뒤)에서 별도로 내야
평행이동을 자연히 안 받는다. `.sticky_head`가 자식 배열이 아니라 별도 슬롯인 이유가 이것이다.

**순서는 자식들 뒤, 스크롤바 앞이다.** z는 emit 순서이고 `hitAction`은 reverse z라 뒤에 온 것이 이긴다.
카드가 헤더 **밑으로** 지나가야 하므로 헤더는 자식들보다 뒤여야 하고, 헤더가 클릭 가능하면(그룹 접기)
스크롤바가 그 위를 덮어야 gutter 클릭이 헤더로 새지 않는다. 둘은 좌우로 겹치지 않지만(헤더는 gutter
왼쪽) 순서를 정해 두지 않으면 나중에 헤더 폭이 gutter까지 늘어날 때 조용히 갈린다.

**지금 하지 않는 것.**

- **중첩 sticky.** 도크 그룹은 평면이라(`Entry`가 `group`/`card` 둘뿐) 상단에 남을 노드가 언제나
  하나다. 계층 그룹이 생기면 `sticky` → 슬라이스로 넓힌다. 지금 만들면 실제 요구
  없이 "쌓인 헤더가 서로 밀어내는 규칙"을 추측으로 정하게 된다.
- **`relative`/`absolute`/`fixed` 일반화.** 지금 스크롤바가 `absolute`를, 모달이 `fixed`를 각자 손으로
  하고 있어 개념은 이미 필요하다. 다만 SV1b가 스크롤바를 `build`의 preorder 안으로 넣을 때 "위치 지정
  자식"의 실제 형태가 드러나므로, 그때 이름을 붙이는 것이 지금 추측보다 정확하다.
- **투명 Fragment.** 슬롯에 조각 여럿을 넣어야 하면 `tree.container`로 묶는다. 그 container는 layout에
  참여하는 실제 노드지만 `overflow = .visible` + 배경 없음이면 사실상 투명하다.

**quad는 text를 덮지 못한다 — 그래서 밴드를 잘라야 한다.**

배경 quad와 글자는 서로 다른 렌더 패스라, 나중에 그린 헤더 배경이 앞서 그린 카드 글자를 가리지 못한다.
불투명 배경을 얹어도 카드 제목이 헤더를 뚫고 나온다(Lab 캡처로 확인). 그래서 host는 **스크롤 텍스트
뷰포트의 위를 헤더 바닥까지 내린다** — 그 밴드 안의 목록 글자는 잘려 없어진다.

헤더 자신은 그 밴드 안에 있어야 하므로 예외를 하나 든다: `above_scroll` op은 스크롤 평행이동을 받지
않고(그 y는 매 프레임 다시 계산한 절대값이다) 자기 clip으로 잘린다. 평행이동을 받는 목록 op과 정확히
반대이며, 둘 다 셰이핑 캐시 키에 안전하다.

밴드 산출(`session_dock.build.scrollTextViewport`)은 **host마다 다시 쓰지 않는다.** 제품 host와 Lab이
갈리면 골든이 제품과 다른 그림을 증명하게 된다.

**판정자.**

- 세 상태가 clamp 한 줄에서 나오므로 셋을 각각 본다 — 흐름·상단 고정·다음 헤더가 밀어냄. 단위 테스트가
  offset 셋을 한 표로 돌고, Lab이 그룹 둘짜리 시나리오를 offset 셋으로 캡처한다. `next_y - header_h`
  항을 빼면 두 헤더가 겹치는데, 그것이 빨개지지 않으면 판정자가 없는 것이다(§10.1).
- 골든은 **밴드**도 본다. 헤더 밑 글자를 안 자르면 카드 제목이 헤더를 뚫고 나와 픽셀이 달라진다.
- **`natural_y`는 도크에서 도달할 수 없다.** 걸린 그룹은 top ≤ offset이라 자연 y가 늘 0 이하이고,
  헤더가 흐름에 있는 동안은 흐름 행이 그린다. 즉 골든의 "흐름" 케이스가 실제로 판정하는 것은 clamp의
  첫 항이 아니라 **전환 순간에 자리가 튀지 않는다**는 것이다. clamp 첫 항의 판정자는 단위 테스트뿐이다.
- **셰이핑 캐시 재사용은 Lab이 못 본다**(그 경로는 delta가 늘 0이다). 떠 있는 헤더가 목록과 함께
  평행이동되면 옛 자리에 얼어붙는데, 그것은 fingerprint 단위 테스트가 본다.

## 5. clip은 컨테이너의 속성이지 그리는 쪽의 기억이 아니다

`overflow: clip`은 이미 tree 노드의 속성이고 `tree.build`가 `own_clip` → `effective_clip`으로 접는다.
빠져 있던 것은 **강제**다: generic paint는 노드마다 clip을 실어 주지만, 컴포넌트가 직접 만드는 장식 quad는
그리는 쪽이 매번 clip을 기억해야 했다. 한 곳만 빠뜨려도 새고, 실제로 그렇게 샜다.

이 절이 다루는 것은 **컴포넌트가 직접 만드는 장식 op**(로딩 스켈레톤, 그룹 count pill 같은 것)이다.
그런 op은 **예외 없이 한 출구를 지나고**, 그 출구가 지금 열려 있는 컨테이너의 clip을 기본값으로 싣는다.
CSS에서 `overflow: hidden`이 자손에게 적용되는 자리와 같다. 더 좁은 clip이 필요한 중첩 컨테이너(펼친
카드의 detail surface 등)는 그 구간 동안 clip을 좁혔다 되돌린다.

**스크롤바는 이 규칙의 대상이 아니다.** 스크롤바는 컴포넌트가 만드는 장식 op이 아니라 `build`가 내는
published entry이고, clip도 `build`가 같은 자리에서 싣는다(§4 — 컨테이너의 clip을 그대로 받는다).
`Writer`가 기억할 것이 애초에 없다.

이 규율의 검증은 "스켈레톤이 잘린다"가 아니라 **"컨테이너 안에서 나온 quad에 clip이 없을 수 없다"** 를
고정하는 쪽이어야 한다. 전자는 그 한 컴포넌트만 지키고, 후자는 앞으로 추가될 장식 quad까지 지킨다.

### 5.1 tree 의 clip 은 **글자를 안 자른다** (2026-08-25)

위 문장들은 전부 **quad** 이야기다. measured CoreText 경로의 글자는 `effective_clip` 을 지나지 않는다 —
host 가 `PanePlacement.clip_rect` 로 넘긴 사각형을 보고 `system_text.appendGpuGlyphs` 가 glyph 마다
자른다(`draw.zig` 의 `scroll_clipped` 계약). **컴포넌트가 `scroll_clipped = true` 를 달아도, host 가 그
사각형을 안 넘기면 아무 데도 안 잘린다.**

그 상태가 실제로 두 도크에 있었다. `collectScmDock`·`collectFileTreeDock` 이 `.pane` 에 `clip_rect` 를
싣지 않아, **반쯤 스크롤된 첫 행의 라벨이 목록 위 고정 chrome(SCM 요약 줄·트리 위 뷰 바) 위에
그려졌다.** 사용자가 골든 캡처에서 지적해 드러났다(그전까지 아무 판정자도 말하지 않았다 — 아래).

그래서 **스크롤 영역을 가진 컴포넌트는 자기 `scrollTextViewport` 를 낸다**(`session_dock`·`scm_dock`·
`file_tree`). host 는 그 값을 pane 원점만큼 옮겨 싣는다. 산출을 host 가 다시 쓰지 않는 이유는 위와 같다.

**왜 골든이 침묵했나.** 그 자리를 보던 골든(`scm-scrolled-row-stops-at-list-viewport`)의 계약문은
*"스크롤로 밀린 행은 … 그 경계에서 잘린다"* 였는데 crop 이 잡은 것은 **개수 알약(quad)** 이었다. quad 는
제대로 잘리고 있었으므로 골든은 초록이었고, 같은 행의 **글자**는 아무도 안 보고 있었다. 계약문이 "행"
이라 적고 실제로는 그 행의 한 종류만 볼 때 생기는 일이다.

**판정자 둘을 세웠다**(같은 결함이 다시 나지 않게):

1. **컴파일러.** `collectMeasuredTextFromCache` 의 `text_viewport` 는 **기본값이 없는 인자**다. 그 값이
   `PanePlacement.clip_rect` 의 기본값(`null`)으로 조용히 빠질 수 있던 것이 이 결함의 원인이었다. 이제
   뷰포트는 그 인자 하나가 배치에 찍고 — 리터럴에 적을 수 없다(출처가 둘이 되지 않게) — 소비처는
   `null` 을 **고르는** 것만 할 수 있다.
2. **소스 게이트**(`tests/boundary/imports.zig`). 인자를 필수로 만들어도 `null` 을 고르는 것은 여전히
   컴파일된다. 그래서 스크롤 목록을 그리는 도크 셋은 각자 `build.scrollTextViewport(` 를 부르고 그 값을
   넘겨야 하고, 고정 밴드 둘(사이드바 검색 줄)은 `null` 을 명시해야 하며, **그 다섯 말고 다른 소비처가
   생기면 실패한다** — 새 도크를 더하는 사람이 어느 쪽인지 정하게 된다.

## 6. drag 수명 — tick이 소비하고, tree 교체를 견딘다

pointer move는 tick보다 훨씬 자주 온다. 매 move마다 offset을 적용하면 한 프레임 안에서 같은 재투영을
여러 번 하고, 반대로 tick에서 소비하지 않으면 손을 뗄 때까지 목록이 안 움직인다. 두 실패가 각각 실제로
있었다. ScrollArea의 drag는 좌표를 흡수만 하고 **소비 지점은 tick 하나**다
([Chrome 상호작용 이관](chrome-interaction-migration.md) §4.3의 continuous drag 계약).

thumb을 끌면 thumb rect가 바뀌므로 tree는 **반드시** 매 프레임 새로 발행된다. 기본 `reconcile`은 tree
교체에서 언제나 capture를 취소하므로(click의 안전한 기본값), 그 위에서는 드래그가 첫 move에 죽는다.
스크롤바 drag는 `reconcileCarryingCapture`의 좁은 문을 쓴다 — 같은 identity가 새 tree에 정확히 하나,
여전히 닿을 수 있고 enabled, host가 준 compatibility key가 같을 때만 이어간다. 목록 자체가 교체되면
(snapshot generation 변경) 이어갈 근거가 없으므로 끊는다.

기하는 **down 시점 값을 고정**한다. 드래그 도중 thumb이 움직이는데 매 move마다 새 기하로 다시 계산하면
손가락이 잡은 지점이 미끄러진다. track의 빈 곳을 누르면 그 지점으로 먼저 점프하고 thumb 중앙을 잡은
것으로 이어간다 — 그래서 눌렀다 그대로 끌 때 위치가 튀지 않는다. track도 thumb과 같은 drag를 선언한다.
선언하지 않으면 점프 뒤 move가 오지 않아 손을 뗐다 다시 잡아야 한다.

## 7. 시각 계약

- thumb 높이는 보이는 비율에 비례하되, 집을 수 있는 최소 높이 아래로 내려가지 않는다. 아주 긴 목록에서
  0.04px짜리 thumb은 affordance가 아니다.
- thumb의 기본색은 track보다 **확실히 밝아야** 한다. 둘의 명암이 비슷하면 스크롤바가 있어도 안 보인다
  (실제로 그렇게 만들었다가 캡처에서 분간되지 않았다).
- 목록이 **실제로 넘칠 때만** 발행한다. 넘치지 않는 목록에 스크롤바를 그리면 없는 여백을 있다고 말하는
  셈이고, 잡을 수 없는 track이 그 아래 콘텐츠의 클릭을 가로챈다.
- 치수는 logical spacing token과 backing scale에서만 나온다. terminal cell 폭/높이는 입력이 아니다
  (도크 chevron이 셀 폭에 묶여 있어 폰트만 바꿔도 움직이던 결함과 같은 부류다).
- **hover/press 상태 색이 기본색을 어둡게 만들면 안 된다.** generic card paint는 hover에 배경 role을
  덮어쓰는데, thumb의 기본색이 그 role보다 밝으면 **마우스를 올렸을 때 thumb이 흐려진다**. 스크롤바는
  정보 표면이 아니라 command target에 가까우므로 상태 색을 card 규칙에서 그대로 물려받지 않는다.
- fade는 소비처마다 다르다 — pane·사이드바·파일 탐색기 스크롤바는 idle tick으로 흐려지지만 Session Dock
  스크롤바는 항상 보인다. ScrollArea는 이 축을 **1일차부터** 갖는다(SV1은 no-fade만 쓰지만, 축이 없으면
  SV2가 발행 경로를 다시 써야 한다).
- **그리고 fade alpha는 published tree에 넣지 않는다.** 스크롤바 entry의 paint에 매 프레임 바뀌는 alpha를
  실으면 tree가 프레임마다 달라져 frame 동등 비교가 매번 실패한다. 그러면 fade가 도는 내내 entry·action
  배열을 다시 복사하고 reconcile을 다시 돈다. **드래그가 죽지는 않는다** — carry의 compatibility key는
  snapshot generation이고 fade는 그 값을 바꾸지 않는다. 즉 이것은 정확성 문제가 아니라 churn이며, 동시에
  carry 조건이 나중에 조금이라도 좁아지면 곧바로 정확성 문제가 되는 자리다. alpha는 tree 값이 아니라
  **paint 시점에 얹는 값**으로 두고 tree는 fade 동안 불변으로 유지한다.

## 8. z 축 — 이미 ad hoc으로 자라고 있다

현재 z는 두 축으로 결정된다. renderer의 `GpuQuad.layer`와, 같은 layer 안에서의 **append 순서**다.

`layer`는 닫힌 enum이 아니라 **이미 ad hoc으로 늘어나고 있다.** 지금 0(under)·1(모달 over)·2(bottom)에
더해 **3이 스크롤바 전용으로 추가돼 있다**(pane·사이드바·파일 탐색기 스크롤바가 쓰고
`dropQuadsByLayer(3)`가 프레임마다 비운다). 즉 "스크롤바가 문서 순서를 벗어나야 한다"는 요구는 이미
있었고, 그 답이 새 layer 상수였다. 층이 필요할 때마다 enum에 값을 더하는 방식은 순서 규칙이 두 군데
(layer 상수 + append 순서)로 갈라진 채 계속 자란다.

Session Dock과 파일 탐색기 스크롤바는 generic paint를 타므로 layer 2에 나오고, pane·사이드바
스크롤바는 layer 3이다 — **같은 역할이 두 층에 흩어져 있다.**

그 두 값의 의미도 대칭이 아니다. 렌더러는 layer를 네 버킷으로만 가른다(`maru_metal_renderer.m`):
2=bottom(셀·텍스트 **아래**), 0=under, 4=header, **그 밖의 값은 전부 over**(최상위). 즉 layer 3은
독립된 층이 아니라 모달(layer 1)과 같은 over 버킷이고, 버킷 안에서는 배열 append 순서가 z를 정한다.
그래서 "layer 3 → 2"는 한 칸 내려가는 것이 아니라 **텍스트 위에서 텍스트 아래로 건너가는 것**이며,
그 순간 같은 버킷의 다른 quad(행 하이라이트 밴드 등)와 순서를 다퉈야 한다.

그래서 z 축 정리는 "필요해지면"이 아니라 **ScrollArea 이관 중에 판단한다.** 판단 기준은 소비처 수가
아니라 이것이다: 스크롤바 층을 layer 상수로 계속 표현할 것인가, 아니면 `(layer, z, order)` 정렬로 옮기고
layer는 "합성 패스"의 의미만 남길 것인가. 후자를 택하면 도크 스크롤바의 층 불일치도 함께 사라진다.

### 판단(2026-08-09) — 전역 정렬 축은 필요 없다

SV1~SV5를 마치며 실제 실패 셋을 겪었고, 코드로 확인해 보니 **한 문제가 아니라 셋이었다.** 그 구분이
없으면 "전역 z 정렬"이라는 큰 답으로 몰리는데, 실제로 그것을 요구하는 실패는 하나도 없었다.

| 무엇이 덮었나 | 사례 | 원인 | 처방 |
| --- | --- | --- | --- |
| 렌더러 소유 표면(사이드바 배경 strip) | SV4a | 스크롤바가 layer 2(bottom)라 버킷이 아래였다 | **layer 값만 맞추면 끝**(순서 무관) |
| 같은 오버레이의 배경 quad | SV5b 팔레트 | layer 1과 3이 같은 over 버킷 → append 순서 | 발행 순서(배경 뒤에 장식) |
| 다른 오버레이(모달)가 뒤 스크롤바를 덮음 | 상시 | 같은 over 버킷 + append 순서 | **의도된 동작 — 고칠 것 없다** |
| 창 바닥 상태바(bottom 버킷) | 사이드바 카드 호버(2026-08-13) | **층 문제가 아니다** — under(0)가 bottom(2)보다 뒤에 그려지는 것은 정상이고, 그 quad가 **뷰포트를 넘어 발행된 것**이 원인 | 스크롤 컨테이너의 클립을 렌더 순서 한 곳에서 건다(셀이 이미 쓰던 scissor를 quad draw에도 — [status-bar.md §5.3](status-bar.md)) |

셋째 줄이 중요하다. 코드 주석이 이미 "모달이 스크롤바를 가린다"를 **의도**로 적어 두었다. over 버킷의
순서 의존이 전부 결함인 것이 아니라, 그중 상당수가 지금 원하는 z를 표현하는 수단이다. 전역 정렬 축을
도입하면 이 의도들을 전부 z 값으로 다시 표현해야 하고, 그 재표현이 곧 새 어긋남의 자리다.

**그래서 다음으로 나눈다.**

- **SV6a — 공용 lowering이 layer를 받는다(완료).** `chrome_draw_lowering.appendBackgroundQuads`가 layer 2를
  고정 출력해, 그 경로를 타는 소비처 중 둘(사이드바·오버레이 스크롤바)이 뒤에서 `q.layer = 3`으로
  **되돌리고 있었다.** 같은 역할이 두 층에 흩어진 원인이 이것이다. 이제 인자로 받는다 — **기본값은 두지
  않고 호출자가 명시한다**(처음에는 기본값 2를 두려 했으나, 그러면 "이 draws가 어느 층인가"를 다시 호출부
  밖에 숨기게 된다). 되돌리기 코드는 사라졌다.
- **SV6b — 오버레이 quad를 프레임 끝에 한 덩어리로 붓는다(완료).**

  **처음 적은 계획("각 소비처가 손으로 순서를 지키니 규약으로 적는다")은 틀렸다.** 코드를 확인해 보니
  세 오버레이 막대는 이미 `tick`의 한 자리에서 연속으로 나오고 있었고(SV5b~SV5a-2를 지나며 그렇게 됐다),
  "배경 → 장식" 순서도 이미 지켜지고 있었다. 규약으로 적을 대상이 실은 없었다.

  대신 **다른 축이 깨져 있었다.** over 버킷에서 오버레이보다 **뒤**에 나오는 발행자가 하나 있다 — sticky
  배너 하단 구분선(layer 3)이다. 그 좌표는 `placeAndDistribute` 결과라 오버레이 lowering보다 늦을 수밖에
  없고, y(`origin_y + ch`)가 find 오버레이 상단(`overlay_input.findLayout`의 `region.y + ch`)과 **같은
  행**이다. 즉 터미널 장식이 열린 오버레이 위에 그어진다.

  구분선을 앞으로 옮기는 것은 불가능하다(좌표가 아직 없다). 그래서 반대쪽에서 같은 불변식을 세운다 —
  오버레이 over quad를 `overlay_quads` 대기 버퍼에 모았다가 **프레임 끝에** `gpu_quads`로 flush한다.
  순서를 규율로 지키는 대신 저장소를 나눠, 오버레이 quad가 flush 전에는 `gpu_quads`에 **존재할 수 없게**
  만든다. 앞으로 over quad를 더하는 코드는 flush 앞에 두면 자동으로 오버레이 아래에 놓인다.

  고정하는 불변식: **오버레이 quad 뒤에는 over 버킷 quad가 없다.** 판정자는 `gpu_quads`의 꼬리가
  `overlay_quads`와 원소 단위로 같은지 본다 — flush 뒤에 하나라도 append되면 꼬리가 밀려 깨진다.
  layer 3에 한정하지 않고 "over 버킷 전부"로 두어, 새 layer 값이 생겨도(렌더러가 2·0·4 외에는 전부 over로
  보내므로) 자동으로 걸리게 했다.

**전역 `(layer, z, order)` 정렬은 하지 않는다.** 그것을 요구하는 실패가 없고, `layer`는 z만이 아니라
**per-frame 수명 그룹**이기도 하다(`dropQuadsByLayer(N)`이 그 layer를 매 프레임 비운다 — 1·2·3·4·0).
z를 별도 축으로 빼면 그 수명 축을 무엇으로 대체할지 함께 설계해야 하는데, 지금 그 비용을 치를 근거가
없다. 근거가 생기면(같은 버킷 안에서 **의도하지 않은** 가림이 반복되면) 그때 다시 연다.

**단, 판단과 변경을 같은 슬라이스에 묶지 않는다.** 정렬 축을 바꾸는 것은 lowering을 지나는 **모든 quad
소비자**에 영향을 준다. 그 변경을 "시각 무변경"이 완료 기준인 이관 단계와 한 PR에 넣으면 무엇이 무엇을
깨뜨렸는지 가릴 수 없다. 그러므로 z 축 정리는 자기 슬라이스와 자기 게이트를 갖는다(모달·툴팁·스크롤바가
겹치는 화면의 골든이 그 게이트다). 비용도 "정렬 한 번이라 작다"고 단정하지 않는다 — 정렬 대상 수와 프레임
비용은 그 슬라이스가 **측정해서** 보인다.

## 9. 이관 순서와 그 근거

한 번에 옮기지 않는다. 각 소비처가 ScrollArea에 없는 요구를 하나씩 갖고 있어, 순서가 곧 계약을 넓히는
순서다.

- **SV0 — 판정자를 먼저 만든다(완료).** 이 단계 전까지 도크 골든 어디에도 **스크롤바 픽셀이 없었다.**
  Lab fixture가 `scroll_content_height_px`를 채우지 않아(기본값 0) `scrollbarGeometry`가 `null`을 냈기
  때문이며, 항목 수와 무관했다. 즉 SV1이 스크롤바를 통째로 망가뜨려도 골든이 전부 통과했다.
  `scrollbar` Lab 시나리오(전체 content 4000px, offset 1500px — 양 끝이 아닌 중간이라 track과 thumb이
  **둘 다** 픽셀로 남는다)와 gutter·content 가장자리를 함께 자르는 골든 case가 그 구멍을 닫는다.
  겸사로 게이트 자체의 구멍도 닫았다: 캡처가 **한 장만** 없어도 그 case를 조용히 건너뛰던 것을,
  `MARU_REQUIRE_GOLDEN`(CI가 켠다)에서는 실패로 바꿨다 — 나머지가 통과하면 전체-부재 가드에 걸리지
  않아 그 시나리오의 렌더 실패가 초록에 묻힌다. "게이트가 있다"와 "그 게이트가 이것을 본다"는 다르다.
- **SV1 — Session Dock.** 가상화·픽셀 offset·스크롤바·드래그·키보드 스크롤을 모두 쓰는 유일한 소비처다.
  여기서 ScrollArea를 추출하면 계약이 처음부터 전부 드러난다. 이관이 끝나도 도크의 시각·동작은 바뀌지
  않아야 하며, **0단계가 추가한 스크롤바 골든**이 그 판정이다(기존 네 장만으로는 판정되지 않는다).
  리뷰 가능한 크기로 셋으로 나눈다 — SV1a 좌표계 추출, SV1b 발행·clip을 `build`로, SV1c 측정 pass와
  drag 헬퍼. 단계별 범위는 [ScrollArea 이관 구현 계획](plans/scroll-area.md)이 소유한다.
- **SV2 — 파일 탐색기.** 행 단위 좌표를 픽셀로 옮기는 것이 실제 변경이다. 부분적으로 보이는 행이 생기므로
  행 기반 hit-test·reveal·follow 로직이 픽셀 좌표를 읽도록 함께 바뀐다. 별도 스크롤바 tree와 전용
  capture 경로는 이 단계에서 **제거**한다.

  탐색기 행은 셀 격자 draw list라 도크와 경로가 다르지만, 그것을 measured로 옮기지는 않는다 — pane
  원점이 이미 픽셀이고 `clip_rect`가 있어 부분 행이 표현된다. 그리고 탐색기 콘텐츠는 어떤 tree에도
  없으므로 ScrollArea는 SV1c의 **자식 없는 measure pass** 형태로 쓴다.

  **판정자가 먼저다.** 지금 탐색기에는 시각 골든이 없어(Lab이 도크·detail만 그린다) 스크롤을 통째로
  망가뜨려도 초록이다 — SV0 직전의 도크와 같다. 슬라이스 나눔은
  [ScrollArea 이관 구현 계획](plans/scroll-area.md)이 소유한다.
- **SV3 — 소스 컨트롤.** 탐색기와 같은 행 좌표를 쓰고 스크롤바가 아예 없다. 탐색기 이관이 만든 픽셀 경로를
  그대로 쓰므로 비용이 가장 작고, 없던 스크롤바가 생기는 것이 사용자에게 보이는 변화다.
- **SV4 — 사이드바.** 스크롤바가 host의 GPU quad라 발행 경로가 없다. ScrollArea로 옮기면 사이드바도
  드래그 가능한 스크롤바를 얻는다(지금은 휠 전용이다).

  앞의 셋과 다른 점이 하나 있다. 사이드바는 **이미 제품 컴포넌트**가 밴드를 그리고 그 폭을 자기가
  정하므로, gutter 예약(§4)이 host 안의 산술이 아니라 그 컴포넌트의 계약이 된다. 그래서 발행 경로
  이관과 드래그 추가를 나눠 넣는다 — 슬라이스 나눔은 [ScrollArea 이관 구현 계획](plans/scroll-area.md)이
  소유한다.

  **capture는 공유하되 발행 저장소는 나눈다.** 사이드바와 도크 목록은 동시에 화면에 있으므로 발행된
  track/thumb이 둘 다 살아 있어야 한다. 반면 포인터는 한 번에 하나만 잡으므로 capture와 드래그 기하는
  하나로 두고 대상만 태그한다. 탐색기와 소스 컨트롤이 상태까지 합칠 수 있었던 것은 "한 번에 하나만
  보인다"였기 때문이고, 그 조건은 여기 없다.
- **SV5 — 알림 패널·팔레트·세팅.** `overlay_input.windowStart`의 item-index windowing을 ScrollArea로
  흡수한다. **흡수하기로 결정했다(2026-08-08).** 앞 네 단계를 마치고 실제 계약을 읽은 뒤의 판단이다.

  읽어 보니 셋의 계약이 서로 달랐다.

  | | 스크롤 상태 | 스크롤바 | 휠 |
  | --- | --- | --- | --- |
  | 알림 패널 | `scroll_offset`(**카드 index** 단위) | 없음 | 있음 |
  | 팔레트 | **없음**(`prev_start=0` → selected에서 매번 재파생) | 없음 | 없음 |
  | 세팅 | **없음**(같음) | 없음 | 없음 |

  **반대 근거도 함께 적는다.** 팔레트·세팅은 지금 스크롤 상태가 **0개**다 — 선택이 움직이면 창이 따라올
  뿐이고, 기억하는 값이 없다. 여기에 ScrollArea를 얹으면 없던 픽셀 offset이 생긴다. 이관의 목적이 흩어진
  상태를 **모으는** 것이었는데 이 셋에서는 상태를 **만드는** 쪽이 된다. 알림도 `docs/notifications.md`가
  이미 "텍스트가 셀 행에 스냅되므로 픽셀 스크롤의 실익이 작다"고 판단해 둔 자리다.

  그럼에도 흡수하는 이유는 **일관성과 스크롤바**다. 셋 다 목록이 넘쳐도 얼마나 남았는지 보이지 않고
  잡아 끌 수도 없다 — SV3b가 소스 컨트롤에 준 것과 같은 이득이며, 그것을 주려면 index 단위 창을 픽셀
  좌표로 옮겨야 한다. 스크롤바만 따로 얹는 중간 지점은 없다(발행이 픽셀 좌표를 요구한다).

  **그래서 비용을 설계로 줄인다.** 팔레트·세팅의 offset은 **selection follow가 단일 출처**이고 host가
  손으로 대입하지 않는다. 그러면 새로 생긴 상태가 "selected에서 파생된다"는 지금의 성질을 그대로 유지해,
  두 값이 어긋나는 자리가 생기지 않는다.

  **주의**: 셋 다 오버레이(모달) 셀 경로를 지난다. 스크롤바 quad의 layer와 clip은 사이드바에서 겪은 것
  (공용 lowering의 layer 2가 렌더러 소유 표면에 덮이는 문제)을 다시 판단해야 한다 — 도크에서 안전했다고
  여기서도 안전한 것이 아니다. 슬라이스 나눔은 [ScrollArea 이관 구현 계획](plans/scroll-area.md)이 소유한다.

탭 바(가로)는 이 순서에 넣지 않는다 — §2의 이유로 축 자체가 다른 결정이다.

각 단계는 앞 단계의 계약을 넓히기만 하고 바꾸지 않는다. 넓혀야 한다면 그 이유를 이 문서에 먼저 적는다.
**동작이 늘어나는 단계**(키보드 스크롤이 생기는 곳, 없던 스크롤바가 생기는 곳)는 그 사실을 이관 PR에
명시한다 — 순수 refactor가 아니다.

## 10. 검증

- **컴포넌트 단위**
  - 기하: 넘칠 때만 발행, 최소 thumb, 양 끝 도달, pointer↔offset round-trip.
  - 발행 위치: track/thumb이 스크롤 컨테이너의 자식 **직후**에 나오고 `parent_index`가 그 컨테이너다
    (배열 끝 append가 아니다 — preorder와 subtree range가 유지되는지).
  - clip: 컨테이너 안의 장식 quad에는 clip이 **없을 수 없다**(§5). 스크롤바는 gutter를 컨테이너가 자기
    폭에서 예약하므로 같은 clip 안에 **살아남는다**(§4). 그리고 그 clip이 컨테이너를 **넘지도 않아야**
    한다 — gutter를 되돌리는 코드가 이 저장소에서 clip을 넓히는 유일한 자리라, `layout.zig`의 "자식
    clip은 항상 부모 clip 안" 불변식을 깰 수 있는 지점이 거기뿐이다(경계는 양쪽을 본다 — §10.1).
  - 가상화 평행이동이 스크롤바에 닿지 않음.
  - 자식이 축소되지 않음(§4.3): 넘치는 목록에서 published rect가 metric 높이와 같은지.
  - selection follow(§4.5): 선택이 창 안이면 offset 불변, 밖이면 최소 이동.
- **host 단위**: tick이 소비 지점임(move 수가 아니라 tick 수만큼 스크롤한다), tree 재발행에서 capture가
  살아남고 snapshot 교체에서는 끊김, 그리고 측정 pass의 viewport와 최종 layout의 viewport가 **같음**
  (§4.2 — 예측식이 되살아나면 여기서 갈라진다).
- **시각**: SV0가 추가한 **스크롤바가 실제로 보이는** 골든이 이관 전후 불변임을 보인다. 기존 네 장은
  스크롤바 픽셀이 없어 이 판정을 하지 못한다. 시각이 바뀌어야 하는 변경이면 캡처를 눈으로 대조하고
  무엇이 왜 달라졌는지를 남긴다([파일 탐색기](file-explorer.md)·[에이전트 세션 기록 도크](agent-session-list.md)의
  해당 절과 같은 규율).
- 각 회귀 테스트는 **그 수정을 되돌리면 실패해야** 한다. 통과만 확인한 테스트는 무엇도 고정하지 않는다.
- **"게이트가 있다"와 "그 게이트가 이것을 본다"는 다르다.** 도크 골든이 좋은 예다 — 네 장이 존재하지만
  Lab이 스크롤 입력을 채우지 않아 **스크롤바 픽셀이 하나도 없다**. 스크롤바를 통째로 지워도 전부
  통과한다. 새 계약을 세울 때는 그 계약이 깨진 상태를 **실제로 만들어** 게이트가 빨개지는지 확인한다.

### 10.1 계약을 깨뜨려 확인할 때

SV1a는 좌표계를 옮기는 작은 이관이었는데, 계약을 하나씩 실제로 깨뜨려 보니 스크롤 전반이 거의
판정되지 않고 있었다. 그 과정에서 **판정 자체가 틀리는 방식**이 나왔고, 이후 단계(SV1b·SV1c·SV1d)에서
더 나온 것을 같은 자리에 더한다.

- **게이트를 하나 빼고 결론짓지 않는다.** `view.zig` 변이를 단위 테스트로만 돌려 "텍스트 배치가
  무판정"이라고 할 뻔했다. 실제로는 골든이 그 축을 보고 있었다. 관련 게이트를 전부 태워야 한다.
- **부분 변이는 근거가 못 된다.** 같은 계약이 두 곳에 쓰여 있으면(`.clip = active_clip`,
  `pageStepPx(...)`) 한 곳만 바꿔서는 다른 경로가 여전히 지킨다. 살아남았다면 먼저 변이가 대상에
  **닿았는지** 확인한다.
- **컴파일 실패와 panic은 다르다.** 변이가 컴파일되지 않으면 테스트가 아예 안 돌았으므로 판정이
  아니다("0 FAIL"을 통과로 읽으면 안 된다). 반대로 panic(ABRT)은 스위트가 초록이 되지 않으므로
  **감지된 것**이다. 그래서 **변이 실행의 출력을 버리면 실험이 아니라 추측이다** — 존재하지 않는
  color role로 thumb을 바꾸고 스모크를 `> /dev/null 2>&1`로 돌린 적이 있다. 빌드가 실패해 캡처가
  갱신되지 않았는데 골든이 초록이었고, 그걸 "게이트가 깨졌다"로 읽었다. 변이 실행은 빌드 성공을
  **먼저 눈으로 확인**한다.
- **캡처 기반 게이트는 캡처를 다시 만들어야 판정이다.** 골든은 `zig-out/maru-macos-chrome-lab/*.ppm`을
  읽어 `tests/golden/*.ppm`과 비교할 뿐 렌더를 다시 하지 않는다. 소스만 변이하고 골든을 돌리면 **변이한
  빌드의 픽셀을 한 번도 안 본 채** 초록을 얻는다. Lab 스모크를 먼저 돌려 캡처를 갱신한 뒤 골든을 본다.
- **fixture가 그 계약을 발동시키는지 먼저 본다.** 스크롤 자식의 `shrink = 0`(§4.3)을 지우고 Lab 스모크를
  다시 돌렸더니 캡처 29장이 **전부 byte-identical**이었다. 골든이 고장난 것이 아니라(같은 방법으로 thumb
  색을 바꾸면 빨개진다) fixture가 flex line을 넘치지 않아 축소가 **일어나지 않은** 것이다 —
  `scroll_content_height_px`는 스크롤바를 띄우기 위한 선언값이지 자식 높이의 합이 아니다. 넘침·잘림처럼
  **입력 조건이 있어야 성립하는 계약**은, 변이 전에 그 조건이 fixture에서 참인지 단언으로 고정한다
  (`build.zig`의 축소 테스트가 `total_h > content.rect.height`를 먼저 단언하는 것이 그 형태다).
- **테스트가 제품 경로를 태우는지 본다.** 도크 props 리터럴을 테스트가 복제하고 있어서, host를
  아무리 틀리게 만들어도 테스트는 자기 복제본만 검사했다. 같은 지식이 두 곳에 있으면 판정이 사라진다
  (버퍼 크기 산술도 같은 이유로 `build.bufferSizes` 하나로 모았다).
- **단언이 판정할 수 있는 상태인지 본다.** 값이 0인 상수를 양쪽에 쓰거나(도크의 `item_gap`),
  잔여가 없는 상태에서 잔여 소거를 검사하거나, thumb **중앙**을 눌러 잡기와 점프를 구분하려 하면
  단언은 통과하지만 아무것도 고정하지 않는다.
- **경계는 양쪽을 본다.** SV1b의 clip 확장이 그랬다 — "스크롤바가 clip **안**"만 보고 "clip이 컨테이너
  **안**"을 안 봐서, clip을 gutter의 두 배로 넓히는 변이가 통과했다. clip은 "여기까지만 그린다"는
  약속이라 넓히기만 하고 상한을 안 보면 약속 자체가 무의미해진다. `layout.zig`가 "자식 clip은 항상
  부모 clip 안"이라고 적은 불변식이 있으면, 그것을 **깰 수 있는 코드**(여기서는 clip을 넓히는 유일한
  자리)마다 그 불변식을 단언한다.
- **Lab은 원점이 (0,0)이라 좌표 변환을 못 본다.** 고정 헤더의 clip에 pane 원점을 안 더한 결함이
  단위·골든을 전부 통과했다 — Lab이 도크를 프레임 원점에 그리기 때문이다. 제품에서는 도크가 화면
  오른쪽에 있어 clip이 왼쪽 끝에 남았고 **헤더 글자가 통째로 사라졌다**. 제품 스모크 캡처를 눈으로
  보고서야 드러났다. 컴포넌트 좌표를 backing 좌표로 옮기는 코드는 원점이 0이 아닌 축에서 판정한다.
- **초록/빨강을 문자열로 읽지 않는다.** SV1d에서 변이 검출기가 `FAIL`이라는 낱말을 찾았는데,
  `expectEqual` 실패는 `expected X, found Y`만 낸다. 그래서 **잡힌 변이 둘을 살아남았다고 보고했고**,
  없는 구멍을 메우려 할 뻔했다. 자동 판정은 종료 코드나 그 테스트 이름 뒤의 `OK` 유무로 본다.
- **한 사실을 두 번 키에 넣으면 뒤엣것은 무판정이다.** sticky op의 `above_scroll` 불리언과 그 op의
  clip을 **둘 다** fingerprint에 섞었더니, 불리언을 빼는 변이가 통과했다 — clip을 섞는 분기 자체가
  이미 그 사실을 남기고 있었다. 관측할 수 없는 항은 지운다.
- **살아남았다고 다 구멍은 아니다.** 관측 가능한 차이가 없으면 등가 변이다(도크에는 스크롤바 외
  drag가 없어 carry 문을 넓혀도 통과할 것이 없다). 그리고 **내가 계약을 잘못 알았을 수도 있다** —
  원점이 0인 카드도 유효한 anchor다. 테스트를 쓰기 전에 코드를 읽고 왜 그런지 확인한다.

## 11. API 스케치

아래는 계약이 실제 호출부에서 어떤 모양이 되는지 보이는 흐름이고, 소유는 `chrome/ui/scroll_area.zig`와
`chrome/ui/tree.zig`가 나눠 갖는다(좌표계·투영·스크롤바 기하·drag 수명은 앞이, 발행과 clip은 뒤가).
이름과 시그니처는 계약이 아니라 예시다 — 실제 호출부가 이 형태를 그대로 따라야 한다는 뜻은 아니다.

```zig
// 상태는 소비처가 소유한다. ScrollArea는 그 값의 legal range와 전이만 정한다.
scroll: chrome.ui.scroll_area.State = .{},

// ── 1. 측정 pass. 고정 chrome과 **자식 없는** 스크롤 컨테이너만 layout해 viewport를
//      확정한다. 뷰포트 높이를 손으로 예측하지 않는다(§4.2).
const measured = try tree.build(self.chromeRoot(&.{}), options, measure_buffers);
const viewport_h_px = measured.rectOf(NodeIds.content).height;

// ── 2. 그 viewport로 창을 정한다. 무엇을 build할지가 여기서 나온다(div와 반대 방향, §2.1).
//      항목 높이는 **함수로** 묻는다 — 균일 높이를 전제하면 §3의 walk 계약이 깨진다. 도크는 그룹
//      헤더·카드·펼친 카드가 각각 다르므로, 그 예외 전부가 `items` 한 자리에 모인다.
const items = self.dockScrollItems(); // entries + 높이 규칙
const window = chrome.ui.scroll_area.project(
    items,
    @TypeOf(items).heightPx,
    items.extent(viewport_h_px),
    self.scroll.offset_y_px,
);

// ── 3. 그 창의 item만 만든다. 보이지 않는 행은 노드도 텍스트도 만들지 않는다.
const item_nodes = try self.buildItems(arena, window.first_index, window.end_exclusive);

// ── 4. 선언은 한 줄이다. clip·자식 shrink 금지·가상화 평행이동·sticky·track/thumb 발행은 `build`가 한다.
top[3] = tree.scrollArea(.{
    .id = NodeIds.content,
    .style = .{ .width = .{ .percent = 1 }, .height = .{ .fill = 1 } },
    .scroll = .{
        .offset_px = window.offset_px,
        .content_h_px = window.content_height_px,
        .first_item_origin_y_px = window.first_origin_y_px,
        .gutter_px = m.root_inset,
        .metrics = m.scrollbarMetrics(),
    },
}, item_nodes);

const built = try tree.build(root, options, buffers);
```

host 쪽은 세 지점뿐이고, 그 셋이 §6의 drag 계약을 그대로 만든다 — `scroll_area.Drag`가 그 수명을 소유한다.

```zig
// down이 스크롤바 위면 grab 지점을 확정한다(track의 빈 곳이면 그 지점으로 먼저 점프할 offset을
// 돌려주고, 이어지는 드래그는 옮긴 뒤의 기하를 쓴다). 기하는 **published tree에서 읽는다** —
// 두 번째 기하 출처를 만들지 않는다(§4).
if (phase == .down) _ = self.scroll_drag.begin(bar, local_x, local_y);

// dispatch가 낸 drag는 **좌표만 흡수**한다. 여기서 offset을 적용하지 않는다.
if (dispatched.drag) |event| self.scroll_drag.absorb(event.x, event.y);

// tick 하나가 소비한다 — move 수가 아니라 tick 수가 상한이다. 값이 직전과 같으면 null이라
// track 끝에 닿은 채 계속 미는 동안 같은 effect를 반복하지 않는다.
if (self.scroll_drag.takeOffset()) |offset| self.scroll.offset_y_px = offset;
```

tree를 다시 발행할 때는 스크롤바 drag만 좁은 carry 문을 태운다(§6).

```zig
if (scroll_area.isDraggingScrollbar(interaction)) {
    _ = try interaction_mod.reconcileCarryingCapture(&interaction, new_tree, previous_key, current_key);
    if (interaction.capture == null) self.scroll_drag.end();
} else {
    _ = try interaction_mod.reconcile(&interaction, old_tree, new_tree);
}
```

이 스케치가 드러내는 것 셋. 첫째, **`project`가 build보다 먼저 온다** — ScrollArea는 "자식을 자르는 상자"가
아니라 "자식을 만들기 전에 창을 정하는 것"이고, 그 순서가 §2.1에서 div와 갈라지는 지점이다. 둘째, **소비처
코드에 발행 단계가 보이지 않는다** — 선언 하나이고 나머지는 `build`가 한다. 그래서 중첩이 늘어도 호출부는
변하지 않는다. 셋째, **뷰포트 높이가 코드에 상수식으로 나타나지 않는다** — 측정 pass가 알려 주므로
`fixedChromeHeight` 같은 복제 계산이 생길 자리가 없다.
