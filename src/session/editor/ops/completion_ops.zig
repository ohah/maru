//! 자동완성 확정(native-editor §8.2g-f)의 **순수 판정** — 어디서부터 덮고, 자동 import(additional)를 받을지, 다른 커서마다
//! 어디에 넣고 caret 을 어디에 둘지. 목록 상태·적용·커서 저장은 호출자(L4 `app_session/editor/completion.zig` 의
//! `accept`)가 한다. 자리 규칙(`multiSites`)·한 목록으로 합치기(`mergeMany`)·caret 자리(`siteEnds`)는
//! `../../lsp/completion.zig` 가 소유한다 — 이 파일은 그것을 잇는 판정이다.
//!
//! 이 폴더는 OS 를 부르지 않는다(`tests/boundary/editor_ops_sans_io.zig`).
const std = @import("std");
const completion = @import("../../lsp/completion.zig");
const delta = @import("../delta.zig");
const selection = @import("../selection.zig");
const text_edits = @import("../../lsp/text_edits.zig");

const Change = delta.Change;
const Selection = selection.Selection;
const Span = completion.Span;

/// Pending Enter requires every additional edit; ordinary preview-era acceptance
/// retains its existing conservative additional-edit filtering.
pub const CommitMode = enum { ordinary, atomic };

pub const Accept = struct {
    /// 적용할 정렬된 변경 — additional(받으면) + 자리마다 넣을 글. undo 하나다.
    changes: text_edits.Changes,
    /// 자리마다 caret(넣은 글 끝, 편집 **후** 좌표). `[0]` 이 primary 다.
    ends: []usize,
    /// 놓은 자리 수(primary 포함). 놓을 수 없던 커서(primary 가 덮은 범위 안 · import 와 겹침)는 빠진다.
    site_count: usize,
    /// additional 을 받았는가.
    allow: bool,

    pub fn deinit(self: *Accept, allocator: std.mem.Allocator) void {
        self.changes.deinit(allocator);
        allocator.free(self.ends);
        self.* = undefined;
    }
};

/// **확정 한 번**(§8.2g-f). `caret` 은 primary 의 caret, `word_start` 는 목록이 든 낱말 시작, `edit_start` 는 서버
/// textEdit 의 머리(caret 앞일 때만 낱말 시작을 이긴다). `same_version` 은 응답 뒤 문서가 안 바뀌었는가 — 바뀌었으면
/// additional 은 전부 낱말 앞에서 끝날 때만 받는다. `extras` 는 primary 말고 다른 커서들(순서 무관).
///
/// **다른 커서마다 같은 글을 넣는다** — 앞 글이 primary 가 덮는 글(`[start, caret)`)과 같으면 그만큼 덮고, 다르면 넣기만
/// 한다(VS Code `snippetSession` 의 규칙). additional 이 다른 커서의 자리와 겹치면 **그 커서만** 놓는다 — primary 의
/// 확정(과 import)이 먼저다.
pub fn planAccept(
    allocator: std.mem.Allocator,
    content: []const u8,
    caret_in: usize,
    word_start: usize,
    edit_start: ?usize,
    insert: []const u8,
    additional: []const Change,
    same_version: bool,
    extras: []const Selection,
    mode: CommitMode,
) !Accept {
    const caret = @min(caret_in, content.len);
    var start = word_start;
    if (edit_start) |es| if (es <= caret) {
        start = es;
    };
    var allow = same_version;
    if (!allow) {
        allow = true;
        for (additional) |c| if (c.end > start) {
            allow = false;
        };
    }
    // A pending transaction cannot degrade into a primary-only edit when an
    // additional edit no longer has a valid basis.
    if (mode == .atomic and !allow and additional.len > 0) return error.StaleAdditional;
    var others: std.ArrayList(Span) = .empty;
    defer others.deinit(allocator);
    for (extras) |e| try others.append(allocator, .{ .start = e.start(), .end = e.end() });
    const primary_site: Span = .{ .start = @min(start, caret), .end = caret };
    const decided = try completion.multiSites(allocator, content, primary_site, others.items);
    defer allocator.free(decided);
    var sites: std.ArrayList(Span) = .empty;
    defer sites.deinit(allocator);
    try sites.append(allocator, primary_site);
    for (decided) |d| if (d) |site| try sites.append(allocator, site);
    const used: []const Change = if (allow) additional else &.{};
    var changes = completion.mergeMany(allocator, used, sites.items, insert) catch |err| switch (err) {
        // additional 이 다른 커서의 자리와 겹치면 **그 커서만** 놓는다(적대적 1회차: 예전엔 전부 놓았다).
        error.Overlap => blk: {
            var k: usize = 1;
            while (k < sites.items.len) {
                var hit = false;
                for (used) |c| if (completion.conflicts(sites.items[k], .{ .start = c.start, .end = c.end })) {
                    hit = true;
                };
                if (hit) _ = sites.orderedRemove(k) else k += 1;
            }
            break :blk try completion.mergeMany(allocator, used, sites.items, insert);
        },
        else => |e| return e,
    };
    errdefer changes.deinit(allocator);
    // caret 은 자리마다 insert 끝 — 정렬된 목록에서 **그 자리 자신의 항목**까지 길이 차를 쌓아 잰다(같은 시작의 import 가
    // 앞에 있어도 맞다).
    const ends = try completion.siteEnds(allocator, changes, used.len, sites.items);
    return .{ .changes = changes, .ends = ends, .site_count = sites.items.len, .allow = allow };
}

