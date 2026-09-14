//! 터미널 마커 이미지 프리뷰의 **떠 있는 상자** — 계약은
//! [docs/agent-image-marker-preview.md](../../../docs/agent-image-marker-preview.md) §2.3·§2.4가 소유한다.
//!
//! **pane의 자식이 아니라 팝오버다.** `context_menu`가 pane을 아예 모르고 workspace로 clamp하는 것과
//! 같은 부류다 — 마커가 좁은 pane에 있어도 프리뷰는 옆 pane 위로 떠서 읽을 수 있는 크기를 가진다.
//! 그래서 이 모듈은 pane rect를 **입력으로 받지 않는다**(받을 수 있게 두면 언젠가 누가 쓴다).
//!
//! 이 모듈은 **자리와 크기만** 정한다. 픽셀은 `MaruAppHostGpuImage`가 그리고(갤러리 §5.4 분업),
//! 테두리·라벨은 호출자가 chrome `Op`로 그린다.

const std = @import("std");
const draw = @import("../draw.zig");
const props = @import("../props.zig");
const popup_box = @import("popup_box.zig"); // 앵커 팝업 기하 공유 프리미티브(§5.4)

/// 프리뷰가 차지할 자리. `image`는 그림이 들어갈 안쪽 사각형(테두리 제외)이다.
pub const Placement = struct {
    /// 테두리를 포함한 바깥 상자.
    box: draw.Rect,
    /// 그림이 들어갈 안쪽 사각형 — `gpu_images`의 dest가 이 값이다.
    image: draw.Rect,
    /// 원본 대비 배율(≤ 1.0). 진단·테스트용.
    scale: f32,
    /// 앵커 위로 뒤집혔나. 입력창이 화면 하단이라 **실전의 기본 경로**다(§2.4).
    flipped_up: bool,
};

/// 테두리 두께(셀 기준이 아니라 고정 px) — chrome이 그리는 선 한 겹.
pub const border_px: u32 = 1;

/// 그림과 테두리 사이 여백.
pub const padding_px: u32 = 4;

/// 앵커(마커) 줄과 상자 사이 간격. 마커를 가리지 않도록 한 줄 띄운다.
pub const anchor_gap_px: u32 = 2;

/// 프리뷰 자리를 정한다. `anchor`는 **마커 span의 화면 사각형**(셀 → px 변환은 호출자 몫)이고,
/// `img_w`/`img_h`는 원본 픽셀 크기다. 그릴 수 없으면 null(원본이 0이거나 workspace가 너무 작다).
///
/// 규칙은 §2.3·§2.4다 — workspace의 절반을 넘지 않고, 1.0을 넘겨 늘리지 않으며, 아래로 넘치면 위로
/// 뒤집고, 좌우는 `context_menu.menuRect`와 같은 `edge_gap`을 두고 민다.
pub fn place(
    anchor: draw.Rect,
    img_w: u32,
    img_h: u32,
    p: props.ChromeProps,
) ?Placement {
    if (img_w == 0 or img_h == 0) return null;
    const m = p.metrics;
    const ws = props.workspaceRect(m);
    if (ws.w == 0 or ws.h == 0) return null;

    const chrome_w = 2 * (border_px + padding_px);
    const chrome_h = 2 * (border_px + padding_px);
    // 쓸 수 있는 최대 그림 크기 — workspace의 절반에서 테두리를 뺀다. 절반 규칙(§2.3)은 **pane이 아니라
    // workspace 기준**이라, 좁은 pane에 있는 마커도 읽을 수 있는 프리뷰를 얻는다.
    const avail_w = (ws.w / 2) -| chrome_w;
    const avail_h = (ws.h / 2) -| chrome_h;
    if (avail_w == 0 or avail_h == 0) return null;

    // **1.0을 넘겨 늘리지 않는다.** 작은 이미지를 흐리게 키우면 「원본 확인」이 거짓말이 된다(갤러리 §2).
    var scale: f32 = 1.0;
    scale = @min(scale, @as(f32, @floatFromInt(avail_w)) / @as(f32, @floatFromInt(img_w)));
    scale = @min(scale, @as(f32, @floatFromInt(avail_h)) / @as(f32, @floatFromInt(img_h)));
    if (!(scale > 0)) return null;

    const draw_w: u32 = @max(1, @as(u32, @intFromFloat(@round(@as(f32, @floatFromInt(img_w)) * scale))));
    const draw_h: u32 = @max(1, @as(u32, @intFromFloat(@round(@as(f32, @floatFromInt(img_h)) * scale))));
    const box_w = draw_w + chrome_w;
    const box_h = draw_h + chrome_h;

    // 자리는 **공유 프리미티브**가 정한다(`popup_box`) — 우클릭 메뉴와 같은 clamp 를 쓴다(§5.4).
    // 세로는 `below_flip_up`: 입력창이 화면 하단이라 **위로 뒤집히는 쪽이 실전의 기본 경로**다.
    const placed = popup_box.place(box_w, box_h, .{
        .anchor = anchor,
        .vertical = .below_flip_up,
        .gap_px = anchor_gap_px,
    }, p) orelse return null;
    const x = placed.rect.x;
    const y = placed.rect.y;

    const inner: i32 = @intCast(border_px + padding_px);
    return .{
        .box = placed.rect,
        .image = .{ .x = x + inner, .y = y + inner, .w = draw_w, .h = draw_h },
        .scale = scale,
        .flipped_up = placed.flipped_up,
    };
}

