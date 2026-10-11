//! 붙여넣기·단위 지우기·바꾸기·충돌 고르기·다시 읽기(문서 모델 §3.2·§3.4·§5.1, editor-merge-conflicts, editor-surface §4)의
//! **순수 판정** — 무엇을 바꾸고 caret 을 어디에 두는가. 문서 적용·undo·스크롤·클립보드 읽기·찾기 상태는 호출자(L4
//! `app_session/editor` 의 `pasteText`·`deleteBy`·`replaceCurrentMatch`·`replaceAllMatches`·`acceptConflict`,
//! `conflict.confirmReload`)가 한다. 조각 경계의 기억과 분배 규칙은 옆 `../clipboard.zig` 가, 단위 경계는 `../motion.zig`
//! 가 소유한다 — 이 파일은 그것으로 변경 목록을 짓는다.
//!
//! 이 폴더는 OS 를 부르지 않는다(`tests/boundary/editor_ops_sans_io.zig`).
const std = @import("std");
const clipboard = @import("../clipboard.zig");
const conflict = @import("../conflict.zig");
const delta = @import("../delta.zig");
const find = @import("../find.zig");
const line_index = @import("../line_index.zig");
const motion = @import("../motion.zig");
const selection = @import("../selection.zig");

const Change = delta.Change;
const LineIndex = line_index.LineIndex;
const Selection = selection.Selection;

/// 커서마다 변경을 많아야 하나 낸 편집. `of_sel[i]` 는 **문서 순서** `i` 번째 커서가 낸 변경의 인덱스이고, 변경을 안 낸
/// 커서는 `null` 이다(문서 처음의 Backspace, 같은 줄에 겹친 줄 단위 붙여넣기). 그 커서는 남의 caret 을 받지 않고 편집을
/// 따라 밀린 제자리를 지킨다(결함 13 — 예전에는 변경 인덱스와 커서 인덱스를 같다고 보았다).
pub const Edit = struct {
    changes: std.ArrayList(Change),
    of_sel: []?usize,

    pub fn deinit(self: *Edit, allocator: std.mem.Allocator) void {
        self.changes.deinit(allocator);
        allocator.free(self.of_sel);
        self.* = undefined;
    }

    /// **변경을 낸 커서는 넣은 글 뒤로 간다 — 매핑에 맡기지 않는다**(EDIT1·EDIT5). `inverse` 는 이 편집의 역연산이고, 그
    /// 각 range 가 편집 **후** 좌표로 새 구간을 가리킨다(지운 자리는 시작 = 끝). `out` 은 편집을 지나 매핑된 문서 순서
    /// 커서이고, 변경을 안 낸 커서는 그 값 그대로 둔다.
    pub fn placeCarets(self: Edit, inverse: []const Change, out: []Selection) void {
        for (self.of_sel, 0..) |k, i| {
            const ci = k orelse continue;
            if (i >= out.len or ci >= inverse.len) continue;
            out[i] = Selection.at(inverse[ci].end);
        }
    }
};

const Tagged = struct { change: Change, sel: usize };

fn sortTagged(items: []Tagged) void {
    std.mem.sort(Tagged, items, {}, struct {
        fn lessThan(_: void, a: Tagged, b: Tagged) bool {
            if (a.change.start != b.change.start) return a.change.start < b.change.start;
            return a.sel < b.sel;
        }
    }.lessThan);
}

/// 정렬한 꼬리표 목록을 `Edit` 로 접는다. `keep` 이 거절한 변경은 그 커서의 `of_sel` 이 `null` 로 남는다.
fn fold(allocator: std.mem.Allocator, tagged: []const Tagged, sel_count: usize, ctx: anytype, comptime keep: fn (@TypeOf(ctx), []const Change, Change) bool) !Edit {
    const of_sel = try allocator.alloc(?usize, sel_count);
    errdefer allocator.free(of_sel);
    @memset(of_sel, null);
    var changes: std.ArrayList(Change) = .empty;
    errdefer changes.deinit(allocator);
    for (tagged) |t| {
        if (!keep(ctx, changes.items, t.change)) continue;
        of_sel[t.sel] = changes.items.len;
        try changes.append(allocator, t.change);
    }
    return .{ .changes = changes, .of_sel = of_sel };
}

