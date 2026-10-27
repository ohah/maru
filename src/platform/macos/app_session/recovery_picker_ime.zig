//! Native owner and atomic result publication for the existing recovery picker.
//! Shared chrome owns Unicode ranges and key rollback; the recovery flow owns filter preparation.
const std = @import("std");
const maru = @import("maru");
const app = @import("../app_session.zig");
const recovery = @import("editor/recovery.zig");
const model = maru.chrome.components.overlay_input_ime;
const tag: u64 = @as(u64, 1) << 51;
const Owner = struct { lifecycle: u64, surface: u64, catalog: usize };
pub const State = struct {
    transaction: model.Transaction = .{},
    observed: ?Owner = null,
    sequence: u64 = 1,
    owner: ?u64 = null,
    lifecycle: u64 = 0,
    pub fn deinit(self: *State, a: std.mem.Allocator) void {
        self.transaction.finish(a);
    }
};
fn current(self: *app.AppSession) ?Owner {
    if (!self.surface_initialized or self.tabs.items.len == 0 or self.ime_terminal_target_id != null or
        self.inputFocus() != .recovery_picker or self.chrome_host.recovery_picker.ime_generation == std.math.maxInt(u64)) return null;
    const catalog = &(self.editor_recovery.catalog orelse return null);
    return .{ .lifecycle = self.chrome_host.recovery_picker.ime_generation, .surface = @import("pane.zig").activePane(self).activeTerm().surfaceId(), .catalog = @intFromPtr(catalog.path.ptr) };
}
pub fn generation(self: *app.AppSession) ?u64 {
    const s = &self.recovery_picker_ime;
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
    return self.recovery_picker_ime.owner != null and generation(self) == null;
}
pub fn projection(self: *app.AppSession) ?*maru.inline_text_input.DynamicContext {
    _ = generation(self) orelse return null;
    return self.chrome_host.recovery_picker.range_ime.sync(self.allocator, &self.chrome_host.recovery_picker.input);
}
fn rollback(self: *app.AppSession) void {
    const p = &self.chrome_host.recovery_picker;
    self.recovery_picker_ime.transaction.rejected = true;
    p.range_ime.rollback(self.allocator, &p.input, &self.recovery_picker_ime.transaction);
}
fn publishRows(self: *app.AppSession) bool {
    // Normalization and all result indices are ready before any visible change.
    var prepared = recovery.prepareFilter(self, self.chrome_host.recovery_picker.input.query.items) catch return false;
    defer prepared.deinit(self.allocator);
    recovery.publishFilter(self, &prepared, true);
    self.resetCursorBlink();
    return true;
}

fn settle(self: *app.AppSession, event: ?maru.terminal.KeyEvent) bool {
    const s = &self.recovery_picker_ime;
    const p = &self.chrome_host.recovery_picker;
    const key: ?model.Key = if (event) |e| switch (e.key) {
        .enter => .enter,
        .backspace => .backspace,
        else => .other,
    } else null;
    const result = p.range_ime.finishKey(self.allocator, &p.input, &s.transaction, key, self.ime_did_delete);
    if (result.changed and !publishRows(self)) rollback(self);
    self.metal_dirty = true;
    return result.consumed or s.transaction.rejected;
}
pub fn insert(self: *app.AppSession, bytes: []const u8, replacement: ?model.Range) bool {
    if (stale(self)) return true;
    if (self.ime_terminal_target_id != null or self.inputFocus() != .recovery_picker) return false;
    _ = generation(self) orelse return true;
    const p = &self.chrome_host.recovery_picker;
    if (!self.ime_active) self.recovery_picker_ime.transaction.begin(self.allocator, &p.range_ime, &p.input);
    _ = p.range_ime.insert(self.allocator, &p.input, bytes, replacement, &self.recovery_picker_ime.transaction);
    if (!self.ime_active) {
        defer finish(self);
        _ = settle(self, null);
    }
    self.metal_dirty = true;
    return true;
}
pub fn marked(self: *app.AppSession, bytes: []const u8, selected: model.Range, replacement: ?model.Range) bool {
    if (stale(self)) return true;
    if (self.ime_terminal_target_id != null or self.inputFocus() != .recovery_picker) return false;
    _ = generation(self) orelse return true;
    const p = &self.chrome_host.recovery_picker;
    if (!self.ime_active) self.recovery_picker_ime.transaction.begin(self.allocator, &p.range_ime, &p.input);
    _ = p.range_ime.marked(self.allocator, &p.input, bytes, selected, replacement, &self.recovery_picker_ime.transaction);
    if (!self.ime_active) {
        defer finish(self);
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
    self.recovery_picker_ime.owner = generation(self);
    if (self.recovery_picker_ime.owner == null) return;
    self.recovery_picker_ime.lifecycle = self.chrome_host.recovery_picker.ime_generation;
    self.recovery_picker_ime.transaction.begin(self.allocator, &self.chrome_host.recovery_picker.range_ime, &self.chrome_host.recovery_picker.input);
}
pub fn finish(self: *app.AppSession) void {
    const s = &self.recovery_picker_ime;
    if (s.transaction.active and self.chrome_host.recovery_picker.range_ime.context.value.pending) self.chrome_host.recovery_picker.range_ime.invalidate();
    s.transaction.finish(self.allocator);
    s.owner = null;
}
pub fn end(self: *app.AppSession, event: ?maru.terminal.KeyEvent) bool {
    if (self.recovery_picker_ime.owner == null) return self.ime_terminal_target_id == null and self.inputFocus() == .recovery_picker and generation(self) == null;
    if (generation(self) == null) {
        if (self.recovery_picker_ime.lifecycle == self.chrome_host.recovery_picker.ime_generation) rollback(self);
        self.chrome_host.recovery_picker.range_ime.invalidate();
        return true;
    }
    return settle(self, event);
}
pub fn commitAll(self: *app.AppSession) bool {
    const s = &self.recovery_picker_ime;
    const p = &self.chrome_host.recovery_picker;
    if (s.transaction.rejected or stale(self)) return false;
    if (p.input.preedit.items.len == 0 and !p.range_ime.context.value.pending) return true;
    const outside = !s.transaction.active;
    if (outside) s.transaction.begin(self.allocator, &p.range_ime, &p.input);
    defer if (outside) finish(self);
    if (s.transaction.rejected) return false;
    const changed = p.range_ime.commitAll(self.allocator, &p.input) orelse {
        rollback(self);
        return false;
    };
    if (changed and !publishRows(self)) {
        rollback(self);
        return false;
    }
    self.metal_dirty = true;
    return true;
}
