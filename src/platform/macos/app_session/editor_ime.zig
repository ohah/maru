//! NSTextInputClient's document ranges live at the editor boundary, not in the terminal grid.
//! The document stays unchanged while marked text is visible; commits still use the key transaction
//! so the Korean input method's insertText + deleteBackward pair can cancel the last jamo.
const std = @import("std");
const maru = @import("maru");
const app = @import("../app_session.zig");
const input = @import("input.zig");
const editor = @import("editor/mod.zig");
const ranges = maru.session.editor.text_input;
pub const Range = ranges.Utf16Range;
pub const State = struct { selected: Range, marked: Range };

fn target(self: *app.AppSession) ?*app.Term {
    const term = input.activeEditorTermForIme(self) orelse return null;
    if (term.rt.editor_diff != null or term.rt.editorDocument().opened == null) return null;
    return term;
}

fn pending(self: *app.AppSession, term: *app.Term) []const u8 {
    _ = term;
    if (!self.ime_active and !self.ime_editor_commit_pending) return "";
    return self.ime_inserted.items;
}

/// Borrowed pieces of the input method's current document. The committed prefix in this key's
/// transaction is visible to AppKit before it is applied to the canonical document at imeEnd.
pub const Projection = struct {
    segments: [5][]const u8,
    replacement: ranges.ByteRange,
    prefix_units: u64,
    queued_units: u64,
    marked_units: u64,
    has_splice: bool,
    selected: Range,
    selected_bytes: ranges.ByteRange,
};

pub fn projection(self: *app.AppSession) ?Projection {
    _ = input.validateEditorCommit(self);
    return project(self, target(self) orelse return null);
}

fn project(self: *app.AppSession, term: *app.Term) ?Projection {
    const selection = term.rt.editor_selection orelse return null;
    const content = term.rt.editorDocument().opened.?.file.content;
    const queued = pending(self, term);
    // Deletion retries have zero bytes but retain a replacement range. Queries and direct callbacks
    // must see that splice too, or the next callback revives the canonical jamo slated for deletion.
    const has_queued = queued.len > 0 or
        ((self.ime_active or self.ime_editor_commit_pending) and term.rt.editor_ime_replacement != null);
    const has_splice = has_queued or term.rt.editor_preedit.len > 0;
    const replacement: ranges.ByteRange = if (has_queued)
        term.rt.editor_ime_replacement orelse .{ .start = selection.start(), .end = selection.end() }
    else if (term.rt.editor_preedit.len > 0)
        .{ .start = term.rt.editor_preedit_at, .end = term.rt.editor_preedit_end }
    else
        .{ .start = selection.start(), .end = selection.start() };
    if (replacement.start > replacement.end or replacement.end > content.len) return null;
    const queued_selection = term.rt.editor_ime_commit_selection orelse ranges.ByteRange{ .start = replacement.start + queued.len, .end = replacement.start + queued.len };
    const queued_caret = @min(queued_selection.start -| replacement.start, queued.len);
    const prefix_units = ranges.utf16Offset(content, replacement.start) orelse return null;
    const queued_units = ranges.utf16Offset(queued, queued_caret) orelse return null;
    const local_selection = if (term.rt.editor_preedit.len > 0)
        ranges.byteRange(term.rt.editor_preedit, term.rt.editor_preedit_selected) orelse return null
    else
        ranges.ByteRange{ .start = 0, .end = 0 };
    const selected_bytes: ranges.ByteRange = if (term.rt.editor_preedit.len > 0) .{
        .start = replacement.start + queued_caret + local_selection.start,
        .end = replacement.start + queued_caret + local_selection.end,
    } else if (has_queued) queued_selection else .{ .start = selection.start(), .end = selection.end() };
    const segments: [5][]const u8 = .{ content[0..replacement.start], queued[0..queued_caret], term.rt.editor_preedit, queued[queued_caret..], content[replacement.end..] };
    const selected_start = virtualUnits(&segments, selected_bytes.start) orelse return null;
    const selected_end = virtualUnits(&segments, selected_bytes.end) orelse return null;
    return .{
        .segments = segments,
        .replacement = replacement,
        .prefix_units = prefix_units,
        .queued_units = queued_units,
        .marked_units = ranges.utf16Length(term.rt.editor_preedit) orelse return null,
        .has_splice = has_splice,
        .selected = .{ .location = selected_start, .length = selected_end - selected_start },
        .selected_bytes = selected_bytes,
    };
}

