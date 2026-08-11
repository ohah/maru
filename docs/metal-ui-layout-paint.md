# Metal UI — Metal paint와 입력 정합 (§5)

화면 배치를 Zig가 정하고 `.m`은 명령만 실행한다는 ML-GEO 계약, 입력 dispatch와 interaction state, ML2b interaction 계약이다.

> **절 번호는 파일을 넘어 이어진다.** 본문이 `§5`처럼 절만 가리키면 아래에서 소유 파일을 찾는다 — §1~§4·§7 [metal-ui-layout.md](metal-ui-layout.md) · §2의 B1 [rich Button](metal-ui-layout-button.md) · §5 [Metal paint와 입력 정합](metal-ui-layout-paint.md) · §6 [Chrome Lab](metal-ui-layout-lab.md) · §8 [구현·검증 순서](plans/metal-ui-layout.md)

## 5. Metal paint와 입력 정합

`UiRectTree`의 모든 rect는 one-source다.

- `ui/paint`만 rect와 `ui/paint_style`의 semantic paint 결과에서 `ChromeDraw.fill/border/text/quad`를 만들고,
  Metal backend가 glyph/cell/GPU quad로 lower한다. component와 backend는 draw op를 따로 만들지
  않는다.
- `ui/interaction`은 동일 rect와 clip chain을 역순으로 검사한다. ML2b의 현재 action hit 영역은
  axis-aligned rect이며, ML3의 corner radius는 painter만 소비한다. rounded hit mask가 필요해지면
  paint의 radius를 복제하지 않고 shared typed shape를 `ui/tree`에서 추가하고, 그 mask의
  unit/clip/경계 fixture를 같은 slice에서 먼저 추가한다.
- scroll viewport와 virtualization은 list child를 그리기 전에 같은 rect tree로
  visible range를 정한다. fixed header와 scroll body가 서로 다른 y origin을
  재계산하면 안 된다. 그 규율을 한 컴포넌트로 묶은 계약은
  [ScrollArea](scroll-area.md)가 단일 출처다 — 스크롤 좌표·가상화 창·스크롤바·drag 수명·
  viewport clip이 거기 함께 산다.
- focus ring, hover, pressed, disabled는 layout 밖의 state지만 모두 같은 component
  rect에 paint한다. keyboard action과 pointer action은 stable item identity를
  공유한다.
- UI frame path는 I/O, JSON parse, worker wait, blocking lock을 하지 않는다. dirty
  props/style/size가 바뀔 때만 layout과 draw artifact를 다시 만든다.

### 화면 배치는 Zig가 정한다 — `.m`은 명령 실행 (ML-GEO)

**규칙**: 무엇을 어디에 얼마만큼 그릴지는 **Zig가 픽셀 rect로 정해 넘긴다**. Objective-C 렌더러는 그 rect를 Metal 명령으로 옮기고, 창 크기·사이드바 폭·띠 높이 같은 화면 구조에서 **배치를 스스로 유도하지 않는다**. GPU로 그린다는 것과 "무엇을 그릴지 GPU 쪽 코드가 정한다"는 다른 말이다 — 후자를 허용하면 같은 값이 두 언어에 손으로 미러되고, 컴파일러도 타입도 그 어긋남을 못 잡는다. 이 방향은 [macos-app-host-boundary.md](macos-app-host-boundary.md) "수치 계산·상태 결정은 네이티브에 두지 않는다"와 [layering-and-portability.md](layering-and-portability.md)의 L4 어댑터 규정을 화면 기하에 좁혀 적은 것이다.

**두 축으로 가른다**(단순 이분법으로는 회색지대가 갈리지 않는다 — 아래 예외 대부분이 셀 *바깥*을 그린다).

