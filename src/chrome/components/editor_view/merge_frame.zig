//! 3-way 병합 한 프레임 — pane 넷(S3b-2, docs/editor-merge-conflicts.md §5 S3b).
//!
//! **새 렌더 경로가 아니다.** `frame.build`를 **넷** 부르는 조합일 뿐이고, 각 pane 은 지금까지의
//! 편집기 뷰와 같은 것이다 — gutter·스크롤바·랩·hazard·구문색이 공짜로 따라온다. 비교 뷰가
//! 「`frame.build` 를 둘 부르는 조합」으로 선 것과 **같은 자리, 같은 이유**다.
//!
//! **왜 컴포넌트 층인가**: 제품(`app_session/editor.zig`)과 Chrome Lab 이 **같은 함수**를 불러야
//! 캡처가 제품을 예고한다. 한쪽만 조합을 들면 골든은 초록인데 제품만 틀린 상태가 만들어진다
//! (편집기 배경 층에서 실제로 그랬다 — `diff_frame` 머리말).
//!
//! **비교 뷰 «기계»는 재활용하지 않는다**(계약 §7 ④). 그쪽은 좌우가 세로를 **일부러 공유**하고
//! (§3.5) 이쪽은 세 판이 각자 세로를 갖는다 — 그 규칙이 모드마다 갈리면 이미 서 있는 비교 뷰가
//! 같이 흔들린다. 다만 **순수 헬퍼 둘**(`sideMetrics`·`sideMetricsWith` — 「한 열의 스크롤바가
//! 자리를 얼마나 먹나」)은 그쪽에서 빌려 온다. 그것을 베끼면 같은 규칙의 주인이 둘이 된다.

const std = @import("std");
const draw = @import("../../draw.zig");
const frame = @import("frame.zig");
const diff_frame = @import("diff_frame.zig");
const geometry = @import("geometry.zig");
const gutter = @import("gutter.zig");
const content = @import("content.zig");
const visual_map = @import("../../ui/visual_map.zig");

/// pane 하나가 그릴 것. **비교 뷰의 `Side` 보다 얇다** — 이 조각의 세 판은 읽기만 하므로
/// 검색·선택·접힘 축이 아직 없다(S3b-3 에서 붙는다).
pub const Pane = struct {
    /// 그 pane 의 줄들.
    lines: []const []const u8,
    /// 줄별 구문 강조(있으면). 세 판도 색이 붙는다 — 같은 파일의 같은 언어다.
    line_colors: []const []const content.ColorSpan = &.{},
    /// 화면 맨 위 줄(각자 세로를 갖는다 — §5 S3b-2).
    first_line: usize = 0,
    first_piece: u32 = 0,
    /// 화면 맨 왼쪽 열(각자 가로도 갖는다 — 줄 길이가 서로 다르다).
    first_col: u32 = 0,
    /// 가장 긴 줄의 열 수(가로 막대 판정). null 이면 아직 안 셌다.
    content_max_cols: ?u32 = null,
    /// 이 pane 에 caret 이 서나. **Result 만 든다**(이 조각에서 입력을 받는 유일한 pane).
    carets: ?[]const []const u32 = null,
};

/// pane 넷이 실제로 놓인 자리. **`null` 은 「안 그렸다」**이고, 그 자리는 이웃이 가져간다.
///
/// 히트테스트가 이 값을 그대로 읽는다 — 「보이는 자리」와 「누르는 자리」가 갈리지 않으려면
/// 배치를 두 번 계산하면 안 된다(편집기 본문 사각이 같은 규율을 적어 두었다).
pub const Layout = struct {
    /// 왼쪽 위 — 현재 것(`:2:`). 좁으면 `null`.
    current: ?draw.Rect = null,
    /// 가운데 위 — Result(작업트리 파일). **언제나 그린다.**
    result: draw.Rect,
    /// 오른쪽 위 — 들어온 것(`:3:`). 좁으면 `null`.
    incoming: ?draw.Rect = null,
    /// 아래 띠 — 공통 조상(`:1:`). 조상이 없거나 높이가 모자라면 `null`.
    base: ?draw.Rect = null,

    /// 세 열이 다 섰나. 좁아서 Result 만 남았으면 거짓이다.
    pub fn isThreeUp(self: Layout) bool {
        return self.current != null and self.incoming != null;
    }
};

