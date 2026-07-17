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
const file_policy = @import("file_panel_bridge.zig");

/// 브리지 method 이름(5b 최소: `hello` 1개). `window.maru` shim의 `maru.hello()`가 이 method 요청으로 매핑된다.
/// 소켓 핸드셰이크의 `hello` notification(cp.hello_method)과 이름은 같지만 문맥이 다르다 — 이건 id 있는 **request**로
/// reply를 받고, 소켓 hello는 id 없는 notification이다(별개 dispatch라 충돌 없음).
pub const hello_method = "hello";
pub const file_read_method = "maru.file.read";
pub const file_read_asset_method = "maru.file.readAsset";
pub const file_write_method = "maru.file.write";
pub const file_set_dirty_method = "maru.file.setDirty";

/// 실제 파일 시스템 접근을 platform 계층에서 주입한다. 반환 slice는 `gpa` 소유이며 dispatch가 해제한다.
/// callback error는 경로/존재 정보를 노출하지 않는 균일 `internal_error`로 접는다.
pub const FileAccess = struct {
    context: *anyopaque,
    read_fn: *const fn (context: *anyopaque, gpa: std.mem.Allocator) anyerror![]u8,
    read_asset_fn: *const fn (context: *anyopaque, gpa: std.mem.Allocator, normalized_path: []const u8) anyerror![]u8,
    write_fn: *const fn (context: *anyopaque, content: []const u8) anyerror!void,
    set_dirty_fn: *const fn (context: *anyopaque, dirty: bool) anyerror!void,

    fn read(self: FileAccess, gpa: std.mem.Allocator) anyerror![]u8 {
        return self.read_fn(self.context, gpa);
    }

    fn readAsset(self: FileAccess, gpa: std.mem.Allocator, normalized_path: []const u8) anyerror![]u8 {
        return self.read_asset_fn(self.context, gpa, normalized_path);
    }

    fn write(self: FileAccess, content: []const u8) anyerror!void {
        return self.write_fn(self.context, content);
    }

    fn setDirty(self: FileAccess, dirty: bool) anyerror!void {
        return self.set_dirty_fn(self.context, dirty);
    }
};

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
    return dispatchBridgeWithFileAccess(gpa, request_bytes, server_version, null);
}

/// `file_access != null`인 도크 markdown surface에서만 file method를 연다. 일반 신뢰 UI/기존 hello fixture는
/// provider를 넘기지 않아 file method가 `method_not_found`로 닫힌다.
pub fn dispatchBridgeWithFileAccess(
    gpa: std.mem.Allocator,
    request_bytes: []const u8,
    server_version: []const u8,
    file_access: ?FileAccess,
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

    if (std.mem.eql(u8, req.method, hello_method)) return serializeHelloResult(gpa, req.id, server_version);

    const access = file_access orelse return errorResponse(gpa, req.id, .method_not_found);
    if (std.mem.eql(u8, req.method, file_read_method)) {
        if (req.params != null) return errorResponse(gpa, req.id, .invalid_params);
        const content = access.read(gpa) catch return errorResponse(gpa, req.id, .internal_error);
        defer gpa.free(content);
        if (!std.unicode.utf8ValidateSlice(content)) return errorResponse(gpa, req.id, .internal_error);
        return serializeFileReadResult(gpa, req.id, content);
    }
    if (std.mem.eql(u8, req.method, file_read_asset_method)) {
        const raw_path = readAssetPath(req.params) catch return errorResponse(gpa, req.id, .invalid_params);
        var normalized_buf: [std.fs.max_path_bytes]u8 = undefined;
        const normalized = file_policy.normalizeAssetPath(raw_path, &normalized_buf) catch
            return errorResponse(gpa, req.id, .invalid_params);
        const bytes = access.readAsset(gpa, normalized) catch return errorResponse(gpa, req.id, .internal_error);
        defer gpa.free(bytes);
        return serializeFileAssetResult(gpa, req.id, file_policy.mimeForPath(normalized), bytes);
    }
    if (std.mem.eql(u8, req.method, file_write_method)) {
        const content = singleStringParam(req.params, "content") catch return errorResponse(gpa, req.id, .invalid_params);
        if (content.len > file_policy.max_file_bytes or !std.unicode.utf8ValidateSlice(content))
            return errorResponse(gpa, req.id, .invalid_params);
        access.write(content) catch return errorResponse(gpa, req.id, .internal_error);
        return serializeFileMutationResult(gpa, req.id, "written_bytes", content.len);
    }
    if (std.mem.eql(u8, req.method, file_set_dirty_method)) {
        const dirty = singleBoolParam(req.params, "dirty") catch return errorResponse(gpa, req.id, .invalid_params);
        access.setDirty(dirty) catch return errorResponse(gpa, req.id, .internal_error);
        return serializeFileMutationResult(gpa, req.id, "dirty", dirty);
    }
    return errorResponse(gpa, req.id, .method_not_found);
}