1. **방향**: `.m` → Zig(**측정**)는 허용한다. 폰트 metric에서 셀 크기·ascent/descent를 재 Zig로 돌려주는 경로가 그것이고, 그 값이 있어야 Zig가 rect를 만들 수 있다. 규칙이 적용되는 것은 Zig → `.m`(**배치 결정**) 방향뿐이다. 주의: `coretext_smoke.m`은 측정만 하는 파일이 아니다 — 같은 파일이 래스터 슬롯 **안쪽 배치**도 소유한다(아래 예외 표 마지막 행).
2. **값이냐 합성 규칙이냐**: `.m`이 받은 값을 그대로 소비하면 계약이다. `.m`이 **오프셋을 더하거나 중앙정렬·clamp·확장 규칙을 소유**하면 예외다 — 그 규칙을 Zig가 바꾸려면 두 언어를 함께 고쳐야 하기 때문이다.
3. **의존이냐**: 위 둘로 계약이어도, 그 rect가 **`.m`이 소유한 합성 규칙의 결과에 의존**하면 예외와 같은 유지보수 비용을 진다. 알림 배지가 그 예다 — quad 자체는 Zig가 rect·색·layer를 다 정하는 순수 계약인데, 그 좌표는 `.m`의 1.7× 확대·`0.30ch` nudge·벨 `+0.5cw` 이동을 **역산해 굳힌 상수**다(실제로 그 미러 중 하나는 이미 반 칸 드리프트했다). 새 표면은 **`.m`이 확대·이동하는 글리프에 앵커하지 않는다** — 앵커가 필요하면 그 글리프의 배치부터 Zig로 옮긴다.

**현재 예외.** 제품 `.m` 두 파일(`maru_metal_renderer.m`·`coretext_smoke.m`)을 훑어 확인한 목록이며 전수를 주장하지 않는다. 새로 늘리지 않고, 손댈 일이 생기면 그때 이관한다.

| 예외 | 위치 | `.m`이 소유한 규칙 | 상태 |
|---|---|---|---|
| 사이드바 배경 quad 높이 | `maru_metal_renderer.m` `sb = -1.0f` | 창 최하단까지(NDC 하드코딩) | GPU quad 경로가 생기기 전 자리. 이관 방법은 아래 |
| 사이드바 셀 배치 합성 | 같은 파일, 사이드바 셀 루프 | `py_top = origin_y + header − scroll`(**이 항 자체는 아래 선 기준 계약**), `cell_h = atlas_height_px ?: slot_h`(폴백=조건 분기), 좌측 여백 `cw*0.5` | **Zig에 같은 합성이 따로 있다**(`app_session`의 사이드바 quad 경로) — 가드 없는 미러 |
| tui 사이드바 활성 밴드 | `app_session.sidebarBandCell` + 같은 루프 | Zig가 rowTop·행 높이·칸수를 다 실어 보내고 `.m`은 헤더·스크롤 평행이동 + `atlas_height_px == 0 → slot_h` 폴백만 한다 | **선 위에 걸친 행** — 남은 예외분이 폴백 하나뿐이라 이관 비용이 가장 작다. rich는 `GpuQuad`라 무관 |
| 접힘 헤더 세로 중앙 | 같은 파일, 접힘 토글 분기 | `(titlebar_strip_px − ch) * 0.5` | 규칙이 명시한 "띠 높이에서 유도"의 실제 사례 |
| 아이콘 배율·세로 보정·벨 가로 재배치 | 같은 파일 | `1.7×`·`ch*0.30` nudge·에이전트 `1.1×`·벨 `width=1` + `cw*0.5` 이동 | **결합이 양방향**이다 — Zig의 hover quad·배지 좌표가 이 값들을 전제로 계산된다 |
| 그림자 blur 확장 | 같은 파일, shadow 분기 | Zig가 준 rect 밖으로 blur만큼 확장한 rect를 만든다 | `GpuShadow`는 `GpuQuad`와 **별도 채널**이다 |
| OSC 133 거터 좌단 clamp | 같은 파일, reserved 8 분기 | `max(px_left, 0)` — 주석이 "사이드바 폭은 `.m`이 모르니 0 하한만" | 폭을 넘기면 사라진다 |
| `reserved` 부분사각형 두께·여백 | 같은 파일 `maru_fill_cell_quad` 계열 | 커서 바/underline·SGR 장식선 두께를 셀 높이 15%·7.5%로(가로 변인 커서 바·hollow 우측은 `cw`의 15%), 거터 gap을 `cw*0.12`로 계산한다. 전부(divider 제외 — 그쪽 하한은 Zig가 갖는다) `max(2px)`·`max(1px)` 하한이 붙어 **작은 셀에선 비율이 아니라 하한이 값을 정한다** | **의도된 근사** — 폰트 metric(underline thickness)을 `.m`에 안 넘겨서다(그 근거가 해당 주석에 있다) |
| 래스터 슬롯 안쪽 배치 | `coretext_smoke.m` | cover-fit 스케일, ink 측정 후 세로 재중심(`maru_center_ink_vertically`), baseline `descent + (avail_h − line_height)/2`, advance 가로 중앙, 그리고 **어느 글리프를 ink-center할지 codepoint로 판정**(`0x25E7`·`0x2699` 하드코딩). `width.zig`의 wide-render-symbol 목록을 주석-동기로 **미러**한다(가드 없음) | [glyph-role-render-model.md](glyph-role-render-model.md)가 **역할→배치 매핑 정책**을 승인한 자리다. 단 `width.zig` 미러는 그 문서가 "**지금은** smoke 모듈성·저위험을 위해 유지, 백엔드가 늘면 `width.glyphRole`을 C-ABI로 export하거나 역할을 `reserved`에 실어 plumbing"이라 적은 **유예된 이관 대상**이다 — 승인된 것은 배치 정책이고 미러는 기한부다 |

