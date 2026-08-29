# 세션 컨트롤 플레인 — `browser.*` 라이브 배선 (§9.2~§9.3)

헤드리스 제어 코어를 실제 WKWebView에 잇는 남은 슬라이스와 5e 상세 설계다.

> **절 번호는 파일을 넘어 이어진다.** 본문이 `§8.1`처럼 절만 가리키면 아래에서 소유 파일을 찾는다 — §1~§3·§5~§7·§10·§13~§15 [control-plane.md](control-plane.md) · §4 [transport·프로토콜](control-plane-protocol.md) · §8 [보안](control-plane-security.md) · §9.1·§9.6 [browser.\* 코어와 CLI](control-plane-browser.md) · §9.2~§9.3 [라이브 배선](control-plane-browser-wiring.md) · §9.4 [프로토콜 리뷰](control-plane-browser-review.md) · §9.5 [지속 세션·이벤트·대용량 결과](control-plane-browser-session.md) · §11~§12·§16 [구현 Phase와 검증](control-plane-implementation.md)

### 9.2 라이브 end-to-end 에이전트 제어 — 남은 슬라이스 (설계, doc-first)

**목표**: 외부/에이전트가 컨트롤 소켓으로 보낸 `browser.navigate`/`executeScript`가 **실제 인앱 WKWebView surface(7f 팝업 adopt 포함)를 움직이고 결과를 응답으로 받는** 라이브 경로. 이것이 [web-panel.md] §13의 "host-mediated 브라우저 MCP"(Safari MCP tool 표면을 자체 미러링 — 임베드 WKWebView는 `safaridriver`가 안 잡으므로) 의 실체다. maru는 **일반 브라우저 UX(사용자 브라우징) + 에이전트 제어**를 동시에 주는 게 목표고(7f adopt가 팝업까지 addressable하게 만든 전제), 엔진 피벗(CEF, §13) 없이 WKWebView에서 성립한다.

**현재 상태(드리프트 게이트 실측 — 2026-07-11, 코드 인용)**:
- **5a 완료(L2 순수)**: `src/session/control_browser.zig` — `BrowserMethod` **3개**(navigate/getUrl/executeScript, `:50`) 스키마·파서·직렬화 + `dispatchBrowser`(`:231`)가 parse→`browser` authz(`:265`, 존재검사 이전 균일 unauthorized)→surface 검증(`kind==.web`, `:283`)까지 수행. 헤드리스 테스트 있음.
- **5d 완료(L4)**: `MaruAppHost.swift` `enum BrowserControl`(`:715`) — navigate/currentUrl/executeScript 실 WKWebView API. **fixture 스모크로만 구동**(컨트롤 플레인 아님).
- **capability 순수 코어**: `control_capability.zig`에 `ScopeClass.browser`(`:58`)·`issueForFd`/`resolve`/`lookupByNonce`(`:204`·`:226`·`:240`) 정의 — **라이브 호출자 0**.

