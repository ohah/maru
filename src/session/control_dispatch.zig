//! control_dispatch — 컨트롤 플레인 **read-only 바이트→바이트 디스패치 라우터**(L2 순수, OS-중립).
//! Track C slice 1d. 단일 출처: docs/control-plane.md §4.1(네임스페이스)·§6(sessions.list·session.get)·
//! §8.3(균일 unauthorized)·§11(slice 1d·CLI help gate·코드 배치 gate)·§16(코어 L2 = src/session/).
//!
//! **1a/1c와의 관계**: 1a(control_plane.zig)는 wire 프리미티브(JSON-RPC parse/serialize/framer/error-model),
//! 1c(control_surface.zig)는 Surface 엔티티 DTO + **메서드 수준** 응답 직렬화(serializeSessionsList·
//! serializeSessionGet + scope 판정). 1d는 그 위에 **요청 바이트 한 줄 + 주입 snapshot → 응답 바이트 한 줄**의
//! 최상위 라우터를 얹는다: parseMessage(1a) → parseMethod(1a) 라우팅 → 1c 직렬화 위임. 별도 모듈로 두는 이유:
//! 1a는 "봉투", 1c는 "엔티티+scope", 1d는 "요청→응답 라우팅"이라 관심사가 다르다(파일도 목적별로 나눈다 —
//! docs/project-rules.md). 에러 코드/스키마는 1a·1c를 재사용하고 여기서 재구현하지 않는다.
//!
//! **순수 경계(범위 애매점 결정)**: 이 라우터는 **바이트→바이트 + 주입 snapshot + 주입(caller_surface_id,
//! scope)** 이다. `caller_surface_id`·`scope`는 실제 시스템에서 capability auth(1e)·self-origin(1g)이 발급하지만,
//! 1d는 그걸 **인자로 주입**받아 read-only 판정만 한다(auth 발급·소켓 accept-loop 스레드·메인 marshal(§5)은
//! 범위 밖 — L4 1b/1e/1g가 나중에 이 순수 함수를 호출해 배선한다). 그래서 헤드리스 단위 테스트가 전부 커버한다.
//!
//! **범위(1d 라우터):** 요청 한 줄 parse → 최상위 라우팅. 지원 메서드:
//!   - `sessions.list {window?}` → 1c `serializeSessionsListFiltered`(scope 필터 + 선택적 window_id 좁힘).
//!   - `session.get {id}` → 1c `serializeSessionGet`(§8.3 존재검사 이전 scope 판정 → unauthorized/process_exited).
//!   - `session.capture {id, scrollback?}`(1f) → 이 read-only 라우터는 metadata scope만 나르는데 capture는
//!     **read-output** capability를 요구하므로(§8.3) 여기선 **항상 §8.3 균일 unauthorized**로 접는다(존재검사 이전,
//!     oracle 방지). 실 read-output grant + chunk 스트리밍은 control_capture(1f) `dispatchCaptureAck` + `Capture`가
//!     소유하고, L4가 1e fd·1g self-origin으로 read-output을 발급한 뒤 그 경로로 배선한다(이 metadata 라우터 밖).
//! 그 밖: 미지 method → method_not_found(-32601), malformed JSON → parse_error(-32700), 유효 JSON이나 유효
//! request 아님 → invalid_request(-32600), 잘못된 params(id 부재/비정수/음수, window 비정수/음수) → invalid_params(-32602).
//!
//! **범위 밖(구현 금지):** write/lifecycle 메서드(2·3), capability/auth 발급(1e/1g), 실 collector(Swift 트리
//! 순회·core_mutex read), accept-loop 스레드·메인 marshal(§5). 이 라우터에 그것들이 얽히면 넓히지 않는다.
//!
//! **session.get 셀렉터 결정(document-basis-and-decision)**: 요청 params의 `id`는 **surface_id(정수 u64)** 다.
//! 응답 Surface의 외부 ID는 `{surface_id, generation}` 객체지만(§3), 1d 셀렉터는 surface_id만으로 조회한다
//! (generation 한정 in-flight 거부는 M1 — control_surface.zig·window_membership.zig 헤더와 동일한 결정). 요청은
//! bare 정수, 응답은 객체라는 비대칭은 1d 범위이고, generation 셀렉터는 후속이다.
//!
//! **비-request message 결정**: read-only 조회 메서드는 응답에 request `id`가 필요하므로 **request만** 디스패치한다.
//! notification(id 없음)/response가 오면 invalid_request(-32600, id=null)로 돌려준다 — 로컬 컨트롤 플레인이라
//! "무응답"보다 명시적 오류가 클라이언트 디버깅에 유용하다(JSON-RPC notification 무응답 관례의 의도적 이탈, 문서화).
//!
//! **L2 순수:** std + control_plane(1a) + control_surface(1c) + window_membership(M0b)만 import한다
//! (app/pty/platform/chrome import 0 — tests/boundary/imports.zig가 강제). OS 타입 0.

