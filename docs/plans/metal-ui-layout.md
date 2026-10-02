# Metal UI 구현·검증 순서 (§8)

ML 슬라이스의 구현 순서와 검증 게이트다. 계약은 [Metal UI 레이아웃](../metal-ui-layout.md)과 그 절별 소유 문서가 가진다.

> **절 번호는 파일을 넘어 이어진다.** 본문이 `§5`처럼 절만 가리키면 아래에서 소유 파일을 찾는다 — §1~§4·§7 [metal-ui-layout.md](../metal-ui-layout.md) · §2의 B1 [rich Button](../metal-ui-layout-button.md) · §5 [Metal paint와 입력 정합](../metal-ui-layout-paint.md) · §6 [Chrome Lab](../metal-ui-layout-lab.md) · §8 이 문서

## 8. 구현·검증 순서

1. **ML1 — typed rect/flex core:** `UiLength`, edge/min-max resolve, measure callback,
   row/column flex, overflow clip의 pure test. px/percent/auto/fill, zero/negative,
   NaN/∞ fail-close, tiny container, min/max freeze 재분배, text measurement을 단언한다.
2. **ML2a — nested component layout seam:** `src/chrome/ui/tree.zig`가
   `UiNode` builder와 `UiRectTree`, tree-wide unique stable identity, parent/clip
   ancestry, same rect 소비 seam, successful-only rebuild counter를 headless로 고정한다.
   이 tree는 legacy TUI cell/ANSI path를 읽지 않는다. 아직 draw/hit/focus consumer는
   연결하지 않았다.
3. **ML2b — pointer interaction seam:** `UiPointerEvent` mapping, hover enter/leave의
   two-dirty fast path와 focus/pressed의 complete dirty set, outside move/up pointer
   capture, tree mutation/snapshot swap의 cancelled capture와 stale up action=0을 ML2a
   rect tree를 소비하는 **pure `ui/interaction.zig` test**로 고정한다. macOS host adapter의
   event mapping·paint 결과는 ML3 Chrome Lab에서 별도로 고정한다.
4. **ML3a — typed paint resolver:** `ui/style`이 immutable variant/tone/paint prop을 정의하고
   `ui/tree`가 snapshot에 투영하며, 순수 `ui/paint_style.zig`가 그것과 `InteractionState`·rich `Tokens`
   snapshot을 resolved semantic style로 해석한다. `ui/paint.zig`만 `UiRectTree`를 snap해 fixed-capacity
   `ChromeDraw` 후보를 만든다. card의 base/selected/hover/focus/pressed/disabled
   precedence, role override, corner/border/opacity, backing-pixel snap, fixed-capacity
   overflow를 headless draw snapshot으로 고정한다. shadow는 이 단계에서 named token 값까지
   resolve하지만 GPU shadow emission은 ML3b가 연결한다. 이 단계는 platform lowering이나 실제
   text shaping을 연결하지 않으므로 pixel screenshot E2E 완료를 주장하지 않는다.
5. **ML3b — Chrome Lab과 Metal paint seam:** test-only `ChromeLabScenario` surface를
   먼저 만들고 ML3a draw를 production Metal lowering에 연결한다. Lab screenshot/readback
   fixture가 rounded/border/shadow/opacity/clip과 rect·clip 정합, scripted action identity를
   고정한다. clip scissor는 Metal framebuffer의 좌상단 원점을 명시적으로 사용하며,
   clip 미연결 인프라나 하단-원점 변환을 남기지 않는다. (**현황 2026-08-06**: 렌더러 모달 scissor에
   남아 있던 하단-원점 변환은 정정했다. 다만 그 경로에 `draw.Op.clip`을 내는 컴포넌트가 아직 없어
   여기서 요구하는 **경계 screenshot gate는 미구현**이다 — 첫 소비자와 함께 만든다. GPU per-quad
   clip(`GpuQuad.clip_*`)과 dock 스크롤 클리핑은 `test-dock-visual-golden`이 이미 픽셀로 고정한다.) nested clip·부분 pixel scroll의
   경계 screenshot이 y축 반전과 header bleed를 막는 gate다.