**라이브 e2e를 막는 gap(4 + 보조 2)**:
1. **라우팅 미배선** — 라이브 경로(`control_socket.zig` `serveReadOnly`·`app_host_abi.zig` `buildControlResponse` `:1807`)가 `dispatchReadOnly`만 부른다. write-class인 `browser.*`는 read-only 라우터가 받아 `method_not_found`로 접어 `dispatchBrowser`에 **도달조차 못 한다**. → **통합 dispatch 분기**(read-only vs write/browser)가 필요.
2. **capability 발급·resolve 미배선(1e 라이브)** — 라이브 서버는 `scope=.self`(metadata:self) 하드코딩(`control_dispatch.zig:56`)이고 auth 프레임 nonce→`CapabilityStore.resolve`→`Capability` 배선이 없다. `dispatchBrowser`가 요구하는 `caller_cap: ?Capability`(`control_browser.zig:1577`)를 채울 라이브 경로가 없어, 라우팅만 이어도 **항상 `unauthorized`**. → **1e가 browser뿐 아니라 write/lifecycle 라이브 auth의 공통 선행**.
3. **async marshal 부재** — 메인 drain(`app_host_abi.zig`)은 pending pop→동기 `dispatchReadOnly`→**즉시 resolve**(한 tick 완결). `PendingRequest.resolve`(`control_server.zig`)는 1회 동기 rendezvous라, `evaluateJavaScript` completion·navigation didFinish 같은 **지연 콜백 결과를 pending으로 되돌리는** 경로가 없다. → **deferred resolve**(요청을 in-flight로 두고 콜백에서 나중에 resolve) 확장 필요.
4. **surface_id → webView 해소** — `BrowserControl`은 `WKWebView`를 인자로 받는다(`:717`). dispatch가 판정한 target surface_id를 메인에서 `webPanels[surface_id].webView`로 푸는 배선이 주소창 nav 경로(`surfaceOwning`/`webPanels`)에만 있다 — browser dispatch용으로 재사용해야.
5. *(보조)* **`panel.navigated` 이벤트** — `installNavObservers` KVO(`MaruAppHost.swift:898`)는 현재 **주소창 UI 갱신 전용**(`web_nav_states` 해시맵). 에이전트가 nav 완료를 관측하려면 이 KVO를 컨트롤 플레인 이벤트(§11 `events.subscribe`)로도 흘려야 — e2e 제어 자체는 안 막지만 폴링 없는 관측에 필요.
6. *(보조)* **나머지 browser.* 메서드** — screenshot/back/forward/refresh/findElement/click/sendKeys/getCookies는 `BrowserMethod` enum·`BrowserControl` 둘 다 미정의. e2e 토대(1~4)와 독립적으로 확장.

**슬라이스 시퀀싱(제안 — 각 헤드리스/fixture 게이트 후 머지)**:
- **1e (capability fd 발급·resolve 라이브)** — *선행이자 공통 토대*. `browser`·`write`·`lifecycle` 라이브 auth가 전부 여기 걸린다.
  - **1e-core(auth 배선 — 구현 완료)**: 순수 코어(`control_capability.resolve`)를 라이브 서버 auth에 배선했다. auth 프레임(`control_plane.auth.self`)에 optional `cap_nonce`(hex, `parseAuthFrame`/`serializeAuthSelf`)를 실어, `control_dispatch.dispatchAuthenticated`가 `{selector, cap_nonce}` + 라이브 `CapabilityStore`로 `(caller, scope)`를 발급한다 — cap_nonce 없으면 기존 metadata:self(회귀 없음), 있으면 resolve(grant=발급 scope로 dispatch, deny=§8.3 균일 unauthorized). `control_server.PendingRequest.cap_nonce`가 accept 스레드→메인 marshal로 nonce를 나르고, `app_host_abi.buildControlResponse`가 라이브 `control_cap_store`(현재 **빈**=fd 발급 전이라 nonce 요청 default-deny)로 resolve한다. **헤드리스 테스트**: `control_dispatch`(dispatchAuthenticated — metadata:all/window scope 발급·미지 nonce/surface_mismatch=unauthorized·browser cap=method_not_found[미배선] vs scope 불충족=unauthorized) + `control_plane`(cap_nonce 왕복·관대 파싱) + `control_server`(실 소켓 왕복: cap_nonce(metadata:all)→전체 조회). non-metadata cap(browser/write)은 resolve되나 read-only 라우터에 미배선이라 method_not_found(5e/2a 대기).
  - **1e-confirm(대화형 grant UX — 구현 완료 2026-07-13, §9.2 개정으로 fd 상속 폐기)**: 초판은 fd 발급/상속(§8.5, `MARU_CONTROL_CAP_FD`)이었으나, **§9.2 Model B(pane-bound confirm-grant)로 개정** — 실행 중 pane 에이전트에게 확인 모달로 grant(bearer nonce/fd 없이 tty-검증 pane 신원에 grant, `PaneGrantStore` + §5-async held-request + `confirm.zig` 모달). 슬라이스 0/1a/1b/1c-1/1c-2/2a/2b 전부 완료·손 테스트 통과. **발급 UX 결정·상세는 아래 "개정 채택안 — Model B" + "슬라이스 분해" 참조**.
