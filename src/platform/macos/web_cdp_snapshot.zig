//! Chromium(OSR) 탭의 `browser.snapshot` — DevTools 접근성 트리(`Accessibility.getFullAXTree`)를 WebKit snapshot 과 같은 모양
//! `{"tree":[{role, name, ref?, children?}]}` 으로 접는다(W9b①b — CEF·control-plane 을 모르는 순수 변환).
//!
//! - 역할이 있는 노드만 노드가 되고, 역할이 없거나(`generic`·`none`) 무시된 노드는 자식을 그 자리에 펼친다(WebKit 과 같다).
//!   `InlineTextBox` 는 버린다(글자 줄의 배치 조각). 글자(`StaticText`)는 부모 노드의 이름과 다를 때만 `{role:"text", name}` 으로 둔다
//!   — 버튼 「Go」 안의 글자 「Go」 처럼 되풀이는 빼고, 문단의 글은 에이전트가 읽게 한다(WebKit snapshot 에는 글이 없다).
//! - 상호작용 역할(WebKit 의 표와 같다)에만 ref 를 단다 — `n<backendNodeId>`(같은 문서 안에서 바뀌지 않는다, `web_cdp_ops`).
//! - 이름은 160 바이트까지(글자 경계에서 자른다 — WebKit 과 같은 상한).
//! - 트리는 sidecar 가 보낸 것(렌더러가 만든 것)이라 믿지 않는다 — 한 번 쓴 노드는 다시 쓰지 않고(순환·여러 부모), 재귀는
//!   `max_walk_depth` 에서, 남는 노드의 중첩은 `max_emit_depth` 에서 끊는다(W9b①b 적대 리뷰 — 깊게 겹친 `role=group` 이
//!   개발 빌드의 JSON 중첩 검사를 넘겨 앱이 죽었다).
//! - 입력칸(`textbox`·`searchbox`·`combobox`·`spinbutton`) 안의 글(= 지금 값)은 쓰지 않는다 — 사용자가 친 값을 snapshot 에 흘리지
//!   않는다(WebKit snapshot 에도 값은 없다).

const std = @import("std");

pub const Options = struct {
    interactive_only: bool = false,
    max_depth: ?u32 = null,
    /// selector 로 고른 요소(그 노드부터). null 이면 문서 전체(문서 노드의 자식들).
    root_backend: ?i64 = null,
};

const interactive_roles = [_][]const u8{ "button", "link", "textbox", "checkbox", "radio", "combobox", "listbox", "menuitem", "menuitemcheckbox", "menuitemradio", "option", "searchbox", "slider", "switch", "tab", "spinbutton" };
const flatten_roles = [_][]const u8{ "generic", "none", "presentation", "LabelText", "LineBreak", "Ignored" };
const max_name_bytes = 160;
/// 재귀 한도(펼친 노드 포함) — 메인 스레드 스택을 지킨다.
const max_walk_depth = 512;
/// 남는 노드의 중첩 한도 — 받는 쪽(serializeSnapshotResult 의 `std.json` 파서·에이전트)의 중첩 한도와 메인 스레드 스택을 지킨다
/// (노드 하나가 JSON 객체·`children` 배열 둘을 쓴다 — 200 단계).
const max_emit_depth = 100;
const value_roles = [_][]const u8{ "textbox", "searchbox", "combobox", "spinbutton" };

fn isOneOf(role: []const u8, set: []const []const u8) bool {
    for (set) |r| if (std.mem.eql(u8, role, r)) return true;
    return false;
}

const Node = struct {
    role: []const u8,
    name: []const u8,
    backend: ?i64,
    ignored: bool,
    children: []const []const u8,
};

const Tree = struct {
    nodes: std.StringHashMapUnmanaged(Node) = .empty,
    root: ?[]const u8 = null,
    by_backend: std.AutoHashMapUnmanaged(i64, []const u8) = .empty,
    /// 이미 쓴(또는 펼친) 노드 — 순환·여러 부모를 한 번만.
    seen: std.StringHashMapUnmanaged(void) = .empty,
    arena: std.mem.Allocator,
};

