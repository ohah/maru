//! Chromium(OSR) 탭의 `browser.snapshot` — DevTools 접근성 트리(`Accessibility.getFullAXTree`)를 WebKit snapshot 과 같은 모양
//! `{"tree":[{role, name, ref?, children?}]}` 으로 접는다(W9b①b — CEF·control-plane 을 모르는 순수 변환).
//!
//! - 역할이 있는 노드만 노드가 되고, 역할이 없거나(`generic`·`none`) 무시된 노드는 자식을 그 자리에 펼친다(WebKit 과 같다).
//!   `InlineTextBox` 는 버린다(글자 줄의 배치 조각). 글자(`StaticText`)는 부모 노드의 이름과 다를 때만 `{role:"text", name}` 으로 둔다
//!   — 버튼 「Go」 안의 글자 「Go」 처럼 되풀이는 빼고, 문단의 글은 에이전트가 읽게 한다(WebKit snapshot 에는 글이 없다).
//! - 상호작용 역할(WebKit 의 표와 같다)에만 ref 를 단다 — `n<backendNodeId>`(같은 문서 안에서 바뀌지 않는다, `web_cdp_ops`).
//! - 이름은 160 바이트까지(글자 경계에서 자른다 — WebKit 과 같은 상한).

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
    var tree: Tree = .{};
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

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    try s.beginObject();
    try s.objectField("tree");
    try s.beginArray();
    if (opts.root_backend) |rb| {
        if (tree.by_backend.get(rb)) |id| try emit(&s, &tree, id, "", 0, opts);
    } else if (tree.root) |id| {
        // 문서 노드 자신은 넣지 않고 그 자식들부터(WebKit 이 body 부터인 것과 같다).
        const root = tree.nodes.get(id).?;
        for (root.children) |k| try emit(&s, &tree, k, root.name, 0, opts);
    }
    try s.endArray();
    try s.endObject();
    return out.toOwnedSlice();
}

fn clampName(name: []const u8) []const u8 {
    if (name.len <= max_name_bytes) return name;
    var end: usize = max_name_bytes;
    while (end > 0 and (name[end] & 0xC0) == 0x80) end -= 1; // 글자 중간에서 자르지 않는다
    return name[0..end];
}

/// 노드 하나를 쓴다 — 역할이 없거나 무시된 노드면 자식을 그 자리에 쓴다.
fn emit(s: *std.json.Stringify, tree: *Tree, id: []const u8, parent_name: []const u8, depth: u32, opts: Options) !void {
    const n = tree.nodes.get(id) orelse return;
    if (std.mem.eql(u8, n.role, "InlineTextBox")) return;
    const is_text = std.mem.eql(u8, n.role, "StaticText");
    const interactive = isOneOf(n.role, &interactive_roles);
    const keep = !n.ignored and n.role.len != 0 and !isOneOf(n.role, &flatten_roles) and
        (if (is_text) !opts.interactive_only and n.name.len != 0 and !std.mem.eql(u8, n.name, parent_name) else (!opts.interactive_only or interactive));
    if (!keep) {
        if (is_text) return;
        if (opts.max_depth) |m| if (depth > m) return;
        for (n.children) |k| try emit(s, tree, k, if (n.name.len != 0) n.name else parent_name, depth, opts);
        return;
    }
    try s.beginObject();
    try s.objectField("role");
    try s.write(if (is_text) "text" else n.role);
    try s.objectField("name");
    try s.write(clampName(n.name));
    if (interactive) if (n.backend) |b| {
        var buf: [24]u8 = undefined;
        try s.objectField("ref");
        try s.write(try std.fmt.bufPrint(&buf, "n{d}", .{b}));
    };
    const deeper = if (opts.max_depth) |m| depth < m else true;
    if (deeper and !is_text) {
        // 자식이 하나라도 쓰일 때만 `children` 을 연다 — 먼저 세어 본다.
        var any = false;
        for (n.children) |k| if (wouldEmit(tree, k, n.name, opts)) {
            any = true;
            break;
        };
        if (any) {
            try s.objectField("children");
            try s.beginArray();
            for (n.children) |k| try emit(s, tree, k, n.name, depth + 1, opts);
            try s.endArray();
        }
    }
    try s.endObject();
}

/// 이 노드(또는 펼쳐질 자손)가 무엇이라도 쓰이는가.
fn wouldEmit(tree: *Tree, id: []const u8, parent_name: []const u8, opts: Options) bool {
    const n = tree.nodes.get(id) orelse return false;
    if (std.mem.eql(u8, n.role, "InlineTextBox")) return false;
    const is_text = std.mem.eql(u8, n.role, "StaticText");
    if (is_text) return !opts.interactive_only and !n.ignored and n.name.len != 0 and !std.mem.eql(u8, n.name, parent_name);
    const interactive = isOneOf(n.role, &interactive_roles);
    const keep = !n.ignored and n.role.len != 0 and !isOneOf(n.role, &flatten_roles) and (!opts.interactive_only or interactive);
    if (keep) return true;
    for (n.children) |k| if (wouldEmit(tree, k, if (n.name.len != 0) n.name else parent_name, opts)) return true;
    return false;
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
        \\{"tree":[{"role":"form","name":"","children":[{"role":"text","name":"Email "},{"role":"textbox","name":"Email","ref":"n3","children":[{"role":"text","name":"old text"}]},{"role":"button","name":"Go","ref":"n13"}]},{"role":"paragraph","name":"","children":[{"role":"text","name":"Some text"}]},{"role":"link","name":"More","ref":"n40"}]}
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