/// **붙여넣기**(§3.4). 조각 경계를 기억한 이 앱의 복사이고 조각 수가 커서 수와 같으면 커서마다 하나씩(**문서 순서로** —
/// 복사가 문서 순서로 담는다, 결함 12), 아니면 전부에 통짜로 넣는다. 선택 없이 복사한 것은 caret 이 있는 줄의 **머리**에
/// 넣는다(줄 중간에 끼우면 두 줄이 한 줄이 된다). `sels` 는 문서 순서이고, 변경 텍스트는 `text`·`meta` 를 빌린다.
///
/// 겹치는 변경은 뒤 것을 버린다 — 줄 단위에서 같은 줄 커서 여럿은 줄 머리가 같아 실제로 겹친다(PASTE7). `delta` 계약이
/// 정렬·비겹침을 요구하고, `selectionsForEdit` 는 겹침을 합치지 않으므로 이것이 이 경로의 유일한 방어다.
pub fn planPaste(allocator: std.mem.Allocator, content: []const u8, lines: LineIndex, sels: []const Selection, meta: ?clipboard.Meta, text: []const u8) !?Edit {
    if (sels.len == 0 or text.len == 0) return null;
    const line_wise = clipboard.describes(meta, text) and meta.?.from_empty_selection;
    const pieces = try allocator.alloc([]const u8, sels.len);
    defer allocator.free(pieces);
    const dist = clipboard.distribute(meta, text, sels.len, pieces);

    var tagged: std.ArrayList(Tagged) = .empty;
    defer tagged.deinit(allocator);
    for (sels, 0..) |sel, i| {
        const piece = switch (dist) {
            .per_cursor => |ps| ps[i],
            .whole => |w| w,
        };
        if (line_wise) {
            const line = lines.line(lines.lineAt(@min(sel.focus, content.len))) orelse continue;
            try tagged.append(allocator, .{ .change = .{ .start = line.start, .end = line.start, .text = piece }, .sel = i });
        } else {
            const lo = @min(sel.start(), content.len);
            const hi = @min(sel.end(), content.len);
            try tagged.append(allocator, .{ .change = .{ .start = lo, .end = hi, .text = piece }, .sel = i });
        }
    }
    if (tagged.items.len == 0) return null;
    sortTagged(tagged.items);
    return try fold(allocator, tagged.items, sels.len, line_wise, struct {
        fn keep(lw: bool, kept: []const Change, c: Change) bool {
            if (kept.len == 0) return true;
            const last = kept[kept.len - 1];
            if (c.start < last.end) return false;
            return !(lw and c.start == last.start);
        }
    }.keep);
}

/// 삭제가 지우는 **단위**(§3.2 "문자/단어/줄 단위 삭제").
///
/// **이동 일습의 거울이다** — `Motion`이 커서를 옮기는 자리를 이쪽은 지운다. 그래서 경계 계산을
/// `motion.zig`가 그대로 소유하고, 여기서 다시 세지 않는다. 세면 **"⌥←로 간 자리"와 "⌥⌫가 지운
/// 자리"가 갈리고**, 사용자는 그 차이를 설명할 수 없다.
pub const DeleteUnit = enum { char, word, line_edge };

