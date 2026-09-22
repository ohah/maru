//! 심볼 2층(docs/editor-surface-tooling.md §8.2o · native-editor-ui.md §7.5) — **순수** 계산 둘.
//!
//! ① `initialize` 응답의 `documentSymbolProvider`(bool·객체) → 지원 여부.
//! ② `DocumentSymbol[]`(계층) → **문서 순서로 평탄화한** 목록. 1층(tree-sitter `Provider.Symbol`)과 **같은 모양**이라 소비자 셋(밴드 체인·피커·
//!   형제 목록)이 분기하지 않는다.
//!
//! **서버의 nesting 을 그대로 믿지 않는다.** tsgo 는 생성자 **안**의 파라미터를 형제로 내고(실측 2026-09-22), typescript-language-server 는
//! 문서 순서를 안 지킨다(`c`·`Circle`·`s`·`Shape`). 그래서 여기서 ⑴ `(start asc, end desc)` 로 정렬하고 ⑵ **포함 관계로 depth 를 다시 센다** —
//! 1층이 스택으로 세는 것과 같은 규칙이다. 그래야 `chainAt`(앞으로만 훑는다)과 `parentOf`(depth 비교)가 두 층에서 같은 뜻이다.
//!
//! **이름은 문서에서 읽고, 서버 이름과 대조한다.** `selectionRange` 가 이름 범위이고(세 서버 모두 그렇다) 그 자리 글자가 서버의 `name` 과
//! 다르면 **그 항목을 버린다** — 밴드는 「지금 어디 있나」를 말하는 자리라 조용히 틀리면 거짓말이 된다(§7.5).
const std = @import("std");
const position = @import("position.zig");
const rpc = @import("rpc.zig");
const line_index = @import("../editor/line_index.zig");
const LineIndex = line_index.LineIndex;

/// 한 응답에서 받는 심볼 상한(§8.2o).
pub const max_symbols: usize = 2_000;
/// 중첩 깊이 상한 — 넘는 항목은 버린다(1층의 `stack[64]` 와 같은 자리).
pub const max_depth: u16 = 32;
/// 이름 byte 상한 — 넘는 항목은 버린다(목록 한 행에 담을 수 없다).
pub const max_name: usize = 256;

/// 평탄화한 심볼 하나. **필드 뜻은 1층 `syntax.Provider.Symbol` 과 같다**(소비자가 두 층을 구분하지 않는다).
pub const Symbol = struct {
    name_start: u32,
    name_end: u32,
    start: u32,
    end: u32,
    start_row: u32,
    depth: u16,
    /// 우리 어휘(`kindName`) — 서버의 `SymbolKind` 정수를 접은 것. **정적 문자열이라 소유하지 않는다**(1층도 grammar 의 정적 이름을 준다).
    kind: []const u8,
};

pub const Symbols = struct {
    items: std.ArrayList(Symbol) = .empty,
    /// 평탄 꼴(`SymbolInformation[]`)을 받아 **버린** 횟수(§8.2o 「하지 않는 것」) — 실제로 오는 서버가 있으면 이 값으로 보인다.
    flat_dropped: u64 = 0,
    /// 자기 검산(이름 대조)에서 버린 항목 수.
    name_mismatch: u64 = 0,

    pub fn deinit(self: *Symbols, allocator: std.mem.Allocator) void {
        self.items.deinit(allocator);
        self.* = .{};
    }
    pub fn clear(self: *Symbols) void {
        self.items.clearRetainingCapacity();
    }
};

/// `initialize` 응답에 `documentSymbolProvider` 가 참(bool) 이거나 객체면 지원.
pub fn supportedFromResult(result: ?std.json.Value) bool {
    const r = result orelse return false;
    if (r != .object) return false;
    const caps = r.object.get("capabilities") orelse return false;
    if (caps != .object) return false;
    const prov = caps.object.get("documentSymbolProvider") orelse return false;
    return switch (prov) {
        .bool => |b| b,
        .object => true,
        else => false,
    };
}

/// `SymbolKind`(LSP 3.17 표 1~26) → 우리 어휘. **표는 여기 하나뿐이다** — 소비자가 정수를 보지 않는다.
pub fn kindName(kind: i64) []const u8 {
    return switch (kind) {
        1 => "file",
        2 => "module",
        3 => "namespace",
        4 => "package",
        5 => "class",
        6 => "method",
        7 => "property",
        8 => "field",
        9 => "constructor",
        10 => "enum",
        11 => "interface",
        12 => "function",
        13 => "variable",
        14 => "constant",
        15 => "string",
        16 => "number",
        17 => "boolean",
        18 => "array",
        19 => "object",
        20 => "key",
        21 => "null",
        22 => "enum_member",
        23 => "struct",
        24 => "event",
        25 => "operator",
        26 => "type_parameter",
        else => "symbol", // 표 밖(서버가 새 종류를 내면) — 목록에는 서되 분류만 없다
    };
}