6. **ML4 — Session Dock:** `SessionDock`과 `ArchiveDetailPanel`이 ML1~3만 소비해
   direct text draw/ANSI guidance를 대체한다. 첫 AS3 product slice에서 `SessionDock`
   component는 typed tree의 geometry와 semantic `ChromeDraw.text`를 함께 내고, macOS backend의
   기존 CoreText lowering이 text op만 atlas cell로 바꾼다. 이는 platform이 문자열이나 rect를 재계산하지
   않는 one-way text bridge이며 generic GPU text shaping의 대체가 아니다. worker, archive identity,
   resume/reveal 계약은 바꾸지 않는다.
7. **ML5+ — 필요가 증명된 기능:** grid, static transform, transition/animation을
   각각 별도 PR과 fixture로 연다.
8. **ML6 — 나머지 chrome 컴포넌트의 typed-tree 이주:** 최종 목표는 **모든 chrome 컴포넌트가 `chrome/ui/`
   프리미티브 조합으로 구현되는 것**이다. ML4까지는 `SessionDock`·`ArchiveDetailPanel` 둘만 그 형태이고,
   나머지(`notifications`·`palette`·`find`·`notice`·`context_menu`·`settings`·`sidebar`·`tabbar`)는 rect를
   직접 계산해 ops를 내고 짝이 되는 `hitTest`를 따로 유지한다. 그 방식은 "보이는 것 == 눌리는 것"을
   자료구조가 아니라 규약으로 지키므로, 이주의 실질 이득은 **히트테스트가 published rect에서 파생되어 그
   부류의 드리프트가 구조적으로 불가능해지는 것**이다.

   이주는 컴포넌트를 하나씩 옮기는 일이 아니라 **먼저 프리미티브를 갖추는 일**이다. 코드에서 확인한 블로커:

   - **텍스트 모델 전환**: legacy 쪽은 셀 격자다(예: `notifications.zig`의 `card_rows = 2`(셀 2행),
     `text_indent_cols = 3`, 말줄임 `truncateToCols`(EAW 칸 추정)). typed 쪽은 measured 비례 텍스트
     (`ChromeTextRole` line box + `system_text.Artifact`)다. 두 모델은 좌표계가 달라 부분 이주가 안 된다.
   - ~~**없는 프리미티브 — 스크롤 목록/가상화**~~ → **블로커 아님**: ScrollArea(`chrome/ui/scroll_area.zig`·
     `tree.scrollArea`)가 생겼고 이관(SV0~SV6b)이 끝났다 — 계약은 [ScrollArea](../scroll-area.md), 순서와 잔여는
     [ScrollArea 이관 계획](scroll-area.md)이 소유한다. 알림은 픽셀 offset으로(SV5a), 팔레트·세팅은 공유 offset
     상태로 휠·드래그 스크롤이 된다(SV5d) — 셋 다 더는 `overlay_input.windowStart`를 쓰지 않는다. 오버레이는 그 막대를
     host가 자식 없는 scroll-area로 발행할 뿐 레이아웃은 아직 손계산이고(팔레트 `usable_cols`, SV5b), 그것을
     typed tree로 옮기는 것이 이 ML6의 몫이다.
   - ~~**없는 프리미티브 — sticky 헤더 밴드**~~ → 프리미티브는 생겼다(`tree.ScrollDeclaration.sticky`,
     [ScrollArea](../scroll-area.md) §4.7 — SV1d). 알림 패널의 고정 헤더는 아직 컴포넌트가 직접 예약한다.
   - **부분 행 클리핑**: 걸친 행을 자르는 경로는 섰다 — 셀이 자기 clip을 드는 ABI v169와 텍스트 op의 `clip`
     필드로 알림 패널이 부분 카드를 자른다(SV5a). 다만 ML3b가 요구한 **경계 screenshot gate는 아직 없다**
     (SV5a는 헤드리스 판정자만 더했다).

   각 컴포넌트 이주는 그 자체로 시각 회귀 위험이 크므로, `test-dock-visual-golden`처럼 **이주 전 캡처를
   골든으로 박고 이주 후 전체 프레임 픽셀 차이를 보이는** 절차를 따른다(무변경이 목표면 0픽셀이 증거다).

각 slice의 적대적 검증은 (a) draw/hit/clip rect drift, (b) parent resize와
virtualization boundary, (c) identity/stale action과 thread ownership을 독립적으로
공격한다. Taffy와 비교하는 fixture는 synthetic data만 쓰고 provider log·개인 경로를
넣지 않는다.