주의할 점 셋:

- **divider는 값이 아니라 규칙 쪽이다.** 두께 자체는 config `split.divider-thickness` → Zig(pt × scale) → ABI라 값 계약이지만, 그 두께를 seam에 중앙정렬하고 셀폭으로 clamp하는 규칙은 `.m`이 갖는다 — 위 `reserved` 행과 **같은 함수·같은 성격**이다. 표에 따로 올리지 않은 것은 "두께는 Zig 소유"를 강조하려는 편의이고, 축 2 기준으로는 예외다.
- **chrome hairline(`tokens.border.line_thickness_px`)과 터미널 셀 장식선은 별개 개념이다.** 앞은 탭바 하이라인·focus 테두리·pill 테두리(전부 `GpuQuad`), 뒤는 커서 바·SGR 밑줄이다. 코드가 의도적으로 분리했으므로 섞어서 "두 출처"라고 부르지 않는다.
- **미러 가드가 덮는 범위는 좁다.** `tests/boundary/icon_literals.zig`는 아이콘 **배율(1.7) 두 표현식**만 강제한다. `ch*0.30` nudge·에이전트 `1.1×`·벨 `+cw*0.5`는 가드 밖이다([chrome-strategy.md](chrome-strategy.md) §9.7).

**규칙을 이미 따르는 표면**(전부 Zig가 rect를 정해 `GpuQuad`로 낸다): 도크 패널 배경(`appendBarBgQuad` — 탭 바 배경과 공용)·도크 카드/버튼 배경(`chrome_draw_lowering.appendBackgroundQuads`), 모달 배경·테두리, 탭 밴드와 활성 탭 cutout, **rich** 사이드바 활성 밴드, 스크롤바 thumb, 시각 벨 플래시. 모달 **그림자**만 `GpuShadow` 별도 채널이고 blur 확장을 `.m`이 한다(위 표).

