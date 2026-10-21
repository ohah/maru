//! Native owner adapter for published pane tab paint/input geometry.
const std = @import("std");
const maru = @import("maru");
const root = @import("../app_session.zig");
const panes = @import("pane.zig");
const tabs = @import("tab.zig");
const component = maru.chrome.components.tabbar;
const published = component.published;
const AppSession = root.AppSession;
pub const Reference = struct { pane: *root.Pane, stamp: u64 };

fn stamp(self: *const AppSession, pane: *const root.Pane, m: component.Metrics) u64 {
    var h = std.hash.Wyhash.init(self.pane_tab_identity_epoch);
    published.hashMetrics(&h, m, pane.terms.items.len);
    for (pane.terms.items, 0..) |term, i| published.hashTab(&h, .{ .identity = term.surfaceId(), .active = i == pane.active_term });
    return h.final();
}
fn rawMetrics(self: *const AppSession, bar: maru.session.SplitRect, pane: *const root.Pane) ?component.Metrics {
    return root.barMetrics(bar, self.cell_width_px, pane.terms.items.len, self.buildChromeTokens().space.tab_width_cols, pane.tab_scroll_cols);
}
pub fn metrics(self: *const AppSession, bar: maru.session.SplitRect, pane: *root.Pane) ?component.Metrics {
    var m = rawMetrics(self, bar, pane) orelse return null;
    if (self.tab_drag_order.items.len != 0 or self.pane_tabs_publication.stamp == null) return m;
    // Compare pointers without dereferencing old references. Only the live caller
    // pane supplies term identities, so a torn-down cache cannot read freed panes.
    for (self.pane_tab_references.items, 0..) |ref, i| {
        if (ref.pane != pane) continue;
        if (ref.stamp == stamp(self, pane, m) and self.pane_tabs_publication.rect(published.rootId(i)) != null)
            m.publication = .{ .frame = &self.pane_tabs_publication, .pane = i };
        break;
    }
    return m;
}
pub fn invalidate(self: *AppSession) void {
    self.pane_tabs_publication.invalidate();
    self.pane_tab_references.clearRetainingCapacity();
}
pub fn publish(self: *AppSession, leaves: []const root.PaneTree.LeafRect, complete: bool) void {
    if (!complete or self.tab_drag_order.items.len != 0 or self.backing_height_px == 0) {
        invalidate(self);
        return;
    }
    publishInner(self, leaves) catch invalidate(self);
}
fn publishInner(self: *AppSession, leaves: []const root.PaneTree.LeafRect) !void {
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var models: std.ArrayList(published.Pane) = .empty;
    try self.pane_tab_references.ensureTotalCapacity(self.allocator, leaves.len);
    self.pane_tab_references.clearRetainingCapacity();
    for (leaves) |leaf| {
        const bar = panes.paneBar(self, leaf.rect, leaf.leaf) orelse continue;
        const m = rawMetrics(self, bar.tabs, leaf.leaf) orelse continue;
        const entries = try a.alloc(published.Tab, leaf.leaf.terms.items.len);
        for (entries, leaf.leaf.terms.items, 0..) |*entry, term, i| entry.* = .{ .identity = term.surfaceId(), .active = i == leaf.leaf.active_term };
        try models.append(a, .{ .metrics = m, .tabs = entries });
        self.pane_tab_references.appendAssumeCapacity(.{ .pane = leaf.leaf, .stamp = stamp(self, leaf.leaf, m) });
    }
    try self.pane_tabs_publication.publish(self.allocator, models.items, self.pane_tab_identity_epoch);
}
/// Inspector validates against live layout/model identity; it never constructs
/// another rect tree. Drag previews keep their existing canonical/preview split.
pub fn current(self: *AppSession, a: std.mem.Allocator) bool {
    if (self.pane_tabs_publication.stamp == null or self.tab_drag_order.items.len != 0) return false;
    var leaves: std.ArrayList(root.PaneTree.LeafRect) = .empty;
    defer leaves.deinit(a);
    tabs.activeTabLeafRects(self, a, self.termRect(), &leaves) catch return false;
    var i: usize = 0;
    for (leaves.items) |leaf| {
        const bar = panes.paneBar(self, leaf.rect, leaf.leaf) orelse continue;
        const m = rawMetrics(self, bar.tabs, leaf.leaf) orelse continue;
        if (i >= self.pane_tab_references.items.len) return false;
        const ref = self.pane_tab_references.items[i];
        if (ref.pane != leaf.leaf or ref.stamp != stamp(self, leaf.leaf, m)) return false;
        i += 1;
    }
    return i == self.pane_tab_references.items.len;
}

pub fn paintControl(self: *AppSession, m: component.Metrics, control: published.Control, bg: u32) bool {
    const p = m.publication orelse return false;
    if (p.frame.rect(published.controlId(p.pane, control))) |r| self.appendSolidQuad(r.x, r.y, r.width, r.height, bg, 2);
    return true;
}
pub fn paintClose(self: *AppSession, m: component.Metrics, tab: usize, bg: u32) bool {
    const p = m.publication orelse return false;
    if (p.frame.rect(published.closeId(p.pane, tab))) |r| self.appendSolidQuad(r.x, r.y, r.width, r.height, bg, 2);
    return true;
}
