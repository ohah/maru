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
//! - `textDocument/formatting` → 각 줄에서 **첫 두 칸 이상 공백 묶음**을 한 칸으로 줄이는 `TextEdit[]`(줄마다 하나, 줄 순서의 **역순**으로 보내
//!   클라이언트가 정렬해야 한다; character = byte — ASCII 본문에서만 맞다). 본문에 `NOFMT` 면 `null`, `BADFMT` 면 겹치는 edit 둘(거부돼야 한다).
//!   `options` 가 계약(§8.2e ③)과 다르면 — `insertSpaces` 가 false 가 아니거나 `tabSize` 가 1 미만 — `null`(제품 경계에서 options 를 잰다).
//!   capability `documentFormattingProvider: true`(`MARU_FAKE_LSP_NOFMTCAP=1` 이면 false — 클라이언트가 요청을 안 보내야 한다).
//! - `textDocument/rename` → 요청 자리의 식별자를 이 문서와 같은 디렉터리 `other.c`(**디스크에서** 읽는다 — 열려 있지 않은 파일의 관측점)에서
//!   낱말 단위로 `newName` 으로 바꾸는 `WorkspaceEdit`(`changes` 맵; `MARU_FAKE_LSP_RENAME_DOCCHANGES=1` 이면 `documentChanges` + version).
//!   `RENAMEFAIL` → 오류 응답 · `RENAMEOUT` → root 밖 파일 edit 추가 · `RENAMECREATE` → `CreateFile` 추가 · `RENAMEBAD` → 겹치는 edit ·
//!   `RENAMESTALEVER` → `documentChanges` 의 version 을 하나 낮춰(낡은 결과).
//!   capability `renameProvider: true`(`MARU_FAKE_LSP_NORENAMECAP=1` 이면 false).
//! - `textDocument/completion` → 문서의 식별자 전부(나온 순서 sortText) + `fake_import`(textEdit 접두사 교체 + additionalTextEdits 로 첫 줄 include,
//!   preselect) + `fake_tail`(additional 이 다음 줄 머리 — 낱말 뒤) + `.` 바로 뒤면 `arrow_fix`(textEdit 이 `x.` 부터 덮어 `x->m`).
//!   접두사로 거르지 않는다(로컬 필터 관측점), caret 앞 낱말이 2 글자 미만이면 `isIncomplete`. `NOCOMP` → `null`.
//!   capability `completionProvider{triggerCharacters: ["."]}`(`MARU_FAKE_LSP_NOCOMPCAP=1` 이면 없음).
//! - `textDocument/codeAction` → 문맥 진단마다 「fake: fix <code>」(range → `FIXED`, 첫 것 isPreferred) + 「fake: lazy」(data 만 — resolve) +
//!   「fake: command」(command 만) + `Command` 형(둘은 숨겨져야 한다). `NOACT` → `[]`. `codeAction/resolve` → 첫 줄에 `// lazy` 를 넣는 edit;
//!   `RESOLVEFAIL` → 오류. capability `codeActionProvider{resolveProvider: true}`(`MARU_FAKE_LSP_NOACTCAP=1` 이면 없음).
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
const DocText = struct { uri: [1024]u8 = undefined, len: usize = 0, text: [65536]u8 = undefined, text_len: usize = 0, version: i64 = 0 };
var doc_texts: [8]DocText = [_]DocText{.{}} ** 8;

fn setDocText(uri: []const u8, text: []const u8, version: i64) void {
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
    d.version = version;
}

fn docVersion(uri: []const u8) i64 {
    for (&doc_texts) |*d| if (d.len == uri.len and std.mem.eql(u8, d.uri[0..d.len], uri)) return d.version;
    return 0;
}

fn docText(uri: []const u8) []const u8 {
    for (&doc_texts) |*d| if (d.len == uri.len and std.mem.eql(u8, d.uri[0..d.len], uri)) return d.text[0..d.text_len];
    return "";
}

