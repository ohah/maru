# 세션 컨트롤 플레인 — `browser.*` 코어와 CLI (§9 · §9.1 · §9.6)

`browser.*` 제어 표면의 목표와 경계, 헤드리스 스키마·디스패치·authz를 갖춘 제어 코어(5a), 그리고 `maru browser` CLI 클라이언트다. 라이브 배선과 지속 세션은 아래 표의 다른 문서가 소유한다.

> **절 번호는 파일을 넘어 이어진다.** 본문이 `§8.1`처럼 절만 가리키면 아래에서 소유 파일을 찾는다 — §1~§3·§5~§7·§10·§13~§15 [control-plane.md](control-plane.md) · §4 [transport·프로토콜](control-plane-protocol.md) · §8 [보안](control-plane-security.md) · §9.1·§9.6 [browser.\* 코어와 CLI](control-plane-browser.md) · §9.2~§9.3 [라이브 배선](control-plane-browser-wiring.md) · §9.4 [프로토콜 리뷰](control-plane-browser-review.md) · §9.5 [지속 세션·이벤트·대용량 결과](control-plane-browser-session.md) · §11~§12·§16 [구현 Phase와 검증](control-plane-implementation.md)

## 9. `browser.*` — WKWebView 제어 + WebDriver 어댑터

제어 코어(한 번만) 위에 두 얼굴: `browser.*`(컨트롤 플레인 wire 메서드) + W3C WebDriver 서버(외부, §8.6 인증).

- **CDP가 아니라 W3C WebDriver.** agent-browser 백엔드가 ~15개 명령(navigate/get_url/execute_script/screenshot/find_element/click/send_keys/back/forward/refresh/get_cookies/...)뿐이라 CDP(수백)보다 표면이 작고 WebKit 정합이다.
- 명령→WKWebView API: navigate→`load`, execute_script→`evaluateJavaScript`, screenshot→`takeSnapshot`, get_cookies→`WKHTTPCookieStore`, back/forward/reload→`goBack`/`goForward`/`reload`, find_element/click/send_keys→`evaluateJavaScript`. Swift는 API 호출만, 라우팅·매핑·프레이밍은 Zig.
- `safaridriver`는 Safari.app만 제어하므로 WKWebView용 WebDriver 서버는 직접 구현한다. agent-browser가 우리 endpoint에 붙는 통합은 별도(remote WebDriver URL 추가 — Apache-2.0 fork/PR, 또는 인터페이스 흉내).

### 9.1 5a — browser core (헤드리스 스키마·디스패치·authz·제어코어 skeleton)

Phase 5 첫 슬라이스. **실 WKWebView 실행 없이**(=5d) `browser.*`의 **wire 스키마 + 디스패치 라우팅 + `browser` capability authz + WKWebView 제어 코어 경계(skeleton)**를 헤드리스로 확정한다. 브리지(5b)·`maru-app://`/CSP(5c)·실 ops(5d)의 토대다. 이미 존재하는 조각 위에 얹는다: `control_plane.CoreNamespace.browser`(메서드 네임스페이스 파싱)·`control_capability.ScopeClass.browser`(capability 카테고리).

**① `browser.*` 메서드 스키마** — 신규 `src/session/control_browser.zig`(L2, `control_surface.zig`와 같은 "wire 스키마만" 레이어). W3C WebDriver 병렬 명령을 자체 enum + params/result DTO로 정의한다(내부 상태와 격리 — §3 정신, 내부 rename이 wire를 안 흔들게). `id`는 대상 **web surface_id**(u64):