- **§5-async (deferred marshal)** — `PendingRequest`를 "동기 즉시 resolve"에서 "in-flight 등록 → 콜백에서 resolve"로 확장.
  - **서버 인프라(구현 완료)**: `control_server.ControlServer`에 in-flight 레지스트리 추가 — `deferRequest(pending, deadline_ns)`(메인 전용, 즉시 resolve 대신 pending 붙잡고 상관 id 반환, `max_in_flight` bounded → `TooManyInFlight`)·`completeInFlight(id, response)`(콜백이 나중에 resolve+제거, 옛/미지 id는 false 무동작)·`reapExpiredInFlight(now_ns)`(마감 지난 것 timeout=`resolve(null)` 정리, hung async op 방어)·`stop`이 in-flight도 cancel(queue.close와 대칭). 메인 스레드 전용이라 락 없음(pending.resolve/cancel만 cross-thread=thread-safe). 헤드리스 유닛(defer→complete·bounded·reap-timeout·stop-cancel). accept가 serial이라 실질 in-flight ≤1(browser op이 accept를 붙잡는 throughput 한계는 단일 에이전트엔 무해, 후속 concurrent accept 시 재검토).
  - **남음(5e에서 배선)**: drain이 async 메서드(browser.*)에 `deferRequest`를 호출하는 결정, Swift 콜백이 완료를 되돌리는 ABI export(`complete_async`), 매 tick `reapExpiredInFlight` 펌프. proper timeout 에러 응답(현재는 null 종료=client read 타임아웃)도 후속.
- **5e (browser 라이브 배선)** — 통합 dispatch가 `browser.*`를 `dispatchBrowser`로 라우팅 → authz(1e cap) → surface 검증 → **메인 marshal**(surface_id→webView 해소) → `BrowserControl` 호출 → async 완료를 5-async로 응답. 최소 3개(navigate/getUrl/executeScript)로 e2e 왕복 fixture. `dispatchBrowser`의 `notImplementedResponse`(`control_browser.zig:1577`)를 `executeBrowser` 실행으로 교체.
- **5f (나머지 browser.* 메서드)** — enum + `BrowserControl` 확장(screenshot=`takeSnapshot`, back/forward/reload=이미 있는 `goBack`/`goForward`/`reload` 재노출, click/sendKeys/findElement=`evaluateJavaScript` DOM, getCookies=`WKHTTPCookieStore`). 각 스키마 헤드리스 + fixture E2E.
- **5g (panel.navigated 이벤트)** — KVO→컨트롤 이벤트 방출(§11). `events.subscribe`(Phase 3) 위에 얹음.

**결정 — `browser`/`browser_storage` capability 발급 UX**: `browser`(및 민감 `browser_storage` §9.4 D5)는 **기본 거부**(§8.3)다 — 팝업·탭은 임의 untrusted 콘텐츠라, 에이전트 제어는 사용자 브라우징(로그인 세션·OAuth 토큰·폼)을 **읽고 대신 조작**할 수 있어 `sessions.list`와 차원이 다른 신뢰 표면이다. 검토한 후보: **(A)** capability fd 상속(maru-spawned trusted agent profile) — 기존 §8.5 fd 모델 재사용; **(B)** 명시 사용자 확인 모달(per grant/session); **(C)** config allowlist — 정적·오설정 위험.
  - **초판 채택안(2026-07-11)**: default-deny + (A) fd 상속 주경로 + surface 한정 + 첫 grant (B) 1회 확인.
  - **⚠️ 개정 채택안 — Model B: pane-bound confirm-grant (사용자 결정 2026-07-13)**: (A) fd 상속을 **주 경로에서 폐기**하고, **실행 중인 pane 에이전트에게 확인 모달로 grant**한다. **개정 근거**: (1) **UX** — maru의 본질이 "터미널 안에서 협업하는 에이전트"라, 브라우저 제어를 위해 **별도 전용 봇을 spawn**(A)하면 사용자 정신모델이 둘로 갈린다; "지금 그 pane에서 돌던 에이전트가 옆 브라우저도 제어"가 직관적(사용자 지적). (2) fd 상속은 **spawn 시점** 모델이라 이미 실행 중인 에이전트에 소급 부여 불가(재spawn 필요). (3) fd 상속의 **subtree 유출**(§8.5 headline — 셸 서브트리 전 프로세스가 cap fd를 `pread`)은 확인 모달(B)이 어차피 실 게이트라, fd 전달 자체의 이점이 상쇄된다. (4) **Model B는 bearer nonce/fd를 안 쓴다** — grant를 **tty-검증 pane 신원**(§8.4 self-origin selector = `MARU_PANE_ID` tty 경화)에 묶어 서버가 기억하므로, nonce를 파일·env로 나르다 서브트리로 새는 문제 자체가 없다. (잔여 노출: pane의 tty 서브트리는 여전히 그 pane 신원을 공유하나 — 터미널 pane에 cap을 묶는 한 내재 — 확인 모달이 그 최종 게이트다. fd 상속과 동급이되 nonce 전달 표면이 없어 더 좁다.)