const testing = std.testing;

fn metricsOf(ws_w: u32, ws_h: u32) props.ChromeProps {
    return .{ .metrics = .{
        .cell_width_px = 8,
        .cell_height_px = 16,
        .sidebar_width_px = 0,
        .backing_width_px = ws_w,
        .backing_height_px = ws_h,
        .workspace_present = true,
        .workspace_x_px = 0,
        .workspace_y_px = 0,
        .workspace_width_px = ws_w,
        .workspace_height_px = ws_h,
    } };
}

test "MP1 배치: workspace 절반을 넘지 않게 줄인다" {
    const p = metricsOf(1000, 800);
    const pl = place(.{ .x = 100, .y = 100, .w = 80, .h = 16 }, 2000, 1000, p) orelse return error.TestUnexpectedResult;
    try testing.expect(pl.image.w <= 1000 / 2);
    try testing.expect(pl.image.h <= 800 / 2);
    try testing.expect(pl.scale < 1.0);
}

test "MP1 배치: 작은 그림을 늘리지 않는다 — 배율 상한 1.0" {
    const p = metricsOf(1000, 800);
    const pl = place(.{ .x = 100, .y = 100, .w = 80, .h = 16 }, 40, 30, p) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(f32, 1.0), pl.scale);
    try testing.expectEqual(@as(u32, 40), pl.image.w);
    try testing.expectEqual(@as(u32, 30), pl.image.h);
}

test "MP1 배치: 아래로 안 들어가면 위로 뒤집는다 (입력창이 하단이라 실전 기본 경로)" {
    const p = metricsOf(1000, 800);
    // 마커가 화면 맨 아래 근처 — 아래로는 상자가 안 들어간다.
    const pl = place(.{ .x = 100, .y = 760, .w = 80, .h = 16 }, 200, 200, p) orelse return error.TestUnexpectedResult;
    try testing.expect(pl.flipped_up);
    try testing.expect(pl.box.y + @as(i32, @intCast(pl.box.h)) <= 760);
}

test "MP1 배치: 오른쪽으로 넘치면 workspace 안으로 민다 — 가장자리에 딱 붙지 않는다" {
    const p = metricsOf(1000, 800);
    const pl = place(.{ .x = 950, .y = 100, .w = 40, .h = 16 }, 400, 200, p) orelse return error.TestUnexpectedResult;
    const right = pl.box.x + @as(i32, @intCast(pl.box.w));
    try testing.expect(right <= 1000 - 8); // edge_gap = cell_width
}

test "MP1 배치: 사이드바 왼쪽으로는 안 간다 — workspace.x 가 좌단이다" {
    var p = metricsOf(1000, 800);
    p.metrics.sidebar_width_px = 200;
    p.metrics.workspace_x_px = 200;
    p.metrics.workspace_width_px = 800;
    const pl = place(.{ .x = 210, .y = 100, .w = 40, .h = 16 }, 700, 200, p) orelse return error.TestUnexpectedResult;
    try testing.expect(pl.box.x >= 200 + 8);
}

test "MP1 배치: 좁은 pane 이어도 크기가 안 줄어든다 — pane 을 아예 안 본다(옛 M7)" {
    // pane rect 를 받지 않으므로 같은 workspace 면 결과가 같다. 좁은 pane 의 마커(x가 사이드바 바로 옆)여도
    // 그림 크기는 workspace 기준이다.
    const p = metricsOf(1000, 800);
    const narrow = place(.{ .x = 10, .y = 100, .w = 80, .h = 16 }, 2000, 1000, p) orelse return error.TestUnexpectedResult;
    const wide = place(.{ .x = 600, .y = 100, .w = 80, .h = 16 }, 2000, 1000, p) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(narrow.image.w, wide.image.w);
    try testing.expectEqual(narrow.image.h, wide.image.h);
}

test "MP1 배치: 원본이 0이거나 workspace 가 없으면 null" {
    const p = metricsOf(1000, 800);
    try testing.expect(place(.{ .x = 0, .y = 0, .w = 10, .h = 16 }, 0, 100, p) == null);
    try testing.expect(place(.{ .x = 0, .y = 0, .w = 10, .h = 16 }, 100, 0, p) == null);
    const tiny = metricsOf(4, 4);
    try testing.expect(place(.{ .x = 0, .y = 0, .w = 10, .h = 16 }, 100, 100, tiny) == null);
}

test "MP1 배치: 그림 사각형이 상자 안에 있다 — 테두리·패딩만큼 들어간다" {
    const p = metricsOf(1000, 800);
    const pl = place(.{ .x = 100, .y = 100, .w = 80, .h = 16 }, 200, 150, p) orelse return error.TestUnexpectedResult;
    try testing.expect(pl.image.x > pl.box.x);
    try testing.expect(pl.image.y > pl.box.y);
    try testing.expect(pl.image.x + @as(i32, @intCast(pl.image.w)) < pl.box.x + @as(i32, @intCast(pl.box.w)));
    try testing.expect(pl.image.y + @as(i32, @intCast(pl.image.h)) < pl.box.y + @as(i32, @intCast(pl.box.h)));
}