/// **단위로 지운다**(§3.2). 선택이 있으면 단위와 무관하게 그 선택을 지운다 — 사용자가 이미 범위를 골랐는데 단위로 다시
/// 정하면 고른 것이 무시된다. `auto_closed_at` 은 자동으로 넣은 닫는 문자의 자리(§3.7 — Backspace 가 그것을 함께
/// 지운다). 변경이 겹치면 `null` 이다(호출자 결함 — 통째로 거절한다).
pub fn planDelete(allocator: std.mem.Allocator, content: []const u8, lines: LineIndex, sels: []const Selection, backward: bool, unit: DeleteUnit, auto_closed_at: ?usize) !?Edit {
    var tagged: std.ArrayList(Tagged) = .empty;
    defer tagged.deinit(allocator);
    for (sels, 0..) |sel, i| {
        var lo = @min(sel.start(), content.len);
        var hi = @min(sel.end(), content.len);
        if (lo == hi) {
            // caret뿐 — **단위만큼** 무른다. 경계는 `motion.zig`가 소유한다(이동과 같은 자리여야
            // "⌥←로 간 곳"과 "⌥⌫가 지운 곳"이 갈리지 않는다).
            if (backward) {
                if (lo == 0) continue; // 문서 처음: 지울 것이 없다
                // **자동으로 넣은 닫는 문자를 함께 지운다**(§3.7). `(|)`에서 Backspace를 누르면
                // 여는 것만 지우고 닫는 것이 남으면 사용자가 그것을 또 지워야 한다 — 자동 닫기가
                // 만든 일을 자동 닫기가 되무르는 것이 맞다.
                //
                // **표시가 지금 caret 바로 뒤일 때만** 그렇게 한다. 사용자가 직접 친 닫는 문자는
                // 표시가 없고, 그 자리를 떠났다가 돌아온 경우도 표시가 버려져 있다.
                if (unit == .char and auto_closed_at == hi and hi < content.len) {
                    hi = nextCharBoundary(content, hi);
                }
                lo = switch (unit) {
                    .char => prevCharBoundary(content, lo),
                    .word => motion.wordLeft(content, lo),
                    .line_edge => blk: {
                        // **줄 머리까지 — 들여쓰기도 함께 지운다**(§3.2, 2026-09-26).
                        //
                        // 예전에는 smart home 과 같은 자리(첫 글자)였다. 그러면 들여쓴 줄에서 `⌘⌫`를
                        // **두 번** 눌러야 줄이 비고, 그 사이에 「지웠는데 안 지워진 것처럼 보이는」
                        // 상태가 남는다. VS Code 도 macOS 도 **한 번에 0열**까지다 —
                        // `DeleteAllLeftAction` 이 `Range(line, 1, line, column)` 을 지운다.
                        //
                        // **이동과 일부러 갈린다.** 위 주석의 「이동과 같은 자리」는 `⌥` 짝의 규율이고
                        // (`⌥←`/`⌥⌫`는 여전히 `wordLeft` 하나를 쓴다), `⌘` 는 VS Code 자신이
                        // `CursorHome`(하이브리드+smart home)과 `DeleteAllLeft`(0열)로 가른다.
                        // 경계는 여전히 `motion.zig` 가 소유한다 — `^A` 와 **같은** `lineStart` 다.
                        const line = lines.line(lines.lineAt(lo)) orelse break :blk lo;
                        const start = motion.lineStart(line);
                        // **줄 머리에 있으면 앞 줄과 합친다.** 안 그러면 `lo` 가 안 줄어 아무것도 안
                        // 지우는 **죽은 키**가 된다 — `⌘⌦`가 줄 끝에서 겪던 것과 같은 함정이고,
                        // macOS 도 VS Code 도 그 자리에서 앞 개행을 지운다
                        // (적대적 검증 2026-08-27이 실측으로 잡았다).
                        break :blk if (start < lo) start else prevCharBoundary(content, lo);
                    },
                };
            } else {
                if (hi >= content.len) continue; // 문서 끝
                hi = switch (unit) {
                    .char => nextCharBoundary(content, hi),
                    .word => motion.wordRight(content, hi),
                    .line_edge => blk: {
                        const line = lines.line(lines.lineAt(hi)) orelse break :blk hi;
                        const end = motion.lineEnd(line);
                        // **이미 줄 끝이면 개행 하나를 먹는다** — 안 그러면 `⌘⌦`가 죽은 키가 된다.
                        break :blk if (end > hi) end else nextCharBoundary(content, hi);
                    },
                };
            }
        }
        // **지금은 닿지 않는 방어다**(적대적 검증 2026-08-27). caret 갈래가 단위마다 반드시
        // 전진하고(`lo == 0`·문서 끝은 그 앞에서 걸러진다), 선택이 있으면 `start() <= end()`가
        // 보장되므로 여기서 `lo >= hi`가 되는 입력을 만들지 못했다 — 지운 뮤턴트가 살아남아
        // 그것을 보였다.
        //
        // 그래도 남기는 이유: **`delta`의 계약이 빈 변경을 금지하지는 않는다.** 빈 범위가 흘러가면
        // 아무것도 안 바꾸는 undo 항목이 쌓여 **undo가 헛돈다** — `DEL3`이 그 증상(빈 문서에서
        // 무동작)을 재고, 이 줄은 그 성질을 **여기서** 지킨다.
        if (lo >= hi) continue;
        try tagged.append(allocator, .{ .change = .{ .start = lo, .end = hi, .text = "" }, .sel = i });
    }
    if (tagged.items.len == 0) return null;
    sortTagged(tagged.items);
    for (tagged.items[1..], 0..) |t, k| {
        if (t.change.start < tagged.items[k].change.end) return null; // 겹침 — 호출자 결함
    }
    return try fold(allocator, tagged.items, sels.len, {}, struct {
        fn keep(_: void, _: []const Change, _: Change) bool {
            return true;
        }
    }.keep);
}