**Model B — grant 모델·확인 흐름 (1e-confirm 상세 설계, doc-first 2026-07-13)**:
  - **pane-bound grant 레코드**: `(pane_selector_surface_id, target_web_surface_id, scope_class) → granted`. 서버 측 저장(L2 순수 `PaneGrantStore`). 수명 = 두 surface가 살아있는 동안(어느 쪽 close/generation 변경 = grant 무효), 세션(pane) 한정(재시작 넘어 영속 안 함), 명시 revoke 가능. **bearer 토큰 없음** — 다음 CLI 호출이 `auth.self`(selector=pane)로 재연결하면 §8.4 tty 게이트가 pane 신원을 재검증하고 저장된 grant를 조회한다(CLI가 nonce/fd를 안 나름). 전제=`MARU_PANE_ID` tty 경화(§8.4 1g — 구현 시 라이브 확인).
  - **authz 합성(22차 [1]과 정합·가법)**: browser.* 요청의 인가 = **(a) 세션 cap 중 하나가 인가**(기존 `resolveAny`/browser 경로 — fd/nonce는 비대화형·미래용으로 유지) **OR (b) pane이 `(target, scope)` confirmed grant 보유**. 둘 다 아니면 → **확인 대기**. ambient self-origin(metadata:self)·세션 cap·confirmed grant가 **가법**으로 권한을 더한다(제시가 기존 권한을 revoke 안 함 — 22차 [1] 불변식 유지).
  - **확인 흐름(§5-async 붙잡기 재사용)**: (1) pane P의 browser.* 요청(target W, scope S) 인가 실패 → **`deferRequest`로 붙잡고**(§5-async in-flight) 메인 루프에 `GrantPrompt{P,W,S}` enqueue. (2) 메인이 **중복 prompt dedup**(같은 P·W·S가 대기 중이면 새 요청을 held 목록에 합류만) 후 확인 모달 표시. (3) **허용** → grant 기록 → 그 (P,W,S)의 held 요청 **전부** 완료(정상 진행). **거부** → held 요청 균일 unauthorized 완료. **timeout/pane drop** → unauthorized(§5-async reap). (4) 그 뒤 같은 pane의 (W,S) 요청은 grant 조회로 즉시 통과(재확인 없음 — 세션 기억).
  - **확인 모달 내용(사용자 결정 2026-07-13)**: **scope별 구분**(browser = "이 브라우저 제어 — 이동·클릭·입력·화면 읽기" / browser_storage = "이 사이트의 쿠키·스토리지 **읽기·쓰기** — 로그인 토큰 포함", 사용자 결정 2026-07-13 read+write 동일 scope), **target surface 식별**(url + 제목), **요청 pane 식별**(pane 제목/인덱스), **D5 eval-누출 정직 명시**(browser 권한이면 `executeScript`로 localStorage·non-HttpOnly 쿠키·DOM 토큰이 이미 도달 가능함을 숨기지 않음 — §9.4 D5), **세션 기억**(허용 시 그 grant는 세션 동안 재확인 없음 = 매 op 프롬프트 아님). 예/아니오 2버튼(`confirm.zig` 재사용).
  - **fd/nonce 경로(§8.5)와의 관계**: cap fd/nonce 모델(1e-core·§8.5)은 **폐기하지 않고** 비대화형/상속 시나리오·기존 스모크(`test_issue_browser_cap`)용으로 유지하되, **대화형 browser grant의 주 경로는 pane-bound confirm-grant**로 바꾼다. §8.5의 "browser = fd 상속 허용(`allowedViaInheritedFd=true`)"은 "가능하나 주 경로 아님"으로 정정(코드 `Scope.allowedViaInheritedFd`는 그대로 — fd 경로 자체는 남김).

