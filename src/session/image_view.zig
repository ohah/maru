//! 이미지 **크게 보기**의 팬·줌 계산 — 계약 [docs/agent-image-gallery.md](../../docs/agent-image-gallery.md) §2.
//!
//! `image_grid` 와 같은 규율이다: 순수 계산이고 픽셀도 텍스처도 모른다. 돌려주는 것은 «이 이미지를
//! 어느 사각형에 그리는가» 하나뿐이라, 화면 없이 시험할 수 있고 **그린 자리와 눌리는 자리가 갈라지지
//! 않는다**.
//!
//! 격자(`image_grid`)와 나누는 이유는 좌표계가 다르기 때문이다 — 격자는 정수 칸이고, 여기는 연속적인
//! 배율과 오프셋이다. 정수로 하면 확대할수록 어긋남이 눈에 띈다.

const std = @import("std");

pub const Rect = struct { x: f32, y: f32, w: f32, h: f32 };

/// 볼 수 있는 최대 배율. 1 px 을 8 px 로 늘리는 선에서 멈춘다 — 그 위로는 보이는 것이 늘지 않고
/// 텍스처 필터링만 커진다.
pub const max_zoom: f32 = 8.0;

/// 보기 상태. **`scale == 0` 은 「아직 안 정했다」**로, `clamp` 가 fit 으로 채운다 — 열자마자
/// 전체가 보이는 것이 기본이다.
pub const View = struct {
    scale: f32 = 0,
    /// 가운데 정렬에서 얼마나 밀렸는가(backing px). 화면 좌표계라 오른쪽·아래가 +.
    pan_x: f32 = 0,
    pan_y: f32 = 0,
};

/// 이미지 전체가 뷰포트에 들어가는 배율. **1 을 넘지 않는다** — 작은 이미지를 열었다고 흐릿하게
/// 늘려 놓으면 원본을 확인하러 온 사람에게 거짓말이 된다. 확대는 사용자가 하는 것이다.
pub fn fitScale(vp: Rect, img_w: u32, img_h: u32) f32 {
    if (img_w == 0 or img_h == 0 or vp.w <= 0 or vp.h <= 0) return 0;
    const sx = vp.w / @as(f32, @floatFromInt(img_w));
    const sy = vp.h / @as(f32, @floatFromInt(img_h));
    return @min(@min(sx, sy), 1.0);
}

/// 이 이미지에서 허용하는 배율 범위. 아래는 fit(전체보기보다 더 줄일 이유가 없다), 위는 `max_zoom`.
/// **fit 이 `max_zoom` 보다 클 수는 없다**(fit ≤ 1) — 그래도 `@max` 로 뒤집히지 않게 못박는다.
pub fn scaleRange(vp: Rect, img_w: u32, img_h: u32) struct { min: f32, max: f32 } {
    const fit = fitScale(vp, img_w, img_h);
    return .{ .min = fit, .max = @max(fit, max_zoom) };
}

/// 상태를 허용 범위 안으로 되돌린다. **모든 입력의 마지막 단계**다 — 여기를 거치지 않은 상태를
/// 그리면 이미지가 뷰포트 밖으로 사라지고 사용자가 되돌릴 방법이 없어진다.
///
/// 배율이 작아 내용이 뷰포트보다 작으면 그 축의 팬은 **0 으로 되돌린다**(가운데 고정). 여백을 밀어
/// 놓을 수 있게 하면 「왜 안 보이지」가 된다.
pub fn clamp(v: View, vp: Rect, img_w: u32, img_h: u32) View {
    const r = scaleRange(vp, img_w, img_h);
    if (r.min <= 0) return .{ .scale = 0, .pan_x = 0, .pan_y = 0 };

    var out = v;
    if (!(out.scale > 0)) out.scale = r.min; // NaN 도 여기서 fit 으로 떨어진다
    out.scale = std.math.clamp(out.scale, r.min, r.max);

    const cw = @as(f32, @floatFromInt(img_w)) * out.scale;
    const ch = @as(f32, @floatFromInt(img_h)) * out.scale;
    out.pan_x = clampAxis(out.pan_x, vp.w, cw);
    out.pan_y = clampAxis(out.pan_y, vp.h, ch);
    return out;
}

fn clampAxis(pan: f32, view_len: f32, content_len: f32) f32 {
    if (!(pan == pan)) return 0; // NaN
    if (content_len <= view_len) return 0;
    const limit = (content_len - view_len) / 2;
    return std.math.clamp(pan, -limit, limit);
}

/// 이 상태로 그릴 사각형. `clamp` 를 먼저 통과시킨 상태를 넣는다.
pub fn destRect(v: View, vp: Rect, img_w: u32, img_h: u32) Rect {
    const c = clamp(v, vp, img_w, img_h);
    if (c.scale <= 0) return .{ .x = vp.x, .y = vp.y, .w = 0, .h = 0 };
    const cw = @as(f32, @floatFromInt(img_w)) * c.scale;
    const ch = @as(f32, @floatFromInt(img_h)) * c.scale;
    return .{
        .x = vp.x + (vp.w - cw) / 2 + c.pan_x,
        .y = vp.y + (vp.h - ch) / 2 + c.pan_y,
        .w = cw,
        .h = ch,
    };
}