// ── 판정자 ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "planAccept — 다른 커서도 같은 접두사를 덮고 caret 은 자리마다 넣은 글 끝이다 (§8.2g-f)" {
    const a = testing.allocator;
    const content = "fo x\nfo y\n";
    var plan = try planAccept(a, content, 2, 0, null, "foo", &.{}, true, &.{Selection.at(7)}, .ordinary);
    defer plan.deinit(a);
    try testing.expectEqual(@as(usize, 2), plan.site_count);
    try testing.expectEqual(@as(usize, 2), plan.changes.items.len);
    try testing.expectEqualSlices(usize, &.{ 3, 9 }, plan.ends);
}

test "planAccept — 응답 뒤 문서가 바뀌면 낱말 뒤로 걸치는 additional 은 버린다" {
    const a = testing.allocator;
    const content = "import\nfo\n";
    const imports = [_]Change{.{ .start = 0, .end = 0, .text = "use x;\n" }};
    var keep = try planAccept(a, content, 9, 7, null, "foo", &imports, false, &.{}, .ordinary);
    defer keep.deinit(a);
    try testing.expect(keep.allow);
    const late = [_]Change{.{ .start = 8, .end = 9, .text = "!" }};
    var drop = try planAccept(a, content, 9, 7, null, "foo", &late, false, &.{}, .ordinary);
    defer drop.deinit(a);
    try testing.expect(!drop.allow);
    try testing.expectEqual(@as(usize, 1), drop.changes.items.len);
}

test "planAccept — additional 과 겹치는 다른 커서만 놓는다" {
    const a = testing.allocator;
    const content = "ab\nfo\n";
    const imports = [_]Change{.{ .start = 0, .end = 2, .text = "AB" }};
    var plan = try planAccept(a, content, 5, 3, null, "foo", &imports, true, &.{Selection.at(1)}, .ordinary);
    defer plan.deinit(a);
    try testing.expectEqual(@as(usize, 1), plan.site_count);
    try testing.expectEqual(@as(usize, 2), plan.changes.items.len); // import + primary
}

/// Resolve 뒤의 확정은 Enter 때 문맥에만 적용한다. 서버의 재분석이나
/// 사용자 입력이 끝나는 시각에 따라 다른 편집을 만들지 않도록 하는 계약이다.
pub const PendingContext = struct {
    surface: u64,
    document: usize,
    revision: u64,
    target_epoch: u64,
    primary: Selection,
    extras: []const Selection,
};
pub const PendingCompletion = struct {
    context: PendingContext,
    started_ms: u64,
};
pub const pending_timeout_ms: u64 = 5_000;
pub const PendingDecision = enum { wait, apply, cancel };

/// 시간이 다 되면 원문을 보존한다. 응답이 tick보다 먼저 와도 같은 시한을
/// 검사하며, 같은 글로 Undo한 문서도 revision이 다르면 별개의 문맥이다.
pub fn pendingDecision(p: PendingCompletion, current: ?PendingContext, now_ms: u64, response: bool) PendingDecision {
    const c = current orelse return .cancel;
    const old = p.context;
    if (now_ms < p.started_ms or now_ms - p.started_ms >= pending_timeout_ms) return .cancel;
    if (c.surface != old.surface or c.document != old.document or c.revision != old.revision or c.target_epoch != old.target_epoch or
        !std.meta.eql(c.primary, old.primary) or c.extras.len != old.extras.len) return .cancel;
    for (c.extras, old.extras) |a, b| if (!std.meta.eql(a, b)) return .cancel;
    return if (response) .apply else .wait;
}

