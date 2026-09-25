//! 공백 표시 — 한 줄에서 **어느 공백·탭에 기호를 세울지**([시각 매핑](../../../../docs/native-editor-visual-mapping.md) §5.1e).
//!
//! 규칙은 VS Code `viewLineRenderer.ts` 의 `_applyRenderWhitespace` 그대로다: 공백(0x20)·탭(0x09)만 대상이고, 줄의 첫 비공백 앞과 마지막 비공백
//! 뒤는 모두 공백, 그 사이의 탭도 늘 공백, 사이의 공백은 모드가 가른다(`boundary` 는 홀로 선 한 칸을 뺀다). `selection` 은 선택 범위 안만,
//! `trailing` 은 뒤 공백만(공백뿐인 줄이면 줄 전체). 그리기(글리프·색·열)는 호출자(`frame.paintWhitespace`)의 일이다.
const std = @import("std");

/// VS Code `editor.renderWhitespace`.
pub const Mode = enum { none, boundary, selection, trailing, all };

/// 줄 안 byte 범위 `[start, end)`.
pub const Range = struct { start: u32, end: u32 };

/// VS Code 의 **view line 하나**. 랩이면 그 랩 행(`continues` — 다음 행으로 이어진다), 아니면 줄 전체(`whole_line`).
///
/// VS Code 는 랩된 행마다 그 행의 글만 보고 판정한다(monaco `viewLineRenderer.js` — `renderViewLine` 이 `trailing` 을 이어지는 행에서 아예
/// 안 부르고, `_applyRenderWhitespace` 끝에서 `boundary` 는 이어지는 행 끝의 홀로 선 공백 하나를 뺀다). 앞뒤 공백의 경계도 행마다다.
pub const Segment = struct { range: Range, continues: bool = false };

/// 줄 전체 — 랩이 없을 때(가로로 민 창도 줄 하나다). 끝은 `collect` 가 줄 길이로 자른다.
pub const whole_line: Segment = .{ .range = .{ .start = 0, .end = std.math.maxInt(u32) } };

/// `line` 의 조각 `segment` 에서, byte 창 `window` 안에 기호를 세울 글자의 byte 자리(줄 기준)를 `out` 에 오름차순으로 쓰고 그 수를 돌려준다
/// (넘치면 앞에서부터 담은 만큼). `selections` 는 그 줄의 선택 범위(줄 기준 · 오름차순 · 겹치지 않음) — `selection` 모드에서만 읽는다.
///
/// **창은 화면에 보이는 몫이다**(랩 행이면 조각과 같고, 가로로 민 창이면 줄의 일부). 줄 처음부터 담으면 공백이 `out` 보다 많은 긴 줄에서
/// 뒤쪽이 빈다(WSF3). `boundary` 가 보는 「앞 글자가 기호였나」는 창 앞 공백 덩이의 첫 자리(조각 안)에서 다시 걷는다 — 덩이 앞 글자는
/// 비공백이거나 조각의 시작이라 그 답이 늘 「아니다」여서, 거기서 시작하면 조각 처음부터 걸은 것과 같다.
pub fn collect(line: []const u8, mode: Mode, selections: []const Range, segment: Segment, window: Range, out: []align(1) u32) usize {
    if (mode == .none) return 0;
    if (mode == .selection and selections.len == 0) return 0;
    if (mode == .trailing and segment.continues) return 0; // 이어지는 랩 행에는 뒤 공백이 없다
    const seg_end: usize = @min(segment.range.end, line.len);
    const seg_start: usize = @min(segment.range.start, seg_end);
    const seg = line[seg_start..seg_end];
    const first = firstNonWhitespace(seg);
    const all_ws = first == null;
    const first_i: usize = seg_start + (first orelse seg.len);
    const last_i: usize = if (all_ws) seg_end else seg_start + lastNonWhitespace(seg);
    // 이어지는 랩 행 끝의 홀로 선 공백 하나 — `boundary` 는 안 세운다(없으면 `seg_end`, 어느 자리와도 안 겹친다).
    const lone_tail: usize = if (mode == .boundary and segment.continues and seg.len > 0 and seg[seg.len - 1] == ' ' and
        (seg.len < 2 or !isWs(seg[seg.len - 2]))) seg_end - 1 else seg_end;
    const end: usize = @min(window.end, seg_end);
    var start: usize = @min(@max(window.start, seg_start), end);
    while (start > seg_start and isWs(line[start - 1])) start -= 1;
    var n: usize = 0;
    var was = false;
    var si: usize = 0;
    for (line[start..end], start..) |ch, i| {
        while (si < selections.len and selections[si].end <= i) si += 1;
        var is_ws: bool = undefined;
        if (i < first_i or i > last_i) {
            is_ws = true; // 앞뒤 공백 — 그 자리에는 공백·탭만 있다
        } else if (ch == '\t') {
            is_ws = true;
        } else if (ch == ' ') {
            if (mode == .boundary) {
                // 홀로 선 한 칸은 뺀다 — 앞이 공백이었거나 다음(조각 안)이 공백·탭일 때만. (`i + 1 < seg_end` 를 `line.len` 으로 바꿔도 같다 —
                // 등가 변이(적대적 1회차 N05): 이 갈래의 공백은 마지막 비공백보다 앞이라 `i + 1 <= last_i < seg_end` 다. 뜻으로 둔다.)
                is_ws = was or (i + 1 < seg_end and isWs(line[i + 1]));
            } else is_ws = true;
        } else is_ws = false;
        if (is_ws and mode == .selection) is_ws = si < selections.len and selections[si].start <= i and i < selections[si].end;
        if (is_ws and mode == .trailing) is_ws = all_ws or i > last_i;
        was = is_ws;
        if (is_ws and i >= window.start and i != lone_tail) {
            if (n == out.len) break;
            out[n] = @intCast(i);
            n += 1;
        }
    }
    return n;
}

