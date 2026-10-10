//! 여러 문서의 Undo/Redo를 사본에서 준비하고 전부 검증한 뒤 할당 없이 교체한다.
//! 호출자는 준비부터 결산까지 문서 lease와 선택 배열의 단독 actor 소유를 유지해야 한다.
const std = @import("std");
const history = @import("../history.zig");
const edit = @import("../edit_doc.zig");
const selection = @import("../selection.zig");

pub const Direction = enum { undo, redo };
pub const Target = struct {
    file: *edit.EditableFile,
    state: *history.State,
    selections: *selection.Selections,
    expected_id: u64,
    expected_epoch: u64,
};
const Item = struct {
    target: Target,
    resource_allocator: std.mem.Allocator,
    revision: u64,
    from_len: usize,
    to_len: usize,
    to_id: u64,
    before: []selection.Selection,
    primary: usize,
    column: ?selection.ColumnAnchor,
    next: edit.EditableFile,
    next_sels: selection.Selections,
    mirror: history.Entry,
    stack: []history.Entry,
    consumed: bool = false,

    fn deinit(self: *Item) void {
        const a = self.resource_allocator;
        a.free(self.before);
        if (!self.consumed) {
            self.next.deinit();
            a.free(self.next_sels.items);
            self.mirror.deinit(a);
            // 기존 payload는 빌렸다. 슬롯 배열만 해제한다.
            a.free(self.stack);
        }
    }
};
fn source(s: *history.State, d: Direction) []history.Entry {
    return if (d == .undo) s.undo[0..s.undo_len] else s.redo[0..s.redo_len];
}
fn destination(s: *history.State, d: Direction) []history.Entry {
    return if (d == .undo) s.redo[0..s.redo_len] else s.undo[0..s.undo_len];
}
fn validate(t: Target, d: Direction) !history.Entry {
    if (t.file.read_only) return error.ReadOnly;
    if (t.selections.items.len == 0 or t.selections.primary >= t.selections.items.len) return error.InvalidSelection;
    if (t.expected_id == 0 or t.expected_epoch == std.math.maxInt(u64) or t.state.epoch != t.expected_epoch) return error.StaleHistory;
    const entries = source(t.state, d);
    if (entries.len == 0 or entries[entries.len - 1].id != t.expected_id) return error.StaleHistory;
    const top = entries[entries.len - 1];
    if (top.sels_before.len == 0 or top.primary_before >= top.sels_before.len) return error.InvalidHistory;
    // 첫 연결은 파일별 독립 항목만 받는다. 타이핑 묶음의 일부만 되돌리지 않는다.
    if (entries.len > 1 and entries[entries.len - 2].group == top.group) return error.GroupedHistory;
    return top;
}