fn singleStringParam(params: ?std.json.Value, key: []const u8) error{InvalidParams}![]const u8 {
    const obj = switch (params orelse return error.InvalidParams) {
        .object => |obj| obj,
        else => return error.InvalidParams,
    };
    if (obj.count() != 1) return error.InvalidParams;
    return switch (obj.get(key) orelse return error.InvalidParams) {
        .string => |value| value,
        else => error.InvalidParams,
    };
}

fn singleBoolParam(params: ?std.json.Value, key: []const u8) error{InvalidParams}!bool {
    const obj = switch (params orelse return error.InvalidParams) {
        .object => |obj| obj,
        else => return error.InvalidParams,
    };
    if (obj.count() != 1) return error.InvalidParams;
    return switch (obj.get(key) orelse return error.InvalidParams) {
        .bool => |value| value,
        else => error.InvalidParams,
    };
}

fn readAssetPath(params: ?std.json.Value) error{InvalidParams}![]const u8 {
    const obj = switch (params orelse return error.InvalidParams) {
        .object => |obj| obj,
        else => return error.InvalidParams,
    };
    if (obj.count() != 1) return error.InvalidParams;
    return switch (obj.get("path") orelse return error.InvalidParams) {
        .string => |path| if (path.len > 0) path else error.InvalidParams,
        else => error.InvalidParams,
    };
}

fn serializeFileReadResult(gpa: std.mem.Allocator, id: cp.Id, content: []const u8) std.mem.Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    cp.beginResult(&s, id) catch return error.OutOfMemory;
    s.objectField("content") catch return error.OutOfMemory;
    s.write(content) catch return error.OutOfMemory;
    cp.endResult(&s) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn serializeFileAssetResult(
    gpa: std.mem.Allocator,
    id: cp.Id,
    mime: []const u8,
    bytes: []const u8,
) std.mem.Allocator.Error![]u8 {
    const encoded_len = std.base64.standard.Encoder.calcSize(bytes.len);
    const encoded = try gpa.alloc(u8, encoded_len);
    defer gpa.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, bytes);

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    cp.beginResult(&s, id) catch return error.OutOfMemory;
    s.objectField("mime") catch return error.OutOfMemory;
    s.write(mime) catch return error.OutOfMemory;
    s.objectField("data_base64") catch return error.OutOfMemory;
    s.write(encoded) catch return error.OutOfMemory;
    cp.endResult(&s) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn serializeFileMutationResult(gpa: std.mem.Allocator, id: cp.Id, key: []const u8, value: anytype) std.mem.Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    cp.beginResult(&s, id) catch return error.OutOfMemory;
    s.objectField(key) catch return error.OutOfMemory;
    s.write(value) catch return error.OutOfMemory;
    cp.endResult(&s) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
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

const FakeFileAccess = struct {
    read_calls: usize = 0,
    asset_calls: usize = 0,
    last_asset_path: [128]u8 = undefined,
    last_asset_path_len: usize = 0,
    fail: bool = false,
    last_write: [256]u8 = undefined,
    last_write_len: usize = 0,
    dirty: bool = false,

    fn read(context: *anyopaque, gpa: std.mem.Allocator) anyerror![]u8 {
        const self: *FakeFileAccess = @ptrCast(@alignCast(context));
        self.read_calls += 1;
        if (self.fail) return error.ReadFailed;
        return gpa.dupe(u8, "# fixture\n\n안전한 본문");
    }

    fn readAsset(context: *anyopaque, gpa: std.mem.Allocator, path: []const u8) anyerror![]u8 {
        const self: *FakeFileAccess = @ptrCast(@alignCast(context));
        self.asset_calls += 1;
        if (self.fail) return error.ReadFailed;
        @memcpy(self.last_asset_path[0..path.len], path);
        self.last_asset_path_len = path.len;
        return gpa.dupe(u8, &.{ 0x89, 0x50, 0x4e, 0x47 });
    }

    fn write(context: *anyopaque, content: []const u8) anyerror!void {
        const self: *FakeFileAccess = @ptrCast(@alignCast(context));
        if (self.fail or content.len > self.last_write.len) return error.WriteFailed;
        @memcpy(self.last_write[0..content.len], content);
        self.last_write_len = content.len;
    }

    fn setDirty(context: *anyopaque, dirty: bool) anyerror!void {
        const self: *FakeFileAccess = @ptrCast(@alignCast(context));
        if (self.fail) return error.DirtyFailed;
        self.dirty = dirty;
    }

    fn access(self: *FakeFileAccess) FileAccess {
        return .{ .context = self, .read_fn = read, .read_asset_fn = readAsset, .write_fn = write, .set_dirty_fn = setDirty };
    }
};