| 메서드 | params | result | → WKWebView(5d) |
|---|---|---|---|
| `browser.list` | `{}` | `{surfaces:[{id, url, title, panel_kind}]}` | collector snapshot 필터(web만) — **ungated 발견**(§9.6, cap/grant/모달 불요; 제어는 게이트) |
| `browser.navigate` | `{id, url}` | `{ok}` | `load(URLRequest)` |
| `browser.getUrl` | `{id}` | `{url}` | `.url` |
| `browser.back`/`forward`/`refresh` | `{id}` | `{ok}` | `goBack`/`goForward`/`reload` |
| `browser.executeScript` | `{id, script, args?, max_result_bytes?}` | inline `{result, transfer:"inline"}` 또는 `browser.executeScriptChunk` notification×N → 최종 `{transfer:"chunked", result_id, seq_total, bytes}` | 5f-5c live: `script`=JavaScript 표현식, `args`=strict-JSON 배열(`args` 이름으로 접근), Promise 자동 await, strict CSP에서 string-eval 없음. raw strict-JSON ≤512 KiB inline, 그 초과~16 MiB progressive pump. hello 완료 capability는 Track 5 성능 gate 뒤에 연다. 16 MiB 초과와 대체 attachment는 후속 재검토(§4.4·§9.4 D6·§9.5.8) |
| `browser.screenshot` | `{id, format?, rect?, scale?}` | `browser.screenshotChunk` notification×N → 최종 응답 `{capture_id, seq_total, bytes, width, height, format}` | `takeSnapshot`→PNG, **소켓 chunk-streaming**(§9.5.3·§9.5.7 — `{png_base64}` 단일 응답 폐기: >1MB 프레임 상한). rect=`WKSnapshotConfiguration.rect`·scale=`.snapshotWidth` |
| `browser.snapshot` | `{id, interactive_only?, max_depth?, selector?}` | ARIA 트리 `{role,name,ref?,value?,state?,children}` | eval read-only DOM walk + W3C accname, 임시 `data-maru-ref`, inline — scope=`browser`(snapshot-1 구현 §9.5.4) |
| `browser.click` | `{id, selector? \| ref?}` | `{ok}` | eval `querySelector(sel).click()` 또는 `[data-maru-ref=ref]` — scope=`browser`(5f-2 selector·snapshot-2 ref 구현 §9.5.4, 배타) |
| `browser.type` | `{id, selector? \| ref?, text}` | `{ok}` | eval input `.value` + input/change 이벤트 — scope=`browser`(5f-2 selector·snapshot-2 ref 구현) |
| `browser.scroll` | `{id, selector? \| ref?}` | `{ok}` | eval `scrollIntoView()` — scope=`browser`(5f-2 selector·snapshot-2 ref 구현) |
| `browser.wait` | `{id, condition:"selector", selector, timeout_ms?}` 또는 `{id, condition:"load", timeout_ms?}` | `{ok}` / timeout `-32004` | selector=visible DOM box, load=현재 `isLoading == false`; 기본·최대 25,000ms, 100ms 직렬 polling — scope=`browser`(5f-2) |
| `browser.console` | `{id, clear?}` | `{console:[{level,text}]}` | page-world `console.*`/onerror 주입 override → bounded 페이지 ring → throttled proactive drain → Swift 서버 버퍼(네비 넘어 보존) → pull. `clear`=반환 후 비움 — scope=`browser`(설계 §9.5.9, 핸들러 0·§8.1(c) 유지) |
| `browser.findElement`/`sendKeys` | — | — | `snapshot`+ref act로 대체(§9.5.4) — 별도 메서드 불요 |
| `browser.getCookies` | `{id}` | `{cookies}` | `WKHTTPCookieStore.getAllCookies` |
| `browser.setCookie` | `{id, name, value, domain?, path?, secure?}` | `{ok}` | `WKHTTPCookieStore.setCookie` — scope=`browser_storage`(§9.4 D4). httpOnly 미지원(WKWebView 한계) |
| `browser.deleteCookie` | `{id, name, domain?, path?}` | `{ok}` | `WKHTTPCookieStore.delete` — scope=`browser_storage` |
| `browser.getLocalStorage` | `{id, key}` | `{value}` | eval `localStorage.getItem` — scope=`browser`(exec와 동일 도달) |
| `browser.setLocalStorage` | `{id, key, value}` | `{ok}` | eval `localStorage.setItem` — scope=`browser` |
| `browser.removeLocalStorage` | `{id, key}` | `{ok}` | eval `localStorage.removeItem` — scope=`browser` |
| `browser.clearStorage` | `{id}` | `{ok}` | `WKWebsiteDataStore` 대상 origin 삭제 — scope=`browser_storage`(쿠키 포함) |

