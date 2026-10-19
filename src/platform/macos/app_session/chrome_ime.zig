//! Session Dock's editable input boundary. The neutral bounded projection owns ranges;
//! this adapter alone publishes accepted commits to the canonical query/filter.
const std = @import("std");
const maru = @import("maru");
const app = @import("../app_session.zig");
const dock = @import("agent_dock.zig");
pub const Range = maru.inline_text_input.Range;
const Context = maru.inline_text_input.Context;

pub fn generation(self: *app.AppSession) ?u64 {
    if (self.ime_terminal_target_id != null or self.inputFocus() != .agent_session_search) return null;
    if (self.ime_search_owner) |owner| if (owner != self.agent_session_search_generation) return null;
    return self.agent_session_search_generation;
}

pub fn projection(self: *app.AppSession) ?*Context {
    _ = generation(self) orelse return null;
    return sync(self);
}

fn sync(self: *app.AppSession) ?*Context {
    const field = &self.agent_session_archive_search;
    const context = &self.agent_session_search_ime;
    if (!context.matches(field.query.items, field.preedit.items)) {
        if (!context.reset(field.query.items, field.preedit.items)) return null;
    }
    return context;
}

fn reserve(self: *app.AppSession) bool {
    const field = &self.agent_session_archive_search;
    field.query.ensureTotalCapacity(self.allocator, maru.inline_text_input.query_limit) catch return false;
    field.preedit.ensureTotalCapacity(self.allocator, maru.inline_text_input.marked_limit) catch return false;
    return true;
}

fn publishPreedit(self: *app.AppSession, context: *const Context) void {
    const field = &self.agent_session_archive_search;
    field.preedit.clearRetainingCapacity();
    field.preedit.appendSliceAssumeCapacity(context.preedit());
    self.metal_dirty = true;
}

fn publish(self: *app.AppSession, context: *Context) void {
    const field = &self.agent_session_archive_search;
    const length = context.committedLength();
    std.debug.assert(length <= maru.inline_text_input.query_limit);
    var bytes: [maru.inline_text_input.query_limit]u8 = undefined;
    context.copyCommitted(bytes[0..length]);
    const changed = !std.mem.eql(u8, field.query.items, bytes[0..length]);
    field.query.clearRetainingCapacity();
    field.query.appendSliceAssumeCapacity(bytes[0..length]);
    context.accepted(field.query.items);
    if (changed) {
        dock.rebuildAgentSessionArchiveFilter(self);
        dock.resetAgentSessionDockScroll(self);
        self.agent_session_archive_selected = null;
        dock.closeAgentSessionInlineDetail(self);
    }
    self.metal_dirty = true;
}

/// A stale pinned owner consumes callbacks too: falling through would edit the next owner.
pub fn insert(self: *app.AppSession, bytes: []const u8, replacement: ?Range) bool {
    if (self.ime_search_owner != null and generation(self) == null) return true;
    const context = projection(self) orelse return false;
    if (self.ime_active) self.ime_marked_changed = true;
    if (!reserve(self) or !context.insert(bytes, replacement)) {
        if (self.ime_active) self.ime_search_rejected = true;
        return true;
    }
    publishPreedit(self, context);
    if (!self.ime_active) publish(self, context);
    return true;
}

pub fn marked(self: *app.AppSession, bytes: []const u8, selected: Range, replacement: ?Range) bool {
    if (self.ime_search_owner != null and generation(self) == null) return true;
    const context = projection(self) orelse return false;
    if (self.ime_active) self.ime_marked_changed = true;
    if (!reserve(self) or !context.setMarked(bytes, selected, replacement)) {
        if (self.ime_active) self.ime_search_rejected = true;
        return true;
    }
    if (self.ime_active and bytes.len > 0) self.ime_had_marked = true;
    publishPreedit(self, context);
    return true;
}

pub fn begin(self: *app.AppSession) void {
    self.ime_search_owner = generation(self);
    self.ime_search_rejected = false;
    self.ime_search_before = if (projection(self)) |context| context.* else null;
}

pub fn end(self: *app.AppSession, event: ?maru.terminal.KeyEvent) bool {
    _ = self.ime_search_owner orelse return false;
    if (generation(self) == null) return true;
    const context = projection(self) orelse return true;
    if (self.ime_search_rejected) {
        if (self.ime_search_before) |before| {
            context.* = before;
            publishPreedit(self, context);
        }
        return true;
    }
    if (context.pending) {
        if (self.ime_did_delete) context.cancelInsertedScalar();
        publish(self, context);
        publishPreedit(self, context);
        return true;
    }
    if (self.ime_marked_changed) {
        if (context.marked == null) _ = context.reset(self.agent_session_archive_search.query.items, "");
        return true;
    }
    if (event) |key| {
        if (key.key == .backspace and self.ime_did_delete and context.marked == null) {
            if (reserve(self) and context.deleteBackward()) publish(self, context);
            return true;
        }
    }
    // A candidate-consumed key has no replay event even when it produces no callback.
    if (event == null) return true;
    return false;
}

/// Reserve before admitting or clearing any composition. A failed blur keeps its old owner.
pub fn commitAll(self: *app.AppSession) bool {
    const context = sync(self) orelse return false;
    if (!context.pending and context.marked == null) return true;
    if (context.len > maru.inline_text_input.query_limit or !reserve(self)) return false;
    if (!context.admitMarked()) return false;
    publish(self, context);
    publishPreedit(self, context);
    return true;
}
