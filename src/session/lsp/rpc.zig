//! JSON-RPC 2.0 위의 LSP 메시지(docs/editor-surface-tooling.md §8.2a) — **만드는 쪽**(initialize·didOpen·didChange·didClose·shutdown·
//! exit)과 **읽는 쪽**(응답·알림·서버 요청을 가른다). 순수 계산이라 여기 산다. 1단이 보내는 요청은 `initialize`·`shutdown` 둘뿐이라
//! id 대조표가 필요 없다 — 응답의 id 가 그 둘 중 무엇인지만 안다.
//!
//! **서버 → 클라이언트 요청은 전부 거부한다**(§8.2a 「하지 않는 것」): `window/workDoneProgress/create`·`workspace/configuration`·
//! `client/registerCapability`·`workspace/applyEdit`… 어느 것이든 `MethodNotFound`(-32601) 로 답한다 — 승인 UI 가 없는 동안은 거부만.

const std = @import("std");

/// 1단이 보내는 요청의 id. 알림은 id 가 없다.
pub const RequestId = enum(u32) {
    initialize = 1,
    shutdown = 2,
};

/// 위치 인코딩 — `initialize` 에서 utf-8 을 먼저 제안하고 서버가 고른 것을 쓴다(§8.2a).
pub const PositionEncoding = enum { utf8, utf16 };

pub fn initializeRequest(allocator: std.mem.Allocator, root_uri: []const u8, pid: i64) error{OutOfMemory}![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{
        .jsonrpc = "2.0",
        .id = @intFromEnum(RequestId.initialize),
        .method = "initialize",
        .params = .{
            .processId = pid,
            .rootUri = root_uri,
            .workspaceFolders = [_]struct { uri: []const u8, name: []const u8 }{.{ .uri = root_uri, .name = "root" }},
            .capabilities = .{
                .general = .{ .positionEncodings = [_][]const u8{ "utf-8", "utf-16" } },
                .textDocument = .{
                    .synchronization = .{ .dynamicRegistration = false, .didSave = false },
                    .publishDiagnostics = .{ .versionSupport = true },
                },
                .workspace = .{ .applyEdit = false, .configuration = false, .workspaceFolders = false },
            },
        },
    }, .{});
}

pub fn initializedNotification(allocator: std.mem.Allocator) error{OutOfMemory}![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{ .jsonrpc = "2.0", .method = "initialized", .params = .{} }, .{});
}

pub fn didOpen(allocator: std.mem.Allocator, uri: []const u8, language_id: []const u8, version: i64, text: []const u8) error{OutOfMemory}![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{
        .jsonrpc = "2.0",
        .method = "textDocument/didOpen",
        .params = .{ .textDocument = .{ .uri = uri, .languageId = language_id, .version = version, .text = text } },
    }, .{});
}

/// Full sync(§8.2a): 변경 하나에 전문. 증분은 2단.
pub fn didChangeFull(allocator: std.mem.Allocator, uri: []const u8, version: i64, text: []const u8) error{OutOfMemory}![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{
        .jsonrpc = "2.0",
        .method = "textDocument/didChange",
        .params = .{
            .textDocument = .{ .uri = uri, .version = version },
            .contentChanges = [_]struct { text: []const u8 }{.{ .text = text }},
        },
    }, .{});
}

pub fn didClose(allocator: std.mem.Allocator, uri: []const u8) error{OutOfMemory}![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{
        .jsonrpc = "2.0",
        .method = "textDocument/didClose",
        .params = .{ .textDocument = .{ .uri = uri } },
    }, .{});
}

pub fn shutdownRequest(allocator: std.mem.Allocator) error{OutOfMemory}![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{ .jsonrpc = "2.0", .id = @intFromEnum(RequestId.shutdown), .method = "shutdown", .params = null }, .{});
}

pub fn exitNotification(allocator: std.mem.Allocator) error{OutOfMemory}![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{ .jsonrpc = "2.0", .method = "exit", .params = null }, .{});
}

/// 서버 요청 거부 응답(-32601). `id` 는 서버가 준 값 그대로(숫자 또는 문자열) — 대조는 서버가 한다.
pub fn methodNotFound(allocator: std.mem.Allocator, id: std.json.Value) error{OutOfMemory}![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{
        .jsonrpc = "2.0",
        .id = id,
        .@"error" = .{ .code = @as(i32, -32601), .message = "method not supported by this client" },
    }, .{});
}

