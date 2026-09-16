//! 미니맵(§6 · §6.1 N5a) — 문서의 «모양»을 본문 오른쪽 스트립에 색 블록 quad 로 그린다.
//!
//! **글리프를 안 그린다.** 줄 하나가 `line_px`(2px)라 글자가 설 수 없다 — 줄마다 공백 아닌 글자의
//! **run** 을 quad 하나로 내고, 색은 그 run 첫 글자의 구문 역할이다(VS Code `scale = 1`: 글자 높이 2px·
//! 폭 1px 그대로).
//!
//! **문서 크기와 무관하다.** 스트립은 `[top, top + strip_rows)` 만 그린다(비례 스크롤 — §6.1). 그래서
//! 프레임 비용은 스트립 행 수에 비례하고, §3.0 이 미니맵을 축소 1 단으로 둔 전제(전 문서 스팬 요구)는
//! 이 배치에서 사라졌다.
//!
//! 이 파일은 순수 컴포넌트다 — 세션·문서 모델을 모르고, 받은 줄 배열과 색 표만 읽는다.
const std = @import("std");
const draw = @import("../../draw.zig");
const tokens = @import("../../tokens.zig");
const content = @import("content.zig");

/// 줄 하나의 높이(px). VS Code `minimap.scale = 1` 의 글자 높이.
pub const line_px: u32 = 2;
/// 글자 하나의 폭(px).
pub const char_px: u32 = 1;
/// 미니맵을 두고도 본문에 남아야 하는 최소 열 수. 이보다 좁아지면 미니맵이 **접힌다**(0 px) — 좁은 분할에서
/// 본문보다 미니맵이 넓은 화면은 뜻이 없다(병합 세 열이 좁으면 Result 만 남는 규칙과 같은 자리).
pub const min_content_cols: u32 = 40;
/// 역할이 없는 run 의 알파(본문 전경을 옅게) — 구문 색이 없는 문서(`.txt`)도 모양은 보여야 한다.
pub const plain_alpha: u8 = 0x60;
/// 슬라이더(보이는 구간)의 알파. 선택 띠(`selection_alpha` 45%)보다 옅어야 그 아래 run 이 읽힌다.
pub const slider_alpha: u8 = 0x38;
/// 검색 일치 행의 알파(§6.2) — run 위에 얹되 run 색이 비친다.
pub const mark_alpha: u8 = 0x80;

/// 스트립의 폭(px). **한 자리에서 정한다** — 렌더·히트 기하·보이는 열 수·clamp 가 전부 이 값을 지나야
/// 「그려진 것 = 클릭되는 것」이 구조로 지켜진다(§6.1).
///
/// `cols == 0`(설정으로 껐다)이면 0. 미니맵을 두면 본문이 `min_content_cols` 보다 좁아질 때도 0(접힘).
pub fn widthPx(inner_w: u32, cell_w_px: u16, scrollbar_gutter_px: u32, minimap_cols: u16) u32 {
    // `minimap_cols == 0` 가드는 **등가**다(19회차 S5): `want` 가 0 이라 아래 어느 갈래도 0 을 낸다. 남기는 이유는 뜻 —
    // 「껐다」는 계산이 아니라 결정이다.
    if (minimap_cols == 0 or cell_w_px == 0) return 0;
    const want: u32 = @as(u32, minimap_cols) * cell_w_px;
    const body_w = inner_w -| scrollbar_gutter_px;
    if (body_w < want) return 0;
    const content_cols = (body_w - want) / cell_w_px;
    if (content_cols < min_content_cols) return 0;
    return want;
}

/// 스트립의 첫 줄 — **비례 스크롤**(VS Code `minimap.size = proportional`). 문서가 스트립에 다 들어가면 0.
/// `max_top_line` 은 본문 스크롤 상한(그 줄이 맨 위에 오면 마지막 화면) — 본문이 그 끝에 서면 스트립도 끝에 선다.
pub fn topLine(first_line: usize, total_lines: usize, strip_rows: usize, max_top_line: usize) usize {
    if (total_lines <= strip_rows or strip_rows == 0) return 0;
    const span = total_lines - strip_rows; // 스트립이 갈 수 있는 거리
    if (max_top_line == 0) return 0;
    // `first_line` 의 clamp 는 **등가**다(적대적 10·15회차 J2): 상한을 넘는 first_line 도 마지막 `@min(scaled, span)` 이
    // 잡는다. 남겨 두는 이유는 뜻 — 비례의 분자는 「상한 안의 위치」다.
    const f = @min(first_line, max_top_line);
    // u128 로 곱한다 — 줄 수 × 줄 수는 u64 로도 넉넉하지만 뜻을 적어 둔다: 비례식이다.
    const scaled: u128 = @as(u128, f) * @as(u128, span) / @as(u128, max_top_line);
    return @intCast(@min(scaled, span));
}