/// 응답 → 문서 순서의 평탄 목록. 실패하거나 평탄 꼴이면 `out` 은 빈 채로 둔다(호출자는 그때 1층을 쓴다).
pub fn decode(
    allocator: std.mem.Allocator,
    result: ?std.json.Value,
    content: []const u8,
    lines: LineIndex,
    enc: rpc.PositionEncoding,
    out: *Symbols,
) error{OutOfMemory}!void {
    out.clear();
    const r = result orelse return;
    if (r != .array) return;
    if (r.array.items.len > 0 and isFlat(r.array.items[0])) {
        out.flat_dropped += 1;
        return; // §8.2o — 평탄 꼴은 이름 범위가 없다. 1층을 그대로 둔다.
    }
    try walk(allocator, r.array.items, 0, content, lines, enc, out);
    // **정렬은 두 축이다**: 시작이 앞선 것이 먼저, 같은 자리면 **넓은 것(바깥)이 먼저** — `chainAt` 이 바깥부터 쌓는다.
    std.mem.sort(Symbol, out.items.items, {}, lessThan);
    redepth(out.items.items);
}

fn lessThan(_: void, a: Symbol, b: Symbol) bool {
    if (a.start != b.start) return a.start < b.start;
    return a.end > b.end;
}

/// **포함 관계로 depth 를 다시 센다**(서버 nesting 은 순서 힌트로만 쓴다). 정렬된 목록을 한 번 훑으며 열린 심볼을 스택에 쌓는다.
fn redepth(items: []Symbol) void {
    var stack: [max_depth]u32 = undefined;
    var n: usize = 0;
    for (items) |*sym| {
        while (n > 0 and sym.start >= stack[n - 1]) n -= 1; // 닫힌 것부터 뺀다
        sym.depth = @intCast(n);
        if (n < stack.len) {
            stack[n] = sym.end;
            n += 1;
        }
    }
}

/// 첫 항목이 `location` 을 들면 평탄 꼴(`SymbolInformation`)이다 — 계층 꼴에는 그 필드가 없다.
fn isFlat(v: std.json.Value) bool {
    return v == .object and v.object.get("location") != null;
}

fn walk(
    allocator: std.mem.Allocator,
    items: []const std.json.Value,
    depth: u16,
    content: []const u8,
    lines: LineIndex,
    enc: rpc.PositionEncoding,
    out: *Symbols,
) error{OutOfMemory}!void {
    if (depth >= max_depth) return;
    for (items) |it| {
        if (out.items.items.len >= max_symbols) return;
        if (it != .object) continue;
        const o = it.object;
        const name = switch (o.get("name") orelse continue) {
            .string => |sv| sv,
            else => continue,
        };
        if (name.len == 0 or name.len > max_name) continue;
        const kind = switch (o.get("kind") orelse std.json.Value{ .integer = 0 }) {
            .integer => |i| i,
            else => 0,
        };
        const full = rangeOf(o.get("range"), content, lines, enc) orelse continue;
        const sel = rangeOf(o.get("selectionRange"), content, lines, enc) orelse full;
        // **자기 검산**: 이름 범위의 문서 글자가 서버 이름과 같아야 든다(§8.2o). 같지 않으면 **그 심볼 범위 안에서 이름을 찾아** 쓰고,
        // 거기에도 없으면 버린다 — tsgo 는 생성자의 `selectionRange` 를 **빈 범위**로 낸다(실측 2026-09-22: `2:4-2:4`).
        const named: ?ByteRange = blk: {
            if (sel.lo < sel.hi and sel.hi <= content.len and std.mem.eql(u8, content[sel.lo..sel.hi], name)) break :blk sel;
            if (full.hi <= content.len and full.lo <= full.hi) {
                if (std.mem.indexOf(u8, content[full.lo..full.hi], name)) |at| break :blk .{ .lo = full.lo + at, .hi = full.lo + at + name.len };
            }
            break :blk null;
        };
        if (named == null) {
            out.name_mismatch += 1;
        } else if (blk: {
            const nm = named.?;
            break :blk full.lo <= nm.lo and nm.hi <= full.hi;
        }) {
            try out.items.append(allocator, .{
                .name_start = @intCast(named.?.lo),
                .name_end = @intCast(named.?.hi),
                .start = @intCast(full.lo),
                .end = @intCast(full.hi),
                .start_row = rowOf(o.get("range")) orelse 0,
                .depth = depth, // 아래 `redepth` 가 포함 관계로 다시 센다
                .kind = kindName(kind),
            });
        }
        if (o.get("children")) |ch| if (ch == .array) try walk(allocator, ch.array.items, depth + 1, content, lines, enc, out);
    }
}

