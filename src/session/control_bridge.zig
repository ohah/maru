//! Track C 5b: 신뢰 웹 브리지(`window.maru.*`) 디스패치 코어 — **L2 순수·헤드리스**([control-plane.md] §8.1.1).
//!
//! Swift(L4)가 신뢰(markdown) 패널의 isolated `WKContentWorld` 메시지 핸들러 진입에서 **`frameInfo.isMainFrame` +
//! `securityOrigin`(=`maru-app://app`) exact-pin**을 **먼저** 검증(신뢰 게이트 = transport 층, §8.1.1 ②)한 뒤, 통과한
//! 요청 한 줄을 이 함수로 넘긴다. 따라서 이 코어엔 **capability auth가 없다** — 신뢰는 origin/frame으로 이미 확립돼
//! 있고, 소켓 경로(control_dispatch/control_browser)의 peer-cred·capability와 달리 브리지는 in-process 신뢰 채널이다
//! (§8.1 "웹 브리지는 신뢰 콘텐츠에만 노출"). 이 부재는 실수가 아니라 신뢰 모델의 명시적 결과다.
//!
//! **5b 최소 표면**: round-trip 증명 `maru.hello()` → `{protocol, server_version}` 1개. 핸들러 도달 + 신뢰 게이트 통과를
//! E2E로 증명하는 최소 method다. 실 `window.maru.*` API 표면(navigate/read 등)은 5d+/Phase 7.
//!
//! **범위 밖**: `WKContentWorld`·메시지 핸들러·`window.maru` shim·origin 검증(Swift L4 어댑터), 소켓 transport
//! (control_server), `browser.*`(control_browser). wire 스키마는 소켓과 동일 JSON-RPC 2.0(§8.1 "메시지 스키마 하나").

const std = @import("std");
const cp = @import("control_plane.zig");

/// 브리지 method 이름(5b 최소: `hello` 1개). `window.maru` shim의 `maru.hello()`가 이 method 요청으로 매핑된다.
/// 소켓 핸드셰이크의 `hello` notification(cp.hello_method)과 이름은 같지만 문맥이 다르다 — 이건 id 있는 **request**로
/// reply를 받고, 소켓 hello는 id 없는 notification이다(별개 dispatch라 충돌 없음).
pub const hello_method = "hello";

/// bridge `hello` 성공 result 한 줄: `{"jsonrpc":"2.0","id":<id>,"result":{"protocol":..,"server_version":..}}`.
/// minified 한 줄(1a·1c·control_browser와 동일 — ndjson frame 경계 안전). 종단 `\n`은 프레이밍(L4)이 붙인다. caller free.
pub fn serializeHelloResult(gpa: std.mem.Allocator, id: cp.Id, server_version: []const u8) std.mem.Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    (writeHelloResult(&s, id, server_version)) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn writeHelloResult(s: *std.json.Stringify, id: cp.Id, server_version: []const u8) !void {
    try cp.beginResult(s, id); // result envelope 단일 출처(control_browser와 공유 — 리뷰12 [4]).
    try s.objectField("protocol");
    try s.write(cp.protocol_id); // 신뢰 브리지도 같은 프로토콜 식별자를 보고(소켓 hello와 정합).
    try s.objectField("server_version");
    try s.write(server_version);
    try cp.endResult(s);
}