**셀 격자는 셀보다 얇은 것을 표현할 수 없다.** `metal_lowering`의 `paintRectBg`는 픽셀 rect를
`trunc(y/ch) .. trunc((y+h)/ch)` 행 범위로 내리므로, 1px 구분선은 **위치에 따라 둘 중 하나**가 된다 —
행의 마지막 픽셀에 걸리면 `r1 == r0 + 1`이라 **그 행이 통째로** 칠해지고, 행 중간에 걸리면 `r1 == r0`이라
**아예 안 보인다**. 알림 카드 구분선이 18px 회색 밴드로 보이던 것이 앞의 경우였다(1px 의도 → 18배).

규율로 피할 수 없는 표현력의 한계이므로 **lowerer가 가른다**: `.fill`이 한 축이라도 셀보다 얇으면
(`isHairline`) 셀 배경 대신 픽셀 그대로의 GPU quad로 낸다. `.swatch`/`.quad`가 "둥근 모서리는 셀로 못
그리니 quad로" 가르는 것과 같은 규칙이고, 여기서는 **두께**가 그 이유다. 헤어라인 quad는 모달 배경
quad와 같은 layer 1이되 뒤에 append돼 그 위에 그려진다(painter 규칙은 lowerer가 소유).

**이관할 때의 함정**(사이드바 배경을 옮기는 경우 — 첫 예외):

- **`layer = bottom`이다.** 지금 배경 strip은 터미널 셀 **앞**에 그려져 사이드바 헤더 glyph(터미널 셀 패스)가 그 위에 보인다. `under`로 옮기면 터미널 셀 **뒤**가 돼 배경이 헤더 아이콘을 덮는 회귀가 재발한다(그 회귀를 고친 기록이 draw 순서 주석에 있다).
- **색 규약이 다르다.** 셀 경로는 premultiplied(`chromeCellBg`), `GpuQuad`는 straight-alpha(`chromeQuadBg` — 셰이더가 `rgb*=a`). 그대로 옮기면 `window.opacity < 1`에서 이중 premultiply로 어두워진다.
- **셀 strip은 타이틀바 띠까지 칠하는 유일한 페인트다.** 그 strip은 `y=0`부터 그려지는데 `Geometry` 유래 rect는 `titlebar_height_px`에서 시작한다 — 그대로 옮기면 신호등·헤더 아이콘 줄 뒤가 clear color로 드러난다.
- **`GpuQuad`는 SDF라 가장자리에 AA가 붙는다**(경계 프래그먼트 coverage ≈0.84 — 코드 주석에 실측이 있다). 하드 엣지인 셀 패스에서 큰 배경면을 quad로 옮기면 경계에 1px 반투명 seam이 생긴다. premultiply 규약과는 별개 문제다.
- **클리핑 인프라는 이미 있다(빠뜨리지만 말 것).** `GpuQuad`는 픽셀 단위 `clip_x/y/w/h`를 갖고, Zig는 `backing_height_px`로 전창 높이를 알며 이미 그 값으로 전창 quad를 낸다(시각 벨). 배경 strip 자체는 스크롤·scissor 대상이 아니다 — 다만 **스크롤되는 목록**(카드·밴드)을 quad로 옮길 때는 같은 스크롤 오프셋과 헤더 경계 clip을 함께 실어야 [tabs-splits-layout.md](tabs-splits-layout.md)의 "셀(`.m`)과 quad(Zig)가 같은 오프셋" 단일 출처가 유지된다.
- `reserved`는 부분사각형 kind(2~31)와 role(32~)을 겸한다. role을 새로 실으면 `.m`의 `reserved != 0` 분기도 함께 손봐야 한다.

