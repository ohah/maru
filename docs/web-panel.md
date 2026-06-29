# 웹 패널 인프라 (WKWebView 합성·입력·임베드)

이 문서는 Maru에 리치 웹 패널(마크다운 WYSIWYG 편집·인앱 브라우저)을 WKWebView로 임베드하는 **합성·입력·web 특유 보안**의 단일 출처다. **세션 제어·브리지 신뢰 게이트 계약은 [세션 컨트롤 플레인](control-plane.md) §8이 소유**하고, 이 문서는 "WKWebView를 maru 창에 어떻게 올리고·입력을 라우팅하고·web 특유 위협을 막는가"에 집중한다(브리지 게이트를 여기서 재서술하지 않는다).

레이어 경계는 [레이어링과 이식성](layering-and-portability.md), 네이티브 뷰 비사용 예외(리치 웹 패널)는 [구현 계획](implementation-plan.md) UI 렌더 전략·[macOS 앱 호스트 경계](macos-app-host-boundary.md), 탭/split 모델은 [탭·split·레이아웃](tabs-splits-layout.md)을 단일 출처로 둔다.

> **spike로 실측한 범위(2026-06)**: ① 투명 Metal 오버레이가 WKWebView 위에 합성되는 **z-order 순서**(GUI), ② isolated `WKContentWorld`에서 임의 page-world JS가 브리지에 못 닿음(headless). **그 둘만** 확인했다. 입력/firstResponder 라우팅·실제 셀 모달 합성·드래그 인터랙션·per-pane 좌표계는 **미검증 리스크**(§12)다.

## 1. 확정 결정

- **웹 패널 = WKWebView subview, 모달 = 별도 Metal 오버레이 레이어.** 단일 contentView를 컨테이너로 바꾸고 3겹으로 합성한다(§2).
- **z-order(WKWebView subview 모델 전용)**: 터미널 Metal layer(아래) < WKWebView(중간) < 투명 Metal 오버레이(모달, 위). **spike로 순서 합성만 확인**. 실제 셀 모달(텍스트·둥근 모서리·그림자·테마)을 투명 layer에 그린 합성은 Phase 4 종료 게이트에서 GUI 골든으로 1회 확정한다(§11).
- **모달은 NSView가 아니라 Metal 오버레이 레이어** — GPU chrome 철학(셀 렌더 재사용) 일관성 때문이다. **"이식성" 때문이 아니다**: "네이티브 웹뷰 위 GPU surface 합성"은 OS별 컴포지터 문제(macOS=CALayer subview, Windows WebView2=별도 HWND, Linux=Wayland subsurface)라 다른 OS에선 합성 모델을 타깃 시점에 재결정한다([layering-and-portability.md] §4 "호스트는 타깃별 신규").
- **입력 라우팅은 합성과 별개의 1급 문제다**(§4) — "layer만 분리"가 아니다. 모달이 그려지는 것과 키 입력이 모달에 가는 것은 다르다.
- **web 특유 보안**(§7): `maru-app://` 콘텐츠에 엄격 CSP + 스킴 핸들러 경로 샌드박스, `.md`는 "신뢰 렌더러가 그리는 **비신뢰 데이터**"(새니타이즈), untrusted 패널은 데이터스토어·프로세스 격리. **브리지 신뢰 게이트 자체는 [control-plane.md] §8.1 단일 출처.**
- **프론트엔드 개발환경 = zntc** (dev server/preview/build/bundle, dev-only, 확정). `web/` 하위 Bun workspace는 패키지 설치·락파일·script 실행·프론트엔드 단위 테스트(`bun test`)를 맡는다. JS/TS 품질 게이트는 VoidZero/Oxc 계열의 `oxlint`·`oxfmt`를 쓴다. Vite+에는 모노레포 config·task runner가 있지만, 전체 도입은 zntc 개발환경과 Bun test runner와 역할이 겹치므로 기본값에서 제외하고 필요 시 Vite Task만 별도 검토한다. **CEF는 미래 native webview-backend plugin 후보**(일반 Wasm/action plugin 아님 — §13).

## 2. 합성 계층

현재 `contentView`는 단일 `MaruMetalTerminalView`(CAMetalLayer)이고, 이 뷰가 firstResponder로 keyDown·IME·마우스·DnD·hover를 전부 받는다. 웹 패널을 위해 **contentView를 컨테이너 NSView로 바꾸고** 세 겹을 쌓는다:

