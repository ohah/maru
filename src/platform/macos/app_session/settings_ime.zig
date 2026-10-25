//! Settings identity and publication glue. Bounded range/key policy lives in
//! the neutral component; no config action is invoked by an IME callback.
const std = @import("std");
const app = @import("../app_session.zig");
const maru = @import("maru");
const settings = @import("settings.zig");
const model = maru.chrome.components.settings;
const tag: u64 = @as(u64, 1) << 60;

pub fn generation(self: *app.AppSession) ?u64 {
    if (self.ime_terminal_target_id != null or self.inputFocus() != .settings) return null;
    const state = &self.chrome_host.settings;
    if (!state.searchIMEOwnsInput() or state.search_ime_generation >= tag) return null;
    const token = tag | state.search_ime_generation;
    if (self.settings_ime_owner) |owner| if (owner != token) return null;
    return token;
}
pub fn stale(self: *app.AppSession) bool {
    return self.settings_ime_owner != null and generation(self) == null;
}
pub fn projection(self: *app.AppSession) ?*model.SearchIMEContext {
    _ = generation(self) orelse return null;
    return self.chrome_host.settings.searchIMEProjection();
}

fn publish(self: *app.AppSession, result: model.SearchIMEResult) bool {
    const state = &self.chrome_host.settings;
    const saved = state.*;
    state.publishSearchIME(result);
    if (result == .commit) {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const fields = settings.currentSectionFields(self, arena.allocator()) catch {
            state.* = saved;
            state.search_ime.rejected = true;
            state.publishSearchIME(state.search_ime.end(false));
            self.metal_dirty = true;
            return false;
        };
        state.setFieldCount(fields.total());
    }
    self.metal_dirty = true;
    return true;
}
pub fn insert(self: *app.AppSession, bytes: []const u8, replacement: ?maru.inline_text_input.Range) bool {
    if (stale(self)) return true;
    if (self.inputFocus() != .settings or !self.chrome_host.settings.searchIMEOwnsInput()) return false;
    _ = projection(self) orelse return true; // Exhaustion never falls through to append-only input.
    const state = &self.chrome_host.settings;
    const before = state.*;
    if (state.search_ime.insert(bytes, replacement)) {
        if (!publish(self, if (state.search_ime.in_key) .none else .commit) and !before.search_ime.in_key) state.* = before;
    }
    if (self.ime_active) self.ime_marked_changed = true;
    return true;
}
pub fn marked(self: *app.AppSession, bytes: []const u8, selected: maru.inline_text_input.Range, replacement: ?maru.inline_text_input.Range) bool {
    if (stale(self)) return true;
    if (self.inputFocus() != .settings or !self.chrome_host.settings.searchIMEOwnsInput()) return false;
    _ = projection(self) orelse return true;
    if (self.chrome_host.settings.search_ime.marked(bytes, selected, replacement)) _ = publish(self, .none);
    if (self.ime_active) {
        self.ime_marked_changed = true;
        if (bytes.len > 0) self.ime_had_marked = true;
    }
    return true;
}
pub fn begin(self: *app.AppSession) void {
    self.settings_ime_owner = generation(self);
    if (self.settings_ime_owner != null) {
        const state = &self.chrome_host.settings;
        state.search_ime.begin(state.searchQuery(), state.searchPreedit());
    }
}
pub fn finish(self: *app.AppSession) void {
    self.chrome_host.settings.search_ime.finish();
    self.settings_ime_owner = null;
}
pub fn end(self: *app.AppSession, event: ?maru.terminal.KeyEvent) bool {
    if (self.settings_ime_owner == null) return false;
    if (generation(self) == null) return true;
    const state = &self.chrome_host.settings;
    const key: ?model.SearchIMEKey = if (event) |value| switch (value.key) {
        .enter => .enter,
        .backspace => .backspace,
        else => .other,
    } else null;
    const decision = state.search_ime.finishKey(key, self.ime_marked_changed, self.ime_did_delete);
    if (decision.result != .none) _ = publish(self, decision.result);
    return decision.consumed;
}

pub fn commitAll(self: *app.AppSession) bool {
    const state = &self.chrome_host.settings;
    if (!state.searchIMEOwnsInput()) return true;
    _ = projection(self) orelse return false;
    const before = state.*;
    if (!state.search_ime.commitAll()) return false;
    if (publish(self, .commit)) return true;
    state.* = before;
    if (state.search_ime.in_key) state.search_ime.rejected = true;
    return false;
}
