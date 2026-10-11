//! 줄 조작(문서 모델 §3.9a·§3.9b·§3.7 주석 토글)의 **순수 판정** — 변경 목록과 편집 **뒤** 선택을 계산한다.
//!
//! 적용·undo·스크롤 앵커·reveal 은 호출자(L4 `app_session/editor` 의 `applyLineEdit`)가 한다. 여기서는 문서 bytes·
//! 줄 표·문서 순서로 정렬된 선택만 받는다(`selectionsForEdit` 의 순서 — 편집 뒤 선택도 그 순서로 낸다).
//!
//! **caret 은 매핑에 맡기지 않는다.** `delta.mapOffset` 은 삽입 지점의 offset 을 밀지 않고 바뀐 범위 안의 offset 은
//! 범위 시작으로 접어, 옮긴 줄을 caret 이 안 따라가고(§3.9a 「선택은 따라간다」) 지운 줄의 caret 이 열 0 으로 가고
//! Enter 의 caret 이 새 개행 앞에 남았다(native-editor 결함 6·7·8). 그래서 `after` 를 직접 낸다. 들여쓰기·주석 토글·
//! 대소문자는 줄 머리나 제자리에서만 바뀌어 매핑이 맞으므로 `after` 가 없다.
//!
//! 이 폴더는 OS 를 부르지 않는다 — `tests/boundary/editor_ops_sans_io.zig` 가 폴더를 훑어 지킨다
//! (이식 계획 docs/plans/app-session-portability.md §1.5).
const std = @import("std");
const delta = @import("../delta.zig");
const line_index = @import("../line_index.zig");
const selection = @import("../selection.zig");
const case = @import("../../../terminal/selection.zig");

const Change = delta.Change;
const LineIndex = line_index.LineIndex;
const Selection = selection.Selection;

/// 줄 조작 하나의 결과. `changes` 는 문서 순서이고 겹치지 않는다(`delta` 의 불변식). `after` 가 있으면 그것이 편집
/// 뒤 선택이다(입력 `sels` 와 같은 길이·같은 순서). 텍스트는 `owned` 가 갖는다.
pub const Plan = struct {
    changes: std.ArrayList(Change) = .empty,
    owned: std.ArrayList([]u8) = .empty,
    after: ?[]Selection = null,

    pub fn deinit(self: *Plan, allocator: std.mem.Allocator) void {
        for (self.owned.items) |t| allocator.free(t);
        self.owned.deinit(allocator);
        self.changes.deinit(allocator);
        if (self.after) |a| allocator.free(a);
        self.* = .{};
    }

    fn own(self: *Plan, allocator: std.mem.Allocator, t: []u8) !void {
        self.owned.append(allocator, t) catch |e| {
            allocator.free(t);
            return e;
        };
    }
};

/// 커서들이 **걸친 줄 번호**(중복 없이 오름차순). 줄 조작 넷과 주석 토글이 **같은 답**을 써야 한다 — 갈리면 `⌘/` 로
/// 주석 처리한 범위와 `⇧⌘K` 로 지우는 범위가 달라진다(§3.9a).
///
/// **선택이 다음 줄 머리에서 끝나면 그 줄은 뺀다.** 줄 전체를 끌어 고르면 끝이 다음 줄 offset 0 이 되는데, 그대로
/// 넣으면 **고르지 않은 줄이 딸려 온다**(2026-08-27 실측). VSCode·Xcode 가 같은 자리에서 뺀다.
///
/// **중복은 정렬 뒤 인접 비교로 지운다.** 넣을 때마다 앞을 훑으면 O(n²)이고 커서는 `⌘⌃D` 로 수천 개가 된다.
/// 한 줄에 커서가 여럿이어도 **한 번만** 세야 — 두 번 세면 주석은 `////` 가 되고 줄 이동은 **두 칸** 움직인다.
pub fn selectedLineNumbers(allocator: std.mem.Allocator, content: []const u8, lines: LineIndex, sels: []const Selection, out: *std.ArrayList(usize)) !bool {
    if (sels.len == 0) return false;
    for (sels) |sel| {
        const s_off = @min(sel.start(), content.len);
        var e_off = @min(sel.end(), content.len);
        if (e_off > s_off) {
            if (lines.line(lines.lineAt(e_off))) |l| {
                if (l.start == e_off) e_off -= 1;
            }
        }
        var n = lines.lineAt(s_off);
        const hi = lines.lineAt(e_off);
        while (n <= hi) : (n += 1) try out.append(allocator, n);
    }
    if (out.items.len == 0) return false;
    std.mem.sort(usize, out.items, {}, std.sort.asc(usize));
    var w: usize = 0;
    for (out.items, 0..) |n, i| {
        if (i == 0 or n != out.items[w - 1]) {
            out.items[w] = n;
            w += 1;
        }
    }
    out.shrinkRetainingCapacity(w);
    return true;
}

