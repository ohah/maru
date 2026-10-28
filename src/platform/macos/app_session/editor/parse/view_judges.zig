//! 실제 구문 뷰 상태의 설치·조회·반환을 검사한다. 일반 입력 경로는 전환하지 않는다.
const std = @import("std");
const maru = @import("maru");
const syntax = @import("syntax");
const colors = @import("../syntax.zig");
const view = @import("view.zig");
const Runtime = @import("runtime.zig").Runtime;
const worker = @import("worker.zig");
const registry = maru.session.editor.document_registry;
const a = std.testing.allocator;
const grammar: maru.session.editor.syntax.request.Grammar = .{ .identity = 1, .generation = 0 };
const original = "const Container = struct {\n    pub fn first() void {\n        _ = (1 + 2);\n    }\n};\n";
fn document(docs: *registry.Registry, text: []const u8) !registry.Lease {
    const file = try maru.session.editor.edit_doc.EditableFile.init(a, text, false);
    var state: maru.session.editor.document_state.State = .{ .opened = .{ .file = file, .saved_hash = 0 } };
    defer state.clear(a);
    return docs.create(&state, a);
}
fn now() i128 {
    return std.Io.Clock.awake.now(std.testing.io).nanoseconds;
}
fn ready(owner: *Runtime, lease: registry.Lease) !void {
    _ = try owner.submit(lease, grammar, .zig);
    const deadline = now() + 10_000_000_000;
    while (owner.ready(lease.owner.identity(lease).?, grammar, .zig) == null) {
        try std.testing.expect(now() < deadline);
        owner.poll();
        std.Thread.yield() catch {};
    }
}
// 잘못된 native 얕은 복사를 주입한 경우 원본 parser를 두 번 해제하지 않고 assertion만 보고한다.
fn cleanupPrepared(prepared: *view.Prepared) void {
    if (prepared.result) |held| if (prepared.provider) |provider| {
        if (held.provider()) |source| if (provider.parser == source.parser) {
            prepared.provider = null;
        };
    };
    prepared.deinit();
}
fn cleanupState(state: *colors.State, owner: *Runtime) void {
    var saved = state.parse_result;
    const before = owner.service.heldCount();
    if (saved) |held| if (state.provider) |provider| {
        if (held.provider()) |source| if (provider.parser == source.parser) {
            state.provider = null;
        };
    };
    state.deinit(a);
    if (saved != null and owner.service.heldCount() == before) saved.?.release();
}
fn install(owner: *Runtime, state: *colors.State, lease: registry.Lease) !void {
    var prepared = (try view.prepare(owner, lease.owner.identity(lease).?, grammar, .zig)).?;
    defer cleanupPrepared(&prepared);
    try std.testing.expect(try prepared.install(owner, state, lease, grammar, .zig));
    try std.testing.expect(prepared.result == null and prepared.provider == null);
    if (state.provider) |provider| {
        const source = state.parse_result.?.provider().?;
        try std.testing.expect(provider.parser != source.parser and provider.tree != source.tree);
    }
}
fn warm(state: *colors.State, lease: registry.Lease) !void {
    const file = &@constCast(lease.owner).get(lease).?.opened.?.file;
    const rendered = colors.lineColors(state, a, file.content, file.lines, 0, file.lines.lines.len, 4, &.{}, .inherit);
    try std.testing.expect(rendered.len > 0);
    var spans: std.ArrayList(syntax.Provider.FoldSpan) = .empty;
    defer spans.deinit(a);
    try state.provider.?.foldSpansCached(a, &state.folds, file.lines.lines, &spans);
    try std.testing.expect(state.folds.tree != null and spans.items.len > 0);
    var rounds: usize = 0;
    while (colors.advanceBrackets(state, a, file.content, false)) : (rounds += 1) try std.testing.expect(rounds < 100);
    try std.testing.expect(state.brackets.ready and state.bracket_resolved != null);
    state.provider.?.symbols(a, &state.symbols);
    try std.testing.expect(state.symbols.items.len > 0);
    _ = colors.breadcrumb(state, a, "fixture.zig", file.content, 55, null);
}
fn replace(docs: *registry.Registry, lease: registry.Lease) !void {
    return replaceText(docs, lease, "const renamed = [2]u8{1, 2};\n");
}
fn replaceText(docs: *registry.Registry, lease: registry.Lease, text: []const u8) !void {
    const file = &docs.get(lease).?.opened.?.file;
    var entries = [_]maru.session.editor.selection.Selection{maru.session.editor.selection.Selection.at(0)};
    var selections = maru.session.editor.selection.Selections.init(&entries, 0);
    var inverse = try file.apply(.{ .changes = &.{.{ .start = 0, .end = file.content.len, .text = text }} }, &selections);
    inverse.deinit();
}
// 보유 반환 누락을 주입해도 남은 참조만 복구해 테스트 cleanup의 누수와 섞지 않는다.
fn deinitChecked(state: *colors.State, owner: *Runtime, expected: usize) !void {
    var saved = state.parse_result;
    state.deinit(a);
    const actual = owner.service.heldCount();
    if (actual == expected + 1) if (saved) |*held| held.release();
    try std.testing.expectEqual(expected, actual);
}

