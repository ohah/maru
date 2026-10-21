//! Fixed-capacity publication of the dock switcher. No labels or host pointers.
const std = @import("std");
const bar = @import("../dock_view_bar.zig");
const tree = @import("../../ui/tree.zig");
pub const root_id: u64 = 0x444f434b00000000;
pub fn slotId(index: usize) u64 {
    return root_id + 1 + index;
}
pub fn actionId(index: usize) u64 {
    return root_id + 0x100 + index;
}
pub const Model = struct {
    rect: bar.Rect,
    grid: bar.Grid,
    active: usize,
    // Opaque semantic action identities, not only the number of slots.
    actions: []const u64,
    pub fn signature(self: Model) u64 {
        var h = std.hash.Wyhash.init(0);
        const fields = [_]u64{ self.rect.x, self.rect.y, self.rect.w, self.rect.h, self.grid.cell_width_px, self.grid.slot_cols, self.active, self.actions.len };
        h.update(std.mem.asBytes(&fields));
        for (self.actions) |id| h.update(std.mem.asBytes(&id));
        return h.final();
    }
};
pub const Frame = struct {
    // Eight action slots leave room for expansion while keeping publication atomic
    // and allocation-free. Unsupported counts retire the frame, never truncate it.
    entries: [1 + bar.slot_count + 8]tree.RectEntry = undefined,
    len: usize = 0,
    generation: u64 = 0,
    stamp: ?u64 = null,
    pub fn invalidate(self: *Frame) void {
        self.len = 0;
        self.stamp = null;
        self.generation +|= 1;
    }
    pub fn current(self: *const Frame, model: Model) bool {
        return self.stamp != null and self.stamp.? == model.signature();
    }
    pub fn snapshot(self: *const Frame) tree.UiRectTree {
        return .{ .entries = self.entries[0..self.len], .generation = self.generation };
    }
    pub fn rect(self: *const Frame, id: u64) ?bar.Rect {
        const t = self.snapshot();
        const r = t.entries[t.find(id) orelse return null].rect;
        return .{ .x = @intFromFloat(r.x), .y = @intFromFloat(r.y), .w = @intFromFloat(r.width), .h = @intFromFloat(r.height) };
    }
    fn append(self: *Frame, id: u64, r: bar.Rect, role: tree.SemanticRole, active: bool) void {
        const root = self.len == 0;
        self.entries[self.len] = .{ .id = id, .parent_index = if (root) null else 0, .kind = if (root) .container else .button, .rect = .{ .x = @floatFromInt(r.x), .y = @floatFromInt(r.y), .width = @floatFromInt(r.w), .height = @floatFromInt(r.h) }, .effective_clip = if (root) null else self.entries[0].rect, .action = if (root) null else .{ .id = id }, .cursor = if (root) .auto else .press, .semantics = .{ .role = role, .label = "", .selected = active, .focusable = !root } };
        self.len += 1;
    }
    pub fn publish(self: *Frame, model: Model) void {
        if (model.rect.w == 0 or model.rect.h == 0 or model.actions.len > 8) {
            self.invalidate();
            return;
        }
        const stamp = model.signature();
        if (self.stamp == null or self.stamp.? != stamp) self.generation +|= 1;
        self.len = 0;
        self.append(root_id, model.rect, .group, false);
        for (0..bar.slot_count) |i| if (bar.slotRect(model.rect, model.grid, i)) |r| {
            self.append(slotId(i), r, .tab, i == model.active);
        };
        for (model.actions, 0..) |_, i| if (bar.actionRect(model.rect, model.grid, model.actions.len, i)) |r| {
            self.append(actionId(i), r, .button, false);
        };
        self.stamp = stamp;
    }
};

test "dock header publication shares grid slots actions and semantic generations" {
    var f: Frame = .{};
    var m: Model = .{ .rect = .{ .x = 10, .y = 20, .w = 325, .h = 24 }, .grid = bar.Grid.fixedCols(8, 4), .active = 0, .actions = &.{ 1, 2 } };
    f.publish(m);
    const generation = f.generation;
    try std.testing.expectEqual(@as(usize, 9), f.len);
    for (0..bar.slot_count) |i| try std.testing.expectEqualDeep(bar.slotRect(m.rect, m.grid, i).?, f.rect(slotId(i)).?);
    for (0..2) |i| try std.testing.expectEqualDeep(bar.actionRect(m.rect, m.grid, 2, i).?, f.rect(actionId(i)).?);
    try std.testing.expectEqual(@as(u32, 330), f.rect(actionId(1)).?.x + f.rect(actionId(1)).?.w);
    f.publish(m);
    try std.testing.expectEqual(generation, f.generation);
    m.active = 1;
    try std.testing.expect(!f.current(m));
    f.publish(m);
    try std.testing.expect(f.generation > generation);
    const old = f.generation;
    m.actions = &.{ 2, 1 };
    try std.testing.expect(!f.current(m));
    f.publish(m);
    try std.testing.expect(f.generation > old);
    m.rect.w = 193;
    f.publish(m);
    try std.testing.expect(f.rect(actionId(0)) == null);
    try std.testing.expect(f.rect(slotId(0)) != null);
    m.rect.w = 0;
    f.publish(m);
    try std.testing.expectEqual(@as(usize, 0), f.len);
    m.rect.w = 325;
    f.publish(m);
    try std.testing.expect(f.current(m));
    m.actions = &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9 };
    f.publish(m);
    try std.testing.expect(f.stamp == null and f.len == 0);
}

test "dock header publication clip parent active and invalidation preserve source identity" {
    const inspect = @import("../../ui/inspection.zig");
    var f: Frame = .{};
    const m: Model = .{ .rect = .{ .x = 100, .y = 40, .w = 325, .h = 24 }, .grid = bar.Grid.fixedCols(8, 4), .active = 2, .actions = &.{ 1, 2 } };
    f.publish(m);
    const t = f.snapshot();
    for (t.entries[1..], 1..) |e, i| {
        try std.testing.expectEqual(@as(?usize, 0), e.parent_index);
        try std.testing.expectEqualDeep(t.entries[0].rect, e.effective_clip.?);
        try std.testing.expectEqual(e.id == slotId(2), e.semantics.?.selected);
        try std.testing.expectEqual(e.id, e.action.?.id);
        try std.testing.expectEqual(tree.CursorHint.press, e.cursor);
        const node = inspect.project(.dock_header, t, i, 0, 0);
        try std.testing.expectEqual(t.generation, inspect.identity(node).generation);
    }
    const n = inspect.project(.dock_header, t, 1, 0, 0);
    const key = inspect.identity(n);
    f.invalidate();
    f.publish(m);
    const fresh = inspect.project(.dock_header, f.snapshot(), 1, 0, 0);
    try std.testing.expect(inspect.resolve(&.{fresh}, key) == null);
    try std.testing.expect(inspect.resolve(&.{fresh}, inspect.identity(fresh)) != null);
}
