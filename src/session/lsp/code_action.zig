//! LSP code action 목록(docs/editor-surface-tooling.md §8.2h) — `(Command | CodeAction)[]` 을 **메뉴에 낼 항목**으로 편다. `edit` 이 있거나
//! (`resolve` 가 되면) `data` 로 resolve 할 수 있는 `CodeAction` 만 남기고, `Command` 형·`command` 만 있는 것·`disabled` 는 숨긴다(§8.2 seam —
//! `workspace/executeCommand` 는 기본 거부). `isPreferred` 가 앞(안정). 슬라이스는 응답 트리를 빌린다 — 제품이 필요한 것을 복사한다. 순수 계산.

const std = @import("std");

pub const Item = struct {
    title: []const u8,
    kind: []const u8 = "",
    preferred: bool = false,
    /// 응답 트리 안의 `edit`(있으면 곧바로 적용).
    edit: ?std.json.Value = null,
    /// 원래 항목(트리 안) — `edit` 이 없을 때 `codeAction/resolve` 에 그대로 되돌려 준다.
    raw: std.json.Value,
};

pub const List = struct {
    items: []Item = &.{},
    /// 숨긴 것들(판정자 관측): Command 형·command 만·disabled·edit 도 data 도 없음.
    hidden: usize = 0,

    pub fn deinit(self: *List, allocator: std.mem.Allocator) void {
        if (self.items.len > 0) allocator.free(self.items);
        self.* = .{};
    }
};

pub const Error = error{ Malformed, OutOfMemory };

/// `result` 는 응답의 `result`. `null` 이면 빈 목록. 배열이 아니면 `Malformed`. `can_resolve` 는 서버의 `resolveProvider`.
pub fn parse(allocator: std.mem.Allocator, result: ?std.json.Value, can_resolve: bool) Error!List {
    const v = result orelse return .{};
    const arr = switch (v) {
        .array => |a| a.items,
        .null => return .{},
        else => return error.Malformed,
    };
    var out: std.ArrayList(Item) = .empty;
    errdefer out.deinit(allocator);
    var hidden: usize = 0;
    for (arr) |it| {
        if (it != .object) {
            hidden += 1;
            continue;
        }
        const o = it.object;
        const title = strOf(o.get("title")) orelse {
            hidden += 1;
            continue;
        };
        // `Command` 형(`command` 가 문자열)은 실행할 수 없다 — 숨긴다.
        if (o.get("command")) |c| if (c == .string) {
            hidden += 1;
            continue;
        };
        if (o.get("disabled")) |d| if (d == .object) {
            hidden += 1;
            continue;
        };
        const edit: ?std.json.Value = if (o.get("edit")) |e| (if (e == .object) e else null) else null;
        const has_data = o.get("data") != null;
        if (edit == null and !(can_resolve and has_data)) {
            hidden += 1; // command 만 있거나(§8.2 seam) resolve 할 길이 없다
            continue;
        }
        var item: Item = .{ .title = title, .raw = it, .edit = edit };
        if (strOf(o.get("kind"))) |k| item.kind = k;
        if (o.get("isPreferred")) |p| item.preferred = p == .bool and p.bool;
        try out.append(allocator, item);
    }
    // preferred 가 앞 — 안정 정렬이라 나머지 순서는 서버가 준 대로.
    std.mem.sort(Item, out.items, {}, struct {
        fn less(_: void, a: Item, b: Item) bool {
            return a.preferred and !b.preferred;
        }
    }.less);
    return .{ .items = try out.toOwnedSlice(allocator), .hidden = hidden };
}

fn strOf(v: ?std.json.Value) ?[]const u8 {
    const x = v orelse return null;
    return if (x == .string) x.string else null;
}

// ── 판정 ────────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn parseJson(a: std.mem.Allocator, text: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, a, text, .{});
}

test "CAX1 항목 파싱 — edit 있는 것·resolve 되는 data 만, Command 형·command 만·disabled 는 숨김, isPreferred 가 앞(안정), null 은 빈 목록, 배열 아님은 Malformed (§8.2h)" {
    const a = testing.allocator;
    var p = try parseJson(a,
        \\[
        \\ {"title":"Command form","command":"x.y","arguments":[]},
        \\ {"title":"cmd only","kind":"quickfix","command":{"title":"c","command":"x"}},
        \\ {"title":"with edit","kind":"quickfix","edit":{"changes":{}}},
        \\ {"title":"lazy","kind":"refactor","data":{"id":1}},
        \\ {"title":"preferred","kind":"quickfix","isPreferred":true,"edit":{"changes":{}}},
        \\ {"title":"off","disabled":{"reason":"no"},"edit":{"changes":{}}},
        \\ {"title":"both","edit":{"changes":{}},"command":{"title":"c","command":"x"}},
        \\ 7
        \\]
    );
    defer p.deinit();
    var l = try parse(a, p.value, true);
    defer l.deinit(a);
    try testing.expectEqual(@as(usize, 4), l.items.len);
    try testing.expectEqual(@as(usize, 4), l.hidden); // Command 형·cmd only·off·7
    try testing.expectEqualStrings("preferred", l.items[0].title);
    try testing.expectEqualStrings("with edit", l.items[1].title);
    try testing.expectEqualStrings("lazy", l.items[2].title);
    try testing.expect(l.items[2].edit == null);
    try testing.expectEqualStrings("refactor", l.items[2].kind);
    try testing.expectEqualStrings("both", l.items[3].title);
    try testing.expect(l.items[3].edit != null);
    // resolve 가 안 되면 lazy 는 숨는다.
    var l2 = try parse(a, p.value, false);
    defer l2.deinit(a);
    try testing.expectEqual(@as(usize, 3), l2.items.len);
    try testing.expectEqual(@as(usize, 5), l2.hidden);
    var n = try parse(a, null, true);
    defer n.deinit(a);
    try testing.expectEqual(@as(usize, 0), n.items.len);
    var bad = try parseJson(a, "{\"x\":1}");
    defer bad.deinit();
    try testing.expectError(error.Malformed, parse(a, bad.value, true));
}