/// 스트립이 담을 수 있는 줄 수.
pub fn stripRows(height_px: u32) usize {
    return height_px / line_px;
}

/// 스트립의 y(px) → 문서 줄. 스트립 밖이면 마지막/첫 줄로 묶는다.
pub fn lineAtY(top: usize, rel_y_px: i64, total_lines: usize) usize {
    if (total_lines == 0) return 0;
    const row: usize = if (rel_y_px <= 0) 0 else @intCast(@as(u64, @intCast(rel_y_px)) / line_px);
    return @min(top + row, total_lines - 1);
}

pub const Props = struct {
    /// 스트립 사각(px). `w` 는 `widthPx` 의 값.
    rect: draw.Rect,
    /// 문서 전체 줄. 스트립은 `[top, top + rows)` 만 읽는다.
    lines: []const []const u8,
    /// 스트립 창의 색 — **`top` 기준 상대 첨자**(`window_colors[i]` 는 `lines[top + i]` 의 것). 짧은 배열을
    /// 허용한다(없는 줄은 무색 run).
    window_colors: []const []const content.ColorSpan = &.{},
    /// 스트립 첫 줄(`topLine`).
    top: usize,
    /// 슬라이더 — 본문이 보고 있는 구간 `[first, first + len)`.
    slider_first: usize,
    slider_len: usize,
    tab_width: u8,
    /// **검색 일치가 있는 줄**(§6.2) — `lines` 와 같은 축(절대 줄). 창 밖은 안 그린다. 행 전체를 칠한다.
    mark_lines: []const u32 = &.{},
    /// `mark_lines` 안에서 현재 일치의 인덱스 — 그 행만 `search_match_current`.
    mark_current: ?usize = null,
};

pub const Written = struct { ops: usize, truncated: bool };

