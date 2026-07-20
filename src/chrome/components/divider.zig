//! Divider — pane 분할 경계 선 + 드래그 hit-test. chrome **마우스 hit-test 컴포넌트의 첫 선례**.
//! notice/find/palette(키보드 오버레이, State+view+handle)와 달리, divider의 드래그 상태는 라이브 split-tree
//! 포인터(`*Split`)에 묶여 있어 그 상태는 platform이 든다(docs/layering-and-portability.md §6 — 라이브 트리 포인터는
//! neutral chrome 밖, freed 시 invalidate). 그래서 이 컴포넌트는 **State 없는 순수 함수 모듈**이다: host가
//! `PaneTree.layoutDividers` 결과를 중립 `Seg`로 변환 주입하면(palette `Row` 선례), hitTest(마우스→seg index)·
//! view(seg→Rule op 선)·dragRatio(마우스→비율)를 순수하게 계산한다. host 키보드 라우팅(ChromeHost.handleInput)을
//! 안 거친다(divider는 마우스). 단일 출처: docs/chrome-strategy.md §5.4, docs/layering-and-portability.md §5(C2).

const std = @import("std");
const draw = @import("../draw.zig");

/// 이 컴포넌트가 그리는 레이어 — pane overlay(터미널 위, 커서·모달 아래). platform이 divider.view를 직접 lower해
/// pane_overlay 셀 슬롯에 넣는다(host 키보드 라우팅을 안 거치는 마우스 컴포넌트라, 이 상수는 Z-순서 분류용).
pub const layer = draw.Layer.pane_overlay;

/// divider 선의 방향. host가 split 방향에서 변환한다: 좌우 분할(app `SplitDirection.horizontal`) → 세로선,
/// 상하 분할(`.vertical`) → 가로선. hitTest/view/dragRatio가 이걸로 normal 축(드래그·밴드)과 교차 축(bounds)을 가른다.
pub const Orientation = enum { vertical_line, horizontal_line };

/// 중립 divider 세그먼트 — host가 `PaneTree.layoutDividers`의 DividerSeg에서 `*Split`를 떼고 만든다(chrome은 app
/// 트리를 모른다). bounds=이 경계가 나누는 부모 영역(드래그 비율의 분모), pos=경계 픽셀(세로선=x, 가로선=y).
pub const Seg = struct {
    orientation: Orientation,
    bounds: draw.Rect,
    pos: u32,
};

/// WebView pass-through projection도 hit-test와 같은 normal-axis 폭을 써야 하므로 공개한 순수 SSOT.
/// 0 cell은 hit target이 없음을 뜻한다.
pub fn hitHalfExtentPx(orientation: Orientation, cell_width_px: u32, cell_height_px: u32) f64 {
    const cell = switch (orientation) {
        .vertical_line => cell_width_px,
        .horizontal_line => cell_height_px,
    };
    if (cell == 0) return 0;
    return @as(f64, @floatFromInt(cell)) / 2 + 2;
}

/// 마우스 (x,y)가 어느 seg의 드래그 밴드 안인가 — 맞으면 그 index, 아니면 null. 밴드: normal 축은 경계 pos ± (cell
/// 절반 + 2px 여유, 잡기 쉽게), 교차 축은 bounds 범위. 렌더 선(view)과 같은 seg라 "보이는 선 == 잡히는 선".
/// 셀 0·비유한이면 매치 없음. 단일 panel(segs 빈)이면 항상 null. (옛 app_session.dividerHit 수학 이전.)
pub fn hitTest(segs: []const Seg, cell_width_px: u32, cell_height_px: u32, x_px: f64, y_px: f64) ?usize {
    if (cell_width_px == 0 or cell_height_px == 0 or !std.math.isFinite(x_px) or !std.math.isFinite(y_px)) return null;
    for (segs, 0..) |seg, i| {
        const pos: f64 = @floatFromInt(seg.pos);
        const hit = switch (seg.orientation) {
            .vertical_line => blk: { // 세로선: x가 경계 근처, y가 bounds.y..y+h
                const half = hitHalfExtentPx(.vertical_line, cell_width_px, cell_height_px);
                const y0: f64 = @floatFromInt(seg.bounds.y);
                const y1: f64 = y0 + @as(f64, @floatFromInt(seg.bounds.h));
                break :blk @abs(x_px - pos) <= half and y_px >= y0 and y_px < y1;
            },
            .horizontal_line => blk: { // 가로선: y가 경계 근처, x가 bounds.x..x+w
                const half = hitHalfExtentPx(.horizontal_line, cell_width_px, cell_height_px);
                const x0: f64 = @floatFromInt(seg.bounds.x);
                const x1: f64 = x0 + @as(f64, @floatFromInt(seg.bounds.w));
                break :blk @abs(y_px - pos) <= half and x_px >= x0 and x_px < x1;
            },
        };
        if (hit) return i;
    }
    return null;
}

