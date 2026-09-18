//! 가짜 언어 서버(docs/editor-surface-tooling.md §8.2a 관측점) — 판정자가 `MARU_LSP_SERVER_OVERRIDE` 로 끼운다.
//!
//! stdin 에서 Content-Length 프레임을 읽고:
//! - `initialize` → 응답(제안된 인코딩에 utf-8 이 있으면 `positionEncoding: "utf-8"`, `MARU_FAKE_LSP_UTF16=1` 이면 utf-16; textDocumentSync Full).
//! - `initialized` → 서버 → 클라이언트 요청 `workspace/configuration` 하나(클라이언트가 **거부**해야 한다). 그 응답(id `srv-1`,
//!   result 든 error 든)이 오면 `answered` — 안 온 채 didChange 를 받으면 WARN 진단의 message 가 `fake: warn noack` 이 된다
//!   (답이 없으면 실서버는 그 요청에 **영원히 매달린다** — 카운터가 아니라 서버 쪽에서 봐야 변이 B7 이 죽는다).
//! - `didOpen`/`didChange` → 그 문서의 `publishDiagnostics` 하나: 첫 줄 0..3 에 error, message `fake: <version>`·code `E1`, `version` 은
//!   문서 version. 본문에 `STALE` 이 있으면 version 을 **하나 낮춰**(클라이언트가 버려야 한다). `BOOM` 이 있으면 즉시 exit 1(재시작).
//!   `WARN` 이 있으면 severity 2 를 하나 더(둘째 줄 0..2). `INFO` 가 있으면 severity 3 을 첫 줄 0..1 에 하나 더(message 두 줄).
//! - `HANG` 이 있으면 stdout 을 **닫고 살아 있는다**(진단도 exit 도 없다) — 클라이언트는 EOF 를 「끝」으로 보고 죽여 재시작해야 한다.
//! - `textDocument/hover` → contents(markdown): 펜스 `int fake` · `fake hover L<line>:C<char>` · `**bold** here` · 항목 14개(`- item N`,
//!   상자 높이 상한 12행을 넘긴다), range = 그 줄의 `character..character+3`(클라이언트가 앵커로 써야 한다). 본문에 `NOHOVER` 가
//!   있으면 `null` 결과(내용 없음). `MUTEHOVER` 가 있으면 hover 에 **답하지 않는다**(시간 초과 경로).
//! - `textDocument/definition` → `Location[]` 둘(첫 항목 = 줄 1, 글자 = **요청한 character**; 둘째는 버려져야 한다). 본문에 `NODEF` 면 `null`, `XFILE` 이면
//!   같은 디렉터리의 `other.c`, `OUTSIDE` 면 `file:///nonexistent-outside-root/x.c`(root 밖).
//! - `textDocument/signatureHelp` → 요청 줄의 caret 앞에서 마지막 `(` 뒤 `,` 수를 activeParameter 로, 시그니처 둘(`int add(int a, int b)` —
//!   parameters 는 `[8,13]`·`[15,20]`, doc `**adds** two`·첫 파라미터 doc `first`; `int add(double a)`). `(` 가 없거나 닫혔거나 `NOSIG` 면 `null`.
//!   capability 로 triggerCharacters `(`·`,` 와 retriggerCharacters `)` 를 낸다.
//! - `shutdown` → `null` 응답, `exit` → 종료 0.
//! - 시작하자마자 stderr 에 한 줄을 쓴다(실서버 clangd 가 그렇다) — stdout 에 섞이면 프레임이 깨진다(§8.2a 「stderr」).
//! 순수 판정 대상이 아니라(맞으면 되는 도구) 테스트는 없다 — 이 도구의 계약은 `LSPB*` 가 제품 경계에서 든다.

const std = @import("std");

fn writeAll(bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = std.c.write(1, bytes[off..].ptr, bytes.len - off);
        if (n <= 0) std.c._exit(0);
        off += @intCast(n);
    }
}

fn sendJson(allocator: std.mem.Allocator, v: anytype) void {
    const body = std.json.Stringify.valueAlloc(allocator, v, .{}) catch return;
    defer allocator.free(body);
    var hdr: [64]u8 = undefined;
    const h = std.fmt.bufPrint(&hdr, "Content-Length: {d}\r\n\r\n", .{body.len}) catch return;
    writeAll(h);
    writeAll(body);
}

