# 세션 컨트롤 플레인 — 보안 (§8)

웹 브리지 노출 게이트, 소켓 권한과 peer-cred, capability 인가, self-origin 증명, 환경변수 redaction, WebDriver 어댑터와 SSH 원격의 신뢰 경계다.

> **절 번호는 파일을 넘어 이어진다.** 본문이 `§8.1`처럼 절만 가리키면 아래에서 소유 파일을 찾는다 — §1~§3·§5~§7·§10·§13~§15 [control-plane.md](control-plane.md) · §4 [transport·프로토콜](control-plane-protocol.md) · §8 [보안](control-plane-security.md) · §9.1·§9.6 [browser.\* 코어와 CLI](control-plane-browser.md) · §9.2~§9.3 [라이브 배선](control-plane-browser-wiring.md) · §9.4 [프로토콜 리뷰](control-plane-browser-review.md) · §9.5 [지속 세션·이벤트·대용량 결과](control-plane-browser-session.md) · §11~§12·§16 [구현 Phase와 검증](control-plane-implementation.md)

## 8. 보안

컨트롤 플레인은 같은 uid 안에서도 신뢰가 다른 코드(웹 콘텐츠·저권한 자동화·sudo 세션)가 공존한다고 가정한다. "uid가 같으면 신뢰가 같다"고 보지 않는다.

### 8.1 웹 브리지 노출 게이트
- `window.maru.*`는 신뢰 콘텐츠에만 주입한다. maru가 빌드해 `maru-app://` 커스텀 스킴으로 서빙하는 콘텐츠(마크다운 등)만 브리지를 받고, `panel_kind=browser`(임의 URL)에는 주입하지 않는다.
- 브리지를 isolated `WKContentWorld`에만 등록한다(spike 실측: 임의 페이지 page-world에서 `window.maru` 접근 불가, isolated world에서만 가능). 단 **`forMainFrameOnly`는 주입 user script에만 적용**되고 메시지 핸들러 등록은 world-scope라 프레임을 안 가린다 — 따라서 **핸들러 진입에서 `frameInfo.isMainFrame`+`securityOrigin`을 검사**해 서브프레임·clickjacking을 막는다(enforcement 디테일은 [web-panel.md] §7).
- 신뢰 콘텐츠도 자기 surface(또는 명시 위임)만 제어한다.
- **브리지는 sanitizer에 전적으로 의존하지 않는다(origin 격리 명시).** `.md`는 비신뢰 데이터(§8.1 위 문단·[web-panel.md] §7)인데 브리지가 그 콘텐츠를 서빙하는 origin에 살면, sanitizer 한 번 우회(mXSS·DOM clobbering·SVG/MathML)로 브리지에 도달한다. 따라서 (a) 브리지는 **신뢰 viewer shell origin에만** 붙이고 md-derived 문서는 브리지가 없는 **별도 origin**으로 렌더한다(sanitizer 우회는 script 실행까지만, 브리지 미도달), (b) `securityOrigin` 검사는 scheme(`maru-app://`) 수준이 아니라 **정확한 shell origin**으로 pin, (c) `panel_kind=browser`(untrusted) `WKWebViewConfiguration`에는 `maru-app://` scheme handler와 message handler를 **애초에 등록하지 않고** `maru-app://` 네비게이션도 `decidePolicyForNavigationAction`에서 차단한다(origin 위장으로 브리지 탈취 방지). 상세는 [web-panel.md] §7.

#### 8.1.1 5b — trusted bridge 설계 (isolated world 주입/미주입 + 프레임 검증)

