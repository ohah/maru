//! Main-thread edit/history publication shared by native hosts. Every connected
//! view participates; allocations finish before body or live history changes.
const std = @import("std");
const state_mod = @import("document_state.zig");
const navigation = @import("view_navigation.zig");
const selection = @import("selection.zig");
const delta = @import("delta.zig");
const history = @import("history.zig");
const shared = @import("shared_edit.zig");
const grapheme = @import("../../grapheme.zig");
const File = @import("edit_doc.zig").EditableFile;

pub const Participant = struct { view: *navigation.View, id: u64 };
pub const Command = union(enum) { insert: []const u8, backspace, delete_forward, undo, redo };
pub const Event = struct { now_ms: u64, isolate: bool = false };
const stack_limit = 2048;
const group_gap_ms = 500;

const Prepared = struct {
    storage: []selection.Selection,
    count: usize,
    primary: usize,
};

fn prepare(a: std.mem.Allocator, views: []const Participant, restore_owner: usize, restore_count: usize) ![]Prepared {
    const prepared = try a.alloc(Prepared, views.len);
    var built: usize = 0;
    errdefer {
        for (prepared[0..built]) |p| a.free(p.storage);
        a.free(prepared);
    }
    for (views, prepared, 0..) |v, *p, i| {
        const count = @max(1, v.view.items.items.len);
        const capacity = @max(count, if (i == restore_owner) restore_count else 0);
        const storage = try a.alloc(selection.Selection, capacity);
        p.* = .{ .storage = storage, .count = count, .primary = if (v.view.items.items.len == 0) 0 else v.view.primary };
        built += 1;
        if (v.view.items.items.len == 0) storage[0] = selection.Selection.at(0) else @memcpy(storage[0..count], v.view.items.items);
        if (p.primary >= count) return error.InvalidSelection;
        // Only capacity may change on failure; visible items remain untouched.
        try v.view.items.ensureTotalCapacity(a, capacity);
    }
    return prepared;
}

fn release(a: std.mem.Allocator, prepared: []Prepared) void {
    for (prepared) |p| a.free(p.storage);
    a.free(prepared);
}

fn reserve(a: std.mem.Allocator, stack: *[]history.Entry, count: usize) !void {
    if (stack.len >= count) return;
    stack.* = try a.realloc(stack.*, @max(count, @max(16, stack.len * 2)));
}

fn append(a: std.mem.Allocator, stack: []history.Entry, count: *usize, entry: history.Entry) void {
    stack[count.*] = entry;
    count.* += 1;
    if (count.* > stack_limit) {
        const drop = count.* - stack_limit;
        for (stack[0..drop]) |*e| e.deinit(a);
        std.mem.copyForwards(history.Entry, stack[0 .. count.* - drop], stack[drop..count.*]);
        count.* -= drop;
    }
}

fn boundary(file: *const File, offset: usize, up: bool) usize {
    const at = @min(offset, file.content.len);
    const line = file.lines.lines[file.lines.lineAt(at)];
    const bytes = file.content[line.start..line.contentEnd()];
    const local = @min(at, line.contentEnd()) - line.start;
    const floor = grapheme.snapToBoundary(bytes, local);
    return line.start + if (up and floor < local) grapheme.clusterEnd(bytes, floor) else floor;
}

fn normalize(file: *const File, s: selection.Selection) selection.Selection {
    var result = s;
    const point_anchor = s.anchor_start == s.anchor_end;
    result.anchor_start = boundary(file, s.anchor_start, point_anchor);
    result.anchor_end = boundary(file, s.anchor_end, true);
    result.focus = boundary(file, s.focus, !s.isReversed());
    result.goal = .none;
    result.anchor_goal = .none;
    return result;
}

fn publish(file: *const File, views: []const Participant, prepared: []Prepared) void {
    for (views, prepared) |v, *p| {
        for (p.storage[0..p.count]) |*s| s.* = normalize(file, s.*);
        const merged = selection.mergeOverlapping(p.storage[0..p.count], p.primary);
        v.view.items.items.len = merged.len;
        @memcpy(v.view.items.items, p.storage[0..merged.len]);
        v.view.primary = merged.primary;
    }
}

fn adjacent(file: *const File, at: usize, backwards: bool) usize {
    return navigation.destination(file, at, if (backwards) .left else .right);
}

