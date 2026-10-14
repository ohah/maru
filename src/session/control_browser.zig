//! control_browser — 컨트롤 플레인 **`browser.*` wire 스키마 + 디스패치 + authz**(L2 순수, OS-중립).
//! Track C slice 5a(Phase 5 첫 슬라이스). 단일 출처: docs/control-plane-browser.md §9.1(5a browser core)·§9(browser.*
//! 매핑)·§8.3(균일 unauthorized)·§6 line 111(method↔scope)·§11(slice 5a·코드 배치 gate)·§16(코어 L2 = src/session/).
//!
//! **1a/1c/1e/1d와의 관계**: 1a(control_plane.zig)=wire 프리미티브(JSON-RPC parse/serialize/framer/error-model·
//! `parseMethod`의 `CoreNamespace.browser`), 1c(control_surface.zig)=Surface 엔티티 DTO(`web` surface=`detail==.web`)
//! + `CollectorSnapshot`, 1e(control_capability.zig)=`Capability`·`authorize`·`ScopeClass.browser`. 5a는 그 위에
//! `browser.*`의 **메서드 스키마 + 요청 바이트→응답 바이트 디스패치 + browser capability authz**를 얹는다.
//! 1d(control_dispatch.zig)의 read-only 라우터와 대칭 구조(parse→라우팅→errorResponse)이나, `browser.*`는
//! **write-class**(WKWebView 상태 변경, §9.1 ②)라 read-only 라우터가 아니라 별도 write/lifecycle 경로다.
//!
//! **범위(5a, 헤드리스·순수 — 실 WKWebView 실행은 5d):**
//!   ① `browser.*` wire 스키마: `BrowserMethod`(5a 핵심 3개 navigate/getUrl/executeScript) + `parseBrowserMethod`
//!      + 각 params 파서(navigate `{id,url}`·getUrl `{id}`·executeScript `{id,script}`) + result 직렬화
//!      (navigate `{ok}`·getUrl `{url}`·executeScript `{result}`). W3C WebDriver 병렬 명령을 **자체 enum + DTO**로
//!      정의해 내부 상태와 격리(§3 정신 — 내부 rename이 wire를 안 흔들게). `args`(executeScript)는 5d.
//!   ② `dispatchBrowser`: 요청 한 줄 + 주입 snapshot + 주입 `caller_caps`(세션 누적 cap **집합** — 라이브 서버가 각
//!      nonce→Capability lookup해 넘김, 1e·5f-4a) → `BrowserDispatch`(게이트 실패=`err` 응답 바이트 / 통과=`op` 실행 op).
//!      집합 중 **하나라도** target+method 인가하면 통과(§9.5.6 ③). **정확한 보안 순서**(아래).
//!      **5e**: 옛 skeleton(`internal_error "not implemented (5d)"`)을 **`BrowserOp` 반환**으로 교체 — 모든 게이트를
//!      통과한 인가·유효 요청을 L4가 §5-async marshal → Swift `BrowserControl`이 WKWebView API 호출.
//!   ③ authz(§8.3): `browser.*`→`ScopeClass.browser`(1e `methodRequiredScope`가 단일 출처). browser cap 없거나
//!      deny면 **존재검사 이전에 균일 unauthorized**(oracle 방지). browser cap의 anchor는 target web surface(dispatchAuthenticated가 위임).
//!
//! **범위 밖(구현 금지 — 이 파일 밖)**: isolated `WKContentWorld` 브리지(5b)·`maru-app://` 스킴+CSP(5c)·실 WKWebView
//! API 호출(navigate=`load`/executeScript=`evaluateJavaScript`, 5d, Swift `BrowserControl`)·**dispatchAuthenticated
//! 라우팅 + L4 marshal + ABI(5e-2)**·나머지 메서드(screenshot/back/forward/…) 스키마·실행(5f). 이 파일은 `BrowserOp`
//! 산출까지(순수 L2). op의 실 실행·응답 직렬화 배선은 L4(app_host_abi)가 소유한다.
//!
//! **보안 불변식(§8.3·§9.1 ②③ — 구현·주석 둘 다):**
//!   - **authz(순서 4)는 존재검사(순서 7)보다 먼저**. `surface_id`가 monotonic u64라(§3) "존재하나 unauthorized"
//!     vs "없음"의 에러가 다르면 live surface 열거 oracle이 된다(§8.3). session.get(control_surface)의 균일
//!     unauthorized 패턴과 동형.
//!   - **모든 deny는 하나의 `unauthorized`**. cap 부재·revoked·expired·surface_mismatch·generation_mismatch·
//!     scope_insufficient·surface 부재·surface가 terminal(web 아님)이 **전부** 균일 `unauthorized`(-32002)로 접힌다.
//!     deny 이유는 절대 wire로 안 나간다(`authorize`의 `.deny` reason을 버리고 message는 균일 "Unauthorized").
//!   - id 형식 오류(순서 3)만 `invalid_params`다 — surface 존재 oracle이 아니라 요청 형식 오류라 session.get과 동일.
//!
//! **L2 순수:** std + control_plane(1a) + control_capability(1e) + control_surface(1c) + control_events(5f-0a: browser.subscribe
//! 이벤트 필터 vocabulary)만 import한다(app/pty/platform/chrome import 0 — tests/boundary/imports.zig가 강제). OS 타입 0.

const std = @import("std");
const cp = @import("control_plane.zig");
const capmod = @import("control_capability.zig");
const cs = @import("control_surface.zig");
const cev = @import("control_events.zig"); // 5f-0b-3b: browser.subscribe params의 events 필터(EventKind/EventFilter)
const cpg = @import("control_pane_grant.zig");
const new_tab = @import("web_sidecar/new_tab.zig");
const ws_wire = @import("web_sidecar/wire.zig"); // W9c②: 대화상자 답 글 상한(sidecar 가 받는 것과 같다) // W9b③: browser.open 의 주소 규칙(페이지가 여는 새 탭과 같다) // 1e-confirm-1b: pane-bound confirm-grant 조회(§9.2 Model B — 세션 cap OR pane grant 가법)

// ── ① browser.* wire 스키마(§9.1 ①) ──────────────────────────────────────────────────────────────────────

/// 구현된 `browser.*` 메서드(§9 표). async op의 enum tag는 Swift `drainBrowserOps` op_kind wire이므로 끝에만 추가하고
/// `app_host_abi.zig` 숫자 assert를 같이 갱신한다. 아직 없는 back/forward/refresh/findElement/sendKeys 등은
/// `parseBrowserMethod`가 null을 반환해 `method_not_found`로 접는다.
pub const BrowserMethod = enum {
    /// `browser.navigate {id, url}` → 5d `load(URLRequest)`.
    navigate,
    /// `browser.getUrl {id}` → 5d `.url`.
    get_url,
    /// `browser.executeScript {id, script, args?, max_result_bytes?}` → 5f-5c `callAsyncJavaScript` expression/await.
    execute_script,
    /// `browser.subscribe {id, events?}`(5f-0b-3b) → **동기 registry 구독**(async op 아님). L4가 SubscriberRegistry에
    /// 등록하고 `{subscriber_id}` 응답. events 없으면 전체, 있으면 그 종류만(§9.5.2).
    subscribe,
    /// `browser.getCookies {id}`(5f-4c) → 5d/5f Swift `WKHTTPCookieStore.getAllCookies`(async). result=`{cookies:[...]}`.
    /// **`browser`가 아니라 `browser_storage` scope 요구**(§9.4 D5 — 쿠키=인증 토큰, `methodRequiredScope`가 단일 출처).
    /// **op_kind=4 고정**(app_host_abi 컴파일 assert — enum 재배치 금지, 새 async 메서드는 뒤에 추가).
    get_cookies,
    /// `browser.screenshot {id, format?}`(5f-1) → 5f Swift `WKWebView.takeSnapshot`(async)→PNG. 결과는 단일 응답이
    /// 아니라 **소켓 chunk-streaming**: `browser.screenshotChunk` notification×N + 최종 응답(complete+metadata)
    /// (§9.5.3·§9.5.7 — PNG는 프레임 상한 1MiB를 넘을 수 있어 단일 `{png_base64}` 폐기). completeBrowserOp이 이
    /// method를 감지해 serializeBrowserResponse(단일) 대신 chunk 경로로 분기한다. scope=`browser`(base).
    /// **op_kind=5 고정**(app_host_abi 컴파일 assert — enum 재배치 금지, 끝에 추가).
    screenshot,
    /// `browser.setCookie {id, name, value, domain?, path?, secure?, httpOnly?}`(cookie write) → Swift `WKHTTPCookieStore.setCookie`.
    /// **`browser_storage` scope**(getCookies와 동일 — §9.4 D4 사용자 결정 read+write 동일 scope). op.arg=쿠키 필드 compact JSON.
    /// **op_kind=6 고정**(app_host_abi 컴파일 assert — 끝에 추가).
    set_cookie,
    /// `browser.deleteCookie {id, name, domain?, path?}`(cookie write) → Swift `WKHTTPCookieStore.delete`. `browser_storage` scope.
    /// op.arg=`{name, domain?, path?}` compact JSON. **op_kind=7 고정**.
    delete_cookie,
    /// `browser.getLocalStorage {id, key}` → `{value}`. Swift `evaluateJavaScript("localStorage.getItem(...)")`(WKWebView에
    /// 네이티브 localStorage API 없음 — eval 백엔드). **base `browser` scope**(exec와 같은 도달이라 D5 laundering-hole 불변).
    /// op.arg=key. **op_kind=8 고정**.
    get_local_storage,
    /// `browser.setLocalStorage {id, key, value}` → `{ok}`. eval `localStorage.setItem`. base `browser`. op.arg=`{key,value}` JSON. **op_kind=9**.
    set_local_storage,
    /// `browser.removeLocalStorage {id, key}` → `{ok}`. eval `localStorage.removeItem`. base `browser`. op.arg=key. **op_kind=10**.
    remove_local_storage,
    /// `browser.clearStorage {id}` → `{ok}`. Swift `WKWebsiteDataStore`로 대상 origin 쿠키+스토리지 comprehensive 삭제.
    /// **`browser_storage` scope**(쿠키=토큰 건드림). op.arg=빈. **op_kind=11 고정**.
    clear_storage,
    /// `browser.click {id, selector|ref}` → `{ok}`(ok=요소 발견+클릭). eval `querySelector(...).click()`. base `browser`.
    /// op.arg=`{selector}` 또는 `{ref}` JSON(§9.5.4 — ref=snapshot이 부여한 data-maru-ref, 배타). **op_kind=12 고정**.
    click,
    /// `browser.type {id, selector|ref, text}` → `{ok}`. eval로 input/textarea .value 설정 + input/change 이벤트. base `browser`.
    /// op.arg=`{selector|ref, text}` JSON. **op_kind=13**.
    type_text,
    /// `browser.scroll {id, selector|ref}` → `{ok}`. eval `querySelector(...).scrollIntoView()`. base `browser`. op.arg=`{selector|ref}`. **op_kind=14**.
    scroll,
    /// `browser.wait {id, condition, selector?, timeout_ms?}`(5f-2) → `{ok}`. selector=visible DOM 조건, load=현재
    /// `WKWebView.isLoading == false`. base `browser`. **op_kind=15 고정**.
    wait,
    /// `browser.snapshot {id, interactive_only?, max_depth?, selector?}`(§9.5.4) → `{snapshot:{tree:[...]}}`. eval read-only
    /// DOM walk + W3C accname로 ARIA 트리(role/name/ref) 계산, 상호작용 요소에 임시 `data-maru-ref` 부여(ref act가 해소).
    /// base `browser` scope(executeScript/act와 같은 eval 도달). op.arg=`{interactive_only?,max_depth?,selector?}` JSON.
    /// **op_kind=16 고정**(app_host_abi 컴파일 assert — enum 재배치 금지, 끝에 추가).
    snapshot,
    /// `browser.console {id, clear?}`(§9.5.9) → `{console:[{level,text}]}`. page-world 주입 override가 쌓은 콘솔을 Swift
    /// 서버 버퍼(네비 넘어 보존)에서 회수. `clear`=반환 후 버퍼 비움. base `browser` scope(콘솔 텍스트=executeScript 결과
    /// 등급). op.arg=`{clear?}` JSON. **op_kind=17 고정**(app_host_abi 컴파일 assert — enum 재배치 금지, 끝에 추가).
    console,
    /// `browser.back {id}`·`browser.forward {id}` → `{ok:<bool>}`(갈 곳이 없으면 false), `browser.reload {id}` → `{ok:true}`(W9b① —
    /// Chromium 전용: DevTools 방문 기록·`Page.reload`. WebKit 은 걷어낼 예정이라 새로 두지 않는다 — `-32008`). op.arg 빈 것.
    /// **op_kind=18·19·20 고정**.
    back,
    forward,
    reload,
    /// `browser.hover {id, selector|ref}` → `{ok}`(W9b①b-2 — Chromium 전용: 진짜 포인터 이동 `Input.dispatchMouseEvent mouseMoved`,
    /// 페이지는 isTrusted mouseover·`:hover`). op.arg=`{selector|ref}`. **op_kind=21 고정**.
    hover,
    /// `browser.press {id, key, selector?|ref?}` → `{ok}`(W9b①b-2 — Chromium 전용: 진짜 키 누름·뗌 `Input.dispatchKeyEvent`).
    /// key=`수식키+…+키`(예 `Enter`·`Shift+Tab`·`Meta+a`). 대상이 있으면 그 요소에 초점을 주고 누르고, 없으면 지금 초점에.
    /// op.arg=`{key, selector?|ref?}`. **op_kind=22 고정**.
    press,
    /// `browser.open {url?, timeout_ms?}`(W9b③ — Chromium 전용) → `{id, url, loaded}`. 대상 탭이 아직 없어 `id` 를 받지 않는다 —
    /// op 의 `surface_id` 는 부른 pane(1g 가 찾은 pane). 확인 모달 없음(사용자 결정 2026-10-10 — pane 신원만). 앱이 그 pane 의 탭 줄
    /// 끝에 뒤쪽 탭으로 열고(포커스 그대로) 그 pane 이 곧 제어하게 grant 를 넣은 뒤, 요청한 주소의 첫 불러오기까지 기다려 답한다.
    /// op.arg=`{url?, timeout_ms}`. **op_kind=23 고정**.
    open,
    /// `browser.close {id}`(W9b③ — Chromium 전용) → `{closed:true}` 또는 `{closed:false, reason}`. 그 pane 이 연 탭만(앱이 본다).
    /// 여는 순간 넣은 `browser` grant 가 없으면 확인 모달 없이 `unauthorized`(남의 탭을 닫으려고 허락을 묻지 않는다). 페이지에 묻는
    /// 닫기 — 떠나기 확인으로 물으면 기다리지 않고 `closed:false`(사용자가 그 탭에서 정한다). op.arg 빈 것. **op_kind=24 고정**.
    close,
    /// `browser.dialog {id}`(W9c② — Chromium 전용) → `{dialogs:[…]}` — 그 탭의 팝업 가족에 떠 있는 JS 대화상자·파일 선택(권한 요청은
    /// 싣지 않는다). grant 가 있는 탭의 것만 전부(`token`·글·`cause`·`may_answer`), 나머지는 `{tab, kind}`. DevTools 를 부르지 않아 앱이
    /// 곧 답한다(대화상자로 멈춘 탭의 op 줄 뒤에 서지 않는다). op.arg 빈 것. **op_kind=25 고정**.
    dialog,
    /// `browser.handleDialog {id, accept, text?, dialog?}`(W9c② — Chromium 전용) → `{ok:true, kind, continues?}`. `dialog`(번호)가 없으면
    /// 그 탭 자신의 대화상자, 있으면 grant 가 있는 가족 탭의 그 대화상자. 답해도 되는지(`may_answer`)는 앱이 본다. 파일 선택은 닫기만.
    /// op.arg=`{accept, text?, dialog?}`. **op_kind=26 고정**.
    handle_dialog,
    /// `browser.upload {id, selector|ref|locator, files:[절대 경로]}`(W9c③ — Chromium 전용) → `{origin, files:[{name,size}]}`. 로케이터가 가리킨
    /// `<input type=file>` 에 파일을 넣는다. **부를 때마다 확인 모달**(grant·cap 이 있어도 — 기억하지 않는다)이 파일을 모두 보이고, 앱이 파일을 열어
    /// 승인 뒤에 사본을 만들어 그 사본을 넣는다(docs/plans/web-osr-backend.md 「W9c③ 결정」). op.arg=`{선택자 필드, files:[…]}`. **op_kind=27 고정**.
    upload,
};

/// `parseMethod("browser.navigate").rest`(= "navigate")를 `BrowserMethod`로 매핑한다(순수, 할당 없음). wire 이름은
/// camelCase(§9 표 그대로): navigate/getUrl/executeScript. 5a 미구현 메서드(screenshot 등)·미지 문자열 → null
/// (dispatch가 `method_not_found`). enum 자체가 wire↔내부 격리라 내부 이름 리팩터가 wire를 안 흔든다(§3 정신).
pub fn parseBrowserMethod(rest: []const u8) ?BrowserMethod {
    if (eq(rest, "navigate")) return .navigate;
    if (eq(rest, "getUrl")) return .get_url;
    if (eq(rest, "executeScript")) return .execute_script;
    if (eq(rest, "subscribe")) return .subscribe;
    if (eq(rest, "getCookies")) return .get_cookies;
    if (eq(rest, "screenshot")) return .screenshot;
    if (eq(rest, "setCookie")) return .set_cookie;
    if (eq(rest, "deleteCookie")) return .delete_cookie;
    if (eq(rest, "getLocalStorage")) return .get_local_storage;
    if (eq(rest, "setLocalStorage")) return .set_local_storage;
    if (eq(rest, "removeLocalStorage")) return .remove_local_storage;
    if (eq(rest, "clearStorage")) return .clear_storage;
    if (eq(rest, "click")) return .click;
    if (eq(rest, "type")) return .type_text;
    if (eq(rest, "scroll")) return .scroll;
    if (eq(rest, "wait")) return .wait;
    if (eq(rest, "snapshot")) return .snapshot;
    if (eq(rest, "console")) return .console;
    if (eq(rest, "back")) return .back;
    if (eq(rest, "forward")) return .forward;
    if (eq(rest, "reload")) return .reload;
    if (eq(rest, "hover")) return .hover;
    if (eq(rest, "press")) return .press;
    if (eq(rest, "open")) return .open;
    if (eq(rest, "close")) return .close;
    if (eq(rest, "dialog")) return .dialog;
    if (eq(rest, "handleDialog")) return .handle_dialog;
    if (eq(rest, "upload")) return .upload;
    return null;
}

/// wire 메서드 이름(`browser.` 뒤) — `parseBrowserMethod` 의 역. `browser.list` 의 지원 목록이 쓴다.
pub fn browserMethodWireName(m: BrowserMethod) []const u8 {
    return switch (m) {
        .navigate => "navigate",
        .get_url => "getUrl",
        .execute_script => "executeScript",
        .subscribe => "subscribe",
        .get_cookies => "getCookies",
        .screenshot => "screenshot",
        .set_cookie => "setCookie",
        .delete_cookie => "deleteCookie",
        .get_local_storage => "getLocalStorage",
        .set_local_storage => "setLocalStorage",
        .remove_local_storage => "removeLocalStorage",
        .clear_storage => "clearStorage",
        .click => "click",
        .type_text => "type",
        .scroll => "scroll",
        .wait => "wait",
        .snapshot => "snapshot",
        .console => "console",
        .back => "back",
        .forward => "forward",
        .reload => "reload",
        .hover => "hover",
        .press => "press",
        .open => "open",
        .close => "close",
        .dialog => "dialog",
        .handle_dialog => "handleDialog",
        .upload => "upload",
    };
}

/// 그 엔진이 이 메서드를 지원하는가(W9-0 — 단일 출처). WebKit 은 W9 전의 것만(걷어낼 예정 — 새 메서드를 두지 않는다, 사용자 결정
/// 2026-10-10), Chromium 은 W9 단계마다 늘어난다(docs/plans/web-osr-backend.md W9). 지원하지 않으면 인가 판정 **전에**
/// `unsupported_by_engine` 으로 답한다.
/// 탭 하나가 지원하는지는 `surfaceSupports`(브라우저 탭이 아니면 엔진과 무관하게 아무것도 없다).
pub fn engineSupports(engine: cs.WebEngine, m: BrowserMethod) bool {
    return switch (engine) {
        .webkit => switch (m) {
            .back, .forward, .reload, .hover, .press, .open, .close, .dialog, .handle_dialog, .upload => false,
            else => true,
        },
        // W9 단계마다 여기에 메서드를 더한다 — W9b①a: 진짜 클릭(DevTools 입력)·방문 기록, W9b①b: snapshot·type·scroll·wait·
        // hover·press.
        // W9a①: navigate·getUrl·screenshot, W9a②: executeScript, W9a③: localStorage·쿠키·clearStorage, W9c②: 대화상자 보기·답하기,
        // W9c①: console(CEF `on_console_message` — DevTools 를 부르지 않는다). W9c③: 업로드(`DOM.setFileInputFiles` — 매번 확인 모달).
        .chromium => switch (m) {
            .click, .back, .forward, .reload, .snapshot, .console, .type_text, .scroll, .wait, .hover, .press, .open, .close, .navigate, .get_url, .screenshot, .execute_script, .get_cookies, .set_cookie, .delete_cookie, .get_local_storage, .set_local_storage, .remove_local_storage, .clear_storage, .dialog, .handle_dialog, .upload => true,
            else => false,
        },
    };
}

/// 그 web 탭에서 이 메서드를 실행할 수 있는가 — 목록의 `methods` 와 확인 모달 전 거절이 함께 쓴다.
pub fn surfaceSupports(w: cs.WebMeta, m: BrowserMethod) bool {
    // `open` 은 탭에 쓰는 메서드가 아니다(대상이 부른 pane) — 탭마다의 목록에 싣지 않는다(W9b③).
    if (m == .open) return false;
    return w.controllable and engineSupports(w.engine, m);
}

inline fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

// ── params DTO + 파서(§9.1 ①, control_dispatch `readIdParam` 스타일) ───────────────────────────────────────
// DTO의 슬라이스(url/script)는 파싱된 params `std.json.Value`(arena)를 빌린다 — 소유 안 함. dispatch는 pm(arena)
// 수명 안에서 즉시 파싱·판정하므로 안전하다(1c SurfaceDto가 collector 버퍼를 빌리는 것과 동일 규약).

/// params 오류(shape/타입/범위)를 하나로 접는 sentinel — 호출자가 `invalid_params`로 매핑한다(control_dispatch 동일).
const ParamError = error{InvalidParams};

/// `browser.navigate` params(§9 표 `{id, url}`). 둘 다 필수.
pub const NavigateParams = struct {
    /// 대상 web surface_id(§9.1 ① "id는 대상 web surface_id(u64)").
    id: u64,
    /// 이동할 URL(5d `load(URLRequest)`). 5a는 형식만 확정하고 검증(스킴 allowlist 등)은 5d.
    url: []const u8,
};

/// `browser.getUrl` params(§9 표 `{id}`).
pub const GetUrlParams = struct {
    id: u64,
};

/// `browser.executeScript` params. `script`는 callAsyncJavaScript가 CSP-safe하게 실행할 JavaScript 표현식이고,
/// `args`는 그 표현식에 동일 이름으로 주입하는 strict-JSON 배열이다.
pub const ExecuteScriptParams = struct {
    id: u64,
    script: []const u8,
    args: []const std.json.Value,
    max_result_bytes: usize,
};

/// Zig→Swift backend 전용 arg. 표현식·JSON args·page-process serializer byte cap을 한 object로 묶어 ABI 필드
/// 추가 없이 전달한다. args는 파싱 arena를 빌리므로 이 함수 안에서 즉시 owned JSON으로 복사한다.
pub fn serializeExecuteScriptBackendArg(gpa: std.mem.Allocator, script: []const u8, args: []const std.json.Value, max_result_bytes: usize) std.mem.Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    s.beginObject() catch return error.OutOfMemory;
    s.objectField("script") catch return error.OutOfMemory;
    s.write(script) catch return error.OutOfMemory;
    s.objectField("args") catch return error.OutOfMemory;
    s.beginArray() catch return error.OutOfMemory;
    for (args) |arg| s.write(arg) catch return error.OutOfMemory;
    s.endArray() catch return error.OutOfMemory;
    s.objectField("max_result_bytes") catch return error.OutOfMemory;
    s.write(max_result_bytes) catch return error.OutOfMemory;
    s.endObject() catch return error.OutOfMemory;
    return aw.toOwnedSlice() catch return error.OutOfMemory;
}

pub const execute_script_default_max_result_bytes: usize = 16 * 1024 * 1024;
/// 5f-5b: 이 크기까지는 한 tick의 단일 pull로 inline 응답을 만들고, 초과는 progressive chunk로 전환한다.
pub const execute_script_inline_max_result_bytes: usize = 512 * 1024;
pub const execute_script_protocol_max_result_bytes: usize = 256 * 1024 * 1024;
pub const execute_script_error_payload_max_bytes: usize = 24 * 1024;
pub const execute_script_error_frame_max_bytes: usize = 32 * 1024;
pub const execute_script_request_id_max_bytes: usize = 1024;
pub const execute_script_args_max_depth: usize = 128;
const javascript_max_safe_integer: i64 = 9_007_199_254_740_991;
const javascript_max_safe_number: f64 = 9_007_199_254_740_991.0;

/// callAsyncJavaScript가 NSNumber를 JavaScript Number로 옮길 때 의미가 바뀌지 않는 strict-JSON input만 허용한다.
/// request frame 자체가 node/byte 총량을 제한하고, 여기서는 중첩 폭발과 i64→double silent rounding을 막는다.
fn validExecuteScriptArg(value: std.json.Value, depth: usize) bool {
    if (depth > execute_script_args_max_depth) return false;
    return switch (value) {
        .null, .bool, .string => true,
        .integer => |n| n >= -javascript_max_safe_integer and n <= javascript_max_safe_integer,
        .float => |n| std.math.isFinite(n) and @abs(n) <= javascript_max_safe_number and !(n == 0 and std.math.signbit(n)),
        // Public request validation reparses the original wire with parse_numbers=false, so a number_string reaching
        // this typed path is never trusted by itself.
        .number_string => false,
        .array => |a| for (a.items) |child| {
            if (!validExecuteScriptArg(child, depth + 1)) break false;
        } else true,
        .object => |o| for (o.values()) |child| {
            if (!validExecuteScriptArg(child, depth + 1)) break false;
        } else true,
    };
}

/// Dynamic JSON parsing normally canonicalizes `-0` to integer 0 and can round a float-form integer before params
/// validation. Reparse the original request with number lexemes preserved so JSON→NSNumber→JavaScript does not silently
/// change argument meaning. This is called only after browser method routing/authz, preserving the existing oracle order.
fn validExecuteScriptArgLexeme(value: std.json.Value, depth: usize) bool {
    if (depth > execute_script_args_max_depth) return false;
    return switch (value) {
        .null, .bool, .string => true,
        .number_string => |raw| blk: {
            const n = std.fmt.parseFloat(f64, raw) catch break :blk false;
            if (!std.math.isFinite(n) or @abs(n) > javascript_max_safe_number) break :blk false;
            if (n == 0) {
                // parseFloat가 `1e-400`을 +0으로 underflow시키거나 JSON parser가 `-0`을 integer 0으로
                // canonicalize하기 전에, 원 significand가 실제 0인지와 음수 부호를 lexeme에서 판정한다.
                if (std.mem.startsWith(u8, raw, "-") or !numberLexemeHasZeroSignificand(raw)) break :blk false;
            }
            break :blk true;
        },
        .array => |a| for (a.items) |child| {
            if (!validExecuteScriptArgLexeme(child, depth + 1)) break false;
        } else true,
        .object => |o| for (o.values()) |child| {
            if (!validExecuteScriptArgLexeme(child, depth + 1)) break false;
        } else true,
        .integer, .float => false,
    };
}

fn numberLexemeHasZeroSignificand(raw: []const u8) bool {
    var i: usize = if (std.mem.startsWith(u8, raw, "-")) 1 else 0;
    while (i < raw.len and raw[i] != 'e' and raw[i] != 'E') : (i += 1) {
        if (raw[i] >= '1' and raw[i] <= '9') return false;
    }
    return true;
}

fn validExecuteScriptArgsWire(gpa: std.mem.Allocator, request_bytes: []const u8) std.mem.Allocator.Error!bool {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, request_bytes, .{ .parse_numbers = false }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return false,
    };
    const params = switch (root.get("params") orelse return false) {
        .object => |o| o,
        else => return false,
    };
    const args = switch (params.get("args") orelse return true) {
        .array => |a| a,
        else => return false,
    };
    for (args.items) |arg| if (!validExecuteScriptArgLexeme(arg, 0)) return false;
    return true;
}

/// `browser.setCookie` params(§9.4 D4). name/value 필수, 나머지 선택(domain 생략=대상 문서 host·path 생략=`/`·secure
/// 생략=false는 Swift가 적용). **httpOnly는 미지원**: `HTTPCookie(properties:)`가 HttpOnly를 설정 못 함(Set-Cookie 헤더
/// 전용)이라 WKWebView 주입 쿠키는 항상 non-HttpOnly(문서화된 한계). expires/sameSite는 후속. 슬라이스는 파싱 arena를 빌린다.
pub const SetCookieParams = struct {
    id: u64,
    name: []const u8,
    value: []const u8,
    domain: ?[]const u8,
    path: ?[]const u8,
    secure: bool,
};

/// `browser.deleteCookie` params(§9.4 D4). name 필수, domain/path 선택(대상 문서 host·`/` 기본).
pub const DeleteCookieParams = struct {
    id: u64,
    name: []const u8,
    domain: ?[]const u8,
    path: ?[]const u8,
};

/// `browser.getLocalStorage`/`removeLocalStorage` params `{id, key}`. key 필수.
pub const KeyParams = struct { id: u64, key: []const u8 };

/// `browser.setLocalStorage` params `{id, key, value}`. 둘 다 필수.
pub const SetLocalStorageParams = struct { id: u64, key: []const u8, value: []const u8 };

/// act(click/type/scroll) 대상 지시자 — CSS selector 또는 snapshot ref(§9.5.4) 중 **정확히 하나**.
/// ref는 wire에서 **불투명 토큰**이다: `[data-maru-ref]` 바인딩 해소는 L4(엔진) 소관이라(현 WKWebView=주입 data 속성,
/// 미래 CDP 엔진=backendNodeId) L2는 selector/ref를 구분만 해 arg에 실어 넘기고 의미는 부여하지 않는다.
pub const Locator = union(enum) {
    selector: []const u8,
    ref: []const u8,
    /// W9b② — 역할·이름(`{"locator":{"role","name"?,"level"?,"exact"?,"nth"?}}`). Chromium 만(WebKit 은 모달 전 `-32008`). 역할 이름의
    /// 해석(허용 목록·별칭)은 엔진이 한다 — L2 는 모양·상한만 본다.
    role: RoleLocator,
    /// W9b②-2 — 보이는 글(`{"locator":{"text","exact"?,"nth"?}}`)·라벨(`{"label",…}`)로. Chromium 만.
    text: TextLocator,
    label: TextLocator,
};

pub const TextLocator = struct {
    value: []const u8,
    exact: bool = false,
    nth: ?i64 = null,
};

pub const RoleLocator = struct {
    role: []const u8,
    name: ?[]const u8 = null,
    level: ?i64 = null,
    exact: bool = false,
    nth: ?i64 = null,
};

/// 로케이터 글(역할 이름·name)의 상한 — 엔진(`web_cdp_locate.max_text_bytes`)과 같다.
pub const max_locator_text_bytes = 1024;
pub const max_locator_role_bytes = 64;

/// `browser.click`/`scroll` params `{id, selector | ref}`. locator=selector 또는 ref 정확히 하나.
pub const ActParams = struct { id: u64, locator: Locator };

/// `browser.type` params `{id, selector | ref, text}`. locator + text 필수.
pub const TypeParams = struct { id: u64, locator: Locator, text: []const u8 };

/// `browser.press` params `{id, key, selector? | ref?}`. key 필수(비지 않고 `max_press_key_bytes` 이하 — 키 이름의 해석은 실행하는
/// 엔진이 한다), 대상은 없어도 된다(지금 초점에 누른다).
pub const PressParams = struct { id: u64, key: []const u8, locator: ?Locator };
/// `browser.open` params(W9b③) — url 은 없거나 http·https(`new_tab.urlAllowed` — 페이지가 여는 새 탭과 같은 규칙).
pub const OpenParams = struct { url: ?[]const u8, timeout_ms: u32 };
pub const open_default_timeout_ms: u32 = 25_000;
pub const open_max_timeout_ms: u32 = 25_000;
pub const max_press_key_bytes = 64;
/// `browser.handleDialog` params(W9c②). `dialog` 은 `browser.dialog` 가 준 번호(0 은 없다).
pub const HandleDialogParams = struct { accept: bool, text: ?[]const u8, dialog: ?u64 };
/// 답 글의 상한 — sidecar 가 대화상자 답에 받는 글 상한(`wire.max_text_bytes`)과 같다(넘는 글을 조용히 자르지 않고 거절한다).
pub const handle_dialog_max_text_bytes = ws_wire.max_text_bytes;

/// `browser.wait` 조건. 첫 슬라이스는 명시적 selector visible·현재 load 완료만 지원한다. URL/text/fn/network-idle과
/// click/type auto-wait는 후속(§9.4 D3·§9.5).
pub const WaitCondition = enum {
    selector,
    load,
    /// W9b②-3 — `selector` 나 `locator`(act 와 같은 세 모양)가 보일 때까지. selector 면 엔진에는 `selector` 조건으로 넘긴다(같은 뜻 —
    /// WebKit 도 안다), locator 는 Chromium 만(WebKit 은 모달 전 `-32008`).
    visible,

    pub fn wire(self: WaitCondition) []const u8 {
        return switch (self) {
            .selector => "selector",
            .load => "load",
            .visible => "visible",
        };
    }
};

pub const wait_default_timeout_ms: u32 = 25_000;
pub const wait_max_timeout_ms: u32 = 25_000;
pub const wait_poll_interval_ms: u32 = 100;

pub const WaitParams = struct {
    id: u64,
    condition: WaitCondition,
    selector: ?[]const u8,
    timeout_ms: u32,
    /// `visible` 의 로케이터(role·text·label — selector 는 `selector` 에).
    locator: ?Locator = null,
};

/// `browser.screenshot` 선택 params — rect(캡처 영역, CSS 포인트)·scale(출력 배율). 둘 다 부재 가능(=전체 뷰·기기 배율).
/// id는 dispatch가 먼저 읽으므로(readIdParam) 여기선 rect/scale만 추출. 형식 오류는 invalid_params(surface oracle 아님).
pub const ScreenshotRect = struct { x: f64, y: f64, width: f64, height: f64 };
pub const ScreenshotOptParams = struct { rect: ?ScreenshotRect = null, scale: ?f64 = null };

/// `browser.snapshot` 선택 params(§9.5.4). interactive_only=상호작용 role만·max_depth=트리 깊이 제한·selector=하위트리 scope.
/// 전부 부재 가능(=전체 트리·전 요소·루트=body). id는 dispatch가 먼저 읽음. 형식 오류는 invalid_params(surface oracle 아님).
pub const SnapshotParams = struct { interactive_only: bool = false, max_depth: ?u32 = null, selector: ?[]const u8 = null };

/// `browser.console` 선택 params(§9.5.9). clear=반환 후 서버 버퍼 비움(read-and-clear 소비). 부재=false(비파괴 읽기).
/// id는 dispatch가 먼저 읽음(readIdParam). 형식 오류는 invalid_params.
pub const ConsoleParams = struct { clear: bool = false };

fn paramsObject(params: ?std.json.Value) ParamError!std.json.ObjectMap {
    return switch (params orelse return error.InvalidParams) {
        .object => |o| o,
        else => error.InvalidParams,
    };
}

/// 필수 `id`(surface_id, u64). 부재/비정수/음수 → InvalidParams. 모든 browser.* 메서드가 공유(§9 표 전부 `{id,...}`).
fn idFromObj(obj: std.json.ObjectMap) ParamError!u64 {
    return switch (obj.get("id") orelse return error.InvalidParams) {
        .integer => |i| if (i < 0) error.InvalidParams else @intCast(i),
        else => error.InvalidParams,
    };
}

/// 필수 문자열 필드(url/script). 부재/비문자열 → InvalidParams.
fn strFromObj(obj: std.json.ObjectMap, name: []const u8) ParamError![]const u8 {
    return switch (obj.get(name) orelse return error.InvalidParams) {
        .string => |s| s,
        else => error.InvalidParams,
    };
}

/// 선택 문자열 필드(domain/path). 부재/null → null, 문자열 → 값, 비문자열 → InvalidParams(형식 오류는 surface oracle 아님).
fn optStrFromObj(obj: std.json.ObjectMap, name: []const u8) ParamError!?[]const u8 {
    return switch (obj.get(name) orelse return null) {
        .string => |s| s,
        .null => null,
        else => error.InvalidParams,
    };
}

/// 선택 bool 필드(secure/httpOnly). 부재/null → default, bool → 값, 비-bool → InvalidParams.
fn optBoolFromObj(obj: std.json.ObjectMap, name: []const u8, default: bool) ParamError!bool {
    return switch (obj.get(name) orelse return default) {
        .bool => |b| b,
        .null => default,
        else => error.InvalidParams,
    };
}

/// authz(순서 4)가 target surface를 알아야 하므로 dispatch가 메서드 확정 전에 `id`만 먼저 읽는 공유 파서. 모든
/// browser.* 메서드의 params가 `{id, ...}` 모양이라 메서드 무관하게 id를 뽑는다(형식 오류는 surface oracle이 아님).
fn readIdParam(params: ?std.json.Value) ParamError!u64 {
    return idFromObj(try paramsObject(params));
}

pub fn parseNavigateParams(params: ?std.json.Value) ParamError!NavigateParams {
    const obj = try paramsObject(params);
    return .{ .id = try idFromObj(obj), .url = try strFromObj(obj, "url") };
}

pub fn parseGetUrlParams(params: ?std.json.Value) ParamError!GetUrlParams {
    return .{ .id = try idFromObj(try paramsObject(params)) };
}

pub fn parseExecuteScriptParams(params: ?std.json.Value) ParamError!ExecuteScriptParams {
    const obj = try paramsObject(params);
    const max = if (obj.get("max_result_bytes")) |v| switch (v) {
        // 5f-5a effective capability is the conservative 16 MiB tier. The 256 MiB
        // protocol ceiling is reserved for the later bounded/chunked gate.
        .integer => |n| if (n > 0 and n <= execute_script_default_max_result_bytes) @as(usize, @intCast(n)) else return error.InvalidParams,
        else => return error.InvalidParams,
    } else execute_script_default_max_result_bytes;
    const args = if (obj.get("args")) |v| switch (v) {
        .array => |a| blk: {
            for (a.items) |arg| if (!validExecuteScriptArg(arg, 0)) return error.InvalidParams;
            break :blk a.items;
        },
        else => return error.InvalidParams,
    } else &.{};
    return .{ .id = try idFromObj(obj), .script = try strFromObj(obj, "script"), .args = args, .max_result_bytes = max };
}

