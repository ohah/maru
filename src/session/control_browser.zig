//! control_browser — 컨트롤 플레인 **`browser.*` wire 스키마 + 디스패치 + authz**(L2 순수, OS-중립).
//! Track C slice 5a(Phase 5 첫 슬라이스). 단일 출처: docs/control-plane.md §9.1(5a browser core)·§9(browser.*
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
//!   ② `dispatchBrowser`: 요청 한 줄 + 주입 snapshot + 주입 `caller_cap`(라이브 서버가 nonce→Capability lookup해
//!      넘김, 1e) → `BrowserDispatch`(게이트 실패=`err` 응답 바이트 / 통과=`op` 실행 op). **정확한 보안 순서**(아래).
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

// ── ① browser.* wire 스키마(§9.1 ①) ──────────────────────────────────────────────────────────────────────

/// `browser.*` 메서드(§9 표). **5a 구현 범위**(사용자 결정 2026-07-10)는 핵심 3개만 — 나머지(screenshot/back/
/// forward/refresh/findElement/click/sendKeys/getCookies)는 5d에서 이 enum에 추가된다. `parseBrowserMethod`가
/// 인식 못 하면(screenshot 등) dispatch가 `method_not_found`로 접는다.
pub const BrowserMethod = enum {
    /// `browser.navigate {id, url}` → 5d `load(URLRequest)`.
    navigate,
    /// `browser.getUrl {id}` → 5d `.url`.
    get_url,
    /// `browser.executeScript {id, script}` (args는 5d) → 5d `evaluateJavaScript`.
    execute_script,
    /// `browser.subscribe {id, events?}`(5f-0b-3b) → **동기 registry 구독**(async op 아님). L4가 SubscriberRegistry에
    /// 등록하고 `{subscriber_id}` 응답. events 없으면 전체, 있으면 그 종류만(§9.5.2).
    subscribe,
};