/// 찾기 매치 하나의 문서 범위(줄 머리 + 줄 안 offset, 길이는 원문에서 훑은 byte). 줄이 낡았으면 `null`.
pub fn matchRange(content: []const u8, lines: LineIndex, m: find.Match) ?struct { start: usize, end: usize } {
    const line = lines.line(m.line) orelse return null;
    const start = line.start + m.start;
    if (start > content.len) return null;
    return .{ .start = start, .end = @min(start + m.len, content.len) };
}

/// 바꾸기의 변경 목록(§5.1). regex 로 펼친 글은 `owned` 가 들고, 변경이 그것을 빌린다.
pub const Replace = struct {
    changes: std.ArrayList(Change),
    owned: std.ArrayList([]u8),

    pub fn deinit(self: *Replace, allocator: std.mem.Allocator) void {
        for (self.owned.items) |o| allocator.free(o);
        self.owned.deinit(allocator);
        self.changes.deinit(allocator);
        self.* = undefined;
    }
};

/// **매치마다 변경 하나 — 한 번에 적용한다**(§5.1). 하나씩 바꾸고 다시 찾기를 되풀이하면 바꾼 글이 검색어를 품을 때
/// 끝나지 않는다(`a` → `aa`). regex 면 캡처를 펼친다 — 원문 UTF-8 은 한 번만 검사한다(매치 수만큼 문서 전체를 다시
/// 훑지 않는다). 낡은 매치는 건너뛰고, 남은 것이 없으면 `null`.
///
/// `error.InvalidUtf8` 은 원문이 UTF-8 이 아니고, `error.Expand` 는 바꿀 글을 펼치지 못했다(호출자가 「invalid replace」를
/// 띄운다).
pub fn planReplace(allocator: std.mem.Allocator, content: []const u8, lines: LineIndex, matches: []const find.Match, replace: []const u8, pattern: ?*find.regex.Pattern) error{ OutOfMemory, InvalidUtf8, Expand }!?Replace {
    if (pattern != null and !std.unicode.utf8ValidateSlice(content)) return error.InvalidUtf8;
    var out: Replace = .{ .changes = .empty, .owned = .empty };
    errdefer out.deinit(allocator);
    for (matches) |m| {
        const r = matchRange(content, lines, m) orelse continue;
        var text: []const u8 = replace;
        if (pattern) |p| {
            const owned = p.expandFromValidated(allocator, content, .{ .start = r.start, .end = r.end }, replace, m.regex_from orelse r.start) catch return error.Expand;
            out.owned.append(allocator, owned) catch {
                allocator.free(owned);
                return error.OutOfMemory;
            };
            text = owned;
        }
        try out.changes.append(allocator, .{ .start = r.start, .end = r.end, .text = text });
    }
    if (out.changes.items.len == 0) {
        out.deinit(allocator);
        return null;
    }
    return out;
}