pub fn parseSetCookieParams(params: ?std.json.Value) ParamError!SetCookieParams {
    const obj = try paramsObject(params);
    return .{
        .id = try idFromObj(obj),
        .name = try strFromObj(obj, "name"),
        .value = try strFromObj(obj, "value"),
        .domain = try optStrFromObj(obj, "domain"),
        .path = try optStrFromObj(obj, "path"),
        .secure = try optBoolFromObj(obj, "secure", false),
    };
}

pub fn parseDeleteCookieParams(params: ?std.json.Value) ParamError!DeleteCookieParams {
    const obj = try paramsObject(params);
    return .{
        .id = try idFromObj(obj),
        .name = try strFromObj(obj, "name"),
        .domain = try optStrFromObj(obj, "domain"),
        .path = try optStrFromObj(obj, "path"),
    };
}

pub fn parseKeyParams(params: ?std.json.Value) ParamError!KeyParams {
    const obj = try paramsObject(params);
    return .{ .id = try idFromObj(obj), .key = try strFromObj(obj, "key") };
}

pub fn parseSetLocalStorageParams(params: ?std.json.Value) ParamError!SetLocalStorageParams {
    const obj = try paramsObject(params);
    return .{ .id = try idFromObj(obj), .key = try strFromObj(obj, "key"), .value = try strFromObj(obj, "value") };
}

/// act locator 파싱 — `selector`와 `ref` 중 **정확히 하나**여야 한다(둘 다=배타 위반, 둘 다 없음=대상 미지정, 모두
/// `invalid_params`). ref는 여기서 형식 검증 없이 그대로 통과(불투명 토큰 — L4가 해소, 미발견은 정직하게 `ok:false`).
fn parseLocator(obj: std.json.ObjectMap) ParamError!Locator {
    const selector = try optStrFromObj(obj, "selector");
    const ref = try optStrFromObj(obj, "ref");
    const locator = obj.get("locator");
    const given = @as(u8, @intFromBool(selector != null)) + @intFromBool(ref != null) + @intFromBool(locator != null);
    if (given != 1) return error.InvalidParams;
    if (selector) |s| return .{ .selector = s };
    if (ref) |r| return .{ .ref = r };
    const lv = locator.?;
    if (lv == .object and lv.object.get("role") == null) {
        if (lv.object.get("text") != null) return .{ .text = try parseTextLocator(lv, "text") };
        if (lv.object.get("label") != null) return .{ .label = try parseTextLocator(lv, "label") };
    }
    return .{ .role = try parseRoleLocator(lv) };
}

/// `{text|label, exact?, nth?}` — 키 집합을 엄격히(role 의 name·level 은 받지 않는다). 빈 글·상한 초과·틀린 타입은 invalid_params.
fn parseTextLocator(v: std.json.Value, field: []const u8) ParamError!TextLocator {
    const o = v.object;
    var it = o.iterator();
    while (it.next()) |e| {
        const k = e.key_ptr.*;
        if (!(eq(k, field) or eq(k, "exact") or eq(k, "nth"))) return error.InvalidParams;
    }
    const value = try strFromObj(o, field);
    if (value.len == 0 or value.len > max_locator_text_bytes) return error.InvalidParams;
    var r: TextLocator = .{ .value = value };
    if (o.get("exact")) |x| {
        if (x != .bool) return error.InvalidParams;
        r.exact = x.bool;
    }
    if (o.get("nth")) |n| {
        if (n != .integer or n.integer < 0 or n.integer > 1_000_000) return error.InvalidParams;
        r.nth = n.integer;
    }
    return r;
}

/// `locator` 객체의 role 갈래. 모르는 키·틀린 타입·빈 글·상한 초과·이름 없는 exact 는 invalid_params.
fn parseRoleLocator(v: std.json.Value) ParamError!RoleLocator {
    if (v != .object) return error.InvalidParams;
    const o = v.object;
    var it = o.iterator();
    while (it.next()) |e| {
        const k = e.key_ptr.*;
        if (!(eq(k, "role") or eq(k, "name") or eq(k, "level") or eq(k, "exact") or eq(k, "nth"))) return error.InvalidParams;
    }
    const role = try strFromObj(o, "role");
    if (role.len == 0 or role.len > max_locator_role_bytes) return error.InvalidParams;
    var r: RoleLocator = .{ .role = role };
    if (o.get("name")) |n| {
        if (n != .string or n.string.len == 0 or n.string.len > max_locator_text_bytes) return error.InvalidParams;
        r.name = n.string;
    }
    if (o.get("level")) |l| {
        if (l != .integer or l.integer < 1 or l.integer > 100) return error.InvalidParams;
        r.level = l.integer;
    }
    if (o.get("exact")) |x| {
        if (x != .bool) return error.InvalidParams;
        if (x.bool and r.name == null) return error.InvalidParams; // 이름 없이 exact 는 뜻이 없다
        r.exact = x.bool;
    }
    if (o.get("nth")) |n| {
        if (n != .integer or n.integer < 0 or n.integer > 1_000_000) return error.InvalidParams;
        r.nth = n.integer;
    }
    return r;
}

pub fn parseActParams(params: ?std.json.Value) ParamError!ActParams {
    const obj = try paramsObject(params);
    return .{ .id = try idFromObj(obj), .locator = try parseLocator(obj) };
}

pub fn parseTypeParams(params: ?std.json.Value) ParamError!TypeParams {
    const obj = try paramsObject(params);
    return .{ .id = try idFromObj(obj), .locator = try parseLocator(obj), .text = try strFromObj(obj, "text") };
}

/// 새 메서드라 키를 엄격히 본다 — 모르는 키·`id` 는 거절(대상 탭이 없다 — 있으면 잘못 쓴 것이다).
pub fn parseOpenParams(params: ?std.json.Value) ParamError!OpenParams {
    const obj = if (params) |p| switch (p) {
        .object => |o| o,
        else => return error.InvalidParams,
    } else return .{ .url = null, .timeout_ms = open_default_timeout_ms };
    var it = obj.iterator();
    while (it.next()) |e| if (!(eq(e.key_ptr.*, "url") or eq(e.key_ptr.*, "timeout_ms"))) return error.InvalidParams;
    const url = try optStrFromObj(obj, "url");
    if (url) |u| if (!new_tab.urlAllowed(u)) return error.InvalidParams;
    const timeout_ms: u32 = if (obj.get("timeout_ms")) |v| switch (v) {
        .integer => |i| if (i < 1 or i > @as(i64, open_max_timeout_ms)) return error.InvalidParams else @intCast(i),
        else => return error.InvalidParams,
    } else open_default_timeout_ms;
    return .{ .url = url, .timeout_ms = timeout_ms };
}

pub fn serializeOpenArg(gpa: std.mem.Allocator, p: OpenParams) std.mem.Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    (blk: {
        s.beginObject() catch |e| break :blk e;
        if (p.url) |u| {
            s.objectField("url") catch |e| break :blk e;
            s.write(u) catch |e| break :blk e;
        }
        s.objectField("timeout_ms") catch |e| break :blk e;
        s.write(p.timeout_ms) catch |e| break :blk e;
        s.endObject() catch |e| break :blk e;
    }) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

/// W9c②: 새 메서드라 키를 엄격히 본다(`open` 과 같다) — 모르는 키는 거절.
fn onlyKeys(obj: std.json.ObjectMap, allowed: []const []const u8) ParamError!void {
    var it = obj.iterator();
    while (it.next()) |e| {
        for (allowed) |k| {
            if (eq(e.key_ptr.*, k)) break;
        } else return error.InvalidParams;
    }
}

pub fn parseDialogParams(params: ?std.json.Value) ParamError!void {
    const obj = try paramsObject(params);
    try onlyKeys(obj, &.{"id"});
}

pub fn parseHandleDialogParams(params: ?std.json.Value) ParamError!HandleDialogParams {
    const obj = try paramsObject(params);
    try onlyKeys(obj, &.{ "id", "accept", "text", "dialog" });
    const accept = switch (obj.get("accept") orelse return error.InvalidParams) {
        .bool => |b| b,
        else => return error.InvalidParams,
    };
    const text = try optStrFromObj(obj, "text");
    if (text) |t| if (t.len > handle_dialog_max_text_bytes) return error.InvalidParams;
    const dialog: ?u64 = if (obj.get("dialog")) |v| switch (v) {
        .integer => |i| if (i < 1) return error.InvalidParams else @intCast(i),
        .null => null,
        else => return error.InvalidParams,
    } else null;
    return .{ .accept = accept, .text = text, .dialog = dialog };
}

pub fn serializeHandleDialogArg(gpa: std.mem.Allocator, p: HandleDialogParams) std.mem.Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    (blk: {
        s.beginObject() catch |e| break :blk e;
        s.objectField("accept") catch |e| break :blk e;
        s.write(p.accept) catch |e| break :blk e;
        if (p.text) |t| {
            s.objectField("text") catch |e| break :blk e;
            s.write(t) catch |e| break :blk e;
        }
        if (p.dialog) |d| {
            s.objectField("dialog") catch |e| break :blk e;
            s.write(d) catch |e| break :blk e;
        }
        s.endObject() catch |e| break :blk e;
    }) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

/// W9c③: 한 번에 넣는 파일 수 상한(작성자 선택 — 확인 모달이 파일을 모두 보여야 하고, 다 보이지 않으면 허용을 막는다).
pub const max_upload_files = 10;
/// 경로 하나의 바이트 상한 — macOS 의 PATH_MAX(1024). 앱이 `realpath` 에 넘길 수 있는 길이다.
pub const max_upload_path_bytes = 1024;

/// `browser.upload` params(W9c③) — 대상(`selector`·`ref`·`locator` 가운데 하나)과 파일 경로들. 경로는 요청 arena 를 빌린다.
pub const UploadParams = struct {
    id: u64,
    locator: Locator,
    files: [max_upload_files][]const u8 = undefined,
    count: usize = 0,

    pub fn paths(self: *const UploadParams) []const []const u8 {
        return self.files[0..self.count];
    }
};

/// 앱에 넘겨도 되는 경로인가 — 절대 경로(`/` 로 시작 — 상대 경로는 Chromium 이 다음 이동에서 렌더러를 죽였다, 계획 실측 k3), PATH_MAX 안,
/// 올바른 UTF-8, 제어 문자(C0·DEL·C1) 없음(확인 모달에 줄바꿈 같은 글자로 다른 파일처럼 보이게 하지 못하게 — `file_dialog_path` 와 같은 규칙).
/// 양방향·폭 없는 글자는 받되 모달이 코드로 보인다(`web_upload_display`).
pub fn uploadPathOk(path: []const u8) bool {
    if (path.len == 0 or path.len > max_upload_path_bytes or path[0] != '/') return false;
    const view = std.unicode.Utf8View.init(path) catch return false;
    var it = view.iterator();
    while (it.nextCodepoint()) |c| if (c < 0x20 or (c >= 0x7f and c <= 0x9f)) return false;
    return true;
}

/// 글자만 보고 정규화한 경로(`//`·`.` 를 지우고 `..` 를 앞 이름과 지운다) — 같은 파일을 두 번 적은 것을 L2 에서 거른다(심볼릭 링크로 같은 파일이
/// 되는 것은 앱이 연 파일의 장치·inode 로 다시 본다). `out` 은 `max_upload_path_bytes` 이상.
fn lexicalPath(path: []const u8, out: []u8) []const u8 {
    var n: usize = 0;
    var it = std.mem.tokenizeScalar(u8, path, '/');
    while (it.next()) |part| {
        if (eq(part, ".")) continue;
        if (eq(part, "..")) {
            while (n > 0 and out[n - 1] != '/') n -= 1;
            if (n > 0) n -= 1;
            continue;
        }
        out[n] = '/';
        @memcpy(out[n + 1 .. n + 1 + part.len], part);
        n += 1 + part.len;
    }
    if (n == 0) {
        out[0] = '/';
        n = 1;
    }
    return out[0..n];
}

/// 새 메서드라 키를 엄격히 본다(`open`·`handleDialog` 와 같다). `files` 는 1..10 개의 절대 경로(`uploadPathOk`), 글자로 같은 경로가 둘이면
/// 거절한다. 대상은 click 과 같은 셋 가운데 하나.
pub fn parseUploadParams(params: ?std.json.Value) ParamError!UploadParams {
    const obj = try paramsObject(params);
    try onlyKeys(obj, &.{ "id", "selector", "ref", "locator", "files" });
    var r: UploadParams = .{ .id = try idFromObj(obj), .locator = try parseLocator(obj) };
    const list = switch (obj.get("files") orelse return error.InvalidParams) {
        .array => |a| a.items,
        else => return error.InvalidParams,
    };
    if (list.len == 0 or list.len > max_upload_files) return error.InvalidParams;
    var norm: [max_upload_files][max_upload_path_bytes]u8 = undefined;
    var norms: [max_upload_files][]const u8 = undefined;
    for (list, 0..) |v, i| {
        const path = switch (v) {
            .string => |s| s,
            else => return error.InvalidParams,
        };
        if (!uploadPathOk(path)) return error.InvalidParams;
        norms[i] = lexicalPath(path, &norm[i]);
        for (norms[0..i]) |prev| if (eq(prev, norms[i])) return error.InvalidParams;
        r.files[i] = path;
    }
    r.count = list.len;
    return r;
}

/// upload op.arg — `{선택자 필드, files:[…]}`(id 는 실행 계층이 op 의 surface_id 로 안다).
pub fn serializeUploadArg(gpa: std.mem.Allocator, p: UploadParams) std.mem.Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    (blk: {
        s.beginObject() catch |e| break :blk e;
        writeLocatorFields(&s, p.locator) catch |e| break :blk e;
        s.objectField("files") catch |e| break :blk e;
        s.beginArray() catch |e| break :blk e;
        for (p.paths()) |f| s.write(f) catch |e| break :blk e;
        s.endArray() catch |e| break :blk e;
        s.endObject() catch |e| break :blk e;
    }) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

pub fn parsePressParams(params: ?std.json.Value) ParamError!PressParams {
    const obj = try paramsObject(params);
    const key = try strFromObj(obj, "key");
    if (key.len == 0 or key.len > max_press_key_bytes) return error.InvalidParams;
    const has_locator = (try optStrFromObj(obj, "selector")) != null or (try optStrFromObj(obj, "ref")) != null or obj.get("locator") != null;
    return .{ .id = try idFromObj(obj), .key = key, .locator = if (has_locator) try parseLocator(obj) else null };
}

/// `browser.wait` params. condition은 tagged string이라 후속 URL/text 조건을 기존 필드 의미 변경 없이 확장할 수 있다.
/// selector 조건은 non-empty selector가 필수, load 조건은 selector를 금지한다. timeout은 1..25_000ms bounded.
pub fn parseWaitParams(params: ?std.json.Value) ParamError!WaitParams {
    const obj = try paramsObject(params);
    const condition_wire = try strFromObj(obj, "condition");
    const condition: WaitCondition = if (eq(condition_wire, "selector"))
        .selector
    else if (eq(condition_wire, "load"))
        .load
    else if (eq(condition_wire, "visible"))
        .visible
    else
        return error.InvalidParams;
    var selector = try optStrFromObj(obj, "selector");
    var locator: ?Locator = null;
    switch (condition) {
        .selector => if (selector == null or selector.?.len == 0) return error.InvalidParams,
        .load => if (selector != null) return error.InvalidParams,
        .visible => {
            // 새 조건이라 키를 엄격히 본다(옛 조건은 뒤 호환으로 모르는 키를 그대로 둔다 — `locator` 만 거절).
            var it = obj.iterator();
            while (it.next()) |e| {
                const k = e.key_ptr.*;
                if (!(eq(k, "id") or eq(k, "condition") or eq(k, "selector") or eq(k, "locator") or eq(k, "timeout_ms"))) return error.InvalidParams;
            }
            const loc = try parseLocator(obj); // selector·locator 가운데 정확히 하나(ref 는 위에서 거절)
            switch (loc) {
                .selector => |sel| if (sel.len == 0) return error.InvalidParams,
                .ref => return error.InvalidParams,
                else => {
                    locator = loc;
                    selector = null;
                },
            }
        },
    }
    if (condition != .visible and obj.get("locator") != null) return error.InvalidParams; // 조용히 버리지 않는다(계획 공격 3 회차)
    const timeout_ms: u32 = if (obj.get("timeout_ms")) |v| switch (v) {
        .integer => |i| if (i < 1 or i > @as(i64, wait_max_timeout_ms)) return error.InvalidParams else @intCast(i),
        else => return error.InvalidParams,
    } else wait_default_timeout_ms;
    return .{ .id = try idFromObj(obj), .condition = condition, .selector = selector, .timeout_ms = timeout_ms, .locator = locator };
}

/// JSON 수(integer 또는 float) → f64. 비수치 → InvalidParams. rect/scale 파싱 공용.
fn numF64FromObj(obj: std.json.ObjectMap, name: []const u8) ParamError!f64 {
    return switch (obj.get(name) orelse return error.InvalidParams) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => error.InvalidParams,
    };
}

/// screenshot rect/scale 추출. rect 있으면 x/y/width/height 전부 필수(부분 rect=형식 오류). scale/width/height는 양수·유한.
/// 둘 다 부재(=`{id}`만)면 빈 옵션(전체 뷰·기기 배율). **rect 치수·scale 상한(렌더 자원 한계)은 Swift takeSnapshot가
/// 클램프**(L2는 형식[유한·양수]만 검증 — 픽셀 버퍼 자원 한계는 WKWebView가 렌더하는 지점 소유).
pub fn parseScreenshotOptParams(params: ?std.json.Value) ParamError!ScreenshotOptParams {
    const obj = try paramsObject(params);
    var out: ScreenshotOptParams = .{};
    if (obj.get("scale")) |v| {
        if (v != .null) {
            const s = try numF64FromObj(obj, "scale");
            if (!std.math.isFinite(s) or !(s > 0)) return error.InvalidParams;
            out.scale = s;
        }
    }
    if (obj.get("rect")) |v| {
        if (v != .null) {
            const ro = switch (v) {
                .object => |o| o,
                else => return error.InvalidParams,
            };
            const x = try numF64FromObj(ro, "x");
            const y = try numF64FromObj(ro, "y");
            const w = try numF64FromObj(ro, "width");
            const h = try numF64FromObj(ro, "height");
            if (!std.math.isFinite(x) or !std.math.isFinite(y) or !std.math.isFinite(w) or !std.math.isFinite(h)) return error.InvalidParams;
            if (!(w > 0) or !(h > 0)) return error.InvalidParams;
            out.rect = .{ .x = x, .y = y, .width = w, .height = h };
        }
    }
    return out;
}

/// 선택 비음수 u32 필드(snapshot max_depth). 부재/null→null, 음수/범위밖/비정수→InvalidParams.
fn optU32FromObj(obj: std.json.ObjectMap, name: []const u8) ParamError!?u32 {
    return switch (obj.get(name) orelse return null) {
        .integer => |i| if (i < 0 or i > std.math.maxInt(u32)) error.InvalidParams else @intCast(i),
        .null => null,
        else => error.InvalidParams,
    };
}

/// `browser.snapshot` params 파싱(§9.5.4). 전부 선택 — 부재면 기본(전 요소·무제한 깊이·루트=body).
pub fn parseSnapshotParams(params: ?std.json.Value) ParamError!SnapshotParams {
    const obj = try paramsObject(params);
    return .{
        .interactive_only = try optBoolFromObj(obj, "interactive_only", false),
        .max_depth = try optU32FromObj(obj, "max_depth"),
        .selector = try optStrFromObj(obj, "selector"),
    };
}

/// `browser.console` params 파싱(§9.5.9). clear만 선택(부재=false, 비파괴 읽기).
pub fn parseConsoleParams(params: ?std.json.Value) ParamError!ConsoleParams {
    const obj = try paramsObject(params);
    return .{ .clear = try optBoolFromObj(obj, "clear", false) };
}

/// act op.arg — Swift가 eval로 쓸 compact JSON. locator에 따라 `{selector}` 또는 `{ref}`(type은 +`text`). ref는
/// 불투명 토큰 그대로 실어 넘기고 `[data-maru-ref]` 해소는 Swift actScript가 한다(§9.5.4 — 엔진별 바인딩이 L4 소관).
pub fn serializeActArg(gpa: std.mem.Allocator, locator: Locator, text: ?[]const u8) std.mem.Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    writeActArg(&s, locator, text) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

/// press op.arg — `{key, selector?|ref?}`.
pub fn serializePressArg(gpa: std.mem.Allocator, p: PressParams) std.mem.Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    writePressArg(&s, p) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn writePressArg(s: *std.json.Stringify, p: PressParams) !void {
    try s.beginObject();
    try s.objectField("key");
    try s.write(p.key);
    if (p.locator) |l| try writeLocatorFields(s, l);
    try s.endObject();
}

fn writeLocatorFields(s: *std.json.Stringify, locator: Locator) !void {
    switch (locator) {
        .selector => |sel| {
            try s.objectField("selector");
            try s.write(sel);
        },
        .ref => |ref| {
            try s.objectField("ref");
            try s.write(ref);
        },
        .role => |r| {
            try s.objectField("locator");
            try s.beginObject();
            try s.objectField("role");
            try s.write(r.role);
            if (r.name) |n| {
                try s.objectField("name");
                try s.write(n);
            }
            if (r.level) |l| {
                try s.objectField("level");
                try s.write(l);
            }
            if (r.exact) {
                try s.objectField("exact");
                try s.write(true);
            }
            if (r.nth) |n| {
                try s.objectField("nth");
                try s.write(n);
            }
            try s.endObject();
        },
        .text, .label => |t| {
            try s.objectField("locator");
            try s.beginObject();
            try s.objectField(if (locator == .text) "text" else "label");
            try s.write(t.value);
            if (t.exact) {
                try s.objectField("exact");
                try s.write(true);
            }
            if (t.nth) |n| {
                try s.objectField("nth");
                try s.write(n);
            }
            try s.endObject();
        },
    }
}

fn writeActArg(s: *std.json.Stringify, locator: Locator, text: ?[]const u8) !void {
    try s.beginObject();
    try writeLocatorFields(s, locator);
    if (text) |t| {
        try s.objectField("text");
        try s.write(t);
    }
    try s.endObject();
}

/// wait op.arg — Swift wait coordinator가 소비할 compact JSON. id는 L4 routing 필드라 제외한다.
pub fn serializeWaitArg(gpa: std.mem.Allocator, p: WaitParams) std.mem.Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    s.beginObject() catch return error.OutOfMemory;
    s.objectField("condition") catch return error.OutOfMemory;
    // visible + selector 는 엔진에 selector 조건으로(같은 뜻 — Swift·Chromium 의 selector 확인), 로케이터만 visible 로(W9b②-3).
    s.write(if (p.condition == .visible and p.locator == null) WaitCondition.selector.wire() else p.condition.wire()) catch return error.OutOfMemory;
    if (p.selector) |selector| {
        s.objectField("selector") catch return error.OutOfMemory;
        s.write(selector) catch return error.OutOfMemory;
    }
    if (p.locator) |loc| writeLocatorFields(&s, loc) catch return error.OutOfMemory;
    s.objectField("timeout_ms") catch return error.OutOfMemory;
    s.write(p.timeout_ms) catch return error.OutOfMemory;
    s.endObject() catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

/// screenshot op.arg — Swift가 WKSnapshotConfiguration로 쓸 `{rect?, scale?}` compact JSON. 둘 다 부재면 `{}`(전체 뷰·기기 배율).
/// rect={x,y,width,height}(CSS 포인트, config.rect)·scale(config.snapshotWidth 배율). caller free(op.arg 소유).
pub fn serializeScreenshotArg(gpa: std.mem.Allocator, p: ScreenshotOptParams) std.mem.Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    writeScreenshotArg(&s, p) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn writeScreenshotArg(s: *std.json.Stringify, p: ScreenshotOptParams) !void {
    try s.beginObject();
    if (p.rect) |r| {
        try s.objectField("rect");
        try s.beginObject();
        try s.objectField("x");
        try s.write(r.x);
        try s.objectField("y");
        try s.write(r.y);
        try s.objectField("width");
        try s.write(r.width);
        try s.objectField("height");
        try s.write(r.height);
        try s.endObject();
    }
    if (p.scale) |sc| {
        try s.objectField("scale");
        try s.write(sc);
    }
    try s.endObject();
}

/// snapshot op.arg — Swift가 accname DOM walk JS에 넘길 `{interactive_only, max_depth?, selector?}` compact JSON(§9.5.4).
/// selector/max_depth 부재면 생략(Swift 기본=body 루트·무제한 깊이). caller free.
pub fn serializeSnapshotArg(gpa: std.mem.Allocator, p: SnapshotParams) std.mem.Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    writeSnapshotArg(&s, p) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn writeSnapshotArg(s: *std.json.Stringify, p: SnapshotParams) !void {
    try s.beginObject();
    try s.objectField("interactive_only");
    try s.write(p.interactive_only);
    if (p.max_depth) |d| {
        try s.objectField("max_depth");
        try s.write(d);
    }
    if (p.selector) |sel| {
        try s.objectField("selector");
        try s.write(sel);
    }
    try s.endObject();
}

/// console op.arg — Swift가 pull 시 소비할 `{clear}` compact JSON(§9.5.9). clear=true면 반환 후 서버 버퍼 비움. caller free.
pub fn serializeConsoleArg(gpa: std.mem.Allocator, p: ConsoleParams) std.mem.Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    (writeConsoleArg(&s, p)) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn writeConsoleArg(s: *std.json.Stringify, p: ConsoleParams) !void {
    try s.beginObject();
    try s.objectField("clear");
    try s.write(p.clear);
    try s.endObject();
}

/// localStorage op.arg — Swift가 파싱할 `{key}` 또는 `{key, value}` compact JSON(get/remove=key만, set=key+value).
pub fn serializeKeyArg(gpa: std.mem.Allocator, key: []const u8, value: ?[]const u8) std.mem.Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    writeKeyArg(&s, key, value) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn writeKeyArg(s: *std.json.Stringify, key: []const u8, value: ?[]const u8) !void {
    try s.beginObject();
    try s.objectField("key");
    try s.write(key);
    if (value) |v| {
        try s.objectField("value");
        try s.write(v);
    }
    try s.endObject();
}

/// setCookie op.arg — Swift가 `JSONSerialization`으로 파싱할 쿠키 필드 compact JSON(§9.4 D4). domain/path 부재면 생략
/// (Swift가 대상 문서 host·`/` 기본 적용). caller free(op.arg 소유). 파싱 슬라이스를 읽어 owned JSON을 만든다(arena 분리).
pub fn serializeSetCookieArg(gpa: std.mem.Allocator, p: SetCookieParams) std.mem.Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    writeSetCookieArg(&s, p) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn writeSetCookieArg(s: *std.json.Stringify, p: SetCookieParams) !void {
    try s.beginObject();
    try s.objectField("name");
    try s.write(p.name);
    try s.objectField("value");
    try s.write(p.value);
    if (p.domain) |d| {
        try s.objectField("domain");
        try s.write(d);
    }
    if (p.path) |pa| {
        try s.objectField("path");
        try s.write(pa);
    }
    try s.objectField("secure");
    try s.write(p.secure);
    try s.endObject();
}

/// deleteCookie op.arg — `{name, domain?, path?}` compact JSON(§9.4 D4). caller free.
pub fn serializeDeleteCookieArg(gpa: std.mem.Allocator, p: DeleteCookieParams) std.mem.Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    writeDeleteCookieArg(&s, p) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn writeDeleteCookieArg(s: *std.json.Stringify, p: DeleteCookieParams) !void {
    try s.beginObject();
    try s.objectField("name");
    try s.write(p.name);
    if (p.domain) |d| {
        try s.objectField("domain");
        try s.write(d);
    }
    if (p.path) |pa| {
        try s.objectField("path");
        try s.write(pa);
    }
    try s.endObject();
}

/// `browser.subscribe {id, events?}`의 **필터**(id는 readIdParam로 별도). `events` 부재/null → 전체(`EventFilter.all`).
/// 배열이면 각 원소가 이벤트 이름 문자열이어야 하고(`EventKind.fromWire`), 마스크로 **누적**한다(idempotent라 중복 이름을
/// 자연히 dedup — 고정 버퍼/길이 제한 없이 임의 길이 허용, 20차 [1]). 미지 이름·비-문자열·비-배열 → InvalidParams. **빈 배열
/// `events:[]` → InvalidParams**(구독할 이벤트 0 = 무의미. 성공시키면 client가 아무 이벤트도 못 받고 영영 대기하는 silent 트랩
/// — 20차 [0]; 전체 구독은 events를 생략하거나 null). 형식 오류는 surface oracle 아님. §9.5.2 vocabulary는 control_events가 단일 출처.
pub fn parseSubscribeFilter(params: ?std.json.Value) ParamError!cev.EventFilter {
    const obj = try paramsObject(params);
    const ev = obj.get("events") orelse return cev.EventFilter.all; // 부재 = 전체
    const arr = switch (ev) {
        .null => return cev.EventFilter.all, // 명시 null도 전체
        .array => |a| a,
        else => return error.InvalidParams,
    };
    var filter = cev.EventFilter.none;
    for (arr.items) |item| {
        const name = switch (item) {
            .string => |s| s,
            else => return error.InvalidParams,
        };
        filter = filter.with(cev.EventKind.fromWire(name) orelse return error.InvalidParams);
    }
    if (filter.mask == 0) return error.InvalidParams; // 빈 배열 = 구독 이벤트 0 → silent 무한대기 트랩 방지(20차 [0])
    return filter;
}

// ── result 직렬화(§9.1 ① — 5e-2 L4 completion이 값 채울 때 쓸 헬퍼, 여기선 단위 test) ─────────────────────────
// serializeError처럼 gpa로 **완결 JSON-RPC 응답 한 줄**(`{jsonrpc, id, result:{...}}`)을 빌드한다. 5e-2에서 L4가
// Swift BrowserControl 결과(url/script-result/ok)를 이 헬퍼로 실어 completeInFlight 응답한다(dispatchBrowser는 op만
// 산출해 아직 호출하지 않지만 스키마를 확정·test). caller free.
// 모든 직렬화는 minified 한 줄(1a·1c와 동일 — ndjson frame 경계 안전). 종단 `\n`은 프레이밍(1b/L4)이 붙인다.

/// `browser.navigate` 성공 result: `{"jsonrpc":"2.0","id":<id>,"result":{"ok":true}}`.
pub fn serializeNavigateResult(gpa: std.mem.Allocator, id: cp.Id) std.mem.Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    (writeNavigateResult(&s, id)) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn writeNavigateResult(s: *std.json.Stringify, id: cp.Id) !void {
    try writeNavigateLoadedResult(s, id, null);
}

/// `browser.navigate` 성공 — Chromium 탭은 첫 불러오기를 기다려 `loaded` 를 싣는다(W9a — 엔진이 결과 `"true"`/`"false"` 로 준다).
/// WebKit 은 불러오기 시작에 답하고 빈 결과를 준다 — `{ok:true}` 그대로.
pub fn serializeNavigateLoadedResult(gpa: std.mem.Allocator, id: cp.Id, result: []const u8) std.mem.Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    const loaded: ?bool = if (std.mem.eql(u8, result, "true")) true else if (std.mem.eql(u8, result, "false")) false else null;
    (writeNavigateLoadedResult(&s, id, loaded)) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn writeNavigateLoadedResult(s: *std.json.Stringify, id: cp.Id, loaded: ?bool) !void {
    try beginResult(s, id);
    try s.objectField("ok");
    try s.write(true);
    if (loaded) |l| {
        try s.objectField("loaded");
        try s.write(l);
    }
    try endResult(s);
}

/// `browser.getUrl` 성공 result: `{"jsonrpc":"2.0","id":<id>,"result":{"url":<url>}}`.
pub fn serializeGetUrlResult(gpa: std.mem.Allocator, id: cp.Id, url: []const u8) std.mem.Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    (writeGetUrlResult(&s, id, url)) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn writeGetUrlResult(s: *std.json.Stringify, id: cp.Id, url: []const u8) !void {
    try beginResult(s, id);
    try s.objectField("url");
    try s.write(url);
    try endResult(s);
}

/// `browser.getLocalStorage` 성공 result: `{"jsonrpc":"2.0","id":<id>,"result":{"value":<value>}}`. `value`는 eval
/// `localStorage.getItem`의 반환값(문자열; JS null=키 부재=빈 문자열, Swift scriptResultString). caller free.
pub fn serializeValueResult(gpa: std.mem.Allocator, id: cp.Id, value: []const u8) std.mem.Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    (writeValueResult(&s, id, value)) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn writeValueResult(s: *std.json.Stringify, id: cp.Id, value: []const u8) !void {
    try beginResult(s, id);
    try s.objectField("value");
    try s.write(value);
    try endResult(s);
}

/// `browser.executeScript` 성공 result: `{"jsonrpc":"2.0","id":<id>,"result":{"result":<value>}}`. `value`는 스크립트
/// 반환값(불투명 JSON — 5d가 `evaluateJavaScript` 결과를 채운다). 5a는 스키마만.
pub fn serializeExecuteScriptResult(gpa: std.mem.Allocator, id: cp.Id, value: std.json.Value) std.mem.Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    (writeExecuteScriptResult(&s, id, value)) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

const ExecuteScriptResultError = error{ InvalidJson, ResultTooLarge };

fn serializeExecuteScriptResponse(gpa: std.mem.Allocator, id: cp.Id, raw: []const u8) std.mem.Allocator.Error![]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, raw, .{}) catch {
        return cp.serializeError(gpa, id, .internal_error, "invalid executeScript result", null);
    };
    defer parsed.deinit();
    const wire = try serializeExecuteScriptResult(gpa, id, parsed.value);
    if (wire.len > cp.default_max_frame) {
        gpa.free(wire);
        return cp.serializeError(gpa, id, .payload_too_large, "executeScript result exceeds inline frame", null);
    }
    return wire;
}

fn parseExecuteScriptRequestForCompletion(gpa: std.mem.Allocator, request_bytes: []const u8) !cp.ParsedMessage {
    var pm = cp.parseMessage(gpa, request_bytes) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidRequestState,
    };
    const req = switch (pm.message) {
        .request => |r| r,
        else => {
            pm.deinit();
            return error.InvalidRequestState;
        },
    };
    const method = parseBrowserMethod(cp.parseMethod(req.method).rest) orelse {
        pm.deinit();
        return error.InvalidRequestState;
    };
    if (method != .execute_script) {
        pm.deinit();
        return error.InvalidRequestState;
    }
    if (req.id == .string and req.id.string.len > execute_script_request_id_max_bytes) {
        pm.deinit();
        return error.InvalidRequestState;
    }
    _ = parseExecuteScriptParams(req.params) catch {
        pm.deinit();
        return error.InvalidRequestState;
    };
    return pm;
}

/// Swift registry가 알려 준 실제 JSON byte 길이만으로 request limit 오류를 만든다. 결과 bytes를 Zig로 복사하지 않는다.
pub fn serializeExecuteScriptObservedTooLarge(gpa: std.mem.Allocator, request_bytes: []const u8, observed_bytes: usize) std.mem.Allocator.Error![]u8 {
    var pm = parseExecuteScriptRequestForCompletion(gpa, request_bytes) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return cp.serializeError(gpa, .null, .internal_error, "invalid executeScript request state", null),
    };
    defer pm.deinit();
    const req = pm.message.request;
    const params = parseExecuteScriptParams(req.params) catch unreachable;
    return serializeResultTooLarge(gpa, req.id, params.max_result_bytes, observed_bytes);
}

/// §9.5.10: method-generic result-too-large. executeScript는 자기 max_result_bytes를 쓰는 위 함수를 유지하고, snapshot/console은
/// 결과가 예약 상한(=`browserMethodReservedBytes`)을 넘을 때 이걸 쓴다(limit=상한). error envelope는 필드 없어 method-중립. request id만 파싱.
pub fn serializeBrowserResultTooLarge(gpa: std.mem.Allocator, request_bytes: []const u8, limit_bytes: usize, observed_bytes: usize) std.mem.Allocator.Error![]u8 {
    var pm = cp.parseMessage(gpa, request_bytes) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return cp.serializeError(gpa, .null, .internal_error, "invalid browser request state", null),
    };
    defer pm.deinit();
    const req_id: cp.Id = switch (pm.message) {
        .request => |r| r.id,
        else => return cp.serializeError(gpa, .null, .internal_error, "invalid browser request state", null),
    };
    return serializeResultTooLarge(gpa, req_id, limit_bytes, observed_bytes);
}

/// 현재 live transport가 inline frame만 지원할 때 registry의 큰 결과를 복사하지 않고 물리-frame 오류로 끝낸다.
pub fn serializeExecuteScriptInlineTooLarge(gpa: std.mem.Allocator, request_bytes: []const u8) std.mem.Allocator.Error![]u8 {
    var pm = parseExecuteScriptRequestForCompletion(gpa, request_bytes) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return cp.serializeError(gpa, .null, .internal_error, "invalid executeScript request state", null),
    };
    defer pm.deinit();
    return cp.serializeError(gpa, pm.message.request.id, .payload_too_large, "executeScript result exceeds inline frame", null);
}

/// page wrapper/Swift가 이미 bounded한 executeScript 진단을 stable `script-error`로 옮긴다. 입력은 신뢰하지 않고
/// 24 KiB·필수 kind를 재검증하며, 최종 JSON-RPC frame이 32 KiB를 넘으면 작은 고정 fallback으로 교체한다.
pub fn serializeExecuteScriptScriptError(gpa: std.mem.Allocator, request_bytes: []const u8, error_json: []const u8) std.mem.Allocator.Error![]u8 {
    var pm = parseExecuteScriptRequestForCompletion(gpa, request_bytes) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return cp.serializeError(gpa, .null, .internal_error, "invalid executeScript request state", null),
    };
    defer pm.deinit();
    const id = pm.message.request.id;

    if (error_json.len <= execute_script_error_payload_max_bytes) {
        var parsed = std.json.parseFromSlice(std.json.Value, gpa, error_json, .{}) catch null;
        if (parsed) |*payload| {
            defer payload.deinit();
            if (payload.value == .object) {
                const object = payload.value.object;
                const kind = object.get("kind") orelse .null;
                const name = object.get("name") orelse .null;
                const message = object.get("message") orelse .null;
                const stack = object.get("stack") orelse .null;
                const truncated = object.get("diagnostics_truncated") orelse .null;
                if (object.count() == 5 and kind == .string and name == .string and message == .string and stack == .string and truncated == .bool and
                    (std.mem.eql(u8, kind.string, "execution") or std.mem.eql(u8, kind.string, "serialization") or std.mem.eql(u8, kind.string, "navigation")) and
                    escapedJsonStringBytes(name.string) <= 258 and escapedJsonStringBytes(message.string) <= 16 * 1024 + 2)
                {
                    const wire = try cp.serializeError(gpa, id, .script_error, cp.ErrorCode.script_error.defaultMessage(), payload.value);
                    if (wire.len <= execute_script_error_frame_max_bytes) return wire;
                    gpa.free(wire);
                }
            }
        }
    }

    var fallback: std.json.ObjectMap = .empty;
    defer fallback.deinit(gpa);
    try fallback.put(gpa, "kind", .{ .string = "execution" });
    try fallback.put(gpa, "name", .{ .string = "Error" });
    try fallback.put(gpa, "message", .{ .string = "executeScript failed" });
    try fallback.put(gpa, "stack", .{ .string = "" });
    try fallback.put(gpa, "diagnostics_truncated", .{ .bool = true });
    return cp.serializeError(gpa, id, .script_error, cp.ErrorCode.script_error.defaultMessage(), .{ .object = fallback });
}

