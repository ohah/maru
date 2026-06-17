//! Powerline 글리프 합성(U+E0B0~E0BF, Private Use Area) — 폰트(powerline-symbols)가 없어도 셀에 꽉 차게 직접
//! 그린다. box_glyph·block_glyph와 같은 원리(슬롯=cell 크기 + nearest 샘플 + alpha coverage → 픽셀-퍼펙트).
//! Powerline separator는 셀 경계를 칼같이 채워야 다음 세그먼트 배경과 이음매 없이 맞물린다(폰트 글리프는 셀에
//! 안 맞아 틈·흐림).
//!
//! 범위: 삼각형 separator(E0B0 우·E0B2 좌 — solid, E0B1·E0B3 — thin chevron), 모서리 삼각형(E0B8 좌하·E0BA 우하·
//! E0BC 좌상·E0BE 우상 — solid, E0B9·E0BB·E0BD·E0BF — thin 대각선), 반원(E0B4 우·E0B6 좌 — solid D-shape,
//! E0B5·E0B7 — thin arc). 베이스 = powerline-symbols 표준 모양. Ghostty font/sprite/draw/powerline.zig 동작만
//! 비교(코드 미복사 — clean-room: 삼각형 정점·반원 D-shape·thin=edge stroke). 중립 모듈.

const std = @import("std");
const gp = @import("glyph_pixels.zig"); // 슬롯 검증·clear·setPixel·대각선 공유 프리미티브(단일 출처).

/// cp가 합성 대상 Powerline 글리프인지(E0B0~E0BF). 그 밖이면 false → 폰트 글리프 폴백.
pub fn isPowerline(cp: u32) bool {
    return cp >= 0xE0B0 and cp <= 0xE0BF;
}

/// cp Powerline 글리프를 width×height RGBA8 슬롯에 coverage로 채운다(흰색 불투명 0xFFFFFFFF — 셰이더가 alpha를
/// coverage로 읽어 전경색으로). 채운 픽셀 수 반환. isPowerline(cp) 가정. 버퍼 계약 위반 시 빈 글리프로 degrade.
pub fn fillCoverage(cp: u32, width_px: u32, height_px: u32, bytes_per_row: usize, pixels: []u8) u32 {
    const w = width_px;
    const h = height_px;
    if (!gp.slotFits(w, h, bytes_per_row, pixels)) return 0;
    if (!isPowerline(cp)) return 0;
    gp.clear(pixels, h, bytes_per_row);

    const fw = @as(f32, @floatFromInt(w));
    const fh = @as(f32, @floatFromInt(h));
    // thin 선 두께(box_glyph와 같은 공식 — light).
    var t: u32 = (h + 8) / 16;
    if (t < 1) t = 1;
    const ft = @as(f32, @floatFromInt(t));

    return switch (cp) {
        // ── 삼각형 separator ── 공유 삼각형 프리미티브(gp.fillTriangle, invert=false).
        0xE0B0 => gp.fillTriangle(pixels, bytes_per_row, w, h, 0, 0, fw, fh / 2, 0, fh, false), // 우 solid ▶
        0xE0B2 => gp.fillTriangle(pixels, bytes_per_row, w, h, fw, 0, 0, fh / 2, fw, fh, false), // 좌 solid ◀
        0xE0B1 => fillChevron(pixels, bytes_per_row, w, h, ft, true), // 우 thin >
        0xE0B3 => fillChevron(pixels, bytes_per_row, w, h, ft, false), // 좌 thin <
        // ── 모서리 삼각형(solid) ──
        0xE0B8 => gp.fillTriangle(pixels, bytes_per_row, w, h, 0, 0, fw, fh, 0, fh, false), // 좌하 ◣
        0xE0BA => gp.fillTriangle(pixels, bytes_per_row, w, h, fw, 0, fw, fh, 0, fh, false), // 우하 ◢
        0xE0BC => gp.fillTriangle(pixels, bytes_per_row, w, h, 0, 0, fw, 0, 0, fh, false), // 좌상 ◤
        0xE0BE => gp.fillTriangle(pixels, bytes_per_row, w, h, 0, 0, fw, 0, fw, fh, false), // 우상 ◥
        // ── 모서리 thin 대각선(solid 모서리의 빗변) — box ╱╲와 같은 공유 대각선 프리미티브. ╲=do_back, ╱=do_fwd.
        0xE0B9 => gp.fillDiagonal(pixels, bytes_per_row, w, h, t, true, false), // 좌하 빗변 = ╲
        0xE0BF => gp.fillDiagonal(pixels, bytes_per_row, w, h, t, true, false), // 우상 빗변 = ╲
        0xE0BB => gp.fillDiagonal(pixels, bytes_per_row, w, h, t, false, true), // 우하 빗변 = ╱
        0xE0BD => gp.fillDiagonal(pixels, bytes_per_row, w, h, t, false, true), // 좌상 빗변 = ╱
        // ── 반원(D-shape) ──
        0xE0B4 => fillHalfCircle(pixels, bytes_per_row, w, h, 0, true, true), // 우 solid
        0xE0B6 => fillHalfCircle(pixels, bytes_per_row, w, h, 0, false, true), // 좌 solid
        0xE0B5 => fillHalfCircle(pixels, bytes_per_row, w, h, t, true, false), // 우 thin
        0xE0B7 => fillHalfCircle(pixels, bytes_per_row, w, h, t, false, false), // 좌 thin
        else => 0,
    };
}

