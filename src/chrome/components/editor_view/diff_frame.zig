//! 나란한 비교 한 프레임(§7 — 좌우 배치가 기본).
//!
//! **새 렌더 경로가 아니다.** `frame.build`를 두 번 부르는 조합일 뿐이고, 각 열은 지금까지의 편집기
//! 뷰와 같은 것이다(§7: *"diff는 별도 렌더 경로가 아니라 §4 시각 매핑·§5 스팬·§6 미니맵을 그대로 쓰는
//! 소비자다"*). 그래서 gutter·스크롤바·랩·hazard가 공짜로 따라온다.
//!
//! **왜 컴포넌트 층인가**: 제품(`app_session/editor.zig`)과 Chrome Lab이 **같은 함수**를 불러야 캡처가
//! 제품을 예고한다. 한쪽만 조합을 들고 있으면 골든은 초록인데 제품만 틀린 상태가 만들어진다 — 편집기
//! 배경 층에서 실제로 그랬다(`background_layer` 주석).
//!
//! 세로는 하나, 가로는 각자다(§3.5). 세로를 공유하는 것은 **같은 줄이 같은 높이에 서야** 비교가
//! 성립하기 때문이고, 가로를 나누는 것은 양쪽 줄 길이가 달라 한쪽을 따라가면 다른 쪽이 엉뚱한 곳을
//! 보기 때문이다(CM6 `diff-layout.ts`가 같은 결론을 적어 두었다).

const std = @import("std");
const draw = @import("../../draw.zig");
const scroll_area = @import("../../ui/scroll_area.zig");
const frame = @import("frame.zig");

/// 한 쪽이 그릴 것.
pub const Side = struct {
    /// 그 쪽 **행**들의 표시 텍스트. 좌우 길이가 같아야 같은 인덱스가 같은 높이다.
    lines: []const []const u8,
    /// gutter 자릿수를 정하는 **문서** 줄 수(행 수가 아니다). `null`이면 `lines.len`.
    total_lines: ?usize = null,
    /// 행마다의 줄 번호(`null` 항목 = 짝을 맞추려 넣은 빈 행). `null`이면 순차 번호.
    numbers: ?[]const ?u32 = null,
    /// 가로 스크롤(열). **각자다** — 공유하면 반대쪽이 엉뚱한 곳을 본다.
    first_col: u16 = 0,
};

pub const Props = struct {
    left: Side,
    right: Side,
    /// 두 열이 **공유하는** 세로 위치(행 인덱스).
    first_line: usize = 0,
    wrap: bool = false,
    tab_width: u8 = 4,
    /// 내용이 설 사각(호출자가 여백을 이미 반영해 넘긴다).
    rect: draw.Rect,
    /// 배경이 덮을 바깥 사각. 각 열의 배경은 여기서 자기 몫으로 잘린다 — 바깥 가장자리만 여백만큼
    /// 물리고 가운데는 물리지 않는다(뒤로 물리면 반대쪽 본문 밑으로 들어간다).
    background_rect: ?draw.Rect = null,
    cell_w_px: u16,
    cell_h_px: u16,
    font_px: u16,
};

pub const Written = struct {
    ops: usize,
    visual_rows: usize,
    truncated: bool,
    /// 오른쪽 열이 시작하는 x. 테스트·히트테스트가 두 열을 가를 때 쓴다.
    split_x: i32,
};

pub const Columns = struct { left: draw.Rect, right: draw.Rect };

/// 좌우 열의 자리. **가운데 한 칸을 비운다** — 두 본문이 맞닿으면 어느 쪽 글자인지 읽히지 않는다
/// (색 띠가 붙기 전에도 배치만으로 갈라져 보여야 한다). 나머지 픽셀은 오른쪽이 가져가 pane 오른쪽
/// 끝에 칠하지 않은 띠가 남지 않게 한다.
pub fn columns(inner: draw.Rect, cell_w_px: u16) Columns {
    const gap: u32 = @max(cell_w_px, 1);
    const usable = inner.w -| gap;
    const left_w = usable / 2;
    return .{
        .left = .{ .x = inner.x, .y = inner.y, .w = left_w, .h = inner.h },
        .right = .{
            .x = inner.x + @as(i32, @intCast(left_w + gap)),
            .y = inner.y,
            .w = usable -| left_w,
            .h = inner.h,
        },
    };
}

/// 한 열의 폭에서 나오는 값들. **편집기 하나든 diff의 한 쪽이든 같은 계산이다** — 두 곳에 두면
/// 좌우 열만 다르게 어긋난다.
pub const SideMetrics = struct {
    metrics: scroll_area.ScrollbarMetrics,
    total_cols: u16,
    scrollbar_gutter_px: u32,
    visible_rows: u16,
};