/// 스트립을 그린다. 반환 = 쓴 op 수. 저장소가 모자라면 거기서 멈춘다(잘릴 뿐 죽지 않는다 — 이 컴포넌트 계열의 규율).
pub fn build(props: Props, out: []draw.Op) Written {
    var n: usize = 0;
    if (props.rect.w == 0 or props.rect.h == 0) return .{ .ops = 0, .truncated = false };
    const rows = stripRows(props.rect.h);
    const max_cols: u32 = props.rect.w / char_px;
    var truncated = false;

    var i: usize = 0;
    outer: while (i < rows and props.top + i < props.lines.len) : (i += 1) {
        const line = props.lines[props.top + i];
        const colors: []const content.ColorSpan = if (i < props.window_colors.len) props.window_colors[i] else &.{};
        const y = props.rect.y + @as(i32, @intCast(i * line_px));
        var byte: usize = 0;
        var col: u32 = 0;
        var run_start: ?u32 = null;
        var run_role: ?tokens.ColorRole = null;
        // 폭에서 멈춘다 — 그 뒤는 안 그려지므로 걷지 않는다(`runQuad` 의 clamp 와 겹친 방어라 이 조건만 지운 변이는 화면이
        // 같다, 적대적 1회차 A4. 남기는 이유는 비용이다 — 5 만 열 줄에서 스트립 120 글자만 걷는다).
        while (byte < line.len and col < max_cols) {
            const step = content.stepColumn(line, byte, col, props.tab_width);
            const blank = line[byte] == ' ' or line[byte] == '\t' or line[byte] == '\r';
            if (!blank and run_start == null) {
                run_start = col;
                run_role = roleAt(colors, col);
            } else if (blank and run_start != null) {
                if (n >= out.len) {
                    truncated = true;
                    break :outer;
                }
                out[n] = runQuad(props.rect.x, y, run_start.?, col, max_cols, run_role);
                n += 1;
                run_start = null;
            }
            byte = step.next_byte;
            col = step.next_col;
        }
        if (run_start) |s| {
            if (n >= out.len) {
                truncated = true;
                break;
            }
            out[n] = runQuad(props.rect.x, y, s, @min(col, max_cols), max_cols, run_role);
            n += 1;
        }
    }

    // 검색 일치 행 — run 위·슬라이더 아래(§6.2). 창 `[top, top + rows)` 안의 줄만, 행 전체 폭으로.
    for (props.mark_lines, 0..) |line, mi| {
        if (line < props.top or line >= props.top + rows) continue;
        if (n >= out.len) {
            truncated = true;
            break;
        }
        const is_current = props.mark_current != null and props.mark_current.? == mi;
        out[n] = .{ .quad = .{
            .rect = .{
                .x = props.rect.x,
                .y = props.rect.y + @as(i32, @intCast((line - props.top) * line_px)),
                .w = props.rect.w,
                .h = line_px,
            },
            .fill_role = if (is_current) .search_match_current else .search_match,
            .alpha = mark_alpha,
        } };
        n += 1;
    }

    // 슬라이더 — 스트립 안의 보이는 구간. 스트립 밖(비례 스크롤로 밀린 구간)은 잘라 그린다.
    if (props.slider_len > 0 and n < out.len) {
        const first = props.slider_first;
        const last = first + props.slider_len; // 반열림
        const win_first = props.top;
        const win_last = props.top + rows;
        const a = @max(first, win_first);
        const b = @min(last, win_last);
        if (b > a) {
            out[n] = .{ .quad = .{
                .rect = .{
                    .x = props.rect.x,
                    .y = props.rect.y + @as(i32, @intCast((a - props.top) * line_px)),
                    .w = props.rect.w,
                    .h = @intCast((b - a) * line_px),
                },
                .fill_role = .selection,
                .alpha = slider_alpha,
            } };
            n += 1;
        }
    } else if (props.slider_len > 0) truncated = true;
    return .{ .ops = n, .truncated = truncated };
}

fn roleAt(colors: []const content.ColorSpan, col: u32) ?tokens.ColorRole {
    // 스팬은 오름차순이고 겹치지 않는다(`content.Row.colors` 의 계약) — 첫 글자가 든 스팬 하나만 찾는다.
    for (colors) |sp| {
        if (col < sp.start_col) return null;
        if (col < sp.end_col) return sp.role;
    }
    return null;
}

fn runQuad(x0: i32, y: i32, from: u32, to: u32, max_cols: u32, role: ?tokens.ColorRole) draw.Op {
    const end = @min(to, max_cols);
    return .{ .quad = .{
        .rect = .{ .x = x0 + @as(i32, @intCast(from * char_px)), .y = y, .w = (end - from) * char_px, .h = line_px },
        .fill_role = role orelse .surface_fg,
        .alpha = if (role != null) 0xFF else plain_alpha,
    } };
}

// ── 판정자 ──────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "MM1 공백 아닌 run 마다 quad 하나 — 자리·폭·줄 높이" {
    var ops: [16]draw.Op = undefined;
    const lines = [_][]const u8{ "ab  cd", "", "   x" };
    const w = build(.{ .rect = .{ .x = 100, .y = 10, .w = 40, .h = 8 }, .lines = &lines, .top = 0, .slider_first = 0, .slider_len = 0, .tab_width = 4 }, &ops);
    try testing.expectEqual(@as(usize, 3), w.ops);
    try testing.expect(!w.truncated);
    // "ab" → x 100, w 2 · "cd" → x 104, w 2 · 셋째 줄 "x" → x 103, y 10 + 2·2
    try testing.expectEqual(@as(i32, 100), ops[0].quad.rect.x);
    try testing.expectEqual(@as(u32, 2), ops[0].quad.rect.w);
    try testing.expectEqual(@as(u32, line_px), ops[0].quad.rect.h);
    try testing.expectEqual(@as(i32, 104), ops[1].quad.rect.x);
    try testing.expectEqual(@as(i32, 103), ops[2].quad.rect.x);
    try testing.expectEqual(@as(i32, 14), ops[2].quad.rect.y);
    // 역할이 없으면 본문 전경을 옅게
    try testing.expectEqual(tokens.ColorRole.surface_fg, ops[0].quad.fill_role);
    try testing.expectEqual(plain_alpha, ops[0].quad.alpha);
}