`BrowserMethod` enum + `parseBrowserMethod` + 각 params 파서(InvalidParams 규율은 `control_dispatch`의 `session.get` 선례) + result 직렬화. **5a 구현 범위(사용자 결정 2026-07-10)**: 위 표는 5a 당시 로드맵이고(§9.4 능력 택소노미가 이후 이를 대폭 확장 — snapshot/wait/이벤트/storage/performance 등; findElement는 노드-ref snapshot 모델로 대체, screenshot 결과는 §9.5.3대로 chunk 전달로 정정 — 최신 로드맵=§9.4/§9.5), **5a는 핵심 3개 `browser.navigate`/`browser.getUrl`/`browser.executeScript`의 스키마·파싱·직렬화만** 확정한다(디스패치·authz는 네임스페이스 단위라 아래 ②③이 browser.* 전부를 균일 처리 — 스키마 없는 나머지 메서드는 `method_not_found`/`not_implemented`). 나머지 메서드(screenshot/back/forward/refresh/findElement/click/sendKeys/getCookies)의 스키마·실행은 **5d**에서 확장한다.

**② 디스패치** — `browser.*`는 **write-class**(WKWebView 상태 변경)라 read-only 라우터(`dispatchReadOnly`)가 아니라 write/lifecycle 경로다. 순서: `parseMethod`(browser 네임스페이스) → **authz(③)** → **대상 surface 검증**(surface_id 존재 + `kind==.web` — terminal id면 `invalid_params`/`unauthorized` 균일) → **main frame loop로 marshal**(WKWebView는 Swift·메인 스레드 소유, collector와 같은 marshal 패턴 §2) → Swift **제어 코어(④)**. 5a는 제어 코어를 skeleton으로 두어 dispatch가 `not_implemented`(또는 stub result)를 반환 — **파싱·authz·surface 검증까지 헤드리스 red test**, 실행은 5d.

**③ authz(§8.3)** — `browser.*` → `ScopeClass.browser`. `browser` capability가 없으면 **존재검사 이전에 §8.3 균일 unauthorized**(`session.get`의 read-output 접기와 동형 — 존재 여부 누설 금지). `browser`는 **기본 거부**라 일반 login shell 자동경로로는 절대 안 열리고 capability fd(§8.5) 또는 명시 grant로만 열린다(§8.3). **fd 상속 가부(정정 — 옛 서술은 §8.5·§9.2와 정반대였음)**: base `browser`(act/perceive)는 §8.5·§9.2 채택안대로 **fd 상속 허용**(`allowedViaInheritedFd=true`, 주 경로); 단 §9.4 D5의 민감 서브스코프 `browser_storage`/`browser_network`는 **fd 상속 금지**(명시 확인/`SCM_RIGHTS`만). write·lifecycle이 fd 상속 금지인 것과 대비. 5a는 capability category 매핑 + 거부 경로를 테스트(발급 UX는 별도).

**④ WKWebView 제어 코어 skeleton (L4)** — `src/platform/macos`에 `BrowserControl`(가칭) 구조체 인터페이스. web surface_id를 받아 `TerminalSurface.webPanels[id].webView`에 §9 매핑대로 API를 호출하는 **시그니처·경계만** 5a에서 정의(navigate/getUrl/executeScript/…). 실 호출·async 완료(evaluateJavaScript/takeSnapshot은 콜백)·프레이밍은 5d. Swift는 **API 호출만**, 라우팅·매핑·wire는 Zig(§9 원칙).

**⑤ 슬라이스 경계** — 5a=헤드리스(①②③④ skeleton). **5b**=isolated `WKContentWorld` 브리지(`window.maru.*`, §8.1 origin 격리). **5c**=`maru-app://` 스킴 핸들러 + 엄격 CSP + realpath/symlink/traversal 거부([web-panel.md] §7). **5d**=제어 코어 skeleton을 실 WKWebView API로 채움(navigate/executeScript/screenshot 최소 3개 먼저, fixture E2E).

**⑥ TDD(전부 헤드리스)** — `control_browser` 스키마 파싱/직렬화 단위(각 메서드 params 유효/오류) + dispatch authz(browser capability 없음→unauthorized·있음→통과·surface_id 부재/`kind==.terminal`→균일 거부) red→green. WKWebView·브리지·스킴은 5b~5d.