**슬라이스 분해(1e-confirm — 전부 구현 완료 2026-07-13. 계획 시 coarse 0/1/2였으나 안전 위해 아래처럼 세분 구현):**
  - **1e-confirm-0 (doc, 완료)**: §9.2 Model B 채택·grant 모델·확인 흐름·모달 내용(이 개정).
  - **1e-confirm-1a (완료)**: L2 순수 `PaneGrantStore`(`control_pane_grant.zig` — `(pane,target,scope)→granted` CRUD·`removeSurface`). 미배선 mechanism.
  - **1e-confirm-1b (완료)**: browser authz **가법 합성**(`browserOpFromRequest`가 세션 cap OR pane grant 조회). behavior-preserving(빈 store=기존 unauthorized).
  - **1e-confirm-1c-1 (완료)**: `needs_grant` 방출(미grant valid[존재 web+pane]는 unauthorized 대신 확인 대기 후보; subscribe는 surface·authz 검증을 필터 파싱 앞으로=oracle 유지). L4는 우선 unauthorized로 collapse(behavior-preserving).
  - **1e-confirm-1c-2 (완료)**: held-request 흐름(needs_grant→env 스텁 inline 결정→승인 시 grant 기록+**재-dispatch**→기존 라우팅 재사용). 스모크 e2e(무-cap navigate).
  - **1e-confirm-2a (완료)**: held-across-ticks(inline 결정→`deferRequest` 붙잡기+`grant_prompt_queue`, `drainGrantPrompts`가 `server_drain`서 매 tick 결정+resolve). op은 grant async_id 재사용(`pushBrowserOp`=재-defer 금지)·subscribe=`completeInFlight`.
  - **1e-confirm-2b (완료·손 테스트 통과)**: 실 확인 모달(env 스텁→app_session): `pending_grant`+`grant_confirm_decision` latch+`showGrantConfirm`(비파괴·idempotent)+`takeGrantDecision`, `confirm_accept/cancel`에 grant 분기+`showConfirmButtons` supersede. `drainGrantPrompts`=env 설정 시 auto(스모크)·미설정 시 `firstAppSession` 모달+결정 폴. `MARU_TEST_GRANT_PROMPT`=결정 env 없이 실 모달 유발(손 테스트).
  - **realization(손 테스트가 잡음)**: held 요청은 요청 큐서 빠져 `has_pending=0`→Swift가 `server_drain` 스킵→`drainGrantPrompts`가 안 돌아 **모달 클릭 결과를 못 읽음**("허용해도 빈 화면") → `has_pending`이 `grant_prompt_queue` 비어있지 않으면 계속 1 반환하게 수정(per-tick drain 게이트는 held 대기까지 포함해야).
  - **1e-confirm 후속(완료)**: grant dedup(`drainGrantPrompts`의 `isGranted` 조회)·target 창에 모달(`appSessionOwningSurface`)·**grant revoke UX**·`maru browser` CLI(§9.6). **revoke UX(구현 완료)**: (a) **전체 취소** `maru_macos_control_revoke_all_browser_grants`(clearAll)·(b) **개별 취소** "Browser Grants ▸" 서브메뉴 — 열릴 때 `menuNeedsUpdate`가 `..._grant_count`/`..._grant_at`으로 활성 grant를 스냅샷 조회해 "pane #P → 대상 host · scope 취소" 항목을 동적 생성, 클릭 시 `..._revoke_browser_grant(pane,target,scope)`로 **한 건만** 값-기반 취소(멱등, 인덱스 시프트 안전) + 끝에 "Revoke All". scope wire=명시 매핑(0=browser·1=browser_storage, ScopeClass 순서 무관). **미구현(범위 밖)**: MCP 어댑터(§10 — CLI 검증 후 얇게).

