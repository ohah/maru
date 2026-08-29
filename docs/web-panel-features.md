# 웹 패널 — 빠진 기능 (§8)

웹 패널이 제품으로 서려면 반드시 채워야 하는 기능의 계약이다. 어느 슬라이스에서 구현했는지는 [웹 패널 구현 계획](plans/web-panel.md)이 소유한다. 웹 패널 전체의 진입점은 [웹 패널 인프라](web-panel.md)다.

> **절 번호는 파일을 넘어 이어진다.** 본문이 `§7.1`처럼 절만 가리키면 아래에서 소유 파일을 찾는다 — §1~§7·§9·§11~§13 [web-panel.md](web-panel.md) · §8 [빠진 기능](web-panel-features.md) · §10·§14 [구현 계획](plans/web-panel.md)

## 8. 빠진 기능 (구현 시 필수)

- **browser chrome UI (주소창·nav — `browser` kind 전용, 슬라이스 7e)**: WKWebView는 **네비게이션 UI를 제공하지 않는다**(Safari.app의 주소창·버튼은 Safari 앱 자체 chrome이지 WKWebView가 아님; SFSafariViewController의 내장 chrome은 iOS 전용·모달이라 embed 불가). 단 **nav 함수는 공짜**다 — `goBack()`/`goForward()`/`canGoBack`/`canGoForward`/`reload()`/`load(URLRequest)`/`url`/`title`/`backForwardList`/`estimatedProgress`를 WKWebView가 주고 WebKit이 히스토리·백스택을 소유한다. 그래서 maru는 **UI 껍데기만** 만든다: "chrome=Zig+GPU" 원칙대로 **탭바처럼 GPU 셀로 back/forward/reload 버튼 + 주소창**을 그리고, 버튼→ABI→WKWebView API를 호출한다(`canGoBack`/`canGoForward`로 버튼 활성/비활성). **주소창 2모드**: **① 비활성(읽기전용)** = 현재 `url`만 표시(입력 불가 — 위치 확인용, 임의 URL 입력 보안면 없음), **② 편집** = URL 입력 → `load`(임의 웹 로드라 §7 보안 — untrusted 프로세스 격리·`decidePolicyForNavigationAction` 링크 라우팅 — 동반, Phase 5 security 이후). `panel.navigated`(control §11 이벤트)/navigation delegate로 URL·progress 갱신. markdown kind는 주소창 불요라 kind별 분기(닫힌 열거).

  슬라이스와 완료 이력은 [웹 패널 구현 계획](plans/web-panel.md)이 소유한다.