**⑦ 구현 상태 — 5d(제어 코어 실 WKWebView API + fixture E2E, 구현 완료)**: `MaruAppHost.swift`의 `enum BrowserControl`(L4 어댑터) — web 패널 webView를 받아 §9 매핑대로 호출만 한다: `navigate(url)`=`load(URLRequest)`, `currentUrl()`=`.url`, `executeScript(script)`=`evaluateJavaScript`(async 콜백). 5d 범위=핵심 3개(navigate/getUrl/executeScript). **fixture E2E(macos smoke, MARU_WEB_PANEL — browser/untrusted 패널)**: 초기 로드 후 무-네트워크 `data:text/html,…` URL로 navigate→그 로드 완료 시 `currentUrl`(navigate 검증)·`executeScript("…textContent")`(스크립트 실행 검증). 실측: `browser_fixture_url=data:…maru5d…`·`browser_fixture_script=maru5d`. **범위 밖(5d 기준)**: screenshot(`takeSnapshot`)·back/forward/refresh/findElement/click/sendKeys/getCookies는 후속(5f). **라이브 배선은 5e에서 완료**(외부 소켓 → `dispatchAuthenticated`→`browserOpFromRequest`(5e-2a) → §5-async marshal(§5-async) → Zig L4 op 큐(5e-2b-1) → Swift `drainBrowserOps`→`BrowserControl`→complete(5e-2b-2)) — §9.3 5e-2a/5e-2b-1/5e-2b-2 참조. 5d는 이 코어를 fixture로 먼저 확립해 실 WKWebView 실행 API·async 완료를 de-risk했고, 5e가 인가(browser cap)·wire·async marshal을 실제로 태우는 소켓 전 경로를 붙였다.

### 9.6 `maru browser` CLI 클라이언트 (doc-first 2026-07-13)

**목적**: 지금까지 배선한 `browser.*`(navigate/getUrl/executeScript/getCookies)·grant 모달(§9.2 Model B)을 **에이전트가 실제로 쓸 수 있는 클라이언트**로 노출한다. 현재 유일한 드라이버는 스모크의 인-프로세스 소켓 클라뿐 — CLI가 이 표면을 활성화한다. maru pane에서 돌던 에이전트(예: Claude Code)가 `maru browser navigate --surface N <url>`로 옆 브라우저를 제어하고, 미grant면 사용자에게 확인 모달이 떠 승인 후 실행된다.

**구현 상태(5f-5c 기능 완료)**: `exec --args <json-array>`·`--max-result-bytes`(1..16 MiB)·`--out`, executeScript expression/Promise await, inline/chunk 검증과 secure atomic spool/no-replace가 live다. screenshot도 전체 PNG를 CLI RAM에 재조립하지 않고 같은 512 KiB scratch+spool 원칙을 쓴다. strict-CSP 실제 WKWebView smoke는 direct expression/await 성공·nested eval 차단·고유 URL commit 확인과 page marker handshake 뒤 실행 중 navigation의 `kind="navigation"` 분류를 함께 검증한다. surface close는 Swift running set을 선제 종료해 WKWebView를 붙잡지 않고 Zig abandoned reservation의 backend terminal을 회수한다. hello max-result capability는 Track 5 성능 완료 gate 전까지 보류한다.

