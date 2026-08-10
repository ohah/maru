# 탭 · split(panel) · 레이아웃 전략

이 문서는 Maru의 탭/split(panel) UI를 어떻게 만들지의 단일 출처다. 목표 UX, 아키텍처 결정(레이아웃 모델과
terminal runtime 소유 분리), 렌더링 방식, 단계 분해, 레퍼런스 비교(clean-room)를 정한다. 앱 종료를 건너 PTY와
프로세스를 유지하는 계약은 [영속 터미널 세션 호스트](persistent-session-host.md)를 단일 출처로 둔다.

## 목표 UX

cmux 같은 유연한 레이아웃:

> **그룹(접이식 워크스페이스 묶음)**: 워크스페이스 카드를 이름 붙은 그룹으로 묶어 접고 펴는 조직화 레이어는
> [사이드바 그룹 전략](sidebar-groups.md)을 단일 출처로 둔다(설계 단계). 그 설계는 이 절의 flat 카드 나열을
> "SidebarRow 투영"으로 일반화해(검색 필터 `sidebar_visible_tabs`·pinned 파티션을 근본 모델로 승격) 헤더·접힘·
> 들여쓰기를 slot=card 가정 없이 흡수한다.
>
> **에이전트 하위 목록**: 아래 "에이전트 아이콘"과 카드 **상태줄**(대표 1개 압축 표시)은
> [사이드바 에이전트 목록](sidebar-agent-list.md)이 **Term 단위 전수 나열 목록으로 대체**한다(설계 단계). 그 설계는
> 이 절의 "카드 높이는 cell의 3.8×" 고정 슬롯을 **줄 수 기반 동적 높이**로 바꾸고, 카드 하위에 `N agents` 토글 행과
> 에이전트 행을 얹는다. 아래 아이콘·상태줄 서술은 그 슬라이스가 머지되면 그 문서가 단일 출처가 된다.

- **세로 탭 사이드바**(왼쪽) — 워크스페이스마다 **1~3줄 카드**로 보여준다. line0=이름(워크스페이스 번호 prefix는
  안 붙임 — 사용자 요청). **이름줄 선두**엔 동작/활성 마커를 1칸 붙인다: 활성 워크스페이스=`*`(강조), 그 외=`·`(U+00B7,
  흐림). git repo 안이면 line1=`├ {branch}`, line2=cwd 경로(`$HOME`→`~` 축약). 보조줄(브랜치·경로)은
  git repo일 때만 추가되고 흐린 색, 줄들은 슬롯 안에 세로 중앙 정렬한다. 세로 위치는 row에 `slot*32 + line_count*4 +
  line_index`로 인코딩(`sidebarGlyphRow` 단일 출처)하고 렌더러(.m)가 디코드 — 인코딩은 향후 4번째 줄(상태)까지 여유,
  현재 구현은 3줄. **카드 높이는 그 카드가 실제로 그리는 줄 수에서 나온다**(줄 블록 + 위아래 여백 — 옛 고정 슬롯
  cell×5.2 폐기, [사이드바 에이전트 목록](sidebar-agent-list.md) §3이 단일 출처). 4줄 카드는 옛 슬롯과 같은 높이라
  겉모습이 유지되고, 줄이 적은 카드에서 남던 빈 공간만 사라진다. **베이스/결정**: git 브랜치는 OSC 7 cwd에서 `.git/HEAD` walk-up(cwd 변경
  시에만 읽어 per-Term 캐시; 파생값·영속 안 함; `readGitBranch`/`termGitBranch`), repo 밖이면 보조줄 생략.