/// `parseMethod("browser.navigate").rest`(= "navigate")를 `BrowserMethod`로 매핑한다(순수, 할당 없음). wire 이름은
/// camelCase(§9 표 그대로): navigate/getUrl/executeScript. 5a 미구현 메서드(screenshot 등)·미지 문자열 → null
/// (dispatch가 `method_not_found`). enum 자체가 wire↔내부 격리라 내부 이름 리팩터가 wire를 안 흔든다(§3 정신).
pub fn parseBrowserMethod(rest: []const u8) ?BrowserMethod {
    if (eq(rest, "navigate")) return .navigate;
    if (eq(rest, "getUrl")) return .get_url;
    if (eq(rest, "executeScript")) return .execute_script;
    if (eq(rest, "subscribe")) return .subscribe;
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

/// `browser.executeScript` params(§9 표 `{id, script, args?}`). **5a는 script만**(args는 5d — §9.1 ①).
pub const ExecuteScriptParams = struct {
    id: u64,
    script: []const u8,
};

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
    return .{ .id = try idFromObj(obj), .script = try strFromObj(obj, "script") };
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

/// `browser.executeScript` 성공 result: `{"jsonrpc":"2.0","id":<id>,"result":{"result":<value>}}`. `value`는 스크립트
/// 반환값(불투명 JSON — 5d가 `evaluateJavaScript` 결과를 채운다). 5a는 스키마만.
pub fn serializeExecuteScriptResult(gpa: std.mem.Allocator, id: cp.Id, value: std.json.Value) std.mem.Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    (writeExecuteScriptResult(&s, id, value)) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn writeExecuteScriptResult(s: *std.json.Stringify, id: cp.Id, value: std.json.Value) !void {
    try beginResult(s, id);
    try s.objectField("result");
    try s.write(value);
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

// result envelope open/close는 cp.beginResult/endResult 단일 출처 재사용(리뷰12 [4] — 브리지와 공유, 로컬 복제 제거).
const beginResult = cp.beginResult;
const endResult = cp.endResult;

/// **5e-2b: L4 completion이 Swift `BrowserControl` 결과를 browser.* 응답으로 직렬화한다.** op은 응답 id/method를 안
/// 싣으므로(§9.3 ⑥) 원 `request_bytes`(in-flight pending이 아직 소유 — resolve 전이라 유효)를 재파싱해 id·method를
/// 얻고, method별 result 헬퍼로 실는다. `ok=false`(webView 부재·evaluateJavaScript 에러 등)면 `internal_error`(+`result`
/// 를 message로). `result`는 method별: navigate=무시·getUrl=url·executeScript=스크립트 반환값을 **문자열로** 싣는다
/// (JS 값 → 문자열; 진짜 JSON 값 embed는 후속). 재파싱 실패·비-browser는 방어적 내부오류(dispatch가 이미 검증했으므로 도달 안 함).
pub fn serializeBrowserResponse(gpa: std.mem.Allocator, request_bytes: []const u8, ok: bool, result: []const u8) std.mem.Allocator.Error![]u8 {
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
    if (!ok) {
        const msg = if (result.len > 0) result else "browser op failed";
        return cp.serializeError(gpa, req.id, .internal_error, msg, null);
    }
    return switch (bmethod) {
        .navigate => serializeNavigateResult(gpa, req.id),
        .get_url => serializeGetUrlResult(gpa, req.id, result),
        .execute_script => serializeExecuteScriptResult(gpa, req.id, .{ .string = result }),
        .subscribe => unreachable, // subscribe는 async op이 아니라 이 함수(op 완료 응답)로 안 온다 — serializeSubscribeResponse 사용
    };
}

// ── ② dispatchBrowser(§9.1 ②③ — 정확한 보안 순서) ─────────────────────────────────────────────────────────

/// **5e: 모든 게이트(authz·params·surface)를 통과한 인가된 browser 요청의 실행 op.** L4가 main-loop marshal
/// (§5-async deferRequest) → Swift `BrowserControl`이 `webPanels[surface_id]`의 WKWebView API를 호출한다. `arg`는
/// method별 인자(navigate=url·executeScript=script·getUrl=빈) — `gpa`로 **dupe한 소유 슬라이스**라(파싱 arena와
/// 수명 분리) caller가 op를 소비할 때 free한다(§9.3 "arg는 cross_gpa 복사"). 응답 id/method는 L4가 완료 시
/// pending.request_bytes를 재파싱해 얻으므로(§9.3 ⑥) op엔 실행에 필요한 surface_id·method·arg만 싣는다.
pub const BrowserOp = struct {
    surface_id: u64,
    method: BrowserMethod,
    /// gpa-owned(caller가 free). navigate=url·executeScript=script·getUrl=빈("").
    arg: []const u8,
};

/// `browser.subscribe`의 인가·검증 통과 결과(5f-0b-3b): 대상 web surface + 이벤트 필터. async op이 아니라 L4가
/// SubscriberRegistry에 **동기 등록**할 지시(연결 outbound는 L4가 pending에서 가져와 주입).
pub const BrowserSubscribe = struct {
    surface_id: u64,
    filter: cev.EventFilter,
};

/// dispatchBrowser 결과: 게이트 실패면 응답 바이트(`err`, gpa-owned), async op은 `op`, 동기 구독은 `subscribe`(5f-0b-3b).
/// **정확히 하나**만 유효.
pub const BrowserDispatch = union(enum) {
    err: []u8,
    op: BrowserOp,
    subscribe: BrowserSubscribe,
};

/// `browser.*` 요청 한 줄(ndjson frame, 개행 제외)을 주입 snapshot + 주입 `caller_cap`으로 처리한다. 게이트 실패면
/// `.err`(응답 바이트, gpa-owned), 통과면 `.op`(인가·유효한 실행 op — L4가 marshal). OOM만 error로 전파. caller가
/// `.err` 또는 `.op.arg`를 free한다.
///
/// `caller_cap`은 라이브 서버(L4)가 소켓 auth frame의 nonce를 1e `lookupByNonce`해 넘긴 `Capability`(null=cap 없음).
/// authz는 `requested_surface_id=target id`(cap이 이 web surface에 묶였는지), `requested_generation=cap.generation`.
/// **browser cap의 anchor는 selector(에이전트 자기 surface)가 아니라 target(제어 대상 web surface)** — dispatchAuthenticated가
/// browser.*를 이 함수로 위임하며 selector 앵커를 안 쓴다(§9.3). `now`는 TTL 판정 시각.
///
/// **보안 순서(§8.3·§9.1 ②③ — 각 단계 정확히, 모듈 헤더 §보안 불변식):**
///   1. parseMessage → request 아니면 `invalid_request`(id=null). parse 실패 → `parseFailureCode`.
///   2. parseMethod. `core != .browser`면 `method_not_found`(방어 — 라우팅상 안 옴).
///   3. `id` 파싱(params `id`=u64). 형식 오류 → `invalid_params`(authz가 target을 알아야 먼저; 형식 오류는 oracle 아님).
///   4. **authz** — cap null이면 즉시 `unauthorized`. 있으면 `authorize(cap, id, cap.generation, method, now)`.
///      `.granted`가 아니면(어떤 deny든) **균일 `unauthorized`**(존재검사보다 먼저 — oracle 방지). deny 이유 노출 금지.
///   5. `parseBrowserMethod(method.rest)`. null(screenshot 등 5a 미구현) → `method_not_found`(authz 뒤 — 미인가
///      caller가 메서드 탐침 못 하게).
///   6. method별 params 파싱(url/script). 오류 → `invalid_params`. url/script는 gpa로 dupe(op.arg).
///   7. **surface 검증(방어)** — snapshot에서 `id`로 SurfaceDto 찾기. 없으면 `unauthorized`(존재 누설 금지), 있으나
///      `detail != .web`이면 `unauthorized`(browser cap은 web surface 전용).
///   8. **op 반환(5e)** — 여기까지 통과 = 인가·유효. `BrowserOp{surface_id, method, arg(dupe)}`. L4가 실행.
pub fn dispatchBrowser(
    gpa: std.mem.Allocator,
    request_bytes: []const u8,
    snapshot: cs.CollectorSnapshot,
    caller_cap: ?capmod.Capability,
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
    return browserOpFromRequest(gpa, req, snapshot, caller_cap, now);
}

/// dispatchBrowser의 **파싱된 req** 버전(steps 2~8). `dispatchAuthenticated`(1e)가 이미 파싱한 req로 직접 호출해
/// 이중 파싱을 피한다(리뷰 [10] 정신). dispatchBrowser는 parse 후 이걸 부른다. `req.params`/`req.method` 슬라이스는
/// 호출자 parseMessage arena를 빌리므로 이 함수는 그 수명 안에서 즉시 처리하고 op.arg만 gpa-dupe로 분리한다.
pub fn browserOpFromRequest(
    gpa: std.mem.Allocator,
    req: cp.Request,
    snapshot: cs.CollectorSnapshot,
    caller_cap: ?capmod.Capability,
    now: u64,
) std.mem.Allocator.Error!BrowserDispatch {
    // ── 2. parseMethod 라우팅(§4.1). 방어: 라우터가 browser.* 만 이 함수로 보내지만, core != browser면 거부. ──
    const method = cp.parseMethod(req.method);
    if (method.core != .browser) return .{ .err = try errorResponse(gpa, req.id, .method_not_found) };

    // ── 3. id 파싱(target web surface_id). authz(4)가 target을 알아야 하므로 먼저. 형식 오류는 surface 존재
    //       oracle이 아니라 요청 형식 오류다(session.get과 동일) → invalid_params. ──
    const target_id = readIdParam(req.params) catch return .{ .err = try errorResponse(gpa, req.id, .invalid_params) };

    // ── 4. authz(§8.3 균일 unauthorized — 존재검사 이전, deny 이유 절대 노출 금지). ──
    const caller = caller_cap orelse return .{ .err = try errorResponse(gpa, req.id, .unauthorized) };
    switch (capmod.authorize(caller, target_id, caller.generation, req.method, now)) {
        .granted => {},
        .deny => return .{ .err = try errorResponse(gpa, req.id, .unauthorized) },
    }

    // ── 5. BrowserMethod 파싱(authz 뒤 — 미인가 caller가 메서드 탐침 못 하게). 5a 미구현(screenshot 등) → method_not_found. ──
    const bmethod = parseBrowserMethod(method.rest) orelse return .{ .err = try errorResponse(gpa, req.id, .method_not_found) };

    // ── 5f-0b-3b: subscribe는 async op이 아니라 동기 registry 구독. 필터 파싱(6) + surface 검증(7) 후 `.subscribe` 반환
    //    (arg dupe 없음 — 필터는 값 타입). 나머지(navigate/getUrl/executeScript)는 아래 async-op 경로. ──
    if (bmethod == .subscribe) {
        const filter = parseSubscribeFilter(req.params) catch return .{ .err = try errorResponse(gpa, req.id, .invalid_params) };
        const sub_dto = snapshot.find(target_id);
        if (sub_dto == null or sub_dto.?.kind() != .web) return .{ .err = try errorResponse(gpa, req.id, .unauthorized) };
        return .{ .subscribe = .{ .surface_id = target_id, .filter = filter } };
    }

    // ── 6. method별 params 파싱 + arg(url/script) dupe(파싱 arena와 수명 분리 — op는 pm.deinit 뒤에도 유효해야). ──
    const arg: []const u8 = switch (bmethod) {
        .navigate => try gpa.dupe(u8, (parseNavigateParams(req.params) catch return .{ .err = try errorResponse(gpa, req.id, .invalid_params) }).url),
        .get_url => try gpa.dupe(u8, ""), // {id}만 — 인자 없음(빈 슬라이스도 dupe해 free 규약 일관)
        .execute_script => try gpa.dupe(u8, (parseExecuteScriptParams(req.params) catch return .{ .err = try errorResponse(gpa, req.id, .invalid_params) }).script),
        .subscribe => unreachable, // 위에서 이미 분기
    };
    // arg는 이제 gpa-owned. 아래 surface 검증 실패(.err 정상 반환)면 op를 안 만들므로 여기서 명시 free해야 누수 없음
    // (errdefer는 error 반환에만 걸려 .err union 반환은 안 잡는다 — free 후 errorResponse가 OOM나도 double-free 없음).

    // ── 7. surface 검증(방어, §9.1 ②·⑧). cap이 이 surface에 묶였는데 snapshot에 없으면 respawn/닫힘 → 존재 누설
    //       금지로 균일 unauthorized. 있으나 web이 아니면(terminal) browser cap을 terminal에 쓰는 것이라 unauthorized. ──
    const dto = snapshot.find(target_id);
    if (dto == null or dto.?.kind() != .web) {
        gpa.free(arg); // op 미생성 → arg 해제
        return .{ .err = try errorResponse(gpa, req.id, .unauthorized) };
    }

    // ── 8. op 반환(5e). 여기까지 통과 = 인가·유효한 web surface 대상. L4가 §5-async marshal → Swift BrowserControl. ──
    return .{ .op = .{ .surface_id = target_id, .method = bmethod, .arg = arg } };
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

// 게이트 실패(.err) 기대 — 응답 바이트(호출자 free). .op면 op.arg free 후 실패.
fn dispatchErr(bytes: []const u8, cap: ?capmod.Capability) ![]u8 {
    switch (try dispatchBrowser(testing.allocator, bytes, fx, cap, 0)) {
        .err => |e| return e,
        .op => |op| {
            testing.allocator.free(op.arg);
            return error.ExpectedErrGotOp;
        },
        .subscribe => return error.ExpectedErrGotSubscribe, // 이 헬퍼는 subscribe 요청 안 씀(navigate 등)
    }
}
// 게이트 통과(.op) 기대 — op(호출자 op.arg free). .err면 free 후 실패.
fn dispatchOp(bytes: []const u8, cap: ?capmod.Capability) !BrowserOp {
    switch (try dispatchBrowser(testing.allocator, bytes, fx, cap, 0)) {
        .op => |op| return op,
        .err => |e| {
            testing.allocator.free(e);
            return error.ExpectedOpGotErr;
        },
        .subscribe => return error.ExpectedOpGotSubscribe,
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
    switch (try dispatchBrowser(testing.allocator, req_navigate_11, fx, cap, 100)) {
        .err => |wire| {
            defer testing.allocator.free(wire);
            try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.unauthorized)), try errCode(wire));
        },
        .op => |op| {
            testing.allocator.free(op.arg);
            return error.ExpectedErrGotOp;
        },
        .subscribe => unreachable, // navigate 요청이라 subscribe 안 옴
    }
    // 대조: now=99 < exp면 만료 아님 → 게이트 통과해 **op**라야 이 테스트가 만료를 실제로 검사.
    switch (try dispatchBrowser(testing.allocator, req_navigate_11, fx, cap, 99)) {
        .op => |op| testing.allocator.free(op.arg),
        .err => |wire| {
            testing.allocator.free(wire);
            return error.ExpectedOpGotErr;
        },
        .subscribe => unreachable,
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
    // executeScript arg = script.
    const op_js = try dispatchOp("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"browser.executeScript\",\"params\":{\"id\":11,\"script\":\"document.title\"}}", browserCap(11));
    defer testing.allocator.free(op_js.arg);
    try testing.expectEqual(BrowserMethod.execute_script, op_js.method);
    try testing.expectEqualStrings("document.title", op_js.arg);
}

// ── 5f-0b-3b: browser.subscribe — async op이 아니라 동기 `.subscribe`(surface + 필터). L4가 registry 등록. ──
test "dispatchBrowser(5f-0b-3b): 유효 browser cap + web surface → .subscribe{surface, filter}" {
    // events 없음 → 전체 필터.
    switch (try dispatchBrowser(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.subscribe\",\"params\":{\"id\":11}}", fx, browserCap(11), 0)) {
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
    }
    // events=["navigated","dialog"] → 그 둘만(loadState 제외).
    switch (try dispatchBrowser(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"browser.subscribe\",\"params\":{\"id\":11,\"events\":[\"navigated\",\"dialog\"]}}", fx, browserCap(11), 0)) {
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
    switch (try dispatchBrowser(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.subscribe\",\"params\":{\"id\":11,\"events\":[\"navigated\",\"navigated\",\"navigated\",\"navigated\",\"navigated\",\"navigated\"]}}", fx, browserCap(11), 0)) {
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
    }
}

// ── 6) 유효 cap + browser.screenshot(5a 미구현) → method_not_found ── authz는 통과, method 파싱서 접힘
test "dispatchBrowser: 유효 cap + browser.screenshot(5a 미구현) → method_not_found(-32601)" {
    // screenshot도 browser.* 라 methodRequiredScope=.browser → authz granted → parseBrowserMethod(null) → method_not_found.
    const req = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.screenshot\",\"params\":{\"id\":11}}";
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
test "parseBrowserMethod: navigate/getUrl/executeScript 인식, screenshot·미지는 null" {
    try testing.expectEqual(BrowserMethod.navigate, parseBrowserMethod("navigate").?);
    try testing.expectEqual(BrowserMethod.get_url, parseBrowserMethod("getUrl").?);
    try testing.expectEqual(BrowserMethod.execute_script, parseBrowserMethod("executeScript").?);
    // 5a 미구현/미지 → null.
    try testing.expect(parseBrowserMethod("screenshot") == null);
    try testing.expect(parseBrowserMethod("back") == null);
    try testing.expect(parseBrowserMethod("get_url") == null); // snake_case는 wire 이름 아님(camelCase 엄수)
    try testing.expect(parseBrowserMethod("") == null);
    // parseMethod("browser.navigate").rest가 곧 parseBrowserMethod 입력임을 확인(1a와 결합).
    try testing.expectEqual(BrowserMethod.navigate, parseBrowserMethod(cp.parseMethod("browser.navigate").rest).?);
    try testing.expectEqual(BrowserMethod.execute_script, parseBrowserMethod(cp.parseMethod("browser.executeScript").rest).?);
}

// ── 9b) params 파서 단위(유효·오류) ──
test "params 파서: navigate {id,url}·getUrl {id}·executeScript {id,script} 유효/오류" {
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
        var pm = try cp.parseMessage(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.executeScript\",\"params\":{\"id\":3,\"script\":\"1+1\"}}");
        defer pm.deinit();
        const p = try parseExecuteScriptParams(pm.message.request.params);
        try testing.expectEqual(@as(u64, 3), p.id);
        try testing.expectEqualStrings("1+1", p.script);
    }
    // 오류: url 없음, id 비정수, script 비문자열, params 부재/비객체.
    try testing.expectError(error.InvalidParams, parseNavigateParamsFromWire("{\"id\":11}")); // url 없음
    try testing.expectError(error.InvalidParams, parseNavigateParamsFromWire("{\"id\":\"x\",\"url\":\"u\"}")); // id 비정수
    try testing.expectError(error.InvalidParams, parseNavigateParamsFromWire("{\"id\":-1,\"url\":\"u\"}")); // id 음수
    try testing.expectError(error.InvalidParams, parseExecuteScriptParamsFromWire("{\"id\":3,\"script\":5}")); // script 비문자열
    try testing.expectError(error.InvalidParams, parseGetUrlParamsFromWire("{}")); // id 없음
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
    // executeScript ok → {result:{result:"<result 문자열>"}}.
    {
        const w = try serializeBrowserResponse(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.executeScript\",\"params\":{\"id\":11,\"script\":\"document.title\"}}", true, "My Page");
        defer testing.allocator.free(w);
        var pm = try cp.parseMessage(testing.allocator, w);
        defer pm.deinit();
        try testing.expectEqualStrings("My Page", pm.message.response.result.?.object.get("result").?.string);
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
}

test {
    testing.refAllDecls(@This());
}