/// pane 하나가 읽을 만하려면 있어야 하는 **본문 열 수**.
///
/// 24 인 이유: 이보다 좁으면 gutter(번호)와 스크롤바를 뺀 본문이 한 줄에 낱말 두어 개밖에 못
/// 담아, 세 판을 나란히 놓아도 **비교가 안 된다**. 그럴 바에는 Result 하나를 넓게 보는 편이 낫다
/// (계약 §5 S3b-2 「좁으면 접는 순서」).
pub const min_pane_cols: u16 = 24;

/// 아래 Base 띠가 차지하는 **높이 몫**(1/4). 조상은 「무엇이 원래였나」를 확인하는 자리라 세 판보다
/// 덜 보면 되고, 그래서 위쪽에 높이를 몰아 준다.
pub const base_band_denominator: u32 = 4;

/// pane 하나가 읽을 만하려면 있어야 하는 **행 수**. 이보다 낮으면 띠를 안 그린다 — 한두 행짜리
/// 띠는 내용을 말하지 못하면서 위쪽 높이만 먹는다.
pub const min_pane_rows: u16 = 3;

/// 배치를 정한다. **순수 함수다** — 그리기 전에 판정자가 이 규칙만 따로 잴 수 있다.
pub fn layout(rect: draw.Rect, cell_w_px: u16, cell_h_px: u16, has_base: bool) Layout {
    const cw: u32 = @max(cell_w_px, 1);
    const ch: u32 = @max(cell_h_px, 1);
    // 한 pane 의 최소 폭은 **본문 최소 열 + 스크롤바 자리**다 — 막대를 빼먹으면 본문이 그만큼
    // 좁아져 최소 열을 못 채운다(그 자리는 `sideMetrics` 가 소유한다).
    const min_w: u32 = @as(u32, min_pane_cols) * cw + diff_frame.scrollbar_metrics.gutterPx();
    const three_up = rect.w >= min_w * 3;

    // **높이를 먼저 가른다.** Base 띠는 높이 몫(1/4)을 가져가되, 그러고도 위쪽이 최소 행을
    // 못 채우면 **띠를 안 그린다**(계약: Result > Current·Incoming > Base).
    var top_h = rect.h;
    var base_rect: ?draw.Rect = null;
    if (has_base) {
        const band_h = rect.h / base_band_denominator;
        const rest = rect.h -| band_h;
        if (band_h >= @as(u32, min_pane_rows) * ch and rest >= @as(u32, min_pane_rows) * ch) {
            top_h = rest;
            base_rect = .{ .x = rect.x, .y = rect.y + @as(i32, @intCast(rest)), .w = rect.w, .h = band_h };
        }
    }

    if (!three_up) {
        // **Result 만 남는다.** 세 열을 억지로 놓으면 글자가 한 칸씩 잘린 열 셋이 된다.
        return .{ .result = .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = top_h }, .base = base_rect };
    }

    // 세 열은 폭을 **균등하게** 나눈다. 나머지 픽셀은 가운데(Result)가 가져간다 — 편집하는 자리가
    // 가장 넓어야 하고, 자투리를 양 끝에 주면 세 열의 경계가 셀 격자에서 어긋난다.
    const each: u32 = rect.w / 3;
    const extra: u32 = rect.w - each * 3;
    const cur_x = rect.x;
    const res_x = cur_x + @as(i32, @intCast(each));
    const inc_x = res_x + @as(i32, @intCast(each + extra));
    return .{
        .current = .{ .x = cur_x, .y = rect.y, .w = each, .h = top_h },
        .result = .{ .x = res_x, .y = rect.y, .w = each + extra, .h = top_h },
        .incoming = .{ .x = inc_x, .y = rect.y, .w = each, .h = top_h },
        .base = base_rect,
    };
}

