//! Divider — pane 분할 경계 선 + 드래그 hit-test. chrome **마우스 hit-test 컴포넌트의 첫 선례**.
//! notice/find/palette(키보드 오버레이, State+view+handle)와 달리, divider의 드래그 상태는 라이브 split-tree
//! 포인터(`*Split`)에 묶여 있어 그 상태는 platform이 든다(docs/layering-and-portability.md §6 — 라이브 트리 포인터는
//! neutral chrome 밖, freed 시 invalidate). 그래서 이 컴포넌트는 **State 없는 순수 함수 모듈**이다: host가
//! `PaneTree.layoutDividers` 결과를 중립 `Seg`로 변환 주입하면(palette `Row` 선례), hitTest(마우스→seg index)·
//! view(seg→Rule op 선)·dragRatio(마우스→비율)를 순수하게 계산한다. host 키보드 라우팅(ChromeHost.handleInput)을
//! 안 거친다(divider는 마우스). 단일 출처: docs/chrome-strategy.md §5.4, docs/layering-and-portability.md §5(C2).

const std = @import("std");
const draw = @import("../draw.zig");
const layout = @import("../ui/layout.zig");
const tree = @import("../ui/tree.zig");

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

/// 한 seg의 **드래그 밴드 rect** — normal 축은 경계 pos ± `hitHalfExtentPx`(잡기 쉽게 넓힌 폭),
/// 교차 축은 bounds 범위다. hit-test와 published capture rect가 이 하나에서 나오므로 "보이는 선 ==
/// 잡히는 선"에 더해 **"잡히는 rect == 발행된 rect"**도 성립한다. 셀 0이면 hit target이 없다(null).
pub fn bandRect(seg: Seg, cell_width_px: u32, cell_height_px: u32) ?layout.UiRect {
    if (cell_width_px == 0 or cell_height_px == 0) return null;
    const pos: f32 = @floatFromInt(seg.pos);
    const half: f32 = @floatCast(hitHalfExtentPx(seg.orientation, cell_width_px, cell_height_px));
    return switch (seg.orientation) {
        .vertical_line => .{
            .x = pos - half,
            .y = @floatFromInt(seg.bounds.y),
            .width = half * 2,
            .height = @floatFromInt(seg.bounds.h),
        },
        .horizontal_line => .{
            .x = @floatFromInt(seg.bounds.x),
            .y = pos - half,
            .width = @floatFromInt(seg.bounds.w),
            .height = half * 2,
        },
    };
}

fn bandContains(rect: layout.UiRect, x_px: f64, y_px: f64) bool {
    if (rect.width <= 0 or rect.height <= 0) return false;
    const x: f64 = rect.x;
    const y: f64 = rect.y;
    return x <= x_px and x_px < x + @as(f64, rect.width) and y <= y_px and y_px < y + @as(f64, rect.height);
}

/// 마우스 (x,y)가 어느 seg의 드래그 밴드 안인가 — 맞으면 그 index, 아니면 null. 밴드는 `bandRect`가
/// 소유하며 **half-open**이다(`[x, x+w)`): 발행된 capture rect가 쓰는 규칙과 같아야 두 경로가 같은
/// 점에서 같은 답을 낸다. 겹치는 밴드는 **낮은 index가 이긴다**. 셀 0·비유한이면 매치 없음.
/// 단일 panel(segs 빈)이면 항상 null. (옛 app_session.dividerHit 수학 이전.)
pub fn hitTest(segs: []const Seg, cell_width_px: u32, cell_height_px: u32, x_px: f64, y_px: f64) ?usize {
    if (!std.math.isFinite(x_px) or !std.math.isFinite(y_px)) return null;
    for (segs, 0..) |seg, i| {
        const rect = bandRect(seg, cell_width_px, cell_height_px) orelse return null;
        if (bandContains(rect, x_px, y_px)) return i;
    }
    return null;
}

pub const PublishError = error{InsufficientEntryBuffer};

