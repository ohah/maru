//! Host identity only. UTF-16 edits, snapshots and TextField publication belong
//! to the platform-neutral chrome adapter, shared by every future field host.
const app = @import("../app_session.zig");
const maru = @import("maru");
const tag: u64 = @as(u64, 1) << 62;

pub fn generation(self: *app.AppSession) ?u64 {
    if (self.ime_terminal_target_id != null or self.inputFocus() != .addr_edit or self.addr_edit == null) return null;
    if (self.address_ime_generation >= tag) return null;
    const token = tag | self.address_ime_generation;
    if (self.address_ime_owner) |owner| {
        if (owner != token or self.address_ime_surface != self.addr_edit) return null;
    }
    return token;
}

pub fn projection(self: *app.AppSession) ?*maru.inline_text_input.DynamicContext {
    _ = generation(self) orelse return null;
    return self.address_ime.projection(self.allocator, &self.addr_field);
}

pub fn insert(self: *app.AppSession, bytes: []const u8, replacement: ?maru.inline_text_input.Range) bool {
    if (self.address_ime_owner != null and generation(self) == null) return true;
    _ = generation(self) orelse return false;
    _ = self.address_ime.insert(self.allocator, &self.addr_field, bytes, replacement);
    if (self.ime_active) self.ime_marked_changed = true;
    self.metal_dirty = true;
    return true;
}

pub fn marked(self: *app.AppSession, bytes: []const u8, selected: maru.inline_text_input.Range, replacement: ?maru.inline_text_input.Range) bool {
    if (self.address_ime_owner != null and generation(self) == null) return true;
    _ = generation(self) orelse return false;
    _ = self.address_ime.marked(self.allocator, &self.addr_field, bytes, selected, replacement);
    if (self.ime_active) {
        self.ime_marked_changed = true;
        if (bytes.len > 0) self.ime_had_marked = true;
    }
    self.metal_dirty = true;
    return true;
}

pub fn begin(self: *app.AppSession) void {
    self.address_ime_owner = generation(self);
    self.address_ime_surface = self.addr_edit;
    if (self.address_ime_owner != null) self.address_ime.begin(self.allocator, &self.addr_field);
}

pub fn finish(self: *app.AppSession) void {
    self.address_ime.finish(self.allocator);
    self.address_ime_owner = null;
    self.address_ime_surface = null;
}

pub fn end(self: *app.AppSession, event: ?maru.terminal.KeyEvent) bool {
    _ = self.address_ime_owner orelse return false;
    if (generation(self) == null) return true;
    const Key = @import("maru").chrome.components.text_field_ime.Key;
    const key: ?Key = if (event) |value| switch (value.key) {
        .enter => .enter,
        .backspace => .backspace,
        else => .other,
    } else null;
    const consumed = self.address_ime.finishKey(self.allocator, &self.addr_field, key, self.ime_marked_changed, self.ime_did_delete);
    if (consumed) self.metal_dirty = true;
    return consumed;
}

pub fn commitAll(self: *app.AppSession) bool {
    const accepted = self.address_ime.commitAll(self.allocator, &self.addr_field);
    if (accepted) self.metal_dirty = true;
    return accepted;
}