const std = @import("std");
const cp = @import("control_plane.zig");
const cs = @import("control_surface.zig");
const wm = @import("window_membership.zig");
const cap = @import("control_capability.zig");

/// read-only 조회 요청 한 줄(ndjson frame, 개행 제외)을 주입 snapshot으로 처리해 **응답 한 줄 바이트**를 만든다.
/// 성공/에러 모두 유효한 JSON-RPC 응답 바이트(개행 없음, 프레이밍은 L4가 붙임)를 돌려준다 — OOM만 error로 전파한다
/// (응답 자체를 만들 메모리도 없을 때). caller가 반환 슬라이스를 free한다.
///
/// `caller_surface_id`·`scope`는 auth(1e/1g)가 발급한 값을 L4가 주입한다(1d는 판정만). `snapshot`은 collector(L4)가
/// 주입한 중립 스냅샷(1d 테스트는 fake).
pub fn dispatchReadOnly(
    gpa: std.mem.Allocator,
    request_bytes: []const u8,
    snapshot: cs.CollectorSnapshot,
    caller_surface_id: u64,
    scope: wm.MetadataScope,
) std.mem.Allocator.Error![]u8 {
    // ── 1a parse. 실패는 JSON-RPC 관례대로 id=null 에러 응답으로 접는다(OOM만 전파). ──
    var pm = cp.parseMessage(gpa, request_bytes) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return errorResponse(gpa, .null, cp.parseFailureCode(e)),
    };
    defer pm.deinit();

    // read-only 조회는 응답에 request id가 필요하므로 request만 디스패치한다(비-request → invalid_request, 헤더 참조).
    const req = switch (pm.message) {
        .request => |r| r,
        else => return errorResponse(gpa, .null, .invalid_request),
    };

    // ── 1a parseMethod 라우팅(§4.1). 코어 read-only 둘만 지원, 그 밖은 method_not_found. ──
    const method = cp.parseMethod(req.method);
    if (method.core == .sessions and std.mem.eql(u8, method.rest, "list")) {
        const window_filter = readWindowParam(req.params) catch return errorResponse(gpa, req.id, .invalid_params);
        return cs.serializeSessionsListFiltered(gpa, req.id, snapshot, caller_surface_id, scope, window_filter);
    }
    if (method.core == .session and std.mem.eql(u8, method.rest, "get")) {
        const requested = readIdParam(req.params) catch return errorResponse(gpa, req.id, .invalid_params);
        // §8.3 균일 unauthorized/process_exited 판정·직렬화는 1c가 단일 출처로 소유(재구현 금지).
        return cs.serializeSessionGet(gpa, req.id, snapshot, caller_surface_id, scope, requested);
    }
    if (method.core == .session and std.mem.eql(u8, method.rest, "capture")) {
        // session.capture는 **read-output** capability를 요구한다(§8.3). 이 read-only 라우터는 **metadata scope만**
        // 나르고(caller가 주입받는 `scope`는 `MetadataScope`), metadata는 read-output을 **절대** 만족하지 못하므로
        // §8.3 **균일 unauthorized**로 접는다(존재검사 이전 — target 존재 여부 무관, surface_id 열거 oracle 방지).
        // 실 read-output grant + chunk 스트리밍은 control_capture(1f) `dispatchCaptureAck` + `Capture`가 소유하고,
        // L4가 1e fd·1g self-origin으로 read-output을 발급한 뒤 **그 경로로** 배선한다(이 metadata 라우터가 아니라).
        // params/id 형식도 읽지 않는다 — 인가가 이 경로에선 구조적으로 실패라 즉시 종료(oracle 최소화).
        return errorResponse(gpa, req.id, .unauthorized);
    }
    return errorResponse(gpa, req.id, .method_not_found);
}

