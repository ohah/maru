//! 여러 문서의 편집 자원도 정본 변경 전에 전부 준비한다. Undo 연결 예약과 따로 검증할 수 있다.
const std = @import("std");
const edit = @import("../edit_doc.zig");
const history = @import("../history.zig");
const selection = @import("../selection.zig");
const delta = @import("../delta.zig");
pub const Target = struct { file: *edit.EditableFile, state: *history.State, selections: *selection.Selections, changes: []const delta.Change, view_id: u64 };
const Item = struct {
    target: Target,
    allocator: std.mem.Allocator,
    revision: u64,
    epoch: u64,
    next_id: u64,
    group: u32,
    undo_len: usize,
    drop: usize,
    redo_len: usize,
    undo_top: u64,
    redo_top: u64,
    before: []selection.Selection,
    primary: usize,
    column: ?selection.ColumnAnchor,
    next: edit.EditableFile,
    sels: selection.Selections,
    entry: history.Entry,
    stack: []history.Entry,
    consumed: bool = false,
    fn deinit(self: *Item) void {
        self.allocator.free(self.before);
        if (!self.consumed) {
            self.next.deinit();
            self.allocator.free(self.sels.items);
            self.entry.deinit(self.allocator);
            self.allocator.free(self.stack);
        }
    }
};
fn top(entries: []history.Entry, len: usize) u64 {
    return if (len == 0) 0 else entries[len - 1].id;
}
pub const Prepared = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(Item) = .empty,
    committed: bool = false,
    pub fn deinit(self: *Prepared) void {
        for (self.items.items) |*item| item.deinit();
        self.items.deinit(self.allocator);
    }
    pub fn prepare(a: std.mem.Allocator, targets: []const Target) !Prepared {
        if (targets.len == 0) return error.NoTargets;
        var prepared = Prepared{ .allocator = a };
        errdefer prepared.deinit();
        try prepared.items.ensureTotalCapacity(a, targets.len);
        for (targets, 0..) |t, i| {
            for (targets[0..i]) |other| if (t.file == other.file or t.state == other.state or t.selections == other.selections) return error.DuplicateTarget;
            prepared.items.appendAssumeCapacity(try prepareOne(t));
        }
        return prepared;
    }
    pub fn commit(self: *Prepared) !void {
        if (self.committed) return error.AlreadyCommitted;
        for (self.items.items) |item| {
            const t = item.target;
            const h = t.state;
            if (t.file.read_only or t.file.revision != item.revision or !std.meta.eql(t.file.format, item.next.format) or
                t.file.allocator.ptr != item.allocator.ptr or t.file.allocator.vtable != item.allocator.vtable or
                h.epoch != item.epoch or h.next_id != item.next_id or h.edit_group != item.group or
                h.undo_len != item.undo_len or h.redo_len != item.redo_len or top(h.undo, h.undo_len) != item.undo_top or top(h.redo, h.redo_len) != item.redo_top or
                t.selections.primary != item.primary or t.selections.items.len != item.before.len or !std.meta.eql(t.selections.column, item.column)) return error.StaleHistory;
            for (t.selections.items, item.before) |now, before| if (!std.meta.eql(now, before)) return error.StaleSelection;
        }
        for (self.items.items) |*item| {
            const t = item.target;
            const a = item.allocator;
            t.file.deinit();
            t.file.* = item.next;
            a.free(t.selections.items);
            t.selections.* = item.sels;
            for (t.state.redo[0..t.state.redo_len]) |*entry| entry.deinit(a);
            t.state.redo_len = 0;
            for (t.state.undo[0..item.drop]) |*entry| entry.deinit(a);
            if (t.state.undo.len > 0) a.free(t.state.undo);
            t.state.undo = item.stack;
            t.state.undo[item.undo_len - item.drop] = item.entry;
            t.state.undo_len = item.stack.len;
            t.state.next_id += 1;
            t.state.edit_group = item.entry.group +% 1;
            t.state.last_edit_kind = .none;
            item.consumed = true;
        }
        self.committed = true;
    }
};
fn prepareOne(t: Target) !Item {
    if (t.file.read_only) return error.ReadOnly;
    if (t.state.next_id == std.math.maxInt(u64) or t.state.epoch == std.math.maxInt(u64)) return error.HistoryIdExhausted;
    if (t.file.revision == std.math.maxInt(u64)) return error.RevisionExhausted;
    if (t.selections.items.len == 0 or t.selections.primary >= t.selections.items.len) return error.InvalidSelection;
    if (t.changes.len == 0) return error.NoChanges;
    const a = t.file.allocator;
    const before = try a.dupe(selection.Selection, t.selections.items);
    errdefer a.free(before);
    const mapped = try a.dupe(selection.Selection, t.selections.items);
    errdefer a.free(mapped);
    var sels = selection.Selections.init(mapped, t.selections.primary);
    var next = try edit.EditableFile.initContent(a, t.file.content, false);
    errdefer next.deinit();
    next.format = t.file.format;
    next.revision = t.file.revision;
    var inverse = try next.apply(.{ .changes = t.changes }, &sels);
    errdefer inverse.deinit();
    if (std.mem.eql(u8, next.content, t.file.content)) return error.NoChanges;
    const history_sels = try a.dupe(selection.Selection, before);
    errdefer a.free(history_sels);
    // 일반 편집과 같은 항목 상한이다. 폐기는 전체 결산 때만 수행한다.
    const keep: usize = @min(t.state.undo_len, history.stack_limit - 1);
    const drop = t.state.undo_len - keep;
    const stack = try a.alloc(history.Entry, keep + 1);
    @memcpy(stack[0..keep], t.state.undo[drop..t.state.undo_len]);
    var group = t.state.edit_group +% 1;
    if (t.state.undo_len > 0 and group == t.state.undo[t.state.undo_len - 1].group) group +%= 1;
    return .{
        .target = t,
        .allocator = a,
        .revision = t.file.revision,
        .epoch = t.state.epoch,
        .next_id = t.state.next_id,
        .group = t.state.edit_group,
        .undo_len = t.state.undo_len,
        .drop = drop,
        .redo_len = t.state.redo_len,
        .undo_top = top(t.state.undo, t.state.undo_len),
        .redo_top = top(t.state.redo, t.state.redo_len),
        .before = before,
        .primary = t.selections.primary,
        .column = t.selections.column,
        .next = next,
        .sels = sels,
        .entry = .{ .id = t.state.next_id, .inverse = inverse, .sels_before = history_sels, .primary_before = t.selections.primary, .group = group, .view_id = t.view_id },
        .stack = stack,
    };
}