test "parse view install 공유 뷰의 색과 트리 조회는 cold 결과와 같고 보유 참조를 반환한다" {
    var docs: registry.Registry = .{ .allocator = a };
    defer docs.deinit() catch unreachable;
    const first = try document(&docs, original);
    defer _ = docs.release(first) catch unreachable;
    const second = try docs.retain(first, .view);
    defer _ = docs.release(second) catch unreachable;
    var owner = try Runtime.init(a, .{});
    defer owner.deinit() catch unreachable;
    var left: colors.State = .{};
    var right: colors.State = .{};
    var left_live = true;
    var right_live = true;
    defer {
        if (left_live) cleanupState(&left, &owner);
        if (right_live) cleanupState(&right, &owner);
    }
    try ready(&owner, first);
    try install(&owner, &left, first);
    try install(&owner, &right, second);
    try std.testing.expect(left.provider.?.parser != right.provider.?.parser);
    try std.testing.expect(left.provider.?.tree != right.provider.?.tree);
    try std.testing.expect(colors.matchesInput(&left, docs.identity(first).?, 0));
    try std.testing.expect(view.matches(&left, &owner, docs.identity(first).?, grammar, .zig));
    try warm(&left, first);
    try warm(&right, second);
    var cold = colors.openParsedBudgeted(original, .zig, 0);
    defer cold.deinit(a);
    const file = &docs.get(first).?.opened.?.file;
    const actual = colors.lineColors(&left, a, file.content, file.lines, 0, file.lines.lines.len, 4, &.{}, .inherit);
    const expected = colors.lineColors(&cold, a, file.content, file.lines, 0, file.lines.lines.len, 4, &.{}, .inherit);
    try std.testing.expectEqualDeep(expected, actual);
    try std.testing.expect(syntax.testing.equal(cold.provider.?.tree.?, left.provider.?.tree.?) != null);
    try std.testing.expectEqual(@as(usize, 3), owner.service.heldCount());
    const split = colors.prepareSharedSnapshot(&left, a, .zig) orelse return error.NoSharedSnapshot;
    var split_live = true;
    defer {
        if (split_live) cleanupState(split, &owner);
        a.destroy(split);
    }
    try std.testing.expect(split.parse_result != null);
    try std.testing.expectEqual(@as(usize, 4), owner.service.heldCount());
    split_live = false;
    try deinitChecked(split, &owner, 3);
    const refs = left.parse_result.?.job.main_refs;
    left.parse_result.?.job.main_refs = std.math.maxInt(usize);
    const refused = colors.prepareSharedSnapshot(&left, a, .zig);
    left.parse_result.?.job.main_refs = refs;
    if (refused) |unexpected| {
        cleanupState(unexpected, &owner);
        a.destroy(unexpected);
    }
    try std.testing.expect(refused == null);
    try std.testing.expectEqual(@as(usize, 3), owner.service.heldCount());
    left_live = false;
    try deinitChecked(&left, &owner, 2);
    try std.testing.expect(right.provider.?.tree != null);
    right_live = false;
    try deinitChecked(&right, &owner, 1);
}

