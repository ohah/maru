//! Restart metadata for one canonical local document and its independent views.
//! Undo, text content, runtime leases and cached geometry are deliberately absent.
//! The enclosing checkpoint owns escaping and document-reference admission.
const std = @import("std");
const selection = @import("selection.zig");
pub const Selection = selection.Selection;
pub const RecoveryId = @import("recovery_id.zig").Id;

pub const Document = struct {
    index: u32,
    recovery_id: RecoveryId,
    path: []const u8,
    disk_hash: ?u64,
    content_hash: u64,
};

pub const View = struct {
    index: usize,
    document: u32,
    primary: selection.Selection,
    extras: []const selection.Selection = &.{},
    first_line: usize = 0,
    first_piece: u32 = 0,
    first_col: u32 = 0,
    wrap: ?bool = null,
    folded: []const u32 = &.{},

    /// Parsed arrays are owned; the primary selection is stored inline.
    pub fn deinit(self: *View, allocator: std.mem.Allocator) void {
        allocator.free(self.extras);
        allocator.free(self.folded);
        self.* = undefined;
    }
};

pub const DecodeError = error{BadRecord} || std.mem.Allocator.Error;

pub fn validateDocument(doc: Document) error{BadRecord}!void {
    if (!doc.recovery_id.valid()) return error.BadRecord;
    if (doc.path.len == 0 or doc.path.len > std.fs.max_path_bytes or
        !std.fs.path.isAbsolute(doc.path) or !std.unicode.utf8ValidateSlice(doc.path) or
        std.mem.indexOfScalar(u8, doc.path, 0) != null) return error.BadRecord;
}

/// Path is last and length-delimited: colons, quotes and newlines remain data.
/// The returned document borrows the decoded payload; its enclosing arena owns it.
pub fn writeDocument(w: *std.Io.Writer, doc: Document) !void {
    try validateDocument(doc);
    try w.print("{d}:{s}:", .{ doc.index, doc.recovery_id.hex() });
    if (doc.disk_hash) |hash| try w.print("{d}", .{hash}) else try w.writeAll("none");
    try w.print(":{d}:{d}:{s}", .{ doc.content_hash, doc.path.len, doc.path });
}

pub fn parseDocument(payload: []const u8) error{BadRecord}!Document {
    var cursor: Cursor = .{ .rest = payload };
    const index = try cursor.uint(u32);
    const recovery_id = RecoveryId.parse(try cursor.token()) catch return error.BadRecord;
    const base = try cursor.token();
    const disk_hash: ?u64 = if (std.mem.eql(u8, base, "none")) null else try number(u64, base);
    const content_hash = try cursor.uint(u64);
    const len = try cursor.uint(usize);
    if (cursor.rest.len != len) return error.BadRecord;
    const result: Document = .{ .index = index, .recovery_id = recovery_id, .path = cursor.rest, .disk_hash = disk_hash, .content_hash = content_hash };
    try validateDocument(result);
    return result;
}

/// Goals depend on the restored font/wrap mapping and are recomputed by the view.
fn writeSelection(w: *std.Io.Writer, value: selection.Selection) !void {
    try w.print("{d}:{d}:{d}:{s}:", .{ value.anchor_start, value.anchor_end, value.focus, @tagName(value.kind) });
}

pub fn writeView(w: *std.Io.Writer, view: View) !void {
    // Restart must not reintroduce more carets than live editing admits.
    if (view.extras.len >= selection.max_cursors) return error.BadRecord;
    try w.print("{d}:{d}:{d}:{d}:{d}:{s}:", .{
        view.index,                                                         view.document, view.first_line, view.first_piece, view.first_col,
        if (view.wrap) |value| (if (value) "on" else "off") else "inherit",
    });
    try writeSelection(w, view.primary);
    try w.print("{d}:", .{view.extras.len});
    for (view.extras) |value| try writeSelection(w, value);
    try w.print("{d}:", .{view.folded.len});
    for (view.folded) |head| try w.print("{d}:", .{head});
}