const Walk = struct {
    parent_name: []const u8,
    /// 재귀 깊이(펼친 노드 포함).
    walk: u32,
    /// 남는 노드의 중첩 깊이.
    depth: u32,
    /// 입력칸 안이다 — 글(값)을 쓰지 않는다.
    in_value: bool,
};

fn str(v: std.json.Value, a: []const u8, b: []const u8) []const u8 {
    if (v != .object) return "";
    const x = v.object.get(a) orelse return "";
    if (x != .object) return "";
    const y = x.object.get(b) orelse return "";
    return if (y == .string) y.string else "";
}

/// 접근성 트리 JSON(`{"nodes":[…]}`)을 snapshot JSON 으로. 고른 요소가 트리에 없으면 `{"tree":[]}`.
pub fn build(gpa: std.mem.Allocator, ax_json: []const u8, opts: Options) ![]u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, ax_json, .{});
    const list = blk: {
        if (parsed != .object) return error.InvalidTree;
        const n = parsed.object.get("nodes") orelse return error.InvalidTree;
        if (n != .array) return error.InvalidTree;
        break :blk n.array.items;
    };
    var tree: Tree = .{ .arena = a };
    for (list) |item| {
        if (item != .object) continue;
        const id = item.object.get("nodeId") orelse continue;
        if (id != .string) continue;
        var kids: std.ArrayList([]const u8) = .empty;
        if (item.object.get("childIds")) |c| if (c == .array) for (c.array.items) |k| if (k == .string) try kids.append(a, k.string);
        const backend: ?i64 = if (item.object.get("backendDOMNodeId")) |b| (if (b == .integer) b.integer else null) else null;
        const node: Node = .{
            .role = str(item, "role", "value"),
            .name = str(item, "name", "value"),
            .backend = backend,
            .ignored = if (item.object.get("ignored")) |g| g == .bool and g.bool else false,
            .children = kids.items,
        };
        try tree.nodes.put(a, id.string, node);
        if (backend) |bk| try tree.by_backend.put(a, bk, id.string);
        if (item.object.get("parentId") == null and tree.root == null) tree.root = id.string;
    }

    var items: std.ArrayList(u8) = .empty;
    defer items.deinit(gpa);
    if (opts.root_backend) |rb| {
        if (tree.by_backend.get(rb)) |id| try emit(&items, gpa, &tree, id, .{ .parent_name = "", .walk = 0, .depth = 0, .in_value = false }, opts);
    } else if (tree.root) |id| {
        // 문서 노드 자신은 넣지 않고 그 자식들부터(WebKit 이 body 부터인 것과 같다).
        const root = tree.nodes.get(id).?;
        try tree.seen.put(a, id, {});
        for (root.children) |k| try emit(&items, gpa, &tree, k, .{ .parent_name = root.name, .walk = 1, .depth = 0, .in_value = false }, opts);
    }
    return std.fmt.allocPrint(gpa, "{{\"tree\":[{s}]}}", .{items.items});
}

fn clampName(name: []const u8) []const u8 {
    if (name.len <= max_name_bytes) return name;
    var end: usize = max_name_bytes;
    while (end > 0 and (name[end] & 0xC0) == 0x80) end -= 1; // 글자 중간에서 자르지 않는다
    return name[0..end];
}

fn keepNode(n: Node, w: Walk, opts: Options) bool {
    const is_text = std.mem.eql(u8, n.role, "StaticText");
    if (n.ignored or n.role.len == 0 or isOneOf(n.role, &flatten_roles)) return false;
    if (is_text) return !opts.interactive_only and !w.in_value and n.name.len != 0 and !std.mem.eql(u8, n.name, w.parent_name);
    return !opts.interactive_only or isOneOf(n.role, &interactive_roles);
}