fn escapedJsonStringBytes(value: []const u8) usize {
    var total: usize = 2; // surrounding quotes
    // \b \t \n \f \r 는 2 바이트(WebKit `escapedDiagnostic`·Zig 쓰개와 같다 — 6 으로 세면 상한까지 자른 여러 줄 메시지가 폴백으로 바뀌었다, W9a 적대 리뷰 2 회차).
    for (value) |byte| total += switch (byte) {
        '"', '\\', 0x08, 0x09, 0x0a, 0x0c, 0x0d => 2,
        else => if (byte < 0x20) 6 else 1,
    };
    return total;
}

fn writeExecuteScriptResult(s: *std.json.Stringify, id: cp.Id, value: std.json.Value) !void {
    try beginResult(s, id);
    try s.objectField("transfer");
    try s.write("inline");
    try s.objectField("result");
    try s.write(value);
    try endResult(s);
}

/// `browser.getCookies` 성공 result: `{"jsonrpc":"2.0","id":<id>,"result":{"cookies":[...]}}`(5f-4c). `cookies_json`은
/// Swift `BrowserControl.getCookies`가 직렬화한 **JSON 배열**(각 원소 `{name,value,domain,path,secure,httpOnly,
/// expires?,sameSite?}` — `WKHTTPCookie` 프로퍼티 매핑, Swift가 단일 출처). L2는 이걸 **파싱해 구조화 embed**한다
/// (executeScript의 문자열 wrap과 달리 진짜 JSON 배열로 실어 에이전트가 이중 파싱 불요). 파싱 실패(비-배열·malformed)면
/// `InvalidCookiesJson` — L4가 `internal_error`로 접는다(Swift 직렬화 버그 방어, wire로 균일 에러). caller free.
pub fn serializeGetCookiesResult(gpa: std.mem.Allocator, id: cp.Id, cookies_json: []const u8) (std.mem.Allocator.Error || error{InvalidCookiesJson})![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, cookies_json, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidCookiesJson, // malformed JSON = Swift 직렬화 버그(방어)
    };
    defer parsed.deinit();
    if (parsed.value != .array) return error.InvalidCookiesJson; // 반드시 배열(빈 배열 [] 정상)
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    (writeGetCookiesResult(&s, id, parsed.value)) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn writeGetCookiesResult(s: *std.json.Stringify, id: cp.Id, cookies: std.json.Value) !void {
    try beginResult(s, id);
    try s.objectField("cookies");
    try s.write(cookies);
    try endResult(s);
}

/// snapshot 트리 노드 깊이 상한 — Chromium 의 `web_cdp_snapshot.max_emit_depth` 와 같다(W9f 적대 리뷰 5 회차).
pub const max_snapshot_node_depth: usize = 100;

/// Swift `BrowserControl.snapshot`가 직렬화한 **JSON**(`{tree:[...]}` 또는 selector 미발견/루트 없음 시 `null`)을 파싱해
/// `{result:{snapshot:<value>}}`로 구조화 embed(§9.5.4 — getCookies와 동형, 에이전트 이중 파싱 불요). 파싱 실패(malformed)=
/// `InvalidSnapshotJson`(L4가 internal_error로 접음 — Swift 직렬화 버그 방어). caller free.
pub fn serializeSnapshotResult(gpa: std.mem.Allocator, id: cp.Id, snapshot_json: []const u8) (std.mem.Allocator.Error || error{InvalidSnapshotJson})![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, snapshot_json, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidSnapshotJson,
    };
    defer parsed.deinit();
    // 깊은 트리를 그대로 다시 쓰면 `std.json.Stringify` 의 중첩 스택(256)을 넘어 앱이 죽었다(W9f 적대 리뷰 5 회차 — WebKit 의 snapshot 은
    // 깊이 상한이 없다). Chromium 과 같은 깊이에서 자식을 끊는다.
    if (parsed.value == .object) if (parsed.value.object.getPtr("tree")) |tree| pruneSnapshotDepth(tree, 0);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    (writeSnapshotResult(&s, id, parsed.value)) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

/// `nodes`(snapshot 노드 배열)에서 깊이 `max_snapshot_node_depth` 를 넘는 자식을 뗀다 — 재귀는 그 깊이로 묶인다.
fn pruneSnapshotDepth(nodes: *std.json.Value, depth: usize) void {
    if (nodes.* != .array) return;
    for (nodes.array.items) |*node| {
        if (node.* != .object) continue;
        if (depth + 1 >= max_snapshot_node_depth) {
            _ = node.object.orderedRemove("children");
        } else if (node.object.getPtr("children")) |kids| pruneSnapshotDepth(kids, depth + 1);
    }
}

fn writeSnapshotResult(s: *std.json.Stringify, id: cp.Id, snap: std.json.Value) !void {
    try beginResult(s, id);
    try s.objectField("snapshot");
    try s.write(snap);
    try endResult(s);
}

/// Swift `BrowserControl.console`가 직렬화한 **JSON**(`[{level,text},...]` 배열)을 파싱해 `{result:{console:<value>}}`로
/// 구조화 embed(§9.5.9 — snapshot과 동형, 에이전트 이중 파싱 불요). 파싱 실패(malformed)=`InvalidConsoleJson`(L4가
/// internal_error로 접음 — Swift 직렬화 버그 방어). caller free.
pub fn serializeConsoleResult(gpa: std.mem.Allocator, id: cp.Id, console_json: []const u8) (std.mem.Allocator.Error || error{InvalidConsoleJson})![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, console_json, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidConsoleJson,
    };
    defer parsed.deinit();
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    (writeConsoleResult(&s, id, parsed.value)) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn writeConsoleResult(s: *std.json.Stringify, id: cp.Id, console: std.json.Value) !void {
    try beginResult(s, id);
    try s.objectField("console");
    try s.write(console);
    try endResult(s);
}

/// `browser.subscribe` 성공 result: `{"jsonrpc":"2.0","id":<id>,"result":{"subscriber_id":<N>}}`(5f-0b-3b). client가
/// 이 subscriber_id로 향후 unsubscribe한다(§9.5.2).
pub fn serializeSubscribeResult(gpa: std.mem.Allocator, id: cp.Id, subscriber_id: u64) std.mem.Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    (writeSubscribeResult(&s, id, subscriber_id)) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn writeSubscribeResult(s: *std.json.Stringify, id: cp.Id, subscriber_id: u64) !void {
    try beginResult(s, id);
    try s.objectField("subscriber_id");
    try s.write(subscriber_id);
    try endResult(s);
}

/// **5f-0b-3b: L4가 동기 구독 등록 후 응답 직렬화.** subscribe는 async op이 아니므로(op 응답 경로 무관) L4가 원
/// `request_bytes`(pending 소유, resolve 전 유효)를 재파싱해 id를 얻고 `subscriber_id`를 실는다(serializeBrowserResponse의
/// subscribe 대응 — id 재파싱 규약 동일). 재파싱 실패/비-request/비-subscribe는 방어적 내부오류(dispatch가 이미 검증 → 도달 안 함).
pub fn serializeSubscribeResponse(gpa: std.mem.Allocator, request_bytes: []const u8, subscriber_id: u64) std.mem.Allocator.Error![]u8 {
    var pm = cp.parseMessage(gpa, request_bytes) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return errorResponse(gpa, .null, .internal_error),
    };
    defer pm.deinit();
    const req = switch (pm.message) {
        .request => |r| r,
        else => return errorResponse(gpa, .null, .internal_error),
    };
    return serializeSubscribeResult(gpa, req.id, subscriber_id);
}

// ── screenshot(5f-1) chunk-streaming 직렬화(§9.5.3·§9.5.7) ────────────────────────────────────────────────
// browser.screenshot 결과 PNG는 소켓 프레임 상한(default_max_frame 1MiB)을 넘을 수 있어 **단일 응답이 아니라**
// chunk notification 여러 개 + 최종 응답(complete+metadata)으로 전달한다(파일-경로 폐기 — same-uid 유출, §9.5.3).
// L4(completeBrowserOp)가 Swift가 넘긴 PNG 바이트를 이 헬퍼들로 프레임화해 요청 연결 pending.outbound에 seq
// 순서로 push한 뒤 completeInFlight로 최종 응답을 resolve한다(FIFO로 chunk 0..N-1 → 최종 응답, §9.5.7).

/// 한 screenshot chunk의 raw PNG 바이트 상한(§9.5.7). base64는 이 raw 경계 위에서 이뤄진다(512KiB→~683KiB base64 <
/// default_max_frame 1MiB, JSON 오버헤드 포함해도 여유). control_capture의 64KiB보다 큰 값=동기 push 첫 컷의 chunk 수 억제.
pub const screenshot_chunk_bytes: usize = 512 * 1024;
pub const screenshot_max_result_bytes: usize = 12 * 1024 * 1024;
/// 동기 push 첫 컷(§9.5.7)의 chunk 수 상한 — outbound_capacity(64 프레임)를 안 넘게(24 chunk + 최종 응답 = 25 ≤ 64).
/// 초과 PNG는 `screenshot_too_large`로 접는다(에이전트가 rect/scale로 축소 재시도 — 후속). progressive pump(무제한)는 후속.
pub const screenshot_max_chunks: usize = 24;

/// §9.5.10 통일: snapshot·console 결과 예약 상한(executeScript 16 MiB 선례). transfer가 초과 시 chunk-stream하고 이 상한
/// 초과면 result-too-large. 예약은 op 시작 시 aggregate budget서 잡고 beginTransfer가 실제 크기로 낮춘다(executeScript 동형).
/// console(통일-2): 서버 버퍼(cap 500 entries)를 **전량** 반환 — bounded ring은 메모리 상한이지 더는 wire 절단이 아니다.
pub const snapshot_max_result_bytes: usize = 16 * 1024 * 1024;
pub const console_max_result_bytes: usize = 16 * 1024 * 1024;
/// executeScript chunk은 base64 팽창과 JSON envelope를 포함해 1MiB frame 아래에 머물도록 raw 512KiB로 나눈다.
pub const execute_script_chunk_bytes: usize = 512 * 1024;
/// final/error가 일반 chunk에 막히지 않도록 예약한 연결별 terminal wire 상한(개행 포함).
pub const execute_script_terminal_wire_bytes: usize = 64 * 1024;
const execute_script_chunk_method = cp.browser_execute_script_chunk_method;
pub const ExecuteScriptChunkError = error{ InvalidResultId, ChunkTooLarge, FrameTooLarge };
pub const ExecuteScriptCompleteError = error{ InvalidResultId, TerminalFrameTooLarge };

/// §9.5.10 통일: base64-json chunk notification을 **method-generic**하게 직렬화한다. executeScript/snapshot/console이 같은
/// transfer 기계를 쓰되 `chunk_method`(`browser.<m>Chunk` SSOT 상수)만 다르다. chunk body 구조·frame 상한은 동일.
pub fn serializeResultChunk(gpa: std.mem.Allocator, chunk_method: []const u8, request_id: cp.Id, result_id: i64, seq: usize, data: []const u8) (std.mem.Allocator.Error || ExecuteScriptChunkError)![]u8 {
    if (result_id < 0) return error.InvalidResultId;
    if (data.len > execute_script_chunk_bytes) return error.ChunkTooLarge;
    const encoder = std.base64.standard.Encoder;
    const b64 = try gpa.alloc(u8, encoder.calcSize(data.len));
    defer gpa.free(b64);
    _ = encoder.encode(b64, data);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    // method 이름은 SSOT 상수(cp.browser_*_chunk_method) — CLI 소비자와 같은 출처라 wire drift 방지.
    aw.writer.writeAll("{\"jsonrpc\":\"2.0\",\"method\":\"") catch return error.OutOfMemory;
    aw.writer.writeAll(chunk_method) catch return error.OutOfMemory;
    aw.writer.writeAll("\",\"params\":{\"request_id\":") catch return error.OutOfMemory;
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    cp.writeId(&s, request_id) catch return error.OutOfMemory;
    aw.writer.print(",\"result_id\":{d},\"seq\":{d},\"encoding\":\"base64-json\",\"data\":\"", .{ result_id, seq }) catch return error.OutOfMemory;
    // 표준 base64 alphabet에는 JSON escape 대상이 없으므로 Stringify로 byte마다 재검증하지 않고 그대로 쓴다.
    aw.writer.writeAll(b64) catch return error.OutOfMemory;
    aw.writer.writeAll("\"}}") catch return error.OutOfMemory;
    const wire = aw.toOwnedSlice() catch return error.OutOfMemory;
    if (wire.len > cp.default_max_frame) {
        gpa.free(wire);
        return error.FrameTooLarge;
    }
    return wire;
}

/// executeScript chunk — generic core에 executeScript 메서드명을 넘긴 delegate(byte-identical, 기존 호출처·테스트 계약 유지).
pub fn serializeExecuteScriptChunk(gpa: std.mem.Allocator, request_id: cp.Id, result_id: i64, seq: usize, data: []const u8) (std.mem.Allocator.Error || ExecuteScriptChunkError)![]u8 {
    return serializeResultChunk(gpa, execute_script_chunk_method, request_id, result_id, seq, data);
}

/// §9.5.10: op은 id/method를 안 실으므로 원 request_bytes 재파싱해 request id를 얻고 chunk를 만든다(method-generic — pump가
/// kind별 chunk 메서드를 넘긴다). executeScript/snapshot/console 공용.
pub fn serializeResultChunkForRequest(gpa: std.mem.Allocator, chunk_method: []const u8, request_bytes: []const u8, result_id: i64, seq: usize, data: []const u8) (std.mem.Allocator.Error || ExecuteScriptChunkError)![]u8 {
    // method-generic: 원 request의 id만 필요하다(executeScript/snapshot/console 공용). 비-request는 방어(dispatch가 이미
    // request 검증 — 도달 안 함), 파싱 실패와 함께 실패 취급(pump가 cancelBrowserTransfer). id는 pm 소유라 deinit 전에 쓴다.
    var pm = cp.parseMessage(gpa, request_bytes) catch return error.OutOfMemory;
    defer pm.deinit();
    const req_id: cp.Id = switch (pm.message) {
        .request => |r| r.id,
        else => return error.InvalidResultId,
    };
    return serializeResultChunk(gpa, chunk_method, req_id, result_id, seq, data);
}

pub fn serializeExecuteScriptChunkForRequest(gpa: std.mem.Allocator, request_bytes: []const u8, result_id: i64, seq: usize, data: []const u8) (std.mem.Allocator.Error || ExecuteScriptChunkError)![]u8 {
    return serializeResultChunkForRequest(gpa, execute_script_chunk_method, request_bytes, result_id, seq, data);
}

/// progressive chunk를 모두 enqueue한 뒤 같은 FIFO에 놓는 작은 terminal 응답. request id는 원 요청에서 다시 읽어
/// notification의 request_id와 최종 응답 id가 갈라지지 않게 한다. 실제 16 MiB 경로는 pump+CLI sink와 함께 후속에서 연다.
pub fn serializeExecuteScriptChunkedComplete(
    gpa: std.mem.Allocator,
    request_bytes: []const u8,
    result_id: i64,
    seq_total: usize,
    bytes: usize,
) (std.mem.Allocator.Error || ExecuteScriptCompleteError)![]u8 {
    if (result_id < 0) return error.InvalidResultId;
    var pm = cp.parseMessage(gpa, request_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return errorResponse(gpa, .null, .internal_error),
    };
    defer pm.deinit();
    const req = switch (pm.message) {
        .request => |r| r,
        else => return errorResponse(gpa, .null, .internal_error),
    };
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    s.beginObject() catch return error.OutOfMemory;
    s.objectField("jsonrpc") catch return error.OutOfMemory;
    s.write(cp.jsonrpc_version) catch return error.OutOfMemory;
    s.objectField("id") catch return error.OutOfMemory;
    cp.writeId(&s, req.id) catch return error.OutOfMemory;
    s.objectField("result") catch return error.OutOfMemory;
    s.beginObject() catch return error.OutOfMemory;
    s.objectField("transfer") catch return error.OutOfMemory;
    s.write("chunked") catch return error.OutOfMemory;
    s.objectField("result_id") catch return error.OutOfMemory;
    s.write(result_id) catch return error.OutOfMemory;
    s.objectField("seq_total") catch return error.OutOfMemory;
    s.write(seq_total) catch return error.OutOfMemory;
    s.objectField("bytes") catch return error.OutOfMemory;
    s.write(bytes) catch return error.OutOfMemory;
    s.endObject() catch return error.OutOfMemory;
    s.endObject() catch return error.OutOfMemory;
    const wire = aw.toOwnedSlice() catch return error.OutOfMemory;
    if (wire.len + 1 > execute_script_terminal_wire_bytes) {
        gpa.free(wire);
        return error.TerminalFrameTooLarge;
    }
    return wire;
}

const screenshot_chunk_method = cp.browser_screenshot_chunk_method; // 22차 [8]: 단일 출처(control_plane)

/// PNG IHDR의 width/height(§9.5.7 metadata). **단일 출처=control_plane**(서버·CLI 클라이언트가 같은 파서 공유 — cli는
/// cp만 import). 여기선 alias만 재노출(app_host_abi·serializeScreenshotComplete가 control_browser.PngDims/pngDimensions로 참조).
pub const PngDims = cp.PngDims;
pub const pngDimensions = cp.pngDimensions;

/// screenshot chunk notification(§9.5.7): `{"jsonrpc":"2.0","method":"browser.screenshotChunk","params":
/// {"capture_id":N,"seq":K,"encoding":"base64","data":"<base64>"}}`. `data`=PNG 조각 base64(임의 바이트 안전 —
/// §4.3 규율). generation 없음(스크린샷=pinned 스냅샷이라 torn-read 방어 불요, control_capture와 다른 점). caller free.
pub fn serializeScreenshotChunk(gpa: std.mem.Allocator, capture_id: u64, seq: usize, data: []const u8) std.mem.Allocator.Error![]u8 {
    const encoder = std.base64.standard.Encoder;
    const b64 = try gpa.alloc(u8, encoder.calcSize(data.len));
    defer gpa.free(b64);
    _ = encoder.encode(b64, data);

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    aw.writer.print("{{\"jsonrpc\":\"2.0\",\"method\":\"browser.screenshotChunk\",\"params\":{{\"capture_id\":{d},\"seq\":{d},\"encoding\":\"base64\",\"data\":\"", .{ capture_id, seq }) catch return error.OutOfMemory;
    aw.writer.writeAll(b64) catch return error.OutOfMemory;
    aw.writer.writeAll("\"}}") catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

/// screenshot 최종 응답(§9.5.7 — chunk 스트림의 complete 마커 + metadata를 겸함): `{"jsonrpc":"2.0","id":<id>,"result":
/// {"capture_id":N,"seq_total":M,"bytes":B,"width":W,"height":H,"format":"png"}}`. op은 id/method를 안 실으므로(§9.3 ⑥) 원
/// `request_bytes`(in-flight pending 소유·resolve 전 유효) 재파싱해 id를 얻는다. 재파싱 실패/비-request는 방어적 내부오류. caller free.
pub fn serializeScreenshotComplete(gpa: std.mem.Allocator, request_bytes: []const u8, capture_id: u64, seq_total: usize, total_bytes: usize, dims: PngDims) std.mem.Allocator.Error![]u8 {
    var pm = cp.parseMessage(gpa, request_bytes) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return errorResponse(gpa, .null, .internal_error),
    };
    defer pm.deinit();
    const req = switch (pm.message) {
        .request => |r| r,
        else => return errorResponse(gpa, .null, .internal_error),
    };
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    writeScreenshotComplete(&s, req.id, capture_id, seq_total, total_bytes, dims) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn writeScreenshotComplete(s: *std.json.Stringify, id: cp.Id, capture_id: u64, seq_total: usize, total_bytes: usize, dims: PngDims) !void {
    try beginResult(s, id);
    try s.objectField("capture_id");
    try s.write(capture_id);
    try s.objectField("seq_total");
    try s.write(seq_total);
    try s.objectField("bytes");
    try s.write(total_bytes);
    try s.objectField("width");
    try s.write(dims.width);
    try s.objectField("height");
    try s.write(dims.height);
    try s.objectField("format");
    try s.write("png");
    try endResult(s);
}

/// PNG 시그니처(8B) + IHDR chunk(len 4·"IHDR" 4·width 4 BE[off 16]·height 4 BE[off 20])에서 width/height를 읽는다
/// (§9.5.7). 시그니처 불일치·길이 부족·IHDR 부재면 null(비-PNG 스냅샷 → completeBrowserOp이 internal_error로 접음). 순수.
/// op 완료가 screenshot인지(chunk 경로 분기, §9.5.7). request_bytes 재파싱해 method 확인. 비-request/미지 method는 false.
pub fn isScreenshotRequest(gpa: std.mem.Allocator, request_bytes: []const u8) bool {
    var pm = cp.parseMessage(gpa, request_bytes) catch return false;
    defer pm.deinit();
    const req = switch (pm.message) {
        .request => |r| r,
        else => return false,
    };
    const bm = parseBrowserMethod(cp.parseMethod(req.method).rest) orelse return false;
    return bm == .screenshot;
}

/// screenshot 요청의 대상 web surface_id(params.id) — chunk 프레임 tag(surface-close/revoke purge)용(§9.5.7). 재파싱
/// 실패면 null(호출자가 tag=0 폴백). u64 값 복사라 pm.deinit 뒤에도 유효.
pub fn parseScreenshotTargetId(gpa: std.mem.Allocator, request_bytes: []const u8) ?u64 {
    var pm = cp.parseMessage(gpa, request_bytes) catch return null;
    defer pm.deinit();
    const req = switch (pm.message) {
        .request => |r| r,
        else => return null,
    };
    const obj = paramsObject(req.params) catch return null;
    return idFromObj(obj) catch null;
}

// ── browser.list(발견, §9.6) 직렬화 — ungated web surface 나열 ──────────────────────────────────────────────

/// `browser.list` 성공 result(§9.6 발견): `{"jsonrpc":"2.0","id":<id>,"result":{"surfaces":[{"id":N,"url":"...",
/// "title":"...","panel_kind":"browser|markdown"},...]}}`. snapshot에서 **web surface만** 필터(터미널 제외 — 제어 대상만).
/// **ungated**(cap/grant/모달 무관 — 사용자 결정: 같은 uid=자신의 브라우저라 URL 노출 수용; 제어[navigate·screenshot 등]는
/// 별도 §9.2 Model B 모달 게이트 유지). 에이전트가 이 id로 제어를 건다. dispatchAuthenticated이 browser.list를 이 경로로
/// 라우팅(cap 로직 우회). caller free.
pub fn serializeBrowserListResult(gpa: std.mem.Allocator, id: cp.Id, snapshot: cs.CollectorSnapshot) std.mem.Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    writeBrowserListResult(&s, id, snapshot) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

/// 대상 web 탭에서 이 메서드를 실행할 수 없으면 그 탭의 메타를, 할 수 있으면(또는 web 이 아니면) null.
fn unsupportedOnSurface(dto: cs.SurfaceDto, m: BrowserMethod) ?cs.WebMeta {
    const w = switch (dto.detail) {
        .web => |w| w,
        else => return null,
    };
    return if (surfaceSupports(w, m)) null else w;
}

/// 대상 메서드에 `locator` 키가 있고 그 탭의 엔진이 로케이터를 못 하면(WebKit) 그 탭의 메타.
fn locatorUnsupported(dto: cs.SurfaceDto, m: BrowserMethod, params: ?std.json.Value) ?cs.WebMeta {
    switch (m) {
        .click, .type_text, .scroll, .hover, .press, .wait => {},
        else => return null,
    }
    const w = switch (dto.detail) {
        .web => |w| w,
        else => return null,
    };
    if (w.engine == .chromium) return null;
    const p = params orelse return null;
    if (p != .object or p.object.get("locator") == null) return null;
    return w;
}

/// `-32008` — data `{engine}`, 브라우저 탭이 아니면(markdown·파일 뷰) `controllable:false` 도.
fn unsupportedByEngineResponse(gpa: std.mem.Allocator, id: cp.Id, engine: cs.WebEngine, controllable: bool) std.mem.Allocator.Error![]u8 {
    return unsupportedByEngineParamResponse(gpa, id, engine, controllable, null);
}

/// 메서드는 되지만 그 인자를 그 엔진이 못 할 때(W9b② — WebKit 의 `locator`) data 에 `param` 도.
fn unsupportedByEngineParamResponse(gpa: std.mem.Allocator, id: cp.Id, engine: cs.WebEngine, controllable: bool, param: ?[]const u8) std.mem.Allocator.Error![]u8 {
    var data: std.json.ObjectMap = .empty;
    defer data.deinit(gpa);
    try data.put(gpa, "engine", .{ .string = engine.wireName() });
    if (!controllable) try data.put(gpa, "controllable", .{ .bool = false });
    if (param) |p| try data.put(gpa, "param", .{ .string = p });
    return cp.serializeError(gpa, id, .unsupported_by_engine, cp.ErrorCode.unsupported_by_engine.defaultMessage(), .{ .object = data });
}

/// 실행 단계(L4)에서 같은 `-32008` 로 답한다 — L2 와 같은 모양(원 `request_bytes` 를 재파싱해 id 를 얻는다).
pub fn serializeUnsupportedByEngine(gpa: std.mem.Allocator, request_bytes: []const u8, engine: cs.WebEngine) std.mem.Allocator.Error![]u8 {
    var pm = cp.parseMessage(gpa, request_bytes) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return errorResponse(gpa, .null, .internal_error),
    };
    defer pm.deinit();
    const req = switch (pm.message) {
        .request => |r| r,
        else => return errorResponse(gpa, .null, .internal_error),
    };
    return unsupportedByEngineResponse(gpa, req.id, engine, true);
}

fn writeBrowserListResult(s: *std.json.Stringify, id: cp.Id, snapshot: cs.CollectorSnapshot) !void {
    try beginResult(s, id);
    try s.objectField("surfaces");
    try s.beginArray();
    for (snapshot.surfaces) |dto| {
        switch (dto.detail) {
            .web => |w| {
                try s.beginObject();
                try s.objectField("id");
                try s.write(dto.surface_id);
                try s.objectField("url");
                try s.write(w.url orelse "");
                try s.objectField("title");
                try s.write(dto.title);
                try s.objectField("panel_kind");
                try s.write(switch (w.panel_kind) {
                    .markdown => "markdown",
                    .browser => "browser",
                });
                // W9-0: 엔진과 그 탭에서 실행할 수 있는 메서드(에이전트가 「이 탭은 못 한다」를 미리 안다 — Aside 의 탭 목록처럼).
                try s.objectField("engine");
                try s.write(w.engine.wireName());
                try s.objectField("controllable");
                try s.write(w.controllable);
                try s.objectField("methods");
                try s.beginArray();
                inline for (std.meta.fields(BrowserMethod)) |f| {
                    const m: BrowserMethod = @enumFromInt(f.value);
                    if (surfaceSupports(w, m)) try s.write(browserMethodWireName(m));
                }
                try s.endArray();
                try s.endObject();
            },
            else => {}, // terminal surface 제외 — browser.list는 제어 가능한 web만
        }
    }
    try s.endArray();
    try endResult(s);
}

// result envelope open/close는 cp.beginResult/endResult 단일 출처 재사용(리뷰12 [4] — 브리지와 공유, 로컬 복제 제거).
const beginResult = cp.beginResult;
const endResult = cp.endResult;

/// **1e-confirm-1c: needs_grant를 균일 unauthorized 응답으로 접는다.** L4가 (1c-1) needs_grant를 held 흐름 없이
/// 처리하거나 (1c-2) 확인 **거부**·timeout 시 부른다. op 완료 경로처럼 `request_bytes`(pending 소유·resolve 전 유효)를
/// 재파싱해 id를 얻는다(§9.3 ⑥ — needs_grant는 id를 안 실음). 재파싱 실패/비-request는 방어적 내부오류(dispatch가 이미 검증).
pub fn serializeUnauthorized(gpa: std.mem.Allocator, request_bytes: []const u8) std.mem.Allocator.Error![]u8 {
    var pm = cp.parseMessage(gpa, request_bytes) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return errorResponse(gpa, .null, .internal_error),
    };
    defer pm.deinit();
    const req = switch (pm.message) {
        .request => |r| r,
        else => return errorResponse(gpa, .null, .internal_error),
    };
    return errorResponse(gpa, req.id, .unauthorized);
}

/// **5e-2b: L4 completion이 Swift `BrowserControl` 결과를 browser.* 응답으로 직렬화한다.** op은 응답 id/method를 안
/// 싣으므로(§9.3 ⑥) 원 `request_bytes`(in-flight pending이 아직 소유 — resolve 전이라 유효)를 재파싱해 id·method를
/// 얻고, method별 result 헬퍼로 실는다. `ok=false`(webView 부재·evaluateJavaScript 에러 등)면 `internal_error`(+`result`
/// 를 message로). `result`는 method별: navigate=무시·getUrl=url·executeScript=스크립트 반환값을 **문자열로** 싣는다
/// (JS 값 → 문자열; 진짜 JSON 값 embed는 후속). 재파싱 실패·비-browser는 방어적 내부오류(dispatch가 이미 검증했으므로 도달 안 함).
/// Swift→Zig browser op 완료 status. ABI는 u32지만 L2가 숫자 의미의 단일 출처를 소유한다.
pub const BrowserCompletionStatus = enum(u32) {
    success = 0,
    failed = 1,
    timeout = 2,
    invalid_params = 3,
    process_exited = 4,
    unauthorized = 5,
};

pub fn serializeBrowserResponse(gpa: std.mem.Allocator, request_bytes: []const u8, ok: bool, result: []const u8) std.mem.Allocator.Error![]u8 {
    return serializeBrowserResponseStatus(gpa, request_bytes, if (ok) .success else .failed, result);
}

pub fn serializeBrowserResponseStatus(gpa: std.mem.Allocator, request_bytes: []const u8, status: BrowserCompletionStatus, result: []const u8) std.mem.Allocator.Error![]u8 {
    var pm = cp.parseMessage(gpa, request_bytes) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return errorResponse(gpa, .null, .internal_error),
    };
    defer pm.deinit();
    const req = switch (pm.message) {
        .request => |r| r,
        else => return errorResponse(gpa, .null, .internal_error),
    };
    const bmethod = parseBrowserMethod(cp.parseMethod(req.method).rest) orelse return errorResponse(gpa, req.id, .internal_error);
    if (status != .success) {
        return switch (status) {
            .timeout => if (bmethod == .wait)
                serializeWaitTimeoutError(gpa, req, result)
            else
                cp.serializeError(gpa, req.id, .timeout, cp.ErrorCode.timeout.defaultMessage(), null),
            .invalid_params => cp.serializeError(gpa, req.id, .invalid_params, if (result.len > 0) result else "Invalid selector", null),
            .process_exited => cp.serializeError(gpa, req.id, .process_exited, cp.ErrorCode.process_exited.defaultMessage(), null),
            // W9c③: 업로드 확인 모달의 「거부」 는 인가 판정이 아니라 사용자의 답이다 — 무엇을 거절했는지 그대로 싣는다(인가의 균일 글은 존재·이유를
            // 숨기려는 것이라 여기에는 숨길 것이 없다). 철회·닫힘의 unauthorized 는 글 없이 오므로 균일 글 그대로다.
            .unauthorized => cp.serializeError(gpa, req.id, .unauthorized, if (bmethod == .upload and result.len > 0) result else cp.ErrorCode.unauthorized.defaultMessage(), null),
            .success => unreachable,
            .failed => cp.serializeError(gpa, req.id, .internal_error, if (result.len > 0) result else if (bmethod == .wait) "browser wait failed" else "browser op failed", null),
        };
    }
    return switch (bmethod) {
        .navigate => serializeNavigateLoadedResult(gpa, req.id, result),
        .get_url => serializeGetUrlResult(gpa, req.id, result),
        .execute_script => blk: {
            const params = parseExecuteScriptParams(req.params) catch return cp.serializeError(gpa, req.id, .internal_error, "invalid executeScript request state", null);
            if (result.len > params.max_result_bytes) {
                break :blk serializeResultTooLarge(gpa, req.id, params.max_result_bytes, params.max_result_bytes + 1);
            }
            break :blk serializeExecuteScriptResponse(gpa, req.id, result);
        },
        .get_cookies => serializeGetCookiesResult(gpa, req.id, result) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            // Swift가 준 cookies_json이 malformed(배열 아님·손상) = 직렬화 버그 → 균일 internal_error(oracle 아님).
            error.InvalidCookiesJson => return cp.serializeError(gpa, req.id, .internal_error, "invalid cookies payload", null),
        },
        .subscribe => unreachable, // subscribe는 async op이 아니라 이 함수(op 완료 응답)로 안 온다 — serializeSubscribeResponse 사용
        // screenshot(ok=true)은 통상 completeBrowserOp이 chunk 경로로 가로채 이 단일-응답 함수에 안 온다(§9.5.7). 단
        // **isScreenshotRequest가 일시적 OOM으로 false**를 반환하면(app_host_abi) 여기로 falling through할 수 있다 — 그 사이
        // OOM이 풀려 이 재파싱은 성공하면 bmethod=.screenshot, ok=true로 이 arm에 닿는다(22차 리뷰 [0]). `unreachable`이면
        // 저확률이지만 앱이 크래시하므로 **균일 internal_error**로 접는다(ok=false 경로와 동형 — client는 에러 응답 수신).
        .screenshot => cp.serializeError(gpa, req.id, .internal_error, "screenshot delivered out of band", null),
        // setCookie/deleteCookie 성공 = {ok:true}(navigate와 동형 — write 성공 여부만). Swift가 status로 실패 전달(위 !ok 경로).
        .set_cookie, .delete_cookie => serializeNavigateResult(gpa, req.id),
        // getLocalStorage → {value:<result>}(eval getItem 반환, JS null=빈 문자열). set/remove/clear → {ok:true}.
        .get_local_storage => serializeValueResult(gpa, req.id, result),
        .set_local_storage, .remove_local_storage, .clear_storage => serializeNavigateResult(gpa, req.id),
        // act(5f-2): click/type/scroll → {ok:<bool>} — Swift eval이 "true"(요소 발견+동작)/"false"(셀렉터 미매치)를 result로.
        // 로케이터로 찾았으면 엔진이 `{"ok":true,"matched":{"ref","name"}}` 를 준다(W9b② — 무엇을 눌렀는지).
        .click, .type_text, .scroll, .hover, .press => if (result.len > 0 and result[0] == '{')
            serializeActMatchedResult(gpa, req.id, result) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return cp.serializeError(gpa, req.id, .internal_error, "invalid act payload", null),
            }
        else
            serializeOkBoolResult(gpa, req.id, std.mem.eql(u8, result, "true")),
        // W9b①: back/forward → 갈 곳이 있었는가, reload → true.
        .back, .forward, .reload => serializeOkBoolResult(gpa, req.id, std.mem.eql(u8, result, "true")),
        // W9b③: 엔진이 준 `{"id","url","loaded"}`·`{"closed","reason"?}` 을 검사해 그 필드만 싣는다.
        .open, .close => serializeTabResult(gpa, req.id, bmethod, result) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return cp.serializeError(gpa, req.id, .internal_error, "invalid tab payload", null),
        },
        // W9c②: 앱이 준 `{"dialogs":[…]}`·`{"ok","kind","continues"?}` 을 검사해 알려진 필드만 싣는다.
        .dialog, .handle_dialog => serializeDialogResult(gpa, req.id, bmethod, result) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return cp.serializeError(gpa, req.id, .internal_error, "invalid dialog payload", null),
        },
        // W9c③: 앱이 준 `{"origin","files":[{"name","size"}]}` 을 검사해 그 필드만 싣는다.
        .upload => serializeUploadResult(gpa, req.id, result) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return cp.serializeError(gpa, req.id, .internal_error, "invalid upload payload", null),
        },
        // 로케이터로 기다렸으면 엔진이 `{"ok":true,"matched":{…},"ambiguous"?:true}` 를 준다(W9b②-3).
        .wait => if (result.len > 0 and result[0] == '{')
            serializeActMatchedResult(gpa, req.id, result) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return cp.serializeError(gpa, req.id, .internal_error, "invalid wait payload", null),
            }
        else
            serializeNavigateResult(gpa, req.id),
        // snapshot(§9.5.4) → {snapshot:<tree JSON>}. Swift가 준 JSON을 구조화 embed(malformed=internal_error 방어).
        .snapshot => serializeSnapshotResult(gpa, req.id, result) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidSnapshotJson => return cp.serializeError(gpa, req.id, .internal_error, "invalid snapshot payload", null),
        },
        // console(§9.5.9) → {console:<[{level,text}] JSON>}. Swift 서버 버퍼 JSON을 구조화 embed(malformed=internal_error 방어).
        .console => serializeConsoleResult(gpa, req.id, result) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidConsoleJson => return cp.serializeError(gpa, req.id, .internal_error, "invalid console payload", null),
        },
    };
}

/// W9b③ 결과 — open `{"id":<u64>,"url":<str>,"loaded":<bool>}`, close `{"closed":<bool>,"reason"?:<str>}`. 다른 키·모양은 거절.
fn serializeTabResult(gpa: std.mem.Allocator, id: cp.Id, method: BrowserMethod, payload: []const u8) (std.mem.Allocator.Error || error{InvalidTabPayload})![]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, payload, .{}) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidTabPayload,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidTabPayload;
    const o = parsed.value.object;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    switch (method) {
        .open => {
            const tab = o.get("id") orelse return error.InvalidTabPayload;
            const url = o.get("url") orelse return error.InvalidTabPayload;
            const loaded = o.get("loaded") orelse return error.InvalidTabPayload;
            if (tab != .integer or tab.integer <= 0 or url != .string or loaded != .bool) return error.InvalidTabPayload;
            (blk: {
                beginResult(&s, id) catch |e| break :blk e;
                s.objectField("id") catch |e| break :blk e;
                s.write(tab.integer) catch |e| break :blk e;
                s.objectField("url") catch |e| break :blk e;
                s.write(url.string) catch |e| break :blk e;
                s.objectField("loaded") catch |e| break :blk e;
                s.write(loaded.bool) catch |e| break :blk e;
                endResult(&s) catch |e| break :blk e;
            }) catch return error.OutOfMemory;
        },
        .close => {
            const closed = o.get("closed") orelse return error.InvalidTabPayload;
            if (closed != .bool) return error.InvalidTabPayload;
            const reason = o.get("reason");
            if (reason) |r| if (r != .string) return error.InvalidTabPayload;
            (blk: {
                beginResult(&s, id) catch |e| break :blk e;
                s.objectField("closed") catch |e| break :blk e;
                s.write(closed.bool) catch |e| break :blk e;
                if (reason) |r| {
                    s.objectField("reason") catch |e| break :blk e;
                    s.write(r.string) catch |e| break :blk e;
                }
                endResult(&s) catch |e| break :blk e;
            }) catch return error.OutOfMemory;
        },
        else => return error.InvalidTabPayload,
    }
    return aw.toOwnedSlice();
}

