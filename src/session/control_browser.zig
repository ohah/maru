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
//!   ② `dispatchBrowser`: 요청 한 줄 + 주입 snapshot + 주입 `caller_cap`(라이브 서버가 nonce→Capability resolve해
//!      넘김, 1e) → 응답 한 줄. **정확한 보안 순서**(아래 §보안 불변식).
//!   ③ authz(§8.3): `browser.*`→`ScopeClass.browser`(1e `methodRequiredScope`가 단일 출처). browser cap 없거나
//!      deny면 **존재검사 이전에 균일 unauthorized**(oracle 방지).
//!
//! **범위 밖(구현 금지 — 5b~5d)**: isolated `WKContentWorld` 브리지(`window.maru.*`, 5b), `maru-app://` 스킴+CSP
//! (5c), 실 WKWebView API 호출(navigate=`load`/executeScript=`evaluateJavaScript`/…, 5d), main-loop marshal,
//! 나머지 메서드(screenshot/back/forward/refresh/findElement/click/sendKeys/getCookies) 스키마·실행(5d). 5a는
//! 모든 게이트를 통과한 뒤 **제어 코어 skeleton**이 `internal_error`("... not implemented (5d)")로 실행을 보류한다.
//! 5d에서 이 지점을 `executeBrowser`로 교체해 main-loop로 marshal → Swift `BrowserControl`이 WKWebView API를 호출한다.
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
//! **L2 순수:** std + control_plane(1a) + control_capability(1e) + control_surface(1c)만 import한다
//! (app/pty/platform/chrome import 0 — tests/boundary/imports.zig가 강제). OS 타입 0.

const std = @import("std");
const cp = @import("control_plane.zig");
const capmod = @import("control_capability.zig");
const cs = @import("control_surface.zig");

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
};

/// `parseMethod("browser.navigate").rest`(= "navigate")를 `BrowserMethod`로 매핑한다(순수, 할당 없음). wire 이름은
/// camelCase(§9 표 그대로): navigate/getUrl/executeScript. 5a 미구현 메서드(screenshot 등)·미지 문자열 → null
/// (dispatch가 `method_not_found`). enum 자체가 wire↔내부 격리라 내부 이름 리팩터가 wire를 안 흔든다(§3 정신).
pub fn parseBrowserMethod(rest: []const u8) ?BrowserMethod {
    if (eq(rest, "navigate")) return .navigate;
    if (eq(rest, "getUrl")) return .get_url;
    if (eq(rest, "executeScript")) return .execute_script;
    return null;
}

