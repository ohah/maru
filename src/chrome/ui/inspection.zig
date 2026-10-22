//! Read-only projection of the published paint/input tree. No action is dispatched.
const std = @import("std");
const tree = @import("tree.zig");
const layout = @import("layout.zig");
pub const Source = enum { sidebar_header, file_header_details, file_header, dock_header, pane_tabs, sidebar, status_bar, file_tree, scm, agent_sessions, sidebar_scroll, pane_divider };
pub const Key = struct { source: Source, id: u64, generation: u64 = 0 };
/// List row IDs may be reused after publication; bind those to their generation.
/// Fixed status/scroll identities may follow geometry across frames.
pub fn identity(n: Node) Key {
    return .{ .source = n.source, .id = n.id, .generation = switch (n.source) {
        .sidebar_header, .file_header_details, .file_header, .dock_header, .pane_tabs, .sidebar, .file_tree, .scm, .agent_sessions, .pane_divider => n.generation,
        else => 0,
    } };
}
pub const Node = struct {
    source: Source,
    id: u64,
    parent_id: ?u64,
    generation: u64,
    kind: []const u8,
    role: ?[]const u8,
    rect: layout.UiRect,
    visible_rect: layout.UiRect,
    action_id: ?u64,
    enabled: ?bool,
    cursor: []const u8,
};
pub fn project(source: Source, snapshot: tree.UiRectTree, index: usize, dx: f32, dy: f32) Node {
    const e = snapshot.entries[index];
    var rect = e.rect;
    rect.x += dx;
    rect.y += dy;
    var visible = if (e.effective_clip) |clip| layout.intersectRect(e.rect, clip) else e.rect;
    visible.x += dx;
    visible.y += dy;
    return .{ .source = source, .id = e.id, .parent_id = if (e.parent_index) |p| if (p < index) snapshot.entries[p].id else null else null, .generation = snapshot.generation, .kind = @tagName(e.kind), .role = if (e.semantics) |s| @tagName(s.role) else null, .rect = rect, .visible_rect = visible, .action_id = if (e.action) |a| a.id else null, .enabled = if (e.action) |a| a.enabled else null, .cursor = @tagName(e.cursor) };
}
pub fn contains(r: layout.UiRect, x: f64, y: f64) bool {
    return std.math.isFinite(x) and std.math.isFinite(y) and std.math.isFinite(r.x) and std.math.isFinite(r.y) and std.math.isFinite(r.width) and std.math.isFinite(r.height) and r.width > 0 and r.height > 0 and x >= r.x and y >= r.y and x < @as(f64, r.x) + r.width and y < @as(f64, r.y) + r.height;
}
/// Reverse publication order matches painting: a child or later sibling wins.
pub fn pick(nodes: []const Node, x: f64, y: f64) ?Node {
    var i = nodes.len;
    while (i > 0) {
        i -= 1;
        if (contains(nodes[i].visible_rect, x, y)) return nodes[i];
    }
    return null;
}
pub fn resolve(nodes: []const Node, key: ?Key) ?Node {
    const k = key orelse return null;
    for (nodes) |n| if (n.source == k.source and n.id == k.id and (k.generation == 0 or n.generation == k.generation)) return n;
    return null;
}