/// W9c② 결과 — dialog `{"dialogs":[{tab,kind, token?,message?,origin?,default_text?,cause?,may_answer?,may_leave?}]}`(`tab`·`kind` 는 꼭,
/// 나머지는 grant 가 있는 탭에만 — 앱이 정한다), handleDialog `{"ok":true,"kind":<str>,"continues"?:<bool>}`. 모르는 키는 버리고 타입이
/// 틀리면 거절(앱이 낸 것이라도 wire 로 나가는 모양은 여기서 고정한다).
fn serializeDialogResult(gpa: std.mem.Allocator, id: cp.Id, method: BrowserMethod, payload: []const u8) (std.mem.Allocator.Error || error{InvalidDialogPayload})![]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, payload, .{}) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidDialogPayload,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidDialogPayload;
    const o = parsed.value.object;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    switch (method) {
        .dialog => {
            const list = o.get("dialogs") orelse return error.InvalidDialogPayload;
            if (list != .array) return error.InvalidDialogPayload;
            const int_keys = [_][]const u8{ "token", "tab" };
            const str_keys = [_][]const u8{ "kind", "message", "origin", "default_text", "cause" };
            for (list.array.items) |item| {
                if (item != .object) return error.InvalidDialogPayload;
                const tab = item.object.get("tab") orelse return error.InvalidDialogPayload;
                const kind = item.object.get("kind") orelse return error.InvalidDialogPayload;
                if (tab != .integer or tab.integer <= 0 or kind != .string) return error.InvalidDialogPayload;
                for (int_keys) |k| if (item.object.get(k)) |v| if (v != .integer or v.integer <= 0) return error.InvalidDialogPayload;
                for (str_keys) |k| if (item.object.get(k)) |v| if (v != .string) return error.InvalidDialogPayload;
                for ([_][]const u8{ "may_answer", "may_leave" }) |k| if (item.object.get(k)) |v| if (v != .bool) return error.InvalidDialogPayload;
            }
            (blk: {
                beginResult(&s, id) catch |e| break :blk e;
                s.objectField("dialogs") catch |e| break :blk e;
                s.beginArray() catch |e| break :blk e;
                for (list.array.items) |item| {
                    s.beginObject() catch |e| break :blk e;
                    // 순서를 고정한다(번호·탭·종류·글·출처·기본 글·원인·답해도 되는가·떠나도 되는가).
                    for ([_][]const u8{ "token", "tab", "kind", "message", "origin", "default_text", "cause", "may_answer", "may_leave" }) |k| if (item.object.get(k)) |v| {
                        s.objectField(k) catch |e| break :blk e;
                        s.write(v) catch |e| break :blk e;
                    };
                    s.endObject() catch |e| break :blk e;
                }
                s.endArray() catch |e| break :blk e;
                endResult(&s) catch |e| break :blk e;
            }) catch return error.OutOfMemory;
        },
        .handle_dialog => {
            const ok = o.get("ok") orelse return error.InvalidDialogPayload;
            const kind = o.get("kind") orelse return error.InvalidDialogPayload;
            if (ok != .bool or kind != .string) return error.InvalidDialogPayload;
            const continues = o.get("continues");
            if (continues) |c| if (c != .bool) return error.InvalidDialogPayload;
            (blk: {
                beginResult(&s, id) catch |e| break :blk e;
                s.objectField("ok") catch |e| break :blk e;
                s.write(ok.bool) catch |e| break :blk e;
                s.objectField("kind") catch |e| break :blk e;
                s.write(kind.string) catch |e| break :blk e;
                if (continues) |c| {
                    s.objectField("continues") catch |e| break :blk e;
                    s.write(c.bool) catch |e| break :blk e;
                }
                endResult(&s) catch |e| break :blk e;
            }) catch return error.OutOfMemory;
        },
        else => return error.InvalidDialogPayload,
    }
    return aw.toOwnedSlice();
}

/// W9c③ 결과 — `{"origin":<str>,"files":[{"name":<str>,"size":<u64>}, …]}`(파일 1..10 개). 다른 키는 버리고, 모양이 틀리면 거절.
fn serializeUploadResult(gpa: std.mem.Allocator, id: cp.Id, payload: []const u8) (std.mem.Allocator.Error || error{InvalidUploadPayload})![]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, payload, .{}) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidUploadPayload,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidUploadPayload;
    const origin = parsed.value.object.get("origin") orelse return error.InvalidUploadPayload;
    const files = parsed.value.object.get("files") orelse return error.InvalidUploadPayload;
    if (origin != .string or files != .array) return error.InvalidUploadPayload;
    if (files.array.items.len == 0 or files.array.items.len > max_upload_files) return error.InvalidUploadPayload;
    for (files.array.items) |f| {
        if (f != .object) return error.InvalidUploadPayload;
        const name = f.object.get("name") orelse return error.InvalidUploadPayload;
        const size = f.object.get("size") orelse return error.InvalidUploadPayload;
        if (name != .string or size != .integer or size.integer < 0) return error.InvalidUploadPayload;
    }
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    (blk: {
        beginResult(&s, id) catch |e| break :blk e;
        s.objectField("origin") catch |e| break :blk e;
        s.write(origin.string) catch |e| break :blk e;
        s.objectField("files") catch |e| break :blk e;
        s.beginArray() catch |e| break :blk e;
        for (files.array.items) |f| {
            s.beginObject() catch |e| break :blk e;
            s.objectField("name") catch |e| break :blk e;
            s.write(f.object.get("name").?.string) catch |e| break :blk e;
            s.objectField("size") catch |e| break :blk e;
            s.write(f.object.get("size").?.integer) catch |e| break :blk e;
            s.endObject() catch |e| break :blk e;
        }
        s.endArray() catch |e| break :blk e;
        endResult(&s) catch |e| break :blk e;
    }) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn serializeResultTooLarge(gpa: std.mem.Allocator, id: cp.Id, limit_bytes: usize, observed_at_least: usize) std.mem.Allocator.Error![]u8 {
    var data: std.json.ObjectMap = .empty;
    defer data.deinit(gpa);
    try data.put(gpa, "limit_bytes", .{ .integer = @intCast(limit_bytes) });
    try data.put(gpa, "observed_bytes_at_least", .{ .integer = @intCast(observed_at_least) });
    return cp.serializeError(gpa, id, .result_too_large, cp.ErrorCode.result_too_large.defaultMessage(), .{ .object = data });
}

fn serializeWaitTimeoutError(gpa: std.mem.Allocator, req: cp.Request, result: []const u8) std.mem.Allocator.Error![]u8 {
    const p = parseWaitParams(req.params) catch return cp.serializeError(gpa, req.id, .internal_error, "invalid wait request state", null);
    var data: std.json.ObjectMap = .empty;
    defer data.deinit(gpa);
    try data.put(gpa, "condition", .{ .string = p.condition.wire() });
    try data.put(gpa, "timeout_ms", .{ .integer = p.timeout_ms });
    // 로케이터 wait — 마지막 확인의 숨은 일치 수(엔진이 `{"hidden":N}` 으로 준다, W9b②-3). 모양이 틀리면 싣지 않는다.
    if (result.len > 0) if (std.json.parseFromSlice(std.json.Value, gpa, result, .{})) |parsed| {
        defer parsed.deinit();
        if (parsed.value == .object) if (parsed.value.object.get("hidden")) |h| if (h == .integer and h.integer >= 0) {
            try data.put(gpa, "hidden", .{ .integer = h.integer });
        };
    } else |e| if (e == error.OutOfMemory) return error.OutOfMemory;
    return cp.serializeError(gpa, req.id, .timeout, cp.ErrorCode.timeout.defaultMessage(), .{ .object = data });
}

/// 로케이터 act 결과 `{"ok":true,"matched":{"ref","name"}}` — 엔진이 준 JSON 을 검사해 그 두 필드만 싣는다.
fn serializeActMatchedResult(gpa: std.mem.Allocator, id: cp.Id, payload: []const u8) (std.mem.Allocator.Error || error{InvalidActPayload})![]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, payload, .{}) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidActPayload,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidActPayload;
    const ok = parsed.value.object.get("ok") orelse return error.InvalidActPayload;
    if (ok != .bool) return error.InvalidActPayload;
    // 못 찾았지만 숨은 일치가 있었다(W9b②-2) — `{ok:false, hint}`.
    if (!ok.bool) {
        const hint = parsed.value.object.get("hint") orelse return error.InvalidActPayload;
        if (hint != .string) return error.InvalidActPayload;
        var haw: std.Io.Writer.Allocating = .init(gpa);
        defer haw.deinit();
        var hs: std.json.Stringify = .{ .writer = &haw.writer, .options = .{} };
        writeActHint(&hs, id, hint.string) catch return error.OutOfMemory;
        return haw.toOwnedSlice();
    }
    // 입력 뒤 페이지가 JS 대화상자를 띄웠다(W9b③ 적대 리뷰 3 회차) — true 일 때만 싣는다. 그때는 matched 없이도(selector·ref 로 누른 것).
    const dialog = if (parsed.value.object.get("dialog")) |d| d == .bool and d.bool else false;
    const matched_value = parsed.value.object.get("matched");
    if (matched_value == null and !dialog) return error.InvalidActPayload;
    var ref: ?[]const u8 = null;
    var name: []const u8 = "";
    if (matched_value) |matched| {
        if (matched != .object) return error.InvalidActPayload;
        const r = matched.object.get("ref") orelse return error.InvalidActPayload;
        const n = matched.object.get("name") orelse return error.InvalidActPayload;
        if (r != .string or n != .string) return error.InvalidActPayload;
        ref = r.string;
        name = n.string;
    }
    // wait 의 「같은 로케이터로 act 하면 여럿」(W9b②-3) — true 일 때만 싣는다.
    const ambiguous = if (parsed.value.object.get("ambiguous")) |a| a == .bool and a.bool else false;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    writeActMatched(&s, id, ok.bool, ref, name, ambiguous, dialog) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn writeActHint(s: *std.json.Stringify, id: cp.Id, hint: []const u8) !void {
    try beginResult(s, id);
    try s.objectField("ok");
    try s.write(false);
    try s.objectField("hint");
    try s.write(hint);
    try endResult(s);
}

fn writeActMatched(s: *std.json.Stringify, id: cp.Id, ok: bool, ref: ?[]const u8, name: []const u8, ambiguous: bool, dialog: bool) !void {
    try beginResult(s, id);
    try s.objectField("ok");
    try s.write(ok);
    if (ref) |r| {
        try s.objectField("matched");
        try s.beginObject();
        try s.objectField("ref");
        try s.write(r);
        try s.objectField("name");
        try s.write(name);
        try s.endObject();
    }
    if (ambiguous) {
        try s.objectField("ambiguous");
        try s.write(true);
    }
    if (dialog) {
        try s.objectField("dialog");
        try s.write(true);
    }
    try endResult(s);
}

/// act 결과 `{"ok":<bool>}`(click/type/scroll — ok=요소 발견+동작). Swift eval의 boolean 반환을 실는다. caller free.
pub fn serializeOkBoolResult(gpa: std.mem.Allocator, id: cp.Id, ok: bool) std.mem.Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    (writeOkBoolResult(&s, id, ok)) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn writeOkBoolResult(s: *std.json.Stringify, id: cp.Id, ok: bool) !void {
    try beginResult(s, id);
    try s.objectField("ok");
    try s.write(ok);
    try endResult(s);
}

// ── ② dispatchBrowser(§9.1 ②③ — 정확한 보안 순서) ─────────────────────────────────────────────────────────

/// **5e: 모든 게이트(authz·params·surface)를 통과한 인가된 browser 요청의 실행 op.** L4가 main-loop marshal
/// (§5-async deferRequest) → Swift `BrowserControl`이 `webPanels[surface_id]`의 WKWebView API를 호출한다. `arg`는
/// method별 인자(navigate=url·executeScript=`{script,args,max_result_bytes}` JSON·getUrl=빈) — `gpa` 소유 슬라이스라(파싱 arena와
/// 수명 분리) caller가 op를 소비할 때 free한다(§9.3 "arg는 cross_gpa 복사"). 응답 id/method는 L4가 완료 시
/// pending.request_bytes를 재파싱해 얻으므로(§9.3 ⑥) op엔 실행에 필요한 surface_id·method·arg만 싣는다.
pub const BrowserOp = struct {
    surface_id: u64,
    method: BrowserMethod,
    /// gpa-owned(caller가 free). navigate=url·executeScript=backend JSON·getUrl=빈("").
    arg: []const u8,
    /// null=capability가 직접 인가. non-null=pane-bound confirm grant가 인가한 op. 장기 wait revoke가 capability-origin
    /// 요청을 잘못 취소하지 않도록 provenance를 보존한다(짧은 기존 op의 실행 의미는 바꾸지 않음).
    pane_grant: ?GrantProvenance = null,
    /// capability-origin이면 실제 인가에 사용된 raw nonce의 값 복사. 장기 실행 callback에서 현재 revoke/TTL을
    /// 재검사한다. pane grant origin이면 null이다.
    capability_nonce: ?capmod.Nonce = null,
    capability_generation: ?u64 = null,
    /// executeScript가 실행 전에 예약할 선언 결과 바이트. 다른 method는 0.
    max_result_bytes: usize = 0,
};

pub const GrantProvenance = struct {
    pane: u64,
    target: u64,
    scope: capmod.ScopeClass,
    /// 인가한 grant 의 번호(`PaneGrant.id` — W9c①: Chromium 콘솔이 같은 허락으로 읽는 쪽을 알아본다). 0 은 모름.
    id: u64 = 0,
    /// `browser_storage` grant 가 인가한 호스트. 실행 직전(L4)과 Swift 가 쿠키 저장소를 만지기 직전에 대상 문서가 아직 이
    /// 호스트(또는 하위 도메인)인지 다시 본다 — dispatch 와 실행 사이에 탭이 다른 사이트로 가는 경쟁을 막는다.
    host: cpg.GrantHost = .{},
};

/// 대상 web surface 문서의 지금 호스트(collector snapshot 의 URL — http(s) 가 아니면 null).
pub fn targetHost(snapshot: cs.CollectorSnapshot, target_id: u64) ?[]const u8 {
    const dto = snapshot.find(target_id) orelse return null;
    return switch (dto.detail) {
        .web => |w| cpg.hostOfUrl(w.url orelse return null),
        else => null,
    };
}

/// `browser.subscribe`의 인가·검증 통과 결과(5f-0b-3b): 대상 web surface + 이벤트 필터. async op이 아니라 L4가
/// SubscriberRegistry에 **동기 등록**할 지시(연결 outbound는 L4가 pending에서 가져와 주입).
pub const BrowserSubscribe = struct {
    surface_id: u64,
    filter: cev.EventFilter,
};

/// 1e-confirm-1c: 세션 cap도 pane grant도 인가 못 했으나 **valid한**(존재하는 web surface + 유효 메서드) 요청이라,
/// pane이 확인 모달로 grant받으면 통과 가능(§9.2 Model B). L4가 §5-async로 붙잡고 모달을 띄운다(1c-2) — 승인 시
/// `grants.grant(이 셋)` 후 요청 재구동, 거부 시 unauthorized. **`pane_selector`가 있을 때만** 방출(grant는 pane
/// 신원에 묶임 — self-origin 없는 caller는 prompt 대상 아님=균일 unauthorized로 접힘, prompt 스팸·§8.3 oracle 방지).
pub const GrantRequest = struct {
    pane: u64, // 요청 pane의 selector surface_id(grant 귀속)
    target: u64, // 제어 대상 web surface_id
    scope: capmod.ScopeClass, // browser | browser_storage(methodRequiredScope 판정)
};

/// dispatchBrowser 결과: 게이트 실패면 응답 바이트(`err`, gpa-owned), async op은 `op`, 동기 구독은 `subscribe`(5f-0b-3b),
/// 미grant valid 요청은 `needs_grant`(1e-confirm-1c). **정확히 하나**만 유효.
pub const BrowserDispatch = union(enum) {
    err: []u8,
    op: BrowserOp,
    subscribe: BrowserSubscribe,
    needs_grant: GrantRequest,
};

/// `browser.*` 요청 한 줄(ndjson frame, 개행 제외)을 주입 snapshot + 주입 `caller_caps`(세션 누적 cap **집합**)로 처리한다.
/// 게이트 실패면 `.err`(응답 바이트, gpa-owned), 통과면 `.op`(인가·유효한 실행 op — L4가 marshal). OOM만 error로 전파.
/// caller가 `.err` 또는 `.op.arg`를 free한다.
///
/// `caller_caps`는 라이브 서버(L4)가 소켓 세션의 각 nonce(auth.self + auth.grant 누적)를 1e `lookupByNonce`해 넘긴
/// `Capability` **집합**(빈=cap 없음, 5f-4a §9.5.6 ③ — **하나라도** 인가하면 통과, 각 cap은 single-scope 유지).
/// authz는 `requested_surface_id=target id`(cap이 이 web surface에 묶였는지), `requested_generation=cap.generation`.
/// **browser cap의 anchor는 selector(에이전트 자기 surface)가 아니라 target(제어 대상 web surface)** — dispatchAuthenticated가
/// browser.*를 이 함수로 위임하며 selector 앵커를 안 쓴다(§9.3). `now`는 TTL 판정 시각.
///
/// **보안 순서(§8.3·§9.1 ②③ — 각 단계 정확히, 모듈 헤더 §보안 불변식):**
///   1. parseMessage → request 아니면 `invalid_request`(id=null). parse 실패 → `parseFailureCode`.
///   2. parseMethod. `core != .browser`면 `method_not_found`(방어 — 라우팅상 안 옴).
///   3. `id` 파싱(params `id`=u64). 형식 오류 → `invalid_params`(authz가 target을 알아야 먼저; 형식 오류는 oracle 아님).
///   4. **authz** — 세션 cap 중 하나라도 `authorize(cap, id, cap.generation, method, now)` granted면 통과. 아니면
///      **4b. pane confirm-grant 조회**(§9.2 Model B, 1e-confirm — `grants.hasGrant(pane_selector, id, scope)`, 가법).
///      둘 다 아니면 authorized=false로 두고 **최종 판정은 순서 6**으로 미룬다(valid web surface면 needs_grant, 아니면
///      균일 `unauthorized`). deny 이유 노출 금지.
///   5. `parseBrowserMethod(method.rest)`. null(screenshot 등 5a 미구현) → `method_not_found`(authz 뒤 — 미인가
///      caller가 메서드 탐침 못 하게). subscribe는 여기서 분기(surface·authz 뒤 필터 파싱).
///   6. **surface 검증 + authz 최종 판정 — params 파싱 앞**(§8.3 oracle 방지, subscribe 분기와 동일 불변식). snapshot에서
///      `id`로 SurfaceDto 찾기: 없거나 `detail != .web`이면 `unauthorized`(존재 누설 금지·browser cap은 web 전용).
///      미grant valid(존재 web surface)면 needs_grant(확인 대기), 미인가면 균일 `unauthorized`. **미인가 caller는 여기서
///      접혀 params를 파싱당하지 않는다**(malformed params로 스키마를 탐침하는 oracle 차단).
///   7. method별 params 파싱(url/script). 오류 → `invalid_params`(인가된 caller만 도달 — oracle 아님). url/script는 gpa로 dupe(op.arg).
///   8. **op 반환(5e)** — 여기까지 통과 = 인가·유효. `BrowserOp{surface_id, method, arg(dupe)}`. L4가 실행.
pub fn dispatchBrowser(
    gpa: std.mem.Allocator,
    request_bytes: []const u8,
    snapshot: cs.CollectorSnapshot,
    caller_caps: []const capmod.Capability,
    pane_selector: ?u64,
    grants: *const cpg.PaneGrantStore,
    now: u64,
) std.mem.Allocator.Error!BrowserDispatch {
    // ── 1. parse. 실패는 JSON-RPC 관례대로 id=null 에러 응답으로 접는다(OOM만 전파). ──
    var pm = cp.parseMessage(gpa, request_bytes) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .err = try errorResponse(gpa, .null, cp.parseFailureCode(e)) },
    };
    defer pm.deinit();

    // browser.*는 응답에 request id가 필요하므로 request만 디스패치한다(비-request → invalid_request, 1d와 동일).
    const req = switch (pm.message) {
        .request => |r| r,
        else => return .{ .err = try errorResponse(gpa, .null, .invalid_request) },
    };
    return browserOpFromRequest(gpa, req, request_bytes, snapshot, caller_caps, pane_selector, grants, now);
}

/// dispatchBrowser의 **파싱된 req** 버전(steps 2~8). `dispatchAuthenticated`(1e)가 이미 파싱한 req로 직접 호출해
/// 이중 파싱을 피한다(리뷰 [10] 정신). dispatchBrowser는 parse 후 이걸 부른다. `req.params`/`req.method` 슬라이스는
/// 호출자 parseMessage arena를 빌리므로 이 함수는 그 수명 안에서 즉시 처리하고 op.arg만 gpa-dupe로 분리한다.
pub fn browserOpFromRequest(
    gpa: std.mem.Allocator,
    req: cp.Request,
    request_bytes: []const u8,
    snapshot: cs.CollectorSnapshot,
    caller_caps: []const capmod.Capability,
    /// 요청 pane의 surface_id — 1g(§8.4)가 붙은 프로세스의 출처에서 찾은 pane(셀렉터가 아니다). pane confirm-grant 조회 키. null=pane 을 못 찾음=grant 조회 불가.
    pane_selector: ?u64,
    /// pane-bound confirm-grant 저장소(§9.2 Model B). 세션 cap이 인가 못 할 때 가법 조회(1e-confirm-1b).
    grants: *const cpg.PaneGrantStore,
    now: u64,
) std.mem.Allocator.Error!BrowserDispatch {
    // ── 2. parseMethod 라우팅(§4.1). 방어: 라우터가 browser.* 만 이 함수로 보내지만, core != browser면 거부. ──
    const method = cp.parseMethod(req.method);
    if (method.core != .browser) return .{ .err = try errorResponse(gpa, req.id, .method_not_found) };

    // ── W9b③: browser.open 은 대상 탭이 없다 — 부른 pane(1g)이 대상이다. pane 을 못 찾았으면(cap 만 든 연결 포함) 균일
    //    unauthorized, 확인 모달 없음(사용자 결정 — pane 신원만). params 는 pane 이 확인된 뒤에만 푼다(§8.3 oracle 불변식). ──
    if (eq(method.rest, "open")) {
        const pane = pane_selector orelse return .{ .err = try errorResponse(gpa, req.id, .unauthorized) };
        const p = parseOpenParams(req.params) catch return .{ .err = try errorResponse(gpa, req.id, .invalid_params) };
        return .{ .op = .{ .surface_id = pane, .method = .open, .arg = try serializeOpenArg(gpa, p) } };
    }

    // ── 3. id 파싱(target web surface_id). authz(4)가 target을 알아야 하므로 먼저. 형식 오류는 surface 존재
    //       oracle이 아니라 요청 형식 오류다(session.get과 동일) → invalid_params. ──
    const target_id = readIdParam(req.params) catch return .{ .err = try errorResponse(gpa, req.id, .invalid_params) };

    // ── 4. authz(§8.3 균일 unauthorized — 존재검사 이전, deny 이유 절대 노출 금지). **5f-4a cap 누적**(§9.5.6 ③):
    //       세션 보유 cap 중 **하나라도** target+method를 인가하면 통과(각 cap은 single-scope이나 세션은 다중 cap 보유 —
    //       navigate=browser·getCookies=browser_storage가 각기 다른 cap으로 인가). 아무 cap도 없으면 균일 unauthorized. ──
    var authorized = false;
    var pane_grant: ?GrantProvenance = null;
    for (caller_caps) |cap| {
        switch (capmod.authorize(cap, target_id, cap.generation, req.method, now)) {
            .granted => {
                authorized = true;
                break;
            },
            .deny => {}, // 이 cap은 인가 못 함 → 다음 cap 시도(oracle 방지=이유 안 노출)
        }
    }
    // ── 4b. 1e-confirm(§9.2 Model B): 세션 cap이 인가 못 하면 **pane confirm-grant** 조회(가법 — 22차 [1] 정합).
    //       grant는 서버가 찾은 pane 신원(pane_selector — 1g)에 묶인 (pane, target, scope). scope는 methodRequiredScope로
    //       판정(browser.getCookies=browser_storage·나머지 browser.*=browser). **behavior-preserving**: grant 없으면
    //       (빈 store 포함) 기존과 동일 균일 unauthorized. needs_grant/held-request 흐름(미grant면 확인 대기)은 1e-confirm-1c. ──
    const req_scope = capmod.methodRequiredScope(req.method); // cap authz·grant 조회·needs_grant 공용(browser.*=browser|browser_storage)
    if (!authorized) {
        if (req_scope) |sc| {
            if (pane_selector) |pane| {
                // browser_storage 는 grant 호스트가 대상 문서의 지금 호스트를 덮어야 한다(사이트에 묶인 쿠키 권한). 안 덮으면
                // 아래에서 needs_grant — 모달이 새 사이트를 묻는다.
                if (grants.authorizes(pane, target_id, sc, targetHost(snapshot, target_id))) {
                    authorized = true;
                    pane_grant = .{ .pane = pane, .target = target_id, .scope = sc, .id = grants.idOf(pane, target_id, sc).?, .host = grants.hostOf(pane, target_id, sc).? };
                }
            }
        }
    }
    // **1e-confirm-1c**: 여기서 !authorized여도 **즉시 unauthorized로 접지 않는다** — 유효 메서드·존재하는 web surface면
    // needs_grant(확인 대기)를 방출해야 하므로, method 파싱(5)·surface 검증(7)까지 진행 후 최종 판정한다. authz 실패의
    // 최종 처리는 각 분기 말미(subscribe·step 8)의 `ungrantedResult`(pane 있으면 needs_grant·없으면 균일 unauthorized).
    // invalid 메서드→method_not_found·invalid surface→unauthorized는 authorized 무관하게 그대로 접힌다(oracle: 미grant도
    // 존재하는 web surface에 대해서만 prompt·나머지는 균일 err — self-authenticated pane 한정, §9.2·§8.3 트레이드오프).

    // ── 5. BrowserMethod 파싱. 5a 미구현(screenshot 등) → method_not_found(authorized 무관 — 메서드명은 공개 API라 oracle 아님). ──
    // execute_script params 사전 검증(id 길이·args wire)은 surface·authz 게이트 **뒤**(step 7)로 미룬다 — 미인가 caller가
    // malformed params로 invalid_params를 유도해 파라미터 스키마를 탐침하지 못하게(§8.3 oracle, subscribe와 같은 규율).
    const bmethod = parseBrowserMethod(method.rest) orelse return .{ .err = try errorResponse(gpa, req.id, .method_not_found) };

    // ── 5f-0b-3b: subscribe는 async op이 아니라 동기 registry 구독. 필터 파싱(6) + surface 검증(7) 후 `.subscribe` 반환
    //    (arg dupe 없음 — 필터는 값 타입). 나머지(navigate/getUrl/executeScript)는 아래 async-op 경로. ──
    if (bmethod == .subscribe) {
        // surface 검증·authz-fail을 **필터 파싱 앞**으로(1e-confirm-1c): 미인가 caller가 events 값으로 invalid_params를
        // 유도해 필터 vocabulary를 탐침 못 하게(§8.3 oracle — 20차 [0] "authz 뒤 필터 파싱" 불변식 유지). 존재 검증
        // 먼저 → 없음/비-web=unauthorized, 미grant valid=needs_grant(확인 대기), 인가됨만 필터 파싱.
        const sub_dto = snapshot.find(target_id);
        if (sub_dto == null or sub_dto.?.kind() != .web) return .{ .err = try errorResponse(gpa, req.id, .unauthorized) };
        if (unsupportedOnSurface(sub_dto.?, bmethod)) |w| return .{ .err = try unsupportedByEngineResponse(gpa, req.id, w.engine, w.controllable) };
        if (!authorized) return ungrantedResult(gpa, req.id, pane_selector, target_id, req_scope); // 미grant valid subscribe → 확인 대기(필터 미파싱)
        const filter = parseSubscribeFilter(req.params) catch return .{ .err = try errorResponse(gpa, req.id, .invalid_params) };
        return .{ .subscribe = .{ .surface_id = target_id, .filter = filter } };
    }

    // ── 6. surface 검증 + authz 최종 판정을 **params 파싱 앞**으로(subscribe 분기와 동일 불변식 — §8.3 oracle 방지).
    //       없음/비-web → 균일 unauthorized(존재 누설 금지). 미grant valid(존재하는 web surface)면 needs_grant(확인 대기,
    //       params 미파싱 — 1e-confirm-1c). 인가된 caller만 아래 params 파싱에 도달하므로 그 형식 오류(invalid_params)는
    //       인가된 자에게만 보여 oracle이 아니다. 예전엔 이 게이트가 params 파싱 **뒤**라, 미인가 caller의 malformed params가
    //       invalid_params로 답해 파라미터 스키마를 탐침당했다(리뷰 — subscribe는 막았으나 일반 경로가 규율을 놓침). ──
    const dto = snapshot.find(target_id);
    if (dto == null or dto.?.kind() != .web) return .{ .err = try errorResponse(gpa, req.id, .unauthorized) };
    // W9-0: 엔진이 지원하지 않는 메서드는 확인 모달 **전에** 답한다(예전엔 승인 뒤 실행 단계에서 실패해, 사용자가 허용을 눌러도
    // 에이전트는 실패를 받았다).
    if (unsupportedOnSurface(dto.?, bmethod)) |w| return .{ .err = try unsupportedByEngineResponse(gpa, req.id, w.engine, w.controllable) };
    // W9b②: 로케이터(`locator`)는 Chromium 만 — 키가 있는지만 본다(인가 전에는 params 값을 풀지 않는다 — §8.3 oracle 불변식).
    if (locatorUnsupported(dto.?, bmethod, req.params)) |w| return .{ .err = try unsupportedByEngineParamResponse(gpa, req.id, w.engine, w.controllable, "locator") };
    // W9b③: close 는 그 pane 이 연 탭만 — 여는 순간 넣은 grant 가 없으면 확인 모달로 묻지 않고 거절한다(남의 탭을 닫으려고 허락을 묻지 않는다).
    if (!authorized and bmethod == .close) return .{ .err = try errorResponse(gpa, req.id, .unauthorized) };
    if (!authorized) return ungrantedResult(gpa, req.id, pane_selector, target_id, req_scope);

    // ── 7. execute_script params 사전 검증(id 길이·args wire). 이제 authorized만 도달하므로 invalid_params가 oracle 아님. ──
    if (bmethod == .execute_script and req.id == .string and req.id.string.len > execute_script_request_id_max_bytes) {
        return .{ .err = try errorResponse(gpa, req.id, .invalid_params) };
    }
    if (bmethod == .execute_script and !try validExecuteScriptArgsWire(gpa, request_bytes)) {
        return .{ .err = try errorResponse(gpa, req.id, .invalid_params) };
    }

    // ── 8. method별 params 파싱 + arg(url/script) dupe(파싱 arena와 수명 분리 — op는 pm.deinit 뒤에도 유효해야). ──
    // execute_script의 max_result_bytes는 arg 파싱(아래) 때 함께 잡아 재파싱을 피한다(이전엔 여기·op 반환·서버 재파싱 3번).
    // execute_script가 아니면 0. 여기까지 왔으면 인가·유효 web surface라 파싱 실패만 남는다.
    var exec_max_result_bytes: usize = 0;
    const arg: []const u8 = switch (bmethod) {
        .navigate => try gpa.dupe(u8, (parseNavigateParams(req.params) catch return .{ .err = try errorResponse(gpa, req.id, .invalid_params) }).url),
        .get_url => try gpa.dupe(u8, ""), // {id}만 — 인자 없음(빈 슬라이스도 dupe해 free 규약 일관)
        .get_cookies => try gpa.dupe(u8, ""), // {id}만 — Swift가 대상 surface 현재 문서 host의 쿠키를 읽음(22차 [0] host 필터, 인자 없음)
        // screenshot: rect/scale를 compact JSON으로 arg에 실어 Swift가 WKSnapshotConfiguration 구성(둘 다 부재면 `{}`=전체 뷰·기기 배율). PNG 고정.
        .screenshot => try serializeScreenshotArg(gpa, parseScreenshotOptParams(req.params) catch return .{ .err = try errorResponse(gpa, req.id, .invalid_params) }),
        .execute_script => blk: {
            const p = parseExecuteScriptParams(req.params) catch return .{ .err = try errorResponse(gpa, req.id, .invalid_params) };
            exec_max_result_bytes = p.max_result_bytes; // 아래 step 8에서 재파싱 없이 재사용
            break :blk try serializeExecuteScriptBackendArg(gpa, p.script, p.args, p.max_result_bytes);
        },
        // cookie write: 쿠키 필드를 compact JSON으로 arg에 실어 Swift가 파싱(§9.4 D4). 파싱 슬라이스는 arena를 빌리나 serialize가 owned JSON 생성.
        .set_cookie => try serializeSetCookieArg(gpa, parseSetCookieParams(req.params) catch return .{ .err = try errorResponse(gpa, req.id, .invalid_params) }),
        .delete_cookie => try serializeDeleteCookieArg(gpa, parseDeleteCookieParams(req.params) catch return .{ .err = try errorResponse(gpa, req.id, .invalid_params) }),
        // localStorage: get/remove arg=`{key}`, set arg=`{key,value}`(Swift가 eval 백엔드로 실행). clear는 {id}만=빈 arg.
        .get_local_storage, .remove_local_storage => try serializeKeyArg(gpa, (parseKeyParams(req.params) catch return .{ .err = try errorResponse(gpa, req.id, .invalid_params) }).key, null),
        .set_local_storage => blk: {
            const p = parseSetLocalStorageParams(req.params) catch return .{ .err = try errorResponse(gpa, req.id, .invalid_params) };
            break :blk try serializeKeyArg(gpa, p.key, p.value);
        },
        .clear_storage => try gpa.dupe(u8, ""), // {id}만 — Swift가 대상 origin 데이터를 WKWebsiteDataStore로 삭제(인자 없음)
        // act(5f-2·snapshot-2): click/scroll arg=`{selector|ref}`, type arg=`{selector|ref,text}`(Swift가 eval로 실행). base browser scope.
        .click, .scroll, .hover => try serializeActArg(gpa, (parseActParams(req.params) catch return .{ .err = try errorResponse(gpa, req.id, .invalid_params) }).locator, null),
        .press => try serializePressArg(gpa, parsePressParams(req.params) catch return .{ .err = try errorResponse(gpa, req.id, .invalid_params) }),
        .type_text => blk: {
            const p = parseTypeParams(req.params) catch return .{ .err = try errorResponse(gpa, req.id, .invalid_params) };
            break :blk try serializeActArg(gpa, p.locator, p.text);
        },
        .wait => try serializeWaitArg(gpa, parseWaitParams(req.params) catch return .{ .err = try errorResponse(gpa, req.id, .invalid_params) }),
        // snapshot(§9.5.4): interactive_only/max_depth/selector를 arg에 실어 Swift accname JS가 소비. base browser scope.
        .snapshot => try serializeSnapshotArg(gpa, parseSnapshotParams(req.params) catch return .{ .err = try errorResponse(gpa, req.id, .invalid_params) }),
        // console(§9.5.9): clear 플래그를 arg에 실어 Swift가 pull(서버 버퍼 반환 + clear면 비움). base browser scope.
        .console => try serializeConsoleArg(gpa, parseConsoleParams(req.params) catch return .{ .err = try errorResponse(gpa, req.id, .invalid_params) }),
        .back, .forward, .reload, .close => try gpa.dupe(u8, ""), // {id}만
        // W9c②: 대화상자 — 보기는 {id}만, 답하기는 `{accept, text?, dialog?}`.
        .dialog => blk: {
            parseDialogParams(req.params) catch return .{ .err = try errorResponse(gpa, req.id, .invalid_params) };
            break :blk try gpa.dupe(u8, "");
        },
        .handle_dialog => try serializeHandleDialogArg(gpa, parseHandleDialogParams(req.params) catch return .{ .err = try errorResponse(gpa, req.id, .invalid_params) }),
        // W9c③: 업로드 — `{선택자 필드, files}`. 확인 모달은 실행 계층이 매번 띄운다(여기서 인가된 것은 「그 탭을 다뤄도 된다」 뿐이다).
        .upload => try serializeUploadArg(gpa, parseUploadParams(req.params) catch return .{ .err = try errorResponse(gpa, req.id, .invalid_params) }),
        .subscribe => unreachable, // 위에서 이미 분기
        .open => unreachable, // 위(id 파싱 앞)에서 이미 분기
    };
    // arg는 이제 gpa-owned. surface·authz는 step 6에서 이미 접혔으므로(op 반환만 남음) 여기서 free할 실패 경로가 없다
    // — 파싱 실패는 switch 각 arm이 arg 할당 전 return하고, 여기 도달하면 곧장 op에 arg 소유권을 넘긴다.

    // ── 9. op 반환(5e·L4 marshal). 여기까지 = 인가·존재하는 web surface·유효 params. ──
    const max_result_bytes = exec_max_result_bytes; // 위 arg 파싱서 이미 잡음(execute_script 아니면 0)
    return .{ .op = .{
        .surface_id = target_id,
        .method = bmethod,
        .arg = arg,
        .pane_grant = pane_grant,
        .max_result_bytes = max_result_bytes,
    } };
}

/// 실행 전 aggregate 예산 부족. 정확한 사용량은 load oracle이 되므로 노출하지 않는다.
pub fn serializeResourceBusy(gpa: std.mem.Allocator, request_bytes: []const u8, resource: []const u8) std.mem.Allocator.Error![]u8 {
    var pm = cp.parseMessage(gpa, request_bytes) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return errorResponse(gpa, .null, .internal_error),
    };
    defer pm.deinit();
    const req = switch (pm.message) {
        .request => |r| r,
        else => return errorResponse(gpa, .null, .internal_error),
    };
    var data: std.json.ObjectMap = .empty;
    defer data.deinit(gpa);
    try data.put(gpa, "resource", .{ .string = resource });
    try data.put(gpa, "retryable", .{ .bool = true });
    return cp.serializeError(gpa, req.id, .resource_busy, cp.ErrorCode.resource_busy.defaultMessage(), .{ .object = data });
}