/// `line_no` 줄의 `character`(byte 로 친다 — 가짜 서버는 ASCII 픽스처만 받는다) 앞 본문.
/// `textDocument/rename`(§8.2f 관측점) — 요청 자리의 식별자를 문서 전체와 같은 디렉터리의 `other.c`(디스크에서 읽는다 — 열려 있지 않아도)
/// 에서 **낱말 단위**로 찾아 `newName` 으로 바꾸는 `WorkspaceEdit`. 기본은 `changes` 맵, `MARU_FAKE_LSP_RENAME_DOCCHANGES=1` 이면
/// `documentChanges`(마지막으로 본 version 을 싣는다). 본문 표식: `RENAMEFAIL` → 오류 응답(`fake: cannot rename`) · `RENAMEOUT` → root 밖
/// 파일의 edit 을 하나 더 · `RENAMECREATE` → `documentChanges` 에 `CreateFile` 을 하나 더 · `RENAMEBAD` → 겹치는 edit 둘.
fn handleRename(allocator: std.mem.Allocator, obj: std.json.ObjectMap, id: std.json.Value) void {
    var req_uri: []const u8 = "";
    var line_no: i64 = 0;
    var character: i64 = 0;
    var new_name: []const u8 = "";
    if (obj.get("params")) |p| if (p == .object) {
        if (p.object.get("textDocument")) |td| if (td == .object) {
            req_uri = str(td.object.get("uri")) orelse "";
        };
        if (p.object.get("position")) |pos| if (pos == .object) {
            line_no = int(pos.object.get("line")) orelse 0;
            character = int(pos.object.get("character")) orelse 0;
        };
        new_name = str(p.object.get("newName")) orelse "";
    };
    const text = docText(req_uri);
    if (std.mem.indexOf(u8, text, "RENAMEFAIL") != null) {
        sendJson(allocator, .{ .jsonrpc = "2.0", .id = id, .@"error" = .{ .code = @as(i32, -32602), .message = "fake: cannot rename" } });
        return;
    }
    // 요청 자리의 낱말.
    const before = lineBefore(text, line_no, character);
    const line_start = @intFromPtr(before.ptr) - @intFromPtr(text.ptr);
    const caret = line_start + before.len;
    var ws = caret;
    var we = caret;
    while (ws > 0 and isIdent(text[ws - 1])) ws -= 1;
    while (we < text.len and isIdent(text[we])) we += 1;
    if (ws == we) {
        sendJson(allocator, .{ .jsonrpc = "2.0", .id = id, .result = null });
        return;
    }
    const word = text[ws..we];
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var root: std.json.ObjectMap = .empty;
    const want_create = std.mem.indexOf(u8, text, "RENAMECREATE") != null;
    const stale_ver = std.mem.indexOf(u8, text, "RENAMESTALEVER") != null; // documentChanges 의 version 을 하나 낮춰 낸다(클라이언트가 버려야 한다)
    const use_doc_changes = want_create or stale_ver or std.c.getenv("MARU_FAKE_LSP_RENAME_DOCCHANGES") != null; // 파일 연산은 documentChanges 에만 실릴 수 있다
    var doc_changes: std.json.Array = .init(arena);
    var changes: std.json.ObjectMap = .empty;
    if (want_create) {
        var op: std.json.ObjectMap = .empty;
        op.put(arena, "kind", .{ .string = "create" }) catch return;
        op.put(arena, "uri", .{ .string = "file:///tmp/fake-new.c" }) catch return;
        doc_changes.append(.{ .object = op }) catch return;
    }
    // 이 문서.
    {
        const edits = renameEdits(arena, text, word, new_name, std.mem.indexOf(u8, text, "RENAMEBAD") != null) catch return;
        addFileEdits(arena, &changes, &doc_changes, use_doc_changes, req_uri, docVersion(req_uri) - @as(i64, if (stale_ver) 1 else 0), edits) catch return;
    }
    // 같은 디렉터리의 other.c — 디스크에서 읽는다(열려 있지 않은 파일의 관측점).
    if (std.mem.lastIndexOfScalar(u8, req_uri, '/')) |slash| {
        var uri_buf: [1200]u8 = undefined;
        const other_uri = std.fmt.bufPrint(&uri_buf, "{s}/other.c", .{req_uri[0..slash]}) catch "";
        if (std.mem.startsWith(u8, other_uri, "file://")) {
            const other_path = other_uri["file://".len..];
            if (readFileC(arena, other_path)) |other_text| {
                const edits = renameEdits(arena, other_text, word, new_name, false) catch return;
                if (edits.items.len > 0) {
                    const other_known = docVersion(other_uri);
                    addFileEdits(arena, &changes, &doc_changes, use_doc_changes, other_uri, other_known, edits) catch return;
                }
            }
        }
    }
    if (std.mem.indexOf(u8, text, "RENAMEOUT") != null) {
        const edits = renameEdits(arena, "int x;\n", "x", new_name, false) catch return;
        addFileEdits(arena, &changes, &doc_changes, use_doc_changes, "file:///nonexistent-outside-root/x.c", 0, edits) catch return;
    }
    if (use_doc_changes) {
        root.put(arena, "documentChanges", .{ .array = doc_changes }) catch return;
    } else {
        root.put(arena, "changes", .{ .object = changes }) catch return;
    }
    sendJson(allocator, .{ .jsonrpc = "2.0", .id = id, .result = std.json.Value{ .object = root } });
}