/// segs를 pointer capture가 소비할 수 있는 `UiRectTree`로 발행한다 — CIM2.
///
/// divider는 `view`가 Rule op로 직접 그리므로 이 tree는 **paint가 아니라 hit/capture 전용**이다.
/// 각 entry는 `bandRect`(hit-test와 같은 출처)를 rect로 삼고, 자기 seg index를 action ID이자 drag
/// payload로 싣는다. host는 그 payload를 다시 live `*Split`으로 되돌린다 — chrome은 app 트리를 모른다.
///
/// **entry 순서가 뒤집혀 있다.** `interaction.hitAction`은 reverse z-order로 훑어 마지막 entry가
/// 이기는데, `hitTest`는 낮은 index가 이긴다. 밴드가 겹칠 때 두 경로가 다른 seg를 고르지 않도록
/// segs를 역순으로 싣는다.
///
/// threshold는 0이다. divider를 누른 것 자체가 resize 의사이고 경쟁할 click action이 없으므로,
/// 첫 move가 곧 resize여야 한다(계약 §4.3의 continuous resize).
pub fn publish(
    segs: []const Seg,
    cell_width_px: u32,
    cell_height_px: u32,
    generation: u64,
    out: []tree.RectEntry,
) PublishError!tree.UiRectTree {
    if (out.len < segs.len) return error.InsufficientEntryBuffer;
    var count: usize = 0;
    var remaining = segs.len;
    while (remaining > 0) {
        remaining -= 1;
        const rect = bandRect(segs[remaining], cell_width_px, cell_height_px) orelse continue;
        const identity: u64 = @intCast(remaining + 1);
        out[count] = .{
            .id = identity,
            .parent_index = null,
            .kind = .container,
            .rect = rect,
            .effective_clip = null,
            .action = .{ .id = identity },
            .drag = .{
                .payload = identity,
                .axis = switch (segs[remaining].orientation) {
                    .vertical_line => .horizontal,
                    .horizontal_line => .vertical,
                },
                .threshold_px = 0,
            },
        };
        count += 1;
    }
    return .{ .entries = out[0..count], .generation = generation };
}

