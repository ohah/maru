//! Symbols for Legacy Computing — **edge wedge 삼각형** 합성: U+1FB68~1FB6F(한 변을 밑변, 셀 중앙을 꼭짓점으로
//! 하는 삼각형 — solid 4 + 반전 4)와 bowtie U+1FB9A/1FB9B(두 wedge가 중앙에서 맞닿은 모래시계). 정점이 셀
//! 모서리·중앙이라 셀 격자에 칼같이 스냅된다(point-in-triangle 채움, 공유 `glyph_pixels.fillTriangle`).
//!
//! 베이스 = Unicode "Symbols for Legacy Computing"의 edge-triangle/bowtie 도형 정의(밑변=한 변, 꼭짓점=중앙).
//! Ghostty font/sprite 동작만 비교(코드 미복사 — clean-room). smooth-mosaic(U+1FB3C~1FB67 대각 폴리곤)은 후속.
//! 중립 모듈.

const std = @import("std");
const gp = @import("glyph_pixels.zig");

/// wedge 방향 — 밑변이 되는 셀 변. 꼭짓점은 항상 셀 중앙이고 반대편을 가리킨다.
const Edge = enum { left, top, right, bottom };

/// cp가 이 모듈이 합성하는 wedge/bowtie인지(U+1FB68~1FB6F·U+1FB9A~1FB9B). 그 밖이면 폰트 폴백.
pub fn isLegacyWedge(cp: u32) bool {
    return (cp >= 0x1FB68 and cp <= 0x1FB6F) or (cp >= 0x1FB9A and cp <= 0x1FB9B);
}

/// cp wedge/bowtie를 width×height RGBA8 슬롯에 coverage로 채운다(흰색 불투명). 채운 픽셀 수 반환.
/// isLegacyWedge(cp) 가정. 버퍼 계약 위반 시 빈 글리프로 degrade.
pub fn fillCoverage(cp: u32, width_px: u32, height_px: u32, bytes_per_row: usize, pixels: []u8) u32 {
    const w = width_px;
    const h = height_px;
    if (!gp.slotFits(w, h, bytes_per_row, pixels)) return 0;
    gp.clear(pixels, h, bytes_per_row);

    return switch (cp) {
        // 반전 wedge(U+1FB68~1FB6B): 삼각형 바깥(셀에서 wedge를 뺀 나머지)을 채운다.
        0x1FB68 => fillWedge(pixels, bytes_per_row, w, h, .left, true), // 🭨
        0x1FB69 => fillWedge(pixels, bytes_per_row, w, h, .top, true), // 🭩
        0x1FB6A => fillWedge(pixels, bytes_per_row, w, h, .right, true), // 🭪
        0x1FB6B => fillWedge(pixels, bytes_per_row, w, h, .bottom, true), // 🭫
        // solid wedge(U+1FB6C~1FB6F): 밑변=한 변, 꼭짓점=중앙.
        0x1FB6C => fillWedge(pixels, bytes_per_row, w, h, .left, false), // 🭬 ▶
        0x1FB6D => fillWedge(pixels, bytes_per_row, w, h, .top, false), // 🭭 ▼
        0x1FB6E => fillWedge(pixels, bytes_per_row, w, h, .right, false), // 🭮 ◀
        0x1FB6F => fillWedge(pixels, bytes_per_row, w, h, .bottom, false), // 🭯 ▲
        // bowtie: 두 solid wedge가 중앙에서 맞닿음.
        0x1FB9A => fillWedge(pixels, bytes_per_row, w, h, .top, false) +
            fillWedge(pixels, bytes_per_row, w, h, .bottom, false), // 🮚 세로 모래시계
        0x1FB9B => fillWedge(pixels, bytes_per_row, w, h, .left, false) +
            fillWedge(pixels, bytes_per_row, w, h, .right, false), // 🮛 가로 모래시계
        else => 0,
    };
}

