//! Activity ownership and side effects; Unicode/key policy stays in neutral chrome.
const std = @import("std");
const maru = @import("maru");
const app = @import("../app_session.zig");
const ops = @import("agent_activity.zig");
const model = maru.chrome.components.activity_search_ime;
const tag: u64 = @as(u64, 1) << 54;
const Owner = struct { epoch: u64, surface: u64, filter: u3 };
pub const State = struct {
    model: model.State = .{},
    epoch: u64 = 1,
    sequence: u64 = 1,
    observed: ?Owner = null,
    owner: ?u64 = null,
    captured_epoch: u64 = 0,
    pub fn retire(self: *State) void {
        self.epoch +|= 1;
        self.model.projection.invalidate();
    }
};
fn current(self: *app.AppSession) ?Owner {
    if (!self.surface_initialized or self.tabs.items.len == 0 or self.ime_terminal_target_id != null or
        self.inputFocus() != .agent_activity_search or self.agent_activity.ime.epoch == std.math.maxInt(u64)) return null;
    return .{ .epoch = self.agent_activity.ime.epoch, .surface = @import("pane.zig").activePane(self).activeTerm().surfaceId(), .filter = @intCast(@backingInt(self.agent_activity.filter)) };
}
pub fn generation(self: *app.AppSession) ?u64 {
    const s = &self.agent_activity.ime;
    const value = current(self);
    if (!std.meta.eql(value, s.observed)) {
        s.sequence +|= 1;
        s.observed = value;
    }
    if (value == null or s.sequence >= tag) return null;
    const token = tag | s.sequence;
    if (s.owner) |pin| if (pin != token) return null;
    return token;
}
pub fn stale(self: *app.AppSession) bool {
    return self.agent_activity.ime.owner != null and generation(self) == null;
}
pub fn projection(self: *app.AppSession) ?*maru.inline_text_input.DynamicContext {
    _ = generation(self) orelse return null;
    return self.agent_activity.ime.model.projection.sync(self.allocator, &self.agent_activity.search);
}
fn prepareFilter(self: *app.AppSession) bool {
    const s = &self.agent_activity;
    // applyFilter must not reach its legacy show-all/clear-query OOM fallback
    // after a native key has published or cancelled an existing body answer.
    s.hits.ensureTotalCapacity(self.allocator, s.all_hits.items.len) catch return false;
    s.labels.ensureTotalCapacity(self.allocator, s.all_hits.items.len) catch return false;
    return true;
}
fn changed(self: *app.AppSession) void {
    ops.cancelBodySearch(self);
    ops.rebuildFilter(self);
    self.resetCursorBlink();
}
fn settle(self: *app.AppSession, event: ?maru.terminal.KeyEvent) bool {
    const state = &self.agent_activity.ime.model;
    if ((state.projection.context.value.pending or self.ime_did_delete) and !state.transaction.rejected and !prepareFilter(self)) state.reject();
    const key: ?model.Key = if (event) |e| switch (e.key) {
        .enter => .enter,
        .backspace => .backspace,
        else => .other,
    } else null;
    const result = state.end(self.allocator, &self.agent_activity.search, key, self.ime_did_delete);
    if (result.changed) changed(self);
    self.metal_dirty = true;
    return result.consumed;
}
pub fn insert(self: *app.AppSession, bytes: []const u8, replacement: ?model.Range) bool {
    if (stale(self)) return true;
    if (self.ime_terminal_target_id != null or self.inputFocus() != .agent_activity_search) return false;
    _ = generation(self) orelse return true;
    const m = &self.agent_activity.ime.model;
    if (!self.ime_active) m.begin(self.allocator, &self.agent_activity.search);
    _ = m.insert(self.allocator, &self.agent_activity.search, bytes, replacement);
    if (!self.ime_active) {
        defer m.finish(self.allocator);
        _ = settle(self, null);
    }
    self.metal_dirty = true;
    return true;
}
pub fn marked(self: *app.AppSession, bytes: []const u8, selected: model.Range, replacement: ?model.Range) bool {
    if (stale(self)) return true;
    if (self.ime_terminal_target_id != null or self.inputFocus() != .agent_activity_search) return false;
    _ = generation(self) orelse return true;
    const m = &self.agent_activity.ime.model;
    if (!self.ime_active) m.begin(self.allocator, &self.agent_activity.search);
    _ = m.marked(self.allocator, &self.agent_activity.search, bytes, selected, replacement);
    if (!self.ime_active) {
        defer m.finish(self.allocator);
        _ = settle(self, null);
    }
    if (self.ime_active) {
        self.ime_marked_changed = true;
        if (bytes.len > 0) self.ime_had_marked = true;
    }
    self.metal_dirty = true;
    return true;
}
pub fn begin(self: *app.AppSession) void {
    finish(self);
    const s = &self.agent_activity.ime;
    s.owner = generation(self);
    if (s.owner == null) return;
    s.captured_epoch = s.epoch;
    s.model.begin(self.allocator, &self.agent_activity.search);
}
pub fn finish(self: *app.AppSession) void {
    const s = &self.agent_activity.ime;
    s.model.finish(self.allocator);
    s.owner = null;
}
pub fn end(self: *app.AppSession, event: ?maru.terminal.KeyEvent) bool {
    const s = &self.agent_activity.ime;
    if (s.owner == null) return self.ime_terminal_target_id == null and self.inputFocus() == .agent_activity_search and generation(self) == null;
    if (generation(self) == null) {
        if (s.captured_epoch == s.epoch) s.model.abort(self.allocator, &self.agent_activity.search);
        s.model.projection.invalidate();
        return true;
    }
    return settle(self, event);
}
pub fn commitAll(self: *app.AppSession) bool {
    const s = &self.agent_activity;
    if (s.ime.model.transaction.rejected or s.ime.owner != null and s.ime.captured_epoch != s.ime.epoch) return false;
    if (s.search.preedit.items.len == 0 and !s.ime.model.projection.context.value.pending) return true;
    if (!prepareFilter(self)) return false;
    const edited = s.ime.model.commitAll(self.allocator, &s.search) orelse return false;
    if (edited) changed(self);
    self.metal_dirty = true;
    return true;
}
pub fn retire(self: *app.AppSession) void {
    self.agent_activity.ime.retire();
}