/// 줄 머리에서 `offset` 까지의 **글자 수**(코드포인트). 「같은 열」을 byte 로 세면 한글 줄에서 글자 가운데로 떨어진다.
pub fn lineColumn(content: []const u8, line_start: usize, offset: usize) usize {
    var n: usize = 0;
    for (content[line_start..@min(offset, content.len)]) |b| {
        if (b & 0xC0 != 0x80) n += 1;
    }
    return n;
}

/// `col` 글자만큼 들어간 offset — 줄이 짧으면 줄 끝(§3.9a 「다음 줄의 같은 열」).
pub fn offsetAtColumn(content: []const u8, line_start: usize, line_end: usize, col: usize) usize {
    var off = line_start;
    var n: usize = 0;
    while (off < line_end and n < col) : (n += 1) {
        off += 1;
        while (off < line_end and content[off] & 0xC0 == 0x80) off += 1;
    }
    return off;
}

fn shiftSelection(sel: Selection, by: i64) Selection {
    var out = sel;
    out.anchor_start = @intCast(@as(i64, @intCast(sel.anchor_start)) + by);
    out.anchor_end = @intCast(@as(i64, @intCast(sel.anchor_end)) + by);
    out.focus = @intCast(@as(i64, @intCast(sel.focus)) + by);
    return out;
}

/// 연속한 줄 무리 `[lo, hi]` 를 차례로 낸다.
const Runs = struct {
    nums: []const usize,
    i: usize = 0,

    fn next(self: *Runs) ?struct { lo: usize, hi: usize } {
        if (self.i >= self.nums.len) return null;
        var j = self.i;
        while (j + 1 < self.nums.len and self.nums[j + 1] == self.nums[j] + 1) j += 1;
        defer self.i = j + 1;
        return .{ .lo = self.nums[self.i], .hi = self.nums[j] };
    }
};