const ByteRange = struct { lo: usize, hi: usize };

fn rangeOf(v: ?std.json.Value, content: []const u8, lines: LineIndex, enc: rpc.PositionEncoding) ?ByteRange {
    const r = v orelse return null;
    if (r != .object) return null;
    const lo = posOf(r.object.get("start"), content, lines, enc) orelse return null;
    const hi = posOf(r.object.get("end"), content, lines, enc) orelse return null;
    if (hi < lo) return null;
    return .{ .lo = lo, .hi = hi };
}

fn posOf(v: ?std.json.Value, content: []const u8, lines: LineIndex, enc: rpc.PositionEncoding) ?usize {
    const p = v orelse return null;
    if (p != .object) return null;
    const line = u32Of(p.object.get("line")) orelse return null;
    const ch = u32Of(p.object.get("character")) orelse return null;
    return @min(position.offsetOf(content, lines, line, ch, enc), @as(u32, @intCast(content.len)));
}

fn rowOf(v: ?std.json.Value) ?u32 {
    const r = v orelse return null;
    if (r != .object) return null;
    const st = r.object.get("start") orelse return null;
    if (st != .object) return null;
    return u32Of(st.object.get("line"));
}

fn u32Of(v: ?std.json.Value) ?u32 {
    const x = v orelse return null;
    return switch (x) {
        .integer => |i| if (i >= 0 and i <= std.math.maxInt(u32)) @intCast(i) else null,
        else => null,
    };
}

const testing = std.testing;

fn parse(a: std.mem.Allocator, text: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, a, text, .{});
}

test "DSY1 응답 → 목록: 계층을 문서 순서로 펴고(정렬 — 서버가 순서를 안 지킨다), 이름은 selectionRange 에서 읽으며, 종류는 우리 어휘다 (§8.2o)" {
    const a = testing.allocator;
    const content = "class Circle {\n  area() { return 1; }\n}\nconst c = 2;\n";
    var lines = try line_index.build(a, content);
    defer lines.deinit();
    // typescript-language-server 꼴: **문서 순서가 아니다**(`c` 가 먼저 온다).
    var p = try parse(a,
        \\[{"name":"c","kind":14,"range":{"start":{"line":3,"character":6},"end":{"line":3,"character":11}},
        \\  "selectionRange":{"start":{"line":3,"character":6},"end":{"line":3,"character":7}}},
        \\ {"name":"Circle","kind":5,"range":{"start":{"line":0,"character":0},"end":{"line":2,"character":1}},
        \\  "selectionRange":{"start":{"line":0,"character":6},"end":{"line":0,"character":12}},
        \\  "children":[{"name":"area","kind":6,"range":{"start":{"line":1,"character":2},"end":{"line":1,"character":22}},
        \\               "selectionRange":{"start":{"line":1,"character":2},"end":{"line":1,"character":6}}}]}]
    );
    defer p.deinit();
    var out: Symbols = .{};
    defer out.deinit(a);
    try decode(a, p.value, content, lines, .utf16, &out);
    try testing.expectEqual(@as(usize, 3), out.items.items.len);
    // 문서 순서: Circle(0) → area(1) → c(2). 깊이는 **포함 관계**로 센다.
    try testing.expectEqualStrings("Circle", content[out.items.items[0].name_start..out.items.items[0].name_end]);
    try testing.expectEqual(@as(u16, 0), out.items.items[0].depth);
    try testing.expectEqualStrings("class", out.items.items[0].kind);
    try testing.expectEqual(@as(u32, 0), out.items.items[0].start_row);
    try testing.expectEqualStrings("area", content[out.items.items[1].name_start..out.items.items[1].name_end]);
    try testing.expectEqual(@as(u16, 1), out.items.items[1].depth);
    try testing.expectEqualStrings("method", out.items.items[1].kind);
    try testing.expectEqual(@as(u32, 1), out.items.items[1].start_row);
    try testing.expectEqualStrings("c", content[out.items.items[2].name_start..out.items.items[2].name_end]);
    try testing.expectEqual(@as(u16, 0), out.items.items[2].depth);
    try testing.expectEqualStrings("constant", out.items.items[2].kind);
    // 전체 범위는 `range` 다 — 체인 조회(`offset < end`)가 그것을 쓴다.
    try testing.expect(out.items.items[0].start == 0 and out.items.items[0].end > out.items.items[1].end);
}

