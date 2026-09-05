//! 구문 스팬(**문서 바이트 축**) → 줄별 색 구간(**표시 열 축**).
//!
//! **왜 chrome 인가.** 이 계산이 쓰는 것은 전부 이 층의 것이다 — `content.ColorSpan`,
//! `tokens.ColorRole`, 그리고 열 계산 둘(`lineColumnsUpTo`·`columnsAtOffsets`). 문법 파서도
//! 캡처 이름도 여기 안 온다: **역할이 이미 정해진 채로** 들어온다.
//!
//! **캡처 이름 → 역할은 여기가 아니다.** 그 표는 `session.syntax_capture` 가 소유하고 chrome 은
//! 그 모듈을 **import 하지 않는다**(`tokens.ColorRole` 의 doc 이 그 경계를 적어 뒀다). 둘을 잇는
//! 자리는 위쪽 잎이다 — `maru.syntax_colors`(`chrome_theme`·`scm_items` 와 같은 모양).
//!
//! **`platform/macos/app_session/editor_syntax.zig` 에서 옮겨 왔다**(§2m.112). 그 파일에 있는 동안
//! 이 규칙은 macOS 것이었고, Windows 가 색을 칠하려면 **같은 규칙을 다시 적어야** 했다 — 「마지막
//! 캡처가 이긴다」와 탭 열 계산의 주인이 둘이 되는 자리다.

const std = @import("std");
const chrome = @import("../../../chrome.zig");
const content = @import("content.zig");
const tokens = chrome.tokens;

/// 한 줄에서 색을 계산하는 열 상한. 그 너머는 무색이다 — 가로로 무한히 긴 줄에 예산을 안 쓴다.
pub const max_color_cols: usize = 16 * 1024;

/// 문서 바이트 축의 색 스팬. **`role` 이 이미 정해져 있다**(위 doc).
pub const ByteSpan = struct {
    start: u32,
    end: u32,
    role: tokens.ColorRole,
};

/// 한 줄의 **내용** 범위 `[start, end)`. 줄바꿈 바이트는 안 든다.
///
/// **호출자가 줄바꿈 종류를 아는 채로 준다** — CRLF 문서에서 `end` 를 한 바이트 늦게 잡으면 그
/// 줄의 마지막 열이 통째로 밀린다. `session.editor.line_index` 의 `Line.start`·`contentEnd()` 가
/// 그 답을 이미 갖고 있다.
pub const LineBounds = struct { start: u32, end: u32 };

/// 프레임마다 다시 채우되 저장소는 재사용한다.
pub const Scratch = struct {
    /// 줄별 색 구간이 실리는 평평한 저장소.
    flat: std.ArrayList(content.ColorSpan) = .empty,
    /// 렌더 축으로 색인되는 슬라이스 배열 — `frame.Props.line_colors` 가 그대로 받는다.
    per_line: std.ArrayList([]const content.ColorSpan) = .empty,
    /// 열별 역할 임시 버퍼(마지막이 이긴다).
    col_roles: std.ArrayList(?tokens.ColorRole) = .empty,
    /// 정렬·중복 제거한 **줄 안 byte offset**(오름차순 — `columnsAtOffsets` 의 계약).
    offs: std.ArrayList(u32) = .empty,
    /// 위 offset 들의 **열**. 둘을 따로 두는 이유는 `columnsAtOffsets` 가 제자리로 덮어써서
    /// 한 배열로는 byte 를 잃기 때문이다.
    cols: std.ArrayList(u32) = .empty,
    /// `flat` 안의 (시작, 끝). 슬라이스를 **나중에 굳히기** 위해서다.
    bounds: std.ArrayList([2]usize) = .empty,
    /// `per_line[0..empty_upto]` 이 **이미 무색**이라는 기억. 창 앞의 빈 줄을 프레임마다 다시 쓰지
    /// 않기 위한 것이다 — 다시 쓰면 깊이 스크롤한 큰 파일에서 프레임마다 O(first_line) 을 문다
    /// (실측: `first_line = 200_000` 에서 프레임당 5.6 ms, Debug). 여기 아래는 손대지 않았으므로
    /// 여전히 `&.{}` 이고, 그 위는 **매번 다시 채운다**(옛 프레임의 매달린 슬라이스가 있을 수 있다).
    empty_upto: usize = 0,

    pub fn deinit(self: *Scratch, allocator: std.mem.Allocator) void {
        self.flat.deinit(allocator);
        self.per_line.deinit(allocator);
        self.col_roles.deinit(allocator);
        self.offs.deinit(allocator);
        self.cols.deinit(allocator);
        self.bounds.deinit(allocator);
        self.* = .{};
    }
};

