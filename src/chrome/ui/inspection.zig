//! Read-only projection of the published paint/input tree. No action is dispatched.
const std = @import("std");
const tree = @import("tree.zig");
const layout = @import("layout.zig");
pub const Source = enum { status_bar, file_tree, scm, agent_sessions, sidebar_scroll, pane_divider };
pub const Key = struct { source: Source, id: u64, generation: u64 = 0 };
/// List row IDs may be reused after publication; bind those to their generation.
/// Fixed status/scroll identities may follow geometry across frames.
pub fn identity(n: Node) Key {
    return .{ .source = n.source, .id = n.id, .generation = switch (n.source) {
        .file_tree, .scm, .agent_sessions, .pane_divider => n.generation,
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
