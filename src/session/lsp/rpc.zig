//! JSON-RPC 2.0 위의 LSP 메시지(docs/editor-surface-tooling.md §8.2a) — **만드는 쪽**(initialize·didOpen·didChange·didClose·shutdown·
//! exit)과 **읽는 쪽**(응답·알림·서버 요청을 가른다). 순수 계산이라 여기 산다. 1단이 보내는 요청은 `initialize`·`shutdown` 둘뿐이라
//! id 대조표가 필요 없다 — 응답의 id 가 그 둘 중 무엇인지만 안다.
//!
//! **서버 → 클라이언트 요청은 전부 거부한다**(§8.2a 「하지 않는 것」): `window/workDoneProgress/create`·`workspace/configuration`·
//! `client/registerCapability`·`workspace/applyEdit`… 어느 것이든 `MethodNotFound`(-32601) 로 답한다 — 승인 UI 가 없는 동안은 거부만.

const std = @import("std");

/// 우리가 보내는 요청의 id. 알림은 id 가 없다. `initialize`·`shutdown` 은 고정 번호, `hover`(2단 ①, §8.2b)는 `hover_id_base + seq` —
/// 응답을 「지금 기다리는 seq」와 대조해 낡은 것을 버린다(`$/cancelRequest` 는 안 보낸다).
pub const RequestId = union(enum) {
    initialize,
    shutdown,
    hover: u32,
    definition: u32,
};
pub const initialize_id: u32 = 1;
pub const shutdown_id: u32 = 2;
pub const hover_id_base: u32 = 1000;
/// `definition`(2단 ②, §8.2c)의 id 는 `definition_id_base + seq`. hover 와 겹치지 않게 1000 칸 뒤 — seq 는 u32 라 `hover` 가
/// 1000 칸을 넘어 자랄 수 있으므로 **큰 쪽부터 가른다**(`classify`).
pub const definition_id_base: u32 = 2_000_000_000;

/// 위치 인코딩 — `initialize` 에서 utf-8 을 먼저 제안하고 서버가 고른 것을 쓴다(§8.2a).
pub const PositionEncoding = enum { utf8, utf16 };

pub fn initializeRequest(allocator: std.mem.Allocator, root_uri: []const u8, pid: i64) error{OutOfMemory}![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{
        .jsonrpc = "2.0",
        .id = initialize_id,
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
                    .hover = .{ .contentFormat = [_][]const u8{ "markdown", "plaintext" } },
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

/// `textDocument/hover`(§8.2b). `line`·`character` 는 서버 인코딩의 단위(`position.characterOf`).
pub fn hoverRequest(allocator: std.mem.Allocator, seq: u32, uri: []const u8, line: u32, character: u32) error{OutOfMemory}![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{
        .jsonrpc = "2.0",
        .id = hover_id_base + seq,
        .method = "textDocument/hover",
        .params = .{ .textDocument = .{ .uri = uri }, .position = .{ .line = line, .character = character } },
    }, .{});
}

/// `textDocument/definition`(§8.2c).
pub fn definitionRequest(allocator: std.mem.Allocator, seq: u32, uri: []const u8, line: u32, character: u32) error{OutOfMemory}![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{
        .jsonrpc = "2.0",
        .id = definition_id_base + seq,
        .method = "textDocument/definition",
        .params = .{ .textDocument = .{ .uri = uri }, .position = .{ .line = line, .character = character } },
    }, .{});
}

/// definition 결과의 **첫 항목**(§8.2c 「결과」) — `Location` · `Location[]` · `LocationLink[]`. `LocationLink` 는 `targetSelectionRange`
/// (없으면 `targetRange`)의 시작. `null`·빈 배열·모양이 아니면 `null`. `uri` 는 응답 트리 안의 조각(파싱 결과가 사는 동안 유효).
pub const Target = struct { uri: []const u8, line: u32, character: u32 };
pub fn definitionTarget(result: ?std.json.Value) ?Target {
    const r = result orelse return null;
    const first: std.json.Value = switch (r) {
        .object => r,
        .array => |a| if (a.items.len > 0) a.items[0] else return null,
        else => return null,
    };
    if (first != .object) return null;
    const o = first.object;
    // LocationLink
    if (o.get("targetUri")) |tu| {
        if (tu != .string) return null;
        const range = o.get("targetSelectionRange") orelse o.get("targetRange") orelse return null;
        const st = startOf(range) orelse return null;
        return .{ .uri = tu.string, .line = st.line, .character = st.character };
    }
    const uri = o.get("uri") orelse return null;
    if (uri != .string) return null;
    const st = startOf(o.get("range") orelse return null) orelse return null;
    return .{ .uri = uri.string, .line = st.line, .character = st.character };
}

fn startOf(range: std.json.Value) ?struct { line: u32, character: u32 } {
    if (range != .object) return null;
    const st = range.object.get("start") orelse return null;
    if (st != .object) return null;
    return .{
        .line = u32Of(st.object.get("line")) orelse return null,
        .character = u32Of(st.object.get("character")) orelse return null,
    };
}