/// 인가 실패한 **valid**(유효 메서드·존재 web surface) browser 요청의 최종 판정(1e-confirm-1c). `pane_selector`가 있으면
/// `needs_grant`(pane이 확인 모달로 grant받을 수 있음), 없으면(self-origin 없는 caller) 균일 `unauthorized`. `req_scope`
/// null(방어 — browser.*는 항상 non-null)도 unauthorized. grant는 pane 신원에 묶이므로 pane 없이는 prompt 불가.
fn ungrantedResult(gpa: std.mem.Allocator, id: cp.Id, pane_selector: ?u64, target: u64, req_scope: ?capmod.ScopeClass) std.mem.Allocator.Error!BrowserDispatch {
    if (pane_selector) |pane| {
        if (req_scope) |sc| return .{ .needs_grant = .{ .pane = pane, .target = target, .scope = sc } };
    }
    return .{ .err = try errorResponse(gpa, id, .unauthorized) };
}

/// 코드의 default message로 에러 응답 한 줄을 만든다(1a `serializeError` 재사용). 편의 wrapper(1d와 동일).
fn errorResponse(gpa: std.mem.Allocator, id: cp.Id, code: cp.ErrorCode) std.mem.Allocator.Error![]u8 {
    return cp.serializeError(gpa, id, code, code.defaultMessage(), null);
}

// ══ ③ 테스트(헤드리스, Linux CI 포함 — 순수 로직·소켓/WKWebView 0) ═══════════════════════════════════════════
const testing = std.testing;
const wm = @import("window_membership.zig");

// fake collector snapshot: 창 1 = {10 terminal, 11 web(browser·untrusted)}. dispatchBrowser는 snapshot.find(id)만
// 쓰고 windows는 안 보지만(authz는 cap이 권위), CollectorSnapshot 계약상 windows를 채워 realism을 둔다.
const fx_surfaces = [_]cs.SurfaceDto{
    .{ .surface_id = 10, .title = "shell", .window = 1, .detail = .{ .terminal = .{ .at_prompt = .unknown } } },
    .{ .surface_id = 11, .title = "browser", .window = 1, .detail = .{ .web = .{ .url = "https://example/", .panel_kind = .browser, .loading = false, .trust = .untrusted, .controllable = true } } },
};
const fx_ids = [_]u64{ 10, 11 };
const fx_windows = [_]wm.WindowMembershipSnapshot{
    .{ .window_id = 1, .window_kind = .normal, .surface_ids = &fx_ids },
};
const fx: cs.CollectorSnapshot = .{ .surfaces = &fx_surfaces, .windows = &fx_windows };

// 유효 browser cap(web surface 11에 묶임). generation 0.
fn browserCap(sid: u64) capmod.Capability {
    return .{ .surface_id = sid, .generation = 0, .scope = .browser };
}

// 5f-4c: browser_storage cap(getCookies 전용 scope, §9.4 D5). browserCap과 surface는 같고 scope만 다르다.
fn browserStorageCap(sid: u64) capmod.Capability {
    return .{ .surface_id = sid, .generation = 0, .scope = .browser_storage };
}

// 5f-4a: 단일 cap(또는 null)을 dispatchBrowser의 cap **집합** 슬라이스로(누적 시그니처 테스트 어댑터). 슬라이스는 `buf`
// 수명 안에서만 유효(호출 중). null=빈 집합=cap 없음.
fn capsSlice(buf: *[1]capmod.Capability, cap: ?capmod.Capability) []const capmod.Capability {
    if (cap) |c| {
        buf[0] = c;
        return buf[0..1];
    }
    return &.{};
}

// 1e-confirm-1b: grant 없는 테스트용 빈 store(불변 공유). cap-only 경로는 pane grant 조회가 항상 false라 기존 동작 보존.
const no_grants: cpg.PaneGrantStore = .{};

// 게이트 실패(.err) 기대 — 응답 바이트(호출자 free). .op면 op.arg free 후 실패. cap-only(pane_selector=null·빈 grant).
fn dispatchErr(bytes: []const u8, cap: ?capmod.Capability) ![]u8 {
    var buf: [1]capmod.Capability = undefined;
    switch (try dispatchBrowser(testing.allocator, bytes, fx, capsSlice(&buf, cap), null, &no_grants, 0)) {
        .err => |e| return e,
        .op => |op| {
            testing.allocator.free(op.arg);
            return error.ExpectedErrGotOp;
        },
        .subscribe => return error.ExpectedErrGotSubscribe, // 이 헬퍼는 subscribe 요청 안 씀(navigate 등)
        .needs_grant => return error.ExpectedErrGotNeedsGrant, // pane_selector=null이라 needs_grant 안 나옴(균일 unauthorized로 접힘)
    }
}
// 게이트 통과(.op) 기대 — op(호출자 op.arg free). .err면 free 후 실패. cap-only(pane_selector=null·빈 grant).
fn dispatchOp(bytes: []const u8, cap: ?capmod.Capability) !BrowserOp {
    var buf: [1]capmod.Capability = undefined;
    switch (try dispatchBrowser(testing.allocator, bytes, fx, capsSlice(&buf, cap), null, &no_grants, 0)) {
        .op => |op| return op,
        .err => |e| {
            testing.allocator.free(e);
            return error.ExpectedOpGotErr;
        },
        .subscribe => return error.ExpectedOpGotSubscribe,
        .needs_grant => return error.ExpectedOpGotNeedsGrant,
    }
}

// 응답 바이트의 에러 코드를 뽑는다(성공이면 실패 단언).
fn errCode(wire: []const u8) !i64 {
    var pm = try cp.parseMessage(testing.allocator, wire);
    defer pm.deinit();
    try testing.expect(pm.message == .response);
    return pm.message.response.err.?.code;
}

// 응답 바이트의 에러 message를 뽑아 dupe(호출자 free). oracle: deny 이유가 message에 안 실림 확인용.
fn errMessage(wire: []const u8) ![]u8 {
    var pm = try cp.parseMessage(testing.allocator, wire);
    defer pm.deinit();
    try testing.expect(pm.message == .response);
    return testing.allocator.dupe(u8, pm.message.response.err.?.message);
}

// 자주 쓰는 요청 바이트.
const req_navigate_11 = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.navigate\",\"params\":{\"id\":11,\"url\":\"https://a/\"}}";

// ── 1) cap 없음(null) → unauthorized ──
test "dispatchBrowser: cap 없음(null) → 균일 unauthorized(-32002)" {
    const wire = try dispatchErr(req_navigate_11, null);
    defer testing.allocator.free(wire);
    try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.unauthorized)), try errCode(wire));
    // oracle: message는 균일 "Unauthorized"(deny 이유 노출 없음).
    const msg = try errMessage(wire);
    defer testing.allocator.free(msg);
    try testing.expectEqualStrings("Unauthorized", msg);
}

// ── 2) scope != browser → unauthorized(scope_insufficient가 균일 접힘) ──
test "dispatchBrowser: cap.scope가 browser 아님(metadata/lifecycle) → 균일 unauthorized" {
    // metadata cap(surface 11에 묶였지만 scope가 browser 아님) → authorize scope_insufficient → unauthorized.
    {
        const meta_cap: capmod.Capability = .{ .surface_id = 11, .generation = 0, .scope = .{ .metadata = .self } };
        const wire = try dispatchErr(req_navigate_11, meta_cap);
        defer testing.allocator.free(wire);
        try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.unauthorized)), try errCode(wire));
    }
    // lifecycle cap도 마찬가지.
    {
        const life_cap: capmod.Capability = .{ .surface_id = 11, .generation = 0, .scope = .lifecycle };
        const wire = try dispatchErr(req_navigate_11, life_cap);
        defer testing.allocator.free(wire);
        try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.unauthorized)), try errCode(wire));
    }
}

// ── 3) surface 불일치(web cap이 다른 surface) → unauthorized(surface_mismatch 균일) ──
test "dispatchBrowser: cap.surface_id != target id → 균일 unauthorized" {
    // browser cap이 surface 99에 묶였는데 target은 11 → authorize surface_mismatch → unauthorized.
    const wire = try dispatchErr(req_navigate_11, browserCap(99));
    defer testing.allocator.free(wire);
    try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.unauthorized)), try errCode(wire));
}

// ── 4) revoked / expired → unauthorized ──
test "dispatchBrowser: revoked cap → 균일 unauthorized" {
    var cap = browserCap(11);
    cap.revoked = true;
    const wire = try dispatchErr(req_navigate_11, cap);
    defer testing.allocator.free(wire);
    try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.unauthorized)), try errCode(wire));
}

test "dispatchBrowser: expired cap(now>=exp) → 균일 unauthorized" {
    var cap = browserCap(11);
    cap.expires_at = 100;
    // now=100 >= exp=100 → expired → unauthorized(균일, .err).
    switch (try dispatchBrowser(testing.allocator, req_navigate_11, fx, &[_]capmod.Capability{cap}, null, &no_grants, 100)) {
        .err => |wire| {
            defer testing.allocator.free(wire);
            try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.unauthorized)), try errCode(wire));
        },
        .op => |op| {
            testing.allocator.free(op.arg);
            return error.ExpectedErrGotOp;
        },
        .subscribe => unreachable, // navigate 요청이라 subscribe 안 옴
        .needs_grant => unreachable, // cap 있으니(만료 판정 대상) needs_grant 아님·pane=null
    }
    // 대조: now=99 < exp면 만료 아님 → 게이트 통과해 **op**라야 이 테스트가 만료를 실제로 검사.
    switch (try dispatchBrowser(testing.allocator, req_navigate_11, fx, &[_]capmod.Capability{cap}, null, &no_grants, 99)) {
        .op => |op| testing.allocator.free(op.arg),
        .err => |wire| {
            testing.allocator.free(wire);
            return error.ExpectedOpGotErr;
        },
        .subscribe => unreachable,
        .needs_grant => unreachable, // cap 유효(now<exp) → .op·pane=null
    }
}

// ── 5) 유효 browser cap + web surface target → **op 반환**(5e). 모든 게이트 통과 = 인가·유효한 실행 op.
test "dispatchBrowser: 유효 browser cap + web surface → BrowserOp{surface_id, navigate, url}(5e)" {
    const op = try dispatchOp(req_navigate_11, browserCap(11));
    defer testing.allocator.free(op.arg);
    try testing.expectEqual(@as(u64, 11), op.surface_id);
    try testing.expectEqual(BrowserMethod.navigate, op.method);
    try testing.expectEqualStrings("https://a/", op.arg); // navigate arg = url
    // getUrl은 arg 빈("").
    const op_url = try dispatchOp("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"browser.getUrl\",\"params\":{\"id\":11}}", browserCap(11));
    defer testing.allocator.free(op_url.arg);
    try testing.expectEqual(BrowserMethod.get_url, op_url.method);
    try testing.expectEqualStrings("", op_url.arg);
    // executeScript arg = Swift backend가 그대로 소비할 expression/args/cap JSON.
    const op_js = try dispatchOp("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"browser.executeScript\",\"params\":{\"id\":11,\"script\":\"Promise.resolve(args[0])\",\"args\":[\"document.title\"]}}", browserCap(11));
    defer testing.allocator.free(op_js.arg);
    try testing.expectEqual(BrowserMethod.execute_script, op_js.method);
    const parsed_arg = try std.json.parseFromSlice(std.json.Value, testing.allocator, op_js.arg, .{});
    defer parsed_arg.deinit();
    try testing.expectEqualStrings("Promise.resolve(args[0])", parsed_arg.value.object.get("script").?.string);
    try testing.expectEqualStrings("document.title", parsed_arg.value.object.get("args").?.array.items[0].string);
    try testing.expectEqual(execute_script_default_max_result_bytes, op_js.max_result_bytes);
}

// ── 5f-0b-3b: browser.subscribe — async op이 아니라 동기 `.subscribe`(surface + 필터). L4가 registry 등록. ──
test "dispatchBrowser(5f-0b-3b): 유효 browser cap + web surface → .subscribe{surface, filter}" {
    // events 없음 → 전체 필터.
    switch (try dispatchBrowser(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.subscribe\",\"params\":{\"id\":11}}", fx, &[_]capmod.Capability{browserCap(11)}, null, &no_grants, 0)) {
        .subscribe => |s| {
            try testing.expectEqual(@as(u64, 11), s.surface_id);
            try testing.expect(s.filter.wants(.navigated) and s.filter.wants(.load_state) and s.filter.wants(.dialog)); // all
        },
        .op => |op| {
            testing.allocator.free(op.arg);
            return error.ExpectedSubscribeGotOp;
        },
        .err => |e| {
            testing.allocator.free(e);
            return error.ExpectedSubscribeGotErr;
        },
        .needs_grant => return error.ExpectedSubscribeGotNeedsGrant, // cap 있으니 .subscribe(pane=null)
    }
    // events=["navigated","dialog"] → 그 둘만(loadState 제외).
    switch (try dispatchBrowser(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"browser.subscribe\",\"params\":{\"id\":11,\"events\":[\"navigated\",\"dialog\"]}}", fx, &[_]capmod.Capability{browserCap(11)}, null, &no_grants, 0)) {
        .subscribe => |s| {
            try testing.expect(s.filter.wants(.navigated) and s.filter.wants(.dialog));
            try testing.expect(!s.filter.wants(.load_state)); // 필터됨
        },
        .op => |op| {
            testing.allocator.free(op.arg);
            return error.ExpectedSubscribe;
        },
        .err => |e| {
            testing.allocator.free(e);
            return error.ExpectedSubscribe;
        },
        .needs_grant => return error.ExpectedSubscribe,
    }
}

test "dispatchBrowser(5f-0b-3b): subscribe 미지 event 이름 → invalid_params(인가된 caller만 — authz 뒤)" {
    const wire = try dispatchErr("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.subscribe\",\"params\":{\"id\":11,\"events\":[\"bogus\"]}}", browserCap(11));
    defer testing.allocator.free(wire);
    try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.invalid_params)), try errCode(wire));
}

test "dispatchBrowser(5f-0b-3b): subscribe도 cap 없으면 균일 unauthorized(§8.3 — 필터 파싱 이전)" {
    const wire = try dispatchErr("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.subscribe\",\"params\":{\"id\":11,\"events\":[\"bogus\"]}}", null);
    defer testing.allocator.free(wire);
    // cap 없음 → authz(step 4)서 unauthorized. bogus event도 안 노출(필터 파싱은 authz 뒤라 도달 안 함) = oracle 방지.
    try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.unauthorized)), try errCode(wire));
}

test "dispatchBrowser(5f-0b-3b): subscribe events:[] 빈 배열 → invalid_params(silent 무한대기 트랩 방지, 20차 [0])" {
    const wire = try dispatchErr("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.subscribe\",\"params\":{\"id\":11,\"events\":[]}}", browserCap(11));
    defer testing.allocator.free(wire);
    try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.invalid_params)), try errCode(wire));
}

test "dispatchBrowser(5f-0b-3b): subscribe events 중복 이름 → dedup되어 정상 .subscribe(길이 제한 없음, 20차 [1])" {
    // navigated 6회 반복(EventKind 5종보다 많음) — 옛 고정 5-버퍼면 invalid_params였으나 마스크 누적은 dedup해 정상.
    switch (try dispatchBrowser(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.subscribe\",\"params\":{\"id\":11,\"events\":[\"navigated\",\"navigated\",\"navigated\",\"navigated\",\"navigated\",\"navigated\"]}}", fx, &[_]capmod.Capability{browserCap(11)}, null, &no_grants, 0)) {
        .subscribe => |s| {
            try testing.expect(s.filter.wants(.navigated));
            try testing.expect(!s.filter.wants(.dialog)); // navigated만
        },
        .op => |op| {
            testing.allocator.free(op.arg);
            return error.ExpectedSubscribe;
        },
        .err => |e| {
            testing.allocator.free(e);
            return error.ExpectedSubscribeGotErr;
        },
        .needs_grant => return error.ExpectedSubscribeGotNeedsGrant,
    }
}

// ── 5f-4c: browser.getCookies — D5 browser_storage scope 게이트(핵심). ──
test "dispatchBrowser(5f-4c): browser_storage cap + getCookies → BrowserOp{get_cookies, arg=빈}" {
    // getCookies는 methodRequiredScope=browser_storage(D5) → browser_storage cap이 인가 → op(arg 없음, {id}만).
    const op = try dispatchOp("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.getCookies\",\"params\":{\"id\":11}}", browserStorageCap(11));
    defer testing.allocator.free(op.arg);
    try testing.expectEqual(@as(u64, 11), op.surface_id);
    try testing.expectEqual(BrowserMethod.get_cookies, op.method);
    try testing.expectEqualStrings("", op.arg);
}

test "dispatchBrowser(5f-4c) D5 게이트: browser cap은 getCookies 불인가 → 균일 unauthorized(쿠키=별도 scope)" {
    // base browser cap으로 getCookies 시도 → authorize scope_insufficient(browser != browser_storage) → unauthorized.
    // D5 핵심: 페이지를 몰 수 있는 cap이 쿠키(인증 토큰)까지 자동으로 새지 않는다.
    const wire = try dispatchErr("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.getCookies\",\"params\":{\"id\":11}}", browserCap(11));
    defer testing.allocator.free(wire);
    try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.unauthorized)), try errCode(wire));
}

test "dispatchBrowser(5f-4c) D5 대칭: browser_storage cap은 navigate 불인가 → 균일 unauthorized(single-scope)" {
    // 역방향: storage cap으로 navigate 시도 → browser_storage != browser → unauthorized. 각 cap은 single-scope라
    // 세션이 둘 다 쓰려면 cap 2개 누적(§9.5.6 ③ auth.grant — 5f-4a).
    const wire = try dispatchErr(req_navigate_11, browserStorageCap(11));
    defer testing.allocator.free(wire);
    try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.unauthorized)), try errCode(wire));
}

// ── 1e-confirm-1b: pane confirm-grant 합성 — cap 없어도 pane grant가 인가(§9.2 Model B, 가법). ──
// cap 0개 + pane_selector + grant store로 dispatchBrowser 호출하는 어댑터.
fn dispatchGrant(bytes: []const u8, pane: ?u64, grants: *const cpg.PaneGrantStore) !BrowserDispatch {
    return dispatchBrowser(testing.allocator, bytes, fx, &.{}, pane, grants, 0);
}

// 1e-confirm-1c: needs_grant 기대(+ pane·target·scope 확인). .err/.op/.subscribe면 실패(+정리).
fn expectNeedsGrant(bytes: []const u8, pane: ?u64, grants: *const cpg.PaneGrantStore, want_target: u64, want_scope: capmod.ScopeClass) !void {
    switch (try dispatchGrant(bytes, pane, grants)) {
        .needs_grant => |g| {
            try testing.expectEqual(pane.?, g.pane);
            try testing.expectEqual(want_target, g.target);
            try testing.expectEqual(want_scope, g.scope);
        },
        .err => |e| {
            testing.allocator.free(e);
            return error.ExpectedNeedsGrantGotErr;
        },
        .op => |op| {
            testing.allocator.free(op.arg);
            return error.ExpectedNeedsGrantGotOp;
        },
        .subscribe => return error.ExpectedNeedsGrantGotSubscribe,
    }
}

test "W9c①: pane grant 로 인가된 op 은 그 grant 의 번호를 싣는다 — 철회 뒤 다시 허용하면 다른 번호" {
    var grants: cpg.PaneGrantStore = .{};
    try grants.grant(.{ .pane = 5, .target = 9, .scope = .browser }); // 번호가 1 이 아니게 앞에 하나
    try grants.grant(.{ .pane = 5, .target = 11, .scope = .browser });
    const req = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.console\",\"params\":{\"id\":11}}";
    var first: u64 = 0;
    for (0..2) |round| {
        switch (try dispatchGrant(req, 5, &grants)) {
            .op => |op| {
                defer testing.allocator.free(op.arg);
                try testing.expectEqual(BrowserMethod.console, op.method);
                try testing.expectEqual(grants.idOf(5, 11, .browser).?, op.pane_grant.?.id);
                try testing.expect(op.pane_grant.?.id != 0);
                if (round == 0) first = op.pane_grant.?.id else try testing.expect(op.pane_grant.?.id != first);
            },
            .err => |e| {
                testing.allocator.free(e);
                return error.ExpectedOpGotErr;
            },
            .subscribe => return error.ExpectedOp,
            .needs_grant => return error.ExpectedOpGotNeedsGrant,
        }
        grants.revoke(5, 11, .browser);
        try grants.grant(.{ .pane = 5, .target = 11, .scope = .browser });
    }
}

test "dispatchBrowser(1e-confirm-1b): cap 없어도 pane grant가 browser.navigate 인가(가법)" {
    var grants: cpg.PaneGrantStore = .{};
    try grants.grant(.{ .pane = 5, .target = 11, .scope = .browser }); // pane 5 → web surface 11, browser
    // pane 5의 navigate(target 11) → cap 0개지만 grant가 인가 → .op.
    switch (try dispatchGrant(req_navigate_11, 5, &grants)) {
        .op => |op| {
            defer testing.allocator.free(op.arg);
            try testing.expectEqual(@as(u64, 11), op.surface_id);
            try testing.expectEqual(BrowserMethod.navigate, op.method);
            try testing.expectEqual(@as(u64, 5), op.pane_grant.?.pane);
            try testing.expectEqual(@as(u64, 11), op.pane_grant.?.target);
            try testing.expectEqual(capmod.ScopeClass.browser, op.pane_grant.?.scope);
        },
        .err => |e| {
            testing.allocator.free(e);
            return error.ExpectedOpGotErr;
        },
        .subscribe => return error.ExpectedOp,
        .needs_grant => return error.ExpectedOpGotNeedsGrant, // grant 있으니 .op(needs_grant 아님)
    }
}

// 1e-confirm-1c: 미grant(pane 있음·존재 web surface·유효 메서드)면 **needs_grant**(확인 대기). pane_selector 없거나
// surface가 없음/비-web이면 균일 unauthorized(oracle: prompt는 self-authenticated pane + 존재 web surface에만).
test "dispatchBrowser(1e-confirm-1c): 미grant valid 요청은 needs_grant, pane 없음/비-web은 unauthorized" {
    var grants: cpg.PaneGrantStore = .{};
    try grants.grant(.{ .pane = 5, .target = 11, .scope = .browser }); // pane 5만 grant 보유
    // 다른 pane(6): 그 pane엔 grant 없음 but valid → needs_grant{pane 6, target 11, browser}(pane 6이 확인받을 수 있음).
    try expectNeedsGrant(req_navigate_11, 6, &grants, 11, .browser);
    // scope 불일치: pane 5의 browser grant로 getCookies(browser_storage 요구) → 미grant → needs_grant{browser_storage}.
    try expectNeedsGrant("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.getCookies\",\"params\":{\"id\":11}}", 5, &grants, 11, .browser_storage);
    // pane_selector null(self-origin 없음) → grant 대상 아님 → 균일 unauthorized(needs_grant 아님·prompt 스팸 방지).
    {
        const w = (try dispatchGrant(req_navigate_11, null, &grants)).err;
        defer testing.allocator.free(w);
        try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.unauthorized)), try errCode(w));
    }
    // 미grant + **terminal surface(10, 비-web)** → surface 검증서 unauthorized(needs_grant 아님 — 존재하는 web에만 prompt).
    {
        const w = (try dispatchGrant("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.navigate\",\"params\":{\"id\":10,\"url\":\"u\"}}", 6, &grants)).err;
        defer testing.allocator.free(w);
        try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.unauthorized)), try errCode(w));
    }
}

test "dispatchBrowser(1e-confirm-1b): browser_storage grant는 getCookies만 인가·navigate는 needs_grant(scope 대칭)" {
    var grants: cpg.PaneGrantStore = .{};
    try grants.grant(.{ .pane = 5, .target = 11, .scope = .browser_storage, .host = cpg.GrantHost.init("example") }); // fixture 문서 https://example/ 에서 허용
    // getCookies(browser_storage) → 인가 → .op. provenance 가 허용 호스트를 싣는다(실행 직전 재확인용).
    switch (try dispatchGrant("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.getCookies\",\"params\":{\"id\":11}}", 5, &grants)) {
        .op => |op| {
            defer testing.allocator.free(op.arg);
            try testing.expectEqual(BrowserMethod.get_cookies, op.method);
            try testing.expectEqualStrings("example", op.pane_grant.?.host.slice());
        },
        .err => |e| {
            testing.allocator.free(e);
            return error.ExpectedOpGotErr;
        },
        .subscribe => return error.ExpectedOp,
        .needs_grant => return error.ExpectedOpGotNeedsGrant,
    }
    // navigate(browser) → storage grant로는 미grant(scope 불일치) → needs_grant{browser}(pane 5 확인 대기).
    try expectNeedsGrant(req_navigate_11, 5, &grants, 11, .browser);
}

test "dispatchBrowser(쿠키 권한은 사이트에): 다른 호스트에서 허용한 browser_storage grant 는 이 문서에 통하지 않는다 — needs_grant" {
    // 허용한 뒤 탭이 https://example/ 로 옮겨졌다(fixture) — 허용 호스트 github.com 이 덮지 않는다.
    var grants: cpg.PaneGrantStore = .{};
    try grants.grant(.{ .pane = 5, .target = 11, .scope = .browser_storage, .host = cpg.GrantHost.init("github.com") });
    try expectNeedsGrant("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.getCookies\",\"params\":{\"id\":11}}", 5, &grants, 11, .browser_storage);
    try expectNeedsGrant("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.clearStorage\",\"params\":{\"id\":11}}", 5, &grants, 11, .browser_storage);
    // 부모 도메인에서 허용했으면 통한다(하위 도메인 포함 — 사용자 결정).
    var parent: cpg.PaneGrantStore = .{};
    try parent.grant(.{ .pane = 5, .target = 11, .scope = .browser_storage, .host = cpg.GrantHost.init("EXAMPLE") });
    switch (try dispatchGrant("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.getCookies\",\"params\":{\"id\":11}}", 5, &parent)) {
        .op => |op| testing.allocator.free(op.arg),
        .err => |e| {
            testing.allocator.free(e);
            return error.ExpectedOpGotErr;
        },
        .subscribe => return error.ExpectedOp,
        .needs_grant => return error.ExpectedOpGotNeedsGrant,
    }
}

test "targetHost: web surface 의 http(s) 호스트만 — 없는 surface·비 web 은 null" {
    try testing.expectEqualStrings("example", targetHost(fx, 11).?);
    try testing.expect(targetHost(fx, 10) == null); // terminal
    try testing.expect(targetHost(fx, 99) == null);
}

// ── 6) 유효 cap + browser.screenshot(5f-1) → BrowserOp{screenshot, arg={}} ── screenshot도 browser scope, rect/scale 없으면 빈 옵션 `{}`.
test "dispatchBrowser(5f-1): 유효 browser cap + web surface → BrowserOp{screenshot, arg={}}" {
    // screenshot=browser.* → methodRequiredScope=.browser → authz granted → op(op_kind=5). Swift takeSnapshot→chunk 경로.
    const op = try dispatchOp("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.screenshot\",\"params\":{\"id\":11}}", browserCap(11));
    defer testing.allocator.free(op.arg);
    try testing.expectEqual(@as(u64, 11), op.surface_id);
    try testing.expectEqual(BrowserMethod.screenshot, op.method);
    try testing.expectEqualStrings("{}", op.arg); // rect/scale 부재 → 빈 옵션 객체(Swift가 전체 뷰·기기 배율)
}

// D5 대칭(방어): browser_storage cap은 screenshot 불인가(screenshot=browser scope). single-scope 유지 확인.
test "dispatchBrowser(5f-1) D5: browser_storage cap은 screenshot 불인가 → 균일 unauthorized" {
    const req = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.screenshot\",\"params\":{\"id\":11}}";
    const wire = try dispatchErr(req, browserStorageCap(11));
    defer testing.allocator.free(wire);
    try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.unauthorized)), try errCode(wire));
}

// 22차 리뷰 [1]: `parseBrowserMethod(rest) orelse method_not_found`(step 5) 경로 — screenshot 구현 후 dispatch 레벨
//   테스트가 사라졌다(옛 "screenshot 미구현→method_not_found"를 op 테스트로 교체). 모르는 메서드(예 `browser.pdf`)는 에이전트가
//   부르면 method_not_found여야 한다(authorized 무관 — 메서드명은 공개 API라 oracle 아님). 유효 cap이어도 이 접힘을 확인해 복원.
//   (back/forward/reload 는 W9b① 에서 구현됐다 — 아래 시험이 WebKit 탭의 -32008 을 본다.)
test "dispatchBrowser: 유효 cap + 미구현 browser 메서드(pdf) → method_not_found(-32601)" {
    const req = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.pdf\",\"params\":{\"id\":11}}";
    const wire = try dispatchErr(req, browserCap(11));
    defer testing.allocator.free(wire);
    try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.method_not_found)), try errCode(wire));
}

test "dispatchBrowser: WebKit 탭의 back·forward·reload·hover·press 는 cap 이 있어도 -32008(W9b① — Chromium 전용, WebKit 은 걷어낼 예정)" {
    for ([_][]const u8{ "back", "forward", "reload", "hover", "press" }) |m| {
        var buf: [128]u8 = undefined;
        const req = try std.fmt.bufPrint(&buf, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.{s}\",\"params\":{{\"id\":11}}}}", .{m});
        const wire = try dispatchErr(req, browserCap(11));
        defer testing.allocator.free(wire);
        try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.unsupported_by_engine)), try errCode(wire));
    }
}

// ── 7) 유효 cap + navigate params에 url 없음 → invalid_params ──
test "dispatchBrowser: 유효 cap + navigate params에 url 없음 → invalid_params(-32602)" {
    const req = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.navigate\",\"params\":{\"id\":11}}";
    const wire = try dispatchErr(req, browserCap(11));
    defer testing.allocator.free(wire);
    try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.invalid_params)), try errCode(wire));
}

// ── §8.3 oracle: 미인가 caller는 params가 malformed여도 invalid_params가 아니라 균일 unauthorized여야 한다. 위 테스트와
//    같은 malformed 요청이라도 cap이 없으면(미인가) surface·authz 게이트에서 접혀 params를 파싱당하지 않는다 — 미인가
//    caller가 malformed params/args로 파라미터 스키마를 탐침하는 oracle 차단(params 파싱을 authz 뒤로 옮긴 수정; subscribe
//    분기의 규율을 일반 경로에도 적용). 예전엔 params 파싱이 authz 앞이라 invalid_params가 새 스키마가 노출됐다(리뷰). ──
test "dispatchBrowser §8.3: 미인가 caller의 malformed params/args는 invalid_params가 아니라 균일 unauthorized(oracle 차단)" {
    // navigate: url 없음(위 테스트와 동일한 malformed navigate params) + cap 없음 → invalid_params가 아니라 unauthorized.
    {
        const wire = try dispatchErr("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.navigate\",\"params\":{\"id\":11}}", null);
        defer testing.allocator.free(wire);
        try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.unauthorized)), try errCode(wire));
        const msg = try errMessage(wire);
        defer testing.allocator.free(msg);
        try testing.expectEqualStrings("Unauthorized", msg); // 균일(deny 사유·존재 미노출)
    }
    // executeScript: args wire 부적합(unsafe integer -0). 인가됐다면 invalid_params(args wire 사전검증)지만, 미인가면 그
    // 사전검증 이전에 균일 unauthorized여야 한다(사전검증도 authz 뒤로 이동).
    {
        const wire = try dispatchErr("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.executeScript\",\"params\":{\"id\":11,\"script\":\"1\",\"args\":[-0]}}", null);
        defer testing.allocator.free(wire);
        try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.unauthorized)), try errCode(wire));
    }
}

// ── 8) 유효 cap + target이 terminal surface(cap도 그 terminal id에 묶임) → unauthorized(surface 검증 detail!=.web) ──
test "dispatchBrowser: target이 terminal surface면 authz 통과해도 surface 검증서 균일 unauthorized" {
    // cap이 terminal surface 10에 묶임(browser scope) → authorize granted(surface·scope 일치). 그러나 10은
    // terminal(detail=.terminal)이라 순서 7의 web 검증서 거부. browser cap은 web surface 전용(방어).
    const req = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.navigate\",\"params\":{\"id\":10,\"url\":\"https://a/\"}}";
    const wire = try dispatchErr(req, browserCap(10));
    defer testing.allocator.free(wire);
    try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.unauthorized)), try errCode(wire));
    // oracle: 여기도 균일 "Unauthorized"(terminal이라는 이유·존재를 노출하지 않음).
    const msg = try errMessage(wire);
    defer testing.allocator.free(msg);
    try testing.expectEqualStrings("Unauthorized", msg);
}

// ── 8b) §8.3 oracle: 모든 authz deny가 **바이트 동일** unauthorized(deny 이유·존재가 응답으로 안 샘) ──
test "dispatchBrowser §8.3: cap 부재·scope 불충족·surface 불일치·revoked가 전부 바이트 동일 unauthorized" {
    // 같은 요청 바이트(=같은 request id echo)에 서로 다른 deny 사유의 cap을 넣으면, 응답이 **바이트 동일**해야
    // deny 이유가 응답으로 새지 않는다(§8.3 균일 unauthorized oracle). 전부 순서 4에서 접힌다.
    const w_null = try dispatchErr(req_navigate_11, null); // cap 부재
    defer testing.allocator.free(w_null);
    const w_scope = try dispatchErr(req_navigate_11, capmod.Capability{ .surface_id = 11, .generation = 0, .scope = .{ .metadata = .self } }); // scope 불충족
    defer testing.allocator.free(w_scope);
    const w_surface = try dispatchErr(req_navigate_11, browserCap(99)); // surface 불일치
    defer testing.allocator.free(w_surface);
    var revoked = browserCap(11);
    revoked.revoked = true;
    const w_revoked = try dispatchErr(req_navigate_11, revoked); // revoked
    defer testing.allocator.free(w_revoked);

    try testing.expectEqualStrings(w_null, w_scope);
    try testing.expectEqualStrings(w_null, w_surface);
    try testing.expectEqualStrings(w_null, w_revoked);
    try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.unauthorized)), try errCode(w_null));
}

// ── 9a) parse/method 파서 단위 ──
test "parseBrowserMethod: 구현된 browser method 인식, 미지는 null" {
    try testing.expectEqual(BrowserMethod.navigate, parseBrowserMethod("navigate").?);
    try testing.expectEqual(BrowserMethod.get_url, parseBrowserMethod("getUrl").?);
    try testing.expectEqual(BrowserMethod.execute_script, parseBrowserMethod("executeScript").?);
    try testing.expectEqual(BrowserMethod.get_cookies, parseBrowserMethod("getCookies").?); // 5f-4c
    try testing.expectEqual(BrowserMethod.screenshot, parseBrowserMethod("screenshot").?); // 5f-1
    try testing.expectEqual(BrowserMethod.set_cookie, parseBrowserMethod("setCookie").?); // cookie write
    try testing.expectEqual(BrowserMethod.delete_cookie, parseBrowserMethod("deleteCookie").?);
    try testing.expectEqual(BrowserMethod.get_local_storage, parseBrowserMethod("getLocalStorage").?); // localStorage/clear
    try testing.expectEqual(BrowserMethod.set_local_storage, parseBrowserMethod("setLocalStorage").?);
    try testing.expectEqual(BrowserMethod.remove_local_storage, parseBrowserMethod("removeLocalStorage").?);
    try testing.expectEqual(BrowserMethod.clear_storage, parseBrowserMethod("clearStorage").?);
    try testing.expectEqual(BrowserMethod.click, parseBrowserMethod("click").?); // act 5f-2
    try testing.expectEqual(BrowserMethod.type_text, parseBrowserMethod("type").?);
    try testing.expectEqual(BrowserMethod.scroll, parseBrowserMethod("scroll").?);
    try testing.expectEqual(BrowserMethod.wait, parseBrowserMethod("wait").?);
    // W9b①: 방문 기록(Chromium 전용 — 엔진 판정은 dispatch 가 한다).
    try testing.expectEqual(BrowserMethod.back, parseBrowserMethod("back").?);
    try testing.expectEqual(BrowserMethod.forward, parseBrowserMethod("forward").?);
    try testing.expectEqual(BrowserMethod.reload, parseBrowserMethod("reload").?);
    try testing.expectEqual(BrowserMethod.hover, parseBrowserMethod("hover").?); // W9b①b-2
    try testing.expectEqual(BrowserMethod.press, parseBrowserMethod("press").?);
    // 미구현/미지 → null.
    try testing.expect(parseBrowserMethod("goBack") == null);
    try testing.expect(parseBrowserMethod("refresh") == null); // 옛 문서 표의 이름 — reload 다
    try testing.expect(parseBrowserMethod("get_url") == null); // snake_case는 wire 이름 아님(camelCase 엄수)
    try testing.expect(parseBrowserMethod("") == null);
    // parseMethod("browser.navigate").rest가 곧 parseBrowserMethod 입력임을 확인(1a와 결합).
    try testing.expectEqual(BrowserMethod.navigate, parseBrowserMethod(cp.parseMethod("browser.navigate").rest).?);
    try testing.expectEqual(BrowserMethod.execute_script, parseBrowserMethod(cp.parseMethod("browser.executeScript").rest).?);
}

// ── 9b) params 파서 단위(유효·오류) ──
test "params 파서: navigate·getUrl·executeScript expression와 args 유효/오류" {
    // 유효 파싱은 파싱된 Value에서 슬라이스를 빌리므로 pm(arena) 안에서 검증한다.
    {
        var pm = try cp.parseMessage(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.navigate\",\"params\":{\"id\":11,\"url\":\"https://a/b\"}}");
        defer pm.deinit();
        const p = try parseNavigateParams(pm.message.request.params);
        try testing.expectEqual(@as(u64, 11), p.id);
        try testing.expectEqualStrings("https://a/b", p.url);
    }
    {
        var pm = try cp.parseMessage(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.getUrl\",\"params\":{\"id\":7}}");
        defer pm.deinit();
        const p = try parseGetUrlParams(pm.message.request.params);
        try testing.expectEqual(@as(u64, 7), p.id);
    }
    {
        var pm = try cp.parseMessage(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.executeScript\",\"params\":{\"id\":3,\"script\":\"Promise.resolve(args[0]+1)\",\"args\":[41,{\"ok\":true}]}}");
        defer pm.deinit();
        const p = try parseExecuteScriptParams(pm.message.request.params);
        try testing.expectEqual(@as(u64, 3), p.id);
        try testing.expectEqualStrings("Promise.resolve(args[0]+1)", p.script);
        try testing.expectEqual(@as(usize, 2), p.args.len);
        try testing.expectEqual(@as(i64, 41), p.args[0].integer);
        try testing.expect(p.args[1].object.get("ok").?.bool);
        try testing.expectEqual(execute_script_default_max_result_bytes, p.max_result_bytes);
    }
    // 오류: url 없음, id 비정수, script 비문자열, params 부재/비객체.
    try testing.expectError(error.InvalidParams, parseNavigateParamsFromWire("{\"id\":11}")); // url 없음
    try testing.expectError(error.InvalidParams, parseNavigateParamsFromWire("{\"id\":\"x\",\"url\":\"u\"}")); // id 비정수
    try testing.expectError(error.InvalidParams, parseNavigateParamsFromWire("{\"id\":-1,\"url\":\"u\"}")); // id 음수
    try testing.expectError(error.InvalidParams, parseExecuteScriptParamsFromWire("{\"id\":3,\"script\":5}")); // script 비문자열
    try testing.expectError(error.InvalidParams, parseExecuteScriptParamsFromWire("{\"id\":3,\"script\":\"x\",\"args\":{}}"));
    try testing.expectError(error.InvalidParams, parseExecuteScriptParamsFromWire("{\"id\":3,\"script\":\"x\",\"args\":[9007199254740992]}"));
    try testing.expectError(error.InvalidParams, parseExecuteScriptParamsFromWire("{\"id\":3,\"script\":\"x\",\"args\":[9007199254740993.0]}"));
    try testing.expectError(error.InvalidParams, parseExecuteScriptParamsFromWire("{\"id\":3,\"script\":\"x\",\"args\":[9.007199254740993e15]}"));
    try testing.expectError(error.InvalidParams, parseExecuteScriptParamsFromWire("{\"id\":3,\"script\":\"x\",\"args\":[1e400]}"));
    try testing.expectError(error.InvalidParams, parseExecuteScriptParamsFromWire("{\"id\":3,\"script\":\"x\",\"max_result_bytes\":0}"));
    try testing.expectError(error.InvalidParams, parseExecuteScriptParamsFromWire("{\"id\":3,\"script\":\"x\",\"max_result_bytes\":268435457}"));
    try testing.expectError(error.InvalidParams, parseGetUrlParamsFromWire("{}")); // id 없음
}

