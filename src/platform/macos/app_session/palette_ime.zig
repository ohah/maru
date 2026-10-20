//! Palette publication policy for the shared inline projection. Unlike Session
//! Dock, the palette filters marked previews and keeps its existing input length.
const std = @import("std");
const maru = @import("maru");
const app = @import("../app_session.zig");
const model = maru.inline_text_input;
pub const Range = model.Range;
const DynamicContext = model.DynamicContext;
const OwnedContext = maru.inline_text_input_owned.OwnedContext;
const commands = @import("../command_palette.zig");
const catalog = @import("../command_catalog.zig");
const palette_tag: u64 = @as(u64, 1) << 63;

pub fn generation(self: *app.AppSession) ?u64 {
    if (self.ime_terminal_target_id != null or self.inputFocus() != .palette) return null;
    const current = self.chrome_host.palette.ime_generation;
    if (current >= palette_tag) return null;
    const token = current | palette_tag;
    if (self.palette_ime_owner) |owner| if (owner != token) return null;
    return token;
}

fn sync(self: *app.AppSession) ?*DynamicContext {
    const state = &self.chrome_host.palette;
    if (!state.ime_context.value.matches(state.input.query.items, state.input.preedit.items)) {
        state.ime_context.reserve(self.allocator, state.input.query.items.len, state.input.preedit.items.len) catch return null;
        if (!state.ime_context.value.reset(state.input.query.items, state.input.preedit.items)) return null;
    }
    return &state.ime_context.value;
}

pub fn projection(self: *app.AppSession) ?*DynamicContext {
    _ = generation(self) orelse return null;
    return sync(self);
}

fn prepare(self: *app.AppSession, bytes: usize) bool {
    const state = &self.chrome_host.palette;
    const needed = std.math.add(usize, state.ime_context.value.len, bytes) catch return false;
    state.ime_context.reserve(self.allocator, needed, needed) catch return false;
    state.input.query.ensureTotalCapacity(self.allocator, needed) catch return false;
    state.input.preedit.ensureTotalCapacity(self.allocator, needed) catch return false;
    self.palette_filtered.ensureTotalCapacity(self.allocator, catalog.entries.len) catch return false;
    return true;
}

// Prepare the complete filtered result before changing any canonical input,
// preedit or published action list. The catalog bounds this borrowed staging array.
fn publish(self: *app.AppSession, commit: bool) bool {
    const state = &self.chrome_host.palette;
    const context = &state.ime_context.value;
    var indices: [catalog.entries.len]usize = undefined;
    var filtered: std.ArrayList(usize) = .fromOwnedSlice(&indices);
    filtered.clearRetainingCapacity();
    commands.filter(self.allocator, context.text(), &filtered) catch return false;
    if (commit) {
        state.input.query.clearRetainingCapacity();
        state.input.query.appendSliceAssumeCapacity(context.committed[0..context.committedLength()]);
        context.accepted(state.input.query.items);
    }
    state.input.preedit.clearRetainingCapacity();
    state.input.preedit.appendSliceAssumeCapacity(context.preedit());
    self.palette_filtered.clearRetainingCapacity();
    self.palette_filtered.appendSliceAssumeCapacity(filtered.items);
    state.selected = 0;
    state.setResultCount(filtered.items.len);
    self.metal_dirty = true;
    return true;
}

fn rollbackKey(self: *app.AppSession) void {
    if (self.palette_ime_before) |before| {
        const state = &self.chrome_host.palette;
        state.ime_context.deinit(self.allocator);
        state.ime_context = before;
        self.palette_ime_before = null;
        state.input.preedit.clearRetainingCapacity();
        state.input.preedit.appendSliceAssumeCapacity(state.ime_context.value.preedit());
        self.palette_filtered.clearRetainingCapacity();
        self.palette_filtered.appendSliceAssumeCapacity(self.palette_ime_filtered_before[0..self.palette_ime_filtered_before_len]);
        state.setResultCount(self.palette_ime_filtered_before_len);
        state.selected = @min(self.palette_ime_selected_before, state.result_count -| 1);
        self.metal_dirty = true;
    }
}

fn fail(self: *app.AppSession, outside: *?OwnedContext) void {
    if (outside.*) |before| {
        self.chrome_host.palette.ime_context.deinit(self.allocator);
        self.chrome_host.palette.ime_context = before;
        outside.* = null;
    } else reject(self);
}