**이미 승인된 예외적 배선과의 관계.** [layering-and-portability.md](layering-and-portability.md)는 `sidebar_header_height_px` 같은 좌표 시프트를 "L1 DTO로 L4에 전달해 GPU 백엔드가 적용"으로, [tabs-splits-layout.md](tabs-splits-layout.md)는 `.m` scissor와 Zig quad clip이 같은 오프셋을 쓰는 것을 "단일 출처"로 적었다. ML-GEO는 그 배선을 부정하지 않는다 — 다만 **"적용"과 "합성"의 경계는 그 문서들이 긋지 않았다**. `sidebar_header_height_px`를 적용하는 유일한 방법이 `origin_y + header − scroll`이고, 그게 위 예외 표의 사이드바 셀 배치 행이다. 그래서 여기서 선을 긋는다: **한 축의 평행이동까지가 계약**이고, 거기에 **높이·폭 결정, clamp, 확장, 조건 분기가 붙으면 예외**다. 이미 승인된 배선은 그 선에 걸쳐 있으므로 "새로 만들지 않는다"의 대상이고, 새 표면은 선 아래(순수 값 소비)로만 만든다. [sidebar-groups.md](sidebar-groups.md)는 이미 같은 처방(`.m` 기하를 없앤다)을 결정해 두었다.

**`GpuQuad`의 `layer`는 z축이자 수명축이다.** 이걸 모르면 배경이 첫 프레임만 보이고 사라진다.

| layer | z(그리는 순서) | 수명 |
|---|---|---|
| 2 = bottom | 가장 먼저(탭 밴드·도크 패널 배경) | **per-frame** — `dropQuadsByLayer(2)` 후 그 프레임의 build가 재충전 |
| 0 = under | 터미널 셀 뒤(사이드바 밴드·accent) | **retained** — `rebuildSidebar`가 소유 |
| 4 = header | 사이드바 strip 뒤·터미널 셀 앞(알림 배지) | per-frame |
| 3·그 밖 | over 패스(스크롤바·모달) | per-frame |

`metal_frame.zig`의 `layer` 주석은 0/1/2만 적어 stale이다(3·4가 실제로 쓰인다). 그리고 `dropQuadsByLayer`는 `swapRemove`라 **같은 레이어 안의 상대 순서를 보존하지 않는다** — `.m`은 레이어 내부 배열 순서를 painter 순서로 쓰므로(사이드바 tint↔accent 막대), 순서에 의존하는 quad를 더할 때 주의한다.

**`Geometry`는 창 좌표계가 아니다.** `dock_layout.compute`의 `available`은 **사이드바와 타이틀바를 이미 뺀 작업영역**이고(`available.x = sidebar_width_px`, `available.y = titlebar_height_px`), `Geometry`는 `backing_*_px`를 보관하지 않는다. 그래서 **창 전폭·창 전체높이 표면**(사이드바 strip, 시각 벨)은 `Geometry`의 기존 rect들에서 파생할 수 없다 — 예외가 아니라 `Geometry`의 정의다. 다만 그것이 곧 "`dock_layout` 밖에서 계산하라"는 뜻은 아니다: **하단 상태표시줄은 `compute`가 `backing_*_px` Input에서 직접 만들어 `Geometry.status_bar`로 내놓는다**([status-bar.md](status-bar.md) §1) — 창 높이를 먼저 깎아야 terminal·dock·divider가 한 지점에서 정합하기 때문이다. 즉 **작업영역 안 표면은 기존 rect에서 파생하고, 창 전체 표면은 `compute`가 Input에서 새로 만든다.** 어느 쪽이든 배치를 아는 곳은 `dock_layout` 하나다. 아래 "새 표면" 지침의 "`Geometry`에서 파생"은 **작업영역 안에 사는 표면**에 한한 말이고, pane·탭 바 안의 표면은 `chrome.components.tabbar.Metrics`(§5.4)가 단일 출처다.

**rect를 더하는 것과 자리를 예약하는 것은 다르다.** `Geometry`에 필드를 넣어도 공간은 안 생긴다 — `compute`의 `available.h`(그리고 우측 도크가 쓰는 `dock_available.h`)를 깎아야 하고, `compute`에는 **조기 반환이 셋** 있다(도크 숨김·폭 0·높이 0). 새 필드에 기본값을 주면 컴파일러가 그 셋을 안 잡아 주므로, 가장 흔한 상태에서만 조용히 빈 rect가 나간다.