test "executeScript args wire: float-form unsafe integer, negative zero, depth 129 거부" {
    const prefix = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.executeScript\",\"params\":{\"id\":3,\"script\":\"args\",\"args\":";
    const suffix = "}}";
    for ([_][]const u8{
        "[9007199254740993.0]",
        "[9.007199254740993e15]",
        "[-0]",
        "[-0.0]",
        "[-1e-400]",
        "[1e-400]",
    }) |args| {
        const wire = try std.mem.concat(testing.allocator, u8, &.{ prefix, args, suffix });
        defer testing.allocator.free(wire);
        try testing.expect(!try validExecuteScriptArgsWire(testing.allocator, wire));
    }
    const safe = try std.mem.concat(testing.allocator, u8, &.{ prefix, "[9007199254740991,9.007199254740991e15,0,0.5]", suffix });
    defer testing.allocator.free(safe);
    try testing.expect(try validExecuteScriptArgsWire(testing.allocator, safe));

    for ([_]struct { nesting: usize, valid: bool }{
        // 첫 `[`는 args 컨테이너라 depth에 포함하지 않는다. 그 안의 단일 arg가 128중첩이면 허용, 129면 거부.
        .{ .nesting = execute_script_args_max_depth + 1, .valid = true },
        .{ .nesting = execute_script_args_max_depth + 2, .valid = false },
    }) |case| {
        var deep: std.ArrayList(u8) = .empty;
        defer deep.deinit(testing.allocator);
        try deep.appendSlice(testing.allocator, prefix);
        try deep.appendNTimes(testing.allocator, '[', case.nesting);
        try deep.append(testing.allocator, '0');
        try deep.appendNTimes(testing.allocator, ']', case.nesting);
        try deep.appendSlice(testing.allocator, suffix);
        try testing.expectEqual(case.valid, try validExecuteScriptArgsWire(testing.allocator, deep.items));
    }
}

// params-only wire(객체 한 줄)를 파싱해 각 파서에 넘기는 테스트 헬퍼(arena 수명 안에서 파서 실행).
fn parseNavigateParamsFromWire(params_json: []const u8) !NavigateParams {
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, params_json, .{});
    defer parsed.deinit();
    return parseNavigateParams(parsed.value);
}
fn parseGetUrlParamsFromWire(params_json: []const u8) !GetUrlParams {
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, params_json, .{});
    defer parsed.deinit();
    return parseGetUrlParams(parsed.value);
}
fn parseExecuteScriptParamsFromWire(params_json: []const u8) !ExecuteScriptParams {
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, params_json, .{});
    defer parsed.deinit();
    return parseExecuteScriptParams(parsed.value);
}

// ── 9c) result 직렬화 단위(navigate {ok:true}·getUrl {url}·executeScript {result}) ──
test "result 직렬화: navigate {ok:true} — 완결 JSON-RPC 응답 한 줄" {
    const wire = try serializeNavigateResult(testing.allocator, .{ .number = 5 });
    defer testing.allocator.free(wire);
    try testing.expect(std.mem.indexOfScalar(u8, wire, '\n') == null); // 한 줄 불변식
    var pm = try cp.parseMessage(testing.allocator, wire);
    defer pm.deinit();
    try testing.expect(pm.message == .response);
    try testing.expect(cp.idEql(pm.message.response.id, .{ .number = 5 }));
    const result = pm.message.response.result.?.object;
    try testing.expect(result.get("ok").?.bool == true);
}

test "result 직렬화: getUrl {url} — url 문자열이 result에 실린다" {
    const wire = try serializeGetUrlResult(testing.allocator, .{ .number = 6 }, "https://x/y");
    defer testing.allocator.free(wire);
    var pm = try cp.parseMessage(testing.allocator, wire);
    defer pm.deinit();
    const result = pm.message.response.result.?.object;
    try testing.expectEqualStrings("https://x/y", result.get("url").?.string);
}

test "result 직렬화: executeScript {result:<value>} — 불투명 JSON 반환값이 실린다" {
    const wire = try serializeExecuteScriptResult(testing.allocator, .{ .number = 7 }, .{ .integer = 42 });
    defer testing.allocator.free(wire);
    var pm = try cp.parseMessage(testing.allocator, wire);
    defer pm.deinit();
    const result = pm.message.response.result.?.object;
    try testing.expectEqual(@as(i64, 42), result.get("result").?.integer);
}

test "result 직렬화(5f-4c): getCookies {cookies:[...]} — Swift JSON 배열이 구조화 embed(문자열 wrap 아님)" {
    // Swift가 준 쿠키 JSON 배열을 파싱해 result.cookies에 **진짜 배열**로 실린다(이중 파싱 불요).
    const cookies_json = "[{\"name\":\"sid\",\"value\":\"abc\",\"domain\":\"x.test\",\"path\":\"/\",\"secure\":true,\"httpOnly\":false}]";
    const wire = try serializeGetCookiesResult(testing.allocator, .{ .number = 9 }, cookies_json);
    defer testing.allocator.free(wire);
    try testing.expect(std.mem.indexOfScalar(u8, wire, '\n') == null); // 한 줄 불변식
    var pm = try cp.parseMessage(testing.allocator, wire);
    defer pm.deinit();
    const arr = pm.message.response.result.?.object.get("cookies").?.array; // 문자열이 아니라 배열
    try testing.expectEqual(@as(usize, 1), arr.items.len);
    const c0 = arr.items[0].object;
    try testing.expectEqualStrings("sid", c0.get("name").?.string);
    try testing.expectEqualStrings("abc", c0.get("value").?.string);
    try testing.expect(c0.get("secure").?.bool);
    // 빈 배열도 정상(쿠키 0개).
    const wire_empty = try serializeGetCookiesResult(testing.allocator, .{ .number = 1 }, "[]");
    defer testing.allocator.free(wire_empty);
    var pm2 = try cp.parseMessage(testing.allocator, wire_empty);
    defer pm2.deinit();
    try testing.expectEqual(@as(usize, 0), pm2.message.response.result.?.object.get("cookies").?.array.items.len);
}

test "result 직렬화(5f-4c): getCookies malformed/비-배열 payload → InvalidCookiesJson(Swift 버그 방어)" {
    try testing.expectError(error.InvalidCookiesJson, serializeGetCookiesResult(testing.allocator, .{ .number = 1 }, "{not json"));
    try testing.expectError(error.InvalidCookiesJson, serializeGetCookiesResult(testing.allocator, .{ .number = 1 }, "{\"cookies\":1}")); // 객체=비배열
    try testing.expectError(error.InvalidCookiesJson, serializeGetCookiesResult(testing.allocator, .{ .number = 1 }, "\"str\"")); // 문자열=비배열
}

// ── 10) dispatch 라우팅 엣지: 비-browser 메서드·비-request·malformed ──
test "dispatchBrowser: core != browser 방어 → method_not_found" {
    // 라우터가 browser.* 만 보내지만 방어적으로 확인 — session.get이 여기 오면 method_not_found.
    const wire = try dispatchErr("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"session.get\",\"params\":{\"id\":11}}", browserCap(11));
    defer testing.allocator.free(wire);
    try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.method_not_found)), try errCode(wire));
}

test "dispatchBrowser: 비-request(notification)·malformed·id 형식오류" {
    // notification(id 없음) → invalid_request.
    {
        const wire = try dispatchErr("{\"jsonrpc\":\"2.0\",\"method\":\"browser.navigate\",\"params\":{\"id\":11,\"url\":\"u\"}}", browserCap(11));
        defer testing.allocator.free(wire);
        try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.invalid_request)), try errCode(wire));
    }
    // malformed JSON → parse_error(id=null).
    {
        const wire = try dispatchErr("{not json", browserCap(11));
        defer testing.allocator.free(wire);
        var pm = try cp.parseMessage(testing.allocator, wire);
        defer pm.deinit();
        try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.parse_error)), pm.message.response.err.?.code);
        try testing.expect(pm.message.response.id == .null);
    }
    // id 형식오류(비정수)는 authz 이전이라 invalid_params(surface oracle 아님). cap 유효여도 형식이 먼저.
    {
        const wire = try dispatchErr("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.navigate\",\"params\":{\"id\":\"x\",\"url\":\"u\"}}", browserCap(11));
        defer testing.allocator.free(wire);
        try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.invalid_params)), try errCode(wire));
    }
}

// 5e-2b: serializeBrowserResponse — L4 completion이 request_bytes 재파싱해 method별 result/error를 실는다.
test "serializeBrowserResponse: navigate ok·getUrl url·executeScript result·error(id·method 재파싱)" {
    // navigate ok → {result:{ok:true}}, request id echo(7).
    {
        const w = try serializeBrowserResponse(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"browser.navigate\",\"params\":{\"id\":11,\"url\":\"u\"}}", true, "");
        defer testing.allocator.free(w);
        var pm = try cp.parseMessage(testing.allocator, w);
        defer pm.deinit();
        try testing.expect(pm.message.response.err == null);
        try testing.expect(pm.message.response.result.?.object.get("ok").?.bool);
        try testing.expect(cp.idEql(pm.message.response.id, .{ .number = 7 }));
    }
    // getUrl ok → {result:{url:<result>}}.
    {
        const w = try serializeBrowserResponse(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.getUrl\",\"params\":{\"id\":11}}", true, "https://x/y");
        defer testing.allocator.free(w);
        var pm = try cp.parseMessage(testing.allocator, w);
        defer pm.deinit();
        try testing.expectEqualStrings("https://x/y", pm.message.response.result.?.object.get("url").?.string);
    }
    // executeScript ok → 구조화 JSON 결과를 그대로 embed한다.
    {
        const w = try serializeBrowserResponse(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.executeScript\",\"params\":{\"id\":11,\"script\":\"document.title\"}}", true, "\"My Page\"");
        defer testing.allocator.free(w);
        var pm = try cp.parseMessage(testing.allocator, w);
        defer pm.deinit();
        try testing.expectEqualStrings("My Page", pm.message.response.result.?.object.get("result").?.string);
    }
    {
        const w = try serializeBrowserResponse(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.executeScript\",\"params\":{\"id\":11,\"script\":\"({a:1})\"}}", true, "{\"a\":1}");
        defer testing.allocator.free(w);
        var pm = try cp.parseMessage(testing.allocator, w);
        defer pm.deinit();
        try testing.expectEqual(@as(i64, 1), pm.message.response.result.?.object.get("result").?.object.get("a").?.integer);
    }
    {
        const w = try serializeBrowserResponse(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.executeScript\",\"params\":{\"id\":11,\"script\":\"bad\"}}", true, "not-json");
        defer testing.allocator.free(w);
        var pm = try cp.parseMessage(testing.allocator, w);
        defer pm.deinit();
        try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.internal_error)), pm.message.response.err.?.code);
    }
    // 요청별 max_result_bytes는 완료 경로에서 실제 JSON bytes에 적용된다.
    {
        const w = try serializeBrowserResponse(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"browser.executeScript\",\"params\":{\"id\":11,\"script\":\"1\",\"max_result_bytes\":1}}", true, "123");
        defer testing.allocator.free(w);
        var pm = try cp.parseMessage(testing.allocator, w);
        defer pm.deinit();
        const err = pm.message.response.err.?;
        try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.result_too_large)), err.code);
        try testing.expectEqual(@as(i64, 1), err.data.?.object.get("limit_bytes").?.integer);
        try testing.expectEqual(@as(i64, 2), err.data.?.object.get("observed_bytes_at_least").?.integer);
    }
    // ok=false → internal_error + result를 message로.
    {
        const w = try serializeBrowserResponse(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.navigate\",\"params\":{\"id\":11,\"url\":\"u\"}}", false, "webView not found");
        defer testing.allocator.free(w);
        var pm = try cp.parseMessage(testing.allocator, w);
        defer pm.deinit();
        try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.internal_error)), pm.message.response.err.?.code);
        try testing.expectEqualStrings("webView not found", pm.message.response.err.?.message);
    }
    // 5f-4c: getCookies ok → {result:{cookies:[...]}}(Swift JSON 배열을 result 재파싱해 embed).
    {
        const w = try serializeBrowserResponse(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"browser.getCookies\",\"params\":{\"id\":11}}", true, "[{\"name\":\"sid\",\"value\":\"v\"}]");
        defer testing.allocator.free(w);
        var pm = try cp.parseMessage(testing.allocator, w);
        defer pm.deinit();
        const arr = pm.message.response.result.?.object.get("cookies").?.array;
        try testing.expectEqualStrings("sid", arr.items[0].object.get("name").?.string);
    }
    // 5f-4c: getCookies ok지만 payload malformed(Swift 버그) → internal_error(균일, oracle 아님).
    {
        const w = try serializeBrowserResponse(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"browser.getCookies\",\"params\":{\"id\":11}}", true, "{not an array");
        defer testing.allocator.free(w);
        var pm = try cp.parseMessage(testing.allocator, w);
        defer pm.deinit();
        try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.internal_error)), pm.message.response.err.?.code);
    }
}

test "executeScript length-only errors retain string JSON-RPC id ownership through serialization" {
    const request = "{\"jsonrpc\":\"2.0\",\"id\":\"req-1\",\"method\":\"browser.executeScript\",\"params\":{\"id\":11,\"script\":\"1\",\"max_result_bytes\":8}}";
    const too_large = try serializeExecuteScriptObservedTooLarge(testing.allocator, request, 9);
    defer testing.allocator.free(too_large);
    var parsed_too_large = try cp.parseMessage(testing.allocator, too_large);
    defer parsed_too_large.deinit();
    try testing.expectEqualStrings("req-1", parsed_too_large.message.response.id.string);
    try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.result_too_large)), parsed_too_large.message.response.err.?.code);

    const inline_wire = try serializeExecuteScriptInlineTooLarge(testing.allocator, request);
    defer testing.allocator.free(inline_wire);
    var parsed_inline = try cp.parseMessage(testing.allocator, inline_wire);
    defer parsed_inline.deinit();
    try testing.expectEqualStrings("req-1", parsed_inline.message.response.id.string);
    try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.payload_too_large)), parsed_inline.message.response.err.?.code);
}

// ── 9d) screenshot(5f-1) chunk-streaming 직렬화·metadata·감지 단위(§9.5.7) ──

// 최소 유효 PNG 헤더(시그니처 8B + IHDR: len 13·"IHDR"·width 800·height 600). pngDimensions는 24B만 읽는다.
const test_png_800x600 = [_]u8{
    0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a, // 시그니처
    0x00, 0x00, 0x00, 0x0d, // IHDR length=13
    'I',  'H',  'D',  'R',
    0x00, 0x00, 0x03, 0x20, // width=800(BE)
    0x00, 0x00, 0x02, 0x58, // height=600(BE)
};

test "serializeScreenshotChunk: notification(capture_id·seq·base64), 한 줄·프레임<1MB, 라운드트립" {
    const raw = "\x89PNG\x0d\x0a\x1a\x0a raw bytes \xff\x00\xfe"; // 비-UTF8 포함 임의 바이너리
    const w = try serializeScreenshotChunk(testing.allocator, 42, 3, raw);
    defer testing.allocator.free(w);
    try testing.expect(std.mem.indexOfScalar(u8, w, '\n') == null); // 한 줄(ndjson frame 경계)
    try testing.expect(w.len < 1024 * 1024); // default_max_frame 미만
    var pm = try cp.parseMessage(testing.allocator, w);
    defer pm.deinit();
    const note = pm.message.notification; // id 없음 = notification
    try testing.expectEqualStrings(screenshot_chunk_method, note.method);
    const params = note.params.?.object;
    try testing.expectEqual(@as(i64, 42), params.get("capture_id").?.integer);
    try testing.expectEqual(@as(i64, 3), params.get("seq").?.integer);
    try testing.expectEqualStrings("base64", params.get("encoding").?.string);
    // data는 raw의 base64 — 디코드해 원문 복원(임의 바이트 안전 증명).
    const b64 = params.get("data").?.string;
    const decoder = std.base64.standard.Decoder;
    const decoded = try testing.allocator.alloc(u8, try decoder.calcSizeForSlice(b64));
    defer testing.allocator.free(decoded);
    try decoder.decode(decoded, b64);
    try testing.expectEqualSlices(u8, raw, decoded);
}

test "serializeScreenshotChunk: 512KiB raw 조각도 프레임<1MB(base64 팽창 여유)" {
    const raw = try testing.allocator.alloc(u8, screenshot_chunk_bytes); // 512KiB
    defer testing.allocator.free(raw);
    @memset(raw, 0xAB);
    const w = try serializeScreenshotChunk(testing.allocator, 1, 0, raw);
    defer testing.allocator.free(w);
    try testing.expect(w.len < 1024 * 1024); // 683KiB base64 + JSON 오버헤드 < 1MiB
}

test "serializeExecuteScriptChunk: request/result id·seq·base64-json과 frame 상한" {
    const raw = "{\"한글\":true}";
    const wire = try serializeExecuteScriptChunk(testing.allocator, .{ .number = 12 }, 99, 0, raw);
    defer testing.allocator.free(wire);
    try testing.expect(wire.len < cp.default_max_frame);
    var pm = try cp.parseMessage(testing.allocator, wire);
    defer pm.deinit();
    const p = pm.message.notification.params.?.object;
    try testing.expectEqual(@as(i64, 12), p.get("request_id").?.integer);
    try testing.expectEqual(@as(i64, 99), p.get("result_id").?.integer);
    try testing.expectEqual(@as(i64, 0), p.get("seq").?.integer);
    try testing.expectEqualStrings("base64-json", p.get("encoding").?.string);
    const oversized = try testing.allocator.alloc(u8, execute_script_chunk_bytes + 1);
    defer testing.allocator.free(oversized);
    try testing.expectError(error.ChunkTooLarge, serializeExecuteScriptChunk(testing.allocator, .{ .number = 1 }, 1, 0, oversized));
}

test "serializeResultChunk(§9.5.10): method-generic — snapshot은 browser.snapshotChunk, executeScript delegate는 executeScriptChunk 유지" {
    const raw = "{\"tree\":[{\"role\":\"button\"}]}";
    // snapshot 메서드로 직렬화 → browser.snapshotChunk notification, body는 동일(request_id/result_id/seq/base64-json).
    {
        const wire = try serializeResultChunk(testing.allocator, cp.browser_snapshot_chunk_method, .{ .number = 7 }, 3, 1, raw);
        defer testing.allocator.free(wire);
        try testing.expect(wire.len < cp.default_max_frame);
        var pm = try cp.parseMessage(testing.allocator, wire);
        defer pm.deinit();
        try testing.expectEqualStrings("browser.snapshotChunk", pm.message.notification.method);
        const p = pm.message.notification.params.?.object;
        try testing.expectEqual(@as(i64, 7), p.get("request_id").?.integer);
        try testing.expectEqual(@as(i64, 3), p.get("result_id").?.integer);
        try testing.expectEqual(@as(i64, 1), p.get("seq").?.integer);
        // base64 라운드트립.
        const b64 = p.get("data").?.string;
        const dec = try testing.allocator.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(b64));
        defer testing.allocator.free(dec);
        try std.base64.standard.Decoder.decode(dec, b64);
        try testing.expectEqualSlices(u8, raw, dec);
    }
    // executeScript delegate는 여전히 executeScriptChunk(byte-identical 유지 — 무회귀).
    {
        const wire = try serializeExecuteScriptChunk(testing.allocator, .{ .number = 7 }, 3, 1, raw);
        defer testing.allocator.free(wire);
        var pm = try cp.parseMessage(testing.allocator, wire);
        defer pm.deinit();
        try testing.expectEqualStrings("browser.executeScriptChunk", pm.message.notification.method);
    }
}

test "serializeExecuteScriptBackendArg: expression과 args와 page byte cap을 손실 없이 전달" {
    const args = [_]std.json.Value{ .{ .integer = 41 }, .{ .string = "한글" } };
    const wire = try serializeExecuteScriptBackendArg(testing.allocator, "Promise.resolve(args[0]+1)", &args, 1234);
    defer testing.allocator.free(wire);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, wire, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("Promise.resolve(args[0]+1)", parsed.value.object.get("script").?.string);
    try testing.expectEqual(@as(i64, 41), parsed.value.object.get("args").?.array.items[0].integer);
    try testing.expectEqualStrings("한글", parsed.value.object.get("args").?.array.items[1].string);
    try testing.expectEqual(@as(i64, 1234), parsed.value.object.get("max_result_bytes").?.integer);
}

test "executeScript script-error: typed data와 32 KiB frame 상한, malformed fallback" {
    const request = "{\"jsonrpc\":\"2.0\",\"id\":\"req-1\",\"method\":\"browser.executeScript\",\"params\":{\"id\":11,\"script\":\"1\"}}";
    const payload = "{\"kind\":\"serialization\",\"name\":\"TypeError\",\"message\":\"cycle\",\"stack\":\"s\",\"diagnostics_truncated\":false}";
    const wire = try serializeExecuteScriptScriptError(testing.allocator, request, payload);
    defer testing.allocator.free(wire);
    try testing.expect(wire.len <= execute_script_error_frame_max_bytes);
    var parsed = try cp.parseMessage(testing.allocator, wire);
    defer parsed.deinit();
    try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.script_error)), parsed.message.response.err.?.code);
    try testing.expectEqualStrings("serialization", parsed.message.response.err.?.data.?.object.get("kind").?.string);

    const malformed = try serializeExecuteScriptScriptError(testing.allocator, request, "[]");
    defer testing.allocator.free(malformed);
    var fallback = try cp.parseMessage(testing.allocator, malformed);
    defer fallback.deinit();
    const data = fallback.message.response.err.?.data.?.object;
    try testing.expectEqualStrings("execution", data.get("kind").?.string);
    try testing.expect(data.get("diagnostics_truncated").?.bool);
}

test "executeScript request id는 bounded diagnostic frame을 위해 1024 bytes로 제한" {
    const escaped_id = try testing.allocator.alloc(u8, execute_script_request_id_max_bytes * 6);
    defer testing.allocator.free(escaped_id);
    for (0..execute_script_request_id_max_bytes) |i| @memcpy(escaped_id[i * 6 ..][0..6], "\\u0001");
    const accepted_request = try std.fmt.allocPrint(testing.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":\"{s}\",\"method\":\"browser.executeScript\",\"params\":{{\"id\":11,\"script\":\"1\"}}}}", .{escaped_id});
    defer testing.allocator.free(accepted_request);
    const op = try dispatchOp(accepted_request, browserCap(11));
    testing.allocator.free(op.arg);

    const stack = try testing.allocator.alloc(u8, 23 * 1024);
    defer testing.allocator.free(stack);
    @memset(stack, 's');
    const diagnostic = try std.fmt.allocPrint(testing.allocator, "{{\"kind\":\"execution\",\"name\":\"Error\",\"message\":\"m\",\"stack\":\"{s}\",\"diagnostics_truncated\":false}}", .{stack});
    defer testing.allocator.free(diagnostic);
    const accepted_wire = try serializeExecuteScriptScriptError(testing.allocator, accepted_request, diagnostic);
    defer testing.allocator.free(accepted_wire);
    try testing.expect(accepted_wire.len <= execute_script_error_frame_max_bytes);

    const id = try testing.allocator.alloc(u8, execute_script_request_id_max_bytes + 1);
    defer testing.allocator.free(id);
    @memset(id, 'a');
    const request = try std.fmt.allocPrint(testing.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":\"{s}\",\"method\":\"browser.executeScript\",\"params\":{{\"id\":11,\"script\":\"1\"}}}}", .{id});
    defer testing.allocator.free(request);
    const wire = try dispatchErr(request, browserCap(11));
    defer testing.allocator.free(wire);
    try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.invalid_params)), try errCode(wire));
}

test "serializeExecuteScriptChunkedComplete: 원 request id와 result/seq/bytes를 terminal에 고정" {
    const request = "{\"jsonrpc\":\"2.0\",\"id\":12,\"method\":\"browser.executeScript\",\"params\":{\"surface_id\":1,\"script\":\"1\"}}";
    const wire = try serializeExecuteScriptChunkedComplete(testing.allocator, request, 99, 3, 1048577);
    defer testing.allocator.free(wire);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, wire, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(i64, 12), parsed.value.object.get("id").?.integer);
    const result = parsed.value.object.get("result").?.object;
    try testing.expectEqualStrings("chunked", result.get("transfer").?.string);
    try testing.expectEqual(@as(i64, 99), result.get("result_id").?.integer);
    try testing.expectEqual(@as(i64, 3), result.get("seq_total").?.integer);
    try testing.expectEqual(@as(i64, 1048577), result.get("bytes").?.integer);
    try testing.expectError(error.InvalidResultId, serializeExecuteScriptChunkedComplete(testing.allocator, request, -1, 0, 0));

    const prefix = "{\"jsonrpc\":\"2.0\",\"id\":\"";
    const suffix = "\",\"method\":\"browser.executeScript\",\"params\":{\"surface_id\":1,\"script\":\"1\"}}";
    const huge_request = try testing.allocator.alloc(u8, prefix.len + execute_script_terminal_wire_bytes + suffix.len);
    defer testing.allocator.free(huge_request);
    @memcpy(huge_request[0..prefix.len], prefix);
    @memset(huge_request[prefix.len .. prefix.len + execute_script_terminal_wire_bytes], 'x');
    @memcpy(huge_request[prefix.len + execute_script_terminal_wire_bytes ..], suffix);
    try testing.expectError(
        error.TerminalFrameTooLarge,
        serializeExecuteScriptChunkedComplete(testing.allocator, huge_request, 1, 1, 1),
    );
}

test "serializeScreenshotComplete: 최종 응답(capture_id·seq_total·bytes·width·height·format), id 재파싱 echo" {
    const req = "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"browser.screenshot\",\"params\":{\"id\":11}}";
    const w = try serializeScreenshotComplete(testing.allocator, req, 7, 5, 1234, .{ .width = 800, .height = 600 });
    defer testing.allocator.free(w);
    try testing.expect(std.mem.indexOfScalar(u8, w, '\n') == null);
    var pm = try cp.parseMessage(testing.allocator, w);
    defer pm.deinit();
    try testing.expect(cp.idEql(pm.message.response.id, .{ .number = 9 })); // 요청 id echo
    const r = pm.message.response.result.?.object;
    try testing.expectEqual(@as(i64, 7), r.get("capture_id").?.integer);
    try testing.expectEqual(@as(i64, 5), r.get("seq_total").?.integer);
    try testing.expectEqual(@as(i64, 1234), r.get("bytes").?.integer);
    try testing.expectEqual(@as(i64, 800), r.get("width").?.integer);
    try testing.expectEqual(@as(i64, 600), r.get("height").?.integer);
    try testing.expectEqualStrings("png", r.get("format").?.string);
}

test "pngDimensions: 0 크기 IHDR은 등록 전에 거부" {
    var header = [_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n', 0, 0, 0, 13, 'I', 'H', 'D', 'R', 0, 0, 0, 0, 0, 0, 0, 4 };
    try testing.expect(pngDimensions(&header) == null);
    header[19] = 3;
    header[23] = 0;
    try testing.expect(pngDimensions(&header) == null);
}

test "pngDimensions: 유효 PNG IHDR width/height 파싱, 비-PNG/짧은 바이트는 null" {
    const d = pngDimensions(&test_png_800x600).?;
    try testing.expectEqual(@as(u32, 800), d.width);
    try testing.expectEqual(@as(u32, 600), d.height);
    try testing.expect(pngDimensions("not a png at all yo") == null); // 시그니처 불일치
    try testing.expect(pngDimensions(test_png_800x600[0..20]) == null); // 24B 미만(IHDR 잘림)
    try testing.expect(pngDimensions("") == null); // 빈
    // 시그니처는 맞지만 IHDR 아님 → null.
    var bad = test_png_800x600;
    bad[12] = 'X'; // "IHDR" → "XHDR"
    try testing.expect(pngDimensions(&bad) == null);
}

test "isScreenshotRequest·parseScreenshotTargetId: screenshot 요청 감지 + 대상 surface_id" {
    const req = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.screenshot\",\"params\":{\"id\":11}}";
    try testing.expect(isScreenshotRequest(testing.allocator, req));
    try testing.expectEqual(@as(?u64, 11), parseScreenshotTargetId(testing.allocator, req));
    // 다른 browser 메서드·비-request는 false/null.
    try testing.expect(!isScreenshotRequest(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.navigate\",\"params\":{\"id\":11,\"url\":\"u\"}}"));
    try testing.expect(!isScreenshotRequest(testing.allocator, "not json"));
    try testing.expectEqual(@as(?u64, null), parseScreenshotTargetId(testing.allocator, "{\"jsonrpc\":\"2.0\",\"method\":\"browser.screenshot\"}")); // params 없음
}

test "serializeBrowserListResult(§9.6): web surface만 나열(터미널 제외), {id,url,title,panel_kind}" {
    // fx = 터미널 10 + web 11(browser, https://example/). browser.list은 11만.
    const w = try serializeBrowserListResult(testing.allocator, .{ .number = 1 }, fx);
    defer testing.allocator.free(w);
    var pm = try cp.parseMessage(testing.allocator, w);
    defer pm.deinit();
    const arr = pm.message.response.result.?.object.get("surfaces").?.array;
    try testing.expectEqual(@as(usize, 1), arr.items.len); // 터미널(10) 제외
    const o = arr.items[0].object;
    try testing.expectEqual(@as(i64, 11), o.get("id").?.integer);
    try testing.expectEqualStrings("https://example/", o.get("url").?.string);
    try testing.expectEqualStrings("browser", o.get("panel_kind").?.string);
}

// ── W9-0: 엔진별 지원 — 목록에 싣고, 지원하지 않으면 확인 모달 전에 답한다 ──

const fx_engine_surfaces = [_]cs.SurfaceDto{
    .{ .surface_id = 10, .title = "shell", .window = 1, .detail = .{ .terminal = .{ .at_prompt = .unknown } } },
    .{ .surface_id = 11, .title = "webkit", .window = 1, .detail = .{ .web = .{ .url = "https://example/", .panel_kind = .browser, .loading = false, .trust = .untrusted, .controllable = true } } },
    .{ .surface_id = 12, .title = "chromium", .window = 1, .detail = .{ .web = .{ .url = "https://example/", .panel_kind = .browser, .loading = false, .trust = .untrusted, .engine = .chromium, .controllable = true } } },
    // markdown 패널과 파일 HTML 뷰(panel_kind 는 browser 다) — 엔진은 webkit 이어도 browser.* 는 실행되지 않는다.
    .{ .surface_id = 13, .title = "readme", .window = 1, .detail = .{ .web = .{ .panel_kind = .markdown, .loading = false, .trust = .trusted, .controllable = false } } },
    .{ .surface_id = 14, .title = "page.html", .window = 1, .detail = .{ .web = .{ .panel_kind = .browser, .loading = false, .trust = .untrusted, .controllable = false } } },
};
const fx_engine_ids = [_]u64{ 10, 11, 12, 13, 14 };
const fx_engine_windows = [_]wm.WindowMembershipSnapshot{.{ .window_id = 1, .window_kind = .normal, .surface_ids = &fx_engine_ids }};
const fx_engine: cs.CollectorSnapshot = .{ .surfaces = &fx_engine_surfaces, .windows = &fx_engine_windows };

test "browserMethodWireName 은 parseBrowserMethod 의 역이다(모든 메서드)" {
    inline for (std.meta.fields(BrowserMethod)) |f| {
        const m: BrowserMethod = @enumFromInt(f.value);
        try testing.expectEqual(m, parseBrowserMethod(browserMethodWireName(m)).?);
    }
}

test "W9-0: browser.list 는 탭마다 엔진과 그 엔진이 지원하는 메서드를 싣는다" {
    const w = try serializeBrowserListResult(testing.allocator, .{ .number = 1 }, fx_engine);
    defer testing.allocator.free(w);
    var pm = try cp.parseMessage(testing.allocator, w);
    defer pm.deinit();
    const arr = pm.message.response.result.?.object.get("surfaces").?.array;
    try testing.expectEqual(@as(usize, 4), arr.items.len);
    const webkit = arr.items[0].object;
    try testing.expect(webkit.get("controllable").?.bool);
    try testing.expectEqualStrings("webkit", webkit.get("engine").?.string);
    // WebKit 은 W9 전의 것만(back·forward·reload·hover·press·open·close·dialog·handleDialog·upload 는 Chromium 전용 — WebKit 은 걷어낼 예정).
    try testing.expectEqual(@as(usize, std.meta.fields(BrowserMethod).len - 10), webkit.get("methods").?.array.items.len);
    try testing.expectEqualStrings("navigate", webkit.get("methods").?.array.items[0].string);
    const chromium = arr.items[1].object;
    try testing.expectEqualStrings("chromium", chromium.get("engine").?.string);
    // W9 단계마다 늘어난다 — W9b①a: 진짜 클릭·방문 기록, W9b①b: snapshot·type·scroll·wait·hover·press(enum 순서).
    const chromium_methods = chromium.get("methods").?.array.items;
    // W9b③: close 는 탭에(그 pane 이 연 탭), open 은 탭에 쓰지 않아 싣지 않는다. W9a①: navigate·getUrl·screenshot.
    // W9a③: 쿠키·localStorage·clearStorage. W9c②: 대화상자 보기·답하기. W9c①: console. W9c③: upload.
    const want_chromium = [_][]const u8{ "navigate", "getUrl", "executeScript", "getCookies", "screenshot", "setCookie", "deleteCookie", "getLocalStorage", "setLocalStorage", "removeLocalStorage", "clearStorage", "click", "type", "scroll", "wait", "snapshot", "console", "back", "forward", "reload", "hover", "press", "close", "dialog", "handleDialog", "upload" };
    try testing.expectEqual(want_chromium.len, chromium_methods.len);
    for (want_chromium, chromium_methods) |want, got| try testing.expectEqualStrings(want, got.string);
    // 브라우저 탭이 아닌 web 패널은 엔진이 webkit 이어도 메서드가 없다(예전엔 18개를 싣고 승인 뒤 실패했다).
    for (arr.items[2..4]) |item| {
        try testing.expectEqualStrings("webkit", item.object.get("engine").?.string);
        try testing.expect(!item.object.get("controllable").?.bool);
        try testing.expectEqual(@as(usize, 0), item.object.get("methods").?.array.items.len);
    }
}

test "W9-0: 엔진이 지원하지 않는 메서드는 확인 모달(needs_grant) 전에 unsupported_by_engine 으로 답한다" {
    var grants: cpg.PaneGrantStore = .{};
    // W9a 부터 navigate·exec, W9c① 부터 console 도 Chromium 이 받는다 — 아직 받지 않는 subscribe 로 본다.
    const sub12 = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.subscribe\",\"params\":{\"id\":12}}";
    for ([_][]const u8{sub12}) |bytes| {
        // pane 이 있어 WebKit 이었다면 확인 모달을 띄웠을 요청 — Chromium 탭이라 모달 없이 답한다.
        switch (try dispatchBrowser(testing.allocator, bytes, fx_engine, &.{}, 6, &grants, 0)) {
            .err => |e| {
                defer testing.allocator.free(e);
                try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.unsupported_by_engine)), try errCode(e));
                try testing.expect(std.mem.indexOf(u8, e, "\"engine\":\"chromium\"") != null);
            },
            else => return error.TestUnexpectedResult,
        }
    }
    // markdown 패널·파일 HTML 뷰도 확인 모달 전에 답한다 — `controllable:false` 로 이유를 싣는다.
    const others = [_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.navigate\",\"params\":{\"id\":13,\"url\":\"https://x/\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.subscribe\",\"params\":{\"id\":14}}",
    };
    for (others) |bytes| {
        switch (try dispatchBrowser(testing.allocator, bytes, fx_engine, &.{}, 6, &grants, 0)) {
            .err => |e| {
                defer testing.allocator.free(e);
                try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.unsupported_by_engine)), try errCode(e));
                try testing.expect(std.mem.indexOf(u8, e, "\"engine\":\"webkit\"") != null);
                try testing.expect(std.mem.indexOf(u8, e, "\"controllable\":false") != null);
            },
            else => return error.TestUnexpectedResult,
        }
    }
    // WebKit 탭은 그대로 확인 대기 — Chromium 탭의 navigate 도(W9a①).
    for ([_]u64{ 11, 12 }) |target| {
        const nav = try std.fmt.allocPrint(testing.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.navigate\",\"params\":{{\"id\":{d},\"url\":\"https://x/\"}}}}", .{target});
        defer testing.allocator.free(nav);
        switch (try dispatchBrowser(testing.allocator, nav, fx_engine, &.{}, 6, &grants, 0)) {
            .needs_grant => |g| try testing.expectEqual(target, g.target),
            .err => |e| {
                testing.allocator.free(e);
                return error.TestUnexpectedResult;
            },
            else => return error.TestUnexpectedResult,
        }
    }
    // 없는 id·터미널은 지금처럼 균일 unauthorized(엔진 응답이 존재 oracle 이 되지 않게 — 엔진은 web 탭에만 답한다).
    const absent = [_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.navigate\",\"params\":{\"id\":99,\"url\":\"https://x/\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.navigate\",\"params\":{\"id\":10,\"url\":\"https://x/\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.subscribe\",\"params\":{\"id\":10}}",
    };
    for (absent) |bytes| {
        switch (try dispatchBrowser(testing.allocator, bytes, fx_engine, &.{}, 6, &grants, 0)) {
            .err => |e| {
                defer testing.allocator.free(e);
                try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.unauthorized)), try errCode(e));
            },
            else => return error.TestUnexpectedResult,
        }
    }
}

