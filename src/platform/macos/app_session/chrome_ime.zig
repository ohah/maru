//! Session Dock's editable input boundary. The neutral bounded projection owns ranges;
//! this adapter alone publishes accepted commits to the canonical query/filter.
const std = @import("std");
const maru = @import("maru");
const app = @import("../app_session.zig");
const dock = @import("agent_dock.zig");
pub const Range = maru.inline_text_input.Range;
const Context = maru.inline_text_input.Context;
const scm_ime = @import("scm_commit_ime.zig");
const sidebar_ime = @import("sidebar_ime.zig");
const project_ime = @import("editor/search/ime.zig");
const find_ime = @import("find_ime.zig");
const settings_ime = @import("settings_ime.zig");
const field_ime = @import("field_ime.zig");
const palette_ime = @import("palette_ime.zig");

pub const Projection = union(enum) {
    fixed: *Context,
    settings: *maru.chrome.components.settings.SearchIMEContext,
    dynamic: *maru.inline_text_input.DynamicContext,
    pub fn text(self: Projection) []const u8 {
        return switch (self) {
            inline else => |context| context.text(),
        };
    }
    pub fn selectedRange(self: Projection) ?Range {
        return switch (self) {
            inline else => |context| context.selectedRange(),
        };
    }
    pub fn markedRange(self: Projection) ?Range {
        return switch (self) {
            inline else => |context| context.markedRange(),
        };
    }
    pub fn substring(self: Projection, range: Range) ?struct { bytes: []const u8, actual: Range } {
        return switch (self) {
            inline else => |context| blk: {
                const part = context.substringForInputMethod(range) orelse break :blk null;
                break :blk .{ .bytes = part.bytes, .actual = part.actual };
            },
        };
    }
};

pub fn generation(self: *app.AppSession) ?u64 {
    if (scm_ime.generation(self)) |token| return token;
    if (sidebar_ime.generation(self)) |token| return token;
    if (project_ime.generation(self)) |token| return token;
    if (find_ime.generation(self)) |token| return token;
    if (settings_ime.generation(self)) |token| return token;
    if (field_ime.generation(self, .address)) |token| return token;
    if (field_ime.generation(self, .rename)) |token| return token;
    if (palette_ime.generation(self)) |token| return token;
    return fixedGeneration(self);
}
pub fn projection(self: *app.AppSession) ?Projection {
    if (scm_ime.projection(self)) |context| return .{ .dynamic = context };
    if (sidebar_ime.projection(self)) |context| return .{ .dynamic = context };
    if (project_ime.projection(self)) |context| return .{ .dynamic = context };
    if (find_ime.projection(self)) |context| return .{ .dynamic = context };
    if (settings_ime.projection(self)) |context| return .{ .settings = context };
    if (field_ime.projection(self, .address)) |context| return .{ .dynamic = context };
    if (field_ime.projection(self, .rename)) |context| return .{ .dynamic = context };
    if (palette_ime.projection(self)) |context| return .{ .dynamic = context };
    if (fixedProjection(self)) |context| return .{ .fixed = context };
    return null;
}

fn fixedGeneration(self: *app.AppSession) ?u64 {
    if (self.ime_terminal_target_id != null or self.inputFocus() != .agent_session_search) return null;
    if (self.ime_search_owner) |owner| if (owner != self.agent_session_search_generation) return null;
    const token = self.agent_session_search_generation;
    return if (token < (@as(u64, 1) << 56)) token else null;
}

fn fixedProjection(self: *app.AppSession) ?*Context {
    _ = fixedGeneration(self) orelse return null;
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
    // Test the pinned source before considering the current destination. An old
    // palette/search callback must never become a fresh address-field write.
    if (scm_ime.stale(self) or sidebar_ime.stale(self) or project_ime.stale(self) or find_ime.stale(self) or settings_ime.stale(self) or field_ime.stale(self) or
        self.palette_ime_owner != null and palette_ime.generation(self) == null or
        self.ime_search_owner != null and fixedGeneration(self) == null) return true;

    if (scm_ime.insert(self, bytes, replacement)) return true;
    if (sidebar_ime.insert(self, bytes, replacement)) return true;
    if (project_ime.insert(self, bytes, replacement)) return true;
    if (find_ime.insert(self, bytes, replacement)) return true;
    if (settings_ime.insert(self, bytes, replacement)) return true;
    if (field_ime.insert(self, .address, bytes, replacement)) return true;
    if (field_ime.insert(self, .rename, bytes, replacement)) return true;
    if (palette_ime.insert(self, bytes, replacement)) return true;
    if (self.ime_search_owner != null and fixedGeneration(self) == null) return true;
    const context = fixedProjection(self) orelse return false;
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
    // Test the pinned source before considering the current destination. An old
    // palette/search callback must never become a fresh address-field write.
    if (scm_ime.stale(self) or sidebar_ime.stale(self) or project_ime.stale(self) or find_ime.stale(self) or settings_ime.stale(self) or field_ime.stale(self) or
        self.palette_ime_owner != null and palette_ime.generation(self) == null or
        self.ime_search_owner != null and fixedGeneration(self) == null) return true;

    if (scm_ime.marked(self, bytes, selected, replacement)) return true;
    if (sidebar_ime.marked(self, bytes, selected, replacement)) return true;
    if (project_ime.marked(self, bytes, selected, replacement)) return true;
    if (find_ime.marked(self, bytes, selected, replacement)) return true;
    if (settings_ime.marked(self, bytes, selected, replacement)) return true;
    if (field_ime.marked(self, .address, bytes, selected, replacement)) return true;
    if (field_ime.marked(self, .rename, bytes, selected, replacement)) return true;
    if (palette_ime.marked(self, bytes, selected, replacement)) return true;
    if (self.ime_search_owner != null and fixedGeneration(self) == null) return true;
    const context = fixedProjection(self) orelse return false;
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
    scm_ime.begin(self);
    sidebar_ime.begin(self);
    project_ime.begin(self);
    find_ime.begin(self);
    settings_ime.begin(self);
    field_ime.begin(self);
    palette_ime.begin(self);
    self.ime_search_owner = fixedGeneration(self);
    self.ime_search_rejected = false;
    self.ime_search_before = if (fixedProjection(self)) |context| context.* else null;
}

pub fn end(self: *app.AppSession, event: ?maru.terminal.KeyEvent) bool {
    if (scm_ime.end(self, event)) return true;
    if (sidebar_ime.end(self, event)) return true;
    if (project_ime.end(self, event)) return true;
    if (find_ime.end(self, event)) return true;
    if (settings_ime.end(self, event)) return true;
    if (field_ime.end(self, event)) return true;
    if (palette_ime.end(self, event)) return true;
    _ = self.ime_search_owner orelse return false;
    if (fixedGeneration(self) == null) return true;
    const context = fixedProjection(self) orelse return true;
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