/// `⇧⌘K` — 걸친 줄들을 지운다(§3.9a). 지울 것이 없으면 `null`.
///
/// **연속한 줄은 한 덩어리로 지운다.** 줄마다 따로 지우면 「마지막 줄은 앞 개행을 먹는다」가 바로 앞 줄의 범위와
/// 겹쳐 `delta` 가 통째로 거절했다(결함 2). **앞 개행을 먹는 것은 개행이 없는 마지막 줄뿐이다** — `"a\nb\n"` 에서
/// `b` 를 지우면 `"a\n"` 이지 끝 개행까지 사라진 `"a"` 가 아니다(결함 10). **caret 은 다음 줄의 같은 열로 간다, 문서
/// 끝이면 줄 끝**(결함 7).
pub fn planDelete(allocator: std.mem.Allocator, content: []const u8, lines: LineIndex, sels: []const Selection) !?Plan {
    var nums: std.ArrayList(usize) = .empty;
    defer nums.deinit(allocator);
    if (!try selectedLineNumbers(allocator, content, lines, sels, &nums)) return null;

    const Block = struct { lo: usize, hi: usize, start: usize, end: usize, eat_prev: bool };
    var blocks: std.ArrayList(Block) = .empty;
    defer blocks.deinit(allocator);
    var plan: Plan = .{};
    errdefer plan.deinit(allocator);
    var runs: Runs = .{ .nums = nums.items };
    while (runs.next()) |r| {
        const first = lines.line(r.lo) orelse continue;
        const last = lines.line(r.hi) orelse continue;
        var start = first.start;
        const end = @min(last.end_with_ending, content.len);
        const eat_prev = last.end_with_ending == last.contentEnd() and start > 0;
        if (eat_prev) start -= 1;
        try blocks.append(allocator, .{ .lo = r.lo, .hi = r.hi, .start = start, .end = end, .eat_prev = eat_prev });
        try plan.changes.append(allocator, .{ .start = start, .end = end, .text = "" });
    }
    if (plan.changes.items.len == 0) {
        plan.deinit(allocator);
        return null;
    }

    const after = try allocator.dupe(Selection, sels);
    plan.after = after;
    for (after) |*sel| {
        const ln = lines.lineAt(@min(sel.start(), content.len));
        var removed: usize = 0;
        for (blocks.items) |b| {
            defer removed += b.end - b.start;
            if (ln < b.lo or ln > b.hi) continue;
            const next = if (b.eat_prev) null else lines.line(b.hi + 1);
            const target = if (next) |nl| blk: {
                const focus = @min(sel.focus, content.len);
                const cur = lines.line(lines.lineAt(focus)) orelse break :blk nl.start;
                const col = if (lines.lineAt(focus) > b.hi) 0 else lineColumn(content, cur.start, focus);
                break :blk offsetAtColumn(content, nl.start, nl.contentEnd(), col);
            } else b.end; // 앞 개행을 먹었다 — 앞 줄 끝(지운 범위의 시작)으로 접힌다
            sel.* = Selection.at(target - removed - (b.end - b.start));
            break;
        }
    }
    return plan;
}

/// 걸친 줄들을 **아래에** 복사한다(§3.9a). **선택은 복사본으로 옮긴다**(VSCode 관례) — 원본에 두면 다시 눌렀을 때
/// 같은 줄이 또 복제되어 원본만 늘어난다.
///
/// 블록 k 의 커서는 앞 블록들의 사본만큼과 **자기 사본 하나만큼** 간다. 사본 전부의 합을 더하면 첫 블록부터
/// 어긋나고 마지막 블록은 문서 끝을 넘었다(결함 1). **앞에 넣어 미는 방법은 안 된다** — 선택이 삽입 지점에서 시작하면
/// anchor 는 제자리고 focus 만 밀려 두 사본을 통째로 덮는다(실측: 두 번째 복제가 네 벌을 만들었다).
pub fn planDuplicate(allocator: std.mem.Allocator, content: []const u8, lines: LineIndex, sels: []const Selection) !?Plan {
    var nums: std.ArrayList(usize) = .empty;
    defer nums.deinit(allocator);
    if (!try selectedLineNumbers(allocator, content, lines, sels, &nums)) return null;

    const Block = struct { lo: usize, hi: usize, copy_len: usize };
    var blocks: std.ArrayList(Block) = .empty;
    defer blocks.deinit(allocator);
    var plan: Plan = .{};
    errdefer plan.deinit(allocator);
    // **연속한 줄은 한 덩어리로 복사한다.** 줄마다 따로 넣으면 A B 가 A A B B 가 되어 블록이 깨진다.
    var runs: Runs = .{ .nums = nums.items };
    while (runs.next()) |r| {
        const first = lines.line(r.lo) orelse continue;
        const last = lines.line(r.hi) orelse continue;
        const block = content[first.start..@min(last.end_with_ending, content.len)];
        const t = if (block.len > 0 and block[block.len - 1] == '\n')
            try allocator.dupe(u8, block)
        else
            try std.fmt.allocPrint(allocator, "\n{s}", .{block});
        try plan.own(allocator, t);
        const at = @min(last.end_with_ending, content.len);
        try plan.changes.append(allocator, .{ .start = at, .end = at, .text = t });
        try blocks.append(allocator, .{ .lo = r.lo, .hi = r.hi, .copy_len = t.len });
    }
    if (plan.changes.items.len == 0) {
        plan.deinit(allocator);
        return null;
    }

    const after = try allocator.dupe(Selection, sels);
    plan.after = after;
    for (after) |*sel| {
        const ln = lines.lineAt(@min(sel.start(), content.len));
        var add: usize = 0;
        for (blocks.items) |b| {
            add += b.copy_len;
            if (ln >= b.lo and ln <= b.hi) break;
        }
        sel.* = shiftSelection(sel.*, @intCast(add));
    }
    return plan;
}

