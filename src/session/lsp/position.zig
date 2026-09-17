//! LSP 위치 ↔ 문서 byte(docs/editor-surface-tooling.md §8.2a 「위치 인코딩」·「진단 합치기」).
//!
//! LSP `Position` 은 `{line, character}` 이고 `character` 의 단위는 협상된 인코딩이다 — 기본 **UTF-16 code unit**, 서버가 utf-8 을
//! 고르면 byte. 우리 축은 byte(§3.1)라 줄 시작에서 그 줄 안을 걸어 옮긴다. 줄 밖·문서 밖 위치는 **줄 끝/문서 끝으로 묶는다**(서버가
//! 옛 revision 의 위치를 보내도 죽지 않는다 — 버리는 것은 version 필터가 한다).

const std = @import("std");
const rpc = @import("rpc.zig");
const diagnostic = @import("../editor/diagnostic.zig");
const LineIndex = @import("../editor/line_index.zig").LineIndex;

/// `character` → 줄 안 byte. `line_text` 는 그 줄의 내용(개행 제외).
pub fn byteInLine(line_text: []const u8, character: u32, enc: rpc.PositionEncoding) u32 {
    switch (enc) {
        .utf8 => return @intCast(@min(character, line_text.len)),
        .utf16 => {
            var units: u32 = 0;
            var i: usize = 0;
            while (i < line_text.len) {
                if (units >= character) break;
                const len = std.unicode.utf8ByteSequenceLength(line_text[i]) catch 1;
                const end = @min(i + len, line_text.len);
                const cp = std.unicode.utf8Decode(line_text[i..end]) catch 0xFFFD;
                units += if (cp >= 0x10000) 2 else 1;
                i = end;
            }
            return @intCast(i);
        },
    }
}

/// 줄 안 byte → `character`(서버 인코딩 단위) — `byteInLine` 의 역. hover 요청의 위치가 쓴다(§8.2b).
pub fn characterOf(line_text: []const u8, byte: u32, enc: rpc.PositionEncoding) u32 {
    const b: usize = @min(byte, line_text.len);
    switch (enc) {
        .utf8 => return @intCast(b),
        .utf16 => {
            var units: u32 = 0;
            var i: usize = 0;
            while (i < b) {
                const len = std.unicode.utf8ByteSequenceLength(line_text[i]) catch 1;
                const end = @min(i + len, line_text.len);
                const cp = std.unicode.utf8Decode(line_text[i..end]) catch 0xFFFD;
                units += if (cp >= 0x10000) 2 else 1;
                i = end;
            }
            return units;
        },
    }
}

/// `{line, character}` → 문서 byte. 줄이 문서 밖이면 문서 끝.
pub fn offsetOf(content: []const u8, lines: LineIndex, line: u32, character: u32, enc: rpc.PositionEncoding) u32 {
    const ln = lines.line(line) orelse return @intCast(content.len);
    const text = content[ln.start..ln.contentEnd()];
    return @intCast(ln.start + byteInLine(text, character, enc));
}

fn u32Of(v: ?std.json.Value) ?u32 {
    const x = v orelse return null;
    return switch (x) {
        .integer => |n| if (n < 0) 0 else @intCast(@min(n, std.math.maxInt(u32))),
        else => null,
    };
}

fn severityOf(v: ?std.json.Value) diagnostic.Severity {
    const n = u32Of(v) orelse return .@"error";
    return switch (n) {
        2 => .warning,
        3 => .info,
        4 => .hint,
        else => .@"error",
    };
}