pub fn parseView(allocator: std.mem.Allocator, payload: []const u8) DecodeError!View {
    var cursor: Cursor = .{ .rest = payload };
    const index = try cursor.uint(usize);
    const document = try cursor.uint(u32);
    const first_line = try cursor.uint(usize);
    const first_piece = try cursor.uint(u32);
    const first_col = try cursor.uint(u32);
    const wrap_token = try cursor.token();
    const wrap: ?bool = if (std.mem.eql(u8, wrap_token, "inherit")) null else if (std.mem.eql(u8, wrap_token, "on")) true else if (std.mem.eql(u8, wrap_token, "off")) false else return error.BadRecord;
    const primary = try cursor.readSelection();
    const extra_count = try cursor.uint(usize);
    // The shortest selection is 0:0:0:line: (11 bytes). Bound declared count
    // by actual remaining input before allocation; numeric overflow cannot trap.
    if (extra_count >= selection.max_cursors or extra_count > cursor.rest.len / 11) return error.BadRecord;
    const extras = try allocator.alloc(selection.Selection, extra_count);
    errdefer allocator.free(extras);
    for (extras) |*value| value.* = try cursor.readSelection();
    const fold_count = try cursor.uint(usize);
    if (fold_count > cursor.rest.len / 2) return error.BadRecord;
    const folded = try allocator.alloc(u32, fold_count);
    errdefer allocator.free(folded);
    for (folded) |*head| head.* = try cursor.uint(u32);
    if (cursor.rest.len != 0) return error.BadRecord;
    return .{ .index = index, .document = document, .primary = primary, .extras = extras, .first_line = first_line, .first_piece = first_piece, .first_col = first_col, .wrap = wrap, .folded = folded };
}

fn number(comptime T: type, token: []const u8) error{BadRecord}!T {
    if (token.len == 0) return error.BadRecord;
    for (token) |byte| if (byte < '0' or byte > '9') return error.BadRecord;
    return std.fmt.parseInt(T, token, 10) catch error.BadRecord;
}

const Cursor = struct {
    rest: []const u8,
    fn token(self: *Cursor) error{BadRecord}![]const u8 {
        const end = std.mem.indexOfScalar(u8, self.rest, ':') orelse return error.BadRecord;
        const result = self.rest[0..end];
        self.rest = self.rest[end + 1 ..];
        return result;
    }
    fn uint(self: *Cursor, comptime T: type) error{BadRecord}!T {
        return number(T, try self.token());
    }
    fn readSelection(self: *Cursor) error{BadRecord}!selection.Selection {
        const start = try self.uint(usize);
        const end = try self.uint(usize);
        const focus = try self.uint(usize);
        const kind = std.meta.stringToEnum(selection.AnchorKind, try self.token()) orelse return error.BadRecord;
        return .{ .anchor_start = start, .anchor_end = end, .focus = focus, .kind = kind };
    }
};

/// Pane identity is checkpoint-local; the same Term index in two panes is valid.
pub const ViewSlot = struct { pane: usize, view: View };

/// This validates editor-only references. The workspace owns mixed Term occupancy.
/// Same paths deliberately remain distinct documents unless their explicit ID agrees.
pub fn validateReferences(allocator: std.mem.Allocator, documents: []const Document, views: []const ViewSlot) DecodeError!void {
    var ids = std.AutoHashMap(u32, usize).init(allocator);
    defer ids.deinit();
    var recoveries = std.AutoHashMap([16]u8, void).init(allocator);
    defer recoveries.deinit();
    const used = try allocator.alloc(bool, documents.len);
    defer allocator.free(used);
    @memset(used, false);
    for (documents, 0..) |doc, index| {
        try validateDocument(doc);
        const recovery_entry = try recoveries.getOrPut(doc.recovery_id.bytes);
        if (recovery_entry.found_existing) return error.BadRecord;
        const entry = try ids.getOrPut(doc.index);
        if (entry.found_existing) return error.BadRecord;
        entry.value_ptr.* = index;
    }
    const Location = struct { pane: usize, index: usize };
    var locations = std.AutoHashMap(Location, void).init(allocator);
    defer locations.deinit();
    for (views) |slot| {
        const doc_index = ids.get(slot.view.document) orelse return error.BadRecord;
        used[doc_index] = true;
        const entry = try locations.getOrPut(.{ .pane = slot.pane, .index = slot.view.index });
        if (entry.found_existing) return error.BadRecord;
    }
    for (used) |present| if (!present) return error.BadRecord;
}

