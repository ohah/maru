//! Published row geometry shared by sidebar paint, input and inspection.
//! Contract: docs/plans/ui-inspector.md, docs/chrome-interaction-migration.md.
const std = @import("std");
const sidebar = @import("../sidebar.zig");
const tree = @import("../../ui/tree.zig");
const layout = @import("../../ui/layout.zig");
const draw = @import("../../draw.zig");

pub const root_id: u64 = 0x5342000000000000;
pub fn rowId(slot: usize) u64 {
    return root_id + 1 + @as(u64, @intCast(slot)) * 2;
}
pub fn closeId(slot: usize) u64 {
    return rowId(slot) + 1;
}
pub const Params = struct {
    width: u32,
    header: u32,
    viewport_height: u32,
    scroll: u32,
    metrics: sidebar.Metrics,
    close: ?struct { left: f32, right: f32 } = null,
};
fn feed(h: *std.hash.Wyhash, values: []const u64) void {
    h.update(std.mem.sliceAsBytes(values));
}
/// Labels are intentionally absent: their lifetime belongs to native text, and
/// renaming a workspace does not replace its inspection identity.
pub fn signature(rows: []const sidebar.Row, p: Params, model_epoch: u64) u64 {
    var h = std.hash.Wyhash.init(model_epoch);
    const m = p.metrics;
    feed(&h, &.{ p.width, p.header, p.viewport_height, p.scroll, m.line_h, m.line_step, m.card_pad_v, m.header_row_h, m.content_pad_v, m.list_pad_v, rows.len });
    if (p.close) |c| feed(&h, &.{ @as(u32, @bitCast(c.left)), @as(u32, @bitCast(c.right)) });
    for (rows) |row| switch (row) {
        .card => |c| feed(&h, &.{ 1, c.tab, c.depth, c.lines, @intFromBool(c.active) }),
        .group_header => |g| feed(&h, &.{ 2, g.tab, g.depth, g.member_count, @intFromBool(g.collapsed), @intFromBool(g.has_color) }),
        .agent_toggle => |v| feed(&h, &.{ 3, v.tab, v.count, v.depth, @intFromBool(v.collapsed), @intFromBool(v.last) }),
        .agent => |v| feed(&h, &.{ 4, v.tab, v.pane, v.term, v.depth, v.lines, @intFromBool(v.last) }),
        .agent_pane => |v| {
            feed(&h, &.{ 5, v.tab, v.pane, v.term, v.depth, v.lines, v.more, @intFromBool(v.last) });
            // Display-name bytes do not participate in geometry or identity.
        },
        .recovered_sessions_header => feed(&h, &.{6}),
        .recovered_session => |v| {
            feed(&h, &.{ 7, v.projection_index, v.lines });
        },
    };
    return h.final();
}
pub const Frame = struct {
    entries: std.ArrayList(tree.RectEntry) = .empty,
    generation: u64 = 0,
    stamp: ?u64 = null,
    params: ?Params = null,
    row_count: usize = 0,
    pub fn deinit(self: *Frame, a: std.mem.Allocator) void {
        self.entries.deinit(a);
        self.* = .{};
    }
    pub fn invalidate(self: *Frame) void {
        self.entries.clearRetainingCapacity();
        self.stamp = null;
        self.params = null;
        self.generation +|= 1;
    }
    pub fn current(self: *const Frame, rows: []const sidebar.Row, p: Params, epoch: u64) bool {
        return self.stamp != null and self.stamp.? == signature(rows, p, epoch);
    }
    pub fn snapshot(self: *const Frame) tree.UiRectTree {
        return .{ .entries = self.entries.items, .generation = self.generation };
    }
    pub fn row(self: *const Frame, slot: usize) ?tree.RectEntry {
        const t = self.snapshot();
        return t.entries[t.find(rowId(slot)) orelse return null];
    }
    pub fn slotAt(self: *const Frame, y: f64) ?usize {
        if (!std.math.isFinite(y)) return null;
        for (self.entries.items) |entry| {
            if (entry.id <= root_id or (entry.id - root_id) % 2 != 1) continue;
            const r = if (entry.effective_clip) |c| layout.intersectRect(entry.rect, c) else entry.rect;
            if (r.height > 0 and y >= r.y and y < @as(f64, r.y) + r.height) return @intCast((entry.id - root_id - 1) / 2);
        }
        return null;
    }
    /// Paint's list-relative bands are derived from the published screen rects;
    /// the host's existing scissor/lowering remains responsible for clipping.
    pub fn span(self: *const Frame, from: usize, to: usize) ?draw.Rect {
        const p = self.params orelse return null;
        if (from >= @min(to, self.row_count)) return null;
        const first = self.row(from) orelse return null;
        const last = self.row(@min(to, self.row_count) -| 1) orelse return null;
        return .{ .x = @intFromFloat(first.rect.x), .y = @intFromFloat(first.rect.y - @as(f32, @floatFromInt(p.header)) + @as(f32, @floatFromInt(p.scroll))), .w = @intFromFloat(first.rect.width), .h = @intFromFloat(@max(0, last.rect.y + last.rect.height - first.rect.y)) };
    }
    pub fn publish(self: *Frame, a: std.mem.Allocator, rows: []const sidebar.Row, p: Params, epoch: u64) !void {
        const needed = try std.math.add(usize, try std.math.mul(usize, rows.len, 2), 1);
        self.entries.ensureTotalCapacity(a, needed) catch |err| {
            self.invalidate();
            return err;
        };
        const stamp = signature(rows, p, epoch);
        if (self.stamp == null or self.stamp.? != stamp) self.generation +|= 1;
        self.entries.clearRetainingCapacity();
        self.params = p;
        self.stamp = stamp;
        self.row_count = rows.len;
        if (p.width == 0 or p.viewport_height == 0 or p.metrics.line_h == 0) return;
        const clip: layout.UiRect = .{ .x = 0, .y = @floatFromInt(p.header), .width = @floatFromInt(p.width), .height = @floatFromInt(p.viewport_height) };
        self.entries.appendAssumeCapacity(.{ .id = root_id, .parent_index = null, .kind = .scroll_area, .rect = clip, .effective_clip = clip, .own_clip = clip, .action = null, .semantics = .{ .role = .scroll_view, .label = "" } });
        var groups: [256]?usize = @splat(null);
        var card: ?usize = null;
        var top = sidebar.rowTop(rows, 0, p.header, p.metrics, p.scroll);
        for (rows, 0..) |r, i| {
            const rect: layout.UiRect = .{ .x = 0, .y = @floatFromInt(top), .width = @floatFromInt(p.width), .height = @floatFromInt(sidebar.rowHeight(r, p.metrics)) };
            top +|= sidebar.rowHeight(r, p.metrics);
            const index = self.entries.items.len;
            var parent: usize = 0;
            var semantics: ?tree.Semantics = null;
            switch (r) {
                .group_header => |g| {
                    const depth = @max(@as(usize, g.depth), 1);
                    parent = if (depth > 1) groups[depth - 1] orelse 0 else 0;
                    groups[depth] = index;
                    @memset(groups[depth + 1 ..], null);
                    card = null;
                    semantics = .{ .role = .tree_item, .label = "", .expanded = !g.collapsed, .level = @intCast(depth), .focusable = true };
                },
                .card => |c| {
                    if (c.depth == 0) @memset(&groups, null);
                    parent = groups[c.depth] orelse 0;
                    card = index;
                    semantics = .{ .role = .tab, .label = "", .selected = c.active, .focusable = true };
                },
                // These are the existing canonical list rows, not a second
                // Inspector-only layout. Keep labels in the native text owner.
                .agent_toggle => |v| {
                    parent = card orelse 0;
                    semantics = .{ .role = .button, .label = "", .expanded = !v.collapsed, .focusable = true };
                },
                .agent => {
                    parent = card orelse 0;
                    semantics = .{ .role = .list_item, .label = "", .focusable = true };
                },
                else => parent = card orelse 0,
            }
            self.entries.appendAssumeCapacity(.{ .id = rowId(i), .parent_index = parent, .kind = if (r == .group_header or r == .agent_toggle) .button else .card, .rect = rect, .effective_clip = clip, .action = .{ .id = rowId(i) }, .cursor = .press, .semantics = semantics });
            if (r == .card) if (p.close) |c| {
                if (!std.math.isFinite(c.left) or !std.math.isFinite(c.right)) continue;
                const left = @max(0, c.left);
                const right = @min(rect.width, c.right);
                if (std.math.isFinite(left) and std.math.isFinite(right) and right > left) self.entries.appendAssumeCapacity(.{ .id = closeId(i), .parent_index = index, .kind = .button, .rect = .{ .x = left, .y = rect.y, .width = right - left, .height = rect.height }, .effective_clip = clip, .action = .{ .id = closeId(i) }, .cursor = .press, .semantics = .{ .role = .button, .label = "" } });
            };
        }
    }
};