**host-mediated 얕게 vs 깊게(Web Inspector) — 이미 결정된 분기**: 위 5e/5f는 **host-mediated JS**(evaluateJavaScript로 DOM·click·eval, takeSnapshot으로 screenshot, WKHTTPCookieStore로 쿠키, 주입 JS로 console)라 **network 계층은 얕다**. CDP급 network(요청 가로채기·수정)가 필요하면 maru WKWebView를 `isInspectable`로 켜고 **Web Inspector 원격 프로토콜**로 구동한다(복잡·별도 채널 — Safari MCP의 존재가 WKWebView에서 가능함을 방증). 기본은 얕은 host-mediated, 깊은 network는 실수요 시 별도 슬라이스([web-panel.md] §13 분기와 단일 출처 정합).

**MCP 어댑터 관계**: wire가 JSON-RPC 2.0이라(§10) 향후 MCP 어댑터를 얇게 얹으면 `browser.*`가 MCP tool로 노출된다 — "host-mediated 브라우저 MCP"의 MCP 표면은 이 어댑터(§10 note, 구현 계획 미정, 네임스페이스/발견 seam만 보존)로 충족한다.

### 9.3 5e 상세 설계 — 라이브 browser.* 배선 (doc-first)

**목표(다시)**: 소켓으로 온 `browser.navigate`/`getUrl`/`executeScript`(browser cap 인가)가 **실제 WKWebView를 구동하고 결과를 응답으로 되돌린다**. 1e-core(auth)·§5-async(deferred marshal)·5d(BrowserControl)·5a(스키마)를 잇는 슬라이스. 최소 3개 메서드로 e2e 왕복을 fixture로 증명하고, 나머지는 5f.

**전제(5e 설계 시점 출발 상태 — 1e-core·§5-async 후, 아래 항목은 전부 5e에서 해소)**: `buildControlResponse`(L4, 지금 `handleControlRequest`) → `dispatchAuthenticated`(L2)가 auth를 발급한다. browser cap grant는 당시 non-metadata라 `method_not_found`로 접혔다(미배선 — **5e-2a가 `browserOpFromRequest` 위임으로 해소**). `BrowserControl`(Swift, 5d)는 navigate/currentUrl/executeScript를 escaping completion으로 실행한다(async). `ControlServer`는 `deferRequest`/`completeInFlight`/`reapExpiredInFlight`(§5-async)를 갖췄다.

**흐름(레이어별)**:
```
소켓 요청 → accept 스레드 → PendingRequest{selector, cap_nonce, request_bytes}
  → 메인 drain(app_host_abi)
    → dispatchAuthenticated(L2): browser cap grant면 → dispatchBrowser(L2)로 위임
        → dispatchBrowser: authz·surface kind==web 검증 후 BrowserOp{surface_id, method, arg} 반환(에러면 응답 바이트)
    → L4: BrowserOp이면 deferRequest(pending)→async_id + 브라우저 op 큐에 enqueue{async_id, surface_id, method, arg}. 즉시 resolve 안 함.
  → (다음 tick) Swift가 take_browser_op으로 op를 drain → webPanels[surface_id].webView 해소
    → BrowserControl.{navigate/currentUrl/executeScript}(completion)
    → (async 완료) complete_browser_op(async_id, status, result_bytes)
  → 메인: 요청 id·method로 browser.* 응답 직렬화(control_browser.serializeXResult) → completeInFlight(async_id, 응답)
    → accept 스레드가 소켓에 write.
```

