//! PopupBox — **앵커에 붙는** 떠 있는 상자의 공유 기하 프리미티브(디자인 시스템).
//! `modal_box`가 **중앙** 모달에 하는 일을 앵커 팝업에 한다. 단일 출처: docs/chrome-strategy.md §5.4.
//!
//! **왜 뽑았나**: 우클릭 메뉴·설정 드롭다운·마커 이미지 프리뷰가 전부 "앵커에서 시작해 workspace 안으로
//! 당긴다"는 **같은 계산**을 각자 복사해 갖고 있었다. 세 번째 복사본을 만들려다 정리했다(2026-09-14).
//! 복사본이 늘면 「가장자리에 딱 붙이지 않는다」 같은 규칙이 한 곳에서만 고쳐져 나머지가 조용히 낡는다.
//!
//! 이 모듈은 **자리만** 정한다. 배경·테두리·콘텐츠는 각 컴포넌트가 그린다(`modal_box`가 `frame`/`text`를
//! 함께 주는 것과 다른 점 — 앵커 팝업은 콘텐츠 모양이 제각각이라 공유할 것이 기하뿐이다).

const std = @import("std");
const draw = @import("../draw.zig");
const props = @import("../props.zig");

/// 세로 배치 정책.
pub const Vertical = enum {
    /// 앵커 **위치에서** 시작한다(우클릭 메뉴 — 누른 자리에 좌상단을 둔다). 아래로 넘치면 당긴다.
    at_anchor,
    /// 앵커 **아래에** 둔다. 안 들어가면 **위로 뒤집고**, 그것도 안 되면 당긴다(이미지 프리뷰·드롭다운).
    below_flip_up,
};

pub const Placement = struct {
    /// 앵커 사각형. 점 앵커(우클릭)면 `w`/`h`가 0이다.
    anchor: draw.Rect,
    vertical: Vertical = .at_anchor,
    /// 앵커와 상자 사이 간격(px). `below_flip_up`에서 마커·control을 가리지 않게 띄운다.
    gap_px: u32 = 0,
    /// 앵커가 workspace **아래**(상태바 등)에 있는가.
    ///
    /// ⚠️ 이 플래그가 있는 이유가 실제 사고다 — 상태바는 창 전폭이고 workspace **밖**에 산다. 왼쪽
    /// 항목(브랜치·경로)은 사이드바 chrome이 아닌데도 x 범위만 보면 사이드바 안으로 판정돼, 좌단을
    /// `workspace.x`로 밀면 누른 자리와 뜬 자리가 화면 절반만큼 떨어진다(사용자 제보). 그 항목 위에는
    /// 덮을 사이드바 chrome이 애초에 없다.
    anchor_below_workspace: bool = false,
};

pub const Result = struct {
    rect: draw.Rect,
    /// 앵커 위로 뒤집혔나(`below_flip_up`에서만 참이 될 수 있다).
    flipped_up: bool = false,
};

/// 상자 크기(px)와 앵커로 자리를 정한다. workspace가 한 셀보다 좁으면 null.
///
/// **가장자리에 딱 붙이지 않는다.** 붙이면 그쪽 테두리가 창 경계와 겹쳐 안 보이고, 반대쪽만 둥근 모서리가
/// 보여 잘린 것처럼 읽힌다(상태바 우측 항목에 앵커한 팝오버에서 실측 — anchor 820 + box 384 > 960이라
/// 우단에 정확히 붙었다). 한 셀이면 테두리가 드러나기에 충분하다. 세로도 같은 이유로 띄운다.
pub fn place(box_w: u32, box_h: u32, pl: Placement, p: props.ChromeProps) ?Result {
    const m = p.metrics;
    const cw = @max(m.cell_width_px, 1);
    const ch = @max(m.cell_height_px, 1);
    const ws = props.workspaceRect(m);
    if (ws.w < cw or ws.h < ch) return null;

    const right_bound: i32 = @as(i32, @intCast(ws.x + ws.w)) - @as(i32, @intCast(cw));
    const bottom_bound: i32 = @as(i32, @intCast(ws.y + ws.h)) - @as(i32, @intCast(ch));
    const top_bound: i32 = @intCast(ws.y);
    // 좌단은 사이드바 오른쪽으로 — 팝업은 터미널 영역 오버레이라 사이드바 chrome 위로 겹치지 않게 한다.
    // 단 앵커가 workspace 아래(상태바)면 그 규칙을 쓰지 않는다(위 `anchor_below_workspace` 주석).
    const left_bound: i32 = if (pl.anchor_below_workspace) @intCast(cw) else @intCast(ws.x);

    const bw: i32 = @intCast(box_w);
    const bh: i32 = @intCast(box_h);

    var flipped = false;
    var y: i32 = switch (pl.vertical) {
        .at_anchor => pl.anchor.y,
        .below_flip_up => pl.anchor.y + @as(i32, @intCast(pl.anchor.h)) + @as(i32, @intCast(pl.gap_px)),
    };
    if (y + bh > bottom_bound) {
        if (pl.vertical == .below_flip_up) {
            const up = pl.anchor.y - bh - @as(i32, @intCast(pl.gap_px));
            if (up >= top_bound) {
                y = up;
                flipped = true;
            } else {
                y = bottom_bound - bh;
            }
        } else {
            y = bottom_bound - bh;
        }
    }
    if (y < top_bound) y = top_bound;

    var x: i32 = pl.anchor.x;
    if (x + bw > right_bound) x = right_bound - bw;
    if (x < left_bound) x = left_bound;

    return .{ .rect = .{ .x = x, .y = y, .w = box_w, .h = box_h }, .flipped_up = flipped };
}