/// 걸친 블록을 위/아래 줄과 **통째로 맞바꾼다**(§3.9a). **문서 처음/끝에서는 무동작이다**(`null` — clamp 해서 절반만
/// 움직이면 사용자는 무슨 일이 났는지 못 읽는다). **연속하지 않은 줄 무리는 각자 옮긴다.** 옮긴 블록의 커서는 블록과
/// 함께 간다(결함 6).
pub fn planMove(allocator: std.mem.Allocator, content: []const u8, lines: LineIndex, sels: []const Selection, down: bool) !?Plan {
    var nums: std.ArrayList(usize) = .empty;
    defer nums.deinit(allocator);
    if (!try selectedLineNumbers(allocator, content, lines, sels, &nums)) return null;

    const Moved = struct { lo: usize, hi: usize, by: i64 };
    var moved: std.ArrayList(Moved) = .empty;
    defer moved.deinit(allocator);
    var plan: Plan = .{};
    errdefer plan.deinit(allocator);
    var runs: Runs = .{ .nums = nums.items };
    while (runs.next()) |r| {
        const lo = r.lo;
        const hi = r.hi;
        // **경계에서는 그 무리만 건너뛴다** — 다른 무리는 여전히 움직여야 한다.
        if (!down and lo == 0) continue;
        if (down and hi + 1 >= lines.lineCount()) continue;
        // **문서 끝 개행이 만드는 빈 줄은 이동 대상이 아니다.** 그것과 맞바꾸면 `"c\n"` → `"\nc"` 가 되어 빈 줄이
        // 생기고 끝 개행이 사라진다(적대적 검증 LN4 가 실측했다).
        if (down and (lines.line(hi + 1) orelse continue).start >= content.len) continue;
        const swap_n = if (down) hi + 1 else lo - 1;
        const blk_first = lines.line(lo) orelse continue;
        const blk_last = lines.line(hi) orelse continue;
        const other = lines.line(swap_n) orelse continue;

        const blk = content[blk_first.start..@min(blk_last.end_with_ending, content.len)];
        const oth = content[other.start..@min(other.end_with_ending, content.len)];
        // **개행이 없는 마지막 줄이 섞이면 개행을 손으로 맞춘다** — 그대로 이으면 두 줄이 붙는다.
        const blk_nl = blk.len > 0 and blk[blk.len - 1] == '\n';
        const oth_nl = oth.len > 0 and oth[oth.len - 1] == '\n';
        const blk_body = if (blk_nl) blk[0 .. blk.len - 1] else blk;
        const oth_body = if (oth_nl) oth[0 .. oth.len - 1] else oth;
        const region_start = if (down) blk_first.start else other.start;
        const region_end = if (down) @min(other.end_with_ending, content.len) else @min(blk_last.end_with_ending, content.len);
        const trailing_nl = blk_nl and oth_nl;
        const first_body = if (down) oth_body else blk_body;
        const second_body = if (down) blk_body else oth_body;
        const t = if (trailing_nl)
            try std.fmt.allocPrint(allocator, "{s}\n{s}\n", .{ first_body, second_body })
        else
            try std.fmt.allocPrint(allocator, "{s}\n{s}", .{ first_body, second_body });
        try plan.own(allocator, t);
        try plan.changes.append(allocator, .{ .start = region_start, .end = region_end, .text = t });
        const step: i64 = @intCast(oth_body.len + 1);
        try moved.append(allocator, .{ .lo = lo, .hi = hi, .by = if (down) step else -step });
    }
    if (plan.changes.items.len == 0) {
        plan.deinit(allocator);
        return null;
    }

    const after = try allocator.dupe(Selection, sels);
    plan.after = after;
    for (after) |*sel| {
        const ln = lines.lineAt(@min(sel.start(), content.len));
        for (moved.items) |m| {
            if (ln >= m.lo and ln <= m.hi) {
                sel.* = shiftSelection(sel.*, m.by);
                break;
            }
        }
    }
    return plan;
}