test "published sidebar session rows share geometry roles and retire changed owners" {
    const a = std.testing.allocator;
    var rows = [_]sidebar.Row{
        .{ .card = .{ .tab = 0, .label = "private", .active = true } },
        .{ .agent_toggle = .{ .tab = 0, .count = 2, .collapsed = false } },
        .{ .agent = .{ .tab = 0, .pane = 0, .term = 0, .lines = 1 } },
        .{ .agent = .{ .tab = 0, .pane = 0, .term = 1, .lines = 3, .last = true } },
        .recovered_sessions_header,
        .{ .recovered_session = .{ .projection_index = 0 } },
    };
    const p: Params = .{ .width = 240, .header = 40, .viewport_height = 400, .scroll = 10, .metrics = sidebar.Metrics.init(20, 24) };
    var f: Frame = .{};
    defer f.deinit(a);
    try f.publish(a, &rows, p, 10);
    for (1..4) |i| {
        const row = f.row(i).?;
        try std.testing.expectEqual(rowId(0), f.snapshot().entries[row.parent_index.?].id);
        try std.testing.expectEqual(@as(f32, @floatFromInt(sidebar.rowTop(&rows, i, p.header, p.metrics, p.scroll))), row.rect.y);
        try std.testing.expectEqual(@as(f32, @floatFromInt(sidebar.rowHeight(rows[i], p.metrics))), row.rect.height);
        try std.testing.expectEqual(rowId(i), row.action.?.id);
        try std.testing.expectEqual(tree.CursorHint.press, row.cursor);
        try std.testing.expectEqualStrings("", row.semantics.?.label);
        try std.testing.expectEqual(@as(?usize, i), f.slotAt(row.rect.y + 1));
    }
    try std.testing.expectEqual(tree.SemanticRole.button, f.row(1).?.semantics.?.role);
    try std.testing.expect(f.row(1).?.semantics.?.expanded.?);
    try std.testing.expectEqual(tree.SemanticRole.list_item, f.row(2).?.semantics.?.role);
    try std.testing.expect(f.row(2).?.semantics.?.expanded == null);
    try std.testing.expect(f.row(4).?.semantics == null and f.row(5).?.semantics == null);
    const generation = f.generation;
    rows[1].agent_toggle.collapsed = true;
    try std.testing.expect(!f.current(&rows, p, 10));
    try f.publish(a, &rows, p, 10);
    try std.testing.expect(f.generation > generation and !f.row(1).?.semantics.?.expanded.?);
    const changed = f.generation;
    try f.publish(a, &rows, p, 11);
    try std.testing.expect(f.generation > changed);
    rows[2].agent.term = 1;
    rows[3].agent.term = 0;
    try std.testing.expect(!f.current(&rows, p, 11));
}