- **새 창/팝업 (`target=_blank`·`window.open`) — browser kind**: WKWebView는 페이지가 새 창을 요청하면 `WKUIDelegate.webView(_:createWebViewWithConfiguration:for:windowFeatures:)`를 **동기 호출**한다(§8 링크 라우팅 `decidePolicyForNavigationAction`은 **같은 뷰 내 top-level 이동**만 — 새 창은 이 **다른 경로**다). 현재 maru엔 `WKUIDelegate`가 없어 새 창이 **무동작**이다(7e 범위 밖 — 단일 패널 브라우징만).

  **결정: adopt(1급 surface화) — '같은 패널 대체' 기각(근거).** 같은 패널에 새 URL을 덮으면 (a) "새창 열고 다시 리턴"이 불가하고, (b) 에이전트가 주소지정할 별도 대상이 없다 → 목표(일반 브라우저 새창 UX **+ 에이전트 제어**)에 미달. → **`createWebViewWith`가 만든 WKWebView를 maru web term/surface로 등록**해, 사용자에겐 새 browser **탭**, 에이전트에겐 `surface_id`로 **addressable**하게 한다. 이 둘을 동시에 주는 유일한 방식이다.

  **베이스(WebKit 계약)**: 넘어온 `configuration`은 발신 webview config의 **복사본**이고, `window.opener`·named-window·`postMessage` 링크가 성립하려면 반환 WKWebView를 **그 config 그대로**(수정 금지) 생성해야 한다. browser 패널 config는 공유 ephemeral `browserDataStore`(7e-0)를 **config 레벨**에 두므로, 팝업 config 복사본이 같은 데이터스토어를 이어받아 **세션·쿠키 공유(OAuth 연속성)** 가 성립한다(검증 완료). 스킴 핸들러는 browser 패널엔 미등록이라 무관.

  **소유·시점 역전(핵심 난점)**: maru 정상 흐름은 *Zig가 term 생성 → tick → Swift가 maru config로 WKWebView lazy 생성*이다. 팝업은 반대 — Swift가 **동기**로 WebKit config webview를 만들어 반환하고, 그걸 Zig 트리에 **사후 등록(adopt)** 해야 한다. 따라서 (i) **Swift-first '외부 생성 web term 등록' ABI**(활성 pane 탭에 browser web Term 삽입 + `surface_id` 반환), (ii) `drainWebSurfaceTransition`의 create 전이가 이 surface_id엔 WKWebView를 **중복 생성 안 함**(이미 Swift가 만든 것 존재), (iii) `MaruWebPanelView`의 **adopt init**(주어진 webview 채택 + 인스턴스 설정[`navigationDelegate`·`navObservers`·autoresizing·`seamEdges`] 재적용)이 필요하다.

  **행선지·생애주기·보안**: 새 **탭**에 넣는다(maru는 터미널 — 떠다니는 창이 아니라 탭 모델; `windowFeatures` 크기·위치 힌트는 무시). opener↔팝업 **쌍**은 둘 다 1급 surface라 hide/show(배경 탭)·move(reparent 4e-4)·close가 기존 전이 모델로 처리된다(`isHidden`은 web 프로세스를 안 죽여 opener 유지). 팝업도 untrusted 격리(공유 ephemeral store)·`decidePolicyForNavigationAction` 스킴 화이트리스트를 적용하고, `createWebViewWith` 게이트로 **browser(비신뢰) 패널의 http/https 대상만** 허용한다(신뢰 maru-app UI의 창 생성 차단; user-gesture 없는 팝업은 팝업 차단기처럼 게이트/알림).

  슬라이스와 완료 이력은 [웹 패널 구현 계획](plans/web-panel.md)이 소유한다.

  **에이전트 제어와의 연결**: 팝업을 1급 surface(`surface_id`)로 adopt하는 것이 곧 **에이전트가 팝업까지 제어**할 수 있는 전제다 — host-mediated 브라우저 MCP가 각 surface(팝업 adopt 포함)를 `surface_id`로 주소지정한다. 프로토콜 결정과 남은 5f 재슬라이싱은 [control-plane-browser-wiring.md](control-plane-browser-wiring.md) §9.2~§9.5를 **단일 출처**로 따르며, 이 문단에서 진행 상태를 복제하지 않는다. §13의 host-mediated vs Web Inspector 분기도 같은 경계를 따른다.