/// 걸친 줄들의 머리를 한 단계 넣거나 뺀다(§3.9a). **들여쓰기는 탭 문자 하나다** — `Tab` 키가 넣는 것과 같아야 한다.
/// **빈 줄은 건드리지 않는다.** **내어쓰기는 있는 만큼만** 뺀다: 탭 하나, 없으면 공백을 최대 `tab_width` 개. 없는 줄이
/// 섞여도 연산 전체가 실패하지 않는다. caret 은 매핑이 맞다(줄 머리에서만 바뀐다 — LNM8).
pub fn planIndent(allocator: std.mem.Allocator, content: []const u8, lines: LineIndex, sels: []const Selection, outdent: bool, tab_width: usize) !?Plan {
    var nums: std.ArrayList(usize) = .empty;
    defer nums.deinit(allocator);
    if (!try selectedLineNumbers(allocator, content, lines, sels, &nums)) return null;

    const width: usize = @max(1, tab_width);
    var plan: Plan = .{};
    errdefer plan.deinit(allocator);
    for (nums.items) |n| {
        const line = lines.line(n) orelse continue;
        const text = content[line.start..line.contentEnd()];
        if (outdent) {
            if (text.len == 0) continue;
            var take: usize = 0;
            if (text[0] == '\t') {
                take = 1;
            } else {
                while (take < text.len and take < width and text[take] == ' ') take += 1;
            }
            if (take == 0) continue; // 뺄 것이 없다 — 이 줄만 건너뛴다
            try plan.changes.append(allocator, .{ .start = line.start, .end = line.start + take, .text = "" });
        } else {
            if (std.mem.trimStart(u8, text, " \t").len == 0) continue; // 빈 줄
            try plan.changes.append(allocator, .{ .start = line.start, .end = line.start, .text = "\t" });
        }
    }
    if (plan.changes.items.len == 0) {
        plan.deinit(allocator);
        return null;
    }
    return plan;
}