/// `textDocument/completion`(§8.2g 관측점) — 문서의 식별자(중복 없이, 나온 순서 = sortText `0000`~)를 항목으로 내고, 마지막에 `fake_import`
/// (`textEdit` 로 `[낱말 시작, caret)` 교체 + `additionalTextEdits` 로 첫 줄에 `#include "fake.h"\n`, `preselect`) 를 더한다. **접두사로 거르지
/// 않는다**(로컬 필터의 관측점). caret 앞 낱말이 2 글자 미만이면 `isIncomplete: true`(재요청의 관측점). 본문에 `NOCOMP` 면 `null`.
/// capability `completionProvider{triggerCharacters: ["."]}`(`MARU_FAKE_LSP_NOCOMPCAP=1` 이면 없음).
fn handleCompletion(allocator: std.mem.Allocator, obj: std.json.ObjectMap, id: std.json.Value) void {
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
    if (std.mem.indexOf(u8, text, "NOCOMP") != null) {
        sendJson(allocator, .{ .jsonrpc = "2.0", .id = id, .result = null });
        return;
    }
    const before = lineBefore(text, line_no, character);
    var ws = before.len;
    while (ws > 0 and isIdent(before[ws - 1])) ws -= 1;
    const prefix_len = before.len - ws;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var items: std.json.Array = .init(arena);
    var seen: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    var n: usize = 0;
    while (i < text.len) {
        if (!isIdent(text[i])) {
            i += 1;
            continue;
        }
        var j = i;
        while (j < text.len and isIdent(text[j])) j += 1;
        const word = text[i..j];
        i = j;
        if (std.ascii.isDigit(word[0])) continue;
        var dup = false;
        for (seen.items) |w| if (std.mem.eql(u8, w, word)) {
            dup = true;
        };
        if (dup) continue;
        seen.append(arena, word) catch return;
        var it: std.json.ObjectMap = .empty;
        it.put(arena, "label", .{ .string = word }) catch return;
        it.put(arena, "detail", .{ .string = "fake" }) catch return;
        it.put(arena, "sortText", .{ .string = std.fmt.allocPrint(arena, "{d:0>4}", .{n}) catch return }) catch return;
        items.append(.{ .object = it }) catch return;
        n += 1;
    }
    {
        var it: std.json.ObjectMap = .empty;
        it.put(arena, "label", .{ .string = "fake_import" }) catch return;
        it.put(arena, "detail", .{ .string = "adds include" }) catch return;
        it.put(arena, "sortText", .{ .string = "zzzz" }) catch return;
        it.put(arena, "preselect", .{ .bool = true }) catch return;
        // textEdit: [낱말 시작, caret) → fake_import
        var te: std.json.ObjectMap = .empty;
        var range: std.json.ObjectMap = .empty;
        var s: std.json.ObjectMap = .empty;
        s.put(arena, "line", .{ .integer = line_no }) catch return;
        s.put(arena, "character", .{ .integer = @intCast(ws) }) catch return;
        var e: std.json.ObjectMap = .empty;
        e.put(arena, "line", .{ .integer = line_no }) catch return;
        e.put(arena, "character", .{ .integer = character }) catch return;
        range.put(arena, "start", .{ .object = s }) catch return;
        range.put(arena, "end", .{ .object = e }) catch return;
        te.put(arena, "range", .{ .object = range }) catch return;
        te.put(arena, "newText", .{ .string = "fake_import" }) catch return;
        it.put(arena, "textEdit", .{ .object = te }) catch return;
        var adds: std.json.Array = .init(arena);
        adds.append(editValue(arena, 0, 0, 0, "#include \"fake.h\"\n") catch return) catch return;
        it.put(arena, "additionalTextEdits", .{ .array = adds }) catch return;
        items.append(.{ .object = it }) catch return;
    }
    {
        // fake_tail — additional 이 **낱말 뒤**(다음 줄 머리)에 있다: 응답 뒤 문서가 바뀌면 버려져야 한다(§8.2g 「적용」).
        var it: std.json.ObjectMap = .empty;
        it.put(arena, "label", .{ .string = "fake_tail" }) catch return;
        it.put(arena, "sortText", .{ .string = "zzzx" }) catch return;
        var adds: std.json.Array = .init(arena);
        adds.append(editValue(arena, line_no + 1, 0, 0, "// tail\n") catch return) catch return;
        it.put(arena, "additionalTextEdits", .{ .array = adds }) catch return;
        items.append(.{ .object = it }) catch return;
    }
    if (ws >= 2 and before[ws - 1] == '.' and isIdent(before[ws - 2])) {
        // arrow_fix — `x.` 뒤에서 `textEdit` 이 낱말 시작 **앞**(`x.` 부터)을 덮는다(clangd 의 `.`→`->` 교정과 같은 모양).
        var it: std.json.ObjectMap = .empty;
        it.put(arena, "label", .{ .string = "arrow_fix" }) catch return;
        it.put(arena, "sortText", .{ .string = "0000" }) catch return;
        var te: std.json.ObjectMap = .empty;
        var range: std.json.ObjectMap = .empty;
        var s: std.json.ObjectMap = .empty;
        s.put(arena, "line", .{ .integer = line_no }) catch return;
        s.put(arena, "character", .{ .integer = @intCast(ws - 2) }) catch return;
        var e: std.json.ObjectMap = .empty;
        e.put(arena, "line", .{ .integer = line_no }) catch return;
        e.put(arena, "character", .{ .integer = character }) catch return;
        range.put(arena, "start", .{ .object = s }) catch return;
        range.put(arena, "end", .{ .object = e }) catch return;
        te.put(arena, "range", .{ .object = range }) catch return;
        te.put(arena, "newText", .{ .string = "x->m" }) catch return;
        it.put(arena, "textEdit", .{ .object = te }) catch return;
        items.append(.{ .object = it }) catch return;
    }
    var root: std.json.ObjectMap = .empty;
    root.put(arena, "isIncomplete", .{ .bool = prefix_len < 2 }) catch return;
    root.put(arena, "items", .{ .array = items }) catch return;
    sendJson(allocator, .{ .jsonrpc = "2.0", .id = id, .result = std.json.Value{ .object = root } });
}