fn virtualUnits(segments: []const []const u8, offset: usize) ?u64 {
    var bytes = offset;
    var units: u64 = 0;
    for (segments) |segment| {
        if (bytes <= segment.len) return units + (ranges.utf16Offset(segment, bytes) orelse return null);
        units += ranges.utf16Length(segment) orelse return null;
        bytes -= segment.len;
    }
    return null;
}

/// Queries include this key's queued commit. AppKit may ask between insertText and the next marked
/// callback, before imeEnd has committed the document. Returning the old caret then loses a syllable.
pub fn state(self: *app.AppSession) ?State {
    _ = input.validateEditorCommit(self);
    const term = target(self) orelse return null;
    _ = term.rt.editor_selection orelse return .{
        .selected = .{ .location = std.math.maxInt(u64), .length = 0 },
        .marked = .{ .location = std.math.maxInt(u64), .length = 0 },
    };
    const visible = project(self, term) orelse return null;
    const location = visible.prefix_units + visible.queued_units;
    if (term.rt.editor_preedit.len > 0) return .{
        .marked = .{ .location = location, .length = visible.marked_units },
        .selected = visible.selected,
    };
    const selected = visible.selected;
    // NSTextView also returns an empty range when no text is marked. Keeping it at the real caret
    // preserves Korean input-method behaviour without advertising a fictitious document position 0.
    return .{ .selected = selected, .marked = .{ .location = selected.location, .length = 0 } };
}

fn requestedRange(term: *app.Term, visible: Projection, requested: ?Range) ?Range {
    if (requested) |range| return range;
    if (term.rt.editor_preedit.len > 0) return .{
        .location = visible.prefix_units + visible.queued_units,
        .length = visible.marked_units,
    };
    if (visible.has_splice) return visible.selected;
    const selection = term.rt.editor_selection orelse return null;
    return ranges.utf16Range(term.rt.editorDocument().opened.?.file.content, .{ .start = selection.start(), .end = selection.end() });
}

fn virtualOffset(visible: Projection, offset: u64) ?usize {
    var units = offset;
    var bytes: usize = 0;
    for (visible.segments) |segment| {
        const length = ranges.utf16Length(segment) orelse return null;
        if (units <= length) return bytes + (ranges.byteOffset(segment, units) orelse return null);
        units -= length;
        bytes += segment.len;
    }
    return null;
}

/// Only materialize the union of the current splice and the requested replacement. This keeps an
/// input callback from copying the whole document, while allowing endpoints inside marked text.
const Prepared = struct {
    replacement: ranges.ByteRange,
    text: []u8,
    after_len: usize,
    selected: ranges.ByteRange,
};