/// **주석 토글**(§3.7) — 걸친 줄 전체를 한 번에 뒤집는다. **하나라도 주석이 아니면 전부 주석**(VSCode 관례). 섞여
/// 있을 때 「전부 해제」로 가면 주석이던 줄이 코드가 되어 의도하지 않은 실행이 생긴다. **빈 줄은 판단에서도 표식에서도
/// 뺀다.** 표식은 **들여쓰기 뒤**에 넣는다. `marker` 는 언어의 줄 주석(`language.lineComment`) — 모르는 언어는 호출자가
/// 이미 막는다.
pub fn planToggleComment(allocator: std.mem.Allocator, content: []const u8, lines: LineIndex, sels: []const Selection, marker: []const u8) !?Plan {
    var nums: std.ArrayList(usize) = .empty;
    defer nums.deinit(allocator);
    if (!try selectedLineNumbers(allocator, content, lines, sels, &nums)) return null;

    var all_commented = true;
    var any_content = false;
    for (nums.items) |n| {
        const line = lines.line(n) orelse continue;
        const trimmed = std.mem.trimStart(u8, content[line.start..line.contentEnd()], " \t");
        if (trimmed.len == 0) continue; // 빈 줄
        any_content = true;
        if (!std.mem.startsWith(u8, trimmed, marker)) all_commented = false;
    }
    if (!any_content) return null; // 빈 줄만 골랐다 — 넣을 자리가 없다

    var plan: Plan = .{};
    errdefer plan.deinit(allocator);
    for (nums.items) |n| {
        const line = lines.line(n) orelse continue;
        const text = content[line.start..line.contentEnd()];
        const indent = text.len - std.mem.trimStart(u8, text, " \t").len;
        if (indent == text.len) continue; // 빈 줄은 건드리지 않는다
        const at = line.start + indent;
        if (all_commented) {
            // **해제** — 표식과 그 뒤 공백 하나까지 지운다(넣을 때 붙인 그 공백이다).
            var end = at + marker.len;
            if (end < content.len and content[end] == ' ') end += 1;
            try plan.changes.append(allocator, .{ .start = at, .end = end, .text = "" });
        } else {
            const t = try std.fmt.allocPrint(allocator, "{s} ", .{marker});
            try plan.own(allocator, t);
            try plan.changes.append(allocator, .{ .start = at, .end = at, .text = t });
        }
    }
    if (plan.changes.items.len == 0) {
        plan.deinit(allocator);
        return null;
    }
    return plan;
}

/// Enter — 개행을 넣고 **이전 줄의 들여쓰기를 잇는다**(§3.9a). 앞 공백을 글자 그대로 잇고, **caret 앞까지만** 보고,
/// **커서마다 자기 줄을 본다**. 들여쓸 것이 하나도 없으면 `null` — 호출자는 종전 경로(`insertText("\n")`)로 간다(같은
/// 결과를 두 자리에서 만들지 않는다).
///
/// **문서 순서로 쌓는다**(입력 `sels` 가 문서 순서다) — primary 먼저 순서로 쌓으면 primary 가 뒤일 때 거꾸로 쌓여
/// `delta` 가 거절했다(결함 3). **caret 은 새 줄의 들여쓰기 뒤로 간다**(결함 8).
pub fn planNewline(allocator: std.mem.Allocator, content: []const u8, lines: LineIndex, sels: []const Selection) !?Plan {
    if (sels.len == 0) return null;
    var plan: Plan = .{};
    errdefer plan.deinit(allocator);
    const after = try allocator.dupe(Selection, sels);
    plan.after = after;
    var grown: i64 = 0;
    var any_indent = false;
    for (after) |*sel| {
        const s_off = @min(sel.start(), content.len);
        const e_off = @min(sel.end(), content.len);
        const line = lines.line(lines.lineAt(s_off)) orelse {
            plan.deinit(allocator);
            return null;
        };
        const head = content[line.start..s_off];
        const indent = head[0 .. head.len - std.mem.trimStart(u8, head, " \t").len];
        if (indent.len > 0) any_indent = true;
        const t = try std.fmt.allocPrint(allocator, "\n{s}", .{indent});
        try plan.own(allocator, t);
        try plan.changes.append(allocator, .{ .start = s_off, .end = e_off, .text = t });
        sel.* = Selection.at(@intCast(@as(i64, @intCast(s_off + t.len)) + grown));
        grown += @as(i64, @intCast(t.len)) - @as(i64, @intCast(e_off - s_off));
    }
    if (!any_indent) {
        plan.deinit(allocator);
        return null;
    }
    return plan;
}