pub const Branch = struct {
    key: Key,
    parent: ?Key,
    depth: usize,
    children: bool,
    expanded: bool,
    matched: bool,
    node: Node,
};
pub fn same(a: Key, b: Key) bool {
    return a.source == b.source and a.id == b.id and a.generation == b.generation;
}
fn has(keys: []const Key, k: Key) bool {
    for (keys) |candidate| if (same(candidate, k)) return true;
    return false;
}
fn matches(text: []const u8, query: []const u8) bool {
    if (query.len > text.len) return false;
    for (0..text.len - query.len + 1) |i| if (std.ascii.eqlIgnoreCase(text[i..][0..query.len], query)) return true;
    return false;
}
/// Published trees are preorder. Accept only an earlier, unambiguous parent in
/// the same publication, so truncated or malformed input cannot create cycles.
pub fn hierarchy(a: std.mem.Allocator, nodes: []const Node, collapsed: []const Key, query: []const u8) ![]Branch {
    const count = @min(nodes.len, 512);
    const parents = try a.alloc(?usize, count);
    const keep = try a.alloc(bool, count);
    const direct_match = try a.alloc(bool, count);
    const hidden = try a.alloc(bool, count);
    const children = try a.alloc(bool, count);
    @memset(children, false);
    const depths = try a.alloc(usize, count);
    for (nodes[0..count], 0..) |node, i| {
        parents[i] = null;
        if (node.parent_id) |id| {
            var ambiguous = false;
            for (nodes[0..i], 0..) |parent, j| {
                if (parent.source == node.source and parent.generation == node.generation and parent.id == id) {
                    if (parents[i] != null) ambiguous = true;
                    parents[i] = j;
                }
            }
            if (ambiguous) parents[i] = null;
        }
        depths[i] = if (parents[i]) |p| depths[p] + 1 else 0;
        if (parents[i]) |p| children[p] = true;
        hidden[i] = if (parents[i]) |p| hidden[p] or has(collapsed, identity(nodes[p])) else false;
        var id_buf: [20]u8 = undefined;
        const id = std.fmt.bufPrint(&id_buf, "{d}", .{node.id}) catch unreachable;
        keep[i] = query.len == 0 or matches(@tagName(node.source), query) or matches(node.kind, query) or matches(node.role orelse "", query) or matches(id, query);
        direct_match[i] = query.len != 0 and keep[i];
    }
    // Search reveals ancestors even when a branch was explicitly collapsed.
    if (query.len != 0) {
        var i = count;
        while (i > 0) {
            i -= 1;
            if (keep[i]) if (parents[i]) |p| {
                keep[p] = true;
            };
        }
    }
    var out: std.ArrayList(Branch) = .empty;
    for (nodes[0..count], 0..) |node, i| {
        if (!keep[i] or (query.len == 0 and hidden[i])) continue;
        try out.append(a, .{ .key = identity(node), .parent = if (parents[i]) |p| identity(nodes[p]) else null, .depth = depths[i], .children = children[i], .expanded = query.len != 0 or !has(collapsed, identity(node)), .matched = direct_match[i], .node = node });
    }
    return out.toOwnedSlice(a);
}
test "inspector inspection clips, translates, and picks disabled children without dispatch" {
    const entries = [_]tree.RectEntry{
        .{ .id = 1, .parent_index = null, .kind = .container, .rect = .{ .x = 0, .y = 0, .width = 100, .height = 100 }, .effective_clip = null, .action = null },
        .{ .id = 2, .parent_index = 0, .kind = .button, .rect = .{ .x = 10, .y = 10, .width = 80, .height = 80 }, .effective_clip = .{ .x = 20, .y = 20, .width = 20, .height = 20 }, .action = .{ .id = 7, .enabled = false } },
    };
    const t: tree.UiRectTree = .{ .entries = &entries, .generation = 9 };
    const nodes = [_]Node{ project(.scm, t, 0, 100, 200), project(.scm, t, 1, 100, 200) };
    try std.testing.expectEqual(@as(u64, 2), pick(&nodes, 120, 220).?.id);
    try std.testing.expectEqual(@as(u64, 1), pick(&nodes, 140, 240).?.id);
    try std.testing.expectEqual(false, nodes[1].enabled.?);
    try std.testing.expectEqual(@as(?u64, 1), nodes[1].parent_id);
    try std.testing.expect(pick(&nodes, std.math.nan(f64), 220) == null);
    try std.testing.expect(resolve(&nodes, .{ .source = .status_bar, .id = 2 }) == null);
    try std.testing.expectEqual(@as(u64, 9), resolve(&nodes, .{ .source = .scm, .id = 2 }).?.generation);
}

test "inspector inspection rejects stale list identities after replacement and compaction" {
    const entry: tree.RectEntry = .{ .id = 8, .parent_index = null, .kind = .button, .rect = .{ .x = 1, .y = 2, .width = 3, .height = 4 }, .effective_clip = null, .action = null };
    const old = project(.file_tree, .{ .entries = &.{entry}, .generation = 2 }, 0, 0, 0);
    const fresh = project(.file_tree, .{ .entries = &.{entry}, .generation = 3 }, 0, 20, 30);
    try std.testing.expect(resolve(&.{fresh}, identity(old)) == null);
    try std.testing.expect(resolve(&.{}, identity(old)) == null);
    try std.testing.expectEqual(@as(f32, 21), resolve(&.{fresh}, identity(fresh)).?.rect.x);
    const same_id_other_source = project(.scm, .{ .entries = &.{entry}, .generation = 2 }, 0, 0, 0);
    try std.testing.expect(resolve(&.{same_id_other_source}, identity(old)) == null);
}

