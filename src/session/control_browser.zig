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
const cpg = @import("control_pane_grant.zig"); // 1e-confirm-1b: pane-bound confirm-grant 조회(§9.2 Model B — 세션 cap OR pane grant 가법)

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
    return null;
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
};

/// `browser.click`/`scroll` params `{id, selector | ref}`. locator=selector 또는 ref 정확히 하나.
pub const ActParams = struct { id: u64, locator: Locator };

/// `browser.type` params `{id, selector | ref, text}`. locator + text 필수.
pub const TypeParams = struct { id: u64, locator: Locator, text: []const u8 };

/// `browser.wait` 조건. 첫 슬라이스는 명시적 selector visible·현재 load 완료만 지원한다. URL/text/fn/network-idle과
/// click/type auto-wait는 후속(§9.4 D3·§9.5).
pub const WaitCondition = enum {
    selector,
    load,

    pub fn wire(self: WaitCondition) []const u8 {
        return switch (self) {
            .selector => "selector",
            .load => "load",
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
    if (selector != null and ref != null) return error.InvalidParams;
    if (selector) |s| return .{ .selector = s };
    if (ref) |r| return .{ .ref = r };
    return error.InvalidParams;
}

pub fn parseActParams(params: ?std.json.Value) ParamError!ActParams {
    const obj = try paramsObject(params);
    return .{ .id = try idFromObj(obj), .locator = try parseLocator(obj) };
}

pub fn parseTypeParams(params: ?std.json.Value) ParamError!TypeParams {
    const obj = try paramsObject(params);
    return .{ .id = try idFromObj(obj), .locator = try parseLocator(obj), .text = try strFromObj(obj, "text") };
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
    else
        return error.InvalidParams;
    const selector = try optStrFromObj(obj, "selector");
    switch (condition) {
        .selector => if (selector == null or selector.?.len == 0) return error.InvalidParams,
        .load => if (selector != null) return error.InvalidParams,
    }
    const timeout_ms: u32 = if (obj.get("timeout_ms")) |v| switch (v) {
        .integer => |i| if (i < 1 or i > @as(i64, wait_max_timeout_ms)) return error.InvalidParams else @intCast(i),
        else => return error.InvalidParams,
    } else wait_default_timeout_ms;
    return .{ .id = try idFromObj(obj), .condition = condition, .selector = selector, .timeout_ms = timeout_ms };
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

fn writeActArg(s: *std.json.Stringify, locator: Locator, text: ?[]const u8) !void {
    try s.beginObject();
    switch (locator) {
        .selector => |sel| {
            try s.objectField("selector");
            try s.write(sel);
        },
        .ref => |ref| {
            try s.objectField("ref");
            try s.write(ref);
        },
    }
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
    s.write(p.condition.wire()) catch return error.OutOfMemory;
    if (p.selector) |selector| {
        s.objectField("selector") catch return error.OutOfMemory;
        s.write(selector) catch return error.OutOfMemory;
    }
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
    try beginResult(s, id);
    try s.objectField("ok");
    try s.write(true);
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
    for (value) |byte| total += if (byte < 0x20) 6 else if (byte == '"' or byte == '\\') 2 else 1;
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

/// Swift `BrowserControl.snapshot`가 직렬화한 **JSON**(`{tree:[...]}` 또는 selector 미발견/루트 없음 시 `null`)을 파싱해
/// `{result:{snapshot:<value>}}`로 구조화 embed(§9.5.4 — getCookies와 동형, 에이전트 이중 파싱 불요). 파싱 실패(malformed)=
/// `InvalidSnapshotJson`(L4가 internal_error로 접음 — Swift 직렬화 버그 방어). caller free.
pub fn serializeSnapshotResult(gpa: std.mem.Allocator, id: cp.Id, snapshot_json: []const u8) (std.mem.Allocator.Error || error{InvalidSnapshotJson})![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, snapshot_json, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidSnapshotJson,
    };
    defer parsed.deinit();
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    (writeSnapshotResult(&s, id, parsed.value)) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
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
                serializeWaitTimeoutError(gpa, req)
            else
                cp.serializeError(gpa, req.id, .timeout, cp.ErrorCode.timeout.defaultMessage(), null),
            .invalid_params => cp.serializeError(gpa, req.id, .invalid_params, if (result.len > 0) result else "Invalid selector", null),
            .process_exited => cp.serializeError(gpa, req.id, .process_exited, cp.ErrorCode.process_exited.defaultMessage(), null),
            .unauthorized => cp.serializeError(gpa, req.id, .unauthorized, cp.ErrorCode.unauthorized.defaultMessage(), null),
            .success => unreachable,
            .failed => cp.serializeError(gpa, req.id, .internal_error, if (result.len > 0) result else if (bmethod == .wait) "browser wait failed" else "browser op failed", null),
        };
    }
    return switch (bmethod) {
        .navigate => serializeNavigateResult(gpa, req.id),
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
        .click, .type_text, .scroll => serializeOkBoolResult(gpa, req.id, std.mem.eql(u8, result, "true")),
        .wait => serializeNavigateResult(gpa, req.id),
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

fn serializeResultTooLarge(gpa: std.mem.Allocator, id: cp.Id, limit_bytes: usize, observed_at_least: usize) std.mem.Allocator.Error![]u8 {
    var data: std.json.ObjectMap = .empty;
    defer data.deinit(gpa);
    try data.put(gpa, "limit_bytes", .{ .integer = @intCast(limit_bytes) });
    try data.put(gpa, "observed_bytes_at_least", .{ .integer = @intCast(observed_at_least) });
    return cp.serializeError(gpa, id, .result_too_large, cp.ErrorCode.result_too_large.defaultMessage(), .{ .object = data });
}

fn serializeWaitTimeoutError(gpa: std.mem.Allocator, req: cp.Request) std.mem.Allocator.Error![]u8 {
    const p = parseWaitParams(req.params) catch return cp.serializeError(gpa, req.id, .internal_error, "invalid wait request state", null);
    var data: std.json.ObjectMap = .empty;
    defer data.deinit(gpa);
    try data.put(gpa, "condition", .{ .string = p.condition.wire() });
    try data.put(gpa, "timeout_ms", .{ .integer = p.timeout_ms });
    return cp.serializeError(gpa, req.id, .timeout, cp.ErrorCode.timeout.defaultMessage(), .{ .object = data });
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
};

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
///      **4b. pane confirm-grant 조회**(§9.2 Model B, 1e-confirm — `grants.isGranted(pane_selector, id, scope)`, 가법).
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
    /// 요청 pane의 selector surface_id(§8.4 tty-검증). pane confirm-grant 조회 키. null=self-origin 없음=grant 조회 불가.
    pane_selector: ?u64,
    /// pane-bound confirm-grant 저장소(§9.2 Model B). 세션 cap이 인가 못 할 때 가법 조회(1e-confirm-1b).
    grants: *const cpg.PaneGrantStore,
    now: u64,
) std.mem.Allocator.Error!BrowserDispatch {
    // ── 2. parseMethod 라우팅(§4.1). 방어: 라우터가 browser.* 만 이 함수로 보내지만, core != browser면 거부. ──
    const method = cp.parseMethod(req.method);
    if (method.core != .browser) return .{ .err = try errorResponse(gpa, req.id, .method_not_found) };

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
    //       grant는 tty-검증 pane 신원(pane_selector)에 묶인 (pane, target, scope). scope는 methodRequiredScope로
    //       판정(browser.getCookies=browser_storage·나머지 browser.*=browser). **behavior-preserving**: grant 없으면
    //       (빈 store 포함) 기존과 동일 균일 unauthorized. needs_grant/held-request 흐름(미grant면 확인 대기)은 1e-confirm-1c. ──
    const req_scope = capmod.methodRequiredScope(req.method); // cap authz·grant 조회·needs_grant 공용(browser.*=browser|browser_storage)
    if (!authorized) {
        if (req_scope) |sc| {
            if (pane_selector) |pane| {
                if (grants.isGranted(pane, target_id, sc)) {
                    authorized = true;
                    pane_grant = .{ .pane = pane, .target = target_id, .scope = sc };
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
        .click, .scroll => try serializeActArg(gpa, (parseActParams(req.params) catch return .{ .err = try errorResponse(gpa, req.id, .invalid_params) }).locator, null),
        .type_text => blk: {
            const p = parseTypeParams(req.params) catch return .{ .err = try errorResponse(gpa, req.id, .invalid_params) };
            break :blk try serializeActArg(gpa, p.locator, p.text);
        },
        .wait => try serializeWaitArg(gpa, parseWaitParams(req.params) catch return .{ .err = try errorResponse(gpa, req.id, .invalid_params) }),
        // snapshot(§9.5.4): interactive_only/max_depth/selector를 arg에 실어 Swift accname JS가 소비. base browser scope.
        .snapshot => try serializeSnapshotArg(gpa, parseSnapshotParams(req.params) catch return .{ .err = try errorResponse(gpa, req.id, .invalid_params) }),
        // console(§9.5.9): clear 플래그를 arg에 실어 Swift가 pull(서버 버퍼 반환 + clear면 비움). base browser scope.
        .console => try serializeConsoleArg(gpa, parseConsoleParams(req.params) catch return .{ .err = try errorResponse(gpa, req.id, .invalid_params) }),
        .subscribe => unreachable, // 위에서 이미 분기
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
    .{ .surface_id = 11, .title = "browser", .window = 1, .detail = .{ .web = .{ .url = "https://example/", .panel_kind = .browser, .loading = false, .trust = .untrusted } } },
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
    try grants.grant(.{ .pane = 5, .target = 11, .scope = .browser_storage }); // storage grant
    // getCookies(browser_storage) → 인가 → .op.
    switch (try dispatchGrant("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.getCookies\",\"params\":{\"id\":11}}", 5, &grants)) {
        .op => |op| {
            defer testing.allocator.free(op.arg);
            try testing.expectEqual(BrowserMethod.get_cookies, op.method);
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
//   테스트가 사라졌다(옛 "screenshot 미구현→method_not_found"를 op 테스트로 교체). browser.back/forward/refresh는 §9.4
//   표엔 있으나 parseBrowserMethod 미구현(null)이라 에이전트가 부르면 method_not_found여야 한다(authorized 무관 — 메서드명은
//   공개 API라 oracle 아님). 유효 cap이어도 이 접힘을 확인해 복원.
test "dispatchBrowser: 유효 cap + 미구현 browser 메서드(back) → method_not_found(-32601)" {
    const req = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.back\",\"params\":{\"id\":11}}";
    const wire = try dispatchErr(req, browserCap(11));
    defer testing.allocator.free(wire);
    try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.method_not_found)), try errCode(wire));
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
    // 미구현/미지 → null.
    try testing.expect(parseBrowserMethod("back") == null);
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