/// thin chevron(삼각형 separator의 빗변 두 선만). right=true면 (0,0)->(w,h/2)·(0,h)->(w,h/2), false면 좌우 반전.
fn fillChevron(pixels: []u8, bytes_per_row: usize, w: u32, h: u32, t: f32, right: bool) u32 {
    const fw = @as(f32, @floatFromInt(w));
    const fh = @as(f32, @floatFromInt(h));
    const apex_x: f32 = if (right) fw else 0;
    const base_x: f32 = if (right) 0 else fw;
    var count: u32 = 0;
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        const py = @as(f32, @floatFromInt(y)) + 0.5;
        const row_off = @as(usize, y) * bytes_per_row;
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const px = @as(f32, @floatFromInt(x)) + 0.5;
            const near = distSeg(px, py, base_x, 0, apex_x, fh / 2) <= t / 2 or
                distSeg(px, py, base_x, fh, apex_x, fh / 2) <= t / 2;
            if (near) {
                gp.setPixel(pixels, row_off + @as(usize, x) * 4);
                count += 1;
            }
        }
    }
    return count;
}

/// 점 (px,py)에서 선분 (ax,ay)-(bx,by)까지 최단거리.
fn distSeg(px: f32, py: f32, ax: f32, ay: f32, bx: f32, by: f32) f32 {
    const dx = bx - ax;
    const dy = by - ay;
    const len2 = dx * dx + dy * dy;
    if (len2 == 0) return @sqrt((px - ax) * (px - ax) + (py - ay) * (py - ay));
    var tparam = ((px - ax) * dx + (py - ay) * dy) / len2;
    tparam = std.math.clamp(tparam, 0.0, 1.0);
    const qx = ax + tparam * dx;
    const qy = ay + tparam * dy;
    return @sqrt((px - qx) * (px - qx) + (py - qy) * (py - qy));
}