/// `publishDiagnostics` params 의 `diagnostics` 배열 → 목록. 메시지는 **복사**해 `messages` 에 쌓고(§8.2a — 표시는 §8.3 이 오면),
/// 진단은 `out` 에 더한다. 범위는 반열림 byte 로, 폭 0 이면 1 byte(§5.4 와 같은 규칙). 배열이 아니면 아무것도 안 한다.
pub fn appendDiagnostics(
    allocator: std.mem.Allocator,
    params: ?std.json.Value,
    content: []const u8,
    lines: LineIndex,
    enc: rpc.PositionEncoding,
    out: *std.ArrayList(diagnostic.Diagnostic),
    messages: *std.ArrayList(u8),
) error{OutOfMemory}!usize {
    const p = params orelse return 0;
    const obj = switch (p) {
        .object => |o| o,
        else => return 0,
    };
    const arr = switch (obj.get("diagnostics") orelse return 0) {
        .array => |a| a,
        else => return 0,
    };
    // **메시지 저장소를 먼저 넉넉히 잡는다** — 슬라이스가 그 안을 가리키므로 더하는 동안 옮겨지면 앞 항목이 허공을 본다. 호출자는
    // 갈아 끼울 때 `messages` 를 비우고 부른다(이전 배치의 슬라이스는 더 안 쓴다).
    var total: usize = 0;
    for (arr.items) |item| {
        const d = switch (item) {
            .object => |o| o,
            else => continue,
        };
        total += switch (d.get("message") orelse std.json.Value{ .null = {} }) {
            .string => |m| m.len,
            else => 0,
        };
        total += codeLen(d.get("code"));
    }
    try messages.ensureTotalCapacity(allocator, messages.items.len + total);
    var n: usize = 0;
    for (arr.items) |item| {
        const d = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const range = switch (d.get("range") orelse continue) {
            .object => |o| o,
            else => continue,
        };
        const s = switch (range.get("start") orelse continue) {
            .object => |o| o,
            else => continue,
        };
        const e = switch (range.get("end") orelse continue) {
            .object => |o| o,
            else => continue,
        };
        const sl = u32Of(s.get("line")) orelse continue;
        const sc = u32Of(s.get("character")) orelse 0;
        const el = u32Of(e.get("line")) orelse sl;
        const ec = u32Of(e.get("character")) orelse sc;
        const start = offsetOf(content, lines, sl, sc, enc);
        var end = offsetOf(content, lines, el, ec, enc);
        if (end <= start) end = @min(start + 1, @as(u32, @intCast(content.len)) + 1);
        const msg: []const u8 = switch (d.get("message") orelse std.json.Value{ .null = {} }) {
            .string => |m| m,
            else => "",
        };
        const msg_start = messages.items.len;
        try messages.appendSlice(allocator, msg);
        // `code` 도 같은 저장소에 — 문자열은 그대로, 정수는 글자로(§8.2a 「진단 합치기」).
        const code_start = messages.items.len;
        try appendCode(allocator, messages, d.get("code"));
        const code_end = messages.items.len;
        try out.append(allocator, .{
            .start = start,
            .end = end,
            .severity = severityOf(d.get("severity")),
            .source = .lsp,
            .message = messages.items[msg_start .. msg_start + msg.len], // 위에서 잡아 둔 저장소 안 — 이 배치 동안 안 옮겨진다
            .code = messages.items[code_start..code_end],
        });
        n += 1;
    }
    return n;
}

/// `code` 가 차지할 글자 수(저장소를 미리 잡으려고). 정수는 최대 20 자리.
fn codeLen(v: ?std.json.Value) usize {
    const x = v orelse return 0;
    return switch (x) {
        .string => |c| c.len,
        .integer => 20,
        else => 0,
    };
}

fn appendCode(allocator: std.mem.Allocator, messages: *std.ArrayList(u8), v: ?std.json.Value) error{OutOfMemory}!void {
    const x = v orelse return;
    switch (x) {
        .string => |c| try messages.appendSlice(allocator, c),
        .integer => |n| {
            var buf: [24]u8 = undefined;
            const t = std.fmt.bufPrint(&buf, "{d}", .{n}) catch return;
            try messages.appendSlice(allocator, t);
        },
        else => {},
    }
}

// ── 판정 ────────────────────────────────────────────────────────────────────────

const testing = std.testing;
const line_index = @import("../editor/line_index.zig");

test "LSP1 character → byte: utf-8 은 그대로, utf-16 은 한글 1 unit=3 byte·이모지 2 unit=4 byte, 줄 밖은 줄 끝 (§8.2a)" {
    const line = "a가😀b"; // a(1) 가(3) 😀(4) b(1)
    try testing.expectEqual(@as(u32, 1), byteInLine(line, 1, .utf16));
    try testing.expectEqual(@as(u32, 4), byteInLine(line, 2, .utf16)); // a + 가
    try testing.expectEqual(@as(u32, 8), byteInLine(line, 4, .utf16)); // + 😀(2 units)
    try testing.expectEqual(@as(u32, 9), byteInLine(line, 5, .utf16));
    try testing.expectEqual(@as(u32, 9), byteInLine(line, 50, .utf16)); // 줄 끝으로 묶는다
    try testing.expectEqual(@as(u32, 4), byteInLine(line, 4, .utf8));
    try testing.expectEqual(@as(u32, 9), byteInLine(line, 50, .utf8));
    // 역방향(§8.2b hover 위치) — 왕복이 맞고, 줄 밖은 줄 끝.
    try testing.expectEqual(@as(u32, 2), characterOf(line, 4, .utf16));
    try testing.expectEqual(@as(u32, 4), characterOf(line, 8, .utf16));
    try testing.expectEqual(@as(u32, 5), characterOf(line, 50, .utf16));
    try testing.expectEqual(@as(u32, 8), characterOf(line, 8, .utf8));
    try testing.expectEqual(@as(u32, 9), characterOf(line, 50, .utf8));
}

