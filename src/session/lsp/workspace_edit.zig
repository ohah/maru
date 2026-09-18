//! LSP `WorkspaceEdit` → 파일별 `TextEdit[]`(docs/editor-surface-tooling.md §8.2f). `changes`(uri → TextEdit[]) 와 `documentChanges`
//! (`TextDocumentEdit[]` — `textDocument.uri`·`version`·`edits`) 를 **한 목록**으로 편다. 같은 uri 가 여러 번 오면 이어 붙인다(항목 순서
//! 그대로 — 정렬·겹침은 `text_edits.toChanges` 가 뒤에 판정한다). `CreateFile`/`RenameFile`/`DeleteFile`(`kind` 가 있는 항목)은 하나라도
//! 있으면 **전부 거부**(`Unsupported`) — 반만 적용된 rename 은 컴파일되지 않는 코드다. `file:` 이 아닌 uri 도 같다. 순수 계산.

const std = @import("std");
const rpc = @import("rpc.zig");

pub const FileEdits = struct {
    /// 응답 트리 안의 uri 조각(트리가 사는 동안 유효).
    uri: []const u8,
    /// `documentChanges` 의 `version`(있을 때만). `changes` 맵에는 없다.
    version: ?i64 = null,
    /// 그 파일의 `TextEdit` 항목들 — 응답 트리의 값을 빌린다.
    edits: []std.json.Value,
};

pub const Parsed = struct {
    files: []FileEdits = &.{},
    /// `edits` 배열이 이어 붙여진 파일의 저장소(같은 uri 가 여러 번 온 경우).
    merged: [][]std.json.Value = &.{},

    pub fn deinit(self: *Parsed, allocator: std.mem.Allocator) void {
        for (self.merged) |m| allocator.free(m);
        if (self.merged.len > 0) allocator.free(self.merged);
        if (self.files.len > 0) allocator.free(self.files);
        self.* = .{};
    }

    pub fn editCount(self: Parsed) usize {
        var n: usize = 0;
        for (self.files) |f| n += f.edits.len;
        return n;
    }
};

pub const Error = error{ Unsupported, Malformed, OutOfMemory };

/// `result` 는 응답의 `result`. `null` 이나 객체 아님이면 빈 결과(바꿀 것 없음). `changes`·`documentChanges` 둘 다 있으면 둘 다 편다
/// (명세는 하나만 쓰라 하지만 둘 다 읽어도 해가 없다 — 같은 uri 는 이어 붙는다).
pub fn parse(allocator: std.mem.Allocator, result: ?std.json.Value) Error!Parsed {
    const v = result orelse return .{};
    if (v != .object) return .{};
    var files: std.ArrayList(FileEdits) = .empty;
    errdefer files.deinit(allocator);
    var merged: std.ArrayList([]std.json.Value) = .empty;
    errdefer {
        for (merged.items) |m| allocator.free(m);
        merged.deinit(allocator);
    }
    if (v.object.get("documentChanges")) |dc| {
        if (dc != .array) return error.Malformed;
        for (dc.array.items) |it| {
            if (it != .object) return error.Malformed;
            if (it.object.get("kind") != null) return error.Unsupported; // CreateFile·RenameFile·DeleteFile
            const td = it.object.get("textDocument") orelse return error.Malformed;
            if (td != .object) return error.Malformed;
            const uri_v = td.object.get("uri") orelse return error.Malformed;
            if (uri_v != .string) return error.Malformed;
            const version: ?i64 = if (td.object.get("version")) |ver| (switch (ver) {
                .integer => |n| n,
                else => null,
            }) else null;
            const edits_v = it.object.get("edits") orelse return error.Malformed;
            if (edits_v != .array) return error.Malformed;
            try add(allocator, &files, &merged, uri_v.string, version, edits_v.array.items);
        }
    }
    if (v.object.get("changes")) |ch| {
        if (ch != .object) return error.Malformed;
        var it = ch.object.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.* != .array) return error.Malformed;
            try add(allocator, &files, &merged, kv.key_ptr.*, null, kv.value_ptr.array.items);
        }
    }
    return .{ .files = try files.toOwnedSlice(allocator), .merged = try merged.toOwnedSlice(allocator) };
}

fn add(allocator: std.mem.Allocator, files: *std.ArrayList(FileEdits), merged: *std.ArrayList([]std.json.Value), uri: []const u8, version: ?i64, edits: []std.json.Value) Error!void {
    if (!std.mem.startsWith(u8, uri, "file:")) return error.Unsupported;
    for (files.items) |*f| {
        if (!std.mem.eql(u8, f.uri, uri)) continue;
        // 같은 uri — 이어 붙인다(둘 다 빌린 조각이라 새 배열을 만든다).
        const joined = try allocator.alloc(std.json.Value, f.edits.len + edits.len);
        @memcpy(joined[0..f.edits.len], f.edits);
        @memcpy(joined[f.edits.len..], edits);
        try merged.append(allocator, joined);
        f.edits = joined;
        if (f.version == null) f.version = version;
        return;
    }
    try files.append(allocator, .{ .uri = uri, .version = version, .edits = edits });
}

// ── 판정 ────────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn parseJson(a: std.mem.Allocator, text: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, a, text, .{});
}