1. **터미널 Metal layer**(맨 아래): 기존 셀·사이드바·탭바·pane chrome. `isOpaque=true`.
2. **WKWebView subview(들)**(중간): web Term마다 하나, **본문 rect**에만(§5). split이면 여러 개.
3. **모달 Metal 오버레이**(맨 위): command palette·find·confirm. `isOpaque=false`, 평소 clear(투명), 모달 열림 시에만 셀을 그린다.

**모달 레이어 분리는 두 개의 선행 리팩터다**(Phase 4 선행, 가벼운 작업이 아님):
- **(a) 렌더러 분할**: 현재 모달은 터미널과 같은 cells 배열·같은 draw pass에서 `modal_cells_start` 인덱스로만 갈린다. over-quad(`layer=1`)·그림자·`modal_clip_*`(scissor, ABI v84)이 모두 same-pass 전제다. 이를 `drawTerminal(layer, cellSubset)` / `drawOverlay(layer, modalCells+quads+shadow)` 두 패스로 재분할하고, 두 CAMetalLayer의 drawable·redraw·**generation 게이팅을 독립 추적**한다(현 `lastSeenMetalGeneration` 단일 가정 변경). modal-clip 인프라 재배선 대상.
- **(b) 호스트 재편**: contentView를 컨테이너로, 입력 responder를 명시 위임(§4). 오버레이용 `isOpaque=false` + transparent clear 분기(터미널 전용 `terminal_bg`/opacity clear와 별도).

## 3. 좌표계와 frame 동기화

- **기하는 이미 Zig에 있다.** 셀별 `origin_x/origin_y`·`terminal_origin_x_px`로 split pane별 픽셀 origin을 export하고, pane rect(w,h)는 `paneTermRect`가 내부 보유. per-pane rect는 새 수학이 아니라 **기존 내부값 노출 + surface 생애주기**다(§6).
- **좌표계**: 모든 ABI 좌표는 **backing-px·좌상단 원점**이고 WKWebView `frame`은 **포인트·좌하단 원점**이다. ABI는 px로 export하고, **Swift가 `firstRect` 선례대로 px→pt + y-flip**을 한다(기존 관행). backing-scale 변경 시 rect + drawable을 원자적으로 갱신.
- **frame 동기화 트리거**: resize·split·사이드바 폭·탭 스크롤뿐 아니라 **divider 드래그 live-resize·pane zoom·pane/Term 드래그·워크스페이스 전환**까지. 매 변경 시 본문 rect → WKWebView frame.
- **async desync**: 터미널 Metal은 tick(30Hz)에 동기 repaint하지만 WKWebView frame은 AppKit 레이아웃 + WebKit **비동기** 재레이아웃을 거쳐 라이브 resize 중 한 박자 늦는다(jitter). 라이브 resize/divider 드래그 중에는 WKWebView를 `isHidden` 또는 스냅샷으로 가린다.

## 4. 입력·firstResponder·키 라우팅 (BLOCKER 해소)

합성만으로는 부족하다 — WKWebView가 포커스를 쥐면 `keyDown`/`performKeyEquivalent`가 WKWebView로 가고 Metal 뷰로 오지 않는다. 그러면 모달이 오버레이에 그려져도 키가 안 간다. 다음을 정한다:

- **모달 firstResponder 전이**: 모달(palette/find/confirm/rename) 열림 시 입력 responder를 **오버레이(또는 Metal 뷰)로 makeFirstResponder**, 닫힘 시 직전 WKWebView로 복원. 모달 입력·IME preedit가 이 경로로 흐른다.
- **maru 키바인딩 가로채기**: ⌘T·⌘W·⌘1.. 등 앱 액션은 WKWebView 포커스 중에도 먼저 잡아야 한다. WKWebView 서브클래스의 `performKeyEquivalent` override 또는 local event monitor로 — 메커니즘을 하나 택해 명시(현 코드는 오버레이 중 메뉴 keyEquivalent를 일부러 우회하므로 그 경로와 정합 필요).
- **`anyOverlayOpen` 게이트**: 웹 패널 포커스 시 "활성 세션"이 무엇인지 정의해 게이트가 올바른 surface를 읽게 한다.
- **마우스(hitTest)**: 모달 오버레이는 평소 `hitTest=nil`(아래로 통과), 모달 열림 시 `self`(잡음).
- **Phase 4 코딩 전 입력 responder spike 선행**(가장 깨지기 쉬운 IME 코드를 건드리므로): WKWebView 포커스 중 모달 열림 → responder 전이 → IME preedit → 복귀를 실측해 메커니즘(`performKeyEquivalent` override vs local event monitor)을 **착수 전에 확정**한다. 자동 테스트가 어려워 spike+수동이 유일 안전망이다.