/// `lines` 창의 줄마다 색 구간을 만든다.
///
/// **`spans` 는 문서 순서여야 한다** — 아래 `si` 가 앞으로만 훑는다. tree-sitter 질의가 그 순서로
/// 낸다(그 계약이 깨지면 뒤 줄의 색이 통째로 빈다).
///
/// **`leading_empty` 는 창 앞에 붙일 빈 줄 수다.** 렌더 축이 0 부터 시작하는데 창이 중간부터일 때
/// 그 앞을 무색으로 채운다 — 짧은 배열도 허용되므로(그 자리 `frame.zig` 계약) 창 뒤는 안 채운다.
pub fn lineColors(
    self: *Scratch,
    allocator: std.mem.Allocator,
    doc: []const u8,
    lines: []const LineBounds,
    spans: []const ByteSpan,
    tab_width: u16,
    leading_empty: usize,
) []const []const content.ColorSpan {
    self.flat.clearRetainingCapacity();
    self.bounds.clearRetainingCapacity();
    if (lines.len == 0 or spans.len == 0) return &.{};

    self.bounds.ensureTotalCapacity(allocator, lines.len) catch return &.{};

    var si: usize = 0; // spans 를 앞으로만 훑는다
    for (lines) |ln| {
        const lo: usize = ln.start;
        const hi: usize = @min(@as(usize, ln.end), doc.len);
        const start_flat = self.flat.items.len;
        if (hi > lo) {
            while (si < spans.len and spans[si].end <= lo) si += 1;
            var sj = si;
            while (sj < spans.len and spans[sj].start < hi) sj += 1;
            if (sj > si) appendLine(self, allocator, doc[lo..hi], spans[si..sj], lo, tab_width);
        }
        self.bounds.appendAssumeCapacity(.{ start_flat, self.flat.items.len });
    }

    // **슬라이스를 나중에 굳힌다.** `flat` 이 자라면 재할당되므로 도는 중에 뜬 슬라이스는 매달린다.
    const total = leading_empty + self.bounds.items.len;
    self.per_line.ensureTotalCapacity(allocator, total) catch return &.{};
    const prev_len = self.per_line.items.len;
    self.per_line.items.len = total;

    // 창 앞. `empty_upto` 아래는 그대로 두고, 그 위만 무색으로 덮는다 — 그 구간에는 지난 프레임이
    // 쓴 슬라이스나(용량이 자랐다면) 초기화되지 않은 값이 있다.
    if (leading_empty > self.empty_upto) {
        @memset(self.per_line.items[self.empty_upto..leading_empty], &.{});
    }
    std.debug.assert(self.empty_upto <= prev_len or prev_len == 0);
    self.empty_upto = leading_empty;

    for (self.bounds.items, self.per_line.items[leading_empty..]) |b, *slot| {
        slot.* = self.flat.items[b[0]..b[1]];
    }
    return self.per_line.items;
}