/// Hosts supply the connected-view set and their monotonic input timestamp.
/// The policy does not import a window, terminal, clock or renderer.
pub fn run(a: std.mem.Allocator, state: *state_mod.State, views: []const Participant, actor: usize, command: Command, event: Event) !bool {
    if (actor >= views.len) return error.InvalidSelection;
    for (views, 0..) |v, i| for (views[0..i]) |earlier| {
        if (v.id == earlier.id or v.view == earlier.view) return error.InvalidSelection;
    };
    const file = if (state.opened) |*opened| &opened.file else return error.NoDocument;
    if (file.read_only) return error.ReadOnly;
    if (command == .undo or command == .redo) return step(a, state, views, actor, command == .undo);
    const text: []const u8 = if (command == .insert) command.insert else "";
    if (!std.unicode.utf8ValidateSlice(text)) return error.NotUtf8;
    const prepared = try prepare(a, views, actor, 0);
    defer release(a, prepared);
    const active = &prepared[actor];
    for (active.storage[0..active.count]) |s| {
        if (s.end() > file.content.len) return error.OutOfRange;
    }
    const initial = selection.mergeOverlapping(active.storage[0..active.count], active.primary);
    active.count = initial.len;
    active.primary = initial.primary;
    const before = try a.dupe(selection.Selection, active.storage[0..active.count]);
    errdefer a.free(before);
    const primary_before = active.primary;
    if (command != .insert) {
        for (active.storage[0..active.count]) |*s| {
            if (s.isEmpty()) {
                const at = boundary(file, s.focus, true);
                s.* = selection.Selection.fromPoints(at, adjacent(file, at, command == .backspace));
            }
        }
        const merged = selection.mergeOverlapping(active.storage[0..active.count], active.primary);
        active.count = merged.len;
        active.primary = merged.primary;
    }
    const changes = try a.alloc(delta.Change, active.count);
    defer a.free(changes);
    var any = false;
    for (active.storage[0..active.count], changes) |s, *c| {
        c.* = .{ .start = boundary(file, s.start(), false), .end = boundary(file, s.end(), true), .text = text };
        any = any or c.start != c.end or text.len != 0;
    }
    if (!any) {
        a.free(before);
        return false;
    }
    try reserve(a, &state.history.undo, state.history.undo_len + 1);
    var sels = selection.Selections.init(active.storage[0..active.count], active.primary);
    const inverse = try file.apply(.{ .changes = changes }, &sels);
    // No fallible operation follows publication of the new body.
    for (inverse.changes, active.storage[0..active.count]) |c, *s| s.* = selection.Selection.at(c.end);
    for (prepared, 0..) |*p, i| {
        if (i == actor) continue;
        for (p.storage[0..p.count]) |*s| s.* = shared.mapSelection(.{ .changes = changes }, s.*);
    }
    publish(file, views, prepared);
    views[actor].view.visible = true;
    const h = &state.history;
    const kind: history.EditKind = if (command == .insert) .insert else .delete;
    const previous_owner = if (h.undo_len == 0) 0 else h.undo[h.undo_len - 1].view_id;
    const same = !event.isolate and h.last_edit_kind == kind and previous_owner == views[actor].id and event.now_ms >= h.last_edit_ms and event.now_ms - h.last_edit_ms <= group_gap_ms;
    if (!same) h.edit_group +%= 1;
    for (h.redo[0..h.redo_len]) |*e| e.deinit(a);
    h.redo_len = 0;
    append(a, h.undo, &h.undo_len, .{ .inverse = inverse, .sels_before = before, .primary_before = primary_before, .group = h.edit_group, .view_id = views[actor].id });
    h.last_edit_kind = if (event.isolate) .none else kind;
    h.last_edit_ms = event.now_ms;
    return true;
}

fn step(a: std.mem.Allocator, state: *state_mod.State, views: []const Participant, actor: usize, undo: bool) !bool {
    const h = &state.history;
    const from = if (undo) &h.undo else &h.redo;
    const from_len = if (undo) &h.undo_len else &h.redo_len;
    const to = if (undo) &h.redo else &h.undo;
    const to_len = if (undo) &h.redo_len else &h.undo_len;
    if (from_len.* == 0) return false;
    const group = from.*[from_len.* - 1].group;
    var changed = false;
    while (from_len.* > 0 and from.*[from_len.* - 1].group == group) {
        stepOne(a, state, views, actor, from, from_len, to, to_len) catch |err| {
            // The existing grouped-history contract retains successfully applied
            // entries if a later entry cannot be prepared.
            if (changed) return true;
            return err;
        };
        changed = true;
    }
    h.last_edit_kind = .none;
    return changed;
}