/// 코드의 default message로 에러 응답 한 줄을 만든다(1a serializeError 재사용). 편의 wrapper.
fn errorResponse(gpa: std.mem.Allocator, id: cp.Id, code: cp.ErrorCode) std.mem.Allocator.Error![]u8 {
    return cp.serializeError(gpa, id, code, code.defaultMessage(), null);
}

/// **1e-core: capability 인가 배선.** auth 프레임의 `{selector, cap_nonce}`(1a `parseAuthFrame`)와 라이브
/// `CapabilityStore`(L4가 소유·주입)로 요청의 `(caller_surface_id, scope)`를 판정한 뒤 read-only 라우터에 넘긴다.
/// `dispatchReadOnly`가 auth를 **인자로 주입**받던 것을, 그 인자를 capability로 **발급**하는 상위 래퍼다(1d 헤더 §범위).
///
/// 경로:
///  - `cap_nonce == null`(cap 없음): 기존 self-origin 경로 — `caller = selector orelse 0`, `scope = .self`
///    (§8.4 A2b — maru 밖/no-cap shell은 자기 surface metadata만). 라이브 동작 불변(회귀 없음).
///  - `cap_nonce` 제시: `control_capability.resolve`(store lookup → authorize → 균일 unauthorized)로 판정.
///    grant면 capability가 실은 `(surface_id, scope)`로 read-only 라우터를 태우고, deny면 **균일 `unauthorized`**
///    (§8.3 oracle 방지 — resolve가 모든 deny 이유를 접는다). resolve는 method↔scope를 검사하므로 요청 method가
///    필요해 1a로 한 번 파싱한다(라우터가 다시 파싱하지만 로컬 소켓이라 이 이중 파싱은 무시할 비용, 라우터 단일화 유지).
///
/// **non-metadata cap(browser/write/…)**: resolve는 인가하지만 이 **read-only** 라우터엔 그 method 라우팅이 없어
/// `method_not_found`로 접힌다 — 라이브 dispatch 배선은 5e(browser)·2a(write)다. 즉 "cap resolve됨 but 미배선"은
/// `method_not_found`, "cap이 scope 불충족"은 `unauthorized`로 **구별**되어 관측 가능하다(1e-core 인가 자체 검증).
///
/// **generation anchor**: 현재 전 시스템이 generation 0(§3 respawn 경로 미구현)이라 anchor generation을 0으로 고정한다
/// (auth.self 셀렉터는 surface_id만 나름). generation 셀렉터·respawn 무효화는 후속(cap의 generation 검사는 이미 순수
/// 코어에 있음 — 발급 시 0으로 묶이면 0 anchor와 일치).
pub fn dispatchAuthenticated(
    gpa: std.mem.Allocator,
    request_bytes: []const u8,
    snapshot: cs.CollectorSnapshot,
    selector: ?u64,
    cap_nonce: ?cap.Nonce,
    store: *const cap.CapabilityStore,
    now: u64,
) std.mem.Allocator.Error![]u8 {
    const nonce = cap_nonce orelse
        return dispatchReadOnly(gpa, request_bytes, snapshot, selector orelse 0, .self);

    // cap 제시 → method가 필요해 1a 파싱(라우터가 재파싱하지만 단일 라우터 유지가 우선). parse 실패/비-request는
    // dispatchReadOnly와 동일 관례(id=null 에러)로 접는다.
    var pm = cp.parseMessage(gpa, request_bytes) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return errorResponse(gpa, .null, cp.parseFailureCode(e)),
    };
    defer pm.deinit();
    const req = switch (pm.message) {
        .request => |r| r,
        else => return errorResponse(gpa, .null, .invalid_request),
    };

    const anchor = selector orelse 0;
    switch (cap.resolve(store, nonce, anchor, 0, req.method, now)) {
        .unauthorized => return errorResponse(gpa, req.id, .unauthorized),
        .granted => |g| {
            // metadata면 resolved sub-scope, 아니면 .self placeholder(그 method는 read-only 밖이라 method_not_found).
            const ms = g.metadataScope() orelse wm.MetadataScope.self;
            return dispatchReadOnly(gpa, request_bytes, snapshot, g.surface_id, ms);
        },
    }
}

