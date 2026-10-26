//! Inspector input ownership and publication; fixed range/key policy is neutral.
const std = @import("std");
const maru = @import("maru");
const app = @import("../app_session.zig");
const ops = @import("inspector.zig");
const model = maru.chrome.components.inspector.search_ime;
const tag: u64 = @as(u64, 1) << 55;
const Owner = struct { epoch: u64, surface: u64, placement: u3, tab: u3, window: ?u64, focused_window: bool };
pub const State = struct {
    tx: model.State = .{},
    epoch: u64 = 1,
    sequence: u64 = 1,
    observed: ?Owner = null,
    owner: ?u64 = null,
    captured_epoch: u64 = 0,
    before_offset: usize = 0,
    before_selected: [128]u8 = undefined,
    before_selected_len: usize = 0,
};
fn current(self: *app.AppSession) ?Owner {
    if (!self.surface_initialized or self.tabs.items.len == 0 or self.ime_terminal_target_id != null or
        self.inputFocus() != .inspector or self.inspector.ime.epoch == std.math.maxInt(u64)) return null;
    return .{ .epoch = self.inspector.ime.epoch, .surface = @import("pane.zig").activePane(self).activeTerm().surfaceId(), .placement = @intCast(@backingInt(self.inspector.presentation.placement)), .tab = @intCast(@backingInt(self.inspector.tab)), .window = self.inspector.window_id, .focused_window = self.inspector.window_focused };
}
pub fn generation(self: *app.AppSession) ?u64 {
    const s = &self.inspector.ime;
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
    return self.inspector.ime.owner != null and generation(self) == null;
}
pub fn retire(self: *app.AppSession) void {
    self.inspector.ime.epoch +|= 1;
    self.inspector.ime.tx.context.valid = false;
}
pub fn projection(self: *app.AppSession) ?*model.Context {
    _ = generation(self) orelse return null;
    const s = &self.inspector;
    return s.ime.tx.sync(s.query[0..s.query_len], s.preedit[0..s.preedit_len]);
}
fn publish(self: *app.AppSession, result: model.Result) void {
    const s = &self.inspector;
    const c = &s.ime.tx.context;
    if (result != .none) {
        s.query_len = c.committedLength();
        c.copyCommitted(s.query[0..s.query_len]);
        if (result == .commit) c.accepted(s.query[0..s.query_len]);
    }
    const preedit = c.preedit();
    @memcpy(s.preedit[0..preedit.len], preedit);
    s.preedit_len = preedit.len;
    if (result == .rollback) {
        s.offset = s.ime.before_offset;
        s.selected_field_len = s.ime.before_selected_len;
        @memcpy(s.selected_field[0..s.selected_field_len], s.ime.before_selected[0..s.selected_field_len]);
    } else if (result == .commit) {
        s.offset = 0;
        s.selected_field_len = 0;
    }
    self.metal_dirty = true;
}
fn reject(self: *app.AppSession) void {
    if (self.inspector.ime.tx.in_key) self.inspector.ime.tx.rejected = true;
}
pub fn insert(self: *app.AppSession, bytes: []const u8, replacement: ?model.Range) bool {
    if (stale(self)) return true;
    if (self.ime_terminal_target_id != null) return false;
    if (self.inputFocus() != .inspector) return false;
    _ = projection(self) orelse return true;
    var scratch: [model.query_limit]u8 = undefined;
    const clean = model.cleanNative(bytes, &scratch) orelse {
        reject(self);
        return true;
    };
    if (self.ime_active) self.ime_marked_changed = true;
    if (clean.len == 0 and (bytes.len != 0 or replacement == null)) return true;
    const tx = &self.inspector.ime.tx;
    if (tx.insert(clean, replacement)) publish(self, if (tx.in_key) .none else .commit);
    return true;
}
pub fn marked(self: *app.AppSession, bytes: []const u8, selected: model.Range, replacement: ?model.Range) bool {
    if (stale(self)) return true;
    if (self.ime_terminal_target_id != null) return false;
    if (self.inputFocus() != .inspector) return false;
    _ = projection(self) orelse return true;
    if (self.inspector.ime.tx.marked(bytes, selected, replacement)) publish(self, .none);
    if (self.ime_active) {
        self.ime_marked_changed = true;
        if (bytes.len > 0) self.ime_had_marked = true;
    }
    return true;
}
pub fn begin(self: *app.AppSession) void {
    finish(self);
    const s = &self.inspector;
    s.ime.owner = generation(self);
    if (s.ime.owner == null) return;
    s.ime.captured_epoch = s.ime.epoch;
    s.ime.before_offset = s.offset;
    s.ime.before_selected_len = s.selected_field_len;
    @memcpy(s.ime.before_selected[0..s.selected_field_len], s.selected_field[0..s.selected_field_len]);
    s.ime.tx.begin(s.query[0..s.query_len], s.preedit[0..s.preedit_len]);
}
pub fn finish(self: *app.AppSession) void {
    const s = &self.inspector.ime;
    if (s.tx.in_key and s.tx.context.pending) s.tx.context.valid = false;
    s.tx.finish();
    s.owner = null;
}
pub fn end(self: *app.AppSession, event: ?maru.terminal.KeyEvent) bool {
    const s = &self.inspector.ime;
    if (s.owner == null) return self.ime_terminal_target_id == null and self.inputFocus() == .inspector and generation(self) == null;
    if (generation(self) == null) {
        if (s.tx.before != null and s.captured_epoch == s.epoch) {
            // Unadmitted callbacks belong to the hidden source, not its next owner.
            s.tx.rejected = true;
            publish(self, s.tx.end(false));
        }
        s.tx.context.valid = false;
        return true;
    }
    const had_commit = s.tx.context.pending and !s.tx.rejected;
    const key: ?model.Key = if (event) |e| switch (e.key) {
        .enter => .enter,
        .backspace => .backspace,
        else => .other,
    } else null;
    const decision = s.tx.finishKey(key, self.ime_marked_changed, self.ime_did_delete);
    if (decision.result != .none) publish(self, decision.result);
    if (had_commit) if (event) |e| if (app.AppSession.shouldReplayAfterCommit(e, false)) ops.key(self, e);
    return decision.consumed;
}
pub fn commitAll(self: *app.AppSession) bool {
    const s = &self.inspector;
    if (s.ime.owner != null and s.ime.captured_epoch != s.ime.epoch or s.ime.tx.rejected) return false;
    if (s.preedit_len == 0 and !s.ime.tx.context.pending) return true;
    if (!s.ime.tx.context.valid and !s.ime.tx.in_key) {
        ops.commitLegacyPreedit(self);
        return true;
    }
    _ = s.ime.tx.sync(s.query[0..s.query_len], s.preedit[0..s.preedit_len]) orelse return false;
    if (s.ime.tx.context.preedit().len > 0) {
        var scratch: [model.query_limit]u8 = undefined;
        const raw = s.ime.tx.context.preedit();
        const clean = model.cleanNative(raw, &scratch) orelse return false;
        if (clean.len != raw.len) {
            if (clean.len == 0) {
                if (!s.ime.tx.marked("", .{ .location = 0, .length = 0 }, null)) return false;
            } else if (!s.ime.tx.insert(clean, null)) return false;
        }
    }
    if (!s.ime.tx.commitAll()) return false;
    publish(self, .commit);
    return true;
}