/// 충돌 구간에서 **무엇을 고르는가**(S2). 「Ignore」는 두지 않는다 — 손으로 고치는 것과 같다.
/// `both` 는 현재 것 → 들어온 것(파일에 적힌 순서). `both_incoming_first` 는 그 반대 — Incoming 판의
/// 「둘 다 채택 (들어온 것 먼저)」(S3b-3c, VS Code 의 「Accept Combination (X First)」 상당).
pub const ConflictChoice = enum { current, incoming, both, both_incoming_first };

/// 충돌 고르기의 변경 하나. `owned` 는 둘 다 고를 때 이은 글이다(변경이 빌린다).
pub const Resolved = struct {
    change: Change,
    owned: ?[]u8 = null,

    pub fn deinit(self: *Resolved, allocator: std.mem.Allocator) void {
        if (self.owned) |o| allocator.free(o);
        self.* = undefined;
    }
};

/// **마커 줄까지 구간 전체를 고른 쪽의 본문으로 바꾼다**(editor-merge-conflicts). 본문은 원문 그대로 빌린다 — 줄을 모아
/// 새로 이으면 줄바꿈 종류(`\r\n`)가 그 구간에서만 바뀐다. 한쪽이 통째로 지워진 충돌은 빈 글이다. 줄이 낡았으면 `null`.
pub fn planConflictChoice(allocator: std.mem.Allocator, content: []const u8, lines: LineIndex, r: conflict.Region, choice: ConflictChoice) !?Resolved {
    const head = lines.line(r.start) orelse return null;
    const tail = lines.line(r.end) orelse return null;
    const remove_from = head.start;
    const remove_to = @min(tail.end_with_ending, content.len);
    if (remove_to < remove_from) return null;

    const ours = r.ours();
    const theirs = r.theirs();
    const ours_text = sliceOfLines(content, lines, ours.from, ours.to);
    const theirs_text = sliceOfLines(content, lines, theirs.from, theirs.to);
    const first, const second = switch (choice) {
        .current => return .{ .change = .{ .start = remove_from, .end = remove_to, .text = ours_text } },
        .incoming => return .{ .change = .{ .start = remove_from, .end = remove_to, .text = theirs_text } },
        // **둘 다**는 «현재 것» 다음에 «들어온 것»이다(VS Code 와 같은 순서 — 파일에 적힌 순서다).
        .both => .{ ours_text, theirs_text },
        // Incoming 판의 「둘 다 채택 (들어온 것 먼저)」(S3b-3c) — 같은 이어붙이기, 순서만 반대다.
        .both_incoming_first => .{ theirs_text, ours_text },
    };
    const joined = try allocator.alloc(u8, first.len + second.len);
    @memcpy(joined[0..first.len], first);
    @memcpy(joined[first.len..], second);
    return .{ .change = .{ .start = remove_from, .end = remove_to, .text = joined }, .owned = joined };
}

/// `[from, to)` 줄들의 **원문 조각**(줄바꿈 포함). 범위가 비면 빈 조각이다.
fn sliceOfLines(content: []const u8, lines: LineIndex, from: u32, to: u32) []const u8 {
    if (to <= from) return &.{};
    const first = lines.line(from) orelse return &.{};
    const last = lines.line(to - 1) orelse return &.{};
    const end = @min(last.end_with_ending, content.len);
    if (end <= first.start) return &.{};
    return content[first.start..end];
}

