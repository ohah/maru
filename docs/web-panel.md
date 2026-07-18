# 웹 패널 인프라 (WKWebView 합성·입력·임베드)

이 문서는 Maru에 리치 웹 패널(마크다운 WYSIWYG 편집·인앱 브라우저)을 WKWebView로 임베드하는 **합성·입력·web 특유 보안**의 단일 출처다. **세션 제어·브리지 신뢰 게이트 계약은 [세션 컨트롤 플레인](control-plane.md) §8이 소유**하고, 이 문서는 "WKWebView를 maru 창에 어떻게 올리고·입력을 라우팅하고·web 특유 위협을 막는가"에 집중한다(브리지 게이트를 여기서 재서술하지 않는다).

레이어 경계는 [레이어링과 이식성](layering-and-portability.md), 네이티브 뷰 비사용 예외(리치 웹 패널)는 [구현 계획](implementation-plan.md) UI 렌더 전략·[macOS 앱 호스트 경계](macos-app-host-boundary.md), 탭/split 모델은 [탭·split·레이아웃](tabs-splits-layout.md), 윈도우 간 detach/reattach와 WKWebView reparent 선행은 [윈도우와 Surface 이동성](window-surface-mobility.md)을 단일 출처로 둔다.

> **spike로 실측한 범위(2026-06)**: ① 투명 Metal 오버레이가 WKWebView 위에 합성되는 **z-order 순서**(GUI), ② isolated `WKContentWorld`에서 임의 page-world JS가 브리지에 못 닿음(headless). **그 둘만** 확인했다. 입력/firstResponder 라우팅·실제 셀 모달 합성·드래그 인터랙션·per-pane 좌표계는 **미검증 리스크**(§12)다.

## 1. 확정 결정

- **웹 패널 = WKWebView subview, 모달 = 별도 Metal 오버레이 레이어.** 단일 contentView를 컨테이너로 바꾸고 3겹으로 합성한다(§2).
- **z-order(WKWebView subview 모델 전용)**: 터미널 Metal layer(아래) < WKWebView(중간) < 투명 Metal 오버레이(모달, 위). **spike로 순서 합성만 확인**. 실제 셀 모달(텍스트·둥근 모서리·그림자·테마)을 투명 layer에 그린 합성은 Phase 4 종료 게이트에서 GUI 골든으로 1회 확정한다(§11). 이 골든은 렌더러의 자연폭/2-quad/role 기반 글리프 계약도 함께 확인한다.
- **모달은 NSView가 아니라 Metal 오버레이 레이어** — GPU chrome 철학(셀 렌더 재사용) 일관성 때문이다. **"이식성" 때문이 아니다**: "네이티브 웹뷰 위 GPU surface 합성"은 OS별 컴포지터 문제(macOS=CALayer subview, Windows WebView2=별도 HWND, Linux=Wayland subsurface)라 다른 OS에선 합성 모델을 타깃 시점에 재결정한다([layering-and-portability.md] §4 "호스트는 타깃별 신규").
- **입력 라우팅은 합성과 별개의 1급 문제다**(§4) — "layer만 분리"가 아니다. 모달이 그려지는 것과 키 입력이 모달에 가는 것은 다르다.
- **web 특유 보안**(§7): `maru-app://` 콘텐츠에 엄격 CSP + 스킴 핸들러 경로 샌드박스, `.md`는 "신뢰 렌더러가 그리는 **비신뢰 데이터**"(새니타이즈), untrusted 패널은 데이터스토어·프로세스 격리. **브리지 신뢰 게이트 자체는 [control-plane.md] §8.1 단일 출처.**
- **프론트엔드 개발환경 = zntc** (dev server/preview/build/bundle, dev-only, 확정). `web/` 하위 Bun workspace는 패키지 설치·락파일·script 실행·프론트엔드 단위 테스트(`bun test`)를 맡는다. JS/TS 품질 게이트는 VoidZero/Oxc 계열의 `oxlint`·`oxfmt`를 쓴다. Vite+에는 모노레포 config·task runner가 있지만, 전체 도입은 zntc 개발환경과 Bun test runner와 역할이 겹치므로 기본값에서 제외하고 필요 시 Vite Task만 별도 검토한다. **CEF는 미래 native webview-backend plugin 후보**(일반 Wasm/action plugin 아님 — §13).
- **미래 콘텐츠 소비처: 관측성 trace inspector**(후속). 캡처한 세션을 스텝별로 넘겨보는 **관전형 HTML 뷰어**를 이 패널에 띄운다(네이티브 패널을 새로 만들지 않고 재사용 — 자기완결 HTML이라 패널 완성 전엔 외부 브라우저로도 열림). replay 엔진 재사용·단일 출처. 상세: [trace-replay.md](trace-replay.md) "GUI inspector 설계 방향".
- **웹 패널 전에 필요한 이동성 foundation만 먼저 잡는다.** Maru-owned browser/markdown surface는 별도 창으로 detach된 뒤 다시 합쳐질 수 있어야 한다. 따라서 Phase 1 live collector 전에는 `SurfaceIdAllocator`/`WindowMembershipSnapshot`을 확정하고, Phase 4 WKWebView hosting 전에는 그 M0 완료를 확인한 뒤 `WindowGraph`/`LiveSurfaceRegistry`를 확정한다([window-surface-mobility.md](window-surface-mobility.md)). command 이동/drag/reparent UX는 Phase 4 이후에 따라와도 된다. 합쳐지지 않는 브라우저는 Maru surface가 아니라 `Open in External Browser` 경로다.

## 2. 합성 계층

현재 `contentView`는 단일 `MaruMetalTerminalView`(CAMetalLayer)이고, 이 뷰가 firstResponder로 keyDown·IME·마우스·DnD·hover를 전부 받는다. 웹 패널을 위해 **contentView를 컨테이너 NSView로 바꾸고** 세 겹을 쌓는다:

1. **터미널 Metal layer**(맨 아래): 기존 셀·사이드바·탭바·pane chrome. `isOpaque`는 무조건 true가 아니다 — `window.opacity<1`이면 현재 코드가 metalLayer·window의 `isOpaque`를 모두 false로 내리고 chrome 배경(`chromeCellBg`/`chromeQuadBg`)까지 반투명이다. WKWebView와의 정합은 §8.
2. **WKWebView subview(들)**(중간): web Term마다 하나, **본문 rect**에만(§5). split이면 여러 개. **(4e-3 구현 완료)**:
   활성 워크스페이스 탭의 pane 트리를 walk해 **web Term마다** WKWebView(`MaruWebPanelView` 래퍼) 하나를 붙이고, 각 웹뷰를
   **자기 pane 본문 rect에 고정**한다(4c의 활성 pane 추종을 완전 제거 — 사용자 관찰 해소). 같은 pane의 활성 Term만 show·
   비활성 탭 web Term은 hidden(상태 유지), 비활성 워크스페이스 탭의 web Term은 destroy(파일 패널은 워크스페이스 트리
   밖 **전역 도크**라 이 규칙의 대상이 아니다 — [file-panel.md](file-panel.md) §4). Swift는 `webPanels[surface_id]`
   dict로 batch 전이(create/destroy/reframe/hide/show)를 적용한다. Term 이동 시 재부모화는 후속(4e-4·§6).
3. **모달 Metal 오버레이**(맨 위): command palette·find·confirm. `isOpaque=false`, 평소 clear(투명), 모달 열림 시에만 셀을 그린다.

**모달 레이어 분리는 두 개의 선행 리팩터다**(Phase 4 선행, 가벼운 작업이 아님):
- **(a) 렌더러 분할**: 현재 모달은 터미널과 같은 cells 배열·같은 draw pass에서 `modal_cells_start` 인덱스로만 갈린다. same-pass 전제는 over-quad(`layer=1`)·그림자·`modal_clip_*`(scissor, ABI v84)에 더해 **커서 blink 페이드 suffix pass(ABI v95)**까지다 — caret은 단일 cells 버퍼 맨 끝 suffix + 단일 fragment opacity uniform 전제이고 draw 위치가 모달 유무로 갈리므로(모달 열림 시 모달 텍스트 뒤), 분리 시 caret pass를 소유 레이어로 재배선한다. 셀당 2-quad(×12 vertex) 오프셋 규약(`modal_cells_start*12`·`cursor_start*12`의 기반)도 두 패스에 그대로 이관한다. 이를 `drawTerminal(layer, cellSubset[, caret])` / `drawOverlay(layer, modalCells+quads+shadow[, caret])` 두 패스로 재분할한다. **caret은 조건부 이중 소유**다 — 모달이 닫힌 평시 caret은 터미널 콘텐츠라 `drawTerminal` 소유, 모달 열림 시에만 모달 텍스트 위 `drawOverlay` 소유로 이관한다(현재 `has_modal` 분기가 draw 위치를 가르는 그 지점). 두 CAMetalLayer의 drawable·redraw·**generation 게이팅을 독립 추적**한다(현 `lastSeenMetalGeneration` 단일 가정 변경). modal-clip 인프라 재배선 대상 — 주의: `MTLScissorRect`는 **좌상단 원점**이다(현재 미사용 modal_clip 경로에 좌하단 y-flip 가정이 **미수정으로 남아 있다** — 활성 scissor는 좌상단으로 올바름).
  - **present 원자성 불변식(tearing 방지)**: 두 레이어의 generation이 독립이면, 모달 열림/닫힘 **전이 프레임**은 두 레이어를 원자적으로 함께 바꿔야 하는 프레임인데(터미널 레이어에서 caret 제거 + 오버레이에 모달+caret 그림) 서로 다른 vsync에 커밋되면 tearing(모달만 새 프레임·배경은 옛것, 또는 caret 0개/2개)이 난다. 전이 프레임은 **두 레이어를 같은 `CATransaction`에서 커밋**(또는 both-ready까지 both-hold)하고, caret 소유권 이관은 그 단일 커밋 경계에서만 일어난다. 검증 artifact: 전이 프레임에서 caret이 정확히 1개.
  - **b2 구현 present 계약(단일 command buffer + 조건부 오버레이 present)**: 원자성은 `CATransaction`이 아니라 **두 drawable을 한 `MTLCommandBuffer`에 present + 단일 commit**으로 얻는다(`maru_metal_renderer_draw`). command buffer는 **drawable 획득 전에** 잡아, 큐 고갈 시 잡힌 drawable이 없게 하고(누수 0), 인코더 생성이 실패해도 이미 잡은 drawable을 present+commit으로 pool에 되돌린다. **오버레이는 매 프레임 present하지 않는다** — 그릴 내용이 있거나(`has_modal || shadow`) **직전 present가 content였는데 이번엔 비었을 때(clear 전이)**만 present한다(`overlay_needs_present = overlay_has_content || impl.overlayHadContent`). 빈→빈이면 오버레이 present를 통째로 건너뛰어(모달 없는 평상시 이중 present·컴포지터 낭비 제거) CAMetalLayer가 마지막에 present한 투명 clear를 유지한다. content→빈 전이 프레임엔 clear를 present해 **닫힌 모달 잔상**을 지운 뒤 `overlayHadContent`를 갱신한다. **drop-retry**: present가 필요한데 오버레이 drawable을 못 잡으면(pool starvation) `overlay_content_dropped=true` → `maru_metal_renderer_draw`가 false를 반환하고, Swift `drawMetalFrame`이 **`metalNeedsRedraw=true`로 세워 다음 tick에 재시도**한다(정적 모달·닫힘 clear 유실 방지). 재시도 트리거가 `lastDrawnGeneration`이 **아니라** `metalNeedsRedraw`인 이유: tick 게이트가 `lastSeenMetalGeneration`을 무조건 전진시켜 generation 불일치 재시도는 무력이기 때문이다.
- **(b) 호스트 재편**: contentView를 컨테이너로, 입력 responder를 명시 위임(§4). 오버레이용 `isOpaque=false` + transparent clear 분기(터미널 전용 `terminal_bg`/opacity clear와 별도).

## 3. 좌표계와 frame 동기화

- **기하는 이미 Zig에 있다.** 셀별 `origin_x/origin_y`·`terminal_origin_x_px`로 split pane별 픽셀 origin을 export하고, pane rect(w,h)는 `paneTermRect`가 내부 보유. per-pane rect는 새 수학이 아니라 **기존 내부값 노출 + surface 생애주기**다(§6).
- **좌표계**: 모든 ABI 좌표는 **backing-px·좌상단 원점**이고 WKWebView `frame`은 **포인트·좌하단 원점**이다. ABI는 px로 export하고, **Swift가 `firstRect` 선례대로 px→pt + y-flip**을 한다(기존 관행). backing-scale 변경 시 rect + drawable을 원자적으로 갱신.
- **frame 동기화 트리거**: resize·split·사이드바 폭·탭 스크롤뿐 아니라 **divider 드래그 live-resize·pane zoom·pane/Term 드래그·워크스페이스 전환**까지. 매 변경 시 본문 rect → WKWebView frame.
- **async desync와 사용자 피드백 반영(2026-07-18)**: 터미널 Metal은 tick(기본 60Hz·30~120 config — [io-render-threading.md] §10, "30Hz"로 굳히지 않는다)에 동기 repaint하고 WKWebView frame은 AppKit/WebKit 비동기 재레이아웃을 거치므로 한 프레임 jitter 가능성은 있다. 그러나 실제 제품 피드백에서 drag 전체 동안 문서가 사라지는 비용이 훨씬 컸으므로 **가림 대신 live reframe**을 정식 정책으로 택한다. `surfaceDiff`가 rect 변화가 있을 때만 `reframe`을 내고 `visible`은 유지한다.
- **입력 안전성과 정확한 anchor**: outer/group divider mouse-down은 WebView seam이 통과시킨 뒤 Metal view가 받으며, AppKit은 그 responder에 후속 drag/up을 계속 전달하므로 이동 중 WKWebView가 보여도 gesture 소유가 바뀌지 않는다. 확장 grab band 안에서 실제 divider 선이 아닌 곳을 눌렀다면 down 시 `divider - pointer` signed offset을 저장하고 모든 drag 좌표에 더한다. 따라서 첫 이동에서 경계가 포인터로 점프하지 않고 `pointer delta == divider delta`가 유지된다. snapshot 가림은 live reframe 성능이 실제 계측 예산을 넘을 때만 후속 옵션으로 재검토한다.

## 4. 입력·firstResponder·키 라우팅 (BLOCKER 해소)

합성만으로는 부족하다 — WKWebView가 포커스를 쥐면 `keyDown`/`performKeyEquivalent`가 WKWebView로 가고 Metal 뷰로 오지 않는다. 그러면 모달이 오버레이에 그려져도 키가 안 간다. 다음을 정한다:

- **모달 firstResponder 전이**: 모달(palette/find/confirm/rename) 열림 시 입력 responder를 **오버레이(또는 Metal 뷰)로 makeFirstResponder**, 닫힘 시 직전 WKWebView로 복원. 모달 입력·IME preedit가 이 경로로 흐른다.
- **maru 키바인딩 가로채기**: ⌘T·⌘W·⌘1.. 등 앱 액션은 WKWebView 포커스 중에도 먼저 잡아야 한다. WKWebView 서브클래스의 `performKeyEquivalent` override 또는 local event monitor로 — 메커니즘을 하나 택해 명시(현 코드는 오버레이 중 메뉴 keyEquivalent를 일부러 우회하므로 그 경로와 정합 필요). **(4d 확정: `performKeyEquivalent` override — 근거는 아래 spike 결과.)**
- **`anyOverlayOpen` 게이트**: 웹 패널 포커스 시 "활성 세션"이 무엇인지 정의해 게이트가 올바른 surface를 읽게 한다.
- **마우스(hitTest)**: 모달 오버레이는 평소 `hitTest=nil`(아래로 통과), 모달 열림 시 `self`(잡음). **(4d 실제: 오버레이는 `nil` 유지하고, 대신 웹 패널 래퍼가 모달 열림 시 `nil`을 반환해 클릭을 아래 터미널로 통과시킨다 — 오버레이가 `self`면 클릭이 dead-end라 모달 바깥-클릭 dismiss가 깨지므로, 통과가 더 안전하고 최소다.)**
- **Phase 4 코딩 전 입력 responder spike 선행**(가장 깨지기 쉬운 IME 코드를 건드리므로): WKWebView 포커스 중 모달 열림 → responder 전이 → IME preedit → 복귀를 실측해 메커니즘(`performKeyEquivalent` override vs local event monitor)을 **착수 전에 확정**한다. 자동 테스트가 어려워 spike+수동이 유일 안전망이다.

**spike 확정 결과(4d, 코드 실측 근거)**: 메커니즘을 **`performKeyEquivalent` override**로 확정한다(local event monitor 기각). 근거:
  1. **모든 maru 앱 키바인딩은 Zig `default_app_bindings`(config/keybinding.zig)가 단일 출처**이고 keyDown 경로(`maru_macos_app_session_key_down` → `KeyBindingResolver.resolve` → `.app_action`)가 ⌘T=new_term·⌘⇧P=toggle_command_palette·⌘F=toggle_find·⌘,=toggle_settings·⌘1..=select_tab 등을 **전부** 해석한다(메뉴 keyEquivalent는 발견성용 병렬 경로일 뿐, keyDown resolver가 자기완결). 따라서 웹 포커스 중 Cmd-조합을 `handleKeyDown`으로 보내면 Zig가 모두 처리한다 — 메뉴/WebKit performKeyEquivalent 동작에 의존하지 않는다.
  2. **터미널 IME 무회귀**: 웹 래퍼(`MaruWebPanelView`)의 override는 **웹이 포커스일 때만** 동작하고(그 외엔 `false`만 반환) 터미널 뷰의 keyDown/`NSTextInputClient`/`performKeyEquivalent`를 **한 줄도 건드리지 않는다**. local event monitor는 매 keystroke(한글 조합 포함)를 앱 전역에서 가로채는 병렬 경로라 터미널 IME 폭발반경이 크고, 현행 performKeyEquivalent+`anyOverlayOpen` 패턴과도 이질적이라 기각.
  3. **모달 responder 전이**: 웹 포커스 중 모달이 열리면(`anyOverlayOpen` false→true 엣지) `makeFirstResponder(터미널 뷰)`로 전이해 모달 입력·IME preedit가 터미널 `NSTextInputClient`로 흐르고, 닫히면(true→false) 직전 웹뷰로 복원한다. 전이는 **기존** `becomeFirstResponder`(imeFocus true)/`resignFirstResponder`(commitComposition)를 그대로 태운다 — 새 IME 로직 없음. 엣지는 매 tick + 모달 여는 조합 직후 동기로 조정한다(조합 직후 타이핑이 웹뷰로 새지 않게).
  - **자동으로 못 잡는 부분(수동 필수)**: 실제 포커스 전이·한글 preedit 라우팅·복원·기존 터미널 IME 무회귀는 GUI 손 테스트만 확정한다(§11). smoke는 `web_panel_focused`(시작 시 웹이 firstResponder를 안 훔침 = false)만 결정적으로 단언한다.
  - **범위 밖(Phase 5)**: 웹 소유 키(⌘C/⌘V/⌘A 편집·⌘F 페이지 내 find, §8)를 WebKit에 양보하는 **포커스 기준 분기** — 4d 최소 spike는 빈 about:blank라 웹 콘텐츠가 없어 Cmd-조합을 전부 maru로 라우팅한다(⌘C/⌘V가 웹이 아니라 터미널에 작용하지만 빈 페이지라 무해). 실콘텐츠에서 이 분기 정책은 Zig/config가 소유한다.

### 4.1 웹↔터미널 포커스 동기 불변식 (4g — 흩어진 포커스 패치 통합, 계획)

**문제(관측)**: Phase 7 손 테스트에서 포커스 버그가 **반복** 나왔다 — ⑴ 브라우저 보던 중 ⌘Q 종료 모달이 Enter로 안 닫힘 ⑵ 주소창 편집→터미널 클릭 시 포커스가 브라우저로 튐 ⑶ 터미널→브라우저 web 클릭 후 ⌘R 무동작 ⑷ 브라우저 탭을 활성화해도 webview에 포커스가 안 가 ⌘R 게이트가 stale ⑸ (남은 갭) 키보드 pane 전환(⌘⌥→)이 webview 포커스를 안 옮김. **다섯이 전부 하나의 근본**이다: **WKWebView 네이티브 `firstResponder`와 Zig 활성-pane 모델 사이에 단일 권위 있는 양방향 동기가 없어** 둘이 어긋난다. 지금은 케이스별로 기웠다(`reconcileWebModalFocus`·`reconcileWebFocusActivation`·`cancelAddrEdit` focus-restore·⌘R `activeWebSurfaceId` 게이트) — 옳은 레이어지만 파편화라 하나 고치면 옆에서 또 터진다.

**불변식(단일 출처)**: **`firstResponder` ⟺ Zig 활성 pane**.
- 활성 pane의 활성 term이 **web term** → 그 **webview**가 firstResponder.
- 활성 pane의 활성 term이 **terminal** → **터미널 뷰**가 firstResponder.
- **override(우선순위)**: **모달 열림**(notice 제외) 또는 **터미널-라우팅 텍스트 입력**(주소창 편집·rename·사이드바 검색) → **터미널 뷰**(그 입력은 Zig `handleKeyEvent` 경로라 터미널 뷰가 소유). 이 판정은 Zig `terminalOwnsInput`(=`anyModalOverlayOpen ∪ addr_edit ∪ rename ∪ sidebar_search`) **단일 출처**다(4g-3 통합, ABI `terminal_owns_input`). 모달/편집이 끝나면 불변식이 복원한다(별도 focus-restore pending 불요). 비-모달 notice(토스트)는 제외 — 지나가는 토스트가 입력 responder를 뺏으면 안 되고, Zig 키 intercept(rename/addr_edit/sidebar_search)도 같은 `anyModalOverlayOpen` 게이트를 쓴다.

**두 방향 동기(매 tick `reconcileWebFocus`, 순서 중요)**:
1. **Direction 2 — webview 클릭 → Zig 활성**: webview가 **새로 firstResponder가 된 rising edge**(= 사용자가 그 web 콘텐츠를 클릭)면 `activate_surface`로 Zig 활성 pane을 그 surface로 동기한다. **rising edge인 이유**: 키보드 전환 후 webview가 stale 포커스로 남은 경우(활성=terminal인데 webview 포커스)와 싸우지 않게 — "새 클릭"만 반영한다.
2. **Direction 1 — Zig 활성 → firstResponder**: 활성 pane에 firstResponder를 맞춘다(활성=web이면 그 webview, 활성=terminal이면 터미널 뷰, 이미 맞으면 no-op). Direction 2가 클릭을 반영한 **뒤** 실행해, 키보드 pane/탭 전환이 포커스를 따라오게(갭 ⑸ 닫음) + 브라우저 탭 활성화가 webview를 포커스(갭 ⑷ 닫음).

**이 하나가 흩어진 것을 대체(subsume)한다**:
- `reconcileWebModalFocus`(모달→터미널) = override 규칙.
- `reconcileWebFocusActivation`(클릭→활성) = Direction 2.
- `cancelAddrEdit`의 `addr_focus_restore_pending`(편집 종료 시 webview 복원) = addr_edit override 해제 후 Direction 1이 복원(pending 불요·단순화).
- ⌘R `activeWebSurfaceId` 게이트 = Direction 1이 브라우저 탭 활성 시 webview를 포커스하므로 `isWebPanelFocused`가 신뢰 가능해져 원 게이트로 회귀 가능(belt-and-suspenders로 유지 가능).

**필요 표면**: `activate_surface`(v78, 있음). **활성 web surface getter 확장** — 현 `activeWebSurfaceId`는 browser 전용(0=아님)이라, Direction 1이 활성 pane이 **어떤 web kind든**(browser·markdown) 그 webview를 포커스하려면 "활성 pane 활성 term이 web이면 surface_id + kind, 아니면 0"이 필요하다(신규 getter 또는 확장, Zig 순수·헤드리스 테스트). Swift는 surface_id→webPanels로 webview 조회.

**분해**:
- **4g-0 (Zig — 구현 완료)**: `activeWebSurfaceIdAnyKind` getter(활성 term이 web[browser·markdown]이면 surface_id, 아니면 0, ABI v112) + 헤드리스 테스트(터미널=0·browser/markdown=id·browser-only는 markdown서 0=핵심 구분).
- **4g-1 (Swift — 구현 완료, GUI 손 테스트 통과)**: 통합 `reconcileWebFocus`(override → Direction 2 rising-edge → Direction 1) 구현, `reconcileWebModalFocus`·`reconcileWebFocusActivation` **대체·삭제**. override용 `addr_edit_surface` getter(ABI v113). 미사용 `lastOverlayOpen`·`stashedWebFocusSurfaceId` 제거. 손 테스트: 모달 Enter·터미널/브라우저 클릭·키보드 pane/탭 전환(새로 닫은 갭)·주소 편집·팝업·터미널 IME 무회귀 전부 통과.
- **4g-2 (정리 — 완료)**: **검토 결론**: `addr_focus_restore_pending`(주소 편집 종료 후 webview 복원)·⌘R `activeWebSurfaceId` 게이트는 불변식 Direction 1에 **subsume**되지만(D1이 복원·브라우저 탭 활성 시 webview 포커스), **제거 시 ABI export 제거+체인+손 테스트인데 동작 이득 0**(D1과 same-tick 복원)이라 **belt-and-suspenders로 유지**(harmless 중복 — 즉시 복원 fast-path/견고한 게이트, D1이 authority; 향후 저우선 cleanup서 제거 가능). ⌘R KVO `assumeIsolated`(13차 리뷰 [7] PLAUSIBLE)=**유지**(WKWebView nav KVO는 WebKit 메인 스레드 갱신·off-main 미관측 + 코드베이스 확립 패턴[NSColorSampler 등 7곳] + 근거 없는 방어 지양; 실 크래시 관측 시 dispatch 전환). 주석에 근거 명시.
- **4g-3 (14차 리뷰 후속 — 완료)**: override 판정을 `anyOverlayOpen ∪ addr_edit`에서 **`terminalOwnsInput` 단일 출처**로 교체(ABI `addr_edit_surface`→`terminal_owns_input`, v113→v114). 옛 override는 ⑴ **rename·사이드바 검색을 빠뜨려** web pane 활성 중 그 편집 키가 웹뷰로 샜고(리뷰 [0]) ⑵ **notice까지 세어** 비-모달 토스트가 편집 responder를 뺏었다(리뷰 [3]). 겸사로 Zig 키 intercept 3개(rename/addr_edit/sidebar_search)도 `anyOverlayOpen`→`anyModalOverlayOpen`으로 일치, 주소창 편집 chord 처리는 **⌘A/C/V/X/Z를 제외**해 ⌘V가 편집을 통째 날리던 회귀 수정([1], 소비 no-op으로 편집 보존·실 붙여넣기는 후속), 잘못된 주소 무효 시 편집 유지 docstring 정정([5]), `focusTerminalView` 재downcast→바인딩된 `tv` 재사용([8]). **헤드리스**: 브라우저 web term 닫기 확인([4]) + `terminal_owns_input(null)=0` ABI 테스트. **GUI 손 테스트 필요**: web pane 위 rename/사이드바 검색이 웹뷰로 안 새는지, 주소창서 ⌘V가 편집을 안 지우는지, 모달 Enter·키보드 pane 전환 무회귀.
- **4g-4 (파일 도크 교차 영역 입력 회귀 — 완료, 2026-07-18)**: 도크가 열린 mouse-down 경로의 `dockGroupAtPoint(...) orelse return`이 도크 밖 클릭까지 함수 전체에서 종료해, workspace browser는 보이지만 주소창·탭·터미널을 조작할 수 없었다. group hit는 조건부로 처리하고 **실제 dock rect 안** Metal 클릭만 소비하도록 바꿔 바깥 클릭은 workspace hit-test로 흐른다. 도크를 연 browser 주소창 클릭→`addr_edit_surface`/`terminalOwnsInput`→문자 입력까지 red→green 통합 테스트로 고정했다.

**리스크·검증**: 코어 포커스라 회귀 시 **모달·타이핑·IME가 깨진다** → firstResponder는 AppKit이라 헤드리스 불가, **GUI 손 테스트가 유일 안전망**(§11). 특히 `reconcileWebModalFocus`(검증된 모달 Enter 동작)를 대체하므로 그 무회귀를 재확인한다. Zig getter(4g-0)만 헤드리스. 기존 터미널 IME/keyDown은 **한 줄도 안 건드림**(4d 규율 유지 — override는 makeFirstResponder만).

## 5. WKWebView가 막는 터미널-chrome 인터랙션

z-order상 모달(최상위)을 제외한 모든 터미널 마우스 인터랙션이 웹 pane 위에서 WKWebView에 가로채인다. 다음을 정한다:

- **WKWebView frame을 본문 rect로 한정**한다 — pane 탭바·divider seam·pane grip은 Metal 노출 영역으로 남겨 마우스가 닿게.
- **drop-zone split 생성**(Term 탭을 본문 4분할에 드롭)은 드래그 중 대상 WKWebView를 `isHidden`/`hitTest nil`로 임시 통과시키고, drop-zone 하이라이트는 **모달 오버레이(최상위)**에 그린다(터미널 Metal 레이어에 그리면 WKWebView에 가림).
  - **구현(렌더러 슬라이스 — 완료)**: 탭/pane 드래그 시각물 두 가지 — drop-target 반투명 하이라이트(bg-only 셀)와 floating 고스트(끌리는 대상 라벨 박스)를 **터미널 레이어(`pane_overlay`/`pane_frames`) → 최상위 오버레이 레이어**로 옮겼다. `MetalFrameBuffer.replace`에 `drag_overlay_frame`(고스트 PaneFrame — raster는 `buildMergedUploadsN` `drag_raster`로 머지)·`drag_overlay_cells`(하이라이트 bg 셀) 두 채널을 추가하고, 이들이 있으면 `modal_cells_start`를 오버레이 영역 시작으로 세워 렌더러 `has_modal`(실은 "오버레이 영역 존재") 경로로 **WKWebView 위** 오버레이 CAMetalLayer에 그린다. ABI·`MetalFrame` 구조체·렌더러 `.m` draw 로직 **무변경**(modal_cells_start가 이미 구동). 드래그가 없으면 두 채널이 비어 옛 경로와 byte-identical(무회귀). **오버레이 영역 순서 = [하이라이트(아래)] [드래그 고스트(중간)] [모달(위)]** — 모달을 맨 뒤에 둬 그 caret이 버퍼 suffix(blink chop 대상)로 유지된다(15차 리뷰 [0]: 드래그 중 ⌘F로 caret 모달을 열면 modal·drag가 키보드 모달로는 배타가 아니라 공존 → 고스트를 모달 뒤에 두면 blink가 고스트에 얹혔던 것 정정). 헤드리스 테스트=셀 조립(오버레이 영역·`cursor_cells`), 실제 web 위 가시성·드래그+모달 caret=손 테스트. **알려진 한계(15차 [7], 후속)**: `modal_cells_start` sentinel 0이 "오버레이 없음"과 "인덱스 0 시작"을 겸해, rich 테마+접힌 사이드바+단일 web pane(오버레이 앞 셀 0)에서 드래그 시각물이 터미널 레이어로 새 WKWebView에 가릴 수 있다(실무 흔한 config는 탭 바/헤더 셀이 있어 무영향). 견고 수정은 렌더러 게이트·assert를 건드려 손 테스트 필요.
- **divider 드래그·hover 커서**(↔/grip)도 본문 한정 + 드래그 중 통과로 처리.
  - **구현(4e review 0 후속)**: ⑴ Zig가 각 web 본문 rect를 divider에서 작은 seam inset(`dt + 1pt`)만큼 들여 **작은 시각 gap**을 두고, 그 rect의 **divider 맞닿는 가장자리 비트마스크**(`seam_edges`: left=1·right=2·bottom=4)를 ABI(`WebSurfaceTransitionAbi.seam_edges`, v103)로 Swift에 넘긴다. ⑵ `MaruWebPanelView.hitTest`가 seam 가장자리 밴드(`dividerGrabBand`≈10pt) 안 클릭/hover를 `nil`로 **통과**시켜 아래 터미널 뷰의 `dividerAtPoint`가 드래그를 잡는다(기존 divider 로직 재사용 — 네이티브 중복 없음). 이로써 **작은 gap과 넓은 grab 폭을 분리**한다(순수 geometry inset은 gap=grab이라 둘을 같이 줄일 수밖에 없던 한계 해소).
  - **파일 도크 확장(FP8 보강, 2026-07-18)**: 같은 `seam_edges`를 도크 WKWebView에도 leaf 기하에서 정확히 계산한다. right outer 경계뿐 아니라 editor-group 내부 divider와 editor↔project-tree 경계에 실제로 맞닿는 left/right/bottom 비트만 주어, WebView 안쪽 10pt grab band에서도 group/tree resize가 Metal로 통과하고 일반 본문 클릭 영역은 유지된다. resize 동안 WebView를 숨기지 않고 surface diff `reframe`만 적용한다.
  - **알려진 한계(인지·미해결, Phase 5)**: 클릭·드래그 리사이즈는 통과로 되지만, **hover 시 resize 커서(↔/↕) 힌트가 web pane divider 밴드 위에서 안 뜬다** — WKWebView가 native NSView라 자기 frame 위 **커서 소유권**을 갖고(클릭은 hitTest로 우회되나 커서는 별개 메커니즘), arrow로 남는다. 이는 웹뷰를 split pane에 임베드하는 앱의 **잘 알려진 문제**(NSSplitView+WKWebView·Electron/VS Code 등 — maru는 divider를 GPU로 직접 그려 NSSplitView 공짜 divider를 못 쓰므로 DIY 통과가 필연). 전체 커서 해결안 2가지는 실콘텐츠(Phase 5)와 함께 재검토: **(a)** WKWebView를 밴드만큼 들이고 래퍼를 흰 배경으로 채운 뒤 래퍼가 seam 밴드에 resize `addCursorRect` — 동작하나 실콘텐츠에선 seam 가장자리에 ~밴드폭 흰 테두리가 생김. **(b)** divider 위에 얹는 오버레이 grabber 뷰 — 분리는 깔끔하나 divider 드래그를 네이티브로 중복. 지금은 grab 폭 확보(클릭/드래그)만 반영하고 커서 힌트는 미룬다.

## 6. surface 식별·생애주기 ABI (신규)

현 ABI는 활성 surface 1개(`FrameSummary.surface_id`)만 노출한다. 여러 WKWebView를 관리하려면 신규가 필요하다:

- 매 tick **surface diff**: "어느 surface_id ↔ 어느 NSView, url/panel_kind/trust, 생성/숨김/파괴" — [control-plane.md] §3 엔티티·`panel.open` 생애주기와 직접 커플링.
- web surface는 **Term**이다(leaf=Pane이 아니라 Pane 안 Term). 한 Pane이 terminal Term + web Term을 가로 탭으로 섞을 수 있고, per-pane 탭바가 둘을 같이 보인다. **web Term마다 WKWebView**(한 leaf에 N개 가능, 활성만 show, 비활성 hidden으로 상태 유지). **(4e-1 구현 완료 — 모델 토대)**: `session_model.Term.kind`(terminal|web) + `LiveSurface` `union(SurfaceKind)`(web arm=sentinel surface)로 web Term을 트리에 담고, `createWebTerm`이 PTY 없이 생성한다. **(4e-3 구현 완료 — per-Term WKWebView 호스팅)**: `computeWebSurfaceTransitions`가 활성 워크스페이스 탭 pane 트리를 walk해 web Term 집합(각 `{surface_id, panel_kind, 자기 pane 본문 rect, visible=자기 pane 활성 탭인가}`)을 만들고 직전 tick 집합과 `surfaceDiff`한 **batch 전이**(count+at ABI, v101)를 낸다. Swift가 `webPanels[surface_id]` dict에 create/destroy/reframe/hide/show를 적용해 web Term마다 WKWebView를 자기 pane 본문 rect에 고정한다(활성 pane 추종 완전 제거). Term 이동 시 **재부모화**는 4e-4(§10).
- Term 탭을 다른 pane으로 이동하면 WKWebView **재부모화·재프레임**.

## 7. web 특유 보안 (브리지 게이트는 control §8.1)

브리지 신뢰 게이트(isolated world·per-surface capability·forMainFrameOnly)는 **[control-plane.md] §8.1이 단일 출처**다. 여기서는 web 레이어에서만 발생하는 위협을 다룬다:

- **`.md`는 신뢰 콘텐츠가 아니라 "신뢰 렌더러가 그리는 비신뢰 데이터"**다. raw HTML/script 비활성 새니타이즈(`<script>`·`on*`·`javascript:` 제거)가 기본. maru가 빌드해 번들하는 렌더러 JS는 해시 핀(SRI)·락파일로 공급망 고정.
- **`maru-app://` 스킴**(이름 문법·등록 가능성 근거는 §9): 엄격 CSP 응답 헤더로 외부 네트워크·`<base>`·form-action exfil을 차단하고, frame은 번들 renderer origin `maru-app://render` 하나만 허용한다(정확한 문자열 단일 출처=코드 `app_scheme.csp_header`, §7.1 ③). 스킴 핸들러는 **경로 정규화 후 허용 루트 prefix 검증**(realpath·symlink 거부·`..` 차단)하며 maru가 번들한 asset root만 서빙한다.
- **브리지 origin 격리(sanitizer 단독 의존 금지, FP4 실구현)**: 브리지는 신뢰 viewer shell `maru-app://app` main frame에만 붙이고, md-derived 문서는 `sandbox="allow-scripts allow-same-origin"`인 `maru-app://render/render.html` iframe에서 처리한다. app/render의 host가 달라 서로 same-origin이 아니며 renderer에는 user script/message handler를 주입하지 않는다. actual WKWebView smoke가 renderer의 `window.maru`와 `window.webkit.messageHandlers.maru`가 `undefined`, `parent.document` 접근이 실패함을 단언한다. `allow-same-origin`은 custom-scheme ESM+SRI 실행에 필요하지만 host 분리와 이 런타임 gate 없이는 허용하지 않는다.
- **브리지 호출부 프레임 검증**: 메시지 핸들러 등록은 world-scope(frame 무관)라, 핸들러 진입에서 `frameInfo.isMainFrame` + `securityOrigin`이 **scheme=`maru-app`, host=`app`, 명시 port 없음**과 일치하는지 검사한다. 같은 Zig `appOriginAllowed` 정책을 scheme handler(assets=app|render)·navigation(main=app/subframe=render)·bridge(main=app)가 역할별로 소비한다. `browser` config에는 scheme/message handler를 등록하지 않고 `maru-app://` 네비게이션을 차단한다.
- **untrusted 패널 격리**: `browser` 패널은 신뢰 콘텐츠와 데이터스토어를 분리한다 — **실구현(7e-0·2026-07-17 정정)**: browser 탭들은 **공유 ephemeral `browserDataStore`**(탭 간 공유 = 로그인 연속성·팝업 OAuth 근거, §7e-0)이고 신뢰 persistent store와 격리된다. 초판의 "별도 WKProcessPool + per-surface ephemeral"은 stale — WKProcessPool은 최신 WebKit 자동 관리(deprecated)라 명시하지 않고, per-surface 격리는 안 하기로 결정됐다([control-plane.md] §9 동일 정정). 파일 도크의 로컬 html은 FP5에서 별도 ephemeral `filePanelDataStore`로 구현됐고 browser credential을 공유하지 않는다([file-panel.md](file-panel.md) §2).
- **링크 라우팅**: 웹 패널 링크 클릭은 `decidePolicyForNavigationAction`에서 인터셉트해 [링크 감지](link-detection.md)의 존재검증·스킴 화이트리스트·명시 제스처 정책을 재사용한다(`file:///X.app` 실행 등 차단).

### 7.1 5c — `maru-app://` 스킴 + 엄격 CSP + 경로 샌드박스 설계

Phase 5 세 번째 슬라이스(신뢰 UI 경로)는 `maru-app://`를 안정적 origin으로 확립했고, FP4가 실제 file-panel shell/renderer asset과 제한된 iframe 정책을 연결했다.

**의존성**: 소켓 write-경로·capability 발급(1e)·1g와 **무관**(자족적 — 스킴은 in-WKWebView 콘텐츠 서빙이라 컨트롤 소켓 경로를 안 탄다). 안정적으로 독립 진전.

**① 경로 샌드박스(신규 코드 — 보안 코어)**: `sanitizeDropFilename`(cli/ssh.zig, basename+문자 필터만)은 realpath/symlink 거부를 안 하므로 **신규**다. 두 층:
- **L2 순수(헤드리스, `src/session/`)**: 요청 경로 문자열 검증 — `..`(및 인코딩 `%2e%2e`·중복 슬래시·backslash)·절대경로 탈출 거부 + 정규화 후 **허용 asset root prefix 아래인지** 확인. adversarial 단위 test(`../`·`....//`·`%2e%2e%2f`·절대·null byte·`.`만·빈 경로)로 탄탄히. 문자열 레벨이라 순수·이식성.
- **platform(macOS, 실 FS)**: 정규화된 경로를 **realpath**한 결과가 여전히 asset root 아래인지 + **symlink 탈출 거부**(realpath가 root 밖을 가리키면 거부). 실 FS I/O라 platform. macos smoke로 검증(symlink→거부).

**② 스킴 핸들러(`WKURLSchemeHandler`, platform)**: 신뢰 config에만 `setURLSchemeHandler(_, forURLScheme:"maru-app")` 등록. 요청 → ① 샌드박스 검증 → 통과면 **maru 번들 asset root**의 바이트를 읽어 **엄격 CSP 헤더**와 함께 응답, 거부면 차단(404). **뷰되는 파일 자신의 디렉터리는 안 서빙**(§7 — `script-src 'self'` 아래 공격자 디렉터리 스크립트 same-origin 로드 차단). 스킴 이름 근거=§9(RFC 3986, `WKURLSchemeHandler` 커스텀 스킴 등록 가능·소문자 고정).

**③ CSP(응답 헤더)**: 엄격 CSP를 응답에 항상 부착 — 외부 네트워크(`connect-src 'none'`)·임의 frame·`<base>` 하이재킹·form-action exfil 차단. **문자열 단일 출처는 코드 `app_scheme.csp_header`**: `default-src 'none'; script-src 'self'; img-src 'self' data:; style-src 'self' 'sha256-Xeh9es1AoJEyNnawqxMjG30+czqjDUSJ+JDkbXALfVg='; connect-src 'none'; frame-src maru-app://render; base-uri 'none'; form-action 'none'`. style hash는 [file-panel.md](file-panel.md) §1의 두 신뢰 HTML에 공통인 초기 `Canvas` critical style bytes 하나만 허용하며 `unsafe-inline`은 계속 금지한다. frame 예외는 FP4의 번들 renderer exact origin 하나뿐이다.

**④ 트러스트 분기**: `markdown`(신뢰) config만 스킴 핸들러·브리지를 등록한다. `browser`(untrusted) config엔 **미등록** + `maru-app://` 네비 차단. FP4부터 markdown config는 `web/dist`의 실 shell/renderer를 로드한다.

**⑤ 자동 검증**: 경로 샌드박스 adversarial(헤드리스 Zig) + macos smoke(`maru-app://…/index.html` 로드·CSP 존재·asset 서빙; `maru-app://…/../etc/passwd`·symlink→거부; browser 패널서 `maru-app://` 네비 차단).

**⑥ 슬라이스 경계** — 5c=스킴·경로 샌드박스, 5b=exact app-origin bridge, FP2=실 UI build, FP4=제품 asset·read bridge·격리 renderer 결합.