/// params 오류(shape/타입/범위)를 하나로 접는 sentinel — 호출자가 invalid_params로 매핑한다.
const ParamError = error{InvalidParams};

/// `session.get {id}`의 필수 `id`(surface_id, u64)를 읽는다. params 부재/객체 아님/id 부재/비정수/음수 → InvalidParams.
/// 셀렉터는 surface_id만(generation 한정은 후속 — 모듈 헤더 참조).
fn readIdParam(params: ?std.json.Value) ParamError!u64 {
    const obj = switch (params orelse return error.InvalidParams) {
        .object => |o| o,
        else => return error.InvalidParams,
    };
    return switch (obj.get("id") orelse return error.InvalidParams) {
        .integer => |i| if (i < 0) error.InvalidParams else @intCast(i),
        else => error.InvalidParams,
    };
}

/// `sessions.list {window?}`의 **선택적** `window`(window_id, u64)를 읽는다. params 부재/params가 null이면 필터 없음(null).
/// params가 있으나 객체가 아니거나, window가 있으나 비정수/음수면 InvalidParams. window 부재는 필터 없음.
fn readWindowParam(params: ?std.json.Value) ParamError!?u64 {
    const obj = switch (params orelse return null) {
        .object => |o| o,
        else => return error.InvalidParams,
    };
    return switch (obj.get("window") orelse return null) {
        .integer => |i| if (i < 0) error.InvalidParams else @intCast(i),
        else => error.InvalidParams,
    };
}

// ══ 테스트(헤드리스, Linux CI 포함 — 순수 로직·소켓 0) ═══════════════════════════════════════════════════
const testing = std.testing;

// fake collector snapshot: 창 A(normal,win1)={10 terminal, 11 web}, 창 B(normal,win2)={20 terminal}, quick(win3)={30}.
const fx_surfaces = [_]cs.SurfaceDto{
    .{ .surface_id = 10, .generation = 0, .title = "shell-a", .window = 1, .tab = 0, .pane = 0, .focused = true, .detail = .{ .terminal = .{ .cwd = "/home/a", .git_branch = "main", .agent = .{ .kind = .claude, .state = .running }, .at_prompt = .not_at_prompt } } },
    .{ .surface_id = 11, .generation = 0, .title = "docs", .window = 1, .tab = 1, .pane = 0, .focused = false, .detail = .{ .web = .{ .url = "https://x/y", .panel_kind = .markdown, .loading = false, .trust = .trusted } } },
    .{ .surface_id = 20, .generation = 2, .title = "shell-b", .window = 2, .tab = 0, .pane = 0, .focused = false, .detail = .{ .terminal = .{ .cwd = "/srv/b", .at_prompt = .at_prompt } } },
    .{ .surface_id = 30, .generation = 0, .title = "quick", .window = 3, .tab = 0, .pane = 0, .focused = false, .detail = .{ .terminal = .{ .at_prompt = .unknown } } },
};
const fx_a_ids = [_]u64{ 10, 11 };
const fx_b_ids = [_]u64{20};
const fx_q_ids = [_]u64{30};
const fx_windows = [_]wm.WindowMembershipSnapshot{
    .{ .window_id = 1, .window_kind = .normal, .surface_ids = &fx_a_ids },
    .{ .window_id = 2, .window_kind = .normal, .surface_ids = &fx_b_ids },
    .{ .window_id = 3, .window_kind = .quick, .surface_ids = &fx_q_ids },
};
const fx: cs.CollectorSnapshot = .{ .surfaces = &fx_surfaces, .windows = &fx_windows };