const testing = std.testing;
const test_recovery = RecoveryId{ .bytes = @splat(1) };

test "editor restore codec preserves local path bytes and distinct content/base fingerprints" {
    const doc: Document = .{ .index = 3, .recovery_id = test_recovery, .path = "/tmp/한:글\"\n.zig", .disk_hash = 7, .content_hash = 9 };
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeDocument(&out.writer, doc);
    const restored = try parseDocument(out.written());
    try testing.expectEqualDeep(doc, restored);
    try testing.expectError(error.BadRecord, parseDocument("0:01010101010101010101010101010101:none:1:999:/x"));
    try testing.expectError(error.BadRecord, parseDocument("0:01010101010101010101010101010101:none:1:2:xx"));
    try testing.expectError(error.BadRecord, parseDocument("0:01010101010101010101010101010101:none:1:18446744073709551616:/x"));
}

test "editor restore codec preserves primary direction extras folds and wrap inheritance" {
    for ([_]?bool{ null, false, true }) |wrap| {
        const view: View = .{ .index = 5, .document = 3, .primary = .{ .anchor_start = 6, .anchor_end = 9, .focus = 0, .kind = .word }, .extras = &.{selection.Selection.at(11)}, .first_line = 4, .first_piece = 2, .first_col = 7, .wrap = wrap, .folded = &.{ 0, 3 } };
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        try writeView(&out.writer, view);
        var restored = try parseView(testing.allocator, out.written());
        defer restored.deinit(testing.allocator);
        try testing.expectEqualDeep(view, restored);
    }
}

test "editor restore codec rejects truncation unknown values and inflated counts" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeView(&out.writer, .{ .index = 0, .document = 0, .primary = selection.Selection.at(0), .folded = &.{1} });
    const bytes = out.written();
    for (0..bytes.len) |len| try testing.expectError(error.BadRecord, parseView(testing.allocator, bytes[0..len]));
    try testing.expectError(error.BadRecord, parseView(testing.allocator, "0:0:0:0:0:on:0:0:0:simple:18446744073709551615:0:"));
    try testing.expectError(error.BadRecord, parseView(testing.allocator, "0:0:0:0:0:bad:0:0:0:simple:0:0:"));
    try testing.expectError(error.BadRecord, parseView(testing.allocator, "0:0:0:0:0:on:0:0:0:bad:0:0:"));
    const trailing = try std.mem.concat(testing.allocator, u8, &.{ bytes, "junk" });
    defer testing.allocator.free(trailing);
    try testing.expectError(error.BadRecord, parseView(testing.allocator, trailing));
}

fn oomDecode(allocator: std.mem.Allocator) !void {
    const payload = "0:0:0:0:0:inherit:0:0:0:simple:1:3:3:3:simple:2:1:4:";
    var view = try parseView(allocator, payload);
    defer view.deinit(allocator);
}

test "editor restore codec frees all prepared arrays on allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, oomDecode, .{});
}

test "editor restore codec validates explicit references without merging equal paths" {
    const a: Document = .{ .index = 1, .recovery_id = test_recovery, .path = "/same", .disk_hash = 2, .content_hash = 3 };
    var b = a;
    b.index = 2;
    b.recovery_id = .{ .bytes = @splat(2) };
    b.content_hash = 4;
    const first: View = .{ .index = 0, .document = 1, .primary = selection.Selection.at(0) };
    var independent = first;
    independent.document = 2;
    const slots = [_]ViewSlot{ .{ .pane = 0, .view = first }, .{ .pane = 1, .view = first }, .{ .pane = 1, .view = .{ .index = 1, .document = 2, .primary = selection.Selection.at(0) } } };
    try validateReferences(testing.allocator, &.{ a, b }, &slots);
    try testing.expectError(error.BadRecord, validateReferences(testing.allocator, &.{ a, a }, &slots));
    try testing.expectError(error.BadRecord, validateReferences(testing.allocator, &.{a}, &.{.{ .pane = 0, .view = independent }}));
    try testing.expectError(error.BadRecord, validateReferences(testing.allocator, &.{ a, b }, slots[0..2]));
    try testing.expectError(error.BadRecord, validateReferences(testing.allocator, &.{a}, &.{ .{ .pane = 0, .view = first }, .{ .pane = 0, .view = first } }));
}