fn stepOne(a: std.mem.Allocator, state: *state_mod.State, views: []const Participant, actor: usize, from: *[]history.Entry, from_len: *usize, to: *[]history.Entry, to_len: *usize) !void {
    const entry = from.*[from_len.* - 1];
    var owner = actor;
    for (views, 0..) |v, i| if (v.id == entry.view_id) {
        owner = i;
        break;
    };
    const prepared = try prepare(a, views, owner, entry.sels_before.len);
    defer release(a, prepared);
    const current = &prepared[owner];
    const mirror = try a.dupe(selection.Selection, current.storage[0..current.count]);
    errdefer a.free(mirror);
    const primary = current.primary;
    try reserve(a, to, to_len.* + 1);
    var sels: selection.Selections = .{ .items = &.{}, .primary = 0 };
    const file = &state.opened.?.file;
    const back = try file.apply(entry.inverse.delta(), &sels);
    for (prepared, 0..) |*p, i| {
        if (i == owner) continue;
        for (p.storage[0..p.count]) |*s| s.* = shared.mapSelection(entry.inverse.delta(), s.*);
    }
    @memcpy(current.storage[0..entry.sels_before.len], entry.sels_before);
    current.count = entry.sels_before.len;
    current.primary = entry.primary_before;
    publish(file, views, prepared);
    views[owner].view.visible = true;
    from_len.* -= 1;
    append(a, to.*, to_len, .{ .inverse = back, .sels_before = mirror, .primary_before = primary, .group = entry.group, .view_id = views[owner].id });
    var disposed = entry;
    disposed.deinit(a);
    state.history.last_edit_kind = .none;
}

fn testState(a: std.mem.Allocator, bytes: []const u8) !state_mod.State {
    const file = try File.init(a, bytes, false);
    return .{ .opened = .{ .file = file, .saved_hash = state_mod.contentHash(file.content) } };
}

test "Editor commands: shared typing undo redo restore owner selection and dirty" {
    const a = std.testing.allocator;
    var state = try testState(a, "abc");
    defer state.clear(a);
    var first: navigation.View = .{};
    defer first.deinit(a);
    var second: navigation.View = .{};
    defer second.deinit(a);
    try first.items.append(a, selection.Selection.at(1));
    try second.items.append(a, selection.Selection.at(3));
    const views = [_]Participant{ .{ .view = &first, .id = 1 }, .{ .view = &second, .id = 2 } };
    try std.testing.expect(try run(a, &state, &views, 0, .{ .insert = "X" }, .{ .now_ms = 100 }));
    try std.testing.expectEqualStrings("aXbc", state.opened.?.file.content);
    try std.testing.expectEqual(@as(usize, 2), first.items.items[0].focus);
    try std.testing.expectEqual(@as(usize, 4), second.items.items[0].focus);
    try std.testing.expect(state.opened.?.isDirty());
    try std.testing.expect(try run(a, &state, &views, 1, .undo, .{ .now_ms = 101 }));
    try std.testing.expectEqualStrings("abc", state.opened.?.file.content);
    try std.testing.expectEqual(@as(usize, 1), first.items.items[0].focus);
    try std.testing.expectEqual(@as(usize, 3), second.items.items[0].focus);
    try std.testing.expect(!state.opened.?.isDirty());
    try std.testing.expect(try run(a, &state, &views, 1, .redo, .{ .now_ms = 102 }));
    try std.testing.expectEqualStrings("aXbc", state.opened.?.file.content);
    try std.testing.expectEqual(@as(usize, 2), first.items.items[0].focus);
    try std.testing.expectEqual(@as(usize, 4), second.items.items[0].focus);
}

