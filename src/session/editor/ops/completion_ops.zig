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
    var plan = try planAccept(a, content, 2, 0, null, "foo", &.{}, true, &.{Selection.at(7)});
    defer plan.deinit(a);
    try testing.expectEqual(@as(usize, 2), plan.site_count);
    try testing.expectEqual(@as(usize, 2), plan.changes.items.len);
    try testing.expectEqualSlices(usize, &.{ 3, 9 }, plan.ends);
}

test "planAccept — 응답 뒤 문서가 바뀌면 낱말 뒤로 걸치는 additional 은 버린다" {
    const a = testing.allocator;
    const content = "import\nfo\n";
    const imports = [_]Change{.{ .start = 0, .end = 0, .text = "use x;\n" }};
    var keep = try planAccept(a, content, 9, 7, null, "foo", &imports, false, &.{});
    defer keep.deinit(a);
    try testing.expect(keep.allow);
    const late = [_]Change{.{ .start = 8, .end = 9, .text = "!" }};
    var drop = try planAccept(a, content, 9, 7, null, "foo", &late, false, &.{});
    defer drop.deinit(a);
    try testing.expect(!drop.allow);
    try testing.expectEqual(@as(usize, 1), drop.changes.items.len);
}

test "planAccept — additional 과 겹치는 다른 커서만 놓는다" {
    const a = testing.allocator;
    const content = "ab\nfo\n";
    const imports = [_]Change{.{ .start = 0, .end = 2, .text = "AB" }};
    var plan = try planAccept(a, content, 5, 3, null, "foo", &imports, true, &.{Selection.at(1)});
    defer plan.deinit(a);
    try testing.expectEqual(@as(usize, 1), plan.site_count);
    try testing.expectEqual(@as(usize, 2), plan.changes.items.len); // import + primary
}