**설계(1d `sessions` CLI 패턴 미러링 — 재구현 금지)**: L2 순수(`src/cli/browser.zig` — 인자 파싱·wire 조립·stream validator) + main.zig I/O(소켓 발견·connect·auth.self·프레임 왕복·file sink — `runSessionCli`와 동형). **서브커맨드**: `list`·`navigate --surface N <url>`·`get-url --surface N`·`exec --surface N [--args JSON_ARRAY] [--max-result-bytes N] [--out FILE] <expression>`·`get-cookies --surface N`·`wait --surface N (--selector CSS | --load) [--timeout MS]`·`screenshot --surface N [--out f] [--rect x,y,w,h] [--scale s]`. `exec`의 stdout과 `--out`은 모두 현재 16 MiB effective max를 따르며 그 밖은 parser가 거부한다. **모든 결과는 먼저 0600 `std.Io.File.Atomic` spool에 기록**하고 request/result/capture id·seq·최종 bytes·strict JSON 또는 PNG IHDR metadata를 모두 검증한 뒤에만 sink로 보낸다. stdout은 검증 완료 뒤 positional read로 출력해 partial stdout을 막고, `--out`은 `File.Atomic.link`의 atomic no-replace로 게시한다. 구현체가 unnamed temporary file을 지원하지 않으면 동일 destination directory의 random temporary file로 emulation하며 `deinit`이 오류·연결 종료 시 cleanup한다. target 충돌은 기존 파일을 덮어쓰지 않는다. CLI는 최대 결과를 JSON tree나 PNG 전체 buffer로 재조립하지 않고 512 KiB decode scratch만 유지한다. crash/power-loss durability를 위한 parent-directory fsync는 이 기능의 계약이 아니며, 향후 필요하면 별도 durability 옵션으로 설계한다. 표시 절단은 별도 옵션이어야 하며 raw JSON을 조용히 잘라서는 안 된다.

**9.6.1 — web surface 발견 (`browser.list`, 사용자 결정 2026-07-13)**. **문제(실 테스트가 노출)**: 제어(navigate/screenshot 등)는 전부 대상 `--surface N`을 요구하는데, `maru sessions list`는 **metadata:self scope**라 호출 pane 자신만 보이고 **형제 web 패널이 안 나온다**(§8.4 self-only는 same-uid peer의 metadata 유출을 제한하는 의도적 선택). 즉 에이전트가 제어할 web surface_id를 발견할 방법이 없었다(초판 CLI의 "sessions list로 발견"이 실제로 안 됨). **결정: 전용 `browser.list`**. 인스턴스의 **web surface만**(터미널 제외) `{id, url, title, panel_kind}`로 나열한다. **ungated**(cap/grant/모달 불요) — 같은 uid는 사용자 자신의 브라우저라 URL 노출을 수용한다는 사용자 결정. 제어는 여전히 §9.2 Model B 모달 게이트를 거치므로, 발견≠제어(발견은 "무엇이 있나", 제어는 "허용받아 조작"). 라우팅: `dispatchAuthenticated`가 `browser.list`를 cap 로직 **진입 전에** 접어 `serializeBrowserListResult(snapshot)`로 응답(nonce·selector 무관 균일). CLI 흐름: `maru browser list` → web surface 목록 → 그 id로 `maru browser screenshot --surface N` 등. **후속(더 조일 때)**: self-origin 요구(실 maru pane만)·window scope 한정·민감 URL 마스킹은 필요 시 검토(§8.4 트레이드오프).

**auth·grant 상호작용(핵심)**: CLI는 `auth.self`(selector=`MARU_PANE_ID`, **cap_nonce=null** — sessions CLI와 동일)만 보낸다. browser 요청은 세션 cap이 없으므로 §9.2 Model B로 **needs_grant→서버가 held→확인 모달**. **CLI는 응답을 블로킹 read로 기다린다** — 사용자가 모달을 클릭할 때까지(read가 블록). 승인→응답 렌더, 거부→`Unauthorized`, 무응답 timeout(`grant_prompt_timeout` 후 서버 reap→연결 닫힘)→EOF(응답 없음). sessions CLI가 hello skip 후 첫 응답에서 종료하는 것과 동형이되, browser는 held로 **응답이 늦을 수 있음**(read 타임아웃을 짧게 걸지 말 것 — 모달 대기).

**슬라이스**: **CLI-0(doc, = 이 절)**. **CLI-1(L2 순수)**=`cli/browser.zig`(파싱·요청 바이트·렌더링) 헤드리스 TDD. **CLI-2(main 배선)**=main.zig `browser` 서브커맨드→소켓 왕복(runSessionCli 재사용/미러). 손 테스트(에이전트가 CLI로 브라우저 제어→모달→실행). **MCP 어댑터**는 CLI 검증 후 별도(§10 note — wire가 JSON-RPC 2.0이라 얇게 얹힘).
