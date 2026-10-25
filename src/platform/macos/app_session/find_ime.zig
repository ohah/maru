//! Find slots move between views. Identity follows the slot, while a key owns its
//! deep snapshot outside it, so a late callback cannot write into a reused slot.
const std = @import("std");
const maru = @import("maru");
const app = @import("../app_session.zig");
const find = maru.chrome.components.find;
const ops = @import("find.zig");
const tag: u64 = @as(u64, 1) << 59;
var next_identity = std.atomic.Value(u64).init(1);
pub const Owner = struct {
    identity: u64,
    epoch: u64,
    field: find.Focus,
    source: u64,
    target: @FieldType(find.State, "target"),
    side: ?find.DiffSide,
};
fn identity() u64 {
    var value = next_identity.load(.monotonic);
    while (value != std.math.maxInt(u64)) {
        if (next_identity.cmpxchgWeak(value, value + 1, .monotonic, .monotonic)) |actual| value = actual else return value;
    }
    return 0;
}
fn owner(self: *app.AppSession) ?Owner {
    if (!self.surface_initialized or self.ime_terminal_target_id != null) return null;
    ops.syncDiffFind(self);
    if (self.inputFocus() != .find) return null;
    const state = &self.chrome_host.find;
    if (!state.open or !state.input_focused or state.ime_epoch == std.math.maxInt(u64)) return null;
    if (state.ime_identity == 0) state.ime_identity = identity();
    if (state.ime_identity == 0) return null;
    return .{ .identity = state.ime_identity, .epoch = state.ime_epoch, .field = state.effectiveFocus(), .source = @import("pane.zig").activePane(self).activeTerm().surfaceId(), .target = state.target, .side = state.diff_side_shown };
}
pub fn generation(self: *app.AppSession) ?u64 {
    const current = owner(self);
    if (!std.meta.eql(current, self.find_ime_observed)) {
        self.find_ime_sequence +|= 1;
        self.find_ime_observed = current;
    }
    if (current == null or self.find_ime_sequence >= tag) return null;
    const token = tag | self.find_ime_sequence;
    if (self.find_ime_owner) |pin| if (pin != token) return null;
    return token;
}
pub fn stale(self: *app.AppSession) bool {
    return self.find_ime_owner != null and generation(self) == null;
}
pub fn projection(self: *app.AppSession) ?*maru.inline_text_input.DynamicContext {
    _ = generation(self) orelse return null;
    const state = &self.chrome_host.find;
    const role = state.effectiveFocus();
    return state.projection(role).sync(self.allocator, state.field(role));
}
fn changed(self: *app.AppSession, role: find.Focus) void {
    self.dispatchChromeAction(if (role == .find) .find_query_changed else .find_replace_text_changed);
    self.metal_dirty = true;
}
pub fn insert(self: *app.AppSession, bytes: []const u8, replacement: ?maru.inline_text_input.Range) bool {
    if (stale(self)) return true;
    if (self.inputFocus() != .find) return false;
    _ = generation(self) orelse return true;
    const s = &self.chrome_host.find;
    const role = s.effectiveFocus();
    const p = s.projection(role);
    const field = s.field(role);
    const tx = if (self.ime_active) &self.find_ime_transaction else null;
    // Outside a key, publication is immediate; compare canonical bytes through a
    // transaction too, rather than claiming that an identical commit changed query.
    if (tx == null) self.find_ime_transaction.begin(self.allocator, p, field);
    const transaction = tx orelse &self.find_ime_transaction;
    _ = p.insert(self.allocator, field, bytes, replacement, transaction);
    if (tx == null) {
        defer transaction.finish(self.allocator);
        const result = p.finishKey(self.allocator, field, transaction, null, false);
        if (result.changed) changed(self, role);
    }
    self.metal_dirty = true;
    return true;
}
pub fn marked(self: *app.AppSession, bytes: []const u8, selected: maru.inline_text_input.Range, replacement: ?maru.inline_text_input.Range) bool {
    if (stale(self)) return true;
    if (self.inputFocus() != .find) return false;
    _ = generation(self) orelse return true;
    const s = &self.chrome_host.find;
    const role = s.effectiveFocus();
    _ = s.projection(role).marked(self.allocator, s.field(role), bytes, selected, replacement, if (self.ime_active) &self.find_ime_transaction else null);
    if (self.ime_active and bytes.len > 0) self.ime_had_marked = true;
    self.metal_dirty = true;
    return true;
}
pub fn begin(self: *app.AppSession) void {
    finish(self);
    self.find_ime_owner = generation(self);
    if (self.find_ime_owner == null) return;
    self.find_ime_captured = self.find_ime_observed;
    const s = &self.chrome_host.find;
    const role = s.effectiveFocus();
    self.find_ime_transaction.begin(self.allocator, s.projection(role), s.field(role));
}
pub fn finish(self: *app.AppSession) void {
    self.find_ime_transaction.finish(self.allocator);
    self.find_ime_owner = null;
    self.find_ime_captured = null;
}
pub fn end(self: *app.AppSession, event: ?maru.terminal.KeyEvent) bool {
    _ = self.find_ime_owner orelse return false;
    if (generation(self) == null) return true;
    const tx = &self.find_ime_transaction;
    // Internal legacy callers still buffer imeInsert/imeMarked; leave their
    // transaction to the existing engine rather than dropping its text.
    if (!tx.touched and (self.ime_inserted.items.len > 0 or self.ime_marked_changed)) return false;
    const s = &self.chrome_host.find;
    const role = s.effectiveFocus();
    const key: ?find.IMEKey = if (event) |e| if (e.key == .enter) .enter else if (e.key == .backspace) .backspace else if (app.AppSession.shouldReplayAfterCommit(e, false)) .replay else .other else null;
    const result = s.projection(role).finishKey(self.allocator, s.field(role), tx, key, self.ime_did_delete);
    if (result.changed) changed(self, role);
    if (result.replay) if (event) |e| {
        _ = self.handleKeyEvent(e) catch {};
    };
    return result.consumed;
}
/// Settle the source before a view swap, without rediscovering the active view.
/// In particular a rejected key must restore its own source, never the destination.
pub fn beforeTransfer(self: *app.AppSession) void {
    const s = &self.chrome_host.find;
    const capture = self.find_ime_captured orelse return;
    if (capture.identity != s.ime_identity or capture.epoch != s.ime_epoch) return;
    if (self.find_ime_transaction.rejected) s.projection(capture.field).rollback(self.allocator, s.field(capture.field), &self.find_ime_transaction);
}
pub fn commitAll(self: *app.AppSession) bool {
    beforeTransfer(self);
    const s = &self.chrome_host.find;
    const role = s.effectiveFocus();
    const did_change = s.tryCommitField(self.allocator, role) orelse return false;
    if (did_change) changed(self, role);
    return true;
}