fn prepare(allocator: std.mem.Allocator, visible: Projection, requested: Range, inserted: []const u8) ?Prepared {
    const end_units = std.math.add(u64, requested.location, requested.length) catch return null;
    const start = virtualOffset(visible, requested.location) orelse return null;
    const end = virtualOffset(visible, end_units) orelse return null;
    const splice_start = visible.segments[0].len;
    const splice_end = splice_start + visible.segments[1].len + visible.segments[2].len + visible.segments[3].len;
    const union_start = if (visible.has_splice) @min(start, splice_start) else start;
    const union_end = if (visible.has_splice) @max(end, splice_end) else end;
    const replacement: ranges.ByteRange = if (visible.has_splice) .{
        .start = union_start,
        .end = visible.replacement.end + (union_end - splice_end),
    } else .{ .start = union_start, .end = union_end };
    const before_len = start - union_start;
    const after_len = union_end - end;
    const with_before = std.math.add(usize, before_len, inserted.len) catch return null;
    const length = std.math.add(usize, with_before, after_len) catch return null;
    const text = allocator.alloc(u8, length) catch return null;
    copyVirtual(visible, union_start, text[0..before_len]);
    @memcpy(text[before_len..with_before], inserted);
    copyVirtual(visible, end, text[with_before..]);
    const selection = visible.selected_bytes;
    const selected: ranges.ByteRange = if (selection.end <= start and selection.start < start) .{
        .start = selection.start,
        .end = selection.end,
    } else if (selection.start >= end) .{
        .start = selection.start - end + start + inserted.len,
        .end = selection.end - end + start + inserted.len,
    } else .{ .start = start + inserted.len, .end = start + inserted.len };
    return .{ .replacement = replacement, .text = text, .after_len = after_len, .selected = selected };
}

fn copyVirtual(visible: Projection, start: usize, out: []u8) void {
    var skip = start;
    var copied: usize = 0;
    for (visible.segments) |segment| {
        if (skip >= segment.len) {
            skip -= segment.len;
            continue;
        }
        const count = @min(segment.len - skip, out.len - copied);
        @memcpy(out[copied..][0..count], segment[skip..][0..count]);
        copied += count;
        if (copied == out.len) return;
        skip = 0;
    }
    std.debug.assert(copied == out.len);
}

pub fn insert(self: *app.AppSession, bytes: []const u8, replacement: ?Range) bool {
    if (!input.validateEditorCommit(self)) return true;
    const term = target(self) orelse return false;
    const resumed = input.resumeEditorCommitForCallback(self);
    defer if (resumed) input.imeEnd(self, null);
    // A rejected callback still consumed this key. Otherwise imeEnd can replay its physical
    // Backspace at an unrelated caret after refusing the input method's replacement range.
    if (self.ime_active) self.ime_marked_changed = true;
    if (self.ime_editor_commit_pending) return true;
    if (term.rt.editorDocument().opened.?.file.read_only) return true;
    // Returning true means this is an editor callback, including rejection. Falling through after an
    // invalid range would insert the same bytes at an unrelated caret via the legacy terminal route.
    if (ranges.utf16Length(bytes) == null) return true;
    const visible = project(self, term) orelse return true;
    const requested = requestedRange(term, visible, replacement) orelse return true;
    if (term.rt.editor_preedit.len == 0 and pendingSelectionOutside(visible)) {
        const requested_end = std.math.add(u64, requested.location, requested.length) catch return true;
        var query = editor.IMECommitQuery{ .before = .{
            .start = virtualOffset(visible, requested.location) orelse return true,
            .end = virtualOffset(visible, requested_end) orelse return true,
        } };
        if (!editor.insertDirectIMETextAndMapRange(self, term, self.ime_inserted.items, visible.replacement, visible.selected_bytes, &query)) return true;
        self.ime_inserted.clearRetainingCapacity();
        term.rt.editor_ime_replacement = null;
        term.rt.editor_ime_commit_selection = null;
        const mapped = if (replacement != null) ranges.utf16Range(term.rt.editorDocument().opened.?.file.content, query.after) orelse return true else null;
        return insert(self, bytes, mapped);
    }
    // Plain typing still uses typing aids; explicit replacement and composition are literal edits.
    if (!visible.has_splice and replacement == null and bytes.len > 0) {
        if (self.ime_terminal_target_id == null) self.ime_terminal_target_id = term.surface.id;
        input.imeInsert(self, bytes);
        if (!self.ime_active) self.ime_terminal_target_id = null;
        return true;
    }
    const prepared = prepare(self.allocator, visible, requested, bytes) orelse return true;
    defer self.allocator.free(prepared.text);
    if (prepared.text.len == 0 and prepared.replacement.start == prepared.replacement.end) {
        self.ime_inserted.clearRetainingCapacity();
        term.rt.editor_ime_replacement = null;
        term.rt.editor_ime_commit_selection = null;
        input.imeMarked(self, "");
    } else if (self.ime_active and prepared.text.len > 0) {
        // Explicit replacement may edit this key's queued text too. Replacing the queue, after its
        // allocation succeeds, prevents a second callback from appending a duplicate old syllable.
        self.ime_inserted.ensureTotalCapacity(self.allocator, prepared.text.len) catch return true;
        self.ime_inserted.clearRetainingCapacity();
        self.ime_inserted.appendSliceAssumeCapacity(prepared.text);
        term.rt.editor_ime_replacement = prepared.replacement;
        term.rt.editor_ime_commit_selection = prepared.selected;
        if (self.ime_terminal_target_id == null) self.ime_terminal_target_id = term.surface.id;
        input.imeMarked(self, "");
    } else if (editor.insertDirectIMETextAtSelection(self, term, prepared.text, prepared.replacement, prepared.selected)) {
        self.ime_inserted.clearRetainingCapacity();
        term.rt.editor_ime_replacement = null;
        term.rt.editor_ime_commit_selection = null;
        input.imeMarked(self, "");
    }
    if (!self.ime_active and term.rt.editor_preedit.len == 0) self.ime_terminal_target_id = null;
    return true;
}