/// 저장소를 **넷**으로 가른다. 넷이 동시에 살아 있어야 한다 — op 이 text·run 을 가리키므로 같은
/// 버퍼를 다시 쓰면 앞 pane 의 글자가 뒤 pane 것으로 덮인다(비교 뷰가 둘로 가르는 그 이유다).
pub fn splitScratch(s: frame.Scratch, index: usize) frame.Scratch {
    const n = 4;
    const i = @min(index, n - 1);
    return .{
        .ops = sliceOf(draw.Op, s.ops, i, n),
        .text_bytes = sliceOf(u8, s.text_bytes, i, n),
        .runs = sliceOf(draw.Run, s.runs, i, n),
        .content_rows = sliceOf(content.Row, s.content_rows, i, n),
        .visual_rows = sliceOf(visual_map.VisualRow, s.visual_rows, i, n),
        .gutter_rows = sliceOf(gutter.Row, s.gutter_rows, i, n),
        .row_counts = sliceOf(u32, s.row_counts, i, n),
        .count_scratch = sliceOf(u8, s.count_scratch, i, n),
        .caret_cols = sliceOf(u32, s.caret_cols, i, n),
    };
}

fn sliceOf(comptime T: type, buf: []T, i: usize, n: usize) []T {
    const each = buf.len / n;
    const start = each * i;
    // 마지막 조각이 자투리를 가져간다 — 버리면 넷째 pane 만 조용히 좁아진다.
    const end = if (i + 1 == n) buf.len else start + each;
    return buf[start..end];
}

pub const Props = struct {
    rect: draw.Rect,
    /// 배경을 칠할 사각(없으면 `rect`).
    background_rect: ?draw.Rect = null,
    current: Pane,
    result: Pane,
    incoming: Pane,
    /// **`null` 이면 조상이 없다**(add/add) — 띠가 사라진다. 「내용이 비었다」와 다르다:
    /// 빈 조상도 어엿한 조상이라 띠가 선다(그 판정은 `conflict.StageSet` 이 소유한다).
    base: ?Pane = null,
    cell_w_px: u16,
    cell_h_px: u16,
    font_px: u16,
    tab_width: u8,
    wrap: bool,
    caret_visible: bool = false,
    caret_shape: frame.CaretShape = .bar,
};

pub const Written = struct {
    ops: usize,
    truncated: bool,
    /// 실제로 놓인 자리 — 히트테스트가 그대로 읽는다.
    layout: Layout,
    /// pane 마다 그린 시각 행 수(스크롤 상한 계산에 쓴다). 안 그린 pane 은 0.
    current_visual_rows: usize = 0,
    result_visual_rows: usize = 0,
    incoming_visual_rows: usize = 0,
    base_visual_rows: usize = 0,
};

fn buildPane(pane: Pane, props: Props, rect: draw.Rect, background: ?draw.Rect, scratch: frame.Scratch) frame.Written {
    const probe = diff_frame.sideMetrics(rect.w, rect.h, props.cell_w_px, props.cell_h_px);
    const shows_h_bar = frame.showsHorizontalBar(
        props.wrap,
        pane.content_max_cols,
        geometry.compute(probe.total_cols, pane.lines.len, .{}).content.width,
    );
    const m = diff_frame.sideMetricsWith(rect.w, rect.h, props.cell_w_px, props.cell_h_px, shows_h_bar);
    return frame.build(.{
        .lines = pane.lines,
        .line_colors = pane.line_colors,
        .first_line = pane.first_line,
        .first_piece = pane.first_piece,
        .first_col = pane.first_col,
        .total_lines = pane.lines.len,
        .content_max_cols = pane.content_max_cols,
        .carets = pane.carets,
        .caret_visible = props.caret_visible and pane.carets != null,
        .caret_shape = props.caret_shape,
        .visible_rows = m.visible_rows,
        .wrap = props.wrap,
        .tab_width = props.tab_width,
        .rect = rect,
        .background_rect = background,
        .cell_w_px = props.cell_w_px,
        .cell_h_px = props.cell_h_px,
        .font_px = props.font_px,
        .total_cols = m.total_cols,
        .scrollbar_gutter_px = m.scrollbar_gutter_px,
        .metrics = m.metrics,
    }, scratch);
}