## 5. WKWebView가 막는 터미널-chrome 인터랙션

z-order상 모달(최상위)을 제외한 모든 터미널 마우스 인터랙션이 웹 pane 위에서 WKWebView에 가로채인다. 다음을 정한다:

- **WKWebView frame을 본문 rect로 한정**한다 — pane 탭바·divider seam·pane grip은 Metal 노출 영역으로 남겨 마우스가 닿게.
- **drop-zone split 생성**(Term 탭을 본문 4분할에 드롭)은 드래그 중 대상 WKWebView를 `isHidden`/`hitTest nil`로 임시 통과시키고, drop-zone 하이라이트는 **모달 오버레이(최상위)**에 그린다(터미널 Metal 레이어에 그리면 WKWebView에 가림).
- **divider 드래그·hover 커서**(↔/grip)도 본문 한정 + 드래그 중 통과로 처리.

## 6. surface 식별·생애주기 ABI (신규)

현 ABI는 활성 surface 1개(`FrameSummary.surface_id`)만 노출한다. 여러 WKWebView를 관리하려면 신규가 필요하다:

- 매 tick **surface diff**: "어느 surface_id ↔ 어느 NSView, url/panel_kind/trust, 생성/숨김/파괴" — [control-plane.md] §3 엔티티·`panel.open` 생애주기와 직접 커플링.
- web surface는 **Term**이다(leaf=Pane이 아니라 Pane 안 Term). 한 Pane이 terminal Term + web Term을 가로 탭으로 섞을 수 있고, per-pane 탭바가 둘을 같이 보인다. **web Term마다 WKWebView**(한 leaf에 N개 가능, 활성만 show, 비활성 hidden으로 상태 유지).
- Term 탭을 다른 pane으로 이동하면 WKWebView **재부모화·재프레임**.

## 7. web 특유 보안 (브리지 게이트는 control §8.1)

브리지 신뢰 게이트(isolated world·per-surface capability·forMainFrameOnly)는 **[control-plane.md] §8.1이 단일 출처**다. 여기서는 web 레이어에서만 발생하는 위협을 다룬다:

- **`.md`는 신뢰 콘텐츠가 아니라 "신뢰 렌더러가 그리는 비신뢰 데이터"**다. raw HTML/script 비활성 새니타이즈(`<script>`·`on*`·`javascript:` 제거)가 기본. maru가 빌드해 번들하는 렌더러 JS는 해시 핀(SRI)·락파일로 공급망 고정.
- **`maru-app://` 스킴**: 엄격 CSP 응답 헤더(`default-src 'none'; script-src 'self'; img-src 'self' data:; connect-src 'none'; frame-src 'none'`)로 외부 네트워크·iframe 차단(exfil 방지). 스킴 핸들러는 **경로 정규화 후 허용 루트 prefix 검증**(realpath·symlink 거부·`..` 차단). 단 기존 `sanitizeDropFilename`(`cli/ssh.zig`)은 basename+문자 필터만 하고 realpath/symlink 거부는 **하지 않으므로 이 경로 샌드박스는 신규 코드**다(선례는 부분 참고). `.md`마다 고유 origin(uuid 호스트)로 신뢰 UI와 분리.
- **브리지 호출부 프레임 검증**: 메시지 핸들러 등록은 world-scope(frame 무관)라, 핸들러 진입에서 `frameInfo.isMainFrame` + `securityOrigin == maru-app://`를 검사한다(서브프레임·clickjacking 방지).
- **untrusted 패널 격리**: `browser` 패널은 신뢰 콘텐츠와 **별도 `WKProcessPool` + `WKWebsiteDataStore`(per-surface ephemeral)** 강제 — content process·쿠키 jar 분리(렌더러 침해가 신뢰 브리지 힙에 못 닿게, 쿠키 공유 차단).
- **링크 라우팅**: 웹 패널 링크 클릭은 `decidePolicyForNavigationAction`에서 인터셉트해 [링크 감지](link-detection.md)의 존재검증·스킴 화이트리스트·명시 제스처 정책을 재사용한다(`file:///X.app` 실행 등 차단).