test "DSY2 서버 nesting 을 믿지 않는다 — 형제로 온 «안쪽» 항목도 포함 관계로 깊이를 다시 세고(tsgo 꼴), 이름이 문서와 다르면 버린다 (§8.2o)" {
    const a = testing.allocator;
    const content = "class C {\n  constructor(r: number) {}\n}\n";
    var lines = try line_index.build(a, content);
    defer lines.deinit();
    // tsgo 실측: 생성자 파라미터 `r`(L1:14-31) 이 생성자(L1:2-27) **안**인데 형제로 온다. 마지막 항목은 이름이 문서와 다르다(자기 검산).
    var p = try parse(a,
        \\[{"name":"C","kind":5,"range":{"start":{"line":0,"character":0},"end":{"line":2,"character":1}},
        \\  "selectionRange":{"start":{"line":0,"character":6},"end":{"line":0,"character":7}},
        \\  "children":[{"name":"constructor","kind":9,"range":{"start":{"line":1,"character":2},"end":{"line":1,"character":27}},
        \\               "selectionRange":{"start":{"line":1,"character":2},"end":{"line":1,"character":13}}},
        \\              {"name":"r","kind":7,"range":{"start":{"line":1,"character":14},"end":{"line":1,"character":23}},
        \\               "selectionRange":{"start":{"line":1,"character":14},"end":{"line":1,"character":15}}},
        \\              {"name":"ghost","kind":12,"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":5}},
        \\               "selectionRange":{"start":{"line":0,"character":0},"end":{"line":0,"character":5}}}]}]
    );
    defer p.deinit();
    var out: Symbols = .{};
    defer out.deinit(a);
    try decode(a, p.value, content, lines, .utf16, &out);
    try testing.expectEqual(@as(usize, 3), out.items.items.len); // `ghost` 는 버려졌다
    try testing.expectEqual(@as(u64, 1), out.name_mismatch);
    try testing.expectEqualStrings("constructor", content[out.items.items[1].name_start..out.items.items[1].name_end]);
    try testing.expectEqual(@as(u16, 1), out.items.items[1].depth);
    try testing.expectEqualStrings("r", content[out.items.items[2].name_start..out.items.items[2].name_end]);
    try testing.expectEqual(@as(u16, 2), out.items.items[2].depth); // **형제로 왔지만 생성자 안이다**
}

test "DSY7 같은 byte 에서 시작하면 «넓은 것(바깥)»이 먼저다 — 체인이 뒤집히면 「지금 어디」가 거꾸로 읽힌다 (§8.2o 적대적 A2)" {
    const a = testing.allocator;
    const content = "class C { inner() {} }\n";
    var lines = try line_index.build(a, content);
    defer lines.deinit();
    // 둘 다 character 0 에서 시작한다(부모는 줄 끝까지, 자식은 짧게) — 서버는 **좁은 것을 먼저** 낸다.
    var p = try parse(a,
        \\[{"name":"C","kind":5,"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":10}},
        \\  "selectionRange":{"start":{"line":0,"character":6},"end":{"line":0,"character":7}}},
        \\ {"name":"C","kind":5,"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":22}},
        \\  "selectionRange":{"start":{"line":0,"character":6},"end":{"line":0,"character":7}}}]
    );
    defer p.deinit();
    var out: Symbols = .{};
    defer out.deinit(a);
    try decode(a, p.value, content, lines, .utf16, &out);
    try testing.expectEqual(@as(usize, 2), out.items.items.len);
    // **넓은 것이 먼저** — 그래야 `chainAt` 이 바깥부터 쌓고 depth 가 0 → 1 이 된다.
    try testing.expectEqual(@as(u32, 22), out.items.items[0].end);
    try testing.expectEqual(@as(u16, 0), out.items.items[0].depth);
    try testing.expectEqual(@as(u32, 10), out.items.items[1].end);
    try testing.expectEqual(@as(u16, 1), out.items.items[1].depth);
}