pub const Prepared = struct {
    allocator: std.mem.Allocator,
    direction: Direction,
    items: std.ArrayList(Item) = .empty,
    committed: bool = false,

    pub fn deinit(self: *Prepared) void {
        for (self.items.items) |*item| item.deinit();
        self.items.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn prepare(a: std.mem.Allocator, targets: []const Target, direction: Direction) !Prepared {
        if (targets.len == 0) return error.NoTargets;
        var prepared = Prepared{ .allocator = a, .direction = direction };
        errdefer prepared.deinit();
        try prepared.items.ensureTotalCapacity(a, targets.len);
        for (targets, 0..) |t, i| {
            for (targets[0..i]) |other| {
                if (t.file == other.file or t.state == other.state or t.selections == other.selections) return error.DuplicateTarget;
            }
            prepared.items.appendAssumeCapacity(try prepareItem(t, direction));
        }
        return prepared;
    }

    /// 모든 대상을 다시 검증하기 전에는 정본을 바꾸지 않는다. 소유권 이동은 할당하지 않는다.
    pub fn commit(self: *Prepared) !void {
        if (self.committed) return error.AlreadyCommitted;
        for (self.items.items) |item| {
            _ = try validate(item.target, self.direction);
            const t = item.target;
            const dst = destination(t.state, self.direction);
            if (t.file.allocator.ptr != item.resource_allocator.ptr or t.file.allocator.vtable != item.resource_allocator.vtable or
                !std.meta.eql(t.file.format, item.next.format) or t.file.revision != item.revision or source(t.state, self.direction).len != item.from_len or dst.len != item.to_len or
                (if (dst.len == 0) 0 else dst[dst.len - 1].id) != item.to_id or
                t.selections.primary != item.primary or !std.meta.eql(t.selections.column, item.column) or t.selections.items.len != item.before.len) return error.StaleHistory;
            for (t.selections.items, item.before) |current, old| if (!std.meta.eql(current, old)) return error.StaleSelection;
        }
        for (self.items.items) |*item| {
            const t = item.target;
            const a = t.file.allocator;
            const from_len = if (self.direction == .undo) &t.state.undo_len else &t.state.redo_len;
            const from = if (self.direction == .undo) t.state.undo else t.state.redo;
            const to = if (self.direction == .undo) &t.state.redo else &t.state.undo;
            const to_len = if (self.direction == .undo) &t.state.redo_len else &t.state.undo_len;
            t.file.deinit();
            t.file.* = item.next;
            a.free(t.selections.items);
            t.selections.* = item.next_sels;
            from_len.* -= 1;
            var old = from[from_len.*];
            old.deinit(a);
            if (to.len > 0) a.free(to.*);
            to.* = item.stack;
            to.*[to_len.*] = item.mirror;
            to_len.* += 1;
            t.state.last_edit_kind = .none;
            item.consumed = true;
        }
        self.committed = true;
    }
};
fn prepareItem(t: Target, d: Direction) !Item {
    const top = try validate(t, d);
    const a = t.file.allocator;
    const before = try a.dupe(selection.Selection, t.selections.items);
    errdefer a.free(before);
    const mapped = try a.dupe(selection.Selection, t.selections.items);
    defer a.free(mapped);
    var sels = selection.Selections.init(mapped, t.selections.primary);
    // 현재 평탄화 소비처의 계약을 유지한다. 문서 크기에 비례하는 준비 사본이다.
    var next = try edit.EditableFile.initContent(a, t.file.content, false);
    errdefer next.deinit();
    next.format = t.file.format;
    next.revision = t.file.revision;
    if (next.revision == std.math.maxInt(u64)) return error.RevisionExhausted;
    var inverse = try next.apply(top.inverse.delta(), &sels);
    errdefer inverse.deinit();
    const next_items = try a.dupe(selection.Selection, top.sels_before);
    // Undo는 편집 전 좌표를 복원하되 세로 이동 목표와 진행 중 제스처를 부활시키지 않는다.
    for (next_items) |*item| {
        item.goal = .none;
        item.anchor_goal = .none;
    }
    errdefer a.free(next_items);
    const mirror_items = try a.dupe(selection.Selection, before);
    errdefer a.free(mirror_items);
    const dst = destination(t.state, d);
    const stack = try a.alloc(history.Entry, try std.math.add(usize, dst.len, 1));
    @memcpy(stack[0..dst.len], dst);
    return .{
        .target = t,
        .resource_allocator = a,
        .revision = t.file.revision,
        .from_len = source(t.state, d).len,
        .to_len = dst.len,
        .to_id = if (dst.len == 0) 0 else dst[dst.len - 1].id,
        .before = before,
        .primary = t.selections.primary,
        .column = t.selections.column,
        .next = next,
        .next_sels = selection.Selections.init(next_items, top.primary_before),
        .mirror = .{ .id = top.id, .inverse = inverse, .sels_before = mirror_items, .primary_before = t.selections.primary, .group = top.group, .view_id = top.view_id },
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
        const items = try a.dupe(selection.Selection, &.{selection.Selection.at(1)});
        errdefer a.free(items);
        var sels = selection.Selections.init(items, 0);
        const before = try a.dupe(selection.Selection, items);
        errdefer a.free(before);
        const stack = try a.alloc(history.Entry, 1);
        errdefer a.free(stack);
        const inverse = try file.apply(.{ .changes = &.{.{ .start = 0, .end = 1, .text = "\xed\x95\x9c\xf0\x9f\x98\x80" }} }, &sels);
        var state = history.State{};
        stack[0] = .{ .id = try state.issueId(), .inverse = inverse, .sels_before = before, .primary_before = 0, .group = 1 };
        state.undo = stack;
        state.undo_len = 1;
        return .{ .file = file, .state = state, .sels = sels };
    }
    fn deinit(self: *Fixture) void {
        const a = self.file.allocator;
        self.state.clear(a);
        a.free(self.sels.items);
        self.file.deinit();
    }
    fn target(self: *Fixture, d: Direction) Target {
        const entries = source(&self.state, d);
        return .{ .file = &self.file, .state = &self.state, .selections = &self.sels, .expected_id = if (entries.len == 0) 0 else entries[entries.len - 1].id, .expected_epoch = self.state.epoch };
    }
};
test "HST1 two real documents undo redo together and preserve BOM CRLF and identity" {
    var a = try Fixture.init(testing.allocator, "\xef\xbb\xbfa\r\n");
    defer a.deinit();
    var b = try Fixture.init(testing.allocator, "b\n");
    defer b.deinit();
    const id = a.state.undo[0].id;
    var undo = try Prepared.prepare(testing.allocator, &.{ a.target(.undo), b.target(.undo) }, .undo);
    defer undo.deinit();
    try testing.expectEqualStrings("\xed\x95\x9c\xf0\x9f\x98\x80\r\n", a.file.content);
    try undo.commit();
    try testing.expectEqualStrings("a\r\n", a.file.content);
    try testing.expectEqualStrings("b\n", b.file.content);
    try testing.expect(a.file.format.has_bom);
    try testing.expectEqual(id, a.state.redo[0].id);
    try testing.expectError(error.AlreadyCommitted, undo.commit());
    var redo = try Prepared.prepare(testing.allocator, &.{ a.target(.redo), b.target(.redo) }, .redo);
    defer redo.deinit();
    try redo.commit();
    try testing.expectEqualStrings("\xed\x95\x9c\xf0\x9f\x98\x80\r\n", a.file.content);
    try testing.expectEqualStrings("\xed\x95\x9c\xf0\x9f\x98\x80\n", b.file.content);
    try testing.expectEqual(id, a.state.undo[0].id);
}
test "HST2 every allocation failure preparing B leaves A B selections and histories untouched" {
    var failures: usize = 0;
    for (0..100) |offset| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{});
        var first_failing = testing.FailingAllocator.init(testing.allocator, .{});
        var a = try Fixture.init(first_failing.allocator(), "a");
        defer a.deinit();
        var b = try Fixture.init(failing.allocator(), "b");
        defer b.deinit();
        const caret_a = a.sels.items[0];
        const caret_b = b.sels.items[0];
        failing.fail_index = failing.alloc_index + offset;
        var result = Prepared.prepare(testing.allocator, &.{ a.target(.undo), b.target(.undo) }, .undo) catch |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            failures += 1;
            try testing.expectEqualStrings("\xed\x95\x9c\xf0\x9f\x98\x80", a.file.content);
            try testing.expectEqualStrings("\xed\x95\x9c\xf0\x9f\x98\x80", b.file.content);
            try testing.expectEqual(@as(usize, 1), a.state.undo_len);
            try testing.expectEqual(@as(usize, 1), b.state.undo_len);
            try testing.expectEqual(@as(usize, 0), a.state.redo_len);
            try testing.expectEqual(@as(usize, 0), b.state.redo_len);
            try testing.expect(std.meta.eql(caret_a, a.sels.items[0]));
            try testing.expect(std.meta.eql(caret_b, b.sels.items[0]));
            continue;
        };
        defer result.deinit();
        // 준비가 끝나면 다음 할당을 막아도 결산은 성공해야 한다.
        failing.fail_index = failing.alloc_index;
        first_failing.fail_index = first_failing.alloc_index;
        try result.commit();
        try testing.expectEqualStrings("a", a.file.content);
        try testing.expectEqualStrings("b", b.file.content);
        break;
    }
    try testing.expect(failures > 0 and failures < 100);
    std.debug.print("HST B preparation allocation failures checked: {d}\n", .{failures});
}
test "HST3 stale reset followup edit and selection reject all before commit" {
    for ([_]usize{ 2, 1, 0, 3 }) |mode| {
        var a = try Fixture.init(testing.allocator, "a");
        defer a.deinit();
        var b = try Fixture.init(testing.allocator, "b");
        defer b.deinit();
        var prepared = try Prepared.prepare(testing.allocator, &.{ a.target(.undo), b.target(.undo) }, .undo);
        defer prepared.deinit();
        if (mode == 0) b.state.clear(testing.allocator);
        if (mode == 1) {
            var inverse = try b.file.apply(.{ .changes = &.{.{ .start = b.file.content.len, .end = b.file.content.len, .text = "!" }} }, &b.sels);
            inverse.deinit();
        }
        if (mode == 2) b.sels.items[0] = selection.Selection.at(0);
        if (mode == 3) b.file.read_only = true;
        if (prepared.commit()) |_| return error.UnexpectedCommit else |_| {}
        try testing.expectEqualStrings("\xed\x95\x9c\xf0\x9f\x98\x80", a.file.content);
        try testing.expectEqual(@as(usize, 1), a.state.undo_len);
        try testing.expectEqual(@as(usize, 0), a.state.redo_len);
    }
}
test "HST4 redo reset and duplicate targets cannot consume another document" {
    var a = try Fixture.init(testing.allocator, "a");
    defer a.deinit();
    var b = try Fixture.init(testing.allocator, "b");
    defer b.deinit();
    try testing.expectError(error.DuplicateTarget, Prepared.prepare(testing.allocator, &.{ a.target(.undo), a.target(.undo) }, .undo));
    var undo = try Prepared.prepare(testing.allocator, &.{ a.target(.undo), b.target(.undo) }, .undo);
    defer undo.deinit();
    try undo.commit();
    var redo = try Prepared.prepare(testing.allocator, &.{ a.target(.redo), b.target(.redo) }, .redo);
    defer redo.deinit();
    b.state.clear(testing.allocator);
    try testing.expectError(error.StaleHistory, redo.commit());
    try testing.expectEqualStrings("a", a.file.content);
    try testing.expectEqual(@as(usize, 1), a.state.redo_len);
}
test "HST5 reset does not recycle ids and saturation rejects old connections" {
    var state = history.State{};
    const old = try state.issueId();
    state.clear(testing.allocator);
    const next = try state.issueId();
    try testing.expect(next > old);
    state.next_id = std.math.maxInt(u64);
    try testing.expectError(error.HistoryIdExhausted, state.issueId());
    state.epoch = std.math.maxInt(u64);
    state.clear(testing.allocator);
    try testing.expectEqual(std.math.maxInt(u64), state.epoch);
}

