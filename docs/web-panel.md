# 웹 패널 인프라 (WKWebView 합성·z-order·임베드)

이 문서는 Maru에 리치 웹 패널(마크다운 WYSIWYG 편집·인앱 브라우저)을 WKWebView로 임베드하는 **표시·합성·입력**의 단일 출처다. 패널을 통한 세션 제어·브리지 *계약*은 [세션 컨트롤 플레인](control-plane.md)이 소유하고, 이 문서는 "WKWebView를 maru 창에 어떻게 올리고 합성하는가"에 집중한다.

레이어 경계는 [레이어링과 이식성](layering-and-portability.md), 네이티브 뷰 비사용 예외(리치 웹 패널)는 [구현 계획](implementation-plan.md) UI 렌더 전략·[macOS 앱 호스트 경계](macos-app-host-boundary.md), 탭/split 모델은 [탭·split·레이아웃](tabs-splits-layout.md)을 단일 출처로 둔다.

> 핵심 가정은 구현 전 spike로 실측했다(2026-06): ① 투명 Metal 오버레이가 WKWebView 위에 합성(z-order) — GUI 확인, ② isolated `WKContentWorld` 브리지 격리 — headless `evaluateJavaScript` 확인. 본문의 "실측 확정"은 이 spike 결과를 가리킨다.

## 1. 확정 결정

- **웹 패널 = WKWebView subview, 모달 = 별도 Metal 오버레이 레이어.** 둘 다 단일 contentView의 NSView/CALayer 합성으로 쌓는다. (네이티브 뷰 비사용의 닫힌-열거 예외 — 마크다운 WYSIWYG·인앱 브라우저. diff는 GPU 셀. [control-plane.md] §1.)
- **z-order = 3겹 합성** (실측 확정): 터미널 Metal layer(아래) < WKWebView(중간) < 투명 Metal 오버레이(모달, 위). 투명 `CAMetalLayer`(`isOpaque=false`)가 WKWebView 위에 합성돼 모달이 웹뷰 위에 비친다.
- **모달은 NSView가 아니라 Metal 오버레이 레이어.** NSView 모달은 OS별(Win32/GTK) 재작성이라 이식성을 깬다. Metal 오버레이는 기존 셀 렌더 로직을 재사용하고 이식 시 GPU 백엔드만 교체된다(터미널 렌더와 동일).
- **브리지 보안 = isolated `WKContentWorld`** (실측 확정): 브리지를 isolated world에만 등록하면 임의 웹페이지의 page-world JS는 `window.maru`에 닿지 못하고, maru 신뢰 코드(isolated world)만 닿는다. `browser` 패널엔 미주입. 신뢰 콘텐츠는 `maru-app://` 커스텀 스킴으로 서빙한다.
- **per-pane rect ABI = 신규.** 현재 Swift는 사이드바 폭·셀 origin만 받는다. 각 web surface의 pane 사각형(x,y,w,h 포인트)을 Swift에 push하는 ABI를 추가한다.
- **콘텐츠 빌드 = zntc** (dev-only 빌드 도구 — [control-plane.md] §1).

## 2. 합성 위상

```mermaid
flowchart TD
  win["NSWindow.contentView (NSView)"]
  win --> term["터미널 Metal layer<br/>CAMetalLayer · isOpaque=true · 맨 아래"]
  term --> web["WKWebView subview(들)<br/>per-pane rect · 중간"]
  web --> ov["모달 Metal 오버레이<br/>CAMetalLayer · isOpaque=false · 맨 위"]
  ov --> idle["평소: clear(투명) + hitTest nil → 웹뷰/터미널 비침"]
  ov --> modal["모달 열림: 셀 그림 + hitTest self → 웹뷰 위에 덮음"]
```

subview 순서가 z-order다. 맨 위 오버레이는 평소 투명이라 아래 웹뷰·터미널이 비치고, 모달이 열릴 때만 그린다.

## 3. NSView 합성 계층

현재 `contentView`는 단일 `MaruMetalTerminalView`(CAMetalLayer) 하나다. 웹 패널을 위해 세 겹으로 쌓는다:

1. **터미널 Metal layer** (맨 아래): 기존 셀·사이드바·탭바·pane chrome. `isOpaque=true`.
2. **WKWebView subview** (중간): web surface마다 하나, per-pane rect에 `frame`. split이면 여러 개.
3. **모달 Metal 오버레이** (맨 위): command palette·find·confirm. `isOpaque=false`, 평소 clear(투명), 모달 열림 시에만 셀을 그린다.

