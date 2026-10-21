//! Publish actual header DrawCells after lowering. This never reconstructs a
//! breadcrumb from user text: ellipsis and hidden controls follow painted cells.
const std = @import("std");
const maru = @import("maru");
const root = @import("../app_session.zig");
const tabs = @import("tab.zig");
const panes = @import("pane.zig");
const editor = @import("editor/mod.zig");
const component = maru.chrome.components.file_header.details;
const AppSession = root.AppSession;
pub const Reference = struct { term: *root.Term, stamp: u64 };
pub const State = struct {
    frame: component.Frame = .{},
    models: std.ArrayList(component.Model) = .empty,
    refs: std.ArrayList(Reference) = .empty,
    complete: bool = false,
    failed: bool = true,
    pub fn deinit(self: *State, a: std.mem.Allocator) void {
        self.frame.deinit(a);
        self.models.deinit(a);
        self.refs.deinit(a);
    }
};
fn stamp(self: *AppSession, band: AppSession.FileHeaderBand) u64 {
    var h = std.hash.Wyhash.init(self.pane_tab_identity_epoch);
    const r = band.band;
    const values = [_]u64{ band.term.surfaceId(), band.entry.id, @backingInt(band.entry.kind), @backingInt(band.entry.mode), @intFromBool(band.entry.dirty), @intFromBool(band.entry.external_change), @intFromBool(editor.hasConflictRegions(self, band.term)), r.x, r.y, r.w, r.h, self.cell_width_px, self.cell_height_px };
    h.update(std.mem.asBytes(&values));
    h.update(root.bandPathFor(self, band.entry));
    if (band.term.rt.editorDocument().opened) |doc| h.update(std.mem.asBytes(&doc.file.revision));
    if (band.term.rt.editor_selection) |sel| {
        const v = [_]u64{sel.focus};
        h.update(std.mem.asBytes(&v));
    }
    for (band.term.rt.editor_syntax.crumb_bounds.items) |v| h.update(std.mem.asBytes(&v));
    for (band.term.rt.editor_syntax.crumb_syms.items) |v| h.update(std.mem.asBytes(&v));
    return h.final();
}
pub fn begin(self: *AppSession, complete: bool) void {
    const s = &self.file_header_details;
    s.models.clearRetainingCapacity();
    s.refs.clearRetainingCapacity();
    s.complete = false;
    s.failed = !complete or self.tab_drag_order.items.len != 0 or self.backing_height_px == 0;
}
pub fn record(self: *AppSession, band: AppSession.FileHeaderBand, dl: maru.renderer.DrawList) void {
    const s = &self.file_header_details;
    if (s.failed) return;
    const b = band.band;
    if (self.cell_width_px == 0) {
        s.failed = true;
        return;
    }
    const cols: u16 = @intCast(@min(b.w / self.cell_width_px, std.math.maxInt(u16)));
    const header = maru.session.dock_layout.headerCellLayoutWith(cols, band.entry.dirty, band.entry.external_change, editor.hasConflictRegions(self, band.term)) orelse return;
    var m: component.Model = .{ .rect = .{ .x = b.x, .y = b.y, .w = b.w, .h = b.h }, .identity = stamp(self, band) };
    for (dl.cells) |cell| {
        const part: ?component.Part = if (cell.col < header.control_start) .breadcrumb else if (header.dirty_col == cell.col and cell.codepoint == 0x25CF) .modified else if (header.conflict_col == cell.col and cell.codepoint == '!') .reload else if (header.conflict_prev_col == cell.col and cell.codepoint == 0x2191) .previous else if (header.conflict_next_col == cell.col and cell.codepoint == 0x2193) .next else null;
        if (part) |p| {
            const x = b.x + @as(u32, cell.col) * self.cell_width_px;
            const end = @min(b.x + b.w, x + @as(u32, cell.width) * self.cell_width_px);
            if (end <= x) continue;
            const i = @backingInt(p);
            if (m.parts[i]) |old| {
                const right = @max(old.x + old.w, end);
                m.parts[i] = .{ .x = @min(old.x, x), .y = b.y, .w = right - @min(old.x, x), .h = b.h };
            } else m.parts[i] = .{ .x = x, .y = b.y, .w = end - x, .h = b.h };
        }
    }
    s.models.append(self.allocator, m) catch {
        s.failed = true;
        return;
    };
    s.refs.append(self.allocator, .{ .term = band.term, .stamp = m.identity }) catch {
        s.failed = true;
    };
}
pub fn finish(self: *AppSession) void {
    const s = &self.file_header_details;
    if (s.failed) {
        s.frame.invalidate();
        return;
    }
    s.frame.publish(self.allocator, s.models.items, self.pane_tab_identity_epoch) catch return;
    s.complete = true;
}
pub fn current(self: *AppSession, a: std.mem.Allocator) bool {
    const s = &self.file_header_details;
    if (!s.complete or s.frame.stamp == null or self.tab_drag_order.items.len != 0) return false;
    var leaves: std.ArrayList(root.PaneTree.LeafRect) = .empty;
    defer leaves.deinit(a);
    tabs.activeTabLeafRects(self, a, self.termRect(), &leaves) catch return false;
    var i: usize = 0;
    for (leaves.items) |leaf| {
        const band = panes.fileHeaderBandForPane(self, leaf.leaf, leaf.rect) orelse continue;
        if (self.cell_width_px == 0 or band.band.w / self.cell_width_px < 6) continue;
        if (i >= s.refs.items.len or s.refs.items[i].term != band.term or s.refs.items[i].stamp != stamp(self, band)) return false;
        i += 1;
    }
    return i == s.refs.items.len;
}
pub fn actionRect(self: *AppSession, band: AppSession.FileHeaderBand, part: component.Part) ?maru.session.SplitRect {
    if (!current(self, self.allocator)) return switch (part) {
        .reload => if (band.entry.external_change) maru.session.dock_layout.headerConflictRect(band.band, self.cell_width_px, band.entry.dirty) else null,
        .previous, .next => if (editor.hasConflictRegions(self, band.term)) maru.session.dock_layout.headerConflictNavRect(band.band, self.cell_width_px, band.entry.dirty, band.entry.external_change, if (part == .next) .next else .prev) else null,
        else => null,
    };
    for (self.file_header_details.refs.items, 0..) |ref, i| if (ref.term == band.term) {
        const t = self.file_header_details.frame.snapshot();
        const node = t.entries[t.find(component.partId(i, part)) orelse return null];
        const r = node.rect;
        return .{ .x = @intFromFloat(r.x), .y = @intFromFloat(r.y), .w = @intFromFloat(r.width), .h = @intFromFloat(r.height) };
    };
    return null;
}

/// Normal cursor feedback uses exactly the same action rectangles as clicks.
pub fn actionAt(self: *AppSession, x: f64, y: f64) bool {
    var leaves: std.ArrayList(root.PaneTree.LeafRect) = .empty;
    defer leaves.deinit(self.allocator);
    tabs.activeTabLeafRects(self, self.allocator, self.termRect(), &leaves) catch return false;
    for (leaves.items) |leaf| if (panes.fileHeaderBandForPane(self, leaf.leaf, leaf.rect)) |band| {
        for ([_]component.Part{ .reload, .previous, .next }) |part| if (actionRect(self, band, part)) |r| if (maru.session.layout_math.pointInRect(x, y, r)) return true;
    };
    return false;
}