const testing = std.testing;

fn metricsOf(w: u32, h: u32) props.ChromeProps {
    return .{ .metrics = .{
        .cell_width_px = 8,
        .cell_height_px = 16,
        .sidebar_width_px = 0,
        .backing_width_px = w,
        .backing_height_px = h,
        .workspace_present = true,
        .workspace_x_px = 0,
        .workspace_y_px = 0,
        .workspace_width_px = w,
        .workspace_height_px = h,
    } };
}

test "CSP1 popup_box: 우단에 딱 붙이지 않는다 — 한 셀을 띄운다" {
    const p = metricsOf(960, 600);
    const r = place(384, 100, .{ .anchor = .{ .x = 820, .y = 100, .w = 0, .h = 0 } }, p) orelse
        return error.TestUnexpectedResult;
    try testing.expect(r.rect.x + 384 <= 960 - 8);
}

test "CSP1 popup_box: 좌단을 사이드바 오른쪽으로 민다" {
    var p = metricsOf(1000, 600);
    p.metrics.sidebar_width_px = 200;
    p.metrics.workspace_x_px = 200;
    p.metrics.workspace_width_px = 800;
    const r = place(400, 100, .{ .anchor = .{ .x = 10, .y = 50, .w = 0, .h = 0 } }, p) orelse
        return error.TestUnexpectedResult;
    try testing.expectEqual(@as(i32, 200), r.rect.x);
}

test "CSP1 popup_box: 상태바 앵커는 사이드바로 밀지 않는다 — 누른 자리에 뜬다" {
    var p = metricsOf(1000, 600);
    p.metrics.sidebar_width_px = 200;
    p.metrics.workspace_x_px = 200;
    p.metrics.workspace_width_px = 800;
    p.metrics.workspace_height_px = 560; // 상태바가 아래 40px
    const r = place(300, 100, .{
        .anchor = .{ .x = 16, .y = 580, .w = 0, .h = 0 },
        .anchor_below_workspace = true,
    }, p) orelse return error.TestUnexpectedResult;
    try testing.expect(r.rect.x < 200); // 사이드바 오른쪽으로 안 밀렸다
    try testing.expectEqual(@as(i32, 16), r.rect.x); // 누른 자리 그대로 — clamp 가 안 걸린다
}

test "CSP1 popup_box: below_flip_up 은 아래가 모자라면 위로 뒤집는다" {
    const p = metricsOf(1000, 600);
    const r = place(200, 200, .{
        .anchor = .{ .x = 100, .y = 540, .w = 80, .h = 16 },
        .vertical = .below_flip_up,
        .gap_px = 2,
    }, p) orelse return error.TestUnexpectedResult;
    try testing.expect(r.flipped_up);
    try testing.expect(r.rect.y + 200 <= 540);
}

test "CSP1 popup_box: at_anchor 는 뒤집지 않고 당긴다(우클릭 메뉴)" {
    const p = metricsOf(1000, 600);
    const r = place(200, 200, .{ .anchor = .{ .x = 100, .y = 540, .w = 0, .h = 0 } }, p) orelse
        return error.TestUnexpectedResult;
    try testing.expect(!r.flipped_up);
    try testing.expectEqual(@as(i32, 600 - 16 - 200), r.rect.y);
}

test "CSP1 popup_box: 위로도 아래로도 안 들어가면 당기고 마커를 안 덮는다는 보장은 없다" {
    const p = metricsOf(1000, 300);
    const r = place(200, 250, .{
        .anchor = .{ .x = 100, .y = 200, .w = 80, .h = 16 },
        .vertical = .below_flip_up,
    }, p) orelse return error.TestUnexpectedResult;
    try testing.expect(!r.flipped_up); // 위로 뒤집으면 top_bound 를 넘는다 → 당기기
    try testing.expect(r.rect.y >= 0);
}

test "CSP1 popup_box: workspace 가 한 셀보다 좁으면 null" {
    const p = metricsOf(4, 4);
    try testing.expect(place(10, 10, .{ .anchor = .{ .x = 0, .y = 0, .w = 0, .h = 0 } }, p) == null);
}
