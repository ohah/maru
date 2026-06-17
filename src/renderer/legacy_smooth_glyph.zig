//! Symbols for Legacy Computing — **smooth mosaic**(U+1FB3C~1FB67, 44개) 합성. 셀 둘레의 10개 정점(모서리 4 +
//! 좌·우 변의 1/3·2/3 지점 4 + 상·하 변 중점 2) 중 글자별 부분집합을 둘레 순으로 이은 단순 다각형을 채운다
//! (대각 잘린 모자이크 — Teletext식). block 모자이크가 직각 칸이라면 이쪽은 **대각 빗변**을 가진다.
//!
//! 베이스 = Unicode smooth mosaic 글리프 형상(각 글자의 채워진 영역 = 위 10정점 중 어느 것을 잇는 다각형인지).
//! 형상에서 정점 집합(10비트 마스크)을 독립 디코더로 산출해 **마스크 44개만** 임베드(레퍼런스 코드·패턴표
//! 미복사 — clean-room). 폴리곤 채움은 공유 `glyph_pixels.fillPolygon`(scanline). 중립 모듈.

const std = @import("std");
const gp = @import("glyph_pixels.zig");

/// cp가 smooth mosaic(U+1FB3C~1FB67)인지. 그 밖이면 폰트 폴백.
pub fn isSmoothMosaic(cp: u32) bool {
    return cp >= 0x1FB3C and cp <= 0x1FB67;
}

// 둘레 10정점(셀 비율). 순서 = 좌변 위→아래, 하변, 우변 아래→위, 상변 — 둘레를 한 바퀴 돈다. 부분집합을 이
// 순서대로 고르면 항상 단순 다각형이 된다. bit: tl=0,ul=1,ll=2,bl=3,bc=4,br=5,lr=6,ur=7,tr=8,tc=9.
const vert_frac = [10][2]f32{
    .{ 0.0, 0.0 }, // tl 좌상
    .{ 0.0, 1.0 / 3.0 }, // ul 좌변 1/3
    .{ 0.0, 2.0 / 3.0 }, // ll 좌변 2/3
    .{ 0.0, 1.0 }, // bl 좌하
    .{ 0.5, 1.0 }, // bc 하변 중점
    .{ 1.0, 1.0 }, // br 우하
    .{ 1.0, 2.0 / 3.0 }, // lr 우변 2/3
    .{ 1.0, 1.0 / 3.0 }, // ur 우변 1/3
    .{ 1.0, 0.0 }, // tr 우상
    .{ 0.5, 0.0 }, // tc 상변 중점
};

// 글자별 정점 마스크(U+1FB3C부터 44개). Unicode 형상에서 디코더로 산출(정점이 모두 ≥3개라 폴리곤 성립).
const smooth_mask = [44]u10{
    0x01C, 0x02C, 0x01A, 0x02A, 0x019, 0x32A, 0x12A, 0x32C, 0x12C, 0x328,
    0x0AC, 0x070, 0x068, 0x0B0, 0x0A8, 0x130, 0x2A9, 0x0A9, 0x269, 0x069,
    0x229, 0x06A, 0x135, 0x125, 0x133, 0x123, 0x131, 0x203, 0x103, 0x205,
    0x105, 0x209, 0x185, 0x159, 0x149, 0x199, 0x189, 0x119, 0x380, 0x181,
    0x340, 0x141, 0x320, 0x143,
};

/// cp smooth mosaic을 width×height RGBA8 슬롯에 coverage로 채운다(흰색 불투명). 채운 픽셀 수 반환.
/// isSmoothMosaic(cp) 가정. 버퍼 계약 위반 시 빈 글리프로 degrade.
pub fn fillCoverage(cp: u32, width_px: u32, height_px: u32, bytes_per_row: usize, pixels: []u8) u32 {
    const w = width_px;
    const h = height_px;
    if (!gp.slotFits(w, h, bytes_per_row, pixels)) return 0;
    gp.clear(pixels, h, bytes_per_row);
    if (!isSmoothMosaic(cp)) return 0;

    const mask = smooth_mask[cp - 0x1FB3C];
    const fw = @as(f32, @floatFromInt(w));
    const fh = @as(f32, @floatFromInt(h));
    var verts: [10][2]f32 = undefined;
    var n: usize = 0;
    for (0..10) |b| {
        if ((mask >> @as(u4, @intCast(b))) & 1 == 0) continue;
        verts[n] = .{ vert_frac[b][0] * fw, vert_frac[b][1] * fh };
        n += 1;
    }
    return gp.fillPolygon(pixels, bytes_per_row, w, h, verts[0..n]);
}

test "isSmoothMosaic 범위·마스크 표 정점≥3" {
    try std.testing.expect(isSmoothMosaic(0x1FB3C));
    try std.testing.expect(isSmoothMosaic(0x1FB67));
    try std.testing.expect(!isSmoothMosaic(0x1FB3B)); // octant 경계 아래(별도 모듈)
    try std.testing.expect(!isSmoothMosaic(0x1FB68)); // wedge(별도 모듈)
    try std.testing.expectEqual(@as(usize, 44), smooth_mask.len);
    for (smooth_mask) |m| {
        try std.testing.expect(@popCount(m) >= 3); // 폴리곤이려면 정점 3개 이상
    }
}

test "fillCoverage: 대표 글자가 올바른 영역을 채운다(대각 cut 포함)" {
    const w: u32 = 12;
    const h: u32 = 12; // 1/3·2/3이 정수(4·8)로 떨어지게
    const bpr: usize = w * 4;
    var pixels: [12 * 12 * 4]u8 = undefined;
    const a = struct {
        fn at(p: []const u8, bpr_: usize, x: u32, y: u32) u8 {
            return p[@as(usize, y) * bpr_ + @as(usize, x) * 4 + 3];
        }
    }.at;

    // 🬼 U+1FB3C = {ll,bl,bc} 좌하 삼각형: 좌하 채움, 우상·상중앙 빔.
    _ = fillCoverage(0x1FB3C, w, h, bpr, &pixels);
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, 1, 11)); // 좌하 안
    try std.testing.expectEqual(@as(u8, 0x00), a(&pixels, bpr, 11, 1)); // 우상 빔
    try std.testing.expectEqual(@as(u8, 0x00), a(&pixels, bpr, 6, 2)); // 상중앙 빔

    // 🭗 U+1FB57 = {tl,ul,tc} 좌상 삼각형: 좌상 채움, 우하 빔.
    _ = fillCoverage(0x1FB57, w, h, bpr, &pixels);
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, 1, 1)); // 좌상 안
    try std.testing.expectEqual(@as(u8, 0x00), a(&pixels, bpr, 11, 11)); // 우하 빔

    // 🭁 U+1FB41 = {ul,bl,br,tr,tc}: 좌상 모서리만 대각으로 잘린 오각형. 중앙·좌하·우하 채움, 좌상 모서리 빔.
    _ = fillCoverage(0x1FB41, w, h, bpr, &pixels);
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, 6, 6)); // 중앙
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, 1, 11)); // 좌하
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, 11, 11)); // 우하
    try std.testing.expectEqual(@as(u8, 0x00), a(&pixels, bpr, 1, 1)); // 좌상 모서리(대각 cut 위) 빔
}