/// 노드 하나를 `out`(목록 안 — 앞에 쓴 것이 있으면 쉼표)에 쓴다. 역할이 없거나 무시된 노드면 자식을 그 자리에 쓴다. 한 번 쓴
/// 노드·한도를 넘은 깊이는 건너뛴다. 자식은 먼저 임시 버퍼에 써 보고 비어 있지 않을 때만 `children` 으로 붙인다 — 미리 세는
/// 탐색이 없어 공유된 노드가 많은 트리에서도 선형이다(복사는 깊이 `max_emit_depth` 로 묶인다).
fn emit(out: *std.ArrayList(u8), gpa: std.mem.Allocator, tree: *Tree, id: []const u8, w: Walk, opts: Options) !void {
    if (w.walk >= max_walk_depth) return;
    const n = tree.nodes.get(id) orelse return;
    if (std.mem.eql(u8, n.role, "InlineTextBox")) return;
    if (tree.seen.contains(id)) return;
    try tree.seen.put(tree.arena, id, {});
    const is_text = std.mem.eql(u8, n.role, "StaticText");
    const in_value = w.in_value or isOneOf(n.role, &value_roles);
    if (!keepNode(n, w, opts)) {
        if (is_text) return;
        if (opts.max_depth) |m| if (w.depth > m) return;
        for (n.children) |k| try emit(out, gpa, tree, k, .{ .parent_name = if (n.name.len != 0) n.name else w.parent_name, .walk = w.walk + 1, .depth = w.depth, .in_value = in_value }, opts);
        return;
    }
    if (out.items.len != 0) try out.append(gpa, ',');
    try out.print(gpa, "{{\"role\":{f},\"name\":{f}", .{ std.json.fmt(if (is_text) "text" else n.role, .{}), std.json.fmt(clampName(n.name), .{}) });
    if (isOneOf(n.role, &interactive_roles)) if (n.backend) |b| try out.print(gpa, ",\"ref\":\"n{d}\"", .{b});
    const deeper = (if (opts.max_depth) |m| w.depth < m else true) and w.depth + 1 < max_emit_depth;
    if (deeper and !is_text) {
        var kids: std.ArrayList(u8) = .empty;
        defer kids.deinit(gpa);
        const child: Walk = .{ .parent_name = n.name, .walk = w.walk + 1, .depth = w.depth + 1, .in_value = in_value };
        for (n.children) |k| try emit(&kids, gpa, tree, k, child, opts);
        if (kids.items.len != 0) {
            try out.appendSlice(gpa, ",\"children\":[");
            try out.appendSlice(gpa, kids.items);
            try out.append(gpa, ']');
        }
    }
    try out.append(gpa, '}');
}

const testing = std.testing;

// 실측한 트리의 모양(W9b①b 착수 전 — label 안의 입력, 버튼 글, 문단 글, 역할 없는 div).
const sample =
    \\{"nodes":[
    \\{"nodeId":"1","role":{"value":"RootWebArea"},"name":{"value":"b1b"},"backendDOMNodeId":5,"childIds":["2","20","30","40"]},
    \\{"nodeId":"2","role":{"value":"form"},"name":{"value":""},"backendDOMNodeId":2,"parentId":"1","childIds":["3","10"]},
    \\{"nodeId":"3","role":{"value":"LabelText"},"name":{"value":""},"backendDOMNodeId":11,"parentId":"2","childIds":["4","5"]},
    \\{"nodeId":"4","role":{"value":"StaticText"},"name":{"value":"Email "},"backendDOMNodeId":22,"parentId":"3","childIds":["4a"]},
    \\{"nodeId":"4a","role":{"value":"InlineTextBox"},"name":{"value":"Email "},"parentId":"4","childIds":[]},
    \\{"nodeId":"5","role":{"value":"textbox"},"name":{"value":"Email"},"backendDOMNodeId":3,"parentId":"3","childIds":["6"]},
    \\{"nodeId":"6","role":{"value":"generic"},"name":{"value":""},"backendDOMNodeId":12,"parentId":"5","childIds":["7"]},
    \\{"nodeId":"7","role":{"value":"StaticText"},"name":{"value":"old text"},"backendDOMNodeId":23,"parentId":"6","childIds":[]},
    \\{"nodeId":"10","role":{"value":"button"},"name":{"value":"Go"},"backendDOMNodeId":13,"parentId":"2","childIds":["11"]},
    \\{"nodeId":"11","role":{"value":"StaticText"},"name":{"value":"Go"},"backendDOMNodeId":24,"parentId":"10","childIds":[]},
    \\{"nodeId":"20","role":{"value":"paragraph"},"name":{"value":""},"backendDOMNodeId":17,"parentId":"1","childIds":["21"]},
    \\{"nodeId":"21","role":{"value":"StaticText"},"name":{"value":"Some text"},"backendDOMNodeId":26,"parentId":"20","childIds":[]},
    \\{"nodeId":"30","role":{"value":"generic"},"name":{"value":""},"backendDOMNodeId":19,"parentId":"1","childIds":["31"]},
    \\{"nodeId":"31","role":{"value":"link"},"name":{"value":"More"},"backendDOMNodeId":40,"parentId":"30","childIds":[]},
    \\{"nodeId":"40","role":{"value":"button"},"name":{"value":"Hidden"},"ignored":true,"backendDOMNodeId":41,"parentId":"1","childIds":[]}
    \\]}