**구현 조각**:
1. **L2 `dispatchBrowser` → BrowserOp 반환(5a skeleton 교체)**: `control_browser.zig`의 `notImplementedResponse`(5a) 대신 `union(enum){ err: []u8, op: BrowserOp }` 반환. `BrowserOp{ surface_id: u64, method: BrowserMethod, arg: []const u8 }`(navigate=url·executeScript=script·getUrl=빈). authz(browser cap)·surface 검증은 그대로.
2. **L2 `dispatchAuthenticated` 반환 확장**: 현재 `[]u8`. browser cap grant를 marshal하려면 tagged 반환 필요 — `union(enum){ immediate: []u8, browser: BrowserOp }`. metadata/에러=immediate(기존), browser cap grant=browser(op). L4가 분기. (**결정 필요 ①**: dispatchAuthenticated tagged union vs buildControlResponse가 browser.*를 선-검출 — 전자가 auth·라우팅 단일 출처라 우선.)
3. **L4 marshal(app_host_abi)**: BrowserOp이면 `server.deferRequest(pending, now+timeout)`→async_id, 브라우저 op 큐(신규 Zig 큐, 메인 전용)에 `{async_id, surface_id, method, arg 복사}` push. `TooManyInFlight`면 즉시 에러 resolve(defer 안 함). op의 arg는 cross_gpa 복사(pending.request_bytes 수명과 분리).
4. **ABI(신규, take/provide async 패턴 — `take_color_sample_request`/`provide_sampled_color` 선례)**:
   - `maru_macos_control_take_browser_op(out async_id, out surface_id, out op_kind[0=navigate·1=getUrl·2=executeScript], out arg_ptr, out arg_len) u32`(1=op 있음·0=없음). Swift가 매 tick drain.
   - `maru_macos_control_complete_browser_op(async_id, status[0=ok·1=error], result_ptr, result_len)`. Swift completion이 호출.
5. **Swift 실행(MaruAppHost)**: take한 op의 surface_id를 `webPanels[surface_id]?.webView`로 해소(없으면 status=error로 즉시 complete). op_kind별 `BrowserControl` 호출 + completion에서 `complete_browser_op`. getUrl/executeScript는 결과 문자열, navigate는 ok/error.
6. **응답 직렬화(L4 complete 핸들러)**: `complete_browser_op`가 async_id로 in-flight pending을 찾고, 그 `request_bytes`를 **재파싱**해 요청 id·method를 얻어(단일 출처) status·result로 `control_browser.serializeNavigateResult`/`getUrl`/`executeScript`(또는 §8.3 에러) 직렬화 → `completeInFlight(async_id, 응답)`. (request_bytes는 pending이 아직 resolve 안 돼 유효.)
7. **reap 펌프**: `maru_macos_control_server_drain`이 매 tick `reapExpiredInFlight(now_ns)` 호출(hung op → timeout 정리).
8. **smoke용 cap 주입 훅(테스트 전용)**: 실 fd 발급(1e-confirm) 전이라 라이브 store가 비어 browser 요청이 default-deny다. **env-gated 테스트 훅**(예: `MARU_TEST_BROWSER_CAP=1`이면 디버그 web 패널 surface에 고정 nonce의 browser cap을 startup에 `issueForFd`)으로 macos smoke가 소켓 `browser.navigate`(그 nonce)→실 WKWebView 이동을 자동 증명. 프로덕션 경로 불변(env 미설정 시 무동작). (**결정 필요 ②**: 주입 훅을 env-gate vs 별도 테스트 바이너리 — env-gate가 기존 `MARU_WEB_PANEL`류 디버그 훅과 정합.)

**검증**: (a) 헤드리스 — `dispatchBrowser` BrowserOp 반환·에러 분기 단위(control_browser), dispatchAuthenticated tagged 반환 단위(control_dispatch), 브라우저 op 큐 marshal 단위. (b) **macos smoke(fixture E2E)** — 주입 cap + 소켓 `browser.navigate`(무-네트워크 `data:` URL)→WKWebView 이동→`getUrl`/`executeScript` 결과 왕복(5d fixture가 BrowserControl 직접 호출로 증명한 걸 이제 **소켓 전 경로**로). WKWebView async라 헤드리스 Zig 아니라 smoke.