/// edge wedge를 채운다 — 밑변 = edge가 가리키는 셀 변(두 꼭짓점), 세 번째 꼭짓점 = 셀 중앙. invert면 바깥.
fn fillWedge(pixels: []u8, bytes_per_row: usize, w: u32, h: u32, edge: Edge, invert: bool) u32 {
    const fw = @as(f32, @floatFromInt(w));
    const fh = @as(f32, @floatFromInt(h));
    const cx = fw / 2.0;
    const cy = fh / 2.0;
    // 밑변 두 끝점(셀 변).
    var ax: f32 = 0;
    var ay: f32 = 0;
    var bx: f32 = 0;
    var by: f32 = 0;
    switch (edge) {
        .left => { // 좌변
            bx = 0;
            by = fh;
        },
        .top => { // 상변
            bx = fw;
            by = 0;
        },
        .right => { // 우변
            ax = fw;
            bx = fw;
            by = fh;
        },
        .bottom => { // 하변
            ay = fh;
            bx = fw;
            by = fh;
        },
    }
    return gp.fillTriangle(pixels, bytes_per_row, w, h, cx, cy, ax, ay, bx, by, invert);
}

test "isLegacyWedge 범위" {
    try std.testing.expect(isLegacyWedge(0x1FB68));
    try std.testing.expect(isLegacyWedge(0x1FB6F));
    try std.testing.expect(isLegacyWedge(0x1FB9A));
    try std.testing.expect(isLegacyWedge(0x1FB9B));
    try std.testing.expect(!isLegacyWedge(0x1FB67)); // smooth mosaic(후속)
    try std.testing.expect(!isLegacyWedge(0x1FB70));
    try std.testing.expect(!isLegacyWedge(0x1FB99));
    try std.testing.expect(!isLegacyWedge(0x1FB9C)); // corner-shade(후속)
}

test "fillCoverage: solid/반전 wedge·bowtie가 올바른 영역을 채운다" {
    const w: u32 = 8;
    const h: u32 = 16;
    const bpr: usize = w * 4;
    var pixels: [16 * 8 * 4]u8 = undefined;
    const a = struct {
        fn at(p: []const u8, bpr_: usize, x: u32, y: u32) u8 {
            return p[@as(usize, y) * bpr_ + @as(usize, x) * 4 + 3];
        }
    }.at;
    // 셀 중앙 (4,8).

    // 🭬 U+1FB6C left solid: 밑변=좌변·꼭짓점=중앙 → 좌-중앙 채움, 우측은 빔.
    _ = fillCoverage(0x1FB6C, w, h, bpr, &pixels);
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, 1, 8)); // 좌-중앙 안
    try std.testing.expectEqual(@as(u8, 0x00), a(&pixels, bpr, 7, 8)); // 우-중앙 밖
    try std.testing.expectEqual(@as(u8, 0x00), a(&pixels, bpr, 7, 0)); // 우상 밖

    // 🭨 U+1FB68 left 반전: 위 wedge의 보색 → 좌-중앙 빔, 우측 채움.
    _ = fillCoverage(0x1FB68, w, h, bpr, &pixels);
    try std.testing.expectEqual(@as(u8, 0x00), a(&pixels, bpr, 1, 8)); // 좌-중앙 빔
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, 7, 8)); // 우-중앙 채움

    // 🮚 U+1FB9A 세로 bowtie(top+bottom): 상-중앙·하-중앙 채움, 좌-중앙·우-중앙 빔.
    _ = fillCoverage(0x1FB9A, w, h, bpr, &pixels);
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, 4, 1)); // 상-중앙
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, 4, 14)); // 하-중앙
    try std.testing.expectEqual(@as(u8, 0x00), a(&pixels, bpr, 1, 8)); // 좌-중앙 빔
    try std.testing.expectEqual(@as(u8, 0x00), a(&pixels, bpr, 7, 8)); // 우-중앙 빔
}