/// `textDocument/codeAction`(§8.2h 관측점) — `context.diagnostics` 마다 「fake: fix <code>」(그 range 를 `FIXED` 로 바꾸는 `edit`, 첫 것은
/// `isPreferred`), 늘 「fake: lazy」(`edit` 없이 `data` 만 — resolve 로 온다)와 「fake: command」(`command` 만 — 숨겨져야 한다), `Command` 형
/// 하나. 본문에 `NOACT` 면 `[]`. `RESOLVEFAIL` 이면 resolve 가 오류 응답. 진단 없이 오면 fix 는 없다(문맥 관측점).
fn handleCodeAction(allocator: std.mem.Allocator, obj: std.json.ObjectMap, id: std.json.Value) void {
    var req_uri: []const u8 = "";
    var ctx_diags: ?std.json.Array = null;
    if (obj.get("params")) |p| if (p == .object) {
        if (p.object.get("textDocument")) |td| if (td == .object) {
            req_uri = str(td.object.get("uri")) orelse "";
        };
        if (p.object.get("context")) |c| if (c == .object) if (c.object.get("diagnostics")) |d| if (d == .array) {
            ctx_diags = d.array;
        };
    };
    const text = docText(req_uri);
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var items: std.json.Array = .init(arena);
    if (std.mem.indexOf(u8, text, "NOACT") != null) {
        sendJson(allocator, .{ .jsonrpc = "2.0", .id = id, .result = std.json.Value{ .array = items } });
        return;
    }
    if (ctx_diags) |ds| for (ds.items, 0..) |dg, i| {
        if (dg != .object) continue;
        const range = dg.object.get("range") orelse continue;
        const code = str(dg.object.get("code")) orelse "?";
        var it: std.json.ObjectMap = .empty;
        it.put(arena, "title", .{ .string = std.fmt.allocPrint(arena, "fake: fix {s}", .{code}) catch return }) catch return;
        it.put(arena, "kind", .{ .string = "quickfix" }) catch return;
        if (i == 0) it.put(arena, "isPreferred", .{ .bool = true }) catch return;
        var te: std.json.ObjectMap = .empty;
        te.put(arena, "range", range) catch return;
        te.put(arena, "newText", .{ .string = "FIXED" }) catch return;
        var arr: std.json.Array = .init(arena);
        arr.append(.{ .object = te }) catch return;
        var changes: std.json.ObjectMap = .empty;
        changes.put(arena, arena.dupe(u8, req_uri) catch return, .{ .array = arr }) catch return;
        var edit: std.json.ObjectMap = .empty;
        edit.put(arena, "changes", .{ .object = changes }) catch return;
        it.put(arena, "edit", .{ .object = edit }) catch return;
        items.append(.{ .object = it }) catch return;
    };
    {
        var it: std.json.ObjectMap = .empty;
        it.put(arena, "title", .{ .string = "fake: lazy" }) catch return;
        it.put(arena, "kind", .{ .string = "refactor" }) catch return;
        var data: std.json.ObjectMap = .empty;
        data.put(arena, "uri", .{ .string = arena.dupe(u8, req_uri) catch return }) catch return;
        data.put(arena, "id", .{ .integer = 1 }) catch return;
        it.put(arena, "data", .{ .object = data }) catch return;
        items.append(.{ .object = it }) catch return;
    }
    {
        var it: std.json.ObjectMap = .empty;
        it.put(arena, "title", .{ .string = "fake: command" }) catch return;
        var cmd: std.json.ObjectMap = .empty;
        cmd.put(arena, "title", .{ .string = "c" }) catch return;
        cmd.put(arena, "command", .{ .string = "fake.run" }) catch return;
        it.put(arena, "command", .{ .object = cmd }) catch return;
        items.append(.{ .object = it }) catch return;
    }
    {
        var it: std.json.ObjectMap = .empty;
        it.put(arena, "title", .{ .string = "fake: Command form" }) catch return;
        it.put(arena, "command", .{ .string = "fake.run" }) catch return;
        items.append(.{ .object = it }) catch return;
    }
    sendJson(allocator, .{ .jsonrpc = "2.0", .id = id, .result = std.json.Value{ .array = items } });
}