/// **다시 읽기의 변경** — 지금 내용 `old` 를 디스크 내용 `new` 로 바꾸되 **같은 앞뒤는 변경 밖에 둔다**(editor-surface
/// §4 「외부 변경을 받아들일 때 … undo/cursor 를 깨지 않는다」, 결함 14). 문서 전체를 변경 하나로 바꾸면 모든 caret 이
/// 그 변경 안이라 머리로 접힌다. 경계는 코드포인트 경계로 물린다 — 글자 가운데를 자르면 caret·LSP 위치가 글자 안에 선다.
/// `text` 는 `new` 를 빌린다.
pub fn reloadChange(old: []const u8, new: []const u8) Change {
    const limit = @min(old.len, new.len);
    var prefix: usize = 0;
    while (prefix < limit and old[prefix] == new[prefix]) prefix += 1;
    while (prefix > 0 and (isContinuation(old, prefix) or isContinuation(new, prefix))) prefix -= 1;
    var suffix: usize = 0;
    while (suffix < limit - prefix and old[old.len - 1 - suffix] == new[new.len - 1 - suffix]) suffix += 1;
    while (suffix > 0 and (isContinuation(old, old.len - suffix) or isContinuation(new, new.len - suffix))) suffix -= 1;
    return .{ .start = prefix, .end = old.len - suffix, .text = new[prefix .. new.len - suffix] };
}

fn isContinuation(bytes: []const u8, at: usize) bool {
    return at < bytes.len and (bytes[at] & 0xC0) == 0x80;
}

/// `at` **앞** 글자의 시작 byte. UTF-8 이어지는 byte(`0b10xxxxxx`)를 건너뛴다.
///
/// **cluster가 아니라 code point 경계다.** 결합 문자(한글 NFD·이모지 ZWJ)는 여러 code point가
/// 한 글자로 보이는데, 그것까지 한 번에 무르려면 §3.8의 cluster 규칙이 필요하다 — 그 규칙은
/// `grapheme` 층이 소유하고 이 슬라이스 밖이다. **지금은 code point 단위이고, 깨진 UTF-8은
/// 만들지 않는다**(그것이 이 함수가 막는 것이다).
pub fn prevCharBoundary(bytes: []const u8, at: usize) usize {
    var i = @min(at, bytes.len);
    if (i == 0) return 0;
    i -= 1;
    while (i > 0 and (bytes[i] & 0xC0) == 0x80) i -= 1;
    return i;
}

/// `at` **뒤** 글자의 끝 byte.
pub fn nextCharBoundary(bytes: []const u8, at: usize) usize {
    if (at >= bytes.len) return bytes.len;
    const n = std.unicode.utf8ByteSequenceLength(bytes[at]) catch return at + 1;
    return @min(at + n, bytes.len);
}

// ── 판정자 ────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn applyForTest(allocator: std.mem.Allocator, content: []const u8, changes: []const Change) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var at: usize = 0;
    for (changes) |c| {
        try out.appendSlice(allocator, content[at..c.start]);
        try out.appendSlice(allocator, c.text);
        at = c.end;
    }
    try out.appendSlice(allocator, content[at..]);
    return out.toOwnedSlice(allocator);
}

fn metaForTest(allocator: std.mem.Allocator, text: []const u8, ends: []const usize, from_empty: bool) !clipboard.Meta {
    return .{ .text = try allocator.dupe(u8, text), .ends = try allocator.dupe(usize, ends), .from_empty_selection = from_empty };
}

test "planPaste 는 조각을 문서 순서 커서에 나눈다 — primary 가 어디든 (결함 12)" {
    const a = testing.allocator;
    const content = "aa bb cc\n";
    var lines = try line_index.build(a, content);
    defer lines.deinit();
    var meta = try metaForTest(a, "XX\nYY\nZZ", &.{ 2, 5, 8 }, false);
    defer meta.deinit(a);
    const sels = [_]Selection{ Selection.fromPoints(0, 2), Selection.fromPoints(3, 5), Selection.fromPoints(6, 8) };
    var e = (try planPaste(a, content, lines, &sels, meta, "XX\nYY\nZZ")).?;
    defer e.deinit(a);
    const out = try applyForTest(a, content, e.changes.items);
    defer a.free(out);
    try testing.expectEqualStrings("XX YY ZZ\n", out);
}