/// 파일 경로 → `file://` URI. 예약 문자는 퍼센트 인코딩(RFC 3986 unreserved 와 `/` 만 그대로).
pub fn fileUri(allocator: std.mem.Allocator, path: []const u8) error{OutOfMemory}![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "file://");
    for (path) |c| {
        const keep = std.ascii.isAlphanumeric(c) or c == '/' or c == '-' or c == '_' or c == '.' or c == '~';
        if (keep) {
            try out.append(allocator, c);
        } else {
            var hex: [3]u8 = undefined;
            _ = std.fmt.bufPrint(&hex, "%{X:0>2}", .{c}) catch unreachable;
            try out.appendSlice(allocator, &hex);
        }
    }
    return out.toOwnedSlice(allocator);
}

/// `file://` URI → 경로(퍼센트 디코딩). 다른 scheme 이면 `null`. 결과는 `out` 안의 조각.
pub fn pathFromFileUri(uri: []const u8, out: []u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, uri, "file://")) return null;
    var rest = uri["file://".len..];
    // `file://localhost/x` 는 드물지만 명세상 유효 — host 를 뗀다. `file:///x` 는 host 가 빈 것.
    if (rest.len > 0 and rest[0] != '/') {
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
        rest = rest[slash..];
    }
    var n: usize = 0;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        if (n >= out.len) return null;
        if (rest[i] == '%' and i + 2 < rest.len) {
            const v = std.fmt.parseInt(u8, rest[i + 1 .. i + 3], 16) catch return null;
            out[n] = v;
            i += 2;
        } else out[n] = rest[i];
        n += 1;
    }
    return out[0..n];
}

/// 들어온 메시지의 갈래.
pub const Incoming = union(enum) {
    /// 우리가 보낸 요청의 응답. `result` 는 트리 안의 값(파싱 결과가 사는 동안 유효).
    response: struct { id: RequestId, result: ?std.json.Value, is_error: bool },
    /// 서버 알림(`publishDiagnostics` 등).
    notification: struct { method: []const u8, params: ?std.json.Value },
    /// 서버 → 클라이언트 요청(id 있음) — 거부 대상.
    request: struct { id: std.json.Value, method: []const u8 },
    /// 모르는 id 의 응답이나 모양이 아닌 것 — 버린다.
    ignore,
};

pub fn classify(root: std.json.Value) Incoming {
    const obj = switch (root) {
        .object => |o| o,
        else => return .ignore,
    };
    const method: ?[]const u8 = if (obj.get("method")) |m| (switch (m) {
        .string => |s| s,
        else => null,
    }) else null;
    const id = obj.get("id");
    if (method) |m| {
        if (id != null and id.? != .null) return .{ .request = .{ .id = id.?, .method = m } };
        return .{ .notification = .{ .method = m, .params = obj.get("params") } };
    }
    const id_val = id orelse return .ignore;
    const id_num: i64 = switch (id_val) {
        .integer => |n| n,
        else => return .ignore,
    };
    const rid: RequestId = switch (id_num) {
        @intFromEnum(RequestId.initialize) => .initialize,
        @intFromEnum(RequestId.shutdown) => .shutdown,
        else => return .ignore,
    };
    const is_error = obj.get("error") != null;
    return .{ .response = .{ .id = rid, .result = obj.get("result"), .is_error = is_error } };
}

/// `initialize` 응답에서 서버가 고른 위치 인코딩. 없으면 명세 기본(utf-16).
pub fn positionEncodingFromResult(result: ?std.json.Value) PositionEncoding {
    const r = result orelse return .utf16;
    const caps = switch (r) {
        .object => |o| o.get("capabilities") orelse return .utf16,
        else => return .utf16,
    };
    const enc = switch (caps) {
        .object => |o| o.get("positionEncoding") orelse return .utf16,
        else => return .utf16,
    };
    return switch (enc) {
        .string => |s| if (std.mem.eql(u8, s, "utf-8")) .utf8 else .utf16,
        else => .utf16,
    };
}

// ── 판정 ────────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn parse(a: std.mem.Allocator, text: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, a, text, .{});
}

test "LSJ1 initialize 는 id 1·rootUri·utf-8 먼저인 positionEncodings·applyEdit false 를 싣는다 (§8.2a)" {
    const a = testing.allocator;
    const msg = try initializeRequest(a, "file:///r", 42);
    defer a.free(msg);
    var p = try parse(a, msg);
    defer p.deinit();
    const o = p.value.object;
    try testing.expectEqual(@as(i64, 1), o.get("id").?.integer);
    try testing.expectEqualStrings("initialize", o.get("method").?.string);
    const params = o.get("params").?.object;
    try testing.expectEqualStrings("file:///r", params.get("rootUri").?.string);
    try testing.expectEqual(@as(i64, 42), params.get("processId").?.integer);
    const enc = params.get("capabilities").?.object.get("general").?.object.get("positionEncodings").?.array;
    try testing.expectEqualStrings("utf-8", enc.items[0].string);
    try testing.expectEqualStrings("utf-16", enc.items[1].string);
    try testing.expect(!params.get("capabilities").?.object.get("workspace").?.object.get("applyEdit").?.bool);
    try testing.expect(params.get("capabilities").?.object.get("textDocument").?.object.get("publishDiagnostics").?.object.get("versionSupport").?.bool);
}

