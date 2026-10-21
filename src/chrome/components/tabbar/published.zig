//! Published pane tab geometry. Labels and native pane pointers stay in the host.
//! Contract: docs/plans/ui-inspector.md and docs/chrome-interaction-migration.md.
const std = @import("std");
const tabbar = @import("../tabbar.zig");
const tree = @import("../../ui/tree.zig");
const layout = @import("../../ui/layout.zig");

pub const Tab = struct { identity: u64, active: bool };
pub const Pane = struct { metrics: tabbar.Metrics, tabs: []const Tab };
pub const Control = enum { plus, left, right };
pub fn rootId(pane: usize) u64 {
    return 0x5442000000000000 + @as(u64, @intCast(pane)) * 0x100000000;
}
pub fn tabId(pane: usize, index: usize) u64 {
    return rootId(pane) + 1 + @as(u64, @intCast(index)) * 2;
}
pub fn closeId(pane: usize, index: usize) u64 {
    return tabId(pane, index) + 1;
}
pub fn controlId(pane: usize, control: Control) u64 {
    return rootId(pane) + 0xfffffffc + @backingInt(control);
}
pub fn hashMetrics(h: *std.hash.Wyhash, m: tabbar.Metrics, count: usize) void {
    const values = [_]u64{ m.bar_x, m.bar_y, m.bar_w, m.bar_h, m.cell_width_px, m.cols, m.tab_cols, m.tab_w, m.scroll_cols, @intFromBool(m.has_scroll), m.tab_count, count };
    h.update(std.mem.asBytes(&values));
}
pub fn hashTab(h: *std.hash.Wyhash, t: Tab) void {
    const value = [_]u64{ t.identity, @intFromBool(t.active) };
    h.update(std.mem.asBytes(&value));
}
pub fn signature(panes: []const Pane, epoch: u64) u64 {
    var h = std.hash.Wyhash.init(epoch);
    for (panes) |p| {
        hashMetrics(&h, p.metrics, p.tabs.len);
        for (p.tabs) |t| hashTab(&h, t);
    }
    return h.final();
}
pub const Frame = struct {
    entries: std.ArrayList(tree.RectEntry) = .empty,
    generation: u64 = 0,
    stamp: ?u64 = null,
    pub fn deinit(self: *Frame, a: std.mem.Allocator) void {
        self.entries.deinit(a);
        self.* = .{};
    }
    pub fn invalidate(self: *Frame) void {
        self.entries.clearRetainingCapacity();
        self.stamp = null;
        self.generation +|= 1;
    }
    pub fn snapshot(self: *const Frame) tree.UiRectTree {
        return .{ .entries = self.entries.items, .generation = self.generation };
    }
    pub fn rect(self: *const Frame, id: u64) ?layout.UiRect {
        const t = self.snapshot();
        return t.entries[t.find(id) orelse return null].rect;
    }
    pub fn current(self: *const Frame, panes: []const Pane, epoch: u64) bool {
        return self.stamp != null and self.stamp.? == signature(panes, epoch);
    }
    fn append(self: *Frame, a: std.mem.Allocator, id: u64, parent: ?usize, r: layout.UiRect, clip: layout.UiRect, role: tree.SemanticRole, selected: bool, actionable: bool) !void {
        try self.entries.append(a, .{ .id = id, .parent_index = parent, .kind = if (role == .tab) .card else if (actionable) .button else .container, .rect = r, .effective_clip = clip, .action = if (actionable) .{ .id = id } else null, .cursor = if (actionable) .press else .auto, .semantics = .{ .role = role, .label = "", .selected = selected, .focusable = actionable } });
    }
    /// Publish only a completed frame; allocation failure retires the old tree.
    pub fn publish(self: *Frame, a: std.mem.Allocator, panes: []const Pane, epoch: u64) !void {
        self.publishInner(a, panes, epoch) catch |err| {
            self.invalidate();
            return err;
        };
    }
    fn publishInner(self: *Frame, a: std.mem.Allocator, panes: []const Pane, epoch: u64) !void {
        const stamp = signature(panes, epoch);
        if (self.stamp == null or self.stamp.? != stamp) self.generation +|= 1;
        self.entries.clearRetainingCapacity();
        self.stamp = null;
        for (panes, 0..) |p, pi| {
            const m = p.metrics;
            if (m.bar_w == 0 or m.bar_h == 0 or m.cell_width_px == 0 or m.tab_w == 0) continue;
            const clip: layout.UiRect = .{ .x = @floatFromInt(m.bar_x), .y = @floatFromInt(m.bar_y), .width = @floatFromInt(m.bar_w), .height = @floatFromInt(m.bar_h) };
            const root = self.entries.items.len;
            try self.append(a, rootId(pi), null, clip, clip, .group, false, false);
            for (p.tabs, 0..) |tab, ti| {
                const seg = m.rawSegOf(ti);
                if (seg.end_px <= seg.start_px) continue;
                var r = clip;
                r.x = @floatCast(seg.start_px);
                r.width = @floatCast(seg.end_px - seg.start_px);
                const parent = self.entries.items.len;
                try self.append(a, tabId(pi, ti), root, r, clip, .tab, tab.active, true);
                if (seg.has_close) {
                    r.x = @floatCast(seg.close_start_px);
                    r.width = @floatCast(seg.end_px - seg.close_start_px);
                    try self.append(a, closeId(pi, ti), parent, r, clip, .button, false, true);
                }
            }
            for ([_]Control{ .plus, .left, .right }) |control| {
                if (control == .plus and !m.hasPlusZone()) continue;
                if (control != .plus and !m.has_scroll) continue;
                const col = switch (control) {
                    .plus => m.plusZoneStart(),
                    .left => m.tab_cols,
                    .right => m.tab_cols + tabbar.Metrics.scroll_button_cols,
                };
                const cols = if (control == .plus) tabbar.Metrics.plus_button_cols else tabbar.Metrics.scroll_button_cols;
                const end = @min(col + cols, m.cols);
                if (end <= col) continue;
                var r = clip;
                r.x += @floatFromInt(col * m.cell_width_px);
                r.width = @floatFromInt((end - col) * m.cell_width_px);
                r = layout.intersectRect(r, clip);
                if (r.width > 0) try self.append(a, controlId(pi, control), root, r, clip, .button, false, true);
            }
        }
        self.stamp = stamp;
    }
};