**창 높이를 소비하는 출처는 `Geometry` 하나가 아니다.** 새 표면이 높이를 먹으면 다음도 함께 고친다 — `gridPadding()`(spawn grid: `layout_math.gridFromBacking`), `sidebarMaxScrollPx`(사이드바 목록 뷰포트), 사이드바 스크롤바 thumb의 `viewport_h`. 셋 다 `backing_height_px`를 직접 읽는다.

**표면은 rect 하나가 아니라 세 경로에 동시에 들어간다** — 렌더(quad/셀), **hit-test**(`dockGeometry()`가 40+개 포인터 라우팅의 권위다), 그리고 웹 패널이면 네이티브 frame. 렌더만 맞추면 클릭이 엉뚱한 표면으로 간다.

**ABI 필드의 의미를 바꾸면 다섯 곳을 함께 고친다** — `metal_frame.zig` 주석, `app_host_abi.h`, `maru_metal_renderer.h`, Swift 호스트, 그리고 `app_session.zig`의 ABI 버전 원장(vNN).

**새 표면은 예외를 만들지 않는다.** 기하가 필요하면 `session/dock_layout.zig`가 정하고 `GpuQuad`로 내며, `.m`에 새 인자를 더해 **그쪽이 rect를 계산하게** 하지 않는다. ABI 인자 추가가 더 작아 보여도, 그건 "배치를 아는 곳"을 하나 더 만드는 선택이다.

**단 `.m`이 이미 소유한 표면을 새 표면에 맞춰 끊는 것은 다른 문제다.** 하단 상태표시줄이 실제로 그랬다: 바 자체는 Zig가 `GpuQuad`로 그리지만, 사이드바 배경 strip과 셀 scissor는 `.m`이 바닥을 직접 정하는 승인 예외(위 표)라 **Zig가 값을 실어 주는 것 말고는 그 바닥을 옮길 방법이 없다**. 그래서 `MetalFrame.status_bar_height_px`(ABI v167)를 냈다 — `.m`은 그 값으로 **자기 표면을 자르기만** 하고 상태바의 rect는 계산하지 않는다([status-bar.md](status-bar.md) §5.2). 판단 기준은 "인자를 더하느냐"가 아니라 **"배치를 아는 곳이 늘어나느냐"**다.

> **셀 scissor는 그 뒤 예외에서 빠졌다**(ABI v168). 게이트·클램프·뒤집힘 방지를 전부 Zig(`sidebarScissorPx`)로 옮기고 `.m`은 받은 `[top, bottom)` 구간을 **그대로** 쓴다([status-bar.md](status-bar.md) §5.3). 즉 위 문단에서 `.m`이 바닥을 직접 정하는 표면으로 남은 것은 **사이드바 배경 strip 하나**다. 그 strip도 지금은 높이를 받아 `drawable_h - height`를 스스로 빼는데, **가장자리를 받는 쪽으로 정리하는 방향**이 정해져 있다(status-bar.md §6 — 트리거 대기).

### 입력 dispatch와 interaction state

모든 화면 상태를 props로 왕복하지 않는다. immutable props는 domain data, stable
item/action identity, enabled/disabled policy, named visual variant를 가진다. hover,
pressed, focus, pointer capture, scroll offset은 `ChromeHost`가 소유하는 UI-local
`InteractionState`다. component가 provider나 app 전역 상태를 직접 읽어 hover를
추측하지 않으며, Lab만 재현 가능한 interaction state를 explicit fixture input으로
주입한다.

1. `UiPointerEvent`는 현재 chrome의 제한된 `input.PointerEvent`를 완료로 주장하는
   이름이 아니라 ML2에서 추가하는 layout-layer DTO다. ML2는 기존 backing-px
   `down/move/up` 변환을 보존하면서 `scroll`과 monotonic timestamp를 같은 adapter
   경계에서 보강하고, platform → `ChromeHost` event mapping이 하나뿐임을 test로 고정한다.