test "MM2 run 의 색은 첫 글자의 구문 역할 — 스팬 밖 run 은 무색, 탭은 탭 폭으로 전개" {
    var ops: [16]draw.Op = undefined;
    const lines = [_][]const u8{"\tconst x = 1;"};
    // `const` 가 4..9 열(탭 폭 4) — 키워드.
    const spans = [_]content.ColorSpan{.{ .start_col = 4, .end_col = 9, .role = .syntax_keyword }};
    const colors = [_][]const content.ColorSpan{&spans};
    const w = build(.{ .rect = .{ .x = 0, .y = 0, .w = 40, .h = 4 }, .lines = &lines, .window_colors = &colors, .top = 0, .slider_first = 0, .slider_len = 0, .tab_width = 4 }, &ops);
    // "const" · "x" · "=" · "1;" → 4 run
    try testing.expectEqual(@as(usize, 4), w.ops);
    try testing.expectEqual(@as(i32, 4), ops[0].quad.rect.x); // 탭이 4 열을 먹었다
    try testing.expectEqual(tokens.ColorRole.syntax_keyword, ops[0].quad.fill_role);
    try testing.expectEqual(@as(u8, 0xFF), ops[0].quad.alpha);
    try testing.expectEqual(tokens.ColorRole.surface_fg, ops[1].quad.fill_role);
    // **첫 글자**의 역할이다 — 스팬이 run 의 첫 글자만 덮으면 그 색, 둘째 글자만 덮으면 무색(1회차 A2: 둘째 글자를 읽는
    // 변이가 위 픽스처에서는 같은 스팬 안이라 살았다).
    const head_only = [_]content.ColorSpan{.{ .start_col = 0, .end_col = 1, .role = .syntax_string }};
    const tail_only = [_]content.ColorSpan{.{ .start_col = 1, .end_col = 2, .role = .syntax_string }};
    const two = [_][]const u8{"ab"};
    const c1 = [_][]const content.ColorSpan{&head_only};
    _ = build(.{ .rect = .{ .x = 0, .y = 0, .w = 40, .h = 4 }, .lines = &two, .window_colors = &c1, .top = 0, .slider_first = 0, .slider_len = 0, .tab_width = 4 }, &ops);
    try testing.expectEqual(tokens.ColorRole.syntax_string, ops[0].quad.fill_role);
    const c2 = [_][]const content.ColorSpan{&tail_only};
    _ = build(.{ .rect = .{ .x = 0, .y = 0, .w = 40, .h = 4 }, .lines = &two, .window_colors = &c2, .top = 0, .slider_first = 0, .slider_len = 0, .tab_width = 4 }, &ops);
    try testing.expectEqual(tokens.ColorRole.surface_fg, ops[0].quad.fill_role);
}

test "MM3 스트립 폭을 넘는 글자는 잘리고, 스트립 행 수를 넘는 줄은 안 그린다" {
    var ops: [16]draw.Op = undefined;
    const long = "x" ** 60;
    const lines = [_][]const u8{ long, "a", "b", "c" };
    // 폭 10px = 10 글자, 높이 4px = 2 줄
    const w = build(.{ .rect = .{ .x = 0, .y = 0, .w = 10, .h = 4 }, .lines = &lines, .top = 0, .slider_first = 0, .slider_len = 0, .tab_width = 4 }, &ops);
    try testing.expectEqual(@as(usize, 2), w.ops);
    try testing.expectEqual(@as(u32, 10), ops[0].quad.rect.w);
}

