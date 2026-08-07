//! File explorer vertical scrollbar geometry. This module is deliberately state-free: render,
//! hover, track clicks, and drag all consume the same `Geometry` value.

const std = @import("std");
const layout = @import("../ui/layout.zig");
const tree = @import("../ui/tree.zig");

pub const min_thumb_px: f32 = 24;
pub const bar_width_px: u32 = 8;
pub const edge_inset_px: u32 = 3;

/// Number of complete text cells that must be withheld from row layout so the track and its
/// right inset never overlap the last rendered cell. The reservation is derived from the same
/// integer pixel geometry as `compute`; one hard-coded cell is insufficient for narrow fonts.
pub fn reservedColumns(content_w: u32, cell_w: u32) u32 {
    if (content_w == 0 or cell_w == 0) return 0;
    const width = @min(bar_width_px, content_w);
    const inset = @min(edge_inset_px, content_w - width);
    const occupied = width + inset;
    return occupied / cell_w + @intFromBool(occupied % cell_w != 0);
}

pub const Geometry = struct {
    total_rows: usize,
    visible_rows: usize,
    max_scroll: usize,
    scroll_rows: usize,
    track_x: f32,
    track_y: f32,
    track_w: f32,
    track_h: f32,
    thumb_y: f32,
    thumb_h: f32,

    pub fn thumbContains(self: Geometry, x: f64, y: f64) bool {
        return x >= self.track_x and x < self.track_x + self.track_w and
            y >= self.thumb_y and y < self.thumb_y + self.thumb_h;
    }

    pub fn trackContains(self: Geometry, x: f64, y: f64) bool {
        return x >= self.track_x and x < self.track_x + self.track_w and
            y >= self.track_y and y < self.track_y + self.track_h;
    }

    pub fn sameSnapshot(self: Geometry, other: Geometry) bool {
        return self.total_rows == other.total_rows and self.visible_rows == other.visible_rows and
            self.track_x == other.track_x and self.track_y == other.track_y and
            self.track_w == other.track_w and self.track_h == other.track_h and
            self.thumb_h == other.thumb_h;
    }

    pub fn withScroll(self: Geometry, scroll_rows: usize) Geometry {
        var next = self;
        next.scroll_rows = @min(scroll_rows, self.max_scroll);
        const travel = self.track_h - self.thumb_h;
        const ratio = @as(f32, @floatFromInt(next.scroll_rows)) / @as(f32, @floatFromInt(self.max_scroll));
        next.thumb_y = self.track_y + travel * ratio;
        return next;
    }
};

/// 발행된 thumb과 track의 identity. thumb은 drag를, track은 click을 낸다 — 둘은 서로 다른 제스처라
/// 같은 identity를 나눠 쓰지 않는다.
pub const thumb_id: tree.UiId = 1;
pub const track_id: tree.UiId = 2;
pub const drag_payload: u64 = 1;

pub const PublishError = error{InsufficientEntryBuffer};

/// scrollbar를 pointer capture가 소비할 수 있는 `UiRectTree`로 발행한다 — CIM3.
///
/// divider와 같은 규율이다: 이 tree는 **paint가 아니라 hit/capture 전용**이고, 그리는 쪽은 계속
/// 자기 경로를 쓴다. thumb이 먼저(뒤 entry) 이겨야 하므로 track을 앞에 싣는다 —
/// `interaction.hitAction`이 reverse z-order라 마지막 entry가 이긴다.
///
/// thumb의 drag는 세로 축이고 threshold는 0이다. thumb을 누른 것 자체가 스크롤 의사이며, 그 지점에
/// 경쟁할 click이 없다(track click은 thumb **밖**에서만 성립한다).
pub fn publish(
    geometry: Geometry,
    generation: u64,
    out: []tree.RectEntry,
) PublishError!tree.UiRectTree {
    if (out.len < 2) return error.InsufficientEntryBuffer;
    // 스크롤할 것이 없으면 잡을 것도 없다. 빈 tree는 실패가 아니라 "대상 없음"이다.
    if (geometry.max_scroll == 0 or geometry.track_w <= 0 or geometry.track_h <= 0) {
        return .{ .entries = out[0..0], .generation = generation };
    }
    out[0] = .{
        .id = track_id,
        .parent_index = null,
        .kind = .container,
        .rect = .{ .x = geometry.track_x, .y = geometry.track_y, .width = geometry.track_w, .height = geometry.track_h },
        .effective_clip = null,
        .action = .{ .id = track_id },
    };
    out[1] = .{
        .id = thumb_id,
        .parent_index = null,
        .kind = .container,
        .rect = .{ .x = geometry.track_x, .y = geometry.thumb_y, .width = geometry.track_w, .height = geometry.thumb_h },
        .effective_clip = null,
        .action = .{ .id = thumb_id },
        .drag = .{ .payload = drag_payload, .axis = .vertical, .threshold_px = 0 },
    };
    return .{ .entries = out[0..2], .generation = generation };
}

