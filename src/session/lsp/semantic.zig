//! semantic tokens 2층(docs/editor-surface-tooling.md §8.2i · native-editor-visual-mapping.md §5) — **순수** 계산 셋.
//!
//! ① `initialize` 응답의 `semanticTokensProvider` → 지원 여부·`range`/`full`·**legend 를 우리 `Role` 로 미리 옮긴 표**(서버는 우리가 선언한
//!   종류와 무관하게 제 legend 를 낸다 — rust-analyzer 는 표준 밖 종류를 잔뜩 낸다 → 이름으로 매핑하고 모르는 것은 무색).
//! ② 응답 `data`(relative 인코딩 5-tuple) → byte 스팬. 한 줄 토큰만(capability 가 그렇게 선언한다), 상한 `max_tokens`.
//! ③ 편집 통지로 스팬 밀기 — 겹치는 것은 버리고 뒤는 옮긴다(새 응답이 올 때까지 옛 색을 깜빡임 없이 유지).
//!
//! 매핑 표는 **코드가 소유한다**(visual-mapping §5.3 과 같은 규칙) — tree-sitter 의 `syntax_capture` 표와 나란히, 다대일, 색이 상한.
const std = @import("std");
const position = @import("position.zig");
const rpc = @import("rpc.zig");
const LineIndex = @import("../editor/line_index.zig").LineIndex;
pub const Role = @import("../syntax_capture.zig").Role;

/// 한 응답에서 받는 토큰 상한(§8.2i) — 넘치면 앞부분만.
pub const max_tokens: usize = 50_000;

pub const Span = struct { start: u32, end: u32, role: Role };

/// 서버의 semantic tokens capability — legend 는 `Role` 로 옮겨 든다(`null` = 무색).
pub const Caps = struct {
    supported: bool = false,
    range: bool = false,
    full: bool = false,
    /// legend 의 `tokenTypes[i]` → 우리 색. 소유(`deinit`).
    roles: []?Role = &.{},

    pub fn deinit(self: *Caps, allocator: std.mem.Allocator) void {
        if (self.roles.len > 0) allocator.free(self.roles);
        self.* = .{};
    }
};

/// LSP 종류 이름 → 우리 색(§8.2i 표). 모르는 것·의도적으로 무색인 것(`variable`·`parameter`·`namespace`…)은 `null`.
pub fn roleForType(name: []const u8) ?Role {
    const table = .{
        .{ "type", Role.type_name },        .{ "class", Role.type_name },            .{ "struct", Role.type_name },
        .{ "enum", Role.type_name },        .{ "interface", Role.type_name },        .{ "typeParameter", Role.type_name },
        .{ "builtinType", Role.type_name }, .{ "enumMember", Role.property },        .{ "function", Role.function },
        .{ "method", Role.function },       .{ "macro", Role.function },             .{ "keyword", Role.keyword },
        .{ "modifier", Role.keyword },      .{ "comment", Role.comment },            .{ "string", Role.string },
        .{ "character", Role.string },      .{ "regexp", Role.string },              .{ "escapeSequence", Role.string },
        .{ "number", Role.number },         .{ "boolean", Role.number },             .{ "property", Role.property },
        .{ "event", Role.property },        .{ "decorator", Role.attribute },        .{ "attribute", Role.attribute },
        .{ "derive", Role.attribute },      .{ "builtinAttribute", Role.attribute }, .{ "operator", Role.punctuation },
    };
    inline for (table) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return entry[1];
    }
    return null;
}

/// `initialize` 응답에서 capability 를 읽는다. provider 가 없으면 `supported = false`(roles 빈 채).
pub fn capsFromResult(allocator: std.mem.Allocator, result: ?std.json.Value) error{OutOfMemory}!Caps {
    var out: Caps = .{};
    const r = result orelse return out;
    if (r != .object) return out;
    const caps = r.object.get("capabilities") orelse return out;
    if (caps != .object) return out;
    const prov = caps.object.get("semanticTokensProvider") orelse return out;
    if (prov != .object) return out;
    const o = prov.object;
    if (o.get("range")) |v| out.range = switch (v) {
        .bool => |b| b,
        .object => true,
        else => false,
    };
    if (o.get("full")) |v| out.full = switch (v) {
        .bool => |b| b,
        .object => true,
        else => false,
    };
    const legend = o.get("legend") orelse return out;
    if (legend != .object) return out;
    const types = legend.object.get("tokenTypes") orelse return out;
    if (types != .array) return out;
    const roles = try allocator.alloc(?Role, types.array.items.len);
    for (types.array.items, 0..) |t, i| roles[i] = if (t == .string) roleForType(t.string) else null;
    out.roles = roles;
    out.supported = out.range or out.full;
    return out;
}