/// 선택(없으면 caret 의 낱말)을 대문자/소문자로 바꾼다(§3.9b). **낱말 규칙은 `selection.wordRangeAt`**, **대소문자 축은
/// `terminal/selection` 의 `upperCase`·`foldCase`**(찾기의 대소문자 무시 비교와 같은 표). **길이가 안 변한다** — 그래서
/// 다른 커서가 안 밀리고 caret 은 매핑이 맞다. 바뀐 것이 없으면 `null`.
///
/// **문서 순서다**(입력이 문서 순서) — primary 먼저 순서로 쌓아 `apply` 가 거절하던 CS7 의 함정을 다시 안 밟는다.
pub fn planTransformCase(allocator: std.mem.Allocator, content: []const u8, sels: []const Selection, upper: bool) !?Plan {
    var plan: Plan = .{};
    errdefer plan.deinit(allocator);
    for (sels) |sel| {
        var lo = @min(sel.start(), content.len);
        var hi = @min(sel.end(), content.len);
        if (hi == lo) {
            const w = selection.wordRangeAt(content, lo);
            lo = w.lo;
            hi = w.hi;
        }
        const src = content[lo..hi];
        const buf = try allocator.alloc(u8, src.len);
        try plan.own(allocator, buf);
        var w_i: usize = 0;
        // 문서는 열릴 때 UTF-8 이 검증된다 — 디코드 실패는 그 자리를 안 건드리는 안전한 저하다(§3.8).
        var view = std.unicode.Utf8View.init(src) catch continue;
        var cps = view.iterator();
        while (cps.nextCodepoint()) |cp| {
            const out = if (upper) case.upperCase(cp) else case.foldCase(cp);
            w_i += std.unicode.utf8Encode(out, buf[w_i..]) catch continue;
        }
        if (std.mem.eql(u8, buf, src)) continue; // 바뀐 것이 없다 — 빈 delta 를 만들지 않는다
        try plan.changes.append(allocator, .{ .start = lo, .end = hi, .text = buf });
    }
    if (plan.changes.items.len == 0) {
        plan.deinit(allocator);
        return null;
    }
    return plan;
}

// ── 순수 test — 결함의 재현 조건(native-editor 결함 표)을 L4 없이 잰다 ─────────────────────────────

const testing = std.testing;

fn applyPlan(allocator: std.mem.Allocator, content: []const u8, plan: Plan) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var at: usize = 0;
    for (plan.changes.items) |c| {
        try testing.expect(c.start >= at); // 문서 순서·비겹침(`delta` 의 불변식)
        try out.appendSlice(allocator, content[at..c.start]);
        try out.appendSlice(allocator, c.text);
        at = c.end;
    }
    try out.appendSlice(allocator, content[at..]);
    return out.toOwnedSlice(allocator);
}

fn run(comptime op: enum { delete, duplicate, move_down, newline }, content: []const u8, sels: []const Selection) !struct { text: []u8, after: []Selection } {
    const allocator = testing.allocator;
    var lines = try line_index.build(allocator, content);
    defer lines.deinit();
    var plan = (switch (op) {
        .delete => try planDelete(allocator, content, lines, sels),
        .duplicate => try planDuplicate(allocator, content, lines, sels),
        .move_down => try planMove(allocator, content, lines, sels, true),
        .newline => try planNewline(allocator, content, lines, sels),
    }) orelse return error.NoPlan;
    defer plan.deinit(allocator);
    const text = try applyPlan(allocator, content, plan);
    errdefer allocator.free(text);
    const after = try allocator.dupe(Selection, plan.after.?);
    return .{ .text = text, .after = after };
}

test "결함 1 — 떨어진 블록마다 caret 이 자기 사본으로 간다" {
    const r = try run(.duplicate, "aa\nbb\ncc\ndd\n", &.{ Selection.at(0), Selection.at(6) });
    defer testing.allocator.free(r.text);
    defer testing.allocator.free(r.after);
    try testing.expectEqualStrings("aa\naa\nbb\ncc\ncc\ndd\n", r.text);
    try testing.expectEqual(@as(usize, 3), r.after[0].focus);
    try testing.expectEqual(@as(usize, 12), r.after[1].focus);
}

