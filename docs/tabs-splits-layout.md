# 탭 · split(panel) · 레이아웃 전략

이 문서는 Maru의 탭/split(panel) UI를 어떻게 만들지의 단일 출처다. 목표 UX, 아키텍처 결정(모델 vs
드라이버 분리), 렌더링 방식, 단계 분해, 레퍼런스 비교(clean-room)를 정한다.

## 목표 UX

cmux 같은 유연한 레이아웃:

- **세로 탭 사이드바**(왼쪽) — 탭마다 제목 + 메타데이터(우리 OSC 7 cwd, OSC 133 ✓/✗ 종료, 셸 이벤트)를 보여준다.
- **탭마다 split(panel)** — 각 탭은 surface 1개가 아니라 가로/세로로 나눌 수 있는 surface 트리.
- **드래그 재배치** — panel을 끌어 split을 재배열, 탭을 끌어 순서 변경.

## 핵심 결정: 모델과 드라이버를 분리한다

탭/split UI **모델**과 그걸 채우는 **드라이버(소스)** 를 분리한다. 그래야 같은 UI가 "그냥 탭"과 "tmux 탭"
양쪽에서 동작한다.

```
탭/split UI 모델 (SplitTree + 탭 리스트 + 렌더 + 드래그)   ← 하나, 드라이버 무관
        ↑ populate / 조작
  ┌─────────────┴──────────────┐
네이티브 드라이버(기본)          tmux-CC 드라이버(옵션, 후속)
- 탭 = 새 셸 PTY 1개             - tmux 창 → 탭
- split = pane에 새 셸 PTY        - tmux pane → split
- 사용자 액션이 직접 생성/삭제     - 액션을 tmux 제어 명령으로 되보냄
```

- **기본은 네이티브** — `createTab`이 셸 PTY를 띄운다(tmux 없이 그냥 탭/split). 지금까지 만든 게 이 드라이버다.
- **tmux는 옵션 드라이버** — `tmux -CC`(control mode) 공개 프로토콜로 tmux 창/pane이 같은 모델을 구동(후속). iTerm2가 원조이나 GPL이라 **프로토콜 명세(tmux `control-mode`)로만** 구현한다.
- **불변식**: surface/탭/split 모델은 "출력이 어디서 오는지"를 몰라야 한다(네이티브 PTY든 tmux pane이든
  그냥 surface로 본다). 현재 `SurfaceRuntime`이 `surface_id`로만 라우팅하므로 이미 그렇다 — 이 중립성을 유지한다.

## 렌더링 결정: Maru가 직접 그린다(native 최소)

탭 사이드바와 split 레이아웃을 **Maru의 Metal 프레임에 직접 그린다** — AppKit 위젯(NSView 탭/SwiftUI
SplitView)을 쓰지 않는다. 이유:

- 터미널이 이미 Metal로 그려지니, 사이드바·divider도 같은 렌더 경로에 두면 룩을 완전히 통제하고(cmux/Warp식
  커스텀) 우리 메타데이터(cwd/✓✗/이벤트)를 바로 표시할 수 있다.
- [macOS 앱 호스트 경계](macos-app-host-boundary.md)의 native 최소 원칙과 일치 — 레이아웃·상태·히트 테스트는
  Zig가 소유하고, Swift는 backing px 클릭/드래그 좌표만 ABI로 넘긴다(스크롤·마우스 선택과 같은 규율).
- 비-macOS(Linux CI)에서도 레이아웃 로직을 헤드리스 단위로 검증할 수 있다.

레이아웃: 창 drawable을 `[사이드바 strip | 터미널 영역]`으로 나눈다. 터미널 grid의 cols는
`(drawable_width - sidebar_width) / cell_width`로 계산한다(grid 메트릭은 이미 Zig가 권위 있게 소유).
split이 생기면 터미널 영역을 다시 SplitTree에 따라 sub-사각형으로 나눠 각 surface를 그린다.

## SplitTree(panel) 모델

split의 핵심은 재귀 트리다(Ghostty의 SplitTree 동작 참고 — MIT, 개념만, Zig로 독립 구현):

```
Node = leaf(Pane)
     | split{ direction: horizontal|vertical, ratio: f, left: Node, right: Node }
```