test "HST6 prepared cleanup does not read documents released after commit or cancel" {
    for ([_]bool{ false, true }) |commit| {
        var a = try Fixture.init(testing.allocator, "a");
        var b = try Fixture.init(testing.allocator, "b");
        var prepared = try Prepared.prepare(testing.allocator, &.{ a.target(.undo), b.target(.undo) }, .undo);
        if (commit) try prepared.commit();
        a.deinit();
        b.deinit();
        // 정본 수명은 끝났다. cleanup은 준비한 allocator와 독립 자원만 읽어야 한다.
        a = undefined;
        b = undefined;
        prepared.deinit();
    }
}
test "HST7 file format mutation and an intervening completed undo invalidate old preparation" {
    for (0..3) |mode| {
        var a = try Fixture.init(testing.allocator, "a\r\n");
        defer a.deinit();
        var b = try Fixture.init(testing.allocator, "b\r\n");
        defer b.deinit();
        var old = try Prepared.prepare(testing.allocator, &.{ a.target(.undo), b.target(.undo) }, .undo);
        defer old.deinit();
        var allocator_changed = testing.FailingAllocator.init(testing.allocator, .{});
        if (mode == 0) {
            b.file.format.has_bom = true;
        } else if (mode == 2) {
            b.file.allocator = allocator_changed.allocator();
        } else {
            var newer = try Prepared.prepare(testing.allocator, &.{ a.target(.undo), b.target(.undo) }, .undo);
            defer newer.deinit();
            try newer.commit();
        }
        try testing.expectError(error.StaleHistory, old.commit());
        if (mode == 2) b.file.allocator = testing.allocator;
        try testing.expectEqualStrings(if (mode != 1) "\xed\x95\x9c\xf0\x9f\x98\x80\r\n" else "a\r\n", a.file.content);
        if (mode == 0) try testing.expect(b.file.format.has_bom);
    }
}
test "HST8 duplicate owners bad identity and invalid selection reject after preparing A" {
    for (0..5) |mode| {
        var a = try Fixture.init(testing.allocator, "a");
        defer a.deinit();
        var b = try Fixture.init(testing.allocator, "b");
        defer b.deinit();
        var target = b.target(.undo);
        if (mode == 0) target.state = &a.state;
        if (mode == 1) target.selections = &a.sels;
        if (mode == 2) target.expected_id += 1;
        if (mode == 3) target.expected_epoch += 1;
        if (mode == 4) b.sels.primary = b.sels.items.len;
        if (Prepared.prepare(testing.allocator, &.{ a.target(.undo), target }, .undo)) |value| {
            var unexpected = value;
            unexpected.deinit();
            return error.UnexpectedPreparation;
        } else |_| {}
        try testing.expectEqualStrings("\xed\x95\x9c\xf0\x9f\x98\x80", a.file.content);
        try testing.expectEqual(@as(usize, 1), a.state.undo_len);
        try testing.expectEqual(@as(usize, 0), a.state.redo_len);
    }
}
test "HST9 grouped source and discarded redo preserve every untouched document" {
    var a = try Fixture.init(testing.allocator, "a");
    defer a.deinit();
    var b = try Fixture.init(testing.allocator, "b");
    defer b.deinit();
    var undo = try Prepared.prepare(testing.allocator, &.{ a.target(.undo), b.target(.undo) }, .undo);
    defer undo.deinit();
    try undo.commit();
    var redo = try Prepared.prepare(testing.allocator, &.{ a.target(.redo), b.target(.redo) }, .redo);
    defer redo.deinit();
    b.state.redo[0].deinit(testing.allocator);
    b.state.redo_len = 0;
    try testing.expectError(error.StaleHistory, redo.commit());
    try testing.expectEqualStrings("a", a.file.content);
    try testing.expectEqual(@as(usize, 1), a.state.redo_len);
    var mirror_sels = selection.Selections.init(try testing.allocator.dupe(selection.Selection, b.sels.items), 0);
    defer testing.allocator.free(mirror_sels.items);
    const original_sels = try testing.allocator.dupe(selection.Selection, b.sels.items);
    const inverse = try b.file.apply(.{ .changes = &.{.{ .start = 0, .end = 1, .text = "c" }} }, &mirror_sels);
    b.state.undo = try testing.allocator.realloc(b.state.undo, 2);
    b.state.undo[0] = .{ .id = try b.state.issueId(), .inverse = inverse, .sels_before = original_sels, .primary_before = 0, .group = 9 };
    b.state.undo_len = 1;
    const inverse2 = try b.file.apply(.{ .changes = &.{.{ .start = 0, .end = 1, .text = "d" }} }, &mirror_sels);
    b.state.undo[1] = .{ .id = try b.state.issueId(), .inverse = inverse2, .sels_before = try testing.allocator.dupe(selection.Selection, b.sels.items), .primary_before = 0, .group = 9 };
    b.state.undo_len = 2;
    var restore_a = try Prepared.prepare(testing.allocator, &.{a.target(.redo)}, .redo);
    defer restore_a.deinit();
    try restore_a.commit();
    try testing.expectError(error.GroupedHistory, Prepared.prepare(testing.allocator, &.{ a.target(.undo), b.target(.undo) }, .undo));
}
test "HST10 forty alternating transactions preserve text selections and IDs with cancelled previews" {
    var a = try Fixture.init(testing.allocator, "a\r\n");
    defer a.deinit();
    var b = try Fixture.init(testing.allocator, "b\n");
    defer b.deinit();
    const a_id = a.state.undo[0].id;
    const b_id = b.state.undo[0].id;
    for (0..40) |cycle| {
        const d: Direction = if (cycle % 2 == 0) .undo else .redo;
        var cancelled = try Prepared.prepare(testing.allocator, &.{ a.target(d), b.target(d) }, d);
        cancelled.deinit();
        var prepared = try Prepared.prepare(testing.allocator, &.{ a.target(d), b.target(d) }, d);
        defer prepared.deinit();
        try prepared.commit();
        try testing.expectEqualStrings(if (d == .undo) "a\r\n" else "\xed\x95\x9c\xf0\x9f\x98\x80\r\n", a.file.content);
        try testing.expectEqualStrings(if (d == .undo) "b\n" else "\xed\x95\x9c\xf0\x9f\x98\x80\n", b.file.content);
        const opposite: Direction = if (d == .undo) .redo else .undo;
        try testing.expectEqual(a_id, source(&a.state, opposite)[0].id);
        try testing.expectEqual(b_id, source(&b.state, opposite)[0].id);
        try testing.expectEqual(if (d == .undo) @as(usize, 1) else @as(usize, 7), a.sels.items[0].focus);
    }
}