- **에이전트 아이콘** — 그 Term 포그라운드가 claude/codex CLI인 동안만, 카드 **줄과 무관하게 슬롯 세로 중앙·좌측에 독립**
  배치한다(아바타식; 텍스트 줄은 그만큼 우측으로 들여씀). 아이콘 존재=그 Term의 foreground agent 종류,
  사라지면 agent가 아님(파생값, 영속 안 함).
  - 감지: PTY 포그라운드 프로세스명(`tcgetpgrp`+libproc `proc_name`)을 ≈0.5s마다 polling(`pollAgentKinds`/`classifyAgent`).
    comm이 인터프리터(node 등)면 `KERN_PROCARGS2`로 argv[1] 스크립트 basename을 꺼내 분류 — codex가 `#!/usr/bin/env node`
    스크립트라 comm="node"로 떠도 잡힌다(claude는 네이티브라 comm="claude"). 공개 sysctl API(ps·libproc와 동일), clean-room.
  - 심볼·색(베이스/결정): 브랜드 전용 유니코드가 없어 근사 글리프 — claude=`✶`(U+2736 6각별, Anthropic 선버스트 근사)·
    codex=`◆`(U+25C6 다이아)로 **종류**를 구분한다(`agentSymbolCodepoint`). 글리프는 **터미널 폰트(JetBrains Mono)가
    보유한 것만** 고른다 — 미보유 코드포인트(예전 `✳` U+2733)는 CoreText fallback 폰트로 넘어가 한글 '정' 등으로 글리프가
    어긋나 간헐 깨짐이 났다(근본 수정: 폰트가 가진 글리프만 쓰면 fallback 자체가 일어나지 않아 깨질 여지가 사라진다). 아이콘은 카드 왼쪽 독립 gutter에
    **2칸(width 2)**으로 또렷이 그린다(`icon_cols=3`; `.m` gscale 1.1× 보조 확대). 단 ✶/◆는 **OS 폰트로 그리는 알림 제목용 심볼**
    (`agentSymbolCodepoint`)이고, **사이드바 gutter는 maru 합성 PUA**(`agentIconCodepoint` — sparkle `0xF0007`/diamond `0xF0008`,
    `assets/icons/{sparkle,diamond}.svg`→coverage)다. **claude sparkle는 두꺼운 4갈래 별로 코덱스 diamond와 잉크 mass를 맞췄다** —
    얇은 4갈래 스파클이 작은 gutter 크기에서 다이아보다 작고 흐려 보인다는 사용자 피드백 반영(SVG arms를 두껍게 → `svg_to_coverage.py` 재생성,
    잉크 ≈diamond). **색은 종류**를 따른다 —
    claude=Anthropic 공식 코랄 `#CC785C`, codex=OpenAI 청록 `#10A37F`(`term.agent_kind` 기준 단일 출처). **관측 상태**는 카드
    **상태줄**(running=**`▁▅▇▃ 진행중` 이퀄라이저 스피너**, blocked=`? 입력 대기`, idle=`✓ 대기중`,
    unknown=`· 상태 확인 중`)이 구분한다 — running 스피너는 블록 문자
    `▁▂▃▄▅▆▇█`(U+2581~2588, `renderer/block_glyph.zig` 절차 합성) 4칸 바운싱 바로, 각 바 높이는 삼각 파형(`spinner_wave`)을
    서로 다른 위상(`spinner_bar_phase=[0,4,8,12]`)으로 읽어 파도친다. `agent_spin_frame`(약 133ms마다 +1 mod 14, 파형 길이)으로
    진행한다. **위상은 사이드바 카드 파형이 실제로 보일 때만 돈다**(`anyAgentRunning`): 접힘·chrome_minimal이면 사이드바가 없어
    돌지 않고, 검색 필터로 숨은 탭도 카드가 없다(재투영 낭비 회피, code-review high #1 + max). 대표 상태는
    **blocked > running > idle > unknown** 순으로 사용자 조치가 필요한 Term을 먼저 드러낸다. running 판정은 **탭 안 어느
    pane/Term이든**(`tabHasRunningAgent`) — 활성 Term만 보던 옛 게이트에서 확장(백그라운드 Term도 카드 파형 트리거). **브랜드색**
    (색칠 루프가 아이콘과 같은 패턴으로 스피너 codepoint[블록 ▁~█]를 칠하되 **상태줄 row[카드 마지막 줄]로 좁혀** 이름/경로의 블록
    글자가 안 오염, #2 / 색·kind는 `tabAgentKind`로 running Term 우선)이라 "진행중"에 색 표현이 있다. **상단 탭 바**는 파형 대신
    **1칸 정적 플래그 ●**(`flagPrefixedLabel` + `recolorAgentFlagCells`, tmux 창-플래그 관례)를 pane 라벨·running Term 탭 앞에 붙인다 —
    등폭 탭이라 폭이 귀해 파형(5칸)이면 이름이 잘리기 때문(code-review max #1). 정적이라 위상 게이트와 무관하고 상태 변화 시에만
    갱신된다(`agentDisplayVisible`가 카드 or 활성 탭 탭바를 dirty 게이트로 커버). **아이콘은 항상 솔리드 브랜드색**(옛 `dimRgb` 밝기 펄스는
    작은 아이콘에서 작업 중인지 안 보인다는 **사용자 피드백**으로 폐기 — 애니메이션은 상태줄 스피너가 담당, 아이콘은 종류·presence를
    솔리드로 또렷이). 근거: 종류 글리프는 폰트 미보유 시 fallback에서 깨지므로 보유/합성 글리프로 한정.
- **탭마다 split(panel)** — 각 탭은 surface 1개가 아니라 가로/세로로 나눌 수 있는 surface 트리.
- **드래그 재배치** — panel을 끌어 split을 재배열, 탭을 끌어 순서 변경.

## 핵심 결정: 레이아웃 모델과 terminal runtime 수명을 분리한다

탭/split UI **모델**은 Maru 하나만 소유한다. terminal Term의 실행 runtime이 같은 앱 프로세스에 있는지, 향후
`maru-sessiond`에 있는지는 별도 backend 경계로 분리한다.

```
Maru 레이아웃 모델 (Window → Workspace → SplitTree → Pane → Term)
                              │ runtime_handle
                   ┌──────────┴──────────┐
             in-process backend     maru-sessiond backend
             현재 구현·동작          영속 세션, 구현 전
```

- **현재는 in-process** — `createTerm`이 셸 PTY와 `LiveSurface`를 앱 전역 `AppRuntime` registry에 만든다.
- **장기 기본은 Maru session host** — GUI가 종료되어도 `TerminalCore + LivePtySession`을 유지하고, 새 GUI surface가
  동일 runtime에 attach한다. 단일 출처는 [영속 터미널 세션 호스트](persistent-session-host.md)다.
- **tmux-CC layout driver는 기본 계획에서 제외** — tmux window/pane과 Maru의 Workspace/Pane/Term 탭 계층이 일치하지
  않고 두 layout 권위를 동기화해야 하기 때문이다. 외부 tmux 세션 import 수요가 생길 때만 별도 adapter로 재검토한다.
- **연결 ID도 Maru 소유** — Term은 tmux session/window/pane ID가 아니라 Maru `runtime_handle`을 가리킨다. tmux ID
  mirror나 변환표는 canonical layout에 들어가지 않는다.
- **불변식**: workspace/split 재배치는 runtime을 재시작하지 않는다. layout 모델은 live PTY 포인터를 직접 소유하지 않고
  opaque runtime binding을 사용한다. renderer는 runtime 위치와 무관하게 surface snapshot을 소비한다.
- **v1 owner는 하나**: runtime 하나는 manifest의 canonical Term 한 곳에만 배치한다. 추가 GUI/CLI/SSH 화면은 layout 복제가
  아니라 observer subscription이다. collaborative writer와 persisted Mirror Term은 실제 수요 전까지 구현하지 않는다.

## 렌더링 결정: Maru가 직접 그린다(native 최소)

탭 사이드바와 split 레이아웃을 **Maru의 Metal 프레임에 직접 그린다** — AppKit 위젯(NSView 탭/SwiftUI
SplitView)을 쓰지 않는다. 이유:

- 터미널이 이미 Metal로 그려지니, 사이드바·divider도 같은 렌더 경로에 두면 룩을 완전히 통제하고(cmux/Warp식
  커스텀) 우리 메타데이터(cwd/✓✗/이벤트)를 바로 표시할 수 있다.
- [macOS 앱 호스트 경계](macos-app-host-boundary.md)의 native 최소 원칙과 일치 — 레이아웃·상태·히트 테스트는
  Zig가 소유하고, Swift는 backing px 클릭/드래그 좌표만 ABI로 넘긴다(스크롤·마우스 선택과 같은 규율).
- 비-macOS(Linux CI)에서도 레이아웃 로직을 헤드리스 단위로 검증할 수 있다.

레이아웃: 창 drawable을 먼저 `[사이드바 strip | workspace terminal domain | 선택적 파일 도크]`로 나누고,
`termRect()`는 sidebar·titlebar strip·파일 도크를 제외한 **padding 전 raw terminal domain**을 돌려준다. SplitTree는 이
raw rect를 leaf rect로 나눈다. 각 leaf에서는 L4 `AppSession.paneGeometry(leaf_rect)`가 `PaneGeometry { bar, body, grid }`를
한 번 계산한다. `body`는 상단 pane tab bar만 제거한 실제 본문 외곽이고, `grid`는 body에 `window.padding-x/y`(기본 좌우
8pt·상하 4pt)를 saturating inset하되 과대 값에서도 origin/end를 body 내부에 clamp한 셀 그리드 rect다. `bar`가 없으면 body=leaf다. PTY grid·셀 렌더 origin·마우스 cell
hit-test·IME 후보창은 `.grid`를 공유하고, 실제 입력 영역을 표시하는 focus border는 `.body`를 공유해 padding을 border
안쪽에 남긴다. WKWebView도 pane tab bar·browser address band·split seam 노출을 `web_panel_layout.contentRect`로 먼저
제거한 본문에 같은 `layout_math.insetRect(window_padding_px)`를 적용한다. 파일 도크의 WKWebView도 그룹 tab/header를
제거한 content rect에 같은 inset을 적용한다(**FP16 목표**: 파일이 워크스페이스 Term이 되면 도크는 탐색기 전용 GPU chrome이라
WKWebView를 하나도 소유하지 않고, 파일 본문은 위의 web Term 경로 하나로 합쳐진다 — [file-panel.md](file-panel.md) §7).
따라서 terminal grid와 웹 콘텐츠는 같은 수준의 여백을 갖되 tab/header와
split·dock divider 자체는 padding 때문에 안쪽으로 밀리지 않는다. `paneBarRect`/`paneTermRect`는 `PaneGeometry`
accessor일 뿐 bar/padding 산술을 복제하지 않는다. focus border의 상태·z-order·테마와 비-key/OOM fail-close 계약은
[file-panel-dock-ui.md §3.4](file-panel.md#34-terminal파일-도크-입력-포커스-표시왕복)를 단일 출처로 둔다.

**표시 grid는 레이아웃이 소유한다**: 위 `.grid`에서 나온 크기는 그 Term의 표시 grid에 **항상** 적용된다
(`AppSession.resizeTermForLayout`이 단일 출처). 이건 편의가 아니라 렌더가 서는 근거다 — 렌더러는 셀을
`pane origin + col×cell_w`로만 놓고 **터미널 셀 패스에 pane 클리핑(scissor)이 없다**. 즉 화면이 자기 pane 안에
머무는 이유는 오직 "grid가 pane rect에서 나왔다"이고, 이 불변식이 깨진 Term은 divider를 넘어 옆 pane 본문 위에
글자를 그린다. 따라서 **runtime이 resize를 받지 못하는 것은 표시 grid를 낡은 채 둘 근거가 되지 않는다**:
`SurfaceRuntime.resize`는 dead adapter로의 라우팅을 계약대로 거부하지만
([surface-runtime-api.md](surface-runtime-api.md)) — link 없음(`UnknownSurface`)·자식 종료(`ProcessExited`),
그리고 §7 종료 placeholder(묘비) — 그런 Term의 표시 grid는 레이아웃 레이어가 코어에 직접 적용한다(PTY winsize·trace
없이 reflow만). runtime에 못 전달한 사실은 삼키지 않고 `resize_delivery_failures` 카운터와 MARU_DEBUG `resize`
로그로 남긴다(자식 프로세스만 옛 winsize를 믿는 상태의 원인). 레이아웃 적용 자체는 개별 Term의 전달 실패로
중단되지 않는다 — 중단하면 `recomputeActivePaneRect`·`metal_dirty`를 스킵한 half-state로 창 크기 조정이 깨진다.
셀 이하(음수 자간 마지막 칸)의 divider bleed는 별개의 알려진 한계이고 per-pane scissor 도입 시 해소된다
([font-strategy.md](font-strategy.md) 화면 quad 절).

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
7. **영속 terminal runtime backend(별도, 큼)**: `TermRuntimeBackend` seam → `maru-sessiond` → GUI-process-crash-consistent manifest →
   개별 `maru attach` 순서. 기존 단일 `maru.workspace.v1`의 Workspace/Term에 Maru binding scalar를 붙이고 cross-window
   이동은 binding을 보존한다. 제품 완료 범위 P1~P5와 무인 gate는 [영속 터미널 세션 호스트](persistent-session-host.md)
   §13~14를 따른다. tmux-CC 양방향 layout 매핑과 P6 전체 workspace TUI는 이 단계의 완료 조건이 아니다.

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
- **휠 스크롤 라우팅(커서 아래 surface 소유)**: 마우스 휠/트랙패드 세로 스크롤은 **포인터 아래 surface가 통째로 처리**한다 —
  포커스(활성 panel)와 무관하다(**베이스**: Ghostty/Warp — 휠은 커서 아래 surface 소유). split에서 비활성 panel 위를
  굴리면 **그 panel의 스크롤백**이 움직이고 **포커스·텍스트 입력은 안 바뀐다**(클릭만 포커스를 옮긴다 ↔ 위 ①). 핵심:
  **mouse tracking(vim/tmux 등 앱이 휠을 받는지) 판정도 커서 아래 surface 기준**이라, 포커스 panel이 트래킹 앱이어도 옆
  비트래킹 셸 panel 위 휠은 그 셸 스크롤백을 움직이고, 반대로 커서 아래 panel이 트래킹이면 그 panel로 휠 리포트(SGR
  64/65)를 보낸다 — 리포트 좌표(`pxToCellIn`)도 그 panel의 본문 rect 기준이라 pane↔좌표가 정합한다. 라우팅 단일 출처는
  `paneTargetAt`(점을 담는 leaf의 활성 Term surface + 본문 rect — 링크 클릭/hover와 공유하는 '포인터 아래 pane이 소유' 라우팅 단일 출처, [링크 감지](link-detection.md) §어느 pane에서 찾는가)이되 **커서가 사이드바 위면 그 전에 사이드바 세로 스크롤
  (③c)이 휠을 소비**하고, 사이드바도 터미널 leaf도 아닌 영역(밖)이면 활성 surface로 폴백한다. alt 화면 +
  alternate scroll(DECSET 1007)이면 스크롤백 대신 그 surface로 화살표 키를 보낸다(less/vim). 가로(트랙패드 2-finger)
  델타는 직교 축이라 커서 아래 pane **탭 바**를 가로 스크롤한다(`scrollTabBarAt`, 탭 넘칠 때만).
- **Term(가로 탭) 키(PR-B, pane 내 가로 탭 모델)**: 한 pane은 여러 Term(터미널)을 가로 탭으로 든다. `Cmd+T`=활성 pane에
  **새 Term**. `]`/`[` 계열은 modifier로 **세 단계**로 갈린다(modifier 정확 비교): **`Cmd+]`/`Cmd+[`=split(pane)
  순환**(활성 워크스페이스 안의 분할 영역을 panes 순서로 wrap, 분할 없으면 무동작), **`Cmd+Opt+]`/`Cmd+Opt+[`=Term
  순환**(pane 안 가로 탭 wrap), **`Cmd+Shift+]`/`Cmd+Shift+[`=워크스페이스 전환**. 워크스페이스는 `Cmd+Shift+T`=
  **새 워크스페이스**로 만든다. 추가로 **`Cmd+1`~`Cmd+9`=N번째 워크스페이스로 직접 전환**(`select_tab(N-1)`, 범위
  밖이면 no-op — Safari/Terminal.app/iTerm2식). **베이스**: pane 내 가로 탭(새 탭·탭 순환)이라는 탭 모델 관례; `⌘[]`를 split
  순환에 두고 Term을 `⌘⌥[]`로 옮긴 것은 사용자 요청 배치다(split을 가장 자주 오가므로 무수식 `⌘[]`에 둠). 워크스페이스 생성은
  **사이드바 하단 "+" 버튼**(③b)으로도 한다 — 탭 목록 아래 슬롯의 "+"를 클릭하면 새 워크스페이스(`newTab`).
- **닫기(PR5a + PR-B cascade)**: `Cmd+W`는 **cmux식 계층 cascade** — 활성 pane에 Term이 여럿이면 **활성 Term**을
  닫고, Term이 1개면 **pane**을(split이면 형제로 collapse, 형제가 빈자리 차지) 닫고, pane이 1개면 **워크스페이스**를
  (마지막이면 창) 닫는다. 즉 Cmd+W를 반복하면 Term → pane → 워크스페이스 순으로 하나씩 닫힌다.
- **exit 자동 collapse(PR5b)**: 셸이 `exit`하면 그 Term도 같은 cascade로 자동 정리된다(Cmd+W 닫기와 동일 경로의
  exit 버전) — 활성/배경 탭·pane 어디서 죽어도 tick의 drain이 종료를 관측한 직후 reap한다. 단 **모든 Term이
  죽으면** 마지막은 reap하지 않고 세션 종료(창 닫힘) latch가 맡는다(빈 세션을 만들지 않음). **이 reap은 검증된
  자식 종료(`.exited`)에만 일어난다** — `.read_error`(자식 생존 미검증 PTY I/O 오류)는 이 cascade를 타지 않아 산 셸이
  달린 탭이 유지된다(`terminationClosesWorkspace` 게이트; 단일 출처: `pty-operating-model.md` "read_error vs 검증된 exit").
- **per-pane 탭 바 렌더(PR-C)**: 각 pane(leaf rect) 상단에 가로 탭 바 strip(높이 = cell 1칸)을 예약하고 그
  아래를 `PaneGeometry.body`로 쓰고 window padding을 inset한 `.grid`를 셀 그리드 영역으로 쓴다(`paneGeometry`가
  단일 출처이고 `paneBarRect`/`paneTermRect`는 accessor — 좌표·resize·split·렌더가 공유). 바는
  터미널 셀 스트림에 origin 박힌 셀로 그려진다(`metal_frame.replace`의 `pane_chrome_cells`, 렌더러·ABI 무변경).
  **PR-C1**: 바 배경만(활성 강조색·비활성 chrome 색). **PR-C2**: Term 제목 glyph를 탭으로. **PR-D**: 호버 ✕·활성
  하이라이트·클릭. **PR-E**: 탭 드래그(pane 내/간). **PR-F**: "+" 버튼.
  - **활성 탭 룩(rich, U-tab2 — 연결형 cutout)**: 활성 Term 탭은 **터미널 본문색(`theme.background`)** 으로 채워 strip
    (`sidebarBg`)에서 도려낸 듯 아래 본문과 이어져 보인다(VSCode/Ghostty식 깊이). **포커스 pane 구분은 배경이 아니라 하단
    언더바 색** — 포커스=테마 accent(프리셋별 시그니처, `maru`=앰버 #DDA15E), 비포커스=muted(모든 활성 탭 배경은 본문색 통일). 언더바는 탭바 하단 하이라인과
    분리한 전용 토큰 `tab_underbar_px`(rich 3px)로 더 굵게 그려 active/focus 신호를 또렷하게 한다(`appendActiveTabHighlight`
    단일 출처; cutout quad가 활성 탭 구간 하이라인을 덮어 연결이 끊기지 않음). **탭 제목엔 번호 prefix(`N `)를 붙이지 않는다**
    (브라우저/VSCode/Warp식 — Term 번호는 단축키 미매핑이라 군더더기였다; 사이드바 워크스페이스 라벨이 이미 번호를 안 붙이던
    것과 일관). tui 룩은 기존 셀 밴드(`tabbarHighlightCell`). 단일 출처: [chrome-strategy.md](chrome-strategy.md) U-tab2.
  - **탭 스타일 축(`chrome.tab-style`, TS1·TS2)**: 위 connected(본문색 cutout + 앰버 언더바)를 강한 기본으로 두고, `chrome.tab-style
    = connected|underline|pill` 직교 축으로 활성 탭 룩을 고른다 — `underline`=언더바만(배경 박스 없음), `pill`=strip보다 밝은
    lifted 회색으로 채운 둥근 캡슐 + 옅은 밝은 테두리(실제 Warp 벤치마킹 — 밝은 fill로 띄움, 포커스=fill 밝기). 스타일은
    `appendActiveTabHighlight`의 **세그먼트 안 fill만** 바꾸고 탭
    세그먼트 기하(`tabbar.segOf`)는 불변이라 hit-test/드래그/✕/‹›는 그대로다. `chrome.theme`(tui\|rich)·`theme.preset`(색)과
    직교. 단일 출처: [chrome-strategy.md §7](chrome-strategy.md).
- **탭 바 "+" 버튼(PR-F)**: 바 우측에 "+"를 그려 클릭하면 그 pane에 새 Term을 띄운다(⌘T의 마우스 버전). 바를
  `paneTabAreaCols(cols)`(넓으면 `cols - 3`, 좁으면 전체)로 나눠 **탭 영역**과 우측 **"+" 영역**을 분리한다 — 탭
  렌더·hit-test(tabbar `Metrics`의 `tabIndex`/`segOf`로 탭 인덱스, `inCloseZone`으로 ✕)·"+"(`inPlusZone`)가 같은 분할을 공유해 "보이는 = 클릭되는"을
  지킨다. cmux 비교상 "+"는 새 **탭(Term)** 추가이며, split은 ⌘D/⌘⇧D·divider(PR6)로 둔다. **상단탭 Warp 폴리시(인라인 "+")**:
  "+"를 바 far-right가 아니라 **마지막 탭 바로 뒤**에 둔다(Warp식 — 탭과 "+"가 좌측 묶음, 오른쪽은 빈 바). `tabbar.Metrics.plusZoneStart`
  가 `has_scroll`이면 옛대로 far-right(‹·gap·› 뒤), 아니면 `tabsEndCol`(=`min(tab_count*tab_w, tab_cols)`)을 돌려주고 렌더
  (`coretext` `plus_start`)가 같은 값을 써 단일 정합("보이는 + = 클릭되는 +"). **`inPlusZone`은 cols까지가 아니라 버튼 폭(2칸)으로
  한정** — "+" 오른쪽 빈 바 영역을 클릭해도 새 Term이 안 생긴다(빈 영역 무동작, 사용자 결정 ①; 그 영역은 마지막 탭으로 clamp되는
  기존 동작). 탭이 넘쳐 `has_scroll`이면 "+"는 ‹› 뒤 far-right로 폴백.
- **divider 렌더·드래그 리사이즈(PR6)**: 두 panel 사이 경계에 divider 선을 그리고, 끌어서 비율을 조절한다. 선은
  layout을 안 바꾸고(틈 없이 abut) **seam 중심 overlay 셀**로 터미널 위·커서 아래에 그린다(`metal_frame.replace`의
  `pane_overlay_cells`, cursor suffix 앞 insert). hit-test는 `layoutDividers`가 주는 seg(split 노드+경계 pos+부모
  bounds)로 seam 밴드(±cell 절반+여유)를 잡고, 드래그가 `ratio = (mouse - bounds.origin)/bounds.size`(`clampRatio`)
  로 `split.ratio`를 바꿔 live 재배치한다. **탭 바가 seam에 붙어 있어** divider는 탭 바(①) 다음·pane 선택(②) 앞
  순서로 잡아 탭 바 클릭을 안 가로챈다. 초기 비율은 0.5(균등).
- **사이드바 폭 조절(③a)**: 사이드바 우측 경계를 드래그해 폭을 바꾼다(폭은 pt로 저장 → DPI 생존). 경계 밴드는
  터미널 쪽만이라 사이드바 슬롯/✕와 안 겹친다. **사이드바 "+" 버튼(③b)**: 탭 목록 아래 슬롯의 "+"로 새 워크스페이스.
- **사이드바 세로 스크롤(③c)**: 워크스페이스 카드가 **헤더 아래 뷰포트(backing 높이 − 헤더)** 를 넘으면 휠/트랙패드로
  **픽셀 단위 스무스 스크롤**한다. 스크롤량은 `sidebar_scroll_offset_px`(backing px) 단일 출처이고 `[0, sidebarMaxScroll]`로
  clamp한다(`sidebarMaxScrollPx`=표시 카드 전체 높이−뷰포트; 순수 함수라 헤드리스 단위). 카드 추가/삭제·검색 필터·창
  resize로 콘텐츠/뷰포트가 바뀌면 `clampSidebarScroll`이 `rebuildSidebar`에서 stale 오프셋을 자동 정정한다(`tab_scroll_cols`
  재clamp 선례). **베이스/결정**: ① **휠 라우팅** — 커서가 사이드바 위면 휠을 사이드바 스크롤이 **통째로 소비**한다(터미널/
  스크롤백으로 안 흘림). 이는 "휠은 커서 아래 surface 소유"(Ghostty/Warp) 원칙을 사이드바로 확장한 것으로, 카드가 안 넘쳐도
  소비해 뒤 터미널이 굴러가는 위화감을 막는다(`scrollWheel`의 `inSidebar` 분기, 가로 탭바 스크롤보다 먼저). ② **헤더 고정·
  클리핑** — 헤더(검색바·아이콘)는 스크롤과 무관하게 고정이고(헤더 glyph는 터미널 셀 패스라 사이드바 셀 시프트와 분리),
  헤더 위로 밀려 올라간 카드는 **렌더러가 사이드바 셀 draw에 `[header_h, drawable_h]` scissor**를 걸어 자른다(offset>0일 때만;
  `MetalFrame.sidebar_scroll_offset_px`). GPU quad 밴드·tint·accent 막대는 host lowering(`sidebarScrollClipQuad`)이 **같은
  오프셋으로 빼고 헤더 경계에서 클립**한다(상단 라운드는 죽임) — 셀(.m)과 quad(Zig)가 같은 `sidebar_scroll_offset_px`를 써
  단일 출처. ③ **스크롤바** — 우측에 pane 스크롤바와 **동형 pill thumb**(muted 색·`computeScrollbarAlpha` fade·layer 3 over,
  단일 트랙 `sidebar_scrollbar_idle_ticks`)를 카드가 넘칠 때만 그린다. hit-test(`slotAt`/`dragTargetSlot`)도 같은 오프셋을
  더해 "보이는 카드 = 클릭되는 카드"를 지킨다(헤더 영역 y는 스크롤 무관하게 헤더로 판정).
- **split 재배치 드래그(④)**: Term 탭을 다른 pane **본문**의 상/하/좌/우 절반(`paneDropZone` — X자 4등분)에 드롭하면
  그 방향으로 새 split이 생긴다(`moveTermToNewSplit`: Term을 새 pane에 담아 `replaceLeaf(target → split{...})`, 소스가
  비면 collapse). 탭 바에 드롭하면 그 pane으로 Term 이동(PR-E2), 본문에 드롭하면 split 생성으로 갈린다. 드래그
  중에는 드롭 타겟 zone을 **반투명 하이라이트**(④b — `premultipliedRgba`로 미리 곱해 터미널이 비침)로 미리 보이고,
  끌리는 탭은 **floating 탭 미리보기**(박스+제목)가 커서를 따라간다(`buildFloatingTabFrame`, 맨 위 frame).
  **도메인 경계**: `tab_drag_*`는 `termRect()` 안의 terminal pane tree만 target으로 탐색한다. 오른쪽/하단 파일 도크와
  terminal↔dock outer divider는 drop target이 아니며, 그 위에서는 하이라이트를 지우고 mouse-up을 no-op으로 끝낸다.
  반대로 파일 탭도 terminal pane으로 들어오지 않는다. 파일 도크 내부 재정렬·그룹 이동·split 계약은
  [파일 패널 §3.3](file-panel.md#33-파일-탭-드래그도크-내부-분할)을 단일 출처로 둔다.
  단 현행 terminal 탭은 source pane 안에서 pointer x를 따라 live reorder하므로, 도크에 놓아도 cross-domain 이동은 0이지만
  도크로 나가기 전에 이미 보인 source 내부 순서는 유지한다. 즉 cross-domain drop의 no-op은 원래 순서로 rollback한다는 뜻이 아니다.
  **FP16 목표**: 파일이 워크스페이스 Term이 되면 이 "도메인 경계" 자체가 소멸한다 — 파일 탭 드래그가 terminal 탭 드래그에
  흡수돼 금지할 반대 도메인이 없어지고, 탐색기 도크는 콘텐츠 탭이 없어 drop target 후보에서 자연히 빠진다. terminal↔dock
  outer divider가 크기 조절만 소유한다는 규칙은 그대로다. 단일 출처는 [파일 패널 §3.3](file-panel.md#33-파일-탭-드래그도크-내부-분할).
  **호버 커서(②)**: divider=↔/↕ resize, 사이드바 경계=↔, pane grip=✋ openHand(드래그 손잡이), 탭/"+"=손가락(pointingHand), 터미널=I-beam.

### Pane을 워크스페이스로 분리·합치기 (드래그, 구현됨)

Term(가로 탭)뿐 아니라 **Pane 통째**를 사이드바(워크스페이스 영역)로 끌어 **새 워크스페이스로 분리**하거나
**기존 워크스페이스에 합칠** 수 있다. ④(split 재배치)가 pane **본문** 안에서의 이동이라면, 이건 pane을 사이드바로
넘기는 **워크스페이스 간** 이동이다. 모델상 워크스페이스 = SplitTree 루트, Pane = leaf라 "leaf를 한 트리에서 떼
다른 트리에 심기"라는 트리 연산으로 깔끔히 떨어진다 — Term을 옮기지 않고 `*Pane` 포인터를 통째로 재부모화한다.

- **드래그 손잡이(베이스/결정)**: pane 탭바 **좌측 grip 핸들**(**항상 보이는** ⠿ 글리프, `pane_grip_cols`=3칸 예약 — 좌패딩 +
  글리프 중앙(`cols/2`) + 우패딩으로 글리프가 좌단·divider에 안 붙게)을 잡으면 Pane 통째 드래그, **Term 탭**을 잡으면 기존대로
  Term 1개 드래그(④)로 갈린다. ⠿를 **항상 표시**하는 이유(사용자 피드백): pane→워크스페이스 분리 드래그는 **Warp에 없는 maru
  기능**이라 손잡이를 늘 보여야 발견성이 유지된다(한때 Warp 벤치마킹으로 hover-only로 숨겼으나 — Warp는 grip 없는 모델이라
  부적합 — 되돌렸다). **호버 시 커서는 openHand(`CursorKind.grab`)** 로 바뀐다. 바 세로 패딩(`tab_bar_pad_y_px`)은 rich에서
  8px이지만, **rich에서 바 높이는 `cell + 2*pad`가 아니다** — 도크 뷰 스위처와 경계선을 맞추려고 폰트 독립 token
  (`space.bar_height_pt`, rich 40pt)이 높이를 정하고 pad는 텍스트 여백 의미만 남기 때문이다(단일 출처 `chromeBarHeightPx`,
  [file-explorer.md](file-explorer.md) §3.5). token이 0인 tui만 셀 파생(`cell + 2*pad`)으로 떨어진다. 그래서 바 안 텍스트의
  세로 오프셋도 pad가 아니라 실제 바 높이에서 파생한다(`chromeBarTextOffsetY`). **라벨 세그먼트만으로는 부족**하다(custom_name 없는 pane은 라벨 폭이
  0이라 잡을 자리가 없다 — `paneLabelCols`) → grip을 **이름 유무와 무관하게 항상 예약**해 모든 pane이 끌리게 한다(사용자
  결정). custom_name이 있으면 grip 뒤에 이름이 붙는다(`paneBar`가 `grip_cols`+`label_cols`로 탭 영역을 우측 offset). 같은
  탭바에서 "잡는 자리"로만 단위를 구분하므로 새 chrome가 필요 없다(`tab_drag_*`와 분리된 `pane_drag_*` arm; 좁은 바는 탭
  영역 최소 `pane_min_tab_cols` 보장 위해 grip 생략). **호버 시 커서는 openHand(`CursorKind.grab`)** 로 바뀌어 드래그
  가능을 알린다(`updateHoveredTab`이 좌측 grip+라벨 세그먼트를 `BarHover.grip`으로 구분 → `hoverCursor` → Swift
  `NSCursor.openHand`; 탭/‹›/+ 영역은 기존대로 pointingHand). **사이드바 카드 드래그(워크스페이스 순서 재정렬,
  `sidebar_drag_*`)와는 시작 위치로 구분**된다 — pane 드래그는 터미널 영역(pane 탭바 grip)에서 시작, 워크스페이스
  재정렬은 사이드바 카드에서 시작.
- **드롭 위치별 동작(단일 분기)**: 사이드바 드롭 좌표를 `sidebarSlotAt`로 해석해 ① **기존 워크스페이스 카드 위** →
  그 워크스페이스에 **합치기**, ② **빈 사이드바 영역**(카드 목록 아래/"+" 부근) → **새 단독 워크스페이스 생성**.
  사이드바 밖(원래 pane 본문·탭바)이면 ④ 경로(새 split/Term 이동) 그대로다.
- **합치기 기본 배치(베이스/결정)**: 카드는 사이드바 슬롯이라 좌/우/상/하 방향 정보가 없다. 그래서 타겟 워크스페이스의
  **활성 pane을 좌우(`split_horizontal`)로 나눠 들어온 Pane을 우측·활성**으로 둔다(⌘D 관례와 동일). 트리 수술은 ④의
  `moveTermToNewSplit`과 **같은 모양**(`replaceLeaf(dst_active → split{a:기존, b:들어온 Pane})`)이되 새 Pane을 만들지
  않고 떼어온 Pane을 재사용한다. 사용자는 들어간 뒤 ④ 드래그로 방향을 재배치한다.
- **분리(새 워크스페이스)**: 빈 `Tab`을 직접 만들고(셸 PTY를 새로 띄우는 `newTab`/`createTab`은 안 쓴다 — 떼어온 Pane을
  재부모화하므로 새 PTY가 불필요·낭비) 그 단일 leaf를 떼어온 Pane으로 채운다(`tree = leaf(pane)`). 새 워크스페이스는
  **탭 목록 끝에 붙고 활성**이 된다 — "빈 사이드바 영역=카드 목록 아래=끝"이라 드롭 위치와 일치한다(슬롯 중간 삽입·pinned
  clamp는 두지 않는다; 순서 조정은 기존 사이드바 카드 드래그가 맡는다).
- **소스 정리**: 소스에 형제 Pane이 있으면 `removeLeaf`로 그 leaf를 떼고 형제로 collapse한다(④와 동일 경로).
  소스 Pane이 워크스페이스의 **유일한 Pane**일 때 다른 워크스페이스 카드에 합치면, Pane을 대상 트리에 그대로
  재부모화하고 비게 된 소스 워크스페이스를 제거한다. surface/PTY는 파괴하거나 재시작하지 않는다. 반면 유일한 Pane을
  사이드바 빈 영역에 떨어뜨리는 **분리**는 같은 단독 워크스페이스를 다시 만드는 무의미한 동작이므로 계속 무시한다.
- **미리보기·하이라이트·resize 재사용**: 드래그 중 floating 미리보기는 `buildFloatingTabFrame`을 pane 라벨
  (custom_name orelse 활성 Term 라벨)로 재사용해 커서를 따라간다. **드롭 타겟 하이라이트**는 사이드바 밴드 경로
  (`sidebar.view`)에 `drop_slot`을 더해 `.drop_zone` 색 밴드로 그린다 — 합칠 **카드 슬롯**(displaySlotOf) 또는 빈
  영역이면 **카드 목록 아래 행**(표시 카드 수)에 활성/호버 밴드와 같은 lower 경로로 칠한다(`pane_drop_slot`을 drag(2)가
  paneDropHighlightSlot로 갱신, 슬롯 전환 시에만 rebuildSidebar). 분리·합치기 후 **양쪽** 워크스페이스의 pane을
  resize한다(소스는 collapse로 넓어지고, 타겟/새 트리는 새 레이아웃으로).
- **액션·단계 위치**: ④/PR-E(탭·split 재배치)의 워크스페이스-간 확장이다. 드래그 외에 **분리·합치기 둘 다 액션으로
  노출**한다 — **분리(promote)** 는 `move_pane_to_new_workspace`(팔릿 "Move Pane to New Workspace" →
  `promotePaneToNewWorkspace`), **합치기(merge)** 는 `move_pane_to_workspace:N`(0-based; 팔릿 "Move Pane to Workspace
  1..9" → `mergePaneIntoWorkspace(activePane, N)`)로 노출한다. 드래그는 떨어뜨린 카드로 타겟을 정하지만 키는 **번호로
  타겟을 명시**한다(`select_tab:N`·tmux `join-pane -t N`과 같은 선례 — 단일 표준 키가 없는 동작을 번호 타겟으로 단일화).
  자기/범위 밖이면 두 액션 모두 no-op이다. 단독 pane은 `move_pane_to_new_workspace`만 no-op이고,
  `move_pane_to_workspace:N`은 대상에 합친 뒤 빈 소스 워크스페이스를 제거한다. 기본 단축키는 macOS 단일 관례가 없어
  rename·split과 같은 규칙으로
  **bindable 액션만 정의하고 기본 키는 두지 않는다**(발견성은 커맨드 팔릿·드래그; [필수 프로젝트 규칙](project-rules.md)의
  베이스 명시 규칙). 검증은 트리 detach/insert·no-op 가드·드롭 타겟 하이라이트 슬롯·grip 드래그 end-to-end·두 액션
  dispatch를 헤드리스 단위로, grip 글리프 렌더는 제품 스크린샷으로 고정한다.

### Cross-window detach/reattach (선행 foundation)

같은 window 안의 Term/Pane/Workspace 이동은 위 절과 ④가 이미 다룬다. 브라우저·마크다운 웹 패널이 들어오면 같은 surface를 별도 모니터의 OS window로 빼고 다시 합치는 UX가 필요하므로, cross-window 이동은 [윈도우와 Surface 이동성](window-surface-mobility.md)을 단일 출처로 둔다.

- **지원 단위**: surface tab(terminal/web 1개), Pane grip, Workspace card, Window 전체 merge.
- **드래그 UX**: surface tab·Pane grip·Workspace card를 다른 Maru window의 pane/sidebar/drop-zone으로 드롭하면 attach/merge하고, 창 밖 빈 공간에 드롭하면 새 OS window를 만든다.
- **Window 전체 merge**: OS 타이틀바 드래그가 아니라 command/menu/palette action(`merge_window_into_active_window`, `merge_all_windows`)으로 먼저 제공한다.
- **브라우저 정책**: Maru-owned browser surface는 기본적으로 다시 합칠 수 있다. 합쳐지지 않는 단독 브라우저는 외부 Safari/Chrome으로 여는 별도 앱 경로다.
- **구현 순서**: full drag UX보다 `WindowGraph` 순수 move/merge TDD, AppRuntime live surface registry, command 기반 이동을 먼저 구현한다.

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
- **긴 이름 편집(scroll-to-caret)**: 편집 텍스트는 `이름 + caret`으로 caret이 늘 문자열 끝에 온다(`handleRenameKey`는
  끝에서 append/backspace만, 중간 커서 이동 없음). 평소 라벨은 넘치면 **선두 고정 + 뒤를 "…"로**(이름 앞부분 표시)이지만,
  편집 중 라벨/탭 세그먼트가 이름보다 좁으면 **말미 고정(tail 앵커)** 으로 전환해 선두를 "…"로 자르고 **끝(caret)** 을
  보여준다 — 단일 줄 입력창이 caret를 따라 가로 스크롤하는 것과 같다. 이렇게 안 하면 세그먼트를 채우는 순간 caret과 방금
  친 글자가 오른쪽으로 잘려 무엇을 입력 중인지 안 보였다(사용자 제보). 잘림 규칙 단일 출처는 `coretext_frame_builder.appendEllipsizedTitle`
  의 `text_layout.Anchor`(head=읽기용·tail=편집용)이고, platform이 rename 중인 대상에만 tail을 넘긴다: Term 탭(`buildPaneTabBarDrawList`의
  `editing_tab`)·pane 라벨(`buildPaneLabelDrawList`의 `anchor`)·워크스페이스 카드/그룹 헤더(`buildSidebarDrawList`의 `editing_row` — 그
  슬롯 **이름줄만**). 네 계층이 같은 함수·같은 규칙을 공유한다(사이드바 검색창은 헤더 전용 인라인 렌더라 이 패밀리 밖 — 별도).
- **트리거(세 가지 모두)**: ① **키보드 액션 + 커맨드 팔릿** — `rename_workspace`/`rename_pane`/`rename_term`(활성 대상
  기준). ② **더블클릭** — 사이드바 엔트리·Term 탭·pane 라벨 세그먼트. ③ **Zig 오버레이 우클릭 메뉴** — 네이티브 메뉴가
  아니라 Zig로 그린 컨텍스트 메뉴의 "Rename" 항목(chrome을 Zig로 그리는 전략과 일치). 키보드/팔릿은 활성 대상,
  더블클릭/우클릭은 클릭된 대상으로 해석한다.
- **우클릭 메뉴 — 워크스페이스 추가 항목**: 사이드바 워크스페이스를 우클릭하면 "Rename" 외에 **위치 고정(Pin/Unpin)**,
  **배경색 프리셋**("배경: …" 없음·앰버·파랑·초록·빨강·보라; 앰버=maru accent #DDA15E), **좌측 막대색 프리셋**("바: …"
  같은 6색)이 뜬다(pane/Term은 "Rename"만). **배경색과 막대색은 직교한 별도 설정**이다(사용자 요청: "왼쪽 바 색·배경색
  두 개 따로") — 색 팔레트만 공유하고 각각 `tab.background_color`/`tab.accent_color`에 담긴다. 메뉴 항목은 chrome 중립이라
  platform이 대상 타입에 맞게 동적 주입하고(`buildContextMenuItems`), accept는 selected 인덱스 구간으로 분기
  (`acceptContextMenu`; `ctx_menu_bg_first`/`ctx_menu_accent_first`). 위치 고정은 드래그 재정렬에서 그 탭을 안 움직이고
  (`moveTab` no-op) 사이드바 카드 이름줄 **우측 끝**에 📌(선두가 아니라 — 선두 칼럼은 위 동작/활성 마커 전용; 핀이 그
  표시를 가리지 않게). **그룹 만들기·풀기("새 그룹으로 묶기"/"그룹 풀기")도 여기 동적 주입되어 위치 파생 그룹 마커
  (`group_start`)를 세팅·제거한다(단축키 `Cmd+Opt+G`·팔레트 공유) — 단일 출처 [사이드바 그룹 전략](sidebar-groups.md).**
- **카드별 색 렌더(배경 tint·좌측 accent 막대)**: chrome draw op은 role 기반이라 임의 RGB를 못 실어, **둘 다 platform이
  명시-색 GpuQuad로 직접 그린다**(`rebuildSidebar`의 per-tab tint 루프·per-tab accent 루프 — 일관된 경로). 배경색은 카드에
  반투명 tint, 좌측 막대는 카드 좌단(폭=`tokens.space.accent_bar_width_px`, 카드 텍스트는 이 폭만큼 좌측 여백 예약)에
  불투명 막대다. **막대색 기본(`accent_color`=0)은 활성 카드=테마 accent(`.accent_bar` role — 프리셋별 시그니처, 기본 앰버)·비활성 카드=막대 없음**이고,
  프리셋으로 색을 지정하면 **활성·비활성 카드 모두** 그 색 막대를 표시한다("바: …"를 지정하면 비활성에서도 보인다).
  chrome `sidebar.view`는 카드 밴드(role 기반)만 내고 막대는 내지 않는다. 셋 다 workspace.v1에 영속
  (`pinned`/`background-color`/`accent-color` — docs/workspace-restore.md).
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
- 사이드바/split의 시각 렌더와 클릭/드래그 인터랙션은 macOS smoke(스크립트 가능 부분) + `macos-app`
  수동 검증. 클릭/드래그 좌표→탭/panel 히트 테스트는 Zig라 헤드리스 단위로 검증한다.
- terminal 탭 drag가 dock rect·outer divider에서 preview 없이 취소되고 파일 탭 drag가 `termRect()`에서 취소되는 양 방향
  도메인 격리를 헤드리스 hit-test와 macOS 수동 drag로 함께 검증한다.