Phase 5 두 번째 슬라이스. §8.1 브리지 게이트를 **구현**한다: 신뢰 콘텐츠(maru-app:// UI, Phase 7)가 `window.maru.*`로 maru에 콜백하는 브리지를 **isolated `WKContentWorld`에만** 주입해, 임의 page-world JS(md sanitizer 우회 mXSS 등)가 브리지에 못 닿게 한다(2026-06 spike 실측: isolated world만 접근 가능).

**의존성·시퀀싱(정직)**: 브리지 origin **exact-pin**(§8.1 (b))은 신뢰 origin `maru-app://`가 필요한데 그건 **5c**다. 그리고 브리지는 **신뢰 콘텐츠 전용**인데 현재는 `browser`(untrusted, 빈 흰 HTML)만 있다. 따라서 5b는 **브리지 메커니즘 + `isMainFrame` 검증 + 격리 자동 E2E**를 **fixture 신뢰 config**로 확립하고, 실 `maru-app://` origin-pin·CSP·스킴 샌드박스는 5c, 실 `window.maru.*` API 표면·신뢰 UI는 5d+/Phase 7로 둔다. untrusted(browser) 패널엔 브리지를 **애초에 미등록**(§8.1 (c)).

**① 브리지 등록(신뢰 패널만)** — 신뢰 `WKWebViewConfiguration`에: `WKContentWorld.world(name:"MaruBridge")`(page-world와 격리된 named isolated world) + `userContentController.addScriptMessageHandler(_, contentWorld: bridgeWorld, name:"maru")`(**WKScriptMessageHandlerWithReply** — async 응답, macOS 11+) + `WKUserScript(<window.maru shim>, .atDocumentStart, forMainFrameOnly: true, in: bridgeWorld)`. shim은 isolated world에 `window.maru.request(method, params) → Promise`(핸들러 postMessage + reply)를 깐다. `forMainFrameOnly`는 **user script에만** 적용되고 핸들러 등록은 world-scope(프레임 무관)라 → ②로 별도 검증.

**② 핸들러 진입 검증(§8.1·[web-panel.md] §7)** — 매 메시지: `frameInfo.isMainFrame`(서브프레임 거부 — clickjacking·중첩 차단) + `securityOrigin` **exact 신뢰 origin 일치**(**5c에서 `maru-app://` origin으로 pin** — 5b는 fixture origin 자리만, scheme 수준 매칭 아님). 둘 중 하나라도 불일치면 거부(reply 에러). 통과 시 신뢰 method subset으로 라우팅(5b 최소: round-trip 증명 `maru.hello()`→server_version 응답 **1개**; 실 method는 5d+/Phase 7).

**③ untrusted(browser) 격리** — `browser` 패널 config엔 message handler·isolated shim **미등록**(브리지 부재 — 힙 격리 1차). `maru-app://` 네비 차단·per-surface `WKProcessPool`/`WKWebsiteDataStore` 분리는 5c/후속(§7).

**④ 격리 자동 E2E(macOS smoke)** — 신뢰 fixture 패널에 테스트 페이지 로드 후: `evaluateJavaScript("typeof window.maru", in: bridgeWorld)`→`"object"`(isolated 접근) · `evaluateJavaScript(…, in: .page)`→`"undefined"`(page-world 미접근 — §8.1 spike 자동화) · `maru.hello()` round-trip→version(핸들러 도달) · 미등록 browser 패널→window.maru 부재. smoke 요약에 `bridge_isolated_ok`/`bridge_pageworld_absent` 단언(WKWebView·evaluateJavaScript async라 헤드리스 Zig 아니라 macos smoke E2E).

**⑤ 슬라이스 경계** — 5b=브리지 메커니즘·`isMainFrame`·격리 E2E(fixture). **5c**=`maru-app://` origin exact-pin·엄격 CSP·realpath/symlink/traversal 스킴 샌드박스. **5d**=browser.* 실 ops(browser 패널 navigate/evaluate). 실 `window.maru.*` API·신뢰 UI=Phase 7.

**⑥ 구현 상태 — 5b 구현 완료(5b-1 코어 + 5b-2 Swift 배선)**
- **5b-1(브리지 디스패치 코어 — L2 순수·헤드리스)**: `src/session/control_bridge.zig` — `dispatchBridge(gpa, request_bytes, server_version)`가 신뢰 브리지 요청 한 줄(JSON-RPC 2.0)을 처리해 응답 한 줄을 만든다. **auth 없음**(신뢰는 Swift가 origin/frame으로 확립 — 위 ②). 5b 최소 method = `hello`→`{protocol, server_version}`(round-trip 증명), 미지원 method→`method_not_found`, 비-request→`invalid_request`. wire 스키마는 소켓과 동일(cp.parseMessage/serializeError/writeId 재사용). C-ABI = `maru_macos_app_bridge_dispatch`(app_host_abi.{zig,h}). server_version은 소켓 hello와 같은 단일 출처(`control_hello_version`). 헤드리스 테스트(hello round-trip·method_not_found·invalid_request·parse 실패·minified).
- **5b-2(Swift 브리지 배선 + 격리 E2E — 구현 완료)**: `MaruAppHost.swift`의 `MaruBridgeHandler`(WKScriptMessageHandlerWithReply). 신뢰(markdown) 패널 config에만 `WKContentWorld.world(name:"MaruBridge")`(page-world와 격리) + `addScriptMessageHandler(_, contentWorld: world, name:"maru")` + `WKUserScript(shim, .atDocumentStart, forMainFrameOnly:true, in: world)`을 등록한다. shim은 isolated world에 `window.maru.request/hello`(postMessage→Promise)를 깔고 로드 시 `maru.hello()` 결과를 공유 DOM(#bridge-status)에 적는다. 핸들러 진입서 **`frameInfo.isMainFrame` + `securityOrigin`(protocol=`maru-app`·host=`app`) exact-pin**을 검사(둘 중 하나라도 불일치=reply 에러)한 뒤 통과분만 `maru_macos_app_bridge_dispatch`(5b-1)로 넘긴다. browser(비신뢰) 패널엔 브리지 **미등록**(bridgeWorld=nil). **격리 자동 E2E(macos smoke, MARU_WEB_PANEL_MARKDOWN)**: `bridge_isolated_probe=object`(isolated world 접근) · `bridge_pageworld_probe=undefined`(page-world 미접근=격리) · `bridge_hello_version=0.1.0`(callAsyncJavaScript로 `await maru.hello()` round-trip) · browser 패널 `bridge_world_registered=false`. placeholder(index.html)의 #status(page-world app.js: `typeof window.maru`)·#bridge-status(isolated shim)로 GUI 손 테스트도 격리를 눈으로 확인. **범위 밖**: 실 `window.maru.*` API 표면(navigate/read 등)=5d+/Phase 7, per-surface `WKProcessPool`/`WKWebsiteDataStore` 격리=후속(§7).

### 8.2 소켓 권한·peer-cred
- 0700 전용 디렉터리 + socket path 0600. **1b 구현 확정(`control_socket.zig`)**: 권한은 `umask`가 아니라 **bind 후 `chmod(path,0600)`** 로 고정한다 — 프로세스 전역 `umask`는 멀티스레드 앱에서 다른 스레드와 경합하므로 배제하고, bind~chmod 사이 창은 부모 dir 0700이 덮는다(same-uid는 신뢰 경계 안). `fchmod(fd)`는 쓰지 않는다(spike -1). 심볼릭 링크·소유자 검증은 `fstatat(SYMLINK_NOFOLLOW)`로 bind 결과가 S_IFSOCK·소유자==우리·0600인지 확인.
- **stale 소켓 판별(§4.2)**: `flock`은 소켓 fd가 아니라 **별도 `<key>.lock` regular 파일**에 건다(macOS는 소켓 fd `flock`이 `ENOTSUP`). lock 취득 성공=옛 소유자 부재→unlink-then-bind, 실패(EWOULDBLOCK)=살아있는 인스턴스→소켓 unlink 금지·중단. bind 이후 단계 실패 시 자기 lock 파일도 errdefer로 정리(빈 잔해 누적 방지). **다른 인스턴스**의 crash 잔해는 start마다 같은 flock 메커니즘으로 회수한다(§4.2 stale prune — `pruneStaleSockets`).
- accept마다 peer uid 검증. **1b 구현**: `getpeereid(2)`(LOCAL_PEERCRED/xucred·SO_PEERCRED/ucred 이식 wrapper, uid만; pid/LOCAL_PEERPID는 1e/1g)로 peer 유효 uid를 읽어 서버 uid와 비교, 불일치 시 연결 종료. 파일 권한에만 의존하지 않는다.

### 8.3 capability 인가
- 같은 uid의 임의 프로세스가 모든 surface를 제어·열람하면 sudo 세션·다른 보안등급 탭에 대한 권한 상승이 된다. capability는 `metadata:self`(자기 surface 열거/조회), `metadata:window`(호출 surface가 현재 속한 window 안의 surface 열거/조회), `metadata:all`(primary+quick 포함 전체 열거/조회), `bind`(`panel.bindSession`), `read-output`(`capture`/`subscribeOutput`), `write`(`send*`), `lifecycle`(`spawn`/`close`/`resize`/`focus`/`panel.open`), `browser`(페이지 조작/관찰=`browser.getCookies` 외 `browser.*`), `browser-storage`(`browser.getCookies`/`setCookie`/`deleteCookie`/`clearStorage` — 쿠키/스토리지 **읽기·쓰기·comprehensive 삭제**, §9.4 D5로 `browser`에서 분리·`allowedViaInheritedFd=false`)로 나눈다(§6 매핑의 단일 출처).
- unix socket path와 peer-cred는 "같은 사용자"와 "같은 인스턴스 발견"만 증명한다. 특정 surface 권한은 (a) capability fd(§8.5)로 받은 nonce, 또는 (b) `metadata:self`에 한정된 self-origin 증명(§8.4)으로만 생긴다. fd가 없거나 scope/generation/surface가 맞지 않으면 `unauthorized`다.
- **authz 실패는 surface 존재 여부와 무관하게 균일한 `unauthorized`를 존재검사 이전에 반환한다.** `surface_id`가 monotonic u64라 추측 가능하므로(§3), "존재하나 unauthorized" vs "없음/`process-exited`"의 에러가 다르면 live surface·generation 열거 oracle이 된다. `session.get`/`capture` 등 surface-scoped 메서드는 scope 판정을 존재·generation 확인보다 먼저 수행한다.
- spawn profile의 기본 grant는 보수적으로 둔다. 일반 login shell 자식은 `$MARU_SESSION` 기반 발견과 self-origin 증명을 통과한 `metadata:self`까지만 기본으로 둔다. self-origin 증명이 구현·실측되지 않았거나 실패하면 일반 login shell CLI도 metadata를 열지 않는다. `read-output:self`는 capability fd 보존이 실측된 non-login trusted agent/control profile 또는 별도 one-shot grant UX에만 붙인다. `write`·`lifecycle`·`browser`·cross-surface 권한은 기본 거부 또는 사용자 확인이다.
- **`sessions.list`와 `events.subscribe`는 전역 표면이라 `metadata:self`만으로 다른 surface 상태(cwd·생성/종료)가 누설되면 안 된다.** `metadata:self`는 응답을 자기 `(surface_id, generation)` 하나로 필터링하고, `events.subscribe` filter도 self-surface로 강제한다. 같은 창 전체는 현재 WindowGraph membership에 대한 `metadata:window`, quick 포함 전체는 `metadata:all`이 필요하다(filter 스키마 §13).
- `capture`·`subscribeOutput`은 비밀(스크롤백·실시간 출력)을 노출하므로 `read-output` capability가 필요하다. `capture`가 처음 노출되는 Phase 1 안에서 capability fd 발급·auth·거부 테스트까지 함께 구현한다. "read-only라 토큰은 나중"으로 미루지 않는다.

### 8.4 self-origin metadata 증명(일반 login shell)

일반 login shell에서는 현재 macOS login wrapper가 capability fd를 닫는 것으로 실측됐다(§8.5). 그래도 자기 surface의 최소 metadata는 CLI UX에 필요하므로, **비밀 토큰이 아니라 OS가 관측한 프로세스 출처**로 `metadata:self`만 연다. 이 경로는 `read-output`·`write`·`lifecycle`·`browser`·`bind`·cross-surface metadata에는 절대 쓰지 않는다.

인증 순서:

1. CLI가 `$MARU_SESSION` selector(`instance_nonce`, `surface_id`, `generation`)를 auth frame에 보낸다.
2. server는 selector가 현재 registry의 live surface를 가리키는지 확인한다. `surface_id`는 앱 인스턴스 전역 unique라 window별 충돌을 허용하지 않는다.
3. server는 unix socket peer uid/pid를 OS에서 읽고 same-uid를 확인한다.
4. server는 peer pid의 controlling tty identity와 foreground process group을 읽어, 후보 surface가 spawn할 때 기록한 PTY slave identity 및 현재 foreground process group과 비교한다. 둘 중 하나라도 불일치하면 `unauthorized`다.
5. 통과하면 해당 연결/request에만 `metadata:self`를 부여한다. 응답은 항상 자기 surface 하나로 필터링한다.

**A2b 구현 상태(정직 — same-uid+selector까지, tty 검증 없음)**: 라이브 서버 A2b는 위 **1·3·5만** 구현한다. peer-cred(3, same-uid gate)는 `acceptOne`이, 셀렉터(1)는 wire의 `auth.self` 프레임(`control_plane.serializeAuthSelf`/`parseAuthFrame` — 후자는 selector와 optional `cap_nonce`[1e]를 함께 뽑는다)이, `metadata:self` 부여+self 필터(5)는 dispatch(1d)가 한다(**셀렉터를 댄 연결에 한한다** — 안 댄 연결은 아래 `metadata:all` 문단을 따른다). **4단계(peer pid의 tty/foreground pgrp ↔ surface PTY 일치 검증)는 미구현 — 1g 후속이다.** 그리고 **셀렉터의 실제 전달 매개는 `$MARU_SESSION`이 아니라 `$MARU_PANE_ID`**(=surface.id, `pty/macos.zig`가 각 팬 셸에 주입하는 실제 env; `$MARU_SESSION` 복합 selector는 미도입)다. CLI(`main.runSessionRequest`)가 `MARU_PANE_ID`를 읽어 `auth.self{surface_id}`로 보낸다.

**⚠️ 이 auth의 경계 한계(A2b, §8.3/§8.4 대비)**: same-uid peer는 tty 검증이 없으므로 **임의 `surface_id`를 self로 주장**할 수 있다 — 즉 같은 uid의 임의 프로세스가 아무 surface_id나 셀렉터로 보내 그 **한 surface의 metadata(cwd·git_branch·focused·at_prompt)를 열람**할 수 있다. surface_id가 monotonic이라 낮은 값부터 셀렉터를 훑으면 여러 surface metadata를 순차 수집할 수 있다(실측으로 확인 — 한 번의 훑기로 첫 surface 의 메타데이터가 그대로 나왔다). read-output/write/lifecycle은 A2b에서 애초에 안 열린다(§8.3). **1g가 4단계 tty/pgrp 검증을 붙이기 전까지 `metadata:self`는 "같은 uid면 selector로 임의 surface metadata 열람 가능"이라는 한계를 갖는다.**

**셀렉터를 안 댄 연결은 `metadata:all`이다(2026-08-29).** 앞 문단이 예전에는 "scope 가 `metadata:self` 고정이라 `sessions.list` 전역 열거는 안 된다" 를 완화 요소로 들었는데, **그 완화는 실효가 없었다** — 같은 문단이 인정하듯 셀렉터를 훑으면 같은 것이 나온다. 그리고 그 좁힘은 실제로는 **정상 사용을 막고 있었다**: 폰이 SSH `exec` 채널로 여는 중계에는 `MARU_PANE_ID`가 없어 셀렉터를 못 대는데, 그때 `.self`(anchor=0)로 두면 목록이 언제나 비어 폰 화면에 "세션이 없다" 만 떴다([컨트롤 플레인 §4a](control-plane.md)가 그 계약을 이미 "앵커가 필요 없는 것은 된다" 로 적어 두었으나 코드가 어긋나 있었다).

- **셀렉터 있음** → 종전대로 `metadata:self`(그 surface 하나). 바뀐 것 없다.
- **셀렉터 없음** → `metadata:all`. 근거는 이 소켓의 등급이다: same-uid peer-cred + 0700 이라 붙은 쪽은 **그 사용자 자신**이고, SSH 로 붙은 폰도 같다 — 그 사용자로 아무 명령이나 돌릴 수 있으므로 목록이 권한을 넓히지 않는다(§4a "왜 이 모양인가").
- **넓어진 것은 metadata 뿐이다.** `session.capture`(read-output)·write·`browser.*` 는 그대로다 — 각각 cap 이나 target 앵커를 따로 요구하고, 이 규칙은 그 경로에 닿지 않는다.

셀렉터를 대는 쪽이 **더 좁다**는 것이 낯설게 읽히지만 그 방향이 맞다 — 셀렉터는 권한이 아니라 "나는 이 surface 다" 라는 **주장**이고, 주장한 만큼만 보는 것이 self-origin 의 뜻이다. 1g 가 4단계 tty 검증을 붙이면 그 주장이 비로소 검증되고, 그때 이 비대칭은 "검증된 좁힘 vs 미검증 넓힘" 이라는 뜻을 갖는다.

멀티윈도우와 quick terminal 처리:

- 일반 창 A/B와 quick terminal은 모두 앱 전역 `surface_id` 공간을 공유하므로 ID 충돌을 만들지 않는다. 창 A의 CLI가 창 B의 selector를 복사해 보내면 PTY identity/foreground pgrp가 B와 맞지 않아 거부되어야 한다.
- quick terminal은 `window_kind=quick`인 window에 속한 surface다. quick 안의 CLI는 quick 자기 surface의 `metadata:self`만 얻는다. 일반 창의 CLI는 quick을 기본으로 보지 못하고, quick CLI도 primary 창을 기본으로 보지 못한다.
- quick이 숨겨져 있어도 PTY/session이 살아 있으면 selector는 live일 수 있다. 단, lifecycle/write는 기본 거부이고 quick 제어는 별도 explicit grant가 필요하다.

**경계 강도 정직(적대적 리뷰 반영)**: 이 경로가 실제로 증명하는 것은 "peer가 surface의 controlling tty를 공유한다"뿐이지 "peer가 그 surface의 셸 자신이다"가 아니다. `childExec`는 셸에 `setsid`+`TIOCSCTTY(slave)`를 한 번 걸므로 **그 셸의 모든 자손**(background job, `disown`/`nohup`, subshell, 사용자가 실행한 도구의 하위 프로세스)이 같은 ctty를 물려받는다. 따라서:
- **4단계의 foreground pgrp 비교는 보안 경계가 아니라 UX 휴리스틱이다.** CLI 자신이 실행 순간 foreground이므로 정상 경로엔 제약이 0이고, background 형제는 `SIGTTOU`를 무시하고 `tcsetpgrp(getpgrp())`로 잠깐 자기를 foreground로 올려 통과할 수 있다(POSIX 허용). 실제 boundary는 **ctty identity binding(step 4의 tty 비교)뿐**이고, `metadata:self`는 사실상 **surface 세션 단위 grant**다. cross-surface 위장(다른 창/quick selector 복사)만 막힌다.
- **same-ctty 프로세스는 이미 tty를 소유하므로 `write` capability(§8.3) 밖에 있다.** macOS는 `TIOCSTI`를 게이팅하지 않아 same-ctty 코드는 컨트롤 플레인을 우회해 PTY에 직접 입력을 주입할 수 있다. write-cap이 방어하는 것은 cross-session same-uid 코드지 same-session 코드가 아니다.
- **`LOCAL_PEERPID`→pid 검사는 TOCTOU이며 best-effort다.** macOS엔 소켓 연결과 peer ctty를 원자적으로 묶는 primitive가 없다(`xucred`는 uid만). pid는 connect-time이고 ctty/pgrp는 별도 `proc_pidinfo`로 사후 조회하므로 pid 재사용 창이 존재한다. 하드 경계로 취급하지 않고 metadata-only에만 쓴다.
- **"PTY slave identity"를 구체화한다.** 현재 코드는 `openpty(name=null)`로 slave 이름을 안 잡는다. 기록 대상(`ptsname`/`st_rdev`)을 정하되 device number는 pty 해제 후 재사용되므로 **live surface 집합 안에서만** 비교하고 시간에 걸쳐 안정하다고 가정하지 않는다.
- **self-origin grant는 per-connection 캐시가 아니라 per-request 재평가**로 둔다(foreground였다가 background로 내려 연결을 유지해도 grant가 잔존하지 않게). self-origin에는 TTL/liveness 재확인을 붙인다.

**실측 필수 gate**: 이 모델은 구현 PR에서 제품 경로로 측정하기 전까지 완료 처리하지 않는다. 최소 실측 행렬은 primary 창 2개 + quick terminal 1개를 띄우고, 각 shell 안에서 `sessions.list`가 자기 surface 하나만 반환하는지, 다른 창/quick의 selector로 변조하면 거부되는지, maru 밖 일반 shell에서 복사한 selector가 거부되는지 확인한다. zsh/bash login shell, background child, tmux/screen pane, sudo/su는 별도 행으로 기록한다. tmux/screen처럼 nested PTY가 original Maru PTY와 다르면 기본 허용하지 말고 실제 결과를 `tests/artifacts/control-plane/self-origin.summary.txt`에 남긴다.

### 8.5 환경변수 노출·redaction·capability fd
- `$MARU_SESSION`은 키名에 `SESSION` 토큰을 포함하므로 [project-rules.md] §redaction의 deny-by-default 대상이다. trace/artifact에서 값을 마스킹한다. env는 보안 경계가 아니라 편의 채널이다(소켓 경로는 결정론적이라 env 없이도 발견됨). capability fd 번호를 담는 `MARU_CONTROL_CAP_FD`는 비밀이 아니지만, 그 fd에서 읽은 nonce는 절대 로그·trace·artifact에 쓰지 않는다.
- capability 발급: server가 256-bit random nonce를 만들고 server-side에는 `hash(nonce) -> {surface_id, generation, scopes, expires_at?, revoked}`만 저장한다. nonce는 0600 임시 파일에 쓴 뒤 read-only fd로 다시 열고 즉시 unlink한다. child spawn에는 그 read-only fd만 상속한다(다른 fd는 `CLOEXEC`, capability fd만 의도적으로 상속). CLI는 `MARU_CONTROL_CAP_FD`의 fd에서 offset 0 `pread`로 payload를 읽어 control socket의 첫 auth frame에 보낸다(여러 CLI 호출이 공유 file offset에 의존하지 않게). server는 hash를 constant-time 비교하고 surface generation·scope·TTL·revocation을 확인한다.
- fd payload는 magic/version/header를 포함한다. shell startup script가 같은 fd 번호를 닫거나 재사용하면 CLI는 임의 데이터를 nonce로 오해하지 말고 `capability-fd-invalid`로 실패한다. CLI는 nonce를 읽은 직후 capability fd를 닫거나 `FD_CLOEXEC`로 바꿔 pager/editor/helper 프로세스에 fd가 새지 않게 한다.
- **위협: capability fd는 셸 서브트리 전체가 읽는 ambient grant다(headline).** CLI가 fd를 상속하려면 **셸**이 그 fd를 `CLOEXEC` 없이 열어둬야 하는데(§8.5 실측: 셸이 fd를 닫으면 grant 실패로 취급), 그러면 그 셸이 exec하는 **모든 명령**(사용자가 실행한 curl·python·untrusted 자동화 포함 — 위협모델이 격리하려던 바로 그 저권한 코드)이 `pread(MARU_CONTROL_CAP_FD, 0)`로 같은 nonce를 얻는다. nonce는 bytes라 SCM_RIGHTS 없이 다른 프로세스로 forward도 된다. CLI가 자기 복사본을 닫아도 셸 복사본·형제 프로세스는 못 막는다. TTL/revocation은 창을 좁힐 뿐 형제 상속 자체는 못 막는다. 따라서 "fd 상속 = 프로세스 신원 증명"이라는 가정을 폐기한다:
  - `read-output`을 default grant에서 제외하고 **per-invocation 짧은 TTL + 명시 one-shot UX**로만 발급한다(현 §8.3 보수화에 "서브트리 전체 노출·과거 스크롤백 history 유출" 위협을 명시적 근거로 추가).
  - cap fd는 **single-scope**만 싣는다. `write`/`lifecycle`은 어떤 상속 fd 경로로도 발급하지 않는다(상속 fd로 `write`가 새면 same-uid untrusted 코드가 셸에 키 주입 = macOS `TIOCSTI` 제거 후 새로 생기는 권한). 이 둘은 per-request `SCM_RIGHTS` fd-passing 또는 명시 확인 UX로만. **1e 구현(`control_capability.zig` `validateFdIssuance`)**: `write`/`lifecycle` fd 발급 거부, `read-output`은 TTL(`expires_at`) 필수. `bind`/`browser`는 §8.5가 명시 금지하지 않아 현재 fd 허용이나, 그 채널을 실제 여는 Phase 5(`browser`)·Phase 7(`bind`)이 자체 발급 UX에서 더 조일지 재검토한다(코드는 `Scope.allowedViaInheritedFd` 한 곳). **재검토 결과(browser, 2026-07-13)**: `browser`의 **대화형 주 경로는 fd 상속이 아니라 pane-bound confirm-grant**(§9.2 Model B — grant를 tty-검증 pane 신원에 묶고 확인 모달로 게이트, bearer nonce/fd 없음)로 정한다. fd 경로(`allowedViaInheritedFd=true`)는 비대화형/상속 시나리오·스모크용으로 남기되 주 경로 아님. `browser_storage`는 fd 금지(§9.4 D5) — grant도 confirm-grant로만.
  - 대안 배포: 셸 통합이 rc에서 fd를 1회 읽고 즉시 `CLOEXEC`/close해 이후 명령이 상속하지 않게 한 뒤, CLI 호출마다 fresh per-invocation 채널을 mint한다.
- 실측 gate(2026-06-29, macOS Darwin 25.5): read-only unlinked fd는 offset 0 `pread` 재호출이 같은 payload를 돌려주고 write는 `EBADF`로 실패했다. 현재 macOS PTY login wrapper(`/usr/bin/login -flp ... /bin/bash --noprofile --norc -c "exec -l <shell> ..."`)는 `MARU_CONTROL_CAP_FD` env는 보존하지만 fd 자체는 닫았다(zsh/bash 모두 `EBADF`). 반면 non-login 직접 exec의 zsh/bash/sh 자식은 fd payload를 읽었다. 따라서 Phase 1의 `read-output` capability fd grant는 일반 login shell이 아니라 non-login trusted agent/control profile에서 먼저 구현한다. login shell에서 read-output이 필요하면 env bearer token으로 후퇴하지 말고 별도 one-shot grant UX를 설계한다.
- shell·daemon 영향 실측: synthetic `ZDOTDIR/.zshenv`가 fd를 닫으면 CLI는 fd read 실패로 닫힌다. 일반 background child는 fd를 유지했다. 이 환경의 tmux/screen pane은 env는 보존했지만 fd는 닫혀 있었다. 그래서 tmux/screen이 fd를 늘린다고 단정하지 않되, fd가 background/daemon에 남는 경우를 TTL+revocation 테스트로 계속 막는다. `sudo -n -E`는 로컬에서 비밀번호 요구로 미검증이므로 controlled sudoers 환경 또는 수동 gate로 둔다.
- revocation: surface close, generation 변경, grant 취소, TTL 만료 시 capability는 즉시 무효다. auth 성공 후에도 dispatch 시점과 streaming chunk 경계마다 `{surface_id, generation, scopes, revoked}`를 재검증한다. in-flight `capture`는 `capture-invalidated` 또는 `capability-revoked`로 성공 완료 없이 종료하고, `subscribeOutput`은 구독을 끊는다. **revoke·close 시 재검증은 생산 측(dispatch·chunk 경계)만이 아니라 outbound 큐도 대상이다** — 이미 직렬화돼 per-connection outbound 큐(§4.3)에 쌓인 해당 `capture_id`/구독의 잔여 프레임을 **즉시 폐기**하고 종료 오류만 보낸다(그러지 않으면 클라이언트가 일부러 느리게 read해 큐를 채운 뒤 close→revoke해도 큐 용량만큼 데이터가 revoke 이후 계속 나가, revocation의 보안 목적과 충돌한다). 같은 uid의 외부 프로세스가 결정적 socket path만 알아도 nonce fd를 상속하지 않았으면 `capture`/`subscribeOutput`을 호출할 수 없다.

### 8.6 WebDriver 어댑터
- TCP가 아니라 unix 소켓 위 HTTP(또는 loopback + 무작위 bearer 토큰 0600 파일) + Origin/Host 화이트리스트 + 기본 off. 인증 없는 localhost TCP는 cross-uid·CSRF로 `execute_script`/`get_cookies`를 노출하므로 금지한다.

### 8.7 SSH 원격 (2026-08-20 확정 — 단일 출처는 [컨트롤 플레인 §4a](control-plane.md))
- **토큰을 새로 만들지 않는다.** 예전 이 자리는 "원격이면 컨트롤 플레인 **자체 인증(토큰)** 필수" 였으나, 실제 결정은 **SSH 사용자 인증이 곧 신원**이다 — 별도 토큰은 그 수명·폐기·저장을 또 설계하게 만들고, 폐기 수단이 SSH(`authorized_keys`)와 두 곳으로 갈린다.
- **소켓은 여전히 로컬이다.** 원격에서 붙는 것은 그 PC 에서 **그 사용자로** 도는 중계 프로세스(`maru control --stdio`)라 peer-cred(same-uid)가 그대로 성립한다. 조건은 **SSH 로그인 사용자 == 앱을 돌리는 사용자**이고, 아니면 소켓 권한(0700)에서 막히는 것이 옳다.
- **포워딩을 안 쓴다.** `direct-streamlocal` opt-in 대신 SSH **`exec` 채널**을 쓴다 — 우리 코어가 그 채널 타입을 모르고, 써도 원격 쪽 버전·정책을 우리 코드가 볼 수 없다.
- **신뢰 등급은 데스크톱 클라이언트와 동등**(조회·구독·세션 전환·생성·`browser.*`). 폰은 이미 셸 열쇠를 들고 있어 좁혀도 실질 노출이 안 준다. 예외는 `command=`/`ForceCommand` 로 셸을 제한한 키인데, 그 서버에서는 `hello` 가 안 와 **축이 애초에 안 열린다**.
- **§8 의 per-surface capability 규칙은 원격에서도 그대로**다 — 등급이 같다는 말이지 인가를 건너뛴다는 말이 아니다.
