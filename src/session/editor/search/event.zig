//! rg JSON은 외부 프로세스의 입력이다. 소유한 byte 범위로 검증해 수명·UTF-8 좌표를 고정한다.
const std = @import("std");
pub const Position = struct { line: u32, byte: u32 };
pub const Range = struct { start: Position, end: Position };
pub const Match = struct {
    path: []u8,
    text: []u8,
    ranges: []Range,
    text_start: Position = .{ .line = 0, .byte = 0 },
    text_truncated: bool = false,
    pub fn deinit(self: *Match, a: std.mem.Allocator) void {
        a.free(self.path);
        a.free(self.text);
        a.free(self.ranges);
    }
};
pub const Event = union(enum) { match: Match, summary: usize, other };
fn field(value: std.json.Value, name: []const u8) !std.json.Value {
    if (value != .object) return error.MalformedEvent;
    return value.object.get(name) orelse error.MalformedEvent;
}
fn integer(value: std.json.Value) !usize {
    if (value != .integer or value.integer < 0) return error.MalformedEvent;
    return std.math.cast(usize, value.integer) orelse error.MalformedEvent;
}
fn bytes(a: std.mem.Allocator, value: std.json.Value) ![]u8 {
    if (value != .object) return error.MalformedEvent;
    const text = value.object.get("text");
    const encoded = value.object.get("bytes");
    if ((text != null) == (encoded != null)) return error.MalformedEvent;
    if (text) |v| {
        if (v != .string) return error.MalformedEvent;
        return a.dupe(u8, v.string);
    }
    const v = encoded.?;
    if (v != .string) return error.MalformedEvent;
    const decoder = std.base64.standard.Decoder;
    const size = decoder.calcSizeForSlice(v.string) catch return error.MalformedEvent;
    const out = try a.alloc(u8, size);
    errdefer a.free(out);
    decoder.decode(out, v.string) catch return error.MalformedEvent;
    return out;
}
fn boundary(text: []const u8, offset: usize) bool {
    return offset <= text.len and (offset == text.len or text[offset] & 0xc0 != 0x80);
}
fn position(text: []const u8, offset: usize, base: usize) !Position {
    var line = base;
    var start: usize = 0;
    for (text[0..offset], 0..) |byte, i| if (byte == '\n') {
        line += 1;
        start = i + 1;
    };
    return .{ .line = std.math.cast(u32, line) orelse return error.MalformedEvent, .byte = std.math.cast(u32, offset - start) orelse return error.MalformedEvent };
}
/// JSON 수명 밖으로 반환하므로 경로·본문·범위 모두 소유한다. 숨겨진 상위 경로는 받지 않는다.
pub fn parse(a: std.mem.Allocator, json: []const u8) !Event {
    const parsed = try std.json.parseFromSlice(std.json.Value, a, json, .{});
    defer parsed.deinit();
    const kind = try field(parsed.value, "type");
    if (kind != .string) return error.MalformedEvent;
    if (std.mem.eql(u8, kind.string, "summary")) {
        const data = try field(parsed.value, "data");
        return .{ .summary = try integer(try field(try field(data, "stats"), "matches")) };
    }
    if (!std.mem.eql(u8, kind.string, "match")) {
        for ([_][]const u8{ "begin", "end", "context" }) |known| {
            if (std.mem.eql(u8, kind.string, known)) return .other;
        }
        return error.UnknownEvent;
    }
    const data = try field(parsed.value, "data");
    const path = try bytes(a, try field(data, "path"));
    errdefer a.free(path);
    if (path.len == 0 or path[0] == '/' or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| if (std.mem.eql(u8, component, "..")) return error.InvalidPath;
    const text = try bytes(a, try field(data, "lines"));
    errdefer a.free(text);
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    const number = try integer(try field(data, "line_number"));
    if (number == 0) return error.MalformedEvent;
    const submatches = try field(data, "submatches");
    if (submatches != .array) return error.MalformedEvent;
    const ranges = try a.alloc(Range, submatches.array.items.len);
    errdefer a.free(ranges);
    for (submatches.array.items, ranges) |submatch, *range| {
        const lo = try integer(try field(submatch, "start"));
        const hi = try integer(try field(submatch, "end"));
        if (lo > hi or !boundary(text, lo) or !boundary(text, hi)) return error.MalformedEvent;
        const reported = try bytes(a, try field(submatch, "match"));
        defer a.free(reported);
        if (!std.mem.eql(u8, text[lo..hi], reported)) return error.MalformedEvent;
        range.* = .{ .start = try position(text, lo, number - 1), .end = try position(text, hi, number - 1) };
    }
    return .{ .match = .{ .path = path, .text = text, .ranges = ranges, .text_start = try position(text, 0, number - 1) } };
}

const sample =
    \\{"type":"match","data":{"path":{"text":"./a.zig"},"lines":{"text":"\uac00\r\nfoo\n"},"line_number":2,"submatches":[{"start":0,"end":8,"match":{"text":"\uac00\r\nfoo"}}]}}
;

test "PSE1 JSON ranges own multiline UTF8 and CRLF bytes" {
    const a = std.testing.allocator;
    var event = try parse(a, sample);
    defer event.match.deinit(a);
    try std.testing.expectEqual(Position{ .line = 1, .byte = 0 }, event.match.ranges[0].start);
    try std.testing.expectEqual(Position{ .line = 1, .byte = 0 }, event.match.text_start);
    try std.testing.expectEqual(Position{ .line = 2, .byte = 3 }, event.match.ranges[0].end);
    try std.testing.expectError(error.MalformedEvent, parse(a, "{\"type\":\"match\"}"));
    const encoded = "{\"type\":\"match\",\"data\":{\"path\":{\"bytes\":\"eC50eHQ=\"},\"lines\":{\"bytes\":\"6rCAZm9vCg==\"},\"line_number\":1,\"submatches\":[{\"start\":3,\"end\":6,\"match\":{\"bytes\":\"Zm9v\"}}]}}";
    var decoded = try parse(a, encoded);
    defer decoded.match.deinit(a);
    try std.testing.expectEqualStrings("x.txt", decoded.match.path);
    try std.testing.expectEqualStrings("가foo\n", decoded.match.text);
    try std.testing.expectEqual(Position{ .line = 0, .byte = 3 }, decoded.match.ranges[0].start);

    try std.testing.checkAllAllocationFailures(a, struct {
        fn run(alloc: std.mem.Allocator) !void {
            var value = try parse(alloc, sample);
            defer value.match.deinit(alloc);
        }
    }.run, .{});
}

test "PSE2 external byte spans cannot split UTF8 or traverse roots" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.UnknownEvent, parse(a, "{\"type\":\"unexpected\"}"));
    try std.testing.expectError(error.MalformedEvent, parse(a, "{\"type\":\"summary\"}"));
    const summary = try parse(a, "{\"type\":\"summary\",\"data\":{\"stats\":{\"matches\":0}}}");
    try std.testing.expectEqual(@as(usize, 0), summary.summary);
    // 좌표 overflow·역순·범위 초과·절대 경로는 외부 입력 오류다.
    const mutations = [_]struct { before: []const u8, after: []const u8 }{
        .{ .before = "\"line_number\":2", .after = "\"line_number\":4294967297" },
        .{ .before = "\"line_number\":2", .after = "\"line_number\":0" },
        .{ .before = "\"start\":0", .after = "\"start\":9" },
        .{ .before = "\"end\":8", .after = "\"end\":999" },
        .{ .before = "./a.zig", .after = "/a.zig" },
    };
    for (mutations) |mutation| {
        const invalid = try std.mem.replaceOwned(u8, a, sample, mutation.before, mutation.after);
        defer a.free(invalid);
        if (parse(a, invalid)) |value| {
            var unexpected = value;
            unexpected.match.deinit(a);
            return error.AcceptedInvalidEvent;
        } else |_| {}
    }
    const broken = try std.mem.replaceOwned(u8, a, sample, "\"start\":0", "\"start\":1");
    defer a.free(broken);
    try std.testing.expectError(error.MalformedEvent, parse(a, broken));
    const traversal = try std.mem.replaceOwned(u8, a, sample, "./a.zig", "../a.zig");
    defer a.free(traversal);
    try std.testing.expectError(error.InvalidPath, parse(a, traversal));
}