/// 스크롤바 기하. 제품과 Lab이 같은 값을 써야 캡처가 제품을 예고한다.
pub const scrollbar_metrics: scroll_area.ScrollbarMetrics = .{ .width_px = 8, .inset_x_px = 4, .min_thumb_px = 24 };

pub fn sideMetrics(inner_w: u32, inner_h: u32, cell_w_px: u16, cell_h_px: u16) SideMetrics {
    // **스크롤바가 자리를 먹는다**(§4.1a) — 본문 위에 겹치면 오른쪽 끝 글자가 막대에 가려지고,
    // §3.8이 "보이는 것과 파일 내용이 달라지면 안 된다"를 요구하는 편집기에서 그것은 특히 나쁘다.
    const cw: u32 = @max(cell_w_px, 1);
    const ch: u32 = @max(cell_h_px, 1);
    const total_cols: u16 = @intCast(@min(
        (inner_w -| scrollbar_metrics.gutterPx()) / cw,
        @as(u32, std.math.maxInt(u16)),
    ));
    return .{
        .metrics = scrollbar_metrics,
        .total_cols = total_cols,
        // **남은 폭 전부가 스크롤바 gutter다.** `total_cols`가 버림이라 본문이 셀 경계에서 끝나고,
        // 요구한 폭보다 넓은 자투리가 생긴다 — 그것을 포함하지 않으면 막대가 오른쪽 끝에서 뜬다.
        .scrollbar_gutter_px = inner_w -| (@as(u32, total_cols) * cw),
        .visible_rows = @intCast(@min(inner_h / ch, @as(u32, std.math.maxInt(u16)))),
    };
}

/// 두 열이 함께 쓰는 값. 열 하나만 그리는 호출자(단일 편집기)도 이것을 쓴다.
pub const Shared = struct {
    first_line: usize = 0,
    wrap: bool = false,
    tab_width: u8 = 4,
    cell_w_px: u16,
    cell_h_px: u16,
    font_px: u16,
};

/// 한 열을 그린다. 좌표는 `rect`가 정하므로 **열이 어디에 있든** 같은 함수다.
pub fn buildSide(
    side: Side,
    shared: Shared,
    rect: draw.Rect,
    background: ?draw.Rect,
    scratch: frame.Scratch,
) frame.Written {
    const m = sideMetrics(rect.w, rect.h, shared.cell_w_px, shared.cell_h_px);
    return frame.build(.{
        .lines = side.lines,
        .first_line = shared.first_line,
        .first_col = side.first_col,
        .total_lines = side.total_lines orelse side.lines.len,
        .line_numbers = side.numbers,
        .visible_rows = m.visible_rows,
        .wrap = shared.wrap,
        .tab_width = shared.tab_width,
        .rect = rect,
        .background_rect = background,
        .cell_w_px = shared.cell_w_px,
        .cell_h_px = shared.cell_h_px,
        .font_px = shared.font_px,
        .total_cols = m.total_cols,
        .scrollbar_gutter_px = m.scrollbar_gutter_px,
        .metrics = m.metrics,
    }, scratch);
}

const ScratchPair = struct { first: frame.Scratch, second: frame.Scratch };

/// 저장소를 반으로 가른다. **두 결과가 동시에 살아 있어야 한다** — op이 text·run을 가리키므로
/// 같은 버퍼를 두 번 쓰면 왼쪽 글자가 오른쪽 것으로 덮인다.
pub fn splitScratch(s: frame.Scratch) ScratchPair {
    return .{
        .first = .{
            .ops = s.ops[0 .. s.ops.len / 2],
            .text_bytes = s.text_bytes[0 .. s.text_bytes.len / 2],
            .runs = s.runs[0 .. s.runs.len / 2],
            .content_rows = s.content_rows[0 .. s.content_rows.len / 2],
            .visual_rows = s.visual_rows[0 .. s.visual_rows.len / 2],
            .gutter_rows = s.gutter_rows[0 .. s.gutter_rows.len / 2],
            .row_counts = s.row_counts[0 .. s.row_counts.len / 2],
            .count_scratch = s.count_scratch[0 .. s.count_scratch.len / 2],
        },
        .second = .{
            .ops = s.ops[s.ops.len / 2 ..],
            .text_bytes = s.text_bytes[s.text_bytes.len / 2 ..],
            .runs = s.runs[s.runs.len / 2 ..],
            .content_rows = s.content_rows[s.content_rows.len / 2 ..],
            .visual_rows = s.visual_rows[s.visual_rows.len / 2 ..],
            .gutter_rows = s.gutter_rows[s.gutter_rows.len / 2 ..],
            .row_counts = s.row_counts[s.row_counts.len / 2 ..],
            .count_scratch = s.count_scratch[s.count_scratch.len / 2 ..],
        },
    };
}