test "parse view install 준비 뒤 같은 본문 재요청과 편집 및 잘못된 뷰를 거절한다" {
    var docs: registry.Registry = .{ .allocator = a };
    defer docs.deinit() catch unreachable;
    const lease = try document(&docs, original);
    defer _ = docs.release(lease) catch unreachable;
    const other = try document(&docs, original);
    defer _ = docs.release(other) catch unreachable;
    const read = try docs.retain(lease, .read);
    defer _ = docs.release(read) catch unreachable;
    var owner = try Runtime.init(a, .{});
    defer owner.deinit() catch unreachable;
    var state: colors.State = .{};
    defer cleanupState(&state, &owner);
    try ready(&owner, lease);
    try install(&owner, &state, lease);
    const before = state.input_stamp.?;
    var stale = (try view.prepare(&owner, docs.identity(lease).?, grammar, .zig)).?;
    defer cleanupPrepared(&stale);
    try std.testing.expect(!try stale.install(&owner, &state, other, grammar, .zig));
    try std.testing.expect(!try stale.install(&owner, &state, read, grammar, .zig));
    try ready(&owner, lease); // revision이 같아도 요청 번호가 바뀌었다.
    const accepted = try stale.install(&owner, &state, lease, grammar, .zig);
    try std.testing.expect(!accepted);
    try std.testing.expectEqual(before, state.input_stamp.?);
    var edited = (try view.prepare(&owner, docs.identity(lease).?, grammar, .zig)).?;
    defer cleanupPrepared(&edited);
    try replace(&docs, lease);
    try std.testing.expect(!try edited.install(&owner, &state, lease, grammar, .zig));
    try std.testing.expectEqual(before, state.input_stamp.?);
}

test "parse view install legacy 보존과 빈 문서 및 준비 참조 overflow는 대상에 손대지 않는다" {
    var docs: registry.Registry = .{ .allocator = a };
    defer docs.deinit() catch unreachable;
    const lease = try document(&docs, original);
    defer _ = docs.release(lease) catch unreachable;
    const empty = try document(&docs, "");
    defer _ = docs.release(empty) catch unreachable;
    var owner = try Runtime.init(a, .{});
    defer owner.deinit() catch unreachable;
    var legacy = colors.openParsedBudgeted(original, .zig, 0);
    defer legacy.deinit(a);
    const parser = legacy.provider.?.parser;
    try ready(&owner, lease);
    var prepared = (try view.prepare(&owner, docs.identity(lease).?, grammar, .zig)).?;
    defer cleanupPrepared(&prepared);
    try std.testing.expectError(error.LegacyProvider, prepared.install(&owner, &legacy, lease, grammar, .zig));
    try std.testing.expectEqual(parser, legacy.provider.?.parser);
    var current = owner.ready(docs.identity(lease).?, grammar, .zig).?;
    const refs = current.job.main_refs;
    current.job.main_refs = std.math.maxInt(usize);
    const failed = view.prepare(&owner, docs.identity(lease).?, grammar, .zig);
    current.job.main_refs = refs;
    try std.testing.expectError(error.ReferenceOverflow, failed);
    try std.testing.expectEqual(parser, legacy.provider.?.parser);
    var blank: colors.State = .{};
    defer cleanupState(&blank, &owner);
    try ready(&owner, empty);
    try install(&owner, &blank, empty);
    try std.testing.expect(view.matches(&blank, &owner, docs.identity(empty).?, grammar, .zig));
    try std.testing.expect(!blank.pending);
    try std.testing.expect(blank.provider == null);
    const before_split = owner.service.heldCount();
    const blank_split = colors.prepareSharedSnapshot(&blank, a, .zig) orelse return error.NoEmptySharedSnapshot;
    defer {
        cleanupState(blank_split, &owner);
        a.destroy(blank_split);
    }
    try std.testing.expect(blank_split.provider == null and blank_split.parse_result != null);
    try std.testing.expect(view.matches(blank_split, &owner, docs.identity(empty).?, grammar, .zig));
    try std.testing.expectEqual(before_split + 1, owner.service.heldCount());
}