test "LSP3 저장소를 message + code 만큼 먼저 잡는다 — 코드가 커서 재할당이 나면 앞 항목의 슬라이스가 허공을 본다 (변이 A2)" {
    const a = testing.allocator;
    const content = "int x;\n";
    var idx = try line_index.build(a, content);
    defer idx.deinit();
    // 진단 50개: message 1 byte, code 100 byte — code 를 셈에 안 넣으면 첫 code 에서 저장소가 자란다.
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(a);
    try text.appendSlice(a, "{\"uri\":\"file:///a.c\",\"diagnostics\":[");
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        if (i > 0) try text.append(a, ',');
        try text.appendSlice(a, "{\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":1}},\"message\":\"m\",\"code\":\"");
        try text.appendNTimes(a, 'c', 100);
        try text.appendSlice(a, "\"}");
    }
    try text.appendSlice(a, "]}");
    var p = try std.json.parseFromSlice(std.json.Value, a, text.items, .{});
    defer p.deinit();
    var out: std.ArrayList(diagnostic.Diagnostic) = .empty;
    defer out.deinit(a);
    var msgs: std.ArrayList(u8) = .empty;
    defer msgs.deinit(a);
    try testing.expectEqual(@as(usize, 50), try appendDiagnostics(a, p.value, content, idx, .utf8, &out, &msgs));
    // **모든 슬라이스가 지금 저장소 안을 가리킨다** — 재할당이 있었으면 앞 항목이 옛 버퍼를 가리킨다(읽지 않고 주소로 잰다).
    const lo = @intFromPtr(msgs.items.ptr);
    const hi = lo + msgs.items.len;
    for (out.items) |d| {
        try testing.expect(@intFromPtr(d.message.ptr) >= lo and @intFromPtr(d.message.ptr) + d.message.len <= hi);
        try testing.expect(@intFromPtr(d.code.ptr) >= lo and @intFromPtr(d.code.ptr) + d.code.len <= hi);
        try testing.expectEqual(@as(usize, 100), d.code.len);
    }
}

test "LSP2 publishDiagnostics → 목록: 범위·severity·메시지 복사·폭 0 은 1 byte·줄 밖은 문서 끝 (§8.2a)" {
    const a = testing.allocator;
    const content = "int x;\nint 가 = 1;\n";
    var idx = try line_index.build(a, content);
    defer idx.deinit();
    const text =
        \\{"uri":"file:///a.c","version":7,"diagnostics":[
        \\ {"range":{"start":{"line":1,"character":4},"end":{"line":1,"character":5}},"severity":2,"message":"warn here","code":"W1"},
        \\ {"range":{"start":{"line":0,"character":4},"end":{"line":0,"character":4}},"message":"zero width","code":42},
        \\ {"range":{"start":{"line":9,"character":0},"end":{"line":9,"character":3}},"severity":4,"message":"beyond"},
        \\ "not an object",
        \\ {"nope":1}
        \\]}
    ;
    var p = try std.json.parseFromSlice(std.json.Value, a, text, .{});
    defer p.deinit();
    var out: std.ArrayList(diagnostic.Diagnostic) = .empty;
    defer out.deinit(a);
    var msgs: std.ArrayList(u8) = .empty;
    defer msgs.deinit(a);
    const n = try appendDiagnostics(a, p.value, content, idx, .utf16, &out, &msgs);
    try testing.expectEqual(@as(usize, 3), n);
    // 줄 1 의 character 4..5 는 "가"(utf-16 한 unit, byte 3) → byte 11..14
    try testing.expectEqual(@as(u32, 7 + 4), out.items[0].start);
    try testing.expectEqual(@as(u32, 7 + 7), out.items[0].end);
    try testing.expectEqual(diagnostic.Severity.warning, out.items[0].severity);
    try testing.expectEqual(diagnostic.Source.lsp, out.items[0].source);
    try testing.expectEqualStrings("warn here", out.items[0].message);
    // code — 문자열은 그대로, 정수는 글자로, 없으면 빈 문자열(§8.2a 「진단 합치기」 — 호버가 `출처(코드)` 로 낸다).
    try testing.expectEqualStrings("W1", out.items[0].code);
    try testing.expectEqualStrings("42", out.items[1].code);
    try testing.expectEqualStrings("", out.items[2].code);
    // 폭 0 → 1 byte, severity 없음 → error
    try testing.expectEqual(@as(u32, 4), out.items[1].start);
    try testing.expectEqual(@as(u32, 5), out.items[1].end);
    try testing.expectEqual(diagnostic.Severity.@"error", out.items[1].severity);
    // 문서 밖 줄 → 문서 끝(폭 0 → +1 로 묶되 content.len 을 넘긴 1 byte 만)
    try testing.expectEqual(@as(u32, @intCast(content.len)), out.items[2].start);
    try testing.expectEqual(diagnostic.Severity.hint, out.items[2].severity);
    try testing.expectEqualStrings("beyond", out.items[2].message);
    // 세 메시지가 한 저장소에 이어 있고 첫 슬라이스가 여전히 유효하다(저장소를 먼저 잡았다).
    try testing.expectEqualStrings("warn here", out.items[0].message);
    try testing.expectEqual(@as(usize, "warn here".len + "W1".len + "zero width".len + "42".len + "beyond".len), msgs.items.len); // 저장소 = message + code
    // 배열이 아니면 0.
    var q = try std.json.parseFromSlice(std.json.Value, a, "{\"diagnostics\":5}", .{});
    defer q.deinit();
    try testing.expectEqual(@as(usize, 0), try appendDiagnostics(a, q.value, content, idx, .utf16, &out, &msgs));
}