2. `ChromeHost`는 ML2b 순수 상태 머신에 같은 `UiRectTree`를 주어 z-order와 clip chain
   역순 hit-test를 수행한다. move의 hover enter/leave는 이전/새 target의 two-dirty fast
   path를 쓰고, focus/pressed까지 바뀌는 전이는 모든 변경 visual identity의 bounded dirty
   set을 반환한다.
3. down은 target identity를 pointer capture로 보관한다. 이후 move/up은 포인터가
   target 밖으로 나가거나 다른 element 위를 지나도 capture target에 보낸다. up은
   down/up의 action identity와 enabled policy가 모두 여전히 맞을 때만 click Action을
   만든다. drag threshold를 넘으면 click Action 대신 component가 선언한 drag intent만
   허용한다. layout tree mutation, snapshot swap, surface deactivation, capture target
   identity 제거는 capture를 `cancelled`로 끝내 pressed를 지우고 이후 up Action을 만들지
   않는다. hover/focus 보존·정리는 새 enabled snapshot을 기준으로 `reconcile`이 결정한다.
4. wheel/trackpad는 hit target의 scroll owner만 소비하고, viewport clamp 뒤 같은
   rect tree를 다시 사용한다. pointer action과 keyboard focus action은 같은 stable
   identity를 통해 `Action`으로 합류한다.
5. component는 `Action` intent만 반환한다. host dispatcher만 resume/reveal/new-Term
   같은 side effect를 실행하며, Lab dispatcher는 recorded action만 남겨 filesystem,
   provider, process 실행을 절대 하지 않는다.

### ML2b interaction 계약

ML2b는 `src/chrome/ui/interaction.zig`의 순수 상태 머신이다. `ui/tree.zig`가
immutable `UiRectTree`를 만들고, `ui/interaction.zig`가 그 snapshot을 **빌려서만**
hit-test한다. 어느 쪽도 `ChromeHost`, `AppSession`, provider archive, Metal draw를
import하지 않는다. 따라서 실제 macOS adapter는 기존 `input.PointerEvent`를 이 DTO로
한 번 변환하고, `ChromeHost`는 반환 intent와 repaint 요구만 platform에 전달한다.

```zig
pub const UiPointerEvent = struct {
    phase: enum { move, down, up, cancel },
    x_px: f64,
    y_px: f64,
    button: input.PointerButton = .left,
    timestamp_ns: u64,
};

pub const InteractionState = struct {
    hovered: ?UiId = null,
    focused: ?UiId = null,
    capture: ?Capture = null,
};

pub const Dispatch = struct {
    action: ?UiActionId = null,
    /// frame arena가 소유하는 bounded, insertion-order, duplicate-free repaint set.
    /// ML2b state는 hovered/focused/capture 세 visual identity를 동시에 바꿀 수 있으므로
    /// two-rect hover fast path보다 넓은 상한을 둔다.
    dirty: DirtySet = .{},
};

pub const DirtySet = struct {
    ids: [4]?UiId = .{ null, null, null, null },
};
```

- `InteractionState`는 visual prop의 source다. `Card` paint는 immutable node prop과
  `hovered/focused/capture`의 id equality만 읽어 hover·pressed·focus variant를 고른다.
  component API에 arbitrary `onHover` closure나 provider callback을 넣지 않는다.
- hit-test 후보는 preorder의 **역순**으로 검사한다. 좌표가 NaN/∞이면 즉시 target 없음이며,
  유한 좌표도 candidate의 half-open `rect`(`x <= px < x+width`, `y <= py < y+height`)와
  `effective_clip` 양쪽 안에 있어야 한다. clip 밖이면 후보도 그 subtree도 선택할 수 없다.
  후보의 `UiAction`이 없거나 `enabled=false`이면 포인터 focus·capture·click target이 될 수
  없다. `text`처럼 inert node는 hit-test를 가로채지 않아 action을 가진 조상 `Card`가
  선택될 수 있다.