fn nextFrame(buf: []const u8) ?struct { body: []const u8, consumed: usize } {
    const header_end = std.mem.indexOf(u8, buf, "\r\n\r\n") orelse return null;
    var len: ?usize = null;
    var it = std.mem.splitSequence(u8, buf[0..header_end], "\r\n");
    while (it.next()) |line| {
        if (line.len > 15 and std.ascii.eqlIgnoreCase(line[0..15], "content-length:")) {
            len = std.fmt.parseInt(usize, std.mem.trim(u8, line[15..], " "), 10) catch return null;
        }
    }
    const n = len orelse return null;
    if (buf.len < header_end + 4 + n) return null;
    return .{ .body = buf[header_end + 4 .. header_end + 4 + n], .consumed = header_end + 4 + n };
}

fn str(v: ?std.json.Value) ?[]const u8 {
    const x = v orelse return null;
    return switch (x) {
        .string => |s| s,
        else => null,
    };
}

fn int(v: ?std.json.Value) ?i64 {
    const x = v orelse return null;
    return switch (x) {
        .integer => |n| n,
        else => null,
    };
}

extern "c" fn usleep(us: c_uint) c_int;

pub fn main() void {
    const allocator = std.heap.c_allocator;
    const noise = "fake: stderr noise\n";
    _ = std.c.write(2, noise.ptr, noise.len);
    var inbuf: std.ArrayList(u8) = .empty;
    var chunk: [16 * 1024]u8 = undefined;
    while (true) {
        const n = std.c.read(0, &chunk, chunk.len);
        if (n <= 0) std.c._exit(0);
        inbuf.appendSlice(allocator, chunk[0..@intCast(n)]) catch std.c._exit(2);
        while (nextFrame(inbuf.items)) |f| {
            handle(allocator, f.body);
            const rest = inbuf.items.len - f.consumed;
            std.mem.copyForwards(u8, inbuf.items[0..rest], inbuf.items[f.consumed..]);
            inbuf.shrinkRetainingCapacity(rest);
        }
    }
}

var answered = false;
/// 마지막 didOpen/didChange 본문에 `NOHOVER` 가 있었다 — hover 가 `null` 을 낸다.
var no_hover = false;
/// 마지막 본문에 `MUTEHOVER` 가 있었다 — hover 요청에 **답하지 않는다**.
var mute_hover = false;
/// definition 의 답 모양 — **문서마다**(uri 별로) 본문 표식으로 고른다: `NODEF` → null · `XFILE` → 같은 디렉터리 `other.c` · `OUTSIDE` →
/// root 밖 경로 · 없으면 같은 파일. 전역 하나로 두면 다른 문서의 didOpen 이 뒤에 와서 되돌린다(GOTO1 실측 — other.c 의 didOpen 이
/// g.c 의 `OUTSIDE` 를 지웠다).
const DefMode = enum { same, none, other, outside };
const DocMode = struct { uri: [1024]u8 = undefined, len: usize = 0, mode: DefMode = .same };
var doc_modes: [8]DocMode = [_]DocMode{.{}} ** 8;

fn setDocMode(uri: []const u8, mode: DefMode) void {
    if (uri.len > 1024) return;
    for (&doc_modes) |*d| if (d.len == uri.len and std.mem.eql(u8, d.uri[0..d.len], uri)) {
        d.mode = mode;
        return;
    };
    for (&doc_modes) |*d| if (d.len == 0) {
        @memcpy(d.uri[0..uri.len], uri);
        d.len = uri.len;
        d.mode = mode;
        return;
    };
}

/// 문서 본문을 uri 별로 기억한다(signatureHelp 가 caret 앞을 본다). 상한 8 문서·64 KB.
const DocText = struct { uri: [1024]u8 = undefined, len: usize = 0, text: [65536]u8 = undefined, text_len: usize = 0 };
var doc_texts: [8]DocText = [_]DocText{.{}} ** 8;