/// hover 응답의 `contents` 를 **마크다운 한 덩어리**로 편다(§8.2b) — 세 모양이 있다: `MarkupContent{kind,value}` · `MarkedString`
/// (문자열 또는 `{language,value}` — 후자는 펜스로 친다) · 그 배열(빈 줄로 잇는다). `null` 결과나 빈 내용이면 `null`.
/// 돌려주는 것은 호출자 소유.
pub fn hoverMarkdown(allocator: std.mem.Allocator, result: ?std.json.Value) error{OutOfMemory}!?[]u8 {
    const r = result orelse return null;
    const obj = switch (r) {
        .object => |o| o,
        else => return null,
    };
    const contents = obj.get("contents") orelse return null;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try appendMarked(allocator, &out, contents);
    const text = std.mem.trim(u8, out.items, " \t\r\n");
    if (text.len == 0) {
        out.deinit(allocator);
        return null;
    }
    const owned = try allocator.dupe(u8, text);
    out.deinit(allocator);
    return owned;
}

fn appendMarked(allocator: std.mem.Allocator, out: *std.ArrayList(u8), v: std.json.Value) error{OutOfMemory}!void {
    switch (v) {
        .string => |s| try out.appendSlice(allocator, s),
        .array => |items| for (items.items, 0..) |it, i| {
            if (i > 0) try out.appendSlice(allocator, "\n\n");
            try appendMarked(allocator, out, it);
        },
        .object => |o| {
            const value: []const u8 = if (o.get("value")) |x| (switch (x) {
                .string => |s| s,
                else => "",
            }) else "";
            if (o.get("language")) |lang| if (lang == .string) {
                try out.appendSlice(allocator, "```");
                try out.appendSlice(allocator, lang.string);
                try out.append(allocator, '\n');
                try out.appendSlice(allocator, value);
                try out.appendSlice(allocator, "\n```");
                return;
            };
            try out.appendSlice(allocator, value); // MarkupContent — kind 가 plaintext 여도 축소 규칙은 무해하다
        },
        else => {},
    }
}

/// hover 응답의 `range`(있으면) → `{start,end}` 의 `{line,character}` 넷. 없으면 `null`.
pub const Range = struct { start_line: u32, start_char: u32, end_line: u32, end_char: u32 };
pub fn hoverRange(result: ?std.json.Value) ?Range {
    const r = result orelse return null;
    if (r != .object) return null;
    const range = r.object.get("range") orelse return null;
    if (range != .object) return null;
    const st = range.object.get("start") orelse return null;
    const en = range.object.get("end") orelse return null;
    if (st != .object or en != .object) return null;
    return .{
        .start_line = u32Of(st.object.get("line")) orelse return null,
        .start_char = u32Of(st.object.get("character")) orelse return null,
        .end_line = u32Of(en.object.get("line")) orelse return null,
        .end_char = u32Of(en.object.get("character")) orelse return null,
    };
}

fn u32Of(v: ?std.json.Value) ?u32 {
    const x = v orelse return null;
    return switch (x) {
        .integer => |n| if (n >= 0 and n <= std.math.maxInt(u32)) @intCast(n) else null,
        else => null,
    };
}

pub fn shutdownRequest(allocator: std.mem.Allocator) error{OutOfMemory}![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{ .jsonrpc = "2.0", .id = shutdown_id, .method = "shutdown", .params = null }, .{});
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
        initialize_id => .initialize,
        shutdown_id => .shutdown,
        else => if (id_num >= definition_id_base and id_num - definition_id_base <= std.math.maxInt(u32))
            .{ .definition = @intCast(id_num - definition_id_base) }
        else if (id_num >= hover_id_base and id_num - hover_id_base <= std.math.maxInt(u32))
            .{ .hover = @intCast(id_num - hover_id_base) }
        else
            return .ignore,
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