pub fn compute(
    total_rows: usize,
    visible_rows: usize,
    scroll_rows: usize,
    content_x: u32,
    content_y: u32,
    content_w: u32,
    content_h: u32,
) ?Geometry {
    if (visible_rows == 0 or total_rows <= visible_rows or content_w == 0 or content_h == 0) return null;
    const max_scroll = total_rows - visible_rows;
    const track_h: f32 = @floatFromInt(content_h);
    const proportional = track_h * @as(f32, @floatFromInt(visible_rows)) / @as(f32, @floatFromInt(total_rows));
    const thumb_h = @min(track_h, @max(min_thumb_px, proportional));
    const travel = track_h - thumb_h;
    const clamped_scroll = @min(scroll_rows, max_scroll);
    const ratio = @as(f32, @floatFromInt(clamped_scroll)) / @as(f32, @floatFromInt(max_scroll));
    const width = @min(bar_width_px, content_w);
    const inset = @min(edge_inset_px, content_w - width);
    return .{
        .total_rows = total_rows,
        .visible_rows = visible_rows,
        .max_scroll = max_scroll,
        .scroll_rows = clamped_scroll,
        .track_x = @floatFromInt(content_x + content_w - width - inset),
        .track_y = @floatFromInt(content_y),
        .track_w = @floatFromInt(width),
        .track_h = track_h,
        .thumb_y = @as(f32, @floatFromInt(content_y)) + travel * ratio,
        .thumb_h = thumb_h,
    };
}

/// Maps an absolute pointer y to scroll rows while keeping the captured point inside the thumb.
pub fn scrollForPointer(geometry: Geometry, pointer_y: f64, grab_y: f32) usize {
    if (!std.math.isFinite(pointer_y) or !std.math.isFinite(grab_y)) return geometry.scroll_rows;
    const travel = geometry.track_h - geometry.thumb_h;
    if (travel <= 0 or geometry.max_scroll == 0) return 0;
    const thumb_top_f64 = std.math.clamp(
        pointer_y - @as(f64, grab_y),
        @as(f64, geometry.track_y),
        @as(f64, geometry.track_y + travel),
    );
    const thumb_top: f32 = @floatCast(thumb_top_f64);
    const ratio = (thumb_top - geometry.track_y) / travel;
    return @intFromFloat(@round(ratio * @as(f32, @floatFromInt(geometry.max_scroll))));
}

/// Track clicks center the thumb at the click and use the same drag mapping thereafter.
pub fn scrollForTrackClick(geometry: Geometry, pointer_y: f64) usize {
    return scrollForPointer(geometry, pointer_y, geometry.thumb_h / 2);
}

