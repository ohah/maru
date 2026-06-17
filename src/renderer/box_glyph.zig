//! Box-drawing(U+2500~U+257F) 글리프 합성 — 폰트 글리프 대신 셀에 얇은 선을 직접 그려 **셀 경계에서 이음매
//! 없이 연결**한다(폰트 글리프는 셀에 안 맞아 선이 끊기거나 안 보인다 — TUI 보더 `─│╭╮`). block_glyph와 같은
//! 원리: 슬롯이 cell 크기 + 셀 셰이더 nearest 샘플 + alpha coverage라, 슬롯 alpha에 정수 픽셀 선을 채우면
//! 1:1 픽셀-퍼펙트로 셀에 그려진다.
//!
//! **arm 모델**: 각 box 문자는 셀 중앙에서 상/하/좌/우로 뻗는 팔의 조합이다. 가로 팔은 세로 중앙의 t-두께 띠,
//! 세로 팔은 가로 중앙의 t-두께 띠로 그리고, 각 팔을 **셀 경계까지** 뻗어(left→x=0, right→x=w, up→y=0, down→y=h)
//! 이웃 셀의 선과 정확히 맞닿게 한다. 중앙에서 팔들이 교차해 모서리(┌)·삼거리(├)·사거리(┼)가 된다.
//!
//! 범위: **light single 선만** — ─│ 직선, ┌┐└┘ 모서리, ├┤┬┴┼ 교차, 둥근 ╭╮╰╯(**실제 quarter-arc** —
//! fillRoundedCorner). heavy(━┃)·double(═║)·dashed·혼합 굵기는 후속(폰트 글리프로 폴백). 베이스 = Unicode
//! Box Drawing 기하. Ghostty font/sprite/draw/box.zig 동작만 비교(코드 미복사 — clean-room). 중립 모듈.

const std = @import("std");

/// 셀 중앙에서 뻗는 팔(전부 light). 가로(left/right)·세로(up/down) 조합으로 모든 light box 문자를 표현한다.
const Arms = struct { up: bool = false, down: bool = false, left: bool = false, right: bool = false };

/// cp가 합성 대상 light box-drawing 문자인지(이 PR이 덮는 집합). 그 외(heavy/double/dashed/혼합)는 false →
/// 기존 폰트 글리프 경로로 폴백한다.
pub fn isBoxDrawing(cp: u32) bool {
    return armsFor(cp) != null;
}

/// cp → 팔 조합. 덮지 않는 문자면 null. 둥근 모서리(╭╮╰╯)는 직각과 같은 팔(arc 근사는 후속).
fn armsFor(cp: u32) ?Arms {
    return switch (cp) {
        0x2500 => .{ .left = true, .right = true }, // ─ horizontal
        0x2502 => .{ .up = true, .down = true }, // │ vertical
        0x250C => .{ .down = true, .right = true }, // ┌ down+right
        0x2510 => .{ .down = true, .left = true }, // ┐ down+left
        0x2514 => .{ .up = true, .right = true }, // └ up+right
        0x2518 => .{ .up = true, .left = true }, // ┘ up+left
        0x251C => .{ .up = true, .down = true, .right = true }, // ├
        0x2524 => .{ .up = true, .down = true, .left = true }, // ┤
        0x252C => .{ .down = true, .left = true, .right = true }, // ┬
        0x2534 => .{ .up = true, .left = true, .right = true }, // ┴
        0x253C => .{ .up = true, .down = true, .left = true, .right = true }, // ┼
        0x256D => .{ .down = true, .right = true }, // ╭ arc down+right (직각 근사)
        0x256E => .{ .down = true, .left = true }, // ╮
        0x256F => .{ .up = true, .left = true }, // ╯
        0x2570 => .{ .up = true, .right = true }, // ╰
        else => null,
    };
}