/// `codeAction/resolve` — `data.uri` 의 문서 첫 줄 머리에 `// lazy\n` 을 넣는 `edit`. `RESOLVEFAIL` 이면 오류.
fn handleCodeActionResolve(allocator: std.mem.Allocator, obj: std.json.ObjectMap, id: std.json.Value) void {
    var uri: []const u8 = "";
    if (obj.get("params")) |p| if (p == .object) if (p.object.get("data")) |d| if (d == .object) {
        uri = str(d.object.get("uri")) orelse "";
    };
    const text = docText(uri);
    if (std.mem.indexOf(u8, text, "RESOLVEFAIL") != null or uri.len == 0) {
        sendJson(allocator, .{ .jsonrpc = "2.0", .id = id, .@"error" = .{ .code = @as(i32, -32603), .message = "fake: cannot resolve" } });
        return;
    }
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var arr: std.json.Array = .init(arena);
    arr.append(editValue(arena, 0, 0, 0, "// lazy\n") catch return) catch return;
    var changes: std.json.ObjectMap = .empty;
    changes.put(arena, arena.dupe(u8, uri) catch return, .{ .array = arr }) catch return;
    var edit: std.json.ObjectMap = .empty;
    edit.put(arena, "changes", .{ .object = changes }) catch return;
    var it: std.json.ObjectMap = .empty;
    it.put(arena, "title", .{ .string = "fake: lazy" }) catch return;
    it.put(arena, "edit", .{ .object = edit }) catch return;
    sendJson(allocator, .{ .jsonrpc = "2.0", .id = id, .result = std.json.Value{ .object = it } });
}