test "pane tab publication shares scrolled segments close and controls" {
    const a = std.testing.allocator;
    const m: tabbar.Metrics = .{ .bar_x = 100, .bar_y = 24, .bar_w = 400, .bar_h = 30, .cell_width_px = 10, .cols = 40, .tab_cols = 31, .tab_w = 10, .scroll_cols = 10, .has_scroll = true, .tab_count = 5 };
    const tabs = [_]Tab{ .{ .identity = 10, .active = false }, .{ .identity = 11, .active = true }, .{ .identity = 12, .active = false }, .{ .identity = 13, .active = false }, .{ .identity = 14, .active = false } };
    const panes = [_]Pane{ .{ .metrics = m, .tabs = &tabs }, .{ .metrics = m, .tabs = &tabs } };
    var f: Frame = .{};
    defer f.deinit(a);
    try f.publish(a, &panes, 1);
    try std.testing.expect(f.rect(tabId(0, 0)) == null);
    const t = f.snapshot();
    const r = f.rect(tabId(0, 1)).?;
    try std.testing.expectEqualDeep(r, layout.intersectRect(r, t.entries[t.find(tabId(0, 1)).?].effective_clip.?));
    try std.testing.expect(t.entries[t.find(tabId(0, 1)).?].semantics.?.selected);
    try std.testing.expect(!t.entries[t.find(tabId(0, 2)).?].semantics.?.selected);
    const seg = m.rawSegOf(1);
    try std.testing.expectEqual(@as(f32, @floatCast(seg.start_px)), r.x);
    try std.testing.expectEqual(@as(f32, @floatCast(seg.end_px - seg.start_px)), r.width);
    try std.testing.expectEqual(@as(f32, @floatCast(seg.close_start_px)), f.rect(closeId(0, 1)).?.x);
    try std.testing.expectEqual(tabId(0, 1), t.entries[t.entries[t.find(closeId(0, 1)).?].parent_index.?].id);
    try std.testing.expect(f.rect(controlId(0, .plus)) != null);
    try std.testing.expect(f.rect(controlId(0, .left)) != null);
    try std.testing.expect(f.rect(controlId(0, .right)) != null);
    try std.testing.expect(tabId(0, 1) != tabId(1, 1));
    try std.testing.expect(f.rect(closeId(0, 4)) == null); // one visible column cannot close a neighboring tab
    const gen = f.generation;
    try f.publish(a, &panes, 1);
    try std.testing.expectEqual(gen, f.generation);
    try std.testing.expect(!f.current(&panes, 2));
    var identity_changed = panes;
    var replacement = tabs;
    replacement[1].identity = 99;
    identity_changed[0].tabs = &replacement;
    try std.testing.expect(!f.current(&identity_changed, 1));
    var changed = tabs;
    std.mem.swap(Tab, &changed[1], &changed[2]);
    try std.testing.expect(!f.current(&.{.{ .metrics = m, .tabs = &changed }}, 1));
    for (t.entries) |entry| try std.testing.expectEqualStrings("", entry.semantics.?.label);
    var narrow = m;
    narrow.has_scroll = false;
    narrow.tab_cols = 39;
    narrow.tab_count = 4;
    narrow.bar_w = 405;
    try f.publish(a, &.{.{ .metrics = narrow, .tabs = &tabs }}, 2);
    try std.testing.expectEqual(@as(f32, 10), f.rect(controlId(0, .plus)).?.width);
}