/// 드래그 위치 → 새 분할 비율(normal 축 기준). 세로선=`(x − bounds.x)/bounds.w`, 가로선=`(y − bounds.y)/bounds.h`.
/// 0폭/0높이·비유한이면 null(host가 무시). **클램프는 host가 한다**(session.clampRatio — chrome은 app 상수를 모른다).
/// (옛 dragDividerTo 수학 이전.)
pub fn dragRatio(seg: Seg, x_px: f64, y_px: f64) ?f32 {
    const raw: f64 = switch (seg.orientation) {
        .vertical_line => if (seg.bounds.w == 0) return null else (x_px - @as(f64, @floatFromInt(seg.bounds.x))) / @as(f64, @floatFromInt(seg.bounds.w)),
        .horizontal_line => if (seg.bounds.h == 0) return null else (y_px - @as(f64, @floatFromInt(seg.bounds.y))) / @as(f64, @floatFromInt(seg.bounds.h)),
    };
    if (!std.math.isFinite(raw)) return null;
    return @floatCast(raw);
}

/// 각 seg를 Rule op(선) 하나로 `out`에 emit한다(role=`.divider`). 세로선: (pos, bounds.y)→(pos, bounds.y+h);
/// 가로선: (bounds.x, pos)→(bounds.x+w, pos). platform이 이 Rule을 부분사각형 NativeMetalCell로 lower한다(얇은 선
/// — 셀 한 변 ~2px). segs 비면(단일 panel) 무동작. 순수: segs만 읽는다. out·op은 호출자 frame arena 소유.
pub fn view(segs: []const Seg, arena: std.mem.Allocator, out: *std.ArrayList(draw.Op)) !void {
    for (segs) |seg| {
        const pos_i: i32 = @intCast(seg.pos);
        const rule: draw.Op.Rule = switch (seg.orientation) {
            .vertical_line => .{
                .from = .{ .x = pos_i, .y = seg.bounds.y },
                .to = .{ .x = pos_i, .y = seg.bounds.y + @as(i32, @intCast(seg.bounds.h)) },
                .role = .divider,
            },
            .horizontal_line => .{
                .from = .{ .x = seg.bounds.x, .y = pos_i },
                .to = .{ .x = seg.bounds.x + @as(i32, @intCast(seg.bounds.w)), .y = pos_i },
                .role = .divider,
            },
        };
        try out.append(arena, .{ .rule = rule });
    }
}

// ── 테스트 ──────────────────────────────────────────────────────────────────────