fn dispatch(bytes: []const u8, caller: u64, scope: wm.MetadataScope) ![]u8 {
    return dispatchReadOnly(testing.allocator, bytes, fx, caller, scope);
}

// 응답 바이트에서 result 배열의 surface_id 집합을 뽑는다(순서 보존).
fn listIds(wire: []const u8, out: *std.ArrayList(u64)) !void {
    var pm = try cp.parseMessage(testing.allocator, wire);
    defer pm.deinit();
    try testing.expect(pm.message == .response);
    const arr = pm.message.response.result.?.array;
    for (arr.items) |item| {
        try out.append(testing.allocator, @intCast(item.object.get("id").?.object.get("surface_id").?.integer));
    }
}

// 응답 바이트의 에러 코드를 뽑는다(성공이면 실패 단언).
fn errCode(wire: []const u8) !i64 {
    var pm = try cp.parseMessage(testing.allocator, wire);
    defer pm.deinit();
    try testing.expect(pm.message == .response);
    return pm.message.response.err.?.code;
}

test "dispatch: sessions.list self scope → 자기 surface(10)만" {
    const wire = try dispatch("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"sessions.list\"}", 10, .self);
    defer testing.allocator.free(wire);
    var ids: std.ArrayList(u64) = .empty;
    defer ids.deinit(testing.allocator);
    try listIds(wire, &ids);
    try testing.expectEqualSlices(u64, &.{10}, ids.items);
}

test "dispatch: sessions.list window scope → 창 A(10,11), all scope → 전체(10,11,20,30)" {
    {
        const wire = try dispatch("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"sessions.list\"}", 10, .window);
        defer testing.allocator.free(wire);
        var ids: std.ArrayList(u64) = .empty;
        defer ids.deinit(testing.allocator);
        try listIds(wire, &ids);
        try testing.expectEqualSlices(u64, &.{ 10, 11 }, ids.items);
    }
    {
        const wire = try dispatch("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"sessions.list\"}", 10, .all);
        defer testing.allocator.free(wire);
        var ids: std.ArrayList(u64) = .empty;
        defer ids.deinit(testing.allocator);
        try listIds(wire, &ids);
        try testing.expectEqualSlices(u64, &.{ 10, 11, 20, 30 }, ids.items);
    }
}

test "dispatch: sessions.list {window} 필터는 scope와 교집합 — all+window=2 → [20], self+window=2 → []" {
    // all scope + window=2 → 창 B의 20만.
    {
        const wire = try dispatch("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"sessions.list\",\"params\":{\"window\":2}}", 10, .all);
        defer testing.allocator.free(wire);
        var ids: std.ArrayList(u64) = .empty;
        defer ids.deinit(testing.allocator);
        try listIds(wire, &ids);
        try testing.expectEqualSlices(u64, &.{20}, ids.items);
    }
    // self scope caller 10 + window=1 → 10만(11은 self 안 보임). window=2 → [](scope가 window 필터를 이긴다).
    {
        const w1 = try dispatch("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"sessions.list\",\"params\":{\"window\":1}}", 10, .self);
        defer testing.allocator.free(w1);
        var ids1: std.ArrayList(u64) = .empty;
        defer ids1.deinit(testing.allocator);
        try listIds(w1, &ids1);
        try testing.expectEqualSlices(u64, &.{10}, ids1.items);

        const w2 = try dispatch("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"sessions.list\",\"params\":{\"window\":2}}", 10, .self);
        defer testing.allocator.free(w2);
        var ids2: std.ArrayList(u64) = .empty;
        defer ids2.deinit(testing.allocator);
        try listIds(w2, &ids2);
        try testing.expectEqual(@as(usize, 0), ids2.items.len);
    }
}

test "dispatch: session.get self 자기(10) → Surface result" {
    const wire = try dispatch("{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"session.get\",\"params\":{\"id\":10}}", 10, .self);
    defer testing.allocator.free(wire);
    var pm = try cp.parseMessage(testing.allocator, wire);
    defer pm.deinit();
    try testing.expect(pm.message.response.err == null);
    const o = pm.message.response.result.?.object;
    try testing.expectEqual(@as(i64, 10), o.get("id").?.object.get("surface_id").?.integer);
    try testing.expectEqualStrings("terminal", o.get("kind").?.string);
    // request id(7)가 응답에 echo된다.
    try testing.expect(cp.idEql(pm.message.response.id, .{ .number = 7 }));
}