/// libc 로 파일을 읽는다(이 도구는 std.Io 를 안 쓴다). 없으면 null. 상한 64 KB.
fn readFileC(arena: std.mem.Allocator, path: []const u8) ?[]u8 {
    var path_z: [1200]u8 = undefined;
    if (path.len >= path_z.len) return null;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;
    const fd = std.c.open(path_z[0..path.len :0].ptr, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return null;
    defer _ = std.c.close(fd);
    const buf = arena.alloc(u8, 65536) catch return null;
    var len: usize = 0;
    while (len < buf.len) {
        const n = std.c.read(fd, buf[len..].ptr, buf.len - len);
        if (n <= 0) break;
        len += @intCast(n);
    }
    return buf[0..len];
}

fn isIdent(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '_' or b >= 0x80;
}

/// `text` 안의 `word` 낱말 전부를 `new_name` 으로 바꾸는 TextEdit 들(character = byte — ASCII 본문). `bad` 면 첫 edit 을 겹치게 하나 더 낸다.
fn renameEdits(arena: std.mem.Allocator, text: []const u8, word: []const u8, new_name: []const u8, bad: bool) !std.json.Array {
    var edits: std.json.Array = .init(arena);
    var line_no: i64 = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| : (line_no += 1) {
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, line, from, word)) |at| {
            from = at + word.len;
            const left_ok = at == 0 or !isIdent(line[at - 1]);
            const right_ok = at + word.len >= line.len or !isIdent(line[at + word.len]);
            if (!left_ok or !right_ok) continue;
            try edits.append(try editValue(arena, line_no, at, at + word.len, new_name));
            if (bad and edits.items.len == 1) try edits.append(try editValue(arena, line_no, at + 1, at + word.len + 1, new_name));
        }
    }
    return edits;
}

fn editValue(arena: std.mem.Allocator, line_no: i64, start: usize, end: usize, new_text: []const u8) !std.json.Value {
    var s: std.json.ObjectMap = .empty;
    try s.put(arena, "line", .{ .integer = line_no });
    try s.put(arena, "character", .{ .integer = @intCast(start) });
    var e: std.json.ObjectMap = .empty;
    try e.put(arena, "line", .{ .integer = line_no });
    try e.put(arena, "character", .{ .integer = @intCast(end) });
    var range: std.json.ObjectMap = .empty;
    try range.put(arena, "start", .{ .object = s });
    try range.put(arena, "end", .{ .object = e });
    var edit: std.json.ObjectMap = .empty;
    try edit.put(arena, "range", .{ .object = range });
    try edit.put(arena, "newText", .{ .string = new_text });
    return .{ .object = edit };
}