test "pane tab publication OOM retires tree and recovers" {
    const a = std.testing.allocator;
    const p = [_]Pane{.{ .metrics = .{ .bar_x = 0, .bar_y = 0, .bar_w = 100, .bar_h = 30, .cell_width_px = 10, .cols = 10, .tab_cols = 7, .tab_w = 7, .tab_count = 1 }, .tabs = &.{.{ .identity = 1, .active = true }} }};
    var f: Frame = .{};
    defer f.deinit(a);
    try f.publish(a, &p, 1);
    f.entries.deinit(a);
    f.entries = .empty;
    try std.testing.expectError(error.OutOfMemory, f.publish(std.testing.failing_allocator, &p, 2));
    try std.testing.expect(f.snapshot().entries.len == 0 and !f.current(&p, 1));
    try f.publish(a, &p, 3);
    try std.testing.expect(f.rect(tabId(0, 0)) != null);
}

test "pane tab input and paint metrics consume published geometry" {
    const a = std.testing.allocator;
    var m: tabbar.Metrics = .{ .bar_x = 100, .bar_y = 20, .bar_w = 200, .bar_h = 30, .cell_width_px = 10, .cols = 20, .tab_cols = 17, .tab_w = 10, .tab_count = 1 };
    const tabs = [_]Tab{.{ .identity = 1, .active = true }};
    var f: Frame = .{};
    defer f.deinit(a);
    try f.publish(a, &.{.{ .metrics = m, .tabs = &tabs }}, 1);
    m.publication = .{ .frame = &f, .pane = 0 };
    try std.testing.expectEqualDeep(m.rawSegOf(0), m.segOf(0));
    const t = f.snapshot();
    f.entries.items[t.find(tabId(0, 0)).?].rect.x += 5;
    f.entries.items[t.find(tabId(0, 0)).?].rect.width -= 5;
    f.entries.items[t.find(closeId(0, 0)).?].rect.x += 3;
    f.entries.items[t.find(controlId(0, .plus)).?].rect.x += 7;
    try std.testing.expectEqual(m.rawSegOf(0).start_px + 5, m.segOf(0).start_px);
    try std.testing.expect(!m.inCloseZone(0, m.rawSegOf(0).close_start_px));
    try std.testing.expect(m.inCloseZone(0, m.rawSegOf(0).close_start_px + 3));
    try std.testing.expect(!m.inPlusZone(200));
    try std.testing.expect(m.inPlusZone(207));
    try std.testing.expect(!m.inPlusZone(std.math.nan(f64)));
}

test "pane tab partial OOM and reused inspection identity fail closed" {
    const a = std.testing.allocator;
    const inspect = @import("../../ui/inspection.zig");
    const m: tabbar.Metrics = .{ .bar_x = 100, .bar_y = 20, .bar_w = 200, .bar_h = 30, .cell_width_px = 10, .cols = 20, .tab_cols = 17, .tab_w = 5, .tab_count = 4 };
    const ts = [_]Tab{ .{ .identity = 1, .active = true }, .{ .identity = 2, .active = false }, .{ .identity = 3, .active = false }, .{ .identity = 4, .active = false } };
    const ps = [_]Pane{ .{ .metrics = m, .tabs = &ts }, .{ .metrics = m, .tabs = &ts } };
    var f: Frame = .{};
    defer f.deinit(a);
    try f.publish(a, &ps, 1);
    const first = f.snapshot();
    const key = inspect.identity(inspect.project(.pane_tabs, first, first.find(tabId(0, 0)).?, 0, 0));
    try std.testing.expectEqual(f.generation, key.generation);
    try f.publish(a, &ps, 2);
    const second = f.snapshot();
    try std.testing.expect(inspect.resolve(&.{inspect.project(.pane_tabs, second, second.find(key.id).?, 0, 0)}, key) == null);
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 1, .resize_fail_index = 0 });
    var partial: Frame = .{};
    defer partial.deinit(failing.allocator());
    try std.testing.expectError(error.OutOfMemory, partial.publish(failing.allocator(), &ps, 1));
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 0), partial.snapshot().entries.len);
    try std.testing.expect(partial.stamp == null);
}