/// 신뢰 브리지 요청 한 줄(ndjson frame, 개행 제외)을 처리해 **응답 한 줄 바이트**를 만든다. `server_version`은 L4가
/// 단일 출처(app_host_abi `control_hello_version`)를 넘긴다. OOM만 error로 전파(응답 만들 메모리도 없을 때). caller free.
///
/// **auth 없음**(모듈 헤더): 신뢰는 Swift가 핸들러 진입서 origin/frame으로 이미 확립. 순서:
///   1. parseMessage → request 아니면 `invalid_request`(id=null). parse 실패 → `parseFailureCode`(1a 관례).
///   2. method != `hello`면 `method_not_found`(5b는 hello만; 실 method는 5d+). id는 request의 것으로 응답.
///   3. `hello` → `{protocol, server_version}` 응답.
pub fn dispatchBridge(
    gpa: std.mem.Allocator,
    request_bytes: []const u8,
    server_version: []const u8,
) std.mem.Allocator.Error![]u8 {
    var pm = cp.parseMessage(gpa, request_bytes) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return errorResponse(gpa, .null, cp.parseFailureCode(e)),
    };
    defer pm.deinit();

    // 브리지도 응답에 request id가 필요하므로 request만 디스패치한다(비-request → invalid_request, 소켓 1d/browser와 동일).
    const req = switch (pm.message) {
        .request => |r| r,
        else => return errorResponse(gpa, .null, .invalid_request),
    };

    if (!std.mem.eql(u8, req.method, hello_method)) return errorResponse(gpa, req.id, .method_not_found);
    return serializeHelloResult(gpa, req.id, server_version);
}

/// 코드의 default message로 에러 응답 한 줄을 만든다(1a `serializeError` 재사용 — control_browser/1d와 동일 패턴).
fn errorResponse(gpa: std.mem.Allocator, id: cp.Id, code: cp.ErrorCode) std.mem.Allocator.Error![]u8 {
    return cp.serializeError(gpa, id, code, code.defaultMessage(), null);
}

// ══ 테스트(헤드리스, Linux CI 포함 — 순수 로직·WKWebView/소켓 0) ═══════════════════════════════════════════════
const testing = std.testing;

fn parseValue(gpa: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, gpa, bytes, .{});
}

test "dispatchBridge: hello round-trip → protocol + server_version" {
    const req = "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"hello\"}";
    const resp = try dispatchBridge(testing.allocator, req, "9.9.9");
    defer testing.allocator.free(resp);
    var p = try parseValue(testing.allocator, resp);
    defer p.deinit();
    const obj = p.value.object;
    try testing.expectEqualStrings("2.0", obj.get("jsonrpc").?.string);
    try testing.expectEqual(@as(i64, 7), obj.get("id").?.integer);
    const result = obj.get("result").?.object;
    try testing.expectEqualStrings("maru.control.v1", result.get("protocol").?.string);
    try testing.expectEqualStrings("9.9.9", result.get("server_version").?.string);
    try testing.expect(obj.get("error") == null);
}

test "dispatchBridge: 미지원 method → method_not_found(요청 id 보존)" {
    const req = "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"navigate\"}";
    const resp = try dispatchBridge(testing.allocator, req, "0.1.0");
    defer testing.allocator.free(resp);
    var p = try parseValue(testing.allocator, resp);
    defer p.deinit();
    const obj = p.value.object;
    try testing.expectEqual(@as(i64, 3), obj.get("id").?.integer);
    try testing.expectEqual(@as(i64, -32601), obj.get("error").?.object.get("code").?.integer); // method_not_found
    try testing.expect(obj.get("result") == null);
}

test "dispatchBridge: notification(id 없음) → invalid_request(id=null)" {
    const req = "{\"jsonrpc\":\"2.0\",\"method\":\"hello\"}";
    const resp = try dispatchBridge(testing.allocator, req, "0.1.0");
    defer testing.allocator.free(resp);
    var p = try parseValue(testing.allocator, resp);
    defer p.deinit();
    const obj = p.value.object;
    try testing.expect(obj.get("id").? == .null);
    try testing.expectEqual(@as(i64, -32600), obj.get("error").?.object.get("code").?.integer); // invalid_request
}

test "dispatchBridge: 깨진 JSON → parse 에러 응답(OOM 아님)" {
    const req = "{not json";
    const resp = try dispatchBridge(testing.allocator, req, "0.1.0");
    defer testing.allocator.free(resp);
    var p = try parseValue(testing.allocator, resp);
    defer p.deinit();
    try testing.expect(p.value.object.get("error") != null);
}

test "serializeHelloResult: minified 한 줄(개행 없음 — ndjson frame 안전)" {
    const resp = try serializeHelloResult(testing.allocator, .{ .number = 1 }, "0.1.0");
    defer testing.allocator.free(resp);
    try testing.expect(std.mem.indexOfScalar(u8, resp, '\n') == null);
}
