//! Repository-bound native input. Unicode editing/rollback belongs to the neutral
//! TextField model; this host only admits existing message hygiene and reveals edits.
const std = @import("std");
const maru = @import("maru");
const app = @import("../app_session.zig");
const ops = @import("scm_dock.zig");
const model = maru.chrome.components.text_field_ime;
const tag: u64 = @as(u64, 1) << 56;
pub const Owner = struct { epoch: u64, surface: u64 };
pub const State = struct {
    model: model.State = .{ .normalization = .verbatim },
    epoch: u64 = 1,
    sequence: u64 = 1,
    observed: ?Owner = null,
    owner: ?u64 = null,
    captured_epoch: u64 = 0,
    touched: bool = false,
    applied: bool = false,
    before_row: u32 = 0,
    before_reveal: bool = false,
    pub fn deinit(self: *State, a: std.mem.Allocator) void {
        self.model.deinit(a);
    }
};
fn current(self: *app.AppSession) ?Owner {
    if (!self.surface_initialized or self.tabs.items.len == 0 or self.ime_terminal_target_id != null or
        self.inputFocus() != .scm_commit or self.scm_commit_ime.epoch == std.math.maxInt(u64)) return null;
    return .{ .epoch = self.scm_commit_ime.epoch, .surface = @import("pane.zig").activePane(self).activeTerm().surfaceId() };
}
pub fn generation(self: *app.AppSession) ?u64 {
    const st = &self.scm_commit_ime;
    const owner = current(self);
    if (!std.meta.eql(owner, st.observed)) {
        st.sequence +|= 1;
        st.observed = owner;
    }
    if (owner == null or st.sequence >= tag) return null;
    const token = tag | st.sequence;
    if (st.owner) |pin| if (pin != token) return null;
    return token;
}
pub fn stale(self: *app.AppSession) bool {
    return self.scm_commit_ime.owner != null and generation(self) == null;
}
pub fn projection(self: *app.AppSession) ?*maru.inline_text_input.DynamicContext {
    _ = generation(self) orelse return null;
    return self.scm_commit_ime.model.projection(self.allocator, &self.scm_commit_field);
}
pub fn retire(self: *app.AppSession) void {
    self.scm_commit_ime.epoch +|= 1;
    // Keep the old key snapshot/pin until end, but never reuse its pending text.
    self.scm_commit_ime.model.context.value.valid = false;
}
pub fn insert(self: *app.AppSession, bytes: []const u8, replacement: ?model.Range) bool {
    if (stale(self)) return true;
    if (self.inputFocus() != .scm_commit) return false;
    _ = generation(self) orelse return true;
    const st = &self.scm_commit_ime;
    if (self.ime_active) st.touched = true;
    const clean = maru.session.scm_commit_text.sanitizeOwned(self.allocator, bytes) catch {
        _ = st.model.reject();
        return true;
    };
    defer self.allocator.free(clean);
    // Filtering must not turn a forbidden payload into deletion of a selection.
    if (clean.len == 0 and (bytes.len != 0 or replacement == null)) return true;
    if (st.model.insert(self.allocator, &self.scm_commit_field, clean, replacement)) {
        if (self.ime_active) st.applied = true;
        ops.afterEdit(self);
    }
    return true;
}
pub fn marked(self: *app.AppSession, bytes: []const u8, selected: model.Range, replacement: ?model.Range) bool {
    if (stale(self)) return true;
    if (self.inputFocus() != .scm_commit) return false;
    _ = generation(self) orelse return true;
    const st = &self.scm_commit_ime;
    if (self.ime_active) st.touched = true;
    if (st.model.marked(self.allocator, &self.scm_commit_field, bytes, selected, replacement)) {
        if (self.ime_active) {
            st.applied = true;
            if (bytes.len > 0) self.ime_had_marked = true;
        }
        ops.afterEdit(self);
    }
    return true;
}
pub fn begin(self: *app.AppSession) void {
    finish(self);
    const st = &self.scm_commit_ime;
    st.owner = generation(self);
    if (st.owner == null) return;
    st.captured_epoch = st.epoch;
    st.before_row = self.scm_commit_first_row;
    st.before_reveal = self.scm_commit_reveal;
    st.model.begin(self.allocator, &self.scm_commit_field);
}
pub fn finish(self: *app.AppSession) void {
    const st = &self.scm_commit_ime;
    if (st.model.in_key and st.model.context.value.pending) st.model.context.value.valid = false;
    st.model.finish(self.allocator);
    st.owner = null;
    st.touched = false;
    st.applied = false;
}
fn restoreViewport(self: *app.AppSession) void {
    self.scm_commit_first_row = self.scm_commit_ime.before_row;
    self.scm_commit_reveal = self.scm_commit_ime.before_reveal;
    self.metal_dirty = true;
}
pub fn end(self: *app.AppSession, event: ?maru.terminal.KeyEvent) bool {
    const st = &self.scm_commit_ime;
    if (st.owner == null) return self.ime_terminal_target_id == null and self.inputFocus() == .scm_commit and generation(self) == null;
    if (generation(self) == null) {
        // Hidden input still has the same field. A restored destination draft does not.
        if (st.model.rejected and st.captured_epoch == st.epoch) {
            _ = st.model.finishKey(self.allocator, &self.scm_commit_field, null, true, false);
            restoreViewport(self);
        }
        st.model.context.value.valid = false;
        return true;
    }
    const rejected = st.model.rejected;
    const had_commit = st.model.context.value.pending and !rejected;
    const key: ?model.Key = if (event) |e| switch (e.key) {
        .enter => .enter,
        .backspace => .backspace,
        else => .other,
    } else null;
    const consumed = st.model.finishKey(self.allocator, &self.scm_commit_field, key, st.touched, self.ime_did_delete);
    if (rejected) restoreViewport(self) else if (st.applied or consumed and self.ime_did_delete) ops.afterEdit(self);
    if (had_commit) if (event) |e| if (app.AppSession.shouldReplayAfterCommit(e, false)) {
        _ = self.handleKeyEvent(e) catch {};
    };
    return consumed;
}
pub fn commitAll(self: *app.AppSession) bool {
    const st = &self.scm_commit_ime;
    if (st.owner != null and st.captured_epoch != st.epoch) return false;
    if (!st.model.commitAll(self.allocator, &self.scm_commit_field)) return false;
    ops.afterEdit(self);
    return true;
}