test "dispatch §8.3: self caller가 남의 id를 물으면 존재/부재 무관 균일 unauthorized(바이트 동일 = oracle 없음)" {
    // 존재하는 남(20) vs 아예 없는(999) — 같은 request id로 물어 응답 바이트가 동일해야 한다.
    const w_exists = try dispatch("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"session.get\",\"params\":{\"id\":20}}", 10, .self);
    defer testing.allocator.free(w_exists);
    const w_absent = try dispatch("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"session.get\",\"params\":{\"id\":999}}", 10, .self);
    defer testing.allocator.free(w_absent);
    try testing.expectEqualStrings(w_exists, w_absent); // oracle 없음
    try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.unauthorized)), try errCode(w_exists));
}

test "dispatch: 인가된 surface가 snapshot에 없으면 process_exited(unauthorized와 다름)" {
    // window scope caller 10이 같은 창 11을 묻되 snapshot엔 11이 없다 → 인가되나 부재 → process_exited.
    const partial = [_]cs.SurfaceDto{fx_surfaces[0]}; // 10만.
    const snap: cs.CollectorSnapshot = .{ .surfaces = &partial, .windows = &fx_windows };
    const wire = try dispatchReadOnly(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"session.get\",\"params\":{\"id\":11}}", snap, 10, .window);
    defer testing.allocator.free(wire);
    try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.process_exited)), try errCode(wire));
}

test "dispatch: 미지 method → method_not_found(-32601)" {
    for ([_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"session.sendText\",\"params\":{\"id\":10,\"text\":\"x\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"sessions.foo\"}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"foo.bar\"}",
    }) |req| {
        const wire = try dispatch(req, 10, .all);
        defer testing.allocator.free(wire);
        try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.method_not_found)), try errCode(wire));
    }
}

// session.capture(1f)는 read-output capability를 요구하는데(§8.3) 이 read-only 라우터는 metadata scope만 나른다 —
// metadata는 read-output을 절대 만족하지 못하므로 method_not_found가 아니라 **§8.3 균일 unauthorized**로 접는다
// (실 read-output 경로는 control_capture.dispatchCaptureAck·1f). all scope로도, target 존재/부재와도 무관하게 균일.
test "dispatch: session.capture는 metadata 라우터에서 read-output 미충족 → 균일 unauthorized(method_not_found 아님)" {
    for ([_]wm.MetadataScope{ .self, .window, .all }) |scope| {
        const wire = try dispatch("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"session.capture\",\"params\":{\"id\":10}}", 10, scope);
        defer testing.allocator.free(wire);
        try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.unauthorized)), try errCode(wire));
    }
    // §8.3 oracle 방지: target surface_id가 존재하는 10이든 없는 999든 바이트 동일(존재 여부 무누설).
    const w_exists = try dispatch("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"session.capture\",\"params\":{\"id\":10}}", 10, .all);
    defer testing.allocator.free(w_exists);
    const w_absent = try dispatch("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"session.capture\",\"params\":{\"id\":999}}", 10, .all);
    defer testing.allocator.free(w_absent);
    try testing.expectEqualStrings(w_exists, w_absent);
}

test "dispatch: malformed JSON → parse_error(-32700), id=null" {
    for ([_][]const u8{ "{not json", "", "{\"jsonrpc\":\"2.0\"," }) |req| {
        const wire = try dispatch(req, 10, .all);
        defer testing.allocator.free(wire);
        var pm = try cp.parseMessage(testing.allocator, wire);
        defer pm.deinit();
        try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.parse_error)), pm.message.response.err.?.code);
        try testing.expect(pm.message.response.id == .null);
    }
}

test "dispatch: 유효 JSON이나 유효 request 아님 → invalid_request(-32600)" {
    for ([_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":1}", // method/result 없음
        "[]", // 배열
        "{\"jsonrpc\":\"2.0\",\"method\":\"sessions.list\"}", // notification(id 없음) — read-only는 request만
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}", // response
    }) |req| {
        const wire = try dispatch(req, 10, .all);
        defer testing.allocator.free(wire);
        try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.invalid_request)), try errCode(wire));
    }
}

