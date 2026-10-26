//! Sidebar keeps its committed-only filter. The neutral overlay adapter owns
//! Unicode ranges and rollback; this boundary owns window input identity.
const std = @import("std");
const maru = @import("maru");
const app = @import("../app_session.zig");
const sidebar = @import("sidebar.zig");
const model = maru.chrome.components.overlay_input_ime;
const tag: u64 = @as(u64, 1) << 57;
pub const Owner = struct { epoch: u64, surface: u64 };
pub const State = struct {
    projection: model.Projection = .{},
    transaction: model.Transaction = .{},
    epoch: u64 = 1,
    sequence: u64 = 1,
    observed: ?Owner = null,
    owner: ?u64 = null,
    pub fn deinit(self: *State, a: std.mem.Allocator) void {
        self.transaction.finish(a);
        self.projection.deinit(a);
    }
};
fn current(self: *app.AppSession) ?Owner {
    if (!self.surface_initialized or self.tabs.items.len == 0 or self.ime_terminal_target_id != null or
        self.sidebar_collapsed or self.chrome_minimal or self.sidebar_ime.epoch == std.math.maxInt(u64) or self.inputFocus() != .sidebar_search) return null;
    return .{ .epoch = self.sidebar_ime.epoch, .surface = @import("pane.zig").activePane(self).activeTerm().surfaceId() };
}
pub fn generation(self: *app.AppSession) ?u64 {
    const state = &self.sidebar_ime;
    const value = current(self);
    if (!std.meta.eql(value, state.observed)) {
        state.sequence +|= 1;
        state.observed = value;
    }
    if (value == null or state.sequence >= tag) return null;
    const token = tag | state.sequence;
    if (state.owner) |pin| if (pin != token) return null;
    return token;
}
pub fn stale(self: *app.AppSession) bool {
    return self.sidebar_ime.owner != null and generation(self) == null;
}
pub fn projection(self: *app.AppSession) ?*maru.inline_text_input.DynamicContext {
    _ = generation(self) orelse return null;
    return self.sidebar_ime.projection.sync(self.allocator, &self.sidebar_search_input);
}
fn changed(self: *app.AppSession) void {
    sidebar.rebuildSidebar(self) catch {};
    self.resetCursorBlink();
    self.metal_dirty = true;
}
pub fn insert(self: *app.AppSession, bytes: []const u8, replacement: ?model.Range) bool {
    if (stale(self)) return true;
    if (self.inputFocus() != .sidebar_search) return false;
    _ = generation(self) orelse return true;
    const state = &self.sidebar_ime;
    // Outside-key edits need the same deep rollback as callbacks within a key.
    if (!self.ime_active) state.transaction.begin(self.allocator, &state.projection, &self.sidebar_search_input);
    _ = state.projection.insert(self.allocator, &self.sidebar_search_input, bytes, replacement, &state.transaction);
    if (!self.ime_active) {
        defer state.transaction.finish(self.allocator);
        const result = state.projection.finishKey(self.allocator, &self.sidebar_search_input, &state.transaction, null, false);
        if (result.changed) changed(self);
    }
    self.metal_dirty = true;
    return true;
}
pub fn marked(self: *app.AppSession, bytes: []const u8, selected: model.Range, replacement: ?model.Range) bool {
    if (stale(self)) return true;
    if (self.inputFocus() != .sidebar_search) return false;
    _ = generation(self) orelse return true;
    const state = &self.sidebar_ime;
    if (!self.ime_active) state.transaction.begin(self.allocator, &state.projection, &self.sidebar_search_input);
    _ = state.projection.marked(self.allocator, &self.sidebar_search_input, bytes, selected, replacement, &state.transaction);
    if (!self.ime_active) {
        defer state.transaction.finish(self.allocator);
        const result = state.projection.finishKey(self.allocator, &self.sidebar_search_input, &state.transaction, null, false);
        if (result.changed) changed(self);
    }
    if (self.ime_active and bytes.len > 0) self.ime_had_marked = true;
    self.metal_dirty = true;
    return true;
}
pub fn begin(self: *app.AppSession) void {
    finish(self);
    self.sidebar_ime.owner = generation(self);
    if (self.sidebar_ime.owner == null) return;
    self.sidebar_ime.transaction.begin(self.allocator, &self.sidebar_ime.projection, &self.sidebar_search_input);
}
pub fn finish(self: *app.AppSession) void {
    if (self.sidebar_ime.transaction.active and self.sidebar_ime.projection.context.value.pending) self.sidebar_ime.projection.invalidate();
    self.sidebar_ime.transaction.finish(self.allocator);
    self.sidebar_ime.owner = null;
}
pub fn end(self: *app.AppSession, event: ?maru.terminal.KeyEvent) bool {
    _ = self.sidebar_ime.owner orelse return false;
    if (generation(self) == null) {
        self.sidebar_ime.projection.invalidate();
        return true;
    }
    const state = &self.sidebar_ime;
    const key: ?model.Key = if (event) |e| switch (e.key) {
        .enter => .enter,
        .backspace => .backspace,
        else => .other,
    } else null;
    const result = state.projection.finishKey(self.allocator, &self.sidebar_search_input, &state.transaction, key, self.ime_did_delete);
    if (result.changed) changed(self);
    self.metal_dirty = true;
    return result.consumed;
}
pub fn commitAll(self: *app.AppSession) bool {
    if (self.ime_active and self.sidebar_ime.transaction.rejected) return false;
    const edited = self.sidebar_ime.projection.commitAll(self.allocator, &self.sidebar_search_input) orelse return false;
    if (edited) changed(self);
    self.metal_dirty = true;
    return true;
}
pub fn setActive(self: *app.AppSession, active: bool) void {
    if (self.sidebar_search_active != active) self.sidebar_ime.epoch +|= 1;
    self.sidebar_search_active = active;
}