/// 한 점을 붙잡은 채 배율을 곱한다. **커서 밑의 픽셀이 커서 밑에 남는다** — 가운데 기준으로 확대하면
/// 보려던 곳이 화면 밖으로 밀려나 사용자가 매번 팬으로 쫓아가야 한다.
///
/// 배율이 범위에 걸려 실제로 안 바뀌면 팬도 그대로다(안 그러면 한계에서 그림이 슬금슬금 밀린다).
pub fn zoomAt(v: View, vp: Rect, img_w: u32, img_h: u32, factor: f32, anchor_x: f32, anchor_y: f32) View {
    const cur = clamp(v, vp, img_w, img_h);
    if (cur.scale <= 0 or !(factor > 0)) return cur;
    const r = scaleRange(vp, img_w, img_h);
    const next_scale = std.math.clamp(cur.scale * factor, r.min, r.max);
    if (next_scale == cur.scale) return cur;

    const before = destRect(cur, vp, img_w, img_h);
    // 붙잡은 점이 이미지의 어디인가(원본 px). 확대 뒤에도 같은 화면 좌표에 오게 팬을 다시 푼다.
    const u = (anchor_x - before.x) / cur.scale;
    const w = (anchor_y - before.y) / cur.scale;

    const cw = @as(f32, @floatFromInt(img_w)) * next_scale;
    const ch = @as(f32, @floatFromInt(img_h)) * next_scale;
    const want_x = anchor_x - u * next_scale;
    const want_y = anchor_y - w * next_scale;
    return clamp(.{
        .scale = next_scale,
        .pan_x = want_x - vp.x - (vp.w - cw) / 2,
        .pan_y = want_y - vp.y - (vp.h - ch) / 2,
    }, vp, img_w, img_h);
}

/// 드래그로 민다. 화면 이동량 그대로다 — 배율로 나누지 않는다(잡은 곳이 손끝을 따라와야 한다).
pub fn panBy(v: View, vp: Rect, img_w: u32, img_h: u32, dx: f32, dy: f32) View {
    const cur = clamp(v, vp, img_w, img_h);
    return clamp(.{ .scale = cur.scale, .pan_x = cur.pan_x + dx, .pan_y = cur.pan_y + dy }, vp, img_w, img_h);
}

const testing = std.testing;
const vp_800x600: Rect = .{ .x = 100, .y = 50, .w = 800, .h = 600 };

fn expectClose(want: f32, got: f32) !void {
    try testing.expect(@abs(want - got) < 0.01);
}

test "fit: 큰 이미지는 줄여 넣고 작은 이미지는 늘리지 않는다" {
    // 1600×1200 은 정확히 절반.
    try expectClose(0.5, fitScale(vp_800x600, 1600, 1200));
    // 세로가 더 긴 이미지는 세로가 정한다.
    try expectClose(600.0 / 2400.0, fitScale(vp_800x600, 100, 2400));
    // **작은 이미지는 1 에서 멈춘다** — 2×2 를 800 px 로 늘려 보여 주면 원본을 확인하러 온 사람에게 거짓말이다.
    try expectClose(1.0, fitScale(vp_800x600, 2, 2));
    // 퇴화 입력은 0(그리지 않는다는 뜻).
    try expectClose(0, fitScale(vp_800x600, 0, 10));
    try expectClose(0, fitScale(.{ .x = 0, .y = 0, .w = 0, .h = 0 }, 10, 10));
}

test "clamp: 안 정한 배율은 fit 이 되고 범위 밖은 되돌아온다" {
    const c = clamp(.{}, vp_800x600, 1600, 1200);
    try expectClose(0.5, c.scale);

    // fit 아래로는 못 내려간다 — 전체보기보다 더 줄일 이유가 없다.
    try expectClose(0.5, clamp(.{ .scale = 0.01 }, vp_800x600, 1600, 1200).scale);
    // max_zoom 위로도 못 올라간다.
    try expectClose(max_zoom, clamp(.{ .scale = 100 }, vp_800x600, 1600, 1200).scale);
    // NaN 은 fit 으로 떨어진다(입력 어디서 새 들어와도 화면이 사라지지 않는다).
    try expectClose(0.5, clamp(.{ .scale = std.math.nan(f32) }, vp_800x600, 1600, 1200).scale);
}

test "clamp: 내용이 뷰포트보다 작으면 팬은 0 으로 되돌아간다" {
    // fit 배율에서는 한 축이 딱 맞고 다른 축은 남는다 — 어느 쪽도 밀 수 없다.
    const c = clamp(.{ .scale = 0.5, .pan_x = 300, .pan_y = -200 }, vp_800x600, 1600, 1200);
    try expectClose(0, c.pan_x);
    try expectClose(0, c.pan_y);
}

