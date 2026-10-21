//! Publish actual file mode geometry during paint, then validate live owners
//! before inspection/input. Cached Term references are compared, never dereferenced.
const std = @import("std");
const maru = @import("maru");
const root = @import("../app_session.zig");
const panes = @import("pane.zig");
const tabs = @import("tab.zig");
const editor = @import("editor/mod.zig");
const raw = maru.session.dock_layout;
const component = maru.chrome.components.file_header;
const AppSession = root.AppSession;
pub const Reference = struct { term: *root.Term, stamp: u64 };
fn model(self: *AppSession, band: AppSession.FileHeaderBand) component.Model {
    const r = band.band;
    var h = std.hash.Wyhash.init(self.pane_tab_identity_epoch);
    const nav = editor.hasConflictRegions(self, band.term);
    const fields = [_]u64{ band.term.surfaceId(), band.entry.id, @backingInt(band.entry.kind), @backingInt(band.entry.mode), @intFromBool(band.entry.dirty), @intFromBool(band.entry.external_change), @intFromBool(nav) };
    h.update(std.mem.asBytes(&fields));
    var m: component.Model = .{ .rect = .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h }, .identity = h.final() };
    if (self.cell_width_px == 0) return m;
    for (raw.modesForKind(band.entry.kind)) |d| if (raw.headerModeRectWith(r, self.cell_width_px, band.entry.kind, d.mode, band.entry.dirty, band.entry.external_change, nav)) |rect| {
        m.controls[m.count] = .{ .tag = @backingInt(d.mode), .rect = .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h }, .active = band.entry.mode == d.mode };
        m.count += 1;
    };
    return m;
}
pub fn invalidate(self: *AppSession) void {
    self.file_header_publication.invalidate();
    self.file_header_references.clearRetainingCapacity();
}
pub fn publish(self: *AppSession, leaves: []const root.PaneTree.LeafRect, complete: bool) void {
    if (!complete or self.tab_drag_order.items.len != 0 or self.backing_height_px == 0) {
        invalidate(self);
        return;
    }
    inner(self, leaves) catch invalidate(self);
}
fn inner(self: *AppSession, leaves: []const root.PaneTree.LeafRect) !void {
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var models: std.ArrayList(component.Model) = .empty;
    try self.file_header_references.ensureTotalCapacity(self.allocator, leaves.len);
    self.file_header_references.clearRetainingCapacity();
    for (leaves) |leaf| {
        const band = panes.fileHeaderBandForPane(self, leaf.leaf, leaf.rect) orelse continue;
        const m = model(self, band);
        if (m.count == 0) continue;
        try models.append(a, m);
        self.file_header_references.appendAssumeCapacity(.{ .term = band.term, .stamp = component.signature(&.{m}, self.pane_tab_identity_epoch) });
    }
    try self.file_header_publication.publish(self.allocator, models.items, self.pane_tab_identity_epoch);
}
pub fn current(self: *AppSession, a: std.mem.Allocator) bool {
    if (self.file_header_publication.stamp == null or self.tab_drag_order.items.len != 0) return false;
    var leaves: std.ArrayList(root.PaneTree.LeafRect) = .empty;
    defer leaves.deinit(a);
    tabs.activeTabLeafRects(self, a, self.termRect(), &leaves) catch return false;
    var i: usize = 0;
    for (leaves.items) |leaf| {
        const band = panes.fileHeaderBandForPane(self, leaf.leaf, leaf.rect) orelse continue;
        const m = model(self, band);
        if (m.count == 0) continue;
        if (i >= self.file_header_references.items.len) return false;
        const ref = self.file_header_references.items[i];
        if (ref.term != band.term or ref.stamp != component.signature(&.{m}, self.pane_tab_identity_epoch)) return false;
        i += 1;
    }
    return i == self.file_header_references.items.len;
}
pub fn modeRect(self: *AppSession, band: AppSession.FileHeaderBand, mode: maru.session.dock_panel.Mode) ?maru.session.SplitRect {
    const m = model(self, band);
    if (self.file_header_publication.stamp != null and self.tab_drag_order.items.len == 0) for (self.file_header_references.items, 0..) |ref, i| {
        if (ref.term != band.term) continue;
        if (ref.stamp == component.signature(&.{m}, self.pane_tab_identity_epoch)) {
            const r = self.file_header_publication.rect(component.controlId(i, @backingInt(mode))) orelse return null;
            return .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h };
        }
        break;
    };
    // Startup/layout changes retain existing behavior until paint publishes again.
    for (m.controls[0..m.count]) |c| if (c.tag == @backingInt(mode)) return .{ .x = c.rect.x, .y = c.rect.y, .w = c.rect.w, .h = c.rect.h };
    return null;
}
pub fn modeAt(self: *AppSession, band: AppSession.FileHeaderBand, x: f64, y: f64) ?maru.session.dock_panel.Mode {
    for (raw.modesForKind(band.entry.kind)) |d| if (modeRect(self, band, d.mode)) |r| if (maru.session.layout_math.pointInRect(x, y, r)) return d.mode;
    return null;
}