test "W9b①b-2: Chromium 탭의 hover·press 는 op 으로 — press 는 key 필수(64 바이트까지)·대상은 없어도 된다" {
    var buf: [1]capmod.Capability = undefined;
    const caps = capsSlice(&buf, browserCap(12));
    const cases = [_]struct { req: []const u8, arg: ?[]const u8 }{
        .{ .req = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.hover\",\"params\":{\"id\":12,\"selector\":\"#h\"}}", .arg = "{\"selector\":\"#h\"}" },
        .{ .req = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.press\",\"params\":{\"id\":12,\"key\":\"Enter\"}}", .arg = "{\"key\":\"Enter\"}" },
        .{ .req = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.press\",\"params\":{\"id\":12,\"key\":\"Meta+a\",\"ref\":\"n5\"}}", .arg = "{\"key\":\"Meta+a\",\"ref\":\"n5\"}" },
        .{ .req = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.press\",\"params\":{\"id\":12}}", .arg = null },
        .{ .req = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.press\",\"params\":{\"id\":12,\"key\":\"\"}}", .arg = null },
        .{ .req = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.press\",\"params\":{\"id\":12,\"key\":\"" ++ "a" ** 65 ++ "\"}}", .arg = null },
        .{ .req = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.press\",\"params\":{\"id\":12,\"key\":\"a\",\"selector\":\"#a\",\"ref\":\"n1\"}}", .arg = null },
        .{ .req = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.hover\",\"params\":{\"id\":12}}", .arg = null },
    };
    for (cases) |c| switch (try dispatchBrowser(testing.allocator, c.req, fx_engine, caps, null, &no_grants, 0)) {
        .op => |op| {
            defer testing.allocator.free(op.arg);
            try testing.expectEqualStrings(c.arg.?, op.arg);
        },
        .err => |e| {
            defer testing.allocator.free(e);
            try testing.expect(c.arg == null);
            try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.invalid_params)), try errCode(e));
        },
        else => return error.TestUnexpectedResult,
    };
}

test "W9b②: role 로케이터는 Chromium 탭에서 op arg 로 — 모양·상한·배타는 invalid_params, WebKit 은 인가 전 -32008(param locator)" {
    var buf: [1]capmod.Capability = undefined;
    const ok_cases = [_]struct { req: []const u8, arg: []const u8 }{
        .{ .req = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.click\",\"params\":{\"id\":12,\"locator\":{\"role\":\"button\",\"name\":\"Save\",\"exact\":true,\"nth\":0}}}", .arg = "{\"locator\":{\"role\":\"button\",\"name\":\"Save\",\"exact\":true,\"nth\":0}}" },
        .{ .req = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.type\",\"params\":{\"id\":12,\"locator\":{\"role\":\"textbox\"},\"text\":\"hi\"}}", .arg = "{\"locator\":{\"role\":\"textbox\"},\"text\":\"hi\"}" },
        .{ .req = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.press\",\"params\":{\"id\":12,\"key\":\"Enter\",\"locator\":{\"role\":\"heading\",\"level\":2}}}", .arg = "{\"key\":\"Enter\",\"locator\":{\"role\":\"heading\",\"level\":2}}" },
        // W9b②-2 — text·label(exact 는 이름 없이도).
        .{ .req = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.click\",\"params\":{\"id\":12,\"locator\":{\"text\":\"Sign in\",\"exact\":true,\"nth\":1}}}", .arg = "{\"locator\":{\"text\":\"Sign in\",\"exact\":true,\"nth\":1}}" },
        .{ .req = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.type\",\"params\":{\"id\":12,\"locator\":{\"label\":\"Email\"},\"text\":\"a@b\"}}", .arg = "{\"locator\":{\"label\":\"Email\"},\"text\":\"a@b\"}" },
    };
    for (ok_cases) |c| switch (try dispatchBrowser(testing.allocator, c.req, fx_engine, capsSlice(&buf, browserCap(12)), null, &no_grants, 0)) {
        .op => |op| {
            defer testing.allocator.free(op.arg);
            try testing.expectEqualStrings(c.arg, op.arg);
        },
        .err => |e| {
            defer testing.allocator.free(e);
            return error.TestUnexpectedResult;
        },
        else => return error.TestUnexpectedResult,
    };
    const bad = [_][]const u8{
        "{\"id\":12,\"locator\":{\"role\":\"button\"},\"selector\":\"#b\"}", // 둘
        "{\"id\":12,\"locator\":\"button\"}",
        "{\"id\":12,\"locator\":{\"label\":\"\"}}", // 빈 라벨
        "{\"id\":12,\"locator\":{\"text\":\"a\",\"name\":\"b\"}}", // text 에 role 의 키
        "{\"id\":12,\"locator\":{\"text\":\"a\",\"label\":\"b\"}}", // 둘
        "{\"id\":12,\"locator\":{\"label\":1}}",
        "{\"id\":12,\"locator\":{\"role\":\"\"}}",
        "{\"id\":12,\"locator\":{\"role\":\"button\",\"exact\":true}}", // 이름 없는 exact
        "{\"id\":12,\"locator\":{\"role\":\"button\",\"nth\":-1}}",
        "{\"id\":12,\"locator\":{\"role\":\"button\",\"level\":101}}",
        "{\"id\":12,\"locator\":{\"role\":\"button\",\"bogus\":1}}",
    };
    for (bad) |params| {
        var req_buf: [256]u8 = undefined;
        const req = try std.fmt.bufPrint(&req_buf, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.click\",\"params\":{s}}}", .{params});
        switch (try dispatchBrowser(testing.allocator, req, fx_engine, capsSlice(&buf, browserCap(12)), null, &no_grants, 0)) {
            .err => |e| {
                defer testing.allocator.free(e);
                try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.invalid_params)), try errCode(e));
            },
            .op => |op| {
                testing.allocator.free(op.arg);
                return error.TestUnexpectedResult;
            },
            else => return error.TestUnexpectedResult,
        }
    }
    // WebKit 탭 — 인가(모달) 전에 -32008, 값은 보지 않는다(값이 틀려도 -32008 — 미인가 caller 에게 스키마를 알려 주지 않는다).
    var grants: cpg.PaneGrantStore = .{};
    for ([_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.click\",\"params\":{\"id\":11,\"locator\":{\"role\":\"button\"}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.scroll\",\"params\":{\"id\":11,\"locator\":42}}",
    }) |req| switch (try dispatchBrowser(testing.allocator, req, fx_engine, &.{}, 6, &grants, 0)) {
        .err => |e| {
            defer testing.allocator.free(e);
            try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.unsupported_by_engine)), try errCode(e));
            try testing.expect(std.mem.indexOf(u8, e, "\"param\":\"locator\"") != null);
            try testing.expect(std.mem.indexOf(u8, e, "\"engine\":\"webkit\"") != null);
        },
        else => return error.TestUnexpectedResult,
    };
}

test "W9b②: 로케이터로 찾은 act 의 결과는 {ok, matched{ref,name}} — 모양이 틀린 엔진 답은 internal_error" {
    const req = "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"browser.click\",\"params\":{\"id\":12,\"locator\":{\"role\":\"button\"}}}";
    const good = try serializeActMatchedResult(testing.allocator, .{ .number = 5 }, "{\"ok\":true,\"matched\":{\"ref\":\"n11\",\"name\":\"Save \\\"x\\\"\"}}");
    defer testing.allocator.free(good);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":5,\"result\":{\"ok\":true,\"matched\":{\"ref\":\"n11\",\"name\":\"Save \\\"x\\\"\"}}}", good);
    try testing.expectError(error.InvalidActPayload, serializeActMatchedResult(testing.allocator, .{ .number = 5 }, "{\"ok\":true}"));
    // 숨은 일치만 있었다 — {ok:false, hint}(W9b②-2).
    const hinted = try serializeActMatchedResult(testing.allocator, .{ .number = 5 }, "{\"ok\":false,\"hint\":\"1 matching element(s) are hidden\"}");
    defer testing.allocator.free(hinted);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":5,\"result\":{\"ok\":false,\"hint\":\"1 matching element(s) are hidden\"}}", hinted);
    try testing.expectError(error.InvalidActPayload, serializeActMatchedResult(testing.allocator, .{ .number = 5 }, "{\"ok\":false}"));
    try testing.expectError(error.InvalidActPayload, serializeActMatchedResult(testing.allocator, .{ .number = 5 }, "{nope"));
    _ = req;
}

test "W9-0: 실행 단계의 -32008 은 L2 와 같은 모양이다(원 요청의 id · engine)" {
    const w = try serializeUnsupportedByEngine(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":\"req-7\",\"method\":\"browser.navigate\",\"params\":{\"id\":12,\"url\":\"https://x/\"}}", .chromium);
    defer testing.allocator.free(w);
    var pm = try cp.parseMessage(testing.allocator, w);
    defer pm.deinit();
    const resp = pm.message.response;
    try testing.expectEqualStrings("req-7", resp.id.string);
    const e = resp.err.?;
    try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.unsupported_by_engine)), e.code);
    try testing.expectEqualStrings("chromium", e.data.?.object.get("engine").?.string);
    try testing.expect(e.data.?.object.get("controllable") == null);
    // L2 응답과 바이트가 같다.
    const l2 = try unsupportedByEngineResponse(testing.allocator, .{ .string = "req-7" }, .chromium, true);
    defer testing.allocator.free(l2);
    try testing.expectEqualStrings(l2, w);
}

// ── cookie write(§9.4 D4) params·arg·dispatch·응답 단위 ──

fn setCookieFromWire(params_json: []const u8) !SetCookieParams {
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, params_json, .{});
    defer parsed.deinit();
    return parseSetCookieParams(parsed.value);
}
fn deleteCookieFromWire(params_json: []const u8) !DeleteCookieParams {
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, params_json, .{});
    defer parsed.deinit();
    return parseDeleteCookieParams(parsed.value);
}

test "params: setCookie(필수 name/value·선택 domain/path/secure)·deleteCookie(name)·오류" {
    {
        var pm = try cp.parseMessage(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.setCookie\",\"params\":{\"id\":11,\"name\":\"sid\",\"value\":\"abc\",\"domain\":\"x.com\",\"path\":\"/a\",\"secure\":true}}");
        defer pm.deinit();
        const p = try parseSetCookieParams(pm.message.request.params);
        try testing.expectEqual(@as(u64, 11), p.id);
        try testing.expectEqualStrings("sid", p.name);
        try testing.expectEqualStrings("abc", p.value);
        try testing.expectEqualStrings("x.com", p.domain.?);
        try testing.expectEqualStrings("/a", p.path.?);
        try testing.expect(p.secure);
    }
    // 최소(name/value) → domain/path null·secure false.
    {
        var pm = try cp.parseMessage(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.setCookie\",\"params\":{\"id\":11,\"name\":\"n\",\"value\":\"v\"}}");
        defer pm.deinit();
        const p = try parseSetCookieParams(pm.message.request.params);
        try testing.expect(p.domain == null and p.path == null and !p.secure);
    }
    {
        var pm = try cp.parseMessage(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.deleteCookie\",\"params\":{\"id\":11,\"name\":\"n\"}}");
        defer pm.deinit();
        const p = try parseDeleteCookieParams(pm.message.request.params);
        try testing.expectEqualStrings("n", p.name);
        try testing.expect(p.domain == null);
    }
    try testing.expectError(error.InvalidParams, setCookieFromWire("{\"id\":1,\"value\":\"v\"}")); // name 없음
    try testing.expectError(error.InvalidParams, setCookieFromWire("{\"id\":1,\"name\":\"n\"}")); // value 없음
    try testing.expectError(error.InvalidParams, setCookieFromWire("{\"id\":1,\"name\":\"n\",\"value\":\"v\",\"secure\":\"yes\"}")); // secure 비-bool
    try testing.expectError(error.InvalidParams, deleteCookieFromWire("{\"id\":1}")); // name 없음
}

test "serializeSetCookieArg/DeleteCookieArg: compact JSON, 선택 필드 생략" {
    {
        const a = try serializeSetCookieArg(testing.allocator, .{ .id = 11, .name = "sid", .value = "abc", .domain = "x.com", .path = "/a", .secure = true });
        defer testing.allocator.free(a);
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, a, .{});
        defer parsed.deinit();
        const o = parsed.value.object;
        try testing.expectEqualStrings("sid", o.get("name").?.string);
        try testing.expectEqualStrings("abc", o.get("value").?.string);
        try testing.expectEqualStrings("x.com", o.get("domain").?.string);
        try testing.expect(o.get("secure").?.bool);
    }
    // domain/path 생략 → 키 부재.
    {
        const a = try serializeSetCookieArg(testing.allocator, .{ .id = 11, .name = "n", .value = "v", .domain = null, .path = null, .secure = false });
        defer testing.allocator.free(a);
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, a, .{});
        defer parsed.deinit();
        try testing.expect(parsed.value.object.get("domain") == null);
        try testing.expect(!parsed.value.object.get("secure").?.bool);
    }
    {
        const a = try serializeDeleteCookieArg(testing.allocator, .{ .id = 11, .name = "n", .domain = "x.com", .path = null });
        defer testing.allocator.free(a);
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, a, .{});
        defer parsed.deinit();
        try testing.expectEqualStrings("n", parsed.value.object.get("name").?.string);
        try testing.expectEqualStrings("x.com", parsed.value.object.get("domain").?.string);
        try testing.expect(parsed.value.object.get("path") == null);
    }
}

test "dispatchBrowser(cookie write): browser_storage cap + setCookie → op{set_cookie, arg JSON}; browser cap 불인가(D5)" {
    const op = try dispatchOp("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.setCookie\",\"params\":{\"id\":11,\"name\":\"n\",\"value\":\"v\"}}", browserStorageCap(11));
    defer testing.allocator.free(op.arg);
    try testing.expectEqual(BrowserMethod.set_cookie, op.method);
    try testing.expectEqual(@as(u64, 11), op.surface_id);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, op.arg, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("n", parsed.value.object.get("name").?.string); // arg=쿠키 필드 JSON
    // D5: browser cap은 setCookie 불인가(쿠키=browser_storage, laundering-hole 방지).
    const wire = try dispatchErr("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.setCookie\",\"params\":{\"id\":11,\"name\":\"n\",\"value\":\"v\"}}", browserCap(11));
    defer testing.allocator.free(wire);
    try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.unauthorized)), try errCode(wire));
}

test "serializeBrowserResponse(cookie write): setCookie → {ok:true}, id echo" {
    const w = try serializeBrowserResponse(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"browser.setCookie\",\"params\":{\"id\":11,\"name\":\"n\",\"value\":\"v\"}}", true, "");
    defer testing.allocator.free(w);
    var pm = try cp.parseMessage(testing.allocator, w);
    defer pm.deinit();
    try testing.expect(pm.message.response.result.?.object.get("ok").?.bool);
    try testing.expect(cp.idEql(pm.message.response.id, .{ .number = 3 }));
}

// ── localStorage/clear(§9.4 D4) params·arg·dispatch·응답 단위 ──

test "params: getLocalStorage {id,key}·setLocalStorage {id,key,value}·오류" {
    {
        var pm = try cp.parseMessage(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.getLocalStorage\",\"params\":{\"id\":11,\"key\":\"tok\"}}");
        defer pm.deinit();
        const p = try parseKeyParams(pm.message.request.params);
        try testing.expectEqual(@as(u64, 11), p.id);
        try testing.expectEqualStrings("tok", p.key);
    }
    {
        var pm = try cp.parseMessage(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.setLocalStorage\",\"params\":{\"id\":11,\"key\":\"k\",\"value\":\"v\"}}");
        defer pm.deinit();
        const p = try parseSetLocalStorageParams(pm.message.request.params);
        try testing.expectEqualStrings("k", p.key);
        try testing.expectEqualStrings("v", p.value);
    }
    // key 없음·value 없음 오류.
    {
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"id\":1}", .{});
        defer parsed.deinit();
        try testing.expectError(error.InvalidParams, parseKeyParams(parsed.value));
    }
    {
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"id\":1,\"key\":\"k\"}", .{});
        defer parsed.deinit();
        try testing.expectError(error.InvalidParams, parseSetLocalStorageParams(parsed.value)); // value 없음
    }
}

test "serializeKeyArg: {key} 또는 {key,value}, 라운드트립" {
    {
        const a = try serializeKeyArg(testing.allocator, "tok", null);
        defer testing.allocator.free(a);
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, a, .{});
        defer parsed.deinit();
        try testing.expectEqualStrings("tok", parsed.value.object.get("key").?.string);
        try testing.expect(parsed.value.object.get("value") == null);
    }
    {
        const a = try serializeKeyArg(testing.allocator, "k", "v");
        defer testing.allocator.free(a);
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, a, .{});
        defer parsed.deinit();
        try testing.expectEqualStrings("v", parsed.value.object.get("value").?.string);
    }
}

test "dispatchBrowser(localStorage): base browser cap + getLocalStorage → op{arg=key JSON}; clearStorage는 browser_storage" {
    // getLocalStorage=base browser scope(eval 백엔드) → browser cap으로 인가.
    const op = try dispatchOp("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.getLocalStorage\",\"params\":{\"id\":11,\"key\":\"tok\"}}", browserCap(11));
    defer testing.allocator.free(op.arg);
    try testing.expectEqual(BrowserMethod.get_local_storage, op.method);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, op.arg, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("tok", parsed.value.object.get("key").?.string);
    // clearStorage=browser_storage → browser_storage cap 인가, browser cap 불인가(D5 comprehensive clear=쿠키).
    const op2 = try dispatchOp("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.clearStorage\",\"params\":{\"id\":11}}", browserStorageCap(11));
    defer testing.allocator.free(op2.arg);
    try testing.expectEqual(BrowserMethod.clear_storage, op2.method);
    const wire = try dispatchErr("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.clearStorage\",\"params\":{\"id\":11}}", browserCap(11));
    defer testing.allocator.free(wire);
    try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.unauthorized)), try errCode(wire));
}

test "serializeBrowserResponse(localStorage): getLocalStorage → {value}, set/clear → {ok}" {
    {
        const w = try serializeBrowserResponse(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.getLocalStorage\",\"params\":{\"id\":11,\"key\":\"k\"}}", true, "hello");
        defer testing.allocator.free(w);
        var pm = try cp.parseMessage(testing.allocator, w);
        defer pm.deinit();
        try testing.expectEqualStrings("hello", pm.message.response.result.?.object.get("value").?.string);
    }
    {
        const w = try serializeBrowserResponse(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.clearStorage\",\"params\":{\"id\":11}}", true, "");
        defer testing.allocator.free(w);
        var pm = try cp.parseMessage(testing.allocator, w);
        defer pm.deinit();
        try testing.expect(pm.message.response.result.?.object.get("ok").?.bool);
    }
}

// ── act(5f-2) params·arg·dispatch·응답 단위 ──

test "params/arg: click/type locator selector·ref 배타·serializeActArg" {
    {
        var pm = try cp.parseMessage(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.click\",\"params\":{\"id\":11,\"selector\":\"#btn\"}}");
        defer pm.deinit();
        const p = try parseActParams(pm.message.request.params);
        try testing.expectEqualStrings("#btn", p.locator.selector);
    }
    // ref locator(§9.5.4 snapshot-2) — selector 대안.
    {
        var pm = try cp.parseMessage(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.click\",\"params\":{\"id\":11,\"ref\":\"e3\"}}");
        defer pm.deinit();
        const p = try parseActParams(pm.message.request.params);
        try testing.expectEqualStrings("e3", p.locator.ref);
    }
    {
        var pm = try cp.parseMessage(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.type\",\"params\":{\"id\":11,\"ref\":\"e5\",\"text\":\"hi\"}}");
        defer pm.deinit();
        const p = try parseTypeParams(pm.message.request.params);
        try testing.expectEqualStrings("e5", p.locator.ref);
        try testing.expectEqualStrings("hi", p.text);
    }
    // arg JSON: selector locator={selector}, ref locator={ref}(+text).
    {
        const a = try serializeActArg(testing.allocator, .{ .selector = "#btn" }, null);
        defer testing.allocator.free(a);
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, a, .{});
        defer parsed.deinit();
        try testing.expectEqualStrings("#btn", parsed.value.object.get("selector").?.string);
        try testing.expect(parsed.value.object.get("ref") == null);
        try testing.expect(parsed.value.object.get("text") == null);
    }
    {
        const a = try serializeActArg(testing.allocator, .{ .ref = "e7" }, "hi");
        defer testing.allocator.free(a);
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, a, .{});
        defer parsed.deinit();
        try testing.expectEqualStrings("e7", parsed.value.object.get("ref").?.string);
        try testing.expect(parsed.value.object.get("selector") == null);
        try testing.expectEqualStrings("hi", parsed.value.object.get("text").?.string);
    }
    // 오류: locator 없음(selector·ref 둘 다 부재), 둘 다 지정(배타 위반), text 없음.
    {
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"id\":1}", .{});
        defer parsed.deinit();
        try testing.expectError(error.InvalidParams, parseActParams(parsed.value));
    }
    {
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"id\":1,\"selector\":\"#x\",\"ref\":\"e1\"}", .{});
        defer parsed.deinit();
        try testing.expectError(error.InvalidParams, parseActParams(parsed.value)); // selector+ref 배타
    }
    {
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"id\":1,\"selector\":\"#x\"}", .{});
        defer parsed.deinit();
        try testing.expectError(error.InvalidParams, parseTypeParams(parsed.value)); // text 없음
    }
}

test "dispatchBrowser(act): base browser cap + click → op{click, arg=selector|ref JSON}" {
    {
        const op = try dispatchOp("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.click\",\"params\":{\"id\":11,\"selector\":\"#btn\"}}", browserCap(11));
        defer testing.allocator.free(op.arg);
        try testing.expectEqual(BrowserMethod.click, op.method);
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, op.arg, .{});
        defer parsed.deinit();
        try testing.expectEqualStrings("#btn", parsed.value.object.get("selector").?.string);
    }
    // ref locator(§9.5.4 snapshot-2) → op.arg에 {ref}(selector 없음). 같은 op_kind(12) 재사용.
    {
        const op = try dispatchOp("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.click\",\"params\":{\"id\":11,\"ref\":\"e2\"}}", browserCap(11));
        defer testing.allocator.free(op.arg);
        try testing.expectEqual(BrowserMethod.click, op.method);
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, op.arg, .{});
        defer parsed.deinit();
        try testing.expectEqualStrings("e2", parsed.value.object.get("ref").?.string);
        try testing.expect(parsed.value.object.get("selector") == null);
    }
}

test "serializeBrowserResponse(act): click result true/false → {ok:bool}" {
    // eval "true"(발견+클릭) → ok:true.
    {
        const w = try serializeBrowserResponse(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.click\",\"params\":{\"id\":11,\"selector\":\"#b\"}}", true, "true");
        defer testing.allocator.free(w);
        var pm = try cp.parseMessage(testing.allocator, w);
        defer pm.deinit();
        try testing.expect(pm.message.response.result.?.object.get("ok").?.bool);
    }
    // eval "false"(셀렉터 미매치) → ok:false.
    {
        const w = try serializeBrowserResponse(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.click\",\"params\":{\"id\":11,\"selector\":\"#x\"}}", true, "false");
        defer testing.allocator.free(w);
        var pm = try cp.parseMessage(testing.allocator, w);
        defer pm.deinit();
        try testing.expect(!pm.message.response.result.?.object.get("ok").?.bool);
    }
}

test "params/arg(§9.5.7): screenshot rect/scale 파싱·직렬화, 오류(부분 rect·비양수)" {
    // rect+scale 있음 → ScreenshotOptParams + arg JSON에 {rect:{x,y,width,height}, scale}.
    {
        var pm = try cp.parseMessage(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.screenshot\",\"params\":{\"id\":11,\"rect\":{\"x\":10,\"y\":20,\"width\":300,\"height\":400},\"scale\":0.5}}");
        defer pm.deinit();
        const p = try parseScreenshotOptParams(pm.message.request.params);
        try testing.expectEqual(@as(f64, 10), p.rect.?.x);
        try testing.expectEqual(@as(f64, 400), p.rect.?.height);
        try testing.expectEqual(@as(f64, 0.5), p.scale.?);
        const a = try serializeScreenshotArg(testing.allocator, p);
        defer testing.allocator.free(a);
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, a, .{});
        defer parsed.deinit();
        // 정수값 f64(300)는 "300"으로 직렬화돼 .integer로 파싱되므로 numF64FromObj로 관대 비교.
        try testing.expectEqual(@as(f64, 300), try numF64FromObj(parsed.value.object.get("rect").?.object, "width"));
        try testing.expectEqual(@as(f64, 0.5), try numF64FromObj(parsed.value.object, "scale"));
    }
    // 부재(=id만) → 빈 옵션, arg="{}"(rect/scale 필드 없음).
    {
        var pm = try cp.parseMessage(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.screenshot\",\"params\":{\"id\":11}}");
        defer pm.deinit();
        const p = try parseScreenshotOptParams(pm.message.request.params);
        try testing.expect(p.rect == null and p.scale == null);
        const a = try serializeScreenshotArg(testing.allocator, p);
        defer testing.allocator.free(a);
        try testing.expectEqualStrings("{}", a);
    }
    // 정수 좌표도 허용(JSON integer → f64).
    {
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"id\":1,\"rect\":{\"x\":0,\"y\":0,\"width\":100,\"height\":50}}", .{});
        defer parsed.deinit();
        const p = try parseScreenshotOptParams(parsed.value);
        try testing.expectEqual(@as(f64, 100), p.rect.?.width);
    }
    // 오류: 부분 rect(height 누락)·비양수 width·scale<=0.
    {
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"id\":1,\"rect\":{\"x\":0,\"y\":0,\"width\":10}}", .{});
        defer parsed.deinit();
        try testing.expectError(error.InvalidParams, parseScreenshotOptParams(parsed.value));
    }
    {
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"id\":1,\"rect\":{\"x\":0,\"y\":0,\"width\":0,\"height\":10}}", .{});
        defer parsed.deinit();
        try testing.expectError(error.InvalidParams, parseScreenshotOptParams(parsed.value));
    }
    {
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"id\":1,\"scale\":0}", .{});
        defer parsed.deinit();
        try testing.expectError(error.InvalidParams, parseScreenshotOptParams(parsed.value));
    }
}

test "dispatchBrowser(screenshot): base browser cap + rect/scale → op{screenshot, arg=rect/scale JSON}" {
    const op = try dispatchOp("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.screenshot\",\"params\":{\"id\":11,\"rect\":{\"x\":1,\"y\":2,\"width\":3,\"height\":4},\"scale\":2}}", browserCap(11));
    defer testing.allocator.free(op.arg);
    try testing.expectEqual(BrowserMethod.screenshot, op.method);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, op.arg, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(f64, 4), try numF64FromObj(parsed.value.object.get("rect").?.object, "height"));
    try testing.expectEqual(@as(f64, 2), try numF64FromObj(parsed.value.object, "scale"));
}

test "dispatchBrowser(screenshot): 형식 오류 rect → invalid_params(surface oracle 아님)" {
    // 부분 rect는 invalid_params(-32602) — 존재 web surface에도 형식 오류는 균일 거부.
    const wire = try dispatchErr("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.screenshot\",\"params\":{\"id\":11,\"rect\":{\"x\":0}}}", browserCap(11));
    defer testing.allocator.free(wire);
    try testing.expectEqual(@as(i64, -32602), try errCode(wire));
}

// ── browser.wait: params/dispatch/provenance/completion ──

test "parseWaitParams: selector/load·기본 timeout·경계·형식 오류" {
    {
        var pm = try cp.parseMessage(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.wait\",\"params\":{\"id\":11,\"condition\":\"selector\",\"selector\":\"#ready\"}}");
        defer pm.deinit();
        const p = try parseWaitParams(pm.message.request.params);
        try testing.expectEqual(@as(u64, 11), p.id);
        try testing.expectEqual(WaitCondition.selector, p.condition);
        try testing.expectEqualStrings("#ready", p.selector.?);
        try testing.expectEqual(wait_default_timeout_ms, p.timeout_ms);
    }
    {
        var pm = try cp.parseMessage(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.wait\",\"params\":{\"id\":11,\"condition\":\"load\",\"timeout_ms\":1}}");
        defer pm.deinit();
        const p = try parseWaitParams(pm.message.request.params);
        try testing.expectEqual(WaitCondition.load, p.condition);
        try testing.expect(p.selector == null);
        try testing.expectEqual(@as(u32, 1), p.timeout_ms);
    }
    const invalid = [_][]const u8{
        "{\"id\":11,\"condition\":\"selector\"}",
        "{\"id\":11,\"condition\":\"selector\",\"selector\":\"\"}",
        "{\"id\":11,\"condition\":\"load\",\"selector\":\"#x\"}",
        "{\"id\":11,\"condition\":\"networkidle\"}",
        "{\"id\":11,\"condition\":\"load\",\"timeout_ms\":0}",
        "{\"id\":11,\"condition\":\"load\",\"timeout_ms\":25001}",
        "{\"id\":11,\"condition\":\"load\",\"timeout_ms\":1.5}",
    };
    for (invalid) |params_json| {
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, params_json, .{});
        defer parsed.deinit();
        try testing.expectError(error.InvalidParams, parseWaitParams(parsed.value));
    }
}

test "dispatchBrowser(wait): cap과 pane grant provenance를 구분하고 compact arg 생성" {
    const request = "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"browser.wait\",\"params\":{\"id\":11,\"condition\":\"selector\",\"selector\":\"#ready\",\"timeout_ms\":500}}";
    {
        const op = try dispatchOp(request, browserCap(11));
        defer testing.allocator.free(op.arg);
        try testing.expectEqual(BrowserMethod.wait, op.method);
        try testing.expect(op.pane_grant == null); // capability-origin wait는 pane grant revoke 대상 아님
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, op.arg, .{});
        defer parsed.deinit();
        try testing.expectEqualStrings("selector", parsed.value.object.get("condition").?.string);
        try testing.expectEqualStrings("#ready", parsed.value.object.get("selector").?.string);
        try testing.expectEqual(@as(i64, 500), parsed.value.object.get("timeout_ms").?.integer);
    }
    {
        var grants: cpg.PaneGrantStore = .{};
        try grants.grant(.{ .pane = 5, .target = 11, .scope = .browser });
        switch (try dispatchGrant(request, 5, &grants)) {
            .op => |op| {
                defer testing.allocator.free(op.arg);
                try testing.expectEqual(@as(u64, 5), op.pane_grant.?.pane);
                try testing.expectEqual(@as(u64, 11), op.pane_grant.?.target);
                try testing.expectEqual(capmod.ScopeClass.browser, op.pane_grant.?.scope);
            },
            .err => |e| {
                testing.allocator.free(e);
                return error.ExpectedOpGotErr;
            },
            else => return error.ExpectedOp,
        }
    }
}

test "serializeBrowserResponseStatus(wait): success·timeout data·invalid selector·surface close·grant revoke" {
    const request = "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"browser.wait\",\"params\":{\"id\":11,\"condition\":\"load\",\"timeout_ms\":125}}";
    {
        const w = try serializeBrowserResponseStatus(testing.allocator, request, .success, "");
        defer testing.allocator.free(w);
        var pm = try cp.parseMessage(testing.allocator, w);
        defer pm.deinit();
        try testing.expect(pm.message.response.result.?.object.get("ok").?.bool);
    }
    {
        const w = try serializeBrowserResponseStatus(testing.allocator, request, .timeout, "");
        defer testing.allocator.free(w);
        var pm = try cp.parseMessage(testing.allocator, w);
        defer pm.deinit();
        const e = pm.message.response.err.?;
        try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.timeout)), e.code);
        try testing.expectEqualStrings("load", e.data.?.object.get("condition").?.string);
        try testing.expectEqual(@as(i64, 125), e.data.?.object.get("timeout_ms").?.integer);
    }
    {
        const w = try serializeBrowserResponseStatus(testing.allocator, request, .invalid_params, "Invalid selector");
        defer testing.allocator.free(w);
        try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.invalid_params)), try errCode(w));
    }
    {
        const w = try serializeBrowserResponseStatus(testing.allocator, request, .process_exited, "");
        defer testing.allocator.free(w);
        try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.process_exited)), try errCode(w));
    }
    {
        const w = try serializeBrowserResponseStatus(testing.allocator, request, .unauthorized, "");
        defer testing.allocator.free(w);
        try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.unauthorized)), try errCode(w));
    }
}

test "all browser methods preserve typed lifecycle terminal codes" {
    const requests = [_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.navigate\",\"params\":{\"id\":11,\"url\":\"about:blank\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"browser.getCookies\",\"params\":{\"id\":11}}",
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"browser.screenshot\",\"params\":{\"id\":11}}",
        "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"browser.setCookie\",\"params\":{\"id\":11,\"name\":\"a\",\"value\":\"b\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"browser.click\",\"params\":{\"id\":11,\"selector\":\"button\"}}",
    };
    const statuses = [_]struct { status: BrowserCompletionStatus, code: cp.ErrorCode }{
        .{ .status = .timeout, .code = .timeout },
        .{ .status = .process_exited, .code = .process_exited },
        .{ .status = .unauthorized, .code = .unauthorized },
    };
    for (requests) |request| for (statuses) |expected| {
        const wire = try serializeBrowserResponseStatus(testing.allocator, request, expected.status, "");
        defer testing.allocator.free(wire);
        try testing.expectEqual(@as(i64, @intFromEnum(expected.code)), try errCode(wire));
    };
}

test "executeScript lifecycle errors: resource-busy와 timeout은 stable wire code/data" {
    const request = "{\"jsonrpc\":\"2.0\",\"id\":42,\"method\":\"browser.executeScript\",\"params\":{\"id\":11,\"script\":\"1\",\"max_result_bytes\":64}}";
    {
        const wire = try serializeResourceBusy(testing.allocator, request, "browser-result-bytes");
        defer testing.allocator.free(wire);
        var pm = try cp.parseMessage(testing.allocator, wire);
        defer pm.deinit();
        const e = pm.message.response.err.?;
        try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.resource_busy)), e.code);
        try testing.expectEqualStrings("browser-result-bytes", e.data.?.object.get("resource").?.string);
        try testing.expect(e.data.?.object.get("retryable").?.bool);
        try testing.expect(e.data.?.object.get("used_bytes") == null);
    }
    {
        const wire = try serializeBrowserResponseStatus(testing.allocator, request, .timeout, "");
        defer testing.allocator.free(wire);
        var pm = try cp.parseMessage(testing.allocator, wire);
        defer pm.deinit();
        try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.timeout)), pm.message.response.err.?.code);
    }
}

test "params/arg(§9.5.4): snapshot 기본·선택 필드 파싱·직렬화" {
    // 기본(id만) → interactive_only=false, max_depth/selector 부재. arg={"interactive_only":false}.
    {
        var pm = try cp.parseMessage(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.snapshot\",\"params\":{\"id\":11}}");
        defer pm.deinit();
        const p = try parseSnapshotParams(pm.message.request.params);
        try testing.expect(!p.interactive_only and p.max_depth == null and p.selector == null);
        const a = try serializeSnapshotArg(testing.allocator, p);
        defer testing.allocator.free(a);
        try testing.expectEqualStrings("{\"interactive_only\":false}", a);
    }
    // 전체 지정 → arg에 세 필드.
    {
        var pm = try cp.parseMessage(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.snapshot\",\"params\":{\"id\":11,\"interactive_only\":true,\"max_depth\":3,\"selector\":\"#main\"}}");
        defer pm.deinit();
        const p = try parseSnapshotParams(pm.message.request.params);
        try testing.expect(p.interactive_only);
        try testing.expectEqual(@as(u32, 3), p.max_depth.?);
        try testing.expectEqualStrings("#main", p.selector.?);
        const a = try serializeSnapshotArg(testing.allocator, p);
        defer testing.allocator.free(a);
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, a, .{});
        defer parsed.deinit();
        try testing.expect(parsed.value.object.get("interactive_only").?.bool);
        try testing.expectEqual(@as(i64, 3), parsed.value.object.get("max_depth").?.integer);
        try testing.expectEqualStrings("#main", parsed.value.object.get("selector").?.string);
    }
    // 음수 max_depth → invalid_params.
    {
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"id\":1,\"max_depth\":-1}", .{});
        defer parsed.deinit();
        try testing.expectError(error.InvalidParams, parseSnapshotParams(parsed.value));
    }
}

test "dispatchBrowser(snapshot): base browser cap → op{snapshot, arg}" {
    const op = try dispatchOp("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.snapshot\",\"params\":{\"id\":11,\"interactive_only\":true}}", browserCap(11));
    defer testing.allocator.free(op.arg);
    try testing.expectEqual(BrowserMethod.snapshot, op.method);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, op.arg, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("interactive_only").?.bool);
}

test "serializeBrowserResponse(snapshot): 트리 JSON을 {snapshot} 구조화 embed·malformed→internal_error" {
    // Swift가 준 {tree:[...]} → {result:{snapshot:{tree:[...]}}}.
    {
        const w = try serializeBrowserResponse(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.snapshot\",\"params\":{\"id\":11}}", true, "{\"tree\":[{\"role\":\"button\",\"name\":\"OK\",\"ref\":\"e1\"}]}");
        defer testing.allocator.free(w);
        var pm = try cp.parseMessage(testing.allocator, w);
        defer pm.deinit();
        const snap = pm.message.response.result.?.object.get("snapshot").?.object;
        const tree = snap.get("tree").?.array;
        try testing.expectEqualStrings("button", tree.items[0].object.get("role").?.string);
        try testing.expectEqualStrings("e1", tree.items[0].object.get("ref").?.string);
    }
    // malformed(비-JSON) → internal_error(Swift 버그 방어).
    {
        const w = try serializeBrowserResponse(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.snapshot\",\"params\":{\"id\":11}}", true, "not json");
        defer testing.allocator.free(w);
        var pm = try cp.parseMessage(testing.allocator, w);
        defer pm.deinit();
        try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.internal_error)), pm.message.response.err.?.code);
    }
}

test "params/arg(§9.5.9): console clear 파싱·직렬화" {
    // 기본(id만) → clear=false. arg={"clear":false}.
    {
        var pm = try cp.parseMessage(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.console\",\"params\":{\"id\":11}}");
        defer pm.deinit();
        const p = try parseConsoleParams(pm.message.request.params);
        try testing.expect(!p.clear);
        const a = try serializeConsoleArg(testing.allocator, p);
        defer testing.allocator.free(a);
        try testing.expectEqualStrings("{\"clear\":false}", a);
    }
    // clear=true → arg={"clear":true}.
    {
        var pm = try cp.parseMessage(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.console\",\"params\":{\"id\":11,\"clear\":true}}");
        defer pm.deinit();
        const p = try parseConsoleParams(pm.message.request.params);
        try testing.expect(p.clear);
        const a = try serializeConsoleArg(testing.allocator, p);
        defer testing.allocator.free(a);
        try testing.expectEqualStrings("{\"clear\":true}", a);
    }
    // 비-bool clear → invalid_params.
    {
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"id\":1,\"clear\":\"x\"}", .{});
        defer parsed.deinit();
        try testing.expectError(error.InvalidParams, parseConsoleParams(parsed.value));
    }
}