fn isWs(ch: u8) bool {
    return ch == ' ' or ch == '\t';
}

/// 첫 비공백(공백·탭이 아닌) 글자의 자리 — 없으면 null(빈 줄 · 공백뿐인 줄).
fn firstNonWhitespace(line: []const u8) ?usize {
    for (line, 0..) |ch, i| if (ch != ' ' and ch != '\t') return i;
    return null;
}

/// 마지막 비공백 글자의 자리(있다고 안 뒤에 부른다).
fn lastNonWhitespace(line: []const u8) usize {
    var i = line.len;
    while (i > 0) {
        i -= 1;
        if (line[i] != ' ' and line[i] != '\t') return i;
    }
    return 0;
}

// ── 판정자 ────────────────────────────────────────────────────────────────────

const testing = std.testing;
/// 창을 안 좁힌다 — 줄 끝은 `collect` 가 자른다.
const all_line: Range = .{ .start = 0, .end = std.math.maxInt(u32) };

test "WSR1 모드 다섯 — 앞뒤 공백 · 사이의 탭 · 홀로 선 공백 · 선택 · 뒤 공백 · 랩 행 (§5.1e, VS Code _applyRenderWhitespace)" {
    var buf: [32]u32 = undefined;
    const line = "  a b  c\t d  ";
    const W = whole_line;
    // all — 공백·탭 전부
    try testing.expectEqualSlices(u32, &.{ 0, 1, 3, 5, 6, 8, 9, 11, 12 }, buf[0..collect(line, .all, &.{}, W, all_line, &buf)]);
    // boundary — 사이의 홀로 선 공백(3)만 빠진다; 탭(8)과 그 뒤 공백(9 — 앞이 공백이었다)은 선다
    try testing.expectEqualSlices(u32, &.{ 0, 1, 5, 6, 8, 9, 11, 12 }, buf[0..collect(line, .boundary, &.{}, W, all_line, &buf)]);
    // trailing — 뒤 공백만
    try testing.expectEqualSlices(u32, &.{ 11, 12 }, buf[0..collect(line, .trailing, &.{}, W, all_line, &buf)]);
    // selection — [2, 7) 안만; 선택이 없으면(커서만) 없다
    try testing.expectEqualSlices(u32, &.{ 3, 5, 6 }, buf[0..collect(line, .selection, &.{.{ .start = 2, .end = 7 }}, W, all_line, &buf)]);
    try testing.expectEqual(@as(usize, 0), collect(line, .selection, &.{}, W, all_line, &buf));
    // **맞닿은 선택** [2, 5) · [5, 7) — 앞 선택의 끝(5)에서 다음 선택으로 넘어간다(monaco `endExclusive <= charIndex`)
    try testing.expectEqualSlices(u32, &.{ 3, 5, 6 }, buf[0..collect(line, .selection, &.{ .{ .start = 2, .end = 5 }, .{ .start = 5, .end = 7 } }, W, all_line, &buf)]);
    // 공백뿐인 줄 — trailing 이면 줄 전체
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, buf[0..collect(" \t ", .trailing, &.{}, W, all_line, &buf)]);
    // NBSP 는 공백이 아니다(글자다)
    try testing.expectEqual(@as(usize, 0), collect("a\u{a0}b", .all, &.{}, W, all_line, &buf));
    try testing.expectEqual(@as(usize, 0), collect("x", .none, &.{}, W, all_line, &buf));
    // **랩 행** — 조각 [4, 10) = "b  c\t " 가 다음 행으로 이어진다.
    const seg: Segment = .{ .range = .{ .start = 4, .end = 10 }, .continues = true };
    // trailing — 이어지는 행에는 없다(끝 행이면 마지막 비공백 `c`(7) 뒤의 탭·공백이 선다)
    try testing.expectEqual(@as(usize, 0), collect(line, .trailing, &.{}, seg, all_line, &buf));
    try testing.expectEqualSlices(u32, &.{ 8, 9 }, buf[0..collect(line, .trailing, &.{}, .{ .range = seg.range }, all_line, &buf)]);
    // boundary — 끝 공백(9)은 앞이 탭이라 홀로 선 게 아니다 → 선다; 조각 [2, 4) = "a " 의 끝 공백(3)은 홀로 섰다 → 빠진다
    try testing.expectEqualSlices(u32, &.{ 5, 6, 8, 9 }, buf[0..collect(line, .boundary, &.{}, seg, all_line, &buf)]);
    try testing.expectEqual(@as(usize, 0), collect(line, .boundary, &.{}, .{ .range = .{ .start = 2, .end = 4 }, .continues = true }, all_line, &buf));
    // 같은 조각이 끝 행이면 뒤 공백으로 선다
    try testing.expectEqualSlices(u32, &.{3}, buf[0..collect(line, .boundary, &.{}, .{ .range = .{ .start = 2, .end = 4 } }, all_line, &buf)]);
    // 앞뒤 경계는 조각마다다 — 조각 [5, 8) = "  c" 의 앞 공백은 boundary 에서 선다(줄 전체로는 사이의 공백이지만 둘이라 어차피 선다), 조각
    // [3, 5) = " b" 의 앞 공백 하나는 **앞 공백이라** 선다(줄 전체로는 홀로 선 사이의 공백이라 빠진다)
    try testing.expectEqualSlices(u32, &.{3}, buf[0..collect(line, .boundary, &.{}, .{ .range = .{ .start = 3, .end = 5 } }, all_line, &buf)]);
}

