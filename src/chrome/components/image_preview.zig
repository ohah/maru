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
const tokens = @import("../tokens.zig");
const overlay_input = @import("overlay_input.zig"); // displayCols(EAW 표시폭) 단일 출처

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

/// 테두리 두께(고정 px).
///
/// **한 겹으로는 팝업인 줄 모른다(사용자 제보 2026-09-14).** 터미널 배경 위에 그림만 뜨면 «출력의
/// 일부»로 읽힌다 — 떠 있는 것이라는 신호가 필요하다. 두께와 여백을 함께 키워 테를 만든다.
pub const border_px: u32 = 3;

/// 그림과 테두리 사이 여백.
///
/// **0이다 — 다만 이제는 제약이 아니라 선택이다.** 한때는 그 영역을 채울 자리가 렌더 순서에 없어
/// 0일 수밖에 없었는데(셀보다 위·이미지보다 아래인 quad 패스가 없었다), 2026-09-15 에 그 패스를
/// 열었다(`metal_frame.quad_layer.image_backdrop`). 여백을 주고 싶으면 이제 줄 수 있고, 뒤판이
/// 그 영역을 불투명하게 채운다. 지금 0 인 것은 액자를 얇게 두는 **시각 결정**이다.
pub const padding_px: u32 = 0;

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

/// 이 상자가 그리는 레이어. **pane 오버레이**다 — 모달이 아니므로 입력을 막지 않는다(§2.2에서
/// hover가 아니라 명시 제스처를 고른 것과 같은 결: 프리뷰는 터미널을 잠그지 않는다).
pub const layer = draw.Layer.pane_overlay;

/// 프리뷰 상자의 **테두리와 배경**을 그린다. 그림 픽셀은 `gpu_images`가 따로 싣는다(갤러리 §5.4 분업) —
/// 여기서 그리는 것은 그 픽셀이 놓일 자리의 테두리뿐이다.
///
/// `notice`가 있으면 그림 대신 그 문구를 가운데에 적는다(디코드 실패 — §2.3). 문구는 **호출자가 i18n에서
/// 골라 넘긴다**: 컴포넌트는 `ui.language`를 모르고, 그래야 번역이 두 군데로 흩어지지 않는다.
pub fn view(
    pl: Placement,
    notice: ?[]const u8,
    p: props.ChromeProps,
    tk: *const tokens.Tokens,
    arena: std.mem.Allocator,
    out: *std.ArrayList(draw.Op),
) !void {
    _ = tk;
    const r = p.shape.corner_radius_px;
    const bw = p.shape.border_width_px;
    try out.append(arena, .{ .quad = .{
        .rect = pl.box,
        .fill_role = .surface_bg,
        .corner_radii = .{ r, r, r, r },
        .border_widths = .{ bw, bw, bw, bw },
        .border_role = .focus_accent,
    } });
    const text = notice orelse return;
    const cw = @max(p.metrics.cell_width_px, 1);
    const ch = @max(p.metrics.cell_height_px, 1);
    const cols = overlay_input.displayCols(text);
    const text_w = cols * cw;
    const x = pl.box.x + @divTrunc(@as(i32, @intCast(pl.box.w)) - @as(i32, @intCast(text_w)), 2);
    const y = pl.box.y + @divTrunc(@as(i32, @intCast(pl.box.h)) - @as(i32, @intCast(ch)), 2);
    const runs = try arena.alloc(draw.Run, 1);
    runs[0] = .{ .text = text };
    try out.append(arena, .{ .text = .{
        .origin = .{ .x = x, .y = y },
        .runs = runs,
        .role = .muted_fg,
    } });
}