// 예약이 **올림**이어야 하는 이유: track(8px) + 우측 inset(3px) = 11px가 셀 폭으로 나누어떨어지는
// 일은 거의 없고, 내림하면 마지막 칸의 일부를 트랙이 덮는다. 그 반 칸이 글자를 자른다.
test "file tree scrollbar: reserved columns round up so the track never covers a partial cell" {
    // 11px를 7px 셀로: 1.57칸 → 2칸을 빼야 트랙이 글자를 안 덮는다.
    try std.testing.expectEqual(@as(u32, 2), reservedColumns(200, 7));
    // 나누어떨어지면 올림이 없다(11px를 11px 셀로 = 1칸).
    try std.testing.expectEqual(@as(u32, 1), reservedColumns(200, 11));
    // 예약한 칸 수 × 셀 폭이 항상 점유 픽셀 이상이다 — 이것이 계약의 본체다.
    for ([_]u32{ 5, 6, 7, 8, 9, 10, 12, 16 }) |cell_w| {
        const occupied = bar_width_px + edge_inset_px;
        try std.testing.expect(reservedColumns(200, cell_w) * cell_w >= occupied);
    }
    // content 폭이 트랙보다 좁으면 트랙이 그 폭에 눌린다 — 예약이 폭을 넘어서면 안 된다.
    try std.testing.expect(reservedColumns(5, 8) * 8 <= 5 + 8);
    try std.testing.expect(reservedColumns(5, 1) <= 5);
    // 퇴화 입력은 0이다(0으로 나누지 않는다).
    try std.testing.expectEqual(@as(u32, 0), reservedColumns(0, 8));
    try std.testing.expectEqual(@as(u32, 0), reservedColumns(200, 0));
}

// `withScroll`과 `compute`는 둘 다 `max_scroll`로 나눈다. 0이면 0/0 = NaN이라 thumb 좌표가 화면 밖으로
// 나가거나 사라진다. 지금 그 상태가 **도달 불가**한 이유는 `compute`가 `total_rows <= visible_rows`를
// null로 걸러 `max_scroll >= 1`을 보장하기 때문이다 — 방어 코드를 더하는 대신 그 불변식을 고정한다.
// 이 게이트가 사라지면(예: 넘치지 않아도 트랙을 그리도록 바꾸면) 여기서 먼저 빨개진다.
test "file tree scrollbar: compute never publishes a zero scroll range" {
    try std.testing.expect(compute(3, 3, 0, 0, 0, 100, 90) == null); // 딱 맞으면 없다
    try std.testing.expect(compute(2, 3, 0, 0, 0, 100, 90) == null); // 모자라도 없다
    const g = compute(4, 3, 0, 0, 0, 100, 90) orelse return error.TestUnexpectedResult;
    try std.testing.expect(g.max_scroll >= 1);
    try std.testing.expect(std.math.isFinite(g.thumb_y));
    try std.testing.expect(std.math.isFinite(g.withScroll(g.max_scroll).thumb_y));
}

test "file tree scrollbar: overflow only and endpoints" {
    try std.testing.expect(compute(10, 10, 0, 0, 0, 200, 200) == null);
    const top = compute(100, 10, 0, 10, 20, 200, 300).?;
    const bottom = compute(100, 10, 90, 10, 20, 200, 300).?;
    try std.testing.expectEqual(@as(f32, 20), top.thumb_y);
    try std.testing.expectApproxEqAbs(top.track_y + top.track_h - top.thumb_h, bottom.thumb_y, 0.01);
    try std.testing.expectEqual(@as(usize, 0), scrollForTrackClick(top, -100));
    try std.testing.expectEqual(@as(usize, 90), scrollForTrackClick(top, 1000));
}

test "file tree scrollbar: drag round trips every row" {
    const geometry = compute(257, 17, 0, 0, 5, 180, 400).?;
    const travel = geometry.track_h - geometry.thumb_h;
    for (0..geometry.max_scroll + 1) |wanted| {
        const y = geometry.track_y + travel * @as(f32, @floatFromInt(wanted)) /
            @as(f32, @floatFromInt(geometry.max_scroll));
        try std.testing.expectEqual(wanted, scrollForPointer(geometry, y, 0));
    }
}

