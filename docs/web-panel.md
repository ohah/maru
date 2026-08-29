# 웹 패널 인프라 (WKWebView 합성·입력·임베드)

이 문서는 Maru에 리치 웹 패널(마크다운 WYSIWYG 편집·인앱 브라우저)을 WKWebView로 임베드하는 **합성·입력·web 특유 보안**의 단일 출처다. **세션 제어·브리지 신뢰 게이트 계약은 [세션 컨트롤 플레인](control-plane-security.md) §8이 소유**하고, 이 문서는 "WKWebView를 maru 창에 어떻게 올리고·입력을 라우팅하고·web 특유 위협을 막는가"에 집중한다(브리지 게이트를 여기서 재서술하지 않는다).

레이어 경계는 [레이어링과 이식성](layering-and-portability.md), 네이티브 뷰 비사용 예외(리치 웹 패널)는 [메뉴바와 커맨드 팝업 구현 계획](plans/menu-and-command-palette.md) UI 렌더 전략·[macOS 앱 호스트 경계](macos-app-host-boundary.md), 탭/split 모델은 [탭·split·레이아웃](tabs-splits-layout.md), 윈도우 간 detach/reattach와 WKWebView reparent 선행은 [윈도우와 Surface 이동성](window-surface-mobility.md)을 단일 출처로 둔다.

> **spike로 실측한 범위(2026-06)**: ① 투명 Metal 오버레이가 WKWebView 위에 합성되는 **z-order 순서**(GUI), ② isolated `WKContentWorld`에서 임의 page-world JS가 브리지에 못 닿음(headless). **그 둘만** 확인했다. 입력/firstResponder 라우팅·실제 셀 모달 합성·드래그 인터랙션·per-pane 좌표계는 **미검증 리스크**(§12)다.

## 계약 문서 구성

웹 패널 계약은 아래 문서가 나눠 소유한다. **절 번호는 파일을 넘어 이어진다** — 다른 문서와 코드 주석이
`web-panel.md §7.1`처럼 절 번호로 가리키므로 재번호하지 않는다.

| 절 | 문서 | 소유 |
|---|---|---|
| §1~§7 · §9 · §11~§13 | 이 문서 | 확정 결정, 합성 계층, 좌표계, 입력·키 라우팅, chrome 인터랙션 제약, surface ABI, 보안, 베이스와 결정, 검증, 리스크, CEF 백엔드(범위 밖) |
| §8 | [빠진 기능](web-panel-features.md) | 제품으로 서기 위해 채워야 하는 기능의 계약 |
| §10 · §14 | [구현 계획](plans/web-panel.md) | Phase 순서·코드 위치·기능별 슬라이스 이력 |

## 1. 확정 결정

- **웹 패널 = WKWebView subview, 모달 = 별도 Metal 오버레이 레이어.** 단일 contentView를 컨테이너로 바꾸고 3겹으로 합성한다(§2).
- **z-order(WKWebView subview 모델 전용)**: 터미널 Metal layer(아래) < WKWebView(중간) < 투명 Metal 오버레이(모달, 위). **spike로 순서 합성만 확인**. 실제 셀 모달(텍스트·둥근 모서리·그림자·테마)을 투명 layer에 그린 합성은 Phase 4 종료 게이트에서 GUI 골든으로 1회 확정한다(§11). 이 골든은 렌더러의 자연폭/2-quad/role 기반 글리프 계약도 함께 확인한다.
- **모달은 NSView가 아니라 Metal 오버레이 레이어** — GPU chrome 철학(셀 렌더 재사용) 일관성 때문이다. **"이식성" 때문이 아니다**: "네이티브 웹뷰 위 GPU surface 합성"은 OS별 컴포지터 문제(macOS=CALayer subview, Windows WebView2=별도 HWND, Linux=Wayland subsurface)라 다른 OS에선 합성 모델을 타깃 시점에 재결정한다([layering-and-portability.md] §4 "호스트는 타깃별 신규").
- **입력 라우팅은 합성과 별개의 1급 문제다**(§4) — "layer만 분리"가 아니다. 모달이 그려지는 것과 키 입력이 모달에 가는 것은 다르다.
- **web 특유 보안**(§7): `maru-app://` 콘텐츠에 엄격 CSP + 스킴 핸들러 경로 샌드박스, `.md`는 "신뢰 렌더러가 그리는 **비신뢰 데이터**"(새니타이즈), untrusted 패널은 데이터스토어·프로세스 격리. **브리지 신뢰 게이트 자체는 [control-plane-security.md] §8.1 단일 출처.**
- **프론트엔드 개발환경 = zntc** (dev server/preview/build/bundle, dev-only, 확정). `web/` 하위 Bun workspace는 패키지 설치·락파일·script 실행·프론트엔드 단위 테스트(`bun test`)를 맡는다. JS/TS 품질 게이트는 VoidZero/Oxc 계열의 `oxlint`·`oxfmt`를 쓴다. Vite+에는 모노레포 config·task runner가 있지만, 전체 도입은 zntc 개발환경과 Bun test runner와 역할이 겹치므로 기본값에서 제외하고 필요 시 Vite Task만 별도 검토한다. **CEF는 미래 native webview-backend plugin 후보**(일반 Wasm/action plugin 아님 — §13).
- **미래 콘텐츠 소비처: 관측성 trace inspector**(후속). 캡처한 세션을 스텝별로 넘겨보는 **관전형 HTML 뷰어**를 이 패널에 띄운다(네이티브 패널을 새로 만들지 않고 재사용 — 자기완결 HTML이라 패널 완성 전엔 외부 브라우저로도 열림). replay 엔진 재사용·단일 출처. 상세: [trace-replay.md](trace-replay.md) "GUI inspector 설계 방향".
- **웹 패널 전에 필요한 이동성 foundation만 먼저 잡는다.** Maru-owned browser/markdown surface는 별도 창으로 detach된 뒤 다시 합쳐질 수 있어야 한다. 따라서 Phase 1 live collector 전에는 `SurfaceIdAllocator`/`WindowMembershipSnapshot`을 확정하고, Phase 4 WKWebView hosting 전에는 그 M0 완료를 확인한 뒤 `WindowGraph`/`LiveSurfaceRegistry`를 확정한다([window-surface-mobility.md](window-surface-mobility.md)). command 이동/drag/reparent UX는 Phase 4 이후에 따라와도 된다. 합쳐지지 않는 브라우저는 Maru surface가 아니라 `Open in External Browser` 경로다.

## 2. 합성 계층

현재 `contentView`는 단일 `MaruMetalTerminalView`(CAMetalLayer)이고, 이 뷰가 firstResponder로 keyDown·IME·마우스·DnD·hover를 전부 받는다. 웹 패널을 위해 **contentView를 컨테이너 NSView로 바꾸고** 세 겹을 쌓는다:

1. **터미널 Metal layer**(맨 아래): 기존 셀·사이드바·탭바·pane chrome. `isOpaque`는 무조건 true가 아니다 — `window.opacity<1`이면 현재 코드가 metalLayer·window의 `isOpaque`를 모두 false로 내리고 chrome 배경(`chromeCellBg`/`chromeQuadBg`)까지 반투명이다. WKWebView와의 정합은 §8.
2. **WKWebView subview(들)**(중간): web Term마다 하나, **본문 rect**에만(§5). split이면 여러 개:
   활성 워크스페이스 탭의 pane 트리를 walk해 **web Term마다** WKWebView(`MaruWebPanelView` 래퍼) 하나를 붙이고, 각 웹뷰를
   **자기 pane 본문 rect에 고정**한다(4c의 활성 pane 추종을 완전 제거 — 사용자 관찰 해소). 같은 pane의 활성 Term만 show·
   비활성 탭 web Term은 hidden(상태 유지), 비활성 워크스페이스 탭의 web Term은 destroy. Swift는 `webPanels[surface_id]`
   dict로 batch 전이(create/destroy/reframe/hide/show)를 적용한다. Term 이동 시 재부모화는 후속(4e-4·§6).
   **FP16 목표 변경(계획 — [file-panel.md](file-panel.md) §4가 단일 출처)**: 마지막 규칙("비활성 워크스페이스 탭의 web Term은
   destroy")을 **"zero rect + hidden으로 보존"**으로 바꾼다. 파일 패널이 전역 도크에서 워크스페이스 Term으로 옮겨오면서
   destroy가 곧 미저장 편집 유실이 되기 때문이며, 적용 범위는 파일뿐 아니라 **web Term 전체**(브라우저 포함)다. 그 결과
   브라우저가 워크스페이스 전환 뒤 흰 페이지가 되던 현행 동작도 함께 사라진다. 현재 코드는 아직 destroy다.
   **관련 현행 결함(적대적 검증에서 확인)**: destroy 분기의 "이동↔닫힘" 판정(`windowOwningWebSurfaceModel`)이 **자기 창을
   `except`로 제외**하므로(MaruAppHost.swift:5204), 같은 창 안의 워크스페이스 전환도 "진짜 닫힘"으로 오판돼 실제로는 닫히지
   않은 브라우저 패널에 `browser.closed`가 push된다(MaruAppHost.swift:5906). FP16의 hidden 보존은 surface가 집합을
   떠나지 않게 하므로 이 control-plane 이벤트 오발행도 함께 해소한다.
3. **모달 Metal 오버레이**(맨 위): command palette·find·confirm. `isOpaque=false`, 평소 clear(투명), 모달 열림 시에만 셀을 그린다.

**모달 레이어 분리는 두 개의 선행 리팩터다**(Phase 4 선행, 가벼운 작업이 아님):
- **(a) 렌더러 분할**: 현재 모달은 터미널과 같은 cells 배열·같은 draw pass에서 `modal_cells_start` 인덱스로만 갈린다. same-pass 전제는 over-quad(`layer=1`)·그림자·셀 clip scissor(`clip_index`, ABI v169)에 더해 **커서 blink 페이드 pass(ABI v95, v146에서 구간 명시화)**까지다 — caret은 단일 cells 버퍼 + 단일 fragment opacity uniform 전제이고 draw 위치가 모달 유무로 갈리므로(모달 열림 시 모달 텍스트 뒤), 분리 시 caret pass를 소유 레이어로 재배선한다. 셀당 2-quad(×12 vertex) 오프셋 규약(`modal_cells_start*12`·`cursor_start*12`의 기반)도 두 패스에 그대로 이관한다. **v146 정정**: caret은 더 이상 "버퍼 맨 끝 suffix"가 아니다 — caret 없는 오버레이 셀(포커스 테두리·drop 하이라이트·드래그 고스트)이 커서 뒤에 붙으면 그 가정이 깨져 옛 코드가 `cursor_cells=0`으로 접었고, 그 결과 커서가 본문과 함께 불투명하게 그려져 **blink가 죽었다**(`appendFocusOwnerBorder`가 상시 흘러 사실상 항상 재현). 이제 `cursor_start`를 ABI로 명시해 커서가 버퍼 어디에 있든 구간을 특정하고, 렌더러가 본문을 커서 앞/뒤 두 구간으로 나눠 그린다. 이를 `drawTerminal(layer, cellSubset[, caret])` / `drawOverlay(layer, modalCells+quads+shadow[, caret])` 두 패스로 재분할한다. **caret은 조건부 이중 소유**다 — 모달이 닫힌 평시 caret은 터미널 콘텐츠라 `drawTerminal` 소유, 모달 열림 시에만 모달 텍스트 위 `drawOverlay` 소유로 이관한다(현재 `has_modal` 분기가 draw 위치를 가르는 그 지점). 두 CAMetalLayer의 drawable·redraw·**generation 게이팅을 독립 추적**한다(현 `lastSeenMetalGeneration` 단일 가정 변경). 셀 clip 재배선 대상 — 주의: `MTLScissorRect`는 **좌상단 원점**이다(활성 scissor·per-quad clip과 같은 규약).
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
  1. **모든 maru 앱 키바인딩은 Zig `default_app_bindings`(config/keybinding.zig)가 단일 출처**다. 초기 4d spike는 keyDown 재진입으로 이 가설을 검증했지만, FP10/ABI v132의 제품 계약은 typed `maru_macos_app_session_web_key_route` → `maru_macos_app_session_dispatch_web_app_action`이다. 후자는 같은 `KeyBindingResolver.resolveWebDetailed`을 다시 평가해 현재 `Action`만 직접 실행하므로 terminal copy/paste·scroll·macro 전처리와 PTY write를 우회한다. 메뉴 keyEquivalent는 발견성용 병렬 경로이고, WebKit 소유/explicit consume/app action 판정은 Zig resolver가 자기완결한다.
  2. **터미널 IME 무회귀**: 웹 래퍼(`MaruWebPanelView`)의 override는 **웹이 포커스일 때만** 동작하고(그 외엔 `false`만 반환) 터미널 뷰의 keyDown/`NSTextInputClient`/`performKeyEquivalent`를 **한 줄도 건드리지 않는다**. local event monitor는 매 keystroke(한글 조합 포함)를 앱 전역에서 가로채는 병렬 경로라 터미널 IME 폭발반경이 크고, 현행 performKeyEquivalent+`anyOverlayOpen` 패턴과도 이질적이라 기각.
  3. **모달 responder 전이**: 웹 포커스 중 모달이 열리면(`anyOverlayOpen` false→true 엣지) `makeFirstResponder(터미널 뷰)`로 전이해 모달 입력·IME preedit가 터미널 `NSTextInputClient`로 흐르고, 닫히면(true→false) 직전 웹뷰로 복원한다. 전이는 **기존** `becomeFirstResponder`(imeFocus true)/`resignFirstResponder`(commitComposition)를 그대로 태운다 — 새 IME 로직 없음. 엣지는 매 tick + 모달 여는 조합 직후 동기로 조정한다(조합 직후 타이핑이 웹뷰로 새지 않게).
  - **자동으로 못 잡는 부분(수동 필수)**: 실제 포커스 전이·한글 preedit 라우팅·복원·기존 터미널 IME 무회귀는 GUI 손 테스트만 확정한다(§11). smoke는 `web_panel_focused`(시작 시 웹이 firstResponder를 안 훔침 = false)만 결정적으로 단언한다.
  - **포커스 기준 분기(웹 소유 키 → WebKit 양보)**: **클립보드 키 `⌘C`/`⌘V`/`⌘A`는 WebKit이 받는다** — 웹 패널 포커스 시 메뉴바 편집 항목이 표준 셀렉터를 WebKit responder chain으로 넘긴다(§4.2 단일 출처). `⌘F` 페이지 내 find는 **[빠진 기능](web-panel-features.md) §8이 계약을 소유**한다(라우팅 기준은 포커스가 아니라 `activeWebSurfaceIdAnyKind` — §8이 그 이유를 적는다). 초기 4d 최소 spike는 빈 about:blank라 Cmd-조합을 전부 maru로 라우팅했고(⌘C/⌘V가 웹이 아니라 터미널에 작용하지만 빈 페이지라 무해), 실콘텐츠에서 이 분기 정책은 Zig/config와 §4.2가 소유한다.

### 4.1 웹↔터미널 포커스 동기 불변식 (4g — 흩어진 포커스 패치 통합)

이 불변식은 4g-0(ABI v112 `active_web_surface_id_any_kind`)·4g-1(v113 `addr_edit_surface` → 14차 리뷰 후 v114 `terminal_owns_input`으로 단일화)로 배선돼 있다 — Swift `reconcileWebFocus()`가 매 tick 돌며 옛 `reconcileWebModalFocus` 등 흩어진 패치를 대체한다.

**문제(관측 — 이 절이 해결한 것)**: Phase 7 손 테스트에서 포커스 버그가 **반복** 나왔다 — ⑴ 브라우저 보던 중 ⌘Q 종료 모달이 Enter로 안 닫힘 ⑵ 주소창 편집→터미널 클릭 시 포커스가 브라우저로 튐 ⑶ 터미널→브라우저 web 클릭 후 ⌘R 무동작 ⑷ 브라우저 탭을 활성화해도 webview에 포커스가 안 가 ⌘R 게이트가 stale ⑸ 키보드 pane 전환(⌘⌥→)이 webview 포커스를 안 옮김. 근본 원인은 WKWebView 네이티브 `firstResponder` 관측을 사용자 intent와 동일시하거나 Zig 활성 모델과 병렬 권위로 둔 데 있다. programmatic/accessibility focus도 같은 관측을 만들므로 passive reconcile은 정책을 바꿀 수 없다.

**불변식(단일 출처)**: **명시적 primary-down/typed completion → Zig owner → `firstResponder`**.
- 활성 pane의 활성 term이 **web term** → 그 **webview**가 firstResponder.
- 활성 pane의 활성 term이 **terminal** → **터미널 뷰**가 firstResponder.
- **override(우선순위)**: **모달 열림**(notice 제외) 또는 **터미널-라우팅 텍스트 입력**(주소창 편집·rename·사이드바 검색) → **터미널 뷰**(그 입력은 Zig `handleKeyEvent` 경로라 터미널 뷰가 소유). 이 판정은 Zig `terminalOwnsInput`(=`anyModalOverlayOpen ∪ addr_edit ∪ rename ∪ sidebar_search`) **단일 출처**다(4g-3 통합, ABI `terminal_owns_input`). 모달/편집이 끝나면 불변식이 복원한다(별도 focus-restore pending 불요). 비-모달 notice(토스트)는 제외 — 지나가는 토스트가 입력 responder를 뺏으면 안 되고, Zig 키 intercept(rename/addr_edit/sidebar_search)도 같은 `anyModalOverlayOpen` 게이트를 쓴다.

**입력·reconcile 순서**:
1. **명시적 입력 → Zig 활성**: `MaruWebPanelView.hitTest`가 overlay/seam을 제외한 실제 primary-down에서만 `webPanelPrimaryDown`을 호출한다. file panel은 `focus_file_panel_surface`, workspace browser는 `activate_surface` 뒤 `focus_workspace_input`을 호출한다. 이미 firstResponder인 같은 WebView 재클릭도 새 intent로 전달된다. programmatic/accessibility focus와 매 tick 관측은 이 권한이 없다.
   - **"실제"의 기준은 `super.hitTest`가 non-nil인 것**이다. `hitTest`는 이벤트 수신이 아니라 **조회** 함수라, AppKit이 목적지를 찾는 동안 이 패널의 frame **밖** 좌표로도, 숨긴 패널에도 호출한다. 이벤트 타입만 보고 통지하면 **탭 바 클릭이 web surface를 활성화해 터미널 탭을 눌러도 브라우저로 되튄다**(Phase 7 손 테스트 재발 → `MARU_DEBUG` 로그에서 클릭마다 `activate_surface`가 찍혀 확정). 결과가 nil이면 이 패널도 그 자손도 그 클릭을 받지 않으므로 통지하지 않는다 — drop-zone 드래그 중 `isHidden` 패널도 이 기준으로 함께 걸러진다.
2. **typed dock completion → Zig 활성**: surface publish를 기다리는 파일 Term은 `.dock_pending`(FP16 — 옛 `.dock_group`)에서 text/paste를 fail-close하고, `PendingDockFocus`의 EntryId/surface/epoch/revision 검증과 native firstResponder 성공 뒤에만 `.dock_surface`로 승격한다.
3. **Zig 활성 → firstResponder**: 매 tick `reconcileWebFocus`는 `focused_dock_surface`와 `active_web_surface_id_any_kind`만 읽어 해당 webview 또는 터미널 뷰로 맞춘다. firstResponder 관측으로 `activate_surface`, `focus_workspace_input`, Swift file-focus 상태를 갱신하지 않는다.

**이 하나가 흩어진 것을 대체(subsume)한다**:
- `reconcileWebModalFocus`(모달→터미널) = override 규칙.
- `reconcileWebFocusActivation`(클릭→활성) = explicit `webPanelPrimaryDown`.
- `cancelAddrEdit`의 `addr_focus_restore_pending`(편집 종료 시 webview 복원) = addr_edit override 해제 후 Direction 1이 복원(pending 불요·단순화).
- ⌘R `activeWebSurfaceId` 게이트 = Direction 1이 브라우저 탭 활성 시 webview를 포커스하므로 `isWebPanelFocused`가 신뢰 가능해져 원 게이트로 회귀 가능(belt-and-suspenders로 유지 가능).

**필요 표면**: `activate_surface`(v78, 있음). **활성 web surface getter 확장** — 현 `activeWebSurfaceId`는 browser 전용(0=아님)이라, Direction 1이 활성 pane이 **어떤 web kind든**(browser·markdown) 그 webview를 포커스하려면 "활성 pane 활성 term이 web이면 surface_id + kind, 아니면 0"이 필요하다(신규 getter 또는 확장, Zig 순수·헤드리스 테스트). Swift는 surface_id→webPanels로 webview 조회.

슬라이스와 완료 이력은 [웹 패널 구현 계획](plans/web-panel.md)이 소유한다.
- **4g-3 (14차 리뷰 후속 — 완료)**: override 판정을 `anyOverlayOpen ∪ addr_edit`에서 **`terminalOwnsInput` 단일 출처**로 교체(ABI `addr_edit_surface`→`terminal_owns_input`, v113→v114). 옛 override는 ⑴ **rename·사이드바 검색을 빠뜨려** web pane 활성 중 그 편집 키가 웹뷰로 샜고(리뷰 [0]) ⑵ **notice까지 세어** 비-모달 토스트가 편집 responder를 뺏었다(리뷰 [3]). 겸사로 Zig 키 intercept 3개(rename/addr_edit/sidebar_search)도 `anyOverlayOpen`→`anyModalOverlayOpen`으로 일치, 주소창 편집 chord 처리는 **⌘A/C/V/X/Z를 제외**해 ⌘V가 편집을 통째 날리던 회귀 수정([1], 소비 no-op으로 편집 보존·실 붙여넣기는 후속), 잘못된 주소 무효 시 편집 유지 docstring 정정([5]), `focusTerminalView` 재downcast→바인딩된 `tv` 재사용([8]). **헤드리스**: 브라우저 web term 닫기 확인([4]) + `terminal_owns_input(null)=0` ABI 테스트. **GUI 손 테스트 필요**: web pane 위 rename/사이드바 검색이 웹뷰로 안 새는지, 주소창서 ⌘V가 편집을 안 지우는지, 모달 Enter·키보드 pane 전환 무회귀.
- **4g-4 (파일 도크 교차 영역 입력 회귀 — 완료, 2026-07-18)**: 도크가 열린 mouse-down 경로의 `dockGroupAtPoint(...) orelse return`이 도크 밖 클릭까지 함수 전체에서 종료해, workspace browser는 보이지만 주소창·탭·터미널을 조작할 수 없었다. group hit는 조건부로 처리하고 **실제 dock rect 안** Metal 클릭만 소비하도록 바꿔 바깥 클릭은 workspace hit-test로 흐른다. 도크를 연 browser 주소창 클릭→`addr_edit_surface`/`terminalOwnsInput`→문자 입력까지 red→green 통합 테스트로 고정했다.

**리스크·검증**: 코어 포커스라 회귀 시 **모달·타이핑·IME가 깨진다** → firstResponder는 AppKit이라 헤드리스 불가, **GUI 손 테스트가 유일 안전망**(§11). 특히 `reconcileWebModalFocus`(검증된 모달 Enter 동작)를 대체하므로 그 무회귀를 재확인한다. Zig getter(4g-0)만 헤드리스. 기존 터미널 IME/keyDown은 **한 줄도 안 건드림**(4d 규율 유지 — override는 makeFirstResponder만).

### 4.2 메뉴바 편집 키(Copy·Paste·Select All) 포커스 인지 분기 — 클립보드 복붙 단일 출처

`performKeyEquivalent`의 `WebKeyRoute`가 `web_editor`/`pass_through`에서 이벤트를 소비하지 않고 넘겨도(§4 spike), **앱 메뉴바의 편집 항목이 자체 keyEquivalent로 그 키를 먼저 가져간다**. `Edit▸Copy(⌘C)`·`Paste(⌘V)`는 컨트롤러 셀렉터 `menuCopy`/`menuPaste`(각각 터미널 선택 복사·PTY 붙여넣기), `Select All(⌘A)`은 카탈로그 `select_all`(터미널 전체 선택)에 배선돼 **first responder와 무관하게 발화**한다. 그래서 이 세 키만은 `WebKeyRoute`가 "WebKit에 양보"해도 실제로는 터미널로 갔고, 이것이 도크·브라우저에서 웹 선택 복사/붙여넣기가 안 되던 근본 원인이다(`⌘X`/`⌘Z`/`⌘S`/`⌘F`는 충돌 메뉴 항목이 없어 이미 `WebKeyRoute`로 CM6/WebKit에 도달하므로 저장 smoke는 통과하고 복붙만 깨진 관측과 정합).

**계약(단일 출처)**: 이 세 메뉴 항목은 **key window의 first responder가 웹 패널(도크 파일 뷰 `filePanelKind∈{1,2}` 또는 워크스페이스 브라우저 `filePanelKind==0`) 안쪽이면 표준 편집 셀렉터를 responder chain으로 넘긴다** — `Copy→copy:`, `Paste→paste:`, `Select All→selectAll:`. 그러면 first responder인 WKWebView(WKContentView)가 WebKit 네이티브 복사/붙여넣기/전체 선택을 수행한다. first responder가 웹 패널이 아니면(터미널·모달·`.dock_group` publish 대기 등 `terminalOwnsInput` 상태 포함) 기존 터미널 경로 그대로다. 판정 소스는 Swift `firstResponderWebPanel()`(key window firstResponder의 superview 사슬에서 `MaruWebPanelView` 탐색) 하나이며, 세 진입점(`menuCopy`·`menuPaste`·`runCatalogAction`의 `select_all`)이 이를 공유한다.

**모드별 결과**: `live`·`source` 마크다운은 CM6가 복사·붙여넣기·전체 선택을 모두 처리한다. `read` 마크다운·`html`은 편집기가 아니므로 **선택 텍스트 복사(⌘C)와 전체 선택(⌘A)만** WebKit이 수행하고 붙여넣기(⌘V)는 삽입 대상이 없어 no-op이다. 이는 [key-input-and-shortcuts.md](key-input-and-shortcuts.md)의 `web_editor`/`pass_through` "WebKit에 양보" 계약을 **메뉴바 축에서 실제로 성립**시키는 보완이다.

**베이스·결정**: responder chain 표준 셀렉터 dispatch(macOS 관용 — WKWebView는 `copy:`/`paste:`/`selectAll:`을 이미 지원). 대안인 "터미널 Metal 뷰에 `copy:`/`paste:`/`selectAll:` NSResponder 구현 + 메뉴 `target=nil` 표준 체인 전환"은 가장 관용적이나 **가장 민감한 터미널 입력·IME 경로**를 건드려 블라스트 반경이 커 기각(사용자 결정 2026-07-21). `⌘F` 페이지 내 find는 §8이 소유한다(포커스가 아니라 `activeWebSurfaceIdAnyKind` 기준).

**검증**: firstResponder는 AppKit이라 헤드리스 불가 — **GUI 손 테스트가 유일 안전망**(§11). ⑴ 도크 `read` `.md`·`.html`에서 텍스트 선택 후 `⌘C`→외부 앱 붙여넣기로 확인, ⑵ `live`/`source`에서 `⌘C`/`⌘V`/`⌘A`가 CM6에 작용, ⑶ 터미널 포커스에서 `⌘C`/`⌘V`/`⌘A`가 기존대로 터미널에 동작(무회귀), ⑷ 모달 열림·`.dock_group` publish 대기 중에는 터미널 경로.

## 5. WKWebView가 막는 터미널-chrome 인터랙션

z-order상 모달(최상위)을 제외한 모든 터미널 마우스 인터랙션이 웹 pane 위에서 WKWebView에 가로채인다. 다음을 정한다:

- **WKWebView frame을 padding된 본문 rect로 한정**한다 — pane 탭바·divider seam·pane grip을 Metal 노출 영역으로 남긴 뒤, terminal grid와 동일한 `window.padding-{top,right,bottom,left}`를 본문 안쪽에 적용한다. workspace web Term과 파일 도크 WebView가 `layout_math.insetRect`를 공유하며, tab/header/divider 기하는 padding 소비자가 아니다.
- **drop-zone split 생성**(Term 탭을 본문 4분할에 드롭)은 드래그 중 대상 WKWebView를 `isHidden`/`hitTest nil`로 임시 통과시키고, drop-zone 하이라이트는 **모달 오버레이(최상위)**에 그린다(터미널 Metal 레이어에 그리면 WKWebView에 가림).
  - **구현(렌더러 슬라이스 — 완료)**: 탭/pane 드래그 시각물 두 가지 — drop-target 반투명 하이라이트(bg-only 셀)와 floating 고스트(끌리는 대상 라벨 박스)를 **터미널 레이어(`pane_overlay`/`pane_frames`) → 최상위 오버레이 레이어**로 옮겼다. `MetalFrameBuffer.replace`에 `drag_overlay_frame`(고스트 PaneFrame — raster는 `buildMergedUploadsN` `drag_raster`로 머지)·`drag_overlay_cells`(하이라이트 bg 셀) 두 채널을 추가하고, 이들이 있으면 `modal_cells_start`를 오버레이 영역 시작으로 세워 렌더러 `has_modal`(실은 "오버레이 영역 존재") 경로로 **WKWebView 위** 오버레이 CAMetalLayer에 그린다. ABI·`MetalFrame` 구조체·렌더러 `.m` draw 로직 **무변경**(modal_cells_start가 이미 구동). 드래그가 없으면 두 채널이 비어 옛 경로와 byte-identical(무회귀). **오버레이 영역 순서 = [하이라이트(아래)] [드래그 고스트(중간)] [모달(위)]** — 모달을 맨 뒤에 둬 그 caret이 버퍼 suffix(blink chop 대상)로 유지된다(15차 리뷰 [0]: 드래그 중 ⌘F로 caret 모달을 열면 modal·drag가 키보드 모달로는 배타가 아니라 공존 → 고스트를 모달 뒤에 두면 blink가 고스트에 얹혔던 것 정정). 헤드리스 테스트=셀 조립(오버레이 영역·`cursor_cells`), 실제 web 위 가시성·드래그+모달 caret=손 테스트. **알려진 한계(15차 [7], 후속)**: `modal_cells_start` sentinel 0이 "오버레이 없음"과 "인덱스 0 시작"을 겸해, rich 테마+접힌 사이드바+단일 web pane(오버레이 앞 셀 0)에서 드래그 시각물이 터미널 레이어로 새 WKWebView에 가릴 수 있다(실무 흔한 config는 탭 바/헤더 셀이 있어 무영향). 견고 수정은 렌더러 게이트·assert를 건드려 손 테스트 필요.
- **divider 드래그·hover 커서**(↔/grip)도 본문 한정 + 드래그 중 통과로 처리.
  - **구현(좌표·padding 정합 보강 2026-07-20, ABI v136)**: Zig가 각 web 본문 rect를 divider에서 작은 seam inset(`dt + 1pt`)만큼 들이고, divider 맞닿는 가장자리 비트마스크(`seam_edges`: left=1·right=2·bottom=4)를 만든다. `AppSession.collectWebSurfaces`는 window padding까지 적용한 **최종** `content_rect`와 실제 Zig resize target의 연속 교집합만 `divider_grab_left/right/bottom_pt`로 투영한다. resize target은 두 갈래다 — pane 사이 seam은 `pane.paneDividerTarget`(경계선 ± `chrome.components.divider.hitHalfExtentPx`), 도크 경계는 `dock_layout.outerDividerHitRect`다. **left에는 도크 갈래가 없다** — `dock_panel.Side`가 `right`·`bottom` 둘뿐이라 왼쪽 seam은 언제나 형제 pane과의 경계다(비대칭이 아니라 도크 배치의 결과다). 교집합 폭 계산 자체는 **L2** `session/web_panel_layout.dividerPassThroughBandPx`가 소유하고 — target이 그 edge를 **연속으로 덮지 않으면 0**으로 fail-close한다 — `pane.dividerBandPt`는 그 px 값을 pt로 바꾸는 래퍼다. 비대칭 padding 때문에 edge별 교집합이 다르므로 단일 전역 폭을 쓰지 않으며, padding/seam이 hit target을 이미 전부 노출한 edge는 0으로 fail-close한다. `surfaceDiff`는 이 세 값도 equality에 포함해 보이는 surface의 변경만 `reframed`하고 숨은 surface는 다음 `shown`에 최신 값을 싣는다.
  - `MaruWebPanelView.hitTest`는 AppKit 입력과 같은 **superview 좌표**의 `frame`과 위 edge별 폭만 `WebPanelHitTestGeometry`에 넘긴다. `bounds`와 섞으면 origin이 0이 아닌 오른쪽/아래 도크에서 본문 전체를 seam으로 오판해 클릭·휠이 Metal view로 새고, 최종 frame에서 다시 고정 10pt를 떼면 padding만큼 resize target 밖 dead strip이 생긴다. native helper는 frame 밖과 band 경계를 half-open으로 거부하므로 **통과한 모든 점은 Zig resize target**이다. 일반 본문은 WebKit 클릭·휠을 유지하고, 실제 divider target 안의 edge band만 Metal의 기존 hover/down/drag/up·`PointerGestureOwner` 경로로 들어간다. `split.divider-thickness=0`이면 세 폭이 모두 0이다. resize 동안 WebView는 재생성/숨김 없이 기존 surface의 bounded `reframe`만 적용한다.

## 6. surface 식별·생애주기 ABI (신규)

현 ABI는 활성 surface 1개(`FrameSummary.surface_id`)만 노출한다. 여러 WKWebView를 관리하려면 신규가 필요하다:

- 매 tick **surface diff**: "어느 surface_id ↔ 어느 NSView, url/panel_kind/trust, 생성/숨김/파괴" — [control-plane.md] §3 엔티티·`panel.open` 생애주기와 직접 커플링.
- web surface는 **Term**이다(leaf=Pane이 아니라 Pane 안 Term). 한 Pane이 terminal Term + web Term을 가로 탭으로 섞을 수 있고, per-pane 탭바가 둘을 같이 보인다. **web Term마다 WKWebView**(한 leaf에 N개 가능, 활성만 show, 비활성 hidden으로 상태 유지). **모델 토대**: `session_model.Term.kind`(terminal|web) + `LiveSurface` `union(SurfaceKind)`(web arm=sentinel surface)로 web Term을 트리에 담고, `createWebTerm`이 PTY 없이 생성한다. **per-Term WKWebView 호스팅**: `computeWebSurfaceTransitions`가 활성 워크스페이스 탭 pane 트리를 walk해 web Term 집합(각 `{surface_id, panel_kind, 자기 pane 본문 rect, visible=자기 pane 활성 탭인가}`)을 만들고 직전 tick 집합과 `surfaceDiff`한 **batch 전이**(count+at ABI, v101)를 낸다. Swift가 `webPanels[surface_id]` dict에 create/destroy/reframe/hide/show를 적용해 web Term마다 WKWebView를 자기 pane 본문 rect에 고정한다(활성 pane 추종 완전 제거). Term 이동 시 **재부모화**는 4e-4(§10).
- Term 탭을 다른 pane으로 이동하면 WKWebView **재부모화·재프레임**.
- **터미널 링크의 착지점**(v147): 터미널에서 Cmd+클릭한 http(s) 링크는 `input.link-open-target`이 `auto`(기본)·`in-app`일 때 이 브라우저 패널로 들어온다 — 활성 탭에서 **보이는** browser Term을 재사용하고, 없으면 `auto`는 시스템 브라우저·`in-app`은 새 browser Term을 연다. 정책은 Zig(`openTerminalWebLink`)가 소유하고, 인앱 대상은 파일 패널 외부 링크와 **같은 pending action**으로 실려 Swift가 매 tick surface 전이 batch를 적용한 **뒤** drain해 `BrowserControl.navigate`한다(새 패널의 WKWebView가 준비된 다음에 load되도록 하는 순서 계약). 단일 출처는 [링크 감지](link-detection.md) §링크를 어디에 여는가.

## 7. web 특유 보안 (브리지 게이트는 control §8.1)

브리지 신뢰 게이트(isolated world·per-surface capability·forMainFrameOnly)는 **[control-plane-security.md] §8.1이 단일 출처**다. 여기서는 web 레이어에서만 발생하는 위협을 다룬다:

- **`.md`는 신뢰 콘텐츠가 아니라 "신뢰 렌더러가 그리는 비신뢰 데이터"**다. raw HTML/script 비활성 새니타이즈(`<script>`·`on*`·`javascript:` 제거)가 기본. maru가 빌드해 번들하는 렌더러 JS는 해시 핀(SRI)·락파일로 공급망 고정.
- **`maru-app://` 스킴**(이름 문법·등록 가능성 근거는 §9): 엄격 CSP 응답 헤더로 외부 네트워크·`<base>`·form-action exfil을 차단하고, frame은 번들 renderer origin `maru-app://render` 하나만 허용한다. FP10의 문자열 단일 출처는 Zig의 host-role별 `app_csp_header`/`render_csp_header`다. app role만 exact `live-preview-worker.js`를 `worker-src 'self'`로 허용·서빙하고 render role은 `worker-src 'none'`이며 worker asset 요청도 거부한다(§7.1 ③). 스킴 핸들러는 `..`·비허용 문자를 먼저 거부하고 flat bundle allowlist만 root-relative `follow_symlinks=false`로 연다. Zig가 open fd를 `fstat`해 정규 파일·worker hardlink alias·4 MiB cap을 확인하고 **같은 fd**에서 응답 bytes를 읽으므로 검증 뒤 Swift pathname 재-open은 없다. FP10b부터 물리 queued+running job은 취소를 포함해 completion까지 앱 전역 32 slot을 점유하는 serial asset queue에서만 수행하고, AppSession과 분리된 Zig I/O instance를 쓴다. MainActor는 admission과 `WKURLSchemeTask` 응답/취소만 처리해 frame tick FS I/O를 0으로 유지한다.
- **브리지 origin 격리(sanitizer 단독 의존 금지, FP4 실구현, renderer capability 승격)**: 브리지는 신뢰 viewer shell `maru-app://app` main frame에만 붙이고, md-derived 문서는 `sandbox="allow-scripts allow-same-origin"`인 `maru-app://render/render.html` iframe에서 처리한다. 읽기 모드의 document iframe뿐 아니라 라이브 프리뷰의 CM6 widget도 이 bridge-free renderer iframe이어야 하며 Markdown 파생 HTML/SVG를 shell DOM에 삽입하지 않는다. app/render의 host가 달라 서로 same-origin이 아니며 renderer page world에는 user script/message handler를 주입하지 않는다. shell은 load마다 비재사용 `renderer_instance`와 새 `MessageChannel`을 발급하고 FP11a 현재 공용 alias `RendererCapability { editor_epoch, document_revision, projection_generation, widget_id, widget_generation, renderer_instance }`가 맞는 port message만 수용한다. navigation/detach/crash/mode 전환은 port와 registry를 먼저 revoke한다. renderer page world는 asset/link action을 보낼 수 없고 trusted `AssetGrant` prefetch와 isolated-world trusted-click handler만 그 효과를 낸다. 모든 renderer navigation은 종류와 무관하게 취소하며 `anchor.click()`·synthetic event·redirect·직접 navigation은 action 0이다. actual WKWebView smoke가 document와 fragment renderer 모두 `window.maru`/`window.webkit.messageHandlers.maru`가 `undefined`, `parent.document` 접근 실패, 외부 요청 0, 물리 click/keyboard trusted activation만 action 1임을 단언한다. `allow-same-origin`은 custom-scheme ESM+SRI 실행에 필요하지만 host 분리와 이 런타임 gate 없이는 허용하지 않는다.
- **브리지 호출부 프레임 검증**: 메시지 핸들러 등록은 world-scope(frame 무관)라, 핸들러 진입에서 `frameInfo.isMainFrame` + `securityOrigin`이 **scheme=`maru-app`, host=`app`, 명시 port 없음**과 일치하는지 검사한다. 같은 Zig `appOriginAllowed` 정책을 scheme handler(assets=app|render)·navigation(main=app/subframe=render)·bridge(main=app)가 역할별로 소비한다. `browser` config에는 scheme/message handler를 등록하지 않고 `maru-app://` 네비게이션을 차단한다.
- **untrusted 패널 격리**: `browser` 패널은 신뢰 콘텐츠와 데이터스토어를 분리한다 — **실구현(7e-0·2026-07-17 정정)**: browser 탭들은 **공유 ephemeral `browserDataStore`**(탭 간 공유 = 로그인 연속성·팝업 OAuth 근거, §7e-0)이고 신뢰 persistent store와 격리된다. 초판의 "별도 WKProcessPool + per-surface ephemeral"은 stale — WKProcessPool은 최신 WebKit 자동 관리(deprecated)라 명시하지 않고, per-surface 격리는 안 하기로 결정됐다([control-plane-browser.md] §9 동일 정정). 파일 도크의 로컬 html은 FP5에서 별도 ephemeral `filePanelDataStore`로 구현됐고 browser credential을 공유하지 않는다([file-panel-kinds.md](file-panel-kinds.md) §2).
- **링크 라우팅**: browser/HTML 패널은 기존 `decidePolicyForNavigationAction` 정책을 쓴다. Markdown renderer는 모든 navigation을 취소하고, render-origin subframe에 document-start로 설치한 isolated-world capture listener가 `event.isTrusted`를 확인해 current `renderer_instance`에 묶은 one-shot link action만 Zig의 존재검증·스킴 화이트리스트로 전달한다. page-world `link-activate`, `.linkActivated` 단독 권한, 합성 click/redirect는 허용하지 않는다.
- **Mermaid 실행 격리(FP10)**: `WKProcessPool`은 macOS 12+에서 여러 인스턴스의 격리 효과가 없으므로 Mermaid timeout 경계로 쓰지 않는다. 앱은 번들된 별도 `maru-mermaid-renderer` helper process와 bounded stdin/stdout frame으로만 통신하고, helper 내부 WKWebView에는 앱 bridge/message handler·파일 경로·asset grant를 제공하지 않는다. parent의 Zig coordinator가 고르는 cold 5초/warm 2초 response deadline은 job capability revoke와 helper terminate/restart를 보장하지만 WebKit service CPU의 정확한 종료 시각은 보장한다고 주장하지 않는다. helper의 protocol·queue·서명·검증 계약은 [file-panel-dock-ui.md] §3과 [macos-app-host-boundary.md]를 따른다.

### 7.1 5c — `maru-app://` 스킴 + 엄격 CSP + 경로 샌드박스 설계

Phase 5 세 번째 슬라이스(신뢰 UI 경로)는 `maru-app://`를 안정적 origin으로 확립했고, FP4가 실제 file-panel shell/renderer asset과 제한된 iframe 정책을 연결했다.

**의존성**: 소켓 write-경로·capability 발급(1e)·1g와 **무관**(자족적 — 스킴은 in-WKWebView 콘텐츠 서빙이라 컨트롤 소켓 경로를 안 탄다). 안정적으로 독립 진전.

**① 경로 샌드박스(신규 코드 — 보안 코어)**: `sanitizeDropFilename`(cli/ssh.zig, basename+문자 필터만)은 realpath/symlink 거부를 안 하므로 **신규**다. 두 층:
- **L2 순수(헤드리스, `src/session/`)**: 요청 경로 문자열 검증 — `..`(및 인코딩 `%2e%2e`·중복 슬래시·backslash)·절대경로 탈출 거부 + 정규화 후 **허용 asset root prefix 아래인지** 확인. adversarial 단위 test(`../`·`....//`·`%2e%2e%2f`·절대·null byte·`.`만·빈 경로)로 탄탄히. 문자열 레벨이라 순수·이식성.
- **platform(macOS, 실 FS)**: 정규화된 경로를 **realpath**한 결과가 여전히 asset root 아래인지 + **symlink 탈출 거부**(realpath가 root 밖을 가리키면 거부). 실 FS I/O라 platform. macos smoke로 검증(symlink→거부).

**② 스킴 핸들러(`WKURLSchemeHandler`, platform)**: 신뢰 config에만 `setURLSchemeHandler(_, forURLScheme:"maru-app")` 등록. 요청 → ① 샌드박스 검증 → 통과면 **maru 번들 asset root**의 바이트를 읽어 **엄격 CSP 헤더**와 함께 응답, 거부면 차단(404). **뷰되는 파일 자신의 디렉터리는 안 서빙**(§7 — `script-src 'self'` 아래 공격자 디렉터리 스크립트 same-origin 로드 차단). 스킴 이름 근거=§9(RFC 3986, `WKURLSchemeHandler` 커스텀 스킴 등록 가능·소문자 고정).

**③ CSP(응답 헤더)**: 엄격 CSP를 응답에 항상 부착 — 외부 네트워크(`connect-src 'none'`)·임의 frame/worker·`<base>` 하이재킹·form-action exfil 차단. 문자열 단일 출처는 Zig의 host-role별 `app_csp_header`와 `render_csp_header`다. app은 exact same-origin worker를 위해 `worker-src 'self'`, render는 `worker-src 'none'`이고 scheme asset resolver도 `live-preview-worker.js`를 app host에만 제공한다. `script-src 'self'`, `frame-src maru-app://render`, `connect-src 'none'`, `base-uri 'none'`, `form-action 'none'`은 양쪽 다 유지한다. build integrity manifest가 shell/worker 두 bundle digest를 검증하고 HTML에는 shell SRI만 삽입한다. Swift는 Zig가 role별로 반환한 CSP를 붙일 뿐 host policy를 재판정하지 않는다. **script-src에는 어느 role도 `unsafe-inline`을 허용하지 않는다.**

**③-1 style-src의 role 분기(FP12b, 사용자 결정 2026-07-22)**: **app origin만 `style-src 'self' 'unsafe-inline'`**, render origin은 strict `style-src 'self' 'sha256-…'`(critical style hash 핀 유지). 근거: CodeMirror 6는 `syntaxHighlighting`·base theme를 style-mod StyleModule의 **런타임 `<style>` 주입**으로 넣는데, 그 내용은 URL도 고정 hash도 아니라 `'self'`/hash로 허용할 수 없어 WebKit이 *"Refused to apply a stylesheet"*로 차단한다(text/code 소스 에디터 하이라이트가 전부 기본색이 되던 근본원인 — 헤드리스 Playwright WebKit로 재현·확정). app origin은 **우리 번들만** 실행하고 파일 내용은 CM6 `Text` 문서로만 들어가 shell DOM에 HTML/CSS로 삽입되지 않으므로(§7 md-파생 격리) CSS 주입 벡터가 없어 `'unsafe-inline'`이 안전하다. render origin은 md 파생·비신뢰 HTML을 materialize하므로 strict style-src를 유지해 sanitizer 우회 시 style 주입을 막는다. CSP 규약상 hash가 있으면 `'unsafe-inline'`이 무시되므로 app에서는 hash를 제거한다. critical-background 무백색 계약(§1 file-panel)은 app에선 `'unsafe-inline'`으로, render에선 hash로 각각 인라인 허용된다.

**④ 트러스트 분기**: `markdown`(신뢰) config만 스킴 핸들러·브리지를 등록한다. `browser`(untrusted) config엔 **미등록** + `maru-app://` 네비 차단. FP4부터 markdown config는 `web/dist`의 실 shell/renderer를 로드한다.

**⑤ 자동 검증**: 경로 샌드박스 adversarial(헤드리스 Zig) + role-aware ABI raw 값(C/Zig/Swift) + 실제 scheme handler macos smoke를 required gate로 둔다. smoke는 app host의 정상 asset과 `live-preview-worker.js`가 200이고 응답 CSP가 `worker-src 'self'`인지, render host의 정상 renderer asset은 200이지만 같은 worker 경로는 거부되고 CSP가 `worker-src 'none'`인지 확인한다. 기존 `maru-app://…/../etc/passwd`·symlink 거부와 browser 패널의 `maru-app://` navigation 차단도 함께 유지한다. 문자열 상수·mock resolver만 검사하고 실제 `WKURLSchemeHandler` 응답을 통과하지 않으면 이 gate는 성공이 아니다.

**⑥ 슬라이스 경계** — 5c=스킴·경로 샌드박스, 5b=exact app-origin bridge, FP2=실 UI build, FP4=제품 asset·read bridge·격리 renderer 결합.

슬라이스와 완료 이력은 [웹 패널 구현 계획](plans/web-panel.md)이 소유한다.

## 9. 베이스와 결정 (clean-room)

- WKWebView 임베드·isolated `WKContentWorld`·`WKURLSchemeHandler`는 WebKit 표준 API. CSP·새니타이즈는 웹 보안 표준.
- 모달 오버레이 z-order는 CALayer 합성 + `hitTest` 라우팅 표준.
- **`maru-app://` 스킴 이름 확정 (근거)**: 베이스는 URI 문법 표준 [RFC 3986](https://www.rfc-editor.org/rfc/rfc3986#section-3.1) §3.1로, `scheme = ALPHA *( ALPHA / DIGIT / "+" / "-" / "." )`이다. 즉 하이픈(`-`)은 스킴 이름의 유효 문자이고(첫 글자만 `ALPHA` 강제), `maru-app`은 이 문법을 만족한다. `WKURLSchemeHandler`(`WKWebViewConfiguration.setURLSchemeHandler(_:forURLScheme:)`)는 built-in/특수 스킴(`http`·`https`·`file`·`about`·`data`·`blob`·`ws`·`wss` 등)에 대한 커스텀 핸들러 등록만 예외로 거부하므로, 커스텀 스킴 `maru-app`은 등록 가능하다. 스킴은 대소문자를 구분하지 않고 WebKit이 소문자로 정규화하므로 코드·CSP·핸들러 문자열은 전부 소문자 `maru-app`으로 고정한다(하이픈은 CSP source expression `maru-app:`에서도 유효). 결정: `maruapp`(하이픈 제거)이나 역-DNS(`app.maru`)로 바꾸지 않고 `maru-app://` 그대로 확정한다 — 사람이 읽을 때 maru 앱 내부 스킴임이 분명하고, 단일 라벨 커스텀 스킴이라 충돌 위험도 없다.
- maru 독립 설계: 모달을 Metal 오버레이로(GPU chrome 일관성), surface 생애주기 ABI, web 특유 보안 게이트.

## 11. 테스트·검증

- **자동(headless/TDD)**: 브리지 격리(`evaluateJavaScript`로 page-world `window.maru === undefined`), per-pane rect 계산(px↔pt·y-flip) 단위, surface diff 로직, WKWebView frame·NSView 계층 값 단언, CSP·경로 정규화(traversal 거부) 단위를 먼저 실패시키고 구현한다. Phase 7 웹 콘텐츠의 순수 JS/TS 로직은 Bun 내장 test runner(`bun test`, `web:test`)로 검증한다. Phase 6 WebDriver 어댑터가 아직 없으면 WKWebView 통합 E2E는 `evaluateJavaScript` 하니스로 먼저 검증하고, WebDriver가 붙은 뒤 같은 subset을 표준 WebDriver smoke로 반복한다.
- **에디터 WebKit gate**: 에디터는 markdown 라우트로 권한을 공유하지 않고 전용 `PanelKind.editor`·asset/CSP·bridge/grant를 권장한다([editor-surface.md](editor-surface.md)). 2026-07-16 PoC에서 custom scheme module/worker/diff 계산은 됐지만 현행 `style-src 'self'`가 Monaco inline style을 차단했고, 완화 뒤에도 text layout·caret·편집·한글 IME는 통과하지 못했다. 따라서 worker 성공이나 Chrome pixel parity를 제품 가능성으로 간주하지 않는다. 실제 Maru WKWebView에서 text/caret/ASCII edit/undo/한글 preedit·NFD·backspace/CSP·cleanup gate를 먼저 green으로 만들고, editor 한정 style CSP 완화는 별도 사용자 결정으로 둔다.
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

**사용자 Chrome/CDP 전략**: 인앱 웹 패널 백엔드가 아니라 **외부 브라우저 자동화 어댑터**다. 이 경로의 동작 베이스는 [references.md]의 `agent-browser`다: `agent-browser`는 CDP=Chrome, WebDriver=Safari/iOS 식의 백엔드 추상화와 navigate/evaluate/screenshot/click/find_element 등 명령 표면을 제공한다. 따라서 Maru가 agent-browser 호환을 하려면 (1) WKWebView 패널을 WebDriver 어댑터로 노출하거나([control-plane-browser.md] §9), (2) 별도 Chrome/Chrome for Testing 프로세스를 CDP로 붙이는 외부 자동화 경로를 둔다. 하지만 Google Chrome은 Maru NSView 안에 임베드할 안정 API를 제공하지 않는다. 실행은 별도 Chrome window/headless이고, Maru 패널에는 screenshot/상태를 표시할 수 있을 뿐 실제 WKWebView/CEF 같은 in-app surface가 아니다. 또한 Chrome 136+는 보안상 기본 프로필에 `--remote-debugging-port`/`--remote-debugging-pipe`를 적용하지 않고 별도 `--user-data-dir`을 요구한다. 자동화 목적이면 사용자 일상 Chrome이 아니라 Chrome for Testing 또는 별도 프로필 Chrome을 opt-in으로 띄우는 쪽이 맞다.

**Safari MCP / host-mediated 브라우저 MCP (에이전트 제어 — WKWebView 유지)**: Apple이 Safari MCP 서버(WebKit, [webkit.org/blog/18136](https://webkit.org/blog/18136/introducing-the-safari-mcp-server-for-web-developers/), Safari Technology Preview 247)를 출시했다 — `safaridriver --mcp`로 뜨고 `navigate_to_url`/`evaluate_javascript`/`get_page_content`/`browser_console_messages`/`list_network_requests`/`screenshot`/`browser_dialogs`/`create_tab`·`switch_tab` 등 도구 표면을 준다(§238 agent-browser의 "WebDriver=Safari" 경로에 대응하는 Apple 공식 표면). **단 이건 `safaridriver`(WebDriver) 기반이라 Safari.app 창/탭을 몰지, 서드파티 앱 임베드 WKWebView는 안 잡는다**(임베드 WKWebView 원격 제어는 `isInspectable`+Web Inspector 원격 프로토콜이라는 **다른 채널**). 따라서 maru의 **인앱 브라우저 에이전트 제어**는 Safari MCP를 *쓰는* 게 아니라, **그 tool 표면을 미러링한 자체 host-mediated "브라우저 MCP"** 를 [control-plane.md]에 노출한다: 각 web surface(**7f 팝업 adopt 포함**)를 `surface_id`로 주소지정하고, `evaluateJavaScript`(DOM·click·type·eval·snapshot)·`takeSnapshot`(screenshot)·`WKHTTPCookieStore`(cookies)·주입 JS(console 후킹)·KVO(nav 모니터)·`WKUIDelegate`(dialogs)로 구현한다. network까지 CDP급 깊이가 필요하면 maru WKWebView를 `isInspectable`로 켜고 Web Inspector 원격 프로토콜로 구동한다(**설계 분기**: 얕게=host-mediated JS[network 얕음] vs 깊게=Web Inspector[network 포함, 복잡] — Safari MCP의 존재가 후자가 WKWebView에서 가능함을 방증한다). **default-deny 신뢰 게이트 필수**: 팝업·탭은 임의 untrusted 콘텐츠라, 에이전트 제어는 사용자 브라우징(로그인 세션·OAuth 토큰·폼)을 **읽고 대신 조작**할 수 있어 세션 목록 조회와 차원이 다른 신뢰 표면이다 → 명시 opt-in([control-plane.md] auth 위에). 이 경로는 §236의 "외부 자동화=Chrome for Testing/CDP"와 **별개**다 — **인앱 WKWebView surface를 직접 제어**하며, 엔진 피벗(CEF) 없이 WKWebView에서 성립한다(CEF는 아래 천장에 부딪힐 때만). 라이브 E2E 배선·현재 구현 상태·남은 슬라이스는 [control-plane-browser-wiring.md](control-plane-browser-wiring.md) §9.2~§9.5를 **단일 출처**로 따르고 이 문단에서는 복제하지 않는다. 이 문단은 위협과 얕은 host-mediated 대 깊은 Web Inspector 설계 분기만 소유한다.

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