/// 발행된 identity를 seg index로 되돌린다. `publish`가 쓰는 1-기반 규칙의 유일한 역함수다.
pub fn segIndexOf(identity: u64, seg_count: usize) ?usize {
    if (identity == 0 or identity > seg_count) return null;
    return @intCast(identity - 1);
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
    try std.testing.expectEqual(@as(?usize, 0), hitTest(&segs, cw, ch, 43, 100)); // 밴드 시작(포함)
    try std.testing.expectEqual(@as(?usize, 0), hitTest(&segs, cw, ch, 56.9, 100));
    // 밴드는 `bandRect`가 소유하는 half-open 구간 [43, 57)이다. 발행되는 capture rect와 같은
    // 규칙이라 두 경로가 같은 점에서 갈리지 않는다 — 예전엔 이 끝점 하나만 hit-test가 더 받았다.
    try std.testing.expectEqual(@as(?usize, null), hitTest(&segs, cw, ch, 57, 100));
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

test "published capture rects are the same geometry hit-test accepts" {
    const cw: u32 = 10;
    const ch: u32 = 16;
    const segs = [_]Seg{
        .{ .orientation = .vertical_line, .bounds = .{ .x = 0, .y = 0, .w = 100, .h = 200 }, .pos = 50 },
        .{ .orientation = .horizontal_line, .bounds = .{ .x = 0, .y = 0, .w = 200, .h = 100 }, .pos = 80 },
    };
    var storage: [4]tree.RectEntry = undefined;
    const published = try publish(&segs, cw, ch, 7, &storage);

    try std.testing.expectEqual(@as(usize, 2), published.entries.len);
    try std.testing.expectEqual(@as(u64, 7), published.generation);

    // 두 경로가 같은 점에서 같은 답을 낸다. 밴드 rect가 하나뿐이므로 여기서 갈릴 수가 없다.
    for (published.entries) |entry| {
        const index = segIndexOf(entry.id, segs.len).?;
        const rect = bandRect(segs[index], cw, ch).?;
        try std.testing.expectEqual(rect.x, entry.rect.x);
        try std.testing.expectEqual(rect.y, entry.rect.y);
        try std.testing.expectEqual(rect.width, entry.rect.width);
        try std.testing.expectEqual(rect.height, entry.rect.height);
        // drag 축은 선의 방향에서 나온다 — 세로선은 좌우로만 끌린다.
        const expected_axis: tree.DragAxis = switch (segs[index].orientation) {
            .vertical_line => .horizontal,
            .horizontal_line => .vertical,
        };
        try std.testing.expectEqual(expected_axis, entry.drag.?.axis);
        // divider를 누른 것이 곧 resize 의사다. threshold가 있으면 첫 move가 먹힌다.
        try std.testing.expectEqual(@as(f32, 0), entry.drag.?.threshold_px);
        try std.testing.expect(entry.action.?.enabled);
    }
}

test "overlapping bands resolve to the same seg in both paths" {
    const cw: u32 = 10;
    const ch: u32 = 16;
    // 두 세로선이 8px 떨어져 있어 밴드(각 ±7)가 겹친다.
    const segs = [_]Seg{
        .{ .orientation = .vertical_line, .bounds = .{ .x = 0, .y = 0, .w = 100, .h = 200 }, .pos = 50 },
        .{ .orientation = .vertical_line, .bounds = .{ .x = 0, .y = 0, .w = 100, .h = 200 }, .pos = 58 },
    };
    var storage: [4]tree.RectEntry = undefined;
    const published = try publish(&segs, cw, ch, 1, &storage);

    const x: f64 = 54; // 두 밴드 모두 안
    try std.testing.expectEqual(@as(?usize, 0), hitTest(&segs, cw, ch, x, 100));

    // `interaction.hitAction`은 reverse z-order로 훑어 **마지막** entry가 이긴다. 그래서 publish가
    // segs를 역순으로 싣지 않으면 겹치는 지점에서 두 경로가 다른 seg를 고른다.
    var winner: ?u64 = null;
    var index = published.entries.len;
    while (index > 0) {
        index -= 1;
        const entry = published.entries[index];
        const rect = entry.rect;
        if (rect.x <= x and x < rect.x + rect.width and rect.y <= 100 and 100 < rect.y + rect.height) {
            winner = entry.id;
            break;
        }
    }
    try std.testing.expectEqual(@as(?usize, 0), segIndexOf(winner.?, segs.len));
}

test "publish fails closed and drops segs that have no hit target" {
    const segs = [_]Seg{
        .{ .orientation = .vertical_line, .bounds = .{ .x = 0, .y = 0, .w = 100, .h = 200 }, .pos = 50 },
        .{ .orientation = .horizontal_line, .bounds = .{ .x = 0, .y = 0, .w = 200, .h = 100 }, .pos = 80 },
    };
    var small: [1]tree.RectEntry = undefined;
    // partial publish 대신 후보 자체가 실패한다 — 절반만 잡히는 divider를 내놓지 않는다.
    try std.testing.expectError(error.InsufficientEntryBuffer, publish(&segs, 10, 16, 1, &small));

    // 셀 0이면 hit target이 없다. 그 seg는 발행되지 않고, 남은 것들의 identity는 그대로다.
    var storage: [4]tree.RectEntry = undefined;
    const none = try publish(&segs, 0, 16, 1, &storage);
    try std.testing.expectEqual(@as(usize, 0), none.entries.len);

    // 단일 panel(segs 빈)은 빈 tree다 — capture 대상이 없다는 뜻이지 실패가 아니다.
    const empty = try publish(&.{}, 10, 16, 1, &storage);
    try std.testing.expectEqual(@as(usize, 0), empty.entries.len);

    // identity는 1-기반이고 그 역함수만 유효하다.
    try std.testing.expectEqual(@as(?usize, null), segIndexOf(0, 2));
    try std.testing.expectEqual(@as(?usize, 1), segIndexOf(2, 2));
    try std.testing.expectEqual(@as(?usize, null), segIndexOf(3, 2));
}
