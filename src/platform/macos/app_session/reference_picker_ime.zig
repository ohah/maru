//! Native owner and atomic result publication for the existing reference picker.
//! Shared chrome owns Unicode ranges and key rollback; the existing result model owns filtering.
const std = @import("std");
const maru = @import("maru");
const app = @import("../app_session.zig");
const editor = @import("editor/mod.zig");

const model = maru.chrome.components.overlay_input_ime;
const tag: u64 = @as(u64, 1) << 52;
const Owner = struct { lifecycle: u64, source: editor.SymbolPickerSource, results: u64, kind: maru.session.editor.lsp.rpc.LocationKind };
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
        self.inputFocus() != .reference_picker or self.chrome_host.reference_picker.ime_generation == std.math.maxInt(u64) or self.reference_picker_rows.result_generation == std.math.maxInt(u64)) return null;
    const source = editor.symbolPickerSource(@import("pane.zig").activePane(self).activeTerm()) orelse return null;
    return .{ .lifecycle = self.chrome_host.reference_picker.ime_generation, .source = source, .results = self.reference_picker_rows.result_generation, .kind = self.editor_references.waiting_kind };
}
pub fn generation(self: *app.AppSession) ?u64 {
    const s = &self.reference_picker_ime;
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
    return self.reference_picker_ime.owner != null and generation(self) == null;
}
pub fn projection(self: *app.AppSession) ?*maru.inline_text_input.DynamicContext {
    _ = generation(self) orelse return null;
    return self.chrome_host.reference_picker.range_ime.sync(self.allocator, &self.chrome_host.reference_picker.input);
}
fn rollback(self: *app.AppSession) void {
    const p = &self.chrome_host.reference_picker;
    self.reference_picker_ime.transaction.rejected = true;
    p.range_ime.rollback(self.allocator, &p.input, &self.reference_picker_ime.transaction);
}
fn prepareFilter(self: *app.AppSession) bool {
    self.reference_picker_rows.prepareFilter(self.allocator) catch return false;
    return true;
}
fn publishRows(self: *app.AppSession) void {
    // The result owner was checked for this synchronous, nonallocating step.
    self.reference_picker_rows.applyPreparedFilter(self.chrome_host.reference_picker.input.query.items);
    self.chrome_host.reference_picker.selected = 0;
    self.chrome_host.reference_picker.setResultCount(self.reference_picker_rows.shown.items.len);
    self.resetCursorBlink();
}
fn settle(self: *app.AppSession, event: ?maru.terminal.KeyEvent) bool {
    const s = &self.reference_picker_ime;
    const p = &self.chrome_host.reference_picker;
    const key: ?model.Key = if (event) |e| switch (e.key) {
        .enter => .enter,
        .backspace => .backspace,
        else => .other,
    } else null;
    if ((p.range_ime.context.value.pending or self.ime_did_delete) and !s.transaction.rejected and !prepareFilter(self)) s.transaction.rejected = true;
    const result = p.range_ime.finishKey(self.allocator, &p.input, &s.transaction, key, self.ime_did_delete);
    if (result.changed) publishRows(self);
    self.metal_dirty = true;
    return result.consumed or s.transaction.rejected;
}
pub fn insert(self: *app.AppSession, bytes: []const u8, replacement: ?model.Range) bool {
    if (stale(self)) return true;
    if (self.ime_terminal_target_id != null or self.inputFocus() != .reference_picker) return false;
    _ = generation(self) orelse return true;
    const p = &self.chrome_host.reference_picker;
    if (!self.ime_active) self.reference_picker_ime.transaction.begin(self.allocator, &p.range_ime, &p.input);
    _ = p.range_ime.insert(self.allocator, &p.input, bytes, replacement, &self.reference_picker_ime.transaction);
    if (!self.ime_active) {
        defer finish(self);
        _ = settle(self, null);
    }
    self.metal_dirty = true;
    return true;
}
pub fn marked(self: *app.AppSession, bytes: []const u8, selected: model.Range, replacement: ?model.Range) bool {
    if (stale(self)) return true;
    if (self.ime_terminal_target_id != null or self.inputFocus() != .reference_picker) return false;
    _ = generation(self) orelse return true;
    const p = &self.chrome_host.reference_picker;
    if (!self.ime_active) self.reference_picker_ime.transaction.begin(self.allocator, &p.range_ime, &p.input);
    _ = p.range_ime.marked(self.allocator, &p.input, bytes, selected, replacement, &self.reference_picker_ime.transaction);
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
    self.reference_picker_ime.owner = generation(self);
    if (self.reference_picker_ime.owner == null) return;
    self.reference_picker_ime.lifecycle = self.chrome_host.reference_picker.ime_generation;
    self.reference_picker_ime.transaction.begin(self.allocator, &self.chrome_host.reference_picker.range_ime, &self.chrome_host.reference_picker.input);
}
pub fn finish(self: *app.AppSession) void {
    const s = &self.reference_picker_ime;
    if (s.transaction.active and self.chrome_host.reference_picker.range_ime.context.value.pending) self.chrome_host.reference_picker.range_ime.invalidate();
    s.transaction.finish(self.allocator);
    s.owner = null;
}
pub fn end(self: *app.AppSession, event: ?maru.terminal.KeyEvent) bool {
    if (self.reference_picker_ime.owner == null) return self.ime_terminal_target_id == null and self.inputFocus() == .reference_picker and generation(self) == null;
    if (generation(self) == null) {
        if (self.reference_picker_ime.lifecycle == self.chrome_host.reference_picker.ime_generation) rollback(self);
        self.chrome_host.reference_picker.range_ime.invalidate();
        return true;
    }
    return settle(self, event);
}
pub fn commitAll(self: *app.AppSession) bool {
    const s = &self.reference_picker_ime;
    const p = &self.chrome_host.reference_picker;
    if (s.transaction.rejected or stale(self)) return false;
    if (p.input.preedit.items.len == 0 and !p.range_ime.context.value.pending) return true;
    const outside = !s.transaction.active;
    if (outside) s.transaction.begin(self.allocator, &p.range_ime, &p.input);
    defer if (outside) finish(self);
    if (s.transaction.rejected) return false;
    if (!prepareFilter(self)) {
        rollback(self);
        return false;
    }
    const changed = p.range_ime.commitAll(self.allocator, &p.input) orelse {
        rollback(self);
        return false;
    };
    if (changed) publishRows(self);
    self.metal_dirty = true;
    return true;
}