test "planPaste 줄 단위 — 같은 줄의 뒤 커서는 변경을 안 내고 of_sel 이 null 이다 (PASTE7·결함 13)" {
    const a = testing.allocator;
    const content = "alpha\nbeta\ngamma\n";
    var lines = try line_index.build(a, content);
    defer lines.deinit();
    var meta = try metaForTest(a, "alpha\n", &.{6}, true);
    defer meta.deinit(a);
    const sels = [_]Selection{ Selection.at(6), Selection.at(8), Selection.at(13) };
    var e = (try planPaste(a, content, lines, &sels, meta, "alpha\n")).?;
    defer e.deinit(a);
    try testing.expectEqual(@as(usize, 2), e.changes.items.len);
    try testing.expectEqualSlices(?usize, &.{ 0, null, 1 }, e.of_sel);
    const out = try applyForTest(a, content, e.changes.items);
    defer a.free(out);
    try testing.expectEqualStrings("alpha\nalpha\nbeta\nalpha\ngamma\n", out);
}

test "planPaste 외부 클립보드는 통짜다 — 기억이 남의 문자열을 자르지 않는다 (PASTE3)" {
    const a = testing.allocator;
    const content = "aa bb\n";
    var lines = try line_index.build(a, content);
    defer lines.deinit();
    var meta = try metaForTest(a, "aa\nbb", &.{ 2, 5 }, false);
    defer meta.deinit(a);
    const sels = [_]Selection{ Selection.fromPoints(0, 2), Selection.fromPoints(3, 5) };
    var e = (try planPaste(a, content, lines, &sels, meta, "PP\nQQ")).?;
    defer e.deinit(a);
    const out = try applyForTest(a, content, e.changes.items);
    defer a.free(out);
    try testing.expectEqualStrings("PP\nQQ PP\nQQ\n", out);
}

test "planDelete — 문서 처음의 caret 은 변경을 안 내고 of_sel 이 null 이다 (DEL6·결함 13)" {
    const a = testing.allocator;
    const content = "ab\ncd\n";
    var lines = try line_index.build(a, content);
    defer lines.deinit();
    const sels = [_]Selection{ Selection.at(0), Selection.at(4) };
    var e = (try planDelete(a, content, lines, &sels, true, .char, null)).?;
    defer e.deinit(a);
    try testing.expectEqualSlices(?usize, &.{ null, 0 }, e.of_sel);
    try testing.expectEqual(@as(usize, 3), e.changes.items[0].start);
    try testing.expectEqual(@as(usize, 4), e.changes.items[0].end);
}

test "planDelete — 단위와 자동 닫기, 겹치면 거절한다 (§3.2·§3.7)" {
    const a = testing.allocator;
    {
        const content = "  foo bar\n";
        var lines = try line_index.build(a, content);
        defer lines.deinit();
        const sels = [_]Selection{Selection.at(9)};
        var w = (try planDelete(a, content, lines, &sels, true, .word, null)).?;
        defer w.deinit(a);
        try testing.expectEqual(@as(usize, 6), w.changes.items[0].start);
        var l = (try planDelete(a, content, lines, &sels, true, .line_edge, null)).?;
        defer l.deinit(a);
        try testing.expectEqual(@as(usize, 0), l.changes.items[0].start); // 들여쓰기까지 0열
    }
    {
        const content = "()\n";
        var lines = try line_index.build(a, content);
        defer lines.deinit();
        const sels = [_]Selection{Selection.at(1)};
        var e = (try planDelete(a, content, lines, &sels, true, .char, 1)).?;
        defer e.deinit(a);
        try testing.expectEqual(@as(usize, 0), e.changes.items[0].start);
        try testing.expectEqual(@as(usize, 2), e.changes.items[0].end); // 닫는 것까지
    }
    {
        const content = "abcd\n";
        var lines = try line_index.build(a, content);
        defer lines.deinit();
        const sels = [_]Selection{ Selection.fromPoints(0, 3), Selection.at(2) };
        try testing.expect((try planDelete(a, content, lines, &sels, true, .char, null)) == null);
    }
}