test "MM4 슬라이더는 보이는 구간을 스트립 창 안에서 잘라 그린다 — 창 밖은 없다" {
    var ops: [16]draw.Op = undefined;
    const lines = [_][]const u8{ "a", "b", "c", "d", "e", "f" };
    // 창 = [2, 5) (top 2, 높이 6px = 3 줄). 보이는 구간 [0, 4) → 겹침 [2, 4) → y 0, h 4.
    const w = build(.{ .rect = .{ .x = 0, .y = 0, .w = 8, .h = 6 }, .lines = &lines, .top = 2, .slider_first = 0, .slider_len = 4, .tab_width = 4 }, &ops);
    try testing.expectEqual(@as(usize, 4), w.ops); // run 3 + 슬라이더 1
    const s = ops[3].quad;
    try testing.expectEqual(tokens.ColorRole.selection, s.fill_role);
    try testing.expectEqual(@as(i32, 0), s.rect.y);
    try testing.expectEqual(@as(u32, 4), s.rect.h);
    try testing.expectEqual(@as(u32, 8), s.rect.w);
    // 구간이 창 밖이면 슬라이더가 없다
    const w2 = build(.{ .rect = .{ .x = 0, .y = 0, .w = 8, .h = 6 }, .lines = &lines, .top = 2, .slider_first = 5, .slider_len = 1, .tab_width = 4 }, &ops);
    try testing.expectEqual(@as(usize, 3), w2.ops);
}

test "MM5 비례 스크롤 — 본문이 상한에 서면 스트립도 끝에 서고, 다 들어가면 0" {
    try testing.expectEqual(@as(usize, 0), topLine(50, 100, 200, 60)); // 다 들어간다
    try testing.expectEqual(@as(usize, 0), topLine(0, 1000, 200, 960));
    try testing.expectEqual(@as(usize, 800), topLine(960, 1000, 200, 960)); // 끝 = lines − rows
    try testing.expectEqual(@as(usize, 400), topLine(480, 1000, 200, 960)); // 가운데는 가운데
    try testing.expectEqual(@as(usize, 800), topLine(5000, 1000, 200, 960)); // 상한 너머는 끝
    try testing.expectEqual(@as(usize, 0), topLine(10, 1000, 200, 0)); // 상한 0 이면 0
}

test "MM6 폭 — 설정 0 이면 0, 본문이 최소 열보다 좁아지면 접힌다, 아니면 셀 × 열" {
    try testing.expectEqual(@as(u32, 0), widthPx(1000, 8, 16, 0));
    try testing.expectEqual(@as(u32, 120), widthPx(1000, 8, 16, 15)); // (1000−16−120)/8 = 108 열 남는다
    try testing.expectEqual(@as(u32, 0), widthPx(400, 8, 16, 15)); // (400−16−120)/8 = 33 < 40 → 접힘
    try testing.expectEqual(@as(u32, 120), widthPx(456, 8, 16, 15)); // (456−16−120)/8 = 40 → 딱 경계는 선다
    try testing.expectEqual(@as(u32, 0), widthPx(100, 8, 16, 15)); // 폭 자체가 모자란다
}

test "MM7 y → 줄: 창 첫 줄 + 행, 밖은 묶는다" {
    try testing.expectEqual(@as(usize, 10), lineAtY(10, 0, 100));
    try testing.expectEqual(@as(usize, 13), lineAtY(10, 7, 100)); // 7px / 2 = 3
    try testing.expectEqual(@as(usize, 10), lineAtY(10, -5, 100));
    try testing.expectEqual(@as(usize, 99), lineAtY(10, 100_000, 100));
    try testing.expectEqual(@as(usize, 0), lineAtY(10, 4, 0));
}

test "MM9 두 칸 글자(CJK)는 두 열을 먹는다 — run 폭은 byte 가 아니라 열이다" {
    var ops: [8]draw.Op = undefined;
    const lines = [_][]const u8{"가나 x"}; // 가·나 = 2 열씩 → run 4 열, 그다음 x 는 5 열
    const w = build(.{ .rect = .{ .x = 0, .y = 0, .w = 40, .h = 2 }, .lines = &lines, .top = 0, .slider_first = 0, .slider_len = 0, .tab_width = 4 }, &ops);
    try testing.expectEqual(@as(usize, 2), w.ops);
    try testing.expectEqual(@as(u32, 4), ops[0].quad.rect.w);
    try testing.expectEqual(@as(i32, 5), ops[1].quad.rect.x);
}