**범위 밖(후속)**: 실 cap 발급 UX=1e-confirm. 나머지 메서드(screenshot/back/forward/click/sendKeys/findElement/getCookies)=5f. proper timeout 에러 응답·concurrent accept=후속. **손 테스트**: smoke가 자동 증명하므로 최소(실 에이전트가 실 웹 로그인 세션 제어하는 통합 시나리오만 사용자 확인).

**열린 결정 요약**: ① dispatchAuthenticated tagged union(권장) vs buildControlResponse 선-검출. ② smoke cap 주입 env-gate(권장) vs 별도 바이너리. 둘 다 권장안이 기존 패턴과 정합 — 이견 없으면 그대로 진행.

**구현 분할·상태(5e-2를 헤드리스/GUI 경계로 나눔)**:
- **5e-1(구현 완료)**: `control_browser.dispatchBrowser` → `BrowserOp` 반환(skeleton 교체).
- **5e-2a(구현 완료)**: `control_dispatch.dispatchAuthenticated` → `AuthDispatch{immediate|browser}`, browser.*는 nonce 유무 무관 `browserOpFromRequest` 위임(리뷰 [2]).
- **5e-2b-1(Zig L4 marshal — 구현 완료)**: `control_browser.serializeBrowserResponse`(완료 시 request_bytes 재파싱→method별 result/error) + `control_server.inFlightPending`(async_id→pending 조회) + `app_host_abi`의 `BrowserOpQueue`(bounded FIFO, 메인 전용) + `handleControlRequest`(dispatchAuthenticated의 .browser를 `deferRequest`+큐 enqueue) + ABI `maru_macos_control_take_browser_op`(reap + pop, 안정 슬롯 arg)·`maru_macos_control_complete_browser_op`(직렬화+completeInFlight). 헤드리스 유닛(BrowserOpQueue push/take/bounded·serializeBrowserResponse). op.arg 소유권=cross_gpa(큐 인수→take/deinit free), completeInFlight 미발견=free(리뷰 [1] 대칭 소유).
- **5e-2b-2(Swift 배선 + macos 소켓 E2E — 구현 완료)**: `MaruAppHost.swift`가 매 tick `drainBrowserOps`(=`take_browser_op` loop drain → `surfaceOwning(byId:)`+`webPanels[surface_id]` webView 해소 → `BrowserControl`[op_kind] 실행: navigate/getUrl=동기 완료·executeScript=async 콜백 → `complete_browser_op`; surface 부재=status 1). `BrowserControl.scriptResultString`(JS 값→문자열, §9.3 ⑥). **테스트 전용 훅**(둘 다 additive export, ABI 버전 불변): `maru_macos_control_test_issue_browser_cap`(env `MARU_TEST_BROWSER_CAP` 게이트 — surface에 묶인 browser cap 발급+nonce 반환, 프로덕션 무영향)·`maru_macos_control_socket_path`(바인딩 경로). **macos 소켓 E2E(display 필요·CI 비게이트)**: smoke가 배경 큐에서 인-프로세스 소켓 클라이언트(요청당 새 연결·`SO_NOSIGPIPE`)로 auth(cap nonce)+`browser.navigate`(무-네트워크 `data:` URL)→**소켓 전 경로**(accept 스레드→메인 marshal→drainBrowserOps→BrowserControl→complete)→응답 왕복, 이어 `browser.getUrl`로 실제 이동 확인. **실측**(`MARU_WEB_PANEL=1 MARU_TEST_BROWSER_CAP=1` smoke 요약): `browser_ctl_navigate_ok=true`·`browser_ctl_get_url=data:…maru5d…`(5d fixture가 BrowserControl **직접** 호출로 증명한 걸 이제 인가·wire·async marshal을 **실제로 태우는** 소켓 전 경로로 재증명). 헤드리스 CI green=`macos-app-build`(전 배선 컴파일)+기존 유닛; WKWebView·소켓이라 E2E는 display smoke.