/// 반원(D-shape). right=true면 평평한 변이 좌측(x=0), 우측으로 불룩. solid면 내부 채움, thin이면 곡선 둘레만
/// (두께 t). 반지름 r=min(w, h/2): 위/아래는 quarter-arc(중심 (0,r)·(0,fh-r)), 가운데는 직선 x=r.
///
/// 경계까지의 **부호 있는 수직 거리** bd로 칠한다(bd<0=내부, bd=0=경계). 위/아래 호는 평평한 변 위의 중심에서
/// 잰 반지름 차(`hypot(depth, dy) - r`), 가운데는 `depth - r`. solid=`bd<=0`. thin=안쪽 균일 밴드 `-ft<=bd<=0`
/// — 호에 **수직**인 두께라 극(極)에서 가늘어지지 않는다(예전엔 수평 깊이 밴드 `[max_d-ft, max_d]`라 호가 가파른
/// 위/아래에서 perpendicular 두께가 ~0.6px로 핀치됐다). thin은 곡선 둘레만(평평한 변은 안 긋는다 — Ghostty의
/// open path와 동일).
fn fillHalfCircle(pixels: []u8, bytes_per_row: usize, w: u32, h: u32, t: u32, right: bool, solid: bool) u32 {
    const fw = @as(f32, @floatFromInt(w));
    const fh = @as(f32, @floatFromInt(h));
    const r = @min(fw, fh / 2.0);
    if (r <= 0) return 0;
    const ft = @as(f32, @floatFromInt(t));
    var count: u32 = 0;
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        const py = @as(f32, @floatFromInt(y)) + 0.5;
        const row_off = @as(usize, y) * bytes_per_row;
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const px = @as(f32, @floatFromInt(x)) + 0.5;
            const depth = if (right) px else fw - px; // 평평한 변(x=0 또는 x=w)에서의 깊이
            // 경계까지 부호 있는 수직 거리.
            const bd: f32 = if (py < r)
                @sqrt(depth * depth + (r - py) * (r - py)) - r // 위 호(중심 (0,r))
            else if (py > fh - r)
                @sqrt(depth * depth + (py - (fh - r)) * (py - (fh - r))) - r // 아래 호(중심 (0,fh-r))
            else
                depth - r; // 가운데 직선(경계 x=r)
            const inside = if (solid) bd <= 0 else (bd <= 0 and bd >= -ft);
            if (inside) {
                gp.setPixel(pixels, row_off + @as(usize, x) * 4);
                count += 1;
            }
        }
    }
    return count;
}

test "isPowerline: E0B0~E0BF만" {
    try std.testing.expect(isPowerline(0xE0B0)); // 우 화살표 solid
    try std.testing.expect(isPowerline(0xE0B3)); // 좌 thin
    try std.testing.expect(isPowerline(0xE0B4)); // 우 반원
    try std.testing.expect(isPowerline(0xE0BF)); // 우상 thin
    try std.testing.expect(!isPowerline(0xE0AF)); // 범위 밖
    try std.testing.expect(!isPowerline(0xE0C0)); // 범위 밖
    try std.testing.expect(!isPowerline(0x2500)); // box-drawing
    try std.testing.expect(!isPowerline('A'));
}

test "fillCoverage: E0B0 우 삼각형은 좌단 가득·우측 점으로 좁아진다" {
    const w: u32 = 16;
    const h: u32 = 32;
    const bpr: usize = w * 4;
    var pixels: [32 * 16 * 4]u8 = undefined;
    const a = struct {
        fn at(p: []const u8, bpr_: usize, x: u32, y: u32) u8 {
            return p[@as(usize, y) * bpr_ + @as(usize, x) * 4 + 3];
        }
    }.at;
    _ = fillCoverage(0xE0B0, w, h, bpr, &pixels);
    // 좌단(x=0): 위~아래 전부 채워짐(삼각형 밑변).
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, 0, 0));
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, 0, h / 2));
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, 0, h - 1));
    // 우단 중앙(점) 근처는 채워지고, 우단 위/아래(점 밖)는 빈다.
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, w - 1, h / 2)); // 점
    try std.testing.expectEqual(@as(u8, 0x00), a(&pixels, bpr, w - 1, 0)); // 우상 빔
    try std.testing.expectEqual(@as(u8, 0x00), a(&pixels, bpr, w - 1, h - 1)); // 우하 빔
    // 좌단 칠 픽셀 수 > 우단 칠 픽셀 수(좁아짐).
    var left: u32 = 0;
    var rightc: u32 = 0;
    for (0..h) |yy| {
        if (a(&pixels, bpr, 0, @intCast(yy)) == 0xFF) left += 1;
        if (a(&pixels, bpr, w - 1, @intCast(yy)) == 0xFF) rightc += 1;
    }
    try std.testing.expect(left > rightc);
}

