//! Owner-window adapter for the neutral published-tree inspection model.
const std = @import("std");
const maru = @import("maru");
const root = @import("../app_session.zig");
const ops = @import("inspector.zig");
const dock = @import("dock.zig");
const sidebar = @import("sidebar.zig");
const status = @import("status_bar.zig");
const inspect = maru.chrome.ui.inspection;
const tree = maru.chrome.ui.tree;
const AppSession = root.AppSession;

fn append(a: std.mem.Allocator, out: *std.ArrayList(inspect.Node), source: inspect.Source, t: tree.UiRectTree, dx: f32, dy: f32) !void {
    for (t.entries, 0..) |_, i| {
        // Bound the control-plane report; retain the topmost published nodes.
        // Identities use source/ID, so this compaction cannot retarget selection.
        if (out.items.len == 512) _ = out.orderedRemove(0);
        try out.append(a, inspect.project(source, t, i, dx, dy));
    }
}
/// Only published, currently visible trees are exposed. No labels or user text are
/// copied: inspection identity and geometry remain safe to export anonymously.
pub fn nodes(self: *AppSession, a: std.mem.Allocator) ![]const inspect.Node {
    var out: std.ArrayList(inspect.Node) = .empty;
    if (self.anyModalOverlayOpen() or !self.surface_initialized or self.tabs.items.len == 0) return out.items;
    if (sidebar.sidebarPublicationCurrent(self)) {
        const t = self.sidebar_publication.snapshot();
        for (t.entries, 0..) |entry, i| {
            if (entry.semantics == null) continue;
            if (out.items.len == 512) _ = out.orderedRemove(0);
            try out.append(a, inspect.project(.sidebar, t, i, 0, 0));
        }
    }
    try append(a, &out, .sidebar_scroll, sidebar.sidebarScrollTree(self), 0, 0);
    if (root.inspector_tabs_ops.current(self, a)) try append(a, &out, .pane_tabs, self.pane_tabs_publication.snapshot(), 0, 0);
    if (root.inspector_file_header_details_ops.current(self, a)) try append(a, &out, .file_header_details, self.file_header_details.frame.snapshot(), 0, 0);
    if (root.inspector_file_header_ops.current(self, a)) try append(a, &out, .file_header, self.file_header_publication.snapshot(), 0, 0);
    try append(a, &out, .pane_divider, .{ .entries = self.divider_entry_scratch.items, .generation = self.divider_snapshot_generation }, 0, 0);
    if (dock.dockVisible(self)) {
        if (dock.headerPublicationCurrent(self)) try append(a, &out, .dock_header, self.dock_header_publication.snapshot(), 0, 0);
        const content = dock.dockGeometry(self).tree_content;
        switch (self.dock.view) {
            .explorer => if (self.file_tree_published_generation == self.file_tree_projection_generation) {
                try append(a, &out, .file_tree, .{ .entries = self.file_tree_entries.items, .generation = self.file_tree_published_generation }, 0, 0);
            },
            .source_control => try append(a, &out, .scm, .{ .entries = self.scm_dock_entries.items, .generation = self.scm_dock_snapshot_generation }, @floatFromInt(content.x), @floatFromInt(content.y)),
            .agent_sessions => try append(a, &out, .agent_sessions, .{ .entries = self.agent_session_dock_entries.items, .generation = self.agent_session_dock_snapshot_generation }, @floatFromInt(content.x), @floatFromInt(content.y)),
            else => {},
        }
    }
    try append(a, &out, .status_bar, status.statusBarTree(self), 0, 0);
    return out.items;
}
pub fn snapshot(self: *AppSession, a: std.mem.Allocator, window: ?u64) error{OutOfMemory}!std.json.Value {
    const all = try nodes(self, a);
    const branches = try inspect.hierarchy(a, all, self.inspector.collapsed[0..self.inspector.collapsed_len], self.inspector.query[0..self.inspector.query_len]);
    const dto = .{ .tree = branches, .collapsed = self.inspector.collapsed[0..self.inspector.collapsed_len], .query = self.inspector.query[0..self.inspector.query_len], .window = window, .coordinate_space = "owner_window_backing_pixels", .node_limit = 512, .limit_reached = all.len == 512, .picking = self.inspector.picking, .hovered = inspect.resolve(all, self.inspector.picker_hover), .selected = inspect.resolve(all, self.inspector.picker_selected), .coverage = "published file breadcrumb/modified/reload/conflict navigation and mode selectors, dock view switcher/actions, pane tabs/close/plus/scroll controls, sidebar workspace cards/groups, status bar, sidebar scroll, pane dividers and visible file/SCM/session dock trees; unpublished chrome, terminal cells and web DOM unsupported", .nodes = all };
    const bytes = try std.json.Stringify.valueAlloc(a, dto, .{});
    const parsed = std.json.parseFromSlice(std.json.Value, a, bytes, .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable, // Stringify generated this DTO in this call.
    };
    return parsed.value;
}
/// Tree interaction is read-only and validates the rendered identity against the
/// current publication before changing selection or expansion.
pub fn select(self: *AppSession, key: inspect.Key, disclosure: bool) void {
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const all = nodes(self, arena.allocator()) catch return;
    const node = inspect.resolve(all, key) orelse return;
    const s = &self.inspector;
    // Drop vanished publications before storing another key. Otherwise repeated
    // refresh/collapse cycles could fill the bounded state with dead identities.
    var retained: usize = 0;
    for (s.collapsed[0..s.collapsed_len]) |k| {
        if (inspect.resolve(all, k) != null) {
            s.collapsed[retained] = k;
            retained += 1;
        }
    }
    s.collapsed_len = retained;
    if (disclosure) {
        var found: ?usize = null;
        for (s.collapsed[0..s.collapsed_len], 0..) |k, i| if (inspect.same(k, key)) {
            found = i;
            break;
        };
        if (found) |i| {
            s.collapsed_len -= 1;
            s.collapsed[i] = s.collapsed[s.collapsed_len];
        } else if (s.collapsed_len < s.collapsed.len) {
            s.collapsed[s.collapsed_len] = inspect.identity(node);
            s.collapsed_len += 1;
        }
    } else {
        s.picker_selected = inspect.identity(node);
        s.selected_field_len = 0;
        // Selecting in the tree completes inspection just like selecting on the
        // owner. Leaving Pick active would hide this selection behind hover.
        cancel(self);
    }
    // An explicit tree interaction requests a fresh sample even while Paused,
    // just like Refresh. Background polling remains paused afterwards.
    s.refresh = true;
    ops.poll(self);
    self.metal_dirty = true;
}
fn reveal(self: *AppSession) void {
    const s = &self.inspector;
    const selected = s.picker_selected orelse return;
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const all = nodes(self, a) catch return;
    const expanded = inspect.hierarchy(a, all, &.{}, "") catch return;
    var ancestor: ?inspect.Key = selected;
    while (ancestor) |key| {
        var i: usize = 0;
        while (i < s.collapsed_len) {
            if (inspect.same(s.collapsed[i], key)) {
                s.collapsed_len -= 1;
                s.collapsed[i] = s.collapsed[s.collapsed_len];
            } else i += 1;
        }
        ancestor = null;
        for (expanded) |branch| if (inspect.same(branch.key, key)) {
            ancestor = branch.parent;
            break;
        };
    }
    const visible = inspect.hierarchy(a, all, s.collapsed[0..s.collapsed_len], "") catch return;
    for (visible, 0..) |branch, i| if (inspect.same(branch.key, selected)) {
        s.offset = i;
        break;
    };
}
pub fn toggle(self: *AppSession) void {
    self.inspector.picking = !self.inspector.picking;
    self.inspector.picker_hover = null;
    self.inspector.tab = .elements;
    self.inspector.query_len = 0;
    self.inspector.offset = 0;
    // Pick is explicitly live: it resumes a paused sample rather than mutating it
    // silently while the panel still says Paused.
    if (self.inspector.picking) {
        self.inspector.paused = false;
        self.clearAllHover();
    }
    self.inspector.refresh = true;
    ops.poll(self);
    self.metal_dirty = true;
}
pub fn cancel(self: *AppSession) void {
    self.inspector.picking = false;
    self.inspector.picker_hover = null;
    self.inspector.picker_capture = false;
    self.metal_dirty = true;
}
pub fn hover(self: *AppSession, x: f64, y: f64) bool {
    if (!self.inspector.picking) return false;
    if (!ops.visible(self) or self.anyModalOverlayOpen()) {
        cancel(self);
        return false;
    }
    if (ops.contains(self, x, y)) {
        if (self.inspector.picker_hover != null) {
            self.inspector.picker_hover = null;
            self.inspector.refresh = true;
            ops.poll(self);
            self.metal_dirty = true;
        }
        return false;
    }
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const all = nodes(self, arena.allocator()) catch return true;
    const n = inspect.pick(all, x, y);
    self.inspector.picker_hover = if (n) |node| inspect.identity(node) else null;
    self.inspector.refresh = true;
    ops.poll(self);
    self.metal_dirty = true;
    return true;
}
pub fn pointer(self: *AppSession, kind: i32, button: i32, x: f64, y: f64) bool {
    if (self.inspector.picker_capture) {
        if (kind == 1) {
            // A lost up (for example window deactivation) cannot swallow the next
            // independent click. The selected gesture owns only its drag/up.
            self.inspector.picker_capture = false;
        } else {
            if (kind == 3) self.inspector.picker_capture = false;
            return true;
        }
    }
    if (self.anyModalOverlayOpen()) {
        if (self.inspector.picking) cancel(self);
        return false;
    }
    if (!self.inspector.picking or !ops.visible(self) or ops.contains(self, x, y)) return false;
    _ = hover(self, x, y);
    if (kind == 1 and button == 0) {
        self.inspector.picker_selected = self.inspector.picker_hover;
        self.inspector.query_len = 0;
        reveal(self);
        cancel(self);
        self.inspector.picker_capture = true;
        self.swallow_multi_click = true;
        self.inspector.refresh = true;
        ops.poll(self);
    }
    return true;
}
/// Resolve identity against today's tree, never keep borrowed entries across frames.
pub fn collectOutline(self: *AppSession) void {
    if (!ops.visible(self) or self.anyModalOverlayOpen()) {
        if (self.inspector.picking) cancel(self);
        return;
    }
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const all = nodes(self, a) catch return;
    const n = inspect.resolve(all, if (self.inspector.picking) self.inspector.picker_hover else self.inspector.picker_selected) orelse return;
    const r = n.visible_rect;
    if (r.width < 1 or r.height < 1 or !inspect.contains(r, r.x, r.y)) return;
    const w: u32 = @intFromFloat(r.width);
    const h: u32 = @intFromFloat(r.height);
    const x: i32 = @intFromFloat(r.x);
    const y: i32 = @intFromFloat(r.y);
    const thick = @min(@min(w, h), @max(@as(u32, 1), self.scale_milli / 500));
    const Rect = maru.chrome.draw.Rect;
    const borders = [_]Rect{ .{ .x = x, .y = y, .w = w, .h = thick }, .{ .x = x, .y = y + @as(i32, @intCast(h - thick)), .w = w, .h = thick }, .{ .x = x, .y = y, .w = thick, .h = h }, .{ .x = x + @as(i32, @intCast(w - thick)), .y = y, .w = thick, .h = h } };
    var draw_ops: [4]maru.chrome.draw.Op = undefined;
    for (borders, 0..) |b, i| draw_ops[i] = .{ .quad = .{ .rect = b, .fill_role = .accent_bar } };
    const draws = [_]maru.chrome.ChromeDraw{.{ .layer = .pane_overlay, .ops = &draw_ops }};
    const tokens = self.buildChromeTokens();
    root.chrome_draw_lowering.appendBackgroundQuads(self.allocator, &draws, &tokens, 0, 0, &self.gpu_quads, root.chrome_draw_lowering.layers.over);
}