/// dispatch 실행 보류 메시지(§8·에러) 및 result 직렬화에서 쓰는 정규 wire 메서드 이름(BrowserMethod → "browser.*").
fn browserMethodName(m: BrowserMethod) []const u8 {
    return switch (m) {
        .navigate => "browser.navigate",
        .get_url => "browser.getUrl",
        .execute_script => "browser.executeScript",
    };
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

// ── result 직렬화(§9.1 ① — 5d가 값 채울 때 쓸 헬퍼, 5a도 단위 test) ─────────────────────────────────────────
// serializeError처럼 gpa로 **완결 JSON-RPC 응답 한 줄**(`{jsonrpc, id, result:{...}}`)을 빌드한다. 5d dispatch가
// 실행 결과를 이 헬퍼로 실어 응답한다(5a dispatch는 실행 보류라 아직 호출하지 않지만 스키마를 확정·test). caller free.
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

/// `{"jsonrpc":"2.0","id":<id>,"result":{` 까지 연다(1a `writeId` 재사용). body는 호출자가 채우고 `endResult`로 닫는다.
fn beginResult(s: *std.json.Stringify, id: cp.Id) !void {
    try s.beginObject();
    try s.objectField("jsonrpc");
    try s.write(cp.jsonrpc_version);
    try s.objectField("id");
    try cp.writeId(s, id);
    try s.objectField("result");
    try s.beginObject();
}

fn endResult(s: *std.json.Stringify) !void {
    try s.endObject(); // result body
    try s.endObject(); // envelope
}

// ── ② dispatchBrowser(§9.1 ②③ — 정확한 보안 순서) ─────────────────────────────────────────────────────────

/// `browser.*` 요청 한 줄(ndjson frame, 개행 제외)을 주입 snapshot + 주입 `caller_cap`으로 처리해 **응답 한 줄
/// 바이트**를 만든다. OOM만 error로 전파(응답 자체를 만들 메모리도 없을 때). caller가 반환 슬라이스를 free한다.
///
/// `caller_cap`은 라이브 서버(L4)가 소켓 auth frame의 nonce를 1e `resolve`해 넘긴 `Capability`(null=cap 없음).
/// **5a: 라이브 서버가 resolve에서 generation 신선도를 이미 강제**하므로 authz엔 `requested_generation=cap.generation`
/// 을 넘긴다(generation 검사는 이 경로에선 항상 통과 — surface·scope 검사가 실질 게이트). `now`는 TTL 판정 시각.
///
/// **보안 순서(§8.3·§9.1 ②③ — 각 단계 정확히, 모듈 헤더 §보안 불변식):**
///   1. parseMessage → request 아니면 `invalid_request`(id=null). parse 실패 → `parseFailureCode`.
///   2. parseMethod. `core != .browser`면 `method_not_found`(방어 — 라우팅상 안 옴).
///   3. `id` 파싱(params `id`=u64). 형식 오류 → `invalid_params`(authz가 target을 알아야 먼저; 형식 오류는 oracle 아님).
///   4. **authz** — cap null이면 즉시 `unauthorized`. 있으면 `authorize(cap, id, cap.generation, method, now)`.
///      `.granted`가 아니면(어떤 deny든) **균일 `unauthorized`**(존재검사보다 먼저 — oracle 방지). deny 이유 노출 금지.
///   5. `parseBrowserMethod(method.rest)`. null(screenshot 등 5a 미구현) → `method_not_found`(authz 뒤 — 미인가
///      caller가 메서드 탐침 못 하게).
///   6. method별 params 파싱(url/script). 오류 → `invalid_params`.
///   7. **surface 검증(방어)** — snapshot에서 `id`로 SurfaceDto 찾기. 없으면 `unauthorized`(존재 누설 금지), 있으나
///      `detail != .web`이면 `unauthorized`(browser cap은 web surface 전용). authz의 surface_mismatch가 다른 surface를
///      막지만, cap의 surface 자체가 web인지 방어 확인.
///   8. **제어코어 skeleton** — 여기까지 통과 = 인가·유효. 실 WKWebView 실행은 5d. `internal_error`로 실행 보류.
pub fn dispatchBrowser(
    gpa: std.mem.Allocator,
    request_bytes: []const u8,
    snapshot: cs.CollectorSnapshot,
    caller_cap: ?capmod.Capability,
    now: u64,
) std.mem.Allocator.Error![]u8 {
    // ── 1. parse. 실패는 JSON-RPC 관례대로 id=null 에러 응답으로 접는다(OOM만 전파). ──
    var pm = cp.parseMessage(gpa, request_bytes) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return errorResponse(gpa, .null, cp.parseFailureCode(e)),
    };
    defer pm.deinit();

    // browser.*는 응답에 request id가 필요하므로 request만 디스패치한다(비-request → invalid_request, 1d와 동일).
    const req = switch (pm.message) {
        .request => |r| r,
        else => return errorResponse(gpa, .null, .invalid_request),
    };

    // ── 2. parseMethod 라우팅(§4.1). 방어: 라우터가 browser.* 만 이 함수로 보내지만, core != browser면 거부. ──
    const method = cp.parseMethod(req.method);
    if (method.core != .browser) return errorResponse(gpa, req.id, .method_not_found);

    // ── 3. id 파싱(target web surface_id). authz(4)가 target을 알아야 하므로 먼저. 형식 오류는 surface 존재
    //       oracle이 아니라 요청 형식 오류다(session.get과 동일) → invalid_params. ──
    const target_id = readIdParam(req.params) catch return errorResponse(gpa, req.id, .invalid_params);

    // ── 4. authz(§8.3 균일 unauthorized — 존재검사 이전, deny 이유 절대 노출 금지). ──
    // cap 부재면 즉시 unauthorized. 있으면 authorize: requested_surface_id=target id(cap이 이 surface에 묶였는지),
    // requested_generation=cap.generation(5a: 라이브 서버 resolve가 generation 신선도 이미 강제). 결과가 granted가
    // 아니면(revoked/expired/surface_mismatch/generation_mismatch/scope_insufficient/unknown_method 어떤 deny든)
    // 이유를 버리고 하나의 unauthorized로 접는다(oracle 방지 — DenyReason은 내부 진단 전용이라 wire로 안 나간다).
    const caller = caller_cap orelse return errorResponse(gpa, req.id, .unauthorized);
    switch (capmod.authorize(caller, target_id, caller.generation, req.method, now)) {
        .granted => {},
        .deny => return errorResponse(gpa, req.id, .unauthorized),
    }

    // ── 5. BrowserMethod 파싱(authz 뒤 — 미인가 caller가 메서드 탐침 못 하게). 5a 미구현(screenshot 등) → method_not_found. ──
    const bmethod = parseBrowserMethod(method.rest) orelse return errorResponse(gpa, req.id, .method_not_found);

    // ── 6. method별 params 파싱(url/script). id는 3에서 검증됐고, 여기선 스키마 파서(단일 출처)로 전체를 재검증해
    //       method-specific 필드(url/script) 유무·타입을 확인한다. 오류 → invalid_params. ──
    switch (bmethod) {
        .navigate => _ = parseNavigateParams(req.params) catch return errorResponse(gpa, req.id, .invalid_params),
        .get_url => {}, // {id}만 — 3에서 이미 검증. 추가 필드 없음.
        .execute_script => _ = parseExecuteScriptParams(req.params) catch return errorResponse(gpa, req.id, .invalid_params),
    }

    // ── 7. surface 검증(방어, §9.1 ②·⑧). cap이 이 surface에 묶였는데 snapshot에 없으면 respawn/닫힘 → 존재 누설
    //       금지로 균일 unauthorized. 있으나 web이 아니면(terminal) browser cap을 terminal에 쓰는 것이라 unauthorized. ──
    const dto = snapshot.find(target_id) orelse return errorResponse(gpa, req.id, .unauthorized);
    if (dto.kind() != .web) return errorResponse(gpa, req.id, .unauthorized);

    // ── 8. 제어코어 skeleton(§9.1 ②·④). 여기까지 통과 = 인가·유효한 web surface 대상. 실 WKWebView 실행은 5d다.
    //       5d에서 이 지점을 executeBrowser로 교체해 main-loop로 marshal → Swift BrowserControl이 WKWebView API
    //       (navigate=load / getUrl=.url / executeScript=evaluateJavaScript, §9)를 호출하고 결과를 위 result 직렬화
    //       헬퍼로 응답한다. 5a 계약 = 모든 게이트 통과 후 실행 보류. ──
    return notImplementedResponse(gpa, req.id, bmethod);
}