test "dispatch: session.get params 오류 → invalid_params(-32602)" {
    for ([_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"session.get\"}", // params 없음
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"session.get\",\"params\":{}}", // id 없음
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"session.get\",\"params\":{\"id\":\"x\"}}", // 비정수
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"session.get\",\"params\":{\"id\":-3}}", // 음수
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"session.get\",\"params\":[1,2]}", // params가 객체 아님
    }) |req| {
        const wire = try dispatch(req, 10, .all);
        defer testing.allocator.free(wire);
        try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.invalid_params)), try errCode(wire));
    }
}

test "dispatch: sessions.list window params 오류 → invalid_params" {
    for ([_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"sessions.list\",\"params\":{\"window\":\"x\"}}", // 비정수
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"sessions.list\",\"params\":{\"window\":-2}}", // 음수
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"sessions.list\",\"params\":[]}", // params가 객체 아님
    }) |req| {
        const wire = try dispatch(req, 10, .all);
        defer testing.allocator.free(wire);
        try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.invalid_params)), try errCode(wire));
    }
}

test "dispatch: 빈 snapshot → sessions.list []" {
    const empty_s = [_]cs.SurfaceDto{};
    const empty_w = [_]wm.WindowMembershipSnapshot{};
    const snap: cs.CollectorSnapshot = .{ .surfaces = &empty_s, .windows = &empty_w };
    const wire = try dispatchReadOnly(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"sessions.list\"}", snap, 10, .all);
    defer testing.allocator.free(wire);
    var pm = try cp.parseMessage(testing.allocator, wire);
    defer pm.deinit();
    try testing.expectEqual(@as(usize, 0), pm.message.response.result.?.array.items.len);
}

test "dispatch: 응답이 request id(number·string)를 echo한다" {
    // string id.
    const wire = try dispatch("{\"jsonrpc\":\"2.0\",\"id\":\"req-9\",\"method\":\"sessions.list\"}", 10, .self);
    defer testing.allocator.free(wire);
    var pm = try cp.parseMessage(testing.allocator, wire);
    defer pm.deinit();
    try testing.expect(cp.idEql(pm.message.response.id, .{ .string = "req-9" }));
}

// ══ 1e-core: dispatchAuthenticated(capability 인가 배선) 테스트(헤드리스, 주입 store) ══════════════════════
const n_all: cap.Nonce = [_]u8{0x01} ** cap.nonce_len;
const n_win: cap.Nonce = [_]u8{0x02} ** cap.nonce_len;
const n_browser: cap.Nonce = [_]u8{0x03} ** cap.nonce_len;
const n_unknown: cap.Nonce = [_]u8{0xEE} ** cap.nonce_len;

fn authDispatch(bytes: []const u8, selector: ?u64, nonce: ?cap.Nonce, store: *const cap.CapabilityStore) ![]u8 {
    return dispatchAuthenticated(testing.allocator, bytes, fx, selector, nonce, store, 0);
}

test "dispatchAuthenticated: nonce 없음 → 기존 self 경로(회귀 없음) — selector=10 sessions.list → 10만" {
    var store: cap.CapabilityStore = .{};
    defer store.deinit(testing.allocator);
    const wire = try authDispatch("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"sessions.list\"}", 10, null, &store);
    defer testing.allocator.free(wire);
    var ids: std.ArrayList(u64) = .empty;
    defer ids.deinit(testing.allocator);
    try listIds(wire, &ids);
    try testing.expectEqualSlices(u64, &.{10}, ids.items); // cap 없음 = self only(기존 동작)
}

test "dispatchAuthenticated: metadata:all cap(surface 10) → sessions.list 전체(10,11,20,30)" {
    var store: cap.CapabilityStore = .{};
    defer store.deinit(testing.allocator);
    try store.issueForFd(testing.allocator, n_all, .{ .surface_id = 10, .generation = 0, .scope = .{ .metadata = .all } });
    const wire = try authDispatch("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"sessions.list\"}", 10, n_all, &store);
    defer testing.allocator.free(wire);
    var ids: std.ArrayList(u64) = .empty;
    defer ids.deinit(testing.allocator);
    try listIds(wire, &ids);
    try testing.expectEqualSlices(u64, &.{ 10, 11, 20, 30 }, ids.items); // cap이 self보다 넓은 scope 발급
}