test "DSY8 유효한 selectionRange 는 «범위 안 첫 등장»을 이긴다 — 주석·문자열에 같은 이름이 앞서 있어도 선언 자리를 가리킨다 (§8.2o 적대적 A11)" {
    const a = testing.allocator;
    const content = "/* add */ int add(void) {}\n";
    var lines = try line_index.build(a, content);
    defer lines.deinit();
    const decl = std.mem.lastIndexOf(u8, content, "add").?; // 선언 자리(주석 속 것이 아니다)
    var p = try parse(a,
        \\[{"name":"add","kind":12,"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":26}},
        \\  "selectionRange":{"start":{"line":0,"character":14},"end":{"line":0,"character":17}}}]
    );
    defer p.deinit();
    var out: Symbols = .{};
    defer out.deinit(a);
    try decode(a, p.value, content, lines, .utf16, &out);
    try testing.expectEqual(@as(usize, 1), out.items.items.len);
    try testing.expectEqual(@as(u32, @intCast(decl)), out.items.items[0].name_start); // 주석 속 3 이 아니다
    try testing.expectEqual(@as(u64, 0), out.name_mismatch);
}

test "DSY6 이름 범위가 쓸모없을 때 — 빈 selectionRange(tsgo 의 생성자)는 심볼 범위 안에서 이름을 찾아 쓰고, 거기에도 없으면 버린다 (§8.2o)" {
    const a = testing.allocator;
    const content = "class C {\n    constructor(private sides: number) {}\n}\n";
    var lines = try line_index.build(a, content);
    defer lines.deinit();
    // tsgo 실측: `selectionRange` 가 **빈 범위**(2:4-2:4)다. 둘째는 그 범위 안에도 이름이 없다.
    var p = try parse(a,
        \\[{"name":"constructor","kind":9,"range":{"start":{"line":1,"character":4},"end":{"line":1,"character":41}},
        \\  "selectionRange":{"start":{"line":1,"character":4},"end":{"line":1,"character":4}}},
        \\ {"name":"nowhere","kind":12,"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":9}},
        \\  "selectionRange":{"start":{"line":0,"character":0},"end":{"line":0,"character":0}}}]
    );
    defer p.deinit();
    var out: Symbols = .{};
    defer out.deinit(a);
    try decode(a, p.value, content, lines, .utf16, &out);
    try testing.expectEqual(@as(usize, 1), out.items.items.len);
    try testing.expectEqualStrings("constructor", content[out.items.items[0].name_start..out.items.items[0].name_end]);
    try testing.expectEqual(@as(u64, 1), out.name_mismatch); // `nowhere` 는 버렸다
}

test "DSY3 provider·평탄 꼴·빈 응답 — bool·객체·거짓·없음, SymbolInformation 은 버리고 세며, 상한 (§8.2o)" {
    const a = testing.allocator;
    const content = "fn a() {}\n";
    var lines = try line_index.build(a, content);
    defer lines.deinit();
    {
        var p = try parse(a, "{\"capabilities\":{\"documentSymbolProvider\":true}}");
        defer p.deinit();
        try testing.expect(supportedFromResult(p.value));
    }
    {
        var p = try parse(a, "{\"capabilities\":{\"documentSymbolProvider\":{\"label\":\"x\"}}}");
        defer p.deinit();
        try testing.expect(supportedFromResult(p.value));
    }
    {
        var p = try parse(a, "{\"capabilities\":{\"documentSymbolProvider\":false}}");
        defer p.deinit();
        try testing.expect(!supportedFromResult(p.value));
    }
    {
        var p = try parse(a, "{\"capabilities\":{}}");
        defer p.deinit();
        try testing.expect(!supportedFromResult(p.value));
    }
    try testing.expect(!supportedFromResult(null));
    // 평탄 꼴(`location` 을 든다) — 이름 범위가 없어 통째로 버리고 센다(1층이 그대로 남는다).
    var out: Symbols = .{};
    defer out.deinit(a);
    {
        var p = try parse(a,
            \\[{"name":"a","kind":12,"location":{"uri":"file:///x","range":{"start":{"line":0,"character":0},"end":{"line":0,"character":9}}}}]
        );
        defer p.deinit();
        try decode(a, p.value, content, lines, .utf16, &out);
        try testing.expectEqual(@as(usize, 0), out.items.items.len);
        try testing.expectEqual(@as(u64, 1), out.flat_dropped);
    }
    // `null`·배열 아님·빈 배열 — 전부 빈 목록(호출자는 1층을 쓴다).
    try decode(a, null, content, lines, .utf16, &out);
    try testing.expectEqual(@as(usize, 0), out.items.items.len);
    {
        var p = try parse(a, "[]");
        defer p.deinit();
        try decode(a, p.value, content, lines, .utf16, &out);
        try testing.expectEqual(@as(usize, 0), out.items.items.len);
    }
    try testing.expectEqualStrings("symbol", kindName(99)); // 표 밖은 목록에는 선다
}