- `leaf`는 **Pane 하나**(= 화면의 한 분할 영역). **cmux 풀 모델(PR-A~)**: 한 Pane은 surface 1개가 아니라
  **여러 터미널(Term: surface+PTY+pump)을 가로 탭으로** 담는 컨테이너다(⌘T가 활성 Pane에 Term 추가, Pane
  상단 탭 바가 각 Term을 탭으로 표시, 화면엔 활성 Term의 surface를 그림). `split`은 두 자식을 방향(가로=좌우,
  세로=상하)과 비율로 나눈다.
- `SplitTree`는 **leaf 타입에 generic**(`SplitTree(comptime Leaf)`)이라 트리가 leaf를 pointer-identity로만
  다룬다 — app 레이어(트리)가 platform의 `Pane` 타입을 몰라도 platform이 `SplitTree(*Pane)`로 인스턴스화한다.
- 워크스페이스(사이드바 탭) = 이 트리의 루트. 워크스페이스 리스트 = 트리들의 리스트.
- zoom(한 panel 전체화면), focus 이동, drag-drop zone, Term 탭 이동은 트리/Pane 위 연산이다.

현재 Maru는 탭 = surface 1개(플랫)이고 활성 surface 1개를 풀창 렌더한다. split을 하려면 (1) SplitTree
모델 + (2) **멀티-panel 렌더**(N개 surface를 sub-사각형에 동시 합성 — 렌더러의 큰 확장)가 필요하다.

## 단계 분해

플랫 탭(PR1~PR2, 머지됨: 라우팅 seam·heap-pin·active·동적 컨테이너·멀티-pump·Cmd+T)을 토대로, 다음 순서로
간다. 각 단계는 독립 동작·검증.

1. **PR3a — 세로 사이드바 탭바(레이아웃 토대)**: drawable에 사이드바 strip을 예약하고 터미널 grid가 줄어든
   너비를 쓰게 한다. 사이드바는 우선 단색 strip(탭 엔트리 전). 헤드리스 레이아웃 단위 + macOS smoke(터미널이
   오른쪽으로 밀리고 cols 감소).
2. **PR3b — 탭 엔트리 렌더**(위험도 차이로 둘로 분해):
   - **PR3b-1 — 렌더 메커니즘 + 활성 하이라이트**: `MetalFrame`/ABI에 `sidebar_cells` 두 번째 셀 배열을 더해
     사이드바 rect(x:0..origin_x)에 **origin 0으로 그린다**(렌더러는 셀→quad를 `maru_fill_cell_quad`로 추출해
     터미널·사이드바가 공유; quad 순서 `[터미널][사이드바 배경][사이드바 셀]`). 활성 탭 행에 하이라이트 밴드
     1개(sentinel-UV 배경 셀, 폭=사이드바 칸 floor)를 emit. 텍스트는 아직 없음. "surface→rect"의 두 번째
     surface라 split이 rect별 셀 배열로 그대로 확장한다.
   - **PR3b-2 — 탭 번호·제목 glyph**: 합성 `DrawList`(탭 제목)를 같은 CoreText shaper/rasterizer에 태워(공유
     atlas 두 번째 패스 + 업로드 머지) 사이드바 셀에 제목 glyph를 채운다. 이후 cwd/✓✗ 메타데이터.
