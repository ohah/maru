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

/// `line` 의 byte 창 `window` 안에서 기호를 세울 글자의 byte 자리를 `out` 에 오름차순으로 쓰고 그 수를 돌려준다(넘치면 앞에서부터 담은 만큼).
/// `selections` 는 그 줄의 선택 범위(오름차순 · 겹치지 않음) — `selection` 모드에서만 읽는다.
///
/// **창은 조각(랩 행 · 가로로 민 창)이다.** 줄 처음부터 담으면 공백이 `out` 보다 많은 긴 줄에서 뒤쪽 조각이 빈다(WSF3). 앞뒤 공백의 경계는 줄
/// 전체로 재고, `boundary` 가 보는 「앞 글자가 기호였나」는 창 앞 공백 덩이의 첫 자리에서 다시 걷는다 — 덩이 앞 글자는 비공백이라 그 답이
/// 늘 「아니다」여서 거기서 시작하면 줄 처음부터 걸은 것과 같다.
pub fn collect(line: []const u8, mode: Mode, selections: []const Range, window: Range, out: []align(1) u32) usize {
    if (mode == .none) return 0;
    if (mode == .selection and selections.len == 0) return 0;
    const first = firstNonWhitespace(line);
    const all_ws = first == null;
    const first_i: usize = first orelse line.len;
    const last_i: usize = if (all_ws) line.len else lastNonWhitespace(line);
    const end: usize = @min(window.end, line.len);
    var start: usize = @min(window.start, end);
    while (start > 0 and (line[start - 1] == ' ' or line[start - 1] == '\t')) start -= 1;
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
                // 홀로 선 한 칸은 뺀다 — 앞이 공백이었거나 다음이 공백·탭일 때만
                is_ws = was or (i + 1 < line.len and (line[i + 1] == ' ' or line[i + 1] == '\t'));
            } else is_ws = true;
        } else is_ws = false;
        if (is_ws and mode == .selection) is_ws = si < selections.len and selections[si].start <= i and i < selections[si].end;
        if (is_ws and mode == .trailing) is_ws = all_ws or i > last_i;
        if (is_ws and i >= window.start) {
            if (n == out.len) break;
            out[n] = @intCast(i);
            n += 1;
        }
        was = is_ws;
    }
    return n;
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

test "WSR1 모드 다섯 — 앞뒤 공백 · 사이의 탭 · 홀로 선 공백 · 선택 · 뒤 공백 (§5.1e, VS Code _applyRenderWhitespace)" {
    var buf: [32]u32 = undefined;
    const line = "  a b  c\t d  ";
    // all — 공백·탭 전부
    try testing.expectEqualSlices(u32, &.{ 0, 1, 3, 5, 6, 8, 9, 11, 12 }, buf[0..collect(line, .all, &.{}, all_line, &buf)]);
    // boundary — 사이의 홀로 선 공백(3)만 빠진다; 탭(8)과 그 뒤 공백(9 — 앞이 공백이었다)은 선다
    try testing.expectEqualSlices(u32, &.{ 0, 1, 5, 6, 8, 9, 11, 12 }, buf[0..collect(line, .boundary, &.{}, all_line, &buf)]);
    // trailing — 뒤 공백만
    try testing.expectEqualSlices(u32, &.{ 11, 12 }, buf[0..collect(line, .trailing, &.{}, all_line, &buf)]);
    // selection — [2, 7) 안만; 선택이 없으면(커서만) 없다
    try testing.expectEqualSlices(u32, &.{ 3, 5, 6 }, buf[0..collect(line, .selection, &.{.{ .start = 2, .end = 7 }}, all_line, &buf)]);
    try testing.expectEqual(@as(usize, 0), collect(line, .selection, &.{}, all_line, &buf));
    // 공백뿐인 줄 — trailing 이면 줄 전체
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, buf[0..collect(" \t ", .trailing, &.{}, all_line, &buf)]);
    // NBSP 는 공백이 아니다(글자다)
    try testing.expectEqual(@as(usize, 0), collect("a\u{a0}b", .all, &.{}, all_line, &buf));
    try testing.expectEqual(@as(usize, 0), collect("x", .none, &.{}, all_line, &buf));
}

test "WSR2 VS Code 와 대조 — monaco 0.56 renderViewLine2 가 낸 줄 80 × 모드 다섯(기호 871)과 같다 (§5.1e)" {
    // 무작위 줄(공백·탭·NBSP·글자) · 무작위 선택 0~2 개를 monaco 의 실제 줄 렌더러로 그려 HTML 에서 `·`·`→`(폭 한 칸 탭은 반각 U+FFEB)가 선 원문
    // 자리를 뽑았다(scratchpad `monaco/ws_oracle.mjs` — 2,500 판 전체, HTML 흐름 어긋남 0). 자리는 JS 의 UTF-16 색인이라 byte 로 옮겨 맞춘다.
    const a = testing.allocator;
    const C = struct { l: []const u8, m: []const u8, s: []const [2]u32, k: []const u32 };
    const Doc = struct { source: []const u8, cases: []const C };
    const parsed = try std.json.parseFromSlice(Doc, a, @embedFile("testdata/whitespace_monaco.json"), .{});
    defer parsed.deinit();
    var total: usize = 0;
    for (parsed.value.cases) |c| {
        errdefer std.debug.print("WSR2 mode={s} line=\"{s}\"\n", .{ c.m, c.l });
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
        var buf: [64]u32 = undefined;
        const got = buf[0..collect(c.l, mode, sels[0..c.s.len], all_line, &buf)];
        var want: [64]u32 = undefined;
        for (c.k, 0..) |k, j| want[j] = u16_to_byte[k];
        try testing.expectEqualSlices(u32, want[0..c.k.len], got);
        total += got.len;
        // **창을 좁혀도 같은 자리다** — 모든 [s, e) 에서 줄 전체의 답 중 창 안의 것과 같다(창 앞 공백 덩이에서 다시 걷는 규칙을 잰다).
        for (0..c.l.len + 1) |s| for (s..c.l.len + 1) |e| {
            var part: [64]u32 = undefined;
            const pn = collect(c.l, mode, sels[0..c.s.len], .{ .start = @intCast(s), .end = @intCast(e) }, &part);
            var wn: usize = 0;
            for (got) |k| {
                if (k < s or k >= e) continue;
                want[wn] = k;
                wn += 1;
            }
            try testing.expectEqualSlices(u32, want[0..wn], part[0..pn]);
        };
    }
    try testing.expectEqual(@as(usize, 871), total);
}