- `dirty`는 상태 전/후를 비교해 visual identity(`hovered`, `focused`, `capture`)가 바뀐 모든
  id를 insertion-order·중복 없이 담는다. ML2b에는 이 상태가 세 개뿐이므로 fixed `[4]`로
  충분하며 overflow는 programmer error로 fail-close한다. `move`의 hover A→B는 여전히 정확히
  two-dirty fast path이고, 같거나 둘 다 null이면 repaint 요구가 없다. `down`은 left button의
  enabled target만 `focused` 및 `capture`로 기록하고 pressed variant를 시작하며, 같은 event의
  hit target으로 hover도 갱신한다. `up`/`cancel`은 capture를 끝낸 뒤 현재 좌표의 enabled
  target으로 hover를 다시 계산한다. 이 전이 규칙을 통해 drag 뒤 pointer가 놓인 위치와
  hover paint가 한 frame에서 일치한다.
- ML2b는 pointer id 없는 single-primary-pointer protocol이다. left capture가 남은 상태로 또
  `down`이 오면 기존 capture를 action 없이 먼저 cancel한 뒤 새 `down`을 처리한다. capture는
  left `up` 또는 `cancel`에서만 끝내며, right/other `up`은 left capture와 focus를 지우거나
  action을 만들지 않는다. `cancel`은 button 값과 무관하게 action 0으로 capture를 끝낸다.
- capture에는 down 당시 `UiId`와 `UiActionId`를 함께 보관한다. `up`은 좌표가 target
  밖이어도 capture 대상으로 끝나지만, **down과 같은 published snapshot**에 capture가
  계속 남아 있을 때만 action을 하나 낸다. 우클릭/other button, target 없는 down,
  capture 없는 up은 action 0이다. drag intent·multi-pointer·double-click은 이 slice 밖이다.
- host가 새 tree를 publish하기 전 `reconcile(old_tree, new_tree)`를 호출한다. 새 snapshot
  publish는 capture를 항상 `.cancel`과 동등하게 끝내 pressed를 지우고 이후 stale `up`
  action을 금지한다. hover/focus는 새 tree에 같은 enabled id가 있을 때만 보존하고, 없으면
  null로 정리한다. old rect의 repaint는 old tree가 retire되기 전에 요청한다. build 실패에는
  새 tree가 없으므로 reconcile도 publish도 하지 않아 기존 capture/focus를 보존한다.
- surface가 deactivate되면 `deactivate`가 capture·hover·focus를 모두 action 0으로 지운다.
  다음 활성 surface가 재사용한 numeric id를 이전 surface의 hover/focus state로 오인하지 않는다.
- `timestamp_ns`는 adapter에서 단조 clock으로만 만든다. ML2b는 시간·worker·lock을 읽지
  않으며, 이후 drag threshold가 필요할 때만 이 event의 시간과 최초 down 좌표를 사용한다.
  `scroll`은 ML2b의 action/capture contract에 넣지 않는다. scroll owner/viewport는
  [ScrollArea](scroll-area.md)가 소유한다.

검증은 순수 `UiRectTree` fixture로 다음을 고정한다: clip 뒤의 action 무시, 겹친 card의
z-order, hover A→B의 two-dirty, focus/pressed 전환이 관련 모든 rect를 dirty에 넣는지, outside
move/up capture, disabled·action 변경 후 stale up=0, snapshot swap·surface deactivation의 cancel,
build 실패 뒤 기존 interaction 보존이다. 이들은 headless 계약 증거이고, 실제 Metal
cursor/hover paint와 scripted macOS 입력은 ML3 Chrome Lab capture에서 별도로 증명한다.