**모달 레이어 분리(선행 리팩터):** 현재 모달은 터미널과 같은 render pass에서 `modal_cells_start` 분할점으로 그려진다. 이를 별도 최상위 CAMetalLayer로 옮긴다. 모달의 셀 렌더 로직·테마는 그대로 재사용하고 **대상 layer만** 분리하므로 GPU chrome 전략(네이티브 뷰 비사용)을 깨지 않는다.

## 4. per-pane rect ABI (신규)

- 현재: `terminal_origin_x_px`(사이드바 폭) + 셀별 origin만 Swift로 흐른다. per-pane 사각형은 없다.
- 신규: 각 web surface의 pane rect(x,y,w,h 포인트)를 Swift에 push. 레이아웃 변경(resize·split·사이드바 폭·탭 스크롤) 시 갱신한다.
- Swift는 그 rect로 해당 WKWebView의 `frame`을 맞춘다. 좌표 계산(셀↔px, pane 기하)은 Zig가 소유한다([macos-app-host-boundary.md] 정책 — Swift는 OS 호출만).

## 5. frame 동기화

- 레이아웃 변경마다 per-pane rect → WKWebView `frame`.
- 탭 전환: 활성 web surface만 보이게(`isHidden=false`), 비활성은 `isHidden=true`(WKWebView가 살아 있어 스크롤·로그인·재생 상태 유지).
- split: leaf마다 WKWebView를 각 rect에 둔다.

## 6. 입력·포커스·hitTest

- WKWebView가 포커스를 가지면 키 입력은 웹뷰로 간다. maru 앱 키바인딩(⌘T·⌘W 등)은 먼저 가로채고 나머지는 웹뷰로 보낸다.
- 모달 오버레이의 입력 라우팅: 평소 `hitTest`가 `nil`을 반환해 이벤트가 아래 웹뷰로 통과하고, 모달 열림 시 `self`를 반환해 이벤트를 잡는다(실측 spike의 `OverlayView.hitTest` 패턴).

## 7. 신뢰 게이트·브리지 (실측 확정)

- 브리지(`window.maru.*`)는 **isolated `WKContentWorld`에만** 등록한다 — 페이지의 page-world JS(임의 웹사이트·광고 iframe 포함)는 브리지를 보지 못한다.
- 신뢰 콘텐츠(마크다운 UI 등)는 maru가 빌드해 **`maru-app://` 커스텀 스킴**으로 서빙한다. maru의 기능 주입은 isolated world에서 `evaluateJavaScript`로 한다.
- `browser` 패널(임의 URL)은 `trust=untrusted`로 브리지를 **주입하지 않는다**.
- 실측: 임의 페이지(page-world)에서 `window.webkit.messageHandlers.maru`가 `undefined`, isolated world에서만 접근·호출 가능함을 확인했다.

## 8. 생명주기

- 탭 전환: 활성 show / 비활성 hide(상태 유지).
- 세션 종료: 해당 WKWebView teardown.
- 멀티윈도우: 각 AppSession(창)이 자기 web surface·오버레이를 가진다. quick terminal은 별도 NSPanel이라 자기 합성 스택을 갖는다.

## 9. 베이스와 결정 (clean-room)

- WKWebView 임베드·isolated `WKContentWorld`·`WKURLSchemeHandler`(커스텀 스킴)는 WebKit 표준 API.
- 모달 오버레이 z-order는 CALayer 합성 표준(네이티브 오버레이가 웹뷰 위로 그려지는 일반 패턴) + `hitTest` 라우팅.
- maru 독립 설계: 모달을 NSView가 아닌 **Metal 오버레이 레이어**로(이식성), per-pane rect ABI, 신뢰 게이트.

## 10. 구현 ([control-plane.md] Phase 4~5와 연계)

- **Phase 4(껍데기)**: NSView 3겹 합성 + per-pane rect ABI + 모달 레이어 분리 + 빈 WKWebView가 탭/split 추종.
- **Phase 5(브리지)**: isolated world 브리지 + `maru-app://` 스킴 + [control-plane.md] `browser.*` 연결.

## 11. 테스트·검증

- **자동(headless)**: 브리지 격리(`evaluateJavaScript`로 page-world `window.maru === undefined` 단언), per-pane rect 계산(셀↔px) 단위, WKWebView `frame`·NSView 계층(z-order 순서) 값 단언.
- **수동/시각**: z-order 픽셀 합성(모달이 웹뷰 위에 비침 — spike로 확인), frame 추종은 GUI에서 눈 확인.
- 합성 스크린샷은 `CGWindowListCreateImage`가 macOS 15+에서 제거됐으므로 ScreenCaptureKit 또는 GUI 수동 확인을 쓴다(headless 환경은 시각 캡처 불가).