fn oomReferences(allocator: std.mem.Allocator) !void {
    try validateReferences(allocator, &.{.{ .index = 1, .recovery_id = test_recovery, .path = "/doc", .disk_hash = null, .content_hash = 1 }}, &.{.{ .pane = 0, .view = .{ .index = 0, .document = 1, .primary = selection.Selection.at(0) } }});
}

test "editor restore codec reference admission frees scratch state on every allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, oomReferences, .{});
}

test "editor restore codec enforces the existing total cursor limit before allocation or emission" {
    const extras = try testing.allocator.alloc(selection.Selection, selection.max_cursors);
    defer testing.allocator.free(extras);
    @memset(extras, selection.Selection.at(0));
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expectError(error.BadRecord, writeView(&out.writer, .{ .index = 0, .document = 0, .primary = selection.Selection.at(0), .extras = extras }));
    try testing.expectEqual(@as(usize, 0), out.written().len);
    // Build an otherwise valid oversized input without the guarded writer.
    try out.writer.print("0:0:0:0:0:inherit:0:0:0:simple:{d}:", .{extras.len});
    for (extras) |value| try writeSelection(&out.writer, value);
    try out.writer.writeAll("0:");
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(error.BadRecord, parseView(failing.allocator(), out.written()));
    try testing.expect(!failing.has_induced_failure);
    out.clearRetainingCapacity();
    try writeView(&out.writer, .{ .index = 0, .document = 0, .primary = selection.Selection.at(0), .extras = extras[0 .. selection.max_cursors - 1] });
    var restored = try parseView(testing.allocator, out.written());
    defer restored.deinit(testing.allocator);
    try testing.expectEqual(selection.max_cursors - 1, restored.extras.len);
}

test "editor restore codec rejects one recovery identity assigned to independent descriptors" {
    const a: Document = .{ .index = 1, .recovery_id = test_recovery, .path = "/a", .disk_hash = 1, .content_hash = 2 };
    var b = a;
    b.index = 2;
    b.path = "/b";
    const slots = [_]ViewSlot{
        .{ .pane = 0, .view = .{ .index = 0, .document = 1, .primary = Selection.at(0) } },
        .{ .pane = 1, .view = .{ .index = 0, .document = 2, .primary = Selection.at(0) } },
    };
    try testing.expectError(error.BadRecord, validateReferences(testing.allocator, &.{ a, b }, &slots));
    b.recovery_id = .{ .bytes = @splat(2) };
    try validateReferences(testing.allocator, &.{ a, b }, &slots);
}

test "editor restore codec rejects absent invalid or zero identity before emitting metadata" {
    try testing.expectError(error.BadRecord, parseDocument("1:none:2:2:/a"));
    try testing.expectError(error.BadRecord, parseDocument("1:00000000000000000000000000000000:none:2:2:/a"));
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expectError(error.BadRecord, writeDocument(&out.writer, .{ .index = 1, .recovery_id = .{ .bytes = @splat(0) }, .path = "/a", .disk_hash = null, .content_hash = 2 }));
    try testing.expectEqual(@as(usize, 0), out.written().len);
    try writeDocument(&out.writer, .{ .index = 1, .recovery_id = test_recovery, .path = "/a", .disk_hash = null, .content_hash = 2 });
    const bytes = out.written();
    for (0..bytes.len) |n| try testing.expectError(error.BadRecord, parseDocument(bytes[0..n]));
}