test "inspector inspection handles shared edges zero extents infinity and reverse overlap" {
    const entry: tree.RectEntry = .{ .id = 1, .parent_index = null, .kind = .container, .rect = .{ .x = 0, .y = 0, .width = 10, .height = 10 }, .effective_clip = null, .action = null };
    var first = project(.status_bar, .{ .entries = &.{entry} }, 0, 0, 0);
    var second = first;
    second.id = 2;
    try std.testing.expectEqual(@as(u64, 2), pick(&.{ first, second }, 5, 5).?.id);
    try std.testing.expect(pick(&.{first}, 10, 5) == null);
    try std.testing.expect(pick(&.{first}, 5, 10) == null);
    try std.testing.expect(pick(&.{first}, -0.1, 0) == null);
    try std.testing.expect(pick(&.{first}, std.math.inf(f64), 0) == null);
    first.visible_rect.width = 0;
    try std.testing.expect(pick(&.{first}, 0, 0) == null);
    first.visible_rect.width = std.math.nan(f32);
    try std.testing.expect(pick(&.{first}, 0, 0) == null);
}

fn fixtureNode(id: u64, parent: ?u64, kind: []const u8) Node {
    return .{ .source = .file_tree, .id = id, .parent_id = parent, .generation = 7, .kind = kind, .role = null, .rect = .{ .x = 0, .y = 0, .width = 10, .height = 10 }, .visible_rect = .{ .x = 0, .y = 0, .width = 10, .height = 10 }, .action_id = null, .enabled = null, .cursor = "arrow" };
}
test "inspector hierarchy preserves parent depth collapse and search paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nodes = [_]Node{ fixtureNode(1, null, "container"), fixtureNode(2, 1, "group"), fixtureNode(3, 2, "button"), fixtureNode(4, 1, "label") };
    const normal = try hierarchy(a, &nodes, &.{}, "");
    try std.testing.expectEqual(@as(usize, 4), normal.len);
    try std.testing.expectEqual(@as(usize, 2), normal[2].depth);
    try std.testing.expect(same(normal[2].parent.?, identity(nodes[1])));
    try std.testing.expect(normal[0].children and normal[1].children and !normal[2].children);
    const closed = try hierarchy(a, &nodes, &.{identity(nodes[1])}, "");
    try std.testing.expectEqual(@as(usize, 3), closed.len);
    try std.testing.expectEqual(@as(u64, 4), closed[2].key.id);
    try std.testing.expect(!closed[1].expanded);
    const search = try hierarchy(a, &nodes, &.{identity(nodes[0])}, "BUTTON");
    try std.testing.expectEqual(@as(usize, 3), search.len);
    try std.testing.expect(search[0].expanded and search[1].expanded);
    try std.testing.expect(!search[0].matched and search[2].matched);
    try std.testing.expectEqual(@as(usize, 0), (try hierarchy(a, &nodes, &.{}, "absent")).len);
    try std.testing.expectEqual(@as(usize, 3), (try hierarchy(a, &nodes, &.{}, "3")).len);
    try std.testing.expectEqual(@as(usize, 4), (try hierarchy(a, &nodes, &.{}, "file_tree")).len);
    try std.testing.expectEqual(@as(usize, 0), (try hierarchy(a, &.{}, &.{}, "")).len);
}
test "inspector hierarchy rejects cycles ambiguous parents and cross publication ancestry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var nodes = [_]Node{ fixtureNode(1, 2, "root"), fixtureNode(2, 1, "child"), fixtureNode(3, 99, "orphan") };
    var rows = try hierarchy(a, &nodes, &.{}, "");
    try std.testing.expect(rows[0].parent == null and rows[2].parent == null);
    try std.testing.expectEqual(@as(usize, 1), rows[1].depth);
    nodes[1].generation = 8;
    rows = try hierarchy(a, &nodes, &.{}, "");
    try std.testing.expect(rows[1].parent == null);
    nodes[1].generation = 7;
    nodes[1].source = .scm;
    rows = try hierarchy(a, &nodes, &.{}, "");
    try std.testing.expect(rows[1].parent == null);
    nodes[1] = nodes[0];
    nodes[2].parent_id = 1;
    rows = try hierarchy(a, &nodes, &.{}, "");
    try std.testing.expect(rows[2].parent == null);
    nodes[2] = fixtureNode(std.math.maxInt(u64), null, "button");
    rows = try hierarchy(a, &nodes, &.{}, "18446744073709551615");
    try std.testing.expectEqual(std.math.maxInt(u64), rows[0].key.id);
}
test "inspector hierarchy bounds deep trees and ignores stale collapse keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var nodes: [513]Node = undefined;
    for (&nodes, 0..) |*node, i| node.* = fixtureNode(i + 1, if (i == 0) null else i, "container");
    const rows = try hierarchy(a, &nodes, &.{.{ .source = .file_tree, .id = 1, .generation = 6 }}, "");
    try std.testing.expectEqual(@as(usize, 512), rows.len);
    try std.testing.expectEqual(@as(usize, 511), rows[511].depth);
    try std.testing.expectEqual(@as(usize, 1), (try hierarchy(a, &nodes, &.{identity(nodes[0])}, "")).len);
}