test "LSJ2 didOpen/didChange/didClose — uri·version·전문, didChange 는 contentChanges 하나(Full) (§8.2a)" {
    const a = testing.allocator;
    const o1 = try didOpen(a, "file:///a.c", "c", 3, "int x;\n");
    defer a.free(o1);
    var p1 = try parse(a, o1);
    defer p1.deinit();
    const td = p1.value.object.get("params").?.object.get("textDocument").?.object;
    try testing.expectEqualStrings("c", td.get("languageId").?.string);
    try testing.expectEqual(@as(i64, 3), td.get("version").?.integer);
    try testing.expectEqualStrings("int x;\n", td.get("text").?.string);
    try testing.expect(p1.value.object.get("id") == null); // 알림

    const c1 = try didChangeFull(a, "file:///a.c", 4, "int y;\n");
    defer a.free(c1);
    var p2 = try parse(a, c1);
    defer p2.deinit();
    const changes = p2.value.object.get("params").?.object.get("contentChanges").?.array;
    try testing.expectEqual(@as(usize, 1), changes.items.len);
    try testing.expect(changes.items[0].object.get("range") == null); // Full — range 없음
    try testing.expectEqualStrings("int y;\n", changes.items[0].object.get("text").?.string);

    const cl = try didClose(a, "file:///a.c");
    defer a.free(cl);
    try testing.expect(std.mem.indexOf(u8, cl, "textDocument/didClose") != null);
}

test "LSJ3 들어온 메시지를 가른다 — 응답(우리 id 만)·알림·서버 요청(거부 대상)·모르는 것 (§8.2a)" {
    const a = testing.allocator;
    var r = try parse(a, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"capabilities\":{\"positionEncoding\":\"utf-8\"}}}");
    defer r.deinit();
    const c1 = classify(r.value);
    try testing.expect(c1 == .response and c1.response.id == .initialize and !c1.response.is_error);
    try testing.expectEqual(PositionEncoding.utf8, positionEncodingFromResult(c1.response.result));

    var n = try parse(a, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":\"file:///a\"}}");
    defer n.deinit();
    const c2 = classify(n.value);
    try testing.expect(c2 == .notification);
    try testing.expectEqualStrings("textDocument/publishDiagnostics", c2.notification.method);

    var q = try parse(a, "{\"jsonrpc\":\"2.0\",\"id\":\"srv-7\",\"method\":\"workspace/configuration\",\"params\":{}}");
    defer q.deinit();
    const c3 = classify(q.value);
    try testing.expect(c3 == .request);
    try testing.expectEqualStrings("workspace/configuration", c3.request.method);
    const rej = try methodNotFound(a, c3.request.id);
    defer a.free(rej);
    try testing.expect(std.mem.indexOf(u8, rej, "\"id\":\"srv-7\"") != null);
    try testing.expect(std.mem.indexOf(u8, rej, "-32601") != null);

    var u = try parse(a, "{\"jsonrpc\":\"2.0\",\"id\":99,\"result\":null}");
    defer u.deinit();
    try testing.expect(classify(u.value) == .ignore); // 우리가 보낸 적 없는 id
    var e = try parse(a, "{\"jsonrpc\":\"2.0\",\"id\":2,\"error\":{\"code\":-1,\"message\":\"x\"}}");
    defer e.deinit();
    const c5 = classify(e.value);
    try testing.expect(c5 == .response and c5.response.id == .shutdown and c5.response.is_error);
    var arr = try parse(a, "[1,2]");
    defer arr.deinit();
    try testing.expect(classify(arr.value) == .ignore);
    // 인코딩 기본은 utf-16 — 없으면·모르면.
    var r2 = try parse(a, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"capabilities\":{}}}");
    defer r2.deinit();
    try testing.expectEqual(PositionEncoding.utf16, positionEncodingFromResult(classify(r2.value).response.result));
}

test "LSJ4 file URI — 공백·한글은 퍼센트, 되읽으면 같은 경로 (§8.2a)" {
    const a = testing.allocator;
    const uri = try fileUri(a, "/tmp/a b/가.c");
    defer a.free(uri);
    try testing.expectEqualStrings("file:///tmp/a%20b/%EA%B0%80.c", uri);
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("/tmp/a b/가.c", pathFromFileUri(uri, &buf).?);
    try testing.expect(pathFromFileUri("http://x/y", &buf) == null);
    try testing.expectEqualStrings("/x", pathFromFileUri("file://localhost/x", &buf).?);
}