/// 한 줄의 색 구간을 `flat` 에 붙인다. **마지막 스팬이 이긴다.**
///
/// tree-sitter 는 한 범위에 캡처를 여럿 낸다(`x` 하나에 넷이 붙는 것을 실측했다 — predicate 를
/// 평가하지 않는 탓이다). 어느 것이 이길지 규칙이 필요하고 **뒤엣것**을 고른다 — Neovim·Helix 가
/// 같은 관례이고, `.scm` 이 더 좁은 패턴을 뒤에 적는 편이라 그쪽이 더 구체적이다.
fn appendLine(
    self: *Scratch,
    allocator: std.mem.Allocator,
    line_bytes: []const u8,
    spans: []const ByteSpan,
    line_start: usize,
    tab_width: u16,
) void {
    const width = content.lineColumnsUpTo(line_bytes, tab_width, @intCast(max_color_cols));
    if (width == 0) return;
    const w: usize = @min(width, max_color_cols);

    self.col_roles.resize(allocator, w) catch return;
    @memset(self.col_roles.items, null);

    // **`columnsAtOffsets` 는 오름차순 입력을 요구한다.** span 을 그냥 `[start, end]` 짝으로
    // 늘어놓으면 그 계약이 깨진다 — tree-sitter 가 **같은 범위에 캡처를 여럿** 내므로
    // `[6,7, 6,7, 6,7]` 같은 배열이 나온다. 그래서 **정렬·중복 제거한 유일 offset** 을 만들어 한 번
    // 훑고, span 마다 그 표에서 찾는다. 줄 하나의 offset 수는 수십이라 정렬 비용이 문제되지 않는다.
    self.offs.clearRetainingCapacity();
    self.offs.ensureTotalCapacity(allocator, spans.len * 2) catch return;
    for (spans) |sp| {
        self.offs.appendAssumeCapacity(relStart(sp, line_start, line_bytes.len));
        self.offs.appendAssumeCapacity(relEnd(sp, line_start, line_bytes.len));
    }
    std.mem.sort(u32, self.offs.items, {}, std.sort.asc(u32));
    var uniq: usize = 0;
    for (self.offs.items) |v| {
        if (uniq == 0 or self.offs.items[uniq - 1] != v) {
            self.offs.items[uniq] = v;
            uniq += 1;
        }
    }
    self.offs.shrinkRetainingCapacity(uniq);
    self.cols.resize(allocator, uniq) catch return;
    content.columnsAtOffsets(line_bytes, tab_width, self.offs.items, self.cols.items, @intCast(w));

    for (spans) |sp| {
        const sb = relStart(sp, line_start, line_bytes.len);
        const eb = relEnd(sp, line_start, line_bytes.len);
        if (eb <= sb) continue;
        const c0: usize = self.cols.items[lowerBound(self.offs.items, sb)];
        const c1: usize = self.cols.items[lowerBound(self.offs.items, eb)];
        var col: usize = c0;
        while (col < @min(c1, w)) : (col += 1) self.col_roles.items[col] = sp.role;
    }

    // 같은 역할이 이어지는 구간을 하나로 묶는다 — run 이 적을수록 렌더가 싸다.
    var col: usize = 0;
    while (col < w) {
        const role = self.col_roles.items[col] orelse {
            col += 1;
            continue;
        };
        var end = col + 1;
        while (end < w and self.col_roles.items[end] == role) end += 1;
        self.flat.append(allocator, .{
            .start_col = @intCast(col),
            .end_col = @intCast(end),
            .role = role,
        }) catch return;
        col = end;
    }
}

/// span 의 **줄 안** 시작·끝 byte. 줄을 벗어난 부분은 줄 경계로 자른다(여러 줄 토큰이 그렇다).
fn relStart(sp: ByteSpan, line_start: usize, line_len: usize) u32 {
    const s = @max(@as(usize, sp.start), line_start) - line_start;
    return @intCast(@min(s, line_len));
}
fn relEnd(sp: ByteSpan, line_start: usize, line_len: usize) u32 {
    return @intCast(@min(@as(usize, sp.end) -| line_start, line_len));
}

/// `v` 이상인 첫 자리. `offs` 는 오름차순이고 `v` 는 반드시 그 안에 있다(같은 식으로 만들었다).
fn lowerBound(offs: []const u32, v: u32) usize {
    var lo: usize = 0;
    var hi: usize = offs.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (offs[mid] < v) lo = mid + 1 else hi = mid;
    }
    return @min(lo, offs.len - 1);
}

test "겹친 스팬은 뒤엣것이 이긴다" {
    const a = std.testing.allocator;
    var s: Scratch = .{};
    defer s.deinit(a);

    const doc = "const x = 1;";
    const lines = [_]LineBounds{.{ .start = 0, .end = @intCast(doc.len) }};
    // 같은 범위에 둘 — tree-sitter 가 실제로 그렇게 낸다.
    const spans = [_]ByteSpan{
        .{ .start = 6, .end = 7, .role = .syntax_property },
        .{ .start = 6, .end = 7, .role = .syntax_type_name },
    };
    const out = lineColors(&s, a, doc, &lines, &spans, 4, 0);
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqual(@as(usize, 1), out[0].len);
    try std.testing.expectEqual(tokens.ColorRole.syntax_type_name, out[0][0].role);
    try std.testing.expectEqual(@as(u32, 6), out[0][0].start_col);
    try std.testing.expectEqual(@as(u32, 7), out[0][0].end_col);
}