/// 응답 `result.data`(relative 5-tuple) → 문서 순서의 byte 스팬. 모르는 종류(`null` role)는 빼고, 문서 밖·빈 것도 뺀다. `max_tokens` 를 넘는 뒷부분은 버린다.
pub fn decode(allocator: std.mem.Allocator, result: ?std.json.Value, roles: []const ?Role, content: []const u8, lines: LineIndex, enc: rpc.PositionEncoding) error{OutOfMemory}![]Span {
    var out: std.ArrayList(Span) = .empty;
    errdefer out.deinit(allocator);
    const r = result orelse return out.toOwnedSlice(allocator);
    if (r != .object) return out.toOwnedSlice(allocator);
    const data = r.object.get("data") orelse return out.toOwnedSlice(allocator);
    if (data != .array) return out.toOwnedSlice(allocator);
    const items = data.array.items;
    var line: u32 = 0;
    var char: u32 = 0;
    var i: usize = 0;
    var count: usize = 0;
    while (i + 5 <= items.len and count < max_tokens) : (i += 5) {
        count += 1;
        const dl = intOf(items[i]) orelse break;
        const dc = intOf(items[i + 1]) orelse break;
        const len = intOf(items[i + 2]) orelse break;
        const ty = intOf(items[i + 3]) orelse break;
        if (dl > 0) {
            line +|= dl;
            char = dc;
        } else char +|= dc;
        if (ty >= roles.len) continue;
        const role = roles[ty] orelse continue;
        if (len == 0) continue;
        const start = position.offsetOf(content, lines, line, char, enc);
        const end = position.offsetOf(content, lines, line, char +| len, enc);
        if (end <= start or end > content.len) continue;
        try out.append(allocator, .{ .start = start, .end = end, .role = role });
    }
    return out.toOwnedSlice(allocator);
}

fn intOf(v: std.json.Value) ?u32 {
    return switch (v) {
        .integer => |n| if (n >= 0 and n <= std.math.maxInt(u32)) @intCast(n) else null,
        else => null,
    };
}

/// 편집 통지로 스팬을 민다(§8.2i 「편집 중」): `[start, old_end)` 와 겹치는(끝점 포함해 **닿는** 것은 살린다 — 삽입점이 토큰 안이면 버린다) 토큰은
/// 버리고, 그 뒤 토큰은 `new_end - old_end` 만큼 옮긴다. 제자리에서 줄인다.
pub fn shift(spans: *std.ArrayList(Span), start: u32, old_end: u32, new_end: u32) void {
    var w: usize = 0;
    const delta: i64 = @as(i64, new_end) - @as(i64, old_end);
    for (spans.items) |sp| {
        if (sp.end <= start) {
            // 편집 앞 — 그대로(토큰 끝에 딱 붙은 삽입도 포함 — `add|` 에 글자를 더하면 서버가 새로 준다).
            spans.items[w] = sp;
            w += 1;
        } else if (sp.start >= old_end) {
            // 편집 뒤 — 옮긴다(토큰 시작에 딱 붙은 삽입도 포함).
            const ns: i64 = @as(i64, sp.start) + delta;
            const ne: i64 = @as(i64, sp.end) + delta;
            if (ns < 0 or ne <= ns) continue;
            spans.items[w] = .{ .start = @intCast(ns), .end = @intCast(ne), .role = sp.role };
            w += 1;
        }
        // 그 밖은 겹친다(삽입점이 토큰 안인 것 포함) — 버린다.
    }
    spans.shrinkRetainingCapacity(w);
}

// ── 판정 ────────────────────────────────────────────────────────────────────────

const testing = std.testing;
const line_index = @import("../editor/line_index.zig");

fn parseJson(a: std.mem.Allocator, text: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, a, text, .{});
}