/// cp box 문자를 width×height RGBA8 슬롯에 coverage로 채운다 — 선은 흰색 불투명(0xFFFFFFFF, 셰이더가 alpha를
/// coverage로 읽어 전경색으로), 나머지 0. 채운 픽셀 수 반환. isBoxDrawing(cp) 가정. 선 두께 t는 cell 높이 비례
/// (light, 최소 1px), 중앙 정렬·정수 픽셀 스냅. 버퍼 계약(bpr≥w*4·len≥h*bpr) 위반 시 빈 글리프로 안전 degrade.
pub fn fillCoverage(cp: u32, width_px: u32, height_px: u32, bytes_per_row: usize, pixels: []u8) u32 {
    const w = width_px;
    const h = height_px;
    if (w == 0 or h == 0) return 0;
    if (bytes_per_row < @as(usize, w) * 4 or pixels.len < @as(usize, h) * bytes_per_row) return 0;
    const arms = armsFor(cp) orelse return 0;
    @memset(pixels[0 .. @as(usize, h) * bytes_per_row], 0);

    // light 선 두께(device px) — cell 높이 비례, 최소 1, cell보다 두껍지 않게(언더플로 방지).
    var t: u32 = (h + 8) / 16;
    if (t < 1) t = 1;
    t = @min(t, @min(w, h));
    // 중앙 정렬 띠: 가로 팔은 [yb0,yb1) 높이, 세로 팔은 [xb0,xb1) 폭.
    const yb0 = (h - t) / 2;
    const yb1 = yb0 + t;
    const xb0 = (w - t) / 2;
    const xb1 = xb0 + t;

    // 둥근 모서리(╭╮╰╯)는 직각 대신 quarter-arc로 — 두 팔 방향(h_dir·v_dir)으로 아크 코너를 그린다.
    switch (cp) {
        0x256D => return fillRoundedCorner(pixels, bytes_per_row, w, h, t, yb0, yb1, xb0, xb1, 1, 1), // ╭ right+down
        0x256E => return fillRoundedCorner(pixels, bytes_per_row, w, h, t, yb0, yb1, xb0, xb1, -1, 1), // ╮ left+down
        0x256F => return fillRoundedCorner(pixels, bytes_per_row, w, h, t, yb0, yb1, xb0, xb1, -1, -1), // ╯ left+up
        0x2570 => return fillRoundedCorner(pixels, bytes_per_row, w, h, t, yb0, yb1, xb0, xb1, 1, -1), // ╰ right+up
        else => {},
    }

    var count: u32 = 0;
    // 각 팔을 셀 경계까지 뻗는다(중앙 교차 [xb0,xb1)×[yb0,yb1)를 공유해 모서리/교차가 자연히 이어진다).
    if (arms.left) count += fillRect(pixels, bytes_per_row, 0, yb0, xb1, yb1); // 좌단~중앙
    if (arms.right) count += fillRect(pixels, bytes_per_row, xb0, yb0, w, yb1); // 중앙~우단
    if (arms.up) count += fillRect(pixels, bytes_per_row, xb0, 0, xb1, yb1); // 상단~중앙
    if (arms.down) count += fillRect(pixels, bytes_per_row, xb0, yb0, xb1, h); // 중앙~하단
    return count;
}