test "reloadChange 는 같은 앞뒤를 남기고 코드포인트 경계에서 자른다 (결함 14)" {
    {
        const c = reloadChange("Xone\ntwo\nthree\n", "ONE\ntwo\nthree\n");
        try testing.expectEqual(@as(usize, 0), c.start);
        try testing.expectEqual(@as(usize, 4), c.end);
        try testing.expectEqualStrings("ONE", c.text);
    }
    {
        // "가"(EA B0 80) → "각"(EA B0 81): 앞 두 byte 가 같아도 글자 머리에서 자른다.
        const c = reloadChange("a가b", "a각b");
        try testing.expectEqual(@as(usize, 1), c.start);
        try testing.expectEqual(@as(usize, 4), c.end);
        try testing.expectEqualStrings("각", c.text);
    }
    {
        const c = reloadChange("same", "same");
        try testing.expectEqual(c.start, c.end);
        try testing.expectEqual(@as(usize, 0), c.text.len);
    }
    {
        // 앞뒤가 겹칠 수 있는 반복 — 앞이 먼저 먹고 뒤는 남은 길이까지만.
        const c = reloadChange("aaa", "aaaa");
        try testing.expectEqual(@as(usize, 3), c.start);
        try testing.expectEqual(@as(usize, 3), c.end);
        try testing.expectEqualStrings("a", c.text);
    }
}

test "planReplace — 매치마다 변경, 낡은 매치는 건너뛴다 (§5.1)" {
    const a = testing.allocator;
    const content = "foo bar foo\n";
    var lines = try line_index.build(a, content);
    defer lines.deinit();
    const matches = [_]find.Match{ .{ .line = 0, .start = 0, .len = 3 }, .{ .line = 0, .start = 8, .len = 3 }, .{ .line = 9, .start = 0, .len = 3 } };
    var r = (try planReplace(a, content, lines, &matches, "X", null)).?;
    defer r.deinit(a);
    const out = try applyForTest(a, content, r.changes.items);
    defer a.free(out);
    try testing.expectEqualStrings("X bar X\n", out);
    try testing.expect((try planReplace(a, content, lines, matches[2..], "X", null)) == null);
}

test "planReplace — regex 캡처를 펼친다 (§5.1)" {
    const a = testing.allocator;
    const content = "k=1 k=2\n";
    var lines = try line_index.build(a, content);
    defer lines.deinit();
    var p = try find.regex.Pattern.initDocument("k=(\\d)", true, .anycrlf);
    defer p.deinit();
    const matches = [_]find.Match{ .{ .line = 0, .start = 0, .len = 3 }, .{ .line = 0, .start = 4, .len = 3 } };
    var r = (try planReplace(a, content, lines, &matches, "v$1", &p)).?;
    defer r.deinit(a);
    const out = try applyForTest(a, content, r.changes.items);
    defer a.free(out);
    try testing.expectEqualStrings("v1 v2\n", out);
}

test "planConflictChoice — 고른 쪽 본문으로 마커까지 바꾸고, 둘 다는 순서대로 잇는다" {
    const a = testing.allocator;
    const content = "x\n<<<<<<< ours\nA\r\n=======\nB\n>>>>>>> theirs\ny\n";
    var lines = try line_index.build(a, content);
    defer lines.deinit();
    const region: conflict.Region = .{ .start = 1, .separator = 3, .end = 5 };
    const Case = struct { choice: ConflictChoice, want: []const u8 };
    for ([_]Case{
        .{ .choice = .current, .want = "x\nA\r\ny\n" },
        .{ .choice = .incoming, .want = "x\nB\ny\n" },
        .{ .choice = .both, .want = "x\nA\r\nB\ny\n" },
        .{ .choice = .both_incoming_first, .want = "x\nB\nA\r\ny\n" },
    }) |c| {
        var r = (try planConflictChoice(a, content, lines, region, c.choice)).?;
        defer r.deinit(a);
        const out = try applyForTest(a, content, &.{r.change});
        defer a.free(out);
        try testing.expectEqualStrings(c.want, out);
    }
}