test "SEM1 capability·legend 매핑·relative 풀기 — 모르는 종류는 무색, utf-16 인코딩, 문서 밖은 뺌, 상한 (§8.2i)" {
    const a = testing.allocator;
    var p = try parseJson(a, "{\"capabilities\":{\"semanticTokensProvider\":{\"legend\":{\"tokenTypes\":[\"keyword\",\"function\",\"variable\",\"builtinType\",\"angle\",\"string\"],\"tokenModifiers\":[\"declaration\"]},\"range\":true,\"full\":{\"delta\":true}}}}");
    defer p.deinit();
    var caps = try capsFromResult(a, p.value);
    defer caps.deinit(a);
    try testing.expect(caps.supported and caps.range and caps.full);
    try testing.expectEqual(@as(usize, 6), caps.roles.len);
    try testing.expectEqual(Role.keyword, caps.roles[0].?);
    try testing.expectEqual(Role.function, caps.roles[1].?);
    try testing.expect(caps.roles[2] == null); // variable — 의도된 무색
    try testing.expectEqual(Role.type_name, caps.roles[3].?); // rust-analyzer 의 표준 밖 종류
    try testing.expect(caps.roles[4] == null); // angle — 모르는 것
    // provider 없음.
    var np = try parseJson(a, "{\"capabilities\":{}}");
    defer np.deinit();
    var ncaps = try capsFromResult(a, np.value);
    defer ncaps.deinit(a);
    try testing.expect(!ncaps.supported and ncaps.roles.len == 0);
    // clangd 꼴 — full 만.
    var cp = try parseJson(a, "{\"capabilities\":{\"semanticTokensProvider\":{\"legend\":{\"tokenTypes\":[\"variable\"],\"tokenModifiers\":[]},\"full\":{\"delta\":true}}}}");
    defer cp.deinit();
    var ccaps = try capsFromResult(a, cp.value);
    defer ccaps.deinit(a);
    try testing.expect(ccaps.supported and !ccaps.range and ccaps.full);
    // relative 풀기 — `fn add(a) {}\nlet 가 = s;` : fn(kw) add(fn) a(var→무색) / 가(var) s(string 1 글자).
    const content = "fn add(a) {}\nlet 가 = s;\n";
    var idx = try line_index.build(a, content);
    defer idx.deinit();
    // 5-tuple: (dLine, dChar, len, type, mods). 둘째 줄의 `가` 는 utf-16 으로 1 글자·byte 3.
    var d = try parseJson(a, "{\"data\":[0,0,2,0,0, 0,3,3,1,1, 0,4,1,2,0, 1,4,1,2,0, 0,4,1,5,0, 0,0,0,5,0, 0,90,1,5,0, 0,1,1,9,0]}");
    defer d.deinit();
    const spans = try decode(a, d.value, caps.roles, content, idx, .utf16);
    defer a.free(spans);
    try testing.expectEqual(@as(usize, 3), spans.len); // fn · add · s (a·가 는 무색, 길이 0·문서 밖·모르는 첨자는 뺌)
    try testing.expectEqualStrings("fn", content[spans[0].start..spans[0].end]);
    try testing.expectEqual(Role.keyword, spans[0].role);
    try testing.expectEqualStrings("add", content[spans[1].start..spans[1].end]);
    try testing.expectEqual(Role.function, spans[1].role);
    try testing.expectEqualStrings("s", content[spans[2].start..spans[2].end]); // `가 = s` — utf-16 4번째 글자
    try testing.expectEqual(Role.string, spans[2].role);
    // null·모양 틀림 → 빈 목록.
    const none = try decode(a, null, caps.roles, content, idx, .utf8);
    defer a.free(none);
    try testing.expectEqual(@as(usize, 0), none.len);
    // 상한 — 50,001 개를 주면 50,000 개.
    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(a);
    try big.appendSlice(a, "{\"data\":[");
    var k: usize = 0;
    while (k < max_tokens + 1) : (k += 1) {
        if (k > 0) try big.appendSlice(a, ",");
        try big.appendSlice(a, "0,0,1,0,0");
    }
    try big.appendSlice(a, "]}");
    var bp = try parseJson(a, big.items);
    defer bp.deinit();
    const many = try decode(a, bp.value, caps.roles, content, idx, .utf8);
    defer a.free(many);
    try testing.expectEqual(max_tokens, many.len);
}

test "SEM2 편집 밀기 — 앞은 그대로, 겹침·삽입점이 안이면 버림, 뒤는 옮김; 지우기·바꾸기 (§8.2i)" {
    const a = testing.allocator;
    var spans: std.ArrayList(Span) = .empty;
    defer spans.deinit(a);
    // [0,2) [3,6) [7,8) [10,14)
    try spans.appendSlice(a, &.{ .{ .start = 0, .end = 2, .role = .keyword }, .{ .start = 3, .end = 6, .role = .function }, .{ .start = 7, .end = 8, .role = .string }, .{ .start = 10, .end = 14, .role = .type_name } });
    // 삽입 2 글자 at 6 (토큰 끝에 딱 — `add|`): [3,6) 은 그대로, 뒤는 +2.
    shift(&spans, 6, 6, 8);
    try testing.expectEqual(@as(usize, 4), spans.items.len);
    try testing.expectEqual(@as(u32, 6), spans.items[1].end);
    try testing.expectEqual(@as(u32, 9), spans.items[2].start);
    try testing.expectEqual(@as(u32, 12), spans.items[3].start);
    // 삽입 at 11 (토큰 [12,16) 앞이 아니라 안? 11 은 [9,10)·[12,16) 사이 — 아무것도 안 버리고 [12,16) 만 +1).
    shift(&spans, 11, 11, 12);
    try testing.expectEqual(@as(usize, 4), spans.items.len);
    try testing.expectEqual(@as(u32, 13), spans.items[3].start);
    // 삽입점이 토큰 안(14, [13,17) 안) → 그 토큰은 버린다.
    shift(&spans, 14, 14, 15);
    try testing.expectEqual(@as(usize, 3), spans.items.len);
    // 지우기 [1,4): [0,2)·[3,6) 겹침 → 버림, [9,10) → -3.
    shift(&spans, 1, 4, 1);
    try testing.expectEqual(@as(usize, 1), spans.items.len);
    try testing.expectEqual(@as(u32, 6), spans.items[0].start);
    try testing.expectEqual(@as(u32, 7), spans.items[0].end);
    // 바꾸기 [0,6) → 3 글자: [6,7) 은 old_end 에 딱 붙어 옮긴다 → [3,4).
    shift(&spans, 0, 6, 3);
    try testing.expectEqual(@as(u32, 3), spans.items[0].start);
}