test "WSE1 changes 맵 → 파일별 edits; null·객체 아님은 빈 결과; edits 는 트리를 빌린다 (§8.2f)" {
    const a = testing.allocator;
    var p = try parseJson(a,
        \\{"changes":{"file:///a.c":[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":3}},"newText":"x"}],
        \\            "file:///b.c":[{"range":{"start":{"line":1,"character":0},"end":{"line":1,"character":3}},"newText":"y"},
        \\                           {"range":{"start":{"line":2,"character":0},"end":{"line":2,"character":3}},"newText":"z"}]}}
    );
    defer p.deinit();
    var r = try parse(a, p.value);
    defer r.deinit(a);
    try testing.expectEqual(@as(usize, 2), r.files.len);
    try testing.expectEqual(@as(usize, 3), r.editCount());
    var seen_a = false;
    var seen_b = false;
    for (r.files) |f| {
        try testing.expect(f.version == null);
        if (std.mem.eql(u8, f.uri, "file:///a.c")) {
            seen_a = true;
            try testing.expectEqual(@as(usize, 1), f.edits.len);
        } else if (std.mem.eql(u8, f.uri, "file:///b.c")) {
            seen_b = true;
            try testing.expectEqual(@as(usize, 2), f.edits.len);
            try testing.expectEqualStrings("z", f.edits[1].object.get("newText").?.string);
        }
    }
    try testing.expect(seen_a and seen_b);
    var n = try parse(a, null);
    defer n.deinit(a);
    try testing.expectEqual(@as(usize, 0), n.files.len);
    var arr = try parseJson(a, "[1]");
    defer arr.deinit();
    var e = try parse(a, arr.value);
    defer e.deinit(a);
    try testing.expectEqual(@as(usize, 0), e.files.len);
}

test "WSE2 documentChanges — version 을 든다, 같은 uri 는 이어 붙는다, 파일 연산·file: 아님은 Unsupported, 모양 틀림은 Malformed (§8.2f)" {
    const a = testing.allocator;
    var p = try parseJson(a,
        \\{"documentChanges":[
        \\  {"textDocument":{"uri":"file:///a.c","version":7},"edits":[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}},"newText":"p"}]},
        \\  {"textDocument":{"uri":"file:///a.c","version":7},"edits":[{"range":{"start":{"line":3,"character":0},"end":{"line":3,"character":1}},"newText":"q"}]},
        \\  {"textDocument":{"uri":"file:///b.c","version":null},"edits":[]}
        \\]}
    );
    defer p.deinit();
    var r = try parse(a, p.value);
    defer r.deinit(a);
    try testing.expectEqual(@as(usize, 2), r.files.len);
    try testing.expectEqualStrings("file:///a.c", r.files[0].uri);
    try testing.expectEqual(@as(i64, 7), r.files[0].version.?);
    try testing.expectEqual(@as(usize, 2), r.files[0].edits.len); // 이어 붙었다 — 순서 그대로
    try testing.expectEqualStrings("p", r.files[0].edits[0].object.get("newText").?.string);
    try testing.expectEqualStrings("q", r.files[0].edits[1].object.get("newText").?.string);
    try testing.expect(r.files[1].version == null);
    try testing.expectEqual(@as(usize, 0), r.files[1].edits.len);
    // 파일 연산 하나가 섞이면 전부 거부.
    var create = try parseJson(a, "{\"documentChanges\":[{\"textDocument\":{\"uri\":\"file:///a.c\"},\"edits\":[]},{\"kind\":\"create\",\"uri\":\"file:///n.c\"}]}");
    defer create.deinit();
    try testing.expectError(error.Unsupported, parse(a, create.value));
    var rename_op = try parseJson(a, "{\"documentChanges\":[{\"kind\":\"rename\",\"oldUri\":\"file:///a.c\",\"newUri\":\"file:///b.c\"}]}");
    defer rename_op.deinit();
    try testing.expectError(error.Unsupported, parse(a, rename_op.value));
    var untitled = try parseJson(a, "{\"changes\":{\"untitled:Untitled-1\":[]}}");
    defer untitled.deinit();
    try testing.expectError(error.Unsupported, parse(a, untitled.value));
    var bad = try parseJson(a, "{\"documentChanges\":[{\"textDocument\":{\"uri\":\"file:///a.c\"}}]}");
    defer bad.deinit();
    try testing.expectError(error.Malformed, parse(a, bad.value));
    var bad2 = try parseJson(a, "{\"changes\":{\"file:///a.c\":{}}}");
    defer bad2.deinit();
    try testing.expectError(error.Malformed, parse(a, bad2.value));
    // 둘 다 있으면 둘 다 편다 — 같은 uri 는 하나로.
    var both = try parseJson(a, "{\"changes\":{\"file:///a.c\":[{\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":1}},\"newText\":\"c\"}]},\"documentChanges\":[{\"textDocument\":{\"uri\":\"file:///a.c\",\"version\":2},\"edits\":[{\"range\":{\"start\":{\"line\":1,\"character\":0},\"end\":{\"line\":1,\"character\":1}},\"newText\":\"d\"}]}]}");
    defer both.deinit();
    var b = try parse(a, both.value);
    defer b.deinit(a);
    try testing.expectEqual(@as(usize, 1), b.files.len);
    try testing.expectEqual(@as(usize, 2), b.files[0].edits.len);
    try testing.expectEqual(@as(i64, 2), b.files[0].version.?);
}