## 12. 리스크

- 모달 레이어 분리 리팩터(현재 단일 render pass) — Phase 4 선행.
- 이식: WebKitGTK(Linux)·WebView2(Windows) 위에 GPU 오버레이를 합성하는 건 OS별 컴포지터(DirectComposition·GTK) 검증이 필요(미래).
- per-pane rect ABI 신규 배선.
- 투명 `CAMetalLayer` 오버레이는 maru 렌더러가 `isOpaque=true` 가정이라 오버레이용 별도 설정이 필요(spike로 가능 확인, 통합 시 재확인).

## 13. 미래: 웹뷰 백엔드 추상화 + CEF opt-in 플러그인 (이번 범위 밖)

WKWebView(WebKit)는 시스템 프레임워크라 의존성이 없지만 **Chromium 호환·CDP 생태계 검증이 제약**된다. 미래에 CEF(Chromium Embedded Framework)를 대안 백엔드로 두되, **기본 번들에 넣지 않고 opt-in 플러그인으로** 한다 — 기본 maru는 WKWebView만 써 의존성 0을 유지하고, CEF를 원하는 사용자만 설치한다. maru `plugin.zig`(현재 스텁)가 토대.

**플러그인 설치 모델:**
1. 설정/명령에서 "CEF 웹뷰 설치" → CEF "minimal" 바이너리 + helper를 다운로드(suji 선례: Spotify CDN) → `~/.cache/maru/cef/<platform>/`.
2. maru는 빌드 타임 정적 링크가 아니라 **런타임에 발견한** CEF를 백엔드로 활성화한다.
3. 웹 패널이 백엔드 인터페이스 뒤에 있어, 백엔드를 WKWebView(기본)↔CEF(설치 시)로 바꿔도 콘텐츠·`browser.*`는 그대로다.

**백엔드 인터페이스(추상화 대상):** `mount`(pane rect에 붙이기)·`navigate`·`eval`·`snapshot`·`frameSync`·`bridge`(메시지 in/out)·`teardown`. WKWebView·CEF가 각자 구현.

**WKWebView vs CEF (suji 선례 기반):**

| 축 | WKWebView (기본) | CEF (플러그인) |
|---|---|---|
| 엔진 | WebKit(Safari) | Chromium(Chrome) |
| 번들 | 시스템(추가 0) | 150~200MB + helper 5개 — **별도 다운로드** |
| Chrome 호환·검증 | 제약 | 완전 |
| CDP | 없음(WebDriver 어댑터 직접 — [control-plane.md] §9) | 네이티브(`send_dev_tools_message`) — agent-browser·Selenium 직접 호환 |
| 합성 모델 | contentView **subview**(실측 확정) | **CEF Views child window attach**(suji 17-A NSView 직접 합성→멀티뷰 강종→17-B) |
| 이식성 | OS별 API 상이 | 3-OS 통일 C API(`@cImport`) |
| 의존성 정신 | 부합 | 플러그인이라 **기본 0 유지**, 설치 시에만 |

**플러그인 모델의 함정(정직):**
- **"즉시 삽입"보다 재시작이 현실적.** CEF는 프로세스 시작 초기에 `CefInitialize` + helper 프로세스(같은 exe 재실행 또는 별도 helper 번들)를 요구한다. 실행 중 `dlopen`으로 끼우는 건 프로세스 모델상 어려울 수 있어 **"설치 → 재시작 → CEF 백엔드 활성"**이 안전한 1차 모델이다(런타임 즉시 로드는 별도 검증).
- **helper 프로세스**: maru가 CEF helper(렌더/GPU 등 5개)를 띄워야 한다. macOS는 helper가 별도 `.app`이라 서명 대상.
- **서명/공증**: 다운로드한 CEF dylib·helper를 maru가 로드/실행 → Gatekeeper. 서명 검증 또는 사용자 승인 흐름이 필요.
- **버전 호환**: CEF 버전 ↔ maru `@cImport` 헤더 호환. 플러그인 버전 핀·체크.

**결정 미정**: 도입 여부·시점은 사용자가 정한다. 지금은 백엔드 인터페이스 경계만 의식해 WKWebView 구현이 CEF 플러그인을 막지 않게 한다.

## 14. 코드 위치 (구현 시 채움)

- 합성·WKWebView·브리지: `platform/macos/web_panel.{zig,swift}`
- per-pane rect ABI: `platform/macos/app_host_abi.{zig,h}`
- 모달 레이어 분리: `platform/macos/maru_metal_renderer.{h,m}`(별도 오버레이 layer), `renderer/metal_frame.zig`