test "결함 2·10 — 마지막 내용 줄을 앞 줄과 함께 지우고, 개행이 있는 마지막 줄은 자기 개행까지만" {
    const r = try run(.delete, "a\nb\nc", &.{Selection.fromPoints(2, 5)});
    defer testing.allocator.free(r.text);
    defer testing.allocator.free(r.after);
    try testing.expectEqualStrings("a", r.text);
    const r2 = try run(.delete, "a\nb\n", &.{Selection.at(2)});
    defer testing.allocator.free(r2.text);
    defer testing.allocator.free(r2.after);
    try testing.expectEqualStrings("a\n", r2.text);
}

test "결함 7 — 지운 뒤 caret 은 다음 줄의 같은 열(글자 수)" {
    const r = try run(.delete, "abc\ndef\nghi\n", &.{Selection.at(2)});
    defer testing.allocator.free(r.text);
    defer testing.allocator.free(r.after);
    try testing.expectEqualStrings("def\nghi\n", r.text);
    try testing.expectEqual(@as(usize, 2), r.after[0].focus);
    // 한글 줄 — byte 가 아니라 글자로 센다(3 byte 글자 가운데로 안 떨어진다).
    const k = try run(.delete, "가나다\n라마바\n", &.{Selection.at(3)}); // "가|나다"
    defer testing.allocator.free(k.text);
    defer testing.allocator.free(k.after);
    try testing.expectEqual(@as(usize, 3), k.after[0].focus); // "라|마바"
}

test "결함 3·8 — primary 가 뒤인 다중 커서 Enter 도 문서 순서이고, caret 은 들여쓰기 뒤" {
    // 입력은 문서 순서다(호출자 `selectionsForEdit`). primary 의 위치는 이 함수와 무관하다.
    const r = try run(.newline, "\tab\n\tcd\n", &.{ Selection.at(2), Selection.at(6) });
    defer testing.allocator.free(r.text);
    defer testing.allocator.free(r.after);
    try testing.expectEqualStrings("\ta\n\tb\n\tc\n\td\n", r.text);
    try testing.expectEqual(@as(usize, 4), r.after[0].focus); // "\t|b"
    try testing.expectEqual(@as(usize, 10), r.after[1].focus); // "\t|d"
}

test "결함 6 — 옮긴 블록을 caret 이 따라간다" {
    const r = try run(.move_down, "ab\ncd\nef\n", &.{Selection.at(1)});
    defer testing.allocator.free(r.text);
    defer testing.allocator.free(r.after);
    try testing.expectEqualStrings("cd\nab\nef\n", r.text);
    try testing.expectEqual(@as(usize, 4), r.after[0].focus);
}

test "들여쓸 것이 없으면 Enter 는 종전 경로다(null)" {
    const allocator = testing.allocator;
    var lines = try line_index.build(allocator, "ab\n");
    defer lines.deinit();
    try testing.expect((try planNewline(allocator, "ab\n", lines, &.{Selection.at(1)})) == null);
}

test "주석 토글 — 하나라도 주석이 아니면 전부 주석, 빈 줄은 건너뛴다" {
    const allocator = testing.allocator;
    const content = "a\n\n// b\n";
    var lines = try line_index.build(allocator, content);
    defer lines.deinit();
    var plan = (try planToggleComment(allocator, content, lines, &.{Selection.fromPoints(0, 7)}, "//")).?;
    defer plan.deinit(allocator);
    const out = try applyPlan(allocator, content, plan);
    defer allocator.free(out);
    try testing.expectEqualStrings("// a\n\n// // b\n", out);
}

test "대소문자 — 선택이 없으면 caret 의 낱말, 문서 순서로 낸다" {
    const allocator = testing.allocator;
    var plan = (try planTransformCase(allocator, "ab cd", &.{ Selection.at(1), Selection.at(4) }, true)).?;
    defer plan.deinit(allocator);
    const out = try applyPlan(allocator, "ab cd", plan);
    defer allocator.free(out);
    try testing.expectEqualStrings("AB CD", out);
}