/// 둥근 모서리(╭╮╰╯)를 quarter-arc + 접점 너머 직선 팔로 채운다. 슬롯은 이미 0으로 비워진 상태. h_dir/v_dir은
/// 가로/세로 팔 방향(+1=right/down, -1=left/up). 아크 중심 C=(cx+h_dir·r, cy+v_dir·r), r=min(cx,cy)(셀에 맞는
/// 최대 반지름). 아크 띠 = C에서 거리 [r-t/2, r+t/2]이고 셀 중앙을 향한 사분면((x-C)·dir ≤ 0). 접점 너머는
/// 기존 직선 팔(y/x 띠)로 셀 경계까지 뻗어 이웃 셀과 연결. pixel center(+0.5)로 거리 계산 → 대칭·연결 정확.
fn fillRoundedCorner(
    pixels: []u8,
    bytes_per_row: usize,
    w: u32,
    h: u32,
    t: u32,
    yb0: u32,
    yb1: u32,
    xb0: u32,
    xb1: u32,
    h_dir: i32,
    v_dir: i32,
) u32 {
    const cx = @as(f32, @floatFromInt(w)) * 0.5;
    const cy = @as(f32, @floatFromInt(h)) * 0.5;
    const r = @min(cx, cy); // 코너 반지름 = 셀 짧은 반 치수(아크가 셀에 들어가는 최대)
    const hd = @as(f32, @floatFromInt(h_dir));
    const vd = @as(f32, @floatFromInt(v_dir));
    const c_x = cx + hd * r; // 아크 중심
    const c_y = cy + vd * r;
    const tf = @as(f32, @floatFromInt(t));
    const r_lo = r - tf * 0.5;
    const r_hi = r + tf * 0.5;

    var count: u32 = 0;
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        const fy = @as(f32, @floatFromInt(y)) + 0.5;
        const dy = fy - c_y;
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const fx = @as(f32, @floatFromInt(x)) + 0.5;
            const dx = fx - c_x;
            const dist = @sqrt(dx * dx + dy * dy);
            // 아크: 거리 band 안 + 셀 중앙을 향한 사분면(접점 사이 호).
            const in_arc = dist >= r_lo and dist <= r_hi and dx * hd <= 0.0 and dy * vd <= 0.0;
            // 가로 직선 팔: y 띠 + 아크 접점 바깥((x-C)·h_dir ≥ 0) → 셀 가로 경계까지.
            const in_h = (y >= yb0 and y < yb1) and dx * hd >= 0.0;
            // 세로 직선 팔: x 띠 + 접점 바깥 → 셀 세로 경계까지.
            const in_v = (x >= xb0 and x < xb1) and dy * vd >= 0.0;
            if (in_arc or in_h or in_v) {
                const off = @as(usize, y) * bytes_per_row + @as(usize, x) * 4;
                pixels[off] = 0xFF;
                pixels[off + 1] = 0xFF;
                pixels[off + 2] = 0xFF;
                pixels[off + 3] = 0xFF;
                count += 1;
            }
        }
    }
    return count;
}

/// [x0,x1)×[y0,y1) 픽셀을 흰색 불투명(0xFFFFFFFF)으로. 채운 픽셀 수 반환. RGBA8 + bytes_per_row. 겹쳐도(교차)
/// 멱등이라 안전. 경계는 fillCoverage가 검증(off+4 ≤ h*bpr ≤ len)했으므로 per-pixel 가드 없이 쓴다.
fn fillRect(pixels: []u8, bytes_per_row: usize, x0: u32, y0: u32, x1: u32, y1: u32) u32 {
    if (x1 <= x0 or y1 <= y0) return 0;
    var count: u32 = 0;
    var y = y0;
    while (y < y1) : (y += 1) {
        const row_off = @as(usize, y) * bytes_per_row;
        var x = x0;
        while (x < x1) : (x += 1) {
            const off = row_off + @as(usize, x) * 4;
            const was_set = pixels[off + 3] != 0;
            pixels[off] = 0xFF;
            pixels[off + 1] = 0xFF;
            pixels[off + 2] = 0xFF;
            pixels[off + 3] = 0xFF;
            if (!was_set) count += 1; // 교차에서 겹친 픽셀은 한 번만 센다
        }
    }
    return count;
}

test "isBoxDrawing: 덮는 light 집합만" {
    try std.testing.expect(isBoxDrawing(0x2500)); // ─
    try std.testing.expect(isBoxDrawing(0x2502)); // │
    try std.testing.expect(isBoxDrawing(0x250C)); // ┌
    try std.testing.expect(isBoxDrawing(0x253C)); // ┼
    try std.testing.expect(isBoxDrawing(0x256D)); // ╭ (보더 둥근 모서리)
    try std.testing.expect(isBoxDrawing(0x2570)); // ╰
    try std.testing.expect(!isBoxDrawing(0x2501)); // ━ heavy(후속)
    try std.testing.expect(!isBoxDrawing(0x2550)); // ═ double(후속)
    try std.testing.expect(!isBoxDrawing(0x2588)); // █ block(block_glyph)
    try std.testing.expect(!isBoxDrawing('A'));
}