3. **PR3c — 탭 클릭/전환**: 사이드바 클릭 → Zig가 탭 인덱스로 매핑 → `switchTab`. Cmd+Shift+]/[ 전환 키.
4. **PR3d — 탭 드래그 재정렬**(사이드바 내 순서 변경).
5. **PR4 — 탭 close**(active_tab clamp).
6. **split 단계(별도, 큼)**: SplitTree 모델 → 멀티-panel 렌더 → split 키/드래그 drop-zone.
7. **tmux-CC 드라이버(별도, 큼)**: control-mode 프로토콜 파서 + tmux 창/pane → 모델 매핑(양방향).

### split 키·방향·포커스 (구현됨, PR3b-1b)

- **키**: `Cmd+D` = 좌우 분할(`split_horizontal`), `Cmd+Shift+D` = 상하 분할(`split_vertical`). **베이스**: iTerm2의 기본
  Split 키(Cmd+D=나란히 좌우, Cmd+Shift+D=위아래)를 그대로 따른다 — macOS 터미널 사용자에게 가장 익숙한 매핑이라
  채택. tmux는 `prefix %`(좌우)/`prefix "`(상하)로 다르지만 옵션 드라이버일 뿐이라 기본 네이티브 키는 iTerm2 관습을 베이스로 한다.
- **방향 명명**: `horizontal`=좌우(나란히, 분할선은 세로), `vertical`=상하(분할선은 가로). 이름은 **분할선의 방향이
  아니라 panel이 나란히 놓이는 축**을 따른다 — tmux `split-window -h`(좌우)/`−v`(상하)와 같은 관습(베이스). iTerm2는
  반대로 분할선 방향으로 부르므로(좌우를 "Vertical") 충돌하는데, 모델·코드는 tmux식 축-기준으로 단일화하고 키 매핑만
  iTerm2 관습에 맞춘다(사용자가 누르는 키는 iTerm2, 내부 enum 이름은 tmux). 이 결정은 `config/action.zig` 주석에도 남긴다.
- **포커스**: 분할 직후 **새 panel로 포커스가 이동**한다(cmux/tmux/iTerm2 공통 동작 — 새로 연 pane에서 바로 입력).
  활성 panel만 입력·커서를 받고, 분할은 활성 panel을 둘로 나눠 한쪽(기존)을 줄이고 다른 쪽(새 셸)을 띄운다.
- **포커스 이동(PR3b-2a/2b)**: ① **마우스 클릭** — 다른 panel을 클릭하면 그 panel로 포커스가 옮겨간다(클릭은 포커스에
  소비, 선택은 새 활성 panel에서 다음부터). ② **키보드** — `Cmd+Option+화살표`로 방향 인접 panel로 이동(**베이스**:
  iTerm2의 pane navigation 키). 방향은 각 panel rect 중심의 반평면 + 정렬(같은 행/열 우대)로 고른다 — 그 방향에 panel이
  없으면 무동작. `Cmd+화살표`(줄 처음/끝)·`Option+화살표`(단어 이동)와는 모디파이어 조합이 달라(command+option) 안 겹친다.
  포커스된 panel은 서브-rect에 있으므로 마우스/커서/IME 좌표가 그 panel의 origin(`active_pane_rect`) 기준으로 매핑된다.
- **Term(가로 탭) 키(PR-B, cmux 모델)**: 한 pane은 여러 Term(터미널)을 가로 탭으로 든다. `Cmd+T`=활성 pane에
  **새 Term**, `Cmd+]`/`Cmd+[`=활성 pane 안에서 **다음/이전 Term**(wrap). 워크스페이스(사이드바 탭)는 한 단계
  위라 `Cmd+Shift+T`=**새 워크스페이스**, `Cmd+Shift+]`/`Cmd+Shift+[`=워크스페이스 전환으로 **shift로 갈린다**
  (modifier 정확 비교). 추가로 **`Cmd+1`~`Cmd+9`=N번째 워크스페이스로 직접 전환**(`select_tab(N-1)`, 범위 밖이면
  no-op — Safari/Terminal.app/iTerm2식). **베이스**: cmux의 ⌘T(pane 내 새 탭)·⌘[](탭 전환). 워크스페이스 생성은
  cmux처럼 **사이드바 하단 "+" 버튼**(③b)으로도 한다 — 탭 목록 아래 슬롯의 "+"를 클릭하면 새 워크스페이스(`newTab`).
- **닫기(PR5a + PR-B cascade)**: `Cmd+W`는 **cmux식 계층 cascade** — 활성 pane에 Term이 여럿이면 **활성 Term**을
  닫고, Term이 1개면 **pane**을(split이면 형제로 collapse, 형제가 빈자리 차지) 닫고, pane이 1개면 **워크스페이스**를
  (마지막이면 창) 닫는다. 즉 Cmd+W를 반복하면 Term → pane → 워크스페이스 순으로 하나씩 닫힌다.
- **exit 자동 collapse(PR5b)**: 셸이 `exit`하면 그 Term도 같은 cascade로 자동 정리된다(Cmd+W 닫기와 동일 경로의
  exit 버전) — 활성/배경 탭·pane 어디서 죽어도 tick의 drain이 종료를 관측한 직후 reap한다. 단 **모든 Term이
  죽으면** 마지막은 reap하지 않고 세션 종료(창 닫힘) latch가 맡는다(빈 세션을 만들지 않음).
- **per-pane 탭 바 렌더(PR-C)**: 각 pane(leaf rect) 상단에 가로 탭 바 strip(높이 = cell 1칸)을 예약하고 그
  아래를 터미널 영역으로 쓴다(`paneTermRect`/`paneBarRect` 단일 출처 — 좌표·resize·split·렌더가 공유). 바는
  터미널 셀 스트림에 origin 박힌 셀로 그려진다(`metal_frame.replace`의 `pane_chrome_cells`, 렌더러·ABI 무변경).
  **PR-C1**: 바 배경만(활성 강조색·비활성 chrome 색). **PR-C2**: Term 제목 glyph를 탭으로. **PR-D**: 호버 ✕·활성
  하이라이트·클릭. **PR-E**: 탭 드래그(pane 내/간). **PR-F**: "+" 버튼.
- **탭 바 "+" 버튼(PR-F)**: 바 우측에 "+"를 그려 클릭하면 그 pane에 새 Term을 띄운다(⌘T의 마우스 버전). 바를
  `paneTabAreaCols(cols)`(넓으면 `cols - 3`, 좁으면 전체)로 나눠 **탭 영역**과 우측 **"+" 영역**을 분리한다 — 탭
  렌더·hit-test(`tabIndexInBar`/`xInTabCloseZone`)·"+"(`xInPlusZone`)가 같은 분할을 공유해 "보이는 = 클릭되는"을
  지킨다. cmux 비교상 "+"는 새 **탭(Term)** 추가이며, split은 ⌘D/⌘⇧D·divider(PR6)로 둔다.
- **divider 렌더·드래그 리사이즈(PR6)**: 두 panel 사이 경계에 divider 선을 그리고, 끌어서 비율을 조절한다. 선은
  layout을 안 바꾸고(틈 없이 abut) **seam 중심 overlay 셀**로 터미널 위·커서 아래에 그린다(`metal_frame.replace`의
  `pane_overlay_cells`, cursor suffix 앞 insert). hit-test는 `layoutDividers`가 주는 seg(split 노드+경계 pos+부모
  bounds)로 seam 밴드(±cell 절반+여유)를 잡고, 드래그가 `ratio = (mouse - bounds.origin)/bounds.size`(`clampRatio`)
  로 `split.ratio`를 바꿔 live 재배치한다. **탭 바가 seam에 붙어 있어** divider는 탭 바(①) 다음·pane 선택(②) 앞
  순서로 잡아 탭 바 클릭을 안 가로챈다. 초기 비율은 0.5(균등).
- **사이드바 폭 조절(③a)**: 사이드바 우측 경계를 드래그해 폭을 바꾼다(폭은 pt로 저장 → DPI 생존). 경계 밴드는
  터미널 쪽만이라 사이드바 슬롯/✕와 안 겹친다. **사이드바 "+" 버튼(③b)**: 탭 목록 아래 슬롯의 "+"로 새 워크스페이스.
- **split 재배치 드래그(④)**: Term 탭을 다른 pane **본문**의 상/하/좌/우 절반(`paneDropZone` — X자 4등분)에 드롭하면
  그 방향으로 새 split이 생긴다(`moveTermToNewSplit`: Term을 새 pane에 담아 `replaceLeaf(target → split{...})`, 소스가
  비면 collapse). 탭 바에 드롭하면 그 pane으로 Term 이동(PR-E2), 본문에 드롭하면 split 생성으로 갈린다. 드래그
  중에는 드롭 타겟 zone을 **반투명 하이라이트**(④b — `premultipliedRgba`로 미리 곱해 터미널이 비침)로 미리 보이고,
  끌리는 탭은 **floating 탭 미리보기**(박스+제목)가 커서를 따라간다(`buildFloatingTabFrame`, 맨 위 frame).
  **호버 커서(②)**: divider=↔/↕ resize, 사이드바 경계=↔, "+"=손가락, 터미널=I-beam.

### 사용자 지정 이름(rename)

워크스페이스(사이드바 탭)·Pane(분할 영역)·Term(가로 탭) 세 계층 모두 사용자가 직접 이름을 붙일 수 있다. 자동
제목과 사용자 이름의 관계(우선순위)·저장 위치·필드 모델은 [Workspace Restore 전략](workspace-restore.md#사용자-지정-이름custom_name과-자동-제목)을 단일 출처로 둔다. 여기서는 **표시 위치와 편집 UX**만 정한다.

- **표시 라벨(단일 해석)**: `custom_name(비면 안 씀) orelse auto title orelse 기본값`. 사이드바 워크스페이스 라벨,
  pane 탭바의 Term 탭 라벨은 모두 이 한 해석을 거친다(자동 제목은 Term=OSC 0/2·cwd, 워크스페이스/Pane=없음).
- **Pane 이름 표시 자리**: Pane은 라벨 자리가 없었으므로 **pane 탭바 좌측에 pane 라벨 세그먼트**를 새로 둔다(좌측
  세그먼트 | Term 탭들 | ‹› | +). `tabbar` 메트릭(segOf/tabIndex)이 라벨 폭만큼 offset해 "보이는 탭 == 클릭되는 탭"을
  유지한다. custom_name이 없으면 세그먼트는 비운다(중복 라벨 방지).
- **편집 UX(인라인)**: 별도 팝업이 아니라 기존 라벨 자리에서 바로 편집한다 — find·palette 오버레이와 같은 입력 모델
  (`OverlayInput`: IME 조합 preedit·UTF-8 경계·EAW caret)을 재사용하고, 키 라우팅도 같은 모달 가드 + `inputFocus()`
  IME 분기를 탄다. `Enter`=확정, `Esc`=취소, 포커스 상실=확정.
- **트리거(세 가지 모두)**: ① **키보드 액션 + 커맨드 팔릿** — `rename_workspace`/`rename_pane`/`rename_term`(활성 대상
  기준). ② **더블클릭** — 사이드바 엔트리·Term 탭·pane 라벨 세그먼트. ③ **Zig 오버레이 우클릭 메뉴** — 네이티브 메뉴가
  아니라 Zig로 그린 컨텍스트 메뉴의 "Rename" 항목(chrome을 Zig로 그리는 전략과 일치). 키보드/팔릿은 활성 대상,
  더블클릭/우클릭은 클릭된 대상으로 해석한다.
- **기본 키바인딩 없음(베이스)**: rename 기본 단축키는 macOS 단일 관례가 없어(Terminal.app은 탭 rename 기본키 없음,
  iTerm2는 더블클릭/⌘I 등 제각각) 임의로 고르지 않는다 — 액션은 정의해 bindable로 두고, 발견성은 커맨드 팔릿·더블클릭·
  우클릭으로 확보한다. 이 결정은 `config/action.zig` 주석에도 남긴다([필수 프로젝트 규칙](project-rules.md)의 베이스 명시
  규칙).

quick terminal·global shortcut은 이 레이아웃과 직교라 별도다.

## clean-room

- **Ghostty**(MIT): SplitTree 개념·드래그 zone·native 탭 동작을 **동작 비교**로 본다(`references/ghostty`).
  코드 구조(자료구조 레이아웃·함수 분해)는 옮기지 않고 Zig로 독립 재구현한다.
- **cmux**(GPL-3.0): 세로 사이드바 + 메타데이터·드래그 UX를 **최종 동작 비교로만** 참고하고 소스는 열람하지
  않는다(LGPL/GPL 레퍼런스 규칙).
- **tmux control mode**: 공개 프로토콜 명세(tmux `control-mode` man page)에서 직접 구현. iTerm2(GPL) 소스 미열람.

## 검증 경로

- 레이아웃 계산(사이드바 너비·터미널 영역·grid cols, split sub-사각형 분할)은 헤드리스 Zig 단위로 고정한다.
- 사이드바/split의 시각 렌더와 클릭/드래그 인터랙션은 macOS smoke(스크립트 가능 부분) + `macos-app-dev`
  수동 검증. 클릭/드래그 좌표→탭/panel 히트 테스트는 Zig라 헤드리스 단위로 검증한다.