/// pane 넷을 `scratch.ops` 앞쪽에 채운다.
pub fn build(props: Props, scratch: frame.Scratch) Written {
    const has_base = props.base != null;
    const lay = layout(props.rect, props.cell_w_px, props.cell_h_px, has_base);
    const outer = props.background_rect orelse props.rect;

    var out: Written = .{ .ops = 0, .truncated = false, .layout = lay };
    var written: usize = 0;
    var truncated = false;

    // **그린 순서대로 op 을 앞으로 모은다** — 호출자는 `ops[0..n]` 하나만 안다.
    const Slot = struct { pane: ?Pane, rect: ?draw.Rect, rows: *usize };
    var slots = [_]Slot{
        .{ .pane = props.current, .rect = lay.current, .rows = &out.current_visual_rows },
        .{ .pane = props.result, .rect = lay.result, .rows = &out.result_visual_rows },
        .{ .pane = props.incoming, .rect = lay.incoming, .rows = &out.incoming_visual_rows },
        .{ .pane = props.base, .rect = lay.base, .rows = &out.base_visual_rows },
    };
    for (&slots, 0..) |*slot, i| {
        const pane = slot.pane orelse continue;
        const rect = slot.rect orelse continue;
        const part = splitScratch(scratch, i);
        // 배경은 **자기 사각만** 칠한다 — 이웃까지 칠하면 나중에 그리는 pane 이 앞 pane 을 덮는다.
        const bg: draw.Rect = .{
            .x = rect.x,
            .y = rect.y,
            .w = rect.w,
            .h = if (i == 3) rect.h else @min(rect.h, outer.h),
        };
        const w = buildPane(pane, props, rect, bg, part);
        slot.rows.* = w.visual_rows;
        const moved = @min(w.ops, scratch.ops.len -| written);
        if (moved > 0 and part.ops.ptr != scratch.ops[written..].ptr) {
            std.mem.copyForwards(draw.Op, scratch.ops[written..][0..moved], part.ops[0..moved]);
        }
        written += moved;
        truncated = truncated or w.truncated or moved < w.ops;
    }
    out.ops = written;
    out.truncated = truncated;
    return out;
}

const testing = std.testing;

test "MPN1 조상이 없으면 Base 띠가 «사라진다» — 비워 두지 않는다" {
    // 빈 띠는 「읽는 중」과 구별되지 않는다. 그리고 그 판정은 S3a 가 이미 냈으므로 여기서 길이로
    // 다시 재지 않는다 — 이 함수가 받는 것은 「조상이 있나」뿐이다.
    const rect: draw.Rect = .{ .x = 0, .y = 0, .w = 1200, .h = 800 };
    const with_base = layout(rect, 8, 16, true);
    const no_base = layout(rect, 8, 16, false);
    const band = with_base.base orelse return error.MissingBase;
    try testing.expect(no_base.base == null);
    // **띠는 pane 폭을 다 쓴다** — 좁게 그리면 오른쪽에 배경이 비치고, 조상이 긴 줄일 때 읽을 수 없다.
    try testing.expectEqual(rect.x, band.x);
    try testing.expectEqual(rect.w, band.w);
    // **사라진 자리를 위가 가져간다** — 안 그러면 아래가 빈 채로 남는다.
    try testing.expect(no_base.result.h > with_base.result.h);
    try testing.expectEqual(rect.h, no_base.result.h);
}