fn reject(self: *app.AppSession) void {
    if (self.ime_active) self.palette_ime_rejected = true;
}

pub fn insert(self: *app.AppSession, bytes: []const u8, replacement: ?Range) bool {
    if (self.palette_ime_owner != null and generation(self) == null) return true;
    _ = generation(self) orelse return false;
    _ = projection(self) orelse {
        reject(self);
        return true;
    };
    if (self.palette_ime_rejected) return true;
    var outside: ?OwnedContext = if (!self.ime_active) self.chrome_host.palette.ime_context.clone(self.allocator) catch return true else null;
    defer if (outside) |*before| before.deinit(self.allocator);
    if (!prepare(self, bytes.len) or !self.chrome_host.palette.ime_context.value.insert(bytes, replacement)) {
        fail(self, &outside);
        return true;
    }
    if (self.ime_active) self.ime_marked_changed = true;
    if (!publish(self, !self.ime_active)) fail(self, &outside);
    return true;
}

pub fn marked(self: *app.AppSession, bytes: []const u8, selected: Range, replacement: ?Range) bool {
    if (self.palette_ime_owner != null and generation(self) == null) return true;
    _ = generation(self) orelse return false;
    _ = projection(self) orelse {
        reject(self);
        return true;
    };
    if (self.palette_ime_rejected) return true;
    var outside: ?OwnedContext = if (!self.ime_active) self.chrome_host.palette.ime_context.clone(self.allocator) catch return true else null;
    defer if (outside) |*before| before.deinit(self.allocator);
    if (!prepare(self, bytes.len) or !self.chrome_host.palette.ime_context.value.setMarked(bytes, selected, replacement)) {
        fail(self, &outside);
        return true;
    }
    if (self.ime_active) {
        self.ime_marked_changed = true;
        if (bytes.len > 0) self.ime_had_marked = true;
    }
    if (!publish(self, false)) fail(self, &outside);
    return true;
}

pub fn finish(self: *app.AppSession) void {
    if (self.palette_ime_before) |*before| before.deinit(self.allocator);
    self.palette_ime_before = null;
    self.palette_ime_owner = null;
    self.palette_ime_rejected = false;
}

pub fn begin(self: *app.AppSession) void {
    finish(self);
    self.palette_ime_selected_before = self.chrome_host.palette.selected;
    self.palette_ime_filtered_before_len = self.palette_filtered.items.len;
    if (self.palette_ime_filtered_before_len > self.palette_ime_filtered_before.len) {
        self.palette_ime_owner = generation(self);
        self.palette_ime_rejected = true;
        return;
    }
    @memcpy(self.palette_ime_filtered_before[0..self.palette_ime_filtered_before_len], self.palette_filtered.items);
    self.palette_ime_owner = generation(self);
    if (self.palette_ime_owner == null) return;
    _ = projection(self) orelse {
        self.palette_ime_rejected = true;
        return;
    };
    self.palette_ime_before = self.chrome_host.palette.ime_context.clone(self.allocator) catch {
        self.palette_ime_rejected = true;
        return;
    };
}

pub fn end(self: *app.AppSession, event: ?maru.terminal.KeyEvent) bool {
    _ = self.palette_ime_owner orelse return false;
    if (generation(self) == null) return true;
    if (self.palette_ime_rejected) {
        rollbackKey(self);
        return true;
    }
    const context = projection(self) orelse return true;
    if (context.pending) {
        if (self.ime_did_delete) context.cancelInsertedScalar();
        if (!publish(self, true)) rollbackKey(self);
        return true;
    }
    if (self.ime_marked_changed) return true;
    if (event) |key| {
        if (key.key == .backspace and self.ime_did_delete and context.marked == null) {
            if (prepare(self, 0) and self.chrome_host.palette.ime_context.value.deleteBackward()) {
                if (!publish(self, true)) rollbackKey(self);
            } else rollbackKey(self);
            return true;
        }
    }
    return event == null;
}

pub fn commitAll(self: *app.AppSession) bool {
    const context = sync(self) orelse return false;
    if (!context.pending and context.marked == null) return true;
    var before: ?OwnedContext = self.chrome_host.palette.ime_context.clone(self.allocator) catch return false;
    defer if (before) |*value| value.deinit(self.allocator);
    if (!prepare(self, 0) or !self.chrome_host.palette.ime_context.value.admitMarked() or !publish(self, true)) {
        fail(self, &before);
        return false;
    }
    return true;
}