test "WSR2 VS Code 와 대조 — monaco 0.56 renderViewLine2 가 낸 줄 80 × 랩 행 여부 둘 × 모드 다섯(기호 1,702)과 같다 (§5.1e)" {
    // 무작위 줄(공백·탭·NBSP·글자) · 무작위 선택 0~2 개(맞닿기도 한다)를 monaco 의 실제 줄 렌더러로 그려 HTML 에서 `·`·`→`(폭 한 칸 탭은
    // 반각 U+FFEB)가 선 원문 자리를 뽑았다. `c` 는 `continuesWithWrappedLine`(이어지는 랩 행). scratchpad `monaco/ws_oracle2.mjs` — 5,000 판
    // 전체, HTML 흐름 어긋남 0. 자리는 JS 의 UTF-16 색인이라 byte 로 옮겨 맞춘다.
    const a = testing.allocator;
    const C = struct { l: []const u8, m: []const u8, s: []const [2]u32, k: []const u32, c: bool = false };
    const Doc = struct { source: []const u8, cases: []const C };
    const parsed = try std.json.parseFromSlice(Doc, a, @embedFile("testdata/whitespace_monaco.json"), .{});
    defer parsed.deinit();
    var total: usize = 0;
    var total_cont: usize = 0;
    for (parsed.value.cases) |c| {
        errdefer std.debug.print("WSR2 mode={s} continues={} line=\"{s}\"\n", .{ c.m, c.c, c.l });
        // UTF-16 색인 → byte 자리
        var u16_to_byte: [128]u32 = undefined;
        var u: usize = 0;
        var i: usize = 0;
        while (i < c.l.len) {
            const cp_len = std.unicode.utf8ByteSequenceLength(c.l[i]) catch 1;
            u16_to_byte[u] = @intCast(i);
            u += 1;
            i += cp_len;
        }
        u16_to_byte[u] = @intCast(c.l.len);
        var sels: [4]Range = undefined;
        for (c.s, 0..) |r, k| sels[k] = .{ .start = u16_to_byte[r[0]], .end = u16_to_byte[r[1]] };
        const mode = std.meta.stringToEnum(Mode, c.m) orelse return error.BadMode;
        const seg: Segment = .{ .range = whole_line.range, .continues = c.c };
        var buf: [64]u32 = undefined;
        const got = buf[0..collect(c.l, mode, sels[0..c.s.len], seg, all_line, &buf)];
        var want: [64]u32 = undefined;
        for (c.k, 0..) |k, j| want[j] = u16_to_byte[k];
        try testing.expectEqualSlices(u32, want[0..c.k.len], got);
        total += got.len;
        if (c.c) total_cont += got.len;
        // **창을 좁혀도 같은 자리다** — 모든 [s, e) 에서 줄 전체의 답 중 창 안의 것과 같다(창 앞 공백 덩이에서 다시 걷는 규칙을 잰다).
        for (0..c.l.len + 1) |s| for (s..c.l.len + 1) |e| {
            var part: [64]u32 = undefined;
            const pn = collect(c.l, mode, sels[0..c.s.len], seg, .{ .start = @intCast(s), .end = @intCast(e) }, &part);
            var wn: usize = 0;
            for (got) |k| {
                if (k < s or k >= e) continue;
                want[wn] = k;
                wn += 1;
            }
            try testing.expectEqualSlices(u32, want[0..wn], part[0..pn]);
        };
        // **조각 [s, e) 는 그 부분 문자열을 한 줄로 본 것과 같다**(VS Code 의 랩 행은 그 행의 글이 곧 lineContent 다) — 선택은 조각으로 잘라 옮긴다.
        for (0..c.l.len + 1) |s| for (s..c.l.len + 1) |e| {
            var sub_sels: [4]Range = undefined;
            var sn: usize = 0;
            for (sels[0..c.s.len]) |r| {
                const lo = @max(r.start, s);
                const hi = @min(r.end, e);
                if (hi <= lo) continue;
                sub_sels[sn] = .{ .start = @intCast(lo - s), .end = @intCast(hi - s) };
                sn += 1;
            }
            var part: [64]u32 = undefined;
            const pn = collect(c.l, mode, sels[0..c.s.len], .{ .range = .{ .start = @intCast(s), .end = @intCast(e) }, .continues = c.c }, all_line, &part);
            var sub: [64]u32 = undefined;
            const sub_n = collect(c.l[s..e], mode, sub_sels[0..sn], .{ .range = whole_line.range, .continues = c.c }, all_line, &sub);
            for (sub[0..sub_n]) |*k| k.* += @intCast(s);
            try testing.expectEqualSlices(u32, sub[0..sub_n], part[0..pn]);
        };
    }
    try testing.expectEqual(@as(usize, 1702), total);
    try testing.expectEqual(@as(usize, 810), total_cont);
}