test "MPN2 좁으면 Result «만» 남는다 — 세 열을 억지로 놓지 않는다" {
    const cell_w: u16 = 8;
    const min_w = @as(u32, min_pane_cols) * cell_w + diff_frame.scrollbar_metrics.gutterPx();
    // 세 배에서 한 픽셀 모자라면 못 놓는다(경계는 경계에서만 보인다).
    const narrow = layout(.{ .x = 0, .y = 0, .w = min_w * 3 - 1, .h = 800 }, cell_w, 16, true);
    try testing.expect(!narrow.isThreeUp());
    try testing.expect(narrow.current == null);
    try testing.expect(narrow.incoming == null);
    try testing.expectEqual(min_w * 3 - 1, narrow.result.w); // Result 가 폭을 다 쓴다
    // **딱 세 배면 놓는다.**
    const wide = layout(.{ .x = 0, .y = 0, .w = min_w * 3, .h = 800 }, cell_w, 16, true);
    try testing.expect(wide.isThreeUp());
    // **최소치 자체가 픽스처와 함께 움직이면 안 된다.** 위 둘은 `min_pane_cols` 에서 폭을 파생하므로
    // 그 상수를 낮춘 변이가 **같이 움직여** 살아남는다(적대적 1회차 L5 실측). 그래서 **고정 픽셀**로
    // 한 번 더 못박는다: 480px 은 세 열을 놓기에 좁다(열당 160px = 20 칸 남짓).
    try testing.expect(!layout(.{ .x = 0, .y = 0, .w = 480, .h = 800 }, 8, 16, true).isThreeUp());
    // 그리고 1200px 은 넉넉하다 — 위 단언이 「늘 접는다」로 갈려도 초록이 되지 않게.
    try testing.expect(layout(.{ .x = 0, .y = 0, .w = 1200, .h = 800 }, 8, 16, true).isThreeUp());
    // 좁아도 **Base 는 남는다** — 접는 순서가 Result > Current·Incoming > Base 다.
    const nb = narrow.base orelse return error.MissingBase;
    // **그리고 Result 가 그 띠를 덮지 않는다** — 덮으면 아래 pane 이 위 pane 뒤에 가려 안 보인다
    // (적대적 2회차 M3 이 그 자리였다: 좁을 때 Result 가 전체 높이를 쓰는 변이가 살아남았다).
    try testing.expect(narrow.result.y + @as(i32, @intCast(narrow.result.h)) <= nb.y);
    // 세 열이 설 때도 같다(M4).
    const wb = wide.base orelse return error.MissingBase;
    try testing.expect(wide.result.y + @as(i32, @intCast(wide.result.h)) <= wb.y);
    try testing.expect(wide.current.?.y + @as(i32, @intCast(wide.current.?.h)) <= wb.y);
    try testing.expect(wide.incoming.?.y + @as(i32, @intCast(wide.incoming.?.h)) <= wb.y);
}

test "MPN3 세 열이 «겹치지도 비지도» 않는다 — 자투리는 가운데가 가져간다" {
    const rect: draw.Rect = .{ .x = 17, .y = 5, .w = 1001, .h = 800 }; // 3 으로 안 나눠지는 폭
    const lay = layout(rect, 8, 16, false);
    const cur = lay.current orelse return error.MissingCurrent;
    const inc = lay.incoming orelse return error.MissingIncoming;
    // 왼쪽 끝과 오른쪽 끝이 부모와 같다(자투리를 버리면 오른쪽에 띠가 남는다).
    try testing.expectEqual(rect.x, cur.x);
    try testing.expectEqual(rect.x + @as(i32, @intCast(rect.w)), inc.x + @as(i32, @intCast(inc.w)));
    // 이어 붙는다 — 겹치면 뒤에 그린 pane 이 앞을 덮고, 비면 배경이 비친다.
    try testing.expectEqual(lay.result.x, cur.x + @as(i32, @intCast(cur.w)));
    try testing.expectEqual(inc.x, lay.result.x + @as(i32, @intCast(lay.result.w)));
    // **자투리는 가운데가 가져간다**(편집하는 자리가 가장 넓다).
    try testing.expect(lay.result.w >= cur.w);
    try testing.expect(lay.result.w >= inc.w);
}