test "clamp: 확대했을 때만 팬이 허용되고 가장자리에서 멈춘다" {
    // 1600×1200 을 1.0 배 → 내용 1600×1200, 뷰포트 800×600. 각 축 여유 (1600-800)/2 = 400.
    const c = clamp(.{ .scale = 1.0, .pan_x = 10_000, .pan_y = -10_000 }, vp_800x600, 1600, 1200);
    try expectClose(400, c.pan_x);
    try expectClose(-300, c.pan_y);
    // 한계 안쪽은 그대로 통과한다.
    try expectClose(120, clamp(.{ .scale = 1.0, .pan_x = 120 }, vp_800x600, 1600, 1200).pan_x);
}

test "destRect: fit 이면 뷰포트 가운데에 비율 그대로 놓인다" {
    const r = destRect(.{}, vp_800x600, 1600, 1200);
    try expectClose(800, r.w);
    try expectClose(600, r.h);
    try expectClose(100, r.x); // 폭이 딱 맞으므로 여백 0
    try expectClose(50, r.y);

    // 세로로 긴 이미지는 좌우에 여백이 생긴다 — **늘리지 않는다**.
    const tall = destRect(.{}, vp_800x600, 300, 1200);
    try expectClose(0.5, tall.h / 1200.0);
    try expectClose(150, tall.w);
    try expectClose(100 + (800 - 150) / 2, tall.x);
    try expectClose(50, tall.y);
}

test "zoomAt: 붙잡은 점이 그 자리에 남는다" {
    const vp = vp_800x600;
    const start = clamp(.{}, vp, 1600, 1200); // scale 0.5, 화면을 꽉 채움
    // 뷰포트 왼쪽 위 모서리를 붙잡고 확대한다 — 가운데 기준이었다면 이 점이 밖으로 밀려난다.
    const anchor_x: f32 = 100;
    const anchor_y: f32 = 50;
    const zoomed = zoomAt(start, vp, 1600, 1200, 2.0, anchor_x, anchor_y);
    try expectClose(1.0, zoomed.scale);

    const r = destRect(zoomed, vp, 1600, 1200);
    // 붙잡기 전 그 점이 가리키던 원본 좌표.
    const before = destRect(start, vp, 1600, 1200);
    const u = (anchor_x - before.x) / start.scale;
    const w = (anchor_y - before.y) / start.scale;
    // 확대 뒤에도 같은 화면 좌표에 있어야 한다.
    try expectClose(anchor_x, r.x + u * zoomed.scale);
    try expectClose(anchor_y, r.y + w * zoomed.scale);
}

test "zoomAt: 한계에 걸리면 팬이 슬금슬금 밀리지 않는다" {
    const vp = vp_800x600;
    const at_max = clamp(.{ .scale = max_zoom, .pan_x = 123, .pan_y = -45 }, vp, 1600, 1200);
    const again = zoomAt(at_max, vp, 1600, 1200, 2.0, 400, 300);
    try expectClose(at_max.scale, again.scale);
    try expectClose(at_max.pan_x, again.pan_x);
    try expectClose(at_max.pan_y, again.pan_y);

    // 축소도 같다 — fit 에서 더 줄이려 해도 그대로다.
    const at_fit = clamp(.{}, vp, 1600, 1200);
    const shrunk = zoomAt(at_fit, vp, 1600, 1200, 0.5, 400, 300);
    try expectClose(at_fit.scale, shrunk.scale);
    try expectClose(0, shrunk.pan_x);

    // 배율 계수가 0 이나 음수면 아무 일도 없다(0 으로 나누기·뒤집힘 방지).
    try expectClose(at_fit.scale, zoomAt(at_fit, vp, 1600, 1200, 0, 400, 300).scale);
    try expectClose(at_fit.scale, zoomAt(at_fit, vp, 1600, 1200, -2, 400, 300).scale);
}

test "panBy: 화면 이동량 그대로 밀고 가장자리에서 멈춘다" {
    const vp = vp_800x600;
    const start = clamp(.{ .scale = 1.0 }, vp, 1600, 1200);
    const moved = panBy(start, vp, 1600, 1200, 50, -30);
    try expectClose(50, moved.pan_x);
    try expectClose(-30, moved.pan_y);
    // 계속 밀어도 가장자리에서 멈춘다.
    try expectClose(400, panBy(moved, vp, 1600, 1200, 10_000, 0).pan_x);
    // fit 상태에서는 밀리지 않는다.
    try expectClose(0, panBy(clamp(.{}, vp, 1600, 1200), vp, 1600, 1200, 200, 0).pan_x);
}

test "퇴화 이미지는 그리지 않는다 — 0 크기 사각형" {
    const r = destRect(.{ .scale = 2 }, vp_800x600, 0, 0);
    try expectClose(0, r.w);
    try expectClose(0, r.h);
    try expectClose(0, clamp(.{ .scale = 2 }, vp_800x600, 0, 0).scale);
}