;

test "접근성 트리 → WebKit 모양: 역할 없는 노드는 펼치고, 되풀이 글은 빼고, 상호작용 역할에만 n<backendNodeId> ref" {
    const out = try build(testing.allocator, sample, .{});
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        \\{"tree":[{"role":"form","name":"","children":[{"role":"text","name":"Email "},{"role":"textbox","name":"Email","ref":"n3"},{"role":"button","name":"Go","ref":"n13"}]},{"role":"paragraph","name":"","children":[{"role":"text","name":"Some text"}]},{"role":"link","name":"More","ref":"n40"}]}
    , out);
}

test "interactive_only 는 상호작용 노드만(글 없음), max_depth 는 깊이를 끊고, selector 루트는 그 노드부터 — 없으면 빈 트리" {
    {
        const out = try build(testing.allocator, sample, .{ .interactive_only = true });
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(
            \\{"tree":[{"role":"textbox","name":"Email","ref":"n3"},{"role":"button","name":"Go","ref":"n13"},{"role":"link","name":"More","ref":"n40"}]}
        , out);
    }
    {
        const out = try build(testing.allocator, sample, .{ .max_depth = 0 });
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(
            \\{"tree":[{"role":"form","name":""},{"role":"paragraph","name":""},{"role":"link","name":"More","ref":"n40"}]}
        , out);
    }
    {
        const out = try build(testing.allocator, sample, .{ .root_backend = 2 });
        defer testing.allocator.free(out);
        try testing.expect(std.mem.startsWith(u8, out, "{\"tree\":[{\"role\":\"form\""));
        try testing.expect(std.mem.indexOf(u8, out, "\"More\"") == null);
    }
    {
        const out = try build(testing.allocator, sample, .{ .root_backend = 999 });
        defer testing.allocator.free(out);
        try testing.expectEqualStrings("{\"tree\":[]}", out);
    }
}

test "이름은 160 바이트까지 글자 경계에서, 모양이 틀린 트리는 오류" {
    var long: [400]u8 = undefined;
    for (0..long.len / 3) |i| @memcpy(long[i * 3 ..][0..3], "가");
    const json = try std.fmt.allocPrint(testing.allocator, "{{\"nodes\":[{{\"nodeId\":\"1\",\"role\":{{\"value\":\"RootWebArea\"}},\"name\":{{\"value\":\"\"}},\"childIds\":[\"2\"]}},{{\"nodeId\":\"2\",\"role\":{{\"value\":\"button\"}},\"name\":{{\"value\":\"{s}\"}},\"backendDOMNodeId\":9,\"parentId\":\"1\",\"childIds\":[]}}]}}", .{long[0..399]});
    defer testing.allocator.free(json);
    const out = try build(testing.allocator, json, .{});
    defer testing.allocator.free(out);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out, .{});
    defer parsed.deinit();
    const name = parsed.value.object.get("tree").?.array.items[0].object.get("name").?.string;
    try testing.expect(name.len <= 160 and name.len % 3 == 0 and std.unicode.utf8ValidateSlice(name));
    try testing.expectError(error.InvalidTree, build(testing.allocator, "[]", .{}));
}