test "MM10 검색 일치 행 — 창 안의 줄만 행 전체를 칠하고, 현재 일치는 다른 색, run 위·슬라이더 아래 (§6.2)" {
    var ops: [32]draw.Op = undefined;
    var lines: [40][]const u8 = undefined;
    for (&lines) |*l| l.* = "x";
    // 창은 줄 10..20(높이 20px). 일치: 5(창 밖) · 12 · 19(현재) · 25(창 밖).
    const marks = [_]u32{ 5, 12, 19, 25 };
    const w = build(.{ .rect = .{ .x = 100, .y = 50, .w = 30, .h = 20 }, .lines = &lines, .top = 10, .slider_first = 11, .slider_len = 3, .tab_width = 4, .mark_lines = &marks, .mark_current = 2 }, &ops);
    // run 10 + 일치 2 + 슬라이더 1
    try testing.expectEqual(@as(usize, 13), w.ops);
    try testing.expect(!w.truncated);
    const m12 = ops[10].quad;
    try testing.expectEqual(@as(i32, 100), m12.rect.x);
    try testing.expectEqual(@as(u32, 30), m12.rect.w); // 행 전체
    try testing.expectEqual(@as(i32, 50 + 2 * line_px), m12.rect.y); // (12 − 10) 행
    try testing.expectEqual(@as(u32, line_px), m12.rect.h);
    try testing.expectEqual(tokens.ColorRole.search_match, m12.fill_role);
    try testing.expectEqual(mark_alpha, m12.alpha);
    const m19 = ops[11].quad;
    try testing.expectEqual(@as(i32, 50 + 9 * line_px), m19.rect.y);
    try testing.expectEqual(tokens.ColorRole.search_match_current, m19.fill_role);
    try testing.expectEqual(tokens.ColorRole.selection, ops[12].quad.fill_role); // 슬라이더가 맨 위
    // 목록이 비면 일치 quad 가 없다.
    const w0 = build(.{ .rect = .{ .x = 100, .y = 50, .w = 30, .h = 20 }, .lines = &lines, .top = 10, .slider_first = 11, .slider_len = 3, .tab_width = 4 }, &ops);
    try testing.expectEqual(@as(usize, 11), w0.ops);
}

test "MM8 저장소가 모자라면 잘리되 죽지 않는다" {
    var ops: [2]draw.Op = undefined;
    const lines = [_][]const u8{ "a b c", "d" };
    const w = build(.{ .rect = .{ .x = 0, .y = 0, .w = 8, .h = 4 }, .lines = &lines, .top = 0, .slider_first = 0, .slider_len = 2, .tab_width = 4 }, &ops);
    try testing.expectEqual(@as(usize, 2), w.ops);
    try testing.expect(w.truncated);
    // **슬라이더 없이도** 선다 — 위 사례는 슬라이더 자리가 없어 `truncated` 가 서므로 run 쪽이 표식을 안 세워도 초록이었다
    // (16회차 P5: 두 뜻이 한 픽스처에서 겹쳤다). 그리고 모자라는 run 이 **공백에서 끝나는** 것이어야 한다 — 줄 끝에서 끝나는
    // run 은 다른 갈래(뒤처리)가 표식을 세워 다시 겹친다(20회차 T2). "a b c d": a·b 뒤 c 가 공백에서 끝나며 자리가 없다.
    const lines2 = [_][]const u8{"a b c d"};
    const w2 = build(.{ .rect = .{ .x = 0, .y = 0, .w = 8, .h = 4 }, .lines = &lines2, .top = 0, .slider_first = 0, .slider_len = 0, .tab_width = 4 }, &ops);
    try testing.expectEqual(@as(usize, 2), w2.ops);
    try testing.expect(w2.truncated);
    // 폭 0 사각은 **op 0** — 폭이 0 이라 run 은 안 나오지만 슬라이더는 폭 0 quad 를 내려 했다(16회차 P7). 그리는 것이 없으면
    // op 도 없어야 op 수를 세는 상위(프레임 합계·판정자)가 흔들리지 않는다.
    const w3 = build(.{ .rect = .{ .x = 0, .y = 0, .w = 0, .h = 4 }, .lines = &lines, .top = 0, .slider_first = 0, .slider_len = 2, .tab_width = 4 }, &ops);
    try testing.expectEqual(@as(usize, 0), w3.ops);
    try testing.expect(!w3.truncated);
}