test "dispatchAuthenticated: metadata:window cap(surface 10) → 창 A(10,11)만" {
    var store: cap.CapabilityStore = .{};
    defer store.deinit(testing.allocator);
    try store.issueForFd(testing.allocator, n_win, .{ .surface_id = 10, .generation = 0, .scope = .{ .metadata = .window } });
    const wire = try authDispatch("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"sessions.list\"}", 10, n_win, &store);
    defer testing.allocator.free(wire);
    var ids: std.ArrayList(u64) = .empty;
    defer ids.deinit(testing.allocator);
    try listIds(wire, &ids);
    try testing.expectEqualSlices(u64, &.{ 10, 11 }, ids.items);
}

test "dispatchAuthenticated: 미지 nonce → 균일 unauthorized(store 부재 = default-deny)" {
    var store: cap.CapabilityStore = .{};
    defer store.deinit(testing.allocator);
    // 빈 store(라이브 앱의 fd 발급 전 상태)에 nonce 제시 → unauthorized.
    const wire = try authDispatch("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"sessions.list\"}", 10, n_unknown, &store);
    defer testing.allocator.free(wire);
    try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.unauthorized)), try errCode(wire));
}

test "dispatchAuthenticated: cap surface≠제시 anchor → unauthorized(surface_mismatch 균일 접힘)" {
    var store: cap.CapabilityStore = .{};
    defer store.deinit(testing.allocator);
    // cap은 surface 20에 묶였는데 caller가 anchor 10을 주장 → surface_mismatch → 균일 unauthorized.
    try store.issueForFd(testing.allocator, n_all, .{ .surface_id = 20, .generation = 0, .scope = .{ .metadata = .all } });
    const wire = try authDispatch("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"sessions.list\"}", 10, n_all, &store);
    defer testing.allocator.free(wire);
    try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.unauthorized)), try errCode(wire));
}

// 핵심: cap resolve 자체가 동작함을 "구별되는 결과"로 증명한다 — browser cap + browser.navigate는 resolve 성공하나
// read-only 라우터에 미배선이라 method_not_found(5e 대기); metadata cap + browser.navigate는 scope 불충족이라
// unauthorized. 이 둘이 다른 것이 곧 "1e-core 인가가 scope↔method를 실제로 판정한다"는 증거.
test "dispatchAuthenticated: browser cap + browser.navigate → method_not_found(resolve됨·미배선); metadata cap → unauthorized(scope)" {
    var store: cap.CapabilityStore = .{};
    defer store.deinit(testing.allocator);
    try store.issueForFd(testing.allocator, n_browser, .{ .surface_id = 10, .generation = 0, .scope = .browser });
    try store.issueForFd(testing.allocator, n_all, .{ .surface_id = 10, .generation = 0, .scope = .{ .metadata = .all } });

    const req = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.navigate\",\"params\":{\"id\":10,\"url\":\"https://x\"}}";
    // browser cap → resolve 성공 → read-only 라우터엔 browser.* 없음 → method_not_found.
    const w_ok = try authDispatch(req, 10, n_browser, &store);
    defer testing.allocator.free(w_ok);
    try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.method_not_found)), try errCode(w_ok));
    // metadata cap으로 browser.navigate → scope 불충족 → unauthorized(method_not_found 아님).
    const w_deny = try authDispatch(req, 10, n_all, &store);
    defer testing.allocator.free(w_deny);
    try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.unauthorized)), try errCode(w_deny));
    // 대칭: browser cap으로 sessions.list(metadata) → scope 불충족 → unauthorized.
    const w_cross = try authDispatch("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"sessions.list\"}", 10, n_browser, &store);
    defer testing.allocator.free(w_cross);
    try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.unauthorized)), try errCode(w_cross));
}

test {
    testing.refAllDecls(@This());
}