test "file tree scrollbar: non-finite drag preserves scroll and huge finite values clamp" {
    const geometry = compute(100, 10, 35, 0, 0, 200, 300).?;
    try std.testing.expectEqual(@as(usize, 35), scrollForPointer(geometry, std.math.nan(f64), 0));
    try std.testing.expectEqual(@as(usize, 35), scrollForPointer(geometry, std.math.inf(f64), 0));
    try std.testing.expectEqual(@as(usize, 35), scrollForPointer(geometry, -std.math.inf(f64), 0));
    try std.testing.expectEqual(@as(usize, 90), scrollForPointer(geometry, std.math.floatMax(f64), 0));
    try std.testing.expectEqual(@as(usize, 0), scrollForPointer(geometry, -std.math.floatMax(f64), 0));
}

test "file tree scrollbar: pixel reservation never overlaps the last content cell" {
    try std.testing.expectEqual(@as(u32, 2), reservedColumns(160, 8));
    const content_x: u32 = 17;
    for (1..17) |cell_w_usize| {
        const cell_w: u32 = @intCast(cell_w_usize);
        for (0..cell_w) |remainder_usize| {
            const remainder: u32 = @intCast(remainder_usize);
            const content_w = cell_w * 20 + remainder;
            const geometry = compute(100, 10, 0, content_x, 0, content_w, 300).?;
            const total_cols = content_w / cell_w;
            const content_cols = total_cols -| reservedColumns(content_w, cell_w);
            const last_content_right = content_x + content_cols * cell_w;
            try std.testing.expect(@as(f32, @floatFromInt(last_content_right)) <= geometry.track_x);
        }
    }
}

test "published scrollbar rects agree with the geometry both hit paths already use" {
    const geometry = Geometry{
        .total_rows = 100,
        .visible_rows = 10,
        .max_scroll = 90,
        .scroll_rows = 0,
        .track_x = 200,
        .track_y = 0,
        .track_w = 8,
        .track_h = 400,
        .thumb_y = 0,
        .thumb_h = 40,
    };
    var storage: [4]tree.RectEntry = undefined;
    const published = try publish(geometry, 5, &storage);
    try std.testing.expectEqual(@as(usize, 2), published.entries.len);
    try std.testing.expectEqual(@as(u64, 5), published.generation);

    // thumb은 **마지막** entry여야 한다. `interaction.hitAction`이 reverse z-order라, track이 뒤에
    // 오면 thumb 위 클릭이 track click으로 판정돼 드래그 대신 점프가 일어난다.
    try std.testing.expectEqual(track_id, published.entries[0].id);
    try std.testing.expectEqual(thumb_id, published.entries[1].id);

    // 두 rect가 기존 hit 판정과 같은 기하에서 나온다.
    const thumb = published.entries[1].rect;
    try std.testing.expect(geometry.thumbContains(thumb.x + 1, thumb.y + 1));
    const track = published.entries[0].rect;
    try std.testing.expect(geometry.trackContains(track.x + 1, track.y + track.height - 1));

    // thumb만 drag를 선언하고, 그 축은 세로다. track click은 drag가 아니다.
    try std.testing.expect(published.entries[0].drag == null);
    try std.testing.expectEqual(tree.DragAxis.vertical, published.entries[1].drag.?.axis);
    try std.testing.expectEqual(@as(f32, 0), published.entries[1].drag.?.threshold_px);
}

test "a scrollbar with nothing to scroll publishes no capture target" {
    const geometry = Geometry{
        .total_rows = 5,
        .visible_rows = 10,
        .max_scroll = 0,
        .scroll_rows = 0,
        .track_x = 200,
        .track_y = 0,
        .track_w = 8,
        .track_h = 400,
        .thumb_y = 0,
        .thumb_h = 400,
    };
    var storage: [4]tree.RectEntry = undefined;
    // 잡을 것이 없다는 뜻이지 실패가 아니다 — 빈 tree를 내고 host는 아무 것도 capture하지 않는다.
    try std.testing.expectEqual(@as(usize, 0), (try publish(geometry, 1, &storage)).entries.len);

    var small: [1]tree.RectEntry = undefined;
    // partial publish 대신 후보 자체가 실패한다(thumb만 있고 track이 없는 tree를 내지 않는다).
    try std.testing.expectError(error.InsufficientEntryBuffer, publish(geometry, 1, &small));
}