test "믿지 않는 트리: 순환·여러 부모는 한 번만, 아주 깊은 중첩은 한도에서 끊는다(앱이 죽지 않는다)" {
    // 1 → 2 → 3 → 2(순환), 그리고 1 → 3(두 번째 부모).
    const cyc =
        \\{"nodes":[{"nodeId":"1","role":{"value":"RootWebArea"},"name":{"value":""},"childIds":["2","3"]},
        \\{"nodeId":"2","role":{"value":"group"},"name":{"value":"a"},"parentId":"1","childIds":["3"]},
        \\{"nodeId":"3","role":{"value":"button"},"name":{"value":"b"},"backendDOMNodeId":7,"parentId":"2","childIds":["2"]}]}
    ;
    const out = try build(testing.allocator, cyc, .{});
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("{\"tree\":[{\"role\":\"group\",\"name\":\"a\",\"children\":[{\"role\":\"button\",\"name\":\"b\",\"ref\":\"n7\"}]}]}", out);
    // 2000 겹 group — 남는 노드의 중첩은 100 에서 끊는다.
    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(testing.allocator);
    try json.appendSlice(testing.allocator, "{\"nodes\":[{\"nodeId\":\"0\",\"role\":{\"value\":\"RootWebArea\"},\"name\":{\"value\":\"\"},\"childIds\":[\"1\"]}");
    for (1..2001) |i| try json.print(testing.allocator, ",{{\"nodeId\":\"{d}\",\"role\":{{\"value\":\"group\"}},\"name\":{{\"value\":\"g\"}},\"parentId\":\"{d}\",\"childIds\":[\"{d}\"]}}", .{ i, i - 1, i + 1 });
    try json.appendSlice(testing.allocator, "]}");
    const deep = try build(testing.allocator, json.items, .{});
    defer testing.allocator.free(deep);
    try testing.expectEqual(@as(usize, max_emit_depth), std.mem.count(u8, deep, "\"role\":\"group\""));
}

test "입력칸 안의 글(지금 값)은 snapshot 에 쓰지 않는다" {
    const out = try build(testing.allocator, sample, .{});
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "old text") == null);
    try testing.expect(std.mem.indexOf(u8, out, "Some text") != null); // 문단 글은 그대로
}

test "여러 부모를 가진 노드가 겹겹이 이어진 트리(60 단 다이아몬드)도 한 번씩만 — 지수로 불어나지 않는다" {
    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(testing.allocator);
    try json.appendSlice(testing.allocator, "{\"nodes\":[{\"nodeId\":\"r\",\"role\":{\"value\":\"RootWebArea\"},\"name\":{\"value\":\"\"},\"childIds\":[\"a0\",\"b0\"]}");
    for (0..60) |i| for ([_]u8{ 'a', 'b' }) |c| {
        try json.print(testing.allocator, ",{{\"nodeId\":\"{c}{d}\",\"role\":{{\"value\":\"generic\"}},\"name\":{{\"value\":\"\"}},\"childIds\":[\"a{d}\",\"b{d}\"]}}", .{ c, i, i + 1, i + 1 });
    };
    try json.appendSlice(testing.allocator, ",{\"nodeId\":\"a60\",\"role\":{\"value\":\"button\"},\"name\":{\"value\":\"end\"},\"backendDOMNodeId\":3,\"childIds\":[]}]}");
    const out = try build(testing.allocator, json.items, .{});
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("{\"tree\":[{\"role\":\"button\",\"name\":\"end\",\"ref\":\"n3\"}]}", out);
}