test "MPN4 낮으면 Base 띠를 «안» 그린다 — 한두 행짜리 띠는 말을 못 한다" {
    const cell_h: u16 = 16;
    // 띠 몫(1/4)이 최소 행에 못 미치는 높이.
    const short = layout(.{ .x = 0, .y = 0, .w = 1200, .h = @as(u32, min_pane_rows) * cell_h * 4 - 1 }, 8, cell_h, true);
    try testing.expect(short.base == null);
    // **대조군**: 한 픽셀 더 높으면 띠가 선다(이 판정자가 「늘 안 그린다」로 갈려도 초록이 되지 않게).
    const ok = layout(.{ .x = 0, .y = 0, .w = 1200, .h = @as(u32, min_pane_rows) * cell_h * 4 }, 8, cell_h, true);
    try testing.expect(ok.base != null);
    // **최소 행도 픽스처와 함께 움직이면 안 된다**(적대적 2·3회차 M1) — 고정 픽셀로 한 번 더 못박되,
    // **두 값이 갈리는 자리**를 골라야 한다: 32px 로 쟀더니 최소 행을 1 로 낮춘 변이에서도 여전히
    // `null` 이라(띠 몫 8px < 16px) 그 변이가 살아남았다.
    //
    // 64px 은 띠 몫이 **16px = 한 행**이다 — 최소 3 행이면 안 그리고, 1 행으로 낮추면 그린다.
    try testing.expect(layout(.{ .x = 0, .y = 0, .w = 1200, .h = 64 }, 8, 16, true).base == null);
    // 192px 은 띠 몫이 48px = 세 행이라 최소 3 행에서도 그린다(대조군).
    try testing.expect(layout(.{ .x = 0, .y = 0, .w = 1200, .h = 192 }, 8, 16, true).base != null);
}

test "MPN5 저장소는 «넷» 으로 갈리고 자투리는 마지막이 가져간다" {
    // 같은 버퍼를 두 pane 이 쓰면 앞 pane 의 글자가 덮인다 — 겹침이 없어야 한다.
    var ops: [10]draw.Op = undefined;
    var text: [10]u8 = undefined;
    var runs: [10]draw.Run = undefined;
    var rows: [10]content.Row = undefined;
    var vrows: [10]visual_map.VisualRow = undefined;
    var grows: [10]gutter.Row = undefined;
    var counts: [10]u32 = undefined;
    var cscratch: [10]u8 = undefined;
    var carets: [10]u32 = undefined;
    const s: frame.Scratch = .{
        .ops = &ops,
        .text_bytes = &text,
        .runs = &runs,
        .content_rows = &rows,
        .visual_rows = &vrows,
        .gutter_rows = &grows,
        .row_counts = &counts,
        .count_scratch = &cscratch,
        .caret_cols = &carets,
    };
    var covered: usize = 0;
    var prev_end: usize = 0;
    for (0..4) |i| {
        const part = splitScratch(s, i);
        const start = (@intFromPtr(part.ops.ptr) - @intFromPtr(s.ops.ptr)) / @sizeOf(draw.Op);
        try testing.expectEqual(prev_end, start); // 겹치지도 비지도 않는다
        prev_end = start + part.ops.len;
        covered += part.ops.len;
    }
    try testing.expectEqual(s.ops.len, covered); // 자투리(10 % 4 = 2)까지 전부 쓰인다
    try testing.expectEqual(@as(usize, 4), splitScratch(s, 3).ops.len);
}