test "Editor commands: grapheme deletion CRLF and overlapping delete carets stay atomic" {
    const a = std.testing.allocator;
    var state = try testState(a, "a\u{1100}\u{1161}\u{11a8}\r\nb");
    defer state.clear(a);
    var view: navigation.View = .{};
    defer view.deinit(a);
    try view.items.append(a, selection.Selection.at(10));
    const views = [_]Participant{.{ .view = &view, .id = 1 }};
    _ = try run(a, &state, &views, 0, .backspace, .{ .now_ms = 1, .isolate = true });
    try std.testing.expectEqualStrings("a\r\nb", state.opened.?.file.content);
    _ = try run(a, &state, &views, 0, .delete_forward, .{ .now_ms = 2, .isolate = true });
    try std.testing.expectEqualStrings("ab", state.opened.?.file.content);
    _ = try run(a, &state, &views, 0, .undo, .{ .now_ms = 3 });
    try std.testing.expectEqualStrings("a\r\nb", state.opened.?.file.content);
    view.items.clearRetainingCapacity();
    try view.items.appendSlice(a, &.{ selection.Selection.fromPoints(0, 1), selection.Selection.at(1) });
    _ = try run(a, &state, &views, 0, .backspace, .{ .now_ms = 4 });
    try std.testing.expectEqualStrings("\r\nb", state.opened.?.file.content);
    try std.testing.expectEqual(@as(usize, 1), view.items.items.len);
}

test "Editor commands: time and view boundaries split groups and new typing clears redo" {
    const a = std.testing.allocator;
    var state = try testState(a, "");
    defer state.clear(a);
    var first: navigation.View = .{};
    defer first.deinit(a);
    var second: navigation.View = .{};
    defer second.deinit(a);
    const views = [_]Participant{ .{ .view = &first, .id = 1 }, .{ .view = &second, .id = 2 } };
    _ = try run(a, &state, &views, 0, .{ .insert = "a" }, .{ .now_ms = 0 });
    _ = try run(a, &state, &views, 0, .{ .insert = "b" }, .{ .now_ms = 100 });
    _ = try run(a, &state, &views, 0, .{ .insert = "c" }, .{ .now_ms = 601 });
    _ = try run(a, &state, &views, 1, .{ .insert = "d" }, .{ .now_ms = 602 });
    _ = try run(a, &state, &views, 0, .undo, .{ .now_ms = 603 });
    try std.testing.expectEqualStrings("abc", state.opened.?.file.content);
    _ = try run(a, &state, &views, 0, .undo, .{ .now_ms = 604 });
    try std.testing.expectEqualStrings("ab", state.opened.?.file.content);
    _ = try run(a, &state, &views, 0, .undo, .{ .now_ms = 605 });
    try std.testing.expectEqualStrings("", state.opened.?.file.content);
    _ = try run(a, &state, &views, 0, .{ .insert = "z" }, .{ .now_ms = 606 });
    try std.testing.expectEqual(@as(usize, 0), state.history.redo_len);
    state.opened.?.file.read_only = true;
    try std.testing.expectError(error.ReadOnly, run(a, &state, &views, 0, .{ .insert = "x" }, .{ .now_ms = 607 }));
    try std.testing.expectEqualStrings("z", state.opened.?.file.content);
}