fn setDocText(uri: []const u8, text: []const u8) void {
    if (uri.len > 1024 or text.len > 65536) return;
    var slot: ?*DocText = null;
    for (&doc_texts) |*d| if (d.len == uri.len and std.mem.eql(u8, d.uri[0..d.len], uri)) {
        slot = d;
    };
    if (slot == null) for (&doc_texts) |*d| if (d.len == 0) {
        @memcpy(d.uri[0..uri.len], uri);
        d.len = uri.len;
        slot = d;
        break;
    };
    const d = slot orelse return;
    @memcpy(d.text[0..text.len], text);
    d.text_len = text.len;
}

fn docText(uri: []const u8) []const u8 {
    for (&doc_texts) |*d| if (d.len == uri.len and std.mem.eql(u8, d.uri[0..d.len], uri)) return d.text[0..d.text_len];
    return "";
}

/// `line_no` 줄의 `character`(byte 로 친다 — 가짜 서버는 ASCII 픽스처만 받는다) 앞 본문.
fn lineBefore(text: []const u8, line_no: i64, character: i64) []const u8 {
    var it = std.mem.splitScalar(u8, text, '\n');
    var i: i64 = 0;
    while (it.next()) |line| : (i += 1) {
        if (i == line_no) {
            const c: usize = @intCast(@max(character, 0));
            return line[0..@min(c, line.len)];
        }
    }
    return "";
}

fn docMode(uri: []const u8) DefMode {
    for (&doc_modes) |*d| if (d.len == uri.len and std.mem.eql(u8, d.uri[0..d.len], uri)) return d.mode;
    return .same;
}