const testing = std.testing;
const Fixture = struct {
    file: edit.EditableFile,
    state: history.State = .{},
    sels: selection.Selections,
    fn init(a: std.mem.Allocator, text: []const u8) !Fixture {
        var file = try edit.EditableFile.init(a, text, false);
        errdefer file.deinit();
        return .{ .file = file, .sels = selection.Selections.init(try a.dupe(selection.Selection, &.{selection.Selection.at(1)}), 0) };
    }
    fn deinit(self: *Fixture) void {
        const a = self.file.allocator;
        self.state.clear(a);
        a.free(self.sels.items);
        self.file.deinit();
    }
    fn target(self: *Fixture) Target {
        return .{ .file = &self.file, .state = &self.state, .selections = &self.sels, .changes = &.{.{ .start = 0, .end = 1, .text = "new\n" }}, .view_id = 12 };
    }
};
test "LHT1 B 준비의 모든 할당 실패는 A와 신원 예약을 보존하고 결산은 할당하지 않는다" {
    var failures: usize = 0;
    var success = false;
    for (0..100) |offset| {
        var aa = testing.FailingAllocator.init(testing.allocator, .{});
        var ba = testing.FailingAllocator.init(testing.allocator, .{});
        var a = try Fixture.init(aa.allocator(), "a");
        defer a.deinit();
        var b = try Fixture.init(ba.allocator(), "b");
        defer b.deinit();
        ba.fail_index = ba.alloc_index + offset;
        var prepared = Prepared.prepare(testing.allocator, &.{ a.target(), b.target() }) catch |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            failures += 1;
            try testing.expectEqualStrings("a", a.file.content);
            try testing.expectEqualStrings("b", b.file.content);
            try testing.expectEqual(@as(u64, 1), a.state.next_id);
            try testing.expectEqual(@as(u64, 1), b.state.next_id);
            try testing.expectEqual(@as(usize, 0), a.state.undo_len);
            try testing.expectEqual(@as(usize, 1), a.sels.items[0].focus);
            continue;
        };
        defer prepared.deinit();
        aa.fail_index = aa.alloc_index;
        ba.fail_index = ba.alloc_index;
        try prepared.commit();
        try testing.expectEqualStrings("new\n", a.file.content);
        try testing.expectEqualStrings("new\n", b.file.content);
        try testing.expectEqual(@as(u64, 2), a.state.next_id);
        try testing.expectEqual(@as(u64, 1), a.state.undo[0].id);
        try testing.expectError(error.AlreadyCommitted, prepared.commit());
        success = true;
        break;
    }
    try testing.expect(success and failures > 0);
    std.debug.print("LHT B allocation failures: {d}\n", .{failures});
}
test "LHT2 B 변경과 선택 이동은 전체 결산을 거절한다" {
    for (0..5) |mode| {
        var a = try Fixture.init(testing.allocator, "a");
        defer a.deinit();
        var b = try Fixture.init(testing.allocator, "b");
        defer b.deinit();
        var prepared = try Prepared.prepare(testing.allocator, &.{ a.target(), b.target() });
        defer prepared.deinit();
        if (mode == 0) b.state.clear(testing.allocator);
        if (mode == 1) b.sels.items[0].focus = 0;
        if (mode == 2) b.file.read_only = true;
        if (mode == 3) b.state.next_id += 1;
        if (mode == 4) b.file.revision += 1;
        if (prepared.commit()) |_| return error.UnexpectedCommit else |_| {}
        try testing.expectEqualStrings("a", a.file.content);
        try testing.expectEqualStrings("b", b.file.content);
        try testing.expectEqual(@as(usize, 0), a.state.undo_len);
        try testing.expectEqual(@as(u64, 1), a.state.next_id);
    }
}
test "LHT3 중복 문서 무효 선택 no op 신원 고갈은 준비한 A까지 보존한다" {
    for (0..5) |mode| {
        var a = try Fixture.init(testing.allocator, "a");
        defer a.deinit();
        var b = try Fixture.init(testing.allocator, "b");
        defer b.deinit();
        var target = b.target();
        if (mode == 0) target.file = &a.file;
        if (mode == 1) target.changes = &.{.{ .start = 0, .end = 1, .text = "b" }};
        if (mode == 2) b.state.next_id = std.math.maxInt(u64);
        if (mode == 3) b.sels.primary = 1;
        if (mode == 4) target.changes = &.{.{ .start = 0, .end = 3, .text = "bad" }};
        if (Prepared.prepare(testing.allocator, &.{ a.target(), target })) |value| {
            var unexpected = value;
            unexpected.deinit();
            return error.UnexpectedPreparation;
        } else |_| {}
        try testing.expectEqualStrings("a", a.file.content);
        try testing.expectEqual(@as(usize, 0), a.state.undo_len);
    }
}
test "LHT4 상한 폐기와 Redo 폐기는 모든 문서 준비 뒤에만 수행한다" {
    var a = try Fixture.init(testing.allocator, "a");
    defer a.deinit();
    var b = try Fixture.init(testing.allocator, "b");
    defer b.deinit();
    // 실제 서로 다른 payload를 채워 폐기 때 중복 해제나 누락을 검출한다.
    for (0..history.stack_limit) |_| {
        var target = a.target();
        target.changes = &.{.{ .start = a.file.content.len, .end = a.file.content.len, .text = "x" }};
        var prepared = try Prepared.prepare(testing.allocator, &.{target});
        defer prepared.deinit();
        try prepared.commit();
    }
    const first = a.state.undo[0].id;
    var cancelled = try Prepared.prepare(testing.allocator, &.{ a.target(), b.target() });
    cancelled.deinit();
    try testing.expectEqual(first, a.state.undo[0].id);
    var prepared = try Prepared.prepare(testing.allocator, &.{ a.target(), b.target() });
    defer prepared.deinit();
    try prepared.commit();
    try testing.expectEqual(history.stack_limit, a.state.undo_len);
    try testing.expect(a.state.undo[0].id > first);
    const step = @import("step.zig");
    var undo = try step.Prepared.prepare(testing.allocator, &.{.{ .file = &a.file, .state = &a.state, .selections = &a.sels, .expected_id = a.state.undo[a.state.undo_len - 1].id, .expected_epoch = a.state.epoch }}, .undo);
    defer undo.deinit();
    try undo.commit();
    try testing.expectEqual(@as(usize, 1), a.state.redo_len);
    var again = try Prepared.prepare(testing.allocator, &.{ a.target(), b.target() });
    defer again.deinit();
    try testing.expectEqual(@as(usize, 1), a.state.redo_len);
    try again.commit();
    try testing.expectEqual(@as(usize, 0), a.state.redo_len);
}
