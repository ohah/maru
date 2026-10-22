//! Adapter for shared sidebar header plates. Cell zones and badge-circle/ink
//! precedence remain with the existing sidebar and notification policies.
const maru = @import("maru");
const root = @import("../app_session.zig");
const sidebar = @import("sidebar.zig");
const notification = @import("notification.zig");
const c = maru.chrome.components.sidebar.header;
const AppSession = root.AppSession;
fn ui(r: maru.chrome.draw.Rect) maru.chrome.ui.layout.UiRect {
    return .{ .x = @floatFromInt(r.x), .y = @floatFromInt(r.y), .width = @floatFromInt(r.w), .height = @floatFromInt(r.h) };
}
fn part(region: maru.chrome.components.sidebar.HeaderRegion) ?c.Part {
    return switch (region) {
        .search => .search,
        .view_options => .options,
        .new_workspace => .new_workspace,
        .toggle_sidebar => .toggle,
        .notifications => .notifications,
        .none => null,
    };
}
pub fn model(self: *const AppSession) c.Model {
    var m: c.Model = .{ .viewport = .{ .width = @floatFromInt(self.backing_width_px), .height = @floatFromInt(self.backing_height_px) }, .identity = @intFromBool(self.sidebar_collapsed), .search_active = self.sidebar_search_active };
    if (self.chrome_minimal or self.tabs.items.len == 0 or self.cell_width_px == 0 or self.cell_height_px == 0) return m;
    if (self.sidebar_collapsed) {
        m.icon_clip = .{ .width = m.viewport.width, .height = @floatFromInt(self.titlebar_strip_px) };
        if (self.rawCollapsedToggleRect()) |r| m.rects[@backingInt(c.Part.toggle)] = ui(r);
        if (notification.rawCollapsedNotificationRect(self)) |r| m.rects[@backingInt(c.Part.notifications)] = ui(r);
        return m;
    }
    if (self.sidebar_header_height_px == 0 or self.sidebar_width_px / self.cell_width_px < maru.chrome.components.sidebar.header_icon_min_cols) return m;
    const top = maru.chrome.components.sidebar.headerSearchBandTop(self.sidebar_header_height_px, sidebar.sidebarSearchBandTopPx(self), self.cell_height_px);
    m.icon_clip = .{ .width = @floatFromInt(self.sidebar_width_px), .height = @floatFromInt(top) };
    m.rects[@backingInt(c.Part.search)] = .{ .y = @floatFromInt(top), .width = @floatFromInt(self.sidebar_width_px), .height = @floatFromInt(self.sidebar_header_height_px - top) };
    for ([_]maru.chrome.components.sidebar.HeaderRegion{ .view_options, .new_workspace, .toggle_sidebar, .notifications }) |region| if (sidebar.rawHeaderIconHoverPlateRect(self, region)) |r| {
        m.rects[@backingInt(part(region).?)] = .{ .x = r.x, .y = r.y, .width = r.w, .height = r.h };
    };
    return m;
}
pub fn current(self: *const AppSession) bool {
    return self.sidebar_header_publication.current(model(self));
}
pub fn publish(self: *AppSession) void {
    self.sidebar_header_publication.publish(model(self)) catch {};
}
pub fn invalidate(self: *AppSession) void {
    self.sidebar_header_publication.invalidate();
}
pub fn plate(self: *const AppSession, region: maru.chrome.components.sidebar.HeaderRegion) ?sidebar.HeaderPlateRect {
    if (self.sidebar_collapsed) return null;
    if (!current(self)) return sidebar.rawHeaderIconHoverPlateRect(self, region);
    const p = part(region) orelse return null;
    if (p == .search) return null;
    const r = self.sidebar_header_publication.rect(p) orelse return null;
    return .{ .x = r.x, .y = r.y, .w = r.width, .h = r.height };
}
pub fn collapsed(self: *const AppSession, p: c.Part) ?maru.chrome.draw.Rect {
    if (!self.sidebar_collapsed) return null;
    if (!current(self)) return if (p == .toggle) self.rawCollapsedToggleRect() else notification.rawCollapsedNotificationRect(self);
    const r = self.sidebar_header_publication.rect(p) orelse return null;
    return .{ .x = @intFromFloat(r.x), .y = @intFromFloat(r.y), .w = @intFromFloat(r.width), .h = @intFromFloat(r.height) };
}
pub fn searchContains(self: *const AppSession, x: f64, y: f64) bool {
    if (current(self)) return self.sidebar_header_publication.contains(.search, x, y);
    // Startup uses the same canonical model until the first successful paint.
    var f: c.Frame = .{};
    f.publish(model(self)) catch return false;
    return f.contains(.search, x, y);
}