test "CRLF 문서에서 줄 경계는 호출자가 준 것을 그대로 쓴다" {
    const a = std.testing.allocator;
    var s: Scratch = .{};
    defer s.deinit(a);

    // `ab\r\ncd` — 둘째 줄 내용은 [4, 6) 이다. `\r` 을 안 세면 한 칸씩 밀린다.
    const doc = "ab\r\ncd";
    const lines = [_]LineBounds{
        .{ .start = 0, .end = 2 },
        .{ .start = 4, .end = 6 },
    };
    const spans = [_]ByteSpan{.{ .start = 4, .end = 6, .role = .syntax_string }};
    const out = lineColors(&s, a, doc, &lines, &spans, 4, 0);
    try std.testing.expectEqual(@as(usize, 2), out.len);
    try std.testing.expectEqual(@as(usize, 0), out[0].len); // 첫 줄은 무색
    try std.testing.expectEqual(@as(usize, 1), out[1].len);
    try std.testing.expectEqual(@as(u32, 0), out[1][0].start_col);
    try std.testing.expectEqual(@as(u32, 2), out[1][0].end_col);
}

test "탭은 열을 늘린다 — 바이트가 아니라 표시 열로 칠한다" {
    const a = std.testing.allocator;
    var s: Scratch = .{};
    defer s.deinit(a);

    // `\tab` — 탭 폭 4 면 `a` 는 열 4 에서 시작한다.
    const doc = "\tab";
    const lines = [_]LineBounds{.{ .start = 0, .end = 3 }};
    const spans = [_]ByteSpan{.{ .start = 1, .end = 3, .role = .syntax_keyword }};
    const out = lineColors(&s, a, doc, &lines, &spans, 4, 0);
    try std.testing.expectEqual(@as(usize, 1), out[0].len);
    try std.testing.expectEqual(@as(u32, 4), out[0][0].start_col);
    try std.testing.expectEqual(@as(u32, 6), out[0][0].end_col);
}

test "창 앞의 빈 줄과 여러 줄에 걸친 토큰" {
    const a = std.testing.allocator;
    var s: Scratch = .{};
    defer s.deinit(a);

    const doc = "aa\nbb\ncc";
    // 창은 둘째 줄부터 — 앞에 하나를 무색으로 채운다.
    const lines = [_]LineBounds{
        .{ .start = 3, .end = 5 },
        .{ .start = 6, .end = 8 },
    };
    // 둘째~셋째 줄에 걸친 토큰(주석·문자열이 그렇다).
    const spans = [_]ByteSpan{.{ .start = 3, .end = 8, .role = .syntax_comment }};
    const out = lineColors(&s, a, doc, &lines, &spans, 4, 1);
    try std.testing.expectEqual(@as(usize, 3), out.len);
    try std.testing.expectEqual(@as(usize, 0), out[0].len); // leading_empty
    try std.testing.expectEqual(@as(u32, 2), out[1][0].end_col);
    try std.testing.expectEqual(@as(u32, 2), out[2][0].end_col);
}

test "창 앞의 빈 줄을 다시 안 채워도 지난 프레임의 색이 안 남는다" {
    // `empty_upto` 최적화의 위험한 자리다: 창이 **아래로** 가면 지난 프레임이 색을 쓴 칸이
    // 이번 프레임에는 «창 앞» 이 된다. 그 칸을 안 덮으면 옛 색이(그것도 매달린 슬라이스로) 남는다.
    const a = std.testing.allocator;
    var sc: Scratch = .{};
    defer sc.deinit(a);
    const doc = "const x = 1;\n";
    const bounds = [_]LineBounds{.{ .start = 0, .end = 12 }};
    const spans = [_]ByteSpan{.{ .start = 0, .end = 5, .role = .syntax_keyword }};

    const first = lineColors(&sc, a, doc, &bounds, &spans, 4, 3);
    try std.testing.expectEqual(@as(usize, 4), first.len);
    try std.testing.expect(first[3].len > 0);

    // 창이 두 줄 내려간다. 이제 3·4 는 창 앞이고 **무색이어야 한다**.
    const second = lineColors(&sc, a, doc, &bounds, &spans, 4, 5);
    try std.testing.expectEqual(@as(usize, 6), second.len);
    try std.testing.expectEqual(@as(usize, 0), second[3].len);
    try std.testing.expectEqual(@as(usize, 0), second[4].len);
    try std.testing.expect(second[5].len > 0);

    // 다시 위로. 아래로 갈 때 채워 둔 칸이 그대로 무색이어야 한다(여기가 기억을 쓰는 자리다).
    const third = lineColors(&sc, a, doc, &bounds, &spans, 4, 1);
    try std.testing.expectEqual(@as(usize, 2), third.len);
    try std.testing.expectEqual(@as(usize, 0), third[0].len);
    try std.testing.expect(third[1].len > 0);
}
