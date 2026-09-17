//! 가짜 언어 서버(docs/editor-surface-tooling.md §8.2a 관측점) — 판정자가 `MARU_LSP_SERVER_OVERRIDE` 로 끼운다.
//!
//! stdin 에서 Content-Length 프레임을 읽고:
//! - `initialize` → 응답(제안된 인코딩에 utf-8 이 있으면 `positionEncoding: "utf-8"`, textDocumentSync Full).
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
        sendJson(allocator, .{ .jsonrpc = "2.0", .id = id.?, .result = .{ .capabilities = .{ .positionEncoding = if (utf8) "utf-8" else "utf-16", .textDocumentSync = @as(u8, 1) } } });
        return;
    }
    if (std.mem.eql(u8, method, "initialized")) {
        sendJson(allocator, .{ .jsonrpc = "2.0", .id = "srv-1", .method = "workspace/configuration", .params = .{ .items = [_]struct { section: []const u8 }{.{ .section = "fake" }} } });
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
