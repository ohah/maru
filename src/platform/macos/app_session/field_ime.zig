//! Field identity/routing only. Unicode edits, snapshots, failure handling and
//! commit-key decisions remain in the platform-neutral TextField IME adapter.
const app = @import("../app_session.zig");
const maru = @import("maru");
const chrome = maru.chrome;
pub const Role = enum { address, rename };

fn tag(role: Role) u64 {
    return @as(u64, 1) << @as(u6, if (role == .address) 62 else 61);
}
fn model(self: *app.AppSession, role: Role) *chrome.components.text_field_ime.State {
    return if (role == .address) &self.address_ime else &self.rename_ime;
}
fn field(self: *app.AppSession, role: Role) *chrome.components.text_field.TextField {
    return if (role == .address) &self.addr_field else &self.rename_input;
}
fn pinned(self: *app.AppSession, role: Role) *?u64 {
    return if (role == .address) &self.address_ime_owner else &self.rename_ime_owner;
}
fn current(self: *app.AppSession, role: Role) bool {
    return self.ime_terminal_target_id == null and switch (role) {
        .address => self.inputFocus() == .addr_edit and self.addr_edit != null,
        .rename => self.inputFocus() == .rename and self.rename != null,
    };
}

pub fn generation(self: *app.AppSession, role: Role) ?u64 {
    if (!current(self, role)) return null;
    const nonce = if (role == .address) self.address_ime_generation else self.rename_ime_generation;
    if (nonce >= tag(role)) return null;
    const token = tag(role) | nonce;
    if (pinned(self, role).*) |owner| {
        if (owner != token) return null;
        if (role == .address and self.address_ime_surface != self.addr_edit) return null;
    }
    return token;
}

pub fn stale(self: *app.AppSession) bool {
    inline for (.{ Role.address, Role.rename }) |role| {
        if (pinned(self, role).* != null and generation(self, role) == null) return true;
    }
    return false;
}

pub fn projection(self: *app.AppSession, role: Role) ?*maru.inline_text_input.DynamicContext {
    _ = generation(self, role) orelse return null;
    return model(self, role).projection(self.allocator, field(self, role));
}

pub fn insert(self: *app.AppSession, role: Role, bytes: []const u8, replacement: ?maru.inline_text_input.Range) bool {
    if (pinned(self, role).* != null and generation(self, role) == null) return true;
    if (!current(self, role)) return false;
    // Exhaustion must not fall through to the old range-ignoring route.
    _ = generation(self, role) orelse return true;
    _ = model(self, role).insert(self.allocator, field(self, role), bytes, replacement);
    if (self.ime_active) self.ime_marked_changed = true;
    if (role == .rename) self.resetCursorBlink();
    self.metal_dirty = true;
    return true;
}

pub fn marked(self: *app.AppSession, role: Role, bytes: []const u8, selected: maru.inline_text_input.Range, replacement: ?maru.inline_text_input.Range) bool {
    if (pinned(self, role).* != null and generation(self, role) == null) return true;
    if (!current(self, role)) return false;
    _ = generation(self, role) orelse return true;
    _ = model(self, role).marked(self.allocator, field(self, role), bytes, selected, replacement);
    if (self.ime_active) {
        self.ime_marked_changed = true;
        if (bytes.len > 0) self.ime_had_marked = true;
    }
    if (role == .rename) self.resetCursorBlink();
    self.metal_dirty = true;
    return true;
}

pub fn begin(self: *app.AppSession) void {
    inline for (.{ Role.address, Role.rename }) |role| {
        pinned(self, role).* = generation(self, role);
        if (role == .address) self.address_ime_surface = self.addr_edit;
        if (pinned(self, role).* != null) model(self, role).begin(self.allocator, field(self, role));
    }
}

pub fn finish(self: *app.AppSession) void {
    inline for (.{ Role.address, Role.rename }) |role| {
        model(self, role).finish(self.allocator);
        pinned(self, role).* = null;
    }
    self.address_ime_surface = null;
}

pub fn end(self: *app.AppSession, event: ?maru.terminal.KeyEvent) bool {
    inline for (.{ Role.address, Role.rename }) |role| {
        if (pinned(self, role).* != null) {
            if (generation(self, role) == null) return true;
            const Key = chrome.components.text_field_ime.Key;
            const key: ?Key = if (event) |value| switch (value.key) {
                .enter => .enter,
                .backspace => .backspace,
                else => .other,
            } else null;
            const consumed = model(self, role).finishKey(self.allocator, field(self, role), key, self.ime_marked_changed, self.ime_did_delete);
            if (consumed) self.metal_dirty = true;
            return consumed;
        }
    }
    return false;
}

pub fn commitAll(self: *app.AppSession, role: Role) bool {
    if (role == .rename) {
        // Explicit Save As retries may run while an earlier validation notice is
        // still visible. Focus gates OS callbacks, not this target-owned action.
        if (self.rename == null or self.rename_ime_generation >= tag(role)) return false;
        if (self.rename_ime_owner) |owner| {
            if (owner != (tag(role) | self.rename_ime_generation)) return false;
        }
    } else {
        _ = generation(self, role) orelse return false;
    }
    const accepted = model(self, role).commitAll(self.allocator, field(self, role));
    if (accepted) self.metal_dirty = true;
    return accepted;
}