test "fillCoverage: E0B4 우 반원은 좌단 가득·우로 둥글게 좁아진다" {
    const w: u32 = 20;
    const h: u32 = 40;
    const bpr: usize = w * 4;
    var pixels: [40 * 20 * 4]u8 = undefined;
    const a = struct {
        fn at(p: []const u8, bpr_: usize, x: u32, y: u32) u8 {
            return p[@as(usize, y) * bpr_ + @as(usize, x) * 4 + 3];
        }
    }.at;
    _ = fillCoverage(0xE0B4, w, h, bpr, &pixels);
    // 좌단 세로 중앙: 채워짐(평평한 변).
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, 0, h / 2));
    // 가운데 행(직선부)은 깊이 r=min(w,h/2)까지 채워진다. 이 테스트는 w(20)==h/2(20)을 골라 r==w이므로
    // 우단까지 닿는다. **넓은 셀(w>h/2)에선 r<w라 우단에 못 닿는 게 정상**(반지름은 높이에 앵커된 정확한
    // 반원 기하 — Ghostty도 동일). 그래서 이 단언은 "정사각 비율(w==h/2)일 때 우단 도달"만 고정한다.
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, w - 1, h / 2));
    // 상단 모서리(우상)는 둥글어 빈다.
    try std.testing.expectEqual(@as(u8, 0x00), a(&pixels, bpr, w - 1, 0));
}

test "fillCoverage: E0B5 thin 반원은 극에서 핀치되지 않는다(호에 수직인 균일 두께)" {
    // 회귀 고정(#3): thin 반원 둘레는 **호에 수직**인 균일 두께여야 한다. 예전엔 수평 깊이 밴드
    // `[max_d-ft, max_d]`라, 호가 거의 수평인 위/아래 극에서 perpendicular 두께가 ~0.6px로 핀치됐다.
    const w: u32 = 20;
    const h: u32 = 40;
    const bpr: usize = w * 4;
    var pixels: [40 * 20 * 4]u8 = undefined;
    const a = struct {
        fn at(p: []const u8, bpr_: usize, x: u32, y: u32) u8 {
            return p[@as(usize, y) * bpr_ + @as(usize, x) * 4 + 3];
        }
    }.at;
    _ = fillCoverage(0xE0B5, w, h, bpr, &pixels); // 우 thin, t=(40+8)/16=3
    // 극 근처(y=1, 호가 거의 수평): 평평한 변 쪽 얕은 호까지 stroke가 덮는다 → x=0이 채워진다.
    // 예전 수평 밴드는 [max_d-ft, max_d]≈[4.6,7.6]이라 x=0(depth 0.5)이 비었다 → 이 단언이 핀치 회귀를 잡는다.
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, 0, 1));
    // 적도(y=h/2): 평평한 변(x=0)은 안 긋는다(곡선 둘레만). 불룩한 경계(depth≈r) 쪽은 채워진다.
    try std.testing.expectEqual(@as(u8, 0x00), a(&pixels, bpr, 0, h / 2));
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, w - 2, h / 2));
    // 모든 행에 stroke 픽셀이 최소 1개(둘레가 전 행을 지난다 → 끊김 없음).
    for (0..h) |yy| {
        var any = false;
        for (0..w) |xx| {
            if (a(&pixels, bpr, @intCast(xx), @intCast(yy)) == 0xFF) {
                any = true;
                break;
            }
        }
        try std.testing.expect(any);
    }
}