/// 「도크에서 보기」 과녁 판정 — 이 클릭이 갤러리 크게 보기로 점프하는가, 그렇다면 몇 번째인가.
///
/// `sent_hit_index` 는 **전송된** 마커면 갤러리 인덱스의 순번이고, 전송 전(스테이징)이면 null 이다.
///
/// ⚠️ **전송 전에는 점프가 없다**(agent-image-marker-preview.md §2.3). 아직 트랜스크립트에 없어
/// 자리가 존재하지 않는다 — 갤러리의 소스는 트랜스크립트뿐이라는 계약(§3.1)을 이 기능이 깨지
/// 않는다. 그 갈래가 없으면 「빈 갤러리로 점프」라는 더 나쁜 화면이 나온다.
///
/// **상자 전체가 과녁이다.** 모서리 표식만 누르게 하면 3 px 테두리 안쪽 12 px 사각형을 맞혀야
/// 하는데 그 정밀도를 요구할 이유가 없다 — 표식은 **있다는 것을 알리는 것**이지 과녁이 아니다.
///
/// 비유한 좌표·빈 상자 가드는 `dropdown.hitTest` 와 같은 자리다(포인터 좌표는 플랫폼발 f64 다).
pub fn dockJumpTarget(sent_hit_index: ?usize, box: draw.Rect, x_px: f64, y_px: f64) ?usize {
    const hit_index = sent_hit_index orelse return null;
    if (!std.math.isFinite(x_px) or !std.math.isFinite(y_px)) return null;
    if (box.w == 0 or box.h == 0) return null;
    const x0: f64 = @floatFromInt(box.x);
    const y0: f64 = @floatFromInt(box.y);
    const w: f64 = @floatFromInt(box.w);
    const h: f64 = @floatFromInt(box.h);
    if (x_px < x0 or x_px >= x0 + w or y_px < y0 or y_px >= y0 + h) return null;
    return hit_index;
}

/// 「도크에서 보기」 모서리 표식의 한 변(px). 테두리 두께의 배수라 테두리와 **이어진 덩어리**로
/// 읽힌다 — 흔한 「모서리 접힘 = 더 볼 것이 있다」 관용구다.
///
/// ⚠️ **글자를 쓸 수 없어 표식이다.** 라벨을 넣으려면 `gpu_glyphs` 에 실어야 하는데 그것은 **매
/// 프레임 비워지고 chrome draws 조립부가 채우며, 그 조립부는 매 프레임 돌지 않는다** — 테두리가
/// 「Cmd 를 떼면 사라지던」 바로 그 결함의 원인이다(§11.3). 이 화면이 매 프레임 낼 수 있는 것은
/// quad 뿐이고, 표식은 **그 제약의 결과이지 디자인 선택이 아니다.**
pub const dock_jump_mark_px: u32 = border_px * 4;