test "CPLpending resolve atomic commit — normal, old timeout and deadline boundaries" {
    const t = std.testing;
    const c: PendingContext = .{ .surface = 7, .document = 11, .revision = 2, .target_epoch = 1, .primary = Selection.at(10), .extras = &.{} };
    const p: PendingCompletion = .{ .context = c, .started_ms = 100 };
    for ([_]u64{ 100, 399, 400, 401, 2600, 5099 }) |now| {
        try t.expectEqual(PendingDecision.wait, pendingDecision(p, c, now, false));
        try t.expectEqual(PendingDecision.apply, pendingDecision(p, c, now, true));
    }
    for ([_]u64{ 99, 5100, 5101, std.math.maxInt(u64) }) |now| {
        try t.expectEqual(PendingDecision.cancel, pendingDecision(p, c, now, false));
        try t.expectEqual(PendingDecision.cancel, pendingDecision(p, c, now, true));
    }
}

test "CPLpending rejects changed document and every selection field" {
    const t = std.testing;
    const c: PendingContext = .{ .surface = 7, .document = 11, .revision = 2, .target_epoch = 1, .primary = Selection.at(10), .extras = &.{Selection.at(3)} };
    const p: PendingCompletion = .{ .context = c, .started_ms = 100 };
    try t.expectEqual(PendingDecision.cancel, pendingDecision(p, null, 101, true));
    // These are distinct invalidation paths, rather than repeated time trials.
    for (0..21) |i| {
        var changed = c;
        var extra = [_]Selection{Selection.at(3)};
        switch (i) {
            0 => changed.surface += 1,
            1 => changed.document += 1,
            2 => changed.revision += 1,
            3 => changed.primary.anchor_start += 1,
            4 => changed.primary.anchor_end += 1,
            5 => changed.primary.focus += 1,
            6 => changed.primary.goal = .{ .col = 4 },
            7 => changed.primary.anchor_goal = .{ .row_col = 2 },
            8 => changed.extras = &.{},
            9 => {
                extra[0].focus += 1;
                changed.extras = &extra;
            },
            10 => {
                extra[0].anchor_start += 1;
                changed.extras = &extra;
            },
            11 => {
                extra[0].anchor_end += 1;
                changed.extras = &extra;
            },
            12 => changed.primary.kind = .word,
            13 => {
                extra[0].kind = .line;
                changed.extras = &extra;
            },
            14 => {
                extra[0].goal = .{ .col = 1 };
                changed.extras = &extra;
            },
            15 => {
                extra[0].anchor_goal = .{ .col = 1 };
                changed.extras = &extra;
            },
            16 => changed.extras = &.{ Selection.at(3), Selection.at(4) },
            17 => changed.revision = 0,
            18 => changed.document = 0,
            19 => changed.surface = 0,
            20 => changed.target_epoch += 1,
            else => unreachable,
        }
        try t.expectEqual(PendingDecision.cancel, pendingDecision(p, changed, 101, true));
        try t.expectEqual(PendingDecision.cancel, pendingDecision(p, changed, 101, false));
        try t.expectEqual(PendingDecision.apply, pendingDecision(p, c, 101, true));
    }
}

test "CPLpending atomic plan rejects dropping a required additional edit" {
    const content = "prefix pr\ntail";
    const late = [_]Change{.{ .start = 10, .end = 10, .text = "import" }};
    try std.testing.expectError(error.StaleAdditional, planAccept(std.testing.allocator, content, 9, 7, null, "printf", &late, false, &.{}, .atomic));
    var ordinary = try planAccept(std.testing.allocator, content, 9, 7, null, "printf", &late, false, &.{}, .ordinary);
    defer ordinary.deinit(std.testing.allocator);
    try std.testing.expect(!ordinary.allow);
    var same = try planAccept(std.testing.allocator, content, 9, 7, null, "printf", &late, true, &.{}, .atomic);
    defer same.deinit(std.testing.allocator);
    try std.testing.expect(same.allow);
}
