//! Project-search field ownership and publication only. Unicode ranges and
//! rollback stay in the shared neutral TextField adapter.
const std = @import("std");
const maru = @import("maru");
const host = @import("../../../app_session.zig");
const dock = @import("dock.zig");
const adapter = maru.chrome.components.text_field_ime;
const tag: u64 = @as(u64, 1) << 58;
pub const Owner = struct { epoch: u64, index: usize, surface: u64, root: u64 };
fn current(self: *host.AppSession) ?Owner {
    if (!self.surface_initialized or self.tabs.items.len == 0 or self.ime_terminal_target_id != null or !dock.ownsInput(self)) return null;
    const st = &self.editor_search;
    const index = st.focused orelse return null;
    if (index >= 4 or index == 3 and !st.replacing or index > 0 and index < 3 and !st.expanded or st.ime_epoch == std.math.maxInt(u64)) return null;
    return .{ .epoch = st.ime_epoch, .index = index, .surface = @import("../../pane.zig").activePane(self).activeTerm().surfaceId(), .root = if (self.file_tree_initialized) self.file_tree.rootGeneration() else 0 };
}
pub fn generation(self: *host.AppSession) ?u64 {
    const st = &self.editor_search;
    const owner = current(self);
    if (!std.meta.eql(owner, st.ime_observed)) {
        st.ime_sequence +|= 1;
        st.ime_observed = owner;
    }
    if (owner == null or st.ime_sequence >= tag) return null;
    const token = tag | st.ime_sequence;
    if (st.ime_owner) |pin| if (pin != token) return null;
    return token;
}
pub fn stale(self: *host.AppSession) bool {
    return self.editor_search.ime_owner != null and generation(self) == null;
}
pub fn projection(self: *host.AppSession) ?*maru.inline_text_input.DynamicContext {
    _ = generation(self) orelse return null;
    const st = &self.editor_search;
    const index = st.focused.?;
    return st.ime_models[index].projection(self.allocator, &st.fields[index]);
}
fn publish(self: *host.AppSession, in_key: bool) void {
    // Invalidation can happen during an AppKit callback; starting a replacement
    // search remains the existing end-of-key/debounce decision.
    dock.imeChanged(self, in_key);
    self.metal_dirty = true;
}
pub fn insert(self: *host.AppSession, bytes: []const u8, replacement: ?adapter.Range) bool {
    if (stale(self)) return true;
    if (self.inputFocus() != .project_search) return false;
    _ = generation(self) orelse return true;
    const st = &self.editor_search;
    const index = st.focused.?;
    if (self.ime_active) st.ime_touched = true;
    if (st.ime_models[index].insert(self.allocator, &st.fields[index], bytes, replacement)) {
        if (self.ime_active) st.ime_published = true;
        publish(self, self.ime_active);
    }
    return true;
}
pub fn marked(self: *host.AppSession, bytes: []const u8, selected: adapter.Range, replacement: ?adapter.Range) bool {
    if (stale(self)) return true;
    if (self.inputFocus() != .project_search) return false;
    _ = generation(self) orelse return true;
    const st = &self.editor_search;
    const index = st.focused.?;
    if (self.ime_active) st.ime_touched = true;
    if (st.ime_models[index].marked(self.allocator, &st.fields[index], bytes, selected, replacement)) {
        if (self.ime_active) {
            st.ime_published = true;
            if (bytes.len > 0) self.ime_had_marked = true;
        }
        publish(self, self.ime_active);
    }
    return true;
}
pub fn finish(self: *host.AppSession) void {
    const st = &self.editor_search;
    for (&st.ime_models) |*model| model.finish(self.allocator);
    st.ime_owner = null;
    st.ime_index = null;
    st.ime_touched = false;
    st.ime_published = false;
}
pub fn begin(self: *host.AppSession) void {
    finish(self);
    const st = &self.editor_search;
    st.ime_owner = generation(self);
    if (st.ime_owner == null) return;
    const index = st.focused.?;
    st.ime_index = index;
    st.ime_models[index].begin(self.allocator, &st.fields[index]);
}
pub fn end(self: *host.AppSession, event: ?maru.terminal.KeyEvent) bool {
    const st = &self.editor_search;
    _ = st.ime_owner orelse return false;
    if (generation(self) == null) return true;
    const index = st.ime_index orelse return true;
    const model = &st.ime_models[index];
    const had_commit = model.context.value.pending and !model.rejected;
    const key: ?adapter.Key = if (event) |e| switch (e.key) {
        .enter => .enter,
        .backspace => .backspace,
        else => .other,
    } else null;
    const consumed = model.finishKey(self.allocator, &st.fields[index], key, st.ime_touched, self.ime_did_delete);
    if (st.ime_published or self.ime_did_delete and consumed) publish(self, false);
    if (had_commit) if (event) |e| if (host.AppSession.shouldReplayAfterCommit(e, false)) {
        _ = self.handleKeyEvent(e) catch {};
    };
    return consumed;
}
pub fn commitAll(self: *host.AppSession) bool {
    const st = &self.editor_search;
    const index = st.focused orelse return true;
    if (index >= 4) return false;
    const model = &st.ime_models[index];
    if (model.rejected) return false;
    if (st.fields[index].preedit.items.len == 0 and !model.context.value.pending) return true;
    if (!model.commitAll(self.allocator, &st.fields[index])) return false;
    publish(self, false);
    return true;
}