## 8. 빠진 기능 (구현 시 필수)

- **테마/다크모드 동기화**: 터미널은 `viewDidChangeEffectiveAppearance`로 테마 교체. 웹 패널 콘텐츠(maru-app:// UI)가 maru 테마·다크/라이트를 따르도록 브리지로 CSS 변수/토큰 주입.
- **⌘F 분기**: 포커스가 터미널이면 maru find(스크롤백), 웹 패널이면 페이지 내 find. 포커스 기준 라우팅 명시.
- **컨텍스트 메뉴**: WKWebView 기본 우클릭 메뉴(Inspect Element 포함)는 "chrome는 Zig" 원칙·보안과 충돌 → 억제 또는 maru 메뉴로 대체.
- **접근성(AX)**: WKWebView는 네이티브 AX 트리, 터미널·모달(Metal)은 없음 → 혼합 상태. 마크다운 편집기에 AX 필요.
- **콘텐츠 프로세스 크래시 복구**: `webContentProcessDidTerminate` 시 reload·에러 상태.
- **폰트/줌·인쇄**: 저우선.

## 9. 베이스와 결정 (clean-room)

- WKWebView 임베드·isolated `WKContentWorld`·`WKURLSchemeHandler`는 WebKit 표준 API. CSP·새니타이즈는 웹 보안 표준.
- 모달 오버레이 z-order는 CALayer 합성 + `hitTest` 라우팅 표준.
- maru 독립 설계: 모달을 Metal 오버레이로(GPU chrome 일관성), surface 생애주기 ABI, web 특유 보안 게이트.

## 10. 구현 ([control-plane.md] Phase 4~5와 연계)

- **Phase 4(껍데기)**: 컨테이너 contentView + 입력 responder 재편(§4) + 모달 레이어 분리 두 리팩터(§2) + surface 생애주기 ABI(§6) + per-pane rect(§3) + 빈 WKWebView가 본문 rect 추종. → [control-plane.md] §11 Phase 4가 이 규모(특히 모달 분리·입력 재편)를 포함하도록 정합.
- **Phase 5(브리지)**: isolated world 브리지 + `maru-app://` 스킴 + CSP + 경로 샌드박스 + [control-plane.md] `browser.*`·§8.1 게이트 연결. (마크다운 sanitizer adversarial fixture는 마크다운 콘텐츠가 생기는 [control-plane.md] Phase 7와 함께 — §11.)

## 11. 테스트·검증

- **자동(headless)**: 브리지 격리(`evaluateJavaScript`로 page-world `window.maru === undefined`), per-pane rect 계산(px↔pt·y-flip) 단위, surface diff 로직, WKWebView frame·NSView 계층 값 단언, CSP·경로 정규화(traversal 거부) 단위. Phase 7 웹 콘텐츠의 순수 JS/TS 로직은 Bun 내장 test runner(`bun test`, `web:test`)로 검증한다.
- **Phase 7 markdown sanitizer adversarial fixture**: `.md` 입력은 비신뢰 데이터이므로 raw HTML/script 제거를 단위+웹 콘텐츠 테스트로 고정한다. 최소 red fixture: `<script>`, `onerror`/`onclick`, `javascript:` URL, `<iframe>`/`srcdoc`, 외부 `http(s)` 리소스. 기대값은 "DOM에 실행 가능한 sink가 남지 않고, CSP 위반 없이 안전한 텍스트/허용 태그만 렌더"다.
- **수동/시각**: z-order 픽셀 합성(실제 셀 모달 × 투명 오버레이 × 실콘텐츠 WKWebView)은 **CI 자동 불가**(`CGWindowListCreateImage` macOS 15+ 제거, ScreenCaptureKit은 TCC 권한·GUI 필요) → **GUI 골든 1 frame을 Phase 4 종료 게이트**로 둔다.
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

- 합성·WKWebView·입력: `src/platform/macos/web_panel.{zig,swift}`
- surface 생애주기·per-pane rect ABI: `src/platform/macos/app_host_abi.{zig,h}`
- 모달 레이어 분리: `src/platform/macos/maru_metal_renderer.{h,m}`(별도 오버레이 layer·2패스), `src/renderer/metal_frame.zig`
- web 보안(스킴·CSP·새니타이즈): `src/platform/macos/web_panel.swift`(WKURLSchemeHandler), 콘텐츠 번들(zntc)