**⑦ 구현 완료(5c-1·5c-2a/b/c)** — 세 번째 슬라이스를 세 조각으로 나눠 각각 헤드리스 게이트 후 머지했다:
- **5c-1(경로 샌드박스, L2 순수)**: `src/session/app_scheme.zig` — `validateAppPath`(traversal `..` segment·whitelist `[a-zA-Z0-9._/-]`로 `%`·backslash·null·제어문자 거부·정규화 불변식) + `csp_header` 상수(③ 단일 출처). adversarial 헤드리스 테스트 6개.
- **5c-2a(realpath 탈출 방어 보안 코어, L4 platform I/O)**: `app_host_abi.zig` `resolveAppAsset(io, root, req, out)` — 5c-1 문자열 검증 후 candidate·root를 각각 `realPathFile`로 canonicalize해 candidate가 root **아래**(`pathIsUnder`)인지 확인(symlink가 root 밖을 가리키면 거부). `statFile.kind != .file`→NotFound. tmpDir adversarial 4개(정상·traversal·symlink 탈출·부재/디렉터리).
- **5c-2b(C-ABI export)**: `maru_macos_app_resolve_app_asset`(>=0=경로 길이, 음수=−1 Reject/−2 NotFound/−3 OutsideRoot/−4 NULL) + `maru_macos_app_csp_header`(CSP 단일 출처를 Swift가 읽음). 정책=Zig, 어댑터=Swift 경계를 시그니처로 고정.
- **5c-2c + FP4 제품 연결**: `MaruAppSchemeHandler`가 안전 경로의 번들 asset을 CSP와 서빙하고 `MaruWebPanelView`는 markdown config에서만 scheme handler + exact-origin bridge를 등록한다. FP4는 placeholder `src/platform/macos/web/*`를 제거하고 zntc 생성물 `web/dist`를 `Resources/web/`에 복사한다. `maru-app://app/index.html` shell은 `maru-app://render/render.html` iframe을 오케스트레이션하며, macos smoke가 실제 fixture와 bridge/renderer 격리를 자동 단언한다.

## 8. 빠진 기능 (구현 시 필수)