/// 좌우 두 열을 `scratch.ops` 앞쪽에 채운다.
pub fn build(props: Props, scratch: frame.Scratch) Written {
    const cols = columns(props.rect, props.cell_w_px);
    const half = splitScratch(scratch);
    const outer = props.background_rect orelse props.rect;
    const left_bg_x = outer.x;
    const right_bg_end = outer.x + @as(i32, @intCast(outer.w));

    const shared: Shared = .{
        .first_line = props.first_line,
        .wrap = props.wrap,
        .tab_width = props.tab_width,
        .cell_w_px = props.cell_w_px,
        .cell_h_px = props.cell_h_px,
        .font_px = props.font_px,
    };
    const lw = buildSide(props.left, shared, cols.left, .{
        .x = left_bg_x,
        .y = outer.y,
        .w = @intCast(cols.right.x - left_bg_x),
        .h = outer.h,
    }, half.first);

    const rw = buildSide(props.right, shared, cols.right, .{
        .x = cols.right.x,
        .y = outer.y,
        .w = @intCast(@max(right_bg_end - cols.right.x, 0)),
        .h = outer.h,
    }, half.second);

    // 두 열의 op을 앞쪽으로 모은다 — 호출자는 `ops[0..n]` 하나만 안다. 목적지가 원본보다 앞이므로
    // 전진 복사가 안전하다(왼쪽이 저장소 절반을 다 쓰지 않는 한 겹치지도 않는다).
    const moved = @min(rw.ops, scratch.ops.len -| lw.ops);
    std.mem.copyForwards(draw.Op, scratch.ops[lw.ops..][0..moved], half.second.ops[0..moved]);
    return .{
        .ops = lw.ops + moved,
        .visual_rows = @max(lw.visual_rows, rw.visual_rows),
        .truncated = lw.truncated or rw.truncated or moved < rw.ops,
        .split_x = cols.right.x,
    };
}

const testing = std.testing;

test "두 열이 서로를 침범하지 않고 가운데 한 칸이 빈다" {
    const cols = columns(.{ .x = 0, .y = 0, .w = 801, .h = 600 }, 8);
    try testing.expect(cols.left.x + @as(i32, @intCast(cols.left.w)) <= cols.right.x);
    try testing.expectEqual(@as(i32, 8), cols.right.x - (cols.left.x + @as(i32, @intCast(cols.left.w))));
    // **자투리를 남기지 않는다** — 남기면 pane 오른쪽 끝에 칠하지 않은 띠가 선다.
    try testing.expectEqual(@as(u32, 801), cols.left.w + 8 + cols.right.w);
}

test "열이 원점을 따라간다 — pane 안 어디에 있든 같은 함수다" {
    const cols = columns(.{ .x = 100, .y = 50, .w = 400, .h = 200 }, 10);
    try testing.expectEqual(@as(i32, 100), cols.left.x);
    try testing.expectEqual(@as(i32, 100 + 195 + 10), cols.right.x);
}

test "저장소가 겹치지 않는다 — 겹치면 한쪽 글자가 반대쪽 것으로 바뀐다" {
    var ops: [64]draw.Op = undefined;
    var text: [256]u8 = undefined;
    var runs: [64]draw.Run = undefined;
    var content_rows: [16]@import("content.zig").Row = undefined;
    var visual_rows: [16]@import("visual_map.zig").VisualRow = undefined;
    var gutter_rows: [16]@import("gutter.zig").Row = undefined;
    var counts: [16]u32 = undefined;
    var count_scratch: [64]u8 = undefined;
    const s: frame.Scratch = .{
        .ops = &ops,
        .text_bytes = &text,
        .runs = &runs,
        .content_rows = &content_rows,
        .visual_rows = &visual_rows,
        .gutter_rows = &gutter_rows,
        .row_counts = &counts,
        .count_scratch = &count_scratch,
    };
    const pair = splitScratch(s);
    try testing.expect(@intFromPtr(pair.first.text_bytes.ptr) + pair.first.text_bytes.len <= @intFromPtr(pair.second.text_bytes.ptr));
    try testing.expect(@intFromPtr(pair.first.runs.ptr) + pair.first.runs.len * @sizeOf(draw.Run) <= @intFromPtr(pair.second.runs.ptr));
    try testing.expectEqual(ops.len / 2, pair.first.ops.len);
}