test "divider hitTest: 세로선/가로선 밴드 안에서 index, 밖/빈 segs면 null" {
    const cw: u32 = 10;
    const ch: u32 = 16;
    const segs = [_]Seg{
        .{ .orientation = .vertical_line, .bounds = .{ .x = 0, .y = 0, .w = 100, .h = 200 }, .pos = 50 },
        .{ .orientation = .horizontal_line, .bounds = .{ .x = 0, .y = 0, .w = 200, .h = 100 }, .pos = 80 },
    };
    // 세로선(idx 0): x가 경계 50 ± (5+2)=7 안, y는 bounds 0..200.
    try std.testing.expectEqual(@as(?usize, 0), hitTest(&segs, cw, ch, 50, 100));
    try std.testing.expectEqual(@as(?usize, 0), hitTest(&segs, cw, ch, 57, 100)); // 밴드 경계
    try std.testing.expectEqual(@as(?usize, null), hitTest(&segs, cw, ch, 58, 100)); // x 밴드 밖
    try std.testing.expectEqual(@as(?usize, null), hitTest(&segs, cw, ch, 50, 200)); // y bounds 밖(>=200)
    // 가로선(idx 1): y가 경계 80 ± (8+2)=10 안, x는 bounds 0..200.
    try std.testing.expectEqual(@as(?usize, 1), hitTest(&segs, cw, ch, 100, 80));
    try std.testing.expectEqual(@as(?usize, null), hitTest(&segs, cw, ch, 100, 95)); // y 밴드 밖
    // 빈 segs(단일 panel)·셀 0·비유한.
    try std.testing.expectEqual(@as(?usize, null), hitTest(&.{}, cw, ch, 50, 100));
    try std.testing.expectEqual(@as(?usize, null), hitTest(&segs, 0, ch, 50, 100));
    try std.testing.expectEqual(@as(?usize, null), hitTest(&segs, cw, ch, std.math.inf(f64), 100));
}

test "divider dragRatio: normal 축 비율(중앙=0.5·범위 밖 raw·0크기 null)" {
    const vseg = Seg{ .orientation = .vertical_line, .bounds = .{ .x = 0, .y = 0, .w = 100, .h = 200 }, .pos = 50 };
    try std.testing.expectEqual(@as(?f32, 0.5), dragRatio(vseg, 50, 999));
    try std.testing.expectEqual(@as(?f32, 0.0), dragRatio(vseg, 0, 999));
    try std.testing.expectEqual(@as(?f32, 1.0), dragRatio(vseg, 100, 999)); // 클램프 전 raw(host가 clampRatio)
    const hseg = Seg{ .orientation = .horizontal_line, .bounds = .{ .x = 0, .y = 0, .w = 200, .h = 100 }, .pos = 80 };
    try std.testing.expectEqual(@as(?f32, 0.25), dragRatio(hseg, 999, 25));
    // 0 크기 분모 → null.
    const zero = Seg{ .orientation = .vertical_line, .bounds = .{ .x = 0, .y = 0, .w = 0, .h = 200 }, .pos = 0 };
    try std.testing.expectEqual(@as(?f32, null), dragRatio(zero, 50, 100));
}

test "divider view: seg마다 Rule op(세로/가로 좌표·role=divider)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.ArrayList(draw.Op) = .empty;

    const segs = [_]Seg{
        .{ .orientation = .vertical_line, .bounds = .{ .x = 10, .y = 20, .w = 100, .h = 200 }, .pos = 60 },
        .{ .orientation = .horizontal_line, .bounds = .{ .x = 10, .y = 20, .w = 100, .h = 200 }, .pos = 80 },
    };
    try view(&segs, arena, &out);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    // 세로선: (60,20)→(60,220), role=divider.
    try std.testing.expect(out.items[0] == .rule);
    try std.testing.expectEqual(@as(i32, 60), out.items[0].rule.from.x);
    try std.testing.expectEqual(@as(i32, 20), out.items[0].rule.from.y);
    try std.testing.expectEqual(@as(i32, 60), out.items[0].rule.to.x);
    try std.testing.expectEqual(@as(i32, 220), out.items[0].rule.to.y);
    try std.testing.expect(out.items[0].rule.role == .divider);
    // 가로선: (10,80)→(110,80).
    try std.testing.expectEqual(@as(i32, 10), out.items[1].rule.from.x);
    try std.testing.expectEqual(@as(i32, 80), out.items[1].rule.from.y);
    try std.testing.expectEqual(@as(i32, 110), out.items[1].rule.to.x);
    try std.testing.expectEqual(@as(i32, 80), out.items[1].rule.to.y);

    // 빈 segs면 무동작.
    out.clearRetainingCapacity();
    try view(&.{}, arena, &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}