/// 코드의 default message로 에러 응답 한 줄을 만든다(1a `serializeError` 재사용). 편의 wrapper(1d와 동일).
fn errorResponse(gpa: std.mem.Allocator, id: cp.Id, code: cp.ErrorCode) std.mem.Allocator.Error![]u8 {
    return cp.serializeError(gpa, id, code, code.defaultMessage(), null);
}

/// 제어코어 skeleton 응답(§9.1 ②④): `internal_error`(-32603) + message `"browser.<method> not implemented (5d)"`.
/// 5d에서 실 실행으로 교체된다(모듈 헤더). message에 method 이름을 실어 어떤 op가 보류됐는지 진단만 노출(민감 정보 아님).
fn notImplementedResponse(gpa: std.mem.Allocator, id: cp.Id, m: BrowserMethod) std.mem.Allocator.Error![]u8 {
    const msg = try std.fmt.allocPrint(gpa, "{s} not implemented (5d)", .{browserMethodName(m)});
    defer gpa.free(msg);
    return cp.serializeError(gpa, id, .internal_error, msg, null);
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

fn dispatch(bytes: []const u8, cap: ?capmod.Capability) ![]u8 {
    return dispatchBrowser(testing.allocator, bytes, fx, cap, 0);
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
    const wire = try dispatch(req_navigate_11, null);
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
        const wire = try dispatch(req_navigate_11, meta_cap);
        defer testing.allocator.free(wire);
        try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.unauthorized)), try errCode(wire));
    }
    // lifecycle cap도 마찬가지.
    {
        const life_cap: capmod.Capability = .{ .surface_id = 11, .generation = 0, .scope = .lifecycle };
        const wire = try dispatch(req_navigate_11, life_cap);
        defer testing.allocator.free(wire);
        try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.unauthorized)), try errCode(wire));
    }
}

// ── 3) surface 불일치(web cap이 다른 surface) → unauthorized(surface_mismatch 균일) ──
test "dispatchBrowser: cap.surface_id != target id → 균일 unauthorized" {
    // browser cap이 surface 99에 묶였는데 target은 11 → authorize surface_mismatch → unauthorized.
    const wire = try dispatch(req_navigate_11, browserCap(99));
    defer testing.allocator.free(wire);
    try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.unauthorized)), try errCode(wire));
}

// ── 4) revoked / expired → unauthorized ──
test "dispatchBrowser: revoked cap → 균일 unauthorized" {
    var cap = browserCap(11);
    cap.revoked = true;
    const wire = try dispatch(req_navigate_11, cap);
    defer testing.allocator.free(wire);
    try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.unauthorized)), try errCode(wire));
}

test "dispatchBrowser: expired cap(now>=exp) → 균일 unauthorized" {
    var cap = browserCap(11);
    cap.expires_at = 100;
    // now=100 >= exp=100 → expired → unauthorized(균일).
    const wire = try dispatchBrowser(testing.allocator, req_navigate_11, fx, cap, 100);
    defer testing.allocator.free(wire);
    try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.unauthorized)), try errCode(wire));
    // 대조: now=99 < exp면 만료 아님 → 게이트 통과해 internal_error(다른 코드)라야 이 테스트가 만료를 실제로 검사.
    const wire_ok = try dispatchBrowser(testing.allocator, req_navigate_11, fx, cap, 99);
    defer testing.allocator.free(wire_ok);
    try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.internal_error)), try errCode(wire_ok));
}