test "dispatchBridge: file.read is no-arg, provider-scoped, and returns UTF-8 content" {
    var fake: FakeFileAccess = .{};
    const req = "{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"maru.file.read\"}";
    const resp = try dispatchBridgeWithFileAccess(testing.allocator, req, "0.1.0", fake.access());
    defer testing.allocator.free(resp);
    var p = try parseValue(testing.allocator, resp);
    defer p.deinit();
    try testing.expectEqualStrings("# fixture\n\n안전한 본문", p.value.object.get("result").?.object.get("content").?.string);
    try testing.expectEqual(@as(usize, 1), fake.read_calls);

    const with_params = "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"maru.file.read\",\"params\":{}}";
    const bad = try dispatchBridgeWithFileAccess(testing.allocator, with_params, "0.1.0", fake.access());
    defer testing.allocator.free(bad);
    var bp = try parseValue(testing.allocator, bad);
    defer bp.deinit();
    try testing.expectEqual(@as(i64, -32602), bp.value.object.get("error").?.object.get("code").?.integer);
    try testing.expectEqual(@as(usize, 1), fake.read_calls);

    const absent = try dispatchBridge(testing.allocator, req, "0.1.0");
    defer testing.allocator.free(absent);
    var ap = try parseValue(testing.allocator, absent);
    defer ap.deinit();
    try testing.expectEqual(@as(i64, -32601), ap.value.object.get("error").?.object.get("code").?.integer);
}

test "dispatchBridge: file.readAsset normalizes path and base64 encodes bytes" {
    var fake: FakeFileAccess = .{};
    const req = "{\"jsonrpc\":\"2.0\",\"id\":10,\"method\":\"maru.file.readAsset\",\"params\":{\"path\":\"./images//diagram.PNG\"}}";
    const resp = try dispatchBridgeWithFileAccess(testing.allocator, req, "0.1.0", fake.access());
    defer testing.allocator.free(resp);
    var p = try parseValue(testing.allocator, resp);
    defer p.deinit();
    const result = p.value.object.get("result").?.object;
    try testing.expectEqualStrings("image/png", result.get("mime").?.string);
    try testing.expectEqualStrings("iVBORw==", result.get("data_base64").?.string);
    try testing.expectEqualStrings("images/diagram.PNG", fake.last_asset_path[0..fake.last_asset_path_len]);
}

test "dispatchBridge: file.readAsset rejects malformed and traversal params before provider" {
    var fake: FakeFileAccess = .{};
    const cases = [_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"maru.file.readAsset\"}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"maru.file.readAsset\",\"params\":{\"path\":\"../secret\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"maru.file.readAsset\",\"params\":{\"path\":\"a.png\",\"extra\":true}}",
    };
    for (cases) |req| {
        const resp = try dispatchBridgeWithFileAccess(testing.allocator, req, "0.1.0", fake.access());
        defer testing.allocator.free(resp);
        var p = try parseValue(testing.allocator, resp);
        defer p.deinit();
        try testing.expectEqual(@as(i64, -32602), p.value.object.get("error").?.object.get("code").?.integer);
    }
    try testing.expectEqual(@as(usize, 0), fake.asset_calls);
}

test "dispatchBridge: file.write and dirty are pinned provider mutations with exact params" {
    var fake: FakeFileAccess = .{};
    const dirty_req = "{\"jsonrpc\":\"2.0\",\"id\":11,\"method\":\"maru.file.setDirty\",\"params\":{\"dirty\":true}}";
    const dirty_resp = try dispatchBridgeWithFileAccess(testing.allocator, dirty_req, "0.1.0", fake.access());
    defer testing.allocator.free(dirty_resp);
    try testing.expect(fake.dirty);

    const write_req = "{\"jsonrpc\":\"2.0\",\"id\":12,\"method\":\"maru.file.write\",\"params\":{\"content\":\"# 저장\\n\"}}";
    const write_resp = try dispatchBridgeWithFileAccess(testing.allocator, write_req, "0.1.0", fake.access());
    defer testing.allocator.free(write_resp);
    try testing.expectEqualStrings("# 저장\n", fake.last_write[0..fake.last_write_len]);
    try testing.expect(fake.dirty); // write와 dirty ack는 별도 직렬 mutation이다.

    const bad = "{\"jsonrpc\":\"2.0\",\"id\":13,\"method\":\"maru.file.write\",\"params\":{\"content\":\"x\",\"path\":\"/tmp/escape.md\"}}";
    const bad_resp = try dispatchBridgeWithFileAccess(testing.allocator, bad, "0.1.0", fake.access());
    defer testing.allocator.free(bad_resp);
    var parsed = try parseValue(testing.allocator, bad_resp);
    defer parsed.deinit();
    try testing.expectEqual(@as(i64, -32602), parsed.value.object.get("error").?.object.get("code").?.integer);
}

test "dispatchBridge: provider failures are uniform internal errors" {
    var fake: FakeFileAccess = .{ .fail = true };
    const req = "{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"maru.file.read\"}";
    const resp = try dispatchBridgeWithFileAccess(testing.allocator, req, "0.1.0", fake.access());
    defer testing.allocator.free(resp);
    var p = try parseValue(testing.allocator, resp);
    defer p.deinit();
    try testing.expectEqual(@as(i64, -32603), p.value.object.get("error").?.object.get("code").?.integer);
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