test "published sidebar shares row spans, nested parents and clipped input" {
    const a = std.testing.allocator;
    const rows = [_]sidebar.Row{
        .{ .group_header = .{ .collapsed = false, .label = "private", .member_count = 2, .tab = 0, .depth = 1, .has_color = false } },
        .{ .card = .{ .tab = 0, .label = "secret", .active = false, .depth = 1, .lines = 2 } },
        .{ .group_header = .{ .collapsed = false, .label = "nested", .member_count = 1, .tab = 1, .depth = 2, .has_color = true } },
        .{ .card = .{ .tab = 1, .label = "second", .active = true, .depth = 2 } },
    };
    const p: Params = .{ .width = 200, .header = 40, .viewport_height = 90, .scroll = 12, .metrics = sidebar.Metrics.init(20, 20), .close = .{ .left = 170, .right = 190 } };
    var f: Frame = .{};
    defer f.deinit(a);
    try f.publish(a, &rows, p, 10);
    const t = f.snapshot();
    try std.testing.expectEqual(rowId(0), t.entries[f.row(1).?.parent_index.?].id);
    try std.testing.expectEqual(rowId(0), t.entries[f.row(2).?.parent_index.?].id);
    try std.testing.expectEqual(rowId(2), t.entries[f.row(3).?.parent_index.?].id);
    try std.testing.expectEqual(rowId(1), t.entries[t.entries[t.find(closeId(1)).?].parent_index.?].id);
    for (rows, 0..) |r, i| {
        const e = f.row(i).?;
        try std.testing.expectEqual(@as(f32, @floatFromInt(sidebar.rowTop(&rows, i, p.header, p.metrics, p.scroll))), e.rect.y);
        try std.testing.expectEqual(@as(f32, @floatFromInt(sidebar.rowHeight(r, p.metrics))), e.rect.height);
        try std.testing.expectEqualDeep(sidebar.spanRect(&rows, i, i + 1, p.width, p.metrics), f.span(i, i + 1).?);
        try std.testing.expectEqualStrings("", e.semantics.?.label);
    }
    try std.testing.expectEqual(@as(?usize, null), f.slotAt(39));
    try std.testing.expectEqual(@as(?usize, null), f.slotAt(130));
    try std.testing.expectEqual(@as(?usize, null), f.slotAt(std.math.nan(f64)));
    const r = f.row(1).?.rect;
    try std.testing.expectEqual(@as(?usize, 1), f.slotAt(@max(40, r.y)));
    const generation = f.generation;
    try f.publish(a, &rows, p, 10);
    try std.testing.expectEqual(generation, f.generation);
    try std.testing.expect(!f.current(&rows, p, 11));
    try f.publish(a, &rows, p, 11);
    try std.testing.expect(f.generation > generation);
    var changed = rows;
    changed[1].card.tab = 8;
    try std.testing.expect(!f.current(&changed, p, 11));
    var invalid = p;
    invalid.close = .{ .left = std.math.nan(f32), .right = 190 };
    try f.publish(a, &rows, invalid, 11);
    try std.testing.expect(f.snapshot().find(closeId(1)) == null);
}

test "failed sidebar publication retires stale geometry and can recover" {
    const rows = [_]sidebar.Row{.{ .card = .{ .tab = 0, .label = "", .active = true } }};
    const p: Params = .{ .width = 200, .header = 20, .viewport_height = 100, .scroll = 0, .metrics = sidebar.Metrics.init(20, 20) };
    var f: Frame = .{};
    defer f.deinit(std.testing.allocator);
    try f.publish(std.testing.allocator, &rows, p, 1);
    const old = f.generation;
    // Retire capacity to force the real allocation-failure path.
    f.entries.deinit(std.testing.allocator);
    f.entries = .empty;
    try std.testing.expectError(error.OutOfMemory, f.publish(std.testing.failing_allocator, &rows, p, 2));
    try std.testing.expectEqual(@as(usize, 0), f.snapshot().entries.len);
    try std.testing.expect(!f.current(&rows, p, 1));
    try std.testing.expect(f.generation > old);
    try f.publish(std.testing.allocator, &rows, p, 3);
    try std.testing.expect(f.current(&rows, p, 3));
    try std.testing.expect(f.slotAt(f.row(0).?.rect.y) != null);
}