test "parse view install 교체는 이전 캐시를 비우고 최신 판을 독립적으로 증명한다" {
    var docs: registry.Registry = .{ .allocator = a };
    defer docs.deinit() catch unreachable;
    const lease = try document(&docs, original);
    defer _ = docs.release(lease) catch unreachable;
    var owner = try Runtime.init(a, .{});
    defer owner.deinit() catch unreachable;
    var state: colors.State = .{};
    defer cleanupState(&state, &owner);
    try ready(&owner, lease);
    try install(&owner, &state, lease);
    try warm(&state, lease);
    const folds_capacity = state.folds.records.capacity;
    const brackets_capacity = state.brackets.leaves.capacity;
    try replace(&docs, lease);
    try ready(&owner, lease);
    try install(&owner, &state, lease);
    try std.testing.expect(colors.matchesInput(&state, docs.identity(lease).?, 1));
    try std.testing.expect(state.folds.tree == null and state.folds.records.items.len == 0);
    try std.testing.expect(!state.brackets.ready and state.brackets.leaves.items.len == 0);
    try std.testing.expect(state.bracket_resolved == null and state.bracket_navigation.entries.items.len == 0);
    try std.testing.expect(state.symbols.items.len == 0 and state.crumb.items.len == 0);
    try std.testing.expectEqual(folds_capacity, state.folds.records.capacity);
    try std.testing.expectEqual(brackets_capacity, state.brackets.leaves.capacity);
    const file = &docs.get(lease).?.opened.?.file;
    var cold = colors.openParsedBudgeted(file.content, .zig, 0);
    defer cold.deinit(a);
    const actual = colors.lineColors(&state, a, file.content, file.lines, 0, file.lines.lines.len, 4, &.{}, .inherit);
    const expected = colors.lineColors(&cold, a, file.content, file.lines, 0, file.lines.lines.len, 4, &.{}, .inherit);
    try std.testing.expectEqualDeep(expected, actual);
    try std.testing.expect(syntax.testing.equal(cold.provider.?.tree.?, state.provider.?.tree.?) != null);
    try std.testing.expectEqual(@as(usize, 2), owner.service.heldCount());
    // parser 주소와 저장소가 재사용되는 반복 교체도 현재 판·색·전체 좌표와 참조 수를 유지해야 한다.
    for (0..64) |iteration| {
        const next_text = if (iteration % 2 == 0) original else "const renamed = [2]u8{1, 2};\n";
        try replaceText(&docs, lease, next_text);
        try ready(&owner, lease);
        try install(&owner, &state, lease);
        const current_file = &docs.get(lease).?.opened.?.file;
        try std.testing.expect(colors.matchesInput(&state, docs.identity(lease).?, current_file.revision));
        var oracle = colors.openParsedBudgeted(current_file.content, .zig, 0);
        defer oracle.deinit(a);
        const current_colors = colors.lineColors(&state, a, current_file.content, current_file.lines, 0, current_file.lines.lines.len, 4, &.{}, .inherit);
        const cold_colors = colors.lineColors(&oracle, a, current_file.content, current_file.lines, 0, current_file.lines.lines.len, 4, &.{}, .inherit);
        try std.testing.expectEqualDeep(cold_colors, current_colors);
        try std.testing.expect(syntax.testing.equal(oracle.provider.?.tree.?, state.provider.?.tree.?) != null);
        try std.testing.expectEqual(@as(usize, 2), owner.service.heldCount());
        if (iteration % 2 == 0) try warm(&state, lease);
    }
}