fn addFileEdits(arena: std.mem.Allocator, changes: *std.json.ObjectMap, doc_changes: *std.json.Array, use_doc_changes: bool, uri: []const u8, version: i64, edits: std.json.Array) !void {
    const uri_copy = try arena.dupe(u8, uri);
    if (use_doc_changes) {
        var td: std.json.ObjectMap = .empty;
        try td.put(arena, "uri", .{ .string = uri_copy });
        try td.put(arena, "version", if (version == 0) .null else .{ .integer = version });
        var tde: std.json.ObjectMap = .empty;
        try tde.put(arena, "textDocument", .{ .object = td });
        try tde.put(arena, "edits", .{ .array = edits });
        try doc_changes.append(.{ .object = tde });
    } else {
        try changes.put(arena, uri_copy, .{ .array = edits });
    }
}

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
        sendJson(allocator, .{
            .jsonrpc = "2.0",
            .id = id.?,
            .result = .{
                .capabilities = .{
                    .positionEncoding = if (utf8 and !force_utf16) "utf-8" else "utf-16",
                    .textDocumentSync = @as(u8, 1),
                    .signatureHelpProvider = .{ .triggerCharacters = [_][]const u8{ "(", "," }, .retriggerCharacters = [_][]const u8{")"} },
                    .documentFormattingProvider = std.c.getenv("MARU_FAKE_LSP_NOFMTCAP") == null, // `MARU_FAKE_LSP_NOFMTCAP=1` 이면 false
                    .renameProvider = std.c.getenv("MARU_FAKE_LSP_NORENAMECAP") == null, // `MARU_FAKE_LSP_NORENAMECAP=1` 이면 false
                    .completionProvider = if (std.c.getenv("MARU_FAKE_LSP_NOCOMPCAP") == null) .{ .triggerCharacters = [_][]const u8{"."} } else null,
                    .codeActionProvider = if (std.c.getenv("MARU_FAKE_LSP_NOACTCAP") == null) .{ .codeActionKinds = [_][]const u8{"quickfix"}, .resolveProvider = true } else null,
                },
            },
        });
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
    if (std.mem.eql(u8, method, "textDocument/formatting")) {
        var req_uri: []const u8 = "";
        var options_ok = false;
        if (obj.get("params")) |p| if (p == .object) {
            if (p.object.get("textDocument")) |td| if (td == .object) {
                req_uri = str(td.object.get("uri")) orelse "";
            };
            if (p.object.get("options")) |o| if (o == .object) {
                const insert_spaces = o.object.get("insertSpaces");
                const tab_size = int(o.object.get("tabSize")) orelse 0;
                options_ok = insert_spaces != null and insert_spaces.? == .bool and !insert_spaces.?.bool and tab_size >= 1;
            };
        };
        const text = docText(req_uri);
        const Pos = struct { line: u32, character: u32 };
        if (!options_ok) {
            sendJson(allocator, .{ .jsonrpc = "2.0", .id = id.?, .result = null });
            return;
        }
        const Edit = struct { range: struct { start: Pos, end: Pos }, newText: []const u8 };
        if (std.mem.indexOf(u8, text, "NOFMT") != null) {
            sendJson(allocator, .{ .jsonrpc = "2.0", .id = id.?, .result = null });
            return;
        }
        if (std.mem.indexOf(u8, text, "BADFMT") != null) {
            sendJson(allocator, .{ .jsonrpc = "2.0", .id = id.?, .result = [_]Edit{
                .{ .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 2 } }, .newText = "x" },
                .{ .range = .{ .start = .{ .line = 0, .character = 1 }, .end = .{ .line = 0, .character = 3 } }, .newText = "y" },
            } });
            return;
        }
        var edits: std.ArrayList(Edit) = .empty;
        defer edits.deinit(allocator);
        var line_no: u32 = 0;
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |line| : (line_no += 1) {
            const at = std.mem.indexOf(u8, line, "  ") orelse continue;
            var end = at;
            while (end < line.len and line[end] == ' ') end += 1;
            edits.append(allocator, .{ .range = .{ .start = .{ .line = line_no, .character = @intCast(at) }, .end = .{ .line = line_no, .character = @intCast(end) } }, .newText = " " }) catch return;
        }
        std.mem.reverse(Edit, edits.items); // 역순 — 정렬은 클라이언트의 몫이다
        sendJson(allocator, .{ .jsonrpc = "2.0", .id = id.?, .result = edits.items });
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/rename")) {
        handleRename(allocator, obj, id.?);
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/completion")) {
        handleCompletion(allocator, obj, id.?);
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/codeAction")) {
        handleCodeAction(allocator, obj, id.?);
        return;
    }
    if (std.mem.eql(u8, method, "codeAction/resolve")) {
        handleCodeActionResolve(allocator, obj, id.?);
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
        setDocText(uri, text, version);
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