test "dispatchBrowser(console): base browser cap → op{console, arg=clear JSON}" {
    const op = try dispatchOp("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.console\",\"params\":{\"id\":11,\"clear\":true}}", browserCap(11));
    defer testing.allocator.free(op.arg);
    try testing.expectEqual(BrowserMethod.console, op.method);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, op.arg, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("clear").?.bool);
}

test "serializeBrowserResponse(console): 배열 JSON을 {console} 구조화 embed·malformed→internal_error" {
    // Swift가 준 [{level,text},...] → {result:{console:[...]}}.
    {
        const w = try serializeBrowserResponse(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.console\",\"params\":{\"id\":11}}", true, "[{\"level\":\"error\",\"text\":\"boom\"}]");
        defer testing.allocator.free(w);
        var pm = try cp.parseMessage(testing.allocator, w);
        defer pm.deinit();
        const arr = pm.message.response.result.?.object.get("console").?.array;
        try testing.expectEqualStrings("error", arr.items[0].object.get("level").?.string);
        try testing.expectEqualStrings("boom", arr.items[0].object.get("text").?.string);
    }
    // malformed(비-JSON) → internal_error(Swift 버그 방어).
    {
        const w = try serializeBrowserResponse(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.console\",\"params\":{\"id\":11}}", true, "not json");
        defer testing.allocator.free(w);
        var pm = try cp.parseMessage(testing.allocator, w);
        defer pm.deinit();
        try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.internal_error)), pm.message.response.err.?.code);
    }
}

test {
    testing.refAllDecls(@This());
}

test "W9b②-3: wait visible — selector 면 엔진에 selector 조건으로, 로케이터는 visible 로(Chromium), 키는 엄격, 다른 조건의 locator 는 거절, WebKit 은 인가 전 -32008" {
    var buf: [1]capmod.Capability = undefined;
    const ok_cases = [_]struct { req: []const u8, arg: []const u8, surface: u64 }{
        .{ .req = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.wait\",\"params\":{\"id\":11,\"condition\":\"visible\",\"selector\":\"#ready\",\"timeout_ms\":900}}", .arg = "{\"condition\":\"selector\",\"selector\":\"#ready\",\"timeout_ms\":900}", .surface = 11 },
        .{ .req = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.wait\",\"params\":{\"id\":12,\"condition\":\"visible\",\"locator\":{\"role\":\"button\",\"name\":\"Save\",\"nth\":1}}}", .arg = "{\"condition\":\"visible\",\"locator\":{\"role\":\"button\",\"name\":\"Save\",\"nth\":1},\"timeout_ms\":25000}", .surface = 12 },
        .{ .req = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.wait\",\"params\":{\"id\":12,\"condition\":\"visible\",\"locator\":{\"text\":\"Done\",\"exact\":true},\"timeout_ms\":5}}", .arg = "{\"condition\":\"visible\",\"locator\":{\"text\":\"Done\",\"exact\":true},\"timeout_ms\":5}", .surface = 12 },
        // 옛 조건의 모르는 키는 그대로 둔다(뒤 호환).
        .{ .req = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.wait\",\"params\":{\"id\":12,\"condition\":\"load\",\"extra\":1}}", .arg = "{\"condition\":\"load\",\"timeout_ms\":25000}", .surface = 12 },
    };
    for (ok_cases) |c| switch (try dispatchBrowser(testing.allocator, c.req, fx_engine, capsSlice(&buf, browserCap(c.surface)), null, &no_grants, 0)) {
        .op => |op| {
            defer testing.allocator.free(op.arg);
            try testing.expectEqualStrings(c.arg, op.arg);
        },
        .err => |e| {
            defer testing.allocator.free(e);
            return error.TestUnexpectedResult;
        },
        else => return error.TestUnexpectedResult,
    };
    const bad = [_][]const u8{
        "{\"id\":12,\"condition\":\"visible\"}", // 대상 없음
        "{\"id\":12,\"condition\":\"visible\",\"selector\":\"#a\",\"locator\":{\"role\":\"button\"}}", // 둘
        "{\"id\":12,\"condition\":\"visible\",\"ref\":\"n3\"}", // ref 는 받지 않는다
        "{\"id\":12,\"condition\":\"visible\",\"selector\":\"\"}",
        "{\"id\":12,\"condition\":\"visible\",\"locator\":{\"role\":\"button\"},\"bogus\":1}", // 엄격 키
        "{\"id\":12,\"condition\":\"visible\",\"locator\":{\"text\":\"a\",\"name\":\"b\"}}",
        "{\"id\":12,\"condition\":\"load\",\"locator\":{\"role\":\"button\"}}", // 조용히 버리지 않는다
        "{\"id\":12,\"condition\":\"selector\",\"selector\":\"#a\",\"locator\":{\"role\":\"button\"}}",
    };
    for (bad) |params| {
        var req_buf: [256]u8 = undefined;
        const req = try std.fmt.bufPrint(&req_buf, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.wait\",\"params\":{s}}}", .{params});
        switch (try dispatchBrowser(testing.allocator, req, fx_engine, capsSlice(&buf, browserCap(12)), null, &no_grants, 0)) {
            .err => |e| {
                defer testing.allocator.free(e);
                try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.invalid_params)), try errCode(e));
            },
            .op => |op| {
                testing.allocator.free(op.arg);
                return error.TestUnexpectedResult;
            },
            else => return error.TestUnexpectedResult,
        }
    }
    // WebKit 탭의 로케이터 wait — 인가(모달) 전 -32008. selector 의 visible 은 WebKit 도 된다(위).
    var grants: cpg.PaneGrantStore = .{};
    switch (try dispatchBrowser(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.wait\",\"params\":{\"id\":11,\"condition\":\"visible\",\"locator\":{\"role\":\"button\"}}}", fx_engine, &.{}, 6, &grants, 0)) {
        .err => |e| {
            defer testing.allocator.free(e);
            try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.unsupported_by_engine)), try errCode(e));
            try testing.expect(std.mem.indexOf(u8, e, "\"param\":\"locator\"") != null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "W9b②-3: wait visible 의 결과 — 로케이터면 {ok, matched, ambiguous?}, 시한 -32004 data 에 condition visible 과 숨은 일치 수" {
    const req = "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"browser.wait\",\"params\":{\"id\":12,\"condition\":\"visible\",\"locator\":{\"text\":\"Archive\"},\"timeout_ms\":300}}";
    const ok = try serializeBrowserResponseStatus(testing.allocator, req, .success, "{\"ok\":true,\"matched\":{\"ref\":\"n41\",\"name\":\"Archive\"},\"ambiguous\":true}");
    defer testing.allocator.free(ok);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"ok\":true,\"matched\":{\"ref\":\"n41\",\"name\":\"Archive\"},\"ambiguous\":true}}", ok);
    const one = try serializeBrowserResponseStatus(testing.allocator, req, .success, "{\"ok\":true,\"matched\":{\"ref\":\"n41\",\"name\":\"Archive\"}}");
    defer testing.allocator.free(one);
    try testing.expect(std.mem.indexOf(u8, one, "ambiguous") == null);
    const plain = try serializeBrowserResponseStatus(testing.allocator, req, .success, "true");
    defer testing.allocator.free(plain);
    try testing.expect(std.mem.indexOf(u8, plain, "\"ok\":true") != null);
    const bad = try serializeBrowserResponseStatus(testing.allocator, req, .success, "{\"ok\":true}");
    defer testing.allocator.free(bad);
    try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.internal_error)), try errCode(bad));
    const t = try serializeBrowserResponseStatus(testing.allocator, req, .timeout, "{\"hidden\":3}");
    defer testing.allocator.free(t);
    try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.timeout)), try errCode(t));
    try testing.expect(std.mem.indexOf(u8, t, "\"condition\":\"visible\"") != null);
    try testing.expect(std.mem.indexOf(u8, t, "\"hidden\":3") != null);
    const t2 = try serializeBrowserResponseStatus(testing.allocator, req, .timeout, "not json");
    defer testing.allocator.free(t2);
    try testing.expect(std.mem.indexOf(u8, t2, "hidden") == null);
}

// ── W9b③: 탭 열기·닫기 ─────────────────────────────────────────────────────────────────────────────────────

test "W9b③: browser.open 은 부른 pane(1g)이 대상 — pane 이 없으면 unauthorized, 주소·키·시한이 틀리면 invalid_params, 확인 모달 없음" {
    var grants: cpg.PaneGrantStore = .{};
    const ok_cases = [_]struct { bytes: []const u8, arg: []const u8 }{
        .{ .bytes = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.open\",\"params\":{\"url\":\"https://example.com/a?b=1\"}}", .arg = "{\"url\":\"https://example.com/a?b=1\",\"timeout_ms\":25000}" },
        .{ .bytes = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.open\",\"params\":{\"timeout_ms\":500}}", .arg = "{\"timeout_ms\":500}" },
        .{ .bytes = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.open\"}", .arg = "{\"timeout_ms\":25000}" },
    };
    for (ok_cases) |c| switch (try dispatchBrowser(testing.allocator, c.bytes, fx_engine, &.{}, 10, &grants, 0)) {
        .op => |op| {
            defer testing.allocator.free(op.arg);
            try testing.expectEqual(BrowserMethod.open, op.method);
            try testing.expectEqual(@as(u64, 10), op.surface_id); // 부른 pane
            try testing.expect(op.pane_grant == null);
            try testing.expectEqualStrings(c.arg, op.arg);
        },
        else => return error.TestUnexpectedResult,
    };
    // pane 을 못 찾았다(cap 만 든 연결) — 균일 unauthorized(params 를 풀기 전에).
    var buf: [1]capmod.Capability = undefined;
    switch (try dispatchBrowser(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.open\",\"params\":{\"url\":\"file:///etc/passwd\"}}", fx_engine, capsSlice(&buf, browserCap(12)), null, &grants, 0)) {
        .err => |e| {
            defer testing.allocator.free(e);
            try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.unauthorized)), try errCode(e));
        },
        else => return error.TestUnexpectedResult,
    }
    const bad = [_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.open\",\"params\":{\"url\":\"file:///etc/passwd\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.open\",\"params\":{\"url\":\"javascript:alert(1)\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.open\",\"params\":{\"url\":\"about:blank\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.open\",\"params\":{\"url\":\"\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.open\",\"params\":{\"url\":7}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.open\",\"params\":{\"id\":12}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.open\",\"params\":{\"background\":false}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.open\",\"params\":{\"timeout_ms\":0}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.open\",\"params\":{\"timeout_ms\":25001}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.open\",\"params\":[]}",
    };
    for (bad) |bytes| switch (try dispatchBrowser(testing.allocator, bytes, fx_engine, &.{}, 10, &grants, 0)) {
        .err => |e| {
            defer testing.allocator.free(e);
            try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.invalid_params)), try errCode(e));
        },
        .op => |op| {
            testing.allocator.free(op.arg);
            return error.TestUnexpectedResult;
        },
        else => return error.TestUnexpectedResult,
    };
}

test "W9b③: browser.close 는 그 탭의 browser grant 가 있어야 op — 없으면 확인 모달 없이 unauthorized, WebKit 탭은 모달 전 -32008" {
    var grants: cpg.PaneGrantStore = .{};
    const close12 = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.close\",\"params\":{\"id\":12}}";
    // grant 없음 — pane 이 있어도 needs_grant 가 아니라 unauthorized(남의 탭을 닫으려고 허락을 묻지 않는다).
    switch (try dispatchBrowser(testing.allocator, close12, fx_engine, &.{}, 10, &grants, 0)) {
        .err => |e| {
            defer testing.allocator.free(e);
            try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.unauthorized)), try errCode(e));
        },
        .op => |op| {
            testing.allocator.free(op.arg);
            return error.TestUnexpectedResult;
        },
        else => return error.TestUnexpectedResult,
    }
    try grants.grant(.{ .pane = 10, .target = 12, .scope = .browser });
    switch (try dispatchBrowser(testing.allocator, close12, fx_engine, &.{}, 10, &grants, 0)) {
        .op => |op| {
            defer testing.allocator.free(op.arg);
            try testing.expectEqual(BrowserMethod.close, op.method);
            try testing.expectEqual(@as(u64, 12), op.surface_id);
            try testing.expectEqual(@as(u64, 10), op.pane_grant.?.pane); // 앱이 이 pane 이 연 탭인지 본다
        },
        else => return error.TestUnexpectedResult,
    }
    // 다른 pane 의 grant 로는 닫지 못한다.
    switch (try dispatchBrowser(testing.allocator, close12, fx_engine, &.{}, 99, &grants, 0)) {
        .err => |e| testing.allocator.free(e),
        else => return error.TestUnexpectedResult,
    }
    // WebKit 탭 — 확인 모달 전 -32008.
    switch (try dispatchBrowser(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.close\",\"params\":{\"id\":11}}", fx_engine, &.{}, 10, &grants, 0)) {
        .err => |e| {
            defer testing.allocator.free(e);
            try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.unsupported_by_engine)), try errCode(e));
        },
        else => return error.TestUnexpectedResult,
    }
}

test "W9b③: open·close 결과는 엔진이 준 필드만 — 모양이 틀리면 internal_error" {
    const open_req = "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"browser.open\",\"params\":{\"url\":\"https://e.test/\"}}";
    const close_req = "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"browser.close\",\"params\":{\"id\":12}}";
    const cases = [_]struct { req: []const u8, payload: []const u8, want: []const u8 }{
        .{ .req = open_req, .payload = "{\"id\":42,\"url\":\"https://e.test/\",\"loaded\":true,\"extra\":1}", .want = "\"result\":{\"id\":42,\"url\":\"https://e.test/\",\"loaded\":true}" },
        .{ .req = close_req, .payload = "{\"closed\":true}", .want = "\"result\":{\"closed\":true}" },
        .{ .req = close_req, .payload = "{\"closed\":false,\"reason\":\"asking\"}", .want = "\"result\":{\"closed\":false,\"reason\":\"asking\"}" },
    };
    for (cases) |c| {
        const w = try serializeBrowserResponseStatus(testing.allocator, c.req, .success, c.payload);
        defer testing.allocator.free(w);
        try testing.expect(std.mem.indexOf(u8, w, c.want) != null);
    }
    const bad = [_]struct { req: []const u8, payload: []const u8 }{
        .{ .req = open_req, .payload = "{\"id\":0,\"url\":\"x\",\"loaded\":true}" },
        .{ .req = open_req, .payload = "{\"id\":4,\"loaded\":true}" },
        .{ .req = open_req, .payload = "true" },
        .{ .req = close_req, .payload = "{\"closed\":\"yes\"}" },
        .{ .req = close_req, .payload = "{\"closed\":false,\"reason\":5}" },
        .{ .req = close_req, .payload = "{" },
    };
    for (bad) |c| {
        const w = try serializeBrowserResponseStatus(testing.allocator, c.req, .success, c.payload);
        defer testing.allocator.free(w);
        try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.internal_error)), try errCode(w));
    }
}

test "W9b③ 적대 리뷰 3 회차: act 결과의 dialog(누른 뒤 페이지가 대화상자를 띄웠다)는 ok 와 함께 싣는다 — matched 는 로케이터일 때만" {
    const plain = try serializeActMatchedResult(testing.allocator, .{ .number = 5 }, "{\"ok\":true,\"dialog\":true}");
    defer testing.allocator.free(plain);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":5,\"result\":{\"ok\":true,\"dialog\":true}}", plain);
    const located = try serializeActMatchedResult(testing.allocator, .{ .number = 6 }, "{\"ok\":true,\"matched\":{\"ref\":\"n1\",\"name\":\"Go\"},\"dialog\":true}");
    defer testing.allocator.free(located);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":6,\"result\":{\"ok\":true,\"matched\":{\"ref\":\"n1\",\"name\":\"Go\"},\"dialog\":true}}", located);
    try testing.expectError(error.InvalidActPayload, serializeActMatchedResult(testing.allocator, .{ .number = 7 }, "{\"ok\":true}"));
}

test "W9f 적대 리뷰 5 회차: WebKit snapshot 이 아주 깊어도 앱이 죽지 않는다 — Chromium 과 같은 깊이(100)에서 자식을 끊는다" {
    const depth = 300;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(testing.allocator);
    try src.appendSlice(testing.allocator, "{\"tree\":[");
    for (0..depth) |_| try src.appendSlice(testing.allocator, "{\"role\":\"group\",\"ref\":\"e1\",\"children\":[");
    for (0..depth) |_| try src.appendSlice(testing.allocator, "]}");
    try src.appendSlice(testing.allocator, "]}");
    const out = try serializeSnapshotResult(testing.allocator, .{ .number = 1 }, src.items);
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, max_snapshot_node_depth), std.mem.count(u8, out, "\"role\":\"group\""));
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out, .{});
    parsed.deinit();
}

test "W9a: Chromium 탭의 navigate 는 loaded 를 싣고, WebKit 의 빈 결과는 {ok:true} 그대로" {
    const cases = [_]struct { result: []const u8, want: []const u8 }{
        .{ .result = "true", .want = "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"ok\":true,\"loaded\":true}}" },
        .{ .result = "false", .want = "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"ok\":true,\"loaded\":false}}" },
        .{ .result = "", .want = "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"ok\":true}}" },
    };
    for (cases) |c| {
        const wire = try serializeNavigateLoadedResult(testing.allocator, .{ .number = 3 }, c.result);
        defer testing.allocator.free(wire);
        try testing.expectEqualStrings(c.want, wire);
    }
    const nav_req = "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"browser.navigate\",\"params\":{\"id\":1,\"url\":\"https://a.test/\"}}";
    const resp = try serializeBrowserResponseStatus(testing.allocator, nav_req, .success, "false");
    defer testing.allocator.free(resp);
    try testing.expectEqualStrings(cases[1].want, resp);
    try testing.expect(engineSupports(.chromium, .navigate) and engineSupports(.chromium, .get_url) and engineSupports(.chromium, .screenshot));
}

test "W9a 적대 리뷰 2 회차 재현: 진단 메시지의 \\n·\\t 는 2 바이트로 센다(WebKit escapedDiagnostic·Zig 쓰개와 같다) — 상한까지 자른 여러 줄 메시지가 폴백으로 바뀌었다" {
    const req = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.executeScript\",\"params\":{\"id\":1,\"script\":\"x\"}}";
    var msg: std.ArrayList(u8) = .empty;
    defer msg.deinit(testing.allocator);
    while (msg.items.len < 16 * 1024 - 2) try msg.appendSlice(testing.allocator, "\n");
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    try s.write(.{ .kind = "execution", .name = "Error", .message = msg.items[0 .. (16 * 1024) / 2 - 1], .stack = "", .diagnostics_truncated = true });
    const wire = try serializeExecuteScriptScriptError(testing.allocator, req, aw.written());
    defer testing.allocator.free(wire);
    try testing.expect(std.mem.indexOf(u8, wire, "\"name\":\"Error\"") != null);
    try testing.expect(std.mem.indexOf(u8, wire, "executeScript failed") == null);
}

// ── W9c②: 에이전트가 JS 대화상자에 답한다(browser.dialog·handleDialog) ─────────────────────────────────────────────

test "W9c②: dialog·handleDialog 는 close 뒤 25·26 — wire 이름은 dialog·handleDialog, Chromium 만(WebKit 은 모달 전 -32008)" {
    try testing.expectEqual(@as(u8, 25), @as(u8, @intFromEnum(BrowserMethod.dialog)));
    try testing.expectEqual(@as(u8, 26), @as(u8, @intFromEnum(BrowserMethod.handle_dialog)));
    try testing.expectEqual(BrowserMethod.dialog, parseBrowserMethod("dialog").?);
    try testing.expectEqual(BrowserMethod.handle_dialog, parseBrowserMethod("handleDialog").?);
    try testing.expect(engineSupports(.chromium, .dialog) and engineSupports(.chromium, .handle_dialog));
    try testing.expect(!engineSupports(.webkit, .dialog) and !engineSupports(.webkit, .handle_dialog));
    try testing.expectEqual(capmod.ScopeClass.browser, capmod.methodRequiredScope("browser.handleDialog").?);
    var grants: cpg.PaneGrantStore = .{};
    for ([_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.dialog\",\"params\":{\"id\":11}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.handleDialog\",\"params\":{\"id\":11,\"accept\":true}}",
    }) |bytes| switch (try dispatchBrowser(testing.allocator, bytes, fx_engine, &.{}, 10, &grants, 0)) {
        .err => |e| {
            defer testing.allocator.free(e);
            try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.unsupported_by_engine)), try errCode(e));
        },
        .op => |op| {
            testing.allocator.free(op.arg);
            return error.TestUnexpectedResult;
        },
        else => return error.TestUnexpectedResult,
    };
    // grant 없는 Chromium 탭 — 다른 메서드처럼 확인 모달(needs_grant)로 묻는다.
    switch (try dispatchBrowser(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.dialog\",\"params\":{\"id\":12}}", fx_engine, &.{}, 10, &grants, 0)) {
        .needs_grant => |g| try testing.expectEqual(@as(u64, 12), g.target),
        .op => |op| {
            testing.allocator.free(op.arg);
            return error.TestUnexpectedResult;
        },
        .err => |e| {
            testing.allocator.free(e);
            return error.TestUnexpectedResult;
        },
        else => return error.TestUnexpectedResult,
    }
}

test "W9c②: handleDialog params — accept 는 꼭 bool, text·dialog(번호) 는 선택, 모르는 키·긴 글·0 번은 invalid_params" {
    var grants: cpg.PaneGrantStore = .{};
    try grants.grant(.{ .pane = 10, .target = 12, .scope = .browser });
    const ok_cases = [_]struct { bytes: []const u8, method: BrowserMethod, arg: []const u8 }{
        .{ .bytes = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.dialog\",\"params\":{\"id\":12}}", .method = .dialog, .arg = "" },
        .{ .bytes = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.handleDialog\",\"params\":{\"id\":12,\"accept\":false}}", .method = .handle_dialog, .arg = "{\"accept\":false}" },
        .{ .bytes = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.handleDialog\",\"params\":{\"id\":12,\"accept\":true,\"text\":\"이름\",\"dialog\":42}}", .method = .handle_dialog, .arg = "{\"accept\":true,\"text\":\"이름\",\"dialog\":42}" },
    };
    for (ok_cases) |c| switch (try dispatchBrowser(testing.allocator, c.bytes, fx_engine, &.{}, 10, &grants, 0)) {
        .op => |op| {
            defer testing.allocator.free(op.arg);
            try testing.expectEqual(c.method, op.method);
            try testing.expectEqual(@as(u64, 12), op.surface_id);
            try testing.expectEqualStrings(c.arg, op.arg);
        },
        else => return error.TestUnexpectedResult,
    };
    var long: [handle_dialog_max_text_bytes + 1]u8 = undefined;
    @memset(&long, 'a');
    const long_req = try std.fmt.allocPrint(testing.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.handleDialog\",\"params\":{{\"id\":12,\"accept\":true,\"text\":\"{s}\"}}}}", .{&long});
    defer testing.allocator.free(long_req);
    const bad = [_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.handleDialog\",\"params\":{\"id\":12}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.handleDialog\",\"params\":{\"id\":12,\"accept\":\"yes\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.handleDialog\",\"params\":{\"id\":12,\"accept\":true,\"text\":5}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.handleDialog\",\"params\":{\"id\":12,\"accept\":true,\"dialog\":0}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.handleDialog\",\"params\":{\"id\":12,\"accept\":true,\"dialog\":\"7\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.handleDialog\",\"params\":{\"id\":12,\"accept\":true,\"suppress\":true}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.dialog\",\"params\":{\"id\":12,\"all\":true}}",
        long_req,
    };
    for (bad) |bytes| switch (try dispatchBrowser(testing.allocator, bytes, fx_engine, &.{}, 10, &grants, 0)) {
        .err => |e| {
            defer testing.allocator.free(e);
            try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.invalid_params)), try errCode(e));
        },
        .op => |op| {
            testing.allocator.free(op.arg);
            return error.TestUnexpectedResult;
        },
        else => return error.TestUnexpectedResult,
    };
}

test "W9c②: dialog·handleDialog 결과는 엔진이 준 알려진 필드만 — 모양이 틀리면 internal_error" {
    const dialog_req = "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"browser.dialog\",\"params\":{\"id\":12}}";
    const handle_req = "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"browser.handleDialog\",\"params\":{\"id\":12,\"accept\":true}}";
    const cases = [_]struct { req: []const u8, payload: []const u8, want: []const u8 }{
        .{ .req = dialog_req, .payload = "{\"dialogs\":[]}", .want = "\"result\":{\"dialogs\":[]}" },
        .{
            .req = dialog_req,
            .payload = "{\"dialogs\":[{\"token\":7,\"tab\":12,\"kind\":\"prompt\",\"message\":\"m\",\"origin\":\"https://a.test\",\"default_text\":\"d\",\"cause\":\"agent\",\"may_answer\":true,\"x\":1},{\"tab\":13,\"kind\":\"alert\"}]}",
            .want = "\"result\":{\"dialogs\":[{\"token\":7,\"tab\":12,\"kind\":\"prompt\",\"message\":\"m\",\"origin\":\"https://a.test\",\"default_text\":\"d\",\"cause\":\"agent\",\"may_answer\":true},{\"tab\":13,\"kind\":\"alert\"}]}",
        },
        .{ .req = handle_req, .payload = "{\"ok\":true,\"kind\":\"alert\"}", .want = "\"result\":{\"ok\":true,\"kind\":\"alert\"}" },
        .{ .req = handle_req, .payload = "{\"ok\":true,\"kind\":\"before_unload\",\"continues\":true}", .want = "\"result\":{\"ok\":true,\"kind\":\"before_unload\",\"continues\":true}" },
    };
    for (cases) |c| {
        const w = try serializeBrowserResponseStatus(testing.allocator, c.req, .success, c.payload);
        defer testing.allocator.free(w);
        try testing.expect(std.mem.indexOf(u8, w, c.want) != null);
    }
    const bad = [_]struct { req: []const u8, payload: []const u8 }{
        .{ .req = dialog_req, .payload = "{}" },
        .{ .req = dialog_req, .payload = "{\"dialogs\":[{\"kind\":\"alert\"}]}" },
        .{ .req = dialog_req, .payload = "{\"dialogs\":[{\"tab\":12,\"kind\":\"alert\",\"token\":\"7\"}]}" },
        .{ .req = dialog_req, .payload = "{\"dialogs\":[{\"tab\":12,\"kind\":\"alert\",\"may_answer\":1}]}" },
        .{ .req = handle_req, .payload = "{\"ok\":true}" },
        .{ .req = handle_req, .payload = "{\"ok\":\"y\",\"kind\":\"alert\"}" },
        .{ .req = handle_req, .payload = "[" },
    };
    for (bad) |c| {
        const w = try serializeBrowserResponseStatus(testing.allocator, c.req, .success, c.payload);
        defer testing.allocator.free(w);
        try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.internal_error)), try errCode(w));
    }
}

// ── W9c③: 에이전트가 Chromium 탭의 파일 입력칸에 파일을 넣는다(browser.upload) ─────────────────────────────────────────────
// 이 시험들은 L2 의 몫만 본다 — 메서드 번호(op_kind wire)·엔진 게이트가 확인 모달 **전**에 답하는가·인자 모양·결과 모양. 모달이 매번 뜨는가는
// 실행 계층(app_host_abi)의 시험이 본다(여기서 인가된 것은 「그 탭을 다뤄도 된다」 뿐이다).

test "W9c③: upload 는 handleDialog 뒤 27 — wire 이름 upload, Chromium 만, browser scope, WebKit·파일 뷰·markdown 은 확인 모달 전에 -32008" {
    try testing.expectEqual(@as(u8, 27), @as(u8, @intFromEnum(BrowserMethod.upload)));
    try testing.expectEqual(BrowserMethod.upload, parseBrowserMethod("upload").?);
    try testing.expectEqualStrings("upload", browserMethodWireName(.upload));
    try testing.expect(engineSupports(.chromium, .upload));
    try testing.expect(!engineSupports(.webkit, .upload));
    try testing.expectEqual(capmod.ScopeClass.browser, capmod.methodRequiredScope("browser.upload").?);
    var grants: cpg.PaneGrantStore = .{};
    // pane 이 있고 grant 가 없다 — 지원하는 탭이었다면 확인 모달(needs_grant)을 띄웠을 요청. 인자가 틀려도(파일 없음) 인자를 보기 전에 답한다.
    for ([_]u64{ 11, 13, 14 }) |tab| for ([_][]const u8{ "\"files\":[\"/tmp/a\"]", "\"files\":[]" }) |files| {
        const bytes = try std.fmt.allocPrint(testing.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.upload\",\"params\":{{\"id\":{d},\"selector\":\"#f\",{s}}}}}", .{ tab, files });
        defer testing.allocator.free(bytes);
        switch (try dispatchBrowser(testing.allocator, bytes, fx_engine, &.{}, 10, &grants, 0)) {
            .err => |e| {
                defer testing.allocator.free(e);
                try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.unsupported_by_engine)), try errCode(e));
            },
            .op => |op| {
                testing.allocator.free(op.arg);
                return error.TestUnexpectedResult;
            },
            else => return error.TestUnexpectedResult,
        }
    };
    // grant 없는 Chromium 탭 — 다른 메서드처럼 먼저 탭 권한을 묻는다(그 뒤 업로드 모달이 따로 — 두 모달, 작성자 선택 Q3).
    switch (try dispatchBrowser(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.upload\",\"params\":{\"id\":12,\"selector\":\"#f\",\"files\":[\"/tmp/a\"]}}", fx_engine, &.{}, 10, &grants, 0)) {
        .needs_grant => |g| {
            try testing.expectEqual(@as(u64, 12), g.target);
            try testing.expectEqual(capmod.ScopeClass.browser, g.scope);
        },
        .op => |op| {
            testing.allocator.free(op.arg);
            return error.TestUnexpectedResult;
        },
        .err => |e| {
            testing.allocator.free(e);
            return error.TestUnexpectedResult;
        },
        else => return error.TestUnexpectedResult,
    }
}

test "W9c③: upload params — 대상 하나와 1..10 개의 절대 경로, 상대·빈·제어 문자·C1·긴 경로·같은 경로 둘·모르는 키는 invalid_params" {
    var grants: cpg.PaneGrantStore = .{};
    try grants.grant(.{ .pane = 10, .target = 12, .scope = .browser });
    const ok_cases = [_]struct { bytes: []const u8, arg: []const u8 }{
        .{ .bytes = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.upload\",\"params\":{\"id\":12,\"selector\":\"#f\",\"files\":[\"/tmp/a.txt\"]}}", .arg = "{\"selector\":\"#f\",\"files\":[\"/tmp/a.txt\"]}" },
        .{ .bytes = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.upload\",\"params\":{\"id\":12,\"ref\":\"n7\",\"files\":[\"/tmp/한.txt\",\"/tmp/invoice\\u202efdp.exe\"]}}", .arg = "{\"ref\":\"n7\",\"files\":[\"/tmp/한.txt\",\"/tmp/invoice\u{202e}fdp.exe\"]}" },
        .{ .bytes = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.upload\",\"params\":{\"id\":12,\"locator\":{\"label\":\"Resume\"},\"files\":[\"/a\",\"/b\"]}}", .arg = "{\"locator\":{\"label\":\"Resume\"},\"files\":[\"/a\",\"/b\"]}" },
    };
    for (ok_cases) |c| switch (try dispatchBrowser(testing.allocator, c.bytes, fx_engine, &.{}, 10, &grants, 0)) {
        .op => |op| {
            defer testing.allocator.free(op.arg);
            try testing.expectEqual(BrowserMethod.upload, op.method);
            try testing.expectEqual(@as(u64, 12), op.surface_id);
            try testing.expectEqualStrings(c.arg, op.arg);
        },
        else => return error.TestUnexpectedResult,
    };
    // 10 개는 받고 11 개는 거절한다(상한).
    var ten: std.ArrayList(u8) = .empty;
    defer ten.deinit(testing.allocator);
    try ten.appendSlice(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.upload\",\"params\":{\"id\":12,\"selector\":\"#f\",\"files\":[");
    for (0..10) |i| try ten.print(testing.allocator, "{s}\"/tmp/f{d}\"", .{ if (i == 0) "" else ",", i });
    const eleven = try std.fmt.allocPrint(testing.allocator, "{s},\"/tmp/f10\"]}}}}", .{ten.items});
    defer testing.allocator.free(eleven);
    try ten.appendSlice(testing.allocator, "]}}");
    switch (try dispatchBrowser(testing.allocator, ten.items, fx_engine, &.{}, 10, &grants, 0)) {
        .op => |op| testing.allocator.free(op.arg),
        else => return error.TestUnexpectedResult,
    }
    const long_path = try std.fmt.allocPrint(testing.allocator, "/{s}", .{"a" ** max_upload_path_bytes});
    defer testing.allocator.free(long_path);
    const long_req = try std.fmt.allocPrint(testing.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.upload\",\"params\":{{\"id\":12,\"selector\":\"#f\",\"files\":[\"{s}\"]}}}}", .{long_path});
    defer testing.allocator.free(long_req);
    const pre = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.upload\",\"params\":{\"id\":12,";
    const bad = [_][]const u8{
        pre ++ "\"selector\":\"#f\",\"files\":[\"a.txt\"]}}", // 상대 경로 — Chromium 이 렌더러를 죽였다(실측 k3)
        pre ++ "\"selector\":\"#f\",\"files\":[\"~/a.txt\"]}}",
        pre ++ "\"selector\":\"#f\",\"files\":[\"file:///tmp/a\"]}}",
        pre ++ "\"selector\":\"#f\",\"files\":[]}}",
        pre ++ "\"selector\":\"#f\",\"files\":\"/tmp/a\"}}",
        pre ++ "\"selector\":\"#f\",\"files\":[\"\"]}}",
        pre ++ "\"selector\":\"#f\",\"files\":[\"/tmp/a\\nb\"]}}", // 줄바꿈 — 모달에서 다른 파일처럼 보인다
        pre ++ "\"selector\":\"#f\",\"files\":[\"/tmp/a\\u0085b\"]}}", // C1(NEL)
        pre ++ "\"selector\":\"#f\",\"files\":[\"/tmp/a\\u007fb\"]}}", // DEL
        pre ++ "\"selector\":\"#f\",\"files\":[5]}}",
        pre ++ "\"selector\":\"#f\",\"files\":[\"/tmp/a\",\"/tmp/./a\"]}}", // 같은 경로 둘(글자로 정규화)
        pre ++ "\"selector\":\"#f\",\"files\":[\"/tmp/x/../a\",\"//tmp/a\"]}}",
        pre ++ "\"files\":[\"/tmp/a\"]}}", // 대상 없음
        pre ++ "\"selector\":\"#f\",\"ref\":\"n1\",\"files\":[\"/tmp/a\"]}}", // 대상 둘
        pre ++ "\"selector\":\"#f\"}}", // 파일 없음
        pre ++ "\"selector\":\"#f\",\"files\":[\"/tmp/a\"],\"remember\":true}}", // 모르는 키(「기억하기」 같은 것은 없다)
        eleven,
        long_req,
    };
    for (bad) |bytes| switch (try dispatchBrowser(testing.allocator, bytes, fx_engine, &.{}, 10, &grants, 0)) {
        .err => |e| {
            defer testing.allocator.free(e);
            try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.invalid_params)), try errCode(e));
        },
        .op => |op| {
            testing.allocator.free(op.arg);
            std.debug.print("accepted: {s}\n", .{bytes});
            return error.TestUnexpectedResult;
        },
        else => return error.TestUnexpectedResult,
    };
}

test "W9c③: uploadPathOk·lexicalPath — 절대·UTF-8·제어 문자 없음, 정규화는 // · . · .. 만 글자로" {
    try testing.expect(uploadPathOk("/a"));
    try testing.expect(uploadPathOk("/tmp/한 글.txt"));
    try testing.expect(uploadPathOk("/tmp/a\u{202e}b")); // 양방향 제어는 받는다 — 모달이 코드로 보인다
    try testing.expect(!uploadPathOk("a"));
    try testing.expect(!uploadPathOk(""));
    try testing.expect(!uploadPathOk("/tmp/\x00"));
    try testing.expect(!uploadPathOk("/tmp/\t"));
    try testing.expect(!uploadPathOk("/tmp/\xff")); // 깨진 UTF-8
    try testing.expect(!uploadPathOk("/tmp/\u{9b}x")); // C1 CSI
    var buf: [max_upload_path_bytes]u8 = undefined;
    try testing.expectEqualStrings("/tmp/a", lexicalPath("//tmp/./x/../a/", &buf));
    try testing.expectEqualStrings("/", lexicalPath("/..", &buf));
    try testing.expectEqualStrings("/a", lexicalPath("/../a", &buf));
}

test "W9c③: upload 결과는 origin·files(name·size) 만 — 모양이 틀리면 internal_error, 거부는 -32002 와 그 글(철회의 unauthorized 는 균일 글)" {
    const req = "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"browser.upload\",\"params\":{\"id\":12,\"selector\":\"#f\",\"files\":[\"/tmp/a\"]}}";
    {
        const w = try serializeBrowserResponseStatus(testing.allocator, req, .success, "{\"origin\":\"https://a.test\",\"files\":[{\"name\":\"a.txt\",\"size\":3,\"x\":1}],\"y\":2}");
        defer testing.allocator.free(w);
        try testing.expect(std.mem.indexOf(u8, w, "\"result\":{\"origin\":\"https://a.test\",\"files\":[{\"name\":\"a.txt\",\"size\":3}]}") != null);
    }
    for ([_][]const u8{
        "{}",
        "{\"origin\":\"https://a.test\",\"files\":[]}",
        "{\"origin\":1,\"files\":[{\"name\":\"a\",\"size\":1}]}",
        "{\"origin\":\"o\",\"files\":[{\"name\":\"a\",\"size\":-1}]}",
        "{\"origin\":\"o\",\"files\":[{\"name\":\"a\"}]}",
        "[",
    }) |payload| {
        const w = try serializeBrowserResponseStatus(testing.allocator, req, .success, payload);
        defer testing.allocator.free(w);
        try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.internal_error)), try errCode(w));
    }
    {
        const w = try serializeBrowserResponseStatus(testing.allocator, req, .unauthorized, "the user declined the upload");
        defer testing.allocator.free(w);
        try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.unauthorized)), try errCode(w));
        const m = try errMessage(w);
        defer testing.allocator.free(m);
        try testing.expectEqualStrings("the user declined the upload", m);
    }
    {
        // 다른 메서드의 unauthorized 는 글을 받아도 균일 글이다(이유를 흘리지 않는다).
        const click = "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"browser.click\",\"params\":{\"id\":12,\"selector\":\"#b\"}}";
        const w = try serializeBrowserResponseStatus(testing.allocator, click, .unauthorized, "secret reason");
        defer testing.allocator.free(w);
        try testing.expect(std.mem.indexOf(u8, w, "secret reason") == null);
    }
}