test "LSJ5 hover — 요청 id 는 1000+seq·contentFormat 에 markdown, 응답은 seq 로 대조, contents 세 모양이 마크다운 한 덩어리 (§8.2b)" {
    const a = testing.allocator;
    const req = try hoverRequest(a, 7, "file:///a.c", 3, 5);
    defer a.free(req);
    try testing.expect(std.mem.indexOf(u8, req, "\"id\":1007") != null);
    try testing.expect(std.mem.indexOf(u8, req, "\"method\":\"textDocument/hover\"") != null);
    try testing.expect(std.mem.indexOf(u8, req, "\"line\":3,\"character\":5") != null);
    const init = try initializeRequest(a, "file:///r", 1);
    defer a.free(init);
    try testing.expect(std.mem.indexOf(u8, init, "\"hover\":{\"contentFormat\":[\"markdown\",\"plaintext\"]}") != null);
    // 응답 대조 — 1007 은 hover seq 7, 999 는 모르는 id.
    var p1 = try parse(a, "{\"jsonrpc\":\"2.0\",\"id\":1007,\"result\":null}");
    defer p1.deinit();
    const c1 = classify(p1.value);
    try testing.expect(c1 == .response and c1.response.id == .hover and c1.response.id.hover == 7);
    try testing.expect((try hoverMarkdown(a, c1.response.result)) == null); // null 결과 = 내용 없음
    var p2 = try parse(a, "{\"jsonrpc\":\"2.0\",\"id\":999,\"result\":null}");
    defer p2.deinit();
    try testing.expect(classify(p2.value) == .ignore);
    // contents 세 모양.
    var m1 = try parse(a, "{\"contents\":{\"kind\":\"markdown\",\"value\":\"**x**\"},\"range\":{\"start\":{\"line\":1,\"character\":2},\"end\":{\"line\":1,\"character\":5}}}");
    defer m1.deinit();
    const t1 = (try hoverMarkdown(a, m1.value)).?;
    defer a.free(t1);
    try testing.expectEqualStrings("**x**", t1);
    const rg = hoverRange(m1.value).?;
    try testing.expectEqual(@as(u32, 2), rg.start_char);
    try testing.expectEqual(@as(u32, 5), rg.end_char);
    var m2 = try parse(a, "{\"contents\":[{\"language\":\"c\",\"value\":\"int x\"},\"doc\"]}");
    defer m2.deinit();
    const t2 = (try hoverMarkdown(a, m2.value)).?;
    defer a.free(t2);
    try testing.expectEqualStrings("```c\nint x\n```\n\ndoc", t2);
    try testing.expect(hoverRange(m2.value) == null);
    var m3 = try parse(a, "{\"contents\":\"  \"}");
    defer m3.deinit();
    try testing.expect((try hoverMarkdown(a, m3.value)) == null); // 공백뿐이면 없음
}

test "LSJ6 definition — 요청 id 는 2_000_000_000+seq, 응답은 seq 로 대조(hover 와 안 겹침), 결과 세 모양의 첫 항목·LocationLink 는 selection range (§8.2c)" {
    const a = testing.allocator;
    const req = try definitionRequest(a, 3, "file:///a.c", 1, 2);
    defer a.free(req);
    try testing.expect(std.mem.indexOf(u8, req, "\"id\":2000000003") != null);
    try testing.expect(std.mem.indexOf(u8, req, "\"method\":\"textDocument/definition\"") != null);
    var p1 = try parse(a, "{\"jsonrpc\":\"2.0\",\"id\":2000000003,\"result\":null}");
    defer p1.deinit();
    const c1 = classify(p1.value);
    try testing.expect(c1 == .response and c1.response.id == .definition and c1.response.id.definition == 3);
    try testing.expect(definitionTarget(c1.response.result) == null);
    var p2 = try parse(a, "{\"jsonrpc\":\"2.0\",\"id\":1003,\"result\":null}");
    defer p2.deinit();
    try testing.expect(classify(p2.value).response.id == .hover); // 1003 은 hover 3 — definition 이 아니다
    // Location 하나.
    var l1 = try parse(a, "{\"uri\":\"file:///b.c\",\"range\":{\"start\":{\"line\":4,\"character\":2},\"end\":{\"line\":4,\"character\":5}}}");
    defer l1.deinit();
    const t1 = definitionTarget(l1.value).?;
    try testing.expectEqualStrings("file:///b.c", t1.uri);
    try testing.expectEqual(@as(u32, 4), t1.line);
    try testing.expectEqual(@as(u32, 2), t1.character);
    // Location[] — 첫 항목. LocationLink[] — targetSelectionRange 가 targetRange 보다 먼저.
    var l2 = try parse(a, "[{\"uri\":\"file:///c.c\",\"range\":{\"start\":{\"line\":1,\"character\":0},\"end\":{\"line\":1,\"character\":1}}},{\"uri\":\"file:///d.c\",\"range\":{\"start\":{\"line\":9,\"character\":9},\"end\":{\"line\":9,\"character\":9}}}]");
    defer l2.deinit();
    try testing.expectEqualStrings("file:///c.c", definitionTarget(l2.value).?.uri);
    var l3 = try parse(a, "[{\"targetUri\":\"file:///e.c\",\"targetRange\":{\"start\":{\"line\":10,\"character\":0},\"end\":{\"line\":20,\"character\":0}},\"targetSelectionRange\":{\"start\":{\"line\":10,\"character\":4},\"end\":{\"line\":10,\"character\":8}}}]");
    defer l3.deinit();
    const t3 = definitionTarget(l3.value).?;
    try testing.expectEqualStrings("file:///e.c", t3.uri);
    try testing.expectEqual(@as(u32, 4), t3.character);
    var l4 = try parse(a, "[{\"targetUri\":\"file:///f.c\",\"targetRange\":{\"start\":{\"line\":3,\"character\":1},\"end\":{\"line\":3,\"character\":2}}}]");
    defer l4.deinit();
    try testing.expectEqual(@as(u32, 3), definitionTarget(l4.value).?.line); // selection 이 없으면 targetRange
    var l5 = try parse(a, "[]");
    defer l5.deinit();
    try testing.expect(definitionTarget(l5.value) == null);
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