test "Editor commands: every failed replacement preserves body selections and live history" {
    const Check = struct {
        fn runCase(a: std.mem.Allocator) !void {
            var state = try testState(a, "abcdef");
            defer state.clear(a);
            var first: navigation.View = .{};
            defer first.deinit(a);
            var second: navigation.View = .{};
            defer second.deinit(a);
            try first.items.append(a, selection.Selection.fromPoints(2, 5));
            try second.items.append(a, selection.Selection.at(6));
            const views = [_]Participant{ .{ .view = &first, .id = 1 }, .{ .view = &second, .id = 2 } };
            _ = run(a, &state, &views, 0, .{ .insert = "X" }, .{ .now_ms = 100 }) catch |err| {
                try std.testing.expectEqualStrings("abcdef", state.opened.?.file.content);
                try std.testing.expectEqual(@as(u64, 0), state.opened.?.file.revision);
                try std.testing.expectEqual(@as(usize, 2), first.items.items[0].fixedEnd());
                try std.testing.expectEqual(@as(usize, 5), first.items.items[0].focus);
                try std.testing.expectEqual(@as(usize, 6), second.items.items[0].focus);
                try std.testing.expectEqual(@as(usize, 0), state.history.undo_len);
                try std.testing.expectEqual(@as(usize, 0), state.history.redo_len);
                return err;
            };
            try std.testing.expectEqualStrings("abXf", state.opened.?.file.content);
            try std.testing.expectEqual(@as(usize, 3), first.items.items[0].focus);
            try std.testing.expectEqual(@as(usize, 4), second.items.items[0].focus);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.runCase, .{});
}

test "Editor commands: every failed single-entry undo preserves both stacks and views" {
    const Check = struct {
        fn runCase(a: std.mem.Allocator) !void {
            var state = try testState(a, "abc");
            defer state.clear(a);
            var view: navigation.View = .{};
            defer view.deinit(a);
            try view.items.append(a, selection.Selection.at(1));
            const views = [_]Participant{.{ .view = &view, .id = 1 }};
            _ = try run(a, &state, &views, 0, .{ .insert = "X" }, .{ .now_ms = 1 });
            _ = run(a, &state, &views, 0, .undo, .{ .now_ms = 2 }) catch |err| {
                try std.testing.expectEqualStrings("aXbc", state.opened.?.file.content);
                try std.testing.expectEqual(@as(u64, 1), state.opened.?.file.revision);
                try std.testing.expectEqual(@as(usize, 2), view.items.items[0].focus);
                try std.testing.expectEqual(@as(usize, 1), state.history.undo_len);
                try std.testing.expectEqual(@as(usize, 0), state.history.redo_len);
                return err;
            };
            try std.testing.expectEqualStrings("abc", state.opened.?.file.content);
            try std.testing.expect(!state.opened.?.isDirty());
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.runCase, .{});
}

test "Editor commands: multicursor replacement and undo preserve reversed anchors and primary" {
    const a = std.testing.allocator;
    var state = try testState(a, "abcdefghij");
    defer state.clear(a);
    var view: navigation.View = .{};
    defer view.deinit(a);
    try view.items.appendSlice(a, &.{ selection.Selection.fromPoints(2, 0), selection.Selection.at(5), selection.Selection.fromPoints(8, 10) });
    view.primary = 1;
    const views = [_]Participant{.{ .view = &view, .id = 1 }};
    _ = try run(a, &state, &views, 0, .{ .insert = "X" }, .{ .now_ms = 1 });
    try std.testing.expectEqualStrings("XcdeXfghX", state.opened.?.file.content);
    try std.testing.expectEqual(@as(usize, 1), view.primary);
    for (view.items.items, [_]usize{ 1, 5, 9 }) |s, at| try std.testing.expectEqual(at, s.focus);
    _ = try run(a, &state, &views, 0, .undo, .{ .now_ms = 2 });
    try std.testing.expectEqualStrings("abcdefghij", state.opened.?.file.content);
    try std.testing.expectEqual(@as(usize, 1), view.primary);
    try std.testing.expectEqual(@as(usize, 2), view.items.items[0].fixedEnd());
    try std.testing.expectEqual(@as(usize, 0), view.items.items[0].focus);
    try std.testing.expectEqual(@as(usize, 3), view.items.items.len);
}

test "Editor commands: undo after originating view closes restores the remaining view" {
    const a = std.testing.allocator;
    var state = try testState(a, "abc");
    defer state.clear(a);
    var first: navigation.View = .{};
    defer first.deinit(a);
    var second: navigation.View = .{};
    defer second.deinit(a);
    try first.items.append(a, selection.Selection.at(1));
    try second.items.append(a, selection.Selection.at(3));
    const both = [_]Participant{ .{ .view = &first, .id = 1 }, .{ .view = &second, .id = 2 } };
    _ = try run(a, &state, &both, 0, .{ .insert = "X" }, .{ .now_ms = 1 });
    first.deinit(a);
    const remaining = [_]Participant{.{ .view = &second, .id = 2 }};
    _ = try run(a, &state, &remaining, 0, .undo, .{ .now_ms = 2 });
    try std.testing.expectEqualStrings("abc", state.opened.?.file.content);
    try std.testing.expectEqual(@as(usize, 1), second.items.items[0].focus);
    _ = try run(a, &state, &remaining, 0, .redo, .{ .now_ms = 3 });
    try std.testing.expectEqualStrings("aXbc", state.opened.?.file.content);
    try std.testing.expectEqual(@as(usize, 4), second.items.items[0].focus);
}