/// 이 상자에 모서리 표식을 그릴 자리가 있는가.
///
/// **없으면 안 그린다.** 표식이 테두리를 먹으면 액자가 뭉개져 「팝업이라는 신호」(`border_px` 주석)
/// 자체가 약해진다 — 작은 그림에서는 표식보다 액자가 중요하다.
///
/// ⚠️ **배선에 `if` 로 묻어 두면 아무도 못 본다**(적대 6회차에 뺐다). 조건이 순수하면 판정자가
/// 「어느 크기에서 갈리는가」를 값으로 물을 수 있다.
pub fn dockMarkFits(box_w: u32, box_h: u32) bool {
    const need = 2 * border_px + dock_jump_mark_px;
    return box_w > need and box_h > need;
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

test "MP1 도크 점프: 표식은 자리가 있을 때만 — 작은 상자에서는 액자가 이긴다" {
    // 필요 크기 = 테두리 양쪽(3+3) + 표식 한 변(12) = 18. **넘어야** 그린다(같으면 테두리에 닿는다).
    try std.testing.expect(!dockMarkFits(18, 100));
    try std.testing.expect(!dockMarkFits(100, 18));
    try std.testing.expect(dockMarkFits(19, 19));
    try std.testing.expect(!dockMarkFits(0, 0));
}

test "MP1 도크 점프: 전송된 프리뷰의 상자 안을 누르면 그 hit_index 를 낸다" {
    const box: draw.Rect = .{ .x = 100, .y = 200, .w = 300, .h = 150 };
    try std.testing.expectEqual(@as(?usize, 4), dockJumpTarget(4, box, 100, 200)); // 좌상 모서리 포함
    try std.testing.expectEqual(@as(?usize, 4), dockJumpTarget(4, box, 250, 275)); // 한가운데
    try std.testing.expectEqual(@as(?usize, 4), dockJumpTarget(4, box, 399, 349)); // 우하 마지막 픽셀
}

test "MP1 도크 점프: 전송 «전» 은 점프가 없다 — 트랜스크립트에 자리가 없다" {
    const box: draw.Rect = .{ .x = 100, .y = 200, .w = 300, .h = 150 };
    try std.testing.expectEqual(@as(?usize, null), dockJumpTarget(null, box, 250, 275));
}

test "MP1 도크 점프: 상자 «밖» 은 답하지 않는다 — 네 변을 다 민다" {
    const box: draw.Rect = .{ .x = 100, .y = 200, .w = 300, .h = 150 };
    try std.testing.expectEqual(@as(?usize, null), dockJumpTarget(0, box, 99, 275)); // 왼쪽 한 픽셀 밖
    try std.testing.expectEqual(@as(?usize, null), dockJumpTarget(0, box, 400, 275)); // 오른쪽 경계(반열림)
    try std.testing.expectEqual(@as(?usize, null), dockJumpTarget(0, box, 250, 199)); // 위
    try std.testing.expectEqual(@as(?usize, null), dockJumpTarget(0, box, 250, 350)); // 아래 경계(반열림)
}

test "MP1 도크 점프: 비유한 좌표와 빈 상자는 답하지 않는다" {
    const box: draw.Rect = .{ .x = 100, .y = 200, .w = 300, .h = 150 };
    try std.testing.expectEqual(@as(?usize, null), dockJumpTarget(2, box, std.math.nan(f64), 275));
    try std.testing.expectEqual(@as(?usize, null), dockJumpTarget(2, box, 250, std.math.inf(f64)));
    const empty: draw.Rect = .{ .x = 100, .y = 200, .w = 0, .h = 150 };
    try std.testing.expectEqual(@as(?usize, null), dockJumpTarget(2, empty, 100, 275));
}

test "MP1 도크 점프: hit_index 0 도 «있다» 로 답한다 — optional 을 0 으로 접지 않는다" {
    // 첫 이미지가 0 번이다. `?usize` 를 `usize` 로 접고 0 을 「없음」으로 쓰면 **첫 장만 점프가
    // 안 되는** 결함이 되고, 그건 화면에서 「가끔 안 된다」로 보인다.
    const box: draw.Rect = .{ .x = 0, .y = 0, .w = 10, .h = 10 };
    try std.testing.expectEqual(@as(?usize, 0), dockJumpTarget(0, box, 5, 5));
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

test "MP1 view: 테두리 상자를 그리고, 안내가 있으면 가운데에 적는다" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const p = metricsOf(1000, 800);
    const pl = place(.{ .x = 100, .y = 100, .w = 80, .h = 16 }, 200, 150, p) orelse return error.TestUnexpectedResult;
    const Rgb = @import("../../color.zig").Rgb;
    const tk = tokens.Tokens{ .palette = std.EnumArray(tokens.ColorRole, Rgb).initFill(.{ .r = 0, .g = 0, .b = 0 }) };

    var ops: std.ArrayList(draw.Op) = .empty;
    try view(pl, null, p, &tk, arena, &ops);
    try testing.expectEqual(@as(usize, 1), ops.items.len); // 상자만

    var ops2: std.ArrayList(draw.Op) = .empty;
    try view(pl, "열 수 없습니다", p, &tk, arena, &ops2);
    try testing.expectEqual(@as(usize, 2), ops2.items.len); // 상자 + 문구
    try testing.expect(ops2.items[1].text.origin.x > pl.box.x);
}