- **browser chrome UI (주소창·nav — `browser` kind 전용, 슬라이스 7e)**: WKWebView는 **네비게이션 UI를 제공하지 않는다**(Safari.app의 주소창·버튼은 Safari 앱 자체 chrome이지 WKWebView가 아님; SFSafariViewController의 내장 chrome은 iOS 전용·모달이라 embed 불가). 단 **nav 함수는 공짜**다 — `goBack()`/`goForward()`/`canGoBack`/`canGoForward`/`reload()`/`load(URLRequest)`/`url`/`title`/`backForwardList`/`estimatedProgress`를 WKWebView가 주고 WebKit이 히스토리·백스택을 소유한다. 그래서 maru는 **UI 껍데기만** 만든다: "chrome=Zig+GPU" 원칙대로 **탭바처럼 GPU 셀로 back/forward/reload 버튼 + 주소창**을 그리고, 버튼→ABI→WKWebView API를 호출한다(`canGoBack`/`canGoForward`로 버튼 활성/비활성). **주소창 2모드**: **① 비활성(읽기전용)** = 현재 `url`만 표시(입력 불가 — 위치 확인용, 임의 URL 입력 보안면 없음), **② 편집** = URL 입력 → `load`(임의 웹 로드라 §7 보안 — untrusted 프로세스 격리·`decidePolicyForNavigationAction` 링크 라우팅 — 동반, Phase 5 security 이후). `panel.navigated`(control §11 이벤트)/navigation delegate로 URL·progress 갱신. markdown kind는 주소창 불요라 kind별 분기(닫힌 열거).

  **7e 슬라이스 계획(인프라 근거 — 텍스트 입력은 `OverlayInput`[chrome/components/overlay_input.zig, find.zig 컴포넌트 형태] 재사용, chrome 렌더는 ChromeDraw[find/sidebar] + tabbar `Metrics` 존 hit-test 재사용, 본문 rect는 `web_panel_layout.contentRect` inset 확장, nav 상태는 최대 greenfield=신규 ABI). 순서=격리 먼저(사용자 결정 2026-07-10). 편집 텍스트 범위=MVP(입력·백스페이스·붙여넣기·Enter/Esc; mid-string 커서·선택은 후속=[text-field-editor.md] 상세 설계):**
  - **7e-0(untrusted 데이터 격리 — 구현 완료)**: browser(비신뢰) 패널 config에 **공유 ephemeral `WKWebsiteDataStore.nonPersistent()`**(`MaruWebPanelView.browserDataStore`) — 쿠키·localStorage·캐시 비영속(종료 시 소멸) + 신뢰 콘텐츠(maru-app://, 기본 persistent store)와 격리(§7 untrusted 격리). browser 탭들끼리는 공유(브라우저 세션 시맨틱). 스킴 핸들러·브리지는 미등록(신뢰 전용) 유지. smoke: `web_panel_data_store_persistent`=browser false·trusted true. **WKProcessPool은 최신 WebKit서 자동 관리(deprecated)라 명시 안 함.** 스킴 화이트리스트(http/https 허용·file:/javascript: 차단)는 실제 URL 로드가 생기는 **7e-2 navigate 경로(Zig 정책)**에.
  - **7e-1(nav 상태 ABI + 읽기전용 주소창)** — 둘로 분리:
    - **7e-1a(nav 상태 파이프라인 — 구현 완료)**: `MaruWebPanelView`가 browser(panelKind==1) 패널만 WKWebView `url`/`canGoBack`/`canGoForward`를 **block-based KVO**로 관측 → 값 저장 + dirty → tick drain(`drainWebSurfaceTransition` 끝)이 dirty만 `maru_macos_app_session_set_web_nav_state`(ABI v104)로 Zig에 push. Zig `AppSession.web_nav_states`(surface_id → `WebNavState{can_go_back, can_go_forward, url}`, url gpa 소유)에 upsert 저장하고, `collectWebSurfaces`가 매 tick 활성 탭 web 집합에 없는 키를 prune(닫힘/이동 stale url 회수). getter `web_nav_url_at`. 헤드리스 단위 테스트(upsert·옛 url free·빈 url·없는 surface) + smoke 왕복(`web_nav_url_swift`/`web_nav_url_zig`=5d fixture data: URL). 소비는 7e-1b.
    - **7e-1b(읽기전용 주소창 밴드 렌더 — 구현 완료)**: browser web Term의 `collectWebSurfaces` `inset.top`을 `bar_h + addr_h`(addr_h=`paneBarHeightPx()`, 단일 소스)로 늘려 WKWebView 본문을 탭 바+주소창 밴드 아래로 내리고, 탭 바 collect 루프(app_session.zig ~15189 "1c")가 pane의 **활성 탭이 browser web Term일 때** 밴드 `[full.y+bar_h, +2·bar_h]`(웹뷰 top과 정확히 abut)에 배경 quad(`appendBarBgQuad`, 탭 바와 같은 sidebarBg) + URL 셀(`buildPaneAddressBarDrawList` — `buildPaneLabelDrawList` 미러, `.head` 앵커, muted fg)을 그린다. URL은 7e-1a `webNavState(surfaceId).url`(없으면 빈 밴드). **셀 정렬 텍스트**(quad 금지). markdown/터미널 탭은 밴드 없음(byte-identical). 헤드리스 단위 테스트(`buildPaneAddressBarDrawList`) + seam-inset 테스트를 panel-kind aware로 갱신 + 오프스크린 스크린샷(밴드가 탭 바 아래 렌더 — chrome이라 캡처됨). **버튼은 7e-3, 편집은 7e-2**.
  - **7e-2(편집 모드 = 브라우징)** — 둘로 분리:
    - **7e-2a(Zig 편집 코어 — 구현 완료)**: 스킴 정책 `app_scheme.resolveNavUrl`(L2 순수 — "://" 있으면 http/https만 허용·나머지 거부, 없으면 https 프리픽스, 위험 스킴 무해화). `AppSession.addr_edit`(편집 중 surface_id, 한 번에 하나) + **텍스트 입력은 find/palette/rename과 같은 공유 `OverlayInput`(`addr_input`) 재사용**(query/preedit[IME 조합]·EAW 단일 출처 — 별도 버퍼 재구현 안 함, DRY; **단 `OverlayInput`은 끝-caret 전용이라 mid-string caret·선택·가로 스크롤은 미소유**[표시 caret·가로 스크롤은 coretext `appendEllipsizedTitle` tail 앵커 소산] — 그 편집 모델은 [text-field-editor.md]의 `TextField`로 이관) + `enterAddrEdit`/`commitAddrEdit`(→navigate pending·세션 소유 url_buf)/`cancelAddrEdit`/`dropAddrEditIfSurface`(destroyTerm teardown). 클릭 라우팅(mouse-down에서 밴드 rect hit-test=7e-1b band, browser 활성탭만 → enterAddrEdit + focus-pull pending). keyDown 라우팅(`handleKeyEvent`에서 rename 인터셉트처럼 addr_edit 활성이면 `handleAddrEditKey`로 모든 키 소비: char→append·backspace·Enter=commit·Esc=cancel). 렌더 "1c"가 편집 중이면 query+preedit(조합 중 한글 표시) + block caret(셀 정렬)·tail 앵커. IME 조합은 `inputFocus`에 `.addr_edit` 추가로 `imeSetPreedit`/`commitComposition`이 addr_input에 라우팅(find/palette 동형 — 조합 중 글자가 밴드에 보임). 신호 getter 3개(`takeWebAddrFocusPull`/`takeWebAddrNavigate`/`takeWebAddrFocusRestore`, 1회성). 헤드리스 테스트(resolveNavUrl adversarial·AddrEdit 흐름·commit/cancel/teardown·caret). **ABI·Swift 무변경**(이 슬라이스는 상태·정책·라우팅·렌더까지).
    - **7e-2b(Swift 포커스 전이 + navigate 배선 — 구현 완료)**: 신호 getter 3개의 ABI export(`take_web_addr_focus_pull`/`take_web_addr_navigate`/`take_web_addr_focus_restore`, v105) + Swift tick drain(`drainWebSurfaceTransition` 끝): focus-pull→`focusTerminalView`(편집 keyDown이 Zig로), navigate→`BrowserControl.navigate`(5d, webPanels[surface_id].webView), focus-restore→`makeFirstResponder(webView)`. 편집 진입은 밴드 클릭이 터미널 뷰를 firstResponder로 만들고 focus-pull이 확정, 커밋/취소 후 웹뷰 복귀. reconcile은 모달 엣지에서만 동작해 편집 중 비간섭. **여기서 실제 브라우징 동작**(주소창 클릭→URL 타이핑→Enter→로드→KVO가 새 URL을 주소창에 반영). IME preedit(url-edit 타깃)·caret 이동은 후속. **GUI 손 테스트 필수**(포커스 전이·타이핑·로드는 스모크 밖).
  - **7e-3(nav 버튼 back/forward/reload — 구현 완료)**: 주소창 밴드 좌측 [0, nav_end) 셀에 `←`(back)·`→`(forward)·`⟳`(reload) 버튼(각 `nav_button_w`=3칸, 존 가운데 글리프). **NavBarMetrics 단일 소스**를 렌더(coretext `buildPaneAddressBarDrawList`)와 hit-test(`navButtonAt`)가 공유 → 보이는 버튼 == 클릭되는 버튼. URL은 `[nav_end, cols-1)`로 밀려 안 겹침. 활성: back=`webNavState.can_go_back`·forward=`can_go_forward`·reload=항상(비활성=dim·클릭 no-op). 클릭 ①b가 버튼 존이면 활성 버튼만 `web_nav_action_pending`(surface_id+code), URL 존이면 enterAddrEdit. C-ABI `take_web_nav_action`(v106) → Swift drain → `BrowserControl.goBack/goForward/reload`. 헤드리스 테스트 + 스크린샷(3버튼·back/forward dim·reload 밝음). **GUI 손 테스트**: 버튼 클릭→실 뒤로/앞으로/새로고침.
  - **7e-4(nav 버튼 폴리시 + 키보드 단축키 — 구현 완료)**: hover 커서(밴드 nav 버튼 위 pointingHand, `navButtonHoverAt`)·hover 하이라이트(`hovered_nav_button` → **활성** 버튼 3칸 존 배경 quad)·키보드 단축키 `⌘←`(back)·`⌘→`(forward)·`⌘R`(reload). 단축키 게이트는 **활성 pane의 browser 탭**(신규 getter `activeWebSurfaceId` == 이 패널 surface_id, ABI v108)이라 **WKWebView 키보드 포커스 유무와 무관**하다 — 브라우저 탭을 활성화해도 webView에 자동 포커스를 안 주므로 `isWebPanelFocused`만 보면 "탭 열어 보기만 하면 ⌘R 안 됨" 버그가 난다(제보). R은 레이아웃 무관 keyCode 15로 판정. 클릭 ①b·키보드가 `setBrowserNavAction`(활성 판정: back=`can_go_back`·forward=`can_go_forward`·reload=항상) 단일 정책을 공유한다. **동반 수정 3건(GUI 손 테스트 전용 — AppKit firstResponder·hover·키 이벤트라 헤드리스 불가)**: (a) 링크 이동 시 주소 미갱신 → `setWebNavState`가 **값이 실제 바뀐 tick에만 `metal_dirty`**(url·can_go_* 비교)로 주소창 재렌더; (b) **모달 최상위** — browser 패널을 보던 중 `⌘Q` 종료 모달이 Enter로 안 닫히던 것: maru 모달은 Zig가 오버레이 레이어에 그려 시각적으론 최상위지만 입력은 터미널 뷰→`handleKeyEvent` 경로라, WKWebView가 firstResponder를 쥐면 Enter/Esc가 WebKit으로 샌다 → `reconcileWebModalFocus`를 **열림 엣지 전용에서 self-heal로**(모달 열린 내내 firstResponder≠터미널 뷰면 되돌림, `isWebPanelFocused` 탐지에 안 기댐) + `applicationShouldTerminate`가 모달 연 직후 **동기 전이**(⌘Q는 시스템 메뉴 경로라 maru keyDown 안 거침).
- **새 창/팝업 (`target=_blank`·`window.open`) — browser kind, 슬라이스 7f (계획)**: WKWebView는 페이지가 새 창을 요청하면 `WKUIDelegate.webView(_:createWebViewWithConfiguration:for:windowFeatures:)`를 **동기 호출**한다(§8 링크 라우팅 `decidePolicyForNavigationAction`은 **같은 뷰 내 top-level 이동**만 — 새 창은 이 **다른 경로**다). 현재 maru엔 `WKUIDelegate`가 없어 새 창이 **무동작**이다(7e 범위 밖 — 단일 패널 브라우징만).

  **결정: adopt(1급 surface화) — '같은 패널 대체' 기각(근거).** 같은 패널에 새 URL을 덮으면 (a) "새창 열고 다시 리턴"이 불가하고, (b) 에이전트가 주소지정할 별도 대상이 없다 → 목표(일반 브라우저 새창 UX **+ 에이전트 제어**)에 미달. → **`createWebViewWith`가 만든 WKWebView를 maru web term/surface로 등록**해, 사용자에겐 새 browser **탭**, 에이전트에겐 `surface_id`로 **addressable**하게 한다. 이 둘을 동시에 주는 유일한 방식이다.

  **베이스(WebKit 계약)**: 넘어온 `configuration`은 발신 webview config의 **복사본**이고, `window.opener`·named-window·`postMessage` 링크가 성립하려면 반환 WKWebView를 **그 config 그대로**(수정 금지) 생성해야 한다. browser 패널 config는 공유 ephemeral `browserDataStore`(7e-0)를 **config 레벨**에 두므로, 팝업 config 복사본이 같은 데이터스토어를 이어받아 **세션·쿠키 공유(OAuth 연속성)** 가 성립한다(검증 완료). 스킴 핸들러는 browser 패널엔 미등록이라 무관.

  **소유·시점 역전(핵심 난점)**: maru 정상 흐름은 *Zig가 term 생성 → tick → Swift가 maru config로 WKWebView lazy 생성*이다. 팝업은 반대 — Swift가 **동기**로 WebKit config webview를 만들어 반환하고, 그걸 Zig 트리에 **사후 등록(adopt)** 해야 한다. 따라서 (i) **Swift-first '외부 생성 web term 등록' ABI**(활성 pane 탭에 browser web Term 삽입 + `surface_id` 반환), (ii) `drainWebSurfaceTransition`의 create 전이가 이 surface_id엔 WKWebView를 **중복 생성 안 함**(이미 Swift가 만든 것 존재), (iii) `MaruWebPanelView`의 **adopt init**(주어진 webview 채택 + 인스턴스 설정[`navigationDelegate`·`navObservers`·autoresizing·`seamEdges`] 재적용)이 필요하다.

  **행선지·생애주기·보안**: 새 **탭**에 넣는다(maru는 터미널 — 떠다니는 창이 아니라 탭 모델; `windowFeatures` 크기·위치 힌트는 무시). opener↔팝업 **쌍**은 둘 다 1급 surface라 hide/show(배경 탭)·move(reparent 4e-4)·close가 기존 전이 모델로 처리된다(`isHidden`은 web 프로세스를 안 죽여 opener 유지). 팝업도 untrusted 격리(공유 ephemeral store)·`decidePolicyForNavigationAction` 스킴 화이트리스트를 적용하고, `createWebViewWith` 게이트로 **browser(비신뢰) 패널의 http/https 대상만** 허용한다(신뢰 maru-app UI의 창 생성 차단; user-gesture 없는 팝업은 팝업 차단기처럼 게이트/알림).

  **분해**: **7f-0(Zig: Swift-first web term 등록 ABI — 구현 완료, `create_adopted_web_term` v109·헤드리스: term 삽입·surface_id 발급)** · **7f-1(Swift: `WKUIDelegate.createWebViewWith` → 7f-0 ABI로 term 등록 + adopt init + drain `.create` 멱등[중복 WKWebView 생성 스킵=opener 링크 보존] + 새 탭 활성화 — 구현 완료, GUI 손 테스트 통과: ⌘+클릭·target=_blank·window.open이 새 브라우저 탭으로 열리고 리턴)** · **7f-2(팝업 정책 게이트 — 구현 완료, `popupTargetAllowed` v111: about/http/https/빈만 허용, javascript·file·data·blob·maru-app 거부, adversarial 헤드리스; Swift `createWebViewWith`가 팝업 생성 전 호출)**. **opener/OAuth 검증**: WebKit 계약(`createWebViewWith`에 넘어온 config=부모 복사본 → 그 config로 만든 webview라 `window.opener`·named window·`postMessage` 링크 성립·공유 데이터스토어 승계)으로 **구조적 보장** + 7f-1 GUI 손 테스트(window.open 팝업이 열림 = opener 링크 성립)로 검증. **자동 round-trip 스모크는 보류**: 무-네트워크 스모크 하니스에서 data:/about:blank 팝업의 same-origin(opaque origin) 제약으로 부모↔팝업 postMessage 왕복을 깔끔히 구성하기 어렵다 — 실 OAuth 로그인은 GUI 손 테스트로 확인. WKWebView 팝업 생성·opener·포커스는 스모크 밖이라 GUI 손 테스트로 검증(7e-2b/7e-3 동형; 스크린샷은 WKWebView 픽셀 못 잡음).

  **에이전트 제어와의 연결**: 팝업을 1급 surface(`surface_id`)로 adopt하는 것이 곧 **에이전트가 팝업까지 제어**할 수 있는 전제다 — host-mediated 브라우저 MCP가 각 surface(팝업 adopt 포함)를 `surface_id`로 주소지정한다. 프로토콜 결정·구현 완료 상태·남은 5f 재슬라이싱은 [control-plane.md](control-plane.md) §9.2~§9.5를 **단일 출처**로 따르며, 이 문단에서 진행 상태를 복제하지 않는다. §13의 host-mediated vs Web Inspector 분기도 같은 경계를 따른다.
- **파일 패널(마크다운·HTML 뷰어/편집기 — 전역 도크)**: 로컬 `.md`/`.html`을 여는 파일 패널 — 창 레벨 전역 도크 슬롯(우측|하단), 파일 탭·헤더 밴드·파일 트리 = GPU chrome, 브리지 `file.read/write`, CodeMirror 6 편집 — 은 [file-panel.md](file-panel.md)를 단일 출처로 둔다(워크스페이스 pane 트리 밖이라 §2 destroy 규칙 비대상; §7 브리지 origin 격리·§4 포커스 불변식[도크 축 확장]과 상호작용). 웹 브라우저(`browser` kind)는 이 문서 그대로 워크스페이스 term이며, 전환 시 URL 기억·재로드 완화는 백로그([file-panel.md] §13).
- **배경 정합**: 신뢰 Markdown 파일 패널의 **초기 paint**는 [file-panel.md](file-panel.md) §1 계약대로 생성 시 공개 API `underPageBackgroundColor`와 hash-pinned critical CSS를 함께 써 기본 흰 backing을 노출하지 않는다. 반면 터미널·chrome이 반투명(`window.opacity<1`)인 창에서 임의 browser/로컬 HTML 본문까지 투명화할지는 여전히 별도 결정이다. 그 경우에도 공개 API `underPageBackgroundColor`(macOS 12+)만 쓰고, `drawsBackground`는 비공개 KVC 키라 의존하지 않는다.
- **테마/다크모드 동기화**: 터미널은 `viewDidChangeEffectiveAppearance`로 테마 교체. 웹 패널 콘텐츠(maru-app:// UI)가 maru 테마·다크/라이트를 따르도록 브리지로 CSS 변수/토큰 주입.
- **⌘F 분기**: 포커스가 터미널이면 maru find(스크롤백), 웹 패널이면 페이지 내 find. 포커스 기준 라우팅 명시.
- **컨텍스트 메뉴**: WKWebView 기본 우클릭 메뉴(Inspect Element 포함)는 "chrome는 Zig" 원칙·보안과 충돌 → 억제 또는 maru 메뉴로 대체.
- **접근성(AX)**: WKWebView는 네이티브 AX 트리, 터미널·모달(Metal)은 없음 → 혼합 상태. 마크다운 편집기에 AX 필요.
- **콘텐츠 프로세스 크래시 복구**: `webContentProcessDidTerminate` 시 reload·에러 상태.
- **폰트/줌·인쇄**: 저우선.

## 9. 베이스와 결정 (clean-room)

- WKWebView 임베드·isolated `WKContentWorld`·`WKURLSchemeHandler`는 WebKit 표준 API. CSP·새니타이즈는 웹 보안 표준.
- 모달 오버레이 z-order는 CALayer 합성 + `hitTest` 라우팅 표준.
- **`maru-app://` 스킴 이름 확정 (근거)**: 베이스는 URI 문법 표준 [RFC 3986](https://www.rfc-editor.org/rfc/rfc3986#section-3.1) §3.1로, `scheme = ALPHA *( ALPHA / DIGIT / "+" / "-" / "." )`이다. 즉 하이픈(`-`)은 스킴 이름의 유효 문자이고(첫 글자만 `ALPHA` 강제), `maru-app`은 이 문법을 만족한다. `WKURLSchemeHandler`(`WKWebViewConfiguration.setURLSchemeHandler(_:forURLScheme:)`)는 built-in/특수 스킴(`http`·`https`·`file`·`about`·`data`·`blob`·`ws`·`wss` 등)에 대한 커스텀 핸들러 등록만 예외로 거부하므로, 커스텀 스킴 `maru-app`은 등록 가능하다. 스킴은 대소문자를 구분하지 않고 WebKit이 소문자로 정규화하므로 코드·CSP·핸들러 문자열은 전부 소문자 `maru-app`으로 고정한다(하이픈은 CSP source expression `maru-app:`에서도 유효). 결정: `maruapp`(하이픈 제거)이나 역-DNS(`app.maru`)로 바꾸지 않고 `maru-app://` 그대로 확정한다 — 사람이 읽을 때 maru 앱 내부 스킴임이 분명하고, 단일 라벨 커스텀 스킴이라 충돌 위험도 없다.
- maru 독립 설계: 모달을 Metal 오버레이로(GPU chrome 일관성), surface 생애주기 ABI, web 특유 보안 게이트.

## 10. 구현 ([control-plane.md] Phase 4~5와 연계)

- **Phase 4(껍데기)**: 컨테이너 contentView + 입력 responder 재편(§4) + 모달 레이어 분리 두 리팩터(§2) + surface 생애주기 ABI(§6) + per-pane rect(§3) + 빈 WKWebView가 본문 rect 추종. 착수 전 M0 ID/scope foundation이 완료됐고 `WindowGraph`/`LiveSurfaceRegistry`가 surface 생애주기 단일 출처인지 확인한다. → [control-plane.md] §11 Phase 4가 이 규모(특히 모달 분리·입력 재편)를 포함하도록 정합.
- **Phase 5(브리지)**: isolated world 브리지 + `maru-app://` 스킴 + CSP + 경로 샌드박스 + [control-plane.md] `browser.*`·§8.1 게이트 연결. (마크다운 sanitizer adversarial fixture는 마크다운 콘텐츠가 생기는 [control-plane.md] Phase 7와 함께 — §11. WebDriver 어댑터는 첫 콘텐츠의 필수 선행이 아니며, 기본 E2E는 `evaluateJavaScript` 하니스로 먼저 닫는다.)

Phase 4~5도 한 PR로 밀어 넣지 않는다. [control-plane.md] §11의 micro-slice를 따른다:
- 4a: rect/surface lifecycle ABI를 순수 계산 테스트로 먼저 고정한다. **(구현 완료 — `src/session/web_panel_layout.zig`: `contentRect`·`pxTopLeftToPtBottomLeft`·`surfaceDiff`, 헤드리스 TDD·§14.)**
- 4b: 모달 renderer 2-pass와 overlay layer 계약을 웹뷰 없이 먼저 고정한다.
- 4c: 빈 WKWebView를 붙이고 frame/NSView 계층 값 단언 + GUI z-order artifact로 닫는다. **(구현 완료 — 최소 범위)**: 라이브
  web-Term 모델(트리·탭 혼합·재부모화)은 후속으로 미루고, **활성 pane 본문에 바인딩된 단일 빈 WKWebView**를 hosting 증명으로
  붙였다(app_session에 `web_panel` 필드 하나, split/Term 트리 미진입). 생성 경로는 디버그 env 훅 `MARU_WEB_PANEL=1`(kind는
  `MARU_WEB_PANEL_MARKDOWN=1`이면 markdown, 기본 browser — 4c 빈 웹뷰라 시각 무영향). 매 tick 4a 세 순수함수(`contentRect`·
  `pxTopLeftToPtBottomLeft`·`surfaceDiff`)를 **Zig가 전부 소비**해 단일 전이(none/create/destroy/reframe/hide/show)를 계산하고
  ABI(`maru_macos_app_session_web_surface_transition`, v99)로 export하면, Swift가 그 op만 기계적으로 적용한다. 웹뷰는 컨테이너
  z-order **중간**(터미널<웹뷰<오버레이)에 삽입되고 본문 rect(pt·좌하단)를 추종한다. **입력 통과(4d 전)**: 웹뷰를 hitTest→nil
  래퍼 NSView(`MaruWebPanelView`)로 감싸 마우스가 아래 터미널로 통과하고 빈 웹뷰가 firstResponder를 훔치지 않는다(WKWebView
  서브클래스 override 대신 검증된 래퍼 메커니즘 — MaruMetalOverlayView와 동일). §3 드래그 중 hide는 4c 생략(빈 페이지라 jitter
  무해 — 후속). 콘텐츠·URL·브리지·스킴 핸들러·CSP·데이터스토어 격리는 **Phase 5**, IME/firstResponder 전이는 4d. 자동 검증:
  ABI struct 계약 테스트(size/offset·op enum 값) + 4a 순수 계산 단위 테스트 + macos-app-smoke의 `web_panel_subview_order_ok`/
  `web_panel_present`/`web_panel_hittest_in_web`(4d가 4c의 `_nil`을 focusable 전환하며 rename·의미 반전 — 웹 자손을 돌려주는가)
  값 단언(스모크 scripted resize가 **실 창 콘텐츠 크기**를 보내므로 web 패널 frame이 창 안에 정확히 맞는다 — 예전 하드코딩
  1200×720 resize는 창 960×600과 불일치해 web 패널이 창 밖으로 삐져나왔다[런치 시 크기 안 맞음], `sendSmokeDevEvents`가
  `resizeAppSessionFromWindow`를 쓰도록 수정. 픽셀 합성·입력 통과의 최종 눈 확인은 여전히 GUI 손 테스트가 닫는다).
- 4d: responder/IME/drag는 착수 전 spike artifact를 남기고, 확인된 최소 계약만 자동 회귀로 고정한다. **(입력 responder 전이 spike 구현 완료 — 최소 범위, ABI 무변경·Swift 전용)**: 4c의 hitTest→nil 완전 통과를
  **focusable**로 전환하고(모달 닫힘=`super.hitTest`로 웹뷰가 클릭 받아 WKWebView firstResponder→WebKit 자체 IME; 모달
  열림=`nil`로 아래 터미널 통과), **maru 키바인딩 가로채기 = `performKeyEquivalent` override**(웹 포커스 중 Cmd-조합
  중에서도 **maru 앱 바인딩(app_action)인 것만** 가로채 `handleKeyDown`→Zig resolver로 라우팅한다 — ⌘T·⌘W·⌘1-9·⌘⇧P·⌘F·
  ⌘,·⌘A·⌘K 등. 앱 바인딩이 **아닌** Cmd-조합은 `return false`로 **메뉴바 keyEquivalent → WebKit**에 양보한다: ⌘Q 종료·
  ⌘H 숨김·⌘M 최소화(메뉴 전용) + ⌘C/⌘V(WebKit 편집) + ⌘Backspace/←/→(terminal 매크로). app_action 판정은
  `maru_macos_app_session_key_is_app_action`(v100)가 **handleKeyEvent와 같은 `keyBindingResolver`를 side-effect 없이 조회** —
  셸은 포커스가 아니므로 어느 것도 셸로 라우팅하지 않고, terminal 매크로 Cmd 조합도 write 전에 걸러 셸로 새지 않는다.
  옛 spike는 **모든** Cmd 조합을 가로채 셸로 흘려 ⌘Q가 종료 안 되고 키보드가 갇혔었다[code-review 4c/4d]. 웹 포커스가
  아니면 무동작이라 터미널 IME/keyDown 경로 무회귀 — §4 spike 확정 근거). **모달 responder 전이**는
  `reconcileWebModalFocus`가 `anyOverlayOpen` 엣지로 조정한다(웹 포커스 중
  모달 열림→터미널 뷰로 makeFirstResponder, 닫힘→직전 웹뷰 복원; 전이는 기존 becomeFirstResponder/resignFirstResponder를
  그대로 태워 새 IME 로직 0). 전부 **MARU_WEB_PANEL 훅 뒤**(웹 패널 없으면 무동작)라 평시 터미널 빌드 동작 불변. 자동
  검증: swift-check·macos-app-build·macos-app-smoke(`web_panel_focused=false` — 웹이 firstResponder 안 훔침)·ABI 계약
  테스트·zig test·check-boundaries·fmt green. **실 포커스 전이·한글 preedit 라우팅·복원·기존 터미널 IME 무회귀는 GUI 손
  테스트가 닫는다**(§11 수동 gate — 자동 불가). 웹 소유 키 포커스-분기(§8)·드래그 통과(§5)·web-Term lifecycle 포커스는 후속.
  **알려진 한계(4c/4d 오버레이 focusable)**: 4c 웹 패널은 활성 pane에 얹힌 빈 `about:blank` 오버레이라, 클릭해 웹을 포커스한
  뒤 평문 타이핑은 빈 페이지로 들어가고(셸 아님) 그 상태에서 키보드만으로 터미널에 곧장 되돌아갈 전용 키는 없다. 단
  ⌘-nav(⌘1-9·⌘T·⌘⇧P 등 app_action)와 다른 창/탭 클릭은 위 `performKeyEquivalent` 앱-바인딩 가로채기로 **작동**하므로
  포커스 전환으로 복귀 가능하다. 이 한계는 web surface를 Term(탭)으로 만들어 포커스가 터미널/웹 Term을 오가게 하는 **4e가
  근본 해소**한다(빈 오버레이가 아니라 first-class surface).
- 4e(웹 Term 통합 — 4c "후속"의 명시 슬라이스, §6): 4c는 web 패널을 활성 pane에 얹은 **디버그 오버레이**라 가려진 터미널이 뒤에서 계속 렌더된다(낭비·못 씀). 4e는 §6대로 **web surface를 Term(탭)으로 split/Term 트리에 넣어**(활성 Term만 렌더 → 터미널 대체, per-pane 탭바가 terminal/web Term을 같이 보임, Term 탭 재부모화) **first-class surface**로 만든다. **순서 권장**: 콘텐츠(Phase 5)를 오버레이 위에 쌓기 전에 4e로 surface 모델을 먼저 확정하는 게 낫다([control-plane.md] §11 "나중에 소유권 갈아엎기 회피" 정신) — 단 Phase 5 bridge는 per-WKWebView라 4e와 강결합은 아니어서 순서는 유연하다. 생성 경로도 4c의 env 훅에서 **메뉴/command로 승격**(웹 Term 열기)한다.

  **결정된 실행 순서(2026-07-10, 사용자 승인)**: `4e-1·4e-2·4e-3(완료)` → **`4e-5`(생성 command화, 다음)** → **`Phase 5`(콘텐츠)** → **`4e-4`(재부모화, Phase 5 콘텐츠와 함께)**. 근거: ⑴ 4e-5(생성 command화)는 지금 바로 실사용 가치가 있다(env 훅 없이 사용자가 웹 탭을 여는 게 "실사용 가능"의 전제). ⑵ 4e-4(재부모화)의 이득은 **창 간 이동 시 WKWebView 상태 보존**인데, 이는 실제 웹 콘텐츠가 있어야 관찰·검증된다 — 지금 빈 흰 페이지론 destroy+recreate해도 잃을 상태가 없어 회귀 테스트가 vacuous(리로드해도 같은 흰 페이지). 따라서 Phase 5 콘텐츠 후에 하는 게 non-vacuous. ⑶ 이 미룸은 계획 이탈이 아니다 — 계획서가 "**reparent UX는 Phase 4 이후에 따라와도 된다**"(§ "웹 패널 전에 필요한 이동성 foundation만")·"**순서는 유연하다**"(위)라고 이미 명시했고, 반드시 선행이어야 할 것은 UX가 아니라 소유권 토대(`WindowGraph`/`LiveSurfaceRegistry`, [control-plane.md] §11 Phase 4)인데 그건 M0~M3에서 완료됐다. ⑷ 창 **안** pane↔pane 이동은 4e-3의 reframe이 이미 처리한다(같은 컨테이너라 WKWebView가 새 pane rect로 따라감·상태 보존) — 4e-4가 남긴 건 **창 간** 이동 상태 보존뿐이다.
  - **4e-1(웹 Term 모델 토대 — 구현 완료, 렌더·WKWebView·ABI 무변경 = 터미널 byte-identical)**: `session_model.Term`에 `kind: SurfaceKind = .terminal`(기본값이라 terminal Term 생성부 무변경) + `web_panel_kind: PanelKind`(web 라벨·후속 trust 단일 출처) + `surfaceId()`/`webPanelLabel()` accessor를 더하고, `LiveSurface`를 `union(SurfaceKind)`(terminal arm=M3a 번들 그대로, web arm=**sentinel surface**만 — 빈 1×1 core, 렌더/PTY 없음)로 승격했다. 두 arm이 모두 `surface: Surface`를 노출해 `Term.surface: *Surface`가 web에서도 유효 → surface_ptrs 재바인딩·`activeSurface()` 계약 **불변**(sentinel `id`가 web surface_id). `createWebTerm(panel_kind)`가 web Term을 만들고(PTY spawn·attach·pump 없음), `destroyTerm`/deinit이 `kind`로 teardown 분기(web=경량 registry.remove). 4c의 `maybeDebugOpenWebPanel`(MARU_WEB_PANEL 훅)은 오버레이(app_session.web_panel — dormant화) 대신 활성 pane에 web Term을 **비활성 탭**으로 append한다(활성은 터미널 유지 = 무회귀; 활성 전환·렌더 skip은 4e-2). 헤드리스 TDD: `Model(FakeRt)` 혼합 Pane·surfaceId/webPanelLabel 분기, `LiveSurface` web arm sentinel teardown 누수 0. **범위 밖**: 활성 Term 렌더 skip(4e-2)·per-Term WKWebView(4e-3)·탭 혼합 UX/재부모화(4e-4)·command 생성(4e-5).
  - **4e-2(활성 web Term 렌더 skip — 구현 완료)**: 활성 render·입력 경로(readActiveSnapshot·shapeOnlyBuild·cell_colors·kitty·find·terminal_bg 등)를 `activeTermIsTerminal()`/`activeTerminalSurface()`로 gate해 활성 web은 sentinel core를 만지지 않게 하고(본문 blank·no-terminal-frame·크래시 0), `maybeDebugOpenWebPanel`이 web Term을 `focusTerm`으로 **활성화**한다(터미널을 대체 — 4c의 낭비 오버레이 제거). web Term 없으면 항상 terminal 취급이라 byte-identical.
  - **4e-3(per-Term WKWebView 호스팅 — 구현 완료)**: `computeWebSurfaceTransitions`(app_session.zig)가 활성 워크스페이스 탭 pane 트리를 walk해 web Term마다 `SurfaceLayout{surface_id, panel_kind, **자기 pane 본문 rect**(contentRect(leaf, {top=탭 바})), visible=자기 pane 활성 탭인가}`을 만들고 직전 tick 집합(`web_panel_prev`)과 4a `surfaceDiff`한 뒤 **batch**로 marshaling한다(4c의 단일 op·활성 pane 추종을 완전 대체 — 각 웹뷰가 자기 pane에 고정). ABI는 단일 op → **count+at**(command_catalog 선례): `maru_macos_app_session_web_surface_transitions_count` + `..._transition_at(index)`, `WebSurfaceTransitionAbi`에 `visible`(create 시 hidden 생성 여부) 추가, **v101**. Swift는 `TerminalSurface.webPanels: [UInt64: MaruWebPanelView]` dict에 batch op을 적용하고(create=insert+인라인 흰 HTML·isHidden=!visible / destroy=remove / reframe=frame / hide·show=isHidden), 4d 입력 전이(`reconcileWebModalFocus`·`surfaceOwning`)를 dict로 재배선한다. 비활성 워크스페이스 탭 web Term은 집합 밖이라 destroy(§6 "destroy 또는 미포함"). 자동 검증: ABI 계약 테스트(visible offset·op enum) + per-Term batch 헤드리스 test(walk·visible·prev 전진) + macos-app-smoke(`web_panel_present`/`_count`/`_subview_order_ok`, MARU_WEB_PANEL). **흰 화면 시각·split 제자리 고정·z-order·IME 무회귀는 GUI 손 테스트**(§11 — WKWebView는 Metal 스크린샷 밖). placeholder는 `about:blank`가 아니라 **인라인 흰 HTML**을 로드한다 — WKWebView가 배경 미지정 문서(about:blank)를 시스템 appearance로 렌더해 macOS 다크 모드에선 다크가 되어 아래 다크 터미널과 구분되지 않기 때문(명시 흰 배경 CSS로 appearance 무관 흰 rect 보장; Phase 5 실콘텐츠가 이 load를 대체). **범위 밖**: Term 이동 재부모화(4e-4)·command 생성(4e-5)·콘텐츠/브리지/CSP(Phase 5).
  - **4e-5(생성 command화 — 구현 완료)**: 4c/4e의 디버그 env 훅 `MARU_WEB_PANEL`(`maybeDebugOpenWebPanel`)을 **사용자가 부르는 command/메뉴로 승격**한다. 새 액션 `new_web_tab`(`config/action.zig`)이 `newWebTermInActivePane`(`newTermInActivePane` 미러 — `createWebTerm(.browser)` → `pane.terms.append` → `focusTerm`, PTY 없음)을 실행한다(env 훅과 같은 3단계지만 트리거가 사용자·`tabsBlocked()` 가드). command 카탈로그(`command_catalog.zig` `.{ .action = .new_web_tab, .key = "new_web_tab", .title = "New Browser Tab" }`)·메뉴바(`buildMainMenu`의 File 메뉴 `catalogMenuItem("new_web_tab", catalog)`)에 배선한다. 기본 키바인딩은 **⌘⌥T**(⌘T=new_term의 web 버전, ⌥로 구분 — ⌘⇧T=new_tab 워크스페이스와도 구분; ⌘⌥G/⌘⌥] 선례와 동형. 발견성은 메뉴·커맨드 팔릿에도). `panel_kind`는 `.browser`(markdown kind는 후속 — 링크 클릭 라우팅이 생길 때). **게이트 정정(핵심)**: 4e-3의 Swift `drainWebSurfaceTransition` 게이트는 `webPanelHookEnabled`(env-only 상수)라 command 생성 web Term을 못 그린다. `computeWebSurfaceTransitions`는 web Term 0개여도 매 tick `activeTabLeafRects` 등을 **할당**하므로(code-review [8] 최적화 대상) 게이트를 그냥 제거하면 안 된다. 대신 **`FrameSummary`에 `web_surfaces_present: u32` 추가**(매 tick 폴링 구조체라 추가 FFI 0, quit_decision 뒤 4B tail padding을 채워 struct size 176 불변·offset 대조) → Swift 게이트를 `surface.latestFrameSummary.web_surfaces_present != 0 || !surface.webPanels.isEmpty`(존재 신호 + teardown 지속)로 바꾼다. **신호 출처는 유지 카운터가 아니라 활성 워크스페이스 탭 트리 파생**(`activeTabHasWebTerm` = `split_tree.anyLeaf`로 활성 탭 leaf에 web Term이 있는지 alloc-free 계산): 유지 카운터(`createWebTerm`+1/`destroyTerm`−1)는 **창 간 이동**(`moveWorkspaceToSession`=`detachTabForMove`/`adoptTab`이 web Term을 destroy/create 없이 **포인터 relocate**)에서 원본 stuck-high·대상 stuck-0으로 드리프트해 이동한 web 패널이 대상 창에 안 뜬다(4e-3 env-gate엔 없던 회귀). tree-derived 신호는 `collectWebSurfaces`(활성 탭만 walk)와 **같은 범위**라 이동·재부모화·닫기에 자동 정합한다. 헤드리스 검증: `new_web_tab` dispatch → 활성 pane에 web Term append+활성화(4e-1/2/3 경로 재사용)·`parseAction` 왕복·`activeTabHasWebTerm`/`web_surfaces_present` **활성-탭 신호 test(web Term을 비활성 탭으로 전환하면 off — 카운터로는 불가능)** + `anyLeaf` split_tree 단위 test + ABI 계약(FrameSummary size v102) + macos-app-smoke web 계층 단언(env 없이 command로도 부착). **GUI 손 테스트**: File 메뉴/팔레트로 브라우저 탭이 열리고 흰 화면(4e-3 픽스)·`⌘⌥[`로 터미널 복귀. **범위 밖**: 재부모화(4e-4)·콘텐츠(Phase 5).
  - **4e-4(창 간 이동 재부모화 — 구현 착수 2026-07-15, 실콘텐츠 전제 충족)**: 웹 Term을 **다른 창**으로 옮길 때 기존 WKWebView를 원본 컨테이너에서 대상 창 컨테이너로 **재부모화(NSView 이동)해 상태(스크롤·로드된 페이지·폼)를 보존**한다. 현재(4e-3)는 원본 세션 `collectWebSurfaces`가 그 web Term을 더는 못 봐 destroy + 대상 세션이 create = **파괴·재생성(상태 손실)**. 창 **안** pane↔pane 이동은 이미 4e-3 reframe이 상태 보존한다(같은 컨테이너). **전제 충족**: 7e 주소창 + `browser.navigate`로 실 URL을 로드하므로 이제 이동 전후 상태 동일성이 non-vacuous하게 관찰된다(옛 "Phase 5 콘텐츠와 함께" 미룸의 vacuous 근거 해소). 재부모화 identity는 M6 spike에서 실증됨(`union(SurfaceKind)` LiveSurface 채택 근거).

    **구현(컨트롤러 조율 재부모화 — 사용자 승인 2026-07-15)**: WKWebView는 Swift/AppKit 객체라 단일 `MaruAppHostController`가 모든 창(`TerminalSurface.webPanels` 창별 dict)을 전역 소유한다. 이 컨트롤러가 창 간 이동을 조율한다 — **§8A.1 AppRuntime registry lift(Zig 소유 구조 이관)는 직교·불필요**(올바른 재부모화엔 컨트롤러 조율로 충분, band-aid 아님; registry lift는 별개 구조 후속). destroy+recreate의 원인은 per-window 독립 tick이 각자 dict에 create/destroy를 적용하는 것이므로, drain을 **재부모화-aware**로 만든다:
    - **`create` X(대상 창 W)**: X의 WKWebView가 **다른 창에 이미 살아있으면**(`surfaceOwning(byId:)` 전역 스캔) → **훔쳐 재부모화**(removeFromSuperview → 원본 dict 제거 → W 컨테이너 `insertWebPanel` → W dict 등록 → reframe). 없으면 fresh 생성. fresh 뷰가 아니라 **같은 뷰 재사용**이라 상태 보존.
    - **`destroy` X(원본 창 W)**: X가 **다른 창 모델에 여전히 live면**(신규 ABI `has_web_surface`) → 이동이므로 그 **대상 창 dict로 이관**(`reparentWebPanelToOwningWindow` — removeFromSuperview + 대상 dict 등록·원본 dict 제거, 파괴·`browser.closed` 억제; 대상의 후속 create/show가 adopt 브랜치로 컨테이너 insert). 아니면 진짜 close(파괴 + `browser.closed`).
    - **경로별 정합·창 닫힘 안전(코드리뷰 [1] HIGH 정정)**: **① `Move Workspace to Window`**(활성 워크스페이스, 원본 창 유지) — `adoptTab`이 대상서 그 워크스페이스를 **활성**으로 세우므로 `finishCrossWindowMove`의 대상 창 renderTick이 create를 내고 **create-steal**(`detachWebPanelForReparent`)로 재부모화, 원본 destroy는 dict에 X 없어 no-op. **② `Merge Window`**(전 워크스페이스, 원본 창 닫힘) — 대상은 자기 활성 워크스페이스를 유지해 옮긴 것들이 **비활성 탭으로 착지 → create 안 뜸 → steal 미발생**이다(초판이 "create-steal이 처리"라 본 오판); 그래서 원본 창 close의 `teardownWebPanels`가 파괴 대신 **이관**(`reparentWebPanelToOwningWindow`)해 상태를 보존한다. `moveWorkspaceToSession`이 `*Tab`을 **동기 relocate**하므로 두 경로 모두 `has_web_surface`가 이동을 정확히 판정. **destroy move-out**(이관)은 create가 먼저 안 도는 미래 경로(drag M5)용 **순서 독립 안전장치**(원본 park 아니라 대상 이관이라 nav-state 오라우팅 없음 — 코드리뷰 [2]).
    - **재적용 최소**: 재부모화는 **같은 view**라 `controller`·`navObservers`·`navigationDelegate`·autoresizing 불변, `seamEdges`/frame은 reframe 전이가 갱신.

    **신규 ABI**: `maru_macos_app_session_has_web_surface(session, surface_id)`(그 세션 트리에 그 web surface_id가 존재하는지 — additive export → 버전 불변). 헤드리스 유닛으로 존재/부재 판정.

    **검증**: 재부모화·상태 보존·z-order·focus·IME는 **GUI 손 테스트 전용**(WKWebView 상태·NSView 컨테이너는 헤드리스 밖 — §11): 브라우저 탭에서 실 페이지 로드→스크롤/폼 입력→"Move Workspace to Window"로 다른 창 이동→**같은 스크롤·폼·페이지 유지** + 이동 시 spurious `browser.closed` 없음. 헤드리스: `has_web_surface` ABI + 이동 판정 로직. 단일 출처 [window-surface-mobility.md] M6 WKWebView reparent.
- 5a~5d: `browser.*` schema/authz, isolated bridge, `maru-app://` security, minimal browser ops를 각각 별도 red test로 시작한다.
- 7e(browser chrome UI — §8): `browser` kind용 **주소창 + back/forward/reload** nav chrome. WKWebView가 nav 함수(`goBack`/`goForward`/`reload`/`load`/`canGoBack`)를 공짜로 주므로 **UI 껍데기만** 만든다(mechanics=WebKit). GPU 셀(탭바처럼 Zig 렌더), 버튼→ABI→WKWebView API. **주소창 2모드**: ① 비활성=현재 URL 표시만 ② 편집=URL 입력→`load`. 편집 모드의 임의 URL 로드는 §7 보안(untrusted 격리·링크 라우팅)이 걸리므로 Phase 5(security) 이후. markdown kind는 주소창 불요라 kind별 분기.

각 slice는 안정성·성능 영향을 같이 닫는다. WKWebView frame sync는 pane rect diff가 있을 때만 수행하고, 매 frame 무조건 `evaluateJavaScript`/snapshot/navigation을 호출하지 않는다. bridge는 bounded message size와 dispatch backpressure를 갖고, `browser.*` 호출은 main tick을 오래 점유하면 chunk/yield 또는 비동기 완료로 분리한다. z-order/IME처럼 wall-clock 성능 숫자가 흔들리는 영역은 frame 값, responder 전이 순서, message count, dropped/coalesced count 같은 결정적 artifact를 남긴다.

코드 배치는 [control-plane.md](control-plane.md) §11의 코드 배치·컨벤션 gate를 따른다. 특히 Swift의 `WKURLSchemeHandler`/`WKWebView` 코드는 WebKit API 어댑터로만 두고, 어떤 URL·파일·origin·capability를 허용할지의 정책 판정은 테스트 가능한 Zig 또는 `web/` 패키지 코드에 둔다. 마크다운 sanitizer는 Phase 7의 웹 콘텐츠 패키지가 Bun test로 소유하며, Swift에 HTML sanitizer나 bridge trust 정책을 넣지 않는다.

## 11. 테스트·검증

- **자동(headless/TDD)**: 브리지 격리(`evaluateJavaScript`로 page-world `window.maru === undefined`), per-pane rect 계산(px↔pt·y-flip) 단위, surface diff 로직, WKWebView frame·NSView 계층 값 단언, CSP·경로 정규화(traversal 거부) 단위를 먼저 실패시키고 구현한다. Phase 7 웹 콘텐츠의 순수 JS/TS 로직은 Bun 내장 test runner(`bun test`, `web:test`)로 검증한다. Phase 6 WebDriver 어댑터가 아직 없으면 WKWebView 통합 E2E는 `evaluateJavaScript` 하니스로 먼저 검증하고, WebDriver가 붙은 뒤 같은 subset을 표준 WebDriver smoke로 반복한다.
- **Phase 4 렌더 사전 gate**: 모달 레이어 분리·overlay layer를 건드리기 전 현재 렌더러 계약이 green인지 먼저 확인한다. 최소 자동 명령은 `mise run test`, `mise run check-boundaries`, `mise run test-macos-coretext-smoke`, `mise run test-macos-metal-smoke`다. display가 있는 macOS에서는 `mise run macos-coretext-smoke`와 `mise run macos-metal-smoke`도 실행해 CoreText draw-list shaper/raster 준비(`renderer_frame_prepared=true`, `drawlist_frame_prepared=true`, `drawlist_glyph_raster_ready=true`)와 제품 Metal atlas path(`product_atlas_uploaded=true`, `product_atlas_sampled=true`, `atlas_sample_missing_cells=0`, `atlas_readback_mismatched_bytes=0`, `screenshot_artifact=true`)를 확인한다. 이 preflight는 자연폭/2-quad/role 기반 cover-fit/atlas sampling의 기존 green 상태를 확인하는 것이고, WKWebView 위 실제 합성·입력은 아래 수동/시각 gate가 별도로 닫는다.
- **Phase 7 markdown sanitizer adversarial fixture**: `.md` 입력은 비신뢰 데이터이므로 raw HTML/script 제거를 단위+웹 콘텐츠 테스트로 고정한다. 최소 red fixture: `<script>`, `onerror`/`onclick`, `javascript:` URL, `<iframe>`/`srcdoc`, 외부 `http(s)` 리소스. 기대값은 "DOM에 실행 가능한 sink가 남지 않고, CSP 위반 없이 안전한 텍스트/허용 태그만 렌더"다.
- **수동/시각**: z-order 픽셀 합성(실제 셀 모달 × 투명 오버레이 × 실콘텐츠 WKWebView)은 **CI 자동 불가**(`CGWindowListCreateImage` macOS 15+ 제거, ScreenCaptureKit은 TCC 권한·GUI 필요) → **GUI 골든 1 frame을 Phase 4 종료 게이트**로 둔다. 골든 시나리오는 WKWebView 본문 위에 모달 오버레이를 띄운 상태에서 Hack `workspace` baseline(텍스트는 fit/center 금지), `①②③` cover-fit, 음수 자간, SGR48/선택/블록 커서 밑 자연폭 글리프, split divider 경계 bleed를 함께 담는다. 골든 캡처 config는 `theme.min-contrast` 값을 명시 고정한다(팔레트 자동 대비 보정이 baseline 색을 드리프트시키지 않게). 이 항목은 [glyph-role-render-model.md](glyph-role-render-model.md)와 [font-strategy.md](font-strategy.md)의 렌더 계약을 Phase 4 합성 리팩터가 깨지지 않았는지 보는 수동 gate다.
- **입력 라우팅**(§4)·**드래그 통과**(§5)는 실기 수동 검증(자동 어려움).

## 12. 리스크

- **입력/firstResponder 재편**(§4)이 가장 깨지기 쉬운 코드(IME 조합)를 건드린다 — Phase 4 선행, 단독 PR.
- 모달 레이어 분리(§2) 두 리팩터의 규모·generation 게이팅.
- 합성 z-order 시각은 CI 자동검증 불가, GUI 골든 수동(§11).
- 이식: WebView2(별도 HWND)·Wayland에서 모달 오버레이 합성 모델이 macOS와 달라 재결정 필요.
- async resize jitter(§3).

## 13. 미래: CEF native webview-backend plugin (이번 범위 밖)

WKWebView(WebKit)는 시스템 프레임워크라 의존성이 없지만 Chromium 호환·CDP 생태계 검증이 제약된다. 미래에 CEF를 대안 백엔드로 둘 수 있으나, 기본 maru는 WKWebView만 써 의존성 0을 유지한다.

**plugin이라는 말의 경계**: 사용자가 원하는 제품 형태는 "기본 앱에 CEF를 넣지 않고 필요할 때 받는 선택 백엔드"다. 이 방향은 맞다. 다만 현재 maru의 일반 plugin/Wasm 경계는 domain event + action facade만 허용하고 renderer/platform/window를 직접 만지지 못하므로 CEF를 표현할 수 없다. CEF는 모달 Metal 오버레이 z-order 조율(renderer)·NSWindow/CefWindow 마운트(platform)·per-pane 좌표(레이아웃)를 요구한다. 따라서 이름은 plugin이어도 **일반 Wasm/action plugin이 아니라 별도 권한의 native webview-backend plugin ABI**가 필요하다.

**백엔드 추상화는 leaky하다(정직).** 인터페이스(`mount`/`navigate`/`eval`/`snapshot`/`frameSync`/`bridge`)가 WKWebView와 CEF의 차이를 다 흡수하지 못한다:
- **z-order가 역전된다.** WKWebView는 contentView subview라 모달 Metal 오버레이가 위로 가지만, CEF는 child NSWindow(CEF Views)라 **모달 위로 떠서 모달을 가린다**. suji가 NSView 직접 합성(17-A)에서 멀티뷰 강종으로 child-window(17-B)로 후퇴한 게 이를 증명한다 — §1의 3겹 z-order는 **WKWebView 전용**이다.
- `frameSync`: subview 좌표(pt) vs **스크린 좌표 + 부모 창 이동/space 추종**. `bridge`: WKContentWorld(동기·격리 프레임워크 강제) vs CEF 렌더 서브프로세스 V8(비동기·격리 수동 구현). `snapshot`: `takeSnapshot` vs 등가 없음. 제어면: in-band vs out-of-band CDP 소켓.

**의존성·배포(suji 선례 기준)**: CEF prebuilt ~120~150MB + helper **4개**, Spotify CDN. 제어는 `remote_debugging_port`(CDP 소켓). suji는 100% **build-time link**(`linkFramework`·`@cImport` comptime, dlopen 없음)이고 CEF 헬퍼는 main entry에서 `cef_execute_process`를 호출하는 구조다.

**다운로드형 전략**: 가능하면 기본 방향이다. 단, 런타임에 upstream CEF zip을 그대로 내려받아 앱 안에 끼워 넣는 방식은 macOS 코드서명·공증·entitlement 때문에 기본값으로 두지 않는다. Maru가 배포하는 **버전별 native backend bundle**이 필요하다: CEF framework, helper app bundle들, Maru adapter dylib/launcher, entitlements, manifest(`cef_version`, `chromium_version`, `maru_backend_abi`, `platform`, `arch`, `sha256`, signature)를 한 단위로 서명·공증한다. 앱은 사용자 opt-in 후 이 번들을 다운로드/검증/캐시/rollback하고, 로드 전 manifest ABI와 코드서명을 확인한다.

**agent-browser/CEF 호환성**: CEF는 `remote_debugging_port`로 Chrome DevTools Protocol endpoint를 열 수 있으므로, 원칙적으로 `agent-browser`의 CDP 계열 backend가 붙을 수 있다. 하지만 "Chrome과 동일하게 전부 호환"이라고 간주하지 않는다. `agent-browser`는 Runtime/Page/DOM/Accessibility/Input/Network/Target/Browser 계열 명령과 screenshot·element query·download·cookie/state 동작을 쓴다. CEF 버전·remote-debugging origin 정책·Target domain 초기화·Accessibility tree·download behavior가 Chrome for Testing과 다를 수 있으므로, CEF native backend plugin을 확정하려면 **agent-browser 명령 subset 호환 spike**를 먼저 통과해야 한다: navigate/evaluate/screenshot/snapshot/find_element/click/send_keys/cookies/download/target lifecycle.

**선택 기준**: 인앱 브라우저 surface가 목표면 Chrome/CDP가 아니라 CEF native backend plugin이 맞다. Maru 창 안의 z-order·pane rect·input focus·modal overlay·lifecycle을 제어해야 하기 때문이다. 반대로 목표가 agent-browser 호환 자동화라면, CEF보다 별도 Chrome for Testing/Chrome 프로세스를 CDP로 띄우는 외부 자동화 경로가 더 단순하고 검증하기 쉽다. 즉 **제품 UI = WKWebView 우선, Chromium 인앱 필요 시 CEF plugin 후보, 외부 자동화 = Chrome for Testing/CDP**로 나눈다.

**사용자 Chrome/CDP 전략**: 인앱 웹 패널 백엔드가 아니라 **외부 브라우저 자동화 어댑터**다. 이 경로의 동작 베이스는 [references.md]의 `agent-browser`다: `agent-browser`는 CDP=Chrome, WebDriver=Safari/iOS 식의 백엔드 추상화와 navigate/evaluate/screenshot/click/find_element 등 명령 표면을 제공한다. 따라서 Maru가 agent-browser 호환을 하려면 (1) WKWebView 패널을 WebDriver 어댑터로 노출하거나([control-plane.md] §9), (2) 별도 Chrome/Chrome for Testing 프로세스를 CDP로 붙이는 외부 자동화 경로를 둔다. 하지만 Google Chrome은 Maru NSView 안에 임베드할 안정 API를 제공하지 않는다. 실행은 별도 Chrome window/headless이고, Maru 패널에는 screenshot/상태를 표시할 수 있을 뿐 실제 WKWebView/CEF 같은 in-app surface가 아니다. 또한 Chrome 136+는 보안상 기본 프로필에 `--remote-debugging-port`/`--remote-debugging-pipe`를 적용하지 않고 별도 `--user-data-dir`을 요구한다. 자동화 목적이면 사용자 일상 Chrome이 아니라 Chrome for Testing 또는 별도 프로필 Chrome을 opt-in으로 띄우는 쪽이 맞다.

**Safari MCP / host-mediated 브라우저 MCP (에이전트 제어 — WKWebView 유지)**: Apple이 Safari MCP 서버(WebKit, [webkit.org/blog/18136](https://webkit.org/blog/18136/introducing-the-safari-mcp-server-for-web-developers/), Safari Technology Preview 247)를 출시했다 — `safaridriver --mcp`로 뜨고 `navigate_to_url`/`evaluate_javascript`/`get_page_content`/`browser_console_messages`/`list_network_requests`/`screenshot`/`browser_dialogs`/`create_tab`·`switch_tab` 등 도구 표면을 준다(§238 agent-browser의 "WebDriver=Safari" 경로에 대응하는 Apple 공식 표면). **단 이건 `safaridriver`(WebDriver) 기반이라 Safari.app 창/탭을 몰지, 서드파티 앱 임베드 WKWebView는 안 잡는다**(임베드 WKWebView 원격 제어는 `isInspectable`+Web Inspector 원격 프로토콜이라는 **다른 채널**). 따라서 maru의 **인앱 브라우저 에이전트 제어**는 Safari MCP를 *쓰는* 게 아니라, **그 tool 표면을 미러링한 자체 host-mediated "브라우저 MCP"** 를 [control-plane.md]에 노출한다: 각 web surface(**7f 팝업 adopt 포함**)를 `surface_id`로 주소지정하고, `evaluateJavaScript`(DOM·click·type·eval·snapshot)·`takeSnapshot`(screenshot)·`WKHTTPCookieStore`(cookies)·주입 JS(console 후킹)·KVO(nav 모니터)·`WKUIDelegate`(dialogs)로 구현한다. network까지 CDP급 깊이가 필요하면 maru WKWebView를 `isInspectable`로 켜고 Web Inspector 원격 프로토콜로 구동한다(**설계 분기**: 얕게=host-mediated JS[network 얕음] vs 깊게=Web Inspector[network 포함, 복잡] — Safari MCP의 존재가 후자가 WKWebView에서 가능함을 방증한다). **default-deny 신뢰 게이트 필수**: 팝업·탭은 임의 untrusted 콘텐츠라, 에이전트 제어는 사용자 브라우징(로그인 세션·OAuth 토큰·폼)을 **읽고 대신 조작**할 수 있어 세션 목록 조회와 차원이 다른 신뢰 표면이다 → 명시 opt-in([control-plane.md] auth 위에). 이 경로는 §236의 "외부 자동화=Chrome for Testing/CDP"와 **별개**다 — **인앱 WKWebView surface를 직접 제어**하며, 엔진 피벗(CEF) 없이 WKWebView에서 성립한다(CEF는 아래 천장에 부딪힐 때만). 라이브 E2E 배선·현재 구현 상태·남은 슬라이스는 [control-plane.md](control-plane.md) §9.2~§9.5를 **단일 출처**로 따르고 이 문단에서는 복제하지 않는다. 이 문단은 위협과 얕은 host-mediated 대 깊은 Web Inspector 설계 분기만 소유한다.

**CEF 도입 시점 절차**: CEF는 이 PR에서 확정하지 않는다. Chromium 인앱 surface가 실제 제품 요구로 올라오는 PR에서 아래 순서를 먼저 수행한다.

1. **목표 재확인**: 필요한 것이 인앱 Chromium UI인지, agent-browser 외부 자동화인지 분리한다. 외부 자동화만 필요하면 CEF를 넣지 않고 Chrome for Testing/CDP 경로를 우선한다.
2. **native backend plugin ABI 설계**: 일반 Wasm/action plugin과 별도로 `mount`/`unmount`/`frameSync`/`navigate`/`eval`/`snapshot`/`bridge`/`remoteDebuggingEndpoint`/lifecycle 계약을 정의한다. ABI version mismatch와 unload/rollback 동작도 같이 정한다.
3. **배포 spike**: CEF framework + helper app bundle들 + adapter dylib/launcher를 versioned bundle로 묶고, signed+notarized artifact가 Gatekeeper를 통과하는지 확인한다. manifest(`cef_version`, `chromium_version`, `maru_backend_abi`, `platform`, `arch`, `sha256`, signature), download/cache/rollback/삭제 UX를 함께 검증한다.
4. **합성·입력 spike**: 실제 CEF view/window를 pane rect에 붙이고, 모달 Metal 오버레이 z-order, live resize, pane 이동, firstResponder/IME, drag pass-through가 WKWebView 경로와 같은 UX 수준인지 확인한다.
5. **보안 spike**: bridge 격리(page-world 노출 금지), CDP random port/token/lifecycle 묶음, Origin/Host 제한, Library Validation/JIT entitlement 영향, helper process 권한을 검증한다.
6. **agent-browser subset smoke**: CDP endpoint 존재만으로 통과 처리하지 않고 navigate/evaluate/screenshot/snapshot/find_element/click/send_keys/cookies/download/target lifecycle을 `agent-browser` 명령 subset으로 실제 실행한다.
7. **채택 결정**: 위 gate를 통과하면 CEF native backend plugin을 별도 PR로 채택한다. 실패하면 WKWebView를 유지하고 agent-browser 호환은 Chrome for Testing/CDP 외부 자동화 경로로 둔다.

**도입 전 검증할 blocker(미해결)**:
- **공증/업데이트**: 다운로드 번들이 별도 signed+notarized artifact로 Gatekeeper를 통과하는지, helper app bundle 4종과 adapter dylib를 어떤 bundle layout으로 둘지 spike가 필요하다.
- **Library Validation**: backend dylib 로드가 메인 바이너리에 `disable-library-validation` entitlement를 강제하는지 확인해야 한다. 강제된다면 **CEF 안 쓰는 기본 사용자 보안까지 약화**된다.
- **JIT entitlement**(`allow-jit`)도 메인 또는 helper 중 어디에 필요한지 확인해야 한다. CDP `remote_debugging_port`는 localhost 제어면 노출(§7 게이트 무력화)이므로 인증·랜덤 포트·lifecycle 묶음이 필요하다. Chromium ffmpeg 코덱 특허·App Sandbox 비호환·자동업데이트 ABI 불일치도 별도 검증한다.
- CEF 기본 브리지는 page-world 주입이라(WKWebView와 정반대) "임의 페이지가 브리지에 못 닿음"을 CEF에서 **WKWebView와 동일 강도로 재검증**해야 한다. agent-browser 호환도 CDP endpoint 존재만으로 통과 처리하지 말고 위 subset smoke로 증명한다.

**결정 미정**: 위 blocker(특히 공증)를 spike로 검증하기 전엔 도입을 확정하지 않는다.

## 14. 코드 위치 (구현 시 채움)

- **웹 Term 모델 토대(4e-1, 구현 완료 — 렌더·WKWebView·ABI 무변경)**: L2 = `src/session/session_model.zig`(`Term.kind: SurfaceKind`·`web_panel_kind: PanelKind` 필드 + `surfaceId()`/`webPanelLabel()` accessor + `SurfaceKind`/`PanelKind` 별칭; 헤드리스 TDD로 혼합 Pane·kind 분기 고정). app = `src/app/live_pty.zig`(`LiveSurface` struct→`union(SurfaceKind)`: terminal arm=M3a 번들, web arm=sentinel `Surface`; `deinit`이 arm 분기; web arm sentinel teardown 헤드리스 테스트). platform = `src/platform/macos/app_session.zig`(`createTerm` terminal arm 접근, 신규 `createWebTerm`, `destroyTerm`/deinit teardown `kind` 분기, `termLabel` web 분기, `maybeDebugOpenWebPanel`이 web Term을 비활성 탭으로 append). 활성 렌더 skip·per-Term WKWebView·ABI 배선은 4e-2/4e-3.
- 합성·WKWebView·입력: 계획상 `src/platform/macos/web_panel.{zig,swift}`였으나, **최소 범위라 전용 파일 없이 기존 host
  파일에 통합**했다(전용 모듈 분리는 Phase 5 브리지/스킴 핸들러가 붙어 표면이 커질 때 한다). **4e-3 실제 위치**:
  `MaruAppHost.swift`(`MaruWebPanelView` = 조건부 hitTest·performKeyEquivalent 래퍼 + 인라인 흰 HTML WKWebView,
  `MaruTerminalContainerView.insertWebPanel` = z-order 중간 삽입, `TerminalSurface.webPanels: [UInt64: MaruWebPanelView]` dict,
  `drainWebSurfaceTransition` = batch(count+at) op 적용), `app_session.zig`(`web_panel_prev`(prev 집합)·`web_surface_transitions`
  (batch) 상태, `maybeDebugOpenWebPanel` env 훅, `collectWebSurfaces`(pane 트리 walk → web Term 집합)·`marshalWebTransitions`·
  `computeWebSurfaceTransitions`·`webSurfaceTransitionsCount`/`webSurfaceTransitionAt`·`webFramePt` = 4a 3함수 소비). 4c의
  단일 `web_panel`·`active_pane_leaf_rect` 캐시·단일 `webSurfaceTransition`은 제거(per-Term 트리 walk가 대체).
- **입력 responder 전이(4d, 구현 완료 — Swift 전용, ABI 무변경)**: `MaruAppHost.swift`만. `MaruWebPanelView`에 `weak controller` +
  조건부 `hitTest`(모달 닫힘=super/열림=nil) + `performKeyEquivalent` override(웹 포커스 중 Cmd-조합→`handleWebPanelChord`).
  컨트롤러: `isWebPanelFocused`(firstResponder가 wp 자손인지), `handleWebPanelChord`(`handleKeyDown`+즉시 reconcile),
  `reconcileWebModalFocus`(`anyOverlayOpen` 엣지→웹↔터미널 firstResponder 전이·복원, renderTick 매 tick 호출). 전이 추적 상태
  (`lastOverlayOpen`·`stashedWebFocusSurfaceId`)는 `TerminalSurface`(세션별 — 4e-3서 여러 web Term 중 복원 대상을 surface_id로
  기억). 키바인딩 정책의 단일 출처는 여전히 Zig `config/keybinding.zig`의 `default_app_bindings`(Swift는 keyDown으로 넘기기만).
  새 ABI 없음(`any_overlay_open` v80 재사용).
- **surface 생애주기·per-pane rect 순수 계산(4a, 구현 완료)**: `src/session/web_panel_layout.zig`(L2, OS-중립). 본문 rect(`contentRect` — pane rect − chrome inset), backing px·좌상단 → pt·좌하단 y-flip(`pxTopLeftToPtBottomLeft`), surface 생애주기 diff(`surfaceDiff` — created/destroyed/reframed/hidden/shown 전이)의 **단일 출처**다. 헤드리스 단위 테스트로 고정(§11)하고 `check-boundaries`가 L2 중립(app/pty/platform/AppKit import 0·OS 타입명 0)을 강제한다. y-flip 생산 적용(ABI export 또는 Swift 미러)은 이 함수를 단일 출처로 두고 4c가 배선한다.
- surface 생애주기·per-pane rect ABI wiring(**4e-3 구현 완료 — batch**): `src/platform/macos/app_host_abi.{zig,h}` — 위 순수
  계산을 export/marshaling. v101에서 v99 단일 op(`maru_macos_app_session_web_surface_transition`)를 제거하고 **count+at**
  (`..._web_surface_transitions_count` + `..._web_surface_transition_at(index)`)로 대체(command_catalog 선례). `MaruAppHostWebSurfaceTransition`
  (extern struct: op·**visible**·surface_id·panel_kind·frame_pt_{x,y,w,h}) — `visible`은 op 뒤 pad 자리라 struct size v99와 동일.
  Zig가 pane 트리 walk + `surfaceDiff`로 계산한 batch를 marshaling만 하고(NSView 연산은 Swift), struct size/offset(visible 포함)·
  op enum 값을 헤드리스 계약 테스트가 강제한다.
- 모달 레이어 분리: `src/platform/macos/maru_metal_renderer.{h,m}`(별도 오버레이 layer·2패스), `src/renderer/metal_frame.zig`
- `maru-app://` OS 어댑터: `MaruAppHost.swift`의 `MaruAppSchemeHandler` + `MaruWebPanelView` trust 분기·surface-pinned bridge. ABI marshaling·CSP getter·FP4 dynamic bridge dispatch는 `app_host_abi.{zig,h}`(ABI v120). 제품 asset은 `web/src`→zntc `web/dist`→`Resources/web/` 경로이며 생성물은 커밋하지 않는다.
- `maru-app://` 보안 정책(**5c-1·5c-2a 구현 완료**): CSP 상수·경로 문자열 검증(traversal·whitelist·정규화 불변식)은 L2 순수 `src/session/app_scheme.zig`(`csp_header`·`validateAppPath`)가 단일 출처. realpath/symlink 탈출 거부는 실 FS I/O라 `src/platform/macos/app_host_abi.zig`의 `resolveAppAsset`(5c-1 문자열 검증을 소비 + realpath canonical containment). origin/frame allowlist(exact-origin pin)는 5b 브리지가 더한다.
- markdown sanitizer·웹 콘텐츠 보안: `web/` 패키지(zntc build, Bun `web:test`). sanitizer fixture와 렌더러 순수 로직은 Swift가 아니라 웹 패키지가 소유한다.