fn pendingSelectionOutside(visible: Projection) bool {
    const queued_len = visible.segments[1].len + visible.segments[3].len;
    return queued_len > 0 and (visible.selected_bytes.start < visible.replacement.start or visible.selected_bytes.end > visible.replacement.start + queued_len);
}

pub fn marked(self: *app.AppSession, bytes: []const u8, selected: Range, replacement: ?Range) bool {
    if (!input.validateEditorCommit(self)) return true;
    const term = target(self) orelse return false;
    const resumed = input.resumeEditorCommitForCallback(self);
    defer if (resumed) input.imeEnd(self, null);
    if (self.ime_active) self.ime_marked_changed = true; // Rejection must not replay the physical key.
    if (self.ime_editor_commit_pending) return true;
    if (term.rt.editorDocument().opened.?.file.read_only) return true;
    _ = ranges.utf16Length(bytes) orelse return true;
    _ = ranges.byteRange(bytes, selected) orelse return true;
    const visible = project(self, term) orelse return true;
    const requested = requestedRange(term, visible, replacement) orelse return true;
    if (term.rt.editor_preedit.len == 0 and pendingSelectionOutside(visible)) {
        // A disjoint explicit edit can leave the caret outside its pending bytes. Admit that exact
        // edit before starting another mark, or materializing their union would merge unrelated
        // secondary carets and replicate the intervening canonical text into them.
        const requested_end = std.math.add(u64, requested.location, requested.length) catch return true;
        var query = editor.IMECommitQuery{ .before = .{
            .start = virtualOffset(visible, requested.location) orelse return true,
            .end = virtualOffset(visible, requested_end) orelse return true,
        } };
        const next = self.allocator.dupe(u8, bytes) catch return true;
        defer if (next.len == 0) self.allocator.free(next);
        if (!editor.insertDirectIMETextAndMapRange(self, term, self.ime_inserted.items, visible.replacement, visible.selected_bytes, &query)) {
            if (next.len > 0) self.allocator.free(next);
            return true;
        }
        self.ime_inserted.clearRetainingCapacity();
        term.rt.editor_ime_replacement = null;
        term.rt.editor_ime_commit_selection = null;
        // The default range follows the real primary selection. An explicit range instead follows
        // its queried text through the actual multicursor delta, including merged edit ranges.
        const canonical = if (replacement != null) query.after else ranges.ByteRange{
            .start = term.rt.editor_selection.?.start(),
            .end = term.rt.editor_selection.?.end(),
        };
        if (next.len == 0 and canonical.start != canonical.end) {
            if (!editor.insertIMEText(self, term, "", canonical)) return true;
        }
        term.rt.editor_preedit = if (next.len > 0) next else &.{};
        term.rt.editor_preedit_at = canonical.start;
        term.rt.editor_preedit_end = canonical.end;
        term.rt.editor_preedit_selected = selected;
        if (bytes.len > 0 and self.ime_terminal_target_id == null) self.ime_terminal_target_id = term.surface.id;
        self.metal_dirty = true;
        if (self.ime_active) self.ime_marked_changed = true;
        if (!self.ime_active and term.rt.editor_preedit.len == 0) self.ime_terminal_target_id = null;
        return true;
    }
    const whole_marked = requested.location == visible.prefix_units + visible.queued_units and requested.length == visible.marked_units;
    if (!visible.has_splice or whole_marked) {
        const canonical = if (visible.has_splice) visible.replacement else ranges.byteRange(term.rt.editorDocument().opened.?.file.content, requested) orelse return true;
        // Empty marked text can delete a replaced canonical selection. A pending commit already
        // owns that replacement, and must remain cancellable until the last-jamo key ends.
        if (bytes.len == 0 and visible.segments[1].len + visible.segments[3].len == 0 and canonical.start != canonical.end and
            !(self.ime_active and term.rt.editor_ime_replacement != null))
        {
            if (!editor.insertIMEText(self, term, "", canonical)) return true;
        }
        input.imeMarked(self, bytes);
        if (bytes.len > 0 and std.mem.eql(u8, term.rt.editor_preedit, bytes)) {
            if (self.ime_terminal_target_id == null) self.ime_terminal_target_id = term.surface.id;
            term.rt.editor_preedit_at = canonical.start;
            term.rt.editor_preedit_end = canonical.end;
            term.rt.editor_preedit_selected = selected;
        }
        if (!self.ime_active and term.rt.editor_preedit.len == 0) self.ime_terminal_target_id = null;
        return true;
    }

    // NSTextView commits the parts outside a partial replacement: marking a😀b then replacing 😀
    // by marked X leaves committed a/b around X. Only those surrounding bytes enter the document;
    // the new marked bytes stay outside save, undo and LSP text like every other composition.
    const prepared = prepare(self.allocator, visible, requested, "") orelse return true;
    defer self.allocator.free(prepared.text);
    const next = self.allocator.dupe(u8, bytes) catch return true;
    defer if (next.len == 0) self.allocator.free(next);
    if (!editor.insertIMEText(self, term, prepared.text, prepared.replacement)) {
        if (next.len > 0) self.allocator.free(next);
        return true;
    }
    self.ime_inserted.clearRetainingCapacity();
    term.rt.editor_ime_replacement = null;
    term.rt.editor_ime_commit_selection = null;
    // Every secondary caret received the same context. Put each one before the preserved suffix so
    // the eventual marked commit is replicated at the same relative position, in one delta.
    if (term.rt.editor_selection) |selection| {
        term.rt.editor_selection = maru.session.editor.selection.Selection.at(selection.focus - prepared.after_len);
    }
    for (term.rt.editor_extra_selections) |*selection| {
        selection.* = maru.session.editor.selection.Selection.at(selection.focus - prepared.after_len);
    }
    if (term.rt.editor_preedit.len > 0) self.allocator.free(term.rt.editor_preedit);
    term.rt.editor_preedit = if (next.len > 0) next else &.{};
    if (term.rt.editor_selection) |selection| {
        term.rt.editor_preedit_at = selection.start();
        term.rt.editor_preedit_end = selection.end();
    }
    term.rt.editor_preedit_selected = selected;
    if (bytes.len > 0 and self.ime_terminal_target_id == null) self.ime_terminal_target_id = term.surface.id;
    self.metal_dirty = true;
    if (self.ime_active) self.ime_marked_changed = true;
    if (!self.ime_active and term.rt.editor_preedit.len == 0) self.ime_terminal_target_id = null;
    return true;
}