fn handle(allocator: std.mem.Allocator, body: []const u8) void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return,
    };
    const id = obj.get("id");
    const method = str(obj.get("method")) orelse {
        // 응답 — 우리가 낸 `srv-1` 에 대한 것이면(거부여도) 「답을 받았다」.
        if (str(id)) |i| if (std.mem.eql(u8, i, "srv-1")) {
            answered = true;
        };
        return;
    };
    if (std.mem.eql(u8, method, "initialize")) {
        var utf8 = false;
        if (obj.get("params")) |p| if (p == .object) if (p.object.get("capabilities")) |c| if (c == .object) if (c.object.get("general")) |g| if (g == .object) if (g.object.get("positionEncodings")) |pe| if (pe == .array) {
            for (pe.array.items) |e| if (e == .string and std.mem.eql(u8, e.string, "utf-8")) {
                utf8 = true;
            };
        };
        // `MARU_FAKE_LSP_UTF16=1` 이면 제안과 무관하게 utf-16 을 고른다 — 클라이언트의 byte ↔ character 변환을 제품 경계에서 재는 데 쓴다.
        const force_utf16 = std.c.getenv("MARU_FAKE_LSP_UTF16") != null;
        sendJson(allocator, .{ .jsonrpc = "2.0", .id = id.?, .result = .{ .capabilities = .{
            .positionEncoding = if (utf8 and !force_utf16) "utf-8" else "utf-16",
            .textDocumentSync = @as(u8, 1),
            .signatureHelpProvider = .{ .triggerCharacters = [_][]const u8{ "(", "," }, .retriggerCharacters = [_][]const u8{")"} },
        } } });
        return;
    }
    if (std.mem.eql(u8, method, "initialized")) {
        sendJson(allocator, .{ .jsonrpc = "2.0", .id = "srv-1", .method = "workspace/configuration", .params = .{ .items = [_]struct { section: []const u8 }{.{ .section = "fake" }} } });
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/signatureHelp")) {
        // 요청 줄의 본문(마지막 didOpen/didChange 에서 기억)에서 caret 앞을 본다: 마지막 `(` 뒤의 `,` 수가 활성 파라미터, 그 `(` 가 없거나
        // 그 뒤에 `)` 가 왔으면 `null`(닫힌다). `NOSIG` 가 있으면 늘 `null`.
        var req_uri: []const u8 = "";
        var line_no: i64 = 0;
        var character: i64 = 0;
        if (obj.get("params")) |p| if (p == .object) {
            if (p.object.get("textDocument")) |td| if (td == .object) {
                req_uri = str(td.object.get("uri")) orelse "";
            };
            if (p.object.get("position")) |pos| if (pos == .object) {
                line_no = int(pos.object.get("line")) orelse 0;
                character = int(pos.object.get("character")) orelse 0;
            };
        };
        const text = docText(req_uri);
        const before = lineBefore(text, line_no, character);
        const open_at = std.mem.lastIndexOfScalar(u8, before, '(');
        const closed = if (open_at) |o| std.mem.indexOfScalarPos(u8, before, o, ')') != null else true;
        if (open_at == null or closed or std.mem.indexOf(u8, text, "NOSIG") != null) {
            sendJson(allocator, .{ .jsonrpc = "2.0", .id = id.?, .result = null });
            return;
        }
        const active_param: u32 = @intCast(std.mem.count(u8, before[open_at.?..], ","));
        const Param = struct { label: []const u8, documentation: ?[]const u8 = null };
        const ParamOff = struct { label: [2]u32, documentation: ?[]const u8 = null };
        sendJson(allocator, .{ .jsonrpc = "2.0", .id = id.?, .result = .{
            .signatures = .{
                .{ .label = "int add(int a, int b)", .documentation = "**adds** two", .parameters = [_]ParamOff{ .{ .label = .{ 8, 13 }, .documentation = "first" }, .{ .label = .{ 15, 20 } } } },
                .{ .label = "int add(double a)", .parameters = [_]Param{.{ .label = "double a" }} },
            },
            .activeSignature = @as(u32, 0),
            .activeParameter = active_param,
        } });
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/hover")) {
        var line: i64 = 0;
        var character: i64 = 0;
        if (obj.get("params")) |p| if (p == .object) if (p.object.get("position")) |pos| if (pos == .object) {
            line = int(pos.object.get("line")) orelse 0;
            character = int(pos.object.get("character")) orelse 0;
        };
        if (mute_hover) return; // 답하지 않는다 — 클라이언트가 시간 초과로 진단만 열어야 한다(§8.2b 「요청」)
        if (no_hover) {
            sendJson(allocator, .{ .jsonrpc = "2.0", .id = id.?, .result = null });
            return;
        }
        var md: std.ArrayList(u8) = .empty;
        defer md.deinit(allocator);
        md.print(allocator, "```c\nint fake\n```\nfake hover L{d}:C{d}\n**bold** here\n", .{ line, character }) catch return;
        for (1..15) |n| md.print(allocator, "- item {d}\n", .{n}) catch return;
        const Pos = struct { line: i64, character: i64 };
        sendJson(allocator, .{ .jsonrpc = "2.0", .id = id.?, .result = .{
            .contents = .{ .kind = "markdown", .value = md.items },
            .range = .{ .start = Pos{ .line = line, .character = character }, .end = Pos{ .line = line, .character = character + 3 } },
        } });
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/definition")) {
        var req_uri: []const u8 = "";
        var req_char: i64 = 0;
        if (obj.get("params")) |p| if (p == .object) {
            if (p.object.get("textDocument")) |td| if (td == .object) {
                req_uri = str(td.object.get("uri")) orelse "";
            };
            if (p.object.get("position")) |pos| if (pos == .object) {
                req_char = int(pos.object.get("character")) orelse 0;
            };
        };
        const def_mode = docMode(req_uri);
        const Pos = struct { line: i64, character: i64 };
        const Range = struct { start: Pos, end: Pos };
        if (def_mode == .none) {
            sendJson(allocator, .{ .jsonrpc = "2.0", .id = id.?, .result = null });
            return;
        }
        var uri_buf: [4096]u8 = undefined;
        const uri: []const u8 = switch (def_mode) {
            .same => req_uri,
            .other => blk: {
                // 같은 디렉터리의 `other.c` — 요청 uri 의 마지막 조각을 바꾼다.
                const slash = std.mem.lastIndexOfScalar(u8, req_uri, '/') orelse break :blk req_uri;
                break :blk std.fmt.bufPrint(&uri_buf, "{s}/other.c", .{req_uri[0..slash]}) catch req_uri;
            },
            .outside => "file:///nonexistent-outside-root/x.c",
            .none => unreachable,
        };
        // `Location[]` 로 낸다(가장 흔한 모양) — 둘째 항목은 버려져야 한다.
        const Loc = struct { uri: []const u8, range: Range };
        const locs = [_]Loc{
            // 첫 항목의 character 는 **요청한 자리**를 되돌린다 — 어디서 요청했는지가 답에 남아야 caret 자리로 요청한 변이(B5)가 갈린다.
            .{ .uri = uri, .range = .{ .start = .{ .line = 1, .character = req_char }, .end = .{ .line = 1, .character = req_char + 1 } } },
            .{ .uri = uri, .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 1 } } },
        };
        sendJson(allocator, .{ .jsonrpc = "2.0", .id = id.?, .result = locs });
        return;
    }
    if (std.mem.eql(u8, method, "shutdown")) {
        sendJson(allocator, .{ .jsonrpc = "2.0", .id = id.?, .result = null });
        return;
    }
    if (std.mem.eql(u8, method, "exit")) std.c._exit(0);
    if (std.mem.eql(u8, method, "textDocument/didOpen") or std.mem.eql(u8, method, "textDocument/didChange")) {
        const params = obj.get("params") orelse return;
        if (params != .object) return;
        const td = params.object.get("textDocument") orelse return;
        if (td != .object) return;
        const uri = str(td.object.get("uri")) orelse return;
        const version = int(td.object.get("version")) orelse 0;
        const text: []const u8 = blk: {
            if (str(td.object.get("text"))) |t| break :blk t;
            if (params.object.get("contentChanges")) |cc| if (cc == .array and cc.array.items.len > 0 and cc.array.items[0] == .object) {
                if (str(cc.array.items[0].object.get("text"))) |t| break :blk t;
            };
            break :blk "";
        };
        no_hover = std.mem.indexOf(u8, text, "NOHOVER") != null;
        mute_hover = std.mem.indexOf(u8, text, "MUTEHOVER") != null;
        setDocText(uri, text);
        setDocMode(uri, if (std.mem.indexOf(u8, text, "NODEF") != null) .none else if (std.mem.indexOf(u8, text, "XFILE") != null) .other else if (std.mem.indexOf(u8, text, "OUTSIDE") != null) .outside else .same);
        if (std.mem.indexOf(u8, text, "BOOM") != null) std.c._exit(1);
        if (std.mem.indexOf(u8, text, "HANG") != null) {
            _ = std.c.close(1);
            while (true) _ = usleep(100_000);
        }
        const v = if (std.mem.indexOf(u8, text, "STALE") != null) version - 1 else version;
        var msg_buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "fake: {d}", .{version}) catch "fake";
        const Diag = struct { range: struct { start: struct { line: u32, character: u32 }, end: struct { line: u32, character: u32 } }, severity: u8, message: []const u8, code: []const u8 };
        var diags: [3]Diag = undefined;
        var count: usize = 1;
        diags[0] = .{ .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 3 } }, .severity = 1, .message = msg, .code = "E1" };
        if (std.mem.indexOf(u8, text, "WARN") != null) {
            diags[count] = .{ .range = .{ .start = .{ .line = 1, .character = 0 }, .end = .{ .line = 1, .character = 2 } }, .severity = 2, .message = if (answered) "fake: warn" else "fake: warn noack", .code = "W1" };
            count += 1;
        }
        // `INFO` — 첫 줄 0..1 에 info 하나 더(error 와 같은 자리에서 시작 — 호버가 severity 순으로 내고 message 첫 줄만 쓰는지, 그리고
        // 반열림 끝(1)이 덮지 않는지 재는 데 쓴다). message 는 두 줄이다.
        if (std.mem.indexOf(u8, text, "INFO") != null) {
            diags[count] = .{ .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 1 } }, .severity = 3, .message = "fake: info\nnote: more", .code = "I1" };
            count += 1;
        }
        sendJson(allocator, .{ .jsonrpc = "2.0", .method = "textDocument/publishDiagnostics", .params = .{ .uri = uri, .version = v, .diagnostics = diags[0..count] } });
        return;
    }
    // 모르는 요청은 MethodNotFound 로.
    if (id) |i| sendJson(allocator, .{ .jsonrpc = "2.0", .id = i, .@"error" = .{ .code = @as(i32, -32601), .message = "fake: not supported" } });
}