// ── 5) 유효 browser cap + web surface target → internal_error("not implemented (5d)") ── 모든 게이트 통과
test "dispatchBrowser: 유효 browser cap + web surface → internal_error(-32603, not implemented 5d)" {
    const wire = try dispatch(req_navigate_11, browserCap(11));
    defer testing.allocator.free(wire);
    try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.internal_error)), try errCode(wire));
    // skeleton message에 method 이름 + "not implemented (5d)"가 실린다(5d 교체 지점 진단).
    const msg = try errMessage(wire);
    defer testing.allocator.free(msg);
    try testing.expectEqualStrings("browser.navigate not implemented (5d)", msg);
}

// ── 6) 유효 cap + browser.screenshot(5a 미구현) → method_not_found ── authz는 통과, method 파싱서 접힘
test "dispatchBrowser: 유효 cap + browser.screenshot(5a 미구현) → method_not_found(-32601)" {
    // screenshot도 browser.* 라 methodRequiredScope=.browser → authz granted → parseBrowserMethod(null) → method_not_found.
    const req = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.screenshot\",\"params\":{\"id\":11}}";
    const wire = try dispatch(req, browserCap(11));
    defer testing.allocator.free(wire);
    try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.method_not_found)), try errCode(wire));
}

// ── 7) 유효 cap + navigate params에 url 없음 → invalid_params ──
test "dispatchBrowser: 유효 cap + navigate params에 url 없음 → invalid_params(-32602)" {
    const req = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.navigate\",\"params\":{\"id\":11}}";
    const wire = try dispatch(req, browserCap(11));
    defer testing.allocator.free(wire);
    try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.invalid_params)), try errCode(wire));
}

// ── 8) 유효 cap + target이 terminal surface(cap도 그 terminal id에 묶임) → unauthorized(surface 검증 detail!=.web) ──
test "dispatchBrowser: target이 terminal surface면 authz 통과해도 surface 검증서 균일 unauthorized" {
    // cap이 terminal surface 10에 묶임(browser scope) → authorize granted(surface·scope 일치). 그러나 10은
    // terminal(detail=.terminal)이라 순서 7의 web 검증서 거부. browser cap은 web surface 전용(방어).
    const req = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.navigate\",\"params\":{\"id\":10,\"url\":\"https://a/\"}}";
    const wire = try dispatch(req, browserCap(10));
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
    const w_null = try dispatch(req_navigate_11, null); // cap 부재
    defer testing.allocator.free(w_null);
    const w_scope = try dispatch(req_navigate_11, capmod.Capability{ .surface_id = 11, .generation = 0, .scope = .{ .metadata = .self } }); // scope 불충족
    defer testing.allocator.free(w_scope);
    const w_surface = try dispatch(req_navigate_11, browserCap(99)); // surface 불일치
    defer testing.allocator.free(w_surface);
    var revoked = browserCap(11);
    revoked.revoked = true;
    const w_revoked = try dispatch(req_navigate_11, revoked); // revoked
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
    const wire = try dispatch("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"session.get\",\"params\":{\"id\":11}}", browserCap(11));
    defer testing.allocator.free(wire);
    try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.method_not_found)), try errCode(wire));
}

test "dispatchBrowser: 비-request(notification)·malformed·id 형식오류" {
    // notification(id 없음) → invalid_request.
    {
        const wire = try dispatch("{\"jsonrpc\":\"2.0\",\"method\":\"browser.navigate\",\"params\":{\"id\":11,\"url\":\"u\"}}", browserCap(11));
        defer testing.allocator.free(wire);
        try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.invalid_request)), try errCode(wire));
    }
    // malformed JSON → parse_error(id=null).
    {
        const wire = try dispatch("{not json", browserCap(11));
        defer testing.allocator.free(wire);
        var pm = try cp.parseMessage(testing.allocator, wire);
        defer pm.deinit();
        try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.parse_error)), pm.message.response.err.?.code);
        try testing.expect(pm.message.response.id == .null);
    }
    // id 형식오류(비정수)는 authz 이전이라 invalid_params(surface oracle 아님). cap 유효여도 형식이 먼저.
    {
        const wire = try dispatch("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.navigate\",\"params\":{\"id\":\"x\",\"url\":\"u\"}}", browserCap(11));
        defer testing.allocator.free(wire);
        try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.invalid_params)), try errCode(wire));
    }
}

test {
    testing.refAllDecls(@This());
}