- **파일 패널(마크다운·HTML 뷰어/편집기)**: 로컬 `.md`/`.html`을 여는 파일 패널 — 파일 탭·헤더 밴드·파일 트리 = GPU chrome, 브리지 `file.read/write`, CodeMirror 6 편집 — 은 [file-panel.md](file-panel.md)를 단일 출처로 둔다(§7 브리지 origin 격리·§4 포커스 불변식과 상호작용). **현행(FP1~FP15)**은 창 레벨 전역 도크 슬롯(우측|하단)이라 워크스페이스 pane 트리 밖이고 §2 destroy 규칙의 비대상이다. **FP16 목표**는 파일을 워크스페이스 Term(`web_panel_kind = .file`)으로 옮기고 도크를 탐색기 전용으로 축소하는 것이며, 그 때 파일 패널은 §2 규칙의 **정상 대상이 되고 대신 그 규칙의 destroy가 hidden 보존으로 바뀐다**(§2 FP16 항목). 웹 브라우저(`browser` kind)는 이 문서 그대로 워크스페이스 term이고, 전환 시 흰 페이지가 되던 문제는 FP16 §4가 함께 해소한다(별도 URL 기억·재로드 백로그는 폐기).
- **배경 정합**: 신뢰 Markdown 파일 패널의 **초기 paint**는 [file-panel.md](file-panel.md) §1 계약대로 생성 시 공개 API `underPageBackgroundColor`와 hash-pinned critical CSS를 함께 써 기본 흰 backing을 노출하지 않는다. 반면 터미널·chrome이 반투명(`window.opacity<1`)인 창에서 임의 browser/로컬 HTML 본문까지 투명화할지는 여전히 별도 결정이다. 그 경우에도 공개 API `underPageBackgroundColor`(macOS 12+)만 쓰고, `drawsBackground`는 비공개 KVC 키라 의존하지 않는다.
- **테마/다크모드 동기화**: 터미널은 `viewDidChangeEffectiveAppearance`로 테마 교체. 웹 패널 콘텐츠(maru-app:// UI)가 maru 테마·다크/라이트를 따르도록 브리지로 CSS 변수/토큰 주입.
- **⌘F 분기**: 예전에는 **웹/마크다운 탭에서도 ⌘F가 터미널 스크롤백 find를 열었다**
  (우상단 오버레이). `toggleFind`가 활성 서페이스 종류를 보지 않았고, 그 오버레이는 웹 콘텐츠를 검색하지 못했다
  (사용자 제보). 지금은 **같은 오버레이가 대상만 바꾼다** — 활성 탭이 웹이면 질의가 그 페이지로 나간다.

  - **라우팅 기준은 포커스가 아니라 `activeWebSurfaceIdAnyKind`(활성 pane의 web 탭, browser·markdown 모두)다.**
    ⚠️ `activeWebSurfaceId`가 **아니다** — 그건 browser 전용이라 **마크다운 뷰어 탭에서 0을 돌려주고**, 제보된 그 버그가
    그대로 남는다(제보는 마크다운 탭이었다). 위 §8의 원래 서술("포커스 기준")을
    **정정한다** — §7e-4가 ⌘R에서 같은 함정을 이미 겪었다: 브라우저 탭을 활성화해도 webView에 자동 포커스를 주지
    않으므로 `isWebPanelFocused`로 게이트하면 **"탭 열어 보기만 하면 안 됨"**이 된다(제보로 드러났다). ⌘F도 같다.
  - **UI는 기존 find 오버레이를 재사용한다.** 새 검색 UI를 만들지 않는다 — 사용자가 아는 입력·Enter/Shift+Enter·⌘G
    네비게이션을 그대로 쓰고, **질의를 어디로 보낼지만** 활성 서페이스가 정한다(상태바 브랜치 메뉴가 "이미 있는
    표면을 재사용"한 것과 같은 규율). 대상은 `find.State.target`이 들고, **tick이 매 프레임
    동기화한다** — 전환 경로(탭·pane·창·탭 닫기)마다 세우면 반드시 빠뜨리는 문이 남기 때문이다.
    **값은 셋이다: `scrollback|page|editor`** — 네이티브 편집기 문서 검색이 2026-08-23에 같은 자리로
    들어왔다(../docs/native-editor-visual-mapping.md §5.1이 그 값을 소유한다). 이 절이 정한 규율
    (매 프레임 동기화·열림 여부로 게이트 안 함·대상이 바뀌면 지난 목록을 버림)은 셋 다에 그대로 적용된다.
    다만 편집기는 **대상 값만으로는 부족하다** — 편집기끼리 전환하면 값이 안 바뀌므로 tick이
    **어느 Term의 매치인지**(surface id)를 함께 대조한다. **열림 여부로
    게이트하지 않는다**: 닫힌 동안 탭이 바뀌면 대상이 굳어, 다시 열자마자 그리는 첫 프레임이 지난 탭 모드로 나간다.
    - 대상이 페이지로 바뀌면 스크롤백 매치를 버리고(그 화면 것이 아니다), **터미널로 돌아오면 다시 찾는다**.
      단 재검색은 **하이라이트를 실제로 그리는 상태**(오버레이가 열렸거나 ⌘G 네비 중)에서만 한다 —
      `recomputeFind`가 `scrollToCurrentMatch`까지 부르므로, 닫아 둔 find에서 돌리면 탭 복귀만으로 화면이 점프한다.
  - **검색·하이라이트는 WebKit이 한다**(`WKWebView.findString(_:configuration:completionHandler:)`).
    **페이지에 스크립트를 주입하지 않는다.**
    > ⚠️ 앞선 초안은 그 근거를 "markdown/browser에서 bridge 부재"로 적었는데 **오독이었다** — 그 문장은
    > [editor-surface.md]의 **CM6 page-world 브리지**가 없다는 뜻이지 우리 코드가 없다는 뜻이 아니다.
    > 마크다운 뷰어는 **우리가 만든 페이지**(`web/src/main.ts`, 거기서 `contextmenu`를 이미 가로챈다)라
    > JS 검색이 기술적으로 **가능하다**. 주입하지 않는 진짜 이유는 아래 "왜 네이티브 단일 경로인가"다.

  - **왜 네이티브 단일 경로인가**: JS 검색은 **마크다운에서만** 되고 browser 탭(외부 콘텐츠)에서는 안 된다.
    거기서 갈라 놓으면 같은 ⌘F가 탭 종류에 따라 다르게 동작해 **한 기능에 규약이 둘**이 된다.
    네이티브 `find`는 두 종류가 **똑같이** 동작하고 페이지에 아무것도 넣지 않는다.

  - **매치 개수는 넣지 않는다(제약).** `WKFindResult`에는 `matchFound: Bool`뿐이고 **개수 필드가 없다**.
    배포 하한이 macOS 11(`build.zig`)이라 더 새 API도 쓸 수 없다. 반복 호출로 세는 우회는 매치마다 선택·스크롤이
    움직여 화면이 튀므로 하지 않는다. 웹 탭은 **찾음/없음**만 표시한다.
    - **"cur/total" 자리를 비워 두지 않고 찾음/없음을 그린다.** 그 자리에 `0/0`을 남기면 WebKit이 노랗게
      하이라이트한 화면과 정면으로 모순돼 "못 찾았다"로 읽힌다. 결과가 오기 전에는 아무것도 그리지 않는다
      (빈 자리 < 틀린 숫자). 나중에 마크다운 한정 JS 카운트를 붙이면 **덧붙이기**로 끝나고 재설계가 아니다.

  - **비동기 수명이 핵심 위험이다.** `find`는 completion handler다 — 질의를 보낸 뒤 결과가 오기 전에 사용자가
    **탭을 바꾸거나 오버레이를 닫을 수 있다**. 늦게 온 결과를 그대로 반영하면 "누른 적 없는 상태"가 화면에 뜬다.
    상태바 브랜치 메뉴에서 **실제로 그 결함이 났다**(요청 중 상태바가 사라져도 메뉴가 떴다) — 같은 규율을 쓴다:
    - 질의마다 **request id**를 싣고, 회신이 그 id와 다르면 **버린다**.
    - 오버레이가 닫혔으면 반영하지 않는다.
    - **id만으로는 부족하다**: A에서 제출한 뒤 결과가 오기 전에 B로 옮기면 id는 아직 유효한데 그 답은 A의 것이다.
      그대로 붙이면 B 화면이 A의 찾음/없음을 말한다(실측). **제출 대상과 지금 보이는 탭이 같을 때만** 반영한다.
    - Swift도 **제출한 그 surface의 세션**으로만 돌려준다(weak surface). 활성 창으로 다시 찾으면 남의 세션에
      결과를 주게 되고, id는 세션마다 0에서 시작하므로 우연히 맞아떨어질 수 있다.

  - **재제출 판정은 "대상 탭 + 검색어"다.** "결과를 아직 못 받았는가"로 게이트하면 같은 검색어로 다른 웹 탭에
    갔을 때 그 탭은 **영영 검색되지 않는다**(실측). 반대로 조건이 없으면 tick마다 재제출해 WebKit 하이라이트가
    매 프레임 첫 매치로 튄다.

  - **전달 실패는 신고해야 한다.** 방금 만든 웹 탭은 WKWebView가 아직 없어 drain이 질의를 걸지 못한다. 그때 그냥
    버리면 Zig의 제출 마커가 "보냈다"로 남아 tick이 재시도하지 않고 그 탭의 검색은 **조용히 죽는다**. Swift가
    `web_find_undeliverable(seq)`로 신고하면 마커가 지워져 다음 tick이 다시 낸다(주소창 navigate가 "아직
    WKWebView가 없는 Term은 다음 tick에 다시 본다"로 푸는 것과 같은 문제·같은 답).

  - **하이라이트 해제는 할 일이 없다(실기기 확인 완료 — 2026-08-09).** 오버레이를 Esc로 닫으면 페이지
    하이라이트는 **남지 않는다.** WebKit이 알아서 정리한다(find indicator는 원래 일시적이고, 검색창이 떠
    있는 동안 키보드 포커스는 터미널 뷰라 WKWebView가 first responder도 아니다).
    > ⚠️ 이 문서는 한동안 **"clear API가 없으니 하이라이트가 남는다"**고 단언했는데 **틀렸다.**
    > "지울 수단이 없다"에서 "안 지워진다"로 건너뛴 비약이었다(WebKit이 스스로 정리하는 경우를 빼먹었다).
    > 설계 때는 "남는지 확인하고"라는 열린 질문으로 적어 놓고, 구현을 마치며 확인 없이 단정문으로
    > 승격시킨 것이 원인이다. **API 부재는 동작의 근거가 아니다** — 실기기로 봐야 한다.

  슬라이스와 완료 이력은 [웹 패널 구현 계획](plans/web-panel.md)이 소유한다.
  - **범위 밖**: 편집기(CM6) 표면의 find는 [editor-surface.md] Phase 0.5A가 소유한다(CM6 자체 검색). 이 항목은
    **뷰어(markdown)·browser 탭**만 다룬다.
- **컨텍스트 메뉴**: WKWebView 기본 우클릭 메뉴(Inspect Element·**Reload** 포함)는 "chrome는 Zig" 원칙·보안과 충돌하고, 특히 Reload는 편집 중 WebContent를 재시작해 editor recovery latch로 파일 작업을 차단한다 → **신뢰 maru-app 콘텐츠(파일 패널 셸+렌더 iframe)의 셸 entry(`main.ts`)에서 `contextmenu` preventDefault로 억제**한다(브라우저 패널=외부 콘텐츠는 `main.ts`를 로드하지 않아 무영향). 복사·붙여넣기는 메뉴바/⌘ 단축키(§4.2)가 소유한다. maru 자체 메뉴로 대체는 후속.
- **접근성(AX)**: WKWebView는 네이티브 AX 트리, 터미널·모달(Metal)은 없음 → 혼합 상태. 마크다운 편집기에 AX 필요.
- ~~**콘텐츠 프로세스 크래시 복구**~~ → **구현 완료**(2026-08-29 재확인). `webViewWebContentProcessDidTerminate` 가 kind 로 갈라 — 신뢰 파일 패널은 `loadFreshTrustedDocument` 로 **재로드**하고, browser 패널은 `maru_macos_control_push_browser_crashed` 로 `browser.crashed` 이벤트를 흘린 뒤 컨트롤러에 알린다(5f-3c). 남은 것은 **에러 상태 화면**(사용자에게 보이는 안내)뿐이다.
- **폰트/줌·인쇄**: 저우선.