test "fillCoverage: 직선·모서리·교차가 셀 경계까지 닿고 중앙에서 교차한다" {
    const w: u32 = 10;
    const h: u32 = 32; // t=(32+8)/16=2(짝수) → 중앙 띠 [15,17)가 cy=16=h/2을 포함(t=1 홀수면 band가 중앙서 ±0.5 어긋나 테스트만 까다로움; 렌더는 모든 셀 동일 공식이라 이음매 OK)
    const bpr: usize = w * 4;
    var pixels: [32 * 10 * 4]u8 = undefined;
    const a = struct {
        fn at(p: []const u8, bytes_per_row: usize, x: u32, y: u32) u8 {
            return p[@as(usize, y) * bytes_per_row + @as(usize, x) * 4 + 3];
        }
    }.at;
    const cy = h / 2;
    const cx = w / 2;

    // ─ horizontal: 세로 중앙에 가로선이 좌단~우단까지. 중앙 행은 채우고, 위/아래(선 밖)는 빈다.
    _ = fillCoverage(0x2500, w, h, bpr, &pixels);
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, 0, cy)); // 좌단 닿음
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, w - 1, cy)); // 우단 닿음
    try std.testing.expectEqual(@as(u8, 0x00), a(&pixels, bpr, cx, 0)); // 선 밖(위) 빈다
    try std.testing.expectEqual(@as(u8, 0x00), a(&pixels, bpr, cx, h - 1)); // 아래 빈다

    // │ vertical: 가로 중앙에 세로선이 상단~하단. 중앙 열은 채우고 좌/우는 빈다.
    _ = fillCoverage(0x2502, w, h, bpr, &pixels);
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, cx, 0)); // 상단 닿음
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, cx, h - 1)); // 하단 닿음
    try std.testing.expectEqual(@as(u8, 0x00), a(&pixels, bpr, 0, cy)); // 좌 빈다

    // ┌ down+right: 우단·하단엔 닿고 좌단·상단엔 안 닿는다(모서리). 중앙 교차는 채움.
    _ = fillCoverage(0x250C, w, h, bpr, &pixels);
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, w - 1, cy)); // 오른쪽 팔
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, cx, h - 1)); // 아래 팔
    try std.testing.expectEqual(@as(u8, 0x00), a(&pixels, bpr, 0, cy)); // 왼쪽 안 닿음
    try std.testing.expectEqual(@as(u8, 0x00), a(&pixels, bpr, cx, 0)); // 위 안 닿음

    // ┼ all: 사거리 — 네 변에 다 닿는다.
    _ = fillCoverage(0x253C, w, h, bpr, &pixels);
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, 0, cy));
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, w - 1, cy));
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, cx, 0));
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, cx, h - 1));
}

test "fillCoverage: 둥근 모서리 ╭는 호로 두 팔을 잇고 직각 코너는 비운다(이웃과 연결 유지)" {
    const w: u32 = 10;
    const h: u32 = 32; // t=2
    const bpr: usize = w * 4;
    var pixels: [32 * 10 * 4]u8 = undefined;
    const a = struct {
        fn at(p: []const u8, bytes_per_row: usize, x: u32, y: u32) u8 {
            return p[@as(usize, y) * bytes_per_row + @as(usize, x) * 4 + 3];
        }
    }.at;
    const cy = h / 2; // 16
    const cx = w / 2; // 5

    _ = fillCoverage(0x256D, w, h, bpr, &pixels); // ╭ (right+down 둥근)
    // 이웃 연결: 우단 가로선(y=cy 띠)·하단 세로선(x=cx 띠)에 닿아야 ─/│ 이웃과 이어진다.
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, w - 1, cy)); // 우단 → ─ 연결
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, cx, h - 1)); // 하단 → │ 연결
    // ╭는 좌·상으로 안 뻗는다 — 좌단 가로/상단 세로는 빈다.
    try std.testing.expectEqual(@as(u8, 0x00), a(&pixels, bpr, 0, cy)); // 좌단 빈다
    try std.testing.expectEqual(@as(u8, 0x00), a(&pixels, bpr, cx, 0)); // 상단 빈다
    // 둥근 효과: 직각 코너점(좌상 바깥 0,0)과 반대 코너(우하 w-1,h-1)는 비어야 한다.
    try std.testing.expectEqual(@as(u8, 0x00), a(&pixels, bpr, 0, 0)); // 좌상 바깥
    try std.testing.expectEqual(@as(u8, 0x00), a(&pixels, bpr, w - 1, h - 1)); // 우하(╭ 영역 아님)
}
